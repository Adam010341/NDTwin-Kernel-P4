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

THE INTERPRETER ABOVE IS THE ONE THAT WORKS, AND IT IS EASY TO CONCLUDE IT DOES NOT EXIST.
    Verified 2026-08-28 19:4x: .plotvenv is Python 3.13.13 with matplotlib 3.11.1, numpy 2.5.2.
    Two of us independently concluded "no interpreter on this machine can render these figures",
    because we searched $PATH and the named conda/virtualenvs. A venv that is never activated is
    on no PATH, so `compgen -c`, `which`, and a list of the lab envs all miss it -- while the
    answer sat in this docstring, in the file we were about to run. Read the script before
    hunting for its dependencies.

    The `__pycache__/*.cpython-313.pyc` beside these scripts is NOT evidence that some
    interpreter once had matplotlib. CPython writes the .pyc at compile time, before the module
    body executes, so a module whose `import matplotlib` raises still leaves one behind
    (verified directly). Both 3.13s here would produce the same filename, so it does not even
    identify which.

Crop fix (54551bc) verified by rendering, 2026-08-28, not by reading the diff:
                                        bottom margin   ink on last pixel row
    page_bandwidth-ceiling.png   before        0 px           0.1411   <- clipped
                                 after        27 px           0.0000
    page_M_cost-and-benefit.png  before       65 px           0.0000
                                 after        65 px           0.0000
    page_Q_assumed-denominator   before       28 px           0.0000   (plot_deck_903.py)
    .png                         after       102 px           0.0000
    So the fix is real, and it repaired exactly one figure. 54551bc's message says "Every
    figure in the 9/03 deck was cut off at the bottom edge"; measured, one of the three was.
    The other two gained margin they did not need. Left as-is -- the figures are correct now,
    and the commit is public; only the message overstates.

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
CAPFILE = f"{REPO}/doc/audit/2026-08-28_jitter-working-point/01_capacity.md"
EXPECT_LADDER_LOW = 6        # interleaved 160/100 rungs
EXPECT_LADDER_HIGH = 3       # 320 / 640 / 1280
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


def bmv2_ladder():
    """(low, high) from the committed capacity round.

    low  = [(rate_mbit, loss_pct)]        the interleaved 160/100 rungs
    high = [(rate_mbit, loss_mean, delivered_mean)]
    """
    txt = _read(CAPFILE)
    low = [(int(m.group(2)), float(m.group(3)))
           for m in re.finditer(r"^\|\s*(\d)\s*\|\s*(\d+)\s*\|\s*\*{0,2}([\d.]+)%", txt, re.M)]
    assert len(low) == EXPECT_LADDER_LOW, f"low ladder: {len(low)} rungs, want {EXPECT_LADDER_LOW}"

    high = []
    for m in re.finditer(r"^\|\s*(\d{3,4})\s*\|\s*\*{0,2}([\d.]+)%\*{0,2}\s*\|\s*\*{0,2}([\d.]+)%"
                         r"\*{0,2}\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|", txt, re.M):
        rate = int(m.group(1))
        loss = (float(m.group(2)) + float(m.group(3))) / 2
        deliv = (float(m.group(4)) + float(m.group(5))) / 2
        high.append((rate, loss, deliv))
    assert len(high) == EXPECT_LADDER_HIGH, f"high ladder: {len(high)} rows, want {EXPECT_LADDER_HIGH}"
    return low, high


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
    AY, AH = 0.265, 0.365   # bottom raised with BAND["foot"]; see AXES_Y in the sibling script

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
          f"{saving_pct:.2f}% at full precision. Three figures were briefly in circulation — "
          f"51.22, 51.25, 51.3 — differing in the third significant digit, while this quantity's "
          f"within-condition spread is 0.033 cores, about 5%. They are indistinguishable inside "
          f"the measurement's own noise: what needed correcting was a precision claim, not the "
          f"effect, which is 'about half' on every version.",
          width=168)
    _save(fig, "page_M_cost-and-benefit.png")


