#!/usr/bin/env python3
"""Ticket G: read a directory of py-spy JSON dumps and say who holds the GIL, who is queued
behind it, and who is merely parked in a syscall.

[Co-developed with claude code -- Adam]

WHY A SEPARATE PARSER RATHER THAN py-spy top.  `py-spy top --gil` answers "which function holds
the GIL" but not "how many threads had Python work to do and were not running", and the second
question is the one that decides the fix.  A thread queued on the GIL and a thread blocked in
recvfrom look identical to /proc -- both are in S -- so the discriminator has to be the stack
top, which only the per-dump JSON carries.

THE CLASSIFIER IS MINE, AND THAT IS THE WEAK POINT.  BLOCKING_FRAMES below is a hand-written
list.  It is printed verbatim by --show-classifier, the modal frame of every thread is printed
alongside the verdict so the reader can reclassify, and the idle arm is a known-good input: with
no traffic every thread must classify as blocked.  If it does not, this file is wrong and the
loaded arm must not be read.
"""
import glob
import json
import os
import sys
from collections import Counter, defaultdict

# (short_filename, function name) pairs that mean "this thread is waiting on something outside
# the interpreter and is NOT competing for the GIL".  Matched on the TOP frame only.
BLOCKING_FRAMES = [
    ("threading.py", "wait"),          # Condition.wait / Event.wait -- parked
    ("threading.py", "acquire"),       # lock acquire
    ("selectors.py", "select"),        # asyncio / socketserver event loop idle
    ("_channel.py", "channel_spin"),   # grpc: blocks in C on the completion queue
    ("_channel.py", "consume_request_iterator"),
    ("queue.py", "get"),
    ("socket.py", "recv"),
    ("socket.py", "recvfrom"),
    ("socket.py", "accept"),
    ("socket.py", "readinto"),
    ("ssl.py", "read"),
    ("subprocess.py", "wait"),
    ("time", "sleep"),
]
# Any top frame whose function is exactly one of these counts as blocked regardless of file.
BLOCKING_FUNCS = {"sleep", "poll", "epoll_wait", "select", "channel_spin", "wait"}

CLK_TCK = os.sysconf("SC_CLK_TCK")


def is_blocked(top):
    """True if this thread's top frame is a call that waits outside the interpreter."""
    if top is None:
        return True                      # no Python frames at all: it is not running Python
    fn, name = top.get("short_filename") or "", top.get("name") or ""
    if name in BLOCKING_FUNCS:
        return True
    return any(fn == f and name == n for f, n in BLOCKING_FRAMES)


def load_dumps(d):
    out = []
    for p in sorted(glob.glob(os.path.join(d, "dump_*.json"))):
        try:
            with open(p) as fh:
                out.append((os.path.basename(p), json.load(fh)))
        except Exception as e:                      # a failed dump is a result, not a crash
            out.append((os.path.basename(p), e))
    return out


def analyse(dumps):
    """Return the pre-registered metrics.  `dumps` is [(name, threads|Exception)]."""
    ok = [(n, t) for n, t in dumps if not isinstance(t, Exception)]
    bad = [n for n, t in dumps if isinstance(t, Exception)]
    if not ok:
        return None

    gil_dumps = 0
    multi_owner = []                      # the "none of the above" branch
    queued = []                           # W per dump
    owner_count = Counter()
    active_count = Counter()
    frame_mode = defaultdict(Counter)
    thread_sets = Counter()
    tid_name = {}

    for name, threads in ok:
        owners = [t for t in threads if t.get("owns_gil")]
        if owners:
            gil_dumps += 1
        if len(owners) > 1:
            multi_owner.append((name, [t.get("thread_name") for t in owners]))
        for t in owners:
            owner_count[t.get("thread_name") or "(unnamed)"] += 1

        w = 0
        for t in threads:
            nm = t.get("thread_name") or "(unnamed)"
            tid_name[t.get("os_thread_id")] = nm
            top = t["frames"][0] if t.get("frames") else None
            frame_mode[nm][
                "%s:%s(%s)" % (top["short_filename"], top["line"], top["name"]) if top else "(no frames)"
            ] += 1
            if t.get("active"):
                active_count[nm] += 1
            if not t.get("owns_gil") and not is_blocked(top):
                w += 1
        queued.append(w)
        thread_sets[len(threads)] += 1

    n = len(ok)
    return {
        "n_dumps": n,
        "n_failed": len(bad),
        "failed": bad,
        "G": gil_dumps / n,
        "W_mean": sum(queued) / n,
        "W_max": max(queued),
        "W_hist": Counter(queued),
        "multi_owner": multi_owner,
        "owner_count": owner_count,
        "active_count": active_count,
        "frame_mode": frame_mode,
        "thread_set_sizes": thread_sets,
        "tid_name": tid_name,
    }


def read_task_stat(path):
    """{tid: utime+stime in ticks} from a saved `cat /proc/PID/task/*/stat` dump."""
    out = {}
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        # comm can contain spaces and parentheses; everything after the LAST ')' is positional.
        try:
            tid = int(line.split(None, 1)[0])
            rest = line[line.rindex(")") + 1:].split()
        except (ValueError, IndexError):
            continue
        # rest[0] is state (field 3), so utime (field 14) is rest[11], stime (15) is rest[12].
        out[tid] = int(rest[11]) + int(rest[12])
    return out


