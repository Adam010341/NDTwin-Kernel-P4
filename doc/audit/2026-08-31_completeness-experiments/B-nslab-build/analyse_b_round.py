#!/usr/bin/env python3
"""PREREG-B — apply the frozen decision rules to the eight arms.  Nothing here decides
anything: every rule is transcribed from PREREG-B-nslab-build.md sections 3 (R-B1a, R-B1b,
R-B2, R-B3), which were frozen before any build existed.

[Co-developed with claude code -- Adam]

🔴 The one thing this file must not do is invent a rule for a case the prereg did not
anticipate.  Where the arms land somewhere the rules do not cover, it says so and stops,
because "the rule did not foresee this" and "the answer is inconclusive" are different
statements and only one of them is honest.

Usage: analyse_b_round.py [suite]     (suite defaults to 'b'; 'c' is the P4-program round)
"""
import json
import os
import sys

ROOT = os.path.expanduser("~/bnslab-B")
SUITE = sys.argv[1] if len(sys.argv) > 1 else "b"

# The registered ladder, plus the ×1.5-to-2sf extension. Needed to turn a rung reading
# into the interval it stands for: a reading of X means the true zero-loss point is
# somewhere in [X, next rung) -- the ladder cannot see inside a step.
BASE = [1, 2, 3, 5, 8, 12, 20, 30, 45, 70, 110, 160, 240, 360]


def next_rung(p):
    v = p * 1.5
    e = len(str(int(v))) - 1
    s = 10 ** (e - 1)
    return int(v / s + 0.5) * s


def ladder(n=30):
    out = list(BASE)
    while len(out) < n:
        out.append(next_rung(out[-1]))
    return out


LADDER = ladder()


def interval(x):
    """[X, next rung) -- the quantisation interval a rung reading stands for."""
    i = LADDER.index(x)
    return (float(x), float(LADDER[i + 1]))


def read_arm(label):
    p = os.path.join(ROOT, "raw", label, "arm.meta")
    if not os.path.exists(p):
        return None
    d = {}
    for line in open(p):
        if "=" in line:
            k, _, v = line.strip().partition("=")
            d.setdefault(k, v)
    return d


arms = {}
for a in "ABCD":
    for r in (1, 2):
        lbl = f"{SUITE}_{a}{r}"
        m = read_arm(lbl)
        if m:
            arms[f"{a}{r}"] = m

print(f"=== PREREG-B decision rules, suite={SUITE} ===\n")
print(f"  {'arm':<5} {'rung':<8} {'stop_reason':<22} {'binary sha16':<18} {'gate':<8}")
for k in sorted(arms):
    m = arms[k]
    print(f"  {k:<5} {m.get('highest_clean_rung_mbit','?'):<8} "
          f"{m.get('ladder_stop_reason','?'):<22} "
          f"{m.get('binary_sha256','?')[:16]:<18} {m.get('sender_gate_mbit','?'):<8}")

missing = [f"{a}{r}" for a in "ABCD" for r in (1, 2) if f"{a}{r}" not in arms]
if missing:
    print(f"\n🔴 arms missing: {missing} -- rules below are NOT evaluated on a partial round.")
    sys.exit(1)

# ---- F1 falsifiability: four distinct binaries, each appearing exactly twice ------------
shas = {}
for k, m in arms.items():
    shas.setdefault(m.get("binary_sha256", "?"), []).append(k)
print(f"\n--- F1: distinct binaries across the eight arms: {len(shas)} (want 4) ---")
for s, ks in sorted(shas.items(), key=lambda kv: sorted(kv[1])):
    print(f"    {s[:16]}  {sorted(ks)}")
if len(shas) != 4 or any(len(v) != 2 for v in shas.values()):
    print("🔴 F1 FAILED: the arms did not run four binaries two apiece. Every identity")
    print("   record would still read correctly if one binary had run throughout -- that")
    print("   is exactly what this check exists to falsify.")
    sys.exit(1)
print("    ✅ four binaries, two arms each.")


def readings(a):
    return [int(arms[f"{a}{r}"]["highest_clean_rung_mbit"]) for r in (1, 2)]


