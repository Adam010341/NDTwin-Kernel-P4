#!/usr/bin/env python3
"""The E round's 2x2 — drawn so it cannot be read as a 2x2.

🔴 THE FIRST REQUIREMENT IS NOT TO DRAW A FIGURE TIDIER THAN THE DATA.
A conventional 2x2 grid *visually asserts* that its four cells are mutually comparable. In this
round they are not: plan (b) ran `bl`+`p` in one leg and `m`+`mp` in another, 3.3 hours apart, so
**the batching factor is perfectly aliased with leg and period** (F-28) and its main effect is not
estimable. Drawing the four arms on one seamless axis would state, in the strongest visual language
available, exactly the thing that is false.

So the figure is built from four rules:
  1. the two legs are drawn in SEPARATE panels with the wall-clock gap between them, never merged;
  2. within-leg contrasts (bl<->p, m<->mp) are solid — they are measurements;
     the cross-leg contrast (bl<->m) is dashed and labelled "confounded with time";
  3. 1/4 and 1/1 are shaded OFF-CURVE: every cell there is DATAPLANE-HURT, and the registration
     keeps such cells out of the precision curve;
  4. the caption carries BOTH required sentences — the main effect is not estimable, AND the
     primary is immune to the confound. Either one alone misleads in a different direction.

Usage:  python3 plot_2x2.py [OUTDIR]
[Co-developed with claude code -- Adam]
"""
import os
import re
import sys
import collections

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                      # noqa: E402
from matplotlib.lines import Line2D                  # noqa: E402
from matplotlib.patches import Patch                 # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CELLS = os.path.join(HERE, "raw", "cells.tsv")
OUT = sys.argv[1] if len(sys.argv) > 1 else HERE

# House palette (2026-08-20 round, plot_ladder_rates.py:67) — reused, not reinvented.
C_BL, C_P, C_M, C_MP = "#9C3B2E", "#4E88A6", "#B07A55", "#7A8C99"
ARM = {"bl": ("bl  1 kHz · batch 1", C_BL), "p": ("p   1 Hz · batch 1", C_P),
       "m":  ("m   1 kHz · batch 8", C_M),  "mp": ("mp  1 Hz · batch 8", C_MP)}
LEG = {"leg 1  ·  23:26 – 04:47": ("bl", "p"), "leg 2  ·  04:50 – 07:25": ("m", "mp")}
OFF_CURVE = {4, 1}          # every cell here is DATAPLANE-HURT; excluded by registration
LADDER = [1024, 256, 64, 32, 16, 8, 4, 1]


def load():
    """(arm, rung) -> [ratios].  Read the round's own record, not a re-derivation."""
    out = collections.defaultdict(list)
    with open(CELLS, encoding="utf-8") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) < 9:
                continue
            m = re.search(r"ratio=([0-9.eE+-]+)", f[-1])
            if m:
                out[(f[1], int(f[2]))].append(float(m.group(1)))
    return out


