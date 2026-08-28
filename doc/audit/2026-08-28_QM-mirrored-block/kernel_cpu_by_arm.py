#!/usr/bin/env python3
"""Ticket M's BENEFIT: what does dropping calFlowPathByQueried from 1 kHz to 1 Hz save in CPU?

🔴 THIS IS POST-HOC. Unlike the ratio and the path latency, no interval was registered for it
before the data existed. It is reported at lower strength than Q's and M's primary quantities and
must be labelled that way wherever it appears. What makes it worth computing at all is that the
mirrored layout balances position across conditions, so the comparison is not confounded with
drift even though nobody planned it.

WHAT THE FIELD ACTUALLY IS -- checked, not assumed. sample_load.py reads utime and stime from
/proc/<kpid>/stat where kpid comes from `pgrep -x ndtwin_kernel`, so it is the KERNEL PROCESS's
own CPU, not the machine's. That distinction is the whole analysis: machine CPU here is ~87%
saturated by fabric, churn and a neighbour VM, and reporting it as the kernel's would be a
fabrication. (An hour ago a sibling session inferred "the data exists" from "the endpoint
exists" and was wrong; the auditor asked for this to be verified rather than assumed, and it was.)

WHY EACH ARM STARTS FROM ZERO. Every arm restarts the kernel, so utime/stime are cumulative for a
process that began at the start of that arm. The delta across the arm is therefore the whole of
that arm's kernel CPU, with no cross-arm contamination -- the one thing a restart usually costs
us, here it buys us.

WHY base AND Q MAY NOT BE POOLED WITHOUT A CHECK. Q2/Q5 run ab2d7ed1, which carries ticket Q's
rate-denominator fix but leaves the path recompute at 1 kHz, so they sit on the 1 kHz side with
the base arms and would give a 4-vs-2 comparison instead of 2-vs-2. That is only legitimate if
Q's fix does not itself move CPU. This script tests base-vs-Q FIRST and refuses to pool if they
differ by more than the within-condition spread.

Usage: kernel_cpu_by_arm.py <L_raw_dir_suffix>     e.g. "" for the live block, "_block1"
[Co-developed with claude code -- Adam]
"""
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LDIR = os.path.join(HERE, "..", "2026-08-25_large-scale-concurrent", "raw")
ARMS = ["B1", "Q2", "M3", "M4", "Q5", "B6"]
COND = {"B1": "base", "B6": "base", "Q2": "Q", "Q5": "Q", "M3": "M", "M4": "M"}
KHZ = ["B1", "Q2", "Q5", "B6"]          # 1 kHz path recompute
HZ1 = ["M3", "M4"]                       # 1 Hz


def arm_cpu(label, suffix):
    p = os.path.join(LDIR, f"{label}{suffix}", "load.jsonl")
    if not os.path.exists(p):
        return None
    rows = []
    for line in open(p):
        try:
            r = json.loads(line)
        except Exception:
            continue
        if "kernel_utime" in r and "kernel_stime" in r:
            rows.append(r)
    if len(rows) < 3:
        return None
    hz = rows[0].get("clk_tck", 100)
    # Guard against a mid-arm kernel restart: utime is cumulative per process, so a restart makes
    # it go DOWN. Silently differencing across that would report a negative or absurd value.
    jif = [r["kernel_utime"] + r["kernel_stime"] for r in rows]
    if any(b < a for a, b in zip(jif, jif[1:])):
        return {"label": label, "restarted": True}
    cpu_s = (jif[-1] - jif[0]) / hz
    wall = rows[-1]["t"] - rows[0]["t"]
    return {"label": label, "restarted": False, "cpu_s": cpu_s, "wall_s": wall,
            "cores": cpu_s / wall, "threads": rows[-1].get("kernel_threads"),
            "n": len(rows)}


def main():
    suffix = sys.argv[1] if len(sys.argv) > 1 else ""
    A = {a: arm_cpu(a, suffix) for a in ARMS}
    print("=" * 74)
    print(f"KERNEL PROCESS CPU BY ARM  (suffix='{suffix}')   🔴 POST-HOC, NOT PRE-REGISTERED")
    print("=" * 74)
    print(f"\n{'arm':<5}{'cond':<6}{'kHz':<5}{'cpu (s)':>10}{'wall (s)':>10}{'cores':>8}{'threads':>9}")
    ok = {}
    for a in ARMS:
        d = A[a]
        if not d:
            print(f"{a:<5}{COND[a]:<6}{'--':>5}")
            continue
        if d.get("restarted"):
            print(f"{a:<5}{COND[a]:<6}  🔴 kernel restarted mid-arm -- excluded")
            continue
        ok[a] = d
        print(f"{a:<5}{COND[a]:<6}{'1k' if a in KHZ else '1':<5}{d['cpu_s']:>10.1f}"
              f"{d['wall_s']:>10.1f}{d['cores']:>8.3f}{str(d['threads']):>9}")

    def m(labels, k="cores"):
        v = [ok[a][k] for a in labels if a in ok]
        return statistics.fmean(v) if v else None

    # --- the pooling precondition, checked before it is used -----------------------------
    print("\n--- may base and Q be pooled as one 1 kHz group? (auditor's precondition) ---")
    b, q = m(["B1", "B6"]), m(["Q2", "Q5"])
    if b is None or q is None:
        print("  both conditions not yet complete")
        return 0
    within = max(abs(ok["B1"]["cores"] - ok["B6"]["cores"]) if {"B1", "B6"} <= ok.keys() else 0,
                 abs(ok["Q2"]["cores"] - ok["Q5"]["cores"]) if {"Q2", "Q5"} <= ok.keys() else 0)
    print(f"  base {b:.3f} cores   Q {q:.3f} cores   |diff| {abs(b - q):.3f}   "
          f"largest within-condition spread {within:.3f}")
    poolable = abs(b - q) <= within
    print("  => " + ("POOL: Q's fix does not move CPU beyond the within-condition spread"
                     if poolable else
                     "🔴 DO NOT POOL: Q's fix moves CPU on its own. Use base-vs-M at 2v2 and say so."))

    khz_arms = KHZ if poolable else ["B1", "B6"]
    khz, hz = m(khz_arms), m(HZ1)
    if khz is None or hz is None:
        print("\n  1 Hz arms not yet complete")
        return 0
    print(f"\n--- ticket M's BENEFIT: 1 kHz vs 1 Hz path recompute ---")
    print(f"  1 kHz ({'+'.join(khz_arms)}): {khz:.3f} cores")
    print(f"  1 Hz  ({'+'.join(HZ1)}): {hz:.3f} cores")
    print(f"  saved: {khz - hz:+.3f} cores  =  {(khz - hz) / khz * 100:+.1f}% of the kernel's CPU")
    print(f"\n  ⚠️  This is the kernel PROCESS's CPU. It already excludes the fabric, the churn "
          f"generator\n      and the pollers, which is why no common baseline has to be "
          f"subtracted here --\n      the process boundary does that subtraction.")
    print(f"  🔴 POST-HOC: no interval was registered for this before the data. Lower strength "
          f"than\n      Q's ratio and M's latency, both of which were.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
