#!/usr/bin/env python3
"""
Turns cpu_probe.py output into per-process CPU percentages.

[Co-developed with claude code -- Adam]

Usage:  python3 tools/test_workflow/cpu_report.py <cpu.jsonl> [--threads]

Reports two different things that are easy to conflate:

  * "% of one core" -- 100 means one core fully saturated. This is the number to compare
    against a single-threaded bottleneck, and bmv2's forwarding loop is one.
  * "% of machine" -- 100 means every core saturated. This is what tells you whether the box
    was the limit.

Both come from the same jiffies; reporting only the first makes a 12-core machine look
overloaded, and reporting only the second hides a saturated single thread inside a mostly idle
box. bmv2's ceiling is a single-thread ceiling, so the first is usually the interesting one --
which is exactly the distinction the throughput page needs and does not currently make.

Deltas are taken between the first and last sample that contain a given pid, not across the
whole file, because processes come and go: iperf3 flows start mid-run, and a bmv2 restarted by
a power-cycle test gets a new pid. Attributing a short-lived process's jiffies across the full
window would understate it in proportion to how briefly it lived.
"""
import json
import sys
from collections import defaultdict


def main():
    path = sys.argv[1]
    want_threads = "--threads" in sys.argv

    rows = []
    header = None
    dropped = 0
    for line in open(path):
        d = json.loads(line)
        if "clk_tck" in d:
            header = d
        elif "error" in d:
            dropped += 1
        else:
            rows.append(d)

    if header is None or len(rows) < 2:
        sys.exit(f"{path}: need a header and at least 2 samples")

    clk = header["clk_tck"]
    nproc = header["nproc"]
    span = rows[-1]["t"] - rows[0]["t"]

    print(f"{len(rows)} samples over {span:.1f}s  ({nproc} cores, {clk} Hz)"
          + (f"  [{dropped} dropped]" if dropped else ""))

    mb = rows[-1]["machine"]["busy"] - rows[0]["machine"]["busy"]
    mt = rows[-1]["machine"]["total"] - rows[0]["machine"]["total"]
    print(f"whole machine: {100.0 * mb / mt:.1f}% busy across all {nproc} cores\n")

    for section, key in (("PROCESS", "proc"),) + ((("THREAD", "thread"),) if want_threads else ()):
        # first/last per key, so a process that appears late is measured over its own lifetime
        first, last, ft, lt = {}, {}, {}, {}
        for r in rows:
            for k, v in r.get(key, {}).items():
                if k not in first:
                    first[k], ft[k] = v, r["t"]
                last[k], lt[k] = v, r["t"]

        agg = defaultdict(lambda: [0.0, 0.0])   # label -> [core%, seconds observed]
        detail = []
        for k in first:
            dt = lt[k] - ft[k]
            if dt <= 0:
                continue
            core_pct = 100.0 * (last[k] - first[k]) / clk / dt
            detail.append((core_pct, k, dt))
            agg[k.split(":")[0].rsplit("-", 1)[0]][0] += core_pct
            agg[k.split(":")[0].rsplit("-", 1)[0]][1] = max(
                agg[k.split(":")[0].rsplit("-", 1)[0]][1], dt)

        print(f"=== {section}: by group ===")
        print(f"{'group':>12} {'% of one core':>14} {'% of machine':>14}")
        for label, (pct, _) in sorted(agg.items(), key=lambda x: -x[1][0]):
            print(f"{label:>12} {pct:>13.1f}% {pct / nproc:>13.1f}%")

        print(f"\n=== {section}: individual (>0.5% of a core) ===")
        print(f"{'name':>28} {'% of one core':>14} {'observed s':>11}")
        for pct, k, dt in sorted(detail, reverse=True):
            if pct < 0.5:
                continue
            print(f"{k:>28} {pct:>13.1f}% {dt:>10.1f}")
        print()


if __name__ == "__main__":
    main()
