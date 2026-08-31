#!/usr/bin/env python3
"""§C — does the stock-vs-fast build ratio depend on which P4 program is loaded?

Rule transcribed from PREREG-hardening-three-small-rounds.md §C.4, frozen before the
firewall.p4 arms ran:

    R_simple, R_complex = each program's own (D/A) quantisation interval, computed by
    PREREG-B's R-B3 algorithm.
      * intervals intersect      -> the build confound does NOT depend on the P4 program;
                                    study (1)'s scope widens.
      * intervals do not intersect -> the ratio is a function of the program; study (1)
                                    needs a "for this program" qualifier. Unfavourable to
                                    us, registered as publishable, report it.

🔴 Two things this must NOT be read as saying (PREREG §C.3b, recorded before data):
  1. The register path of firewall.p4 is guarded by hdr.tcp.isValid() and this ladder is
     UDP, so ZERO packets executed it. Nothing here bears on register cost.
  2. P_complex is not "more complex". Our own ndtwin_switch.p4 is the larger program
     (508 lines, ten clone references, per-packet sampling logic). The registered
     criterion is "different enough, and smaller is the stricter direction".

[Co-developed with claude code -- Adam]
"""
import os
import sys

ROOT = os.path.expanduser("~/bnslab-B")
BASE = [1, 2, 3, 5, 8, 12, 20, 30, 45, 70, 110, 160, 240, 360]


def next_rung(p):
    v = p * 1.5
    e = len(str(int(v))) - 1
    s = 10 ** (e - 1)
    return int(v / s + 0.5) * s


LADDER = list(BASE)
while len(LADDER) < 30:
    LADDER.append(next_rung(LADDER[-1]))


def rung_interval(x):
    i = LADDER.index(x)
    return (float(x), float(LADDER[i + 1]))


def reading(suite, arm, rep):
    p = os.path.join(ROOT, "raw", f"{suite}_{arm}{rep}", "arm.meta")
    if not os.path.exists(p):
        return None
    for line in open(p):
        if line.startswith("highest_clean_rung_mbit="):
            v = line.strip().split("=", 1)[1]
            return None if v == "NONE" else int(v)
    return None


def widest(suite, arm):
    """Conservative endpoints across an arm's two replicates."""
    vals = [reading(suite, arm, r) for r in (1, 2)]
    if any(v is None for v in vals):
        return None, vals
    ivs = [rung_interval(v) for v in vals]
    return (min(i[0] for i in ivs), max(i[1] for i in ivs)), vals


def ratio(suite, label):
    a, av = widest(suite, "A")
    d, dv = widest(suite, "D")
    if a is None or d is None:
        print(f"  🔴 {label}: missing arms  A={av}  D={dv}")
        return None
    R = (d[0] / a[1], d[1] / a[0])
    print(f"  {label:<26} A arms {av} -> [{a[0]:.0f}, {a[1]:.0f})   "
          f"D arms {dv} -> [{d[0]:.0f}, {d[1]:.0f})")
    print(f"  {'':<26} R = ({R[0]:.2f}, {R[1]:.2f})")
    return R


print("=== §C: does the build ratio depend on the P4 program? ===\n")
Rs = ratio("b", "P_simple  (ndtwin)")
Rc = ratio("c", "P_complex (firewall)")

if Rs is None or Rc is None:
    print("\n  Cannot evaluate: one of the two rounds is incomplete.")
    sys.exit(1)

print()
if Rs[0] < Rc[1] and Rc[0] < Rs[1]:
    print("  ✅ PROGRAM-INDEPENDENT: the two intervals intersect.")
    print("     ⇒ the build confound does not change with the P4 program, at this")
    print("       resolution. Study (1)'s scope widens to both programs measured.")
    print("     🔑 Intersecting is not equal. This rules out program-dependence at rung")
    print("        resolution; it does not say the two ratios are the same number.")
else:
    print("  🔴 PROGRAM-DEPENDENT: the intervals do not intersect.")
    print("     ⇒ the ratio is a function of the P4 program. Study (1) must carry a")
    print("       'for this program' qualifier. Unfavourable to us; registered as")
    print("       publishable in this direction; report it.")

print("\n  scope reminder (PREREG §C.3b): the register path never executed -- this ladder")
print("  is UDP and firewall.p4 guards its bloom filters behind hdr.tcp.isValid().")
