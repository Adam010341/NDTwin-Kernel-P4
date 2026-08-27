#!/usr/bin/env python3
"""Ticket G, secondary analysis: split "not running" into "parked in a wait" and "not on a CPU
at all", which the registered W does not distinguish.

[Co-developed with claude code -- Adam]

WRITTEN BEFORE THE LOADED ARM WAS READ.  This file exists because the IDLE arm -- which the
pre-registration names as the classifier's known-good input -- came back with W = 0.20 instead of
0, and the six offending dumps were a startup thread (`switch-entered-retry` in
kernel_notifier.renotify_until_acknowledged) plus two receivers sitting at grpc/_channel.py:932.
Line 932 is inside `self._call.operate(...)`, a cygrpc call that releases the GIL, so a thread
there is running in C, not queued behind the interpreter.  Neither is a GIL queue, and both would
inflate W under load.  The registration says: if the idle arm's W is not ~0, fix the classifier
BEFORE reading the loaded arm.  That is what this is, and the mtime of this file against
raw_gil/l/window.txt is the evidence of the ordering.

gil_parse.py IS NOT EDITED.  The registered W stays exactly as registered and is still the
primary number; this only adds a second, clearly-labelled reading beside it.  Changing the
instrument after seeing the treatment arm is the move pre-registration exists to prevent, so the
refinement is derived from the control arms alone and both numbers are always printed together.

THE REFINEMENT.  py-spy reports `active` from the OS thread state, independently of `owns_gil`:
  owns_gil=True                -> holds the interpreter
  active=True,  owns_gil=False -> on a CPU with the GIL released, i.e. inside a C extension
  active=False, owns_gil=False -> not on a CPU: either waiting on I/O, or queued for the GIL
Only the third line can be a GIL queue, so W' additionally requires active=False.
"""
import glob
import json
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gil_parse import is_blocked, load_dumps, thread_cpu  # noqa: E402

# Frames found in the CONTROL arms that the registered list misses. Each is justified above; none
# was chosen by looking at the loaded arm.
EXTRA_BLOCKING = [
    ("_channel.py", "_next"),                       # inside cygrpc operate(): C, GIL released
    ("kernel_notifier.py", "renotify_until_acknowledged"),
]


def is_blocked2(top):
    if is_blocked(top):
        return True
    if top is None:
        return True
    return any(top.get("short_filename") == f and top.get("name") == n for f, n in EXTRA_BLOCKING)


def analyse2(dumps):
    ok = [(n, t) for n, t in dumps if not isinstance(t, Exception)]
    if not ok:
        return None
    n = len(ok)
    acc = Counter()
    per = defaultdict(Counter)
    hist_w2 = Counter()
    tid_name = {}
    for _, threads in ok:
        w2 = 0
        for t in threads:
            nm = t.get("thread_name") or "(unnamed)"
            tid_name[t.get("os_thread_id")] = nm
            top = t["frames"][0] if t.get("frames") else None
            gil, act = bool(t.get("owns_gil")), bool(t.get("active"))
            if gil:
                per[nm]["gil"] += 1
                acc["gil"] += 1
            elif act:
                per[nm]["c_running"] += 1        # on a CPU without the GIL: C extension
                acc["c_running"] += 1
            elif is_blocked2(top):
                per[nm]["blocked"] += 1
                acc["blocked"] += 1
            else:
                per[nm]["queued"] += 1           # parked, not in any known wait: GIL queue
                acc["queued"] += 1
                w2 += 1
        hist_w2[w2] += 1
    return {"n": n, "acc": acc, "per": per, "hist": hist_w2, "tid_name": tid_name,
            "W2": sum(k * v for k, v in hist_w2.items()) / n}


def main(base, arms):
    for arm in arms:
        d = os.path.join(base, arm)
        r = analyse2(load_dumps(d))
        print("=" * 78)
        print("ARM %s (refined)" % arm)
        if r is None:
            print("  NO-DATA")
            continue
        cpu = None
        meta = os.path.join(d, "window.txt")
        if os.path.exists(meta):
            el = float(open(meta).read().split()[0])
            s, e = os.path.join(d, "task_start.txt"), os.path.join(d, "task_end.txt")
            if os.path.exists(s) and os.path.exists(e):
                cpu = thread_cpu(s, e, el)
        tot = sum(r["acc"].values())
        print("  thread-states over %d dumps (%d thread-observations):" % (r["n"], tot))
        for k in ("gil", "c_running", "blocked", "queued"):
            print("      %-10s %6d  %5.1f%%" % (k, r["acc"][k], 100.0 * r["acc"][k] / tot))
        print("  W' (parked, not in a known wait) mean %.2f  hist %s"
              % (r["W2"], dict(sorted(r["hist"].items()))))
        if cpu:
            print("  top threads by CPU, with state mix:")
            print("      %-28s %7s %8s %10s %9s %8s" %
                  ("thread", "cpu%", "gil%", "c_run%", "blocked%", "queued%"))
            for tid, pct in sorted(cpu.items(), key=lambda kv: -kv[1])[:14]:
                nm = r["tid_name"].get(tid, "(tid %d)" % tid)
                p = r["per"][nm]
                print("      %-28s %6.1f%% %7.1f%% %9.1f%% %8.1f%% %7.1f%%" % (
                    nm[:28], pct,
                    100.0 * p["gil"] / r["n"], 100.0 * p["c_running"] / r["n"],
                    100.0 * p["blocked"] / r["n"], 100.0 * p["queued"] / r["n"]))
            print("      TOTAL %.1f%% over %d os threads" % (sum(cpu.values()), len(cpu)))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
