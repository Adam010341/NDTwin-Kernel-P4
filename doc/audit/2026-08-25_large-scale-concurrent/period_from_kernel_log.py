#!/usr/bin/env python3
"""Recover the INSTANTANEOUS loop period from the instrumented kernel's cumulative summaries.

The instrumented build (section 1-nonies) logs "rate loop period over N iterations: mean X ms"
every 30 iterations, and that mean is CUMULATIVE -- it covers every iteration since the loop
started, not the last 30. Reading it as the current period understates a period that is rising,
which is exactly the shape here: the 64-flow round's printed mean climbs 1067.9 -> 1108.3 while
the actual per-window period is well above both. This project has already published one number
that came from averaging a cumulative counter, and it looked entirely reasonable.

Between two consecutive lines the windowed period is (N2*mean2 - N1*mean1) / (N2 - N1).

Usage: period_from_kernel_log.py <kernel.log> [...]
[Co-developed with claude code -- Adam]
"""
import re
import statistics
import sys

LINE = re.compile(r"rate loop period over (\d+) iterations: mean ([\d.]+) ms, "
                  r"min ([\d.]+), max ([\d.]+) \(flows=(\d+), counters=(\d+)\)")


def windows(path):
    pts = []
    for line in open(path, errors="replace"):
        m = LINE.search(line)
        if m:
            n, mean, _mn, _mx, flows, counters = m.groups()
            pts.append((int(n), float(mean), int(flows), int(counters)))
    out = []
    for (n1, m1, _f1, _c1), (n2, m2, f2, c2) in zip(pts, pts[1:]):
        if n2 <= n1:
            continue
        out.append({"iters": n2 - n1, "period_ms": (n2 * m2 - n1 * m1) / (n2 - n1),
                    "cumulative_mean": m2, "flows": f2, "counters": c2})
    return pts, out


def main():
    for path in sys.argv[1:]:
        pts, ws = windows(path)
        print(f"\n=== {path} ===")
        if not ws:
            # No lines is not "period zero": say so rather than print an empty table.
            print("  NO INSTRUMENTED PERIOD LINES -- this build did not carry the instrument")
            continue
        print(f"  {len(pts)} summaries -> {len(ws)} windows")
        print(f"  {'iters':>6}{'window ms':>11}{'cumulative':>12}{'flows':>7}{'counters':>9}")
        for w in ws:
            print(f"  {w['iters']:>6}{w['period_ms']:>11.1f}{w['cumulative_mean']:>12.1f}"
                  f"{w['flows']:>7}{w['counters']:>9}")
        # Group by flow count rather than picking one "steady state". The kernel is not restarted
        # between rounds, so p4_T64/kernel.log carries the whole T16 phase before its own -- and
        # taking the mode picked flows=16 out of the 64-flow log, silently answering about the
        # wrong round. Bucketed to the nearest 8 because iperf clients finish at slightly
        # different times, so a nominal 64 shows up as 60-64.
        buckets = {}
        for w in ws:
            if w["flows"] == 0:
                continue
            buckets.setdefault(8 * round(w["flows"] / 8), []).append(w["period_ms"])
        if not buckets:
            print("  no window had flows -- nothing to summarise")
            continue
        for nominal, vals in sorted(buckets.items()):
            sd = f"{statistics.stdev(vals):.1f}" if len(vals) > 1 else "n/a"
            print(f"  ~{nominal:>3} flows (n={len(vals):>2}): mean {statistics.mean(vals):7.1f} ms,"
                  f" SD {sd:>5}, range {min(vals):.1f}-{max(vals):.1f}")
        print(f"  🔴 last CUMULATIVE mean printed by the kernel: {ws[-1]['cumulative_mean']:.1f} ms"
              f" -- that line is not the current period")


if __name__ == "__main__":
    main()
