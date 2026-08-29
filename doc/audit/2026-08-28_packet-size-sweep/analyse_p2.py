#!/usr/bin/env python3
"""2 analysis: is bmv2's forwarding ceiling pps or bps?

Every threshold and interval here comes from PREREG.md sections 3/4 and AMENDMENT-1 section 7 --
registered before any arm ran. The script refuses the same things analyse_p1_3.py refuses: no
verdict from one arm, MISSING is not 0, and the gate's verdict prints whether or not it is
convenient.

Usage: python3 analyse_p2.py [raw_dir]
[Co-developed with claude code -- Adam]
"""
import json, glob, os, sys, statistics

RAW = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw")
SIZES = [64, 256, 1024]
PASSES = ["a", "b"]

# ---- PREREG section 4, registered before any data ---------------------------------------------
H1 = {256: (0.75, 1.30), 1024: (0.65, 1.30)}     # ceiling is pps  -> ratios near 1
H2 = {256: (0.15, 0.40), 1024: (0.03, 0.12)}     # ceiling is bps  -> pps falls with size
EXT_GATE_ABS = 0.15                              # AMENDMENT-1 7.2, on `external` not total busy
CONTROL_CEILING_KPPS = 770.7                     # measured, raw/sender_control/
CONTROL_FACTOR = 5                               # PREREG section 3


def meta(p):
    d = {}
    for line in open(p):
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.split("#")[0].strip()
    return d


def banner(t):
    print(f"\n{'=' * 76}\n{t}\n{'=' * 76}")


arms = {}
for s in SIZES:
    for p in PASSES:
        f = os.path.join(RAW, f"f{s}_{p}", "arm.meta")
        arms[(s, p)] = meta(f) if os.path.isfile(f) else None

banner("2 arms on disk")
print(f"{'frame':8s} {'arm':4s} {'clean kpps':>11s} {'external':>9s} {'total busy':>11s} "
      f"{'bmv2 share':>11s} {'truncated':>11s}")
for s in SIZES:
    for p in PASSES:
        m = arms[(s, p)]
        if m is None or "finished" not in m:
            print(f"{s:<8d} {p:4s} {'MISSING' if m is None else 'INCOMPLETE':>11s}")
            continue
        print(f"{s:<8d} {p:4s} {m['highest_clean_kpps']:>11s} {m['external']:>9s} "
              f"{m['total_busy']:>11s} {m['bmv2_share']:>11s} {m['ladder_truncated_at']:>11s}")

done = {k: v for k, v in arms.items() if v and "finished" in v}

# ---- AMENDMENT-1 7.2 gate ---------------------------------------------------------------------
banner("AMENDMENT-1 gate -- on FOREIGN CPU (external), not total busy")
print("Total busy is dominated by the arm's own forwarding and is maximal at 64 B, which is the")
print("treatment. Gating on it would demand a rerun of exactly the arms carrying the headline.\n")
if len(done) < 2:
    print("🔴 fewer than 2 complete arms -- median undefined, GATE NOT EVALUATED")
else:
    ext = {k: float(v["external"]) for k, v in done.items()}
    med = statistics.median(ext.values())
    print(f"median external = {med:.4f}; rerun any arm above {med + EXT_GATE_ABS:.4f}")
    fired = []
    for k in sorted(done):
        d = ext[k] - med
        f = "🔴 RERUN" if d > EXT_GATE_ABS else "ok"
        if d > EXT_GATE_ABS:
            fired.append(k)
        print(f"  {k[0]:>4d}B {k[1]}  external {ext[k]:.4f}  ({d:+.4f} vs median)  {f}")
    print(f"\n⇒ {len(fired)} arm(s) fired." if fired else "\n⇒ no arm fired.")
    print("🔑 This gate has a POSITIVE CONTROL (AMENDMENT-1 7.3): a throwaway arm with 4 CPU")
    print("   burners read external=0.2959 against 0.0178 without, i.e. it fires when it should.")
    print("   'No arm fired' is therefore a measurement, not an untested gate.")
    bm = [float(v["bmv2_share"]) for v in done.values()]
    print(f"\nbmv2_share across arms: min {min(bm):.4f} max {max(bm):.4f} spread {max(bm)-min(bm):.4f}")
    print("   ⇒ bmv2's own CPU cost is near-constant across frame sizes at the clean rung.")

