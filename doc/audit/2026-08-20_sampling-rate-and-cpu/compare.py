"""Side-by-side of the three sampling-rate conditions. [Co-developed with claude code -- Adam]"""
import json, math, statistics as st, sys
from functools import reduce
from collections import defaultdict

BASE = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu/raw"

def twin_stats(label):
    rows = [json.loads(l) for l in open(f"{BASE}/{label}_twin.jsonl") if '"error"' not in l]
    tot = defaultdict(int)
    for r in rows:
        for k, v in r["twin"].items(): tot[k] += v
    e = max(tot, key=tot.get)
    vals = sorted({r["twin"].get(e, 0) for r in rows if r["twin"].get(e, 0) > 0})
    q = reduce(math.gcd, vals)
    gt = (rows[-1]["tx"][e] - rows[0]["tx"][e]) * 8 / (rows[-1]["t"] - rows[0]["t"])
    hz = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"]); step = max(1, round(hz))
    c = [rows[i]["twin"].get(e, 0) / q for i in range(0, len(rows), step)]
    lam = st.mean(c); sd = math.sqrt(st.pvariance(c))
    # time-weighted mean twin reading vs ground truth: the bias check
    num = den = 0.0
    for i in range(len(rows) - 1):
        dt = rows[i+1]["t"] - rows[i]["t"]; num += rows[i]["twin"].get(e, 0) * dt; den += dt
    return dict(edge=e, q=q, frame=q // 8 // int(round(q / 8 / 1442)) if q else 0,
                gt=gt, lam=lam, fano=st.pvariance(c)/lam, sd_mean=sd/lam*100,
                theory=100/math.sqrt(lam), n_distinct=len(vals), mean=num/den)

def cpu_stats(label):
    rows, hdr = [], None
    for line in open(f"{BASE}/{label}_cpu.jsonl"):
        d = json.loads(line)
        if "clk_tck" in d: hdr = d
        elif "error" not in d: rows.append(d)
    clk = hdr["clk_tck"]; nproc = hdr["nproc"]
    mb = rows[-1]["machine"]["busy"] - rows[0]["machine"]["busy"]
    mt = rows[-1]["machine"]["total"] - rows[0]["machine"]["total"]
    first, last, ft, lt = {}, {}, {}, {}
    for r in rows:
        for k, v in r["proc"].items():
            if k not in first: first[k], ft[k] = v, r["t"]
            last[k], lt[k] = v, r["t"]
    agg = defaultdict(float)
    for k in first:
        dt = lt[k] - ft[k]
        if dt <= 0: continue
        agg[k.split(":")[0].rsplit("-", 1)[0]] += 100.0 * (last[k]-first[k]) / clk / dt
    return dict(machine=100.0*mb/mt, nproc=nproc, **{k: v for k, v in agg.items()})

def delivered(label):
    d = json.load(open(f"{BASE}/{label}_client.json"))
    s = d["end"]["sum"]
    return s["bits_per_second"]/1e6, s["lost_percent"], s["packets"]

CONDS = [("1/256", "rate256"), ("1/128", "rate128"), ("1/64", "rate64")]
T = {lab: twin_stats(f) for lab, f in CONDS}
C = {lab: cpu_stats(f) for lab, f in CONDS}
D = {lab: delivered(f) for lab, f in CONDS}

print("=" * 92)
print("WHAT YOU GET: resolution and precision")
print("=" * 92)
print(f"{'rate':>7} {'quantum Mb':>11} {'lambda/win':>11} {'distinct':>9} {'sd/mean':>9} "
      f"{'1/sqrt(l)':>10} {'Fano':>6} {'mean vs truth':>14}")
for lab, _ in CONDS:
    t = T[lab]
    print(f"{lab:>7} {t['q']/1e6:>11.3f} {t['lam']:>11.1f} {t['n_distinct']:>9} "
          f"{t['sd_mean']:>8.1f}% {t['theory']:>9.1f}% {t['fano']:>6.2f} "
          f"{(t['mean']/t['gt']-1)*100:>+13.1f}%")

base = T["1/256"]
print(f"\n  relative to 1/256:")
for lab, _ in CONDS[1:]:
    t = T[lab]
    print(f"    {lab}: quantum {base['q']/t['q']:.2f}x finer, lambda {t['lam']/base['lam']:.2f}x, "
          f"dispersion {base['sd_mean']/t['sd_mean']:.2f}x tighter "
          f"(sqrt(lambda ratio) predicts {math.sqrt(t['lam']/base['lam']):.2f}x)")

print("\n" + "=" * 92)
print("WHAT IT COSTS: CPU and delivered throughput")
print("=" * 92)
groups = ["bmv2", "kernel", "proxy", "iperf"]
print(f"{'rate':>7} {'machine':>9} " + "".join(f"{g:>11}" for g in groups)
      + f"{'delivered':>11}{'loss':>8}")
for lab, _ in CONDS:
    c = C[lab]; dv, loss, _ = D[lab]
    print(f"{lab:>7} {c['machine']:>8.1f}% " +
          "".join(f"{c.get(g,0):>10.1f}%" for g in groups) +
          f"{dv:>9.1f}M {loss:>7.2f}%")
print(f"\n  (CPU is % of ONE core, summed within a group; {C['1/256']['nproc']} cores total)")
print(f"  bmv2 delta 1/256 -> 1/64: {C['1/64']['bmv2']-C['1/256']['bmv2']:+.1f}% of a core "
      f"({C['1/64']['bmv2']/C['1/256']['bmv2']:.2f}x)")
print(f"  kernel delta:             {C['1/64']['kernel']-C['1/256']['kernel']:+.1f}% of a core "
      f"({C['1/64']['kernel']/C['1/256']['kernel']:.2f}x)")
print(f"  proxy delta:              {C['1/64']['proxy']-C['1/256']['proxy']:+.1f}% of a core "
      f"({C['1/64']['proxy']/C['1/256']['proxy']:.2f}x)")
