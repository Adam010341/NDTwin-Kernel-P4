#!/usr/bin/env python3
# Deck figures 5-8 for the 9/03 report (and future paper use), plus fig5b
# (2026-09-02): the fig5 matrix over all 34 coded bmv2-measuring papers.
# fig5/fig6: literature survey. fig7: aggregate two-planes (data stated in
# audit/2026-08-30_ovs-flowcount-control/FINDINGS.md). fig8: folk-knowledge
# diagram (facts from study s1 item 4 and s2-1 row 13).
# Data source: doc/2026-08-29_bmv2-performance-study.md s2-1 census table and
# its statistics paragraph (revision b2cd6b5, table at lines 120-148).
# Where an entry also appears in fig4 (make_figs.py, poster line), the
# fig4-vetted tuple is reused verbatim (e.g. TSSA "106 B frame" accounting).
# Style matches the fig1-4 family: Okabe-Ito, 7.5 pt, dpi 200, no top/right
# spines. Regenerate with the .plotvenv interpreter (matplotlib 3.11.x):
#   "$HOME/Desktop/NDTwin slide material/NDTwin Slide material 820/.plotvenv/bin/python" make_survey_figs.py
# [Co-developed with claude code -- Adam]

import os
import matplotlib

assert matplotlib.__version__.startswith("3.11"), (
    f"matplotlib {matplotlib.__version__}: use the .plotvenv interpreter "
    "(3.11.x) or layouts will drift; see script header."
)
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyBboxPatch

OUT = os.path.dirname(os.path.abspath(__file__))

C_A = "#0072B2"   # filled = stated in the paper (Okabe-Ito blue)
C_B = "#E69F00"   # half   = qualitative mention only (Okabe-Ito orange)
C_HL = "#D55E00"
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


# The 12 bmv2-measuring papers, census-table order (study s2-1 rows 1-12).
PAPERS = [
    "TOMACS '25", "PADS '23", "PADS '24", "ICNCC '23", "TSSA '23",
    "SOSR '17", "P4CEP '18", "P4-NIDS '24", "PoliTO thesis", "PADS '26",
    "Network '25", "P4sim '25",
]

# rows follow PAPERS; qualitative halves: ICNCC flags ("compiled in a
# non-logging mode", no flags), TSSA pkt-size (two points, qualitative
# attribution, never converted to pps).
M12 = [
    # thr var ver flg A/B pkt pps flw cmp | 2nd  (2nd = second plane measured, added 2026-09-02)
    [1, 1, 0, 0, 0, 0, 0, 0, 0, 1],   # TOMACS '25
    [1, 1, 0, 0, 0, 0, 0, 0, 0, 1],   # PADS '23
    [1, 0, 0, 0, 0, 0, 0, 0, 0, 1],   # PADS '24
    [1, 0, 1, 0.5, 0, 0, 0, 0, 0, 1],   # ICNCC '23
    [1, 0, 0, 0, 0, 0.5, 0, 0, 0, 0],   # TSSA '23
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 1],   # SOSR '17 (latency only)
    [1, 0, 0, 0, 0, 0, 1, 0, 0, 1],   # P4CEP '18
    [1, 0, 0, 0, 0, 0, 0, 0, 0, 1],   # P4-NIDS '24
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],   # PoliTO (delay only)
    [1, 1, 0, 0, 0, 0, 0, 0, 0, 1],   # PADS '26
    [1, 0, 0, 0, 0, 0, 0, 0, 0, 1],   # Network '25
    [1, 0, 0, 0, 0, 0, 0, 0, 0, 0.5],   # P4sim '25
]

