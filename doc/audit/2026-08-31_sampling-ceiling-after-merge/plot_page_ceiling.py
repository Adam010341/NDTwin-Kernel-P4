#!/usr/bin/env python3
"""The 9/03 deck's ceiling page — drawn as two panels because there is no ceiling to draw.

🔴 WHAT THIS FIGURE MUST NOT SAY.  The registered primary of the E round is that the telemetry
ceiling was NOT READ OUT: `SATURATED` fired in 0 of 72 cells, so every arm is right-censored at
>=1/1 and R-E1/R-E2 read INDISTINGUISHABLE.  A figure with a ceiling line on it, or with a curve
that visibly turns over, would assert the one thing the round is not entitled to say.

What there IS to show is the pair of curves coming apart.  Across the same eight rungs:

    delivered throughput  205.9  ->  23.0 Mbit/s     (bl; 89% of the traffic gone)
    fidelity ratio        0.9996 ->  1.0090          (same cells, same instant)

The criterion compares the twin against ground truth, and at 1/1 BOTH have collapsed together, so
their ratio is still ~1.00 -- it reads slightly BETTER at the rung that destroys the network than
at the rung that does not.  That is not a ceiling measurement failing; it is a criterion that was
never measuring the quantity its name implies.  FINDINGS.md calls it the round's headline result.

House rules obeyed (08-30 clean-figure ruling): title + parameter line on the image, everything
protective moved to the template's section G as REQUIRED lines.  Palette from the 08-20 round's
plot_ladder_rates.py via plot_2x2.py -- reused, not reinvented.

Leg 1 only (`bl`, `p`).  `m`/`mp` are excluded on purpose: they ran 3.3 hours later, cover four
rungs rather than eight, and batching is perfectly aliased with leg (F-28), so putting all four
arms on one axis would make a confounded contrast look like an ordinary one.

Usage:  python3 plot_page_ceiling.py [OUTDIR]
[Co-developed with claude code -- Adam]
"""
import os
import re
import sys
import collections

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                      # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CELLS = os.path.join(HERE, "raw", "cells.tsv")
OUT = sys.argv[1] if len(sys.argv) > 1 else HERE

C_BL, C_P = "#9C3B2E", "#4E88A6"                     # house palette, same two arms as plot_2x2.py
C_RULE, C_BAND, C_INK = "#8a2b1f", "#C9C2B6", "#2f2f2f"
ARMS = {"bl": ("bl   recompute 1 kHz", C_BL), "p": ("p    recompute 1 Hz", C_P)}
LADDER = [1024, 256, 64, 32, 16, 8, 4, 1]
OFF_CURVE = {4, 1}                                   # DATAPLANE-HURT everywhere; off the precision curve
SATURATED_RATIO = 0.95


def load():
    """(arm, rung) -> {'gt': [...], 'ratio': [...], 'marks': {...}} from the round's own record."""
    out = collections.defaultdict(lambda: {"gt": [], "ratio": [], "marks": set()})
    with open(CELLS, encoding="utf-8") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) < 9 or f[1] not in ARMS:
                continue
            cell = out[(f[1], int(f[2]))]
            for key, field in (("gt", "gt_mbit"), ("ratio", "ratio")):
                m = re.search(rf"\b{field}=([0-9.eE+-]+)", f[-1])
                if m:
                    cell[key].append(float(m.group(1)))
            m = re.search(r"mark=(\S+)", f[-1])
            if m:
                cell["marks"].add(m.group(1))
    return out


def mean(xs):
    return sum(xs) / len(xs)


def check(d):
    """Assert the figure's own yield.  A plot that silently drops half its input still renders."""
    assert len(d) == len(ARMS) * len(LADDER), f"expected 16 (arm,rung) groups, got {len(d)}"
    for key, cell in d.items():
        assert len(cell["gt"]) == 3 and len(cell["ratio"]) == 3, f"{key}: n != 3"
    hurt = {r for (a, r), c in d.items() if c["marks"] != {"OK"}}
    assert hurt == OFF_CURVE, f"DATAPLANE-HURT rungs are {sorted(hurt)}, expected {sorted(OFF_CURVE)}"
    sat = [k for k, c in d.items() if any("SATURATED" in m for m in c["marks"])]
    assert not sat, f"SATURATED fired at {sat} -- the premise of this figure no longer holds"
    return True


