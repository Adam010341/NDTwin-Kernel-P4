#!/usr/bin/env python3
"""An independent second instrument for the per-rung CPU and S of the fifth campaign.

[Co-developed with claude code -- Adam]

Does NOT import analyse.py. Different arithmetic on purpose:
  * CPU over a span = (last reading - first reading) per pid inside the span, summed per class
    (analyse.py accumulates row-to-row increments; the two agree when no pid is reused);
  * the fit is statistics.linear_regression (analyse.py writes its own least squares);
  * spans are rebuilt from rungs.tsv here, by rep label (numeric = climb, c<N> = confirmation).
For each 1024 B measurement arm and each rung it prints kernel and bmv2 % of one core under
three windows -- UNION (the pre-fix span), CLIMB, CLIMB+CONF (pooled over the two spans) --
and S over the climb and over the union. Then it rebuilds, per reading, the per-group medians,
Delta-kernel, the kernel fit (F, m, share) and the bmv2 coop/none ratios, and compares them
with the summary.json files given on the command line (base for UNION, fix for the other two).

Usage: crosscheck_independent.py <run dir> <base summary.json> <fix summary.json>
"""
import json
import os
import statistics
import sys

RUN, BASE, FIX = sys.argv[1:4]


def read_tsv(path):
    with open(path) as fh:
        lines = [line.rstrip("\n") for line in fh if line.strip()]
    header = lines[0].split("\t")
    return [dict(zip(header, line.split("\t"))) for line in lines[1:]]


def meta(path):
    out = {}
    for line in open(path):
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip()
    return out


def cpu_rows(path):
    header, rows = None, []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        doc = json.loads(line)
        if header is None:
            header = doc
        elif "machine" in doc:
            rows.append(doc)
    return header, rows


def span_cpu(rows, clk, t0, t1):
    """{class: jiffies, '_s': seconds} over [t0, t1] by first/last per pid."""
    inside = [r for r in rows if t0 <= r["t"] <= t1]
    first, last = inside[0], inside[-1]
    out = {"_s": last["t"] - first["t"]}
    for key, value in last["proc"].items():
        if key not in first["proc"]:
            continue                                   # none appear mid-rung for these classes
        cls = "bmv2" if key.startswith("bmv2") else key.split(":")[0]
        out[cls] = out.get(cls, 0) + value - first["proc"][key]
    return out


def pct(parts, cls, clk):
    seconds = sum(p["_s"] for p in parts)
    return 100.0 * sum(p.get(cls, 0) for p in parts) / clk / seconds


def addressed(path):
    doc = json.load(open(path))
    health = doc.get("telemetry_health")
    return (health or {}).get("addressed_total", doc.get("addressed_total"))


arms = []
for gen in sorted(os.listdir(RUN)):
    gdir = os.path.join(RUN, gen)
    if not gen.startswith("G") or not os.path.isdir(gdir):
        continue
    for name in sorted(os.listdir(gdir)):
        adir = os.path.join(gdir, name)
        if not os.path.exists(os.path.join(adir, "arm.meta")):
            continue
        m = meta(os.path.join(adir, "arm.meta"))
        if m.get("frame_bytes") != "1024" or m.get("invalid", "no") != "no":
            continue
        header, rows = cpu_rows(os.path.join(adir, "cpu.jsonl"))
        clk = header["clk_tck"]
        climb, conf, union = {}, {}, {}
        for r in read_tsv(os.path.join(adir, "rungs.tsv")):
            k, t0, t1 = float(r["kpps"]), float(r["t_start"]), float(r["t_end"])
            target = conf if r["rep"].startswith("c") else climb
            lo, hi = target.get(k, (t0, t1))
            target[k] = (min(lo, t0), max(hi, t1))
            lo, hi = union.get(k, (t0, t1))
            union[k] = (min(lo, t0), max(hi, t1))
        per = {}
        for k in sorted(climb):
            pc = span_cpu(rows, clk, *climb[k])
            pu = span_cpu(rows, clk, *union[k])
            parts = [pc] + ([span_cpu(rows, clk, *conf[k])] if k in conf else [])
            d = addressed(os.path.join(adir, "sflow_rung%d_after.json" % k)) - \
                addressed(os.path.join(adir, "sflow_rung%d_before.json" % k))
            per[k] = {
                "UNION": {c: pct([pu], c, clk) for c in ("kernel", "bmv2")},
                "CLIMB": {c: pct([pc], c, clk) for c in ("kernel", "bmv2")},
                "CLIMB+CONF": {c: pct(parts, c, clk) for c in ("kernel", "bmv2")},
                "S_climb": d / (climb[k][1] - climb[k][0]),
                "S_union": d / (union[k][1] - union[k][0]),
                "climb_s": climb[k][1] - climb[k][0], "union_s": union[k][1] - union[k][0],
                "conf": k in conf,
            }
        arms.append({"arm": name, "group": m["group"], "per": per})