# ---------------------------------------------------------------- fig 5
# Reporting matrix. Cell values: 1 = stated, 0.5 = qualitative mention only,
# 0 = absent from the full text. Column totals are the statistics paragraph's
# own fractions -- asserted below so this figure cannot drift from the study.
def fig5():
    cols = ["throughput\nnumber", "variant", "version", "build\nflags",
            "build\nA/B", "pkt-size\nsweep", "pps\nbasis",
            "flows as\nvariable", "comparison\nplane"]
    totals = ["10/12", "3/12", "1/12", "0/12", "0/12", "0/12",
              "1/12", "0/12", "0/12"]
    M = M12
    for j, want in enumerate(totals):  # guard: figure == study statistics
        got = sum(1 for r in M if r[j] == 1)
        assert f"{got}/12" == want, (cols[j], got, want)

    nr, nc = len(M), len(cols)
    fig, ax = plt.subplots(figsize=(4.1, 2.9))
    for i in range(nr):
        y = nr - 1 - i
        for j in range(nc):
            v = M[i][j]
            if v == 1:
                ax.add_patch(Rectangle((j + 0.12, y + 0.12), 0.76, 0.76,
                                       facecolor=C_A, edgecolor="none"))
            elif v == 0.5:
                ax.add_patch(Rectangle((j + 0.12, y + 0.12), 0.38, 0.76,
                                       facecolor=C_B, edgecolor="none"))
                ax.add_patch(Rectangle((j + 0.12, y + 0.12), 0.76, 0.76,
                                       facecolor="none", edgecolor="#bbbbbb",
                                       lw=0.5))
            else:
                ax.add_patch(Rectangle((j + 0.12, y + 0.12), 0.76, 0.76,
                                       facecolor="white", edgecolor="#cccccc",
                                       lw=0.5))
    ax.set_xlim(0, nc)
    ax.set_ylim(-2.05, nr)
    ax.set_xticks([j + 0.5 for j in range(nc)],
                  [c.replace("\n", " ") for c in cols], fontsize=6.0,
                  rotation=32, ha="left", rotation_mode="anchor")
    ax.xaxis.set_ticks_position("top")
    ax.tick_params(axis="x", length=0)
    ax.set_yticks([nr - 1 - i + 0.5 for i in range(nr)], PAPERS, fontsize=6.5)
    ax.tick_params(axis="y", length=0)
    for j, t in enumerate(totals):
        bold = t.startswith("0") or cols[j].startswith("variant")
        # 2026-09-02: totals sat on the last row's cell edge (baseline at
        # -0.28 put the glyph tops above y=0.12) and collided with it when
        # the figure is scaled to .82\linewidth in the 2-page version.
        # Anchor the totals' top edge below the cells instead.
        ax.annotate(t, (j + 0.5, -0.2), ha="center", va="top", fontsize=6.5,
                    fontweight="bold" if bold else "normal",
                    color=C_HL if t == "0/12" else "#333333")
    ax.annotate("filled = stated in the paper; half = qualitative mention only\n"
                "variant 3/12 = one lab lineage (2/11 as independent works)",
                (0, -0.88), va="top", fontsize=5.8, color="#555555")
    for s in ("left", "bottom"):
        ax.spines[s].set_visible(False)
    save(fig, "fig5_reporting_matrix")


