#!/usr/bin/env python3
"""The paired A/B: two kernels one constant apart, at zero sampling and at 1/1024.

[Co-developed with claude code -- Adam]

Usage:  analyse_ab.py

WHY THIS IMPORTS THE 08-20 ANALYSER INSTEAD OF REIMPLEMENTING ITS LOADERS
The 6-second head trim, the .gz-aware reader, the completeness check and the per-group CPU
aggregation live in 2026-08-20_sampling-rate-and-cpu/analyse_matrix.py. Three rounds now read
their cells through that code. A second copy here would be a second place for it to drift, and
the one thing that must not differ between arms is how their numbers are computed -- otherwise
a difference in the loader shows up as a difference in the kernel.

WHAT IS DELIBERATELY NOT IMPORTED: total_sample_rate(). It recovers the sample quantum as
gcd(non-zero twin readings) and, when the readings are no longer quantised, silently returns the
raw sum -- 414,898,073 samples/s against a true ~35 on the 09-01 round. The guard here uses
iperf3's own packet count and aggregate tx from /proc/net/dev, neither of which needs a quantum.
"""
import importlib.util
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OLD = os.path.join(os.path.dirname(HERE), "2026-08-20_sampling-rate-and-cpu")

spec = importlib.util.spec_from_file_location("am", os.path.join(OLD, "analyse_matrix.py"))
am = importlib.util.module_from_spec(spec)
spec.loader.exec_module(am)
am.BASE = os.path.join(HERE, "raw")

CONDS = ["zero", "s1024"]
ARMS = ["1hz", "1khz"]
REPS = [1, 2, 3]
COND_NAME = {"zero": "zero sampling", "s1024": "1/1024"}
ARM_NAME = {"1hz": "1 Hz  (seconds(1))", "1khz": "1 kHz (microseconds(1000))"}

# PREREG.md §3. Frozen before any cell existed; printed here so a reader with only this output
# still sees what was predicted rather than what was found.
PREREG_NOISE = 0.7          # points, the 09-01 round's noise floor
PREREG_STEP = 46.0          # points, the 09-01 round's cross-round difference


def label(cond, arm, rep):
    return f"ab_{cond}_{arm}_r{rep}_nopoll"


def cells():
    """{(cond, arm, rep): {kernel, iperf, bmv2, proxy, pkts, tx}} for every complete cell."""
    out = {}
    for c in CONDS:
        for a in ARMS:
            for r in REPS:
                lab = label(c, a, r)
                if not am._exists(f"{am.BASE}/{lab}_cpu.jsonl"):
                    continue
                if not am.is_complete(lab):
                    print(f"  (skipping {lab}: incomplete)")
                    continue
                cell = am.cpu_cell(lab)
                if not cell:
                    continue
                pkts, tx = am.traffic_fingerprint(lab)
                out[(c, a, r)] = {
                    "kernel": cell[1].get("kernel", 0.0),
                    "iperf": cell[1].get("iperf", 0.0),
                    "bmv2": cell[1].get("bmv2", 0.0),
                    "proxy": cell[1].get("proxy", 0.0),
                    "machine": cell[0],
                    "pkts": pkts, "tx": tx,
                }
    return out


