#!/usr/bin/env python3
"""Ticket H: join py-spy's view of a thread to the kernel's, and say what the sleepers at
sflow_emitter.py:363 are actually waiting on.

[Co-developed with claude code -- Adam]

Pre-registration: PREREG.md, section "工單 H".  Three registered checks, three calls here:
  --selftest        the parser, against inputs whose answer is known
  step 0 + 1        wchan of the emit(363) sleepers, and the collector's queue and drops
  step 2            py-spy's `active` flag against /proc state, with the 60% floor

WHY wchan IS THE WHOLE ARGUMENT.  A thread asleep at a sendto call can be in the kernel's send
path or somewhere else entirely, and Python-level frames cannot tell those apart -- the frame
says where the interpreter stopped, not what the OS is waiting for.  /proc/<tid>/wchan names the
kernel function it is parked in.  futex_do_wait means it is on a futex, which is what CPython's
GIL is built on, and NOT in the send path.  A socket wait means it really is stuck sending.

THE RACE IS HANDLED BY DISCARDING, NOT BY HOPING.  py-spy and /proc are read milliseconds apart,
so each is read twice -- once before the dump and once after -- and any thread whose value moved
between the two reads is dropped as in transit rather than assigned to whichever read is
convenient.  If fewer than 60% survive, the check reports INCONCLUSIVE, which is not PASS.
"""
import glob
import json
import os
import sys
from collections import Counter, defaultdict

STABLE_FLOOR = 0.60          # registered: below this the check is INCONCLUSIVE, not PASS

# The frame whose sleepers are the question. Parameterised ONLY so the smoke test can drive the
# accept path with a stand-in process -- shipping step 0 exercised only by its NO-DATA branch is
# how "eight refusal paths green, accept path 100% broken" happened before. The default is the
# real target and no run overrides it.
TARGET_FILE, TARGET_FUNC = "sflow_emitter.py", "emit"
# emit() spans more than one interesting line: :355 is build_datagram, :363 is the sendto. The
# question is about the SEND, so the line is part of the filter -- but observations at other
# lines inside emit are counted and printed rather than silently dropped, because "my filter ate
# them" and "they do not exist" must not look the same. The review's 59-vs-60 reconciliation was
# exactly this: their :363 filter and my whole-function filter differed by one :355 sample.
TARGET_LINE = 363
# hrtimer_nanosleep is NOT in here. It is what time.sleep() parks in, and the smoke test caught
# this file lumping it under "futex" -- which would have inflated the exact share the step-0
# verdict keys on, turning a thread that chose to sleep into evidence of GIL contention.
FUTEX = ("futex", "do_futex")
TIMER = ("hrtimer_nanosleep", "schedule_hrtimeout")
# Candidate (a), the UDP send path. NOT sk_stream_wait_memory -- the review pointed out that
# symbol is TCP-side and can never appear for a SOCK_DGRAM send, so keying on it would have made
# (a) unfalsifiable: it could never fire, and I would have read that as "(a) is out".
SEND_WAIT = ("sock_wait_for_wmem", "sock_alloc_send_pskb", "sk_stream_wait_memory")
# Candidate (c), direct reclaim. Ticket G ran at loadavg ~11.
RECLAIM = ("shrink_", "try_to_free_pages", "congestion_wait", "reclaim")
SOCKET_WAIT = ("sk_stream_wait_memory", "sk_wait_data", "wait_woken", "sock_wait",
               "unix_stream_read", "skb_wait_for_more_packets")


def kind(w):
    """Classify a wchan string into the three registered buckets."""
    if not w or w in ("0", "-"):
        return "unreadable"
    if any(f in w for f in FUTEX):
        return "futex"
    if any(t in w for t in TIMER):
        return "timer-sleep"
    if any(s in w for s in SEND_WAIT):
        return "send-wait"
    if any(r in w for r in RECLAIM):
        return "reclaim"
    return "other:" + w


def read_kv(path):
    """tid -> value, from a file of 'tid value' lines."""
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path):
        parts = line.split(None, 1)
        if len(parts) == 2:
            out[int(parts[0])] = parts[1].strip()
    return out


def stable(before, after):
    """Only threads whose value did not move between the two reads. Returns (kept, seen)."""
    keep = {t: v for t, v in after.items() if before.get(t) == v}
    return keep, set(before) | set(after)


def iterations(d):
    for p in sorted(glob.glob(os.path.join(d, "it_*_dump.json"))):
        stem = p[:-len("_dump.json")]
        try:
            threads = json.load(open(p))
        except Exception:
            continue
        yield {
            "threads": threads,
            "wchan": stable(read_kv(stem + "_wchan_a.txt"), read_kv(stem + "_wchan_b.txt")),
            "state": stable(read_kv(stem + "_state_a.txt"), read_kv(stem + "_state_b.txt")),
            "udp": read_kv(stem + "_udp.txt"),
        }