# ---------------------------------------------------------------- fig 6
# Twelve headline numbers, one axis. Dots/intervals are each paper's own
# headline figure from the census table; rows with no dot have no bit-rate
# headline to place. Fernando drawn distinct: a working point 3-6 orders
# below the datapath ceiling, excluded from the spread statistics (s2-1
# row 11). TSSA tuple reused from fig4 (vetted frame accounting).
def fig6():
    rows = [  # (label, lo, hi, note, kind)
        ("TOMACS '25",   170, None, "grpc ($\\circ$: simple_switch)", "dot2"),
        ("PADS '23",     212, 1000, "ring, per-pair", "dot"),
        ("PADS '24",     145, 175, "VM / native", "dot"),
        ("ICNCC '23",   1000, 1400, "phys. NIC", "dot"),
        ("TSSA '23",   0.574, 0.757, "106 B frame", "dot"),
        ("SOSR '17",    None, None, "latency only (parse: 11.2 ms)", "none"),
        ("P4CEP '18",   None, None, "$\\approx$12 kpps at min-size — pps basis, the corpus's only", "none"),
        ("P4-NIDS '24",   80, None, "CPU self-report 0.3% — as-is", "dot"),
        ("PoliTO thesis", None, None, "delay only (RTT 0.98 / 2.16 ms)", "none"),
        ("PADS '26",    None, None, "headline: per-switch RTT 729.4 $\\mu$s", "none"),
        ("Network '25", None,   96, "working point, 3–6 orders below ceiling", "excl"),
        ("P4sim '25",     43, None, "saturation", "dot"),
    ]
    FLAG_X = 42000  # right-hand flags column, outside the data axis
    nr = len(rows)
    fig, ax = plt.subplots(figsize=(3.8, 3.0))
    for i, (lbl, lo, hi, note, kind) in enumerate(rows):
        y = nr - 1 - i
        if kind in ("dot", "dot2"):
            if hi:
                ax.plot([lo, hi], [y, y], "-", color=C_LIT, lw=2.5,
                        solid_capstyle="round", zorder=2)
            ax.scatter([lo], [y], color=C_LIT, s=14, zorder=3)
            if kind == "dot2":  # secondary variant, as stated in the paper
                ax.scatter([1000], [y], facecolors="white", edgecolors=C_LIT,
                           s=14, zorder=3)
                ax.annotate(note, (lo / 1.5, y + 0.02), ha="right",
                            va="center", fontsize=5.6, color="#666666")
            else:
                ax.annotate(note, ((hi or lo) * 1.4, y + 0.02),
                            va="center", fontsize=5.6, color="#666666")
        elif kind == "excl":
            ax.plot([0.42, hi], [y, y], "--", color="#aaaaaa", lw=1.2, zorder=2)
            ax.scatter([hi], [y], facecolors="white", edgecolors="#aaaaaa",
                       s=14, zorder=3)
            ax.annotate("$\\leftarrow$ from 6.3 Kbps", (0.46, y - 0.45),
                        fontsize=5.4, color="#888888")
            ax.annotate(note, (hi * 1.4, y + 0.02), va="center", fontsize=5.4,
                        color="#888888")
        else:
            ax.annotate(note, (0.46, y), va="center", fontsize=5.8,
                        color="#888888", style="italic")
        # right-hand column: does the row report build flags? (0/12)
        ax.annotate("✗", (FLAG_X, y), va="center", ha="center", fontsize=7,
                    color="#999999", annotation_clip=False)
    ax.annotate("build\nflags?", (FLAG_X, nr - 0.15), ha="center", fontsize=6,
                annotation_clip=False)
    ax.annotate("0/12", (FLAG_X, -0.62), ha="center", fontsize=6.5,
                fontweight="bold", color=C_HL, annotation_clip=False)
    ax.annotate("4/12 have no bit-rate headline · 1/12 is a working point, "
                "not a ceiling · 0/12 report build",
                (55, -1.35), ha="center", fontsize=6.6, fontweight="bold")
    ax.set_xscale("log")
    ax.set_xlim(0.4, 9000)
    ax.set_ylim(-1.8, nr - 0.3)
    ax.set_yticks([nr - 1 - i for i in range(nr)],
                  [r[0] for r in rows], fontsize=6.5)
    ax.tick_params(axis="y", length=0)
    ax.spines["left"].set_visible(False)
    ax.set_xlabel("published bmv2 throughput (Mbit/s, quantity types mixed)")
    save(fig, "fig6_twelve_numbers_one_axis")


# ---------------------------------------------------------------- fig 7
# Aggregate holds vs aggregate collapses. Every number is stated in
# audit/2026-08-30_ovs-flowcount-control/FINDINGS.md (b2cd6b5): the
# n/aggregate table (bmv2 160-240 / 120-180 / 32-16; OvS 540/960/720),
# the ~971 Mbit htb goodput cap, and "collapses to 30x below the cap".
# Red lines honoured: OvS n=1 carries "receiver-socket-limited"; the OvS
# ceiling is attributed to the configured cap; bmv2 wears no cap and the
# asymmetry is drawn, not hidden.
def fig7():
    n = [1, 4, 16]
    ovs = [540, 960, 720]
    bmv2_hi = [240, 180, 32]
    bmv2_lo = [160, 120, 16]
    fig, ax = plt.subplots(figsize=(3.4, 2.5))
    ax.axhline(971, color="#999999", lw=0.8, ls="--", zorder=1)
    ax.annotate("configured htb 1 Gbit cap ($\\approx$971 Mbit goodput)",
                (1.0, 1060), fontsize=5.8, color="#777777")
    ax.plot(n, ovs, "o-", color=C_A, lw=1.4, ms=4.5, zorder=3,
            label="OVS aggregate (1 Gbit-shaped fabric)")
    ax.scatter([1], [540], facecolors="white", edgecolors=C_A, s=26, zorder=4)
    ax.annotate("receiver-socket-limited", (1.07, 442), fontsize=5.5, color=C_A)
    ax.annotate("holds at the cap,\nsplit across flows", (17.8, 555),
                fontsize=5.8, color=C_A, ha="right", va="top")
    ax.fill_between(n, bmv2_lo, bmv2_hi, color=C_B, alpha=0.22, zorder=2)
    ax.plot(n, bmv2_hi, "s--", color=C_B, lw=1.0, ms=3.5, zorder=3,
            label="bmv2 aggregate (two arms, uncapped)")
    ax.plot(n, bmv2_lo, "s--", color=C_B, lw=1.0, ms=3.5, zorder=3)
    ax.annotate("upper edge at $n$=1: top-rung censored ($\\geq$240)",
                (1.07, 262), fontsize=5.4, color="#996600")
    ax.annotate("collapses $\\approx$10$\\times$ — to 30$\\times$ below\n"
                "the cap it does not even wear",
                (3.6, 42), fontsize=5.8, color=C_HL)
    ax.annotate("per-flow gap at $n$=16: 22–45$\\times$", (9.7, 20.0),
                fontsize=5.4, color="#555555")
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_xticks(n, [str(v) for v in n])
    # "UDP" is load-bearing, not decoration: the §B control (2026-09-01) measured the same
    # switch and the same five-hop path with TCP and got T(16)/T(1) = 1.222/1.108 -- no
    # collapse. The collapse this figure draws is UDP's. Both planes ran iperf3 -u, and the
    # rung criterion is a loss reading, so the qualifier belongs on the ladder itself.
    ax.set_xlabel("concurrent flows $n$ (same UDP ladder, mirrored arms)")
    ax.set_ylabel("aggregate delivered (Mbit/s)")
    ax.set_xlim(0.9, 19)
    ax.set_ylim(13, 1500)
    ax.legend(frameon=False, loc="lower left", fontsize=5.6)
    save(fig, "fig7_aggregate_two_planes")


