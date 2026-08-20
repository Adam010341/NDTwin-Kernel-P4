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


def _exists(path):
    """Presence test that agrees with _open(). Testing the uncompressed name alone made every
    cell look absent once the traces were committed .gz, and main() reported "no cells found"
    on a complete matrix -- the loaders had been taught about .gz but this check had not."""
    return os.path.exists(path) or os.path.exists(str(path) + ".gz")

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
            if not _exists(f"{BASE}/{lab}_cpu.jsonl"):
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

    # A row is only an intercept if its telemetry is actually zero. `mnone` was built to be
    # one -- NDTWIN_CLONE_DISABLE=1 -- and is not: the flag never took, it measures 553.5
    # samples/s and is a replicate of the 1/64 cell. Fitting through a mislabelled zero is how
    # an intercept becomes fiction, so the check is made here rather than trusted from the label.
    print()
    print("=" * 100)
    print("ZERO-POINT CHECK -- a cell is an intercept only if its twin readings are all zero")
    print("=" * 100)
    for lab in ("mnone_poll", "mzero_poll", "mzero_nopoll"):
        if not _exists(f"{BASE}/{lab}_twin.jsonl"):
            continue
        rows = [r for r in load(f"{BASE}/{lab}_twin.jsonl") if "twin" in r]
        if not rows:
            print(f"  {lab:14} no twin readings (poll-off arm records none by design)")
            continue
        t0 = rows[0]["t"]
        rows = [r for r in rows if r["t"] - t0 >= WARM]
        nz = sum(1 for r in rows for v in r["twin"].values() if v > 0)
        tot = sum(v for r in rows for v in r["twin"].values())
        verdict = "TRUE ZERO" if nz == 0 else "NOT A ZERO -- do not fit through it"
        print(f"  {lab:14} non-zero readings {nz:>6}  sum {tot:>18,}   {verdict}")
    # The poll-off arm runs netdev_only.py, which records tx counters and no twin readings at
    # all -- so mzero_nopoll's zero cannot be read off its own trace. It inherits it from
    # mzero_poll, the poll-on arm of the same cold-fabric run, exactly as the poll-off cells
    # inherit their sample rate above. The inheritance is checked the same way: the two arms
    # must differ by the polling cost and nothing else.
    zp, zn = cpu_cell("mzero_poll"), cpu_cell("mzero_nopoll")
    if zp and zn:
        d = zp[1].get("kernel", 0.0) - zn[1].get("kernel", 0.0)
        polls = [k_on - k_off for rate, _, k_on, k_off in table if rate != "none"]
        inside = min(polls) - 0.7 <= d <= max(polls) + 0.7
        print(f"\n  mzero_poll - mzero_nopoll = {d:.1f} points of polling cost; the matrix's own "
              f"poll column\n  spans {min(polls):.1f}-{max(polls):.1f}. "
              f"{'Consistent -- the inheritance holds.' if inside else 'OUTSIDE -- inheritance suspect.'}")

    pts = [(s, k_off) for rate, s, _, k_off in table if s is not None and rate != "none"]
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

        # The fit is excellent inside the measured decade and worthless outside it. Printing the
        # intercept next to the measured zero is what stops the slope being turned into a
        # saturation rate: 1 core / 206 us reads as "~4,800 samples/s", but that arithmetic
        # assumes a line through the origin and this line misses the origin by 45 points.
        # n=3 as of the evening of 2026-08-20: three cold-fabric runs, each with the control
        # verified before measuring. Averaged here; the replicates are also printed, because
        # a mean that hides a wild replicate would be exactly the kind of number this file
        # exists to catch.
        z_reps = []
        for lab in ("mzero_nopoll", "mzero_nopoll_r2", "mzero_nopoll_r3"):
            zc = cpu_cell(lab) if _exists(f"{BASE}/{lab}_cpu.jsonl") else None
            if zc:
                z_reps.append((lab, zc[1].get("kernel", 0.0)))
        if z_reps:
            z = st.mean([v for _, v in z_reps])
            print()
            print("=" * 100)
            print("DOES THE LINE REACH ZERO?  (it does not, so the slope is not a ceiling)")
            print("=" * 100)
            print(f"  fitted intercept              {a:>7.2f}%   at 0 samples/s")
            reps = ", ".join(f"{v:.2f}" for _, v in z_reps)
            print(f"  measured zero (n={len(z_reps)})         {z:>7.2f}%   replicates: {reps} "
                  f"-- cold fabric, control verified each time")
            print(f"  gap                           {a - z:>7.2f}    points = {(a - z) / 0.7:.0f}x "
                  f"the 0.7-point noise floor")
            print()
            print(f"  So {b * 1e4:.0f} us/sample is the marginal cost between {min(xs):.1f} and "
                  f"{max(xs):.1f} samples/s,\n  and nothing more. Dividing one core by it gives "
                  f"{1e6 / (b * 1e4):,.0f} samples/s, and that number is not\n  a capacity: it "
                  f"extrapolates through a region the matrix never measured, where the\n  line is "
                  f"known to be wrong by {a - z:.0f} points at the one end that was checked.")
            print(f"\n  What IS measured: {min(ys) - z:.1f} of the {max(ys) - z:.1f} points of "
                  f"ingest cost at {max(xs):.0f} samples/s are\n  already paid at "
                  f"{min(xs):.1f} samples/s. The cost is dominated by a fixed component whose\n"
                  f"  shape below {min(xs):.1f} samples/s is unknown.")


if __name__ == "__main__":
    main()
