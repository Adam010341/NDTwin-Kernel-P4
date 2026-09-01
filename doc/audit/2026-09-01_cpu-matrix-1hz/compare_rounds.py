#!/usr/bin/env python3
"""Put the 1 kHz (2026-08-20) and 1 Hz (2026-09-01) CPU matrices side by side.

[Co-developed with claude code -- Adam]

Usage:  compare_rounds.py

WHY THIS IMPORTS THE OLD ROUND'S ANALYSER INSTEAD OF REIMPLEMENTING IT
The 6-second head trim, the .gz-aware loader, the completeness check and the group
aggregation all live in doc/audit/2026-08-20_sampling-rate-and-cpu/analyse_matrix.py. A second
copy of that logic here would be a second place for it to drift, and the one thing that must
NOT differ between the two rounds is how their numbers are computed -- otherwise a difference
in the loader shows up as a difference in the kernel. So: import it, swap its BASE, read both
rounds through the identical code path.

🔴 WHAT THIS COMPARISON IS
Adam's ruling, 2026-09-01: the 08-20 numbers come from a kernel twelve days older. Ticket Q's
in-loop divisor instrument and the B-2(1)/E-2 fixes are all in between, and no attempt was
made to isolate the recompute change with a one-constant-apart binary. So every delta printed
below is "the difference between two rounds", NOT "the effect of 1 kHz -> 1 Hz". The script
prints that sentence in its own output so a reader who only has the output still gets it.
"""
import importlib.util
import math
from functools import reduce
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OLD_DIR = os.path.join(os.path.dirname(HERE), "2026-08-20_sampling-rate-and-cpu")

spec = importlib.util.spec_from_file_location("am", os.path.join(OLD_DIR, "analyse_matrix.py"))
am = importlib.util.module_from_spec(spec)
spec.loader.exec_module(am)

ROUNDS = [("1 kHz  (2026-08-20)", os.path.join(OLD_DIR, "raw")),
          ("1 Hz   (2026-09-01)", os.path.join(HERE, "raw"))]
RATES = am.RATES


def read_round(base):
    """Every number for one round, read through the old round's own loaders."""
    am.BASE = base
    out = {"rates": {}, "zero": None, "zero_sd": None, "zero_n": 0, "mnone": None}

    for rate in RATES:
        tag = f"m{rate}"
        if not (am._exists(f"{base}/{tag}_poll_cpu.jsonl")
                and am._exists(f"{base}/{tag}_nopoll_cpu.jsonl")):
            continue
        if not (am.is_complete(f"{tag}_poll") and am.is_complete(f"{tag}_nopoll")):
            continue
        on, off = am.cpu_cell(f"{tag}_poll"), am.cpu_cell(f"{tag}_nopoll")
        if not on or not off:
            continue
        sr = am.total_sample_rate(f"{tag}_poll")
        s = 0.0 if sr in (None, 0.0) else (sr[0] if isinstance(sr, tuple) else sr)
        out["rates"][rate] = {
            "samples": s,
            "kernel_on": on[1].get("kernel", 0.0),
            "kernel_off": off[1].get("kernel", 0.0),
            "proxy_on": on[1].get("proxy", 0.0),
            "bmv2_on": on[1].get("bmv2", 0.0),
        }

    # The cold-fabric zero, n=3 where available. This is the number the decomposition
    # subtracts from every cell, so it is reported with its spread, not as a point.
    #
    # 🔴 A cell counts as a zero only if its telemetry really is zero. The label is not
    # evidence: NDTWIN_CLONE_DISABLE=1 has no reader anywhere in the repo
    # (p4_proxy/proxy_agent/main.py:77 names it as this repo's most-repeated bug shape), so a
    # cell brought up with that flag samples exactly as hard as one without it. The 08-20
    # round retracted its own first zero for this, and the 09-01 round then walked into the
    # same hole -- its three mzero replicates carry ~2,378 non-zero twin readings each and are
    # replicates of the 1/64 cell. Checked here, per cell, rather than trusted from the name.
    #
    # Two prefixes are tried. mzero is what both rounds called their zero; mzs is the 09-01
    # re-do, measured by disabling the pipeline's clone predicate instead of by a flag with no
    # reader, with the control verified before each cell. Every candidate still has to pass the
    # telemetry check below, so listing mzero here cannot resurrect the void cells -- it just
    # means the check, rather than the file name, is what decides.
    zs = []
    cands = [f"{p}_nopoll{s}" for p in ("mzero", "mzs") for s in ("", "_r2", "_r3")]
    for lab in cands:
        if not am._exists(f"{base}/{lab}_cpu.jsonl"):
            continue
        # The poll arm carries the twin trace; the poll-off arm records none by design, so the
        # verification has to come from its paired poll cell.
        pair = lab.replace("_nopoll", "_poll")
        if am._exists(f"{base}/{pair}_twin.jsonl"):
            rows = [r for r in am.load(f"{base}/{pair}_twin.jsonl") if "twin" in r]
            nz = sum(1 for r in rows for v in r["twin"].values() if v > 0)
            if nz:
                out.setdefault("zero_rejected", []).append((lab, nz))
                continue
        c = am.cpu_cell(lab)
        if c:
            zs.append(c[1].get("kernel", 0.0))
    if zs:
        out["zero"] = st.mean(zs)
        out["zero_sd"] = st.pstdev(zs) if len(zs) > 1 else 0.0
        out["zero_n"] = len(zs)
        out["zero_reps"] = zs

    zp = []
    for lab in [f"{p}_poll{s}" for p in ("mzero", "mzs") for s in ("", "_r2", "_r3")]:
        if am._exists(f"{base}/{lab}_cpu.jsonl"):
            c = am.cpu_cell(lab)
            if c:
                zp.append(c[1].get("kernel", 0.0))
    out["zero_poll"] = st.mean(zp) if zp else None
    return out


