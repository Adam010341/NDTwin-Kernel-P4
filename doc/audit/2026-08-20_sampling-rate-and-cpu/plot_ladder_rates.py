#!/usr/bin/env python3
"""The quantisation ladder across SAMPLING RATES — the axis the existing two ladders never varied.

[Co-developed with claude code -- Adam]

WHY THIS EXISTS. Two quantisation ladders are already in the material and neither varies the
sampling rate:
  * `page39_quantisation-ladder.png` (8/20 deck): OVS vs P4, both 1-in-256, 20 Mbit/s.
  * `page_ladder-inherited.png` (this round): three kernel generations, all 1-in-256, 200 Mbit/s.
The rate sweep exists but is rendered as a log-log summary (`page_sampling-tradeoff.png`), which
states the quantum shrinks and never shows the staircase doing it. This draws that.

NO NEW MEASUREMENT. Every panel comes from raw already committed in this round: the two-factor
matrix swept SAMPLE_RATE over 1/1024 … 1/64 on ONE fabric at a fixed 200 Mbit/s offered load,
300 s per cell (`matrix.sh`). Loader, trim rule, colours and quantum arithmetic are imported from
`plot_figures.py` rather than restated, so this figure cannot drift from the ones beside it.

READING IT. The quantum is `rate × frame_bytes × 8`, so it scales with the rate: one sample is
worth ~11.8 Mbit/s at 1/1024 and ~0.74 at 1/64. The staircase is therefore coarse and countable
on the left and dissolves toward a continuum on the right — the same trade `page_sampling-
tradeoff.png` states in two slopes, shown as the thing itself.

The grid-line rendering used by the deck's 20 Mbit/s ladder is deliberately NOT used: at these
lambdas it is a haze of lines over the data (recorded in FIGURES.md item 14). Each panel carries
a one-sample scale bar instead.
"""
import math
import os
import statistics as st
import sys
from functools import reduce

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plot_figures import (  # noqa: E402  -- reuse, never restate
    ACCENT, FAINT, INK, MUTED, RAW, RULE, WARNC, load_twin_path,
)

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
EDGE = "s5-eth2"        # the busiest carrying edge in every matrix cell (REPORT §1)
SPAN = 240.0            # statistics window: every panel gets the same number of refresh windows
# Plot window. 240 s at 1 Hz draws 240 vertical strokes per panel and the discrete levels
# disappear into line density -- the figure then shows "the spread narrows", which the tradeoff
# figure already says. 60 s is short enough to see a reading SIT on a level and step to the next,
# which is the only thing this figure adds. Statistics stay on the full SPAN and say so.
PLOT_SPAN = 60.0
GRID_MAX_LINES = 22     # draw the quantum grid only where the lines are still countable

# poll-ON arms: the twin must be polled for there to be a reading to plot at all.
# Five panels, not eleven. The 08-25 round added r032..r001 and eleven panels in one row blows
# the deck's wide-image threshold (ar > 2.5 changes the page's margins), so this picks a spread
# across the whole measured range instead of packing everything in.
#
# NOT A SILENT CAP -- what is dropped and why:
#   * 1/512, 1/128 are interior points of a staircase the remaining panels already show.
#   * r008, r004, r002, r001 are all DATAPLANE-HURT (5.1 / 45.3 / 70.8 / 85.2 % receiver loss;
#     gt collapses 196 -> 29.5 Mbit/s). Their spread is not a quantisation spread, so drawing
#     them on a quantisation ladder would state something the data does not support. They carry
#     the ceiling, and the ceiling is a table in §C4, not a staircase.
# 1/16 is kept and is the last healthy cell: 0.025% loss, and the panel where the spread has
# already stopped tracking the floor.
CELLS = [("1/1024", "m1024"), ("1/256", "m256"), ("1/64", "m64"),
         ("1/32", "r032"), ("1/16", "r016")]
COLS = ["#9C3B2E", "#B07A55", "#7A8C99", "#4E88A6", ACCENT]


def panel_stats(rows):
    vals = sorted({r["twin"].get(EDGE, 0) for r in rows if r["twin"].get(EDGE, 0) > 0})
    if not vals:
        return None
    q = reduce(math.gcd, vals)
    t0 = rows[0]["t"]
    ts = [r["t"] - t0 for r in rows]
    vs = [r["twin"].get(EDGE, 0) / 1e6 for r in rows]
    gt = ((rows[-1]["tx"][EDGE] - rows[0]["tx"][EDGE]) * 8
          / (rows[-1]["t"] - rows[0]["t"])) / 1e6
    hz = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
    step = max(1, int(round(hz)))
    counts = [rows[i]["twin"].get(EDGE, 0) / q for i in range(0, len(rows), step)]
    lam = st.mean(counts)
    sd_mean = math.sqrt(st.pvariance(counts)) / lam * 100
    floor = 100 / math.sqrt(lam)
    return dict(ts=ts, vs=vs, q=q, gt=gt, lam=lam, sd_mean=sd_mean, floor=floor,
                distinct=len(vals))


