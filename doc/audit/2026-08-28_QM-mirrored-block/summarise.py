#!/usr/bin/env python3
"""Fill in PREREG section 9's read-out table from whatever arms have finished.

Written BEFORE the first arm, and it applies the pre-registered rules rather than inventing
thresholds once the numbers are visible:

  * drift gate      |T(base1) - T(base6)| <= 90 ms         (PREREG 3-1)
  * ratio drift     |dratio(base)| < half the base<->Q effect (PREREG 3-2)
  * Q's power       base T >= 1020 ms, else INCONCLUSIVE-BY-DESIGN, never "no effect" (PREREG 4)
  * M censoring     never_path with watch_s < 3 s is right-censored and leaves the denominator;
                    a flow present on the first poll is left-censored and leaves M's effect
  * linearity       the 5:3:1 diagnostic, printed, explicitly not a gate (PREREG 1-bis)

Runs on a partial block on purpose: it is called after every arm so a usage cutoff or a dead
session leaves a readable table behind rather than six directories of raw.

Usage: summarise.py <raw_dir>
[Co-developed with claude code -- Adam]
"""
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LDIR = os.path.join(HERE, "..", "2026-08-25_large-scale-concurrent")
ARM_ORDER = ["B1", "Q2", "M3", "M4", "Q5", "B6"]
COND = {"B1": "base", "B6": "base", "Q2": "Q", "Q5": "Q", "M3": "M", "M4": "M"}
CLASSES = ["host->switch", "switch->host", "switch->switch"]
RIGHT_CENSOR_S = 3.0          # PREREG 5-M, fixed before any data


def load_T(label):
    """Loop period in ms for one arm, from the external step-transition estimator."""
    p = os.path.join(LDIR, "raw", label, "period_1.json")
    if not os.path.exists(p):
        return None
    d = json.load(open(p))
    v = d.get("cluster_period_s") or d.get("period_median_s")
    return None if v is None else v * 1000.0


def load_ratio(label):
    """Twin-reported bytes / veth bytes, per edge class, over the pre-registered window."""
    adir = os.path.join(LDIR, "raw", label)
    meta_p, rows_p = os.path.join(adir, "meta.json"), os.path.join(adir, "rows.json")
    if not os.path.exists(meta_p):
        return None
    if not os.path.exists(rows_p):
        m = json.load(open(meta_p))
        subprocess.run([sys.executable, os.path.join(LDIR, "analyze.py"), "--dir", adir,
                        "--window", f"{m['window_lo']},{m['window_hi']}", "--json", rows_p],
                       capture_output=True, text=True)
    if not os.path.exists(rows_p):
        return None
    s = json.load(open(rows_p))["summary"]
    return {c: s[c]["ratio"] for c in CLASSES if c in s and s[c].get("ratio") is not None}


def load_M(raw, label):
    """Per-flow detection and path latencies, with the pre-registered censoring applied."""
    p = os.path.join(raw, label, "pathlat", "flows.json")
    if not os.path.exists(p):
        return None
    d = json.load(open(p))
    lat, never, right_cens, left_cens = [], 0, 0, 0
    for f in d["flows"]:
        if f["left_censored"]:
            left_cens += 1
            continue                      # birth may predate the sampler: bounds only, no effect
        if f["never_path"]:
            if f["watch_s"] < RIGHT_CENSOR_S:
                right_cens += 1           # the run ended, not the path
            else:
                never += 1
            continue
        lat.append(f["latency_detect_to_path_s"])
    return {"n": len(lat), "lat": sorted(lat), "never": never,
            "right_censored": right_cens, "left_censored": left_cens,
            "summary": d["summary"]}


def pct(xs, p):
    return None if not xs else xs[min(len(xs) - 1, int(p * len(xs)))]


def fmt(v, n=1, unit=""):
    return "     --" if v is None else f"{v:.{n}f}{unit}"


