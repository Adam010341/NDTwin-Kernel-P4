#!/usr/bin/env python3
"""P1-3 analysis: bmv2 aggregate capacity vs flow count.

Written BEFORE pass B existed, deliberately. Every threshold, interval and verdict string in here
comes from PREREG.md sections 4/6/7 and AMENDMENT-2 section 11.2 -- none of it is chosen after
seeing the numbers it will judge.

What this refuses to do, and why:

  * It will not report a cell verdict from one arm. PREREG section 7 makes the ARM the replication
    unit; a single arm is a re-read, not a replicate. Cells with fewer than two arms print
    ONE-ARM-ONLY and are excluded from every verdict.

  * It will not print 0 or a blank for a missing arm. Missing prints MISSING. "No measurement" and
    "a measurement that came out small" must not serialise to the same thing.

  * The load gate is the in-window busy fraction from /proc/stat deltas (AMENDMENT-2 11.2). The
    `load1 > 3.0` absolute clause registered in section 6 is WITHDRAWN -- it fires on the arm's own
    forwarding load, and per-packet CPU being the bottleneck is this round's premise, so a
    correctly working arm would trip it for working correctly. load1 is printed as a pre-screen
    only. The section 6 RELATIVE clause (> median arm + 0.15 absolute) is kept verbatim.

  * Interface counters are paired ingress-RX against egress-TX ON THE SAME SWITCH. Loss happens
    inside bmv2's own buffers, so every netdev drop counter reads 0 while packets vanish; the only
    informative pairing is what entered s1 against what left it. Comparing an interface's RX to its
    own drop column measures nothing.

Usage: python3 analyse_p1_3.py [raw_dir]
[Co-developed with claude code -- Adam]
"""
import json, glob, os, re, sys, statistics
from datetime import datetime

RAW = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw")
CELLS = [1, 2, 4, 8, 16]
PASSES = ["a", "b"]

# ---- PREREG section 4, registered before any data -------------------------------------------
INTERVALS = {2: (95, 150), 4: (65, 125), 8: (45, 90), 16: (35, 70)}          # aggregate Mbit
MODELS = {
    "per-flow fixed overhead": lambda n: 160.0 / (1 + 0.156 * (n - 1)),
    "power law":               lambda n: 160.0 * n ** -0.434,
}
BUSY_GATE_ABS = 0.15                                                         # PREREG section 6
OLD_16FLOW_SPREAD_MBIT = 48.0                                                # PREREG section 2

MISSING = object()


def read_meta(path):
    d = {}
    for line in open(path):
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.split("#")[0].strip()
    return d


def read_ladder(path):
    rows = []
    with open(path) as fh:
        head = fh.readline()
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) < 7:
                continue
            rows.append(dict(rate=int(f[0]), reps=int(f[1]), scored=f[2],
                             all_reps=f[3], sent=f[4], recv=f[5], clean=f[6]))
    return rows


def load_arm(n, p):
    d = os.path.join(RAW, f"n{n}_{p}")
    meta_p, lad_p = os.path.join(d, "arm.meta"), os.path.join(d, "ladder.tsv")
    if not os.path.isfile(meta_p):
        return MISSING
    m = read_meta(meta_p)
    if "finished" not in m:
        return {"incomplete": True, "dir": d, "meta": m}
    a = {"incomplete": False, "dir": d, "meta": m,
         "ladder": read_ladder(lad_p) if os.path.isfile(lad_p) else []}
    a["agg"] = float(m.get("aggregate_clean_mbit", "nan"))
    a["perflow"] = m.get("highest_clean_per_flow_mbit", "?")
    a["busy"] = float(m.get("busy_fraction", "nan"))
    a["load1max"] = float(m.get("load1_max", "nan"))
    a["truncated"] = m.get("ladder_truncated_at", "?")
    a["confirm"] = m.get("top_rung_confirmation", "")
    # instrument disclosure: JSON files that produced no sum_received
    js = glob.glob(os.path.join(d, "*.json"))
    bad = 0
    for f in js:
        try:
            json.load(open(f))["end"]["sum_received"]
        except Exception:
            bad += 1
    a["json_total"], a["json_bad"] = len(js), bad
    return a


def netdev(path):
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path):
        m = re.match(r"\s*(\S+):\s*(.*)", line)
        if not m:
            continue
        f = m.group(2).split()
        out[m.group(1)] = dict(rxb=int(f[0]), rxp=int(f[1]), rxdrop=int(f[3]),
                               txb=int(f[8]), txp=int(f[9]), txdrop=int(f[11]))
    return out


def banner(t):
    print(f"\n{'=' * 78}\n{t}\n{'=' * 78}")