# ---- cells ------------------------------------------------------------------------------------
banner("Cells -- the arm is the replication unit; one arm yields no verdict")
cells = {}
print(f"{'frame':8s} {'arm a':>8s} {'arm b':>8s} {'mean':>8s}   note")
for s in SIZES:
    vals = []
    for p in PASSES:
        m = arms[(s, p)]
        v = m.get("highest_clean_kpps") if m and "finished" in m else None
        vals.append(float(v) if v and v != "none" else None)
    if None in vals:
        cells[s] = None
        print(f"{s:<8d} {str(vals[0]):>8s} {str(vals[1]):>8s} {'--':>8s}   🔴 ONE-ARM-ONLY, no verdict")
    else:
        cells[s] = statistics.mean(vals)
        note = "arms agree" if vals[0] == vals[1] else "arms differ by one ladder rung"
        print(f"{s:<8d} {vals[0]:>8.0f} {vals[1]:>8.0f} {cells[s]:>8.1f}   {note}")

# ---- the registered question ------------------------------------------------------------------
banner("Section 4 -- the registered ratios")
if any(v is None for v in cells.values()):
    print("🔴 not every cell has two arms; ratios not computed.")
else:
    print(f"{'ratio':16s} {'measured':>9s}   {'H1 (pps ceiling)':>18s}   {'H2 (bps ceiling)':>18s}   verdict")
    verdicts = []
    for s in (256, 1024):
        r = cells[s] / cells[64]
        h1, h2 = H1[s], H2[s]
        in1, in2 = h1[0] <= r <= h1[1], h2[0] <= r <= h2[1]
        v = "H1" if in1 else ("H2" if in2 else "H3 (between)")
        verdicts.append(v)
        print(f"P({s})/P(64)   {r:>9.2f}   {str(h1):>18s}   {str(h2):>18s}   "
              f"{'✅ ' if in1 else '🔴 '}{v}")
    print()
    if all(v == "H1" for v in verdicts):
        print("⇒ **H1: the ceiling is pps, not bps.** Both registered ratios land inside H1.")
    elif all(v == "H2" for v in verdicts):
        print("⇒ H2: the ceiling is bps.")
    else:
        print(f"⇒ MIXED: {verdicts}. PREREG registers 'between' as H3 (fixed + proportional cost),")
        print("  a RESULT, not an inconclusive measurement. Report it as such.")

    print("\nThe same numbers as bits per second at the clean rung (frame bytes, not payload):")
    print(f"{'frame':8s} {'clean kpps':>11s} {'frame Mbit/s':>13s}")
    bps = {}
    for s in SIZES:
        b = cells[s] * 1000 * s * 8 / 1e6
        bps[s] = b
        print(f"{s:<8d} {cells[s]:>11.1f} {b:>13.1f}")
    print(f"\n🔑 pps varies {max(cells.values())/min(cells.values()):.2f}x across the axis; "
          f"bits/s varies {max(bps.values())/min(bps.values()):.1f}x.")
    print("   A bps ceiling would make the bits/s column flat and the pps column fall 16x.")

# ---- section 3 sender-side control -------------------------------------------------------------
banner("Section 3 -- was the generator the limit? (registered gate, decided here)")
top = max(v for v in cells.values() if v) if cells and all(cells.values()) else None
if top is None:
    print("cells incomplete; cannot evaluate.")
else:
    p64 = cells[64]
    need = CONTROL_FACTOR * p64
    print(f"highest 64 B pps measured through bmv2: {p64:.1f} kpps")
    print(f"registered requirement: generator must sustain >= {CONTROL_FACTOR}x that = {need:.1f} kpps")
    print(f"measured generator ceiling (64 B, h1 loopback, no bmv2): {CONTROL_CEILING_KPPS:.1f} kpps")
    ok = CONTROL_CEILING_KPPS >= need
    print(f"\n{'✅ PASSES' if ok else '🔴 FAILS'} by a factor of {CONTROL_CEILING_KPPS/need:.1f}"
          f" over the requirement.")
    if not ok:
        print("🔴 The round is INVALID and may report only 'generator-limited at 64 B'.")

# ---- registered cross-check 7.4.2 --------------------------------------------------------------
banner("AMENDMENT-1 7.4.2 -- free fourth point from 3's n=1 (registered before this round)")
print("3 measured n=1 clean at 160 (arm a) and 240 (arm b) Mbit/flow, 1400 B payload / 1442 B frame.")
for label, mbit in (("arm a", 160), ("arm b", 240)):
    print(f"  {label}: {mbit} Mbit/s / (1400 B x 8) = {mbit*1e6/(1400*8)/1000:.1f} kpps")
m3 = statistics.mean([160e6 / (1400 * 8) / 1000, 240e6 / (1400 * 8) / 1000])
print(f"  mean: {m3:.1f} kpps at a 1442 B frame, from an independent round whose ladder was in")
print("  Mbit/s, not pps -- so this point could not have been shaped by 2's axis.")
if cells.get(1024):
    print(f"\n2's 1024 B cell: {cells[1024]:.1f} kpps.  Ratio {m3/cells[1024]:.2f}.")
    print("H1 predicted these would be close; H2 predicted they would differ substantially.")
