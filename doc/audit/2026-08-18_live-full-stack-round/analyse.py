"""Post-pass for the sFlow accuracy run: twin vs kernel counters, swept over window length.

Reports, for each window T, the distribution of (twin estimate / ground truth) over
non-overlapping windows, next to the sampling-theory prediction 196*sqrt(1/c).

The point of the sweep is to separate two things the prior round could not:
  - spread  -> sampling noise, must shrink as sqrt(T) and must match the formula
  - centre  -> bias, which noise cannot produce and which no window length will fix

[Co-developed with claude code -- Adam]
"""
import json, sys, math, statistics as st

PATH = sys.argv[1]
EDGE = sys.argv[2] if len(sys.argv) > 2 else "s1-eth2"
# 256 (sFlow sampling rate) x frame bytes x 8. Frame length is the *sampled* one, so this
# is per-flow; 1494 measured for this iperf3 UDP stream in the characterisation run.
QUANTUM = 256 * 1494 * 8

rows = [json.loads(l) for l in open(PATH)]
bad = [r for r in rows if "error" in r]
rows = [r for r in rows if "error" not in r]
print(f"{len(rows)} good samples, {len(bad)} dropped, span {rows[-1]['t']-rows[0]['t']:.0f}s\n")


def twin_mean(a, b):
    """Time-weighted mean of the twin's reading over rows[a:b]."""
    num = den = 0.0
    for i in range(a, b - 1):
        dt = rows[i + 1]["t"] - rows[i]["t"]
        num += rows[i]["twin"].get(EDGE, 0) * dt
        den += dt
    return num / den if den else 0.0


def gt_mean(a, b):
    """Exact mean from the tx_bytes delta -- no sampling involved."""
    dt = rows[b - 1]["t"] - rows[a]["t"]
    db = rows[b - 1]["tx"][EDGE] - rows[a]["tx"][EDGE]
    return db * 8 / dt if dt else 0.0


def agg_twin_mean(a, b):
    num = den = 0.0
    for i in range(a, b - 1):
        dt = rows[i + 1]["t"] - rows[i]["t"]
        num += sum(rows[i]["twin"].values()) * dt
        den += dt
    return num / den if den else 0.0


# The switch-to-switch interface set, taken from the twin's own edge list rather than from a
# port-number rule. `eth1..eth4` is NOT that set: on the access switches s1-s4 only eth1/eth2 are
# uplinks and hosts start at eth3, so the heuristic silently folds one host-facing link into
# ground truth while the twin's switch-to-switch sum correctly excludes it. That alone puts a
# fixed ~-19% on the ratio here, and it does not shrink with T, so it reads exactly like a bias.
SS_IFACES = set(rows[0]["twin"].keys())


def agg_gt_mean(a, b):
    dt = rows[b - 1]["t"] - rows[a]["t"]
    if not dt:
        return 0.0
    tot = 0
    for k in SS_IFACES:
        if k in rows[a]["tx"] and k in rows[b - 1]["tx"]:
            tot += rows[b - 1]["tx"][k] - rows[a]["tx"][k]
    return tot * 8 / dt


HZ = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
print(f"effective sample rate {HZ:.2f} Hz\n")

hdr = f"{'T (s)':>7} {'n win':>6} {'gt mean Mbps':>13} {'ratio med':>10} {'ratio min':>10} " \
      f"{'ratio max':>10} {'spread ±%':>10} {'theory ±%':>10}"
print("=== PER-LINK: " + EDGE + " ===")
print(hdr)
print("-" * len(hdr))
for T in (1, 2, 5, 10, 30, 60, 150, 430):
    step = max(1, int(round(T * HZ)))
    ratios, gts = [], []
    i = 0
    while i + step < len(rows):
        g = gt_mean(i, i + step + 1)
        w = twin_mean(i, i + step + 1)
        if g > 1e6:
            ratios.append(w / g)
            gts.append(g)
        i += step
    if len(ratios) < 2:
        continue
    gm = st.mean(gts)
    c = gm * T / QUANTUM
    theory = 196 / math.sqrt(c) if c > 0 else float("nan")
    # observed spread as a 95% interval, expressed like the theory number
    sd = st.pstdev(ratios)
    print(f"{T:>7} {len(ratios):>6} {gm/1e6:>13.1f} {st.median(ratios):>10.3f} "
          f"{min(ratios):>10.3f} {max(ratios):>10.3f} {1.96*sd*100:>10.1f} {theory:>10.1f}")

print("\n=== AGGREGATE: all switch-to-switch edges (F-10 replication) ===")
print(hdr)
print("-" * len(hdr))
for T in (1, 2, 5, 10, 30, 60, 150, 430):
    step = max(1, int(round(T * HZ)))
    ratios, gts = [], []
    i = 0
    while i + step < len(rows):
        g = agg_gt_mean(i, i + step + 1)
        w = agg_twin_mean(i, i + step + 1)
        if g > 1e6:
            ratios.append(w / g)
            gts.append(g)
        i += step
    if len(ratios) < 2:
        continue
    gm = st.mean(gts)
    c = gm * T / QUANTUM
    theory = 196 / math.sqrt(c) if c > 0 else float("nan")
    sd = st.pstdev(ratios)
    print(f"{T:>7} {len(ratios):>6} {gm/1e6:>13.1f} {st.median(ratios):>10.3f} "
          f"{min(ratios):>10.3f} {max(ratios):>10.3f} {1.96*sd*100:>10.1f} {theory:>10.1f}")