# ============================================================== load every arm
arms = {(n, p): load_arm(n, p) for n in CELLS for p in PASSES}

banner("P1-3 arms on disk")
print(f"{'cell':6s} {'arm':4s} {'clean M/flow':>13s} {'aggregate':>10s} {'busy':>7s} "
      f"{'load1max':>9s} {'truncated':>10s} {'bad json':>9s}")
for n in CELLS:
    for p in PASSES:
        a = arms[(n, p)]
        if a is MISSING:
            print(f"n={n:<4d} {p:4s} {'MISSING':>13s}")
            continue
        if a["incomplete"]:
            print(f"n={n:<4d} {p:4s} {'INCOMPLETE':>13s}   (no finished= line; started "
                  f"{a['meta'].get('started','?')})")
            continue
        print(f"n={n:<4d} {p:4s} {a['perflow']:>13s} {a['agg']:>10.1f} {a['busy']:>7.4f} "
              f"{a['load1max']:>9.2f} {a['truncated']:>10s} "
              f"{a['json_bad']:>4d}/{a['json_total']:<4d}")

complete = {k: v for k, v in arms.items() if v is not MISSING and not v["incomplete"]}

# ============================================================== PREREG section 6 gate
banner("Section 6 gate -- the constant shown to be constant")
print("load1 clause WITHDRAWN by AMENDMENT-2 11.2; the relative busy-fraction clause is kept verbatim.")
if len(complete) < 2:
    print(f"🔴 only {len(complete)} complete arm(s) -- a median across arms is not defined. GATE NOT EVALUATED.")
    gate_fail = set()
else:
    med = statistics.median(a["busy"] for a in complete.values())
    print(f"median arm busy_fraction = {med:.4f}; rerun any arm above {med + BUSY_GATE_ABS:.4f}")
    gate_fail = set()
    for k in sorted(complete):
        a = complete[k]
        over = a["busy"] - med
        flag = "🔴 RERUN" if over > BUSY_GATE_ABS else "ok"
        if over > BUSY_GATE_ABS:
            gate_fail.add(k)
        print(f"  n={k[0]:<3d}{k[1]}  busy {a['busy']:.4f}  ({over:+.4f} vs median)  {flag}")
    print(f"\nload1_max across arms: {[round(complete[k]['load1max'], 2) for k in sorted(complete)]}")
    print("  ⇒ pre-screen only. The withdrawn absolute gate (>3.0) would have failed "
          f"{sum(1 for a in complete.values() if a['load1max'] > 3.0)}/{len(complete)} arms.")

    # ---------------------------------------------------------------- SUPPLEMENTARY, NOT THE GATE
    # The verdict above is the registered one and stands as printed. This panel exists because the
    # gate is supposed to detect FOREIGN load, while busy_fraction measures TOTAL CPU -- of which
    # the arm's own forwarding is the dominant term. That is the same defect that got the
    # `load1 > 3.0` clause withdrawn in AMENDMENT-2 11.2, and switching to busy_fraction did not
    # cure it; the relative form does not either, because different cells legitimately forward at
    # different intensities. Printed so the gate's verdict is not read as "this arm was polluted".
    # 🔴 Data already exists, so nothing here may amend the gate. This is disclosure, not a fix.
    print("\n--- supplementary (NOT the gate, NOT registered): CPU per unit of traffic actually moved ---")
    print("If an arm's CPU is high relative to the bytes it pushed, that is foreign load.")
    print("If it rises with n, that is the per-packet-CPU premise of this round showing up.\n")
    print(f"{'arm':7s} {'busy':>7s} {'mean ingress Mbit/s':>20s} {'busy per Mbit/s':>17s} {'wall s':>8s}")
    for k in sorted(complete):
        a = complete[k]
        b, af = netdev(f"{a['dir']}/netdev_before.txt"), netdev(f"{a['dir']}/netdev_after.txt")
        try:
            t0 = datetime.strptime(a["meta"]["started"][:19], "%Y-%m-%d %H:%M:%S")
            t1 = datetime.strptime(a["meta"]["finished"][:19], "%Y-%m-%d %H:%M:%S")
            dur = (t1 - t0).total_seconds()
            rate = 8 * (af["s1-eth3"]["rxb"] - b["s1-eth3"]["rxb"]) / dur / 1e6
            print(f"n={k[0]:<3d}{k[1]}  {a['busy']:>7.4f} {rate:>20.1f} {a['busy'] / rate:>17.5f} {dur:>8.0f}")
        except Exception:
            print(f"n={k[0]:<3d}{k[1]}  {a['busy']:>7.4f} {'(no counters/times)':>20s}")
    print("\n🔴 Read this panel with its own caveat: an arm with dead air (rungs where the iperf3")
    print("   control channel failed, so little traffic flowed) has its arm-mean busy diluted, and")
    print("   arm-mean busy is not comparable across arms that differ in how much of their")
    print("   wall-clock was spent forwarding. That applies to n=16 above all.")

