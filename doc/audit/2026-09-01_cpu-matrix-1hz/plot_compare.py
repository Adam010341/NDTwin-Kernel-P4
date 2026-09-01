#!/usr/bin/env python3
"""The two-round figure. Minimal text on the image; the prose lives in REPORT.md.

Usage:  plot_compare.py [output-dir]

[Co-developed with claude code -- Adam]

Every number drawn here is recomputed from the archived JSONL under both rounds' raw/, through
the 08-20 analyser's own loaders -- same discipline as that round's plot_figures.py, and for the
same reason: a figure on a slide has to trace to the run that produced it, and the report is one
of the things being checked.

THE `none` COLUMN IS THE POINT OF THE FIGURE, NOT A DECORATION
Both rounds are within 1.0 point of each other at zero sampling, and ~46 points apart at every
rate where sampling is on. That is what makes the gap a step rather than a constant: without
the zero column the same five sampled cells read as "a fixed cost was removed", which is what
this round reported before the column existed. It is drawn from cells whose telemetry was
verified zero WHILE TRAFFIC FLOWED, per zero_cell.sh; the main round's mzero cells carried a
zero's label for 300 s each while sampling at 1/64, and zero_cell() rejects them by
measurement rather than by name.

DELIBERATELY ABSENT FROM THE IMAGE
The attribution caveat. The title says what was measured and names neither cause nor effect,
so the figure makes no causal claim that a caption would have to walk back. What the gap is
and is not belongs in REPORT.md, where a reader can act on it.

X is the nominal sampling rate, not samples/s: the quantum recovery that turns twin readings
into samples/s does not work on the 1 Hz round's data (gcd collapses to 1), so samples/s is not
available for both rounds on the same footing.
"""
import importlib.util
import os
import statistics as st
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
OLD_DIR = os.path.join(os.path.dirname(HERE), "2026-08-20_sampling-rate-and-cpu")
OUT = sys.argv[1] if len(sys.argv) > 1 else HERE

spec = importlib.util.spec_from_file_location("am", os.path.join(OLD_DIR, "analyse_matrix.py"))
am = importlib.util.module_from_spec(spec)
spec.loader.exec_module(am)

INK, BODY, RULE = "#1A1A1A", "#2E2E2E", "#D0D0D0"
OLDC, NEWC, WARNC, GREY = "#A9C3D3", "#065A82", "#9C3B2E", "#9AA0A4"

plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white",
    "axes.edgecolor": RULE, "axes.labelcolor": BODY, "text.color": INK,
    "xtick.color": BODY, "ytick.color": BODY,
    "font.size": 11, "axes.titlesize": 13, "axes.titleweight": "bold",
    "axes.spines.top": False, "axes.spines.right": False,
})

RATES = am.RATES


def series(base, arm):
    am.BASE = base
    out = []
    for r in RATES:
        lab = f"m{r}_{arm}"
        if not am._exists(f"{base}/{lab}_cpu.jsonl") or not am.is_complete(lab):
            out.append(None)
            continue
        c = am.cpu_cell(lab)
        out.append(c[1].get("kernel", 0.0) if c else None)
    return out


def zero_cell(base, prefix, arm):
    """The zero-sampling point, averaged over its replicates -- and only over the ones whose
    telemetry really is zero.

    The verification is repeated here rather than trusted from the round that produced it,
    because this is the one number on the figure that is defined by an absence. The main
    round's mzero cells are the reason: they carried a zero's label for 300 s a piece and
    sampled at 1/64 the whole time. A cell counts only if its paired poll arm -- the one that
    carries a twin trace at all -- reports no telemetry on any edge.
    """
    am.BASE = base
    vals = []
    for suf in ("", "_r2", "_r3"):
        lab = f"{prefix}_{arm}{suf}"
        if not am._exists(f"{base}/{lab}_cpu.jsonl"):
            continue
        pair = f"{prefix}_poll{suf}"
        if am._exists(f"{base}/{pair}_twin.jsonl"):
            rows = [r for r in am.load(f"{base}/{pair}_twin.jsonl") if "twin" in r]
            if any(v > 0 for r in rows for v in r["twin"].values()):
                continue                       # not a zero, whatever it is called
        c = am.cpu_cell(lab)
        if c:
            vals.append(c[1].get("kernel", 0.0))
    return (st.mean(vals), len(vals)) if vals else (None, 0)


old_off = series(os.path.join(OLD_DIR, "raw"), "nopoll")
new_off = series(os.path.join(HERE, "raw"), "nopoll")
old_on = series(os.path.join(OLD_DIR, "raw"), "poll")
new_on = series(os.path.join(HERE, "raw"), "poll")

# Sampling rate zero. The 08-20 round has it under mzero (verified zeros); this round's mzero
# is void and its replacement is mzs, measured with the pipeline's clone predicate disabled and
# the control checked before each cell rather than after.
old_z, old_zn = zero_cell(os.path.join(OLD_DIR, "raw"), "mzero", "nopoll")
new_z, new_zn = zero_cell(os.path.join(HERE, "raw"), "mzs", "nopoll")
old_z_on, _ = zero_cell(os.path.join(OLD_DIR, "raw"), "mzero", "poll")
new_z_on, _ = zero_cell(os.path.join(HERE, "raw"), "mzs", "poll")

