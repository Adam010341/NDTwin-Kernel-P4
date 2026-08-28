#!/usr/bin/env python3
"""Measure the rate loop's real period, without rebuilding anything.

THE CLAIM UNDER TEST. FlowLinkUsageCollector accumulates frameLength x samplingRate and, once per
loop iteration, hands the accumulator x 8 straight through as link_bandwidth_usage_bps -- nothing
on that path divides by elapsed time (:1447, :1885-1888, TopologyAndFlowMonitor.cpp:1090-1096).
The loop is `sleep_for(1s)` at the TOP of the body (:1725-1727), so its real period is one second
plus however long the body takes. If that is right, every reported rate is over-stated by exactly
(real period / 1 s).

🔴 DO NOT COMPARE ACROSS ROUNDS. This docstring used to say the 1.227x and 1.193x measured on
2026-08-25 should turn up here as a period of 1.19-1.23 s, and the tool used to print a verdict
against exactly that. REPORT.md section 0 retracted that comparison.

It then said the quiet period was 1043.9 ms "in one fabric generation and 1001.7 ms in the next --
42 ms apart", and concluded the period is a property of a GENERATION and a load. That is also
retracted (60dcca6 retracted it in the printed footer and missed this docstring; 2026-08-28 found
it still here). It compared ONE arm of generation 1 against ONE arm of generation 2, so the
generation was aliased onto the arm. With the arm as the unit of replication:

    gen 1 quiet arms   1043.9, 1016.7   mean 1030.3   the two are 27.2 ms apart
    gen 2 quiet arms   1001.7, 1043.3   mean 1022.5   the two are 41.6 ms apart
    delta 7.8 ms, between-arm SE 24.9, delta/SE = 0.31  -- no generation effect established

The surviving fact is smaller and more useful: **two quiet arms of the SAME generation differ by
27-42 ms**, measured twice. Load has not been shown to exceed that either -- 16 flows, 64 flows
and 16+B14 all sat inside one between-arm spread. So the period is a property of the ARM, and an
arm is what you have to replicate. Compare arms measured in the same window; do not carry a
period across a rebuild; and do not read agreement finer than ~40 ms as precision.

HOW. The loop writes usage for every edge once per iteration, so a loaded edge's value CHANGES on
a step function whose width is the period. Poll faster than the loop and time the steps. No
instrumentation, no rebuild, and it reads the shipped binary rather than a rebuilt one.

WHY THIS IS NOT CIRCULAR. The period is measured from wall-clock timestamps of value transitions.
Any ratio it gets compared against comes from byte totals against veth counters. Neither derives
from the other; if the mechanism is wrong they will simply disagree.

FALSIFIES THE CLAIM: a measured period of ~1.00 s IN THE SAME ARM as the ratio it is being asked
to explain. That would mean the loop keeps 1 Hz there and the over-report comes from elsewhere.

WHAT THIS TOOL DOES NOT DO. It does not decide anything. It prints the period it measured and the
over-report a 1000 ms denominator would produce at that period, and stops. Deciding whether the
denominator explains a given round's bias needs the ratio from the same window, which lives in the
round's own analysis -- not in here.

Usage: measure_loop_period.py <out.json> <seconds>
[Co-developed with claude code -- Adam]
"""
import json
import statistics
import subprocess
import sys
import time

API = "http://127.0.0.1:8000/ndt/get_graph_data"     # 127.0.0.1, never localhost: 131 s of reasons