# ============================================================== per-cell verdicts
banner("Section 7 -- cells, and what may be said about each")
print("The replication unit is the ARM. A cell with fewer than two arms yields no verdict.\n")
print(f"{'cell':6s} {'arm a':>9s} {'arm b':>9s} {'spread':>8s} {'interval':>12s} {'verdict':s}")
verdicts = {}
for n in CELLS:
    vals = []
    for p in PASSES:
        a = arms[(n, p)]
        vals.append(a["agg"] if (a is not MISSING and not a["incomplete"]) else None)
    lo_hi = INTERVALS.get(n)
    itxt = f"{lo_hi[0]}-{lo_hi[1]}" if lo_hi else "(anchor)"
    sa = f"{vals[0]:.1f}" if vals[0] is not None else "MISSING"
    sb = f"{vals[1]:.1f}" if vals[1] is not None else "MISSING"
    if vals[0] is None or vals[1] is None:
        v = "🔴 ONE-ARM-ONLY -- no verdict (PREREG section 7)"
        spread = "--"
    else:
        spread = f"{abs(vals[0] - vals[1]):.1f}"
        if lo_hi is None:
            v = "anchor cell, no registered interval"
        else:
            ins = [lo_hi[0] <= x <= lo_hi[1] for x in vals]
            if all(ins):
                v = "✅ both arms inside interval"
            elif not any(ins):
                side = "high" if vals[0] > lo_hi[1] else "low"
                v = f"🔴 BOTH arms outside interval ({side})"
            else:
                v = "⚠️ arms straddle the interval edge -- interval does not decide this cell"
    verdicts[n] = (vals, v)
    print(f"n={n:<4d} {sa:>9s} {sb:>9s} {spread:>8s} {itxt:>12s} {v}")

# ============================================================== abandon criterion
banner("Registered abandon criterion")
v2, _ = verdicts.get(2, ([None, None], ""))
if v2[0] is None or v2[1] is None:
    print("n=2 does not yet have two arms ⇒ the abandon criterion CANNOT fire. Not fired.")
elif all(not (95 <= x <= 150) for x in v2):
    print(f"🔴 FIRED: n=2 is outside 95-150 in BOTH arms ({v2[0]:.1f}, {v2[1]:.1f}).")
    # Registered in HANDOFF-CONTEXT.md:65-67 by `8/27 mainDev`, committed 48487ed BEFORE any data
    # -- NOT in PREREG.md, which is what an earlier version of this line claimed. Verbatim:
    #   "What would make me abandon the round: if n=2 lands outside 95-150 in both arms. That
    #    would mean the two-point model that generated every interval is wrong, and continuing to
    #    4 and 8 would just produce three numbers with no frame. Stop and re-derive."
    print("   Registered in HANDOFF-CONTEXT.md:65-67 (commit 48487ed, before any data) --")
    print("   NOT in PREREG.md. It says: the two-point model that generated every interval is")
    print("   wrong. Stop and re-derive. That is a decision to escalate, not to continue past.")
else:
    print(f"Not fired (n=2 arms {v2[0]:.1f}, {v2[1]:.1f}).")

# ============================================================== models
banner("Section 4 -- registered models vs measurement")
print("🔴 Both models are anchored on 160 at n=1, and 160 has since been shown NOT to be the")
print("   switch ceiling: n=1 delivered 238.1 Mbit at the top rung of its own ladder. The anchor")
print("   is a lower bound, so residuals below are against a curve pinned too low at its left end.")
print("   Reported as registered; re-fitting to a new anchor after seeing the data would not be.\n")
print(f"{'cell':6s} {'measured (mean of arms)':>24s}  " + "  ".join(f"{k:>24s}" for k in MODELS))
for n in CELLS:
    vals = [x for x in verdicts[n][0] if x is not None]
    meas = f"{statistics.mean(vals):.1f} (n_arms={len(vals)})" if vals else "MISSING"
    row = f"n={n:<4d} {meas:>24s}  "
    for name, f in MODELS.items():
        pred = f(n)
        resid = f"{statistics.mean(vals) - pred:+.1f}" if vals else "--"
        row += f"{pred:8.1f} (resid {resid:>6s})  "
    print(row)

# ============================================================== secondary observation
banner("Section 2 -- free secondary observation (placement)")
v16 = [x for x in verdicts[16][0] if x is not None]
if len(v16) < 2:
    print(f"🔴 n=16 has {len(v16)} arm(s). The old spread-out 48 Mbit point is a single "
          "unreplicated measurement too;\n   comparing one arm against one arm is not this "
          "observation. NO CLAIM.")
