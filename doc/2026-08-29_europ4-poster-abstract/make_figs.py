#!/usr/bin/env python3
# Figures for the EuroP4'26 abstract + the study report.
# Every number below carries its provenance; regenerate with the .plotvenv
# interpreter (matplotlib 3.11.x) -- other versions changed layout defaults.
#   "$HOME/Desktop/NDTwin slide material/NDTwin Slide material 820/.plotvenv/bin/python" make_figs.py
# Outputs: figs/*.pdf (for LaTeX) and figs/*.png (for markdown).
# [Co-developed with claude code -- Adam]

import os
import matplotlib

assert matplotlib.__version__.startswith("3.11"), (
    f"matplotlib {matplotlib.__version__}: use the .plotvenv interpreter "
    "(3.11.x) or layouts will drift; see script header."
)
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "figs")
os.makedirs(OUT, exist_ok=True)

C_A = "#0072B2"   # arm a / stock  (Okabe-Ito blue)
C_B = "#E69F00"   # arm b / fast   (Okabe-Ito orange)
C_HL = "#D55E00"  # highlight
C_LIT = "#666666"

plt.rcParams.update({
    "font.size": 7.5, "axes.titlesize": 8, "axes.labelsize": 7.5,
    "xtick.labelsize": 7, "ytick.labelsize": 7, "legend.fontsize": 6.5,
    "axes.spines.top": False, "axes.spines.right": False,
    "figure.dpi": 200, "savefig.bbox": "tight",
})


def save(fig, name):
    fig.savefig(os.path.join(OUT, name + ".pdf"))
    fig.savefig(os.path.join(OUT, name + ".png"))
    plt.close(fig)


# ---------------------------------------------------------------- fig 1
# Ticket 2, packet-size-sweep/FINDINGS.md s1 (commit c3bfe50):
# clean rungs per arm: 64B a=20,b=12 | 256B a=20,b=20 | 1024B a=12,b=20 kpps
# means 16.0 / 20.0 / 16.0 kpps == 8.2 / 41.0 / 131.1 Mbit/s (frame bits).
def fig1():
    frames = ["64 B", "256 B", "1024 B"]
    x = [0, 1, 2]
    arms = {"arm a": ([20, 20, 12], "o"), "arm b": ([12, 20, 20], "s")}
    mean_kpps = [16.0, 20.0, 16.0]
    mbit = [8.2, 41.0, 131.1]

    fig, (ax1, ax2) = plt.subplots(
        2, 1, figsize=(3.3, 2.6), sharex=True,
        gridspec_kw={"height_ratios": [1, 1], "hspace": 0.18})

    for (lbl, (ys, mk)), c in zip(arms.items(), (C_A, C_B)):
        ax1.scatter(x, ys, marker=mk, s=18, color=c, label=lbl, zorder=3)
    ax1.plot(x, mean_kpps, "-", color="#333333", lw=1, zorder=2, label="mean")
    ax1.set_ylabel("clean rate\n(kpps)")
    ax1.set_ylim(0, 26)
    ax1.annotate("spread $\\times$1.25", (1, 21.5), ha="center", fontsize=7)
    ax1.legend(frameon=False, ncol=3, loc="lower center",
               bbox_to_anchor=(0.5, -0.06), handletextpad=0.2, columnspacing=0.8)

    ax2.bar(x, mbit, width=0.45, color="#999999", edgecolor="none")
    for xi, v in zip(x, mbit):
        ax2.annotate(f"{v:g}", (xi, v * 1.15), ha="center", fontsize=7)
    ax2.set_yscale("log")
    ax2.set_ylim(5, 400)
    ax2.set_ylabel("same cells\n(Mbit/s)")
    ax2.set_xticks(x, frames)
    ax2.set_xlabel("Ethernet frame size")
    ax2.annotate("spread $\\times$16.0", (1, 200), ha="center",
                 fontsize=7, color=C_HL, fontweight="bold")
    save(fig, "fig1_unit_ambiguity")


# ---------------------------------------------------------------- fig 2
# Ticket 3, flow-count-capacity/FINDINGS.md s1 (commit 387d3ea):
# per-flow highest clean rate, arm a 160/110/30/5/2, arm b 240/110/45/8/1.
# Ladder rungs (PREREG s3): 1 2 3 5 8 12 20 30 45 70 110 160 240 M/flow.
def fig2():
    n = [1, 2, 4, 8, 16]
    arm_a = [160, 110, 30, 5, 2]
    arm_b = [240, 110, 45, 8, 1]
    rungs = [1, 2, 3, 5, 8, 12, 20, 30, 45, 70, 110, 160, 240]

    fig, ax = plt.subplots(figsize=(3.3, 2.2))
    for r in rungs:
        ax.axhline(r, color="#dddddd", lw=0.5, zorder=1)
    ax.plot(n, arm_a, "o-", color=C_A, lw=1.2, ms=4, label="arm a", zorder=3)
    ax.plot(n, arm_b, "s--", color=C_B, lw=1.2, ms=4, label="arm b", zorder=3)
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_xticks(n, [str(v) for v in n])
    ax.set_xlabel("concurrent flows $n$ (one path class)")
    ax.set_ylabel("per-flow highest clean rate (Mbit/s)")
    ax.set_ylim(0.8, 320)
    ax.legend(frameon=False, loc="upper right")
    ax.annotate("gridlines = ladder rungs\n(adjacent rungs = $\\pm$1 resolution)",
                (1.05, 1.6), fontsize=6.5, color="#555555")
    save(fig, "fig2_perflow_monotone")


