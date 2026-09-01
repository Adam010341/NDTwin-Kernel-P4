#!/usr/bin/env python3
"""The two-round figure. Minimal text on the image; the prose lives in REPORT.md.

Usage:  plot_compare.py [output-dir]

[Co-developed with claude code -- Adam]

Every number drawn here is recomputed from the archived JSONL under both rounds' raw/, through
the 08-20 analyser's own loaders -- same discipline as that round's plot_figures.py, and for the
same reason: a figure on a slide has to trace to the run that produced it, and the report is one
of the things being checked.

TWO THINGS ARE DELIBERATELY ABSENT FROM THE IMAGE
1. The stacked baseline/ingest/instrument decomposition the 08-20 figure carried. It needs a
   verified zero for both rounds and this round does not have one (its mzero cells sample as
   hard as the 1/64 cell -- NDTWIN_CLONE_DISABLE has no reader). Drawing a split that rests on
   assuming the two baselines are equal would put an unmeasured assumption inside the picture.
2. The attribution caveat. The title says what was measured and names neither cause nor effect,
   so the figure makes no causal claim that a caption would have to walk back. What the delta
   is and is not belongs in REPORT.md, where a reader can act on it.

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


old_off = series(os.path.join(OLD_DIR, "raw"), "nopoll")
new_off = series(os.path.join(HERE, "raw"), "nopoll")
old_on = series(os.path.join(OLD_DIR, "raw"), "poll")
new_on = series(os.path.join(HERE, "raw"), "poll")

delta = [(n - o) if (n is not None and o is not None) else None
         for o, n in zip(old_off, new_off)]
present = [d for d in delta if d is not None]

x = list(range(len(RATES)))
labels = [f"1/{r}" for r in RATES]

fig, (axL, axR) = plt.subplots(1, 2, figsize=(13.5, 5.2),
                               gridspec_kw={"width_ratios": [1.35, 1]})

# ---- left: the two rounds, ingest only -------------------------------------------------
for ys, col, name, mk in ((old_off, OLDC, "1 kHz recompute  ·  2026-08-20", "o"),
                          (new_off, NEWC, "1 Hz recompute  ·  2026-09-01", "s")):
    axL.plot(x, ys, marker=mk, color=col, lw=2.4, ms=8, label=name, zorder=3)
    for xi, v in zip(x, ys):
        if v is None:
            continue
        axL.annotate(f"{v:.1f}", (xi, v), textcoords="offset points", xytext=(0, 11),
                     ha="center", fontsize=10, color=col, fontweight="bold")

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
axR.bar(x, present, color=WARNC, width=0.55, zorder=3)
for xi, v in zip(x, present):
    # The bars run downward from zero, so "inside the bar, near its tip" is a POSITIVE offset.
    axR.annotate(f"{v:.1f}", (xi, v), textcoords="offset points", xytext=(0, 10),
                 ha="center", fontsize=10.5, color="white", fontweight="bold", zorder=5)
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
print(f"wrote {path}")
print(f"  1 kHz poll-off: {['%.1f' % v for v in old_off]}")
print(f"  1 Hz  poll-off: {['%.1f' % v for v in new_off]}")
print(f"  gap           : {['%+.1f' % v for v in present]}  mean {m:+.2f}  "
      f"spread {max(present)-min(present):.2f}")
print(f"  instrument cost (poll-on minus poll-off), unchanged control:")
print(f"    1 kHz: {['%.1f' % (a-b) for a, b in zip(old_on, old_off)]}")
print(f"    1 Hz : {['%.1f' % (a-b) for a, b in zip(new_on, new_off)]}")