print("=== per arm, the rungs whose window differs between readings (kernel / bmv2 % of one core)")
for arm in arms:
    for k, v in sorted(arm["per"].items()):
        if abs(v["union_s"] - v["climb_s"]) < 1e-9 and not v["conf"]:
            continue
        print("  %-22s %5g kpps  union %6.1fs kern %6.3f bmv2 %7.2f | climb %5.1fs kern %6.3f bmv2 "
              "%7.2f | climb+conf kern %6.3f bmv2 %7.2f | S climb %7.1f union %7.1f"
              % (arm["arm"], k, v["union_s"], v["UNION"]["kernel"], v["UNION"]["bmv2"], v["climb_s"],
                 v["CLIMB"]["kernel"], v["CLIMB"]["bmv2"], v["CLIMB+CONF"]["kernel"],
                 v["CLIMB+CONF"]["bmv2"], v["S_climb"], v["S_union"]))

base = json.load(open(BASE))
fix = json.load(open(FIX))
worst = 0.0
for reading, s_key, summary_block in (
        ("UNION", "S_union", base),
        ("CLIMB", "S_climb", fix["cpu_window"]["readings"]["climb"]),
        ("CLIMB+CONF", "S_climb", fix["cpu_window"]["readings"]["climb+confirmation"])):
    print("\n=== reading %s" % reading)
    groups = {}
    for arm in arms:
        for k, v in arm["per"].items():
            g = groups.setdefault(arm["group"], {}).setdefault(k, {"kernel": [], "bmv2": [], "S": []})
            g["kernel"].append(v[reading]["kernel"])
            g["bmv2"].append(v[reading]["bmv2"])
            g["S"].append(v[s_key])
    med = {g: {k: {q: statistics.median(vals) for q, vals in d.items()} for k, d in ks.items()}
           for g, ks in groups.items()}
    common = sorted(set(med["none"]) & set(med["cooperative"]) & set(med["link"]))
    for label, key in (("kernel", "cpu_kernel"), ("bmv2", "cpu_bmv2")):
        theirs = summary_block[key]["per_group"]
        for g in ("none", "cooperative", "link"):
            for k in common:
                mine, other = med[g][k][label], theirs[g][str(k)]["cpu"] if str(k) in theirs[g] \
                    else theirs[g][k]["cpu"]
                worst = max(worst, abs(mine - other))
    for g in ("cooperative", "link"):
        xs = [med[g][k]["S"] for k in common]
        ys = [med[g][k]["kernel"] - med["none"][k]["kernel"] for k in common]
        slope, intercept = statistics.linear_regression(xs, ys)
        share = intercept / (intercept + slope * max(xs))
        fit = summary_block["cpu_kernel"]["fits"][g]["fit"]
        print("  %-12s F=%.4f m=%.2f us/sample share=%.4f   | summary: F=%.4f m=%.2f  |dF|=%.1e |dm|=%.1e"
              % (g, intercept, slope * 1e4, share, fit["fixed_percent"],
                 fit["marginal_us_per_sample"], abs(intercept - fit["fixed_percent"]),
                 abs(slope * 1e4 - fit["marginal_us_per_sample"])))
        print("  %-12s S by rung: %s" % (g, " ".join("%g:%.1f" % (k, med[g][k]["S"]) for k in common)))
        print("  %-12s dkernel:   %s" % (g, " ".join("%g:%.3f" % (k, med[g][k]["kernel"] - med["none"][k]["kernel"])
                                                     for k in common)))
    print("  bmv2 coop/none: %s" % " ".join("%g:%.3f" % (k, med["cooperative"][k]["bmv2"] / med["none"][k]["bmv2"])
                                          for k in common))
print("\nlargest |independent - summary.json| over every per-group kernel/bmv2 cell of the three "
      "readings: %.2e (%% of one core)" % worst)