# ---------------------------------------------------------------- fig 3
# Ticket 1: single-switch-build-ratio/FINDINGS-1b.md s1 (commit e82ac6f):
#   one hop, control plane live: stock 45, fast 360 (both arms identical).
# Pilot, 3-hop production path (doc/2026-08-15_bmv2-performance-report.md,
# quoted in PREREG s2): stock 25, fast 300 (UDP zero-loss point).
def fig3():
    rows = [
        ("1 hop, isolated\n(this work, 4 arms)", 45, 360, "$R=8.0$  (5.14–12.0)"),
        ("3-hop production path\n(pilot)", 25, 300, "$12\\times$"),
    ]
    fig, ax = plt.subplots(figsize=(3.3, 1.7))
    for i, (lbl, s, f, note) in enumerate(rows):
        y = 1 - i
        ax.plot([s, f], [y, y], "-", color="#bbbbbb", lw=1.5, zorder=2)
        ax.scatter([s], [y], color=C_A, s=22, zorder=3,
                   label="stock build" if i == 0 else None)
        ax.scatter([f], [y], color=C_B, s=22, marker="s", zorder=3,
                   label="fast build" if i == 0 else None)
        ax.annotate(note, ((s * f) ** 0.5, y + 0.13), ha="center", fontsize=7)
        ax.annotate(lbl, (11, y), ha="right", va="center", fontsize=6.8)
    ax.set_xscale("log")
    ax.set_xlim(10, 700)
    ax.set_ylim(-0.5, 1.6)
    ax.set_yticks([])
    ax.spines["left"].set_visible(False)
    ax.set_xlabel("UDP zero-loss point (Mbit/s)")
    ax.legend(frameon=False, loc="lower right", ncol=2)
    save(fig, "fig3_build_two_working_points")


# ---------------------------------------------------------------- fig 4
# Literature spread (RELATED-WORK.md s1/s3 + SEARCH-ROUND rows; identities and
# line numbers there). Quantity types are mixed (zero-loss / saturation / mean
# ceiling) and mostly unstated -- that is part of the point (report s5-6).
def fig4():
    pts = [  # (label, lo, hi or None, y)
        ("TSSA '23 (64 B)", 0.574, 0.757, 0),
        ("P4sim '25", 43, None, 1),
        ("PADS '24", 145, 175, 2),
        ("TOMACS '25 (grpc)", 170, None, 3),
        ("ICNCC '23 (phys. NIC)", 1000, 1400, 4),
    ]
    fig, ax = plt.subplots(figsize=(3.3, 2.0))
    for lbl, lo, hi, y in pts:
        if hi:
            ax.plot([lo, hi], [y, y], "-", color=C_LIT, lw=2.5,
                    solid_capstyle="round", zorder=2)
        ax.scatter([lo], [y], color=C_LIT, s=14, zorder=3)
        ax.annotate(lbl, (max((hi or lo) * 1.35, lo * 1.35), y),
                    va="center", fontsize=6.5, color="#444444")
    # ours: same machine, same variant, build A/B (FINDINGS-1b s1)
    ax.scatter([45], [5.2], color=C_A, s=26, zorder=4)
    ax.scatter([360], [5.2], color=C_B, s=26, marker="s", zorder=4)
    ax.plot([45, 360], [5.2, 5.2], "-", color=C_HL, lw=1.2, zorder=3)
    ax.annotate("this work: build A/B,\nsame machine ($\\times$8)",
                (128, 5.55), ha="center", fontsize=6.5, color=C_HL)
    ax.annotate("$\\sim$2,500$\\times$, zero papers report build",
                (24, -0.95), ha="center", fontsize=7, fontweight="bold")
    ax.set_xscale("log")
    ax.set_xlim(0.3, 9000)
    ax.set_ylim(-1.4, 6.3)
    ax.set_yticks([])
    ax.spines["left"].set_visible(False)
    ax.set_xlabel("published bmv2 throughput (Mbit/s, quantity types mixed)")
    save(fig, "fig4_literature_spread")


fig1(); fig2(); fig3(); fig4()
print("wrote 4 figures ->", OUT)
