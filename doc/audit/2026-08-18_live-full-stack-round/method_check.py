"""Does the round-2 harness manufacture a bias on data we independently know is unbiased?

F-10 (OVS, twin/gt ~1.17) and F-18 (P4, ~0.79) were both measured with scratch/lab/tel.py.
Rather than re-run NTG and argue about the result, apply tel.py's *exact* method to the
clean run -- where the corrected method gives 1.00 across every window -- and see what it
reports. Any departure from 1.0 here is manufactured by the method, because the underlying
data has no bias left in it to find.

tel.py's method, reproduced element by element:
  * twin  = a single instantaneous read at the end of the window (no integration)
  * gt    = tx_bytes delta over the whole window / dt
  * window= 25 s
  * gt set= interfaces matching eth1..eth4 AND carrying >100 kbps
  * twin  = sum over all switch-to-switch edges

[Co-developed with claude code -- Adam]
"""
import json, sys, statistics as st

rows = [json.loads(l) for l in open(sys.argv[1]) if "error" not in l]
HZ = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
SS = set(rows[0]["twin"].keys())


def report(label, window_s, integrate, gt_keys, gt_floor):
    step = max(1, int(round(window_s * HZ)))
    ratios = []
    i = 0
    while i + step < len(rows):
        a, b = i, i + step
        dt = rows[b]["t"] - rows[a]["t"]
        if integrate:
            num = den = 0.0
            for j in range(a, b):
                d = rows[j + 1]["t"] - rows[j]["t"]
                num += sum(rows[j]["twin"].values()) * d
                den += d
            twin = num / den
        else:
            twin = sum(rows[b]["twin"].values())          # single instantaneous read
        tot = 0
        for k in rows[a]["tx"]:
            if k not in gt_keys(k):
                continue
            d = rows[b]["tx"][k] - rows[a]["tx"][k]
            if d * 8 / dt > gt_floor:
                tot += d
        gt = tot * 8 / dt
        if gt > 1e6:
            ratios.append(twin / gt)
        i += step
    if len(ratios) < 2:
        print(f"{label:<46} (too few windows: {len(ratios)})")
        return
    print(f"{label:<46} n={len(ratios):>3}  median={st.median(ratios):.3f}  "
          f"min={min(ratios):.3f}  max={max(ratios):.3f}")


eth4 = lambda k: {k} if int(k.split("-eth")[1]) <= 4 else set()
ss = lambda k: {k} if k in SS else set()

print("Applying each method to the SAME clean data (true answer = 1.000)\n")
report("tel.py as written (25 s, instant, eth<=4, >100k)", 25, False, eth4, 100000)
report("  ... but integrating the twin over the window", 25, True, eth4, 100000)
report("  ... but using the real switch-to-switch set", 25, False, ss, 100000)
report("  ... both fixes together", 25, True, ss, 100000)
print()
report("corrected method at 10 s", 10, True, ss, 0)
report("corrected method at 25 s", 25, True, ss, 0)