def main():
    d = load()
    fig, axes = plt.subplots(1, 2, figsize=(13.6, 5.9), sharey=True,
                             gridspec_kw={"wspace": 0.28})

    for ax, (leg_label, arms) in zip(axes, LEG.items()):
        rungs = sorted({r for a in arms for (aa, r) in d if aa == a}, reverse=True)
        xs = list(range(len(rungs)))

        for lo, hi in ((4, 1),):                      # shade the off-curve region
            band = [i for i, r in enumerate(rungs) if r in OFF_CURVE]
            if band:
                ax.axvspan(min(band) - 0.5, max(band) + 0.5, color="#C9C2B6", alpha=0.35, zorder=0)
                ax.text(sum(band) / len(band), 1.0455, "OFF-CURVE\nevery cell DATAPLANE-HURT",
                        ha="center", va="top", fontsize=8.5, color="#5a5348", zorder=3)

        for arm in arms:
            label, col = ARM[arm]
            ys = [sum(d[(arm, r)]) / len(d[(arm, r)]) if d.get((arm, r)) else None for r in rungs]

            # 🔴 The line STOPS at the off-curve boundary and does not resume inside it.
            # A continuous line across that edge asserts "the same curve carries on", which is the
            # one thing the registration excludes those rungs from saying.  The points stay — they
            # are data — but nothing joins them.  (Spec rule 1: do not draw a figure tidier than
            # the data.  Caught by looking at the first render, not by reasoning about it.)
            on = [(x, y) for x, y, r in zip(xs, ys, rungs) if y is not None and r not in OFF_CURVE]
            off = [(x, y) for x, y, r in zip(xs, ys, rungs) if y is not None and r in OFF_CURVE]
            ax.plot([p[0] for p in on], [p[1] for p in on], "-o", color=col, lw=2.0,
                    ms=5.5, label=label, zorder=4)
            if off:
                ax.plot([p[0] for p in off], [p[1] for p in off], "o", color=col, ms=5.5,
                        mfc="none", mew=1.6, zorder=4)        # hollow: measured, not on the curve
            for r, x, y in zip(rungs, xs, ys):        # every individual cell, not just the mean
                for v in d.get((arm, r), []):
                    ax.plot(x, v, ".", color=col, ms=3.4, alpha=0.55, zorder=3)

        ax.axhline(0.95, color="#8a2b1f", lw=1.1, ls=(0, (5, 3)), zorder=2)
        ax.text(len(rungs) - 0.55, 0.9535, "SATURATED threshold 0.95 — never reached, any arm",
                ha="right", fontsize=8.2, color="#8a2b1f")
        ax.set_xticks(xs)
        ax.set_xticklabels([f"1/{r}" for r in rungs], fontsize=9)
        ax.set_title(leg_label, fontsize=11, pad=9)
        ax.set_xlabel("sampling rung")
        ax.grid(axis="y", color="#dcd7cd", lw=0.7)
        ax.set_axisbelow(True)
        ax.legend(fontsize=8.6, loc="lower left", framealpha=0.92)

        # within-leg contrast: a measurement, drawn solid
        if 8 in rungs:
            i = rungs.index(8)
            a0, a1 = arms
            y0 = sum(d[(a0, 8)]) / 3
            y1 = sum(d[(a1, 8)]) / 3
            ax.annotate("", xy=(i, y0), xytext=(i, y1),
                        arrowprops=dict(arrowstyle="<->", color="#2f2f2f", lw=1.4))
            ax.text(i - 0.16, min(y0, y1) - 0.0055, f"{y1 - y0:+.4f}\nmeasured", ha="right",
                    va="top", fontsize=8.4)

    axes[0].set_ylabel("ratio   mean(twin) / ground truth")
    axes[0].set_ylim(0.945, 1.048)

    # 🔴 the cross-leg contrast: the one a 2x2 grid would have drawn as an ordinary comparison
    fig.text(0.5, 0.885, "bl ↔ m  is the batching contrast — and it crosses the gap below",
             ha="center", fontsize=9.4, color="#7a1f1f")
    fig.text(0.5, 0.855,
             "- - - - - - - - - - - -  3 h 18 m  - - - - - - - - - - - -",
             ha="center", fontsize=9, color="#7a1f1f")
    fig.text(0.5, 0.828, "confounded with time · main effect NOT estimable (F-28)",
             ha="center", fontsize=9.4, color="#7a1f1f")

    fig.suptitle("E round · four arms, two legs — deliberately not drawn as one grid",
                 fontsize=13.5, y=0.985)
    cap = (
        "Solid contrasts are measurements: each is between two arms interleaved inside the same "
        "rung of the same leg.  The bl↔m comparison is not drawn as a line because it spans the two "
        "panels — batching is perfectly aliased with leg and period, so its MAIN EFFECT IS NOT "
        "ESTIMABLE, and no number of repetitions recovers it.\n"
        "THE PRIMARY IS UNAFFECTED: SATURATED = 0 in all 72 cells, so all four arms are "
        "right-censored at ≥1/1 and R-E1/R-E2 read INDISTINGUISHABLE — a verdict a time confound "
        "cannot disturb, because a period cannot turn a censored value into an uncensored one.  "
        "Shaded rungs are excluded from the precision curve by registration; their points are drawn hollow and UNJOINED, because a line across that edge would claim the curve continues into rungs the registration removed from it.")
    fig.text(0.5, 0.015, cap, ha="center", va="bottom", fontsize=8.5, wrap=True)
    fig.subplots_adjust(top=0.775, bottom=0.235, left=0.075, right=0.985)

    path = os.path.join(OUT, "fig_2x2_arms_by_leg.png")
    fig.savefig(path, dpi=200)
    print(f"wrote {path}")
    print("  panels: 2 (legs kept apart)   solid contrasts: within-leg only"
          "   shaded: 1/4 and 1/1 OFF-CURVE")


if __name__ == "__main__":
    main()
