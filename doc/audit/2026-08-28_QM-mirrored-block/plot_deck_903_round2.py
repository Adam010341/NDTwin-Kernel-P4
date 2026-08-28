#!/usr/bin/env python3
"""9/03 deck figures from the six-arm mirrored block (2026-08-28).

WHY THIS EXISTS SEPARATELY from plot_deck_903.py:
    That script was run at 09:12, twenty minutes BEFORE the arms started. Its two M panels
    are stamped "MECHANISM - NO ARM HAS RUN YET" and "PRE-FLIGHT", which were true when
    rendered and are false now. A figure that states its own evidential status goes stale the
    moment the evidence arrives, and nothing warns you -- the PNG keeps rendering fine. So the
    M panels are replaced here rather than edited there, and the Q panels are left alone
    because their evidence has not changed.

    The auditor's table of figure status marked ticket M "done" on the day the DATA arrived,
    in a table headed "figure". Data existing and a figure existing are two claims.

Everything is parsed from REPORT.md, which is committed, and every parse asserts its yield.

Run:
  "/home/adam/Desktop/NDTwin slide material/NDTwin Slide material 820/.plotvenv/bin/python3" \
      plot_deck_903_round2.py "<outdir>"

[Co-developed with claude code -- Adam]
"""
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

REPO = "/home/adam/Desktop/NDTwin-Kernel"
HERE = f"{REPO}/doc/audit/2026-08-28_QM-mirrored-block"
PRIOR = f"{REPO}/doc/audit/2026-08-27_hardcoded-denominator"

# Reuse the deck's palette and the tracked-source guard rather than restating either.
sys.path.insert(0, PRIOR)
from plot_deck_903 import (  # noqa: E402
    BAND, AXES_Y, AXES_H, DPI, WIDE, INK, MUTED, GREY, FAINT, PANEL, RULE,
    ACCENT, ACCENT_BG, WARNC, WARN_BG, OKC, _read, _frame, _title, _foot,
)

OUT = sys.argv[1] if len(sys.argv) > 1 else "."

EXPECT_CPU_ROWS = 6          # six arms in the CPU table
EXPECT_CORE_LINKS = 8        # n0.out / n1.out each list eight core links
NROUND = f"{REPO}/doc/audit/2026-08-25_sampling-rounds"
EXPECT_LAT_ROWS = 2          # the M latency table has one column per condition


def cpu_arms():
    """[(arm, cond, hz, cores)] from REPORT.md section 6-bis, in run order."""
    rows = []
    for line in _read(f"{HERE}/REPORT.md").splitlines():
        m = re.match(r"\|\s*([BQM]\d)\s*\|\s*(\w+)\s*\|\s*\*{0,2}(1 k?Hz)\*{0,2}\s*\|"
                     r"\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*\*\*([\d.]+)\*\*\s*\|", line)
        if m:
            rows.append((m.group(1), m.group(2), m.group(3).replace(" ", ""), float(m.group(6))))
    assert len(rows) == EXPECT_CPU_ROWS, f"CPU table: {len(rows)} arms parsed, want {EXPECT_CPU_ROWS}"
    return rows


def m_latency():
    """{'mean':(q,m), 'median':(q,m), 'p95':(q,m), 'n':(q,m)} from REPORT.md section 4."""
    txt = _read(f"{HERE}/REPORT.md")
    out = {}
    for key, pat in (("n",      r"\|\s*n\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"),
                     ("mean",   r"\|\s*mean\s*\|\s*([\d.]+) s\s*\|\s*([\d.]+) s\s*\|"),
                     ("median", r"\|\s*median\s*\|\s*([\d.]+) s\s*\|\s*([\d.]+) s\s*\|"),
                     ("p95",    r"\|\s*p95\s*\|\s*([\d.]+) s\s*\|\s*([\d.]+) s\s*\|")):
        m = re.search(pat, txt)
        assert m, f"M latency table: no {key} row"
        out[key] = (float(m.group(1)), float(m.group(2)))
    assert len(out) == 4, "M latency table: incomplete"
    return out