def main():
    data = [(name, read_round(base)) for name, base in ROUNDS]
    if any(not d["rates"] for _, d in data):
        for name, d in data:
            if not d["rates"]:
                print(f"{name}: no complete cells yet")
        return 1

    print("=" * 96)
    print("GUARD -- same traffic in both rounds?  Rejected above 5%: if the fabric offered a")
    print("different load, the two rounds are not comparable and nothing below matters.")
    print("=" * 96)
    print("  Measured on iperf3's own packet count and on aggregate tx from /proc/net/dev.")
    print("  NOT on recovered samples/s -- see the note under this table for why.")
    print()
    print(f"{'rate':>7} {'1 kHz packets':>15} {'1 Hz packets':>14} | {'1 kHz tx Mbit/s':>16} {'1 Hz tx Mbit/s':>15} {'ratio':>7}  verdict")
    guard_ok = True
    for rate in RATES:
        if rate not in data[0][1]["rates"] or rate not in data[1][1]["rates"]:
            continue
        am.BASE = ROUNDS[0][1]
        pa, ta = am.traffic_fingerprint(f"m{rate}_poll")
        am.BASE = ROUNDS[1][1]
        pb, tb = am.traffic_fingerprint(f"m{rate}_poll")
        r = tb / ta if ta else float("nan")
        ok = abs(r - 1.0) <= 0.05 and (pa == pb or None in (pa, pb))
        guard_ok &= ok
        print(f"{rate:>7} {pa or 0:>15,} {pb or 0:>14,} | {ta/1e6:>16.1f} {tb/1e6:>15.1f} {r:>7.3f}  "
              f"{'ok' if ok else 'OUT OF BAND -- rounds not comparable'}")

    # 🔴 The 08-20 analyser recovers the sample quantum as gcd(all non-zero twin readings) and
    # divides by it. That works only while the twin reports link usage as an integer multiple
    # of one sample -- true on 08-20 (24 distinct values, all multiples of 11,812,864) and
    # FALSE on this round (559 distinct values, gcd 1). When it is false the gcd collapses to
    # 1 and total_sample_rate returns the raw summed bits/s: 414,898,073 where the truth is
    # about 35. It does not raise, warn, or return None -- it returns a number 1.2e7x too
    # large that looks like a measurement. Reported here rather than silently routed around,
    # because the same call sits inside analyse_matrix.py's own headline fit.
    print()
    print("  ⚠️  samples/s could NOT be recovered for the 1 Hz round. The quantum is found as")
    print("      gcd(twin readings), which needs the readings to be multiples of one sample:")
    for name, base in ROUNDS:
        am.BASE = base
        rows = am.load(f"{base}/m1024_poll_twin.jsonl")
        t0 = rows[0]["t"]
        rows = [r for r in rows if r["t"] - t0 >= am.WARM]
        vals = sorted({v for r in rows for v in r["twin"].values() if v > 0})
        q = reduce(math.gcd, vals) if vals else None
        print(f"      {name}: {len(vals):>4} distinct non-zero readings, gcd = {q:,}"
              + ("  <- quantised, recovery valid" if q and q > 1 else "  <- NOT quantised, recovery INVALID"))
    print("      Traffic equality is therefore established above on packets and tx bytes,")
    print("      which need no quantum. The kernel CPU figures below are unaffected either")
    print("      way -- they come from /proc/<pid>/stat and never touch the twin.")
    print()

    print("=" * 96)
    print("KERNEL CPU, % of ONE core")
    print("=" * 96)
    print(f"{'':>7} {'--- poll off (ingest only) ---':>34} {'--- poll on ---':>26}")
    print(f"{'rate':>7} {'1 kHz':>10}{'1 Hz':>11}{'delta':>10} {'1 kHz':>10}{'1 Hz':>11}{'delta':>10}")
    print("-" * 96)
    deltas_off = []
    for rate in RATES:
        a = data[0][1]["rates"].get(rate)
        b = data[1][1]["rates"].get(rate)
        if not a or not b:
            continue
        d_off = b["kernel_off"] - a["kernel_off"]
        d_on = b["kernel_on"] - a["kernel_on"]
        deltas_off.append(d_off)
        print(f"{rate:>7} {a['kernel_off']:>9.1f}%{b['kernel_off']:>10.1f}%{d_off:>+10.1f} "
              f"{a['kernel_on']:>9.1f}%{b['kernel_on']:>10.1f}%{d_on:>+10.1f}")

    # The controls. If something systemic had moved between the rounds -- the machine, the
    # probe, how processes are attributed to groups -- it would move these too. iperf3 does
    # identical work in every cell of both rounds and is the noise-floor reference; bmv2 was
    # already known to be flat in sampling rate; the instrument's own cost is the poll-on minus
    # poll-off difference, which is a property of the harness, not of the kernel's inner loops.
    print()
    print("=" * 96)
    print("CONTROLS -- what did NOT move")
    print("=" * 96)
    print(f"{'rate':>7} | {'iperf 1kHz':>11}{'1Hz':>8} | {'bmv2 1kHz':>11}{'1Hz':>8} | "
          f"{'proxy 1kHz':>12}{'1Hz':>8} | {'instrument 1kHz':>17}{'1Hz':>8}")
    print("-" * 96)
    for rate in RATES:
        if rate not in data[0][1]["rates"] or rate not in data[1][1]["rates"]:
            continue
        row = []
        for _, base in ROUNDS:
            am.BASE = base
            on, off = am.cpu_cell(f"m{rate}_poll"), am.cpu_cell(f"m{rate}_nopoll")
            row.append((off[1].get("iperf", 0.0), off[1].get("bmv2", 0.0),
                        off[1].get("proxy", 0.0),
                        on[1].get("kernel", 0.0) - off[1].get("kernel", 0.0)))
        a, b = row
        print(f"{rate:>7} | {a[0]:>10.1f}%{b[0]:>7.1f}% | {a[1]:>10.1f}%{b[1]:>7.1f}% | "
              f"{a[2]:>11.1f}%{b[2]:>7.1f}% | {a[3]:>16.1f}{b[3]:>8.1f}")

    print()
    print("=" * 96)
    print("THE ZERO-SAMPLING POINT -- the cell that decides whether the gap above is a")
    print("constant present at all times, or a step that switches on when sampling does")
    print("=" * 96)
    for name, d in data:
        for lab, nz in d.get("zero_rejected", []):
            print(f"  {name}:  REJECTED {lab} -- its paired poll cell carries {nz:,} non-zero "
                  f"twin readings, so it is not a zero")
        if d["zero"] is None:
            print(f"  {name}:  NOT OBTAINED")
            continue
        reps = ", ".join(f"{v:.2f}" for v in d.get("zero_reps", []))
        print(f"  {name}:  {d['zero']:.2f}%  (n={d['zero_n']}, sd {d['zero_sd']:.2f})   [{reps}]")
    if all(d["zero"] is not None for _, d in data):
        dz = data[1][1]["zero"] - data[0][1]["zero"]
        print(f"\n  delta {dz:+.2f} points")
    else:
        print("\n  No 1 Hz zero, so the 1 Hz column cannot be split into baseline + ingest.")
        print("  The per-rate comparison below needs no zero: it subtracts one round's cell")
        print("  from the other's at the same rate, and the baseline cancels if it is the same")
        print("  in both -- which is itself unverified, and is why the split is not drawn.")

    print()
    print("=" * 96)
    print("IS THE DIFFERENCE A CONSTANT OFFSET?")
    print("=" * 96)
    print("  The recompute thread does not touch the ingest path, so IF the difference were")
    print("  that change, it should sit at the same size on every sampling rate. A delta that")
    print("  grows with the sample rate is something else -- or something else as well.")
    if deltas_off:
        print(f"\n  poll-off deltas: {', '.join(f'{d:+.1f}' for d in deltas_off)}")
        print(f"  mean {st.mean(deltas_off):+.2f}   spread (max-min) {max(deltas_off)-min(deltas_off):.2f}")

    print()
    print("=" * 96)
    print("🔴 WHAT THIS IS NOT")
    print("=" * 96)
    print("  The 08-20 round ran on a kernel twelve days older: ticket Q's in-loop divisor")
    print("  instrument and the B-2(1)/E-2 fixes all landed in between, and no one-constant-")
    print("  apart binary was built. Every delta above is the difference between two ROUNDS.")
    print("  It is not the effect of 1 kHz -> 1 Hz, and must not be reported as one.")
    return 0 if guard_ok else 2


if __name__ == "__main__":
    sys.exit(main())
