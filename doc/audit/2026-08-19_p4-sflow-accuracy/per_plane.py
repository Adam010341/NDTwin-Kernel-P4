"""Is the over-dispersion a property of one cell, or of the OVS plane?

[Co-developed with claude code -- Adam]

DeepSeek's review challenged "over-dispersion is absent at 200 Mbit/s on the same plane": OVS-200M
sits at Fano 1.14, which is not 1.00. The counter-proposal is that the signal is per-PLANE -- OVS
above the floor at both loads, P4 at it -- rather than one anomalous cell.

Testing that needs a null, because Fano == 1.00 is the null for an *ideal* Poisson process, not for
this estimator applied to 300 windows of quantised data. So the null is simulated: draw Poisson
counts at the measured lambda and n, push them through the same code, and read off the spread.
"""
import gzip, json, math, random, statistics as st
from functools import reduce
from collections import defaultdict

def load(p):
    op = gzip.open if p.endswith(".gz") else open
    return [json.loads(l) for l in op(p, "rt") if '"error"' not in l]

def counts(path, edge=None, warm=6.0):
    rows = load(path)
    t0 = rows[0]["t"]
    rows = [r for r in rows if r["t"] - t0 >= warm]
    if edge is None:
        tot = defaultdict(int)
        for r in rows:
            for k, v in r["twin"].items(): tot[k] += v
        edge = max(tot, key=tot.get)
    q = reduce(math.gcd, sorted({r["twin"].get(edge, 0) for r in rows if r["twin"].get(edge, 0) > 0}))
    hz = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
    step = max(1, int(round(hz)))
    return edge, q, [rows[i]["twin"].get(edge, 0) / q for i in range(0, len(rows), step)]

def null_fano(lam, n, trials=4000):
    """Fano distribution of THIS estimator on an ideal Poisson stream at the same lambda and n."""
    out = []
    for _ in range(trials):
        c = [poisson(lam) for _ in range(n)]
        m = st.mean(c)
        out.append(st.pvariance(c) / m if m else 0)
    out.sort()
    return st.mean(out), st.pstdev(out)

def poisson(lam):
    # Normal approximation with continuity correction is exact enough at lambda>=60 and far
    # faster than Knuth's product method, which underflows past lambda~700 anyway.
    if lam > 30:
        return max(0, int(round(random.gauss(lam, math.sqrt(lam)))))
    L, k, p = math.exp(-lam), 0, 1.0
    while True:
        k += 1; p *= random.random()
        if p <= L: return k - 1

A18 = "doc/audit/2026-08-18_live-full-stack-round"
A19 = "doc/audit/2026-08-19_p4-sflow-accuracy"
A20 = "doc/audit/2026-08-20_sampling-rate-and-cpu/raw"

CELLS = [
    ("OVS", "20 Mbit/s",  f"{A18}/sflow_runB_20M.jsonl.gz", "s1-eth2", 0.0),
    ("OVS", "200 Mbit/s", f"{A18}/sflow_runA_200M.jsonl.gz", "s1-eth2", 0.0),
    ("P4",  "20 Mbit/s",  f"{A19}/p4_stock_20M.jsonl.gz",   None,      0.0),
    ("P4",  "200 Mbit/s", f"{A19}/p4_fast_200M.jsonl.gz",   None,      0.0),
    ("P4",  "200M 1/256", f"{A20}/rate256_twin.jsonl",      None,      6.0),
    ("P4",  "200M 1/128", f"{A20}/rate128_twin.jsonl",      None,      6.0),
    ("P4",  "200M 1/64",  f"{A20}/rate64_twin.jsonl",       None,      6.0),
]

random.seed(20260820)
print(f"{'plane':>6} {'load':>12} {'edge':>9} {'n':>5} {'lambda':>8} {'Fano':>7} "
      f"{'null mean':>10} {'null sd':>8} {'z':>7}   verdict")
print("-" * 96)
byplane = defaultdict(list)
for plane, load_, path, edge, warm in CELLS:
    e, q, c = counts(path, edge, warm)
    lam = st.mean(c)
    f = st.pvariance(c) / lam
    nm, nsd = null_fano(lam, len(c))
    z = (f - nm) / nsd
    v = "OVER-DISPERSED" if z > 2 else ("under" if z < -2 else "consistent w/ Poisson")
    print(f"{plane:>6} {load_:>12} {e:>9} {len(c):>5} {lam:>8.1f} {f:>7.3f} "
          f"{nm:>10.3f} {nsd:>8.3f} {z:>+7.1f}   {v}")
    if load_ in ("20 Mbit/s", "200 Mbit/s"):
        byplane[plane].append(z)

print()
for plane, zs in byplane.items():
    print(f"  {plane}: z = {', '.join(f'{z:+.1f}' for z in zs)}   "
          f"{'both above the floor' if all(x > 2 for x in zs) else 'not a uniform per-plane signal'}")