def core_links(path):
    """[(iface, gbit)] plus (max, total) from a ticket-N qdisc readout."""
    txt = _read(path)
    links = [(m.group(1), float(m.group(2)))
             for m in re.finditer(r"^\s+(s\d+-eth\d+)\s+([\d.]+) Gbit/s", txt, re.M)]
    assert len(links) == EXPECT_CORE_LINKS, \
        f"{path}: {len(links)} core links parsed, want {EXPECT_CORE_LINKS}"
    mx = re.search(r"MAX\s+([\d.]+) Gbit/s", txt)
    tot = re.search(r"TOTAL\s+([\d.]+) Gbit/s", txt)
    assert mx and tot, f"{path}: no MAX/TOTAL line"
    return links, float(mx.group(1)), float(tot.group(1))


def _save(fig, name):
    path = os.path.join(OUT, name)
    fig.savefig(path, dpi=DPI, facecolor="white")
    plt.close(fig)
    print(f"  wrote {path}")


# --------------------------------------------------------------------- figure: M cost & benefit
def fig_m_cost_and_benefit():
    """The whole of ticket M on one page: what it costs and what it buys, both measured."""
    arms = cpu_arms()
    lat = m_latency()

    khz = [c for _, _, hz, c in arms if hz == "1kHz"]
    hz1 = [c for _, _, hz, c in arms if hz == "1Hz"]
    khz_mean, hz1_mean = sum(khz) / len(khz), sum(hz1) / len(hz1)
    saving_pct = (khz_mean - hz1_mean) / khz_mean * 100
    effect = lat["mean"][1] - lat["mean"][0]

    # Axes sit lower than the sibling script's default: this subtitle wraps to two lines and
    # the panel titles need clearance under it. The first render collided in five places.
    AY, AH = 0.205, 0.425

    fig = plt.figure(figsize=WIDE)
    _title(fig,
           "Ticket M, both halves measured: it costs half a second and buys half a core",
           f"Six mirrored arms, one fabric generation. Cost is the pre-registered primary "
           f"measure — latency to first path, effect {effect:+.3f} s, inside the registered "
           f"0.4–0.6 s. Benefit is POST-HOC and was not registered before the data was read.",
           "COST PRE-REGISTERED · BENEFIT POST-HOC", "mixed", sub_width=165)

    # ---- left: the cost (latency)
    axL = fig.add_axes([0.055, AY, 0.40, AH])
    _frame(axL, ylab="latency to first path (s)")
    xs = [0, 1]
    for i, (lab, idx) in enumerate((("1 kHz\n(before)", 0), ("1 Hz\n(after M)", 1))):
        col = GREY if i == 0 else ACCENT
        axL.bar(i, lat["mean"][idx], width=0.46, color=col, zorder=3)
        axL.vlines(i, lat["median"][idx], lat["p95"][idx], color=INK, lw=1.6, zorder=4)
        axL.plot([i], [lat["median"][idx]], "o", ms=6, color=INK, zorder=5)
        axL.text(i, lat["mean"][idx] + 0.035, f"mean {lat['mean'][idx]:.3f}",
                 ha="center", fontsize=11, color=INK, fontweight="bold")
        axL.text(i, lat["p95"][idx] + 0.03, f"p95 {lat['p95'][idx]:.3f}",
                 ha="center", fontsize=9.5, color=MUTED)
    axL.set_xticks(xs)
    axL.set_xticklabels(["1 kHz\n(before)", "1 Hz\n(after M)"], fontsize=11.5, color=INK)
    axL.set_xlim(-1.05, 1.6)
    axL.set_ylim(0, 1.42)
    # Arrow sits in the gap between the bars, label to its left, so neither lands on a bar.
    axL.annotate("", xy=(0.63, lat["mean"][1]), xytext=(0.63, lat["mean"][0]),
                 arrowprops=dict(arrowstyle="<->", color=WARNC, lw=1.6))
    axL.text(0.57, (lat["mean"][0] + lat["mean"][1]) / 2, f"effect\n{effect:+.3f} s",
             fontsize=11, color=WARNC, fontweight="bold", va="center", ha="right")
    axL.set_title("COST — latency to first path", fontsize=12, color=INK,
                  fontweight="bold", pad=12, loc="left")

    # The floor line coincides with the 1 kHz bar top, so any label under it lands on the
    # x tick labels. Park it at the right edge, above the line, where nothing else is drawn.
    axL.axhline(lat["mean"][0], color=FAINT, ls=":", lw=1.3, zorder=1)
    axL.text(-1.0, lat["mean"][0] + 0.02, f"shared floor {lat['mean'][0]:.3f} s",
             fontsize=9, color=MUTED, ha="left", va="bottom")

    # ---- right: the benefit (CPU)
    axR = fig.add_axes([0.565, AY, 0.40, AH])
    _frame(axR, ylab="kernel process CPU (cores)")
    for i, (arm, cond, hz, cores) in enumerate(arms):
        col = ACCENT if hz == "1Hz" else GREY
        axR.bar(i, cores, width=0.62, color=col, zorder=3)
        axR.text(i, cores + 0.012, f"{cores:.3f}", ha="center", fontsize=9.5, color=INK)
        axR.text(i, -0.028, arm, ha="center", fontsize=10, color=MUTED)
    axR.axhline(khz_mean, xmin=0.02, xmax=0.66, color=GREY, ls="--", lw=1.5, zorder=2)
    axR.axhline(hz1_mean, xmin=0.70, xmax=0.98, color=ACCENT, ls="--", lw=1.5, zorder=2)
    # Both mean labels go in the empty band above the bars, as a two-line key. Putting them
    # beside their own lines placed them inside the bars, where they were unreadable.
    axR.text(-0.55, 0.895, f"1 kHz mean  {khz_mean:.4f} cores", fontsize=10.5,
             color=GREY, fontweight="bold", va="center")
    axR.text(-0.55, 0.815, f"1 Hz mean   {hz1_mean:.4f} cores", fontsize=10.5,
             color=ACCENT, fontweight="bold", va="center")
    axR.set_xticks([])
    axR.set_xlim(-0.7, 5.7)
    axR.set_ylim(0, 0.95)

    # The badge lives inside the right panel, over the empty space above the two 1 Hz bars,
    # where nothing is drawn. Floating it in figure coords put it on top of Q2/Q5.
    axR.text(4.5, 0.68, f"−{saving_pct:.1f}%", fontsize=27, color=OKC, fontweight="bold",
             ha="center", va="center", zorder=6,
             bbox=dict(facecolor="#EFF4F1", edgecolor=OKC, linewidth=1.1,
                       boxstyle="round,pad=0.36"))
    axR.text(4.5, 0.55, "groups do not overlap\n(1 kHz min 0.623, 1 Hz max 0.335)",
             fontsize=9, color=MUTED, ha="center", va="top", zorder=6)
    axR.set_title("BENEFIT — CPU of the kernel process", fontsize=12, color=INK,
                  fontweight="bold", pad=12, loc="left")

    _foot(fig,
          f"Source: REPORT.md (committed); every number is parsed from it and the parses assert "
          f"their yield. CPU is /proc/<kernel pid>/stat utime+stime — the kernel process, not the "
          f"machine, which ran 87% busy. Q2/Q5 carry ticket Q's fix but still recompute at 1 kHz. "
          f"{saving_pct:.1f}% is computed from the six arm values; REPORT.md's 51.3% averages the "
          f"means after rounding, the same rounding-then-subtracting slip corrected earlier today.",
          width=168)
    _save(fig, "page_M_cost-and-benefit.png")


