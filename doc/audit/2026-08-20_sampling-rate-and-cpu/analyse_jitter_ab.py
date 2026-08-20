#!/usr/bin/env python3
"""Compare twin-reading dispersion between the 28b8b13 kernel and today's, same OVS fabric.

The question is not "which is smaller" -- it is "how far is each from the floor". sFlow
sampling puts a hard lower bound on the dispersion of any rate estimate built from it:
with c samples in a window the 95% error is about 196*sqrt(1/c), i.e. sd/mean = 100/sqrt(lambda).
No implementation can go below that without smoothing over a longer window, which trades
lag for the appearance of steadiness.

So:
  - both arms on the floor        -> the jitter is sampling statistics, inherited, not ours
  - today's arm ABOVE the floor   -> we added avoidable noise
  - today's arm BELOW the floor   -> we are smoothing (hiding variance behind lag)
  - baseline BELOW the floor      -> the baseline was smoothing, and we removed it

Method is lifted from plot_figures.py's twin_stats() deliberately -- one method for both
arms, because two arms measured by different code is how a difference gets manufactured.
"""
import gzip
import json
import math
import os
import statistics as st
import sys
from collections import defaultdict
from functools import reduce

RAW = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu/raw"
TRIM = 6.0


def _open(p):
    return open(p) if os.path.exists(p) else gzip.open(p + ".gz", "rt")


def load(label):
    rows = [json.loads(l) for l in _open(f"{RAW}/{label}_twin.jsonl") if '"error"' not in l]
    rows = [r for r in rows if "twin" in r]
    t0 = rows[0]["t"]
    return [r for r in rows if r["t"] - t0 >= TRIM]


def carrying_edges(rows, floor_mbps=1.0):
    """Edges the flow actually crossed, from /proc/net/dev -- independent of the twin."""
    dt = rows[-1]["t"] - rows[0]["t"]
    out = {}
    for k in rows[0]["tx"]:
        if k in rows[-1]["tx"]:
            m = (rows[-1]["tx"][k] - rows[0]["tx"][k]) * 8 / dt / 1e6
            if m > floor_mbps:
                out[k] = m
    return out


def stats_for(rows, edge):
    vals = sorted({r["twin"].get(edge, 0) for r in rows if r["twin"].get(edge, 0) > 0})
    if not vals:
        return None
    q = reduce(math.gcd, vals)
    hz = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
    step = max(1, int(round(hz)))
    counts = [rows[i]["twin"].get(edge, 0) / q for i in range(0, len(rows), step)]
    lam = st.mean(counts)
    if lam <= 0:
        return None
    sd = math.sqrt(st.pvariance(counts))
    gt = (rows[-1]["tx"][edge] - rows[0]["tx"][edge]) * 8 / (rows[-1]["t"] - rows[0]["t"])
    num = den = 0.0
    for i in range(len(rows) - 1):
        d = rows[i + 1]["t"] - rows[i]["t"]
        num += rows[i]["twin"].get(edge, 0) * d
        den += d
    return dict(q=q, lam=lam, sd_mean=sd / lam * 100, theory=100 / math.sqrt(lam),
                fano=st.pvariance(counts) / lam, n_win=len(counts),
                mean=num / den, gt=gt, bias=(num / den) / gt if gt else float("nan"))


def report(label, title):
    try:
        rows = load(label)
    except FileNotFoundError:
        print(f"{title}: NO DATA ({label})")
        return None
    edges = carrying_edges(rows)
    print(f"\n{'='*78}\n{title}   [{label}]\n{'='*78}")
    print(f"  {len(rows)} rows post-trim, {len(edges)} edges carrying >1 Mbit/s")
    out = {}
    for e, mbps in sorted(edges.items(), key=lambda kv: -kv[1]):
        s = stats_for(rows, e)
        if not s:
            # Not "the twin read nothing": run.py's recorder keeps only edges whose BOTH
            # endpoints are switches (run.py:63), so an edge the kernel classifies as
            # host-facing (dst_dpid=0) never enters the trace at all. s2-eth3 is one, and
            # the 開機手冊 session measured the kernel reporting 215.6 Mbit/s on it live
            # (2026-08-20) -- the absence below is the recorder's filter, not the kernel's.
            print(f"  {e:12} tx {mbps:7.1f} Mbit/s   not in the recorded edge set "
                  f"(run.py keeps inter-switch edges only)")
            continue
        out[e] = s
        print(f"  {e:12} tx {mbps:7.1f} Mbit/s | q={s['q']/1e6:.4f}M lam={s['lam']:6.1f} "
              f"| sd/mean {s['sd_mean']:5.1f}%  floor {s['theory']:5.1f}%  "
              f"ratio {s['sd_mean']/s['theory']:.2f} | Fano {s['fano']:.2f} "
              f"| bias {s['bias']:.3f}")
    return out


a = report("ovsjit_head", "A -- today's kernel (HEAD)")
b = report("ovsjit_base", "B -- 28b8b13 baseline kernel")

if a and b:
    shared = sorted(set(a) & set(b))
    print(f"\n{'='*78}\nVERDICT -- distance from the sampling floor, edges common to both\n{'='*78}")
    print(f"  {'edge':12}{'HEAD sd/mean':>14}{'ratio':>8}   {'28b8b13 sd/mean':>17}{'ratio':>8}")
    ra, rb = [], []
    for e in shared:
        x, y = a[e], b[e]
        ra.append(x["sd_mean"] / x["theory"])
        rb.append(y["sd_mean"] / y["theory"])
        print(f"  {e:12}{x['sd_mean']:>13.1f}%{x['sd_mean']/x['theory']:>8.2f}   "
              f"{y['sd_mean']:>16.1f}%{y['sd_mean']/y['theory']:>8.2f}")
    if ra and rb:
        print(f"\n  mean ratio-to-floor:  HEAD {st.mean(ra):.2f}   28b8b13 {st.mean(rb):.2f}")
        d = st.mean(ra) - st.mean(rb)
        print(f"  difference: {d:+.2f}")
        if abs(d) < 0.15:
            print("\n  Both arms sit the same distance from the floor. The dispersion is a")
            print("  property of sFlow sampling at this rate, not of either codebase.")
        elif d > 0:
            print("\n  Today's kernel is FURTHER from the floor -- we added noise. Investigate.")
        else:
            print("\n  The baseline is further from the floor -- today's kernel is tighter.")
elif a and not b:
    print("\nOnly the HEAD arm produced data. The baseline arm needs investigating before")
    print("any claim is made in either direction.")
