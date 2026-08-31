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

# --- the deck is version-locked, and the divergence is measured, not hypothetical -----------
# [Co-developed with claude code -- Adam]
# There are two matplotlibs reachable here and they are easy to confuse, because .plotvenv's
# python IS miniconda's python -- the same binary, symlinked, with a different site-packages:
#
#     .plotvenv/bin/python3  -> /home/adam/miniconda3/bin/python3.13   matplotlib 3.11.1
#     miniconda3/bin/python3 -> /home/adam/miniconda3/bin/python3.13   matplotlib 3.10.8
#
# Same interpreter, opposite answers to "is matplotlib installed". Rendered 2026-08-28 on both:
#
#                                     3.11.1        3.10.8      bottom margin differs by
#     page_bandwidth-ceiling.png      27 px         45 px               18 px
#     page_M_cost-and-benefit.png     65 px         79 px               14 px
#
# and the PNGs differ by hash. The margins are what the crop fix (54551bc) was verified on, so
# the verification is version-dependent. Worse, measured directly: the pre-fix figure that
# 3.11.1 renders CLIPPED (0 px margin, 0.1411 ink on the last pixel row) renders CLEAN on
# 3.10.8 (11 px, 0.0000). On the wrong interpreter the defect does not reproduce at all, so a
# reviewer would conclude there was never a bug -- and a deck rendered there is silently
# different from the one in the slide directory.
#
# Hence: refuse by default rather than warn. The escape hatch exists because .plotvenv is a
# single point of failure five days before 9/03, but taking it has to be a decision someone
# made, not a default they fell into.
_WANT_MPL = "3.11.1"
if matplotlib.__version__ != _WANT_MPL and not os.environ.get("DECK_ALLOW_MPL_MISMATCH"):
    sys.exit(
        f"\nplot_deck_903_round2.py: WRONG MATPLOTLIB -- refusing to render.\n"
        f"  want        : {_WANT_MPL}\n"
        f"  got         : {matplotlib.__version__}\n"
        f"  interpreter : {sys.executable}\n"
        f"  use         : \"/home/adam/Desktop/NDTwin slide material/"
        f"NDTwin Slide material 820/.plotvenv/bin/python3\"\n\n"
        f"These versions do not render the same figure: bottom margins differ by 14-18 px and\n"
        f"the pre-fix clipping defect does not even reproduce on 3.10.8. Set\n"
        f"DECK_ALLOW_MPL_MISMATCH=1 to override, and then do not compare the output against\n"
        f"any margin measured on {_WANT_MPL}.\n")

REPO = "/home/adam/Desktop/NDTwin-Kernel"
HERE = f"{REPO}/doc/audit/2026-08-28_QM-mirrored-block"
PRIOR = f"{REPO}/doc/audit/2026-08-27_hardcoded-denominator"

