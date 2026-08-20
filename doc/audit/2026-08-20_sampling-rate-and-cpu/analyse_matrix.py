#!/usr/bin/env python3
"""
Decompose the kernel's CPU into "ingesting sFlow" and "serving the instrument".

[Co-developed with claude code -- Adam]

Usage:  analyse_matrix.py

The question this exists to settle. The single-factor sweep suggested the kernel's sFlow cost
was strongly sub-linear in sample count -- 0 -> 203 samples/s cost 47 points of a core while
203 -> 813 cost only 10 more. Two things could produce that shape and they have opposite
implications:

  (a) a real saturation effect -- a fixed cost paid once for "receiving anything at all"
      (wakeups, a per-interval scan) that dwarfs the per-sample work, or

  (b) an artefact, because the zero point came from a differently-configured run while every
      other point also carried the cost of the kernel serving this harness's own 4 Hz poll of
      a 288-edge graph.

The matrix separates them: five sampling rates plus a no-clone intercept, each measured with
the poll on and off. Subtracting the paired cells gives the polling cost directly; the poll-off
column alone is the ingest cost with the instrument removed, and its shape against sample rate
answers the question.

WHY THE SAMPLE RATE IS TAKEN FROM THE POLL-ON CELL
--------------------------------------------------
A poll-off cell has no twin readings, so there is nothing to divide by the quantum. Its sample
rate is inherited from the poll-on cell at the same sampling rate. That is sound because the
sample rate is a property of the traffic and the pipeline, not of whether anyone is watching --
and it is checked rather than assumed: the paired cells' iperf3 packet counts and aggregate
interface bytes must agree, and this script fails loudly if they do not.

The /proc/net/snmp UDP cross-check that cpu_probe records is NOT used here. On the first pair
it disagreed by 67% between two cells whose traffic was identical to the packet, so it does not
measure what it was added to measure. Left in the data, unused, and reported as a caveat.
"""
import glob
import gzip
import json
import math
import os
import statistics as st
from collections import defaultdict
from functools import reduce

def _open(path):
    """Open a trace whether or not it is gzipped -- traces are committed .gz (see .gitignore)."""
    path = str(path)
    if os.path.exists(path):
        return open(path)
    return gzip.open(path + ".gz", "rt")

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw")
WARM = 6.0                       # harness starts pollers, sleeps 2 s, then iperf3
RATES = [1024, 512, 256, 128, 64]


def load(path):
    return [json.loads(l) for l in _open(path) if '"error"' not in l]


def cpu_cell(label):
    """(machine_busy_pct, {group: pct_of_one_core}) for one cell."""
    rows, hdr = [], None
    for line in _open(f"{BASE}/{label}_cpu.jsonl"):
        d = json.loads(line)
        if "clk_tck" in d:
            hdr = d
        elif "error" not in d:
            rows.append(d)
    if hdr is None or len(rows) < 10:
        return None
    t0 = rows[0]["t"]
    rows = [r for r in rows if r["t"] - t0 >= WARM]
    mb = rows[-1]["machine"]["busy"] - rows[0]["machine"]["busy"]
    mt = rows[-1]["machine"]["total"] - rows[0]["machine"]["total"]
    first, last, ft, lt = {}, {}, {}, {}
    for r in rows:
        for k, v in r["proc"].items():
            if k not in first:
                first[k], ft[k] = v, r["t"]
            last[k], lt[k] = v, r["t"]
    agg = defaultdict(float)
    for k in first:
        dt = lt[k] - ft[k]
        if dt <= 0:
            continue
        agg[k.split(":")[0].rsplit("-", 1)[0]] += 100.0 * (last[k] - first[k]) / hdr["clk_tck"] / dt
    return 100.0 * mb / mt, dict(agg)


def total_sample_rate(label):
    """
    Samples per second reaching the kernel, summed over every edge -- not one edge's lambda.

    The kernel's cost is driven by every datagram it receives, and a flow crossing three
    switches is sampled at each of them. Using the busiest edge's lambda would understate the
    load by the number of carrying hops.
    """
    rows = load(f"{BASE}/{label}_twin.jsonl")
    t0 = rows[0]["t"]
    rows = [r for r in rows if r["t"] - t0 >= WARM]
    if not rows or "twin" not in rows[0]:
        return None
    vals = sorted({v for r in rows for v in r["twin"].values() if v > 0})
    if not vals:
        return 0.0
    q = reduce(math.gcd, vals)
    hz = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
    step = max(1, int(round(hz)))
    per_window = [sum(rows[i]["twin"].values()) / q for i in range(0, len(rows), step)]
    return st.mean(per_window), q


def traffic_fingerprint(label):
    """(iperf packets, aggregate tx bits/s) -- used to prove a pair really is a pair."""
    try:
        s = json.load(open(f"{BASE}/{label}_client.json"))["end"]["sum"]
        pkts = s["packets"]
    except Exception:
        pkts = None
    rows = load(f"{BASE}/{label}_twin.jsonl")
    t0 = rows[0]["t"]
    rows = [r for r in rows if r["t"] - t0 >= WARM]
    dt = rows[-1]["t"] - rows[0]["t"]
    tot = sum(rows[-1]["tx"][k] - rows[0]["tx"][k] for k in rows[0]["tx"] if k in rows[-1]["tx"])
    return pkts, tot * 8 / dt