# ---------------------------------------------------------------- fig 8
# Folk knowledge is not a reporting norm. Facts from study s1 item 4
# (performance.md quote verified there against main and f0b7d201; the
# ~1,047 Mbps / 80 kpps reference; issues #311/#823; ICNCC and TSSA cite
# the doc) and s2-1 (ICNCC qualitative-only build note; row 13 Zhang '21
# contrast: a commit per switch + per-switch parameter appendix).
def fig8():
    fig, ax = plt.subplots(figsize=(4.2, 2.3))
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 10)
    ax.axis("off")

    # hero: the official project's own sentence
    ax.text(5, 9.05,
            "“which flags were used to build bmv2:\n"
            "this can have a massive impact.”",
            ha="center", va="center", fontsize=7.8, style="italic",
            color="#222222")
    ax.text(5, 7.5,
            "— p4lang/behavioral-model, docs/performance.md, which also gives"
            " recommended flags\nand a reference figure"
            " (~1,047 Mbps median / 80 kpps, c4.2xlarge)",
            ha="center", va="center", fontsize=5.3, color="#666666")

    # three equal steps, left to right
    steps = [
        ("the knowledge\ncirculates",
         "docs · issues #311 / #823\nStack Overflow", "#999999"),
        ("two surveyed papers\ncite that document", "ICNCC '23 · TSSA '23",
         C_A),
        ("their own\nbuild flags",
         "not stated\n(ICNCC: qualitative only)", C_HL),
    ]
    for k, (head, sub, ec) in enumerate(steps):
        x0 = 0.3 + k * 3.25
        ax.add_patch(FancyBboxPatch((x0, 3.2), 2.85, 2.9,
                                    boxstyle="round,pad=0.10",
                                    facecolor="white", edgecolor=ec, lw=1.1))
        ax.text(x0 + 1.42, 5.45, head, ha="center", va="center",
                fontsize=5.7, fontweight="bold", color="#222222")
        ax.text(x0 + 1.42, 3.95, sub, ha="center", va="center",
                fontsize=5.1, color="#555555")
    for xa in (3.17, 6.42):
        ax.annotate("", xy=(xa + 0.42, 4.65), xytext=(xa - 0.04, 4.65),
                    arrowprops=dict(arrowstyle="-|>", color="#555555", lw=1.0))

    # verdict, then the contrast as a quiet footnote
    ax.text(5, 2.0,
            "Common knowledge is not a reporting norm — "
            "build flags stated: 0/12.",
            ha="center", fontsize=6.9, fontweight="bold")
    ax.text(5, 0.72,
            "contrast: Zhang, Comput. Netw. '21 (7 software switches, no"
            " bmv2) names a commit per switch\n(FastClick 9d5e9c6, t4p4s"
            " b1161b2, …) + per-switch parameters — the norm exists next door",
            ha="center", va="center", fontsize=5.1, color="#777777")
    save(fig, "fig8_known_but_never_reported")