else:
    m16 = statistics.mean(v16)
    print(f"same-placement n=16 (all flows on one path class): {m16:.1f} Mbit  "
          f"[arms {v16[0]:.1f}, {v16[1]:.1f}]")
    print(f"old n=16 spread over four path classes:            {OLD_16FLOW_SPREAD_MBIT:.1f} Mbit")
    print(f"⇒ spreading flows across path classes {'RAISES' if OLD_16FLOW_SPREAD_MBIT > m16 else 'LOWERS'} "
          f"the aggregate by {abs(OLD_16FLOW_SPREAD_MBIT - m16):.1f} Mbit")
    print("⚠️ the old point is one arm, measured on a coarser ladder (rungs 30/10/5/3). "
          "Directional only.")

# ============================================================== section 5 readouts
banner("Section 5 -- interface counters, paired ingress-RX vs egress-TX on the same switch")
print("netdev drop columns are expected to be 0 throughout: loss is inside bmv2, upstream of")
print("nothing the kernel counts. A nonzero drop column would be a DIFFERENT finding.\n")
print(f"{'arm':7s} {'s1 in (pkt)':>13s} {'s1 out (pkt)':>13s} {'lost in s1':>13s} {'%':>7s} "
      f"{'netdev drops':>13s} {'iperf3/netdev':>14s}")
for k in sorted(complete):
    a = complete[k]
    b, af = netdev(f"{a['dir']}/netdev_before.txt"), netdev(f"{a['dir']}/netdev_after.txt")
    if "s1-eth3" not in b or "s1-eth1" not in af:
        print(f"n={k[0]:<3d}{k[1]}  {'NO COUNTER SNAPSHOT':>13s}")
        continue
    ing = af["s1-eth3"]["rxp"] - b["s1-eth3"]["rxp"]
    egr = af["s1-eth1"]["txp"] - b["s1-eth1"]["txp"]
    drops = sum((af[i][c] - b[i][c]) for i in b if i in af for c in ("rxdrop", "txdrop"))
    # cross-instrument: iperf3 payload + 42 B/pkt of headers should equal netdev RX bytes
    ib = ip = 0
    for f in glob.glob(f"{a['dir']}/*.json"):
        try:
            s = json.load(open(f))["end"]["sum_sent"]
            ib += s["bytes"]; ip += s.get("packets", 0)
        except Exception:
            pass
    nd = af["s1-eth3"]["rxb"] - b["s1-eth3"]["rxb"]
    ratio = nd / (ib + 42 * ip) if (ib + 42 * ip) else float("nan")
    print(f"n={k[0]:<3d}{k[1]}  {ing:>13d} {egr:>13d} {ing - egr:>13d} "
          f"{100 * (ing - egr) / ing if ing else 0:>6.2f}% {drops:>13d} {ratio:>14.4f}")
print("\nlast column: netdev RX bytes / (iperf3 sum_sent bytes + 42 B per packet).")
print("  Away from 1.0000 means the two instruments disagree about what crossed that interface,")
print("  and every per-rung number in this round comes from the iperf3 side.")

# ============================================================== disclosure
banner("Instrument disclosure -- no silent caps")
tot_bad = sum(a["json_bad"] for a in complete.values())
print(f"{tot_bad} of {sum(a['json_total'] for a in complete.values())} iperf3 JSON files across all "
      "complete arms produced no sum_received.")
for k in sorted(complete):
    a = complete[k]
    if a["json_bad"]:
        print(f"  n={k[0]}{k[1]}: {a['json_bad']}/{a['json_total']}")
print("Cause where checked: iperf3 control channel timing out under the congestion being measured")
print("(`unable to read from stream socket`, `\"connected\": []`). A rung with ANY failed flow is")
print("scored -1 / NO_MEASUREMENT, never averaged over the survivors.")
for k in sorted(complete):
    a = complete[k]
    nm = [r["rate"] for r in a["ladder"] if r["clean"] == "NO_MEASUREMENT"]
    if nm:
        print(f"  n={k[0]}{k[1]} rungs with no measurement: {nm}")

banner("Top-rung confirmation (AMENDMENT-2 11.1(b))")
for k in sorted(complete):
    print(f"  n={k[0]:<3d}{k[1]}  {complete[k]['confirm'] or '(none recorded)'}")

n_cells_2arm = sum(1 for n in CELLS if all(x is not None for x in verdicts[n][0]))
banner(f"SUMMARY: {len(complete)}/10 arms complete, {n_cells_2arm}/5 cells replicated")
if n_cells_2arm < len(CELLS):
    print("🔴 This round cannot be reported as a curve. Cells without two arms are re-reads.")