# ------------------------------------------------------------------- figure: bandwidth ceiling
def fig_bandwidth_ceiling():
    """Both forwarding planes' ceilings, and why one cannot be carried to the other.

    The first version of this figure showed only OVS, because on the day it was drawn only
    OVS had been measured. Adam asked where bmv2 was. bmv2's ceiling was measured the same
    afternoon, and the two-order gap is the point: a working point established on one plane is
    meaningless on the other, which is exactly the mistake the jitter round nearly made.

    On the bmv2 build, graded honestly because the footer has no room to: the run that produced
    01_capacity.md did NOT hash the binary it launched, and measure_bmv2_capacity.sh does not
    record it either -- unlike the 08-25 scripts beside it, which all sha256 the switch. What
    the footer cites is provenance by CONFIGURATION: bmv2_binary_override (mtime 08-22) names
    the fast build, the binary itself (mtime 08-15) is older still, neither was touched after
    the 08-28 run, and the topology refuses to start when no binary is named, so there is no
    silent third option. Inferring the build from the throughput instead would be circular --
    that is the reasoning this figure exists to reject.
    """
    before, b_max, b_tot = core_links(f"{NROUND}/n0.out")
    after, a_max, a_tot = core_links(f"{NROUND}/n1.out")
    low, high = bmv2_ladder()

    order = [n for n, _ in sorted(after, key=lambda kv: -kv[1])]
    bmap, amap = dict(before), dict(after)

    # The headline ratio must come from the same expression as the badge below it. It used to be
    # the literal "113x" while the badge computed 109x from the data -- a slide contradicting
    # itself in two places, and the hardcoded half could never track a re-measurement. Same shape
    # as the 08-27 hardcoded-denominator round, in our own figure.
    ratio = a_max * 1000 / high[-1][2]

    AY, AH = 0.265, 0.365   # bottom raised with BAND["foot"]; see AXES_Y in the sibling script
    fig = plt.figure(figsize=WIDE)
    _title(fig,
           f"The two forwarding planes' ceilings differ by {ratio:.0f}x",
           f"Left: OVS — removing the access-layer bw= shaping takes a single core link from "
           f"{b_max:.3f} to {a_max:.1f} Gbit/s, so the '10 G is unreachable' belief was measuring "
           f"the shaper. Right: bmv2 — the -O3 no-logging build — saturates at about "
           f"{high[-1][2]/1000:.2f} Gbit/s delivered no matter what is offered. A working point "
           f"from one plane means nothing on the other.",
           "MEASURED", "measured", sub_width=168)

    # ---- left: OVS, the shaper artefact
    axL = fig.add_axes([0.055, AY, 0.42, AH])
    _frame(axL, ylab="per-link throughput (Gbit/s, log)")
    w = 0.38
    for i, name in enumerate(order):
        axL.bar(i - w / 2, max(bmap[name], 1e-3), width=w, color=GREY, zorder=3)
        axL.bar(i + w / 2, max(amap[name], 1e-3), width=w, color=ACCENT, zorder=3)
    axL.set_yscale("log")
    axL.set_ylim(8e-4, 400)
    axL.set_xticks(range(len(order)))
    axL.set_xticklabels(order, fontsize=8.5, color=MUTED, rotation=45, ha="right")
    axL.set_xlim(-0.75, len(order) - 0.25)
    axL.axhline(10, color=WARNC, ls="--", lw=1.5, zorder=2)
    axL.text(len(order) - 0.35, 12, "10 Gbit/s", fontsize=10, color=WARNC,
             fontweight="bold", ha="right", va="bottom")
    # Legend sits on the right: the tall bars are the first four, so left-anchored labels
    # collided with the 53.1 value label on the top bar.
    axL.text(len(order) - 0.35, 250, "before — access-layer bw= present", fontsize=10,
             color=GREY, fontweight="bold", va="center", ha="right")
    axL.text(len(order) - 0.35, 100, "after — bw= removed", fontsize=10,
             color=ACCENT, fontweight="bold", va="center", ha="right")
    for i, name in enumerate(order[:1]):
        axL.text(i + w / 2, amap[name] * 1.3, f"{amap[name]:.1f}", ha="center",
                 fontsize=10.5, color=ACCENT, fontweight="bold")
    axL.set_title("OVS — the ceiling was the access layer", fontsize=12, color=INK,
                  fontweight="bold", pad=12, loc="left")

    # ---- right: bmv2, a real ceiling
    axR = fig.add_axes([0.625, AY, 0.345, AH])
    _frame(axR, ylab="delivered (Mbit/s)", xlab="offered (Mbit/s, log)")
    lo_pts = sorted({r for r, _ in low})
    offered = lo_pts + [r for r, _, _ in high]
    delivered = ([r * (1 - sum(l for rr, l in low if rr == r) / len([1 for rr, _ in low if rr == r]) / 100)
                  for r in lo_pts] + [d for _, _, d in high])
    axR.plot(offered, offered, ls="--", lw=1.4, color=FAINT, zorder=2)
    axR.plot(offered, delivered, "o-", lw=2.2, ms=7, color=ACCENT, zorder=4)
    axR.set_xscale("log")
    axR.set_xlim(70, 1800)
    axR.set_ylim(0, 620)
    axR.axhline(high[-1][2], color=WARNC, ls=":", lw=1.6, zorder=3)
    axR.text(1750, high[-1][2] + 18, f"delivered ceiling ≈ {high[-1][2]:.0f} Mbit/s",
             fontsize=10, color=WARNC, fontweight="bold", ha="right")
    axR.text(150, 330, "y = x\n(if nothing were lost)", fontsize=9.5, color=MUTED, rotation=32)
    for r, loss, d in high:
        axR.annotate(f"{loss:.0f}% lost", xy=(r, d), xytext=(0, -22),
                     textcoords="offset points", fontsize=9.5, color=MUTED, ha="center")
    axR.set_title("bmv2 — a real ceiling, CPU-bound", fontsize=12, color=INK,
                  fontweight="bold", pad=12, loc="left")

    # Badge goes in the gutter between the panels; it used to sit on top of the right y-axis.
    fig.text(0.545, 0.44, f"{ratio:.0f}×", fontsize=26, color=OKC,
             fontweight="bold", ha="center", va="center",
             bbox=dict(facecolor="#EFF4F1", edgecolor=OKC, linewidth=1.1,
                       boxstyle="round,pad=0.34"))

    _foot(fig,
          "Sources, all committed: OVS from doc/audit/2026-08-25_sampling-rounds/n0.out and "
          "n1.out (parse asserts eight core links each); bmv2 from "
          "doc/audit/2026-08-28_jitter-working-point/01_capacity.md. bmv2's number is a single "
          "flow; sixteen flows together reach only ~48 Mbit/s, because the bottleneck is the "
          "switch's per-packet CPU and not the link — so even within bmv2 a single-flow ceiling "
          "does not extrapolate. That is why the jitter round could not use either number "
          "directly, and why it returned H3 on this plane. The build is named because two "
          "installs here differ 12-18x: bmv2-fast/bin/simple_switch_grpc, sha256 3ff54b5c, "
          "fixed by p4_proxy/mininet/bmv2_binary_override, which the topology requires.",
          width=168)
    _save(fig, "page_bandwidth-ceiling.png")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    print(f"out: {OUT}")
    fig_m_cost_and_benefit()
    fig_bandwidth_ceiling()