# ---------------------------------------------------------------- fig 5b
# The fig5 matrix over all 34 bmv2-measuring papers coded so far: the 12
# corpus papers (rows = M12; columns thr/var/ver/flg/pkt/pps; the "limit
# check" column is the study's own "none of the 12 reports a check of what
# limited its measurement") plus the 22 papers found after the corpus froze
# and coded on the same sheet -- a post-hoc screen, not a census. Sources
# (poster-package, outside the repo): 80a A-3 rows 1-7, 80e s5.1 rows 1-11,
# 80f s1-s3 and s4.7. Column totals are asserted against 80f s7 "merged
# statistics" so the figure cannot drift from the audit sheet. Columns the
# screen did not code (build A/B, flows as variable, comparison plane) are
# omitted rather than drawn as absent. Cell values as in fig5: 1 stated,
# 0.5 qualitative mention only, 0 absent from the full text. Row-by-row
# provenance and the exact quotes: fig5b_reporting_matrix_34.md (same dir).
SCREEN = [
    # label,                  thr  var  ver  flg  pkt  pps  lim | A/B  flw  2nd  cmp   source
    ("P4-IPsec Access '20",      1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0),  # 80a #1
    ("MQTT-P4 arXiv '26",        1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0),  # 80a #2 kpps loads
    ("Tokmakov arXiv '20",       1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0),  # 80a #3 "Release 1.11.0"
    ("RL paths arXiv '25",       1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),  # 80a #4 relative only
    ("P4-MACsec Access '20",     0.5, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0),  # 80a #5 qualitative; IEEE version not obtained
    ("CEI-Net MedComNet '25",    1, 0, 0, 0, 0.5, 0, 0, 0, 0, 0, 0),  # 80a #6 MSS swept, throughput not per size
    ("SDN envs LNNS '26",        1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0),  # 80a #7; ver 0->1 2026-09-02 coverage audit (Table 4)
    ("APATCP Sci Rep '26",       1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0),  # 80e #1
    ("SFARP Sci Rep '25",        1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0),  # 80e #2
    ("MC-LBTO Sci Rep '25",      1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0),  # 80e #3
    ("SBRC '26",                 1, 0, 0, 0.5, 0, 0, 0, 0, 0.5, 0, 0),  # 80e #4 "adapted version" + performance.md, no flags
    ("WPEIF '26",                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),  # 80e #5 latency only
    ("TEPS Sci Rep '25",         1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0),  # 80e #6
    ("DPF Network '25",          1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),  # 80e #7
    ("IoT-6G MDPI IoT '20",      1, 0, 0, 0, 0, 1, 0, 0, 0, 0.5, 0),  # 80e #8 Kpps axis, single 64 B
    ("P4QCN Electronics '19",    1, 0, 0, 0, 0, 0, 0.5, 0, 0, 0, 0),  # 80e #9 own operating-range threshold
    ("INCoS '22",                1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0),  # 80e #10 single 1440 B
    ("L4-LB LOGIC '25",          1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),  # 80e #11
    ("Paolucci IEEE Netw '21",   1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0),  # 80f s1 single 1500 B
    ("Elangovan APNOMS '21",     1, 0.5, 0, 0.5, 1, 0, 0, 0, 0, 0, 0),  # 80f s2 5 sizes; "without logging support"
    ("HOL4P4.EXE VSTTE '25",     1, 0, 0.5, 0, 1, 1, 0.5, 0, 0, 1, 0),  # 80f s3 7 sizes, Mbps+pps; baseline for own switch only
    ("NCTU thesis '18",          1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),  # 80f s4.7 relative only
]


