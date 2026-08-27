#!/usr/bin/env python3
"""Does the flow table contain the flows the churn generator actually ran?

Ticket M metric 6-2 is "of the flows the API lists, what fraction have a path". The auditor's
hypothesis is that the denominator excludes the very flows the metric exists to catch: a flow has
to survive long enough to enter the flow table, and that admission may already take longer than a
path pass -- so anything short is missing from the denominator rather than counted as pathless.

That predicts exactly the pattern measured: 1-4 s churn pinned at 1.000, while 5-10 s churn is
the ONE case that produced 0.944. If the mechanism were "short flows lose their path", the
shorter arm would be the one that dropped. It was not.

This compares, second by second:
  expected_alive(t)  from the churn schedule -- deterministic, known before the run
  api_flows(t)       what the API actually listed

Schedule times are relative to churn t0; sampler times are absolute unix. Both are converted to
seconds-since-t0 before anything is compared, because the two clocks are the whole question.

Usage: check_denominator.py <churn_dir> <path_fill.jsonl>
[Co-developed with claude code -- Adam]
"""
import json
import sys
from pathlib import Path


def main():
    cdir, pf = Path(sys.argv[1]), Path(sys.argv[2])
    meta = dict(l.strip().split("=", 1) for l in open(cdir / "churn.meta") if "=" in l)
    t0 = int(meta["t0"])
    sched = json.loads((cdir / "churn_schedule.json").read_text())["flows"]

    # Only flows that actually moved bytes belong in "expected". A flow whose client failed is
    # not one the twin should have seen, and counting it would manufacture the very shortfall
    # this script is testing for.
    ran = set()
    for f in cdir.glob("f_*.json"):
        try:
            d = json.loads(f.read_text())
        except Exception:
            continue
        if "error" not in d and d.get("end", {}).get("sum_sent", {}).get("bytes", 0) > 0:
            parts = f.stem.split("_")          # f_<at>_<pair>
            ran.add((int(parts[1]), int(parts[2])))

    rows = [json.loads(l) for l in open(pf)]
    print(f"schedule: {len(sched)} flows, {len(ran)} of them transferred bytes")
    print(f"{'t':>4}{'expected_alive':>16}{'api_flows':>11}{'with_path':>11}{'ratio':>8}")

    worst = None
    for r in rows:
        t = r["t"] - t0
        if t < 0 or t > int(meta["t_end"]) - t0:
            continue
        exp = sum(1 for f in sched
                  if (f["at"], f["pair"]) in ran and f["at"] <= t < f["at"] + f["dur"])
        n, w = r.get("n_flows", 0), r.get("n_with_path", 0)
        ratio = r.get("ratio")
        print(f"{t:>4.0f}{exp:>16}{n:>11}{w:>11}"
              + (f"{ratio:>8.3f}" if ratio is not None else f"{'NO-DATA':>8}"))
        if exp > 0:
            frac = n / exp
            worst = frac if worst is None else min(worst, frac)

    print()
    if worst is None:
        print("no second had an expected-alive flow -- nothing to compare")
        return
    print(f"lowest api_flows / expected_alive over the run: {worst:.2f}")
    print("  ~1.0  => the table holds what ran; the auditor's selection hypothesis fails")
    print("  <<1.0 => the flows 6-2 exists to catch are missing from its DENOMINATOR, and the")
    print("           metric is structurally blind to the cost ticket M is supposed to measure")


if __name__ == "__main__":
    main()
