#!/usr/bin/env python3
"""PREREG amendment A: did a load STEP land unevenly across the six arms?

The mirrored layout cancels LINEAR drift exactly. It gives no protection at all against a step --
a neighbour VM starting or finishing a compile -- and today's host is running two qemu guests with
4 G available and 8 G of swap already in use, so steps are the expected shape rather than a
hypothetical one.

WHAT THIS IS ALLOWED TO USE. Only fields sample_load.py has recorded identically on ALL SIX arms
since before the block started: loadavg and /proc/stat. host_mem.jsonl was started mid-block and
covers arms 3-6 only; a signal present for four arms and absent for two cannot adjudicate the
comparison between them, so it appears here strictly as explanation AFTER a step has been found,
never as the thing that finds one.

THE THRESHOLDS WERE COMMITTED IN f2d43c7 WHILE FOUR ARMS WERE STILL UNRUN, and no load.jsonl had
been opened. They are not editable in the light of the result -- that is the entire point of
having written them down.

Usage: check_load_steps.py <raw_dir>
[Co-developed with claude code -- Adam]
"""
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LDIR = os.path.join(HERE, "..", "2026-08-25_large-scale-concurrent")
ARM_ORDER = ["B1", "Q2", "M3", "M4", "Q5", "B6"]
COND = {"B1": "base", "B6": "base", "Q2": "Q", "Q5": "Q", "M3": "M", "M4": "M"}

VOID_BUSY, VOID_L1 = 0.10, 3.0        # PREREG A-3, committed before the data
DOWNGRADE_BUSY = 0.05
WITHIN_STEP_BUSY = 0.10


def busy_series(rows):
    """Non-idle CPU fraction between consecutive samples, from the aggregate `cpu` line.

    Deltas, not levels: /proc/stat holds cumulative jiffies since boot, so a level would be an
    average over three days of uptime and would be flat to four decimal places no matter what
    happened during the arm. iowait is counted as NOT busy -- a machine blocked on swap is not
    doing the twin's work, and lumping it into busy would make swap pressure look like CPU load.
    """
    out, prev = [], None
    for r in rows:
        st = r.get("stat")
        if not st:
            continue
        agg = next((s for s in st if s[0] == "cpu"), None)
        if not agg:
            continue
        v = [int(x) for x in agg[1:]]
        if prev is not None:
            d = [a - b for a, b in zip(v, prev)]
            tot = sum(d)
            if tot > 0:
                idle = d[3] + (d[4] if len(d) > 4 else 0)      # idle + iowait
                out.append((tot - idle) / tot)
        prev = v
    return out


def arm_load(label):
    p = os.path.join(LDIR, "raw", label, "load.jsonl")
    if not os.path.exists(p):
        return None
    rows = []
    for line in open(p):
        try:
            rows.append(json.loads(line))
        except Exception:
            pass
    if not rows:
        return None
    b = busy_series(rows)
    l1 = [float(r["loadavg"][0]) for r in rows if r.get("loadavg")]
    return {"n": len(rows), "busy": statistics.fmean(b) if b else None,
            "busy_min": min(b) if b else None, "busy_max": max(b) if b else None,
            "l1": statistics.fmean(l1) if l1 else None,
            "t0": rows[0]["t"], "t1": rows[-1]["t"]}


def main():
    raw = sys.argv[1]
    A = {a: arm_load(a) for a in ARM_ORDER}
    print("=" * 78)
    print("LOAD-STEP CHECK -- PREREG amendment A. Thresholds committed in f2d43c7, pre-data.")
    print("=" * 78)
    print(f"\n{'arm':<5}{'cond':<6}{'samples':>9}{'busy':>9}{'busy min':>10}{'busy max':>10}{'load1':>9}")
    for a in ARM_ORDER:
        d = A[a]
        if not d:
            print(f"{a:<5}{COND[a]:<6}{'--':>9}")
            continue
        print(f"{a:<5}{COND[a]:<6}{d['n']:>9}{d['busy']:>9.3f}{d['busy_min']:>10.3f}"
              f"{d['busy_max']:>10.3f}{d['l1']:>9.2f}")

    def cond_mean(c, k):
        vs = [A[a][k] for a in ARM_ORDER if COND[a] == c and A[a] and A[a][k] is not None]
        return statistics.fmean(vs) if vs else None

    print("\n--- per-comparison verdicts (PREREG A-3) ---")
    verdicts = {}
    for name, c1, c2 in (("ticket Q  base<->Q", "base", "Q"), ("ticket M  Q<->M", "Q", "M")):
        b1, b2 = cond_mean(c1, "busy"), cond_mean(c2, "busy")
        l1, l2 = cond_mean(c1, "l1"), cond_mean(c2, "l1")
        if None in (b1, b2, l1, l2):
            print(f"  {name:<20} incomplete -- not all arms have run")
            continue
        db, dl = abs(b1 - b2), abs(l1 - l2)
        if db > VOID_BUSY or dl > VOID_L1:
            v = "🔴 VOID -- the two sides differ in load context, so the difference is not " \
                "attributable to the binary (PREREG 3-3: rerun once, new generation)"
        elif db > DOWNGRADE_BUSY:
            v = "⚠️  DOWNGRADED -- report the effect and this load gap in the SAME sentence"
        else:
            v = "PASS"
        verdicts[name] = v
        print(f"  {name:<20} dbusy {db:.3f} (void>{VOID_BUSY}) dload1 {dl:.2f} "
              f"(void>{VOID_L1})  =>  {v}")

    print("\n--- within-condition step check (PREREG A-3) ---")
    for c in ("base", "Q", "M"):
        arms = [a for a in ARM_ORDER if COND[a] == c and A[a] and A[a]["busy"] is not None]
        if len(arms) < 2:
            print(f"  {c:<5} needs both arms")
            continue
        d = abs(A[arms[0]]["busy"] - A[arms[1]]["busy"])
        if d > WITHIN_STEP_BUSY:
            print(f"  {c:<5} {arms[0]} vs {arms[1]}: dbusy {d:.3f} > {WITHIN_STEP_BUSY}  =>  "
                  f"🔴 report this condition as a RANGE, not a mean. Averaging across a step is "
                  f"the operation that hides it.")
        else:
            print(f"  {c:<5} {arms[0]} vs {arms[1]}: dbusy {d:.3f}  =>  no step")

    # --- explanation only, and only for arms it actually covers -----------------------------
    hm = os.path.join(raw, "host_mem.jsonl")
    if os.path.exists(hm):
        rows = []
        for line in open(hm):
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
        if len(rows) > 1:
            print("\n--- host memory/swap: EXPLANATORY ONLY (started mid-block, covers arms 3-6) ---")
            print("  Never used to detect a step. Only to name the mechanism behind one the "
                  "uniform detector above already found.")
            av = [r.get("MemAvailable", 0) / 1e6 for r in rows if "MemAvailable" in r]
            sf = [(r.get("SwapTotal", 0) - r.get("SwapFree", 0)) / 1e6 for r in rows
                  if "SwapTotal" in r]
            swin = [r.get("pswpin", 0) for r in rows if "pswpin" in r]
            print(f"  MemAvailable {min(av):.1f}-{max(av):.1f} GB over {len(rows)} samples")
            print(f"  swap used    {min(sf):.1f}-{max(sf):.1f} GB")
            if len(swin) > 1:
                print(f"  pages swapped IN over the covered span: {swin[-1] - swin[0]:,}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
