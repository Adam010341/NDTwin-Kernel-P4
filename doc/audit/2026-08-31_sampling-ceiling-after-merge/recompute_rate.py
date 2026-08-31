#!/usr/bin/env python3
"""
recompute_rate.py -- PREREG-E §4-bis: is the path-recompute loop ACTUALLY EXECUTING, and at what
                     rate, in this round's fabric configuration?

[Co-developed with claude code -- Adam]

WHY THIS EXISTS (the blocking review finding, 2026-08-31)
    §0 corrected the batching premise: the code shipped, the flag was never set, so the behaviour
    never changed.  The SAME RULER was never applied to the surviving premise.  What the round
    could prove was that the two binaries DIFFER -- a unit test asserting the constant is
    seconds(1) passes on one arm and fails on the other.  Nothing proved that the loop containing
    that constant is ever entered on a live fabric.

    🔑 A unit test proves the VALUE of a constant.  It says nothing about whether the loop that
    reads it runs.  Third instance of one family: the batching flag, PREREG-B's F1, and this.

    The cost lands on R-E2's null cell.  "Indistinguishable within the ladder's resolution"
    currently means either "changing the period buys nothing" or "the path never executed", and
    those have opposite next actions -- stop investing, versus go fix it.  Every outcome must have
    exactly one meaning before the data exists.

WHY CONTEXT SWITCHES AND NOT CPU%
    🔴 Registered constraint: the observable must COUNT EVENTS.  1 Hz and "not running at all"
    both round to zero CPU%, so a CPU-based discriminator has no discriminating power between
    exactly the two states this check exists to separate -- which is the defect this whole round
    keeps treating.

    calFlowPathByQueried ends each pass in std::this_thread::sleep_for(kFlowPathRecomputeInterval)
    (FlowLinkUsageCollector.cpp:2969).  A sleep is a voluntary deschedule, so every pass leaves a
    mark in /proc/<pid>/task/<tid>/status:voluntary_ctxt_switches.  Counting them costs nothing,
    needs no privilege, and -- decisively -- CANNOT be instrumented into the binary, which matters
    because this project has a binary on record whose in-loop instrument flipped a headline result
    from 1.18 to 0.92.  Measuring must not change what is measured.

    Expected: ~1000/s on the 1 kHz arm, ~1/s on the 1 Hz arm, ~0/s if the loop never runs.

WHAT THE COUNT IS AND IS NOT
    🔴 It is an UPPER BOUND on passes, S >= P.  Each pass contributes AT LEAST one voluntary
    deschedule (the sleep_for), and the thread can deschedule again on a mutex, so switches
    ACCUMULATE ABOVE the pass count -- they never fall below it.  (An earlier version of this file
    called it a lower bound.  The direction was wrong; the reviewer line caught it.)

    It is therefore not used as an absolute pass count.  The registered rules are THREE, and the
    direction above is what makes each of them conservative -- rederived here so the next reader
    can check the conservatism instead of believing a claim about it:

      (a) NOT-RUNNING, S <= 0.1/s.  S >= P, so a small S implies a smaller P.  If the observable
          says almost nothing happened, even less actually happened.  VALID.
      (b) cross-arm ratio >= 10.  Mutex wakeups are ADDITIVE noise present in BOTH arms, and
          adding the same quantity to numerator and denominator pulls a ratio TOWARDS 1.  So the
          observed ratio UNDERSTATES the true one, and demanding >= 10 is stricter than the
          physics requires.  CONSERVATIVE.
      (c) per-arm band.  This one IS an absolute-rate criterion and does need the scale.  Because
          S overstates P, a genuinely-1-Hz arm can read above 20/s and be aborted when it did not
          need to be.  Its failure direction is FALSE ABORT, never false pass.  CONSERVATIVE.

    (a) and (b) need no constant of proportionality; (c) does, and is kept because it catches the
    one thing the ratio cannot: an arm running the WRONG BINARY, which shifts both arms together
    and leaves the ratio intact.

    🔑 The general lesson, bigger than the fix: a bound's direction is load-bearing, and the
    downstream rules stayed conservative here only because that was CHECKED.  A rule that is
    conservative under one direction can be anti-conservative under the other.

    The thread is located by the tid it logs at start -- log_thread_ids("calFlowPathByQueried"),
    FlowLinkUsageCollector.cpp:2738 -- and the pid on that line must match the running kernel, or
    the log is from an earlier boot and the tid means nothing.
"""
import argparse
import json
import os
import re
import sys
import time

TAG = "calFlowPathByQueried"
LINE = re.compile(r"\[" + TAG + r"\]\s+pid=(\d+)\s+tid=(\d+)")


def find_tid(klog, pid):
    """The LAST tid logged for this tag by THIS pid.  Last, because a kernel.log can span
    restarts; and pid-matched, because a tid from an earlier boot is a live tid belonging to
    somebody else -- reading it would produce a plausible number for the wrong thread."""
    tid = None
    try:
        with open(klog, "rb") as fh:
            for raw in fh:
                m = LINE.search(raw.decode("utf-8", "replace"))
                if m and int(m.group(1)) == pid:
                    tid = int(m.group(2))
    except OSError as e:
        return None, f"kernel.log unreadable: {e!r}"
    if tid is None:
        return None, (f"no '[{TAG}] pid={pid} tid=...' line in {klog} -- the thread never logged "
                      "its id for this process, so it never started")
    return tid, None