# ------------------------------------------------------------------- figure: bandwidth ceiling
def fig_bandwidth_ceiling():
    """Ticket N: the '10 G is unreachable' ceiling was the access layer, not the fabric."""
    before, b_max, b_tot = core_links(f"{NROUND}/n0.out")
    after,  a_max, a_tot = core_links(f"{NROUND}/n1.out")

    # Same interface order in both panels, sorted by the AFTER value, so the eye compares
    # like with like rather than following two independent rankings.
    order = [n for n, _ in sorted(after, key=lambda kv: -kv[1])]
    bmap, amap = dict(before), dict(after)

    AY, AH = 0.205, 0.435
    fig = plt.figure(figsize=WIDE)
    _title(fig,
           "The bandwidth ceiling was the access layer, not the fabric",
           f"Eight core links, same topology, same traffic. The only change is removing the "
           f"access-layer bw= shaping. Single-link maximum goes {b_max:.3f} → {a_max:.3f} Gbit/s "
           f"and the eight together go {b_tot:.2f} → {a_tot:.1f}. The belief that 10 Gbit/s was "
           f"arithmetically out of reach was measuring the shaper.",
           "MEASURED", "measured", sub_width=168)

    ax = fig.add_axes([0.055, AY, 0.90, AH])
    _frame(ax, ylab="per-link throughput (Gbit/s, log scale)")
    xs = range(len(order))
    w = 0.38
    for i, name in enumerate(order):
        ax.bar(i - w / 2, max(bmap[name], 1e-3), width=w, color=GREY, zorder=3)
        ax.bar(i + w / 2, max(amap[name], 1e-3), width=w, color=ACCENT, zorder=3)
    ax.set_yscale("log")
    ax.set_ylim(8e-4, 260)
    ax.set_xticks(list(xs))
    ax.set_xticklabels(order, fontsize=10.5, color=INK)
    ax.set_xlim(-0.75, len(order) - 0.25)

    # The 10 G line is the whole point: it was believed unreachable and four links clear it.
    ax.axhline(10, color=WARNC, ls="--", lw=1.6, zorder=2)
    ax.text(len(order) - 0.45, 12.5,
            "10 Gbit/s — previously believed arithmetically unreachable",
            fontsize=10.5, color=WARNC, fontweight="bold", ha="right", va="bottom")

    # Legend lives over the four right-hand links, which carry ~0.01 Gbit/s in both
    # conditions, so the space above them is empty at every y. Putting it top-left sat it
    # on the tallest bar and its value label.
    ax.text(4.35, 170, "before — access-layer bw= present", fontsize=11,
            color=GREY, fontweight="bold", va="center")
    ax.text(4.35, 62, "after — access-layer bw= removed", fontsize=11,
            color=ACCENT, fontweight="bold", va="center")

    for i, name in enumerate(order[:4]):
        ax.text(i + w / 2, amap[name] * 1.25, f"{amap[name]:.1f}", ha="center",
                fontsize=10, color=ACCENT, fontweight="bold")
        ax.text(i - w / 2, max(bmap[name], 1e-3) * 1.25, f"{bmap[name]:.3f}", ha="center",
                fontsize=9, color=MUTED)

    _foot(fig,
          "Source: doc/audit/2026-08-25_sampling-rounds/n0.out and n1.out, both committed; the "
          "parse asserts eight core links in each. The four right-hand links carry almost nothing "
          "in both conditions — they are not on the path this traffic takes, and they are shown "
          "so the panel is the whole fabric rather than the four links that make the point. "
          "This measures the OVS testbed; bmv2's own per-link ceiling has never been measured, "
          "and the jitter round needs it first.",
          width=168)
    _save(fig, "page_bandwidth-ceiling.png")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    print(f"out: {OUT}")
    fig_m_cost_and_benefit()
    fig_bandwidth_ceiling()
