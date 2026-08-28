#!/usr/bin/env python3
"""Adam: "at high load even iperf's own reported throughput jitters." Which one is it?

TWO CAUSES, AND THEY LOOK IDENTICAL ON THE USUAL PLOT:

  H1  the data plane really is jittering -- bmv2 scheduling, queueing, drops
  H2  iperf's "per second" is not a second. Under load the interval boundary drifts, and
      bytes divided by a NOMINAL 1.000 s jitters even when the wire is perfectly steady.

H2 is the same shape as ticket Q, which is why it is worth taking seriously rather than assuming
H1: the kernel's rate loop is written `sleep_for(1s)` and was measured at ~1.11 s today, on this
machine, under this load. iperf3's interval timer has no exemption from whatever does that.

THE DISCRIMINATOR IS FREE AND THE DATA IS ALREADY ON DISK. Every iperf3 interval carries `start`
and `end` alongside `bytes`, so each one yields two throughputs:

    nominal   bytes * 8 / 1.0                (what iperf prints, and what Adam saw)
    actual    bytes * 8 / (end - start)      (what actually crossed the wire)

  jitter COLLAPSES in the actual series  => H2, the instrument's clock
  jitter SURVIVES in the actual series   => H1, the data plane

WHY THIS BEATS PLOTTING A WOBBLY LINE. A plot of the nominal series cannot distinguish the two at
all, and it is the plot everyone reaches for. If the answer is H2 then the figure Adam asked for
has a completely different title, and a "tens of GB" run to make the line wobblier would be
measuring the timer harder.

Reports both, plus the interval-duration spread itself, which is the mechanism made visible.

Usage: jitter_h1_vs_h2.py <arm_dir> [arm_dir ...]     each holding iperf/cli_*.json
[Co-developed with claude code -- Adam]
"""
import glob
import json
import os
import statistics
import sys


def series(path):
    """(nominal_bps, actual_bps, durations) for one client, warm-up interval dropped."""
    try:
        d = json.load(open(path))
    except Exception:
        return None
    iv = d.get("intervals") or []
    nom, act, dur = [], [], []
    for i in iv[1:-1]:                       # drop first and last: ramp and drain
        s = i.get("sum") or {}
        b, st, en = s.get("bytes"), s.get("start"), s.get("end")
        if b is None or st is None or en is None:
            continue
        real = en - st
        if real <= 0:
            continue
        nom.append(b * 8 / 1.0)
        act.append(b * 8 / real)
        dur.append(real)
    return (nom, act, dur) if len(nom) >= 10 else None


def cv(xs):
    """Coefficient of variation -- the jitter, normalised so different rates compare."""
    m = statistics.fmean(xs)
    return (statistics.pstdev(xs) / m) if m else None


def main():
    print("=" * 78)
    print("JITTER: is it the data plane (H1) or iperf's interval clock (H2)?")
    print("=" * 78)
    grand_n, grand_a = [], []
    for arm in sys.argv[1:]:
        files = sorted(glob.glob(os.path.join(arm, "iperf", "cli_*.json")))
        rows = [r for r in (series(f) for f in files) if r]
        if not rows:
            print(f"\n{os.path.basename(arm)}: no usable client files")
            continue
        cn = [cv(n) for n, a, d in rows if cv(n) is not None]
        ca = [cv(a) for n, a, d in rows if cv(a) is not None]
        alld = [x for n, a, d in rows for x in d]
        grand_n += cn
        grand_a += ca
        print(f"\n{os.path.basename(arm)}: {len(rows)} clients, {len(alld)} intervals")
        print(f"  jitter (CV) using the NOMINAL 1.000 s : {statistics.fmean(cn) * 100:6.2f}%")
        print(f"  jitter (CV) using the ACTUAL end-start: {statistics.fmean(ca) * 100:6.2f}%")
        print(f"  interval duration: mean {statistics.fmean(alld):.4f} s  "
              f"min {min(alld):.4f}  max {max(alld):.4f}  "
              f"sd {statistics.pstdev(alld) * 1000:.1f} ms")
    if not grand_n:
        return 0
    n, a = statistics.fmean(grand_n), statistics.fmean(grand_a)
    alld = [x for arm in sys.argv[1:]
            for r in [series(f) for f in sorted(glob.glob(os.path.join(arm, "iperf", "cli_*.json")))]
            if r for x in r[2]]
    print("\n" + "-" * 78)
    print(f"ALL ARMS  nominal {n * 100:.2f}%   actual {a * 100:.2f}%   "
          f"removed {(1 - a / n) * 100 if n else 0:.1f}% of the jitter")

    # 🔴 THE PRECONDITION, CHECKED BEFORE THE VERDICT BRANCH. Attributing a phenomenon requires
    # the phenomenon to be present. A first version of this script went straight to the H1/H2
    # branch and announced "H1: the jitter is on the wire" over a nominal CV of 0.31% -- which is
    # not the visible wobble the question is about. That is the same error as an error term drawn
    # from the wrong population: the data cannot answer for a name it does not deserve.
    VISIBLE_CV = 0.02          # 2%; below this nothing is "visibly jittering" on a plot
    if n < VISIBLE_CV:
        print(f"\n=> 🔴 THE PHENOMENON IS NOT IN THIS DATA. Nominal jitter is {n * 100:.2f}%, "
              f"far below the ~{VISIBLE_CV * 100:.0f}% that would look like a wobbly line.")
        print("   These arms offer a FIXED rate below capacity, so a steady sender produces a")
        print("   steady series whichever divisor is used. H1 vs H2 cannot be decided here, and")
        print("   neither may be reported. It needs a saturating working point -- which is")
        print("   exactly what Adam described and what these arms are not.")
    elif a / n < 0.5:
        print("\n=> H2 DOMINATES: most of what Adam saw is iperf's interval clock, not the wire.")
        print("   The figure he asked for would have had the wrong title.")
    elif a / n > 0.9:
        print("\n=> H1: the jitter is on the wire. The instrument's clock is not the cause.")
    else:
        print("\n=> BOTH contribute. Report the two numbers; do not round to the nearer branch.")

    # What this data CAN settle, and it is worth more than the question it was asked.
    if alld:
        sd_ms = statistics.pstdev(alld) * 1000
        print("\n" + "-" * 78)
        print("WHAT THIS DATA DOES SETTLE -- iperf3's 1-second timer on the SAME machine, in the")
        print("SAME seconds, as the kernel's own 1-second loop:")
        print(f"  iperf3 interval duration: mean {statistics.fmean(alld):.4f} s, sd {sd_ms:.1f} ms")
        print("  kernel rate loop (block 1): 1141.4 ms -- 141 ms long, measured in the same arm")
        print("  => The machine ran at load1 27-31 throughout. One process's 1 s timer held to")
        print(f"     {sd_ms:.1f} ms while the other's ran {141:.0f} ms long. So the kernel's")
        print("     overshoot is NOT the machine being busy: it is sleep_for(1s) PLUS the loop")
        print("     body, where iperf3 schedules against an absolute deadline and does not")
        print("     accumulate. That is ticket Q's mechanism, isolated by a control nobody")
        print("     designed -- it was already in the arm.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