def panel_delivered(ax, d, xs):
    for arm, (label, col) in ARMS.items():
        ys = [mean(d[(arm, r)]["gt"]) for r in LADDER]
        ax.plot(xs, ys, "-o", color=col, lw=2.2, ms=6, label=label, zorder=4)
        for x, r in zip(xs, LADDER):                 # every replicate, not just the mean
            for v in d[(arm, r)]["gt"]:
                ax.plot(x, v, ".", color=col, ms=3.6, alpha=0.5, zorder=3)
    # Both arms, and the denominator named.  Quoting one arm's 89% while plotting two lines is the
    # defect page_bandwidth-ceiling.png shipped with (32 flows vs 1, only one side labelled); and
    # "89% gone" is meaningless until the figure says gone *relative to the 1/1024 rungs*, which is
    # a different denominator from the 200 Mbit/s offered.
    end = ", ".join(f"{mean(d[(a, 1)]['gt']):.0f}" for a in ARMS)
    start = ", ".join(f"{mean(d[(a, 1024)]['gt']):.0f}" for a in ARMS)
    # Text sits left of the descending segment, not on it: a leader that crosses its own curve
    # makes the reader's eye follow the annotation instead of the data.
    ax.annotate(f"{end} Mbit/s  here\n{start} Mbit/s  at 1/1024",
                xy=(xs[-1] - 0.06, mean(d[("p", 1)]["gt"]) + 4), xytext=(xs[-1] - 2.6, 56),
                fontsize=11, color=C_RULE, fontweight="bold", ha="center", va="center",
                arrowprops=dict(arrowstyle="-", color=C_RULE, lw=1.1,
                                connectionstyle="arc3,rad=-0.12"))
    ax.set_ylabel("delivered (Mbit/s)", fontsize=10.5)
    ax.set_ylim(0, 245)
    ax.set_title("What the network delivered", fontsize=12.5, fontweight="bold", pad=10, loc="left")


def panel_fidelity(ax, d, xs):
    for arm, (label, col) in ARMS.items():
        pts = [(x, mean(d[(arm, r)]["ratio"]), r) for x, r in zip(xs, LADDER)]
        on = [(x, y) for x, y, r in pts if r not in OFF_CURVE]
        off = [(x, y) for x, y, r in pts if r in OFF_CURVE]
        # 🔴 The line stops at the off-curve edge and does not resume inside it.  A continuous line
        # would claim the precision curve carries on into rungs the registration removed from it.
        ax.plot([p[0] for p in on], [p[1] for p in on], "-o", color=col, lw=2.2, ms=6,
                label=label, zorder=4)
        ax.plot([p[0] for p in off], [p[1] for p in off], "o", color=col, ms=6, mfc="none",
                mew=1.7, zorder=4)
        for x, r in zip(xs, LADDER):
            for v in d[(arm, r)]["ratio"]:
                ax.plot(x, v, ".", color=col, ms=3.6, alpha=0.5, zorder=3)
    ax.axhline(SATURATED_RATIO, color=C_RULE, lw=1.3, ls=(0, (5, 3)), zorder=2)
    ax.text(-0.35, SATURATED_RATIO + 0.0035,
            f"SATURATED threshold {SATURATED_RATIO} — never crossed, 0 of 72 cells",
            ha="left", fontsize=9.8, color=C_RULE, fontweight="bold")
    # Both arms at the top rung, because quoting only one invites "was the other one fine?"
    end = ", ".join(f"{mean(d[(a, 1)]['ratio']):.3f}" for a in ARMS)
    start = ", ".join(f"{mean(d[(a, 1024)]['ratio']):.3f}" for a in ARMS)
    ax.annotate(f"{end}  here\n{start}  at 1/1024",
                xy=(xs[-1] - 0.06, mean(d[("p", 1)]["ratio"]) + 0.002),
                xytext=(xs[-1] - 2.6, 1.036),
                fontsize=11, color=C_RULE, fontweight="bold", ha="center", va="center",
                arrowprops=dict(arrowstyle="-", color=C_RULE, lw=1.1,
                                connectionstyle="arc3,rad=-0.12"))
    ax.set_ylabel("twin / ground truth", fontsize=10.5)
    ax.set_ylim(0.938, 1.052)
    ax.set_title("What the fidelity criterion reported", fontsize=12.5, fontweight="bold",
                 pad=10, loc="left")