def is_complete(label, min_seconds=200.0):
    """
    Has this cell finished, or is matrix.sh still writing it?

    A half-written cell is worse than a missing one: its files all exist, its CPU jsonl parses,
    and its iperf3 client.json is present but empty -- so an analysis that only checks for the
    files reads a partial run as if it were a result. Caught by dry-running this script against
    a live matrix, where the in-flight cell produced 0 packets, a "pairing MISMATCH" against its
    own twin, and a *negative* polling cost.
    """
    try:
        s = json.load(open(f"{BASE}/{label}_client.json"))["end"]["sum"]
        if not s.get("packets"):
            return False
    except Exception:
        return False
    try:
        rows = [json.loads(l) for l in _open(f"{BASE}/{label}_cpu.jsonl") if '"clk_tck"' not in l]
        rows = [r for r in rows if "error" not in r]
        if len(rows) < 10 or rows[-1]["t"] - rows[0]["t"] < min_seconds:
            return False
    except Exception:
        return False
    return True


def main():
    cells, skipped = {}, []
    for rate in RATES + ["none"]:
        tag = f"m{rate}" if rate != "none" else "mnone"
        for arm in ("poll", "nopoll"):
            lab = f"{tag}_{arm}"
            if not os.path.exists(f"{BASE}/{lab}_cpu.jsonl"):
                continue
            if not is_complete(lab):
                skipped.append(lab)
                continue
            c = cpu_cell(lab)
            if c:
                cells[(rate, arm)] = c
    if skipped:
        print(f"skipping {len(skipped)} incomplete cell(s): {', '.join(skipped)}\n")

    if not cells:
        print("no cells found -- has matrix.sh produced anything yet?")
        return

    print("=" * 100)
    print("PAIRING CHECK -- a poll-off cell inherits its sample rate from its poll-on twin,")
    print("which is only legitimate if the two really saw the same traffic.")
    print("=" * 100)
    print(f"{'rate':>7} {'poll-on packets':>17} {'poll-off packets':>17} {'tx on':>11} {'tx off':>11}  verdict")
    ok = True
    for rate in RATES + ["none"]:
        tag = f"m{rate}" if rate != "none" else "mnone"
        if (rate, "poll") not in cells or (rate, "nopoll") not in cells:
            continue
        p1, t1 = traffic_fingerprint(f"{tag}_poll")
        p2, t2 = traffic_fingerprint(f"{tag}_nopoll")
        same = (p1 == p2) and abs(t1 - t2) / max(t1, 1) < 0.02
        ok &= same
        print(f"{str(rate):>7} {p1 if p1 else 0:>17,} {p2 if p2 else 0:>17,} "
              f"{t1/1e6:>10.1f}M {t2/1e6:>10.1f}M  {'ok' if same else 'MISMATCH -- pairing invalid'}")
    if not ok:
        print("\n  ^^ at least one pair is not a pair; the inherited sample rates below are unsafe")

    print()
    print("=" * 100)
    print("THE DECOMPOSITION")
    print("=" * 100)
    print(f"{'rate':>7} {'samples/s':>11} | {'kernel on':>10}{'kernel off':>11}{'polling':>9} | "
          f"{'proxy on':>9}{'proxy off':>10} | {'bmv2 on':>9}{'bmv2 off':>9}")
    print("-" * 100)
    table = []
    for rate in RATES + ["none"]:
        tag = f"m{rate}" if rate != "none" else "mnone"
        if (rate, "poll") not in cells or (rate, "nopoll") not in cells:
            continue
        (m1, a1), (m2, a2) = cells[(rate, "poll")], cells[(rate, "nopoll")]
        sr = total_sample_rate(f"{tag}_poll")
        s = 0.0 if sr in (None, 0.0) else (sr[0] if isinstance(sr, tuple) else sr)
        table.append((rate, s, a1.get("kernel", 0), a2.get("kernel", 0)))
        print(f"{str(rate):>7} {s:>11.1f} | {a1.get('kernel',0):>9.1f}%{a2.get('kernel',0):>10.1f}%"
              f"{a1.get('kernel',0)-a2.get('kernel',0):>8.1f} | {a1.get('proxy',0):>8.1f}%"
              f"{a2.get('proxy',0):>9.1f}% | {a1.get('bmv2',0):>8.1f}%{a2.get('bmv2',0):>8.1f}%")

    pts = [(s, k_off) for _, s, _, k_off in table if s is not None]
    if len(pts) >= 3:
        print()
        print("=" * 100)
        print("IS THE INGEST COST LINEAR IN SAMPLE RATE?  (poll-off column, instrument removed)")
        print("=" * 100)
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        n = len(pts)
        mx, my = st.mean(xs), st.mean(ys)
        den = sum((x - mx) ** 2 for x in xs)
        b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else 0
        a = my - b * mx
        print(f"  least-squares fit: kernel% = {a:.2f} + {b*1000:.3f} per 1000 samples/s")
        print(f"  implied marginal cost: {b*1e4:.1f} microseconds of CPU per sample\n")
        print(f"  {'samples/s':>11}{'measured':>10}{'fitted':>9}{'residual':>10}")
        worst = 0.0
        for x, y in pts:
            f = a + b * x
            worst = max(worst, abs(y - f))
            print(f"  {x:>11.1f}{y:>9.1f}%{f:>8.1f}%{y-f:>+9.1f}")
        print(f"\n  largest residual {worst:.1f} points. The per-process noise floor measured "
              f"from iperf3\n  (identical work in every cell) is about 0.7 points, so a residual "
              f"much above that\n  is structure, not noise -- and structure here means the cost "
              f"is NOT linear in samples.")


if __name__ == "__main__":
    main()