def main():
    raw = sys.argv[1]
    T = {a: load_T(a) for a in ARM_ORDER}
    R = {a: load_ratio(a) for a in ARM_ORDER}
    Mx = {a: load_M(raw, a) for a in ARM_ORDER}
    have = [a for a in ARM_ORDER if T[a] is not None or Mx[a] is not None]

    print("=" * 78)
    print("READ-OUT -- PREREG section 9. Arms present: " + (", ".join(have) or "none yet"))
    print("=" * 78)

    print(f"\n{'arm':<5}{'cond':<6}{'T (ms)':>9}" + "".join(f"{c:>16}" for c in CLASSES)
          + f"{'M lat (s)':>11}{'never':>7}")
    for a in ARM_ORDER:
        r, m = R[a] or {}, Mx[a]
        med = pct(m["lat"], 0.5) if m and m["lat"] else None
        print(f"{a:<5}{COND[a]:<6}{fmt(T[a]):>9}"
              + "".join(f"{fmt(r.get(c), 4):>16}" for c in CLASSES)
              + f"{fmt(med, 3):>11}{(m['never'] if m else '--'):>7}")

    # --- PREREG 3-1: the drift gate --------------------------------------------------------
    print("\n--- drift meter (base arms at positions 1 and 6) ---")
    if T["B1"] is not None and T["B6"] is not None:
        d = abs(T["B1"] - T["B6"])
        v = "PASS" if d <= 90 else "🔴 BLOCK VOID for T (PREREG 3-3: rerun once, new generation)"
        print(f"  |T(B1) - T(B6)| = {d:.1f} ms  (gate 90 ms)  => {v}")
        print(f"  third same-generation measurement of the quiet between-arm spread "
              f"(prior: 27.2, 41.6 ms)")
    else:
        print("  both base arms not yet run")

    # --- PREREG 4: is Q even measurable in this generation? --------------------------------
    print("\n--- ticket Q ---")
    bT = [T[a] for a in ("B1", "B6") if T[a] is not None]
    label = None
    if bT:
        mT = statistics.fmean(bT)
        label = ("powered" if mT >= 1020 else
                 "🔴 INCONCLUSIVE-BY-DESIGN" if mT >= 1000 else
                 "🔴 PREMISE REFUTED (loop faster than 1 s)")
        print(f"  base T = {mT:.1f} ms over {len(bT)} arm(s)  =>  predicted over-report "
              f"{(mT/1000 - 1) * 100:+.1f}%  =>  {label}")
        if label.startswith("🔴 INCONCLUSIVE"):
            print("  ⚠️  effect < 2%: this block cannot resolve it. This is NOT 'Q has no effect'.")

    # Primary: the per-class difference, then averaged. Class-specific bias (the three classes
    # sit at different ratios under one T) cancels in the difference; the denominator effect
    # does not, because it is common to all three.
    def cond_ratio(cond, c):
        vs = [R[a][c] for a in ARM_ORDER if COND[a] == cond and R[a] and c in R[a]]
        return statistics.fmean(vs) if vs else None

    deltas = []
    for c in CLASSES:
        b, q = cond_ratio("base", c), cond_ratio("Q", c)
        if b is not None and q is not None:
            deltas.append(b - q)
            print(f"  {c:<16} base {b:.4f}  Q {q:.4f}  delta {b - q:+.4f}")
    if deltas:
        eff = statistics.fmean(deltas)
        print(f"  PRIMARY: mean per-class delta = {eff:+.4f}  "
              f"(predicted ~{(statistics.fmean(bT)/1000 - 1) if bT else 0:+.4f} from T)")
        # PREREG 3-2: the ratio drift gate is relative to the effect, because the between-arm
        # ratio spread has never been measured and must not be back-filled with a plausible number.
        drift = [abs(R["B1"][c] - R["B6"][c]) for c in CLASSES
                 if R["B1"] and R["B6"] and c in R["B1"] and c in R["B6"]]
        if drift:
            dm = statistics.fmean(drift)
            ok = dm < abs(eff) / 2 if eff else False
            print(f"  ratio drift |B1-B6| = {dm:.4f} vs half-effect {abs(eff)/2:.4f}  =>  "
                  + ("PASS" if ok else "🔴 Q RATIO READ-OUT VOID"))
            print(f"  (first measurement of the between-arm ratio spread: {dm:.4f}, n=1 difference)")

    # --- PREREG 5-M ------------------------------------------------------------------------
    print("\n--- ticket M (t_first_path - t_first_seen) ---")
    for cond in ("Q", "M"):
        lats, never, rc, lc = [], 0, 0, 0
        for a in ARM_ORDER:
            if COND[a] != cond or not Mx[a]:
                continue
            lats += Mx[a]["lat"]; never += Mx[a]["never"]
            rc += Mx[a]["right_censored"]; lc += Mx[a]["left_censored"]
        if not lats and not never:
            print(f"  {cond:<5} no arm yet")
            continue
        lats.sort()
        arms = [a for a in ARM_ORDER if COND[a] == cond and Mx[a]]
        print(f"  {cond:<5} n={len(lats):<4} mean {fmt(statistics.fmean(lats) if lats else None, 3)}s"
              f"  median {fmt(pct(lats, 0.5), 3)}s  p95 {fmt(pct(lats, 0.95), 3)}s"
              f"  never {never}  (right-censored {rc}, left-censored {lc} excluded)  arms={arms}")
    qs = [x for a in ARM_ORDER if COND[a] == "Q" and Mx[a] for x in Mx[a]["lat"]]
    ms = [x for a in ARM_ORDER if COND[a] == "M" and Mx[a] for x in Mx[a]["lat"]]
    if qs and ms:
        eff = statistics.fmean(ms) - statistics.fmean(qs)
        verdict = ("in the registered 0.4-0.6 s band" if 0.4 <= eff <= 0.6 else
                   "🔴 ~0: path is written somewhere other than the path pass -- find the second writer"
                   if eff < 0.1 else
                   "🔴 > 1.0 s: the recompute loop's real period is not 1 s (sleep_for, not "
                   "sleep_until) -- same shape as ticket Q" if eff > 1.0 else
                   "outside every registered branch: record as its own result, do not round to "
                   "the nearest branch")
        print(f"  EFFECT (M - Q) = {eff:+.3f} s  =>  {verdict}")

    # --- PREREG 1-bis: linearity diagnostic, not a gate -------------------------------------
    print("\n--- linearity diagnostic (5:3:1), PREREG 1-bis: NOT a gate ---")
    pairs = [("base", "B1", "B6", 5), ("Q", "Q2", "Q5", 3), ("M", "M3", "M4", 1)]
    seen = [(c, T[x] - T[y], sep) for c, x, y, sep in pairs
            if T[x] is not None and T[y] is not None]
    for c, d, sep in seen:
        print(f"  {c:<5} separation {sep}  within-condition T difference {d:+.1f} ms"
              f"  => implied slope {d / sep:+.1f} ms/position")
    if len(seen) == 3:
        print("  each difference carries ~43 ms of arm noise, so only a GROSS violation "
              "(e.g. M's difference largest) is readable here.")

    # --- detection latency: reported, never judged (no prior, so no interval) ---------------
    print("\n--- detection latency (twin first sees a flow) -- never measured before, reported only ---")
    for a in ARM_ORDER:
        if not Mx[a]:
            continue
        s = Mx[a]["summary"]
        print(f"  {a:<5} flows {s['n_flows_seen']:<5} polls {s['n_polls']} "
              f"({s['n_polls_failed']} failed)  achieved gap median {s['achieved_gap_median_s']}s "
              f"p95 {s['achieved_gap_p95_s']}s max {s['achieved_gap_max_s']}s")
    pb = os.path.join(raw, "pollbase", "flows.json")
    if os.path.exists(pb):
        s = json.load(open(pb))["summary"]
        print(f"  IDLE BASELINE (no traffic): gap median {s['achieved_gap_median_s']}s "
              f"p95 {s['achieved_gap_p95_s']}s max {s['achieved_gap_max_s']}s, "
              f"{s['n_polls_failed']}/{s['n_polls']} failed")
        print("  => compare against the arms above: if the arms are slower, the 10 Hz poller is "
              "contending with the workload on a northbound API that serves one request at a time.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