def thread_cpu(start_path, end_path, elapsed):
    a, b = read_task_stat(start_path), read_task_stat(end_path)
    return {
        tid: (b[tid] - a[tid]) / CLK_TCK / elapsed * 100.0
        for tid in b if tid in a
    }


def verdict_G(g):
    if g >= 0.90:
        return "SATURATED (necessary condition met, not sufficient)"
    if g <= 0.60:
        return "H-GIL REFUTED"
    return "BAND -- no point claim"


def verdict_W(w):
    if w >= 1.0:
        return "QUEUE (threads have Python work and are not running)"
    if w <= 0.2:
        return "NO QUEUE (non-runners are blocked on I/O; GIL held but uncontended)"
    return "BAND -- no point claim"


def report(arm, d, cpu=None, elapsed=None):
    r = analyse(load_dumps(d))
    print("=" * 78)
    print("ARM %s   dir=%s" % (arm, d))
    if r is None:
        print("  NO-DATA: no readable dumps")
        return
    print("  dumps            %d ok, %d failed %s" % (r["n_dumps"], r["n_failed"], r["failed"] or ""))
    print("  thread-set sizes %s" % dict(r["thread_set_sizes"]))
    print("  G  (GIL held)    %.3f   -> %s" % (r["G"], verdict_G(r["G"])))
    print("  W  (queued)      mean %.2f  max %d  hist %s"
          % (r["W_mean"], r["W_max"], dict(sorted(r["W_hist"].items()))))
    print("                   -> %s" % verdict_W(r["W_mean"]))
    if r["multi_owner"]:
        print("  !! NONE-OF-THE-ABOVE: %d dumps with >1 owns_gil: %s"
              % (len(r["multi_owner"]), r["multi_owner"][:3]))
    print("  GIL owners (share of dumps):")
    for nm, c in r["owner_count"].most_common(10):
        print("      %-28s %5.1f%%" % (nm, 100.0 * c / r["n_dumps"]))
    if not r["owner_count"]:
        print("      (none)")

    print("  per-thread, sorted by CPU%s:" % (" (independent of py-spy)" if cpu else " unavailable"))
    if cpu:
        rows = sorted(cpu.items(), key=lambda kv: -kv[1])[:12]
        print("      %-28s %7s %7s %7s  %s" % ("thread", "cpu%", "gil%", "active%", "modal top frame"))
        for tid, pct in rows:
            nm = r["tid_name"].get(tid, "(tid %d, not in py-spy)" % tid)
            mode = r["frame_mode"][nm].most_common(1)
            print("      %-28s %6.1f%% %6.1f%% %6.1f%%  %s" % (
                nm[:28], pct,
                100.0 * r["owner_count"].get(nm, 0) / r["n_dumps"],
                100.0 * r["active_count"].get(nm, 0) / r["n_dumps"],
                mode[0][0] if mode else "-"))
        print("      TOTAL over all %d os threads: %.1f%%" % (len(cpu), sum(cpu.values())))
    return r


def selftest():
    """Feed the classifier inputs whose answer is known before trusting it on real dumps."""
    def th(name, fn, func, gil=False, active=False):
        return {"thread_name": name, "os_thread_id": hash(name) % 100000,
                "owns_gil": gil, "active": active,
                "frames": [{"short_filename": fn, "name": func, "line": 1}]}

    parked = [th("a", "threading.py", "wait"), th("b", "_channel.py", "channel_spin"),
              th("c", "selectors.py", "select")]
    r = analyse([("d1", parked), ("d2", parked)])
    assert r["G"] == 0.0, r["G"]
    assert r["W_mean"] == 0.0, r["W_mean"]

    busy = [th("a", "emitter.py", "_handle", gil=True, active=True),
            th("b", "emitter.py", "_handle", active=True),
            th("c", "emitter.py", "_handle", active=True),
            th("d", "threading.py", "wait")]
    r = analyse([("d1", busy)])
    assert r["G"] == 1.0, r["G"]
    assert r["W_mean"] == 2.0, r["W_mean"]        # b and c queued; d parked; a owns it

    two = [th("a", "x.py", "f", gil=True), th("b", "x.py", "f", gil=True)]
    r = analyse([("d1", two)])
    assert len(r["multi_owner"]) == 1, r["multi_owner"]

    r = analyse([("d1", RuntimeError("boom"))])
    assert r is None, "an all-failed directory must report NO-DATA, not 0.0"

    r = analyse([("d1", parked), ("d2", RuntimeError("boom"))])
    assert r["n_dumps"] == 1 and r["n_failed"] == 1

    print("SELFTEST PASS (parked->W=0, busy->W=2, two-owners flagged, all-failed->None)")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    if "--show-classifier" in sys.argv:
        print("BLOCKING_FUNCS =", sorted(BLOCKING_FUNCS))
        for f, n in BLOCKING_FRAMES:
            print("  %-18s %s" % (f, n))
        sys.exit(0)
    base = sys.argv[1]
    for arm in sys.argv[2:]:
        d = os.path.join(base, arm)
        cpu = elapsed = None
        meta = os.path.join(d, "window.txt")
        if os.path.exists(meta):
            elapsed = float(open(meta).read().split()[0])
            s, e = os.path.join(d, "task_start.txt"), os.path.join(d, "task_end.txt")
            if os.path.exists(s) and os.path.exists(e):
                cpu = thread_cpu(s, e, elapsed)
        report(arm, d, cpu, elapsed)
