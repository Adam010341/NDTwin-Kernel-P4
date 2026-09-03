#!/usr/bin/env python3
"""Figure 1 of the 9/03 deck, redrawn so BOTH panels key on flow count alone.

[Co-developed with claude code -- Adam]

WHY A REDRAW. In the original, the left panel's x axis was the work point (two ticks for five
readings) while the right panel's was one tick per reading, carrying arm names and binary shas.
Same five numbers, two different axes -- a reader cannot tell that the third grey bar and the
rightmost dot are the same measurement. Adam's ruling 2026-09-03: label both axes with the flow
count and nothing else.

The two panels now share one x geometry, computed once in XPOS. The k-th marker of a group on the
left and the k-th bar of the same group on the right are the same reading, at the same horizontal
position. That is the only thing the second panel adds that a rescaled y axis would not, so it is
worth being exact about.

READINGS ARE NOT AVERAGED INTO THEIR GROUP. Dropping the per-reading tick labels is a labelling
change; collapsing 2 and 3 readings into a group mean would be a statistical one, and the wrong
one -- 60dcca66 retracted exactly that move ("three reps inside one arm are three reads of one
arm, not three samples of the quiet condition") and established the arm as the unit of
replication. So every reading stays on the figure; only its tick label goes.

WHAT MOVED, NOT WHAT VANISHED. The binary shas left the x tick labels for the parameter line:
the project rule is that a benchmark names its binary, and the axis is no longer the place. The
64-flow survey's binary is NOT stated, because survey_T64.log does not record one -- it is
named only in a commit message, and this deck does not transcribe numbers into figures.

DROPPED FROM THE SUBTITLE: "one fabric generation". raw/round.meta puts the two Q arms at
2026-08-27 22:28:30; survey_T64.log ran at 17:34 the same day, ~5 h and a separate bring-up
earlier. The claim held inside each group and not across them, which is precisely the span the
noise band is defined over.

    python3 plot_q_by_flowcount.py [outdir]
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# Parsers and palette are imported, never re-implemented: the source-of-truth guard in
# plot_deck_903._read (tracked here, or content-matched against audit-raw) must apply to this
# figure too, and a second copy of the regexes could drift from the first.
from plot_deck_903 import (  # noqa: E402
    ACCENT, INK, MUTED, WARNC, WARN_BG,
    AXES_H, AXES_Y, BAND, DPI, WIDE,
    _frame, _title_clean, arm_to_arm_ms, q_arms, q_survey,
)

OUT = sys.argv[1] if len(sys.argv) > 1 else HERE


def xpos(gi, k, n):
    """Horizontal position of reading k of n in group gi. Shared by both panels."""
    return gi * 1.0 + 0.5 + (k - (n - 1) / 2) * 0.235


def main():
    arms, survey = q_arms(), q_survey()
    noise_ms = arm_to_arm_ms()
    noise_pct = noise_ms / 10.0          # ms on a ~1000 ms period -> percentage points

    # (tick label, [(period_s, overreport_pct)])
    groups = [
        ("16 flows", [(a[2], a[3]) for a in arms]),
        ("64 flows", [(p, o) for p, o in survey]),
    ]
    shas = " · ".join(a[1][:8] for a in arms)

    fig = plt.figure(figsize=WIDE)
    _title_clean(fig,
                 "The denominator was assumed to be 1.000 s. It never was.",
                 f"16 flows: {shas}   |   64 flows: 3 reps, binary not recorded in the log"
                 "   |   one marker = one arm reading")

    axL = fig.add_axes([0.055, AXES_Y, 0.375, AXES_H])
    axR = fig.add_axes([0.545, AXES_Y, 0.425, AXES_H])

    # --- left: the periods themselves, against the assumption -------------------------------
    _frame(axL, ylab="Measured loop period  (s)")
    axL.axhline(1.0, color=WARNC, linewidth=1.7, linestyle="--", zorder=3)
    axL.text(1.97, 1.0015, "assumed divisor = 1.000 s", color=WARNC, fontsize=11.5,
             va="bottom", ha="right", fontweight="bold")

    # --- right: the same readings as the error they imply, against the noise floor ----------
    _frame(axR, ylab="Over-report from the hard-coded 1 s  (%)")
    top = max(o for _n, rows in groups for _p, o in rows) * 1.44
    axR.axhspan(0, noise_pct, color=WARN_BG, zorder=1)
    axR.axhline(noise_pct, color=WARNC, linewidth=1.3, linestyle=":", zorder=3)
    axR.text(0.04, top * 0.985, f"arm-to-arm noise floor: {noise_ms:.0f} ms ≈ {noise_pct:.1f} pts",
             color=WARNC, fontsize=11, va="top", ha="left", fontweight="bold")

    for gi, (_gname, rows) in enumerate(groups):
        for k, (p, o) in enumerate(rows):
            x = xpos(gi, k, len(rows))
            axL.plot([x, x], [1.0, p], color=ACCENT, linewidth=1.7, alpha=0.45, zorder=4)
            axL.plot([x], [p], "o", ms=11, color=ACCENT, zorder=5,
                     markeredgecolor="white", markeredgewidth=1.2)
            axL.annotate(f"{p:.4f}", (x, p), textcoords="offset points", xytext=(0, 11),
                         ha="center", fontsize=10, color=MUTED)

            axR.bar(x, o, width=0.15, color=ACCENT, edgecolor="white", linewidth=1.0, zorder=5)
            axR.annotate(f"+{o:.1f}%", (x, o), textcoords="offset points", xytext=(0, 6),
                         ha="center", fontsize=11, color=INK, fontweight="bold")

    ticks = [gi * 1.0 + 0.5 for gi in range(len(groups))]
    names = [g[0] for g in groups]
    for ax, ylim in ((axL, (0.996, 1.070)), (axR, (0, top))):
        ax.set_xticks(ticks)
        ax.set_xticklabels(names, fontsize=12, color=MUTED)
        ax.set_xlim(0, 2.0)
        ax.set_ylim(*ylim)

    for ext in ("png", "pdf"):
        path = os.path.join(OUT, f"fig_assumed_denominator_by_flowcount.{ext}")
        fig.savefig(path, dpi=DPI, facecolor="white")
        print(f"  wrote {path}")
    plt.close(fig)


if __name__ == "__main__":
    main()
