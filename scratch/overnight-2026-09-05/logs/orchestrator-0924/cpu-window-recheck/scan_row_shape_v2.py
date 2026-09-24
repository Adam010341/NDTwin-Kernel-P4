#!/usr/bin/env python3
"""Scan every rungs.tsv of every campaign: confirmation rows, and what the union window swallows.

(v2, round 2: also prints per-campaign totals, which round 1 counted by eye from the listing.)

[Co-developed with claude code -- Adam]

Read-only over the raw. For each arm it prints the rep labels seen, which kpps carry confirmation
rows (rep label c<N>), and -- for each kpps -- whether the (min t_start, max t_end) span that
analyse.py's rung_windows() builds contains any rep of ANOTHER kpps (and which kpps those are).
It also says whether the arm is a 1024 B measurement arm (the only ones cpu_comparison reads).
"""
import os
import sys

RAW = sys.argv[1]


def read_tsv(path):
    with open(path) as fh:
        lines = [line.rstrip("\n") for line in fh if line.strip()]
    header = lines[0].split("\t")
    return [dict(zip(header, line.split("\t"))) for line in lines[1:]]


def meta(path):
    out = {}
    with open(path) as fh:
        for line in fh:
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    return out


total_arms = total_affected = total_affected_1024 = 0
per_campaign = {}
labels_seen = set()
for campaign in sorted(os.listdir(RAW)):
    base = os.path.join(RAW, campaign)
    if not os.path.isdir(base):
        continue
    print("=== %s" % campaign)
    for root, dirs, files in os.walk(base):
        dirs.sort()
        if "rungs.tsv" not in files:
            continue
        rows = read_tsv(os.path.join(root, "rungs.tsv"))
        m = meta(os.path.join(root, "arm.meta")) if "arm.meta" in files else {}
        control = "controls" in os.path.relpath(root, base).split(os.sep)
        frame = m.get("frame_bytes")
        total_arms += 1
        reps = sorted({r["rep"] for r in rows})
        labels_seen.update(reps)
        conf = sorted({float(r["kpps"]) for r in rows if r["rep"].startswith("c")})
        spans = {}
        for r in rows:
            k = float(r["kpps"])
            t0, t1 = float(r["t_start"]), float(r["t_end"])
            lo, hi = spans.get(k, (t0, t1))
            spans[k] = (min(lo, t0), max(hi, t1))
        swallowed = {}
        for k, (lo, hi) in spans.items():
            others = sorted({float(r["kpps"]) for r in rows
                             if float(r["kpps"]) != k and float(r["t_start"]) >= lo
                             and float(r["t_end"]) <= hi})
            if others:
                swallowed[k] = (others, hi - lo)
        tag = "CONTROL" if control else ("1024B-MEASUREMENT" if frame == "1024" else "%sB" % frame)
        affected = bool(swallowed)
        total_affected += affected
        total_affected_1024 += affected and frame == "1024" and not control
        pc = per_campaign.setdefault(campaign, [0, 0, 0, 0, 0])
        pc[0] += 1; pc[1] += (not control); pc[2] += bool(conf) and not control
        pc[3] += affected and not control; pc[4] += affected and frame == "1024" and not control
        print("  %-40s %-18s clean=%-5s reps=%s confirmation_kpps=%s"
              % (os.path.relpath(root, base), tag, m.get("highest_clean_kpps"), ",".join(reps),
                 ",".join("%g" % k for k in conf) or "-"))
        for k, (others, width) in sorted(swallowed.items()):
            print("      union window of %g kpps is %.1f s and contains the reps of %s kpps"
                  % (k, width, ",".join("%g" % o for o in others)))
print("\nper campaign: arms (incl. controls) / ladder measurement arms / of them with c-rows / of them whose union window swallows another rung / of those, 1024 B")
for c, v in sorted(per_campaign.items()):
    print("  %-26s %s" % (c, " / ".join(str(x) for x in v)))
print("\nrep labels seen anywhere: %s" % ",".join(sorted(labels_seen)))
print("arms: %d   arms whose union window swallows another rung: %d   of them 1024 B measurement "
      "arms: %d" % (total_arms, total_affected, total_affected_1024))