def poll():
    r = subprocess.run(["curl", "-sS", "--max-time", "3", API], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout:
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None


def main():
    out_path, dur = sys.argv[1], float(sys.argv[2])
    series = {}          # edge key -> [(ts, bps), ...] transitions only
    last = {}
    n = miss = 0
    t_end = time.time() + dur
    while time.time() < t_end:
        t = time.time()
        g = poll()
        if g is None:
            miss += 1
            continue
        n += 1
        for e in g["edges"]:
            # dst_interface is part of the key. Every host carries src_dpid 0, so without it all
            # 32 host edges hanging off one switch collapse into a single series and overwrite each
            # other -- the first run recorded 4098 "transitions" on one key in 343 polls, which is
            # 32 edges' writes stacked, not a period. Same defect analyze.py had and I fixed there.
            k = f"{e['src_dpid']}:{e['src_interface']}->{e['dst_dpid']}:{e['dst_interface']}"
            v = e.get("link_bandwidth_usage_bps") or 0
            if k not in last:
                last[k] = v
                continue
            if v != last[k]:
                series.setdefault(k, []).append((t, v))
                last[k] = v
        time.sleep(0.02)

    # THE ESTIMATOR, third rewrite. Per-edge gaps have an unavoidable bias: an edge only changes
    # when it got samples, so some iterations are skipped, and any per-edge statistic is either
    # inflated (median, which averages in the skipped multiples) or deflated (a low percentile,
    # which picks the short tail of the single-period cluster). The first gave 1.539, the second
    # 1.135, and the second is a LOWER BOUND -- which is exactly the size of the "residual" I was
    # about to go hunting for.
    #
    # The fix is to stop looking at edges one at a time. The loop writes EVERY edge each pass, so
    # across all edges together nearly every iteration produces at least one transition. Cluster
    # the transition timestamps from all edges: each cluster is one iteration of the loop, and the
    # spacing between cluster centres is the period, with no skipping to correct for.
    all_ts = sorted(t for pts in series.values() for t, _ in pts)
    clusters = []
    for t in all_ts:
        if clusters and t - clusters[-1][-1] < 0.35:      # same pass: writes land back to back
            clusters[-1].append(t)
        else:
            clusters.append([t])
    centres = [sum(c) / len(c) for c in clusters if len(c) >= 2]
    cluster_gaps = sorted(centres[i + 1] - centres[i] for i in range(len(centres) - 1))
    cluster_gaps = [g for g in cluster_gaps if g < 2.5]    # a gap that big is a missed cluster
    cluster_period = statistics.mean(cluster_gaps) if len(cluster_gaps) >= 10 else None

    # Kept for comparison, so the report can show the two estimators disagreeing in exactly the
    # direction predicted: switch-to-switch edges only, tenth percentile of their gaps, which is
    # a LOWER bound on the period because a skipped iteration can only lengthen a gap.
    core = {k: v for k, v in series.items()
            if not k.startswith("0:") and ":0" not in k.split("->")[1]}
    ranked = sorted(core.items(), key=lambda kv: -len(kv[1]))
    busiest = dict(ranked[:12])
    per_edge = {}
    for k, pts in busiest.items():
        gaps = sorted(pts[i + 1][0] - pts[i][0] for i in range(len(pts) - 1))
        gaps = [g for g in gaps if g > 0.25]     # two writes inside one pass are not a period
        if len(gaps) >= 8:
            per_edge[k] = gaps[max(0, int(len(gaps) * 0.10))]

    res = {"cluster_period_s": cluster_period, "clusters": len(centres),
           "cluster_gap_median": statistics.median(cluster_gaps) if cluster_gaps else None,
           "polls": n, "failed_polls": miss, "poll_hz": n / dur if dur else 0,
           "edges_that_moved": len(series), "edges_usable": len(per_edge),
           "per_edge_median_gap": per_edge}
    res["transitions_per_edge"] = {k: len(v) for k, v in
                                   sorted(series.items(), key=lambda kv: -len(kv[1]))[:12]}
    if per_edge:
        med = sorted(per_edge.values())
        res["period_median_s"] = statistics.median(med)
        res["period_min_s"], res["period_max_s"] = med[0], med[-1]
    json.dump(res, open(out_path, "w"), indent=1)

    print(f"polls: {n} at {res['poll_hz']:.1f} Hz ({miss} failed)")
    print(f"edges that changed: {len(series)}, usable for timing: {len(per_edge)}")
    if not per_edge:
        print("🔴 INCONCLUSIVE: no edge changed often enough to time a period. Either there is no "
              "traffic, or the poll rate is below the loop rate. Not evidence of anything.")
        return 2
    if cluster_period:
        print(f"\n🔑 loop period from CLUSTERED transitions (all edges): "
              f"mean {cluster_period:.3f} s over {len(cluster_gaps)} gaps, "
              f"median {res['cluster_gap_median']:.3f}")
    print(f"\nper-edge p10 estimator (lower bound, for comparison): median {res['period_median_s']:.3f} s "
          f"(range {res['period_min_s']:.3f}-{res['period_max_s']:.3f} over {len(per_edge)} edges)")
    p = cluster_period or res["period_median_s"]
    # This tool used to end by comparing p against the 1.227x/1.193x measured on 2026-08-25 and
    # printing a verdict -- "the loop DOES hold ~1 Hz, the hard-coded denominator is not the
    # cause", in red, in a full sentence. Three things were wrong with that and only one of them
    # was that the comparison had since been retracted in REPORT.md section 0:
    #
    #   * the number it compared against came from a different fabric generation, which is exactly
    #     the comparison that was retracted;
    #   * a verdict belongs to whoever is reading the round, not to the instrument, and this one
    #     went on to be written into four arms' drive logs where a later reader would meet it with
    #     none of that context and every reason to read it as a finding;
    #   * p is not one number. Across ticket P's own arms it ran 1.001 to 1.090 with load, so a
    #     threshold on a single reading was answering a question the data cannot answer alone.
    #
    # It now reports what it measured and stops. Interpretation is the round's job.
    print(f"\nperiod: {p:.4f} s over {len(cluster_gaps) if cluster_period else len(per_edge)} "
          f"{'gaps' if cluster_period else 'edges'}"
          f"  =>  a 1000 ms hard-coded denominator would over-report by {(p - 1.0) * 100:+.1f}%")
    print("(one reading from one arm. On 2026-08-27 two quiet arms of the SAME generation came "
          "out 42 ms apart, so a single arm carries roughly that much regardless of its rep "
          "spread -- compare arms, and do not read agreement finer than ~40 ms as precision.)")
    print("⚠️  untested at long periods: a slower loop spreads one iteration's writes over more "
          "wall-clock, so a cluster can split and this estimate reads LOW. Cross-checked against "
          "the in-loop instrument only at ~1042 ms (1043.9 vs 1041.2). Above that, unvalidated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