def fig_ladder_rates(fname):
    panels = []
    for label, cell in CELLS:
        rows = load_twin_path(f"{RAW}/{cell}_poll_twin.jsonl.gz", span=SPAN)
        s = panel_stats(rows)
        if s is None:
            print(f"  SKIP {cell}: twin reported nothing on {EDGE}")
            continue
        panels.append((label, s))

    # 15.2x6.0 renders at ar 2.53, which trips the deck's wide-image mode (E5 #22) and changes
    # the page's margins. 6.35 tall keeps it at 2.39 -- same band as the other figures here.
    fig, axes = plt.subplots(1, len(panels), figsize=(15.2, 6.35), sharey=True)
    out = {}
    for ax, colour, (label, s) in zip(axes, COLS, panels):
        band = st.pstdev(s["vs"])
        ax.axhspan(s["gt"] - band, s["gt"] + band, color=colour, alpha=0.13, zorder=0)

        # The levels themselves: one faint line per attainable value, drawn only while they can
        # still be told apart. This is what makes it a ladder rather than a noise band.
        lo, hi = 105, 320
        nlines = int((hi - lo) / (s["q"] / 1e6))
        if nlines <= GRID_MAX_LINES:
            k = 0
            while k * s["q"] / 1e6 <= hi:
                y = k * s["q"] / 1e6
                if y >= lo:
                    ax.axhline(y, color=RULE, lw=0.6, zorder=1)
                k += 1

        tsp = [t for t in s["ts"] if t <= PLOT_SPAN]
        vsp = s["vs"][:len(tsp)]
        ax.step(tsp, vsp, where="post", color=colour, lw=1.15, zorder=2)
        ax.plot(tsp, vsp, ls="none", marker="o", ms=2.6, color=colour, zorder=3)
        ax.axhline(s["gt"], color=INK, lw=1.3, ls="--", zorder=3)

        # one-sample scale bar: the whole point of the figure is that this bar shrinks
        xq = PLOT_SPAN * 0.93
        y0 = 118.0
        ax.plot([xq, xq], [y0, y0 + s["q"] / 1e6], color=INK, lw=2.2, zorder=4,
                solid_capstyle="butt")
        for y in (y0, y0 + s["q"] / 1e6):
            ax.plot([xq - 4, xq + 4], [y, y], color=INK, lw=1.0, zorder=4)
        ax.text(xq - 7, y0 + s["q"] / 2e6, "1 sample", ha="right", va="center",
                fontsize=7.6, color=MUTED)

        ax.set_xlim(0, PLOT_SPAN)
        ax.set_ylim(105, 320)
        ax.set_xlabel("time (s)")
        ax.set_title(f"sampling {label}", fontsize=11.5, color=colour, loc="left",
                     pad=44, weight="bold")
        ax.text(0, 1.100, f"quantum {s['q']/1e6:.2f} Mbit/s · {s['distinct']} distinct values",
                transform=ax.transAxes, fontsize=8.3, color=MUTED)
        ax.text(0, 1.050, f"λ {s['lam']:.0f} samples per window",
                transform=ax.transAxes, fontsize=8.3, color=MUTED)
        ax.text(0, 1.000, f"spread {s['sd_mean']:.1f}%  ·  floor {s['floor']:.1f}%  (over {SPAN:.0f} s)",
                transform=ax.transAxes, fontsize=8.3, color=MUTED)
        ax.text(0.03, 0.045, f"{s['sd_mean']/s['floor']:.2f}× floor",
                transform=ax.transAxes, fontsize=10.5, color=colour, weight="bold")
        for sp in ("top", "right"):
            ax.spines[sp].set_visible(False)
        ax.spines["left"].set_color(RULE)
        ax.spines["bottom"].set_color(RULE)
        ax.tick_params(colors=FAINT, labelsize=8.5)
        out[label] = dict(q=round(s["q"] / 1e6, 3), lam=round(s["lam"], 1),
                          spread=round(s["sd_mean"], 1), floor=round(s["floor"], 1),
                          ratio=round(s["sd_mean"] / s["floor"], 2), gt=round(s["gt"], 1))

    axes[0].set_ylabel("twin reading (Mbit/s)")
    qs = [v["q"] for v in out.values()]
    fig.suptitle("The staircase dissolves as you sample harder",
                 fontsize=13.5, color=INK, x=0.010, y=0.985, ha="left", weight="bold")
    fig.text(0.010, 0.941,
             f"One fabric, one 200 Mbit/s flow, one edge — only the pipeline's "
             f"SAMPLE_RATE differs. The quantum falls {max(qs)/min(qs):.0f}× from left to right, so the "
             f"same true rate is",
             fontsize=9, color=MUTED, va="top")
    fig.text(0.010, 0.909,
             "reported in ever finer steps. Faint lines are the attainable values; dashed line is "
             "ground truth from the kernel's NIC counters; band is ±1 sd over the full 240 s.",
             fontsize=9, color=MUTED, va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.885])
    fig.subplots_adjust(top=0.700, wspace=0.075)
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname)
    for k, v in out.items():
        print(f"   {k:>7}  {v}")


if __name__ == "__main__":
    fig_ladder_rates("page_ladder-across-rates.png")