def switches(pid, tid):
    try:
        with open(f"/proc/{pid}/task/{tid}/status") as fh:
            for line in fh:
                if line.startswith("voluntary_ctxt_switches:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def measure(pid, tid, window):
    a = switches(pid, tid)
    if a is None:
        return None, "cannot read voluntary_ctxt_switches (thread gone, or /proc denied)"
    t0 = time.monotonic()
    time.sleep(window)
    b = switches(pid, tid)
    if b is None:
        return None, "the thread disappeared during the window"
    return (b - a) / (time.monotonic() - t0), None


def kernel_pid():
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/comm") as fh:
                if fh.read().strip() == "ndtwin_kernel":
                    return int(name)
        except OSError:
            continue
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--klog", default="/home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log")
    ap.add_argument("--pid", type=int)
    ap.add_argument("--window", type=float, default=20.0)
    ap.add_argument("--label", default="cell")
    ap.add_argument("--out")
    ap.add_argument("--arm", choices=("1hz", "1khz"), help="assert this arm's expected band")
    ap.add_argument("--force-zero", action="store_true",
                    help="fixture: pretend the rate is 0.0 and prove the clause fires")
    ap.add_argument("--compare", nargs=2, metavar=("KHZ_JSON", "HZ_JSON"),
                    help="apply the frozen cross-arm rule to two recorded rates")
    a = ap.parse_args()

    # ---- the frozen cross-arm rule (PREREG §4-bis) -------------------------------------------
    if a.compare:
        try:
            khz = json.loads(open(a.compare[0]).read().strip().split("\n")[-1])["passes_per_s"]
            hz = json.loads(open(a.compare[1]).read().strip().split("\n")[-1])["passes_per_s"]
        except Exception as e:                                              # noqa: BLE001
            print(f"RECOMPUTE compare verdict=UNINTERPRETABLE err={e!r}")
            return 2
        print(f"RECOMPUTE compare khz={khz} hz={hz}")
        if khz is None or hz is None or khz <= 0.1 or hz <= 0.1:
            print("RECOMPUTE compare verdict=UNINTERPRETABLE reason=an arm's loop did not run")
            print("  🔴 Q2 IS UNINTERPRETABLE.  Do NOT report 'changing the period had no effect':")
            print("     a rate at or near zero means the path never executed, which is a different")
            print("     finding with the opposite next action (go fix it, not stop investing).")
            return 2
        if khz / hz < 10.0:
            print(f"RECOMPUTE compare verdict=UNINTERPRETABLE ratio={khz/hz:.2f} (<10)")
            print("  🔴 The two arms' recompute rates are not distinguishable, so the treatment")
            print("     was not delivered.  Q2 is UNINTERPRETABLE, not null.")
            return 2
        print(f"RECOMPUTE compare verdict=DELIVERED ratio={khz/hz:.1f}")
        return 0

    # ---- one cell's reading -------------------------------------------------------------------
    rec = dict(label=a.label, when=time.strftime("%FT%T"), arm=a.arm)
    if a.force_zero:
        rate, tid, err, pid = 0.0, -1, None, -1
    else:
        pid = a.pid or kernel_pid()
        if pid is None:
            print("RECOMPUTE verdict=NO-KERNEL (no ndtwin_kernel process)")
            return 2
        tid, err = find_tid(a.klog, pid)
        rate = None
        if err is None:
            rate, err = measure(pid, tid, a.window)

    rec.update(pid=pid, tid=tid, passes_per_s=None if rate is None else round(rate, 3), err=err)

    if err is not None:
        rec["verdict"] = "UNREADABLE"
        print(f"RECOMPUTE {a.label} verdict=UNREADABLE err={err}")
    elif rate <= 0.1:
        rec["verdict"] = "NOT-RUNNING"
        print(f"RECOMPUTE {a.label} pid={pid} tid={tid} passes_per_s={rate:.3f} verdict=NOT-RUNNING")
        print("  🔴 The recompute loop is not executing.  A null result on Q2 from this arm would")
        print("     mean 'the path never ran', NOT 'the period change bought nothing'.")
    else:
        rec["verdict"] = "RUNNING"
        print(f"RECOMPUTE {a.label} pid={pid} tid={tid} passes_per_s={rate:.3f} verdict=RUNNING")

    # Per-arm band -- the third rule, and the only ABSOLUTE one (see the module docstring).
    # Deliberately wide: switches OVERSTATE passes (S >= P), so a tight band would abort a healthy
    # arm on mutex noise.  Its failure direction is false-abort, never false-pass.  It is kept
    # because it catches what the ratio cannot: an arm running the wrong binary moves both arms
    # together and leaves the ratio looking fine.
    if a.arm and rec["verdict"] == "RUNNING":
        lo, hi = (0.2, 20.0) if a.arm == "1hz" else (100.0, 1e9)
        if not (lo <= rate <= hi):
            rec["verdict"] = "WRONG-BAND"
            print(f"  🔴 arm={a.arm} expects {lo}..{hi} passes/s, measured {rate:.3f}.")
            print("     The running binary is not behaving like the arm it is labelled.")

    if a.out:
        with open(a.out, "a") as fh:
            fh.write(json.dumps(rec) + "\n")
    return 0 if rec["verdict"] == "RUNNING" else 2


if __name__ == "__main__":
    sys.exit(main())
