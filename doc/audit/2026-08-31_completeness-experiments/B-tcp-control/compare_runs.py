#!/usr/bin/env python3
"""Put run 1 (two witnesses live) beside run 2 (one witness) and say what moved.

The question this answers is NOT "which run is right". Both are real measurements of
the fabric under a stated background. It is: did the extra ~1,700 forks per ~8 s move
T(16)/T(1) enough to matter to a verdict whose threshold is 0.9?

Written before run 2's fabric cells were read, so the comparison it prints is not one
chosen after seeing which way the numbers went.

[Co-developed with claude code -- Adam]
"""
import os, sys

RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw")

def med(label):
    p = os.path.join(RAW, label, "cell.meta")
    try:
        for line in open(p):
            if line.startswith("aggregate_goodput_mbit_median="):
                return float(line.split("=", 1)[1])
    except OSError:
        return None
    return None

def ratios(suffix):
    out = {}
    for mode in ("loop", "fab"):
        cells = {(n, arm): med(f"tcp_{mode}_n{n}_{arm}{suffix}")
                 for n in (1, 16) for arm in ("a", "b")}
        if any(v is None or v < 0 for v in cells.values()):
            out[mode] = (None, None, None, cells)
            continue
        ra = cells[(16, "a")] / cells[(1, "a")]
        rb = cells[(16, "b")] / cells[(1, "b")]
        out[mode] = (ra, rb, (ra + rb) / 2, cells)
    return out

r1, r2 = ratios(""), ratios("_r2")

print("run 1 = two witnesses live across every cell (~3,400 forks / ~8 s)")
print("run 2 = exactly one witness            (~1,700 forks / ~8 s)")
for mode, name in (("loop", "loopback control"), ("fab", "fabric")):
    print(f"\n--- {name} ---")
    for tag, r in (("run 1", r1), ("run 2", r2)):
        ra, rb, rm, cells = r[mode]
        if rm is None:
            print(f"  {tag}: incomplete {cells}")
            continue
        print(f"  {tag}: n=1 {cells[(1,'a')]:9.1f} / {cells[(1,'b')]:9.1f}   "
              f"n=16 {cells[(16,'a')]:9.1f} / {cells[(16,'b')]:9.1f}   "
              f"T(16)/T(1) {ra:.3f} / {rb:.3f}  mean {rm:.3f}")
    m1, m2 = r1[mode][2], r2[mode][2]
    if m1 and m2:
        print(f"  mean moved {m1:.3f} -> {m2:.3f}  ({100*(m2-m1)/m1:+.1f}%)")
        # Restate the registered thresholds here, so the move is read against them rather
        # than against itself -- a 14% shift is small or fatal depending only on where the
        # threshold sits, and that is the number a reader will not have to hand.
        if mode == "fab":
            for tag, m in (("run 1", m1), ("run 2", m2)):
                v = ("SAME SHAPE (<=0.5)" if m <= 0.5 else
                     "UDP-SPECIFIC (>=0.9)" if m >= 0.9 else
                     "INDETERMINATE (0.5-0.9)")
                margin = m - 0.9
                print(f"    {tag}: {v}   margin above the 0.9 threshold: {margin:+.3f}")
            print("  🔑 If the two runs land on different sides of 0.9, the verdict was an")
            print("     artefact of the instrument's own load and must be reported as such.")