def fig5b():
    # 2026-09-02: `throughput measured` dropped (it is the inclusion criterion,
    # not a reporting item -- 30/34 filled, carrying no claim; the four
    # exceptions are named in the .md). Four columns added: the three fig5
    # columns the screen had not coded, plus `second plane measured`, which is
    # a NEW claim with no precedent in the study (codebook: CODEBOOK-2ndplane).
    cols = ["variant", "version", "build\nflags", "build\nA/B",
            "pkt-size\nsweep", "pps\nbasis", "limit\ncheck",
            "flows as\nvariable", "second plane\nmeasured",
            "comparison plane\n(multi-flow)"]
    #                var   ver   flg   A/B   pkt   pps  lim  flw   2nd   cmp
    corpus = [(PAPERS[i], r[1], r[2], r[3], r[4], r[5], r[6], 0, r[7], r[9], r[8])
              for i, r in enumerate(M12)]
    # SCREEN is stored thr,var,ver,flg,pkt,pps,lim,A/B,flw,2nd,cmp; the
    # figure's column order interleaves A/B after flg, so map explicitly.
    screen = [(r[0], r[2], r[3], r[4], r[8], r[5], r[6], r[7],
               r[9], r[10], r[11]) for r in SCREEN]
    rows = corpus + screen
    n, nc, ncorp = len(rows), len(cols), len(corpus)
    assert n == 34, n
    # guard: (full, half) per column. Six columns are pinned against 80f s7
    # "merged statistics"; `version` is 3 not 2 since the 2026-09-02 coverage
    # audit found LNNS'26 Table 4 ("BMv2 1.16") -- Springer keeps tables off
    # the chapter page, so the browser-innerText coding had missed it.
    # `build A/B`, `flows as variable` and `comparison plane (multi-flow)` are
    # fig5's own columns, coded for the screen in this round (CODEBOOK.md).
    # `second plane measured` is the new claim (CODEBOOK-2ndplane.md); 17 is
    # the body-text reading -- see the .md for the two other readings.
    want = {"variant": (8, 1), "version": (3, 1), "build\nflags": (0, 3),
            "build\nA/B": (0, 0), "pkt-size\nsweep": (2, 2),
            "pps\nbasis": (4, 0), "limit\ncheck": (0, 2),
            "flows as\nvariable": (0, 1), "second plane\nmeasured": (17, 2),
            "comparison plane\n(multi-flow)": (0, 0)}
    totals = []
    for j, c in enumerate(cols):
        full = sum(1 for r in rows if r[1 + j] == 1)
        half = sum(1 for r in rows if r[1 + j] == 0.5)
        assert (full, half) == want[c], (c, full, half, want[c])
        totals.append(f"{full}/{n}")

    GAP = 0.7  # blank band between the corpus block and the screen block

    def ypos(i):
        return (n - 1 - i) + (GAP if i < ncorp else 0)

    fig, ax = plt.subplots(figsize=(4.9, 6.6))
    for i, r in enumerate(rows):
        y = ypos(i)
        for j in range(nc):
            v = r[1 + j]
            if v == 1:
                ax.add_patch(Rectangle((j + 0.12, y + 0.12), 0.76, 0.76,
                                       facecolor=C_A, edgecolor="none"))
            elif v == 0.5:
                ax.add_patch(Rectangle((j + 0.12, y + 0.12), 0.38, 0.76,
                                       facecolor=C_B, edgecolor="none"))
                ax.add_patch(Rectangle((j + 0.12, y + 0.12), 0.76, 0.76,
                                       facecolor="none", edgecolor="#bbbbbb",
                                       lw=0.5))
            else:
                ax.add_patch(Rectangle((j + 0.12, y + 0.12), 0.76, 0.76,
                                       facecolor="white", edgecolor="#cccccc",
                                       lw=0.5))
    ysep = ypos(ncorp) + 1 + GAP / 2
    ax.plot([0, nc], [ysep, ysep], color="#dddddd", lw=0.6)
    for (lo, hi, lab) in ((0, ncorp, "corpus\n(12)"),
                          (ncorp, n, "post-hoc screen\n(22)")):
        yc = (ypos(lo) + 1 + ypos(hi - 1)) / 2
        ax.text(-4.15, yc, lab, rotation=90, ha="center", va="center",
                fontsize=6.0, color="#555555", clip_on=False)
    ax.set_xlim(0, nc)
    ax.set_ylim(-2.7, n + GAP)
    ax.set_xticks([j + 0.5 for j in range(nc)],
                  [c.replace("\n", " ") for c in cols], fontsize=6.0,
                  rotation=32, ha="left", rotation_mode="anchor")
    ax.xaxis.set_ticks_position("top")
    ax.tick_params(axis="x", length=0)
    ax.set_yticks([ypos(i) + 0.5 for i in range(n)], [r[0] for r in rows],
                  fontsize=6.0)
    ax.tick_params(axis="y", length=0)
    for j, t in enumerate(totals):
        zero = t.startswith("0/")
        ax.annotate(t, (j + 0.5, -0.2), ha="center", va="top", fontsize=6.5,
                    fontweight="bold" if zero else "normal",
                    color=C_HL if zero else "#333333")
    ax.annotate("filled = stated in the paper; half = qualitative mention only\n"
                "rows: the 12 corpus papers + 22 found after the corpus froze, same sheet\n"
                "17 papers measured a second plane; none of them at a multi-flow condition",
                (0, -0.95), va="top", fontsize=5.6, color="#555555")
    for s in ("left", "bottom"):
        ax.spines[s].set_visible(False)
    save(fig, "fig5b_reporting_matrix_34")


fig5(); fig5b(); fig6(); fig7(); fig8()
print("wrote 5 figures ->", OUT)
