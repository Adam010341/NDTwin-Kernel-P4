#!/usr/bin/env python3
"""Compare the loop period T between ticket 1's fabric generation and ticket P's.

WHY THIS EXISTS. I reported a "free reconciliation" to the auditor: the P generation's smoke arm
measured T = 1044 ms against ticket 1's quiet arm at 1043.9 ms, and I called the loop period
reproducible across fabric rebuilds. The auditor pushed back that 0.1 ms of agreement is finer
than ticket 1's own 3.4 ms rep spread, and asked two questions: how many flows, and how many reps.
This script answers them from the data instead of from recollection, and it turned out the
reconciliation fails -- not marginally, but in the opposite direction.

The smoke arm ran with T_REPS=1 and FLOW_S=30 (ticket 1's arms: T_REPS=3, FLOW_S=340). The P
round's own quiet arm, measured properly twenty minutes later in the same generation, disagrees
with ticket 1's quiet arm by an amount this script quantifies.

Reads period_*.json written by measure_loop_period.py. cluster_period_s is the period in seconds;
the tool's "predicted over-report" line is the same number re-expressed as T/1000ms, which is why
reading the ratio line and calling it the period was arithmetically right and evidentially wrong --
the ratio line survives `tail -8` and the gap count does not.

Usage: compare_T_across_generations.py
[Co-developed with claude code -- Adam]
"""
import json
import math
from pathlib import Path

RAW = Path(__file__).resolve().parent.parent / "2026-08-25_large-scale-concurrent" / "raw"

# (arm dir, generation, burners). Generation 1 = ticket 1's fabric, 2 = ticket P's rebuild.
ARMS = [
    ("L_Q",  1, 0), ("L_B7", 1, 7), ("L_B14", 1, 14), ("L_B28", 1, 28), ("L_Qp", 1, 0),
    ("P_Q",  2, 0), ("P_B14", 2, 14), ("P_B28", 2, 28), ("P_Qp", 2, 0),
]


def reps_ms(arm):
    """Every rep's period in ms, in file order. Missing arms return [] rather than 0 -- an arm
    that has not run yet must not serialise the same as an arm that measured nothing."""
    out = []
    for p in sorted((RAW / arm).glob("period_*.json")):
        d = json.loads(p.read_text())
        v = d.get("cluster_period_s")
        if v is not None:
            out.append((p.name, v * 1000.0, d.get("clusters"), d.get("polls")))
    return out


def mean_sd(xs):
    n = len(xs)
    if n == 0:
        return None, None
    m = sum(xs) / n
    if n < 2:
        return m, None                     # n=1 has no spread; None, never 0.0
    return m, math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1))


def main():
    stats = {}
    print(f"{'arm':7} {'gen':>3} {'burn':>4} {'n':>2} {'mean ms':>9} {'sd ms':>7}   reps")
    for arm, gen, burn in ARMS:
        rows = reps_ms(arm)
        if not rows:
            print(f"{arm:7} {gen:>3} {burn:>4} {'--':>2} {'not run':>9}")
            continue
        vals = [v for _, v, _, _ in rows]
        m, sd = mean_sd(vals)
        stats[arm] = (m, sd, len(vals))
        sd_s = f"{sd:7.1f}" if sd is not None else "    n/a"
        print(f"{arm:7} {gen:>3} {burn:>4} {len(vals):>2} {m:9.1f} {sd_s}   "
              + ", ".join(f"{v:.1f}" for v in vals))
        for name, v, cl, po in rows:
            print(f"{'':7} {'':>3} {'':>4}    {name}: {v:.1f} ms from {cl} clusters, {po} polls")

    print("\n--- cross-generation pairs (same burner count) ---")
    for a, b in (("L_Q", "P_Q"), ("L_B14", "P_B14"), ("L_B28", "P_B28"), ("L_Qp", "P_Qp")):
        if a not in stats or b not in stats:
            print(f"{a} vs {b}: incomplete, no comparison")
            continue
        (ma, sa, na), (mb, sb, nb) = stats[a], stats[b]
        d = ma - mb
        se = math.sqrt((sa or 0) ** 2 / na + (sb or 0) ** 2 / nb) if sa and sb else None
        if se:
            print(f"{a} {ma:.1f} vs {b} {mb:.1f}  ->  delta {d:+.1f} ms, "
                  f"SE {se:.1f}, delta/SE = {abs(d)/se:.1f}")
        else:
            print(f"{a} {ma:.1f} vs {b} {mb:.1f}  ->  delta {d:+.1f} ms (no SE, n=1 somewhere)")


if __name__ == "__main__":
    main()