def step01(d):
    """Where the emit(363) sleepers are parked, and what the collector's socket looks like."""
    buckets, per_thread, raw = Counter(), defaultdict(Counter), Counter()
    other_lines = Counter()
    n_emit = n_joined = n_it = 0
    rx, drops = [], []
    for it in iterations(d):
        n_it += 1
        wchan, _ = it["wchan"]
        if it["udp"].get(6343):
            r, dr = it["udp"][6343].split()[:2]
            rx.append(int(r)); drops.append(int(dr))
        for t in it["threads"]:
            f = t["frames"][0] if t.get("frames") else None
            if not (f and f["short_filename"] == TARGET_FILE and f["name"] == TARGET_FUNC):
                continue
            if f["line"] != TARGET_LINE:
                other_lines[f["line"]] += 1          # counted, never silently dropped
                continue
            if t.get("owns_gil") or t.get("active"):
                continue                              # only the SLEEPERS are the question
            n_emit += 1
            w = wchan.get(t.get("os_thread_id"))
            if w is None:
                continue                              # moved between the two reads: discarded
            n_joined += 1
            buckets[kind(w)] += 1
            raw[w] += 1
            per_thread[t["thread_name"][:26]][kind(w)] += 1

    print("--- step 0: what the emit(%d) sleepers are parked in (%d iterations) ---"
          % (TARGET_LINE, n_it))
    if other_lines:
        print("  (sleepers inside emit() at OTHER lines, excluded from the verdict: %s)"
              % dict(sorted(other_lines.items())))
    print("  emit sleepers seen %d, joined to a stable wchan %d (%s)"
          % (n_emit, n_joined,
             "%.0f%%" % (100.0 * n_joined / n_emit) if n_emit else "n/a"))
    if not n_joined:
        print("  NO-DATA: nothing to classify")
    else:
        for k, v in buckets.most_common():
            print("      %-14s %4d  %5.1f%%" % (k, v, 100.0 * v / n_joined))
        print("  raw wchan strings (verbatim, so this can be reclassified):")
        for k, v in raw.most_common(8):
            print("      %4d  %s" % (v, k))
        print("  by thread:")
        for nm, c in per_thread.items():
            print("      %-26s %s" % (nm, dict(c)))
        futex_share = buckets["futex"] / n_joined
        print("  VERDICT step 0: futex share %.3f -> %s" % (
            futex_share,
            "(a) OUT, (b) supported -- not in the send path" if futex_share >= 0.80 else
            "(a) REVIVED -- really stuck in the UDP send path"
            if buckets["send-wait"] / n_joined >= 0.50 else
            "(c) SUPPORTED -- direct reclaim" if buckets["reclaim"] / n_joined >= 0.50 else
            "NONE OF THE ABOVE (e) -- record verbatim, do not force"))

    print("--- step 1: collector socket 127.0.0.1:6343 ---")
    if not rx:
        print("  NO-DATA: port 6343 absent from /proc/net/udp (kernel not listening?)")
    else:
        print("  rx_queue  min %d  max %d      (registered: queue empty => (a) out)" % (min(rx), max(rx)))
        print("  drops     first %d  last %d  delta %d   <- CUMULATIVE, read as a difference"
              % (drops[0], drops[-1], drops[-1] - drops[0]))
        print("  VERDICT step 1: %s" % (
            "(a) OUT -- queue empty and no drops" if max(rx) == 0 and drops[-1] == drops[0] else
            "(a) REVIVED as DROPS, not blocking -- ticket E's 'no samples lost' must be re-verified"))


def step2(d):
    """py-spy's `active` flag against the kernel's own idea of the thread state."""
    agree = disagree = 0
    kept = seen = 0
    mism = Counter()
    for it in iterations(d):
        state, allseen = it["state"]
        seen += len(allseen)
        kept += len(state)
        for t in it["threads"]:
            s = state.get(t.get("os_thread_id"))
            if s is None:
                continue
            running = s.split()[0] == "R"
            if bool(t.get("active")) == running:
                agree += 1
            else:
                disagree += 1
                mism[(bool(t.get("active")), s.split()[0])] += 1
    share = kept / seen if seen else 0.0
    tot = agree + disagree
    print("--- step 2: does py-spy's `active` mean what I assumed? ---")
    print("  threads with a stable state across the dump: %d/%d = %.0f%% (floor %.0f%%)"
          % (kept, seen, 100 * share, 100 * STABLE_FLOOR))
    if share < STABLE_FLOOR:
        print("  INCONCLUSIVE -- below the registered floor. This is NOT a pass.")
        return
    if not tot:
        print("  NO-DATA")
        return
    print("  agreement %d/%d = %.1f%%" % (agree, tot, 100.0 * agree / tot))
    for (act, st), c in mism.most_common(6):
        print("      py-spy active=%-5s but /proc state=%s : %d" % (act, st, c))
    print("  VERDICT step 2: %s" % (
        "flag is sound -- (d) out" if agree / tot >= 0.95 else
        "FLAG SUSPECT -- (d) survives, and ticket G's `active` readings inherit the doubt"))


def selftest():
    import tempfile
    assert kind("futex_do_wait") == "futex"
    assert kind("hrtimer_nanosleep") == "timer-sleep", "time.sleep must not count as GIL waiting"
    assert kind("sock_wait_for_wmem") == "send-wait"
    assert kind("sk_stream_wait_memory") == "send-wait"   # TCP-only; kept so it cannot go unseen
    assert kind("shrink_node") == "reclaim"
    assert kind("ep_poll") == "other:ep_poll"
    assert kind("0") == "unreadable" and kind("") == "unreadable"
    # a value that moved between the two reads must be dropped, not silently resolved
    keep, seen = stable({1: "a", 2: "b"}, {1: "a", 2: "c"})
    assert keep == {1: "a"} and seen == {1, 2}, (keep, seen)
    # an empty directory must report NO-DATA rather than 0.0
    with tempfile.TemporaryDirectory() as td:
        assert list(iterations(td)) == []
    print("SELFTEST PASS (futex/socket/other/unreadable, moved values dropped, empty dir empty)")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest(); sys.exit(0)
    if "--target" in sys.argv:                      # smoke test only; see TARGET_FILE above
        i = sys.argv.index("--target")
        TARGET_FILE, TARGET_FUNC = sys.argv[i + 1].split(":")
        del sys.argv[i:i + 2]
    d = sys.argv[1]
    print("=" * 78)
    print("TICKET H  dir=%s" % d)
    step01(d)
    step2(d)