# Reuse the deck's palette and the tracked-source guard rather than restating either.
sys.path.insert(0, PRIOR)
from plot_deck_903 import (  # noqa: E402
    BAND, AXES_Y, AXES_H, DPI, WIDE, INK, MUTED, GREY, FAINT, PANEL, RULE,
    ACCENT, ACCENT_BG, WARNC, WARN_BG, OKC, _read, _frame, _title, _foot,
    _title_clean,
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


def run_context(path):
    """(flows, busy_pct, saturated) for a ticket-N cell -- the conditions the rates were taken under.

    [Co-developed with claude code -- Adam]
    Parsed rather than written into the caption, for the reason the 2026-08-27 round is named
    after: a hardcoded number in a figure cannot track a re-measurement, and the two cells
    differ on every one of these (32 flows both, but 35.1% vs 98.7% busy, NOT SATURATED vs
    SATURATED). The footer's disclosure is only worth anything if it moves with the data.
    """
    txt = _read(path)
    m = re.search(r"===\s*cell\s+\S+:\s*(\d+)\s*flows\s*x\s*(\d+)s", txt)
    assert m, f"{path}: no 'N flows x Ns' cell header"
    b = re.search(r"aggregate busy\s+([\d.]+)%", txt)
    assert b, f"{path}: no 'aggregate busy' line"
    s = re.search(r"->\s*(NOT SATURATED|SATURATED)", txt)
    assert s, f"{path}: no saturation verdict"
    return int(m.group(1)), float(b.group(1)), s.group(1) == "SATURATED"


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
    # Subtitle, the PRE-REGISTERED/POST-HOC stamp and the footer moved to the 903 slide
    # template §G (clean-figure ruling, 2026-08-30). The registration-status distinction is a
    # REQUIRED page note there -- it must reach the audience, just not via the image.
    _title_clean(fig,
                 "Ticket M, both halves measured: it costs half a second and buys half a core",
                 "six mirrored arms · one fabric generation · 1 kHz vs 1 Hz sampling")

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
    # "groups do not overlap (1 kHz min 0.623, 1 Hz max 0.335)" -> template §G.
    axR.set_title("BENEFIT — CPU of the kernel process", fontsize=12, color=INK,
                  fontweight="bold", pad=12, loc="left")

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

    On the ratio, for the audit record and deliberately NOT for the slide: 109x is the most
    CONSERVATIVE framing available in this data, not the most flattering one. It divides one
    OVS link's ECMP share (53.1) by bmv2's single-flow delivered ceiling (486 Mbit/s). Compared
    like for like on aggregate -- all eight OVS core links at 121.9 Gbit/s against bmv2's
    sixteen-flow ~48 Mbit/s -- the gap is about 2540x, over twenty times larger. Whoever chose
    109x had the bigger number available and did not use it.

    (2026-08-30, added on inheritance: the ~48 Mbit sixteen-flow figure is the
    scattered-four-path measurement; the same-path sixteen-flow value measured in round 2 is
    ~32 Mbit, which would push the like-for-like gap to ~3800x. The paragraph above is kept as
    written because its point is the framing's conservatism, and the correction moves further
    in the same direction. [Co-developed with claude code -- Adam])

    That is worth writing down because the criticism of this figure is real but narrow: the
    two sides of the ratio are different units of aggregation (32 flows on one link vs one
    flow), which is why the word "ceilings" in a headline over it is wrong for the OVS side.
    The number is not inflated; the frame around it is. Those are separate findings and
    collapsing them into "the 109x is overstated" would be false.
    """
    before, b_max, b_tot = core_links(f"{NROUND}/n0.out")
    after, a_max, a_tot = core_links(f"{NROUND}/n1.out")
    n0_flows, n0_busy, n0_sat = run_context(f"{NROUND}/n0.out")
    n1_flows, n1_busy, n1_sat = run_context(f"{NROUND}/n1.out")
    low, high = bmv2_ladder()

    order = [n for n, _ in sorted(after, key=lambda kv: -kv[1])]
    bmap, amap = dict(before), dict(after)

    # Kept computed from the data although nothing on the slide draws it any more (Adam took
    # the ratio off the figure, 2026-08-28). It is still quoted in this function's docstring
    # and in the round's notes, and it is printed at render time.
    #
    # History worth not losing: the title once carried the literal "113x" while the badge
    # computed 109x from the same data -- the slide contradicted itself in two places, and the
    # hardcoded half could never track a re-measurement. Same shape as the 08-27
    # hardcoded-denominator round, in our own figure. That is why this stays an expression.
    ratio = a_max * 1000 / high[-1][2]

    AY, AH = 0.265, 0.365   # bottom raised with BAND["foot"]; see AXES_Y in the sibling script
    fig = plt.figure(figsize=WIDE)
    # Title is Adam's ruling, 2026-08-28: what was the closing line of the subtitle is now the
    # headline, and the ratio is off the slide entirely. The reason is more general than the
    # wording problem I reported ("ceilings" is wrong for the OVS side): ANY ratio puts two
    # different units of aggregation on the same line -- one link's ECMP share of 32 flows
    # against a single flow -- so fixing the noun would not fix the root. Non-transferability
    # is the actual finding and it does not need a ratio to stand up.
    # Subtitle, the MEASURED stamp, the ECMP caveat box and the footer moved to the 903
    # slide template §G (clean-figure ruling, 2026-08-30). Two of them are REQUIRED page
    # notes there: the ECMP "not a capacity floor" caveat (the ~9000x misread guard) and
    # "OVS values are measured throughput, not capacity".
    # 2026-08-31: the parameter line disclosed the RIGHT side's unit of aggregation ("single
    # flow") and not the left's, and the missing half is the one that makes a cross-plane
    # reading look reasonable -- 53.1 is one link's ECMP share of a 32-flow, host-saturated run,
    # not a link's capacity. This is the same asymmetry the footer carried until 2026-08-28 and
    # for the same reason: the bmv2 caveat was there from the start and the OVS one was not.
    # This restores the missing PARAMETER, not the footer -- the clean-figure ruling (2026-08-30,
    # template §G) stands and nothing else returns to the image. Wording is template §G2's
    # REQUIRED footer verbatim; both numbers are parsed rather than written for the reason
    # run_context's docstring gives. [Co-developed with claude code -- Adam]
    _title_clean(fig,
                 "A working point from one plane means nothing on the other",
                 f"left: OVS core links, access-layer bw= removed, {n1_flows} TCP flows, "
                 f"{a_max:.1f} is one link's ECMP share · right: bmv2 −O3 build, single flow")

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
    # The four short bars are not a capacity floor and must not be read as one. n1.out says
    # "ECMP split across the top four", and these are the other four: the hash sent almost no
    # traffic their way, so their value is "what happened to cross", not "what could". Without
    # this line the panel reads as a ~9000x spread between links of the same class, which is
    # false. Kept rather than dropped because "ECMP concentrates onto four" is itself true and
    # useful -- the fix is to label the bars, not to hide them.
    # Placed over the empty band above the short bars, not over the tall ones: the first
    # attempt sat at x≈3.5 and rendered on top of the s5-eth3/s6-eth3 grey bars, which the
    # bottom-margin check cannot see. Only looking at the PNG catches that.
    # The "not a capacity floor" ECMP caveat that pointed at the four short bars moved to
    # template §G as a REQUIRED page note (clean-figure ruling, 2026-08-30) -- the protection
    # against the ~9000x misread must survive, just off the image.
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

    # The 109x badge that used to sit in the gutter is gone, and so is the ratio from the
    # title. The auditor's condition for keeping it was that it carry its qualifiers in place
    # -- single link, 32 flows, ECMP share, host-saturated -- and a badge cannot: it is read
    # at slide distance in half a second, which is exactly why a bare number there is worse
    # than none. The qualifiers now live in the footer, where there is room for them, and the
    # framing analysis lives in this function's docstring, which is the audit record.
    #
    # The ratio is still computed and still comes from the data rather than a literal, because
    # it is quoted in the docstring and in the round's notes. It is printed rather than drawn:
    # it stays live and re-measurable without going on the slide.
    print(f"  [audit] OVS single-link max / bmv2 single-flow ceiling = {ratio:.1f}x "
          f"(NOT for the slide: different units of aggregation -- see docstring)")

    # Both sides now disclose how their number was taken, not just bmv2's. The bmv2 caveat was
    # here from the start; the OVS one was not, and the two numbers are not the same kind of
    # measurement -- one is a single flow, the other is one link's ECMP share of 32. Stating
    # only the bmv2 half made the comparison look tighter than it is.
    # Width raised from 168 with the text tightened to hold the line count at five. The footer
    # is anchored at BAND["foot"] with va="top", so it grows DOWNWARD into roughly 207 px of
    # room; five lines fit with ~27 px to spare and six do not. Adding the OVS disclosure at
    # the old width took it to seven lines and reproduced 54551bc's clipping exactly (bottom
    # margin 0 px, 0.1993 ink on the last row) -- measured, not predicted. BAND is shared with
    # every other figure in both scripts, so the room cannot be taken from there.
    print(f"  [audit] BW-ceiling context (template §G carries the prose): after-run "
          f"{n1_flows} flows, host busy {n1_busy:.1f}%, agg {a_tot:.1f} G; before-run busy "
          f"{n0_busy:.1f}%, shaper max {b_max:.3f} G")
    _save(fig, "page_bandwidth-ceiling.png")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    print(f"out: {OUT}")
    fig_m_cost_and_benefit()
    fig_bandwidth_ceiling()
