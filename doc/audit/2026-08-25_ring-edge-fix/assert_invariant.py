#!/usr/bin/env python3
"""B's invariant, checked against SIGUSR2 dumps.

    No synchronous topology request-reply runs on IntelligentRyu's event loop.

Concretely: no greenlet whose stack contains app_manager's `_event_loop` may also contain
get_switch / get_link / get_all_host / send_request. A violation is the ring's precondition; its
absence is what B is for.

WHY THIS AND NOT A WEDGE RATE. Every previous test of this defect needed the wedge to be
summonable, and it decays -- 4/4 at 17.48h uptime, 1/4 at 18.43h, and Phase 0 spent twenty-one
minutes establishing only that the target still existed. This question does not need the target:
the frames either show the call on the loop or they do not.

VALIDATED AGAINST KNOWN-BAD INPUT. `--selftest` runs it over the pre-B wedge dumps, where the
event loop demonstrably WAS parked in get_switch/get_link, and requires it to flag them. A checker
that has only ever seen passing input is not evidence of anything.

[Co-developed with claude code -- Adam]
"""
import os
import re
import sys
import glob

FORBIDDEN = ("get_switch", "get_link", "get_all_host", "send_request")
LOOP = "_event_loop"


def blocks(text):
    """Each greenlet stack in a dump file (files hold several appended dumps)."""
    return text.split("--- greenlet ")[1:]


def violations(path):
    """(frame-line, call) for every event-loop greenlet holding a topology request-reply."""
    out = []
    for b in blocks(open(path, errors="replace").read()):
        if LOOP not in b:
            continue
        for line, code in re.findall(r'File "([^"]+)", line \d+, in \S+\n\s*(.*)', b):
            for f in FORBIDDEN:
                if f + "(" in code:
                    out.append((os.path.basename(path), f, code.strip()[:80]))
                    break
    return out


def loops_seen(path):
    return sum(1 for b in blocks(open(path, errors="replace").read()) if LOOP in b)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--selftest":
        here = os.path.dirname(os.path.abspath(__file__))
        known_bad = sorted(glob.glob(os.path.join(here, "raw", "boot[12]_greenlets.txt")))
        known_bad += sorted(glob.glob(os.path.join(here, "..",
                                                   "2026-08-25_ring-fix-verify", "raw",
                                                   "*_greenlets.txt")))
        # The THIRD site. Everything above parks in get_switch or get_link, so without this the
        # selftest only ever proved detection for two of the three calls it claims to cover --
        # and get_all_host is the one d1d973d already bounded, i.e. the site whose signature is
        # least like the others. Added on the auditer's independent recheck, which included it.
        known_bad += sorted(glob.glob(os.path.join(here, "..", "2026-08-25_host-learning-curve",
                                                   "raw", "wedge_*_greenlets.txt")))
        if not known_bad:
            print("🔴 selftest cannot run: no pre-B dumps found")
            return 2
        bad = 0
        for p in known_bad:
            v = violations(p)
            ok = bool(v)                       # these MUST be flagged
            print(f"  {'flagged' if ok else '🔴 MISSED'}  {os.path.basename(p):<28} "
                  f"loops={loops_seen(p)}  hits={len(v)}"
                  + (f"  e.g. {v[0][1]}" if v else ""))
            if not ok:
                bad += 1
        print(f"\n{len(known_bad)} known-bad dumps, {bad} missed")
        print("PASS: the checker detects the pre-B violation it is meant to detect"
              if bad == 0 else "🔴 FAIL: checker missed a known violation -- do not trust it")
        return 0 if bad == 0 else 1

    if not args:
        print(__doc__)
        return 2

    total = 0
    loops = 0
    for p in args:
        v = violations(p)
        loops += loops_seen(p)
        total += len(v)
        for name, call, code in v:
            print(f"  🔴 VIOLATION {name}: event loop inside {call} -- {code}")
    print(f"\n{len(args)} dump file(s), {loops} event-loop stack(s) examined, {total} violation(s)")
    if loops == 0:
        print("🔴 INCONCLUSIVE: no event-loop stacks found. The dump did not capture what this "
              "asserts about -- absence of violations here is not evidence.")
        return 2
    print("PASS: B's invariant holds across every sampled dump" if total == 0
          else "🔴 FAIL: a topology request-reply ran on the event loop")
    return 0 if total == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
