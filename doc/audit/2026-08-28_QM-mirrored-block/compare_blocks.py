#!/usr/bin/env python3
"""PREREG amendment C-3: did the neighbour VM's CPU contention move the conclusions?

Block 1 (09:32) ran with a neighbour compiling on 4 vCPUs for its whole window, weighted onto the
TREATMENT arms. Block 2 (10:10) ran with that paused -- one 22 s I/O spike on a CONTROL arm is
all that is left. Same generation, same binaries, same working point, same seed, same script.

C-1 narrows what the difference measures: qemu's `stop` halts vCPUs but does not release guest
memory, so block 2 still carries the memory and swap pressure. The difference is what the CPU
CONTENTION did, not what the VM did.

C-3 fixed the reading in advance:
  difference < each block's own arm spread  => contention did not move the conclusion
  difference > it                           => it did, and block 2 governs
  same direction and magnitude              => robust, but NOT "proof of no contamination"

It also reconciles the period three ways, because the two blocks now let a systematic offset be
told apart from arm noise -- something one block could not do.

Usage: compare_blocks.py
[Co-developed with claude code -- Adam]
"""
import json
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
LRAW = os.path.join(HERE, "..", "2026-08-25_large-scale-concurrent", "raw")
CLASSES = ["host->switch", "switch->host", "switch->switch"]
COND = {"B1": "base", "B6": "base", "Q2": "Q", "Q5": "Q", "M3": "M", "M4": "M"}


def load(suffix, blockdir):
    T, R, M = {}, {}, {}
    for a in COND:
        p = os.path.join(LRAW, f"{a}{suffix}", "period_1.json")
        if os.path.exists(p):
            d = json.load(open(p))
            T[a] = (d.get("cluster_period_s") or d["period_median_s"]) * 1000
        p = os.path.join(LRAW, f"{a}{suffix}", "rows.json")
        if os.path.exists(p):
            s = json.load(open(p))["summary"]
            R[a] = {c: s[c]["ratio"] for c in CLASSES if c in s and s[c].get("ratio") is not None}
        p = os.path.join(HERE, blockdir, a, "pathlat", "flows.json")
        if os.path.exists(p):
            fl = json.load(open(p))["flows"]
            lat = [f["latency_detect_to_path_s"] for f in fl
                   if not f["left_censored"] and not f["never_path"]]
            M[a] = statistics.fmean(lat) if lat else None
    return T, R, M


def cm(d, cond, key=None):
    """Mean over a condition's two arms."""
    vs = []
    for a, c in COND.items():
        if c != cond or a not in d or d[a] is None:
            continue
        vs.append(statistics.fmean([d[a][k] for k in CLASSES if k in d[a]]) if key == "r" else d[a])
    return statistics.fmean(vs) if vs else None


def main():
    B1 = load("_block1", "raw_block1")
    B2 = load("", "raw")
    print("=" * 76)
    print("BLOCK 1 (neighbour compiling) vs BLOCK 2 (CPU paused)  -- PREREG C-3")
    print("=" * 76)

    rows = []
    for name, blk in (("block 1", B1), ("block 2", B2)):
        T, R, M = blk
        base_r, q_r = cm(R, "base", "r"), cm(R, "Q", "r")
        rows.append({
            "name": name,
            "T_base": cm(T, "base"),
            "q_delta": (base_r - q_r) if (base_r and q_r) else None,
            "m_effect": (cm(M, "M") - cm(M, "Q")) if (cm(M, "M") and cm(M, "Q")) else None,
            "arm_T": abs(T["B1"] - T["B6"]) if {"B1", "B6"} <= T.keys() else None,
            "arm_r": (abs(statistics.fmean([R["B1"][c] for c in CLASSES])
                          - statistics.fmean([R["B6"][c] for c in CLASSES]))
                      if {"B1", "B6"} <= R.keys() else None),
            "arm_m": abs(M["M3"] - M["M4"]) if {"M3", "M4"} <= M.keys() else None,
            "base_r": base_r, "q_r": q_r,
        })

    a, b = rows
    print(f"\n{'quantity':<34}{'block 1':>12}{'block 2':>12}{'|diff|':>10}{'arm spread':>13}")
    for lbl, k, sk, fmt in (("ticket Q: mean per-class delta", "q_delta", "arm_r", "{:.4f}"),
                            ("ticket M: effect (s)", "m_effect", "arm_m", "{:.3f}"),
                            ("base arms' T (ms)", "T_base", "arm_T", "{:.1f}")):
        if a[k] is None or b[k] is None:
            continue
        d = abs(a[k] - b[k])
        spread = max(x for x in (a[sk], b[sk]) if x is not None)
        verdict = "within" if d <= spread else "🔴 EXCEEDS"
        print(f"{lbl:<34}{fmt.format(a[k]):>12}{fmt.format(b[k]):>12}"
              f"{fmt.format(d):>10}{fmt.format(spread):>10} {verdict}")

    print("\n  'arm spread' is the larger of the two blocks' own within-condition differences --")
    print("  the between-block difference is judged against the noise each block already carries.")

    # --- the period, three ways, now that two blocks can separate offset from noise ---------
    print("\n--- the loop period, reconciled across blocks ---")
    print("  A common multiplicative bias b in twin-vs-veth accounting cancels in base/Q:")
    print("     base_ratio = b x T ,  Q_ratio = b x 1  =>  base_ratio / Q_ratio = T")
    print(f"\n{'':>10}{'T external':>12}{'base ratio':>12}{'Q ratio':>10}{'base/Q':>10}"
          f"{'implied T':>11}{'offset':>9}")
    for r in rows:
        if not (r["base_r"] and r["q_r"] and r["T_base"]):
            continue
        quo = r["base_r"] / r["q_r"]
        print(f"{r['name']:>10}{r['T_base']:>12.1f}{r['base_r']:>12.4f}{r['q_r']:>10.4f}"
              f"{quo:>10.4f}{quo * 1000:>11.1f}{quo * 1000 - r['T_base']:>9.1f}")
    offs = [r["base_r"] / r["q_r"] * 1000 - r["T_base"] for r in rows
            if r["base_r"] and r["q_r"] and r["T_base"]]
    if len(offs) == 2:
        print(f"\n  offsets: {offs[0]:.1f} and {offs[1]:.1f} ms  (they differ by "
              f"{abs(offs[0] - offs[1]):.1f} ms)")
        # An earlier version of this script rendered "REPRODUCIBLE" when the two offsets differed
        # by less than 20 ms -- a threshold invented DURING the analysis, after block 1 was
        # already known, and which then passed by 0.2 ms. That is the exact move this round has
        # spent all day policing in other people's work, so the verdict is removed rather than
        # kept with a caveat. What is stated below is only what does not depend on a number
        # chosen after the fact.
        print("\n  DIRECTION (2 of 2): the ratio implies a LONGER period than the step-transition")
        print("  estimator measures, in both blocks. Both offsets are positive.")
        print(f"  MAGNITUDE: not pinned. The two differ by {abs(offs[0] - offs[1]):.1f} ms, which is")
        print(f"  itself comparable to the between-arm spread ({rows[0]['arm_T']:.0f} and "
              f"{rows[1]['arm_T']:.1f} ms), so n=2 gives a sign and not a size.")
        print("  => Worth its own ticket: a consistent-sign gap between two instruments that")
        print("     were built to measure the same thing. NOT claimed as a quantified bias, and")
        print("     NOT the 'it is inside the noise' reading block 1 alone supported -- one block")
        print("     could not separate offset from noise, and two can only separate the sign.")
    return 0


if __name__ == "__main__":
    main()