def strictly_above(hi, lo):
    """Both `hi` arms strictly above both `lo` arms -- the registered ordering test."""
    return min(readings(hi)) > max(readings(lo))


def widest(a):
    """Conservative interval for an arm: if its two replicates land on different rungs,
    take the WIDER pair of endpoints (PREREG-B section 3, R-B3 parenthesis)."""
    ivs = [interval(x) for x in readings(a)]
    return (min(i[0] for i in ivs), max(i[1] for i in ivs))


print("\n--- R-B2: does the build confound exist on machine 2? (D vs A) ---")
print(f"    A arms {readings('A')}   D arms {readings('D')}")
if strictly_above("D", "A"):
    print("    ✅ CONFOUND EXISTS on machine 2: both D arms strictly above both A arms.")
    print(f"    rung gap: A at {readings('A')} -> D at {readings('D')}")
    print("    🔑 Reported as a rung gap only. PREREG-B forbids converting this to a")
    print("       ratio here, and forbids comparing it to machine 1's ratio.")
elif strictly_above("A", "D"):
    print("    🔴 REVERSED: both A arms strictly above both D arms. Registered as")
    print("       publishable in this direction too. Report it.")
else:
    print("    ⇒ INDISTINGUISHABLE at rung resolution (the arms interleave).")

for hi, lo, name in (("D", "C", "R-B1a  self-added flags (D vs C)"),
                     ("B", "A", "R-B1b  project default vs p4-guide (B vs A)"),
                     ("C", "B", "R-B1b  documented flags vs default (C vs B)")):
    print(f"\n--- {name} ---")
    print(f"    {lo} arms {readings(lo)}   {hi} arms {readings(hi)}")
    if strictly_above(hi, lo):
        print(f"    ⇒ {hi} strictly faster: buys >=1 rung.")
    elif strictly_above(lo, hi):
        print(f"    ⇒ 🔴 {lo} strictly faster -- the change made it SLOWER. Registered in")
        print("       this direction too; publish it.")
    else:
        print("    ⇒ INDISTINGUISHABLE at rung resolution.")
        if name.startswith("R-B1a"):
            print("       This reads study 1's hedge conservatively: self-added flags <=1 rung.")

print("\n--- R-B3: are the two machines' quantisation intervals compatible? ---")
M1 = (360 / 70, 540 / 45)          # machine 1, verbatim from FINDINGS-1b.md:64-69
a_lo, a_hi = widest("A")
d_lo, d_hi = widest("D")
R2 = (d_lo / a_hi, d_hi / a_lo)
print(f"    machine 1: R1 = (360/70, 540/45) = ({M1[0]:.2f}, {M1[1]:.2f})")
print(f"    machine 2: A in [{a_lo:.0f}, {a_hi:.0f})  D in [{d_lo:.0f}, {d_hi:.0f})")
print(f"               R2 = ({R2[0]:.2f}, {R2[1]:.2f})")
if M1[0] < R2[1] and R2[0] < M1[1]:
    print("    ✅ COMPATIBLE: the open intervals intersect.")
    print("       ⇒ machine 1's 8.0 is NOT shown to be an artefact of that dirty host.")
    print("       🔑 Compatible is not equal. Intersection rules out ONE hypothesis; it")
    print("          supports no claim that the two machines measured the same number.")
else:
    print("    🔴 INCOMPATIBLE: the intervals do not intersect.")
    print("       ⇒ the ratio itself changes with the machine. This is a finding in its")
    print("          own right -- not a failure, and not machine 2's fault.")

print("\n--- sender gate: was any arm's reading censored by the generator? ---")
for k in sorted(arms):
    g = float(arms[k].get("sender_gate_mbit", -1))
    x = int(arms[k]["highest_clean_rung_mbit"])
    print(f"    {k}: rung {x:>5} M vs gate {g:>8.0f} M  -> "
          f"{'🔴 within 5x of the gate' if g < 5 * x else f'ok ({g/x:.0f}x headroom)'}")

json.dump({k: v for k, v in arms.items()},
          open(os.path.join(ROOT, "raw", f"{SUITE}_arms_summary.json"), "w"), indent=2)
print(f"\n(summary written to raw/{SUITE}_arms_summary.json)")