RATES = [0] + RATES
old_off = [old_z] + old_off
new_off = [new_z] + new_off
old_on = [old_z_on] + old_on
new_on = [new_z_on] + new_on

delta = [(n - o) if (n is not None and o is not None) else None
         for o, n in zip(old_off, new_off)]
present = [d for d in delta if d is not None]

x = list(range(len(RATES)))
labels = ["none" if r == 0 else f"1/{r}" for r in RATES]

fig, (axL, axR) = plt.subplots(1, 2, figsize=(13.5, 5.2),
                               gridspec_kw={"width_ratios": [1.35, 1]})

# ---- left: the two rounds, ingest only -------------------------------------------------
for ys, col, name, mk, up in ((old_off, OLDC, "1 kHz recompute  ·  2026-08-20", "o", True),
                              (new_off, NEWC, "1 Hz recompute  ·  2026-09-01", "s", False)):
    axL.plot(x, ys, marker=mk, color=col, lw=2.4, ms=8, label=name, zorder=3)
    for xi, v, other in zip(x, ys, (new_off if up else old_off)):
        if v is None:
            continue
        # At `none` the two rounds nearly coincide, so a single label offset puts one on top of
        # the other. Split them only where they actually collide; everywhere else both sit
        # above their marker, which reads better.
        # Pushing the lower label DOWN put it on top of the x-axis tick, because at `none` both
        # series sit near the floor. Sideways is the only free direction there.
        close = other is not None and abs(v - other) < 6
        if up or not close:
            off, ha = (0, 11), "center"
        else:
            off, ha = (20, 6), "left"
        axL.annotate(f"{v:.1f}", (xi, v), textcoords="offset points", xytext=off,
                     ha=ha, fontsize=10, color=col, fontweight="bold")

axL.set_title("Kernel CPU while ingesting sFlow")
axL.set_xlabel("sampling rate")
axL.set_ylabel("kernel CPU, % of ONE core")
axL.set_xticks(x)
axL.set_xticklabels(labels)
axL.set_ylim(0, 72)
axL.legend(frameon=False, loc="center left", fontsize=10.5)
axL.grid(axis="y", color=RULE, lw=0.6, alpha=0.7)
axL.set_axisbelow(True)

# ---- right: the gap, rate by rate ------------------------------------------------------
dx = [xi for xi, d in zip(x, delta) if d is not None]
axR.bar(dx, present, color=WARNC, width=0.55, zorder=3)
for xi, v in zip(dx, present):
    # The bars run downward from zero, so "inside the bar, near its tip" is a POSITIVE offset.
    # A bar only a point tall has no inside: that label goes below its tip, in ink, or it
    # lands above the axis and is clipped away -- which is what happened to the `none` bar.
    inside = abs(v) > 6
    axR.annotate(f"{v:.1f}", (xi, v), textcoords="offset points",
                 xytext=(0, 10 if inside else -15), ha="center", fontsize=10.5,
                 color="white" if inside else INK, fontweight="bold", zorder=5)
m = st.mean(present)
# No mean line and no mean label: five value labels within 0.7 of each other already say
# "flat", and a dashed rule plus its caption collided with the first bar's label. Cheapest
# way to keep the image legible is to draw less, not to reposition more.

axR.set_title("Gap between the rounds")
axR.set_xlabel("sampling rate")
axR.set_ylabel("difference, points of ONE core")
axR.set_xticks(x)
axR.set_xticklabels(labels)
axR.set_ylim(min(present) - 6, 0)
axR.grid(axis="y", color=RULE, lw=0.6, alpha=0.7)
axR.set_axisbelow(True)

fig.suptitle("Kernel CPU per sampling rate, two rounds", x=0.012, ha="left",
             fontsize=16, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.93])

path = os.path.join(OUT, "page_two-rounds-kernel-cpu.png")
fig.savefig(path, dpi=170)
fig.savefig(path.replace(".png", ".pdf"))
def fmt(vals, spec="%.1f"):
    return [("--" if v is None else spec % v) for v in vals]


print(f"wrote {path}")
print(f"  rates         : {labels}")
print(f"  1 kHz poll-off: {fmt(old_off)}   (zero from n={old_zn} verified replicates)")
print(f"  1 Hz  poll-off: {fmt(new_off)}   (zero from n={new_zn} verified replicates)")
print(f"  gap           : {fmt(delta, '%+.1f')}")
sampled = [d for d, r in zip(delta, RATES) if d is not None and r != 0]
if sampled:
    print(f"    over the sampled rates only: mean {st.mean(sampled):+.2f}  "
          f"spread {max(sampled)-min(sampled):.2f}")
print("  instrument cost (poll-on minus poll-off), unchanged control:")
print(f"    1 kHz: {fmt([a - b if None not in (a, b) else None for a, b in zip(old_on, old_off)])}")
print(f"    1 Hz : {fmt([a - b if None not in (a, b) else None for a, b in zip(new_on, new_off)])}")