def main():
    d = cells()
    if not d:
        print("no complete cells yet")
        return 1

    print("=" * 94)
    print("WHAT THIS ROUND IS")
    print("=" * 94)
    print("  Two kernel binaries from the same tree, same commit, same compiler and flags,")
    print("  differing in one constant's value: kFlowPathRecomputeInterval, seconds(1) vs")
    print("  microseconds(1000). Built 2026-08-31 by the E round and never run until now.")
    print("  Arms are interleaved in time and the order is counterbalanced (PREREG.md 4).")
    print("  => a difference between the arms IS attributable to that constant.")
    print("  Build type is Debug (-O0), as in every prior round. Not release numbers.")
    print()

    # ---------------------------------------------------------------- guard
    # A pair is only a pair if both arms did the same work. Checked per (condition, replicate)
    # because that is the unit the difference is taken over -- a round-level average would let
    # one bad pair hide inside a good mean.
    print("=" * 94)
    print("GUARD -- did the two arms of each pair do the same work?")
    print("=" * 94)
    print("  iperf3's own packet count and aggregate tx from /proc/net/dev. Out of band => the")
    print("  pair is dropped, because its difference would be a traffic difference.")
    print()
    print(f"{'pair':>14} {'1hz packets':>13} {'1khz packets':>13} {'1hz Mbit/s':>12} "
          f"{'1khz Mbit/s':>12} {'ratio':>7}  verdict")
    good = set()
    for c in CONDS:
        for r in REPS:
            ka, kb = (c, "1hz", r), (c, "1khz", r)
            if ka not in d or kb not in d:
                continue
            ta, tb = d[ka]["tx"], d[kb]["tx"]
            ratio = tb / ta if ta else float("nan")
            ok = abs(ratio - 1.0) <= 0.05
            if ok:
                good.add((c, r))
            print(f"{c + ' r' + str(r):>14} {d[ka]['pkts'] or 0:>13,} {d[kb]['pkts'] or 0:>13,} "
                  f"{ta/1e6:>12.1f} {tb/1e6:>12.1f} {ratio:>7.3f}  "
                  f"{'ok' if ok else 'OUT OF BAND -- pair dropped'}")

    # ---------------------------------------------------------------- the 2x2
    print()
    print("=" * 94)
    print("KERNEL CPU, % of ONE core   (poll off: pure ingest, no instrument traffic)")
    print("=" * 94)
    cellmean = {}
    print(f"{'condition':>16} {'arm':>28} {'mean':>8} {'sd':>7} {'n':>3}   replicates")
    for c in CONDS:
        for a in ARMS:
            vals = [d[(c, a, r)]["kernel"] for r in REPS if (c, r) in good and (c, a, r) in d]
            if not vals:
                continue
            cellmean[(c, a)] = (st.mean(vals), st.pstdev(vals) if len(vals) > 1 else 0.0, len(vals))
            m, s, n = cellmean[(c, a)]
            print(f"{COND_NAME[c]:>16} {ARM_NAME[a]:>28} {m:>7.2f}% {s:>7.2f} {n:>3}   "
                  + ", ".join(f"{v:.2f}" for v in vals))

    # Paired differences, taken within a replicate. The pairing is the point: whatever the
    # machine was doing during replicate 2 was done to both arms of replicate 2.
    print()
    print("=" * 94)
    print("PAIRED DIFFERENCE, 1 kHz minus 1 Hz, taken within each replicate")
    print("=" * 94)
    diffs = {}
    for c in CONDS:
        ds = [d[(c, "1khz", r)]["kernel"] - d[(c, "1hz", r)]["kernel"]
              for r in REPS if (c, r) in good and (c, "1khz", r) in d and (c, "1hz", r) in d]
        if not ds:
            continue
        diffs[c] = ds
        print(f"  {COND_NAME[c]:>14}:  " + ", ".join(f"{v:+.2f}" for v in ds)
              + f"   =>  mean {st.mean(ds):+.2f}"
              + (f"  sd {st.pstdev(ds):.2f}" if len(ds) > 1 else ""))

    # The round's own noise floor, from the within-cell spread rather than from a prior round.
    sds = [s for (m, s, n) in cellmean.values() if n > 1]
    noise = max(sds) if sds else float("nan")
    print(f"\n  This round's own noise floor (largest within-cell sd): {noise:.2f} points")
    print(f"  Pre-registered noise floor (from 09-01):                {PREREG_NOISE:.2f} points")

    # ---------------------------------------------------------------- predictions
    print()
    print("=" * 94)
    print("THE FOUR PRE-REGISTERED PREDICTIONS  (PREREG.md 3, frozen before any cell existed)")
    print("=" * 94)
    bar = max(noise, PREREG_NOISE) if noise == noise else PREREG_NOISE

    if "zero" in diffs:
        m = st.mean(diffs["zero"])
        hit = abs(m) <= bar
        print(f"  P1  zero sampling: the two arms differ by <= the noise floor")
        print(f"      measured {m:+.2f}, bar {bar:.2f}  =>  {'HOLDS' if hit else 'DOES NOT HOLD'}")
        print("      HOLDS   => the step is triggered by whether samples exist; the interval")
        print("                 does not matter when the flow table is empty (PREREG 2).")
        print("      FAILS   => the mechanism is wrong: 1 kHz is expensive with nothing to walk.")

    if "s1024" in diffs:
        m = st.mean(diffs["s1024"])
        hit = m > bar
        print(f"\n  P2  1/1024: the 1 kHz arm is materially above the 1 Hz arm")
        print(f"      measured {m:+.2f}, bar {bar:.2f}  =>  {'HOLDS' if hit else 'DOES NOT HOLD'}")

        print(f"\n  P3  that difference is about {PREREG_STEP:.0f} points")
        print(f"      measured {m:+.2f} vs {PREREG_STEP:.0f}  =>  "
              f"{m / PREREG_STEP * 100:.0f}% of the 09-01 cross-round difference")
        if hit and abs(m - PREREG_STEP) <= max(5.0, 0.15 * PREREG_STEP):
            print("      => the 09-01 attribution HOLDS: that difference is this constant.")
        elif hit:
            print("      => PARTIAL. This constant accounts for part of the 09-01 difference;")
            print("         the rest came from the other twelve days. The 09-01 REPORT headline")
            print("         must be narrowed -- '46 points is the difference between two rounds'")
            print("         stays true, 'this step is this change' does not.")
        else:
            print("      => the 09-01 difference is NOT attributable to this constant at all.")
            print("         ticket M's 46.31% profiling claim needs re-examining too.")

    if "zero" in cellmean and ("zero", "1hz") in cellmean and ("s1024", "1hz") in cellmean:
        pass
    if ("zero", "1hz") in cellmean and ("s1024", "1hz") in cellmean:
        step_a = cellmean[("s1024", "1hz")][0] - cellmean[("zero", "1hz")][0]
        print(f"\n  P4  the 1 Hz arm has no step: zero -> 1/1024 costs only a few points")
        print(f"      measured {step_a:+.2f} points")
    if ("zero", "1khz") in cellmean and ("s1024", "1khz") in cellmean:
        step_b = cellmean[("s1024", "1khz")][0] - cellmean[("zero", "1khz")][0]
        print(f"      the 1 kHz arm's own step, for contrast: {step_b:+.2f} points")

    # ---------------------------------------------------------------- controls
    print()
    print("=" * 94)
    print("CONTROLS -- what must NOT move between the arms")
    print("=" * 94)
    print("  iperf3 does identical work in every cell and is the noise reference. bmv2 and the")
    print("  proxy are separate processes; the constant under test is inside the kernel only.")
    print("  If these move with the arm, something other than the kernel changed.")
    print()
    print(f"{'condition':>16} {'process':>10} {'1 Hz':>9} {'1 kHz':>9} {'delta':>9}")
    for c in CONDS:
        for proc in ("iperf", "bmv2", "proxy", "machine"):
            va = [d[(c, "1hz", r)][proc] for r in REPS if (c, r) in good and (c, "1hz", r) in d]
            vb = [d[(c, "1khz", r)][proc] for r in REPS if (c, r) in good and (c, "1khz", r) in d]
            if not va or not vb:
                continue
            print(f"{COND_NAME[c]:>16} {proc:>10} {st.mean(va):>8.1f}% {st.mean(vb):>8.1f}% "
                  f"{st.mean(vb) - st.mean(va):>+9.1f}")

    print()
    print("=" * 94)
    print("WHAT THIS IS STILL NOT")
    print("=" * 94)
    print("  The pair is at commit 4d831b58 (2026-08-31), NOT today's HEAD: it does not carry")
    print("  the 09-01 B-2(1) and E-2 fixes. Only the nopoll arm was run, so E-2's path is not")
    print("  exercised, but 'these numbers are today's HEAD' is not a claim this round makes.")
    print("  Absolute heights are not comparable to the 09-01 round -- that round measured a")
    print("  third binary. Only the within-round arm difference is attributable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