def main():
    d = load()
    check(d)
    xs = list(range(len(LADDER)))

    fig, axes = plt.subplots(1, 2, figsize=(15.2, 6.35), gridspec_kw={"wspace": 0.20})
    panel_delivered(axes[0], d, xs)
    panel_fidelity(axes[1], d, xs)

    band = [i for i, r in enumerate(LADDER) if r in OFF_CURVE]
    for ax in axes:
        ax.axvspan(min(band) - 0.5, max(band) + 0.5, color=C_BAND, alpha=0.40, zorder=0)
        ax.set_xticks(xs)
        ax.set_xticklabels([f"1/{r}" for r in LADDER], fontsize=9.6)
        ax.set_xlim(-0.5, len(LADDER) - 0.5)
        ax.set_xlabel("sampling rung  (1 packet in N)", fontsize=10.5)
        ax.grid(axis="y", color="#dcd7cd", lw=0.7)
        ax.set_axisbelow(True)
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        ax.text(sum(band) / len(band), ax.get_ylim()[1], "  DATAPLANE-HURT\n  off the precision curve",
                ha="center", va="top", fontsize=9, color="#5a5348", zorder=5)

    # 🔴 The title is the strongest claim on the page, so it says only what was measured.  Two
    # earlier drafts failed differently: "the fidelity number never moved" is contradicted by the
    # right panel (the ratio moves between 0.97 and 1.01), and "collapsed by 89%" quoted bl alone
    # while the figure plots two arms that lost 89% and 87%.  Derive the range from the data.
    drop = sorted(round(100 * (1 - mean(d[(a, 1)]["gt"]) / mean(d[(a, 1024)]["gt"]))) for a in ARMS)
    fig.suptitle(f"The traffic collapsed by {drop[0]}–{drop[-1]}%.  "
                 f"The fidelity criterion read 1.01.",
                 fontsize=17.5, fontweight="bold", y=0.975)
    fig.text(0.5, 0.912,
             "bmv2, 10 switches / 128 hosts · 200 Mbit/s UDP offered, 300 s per cell, n=3 · "
             "leg 1 only: bl and p, batching off · both panels are the same 48 cells",
             ha="center", fontsize=11.2, color="#4a4a4a")

    # One shared legend rather than two: per-panel boxes collided with the threshold label, and
    # the arms are identical across panels, so repeating the key says they might not be.
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, 0.892),
               ncol=2, fontsize=10.5, frameon=False, handletextpad=0.5, columnspacing=2.6)
    fig.subplots_adjust(top=0.775, bottom=0.115, left=0.058, right=0.985)

    path = os.path.join(OUT, "page_ceiling-not-read-out.png")
    fig.savefig(path, dpi=200)
    print(f"wrote {path}")
    print(f"  delivered  {mean(d[('bl', 1024)]['gt']):.1f} -> {mean(d[('bl', 1)]['gt']):.1f} Mbit/s")
    print(f"  ratio      {mean(d[('bl', 1024)]['ratio']):.4f} -> {mean(d[('bl', 1)]['ratio']):.4f}")
    print("  asserted: 16 groups x n=3, DATAPLANE-HURT exactly at {1/4, 1/1}, SATURATED nowhere")


if __name__ == "__main__":
    main()
