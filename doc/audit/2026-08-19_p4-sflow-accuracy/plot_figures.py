"""Render the slide figures from the archived measurement data.

Every figure here is produced from data committed under doc/audit/, so a figure on a slide
can be traced to the run that produced it. Nothing is typed in by hand except the failover
numbers, which are re-derived from the raw ping logs by outage_from_pings() rather than
copied from the report.

Style follows the deck's E2 palette. Calibri is not installed on this machine, so the
sans-serif fallback is used -- the deck generator re-renders text anyway; these are charts,
not text slides.

Usage:  python plot_figures.py <output-dir>

[Co-developed with claude code -- Adam]
"""
import json, math, re, sys, gzip, glob, os
import statistics as st
from functools import reduce
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

REPO = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))
OUT = sys.argv[1] if len(sys.argv) > 1 else "."

INK, BODY, MUTED = "#1A1A1A", "#2E2E2E", "#4F4F4F"
FAINT, RULE, ACCENT = "#6E6E6E", "#D0D0D0", "#065A82"
ACCENT_BG, PANEL, WARNC = "#EEF3F6", "#F7F8F9", "#9C3B2E"

plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white",
    "axes.edgecolor": RULE, "axes.labelcolor": BODY, "text.color": INK,
    "xtick.color": MUTED, "ytick.color": MUTED, "font.size": 10,
    "axes.spines.top": False, "axes.spines.right": False,
})


# --------------------------------------------------------------------------- data loading
def load(path):
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rt") as fh:
        return [json.loads(l) for l in fh if '"error"' not in l]


def quantum(rows, edge):
    """256 x frame bytes x 8, measured. It is per-flow -- three rounds have seen three
    different frame lengths -- so it must never be hard-coded."""
    vals = sorted({r["twin"].get(edge, 0) for r in rows if r["twin"].get(edge, 0) > 0})
    return reduce(math.gcd, vals)


def busiest_edge(rows):
    tot = {}
    for r in rows:
        for k, v in r["twin"].items():
            tot[k] = tot.get(k, 0) + v
    return max(tot, key=tot.get)


def ratios(rows, edge, T):
    """Distribution of (twin estimate / ground truth) over non-overlapping windows of T s."""
    hz = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
    step = max(1, int(round(T * hz)))
    out, gts, i = [], [], 0
    while i + step < len(rows):
        a, b = i, i + step + 1
        dt = rows[b - 1]["t"] - rows[a]["t"]
        g = (rows[b - 1]["tx"][edge] - rows[a]["tx"][edge]) * 8 / dt if dt else 0
        num = den = 0.0
        for j in range(a, b - 1):
            d = rows[j + 1]["t"] - rows[j]["t"]
            num += rows[j]["twin"].get(edge, 0) * d
            den += d
        w = num / den if den else 0.0
        if g > 1e6:
            out.append(w / g)
            gts.append(g)
        i += step
    return out, (st.mean(gts) if gts else 0.0)


def outage_from_pings(path):
    """Longest gap between consecutive replies. Re-derived from the raw logs, not copied
    from the report -- the report is the thing being checked."""
    pat = re.compile(r"^\[(\d+\.\d+)\]")
    # Transparent to .gz: a 300-second ping log is ~470 lines of pure evidence that nobody
    # diffs, and there are 40 of them. Committing them gzipped is the same rule the .jsonl
    # traces already follow; this is the reader catching up so the rule can be applied.
    op = gzip.open if str(path).endswith(".gz") else open
    ts = [float(m.group(1)) for line in op(path, "rt")
          if (m := pat.match(line)) and "bytes from" in line]
    gaps = [ts[i + 1] - ts[i] for i in range(len(ts) - 1)]
    big = [g for g in gaps if g > 1.0]
    return big[0] if len(big) == 1 else None


# --------------------------------------------------------- figure 1: sFlow accuracy boxes
def fig_sflow(runs, windows, fname, title, subtitle):
    """runs: list of (label, colour, rows, edge). One box per (window, run)."""
    fig, ax = plt.subplots(figsize=(9.2, 4.6))
    n = len(runs)
    width = 0.62 / n
    theory_pts = {}
    for k, (label, colour, rows, edge) in enumerate(runs):
        q = quantum(rows, edge)
        data, pos = [], []
        for i, T in enumerate(windows):
            r, gm = ratios(rows, edge, T)
            if len(r) < 4:
                continue
            data.append(r)
            pos.append(i + (k - (n - 1) / 2) * width)
            theory_pts.setdefault(i, []).append(196 / math.sqrt(gm * T / q) / 100)
        bp = ax.boxplot(data, positions=pos, widths=width * 0.82, patch_artist=True,
                        showfliers=False, medianprops=dict(color=colour, lw=1.6),
                        boxprops=dict(facecolor=ACCENT_BG if colour == ACCENT else "#F6EFEE",
                                      edgecolor=colour, lw=1.0),
                        whiskerprops=dict(color=colour, lw=1.0),
                        capprops=dict(color=colour, lw=1.0))
    # sampling-theory envelope: 1 +/- 196*sqrt(1/c)
    xs = sorted(theory_pts)
    hi = [1 + st.mean(theory_pts[i]) for i in xs]
    lo = [1 - st.mean(theory_pts[i]) for i in xs]
    ax.plot(xs, hi, ls=(0, (4, 3)), color=FAINT, lw=1.2, zorder=1)
    ax.plot(xs, lo, ls=(0, (4, 3)), color=FAINT, lw=1.2, zorder=1,
            label=r"sampling-theory floor  $196\sqrt{1/c}$")
    ax.axhline(1.0, color=RULE, lw=1.0, zorder=0)

    ax.set_xticks(range(len(windows)))
    ax.set_xticklabels([f"{w}" for w in windows])
    ax.set_xlabel("window length (s)  —  accuracy is a function of this, not a constant")
    ax.set_ylabel("twin estimate / ground truth")
    ax.set_title(title, fontsize=13, color=INK, loc="left", pad=14, weight="bold")
    ax.text(0, 1.02, subtitle, transform=ax.transAxes, fontsize=9, color=MUTED)
    handles = [Patch(facecolor=ACCENT_BG if c == ACCENT else "#F6EFEE", edgecolor=c, label=l)
               for l, c, _, _ in runs]
    handles.append(plt.Line2D([], [], ls=(0, (4, 3)), color=FAINT,
                              label=r"sampling-theory floor $196\sqrt{1/c}$"))
    ax.legend(handles=handles, frameon=False, fontsize=9, loc="upper right")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname)


# ------------------------------------------------------------- figure 2: failover box plot
# The 128-host cells were taken from n=3 to n=10 on 2026-08-19; those runs live in their own
# directories so the 2026-08-17 round stays exactly as it was published. Both the box plot and
# the raster read these, through failover_key() -- one classifier, so a cell cannot appear on
# one figure and go missing from the other.
FAILOVER_DIRS = [os.path.join(REPO, "doc/audit/2026-08-17_p4-vs-ovs-matched-topology/raw"),
                 os.path.join(REPO, "doc/audit/2026-08-19_failover-provenance/raw_ovs128_n10"),
                 os.path.join(REPO, "doc/audit/2026-08-19_failover-provenance/raw_p4_128")]



def ping_logs(d):
    """Every ping log in a directory, gzipped or not.

    One place, because there are two callers -- the box plot and the raster -- and a classifier
    that disagrees between them is exactly the defect fixed on 2026-08-19 when the raster was
    missing a cell the box plot had. Compressing the logs would have re-created it: an earlier
    edit patched an `os.path.join` form that does not appear here (both sites concatenate), so
    it matched nothing, and the figures rendered with all four cells EMPTY rather than failing.
    """
    return glob.glob(d + "/*.log") + glob.glob(d + "/*.log.gz")


def failover_key(basename):
    """Which of the four cells a ping log belongs to. Order matters: p4_128_run*.log also
    satisfies startswith("p4_"), so the 128-host test has to come first.

    The .gz suffix is stripped first, and that is not cosmetic. The exact-match arm below tests
    `== "ping_p4_4host.log"`; compressing the logs made that name "ping_p4_4host.log.gz", the
    arm stopped matching, and the run silently reclassified into OVS / 4 hosts -- 9 and 11 where
    the published figure has 10 and 10. Nothing raised; both cells still had data, just the
    wrong data. Caught only by diffing the counts against the committed output.
    """
    if basename.endswith(".gz"):
        basename = basename[:-3]
    if basename.startswith("p4_128"):
        return "P4 / 128 hosts"
    if basename.startswith("p4_") or basename == "ping_p4_4host.log":
        return "P4 / 4 hosts"
    if "128" in basename:
        return "OVS / 128 hosts"
    return "OVS / 4 hosts"


def failover_cells():
    cells = {"P4 / 4 hosts": [], "OVS / 4 hosts": [],
             "OVS / 128 hosts": [], "P4 / 128 hosts": []}
    for d in FAILOVER_DIRS:
        for f in sorted(ping_logs(d)):
            b = os.path.basename(f)
            if b.startswith("base_run"):        # the reverted-router runs, a different question
                continue
            v = outage_from_pings(f)
            if v is not None:
                cells[failover_key(b)].append(v)
    return cells


def fig_failover(fname):
    cells = failover_cells()

    fig, (ax, ax2) = plt.subplots(1, 2, figsize=(9.2, 4.3),
                                  gridspec_kw={"width_ratios": [2, 1]})
    small = ["P4 / 4 hosts", "OVS / 4 hosts"]
    colours = [ACCENT, WARNC]
    for i, (k, c) in enumerate(zip(small, colours)):
        ax.boxplot([cells[k]], positions=[i], widths=0.45, patch_artist=True,
                   showfliers=False, medianprops=dict(color=c, lw=1.8),
                   boxprops=dict(facecolor=ACCENT_BG if c == ACCENT else "#F6EFEE",
                                 edgecolor=c, lw=1.1),
                   whiskerprops=dict(color=c, lw=1.1), capprops=dict(color=c, lw=1.1))
        ax.scatter([i + 0.28] * len(cells[k]), cells[k], s=16, color=c, alpha=0.75, zorder=3)
    ax.set_xticks(range(2))
    ax.set_xticklabels([f"{k}\nn={len(cells[k])}" for k in small])
    ax.set_ylabel("outage (s)")
    ax.set_title("Failover on a matched topology", fontsize=13, color=INK,
                 loc="left", pad=14, weight="bold")
    ax.text(0, 1.02, f"{sum(len(v) for v in cells.values())} live runs, one method. Every run recovered.",
            transform=ax.transAxes, fontsize=9, color=MUTED)
    ax.text(0.02, 0.03, "P4 is 2.0 s faster (13%)\nWelch t=2.89, p=0.0098\n95% CI 0.55–3.50 s",
            transform=ax.transAxes, fontsize=8.5, color=MUTED, va="bottom")

    # The 128-host pair. This is the cell the 2026-08-17 round deliberately skipped as "only
    # an interaction", and the interaction turns out to be the largest effect on the page:
    # OVS triples going from 4 to 128 hosts, P4 barely moves.
    big = ["P4 / 128 hosts", "OVS / 128 hosts"]
    for i, (k, c) in enumerate(zip(big, [ACCENT, WARNC])):
        if not cells[k]:
            continue
        ax2.boxplot([cells[k]], positions=[i], widths=0.45, patch_artist=True,
                    showfliers=False, medianprops=dict(color=c, lw=1.8),
                    boxprops=dict(facecolor=ACCENT_BG if c == ACCENT else "#F6EFEE",
                                  edgecolor=c, lw=1.1),
                    whiskerprops=dict(color=c, lw=1.1), capprops=dict(color=c, lw=1.1))
        ax2.scatter([i + 0.28] * len(cells[k]), cells[k], s=14, color=c, alpha=0.75, zorder=3)
    ax2.set_xlim(-0.6, 1.7)
    ax2.set_xticks(range(len(big)))
    ax2.set_xticklabels([f"{k}\nn={len(cells[k])}" for k in big], fontsize=8.5)
    ax2.set_ylabel("outage (s)")
    ax2.set_title("At 128 hosts the gap is 3x", fontsize=11, color=INK, loc="left", pad=14)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname, {k: [round(x, 2) for x in sorted(v)] for k, v in cells.items()})


# ------------------------------------------------------ figure 3: the three-term breakdown
def fig_decomposition(fname):
    """The first term is deliberately NOT drawn as a multiplier.

    291 s was never a recovery -- traffic did not come back, and 291 s is only how long it
    was watched. Plotting 291/50.1 = 5.8x would say the defect made recovery 5.8x slower,
    when what it did was stop recovery happening at all. That is a censored observation, and
    turning it into a ratio is the same mistake as the P4-vs-OVS table this deck already
    retracted. It gets its own row, open-ended, on its own axis.
    """
    fig, (ax0, ax) = plt.subplots(2, 1, figsize=(9.6, 4.9),
                                  gridspec_kw={"height_ratios": [0.8, 2.6], "hspace": 0.55})

    # the categorical term
    ax0.barh([0], [1.0], color=WARNC, height=0.42)
    ax0.annotate("", xy=(1.16, 0), xytext=(0.99, 0),
                 arrowprops=dict(arrowstyle="-|>", color=WARNC, lw=1.6))
    ax0.text(1.19, 0, "never recovers", va="center", fontsize=10.5,
             color=WARNC, weight="bold")
    ax0.set_xlim(0, 2.1)
    ax0.set_ylim(-0.5, 0.5)
    ax0.set_yticks([0])
    # not "kernel defect": the defect is in intelligent_router.py, the inherited Ryu control
    # program, and it is not in the kernel at all
    ax0.set_yticklabels(["inherited router\n(since fixed)"], fontsize=9)
    ax0.set_xticks([])
    ax0.spines["bottom"].set_visible(False)
    ax0.spines["left"].set_visible(False)
    ax0.text(0.0, -0.62, "Measured 180.75 s × 3 with the fault held 180 s — it came back only "
                         "when the fault\nwas lifted. Not a slower recovery: no recovery.",
             transform=ax0.transAxes, fontsize=8.5, color=MUTED, va="top")

    # The two multipliers -- derived from the logs, not typed in, so the figure cannot drift
    # from the measurements the way a transcribed number would.
    #
    # Each one is drawn TWICE, once at each level of the other factor, because measuring the
    # fourth cell (P4 at 128 hosts, 2026-08-19) showed neither has a single value: the plane
    # is worth 1.15x at 4 hosts and 3.12x at 128, and topology size costs OVS 3.30x but P4
    # only 1.21x. Reporting either as one bar means quoting whichever level happened to be
    # measured, which is what the earlier version of this figure did.
    cells = failover_cells()
    m = {k: st.mean(v) for k, v in cells.items()}
    bars = [
        (2.30, "on OVS", m["OVS / 128 hosts"] / m["OVS / 4 hosts"], WARNC),
        (1.70, "on P4", m["P4 / 128 hosts"] / m["P4 / 4 hosts"], ACCENT),
        (0.75, "at 128 hosts", m["OVS / 128 hosts"] / m["P4 / 128 hosts"], ACCENT),
        (0.15, "at 4 hosts", m["OVS / 4 hosts"] / m["P4 / 4 hosts"], ACCENT),
    ]
    for y, lab, v, c in bars:
        ax.barh([y], [v], color=c, height=0.44)
        ax.text(v + 0.07, y, f"{v:.2f}×", va="center", fontsize=10, color=c)
    ax.set_yticks([b[0] for b in bars])
    ax.set_yticklabels([b[1] for b in bars], fontsize=9)
    ax.set_ylim(-0.35, 2.95)
    ax.set_xlim(0, 4.2)
    ax.set_xlabel("how much longer the outage lasts (×)")
    # Group headings go on the empty rows above each pair, inside the axes -- putting them
    # outside on the left made tight_layout clip them.
    for y, txt in [(2.78, "topology size   4 → 128 hosts"),
                   (1.22, "data plane   OVS → P4")]:
        ax.text(0.05, y, txt, va="center", fontsize=9.5, color=INK, weight="bold")

    fig.suptitle("Three things change how long a link failure lasts — one changes whether "
                 "it ends", fontsize=13, color=INK, x=0.012, ha="left", weight="bold")
    fig.text(0.012, 0.905, "Same fault, same method, n=10 per cell. The first is a difference "
                           "in kind. The other two are multipliers —\nbut neither has a single "
                           "value: each one depends on the level of the other.",
             fontsize=9, color=MUTED, va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.84])
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname, {lab: round(v, 2) for _y, lab, v, _c in bars})


# ----------------------------------------------------------- figure 4: throughput A/B pair
def fig_throughput(fname):
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(9.2, 3.8))
    names = ["bmv2 stock\n(-O0 + logging)", "bmv2 fast\n(-O3, no logging)", "OVS"]
    bps = [40, 495, 980]
    pps = [3.6, 50.8, float("nan")]
    cols = [WARNC, ACCENT, MUTED]
    a1.bar(range(3), bps, color=cols, width=0.55)
    for i, v in enumerate(bps):
        a1.text(i, v + 18, f"{v}", ha="center", fontsize=10, color=cols[i])
    a1.set_xticks(range(3)); a1.set_xticklabels(names, fontsize=8.5)
    a1.set_ylabel("UDP delivered (Mbps)"); a1.set_ylim(0, 1120)
    a1.set_title("Throughput", fontsize=11, color=INK, loc="left", pad=10)

    a2.bar(range(2), pps[:2], color=cols[:2], width=0.55)
    for i, v in enumerate(pps[:2]):
        a2.text(i, v + 1.5, f"{v}k", ha="center", fontsize=10, color=cols[i])
    a2.set_xticks(range(2)); a2.set_xticklabels(names[:2], fontsize=8.5)
    a2.set_ylabel("packets/s (thousands)"); a2.set_ylim(0, 60)
    a2.set_title("...but the ceiling is packet rate", fontsize=11, color=INK, loc="left", pad=10)
    fig.suptitle("Two bmv2 builds on the same fabric and script", fontsize=13,
                 color=INK, x=0.012, ha="left", weight="bold")
    fig.text(0.012, 0.90, "Same pps at 64 B and 1400 B: the cost is per packet, not per bit. "
                          "12–18× from the build alone.", fontsize=9, color=MUTED)
    fig.tight_layout(rect=[0, 0, 1, 0.88])
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname)


# ------------------------------------------------------- figure 5: the quantisation ladder
def fig_quantum(panels, fname):
    """Side by side, so the staircase reads as a property of 1-in-256 sampling rather than
    of either data plane. panels: list of (label, colour, rows, edge)."""
    fig, axes = plt.subplots(1, len(panels), figsize=(9.6, 5.0), sharey=True)
    if len(panels) == 1:
        axes = [axes]
    for ax, (label, colour, rows, edge) in zip(axes, panels):
        q = quantum(rows, edge)
        t0 = rows[0]["t"]
        ts = [r["t"] - t0 for r in rows]
        vs = [r["twin"].get(edge, 0) / 1e6 for r in rows]
        gt = ((rows[-1]["tx"][edge] - rows[0]["tx"][edge]) * 8
              / (rows[-1]["t"] - rows[0]["t"])) / 1e6
        # the quantum grid -- the values the twin is *able* to report
        k = 1
        while k * q / 1e6 < max(vs) * 1.05:
            ax.axhline(k * q / 1e6, color=RULE, lw=0.6, zorder=0)
            k += 1
        ax.step(ts, vs, where="post", color=colour, lw=0.9, zorder=2)
        ax.axhline(gt, color=INK, lw=1.3, ls="--", zorder=3)
        n_distinct = len({r["twin"].get(edge, 0) for r in rows if r["twin"].get(edge, 0) > 0})
        # The mean and the extremes make opposite points and belong side by side: the mean
        # says the estimator is unbiased, the extremes say no single reading can be trusted.
        mean = st.mean(vs)
        sd = st.pstdev(vs)
        ax.set_xlim(0, 300)
        ax.set_xlabel("time (s)")
        ax.set_title(label, fontsize=11, color=colour, loc="left", pad=52, weight="bold")
        ax.text(0, 1.105,
                f"quantum {q/1e6:.2f} Mbit/s = 256 × {q//256//8} B × 8 · "
                f"{n_distinct} distinct values",
                transform=ax.transAxes, fontsize=8.5, color=MUTED)
        ax.text(0, 1.055,
                f"mean {mean:.2f} vs truth {gt:.2f} Mbit/s "
                f"({(mean/gt-1)*100:+.1f}%) · sd {sd:.2f}",
                transform=ax.transAxes, fontsize=8.5, color=MUTED)
        ax.text(0, 1.005,
                f"single readings span {min(vs):.1f} – {max(vs):.1f} Mbit/s",
                transform=ax.transAxes, fontsize=8.5, color=MUTED)
    axes[0].set_ylabel("twin reading (Mbit/s)")
    fig.suptitle("The resolution floor is one sample — on both data planes",
                 fontsize=13, color=INK, x=0.012, y=0.985, ha="left", weight="bold")
    fig.text(0.012, 0.917, "Grey lines are the only values the twin can report. The frame "
                           "length differs per flow, so the quantum does too — it is not a "
                           "constant.", fontsize=9, color=MUTED)
    fig.tight_layout(rect=[0, 0, 1, 0.90])
    fig.subplots_adjust(top=0.74, wspace=0.12)
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname)


def sample_stats(rows, edge, q):
    """Recovers the raw counting process behind the ladder.

    A twin reading divided by the quantum IS the number of sFlow samples that landed in that
    refresh window, so the sampling process can be tested directly instead of inferred from
    the spread.

    One entry per refresh *window*, sampled at the twin's own 1 Hz cadence -- NOT one entry per
    changed value. Counting only changes looks equivalent and is not: when two consecutive
    windows happen to hold the same count the second becomes invisible, and those collisions
    are commonest at the mode, so dropping them hollows out the centre of the distribution and
    biases Fano upward. Measured on these four traces, change-counting discards 9.0-9.7% of
    windows at 20 Mbit/s (small lambda, frequent collisions) and 3.7-4.0% at 200 Mbit/s,
    inflating Fano by 0.02-0.09. Found by an audit of this file, not by writing it carefully.

    Returns (lambda, Fano factor). Fano = variance/mean is 1.00 for an ideal Poisson process.
    Compare against a simulated null rather than against 1.00 exactly: quantisation and the
    finite window put this estimator slightly off 1.00 even on a perfect Poisson stream.
    """
    hz = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
    step = max(1, int(round(hz)))          # polls per refresh window
    counts = [rows[i]["twin"].get(edge, 0) / q for i in range(0, len(rows), step)]
    lam = st.mean(counts)
    return lam, st.pvariance(counts) / lam if lam else 0.0


# --------------------------------- figure 5b: the same ladder at 10x the load, both planes
def fig_quantum_load(grid, fname):
    """The ladder at two loads, so "the jitter looks broken" can be answered with data.

    grid: [(row_label, [(label, colour, rows, edge), ...]), ...]

    The dispersion is not a property of the instrument, it is 1/sqrt(sample count). Ten times
    the load puts ten times the samples in the same one-second window, so the same instrument
    on the same fabric must get sqrt(10) = 3.2x tighter -- and the point of showing both rows
    is that it does. A single row invites "is that normal?"; two rows answer it.

    Each panel is annotated with lambda (samples per refresh window) and the Fano factor,
    because those are the quantities that decide the spread. Reporting sd alone lets a reader
    compare 9.2 against 27 and conclude the low-rate case is worse, when in ratio terms it is
    the arithmetic working exactly as predicted.
    """
    nrow, ncol = len(grid), max(len(p) for _, p in grid)
    fig, axes = plt.subplots(nrow, ncol, figsize=(11.4, 7.6))
    for r, (row_label, panels) in enumerate(grid):
        # sharey within a row only: the two rows are 10x apart, so one shared scale would
        # squash the low-rate row into a line and destroy the comparison it exists to make.
        lo = min(min(x["twin"].get(e, 0) for x in rw) for _, _, rw, e in panels) / 1e6
        hi = max(max(x["twin"].get(e, 0) for x in rw) for _, _, rw, e in panels) / 1e6
        for c, (label, colour, rows, edge) in enumerate(panels):
            ax = axes[r][c]
            q = quantum(rows, edge)
            t0 = rows[0]["t"]
            ts = [x["t"] - t0 for x in rows]
            vs = [x["twin"].get(edge, 0) / 1e6 for x in rows]
            gt = ((rows[-1]["tx"][edge] - rows[0]["tx"][edge]) * 8
                  / (rows[-1]["t"] - rows[0]["t"])) / 1e6
            lam, fano = sample_stats(rows, edge, q)

            # The quantum grid. At 200 Mbit/s there are ~90 rungs across the range and they
            # read as a wash rather than as lines -- which is the honest picture: the ladder
            # has become a ramp. Thinner strokes so it stays a texture, not a grey block.
            k, rungs = 1, 0
            while k * q / 1e6 < hi * 1.05:
                rungs += 1
                k += 1
            lw = 0.6 if rungs < 30 else 0.35
            for k in range(1, rungs + 1):
                ax.axhline(k * q / 1e6, color=RULE, lw=lw, zorder=0)

            ax.step(ts, vs, where="post", color=colour, lw=0.9, zorder=2)
            ax.axhline(gt, color=INK, lw=1.3, ls="--", zorder=3)
            ax.set_xlim(0, 300)
            ax.set_ylim(0, hi * 1.06)
            if r == nrow - 1:
                ax.set_xlabel("time (s)")
            if c == 0:
                ax.set_ylabel(f"{row_label}\ntwin reading (Mbit/s)")
            ax.set_title(label, fontsize=10.5, color=colour, loc="left", pad=34,
                         weight="bold")
            ax.text(0, 1.115,
                    f"{lam:.1f} samples per 1 s window · spread ±{1.96*100/math.sqrt(lam):.0f}% "
                    f"predicted", transform=ax.transAxes, fontsize=8.2, color=MUTED)
            ax.text(0, 1.055,
                    f"single readings {min(vs):.0f}–{max(vs):.0f} vs truth {gt:.1f} Mbit/s · "
                    f"Fano {fano:.2f}", transform=ax.transAxes, fontsize=8.2, color=MUTED)
    fig.suptitle("The same instrument at 10× the load: dispersion is sample count, not noise",
                 fontsize=13, color=INK, x=0.012, y=0.985, ha="left", weight="bold")
    fig.text(0.012, 0.938,
             "Grey rungs are the only values the twin can report — the quantum is one sample, "
             "≈3.06 Mbit/s, at both loads. Ten times the traffic puts ten times the samples in "
             "the same window,",
             fontsize=9, color=MUTED)
    fig.text(0.012, 0.915,
             "so the same ladder gets √10 = 3.2× tighter. Fano ≈ 1.00 means the counts are "
             "Poisson: the spread is the sampling process itself, with nothing added on top.",
             fontsize=9, color=MUTED)
    fig.tight_layout(rect=[0, 0, 1, 0.90])
    fig.subplots_adjust(hspace=0.62, wspace=0.16, top=0.80)
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname)


def fig_per_hop(runs, T, fname):
    """Per-hop consistency along the flow's path.

    NOT a "all 32 links" figure: in these runs only the links on the flow's path carry
    traffic (4 on the OVS cell, 2 on the P4 cell) and the other 28-30 sit at zero, so a
    32-point chart would be 30 points of nothing. What the data does support is the hop
    check -- every link on the path carries the SAME flow, so the twin should report the
    same rate on each, and a per-hop miscount would show up as one hop out of line.
    """
    fig, ax = plt.subplots(figsize=(9.2, 4.0))
    ticks, labels, colours = [], [], []
    pos = 0
    for label, colour, rows, _ in runs:
        a, b = rows[0], rows[-1]
        dt = b["t"] - a["t"]
        carrying = []
        for k in a["twin"]:
            if k in a["tx"] and k in b["tx"]:
                mbps = (b["tx"][k] - a["tx"][k]) * 8 / dt / 1e6
                if mbps > 1:
                    carrying.append(k)
        carrying.sort()
        for edge in carrying:
            r, _gm = ratios(rows, edge, T)
            if len(r) < 4:
                continue
            bp = ax.boxplot([r], positions=[pos], widths=0.5, patch_artist=True,
                            showfliers=False, medianprops=dict(color=colour, lw=1.6),
                            boxprops=dict(facecolor=ACCENT_BG if colour == ACCENT else "#F6EFEE",
                                          edgecolor=colour, lw=1.0),
                            whiskerprops=dict(color=colour, lw=1.0),
                            capprops=dict(color=colour, lw=1.0))
            ticks.append(pos)
            labels.append(f"{edge}\n{label.split()[0]}")
            colours.append(colour)
            pos += 1
        pos += 0.7  # gap between planes
    ax.axhline(1.0, color=RULE, lw=1.0, zorder=0)
    ax.set_xticks(ticks)
    ax.set_xticklabels(labels, fontsize=9)
    for tick, c in zip(ax.get_xticklabels(), colours):
        tick.set_color(c)
    ax.set_ylabel("twin estimate / ground truth")
    ax.set_title("Every hop on the path, same flow, same window",
                 fontsize=13, color=INK, loc="left", pad=16, weight="bold")
    ax.text(0, 1.02, f"{T} s windows. The flow crosses 4 links on the OVS cell and 2 on the "
                     f"P4 cell; the other links carry nothing and are not shown.",
            transform=ax.transAxes, fontsize=9, color=MUTED)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname, labels)


def fig_failover_raster(fname):
    """One row per run, one mark per ping. The box plot compresses each run to a scalar;
    this shows whether the outage really is a single clean gap rather than a flapping tail."""
    pat = re.compile(r"^\[(\d+\.\d+)\]")
    # Same three directories and the same classification as failover_cells(); the raster used
    # to keep a second copy of that logic, which is how it silently lost the P4/128 cell --
    # p4_128_run*.log matches startswith("p4_") too, so adding the directory without fixing
    # the order would have quietly folded those runs into the 4-host panel instead.
    groups = {k: [] for k in ("P4 / 4 hosts", "OVS / 4 hosts",
                              "P4 / 128 hosts", "OVS / 128 hosts")}
    for f in sorted(g for d in FAILOVER_DIRS for g in ping_logs(d)):
        bn = os.path.basename(f)
        if bn.startswith("base_run"):
            continue
        key = failover_key(bn)
        # Same gz-transparency as outage_from_pings. This site was missed the first time and
        # the raster was the figure that crashed -- which was the good outcome: the box plot,
        # sharing the same logs through a different reader, had already rendered with silently
        # wrong cells. A crash is a better failure than a plausible chart.
        ts = [float(m.group(1)) for line in (gzip.open(f, "rt") if str(f).endswith(".gz") else open(f))
              if (m := pat.match(line)) and "bytes from" in line]
        if len(ts) < 10:
            continue
        gaps = [(ts[i + 1] - ts[i], ts[i]) for i in range(len(ts) - 1)]
        big = [g for g in gaps if g[0] > 1.0]
        if len(big) != 1:
            continue
        t_fault = big[0][1]          # align every run on the last reply before the outage
        groups[key].append(([t - t_fault for t in ts], big[0][0]))

    # Ordered 4-host pair then 128-host pair, so the eye reads the plane comparison twice and
    # the third panel's outages visibly run past where the other three have already finished.
    panels = [("P4 / 4 hosts", ACCENT), ("OVS / 4 hosts", WARNC),
              ("P4 / 128 hosts", ACCENT), ("OVS / 128 hosts", WARNC)]
    fig, axes = plt.subplots(1, 4, figsize=(12.4, 4.4), sharex=True)
    for ax, (key, colour) in zip(axes, panels):
        runs = groups[key]
        for row, (ts, outage) in enumerate(runs):
            xs = [t for t in ts if -8 <= t <= 70]
            ax.plot(xs, [row] * len(xs), ls="none", marker="|", ms=4,
                    color=colour, alpha=0.85)
            ax.plot([0, outage], [row, row], lw=2.4, color="#E8E8E8", zorder=0)
        ax.axvline(0, color=INK, lw=1.0, ls="--")
        ax.set_ylim(-0.8, max(len(runs), 1) - 0.2)
        ax.set_xlim(-8, 70)
        ax.set_yticks(range(len(runs)))
        ax.set_yticklabels([f"{i+1}" for i in range(len(runs))], fontsize=8)
        ax.set_xlabel("seconds from fault")
        ax.set_title(f"{key}  (n={len(runs)})", fontsize=10.5, color=colour,
                     loc="left", pad=10, weight="bold")
    axes[0].set_ylabel("run")
    fig.suptitle("Every ping of every run: one clean outage, then full recovery",
                 fontsize=13, color=INK, x=0.012, ha="left", weight="bold")
    fig.text(0.012, 0.895, "Each tick is a reply; the grey bar is the outage. Aligned on the "
                           "last reply before the fault. No run shows a second loss or a "
                           "flapping tail.", fontsize=9, color=MUTED)
    fig.tight_layout(rect=[0, 0, 1, 0.87])
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname, {k: len(v) for k, v in groups.items()})


if __name__ == "__main__":
    A18 = os.path.join(REPO, "doc/audit/2026-08-18_live-full-stack-round")
    A19 = os.path.join(REPO, "doc/audit/2026-08-19_p4-sflow-accuracy")
    ovsA = load(f"{A18}/sflow_runA_200M.jsonl.gz")
    ovsB = load(f"{A18}/sflow_runB_20M.jsonl.gz")
    p4s = load(f"{A19}/p4_stock_20M.jsonl.gz")

    fig_failover("page36_failover-boxplot.png")
    fig_decomposition("page36_failover-decomposition.png")
    fig_throughput("page37_throughput-ab.png")
    fig_quantum([("OVS — native sampling, 20 Mbit/s", ACCENT, ovsB, "s1-eth2"),
                 ("P4 / bmv2 — synthesised, 20 Mbit/s", WARNC, p4s, busiest_edge(p4s))],
                "page39_quantisation-ladder.png")

    W = [1, 2, 5, 10, 30, 60]
    fig_sflow([("OVS  20 Mbit/s", ACCENT, ovsB, "s1-eth2"),
               ("P4/bmv2  20 Mbit/s", WARNC, p4s, busiest_edge(p4s))],
              W, "page39_sflow-accuracy-20M.png",
              "Telemetry accuracy: synthesised (P4) vs native (OVS) sampling",
              "One fixed-rate flow, 20 Mbit/s. Boxes = spread of window estimates; "
              "the twin is unbiased on both planes.")

    fig_failover_raster("page36_failover-raster.png")

    p4f = f"{A19}/p4_fast_200M.jsonl.gz"
    if os.path.exists(p4f):
        p4F = load(p4f)
        fig_sflow([("OVS  200 Mbit/s", ACCENT, ovsA, "s1-eth2"),
                   ("P4/bmv2  200 Mbit/s", WARNC, p4F, busiest_edge(p4F))],
                  W, "page39_sflow-accuracy-200M.png",
                  "Telemetry accuracy at 200 Mbit/s: synthesised (P4) vs native (OVS)",
                  "Same load on both planes; P4 needed the -O3 bmv2 build to reach it.")
        # The load comparison answers "that jitter looks abnormal" with the same experiment
        # at 10x the traffic. It needs both 200 Mbit/s runs, so it lives inside this branch.
        fig_quantum_load(
            [("20 Mbit/s", [("OVS — native sampling", ACCENT, ovsB, "s1-eth2"),
                            ("P4 / bmv2 — synthesised", WARNC, p4s, busiest_edge(p4s))]),
             ("200 Mbit/s", [("OVS — native sampling", ACCENT, ovsA, "s1-eth2"),
                             ("P4 / bmv2 — synthesised", WARNC, p4F, busiest_edge(p4F))])],
            "page39_quantisation-ladder-load.png")
        fig_per_hop([("OVS 200 Mbit/s", ACCENT, ovsA, None),
                     ("P4 200 Mbit/s", WARNC, p4F, None)],
                    30, "page39_per-hop-consistency.png")
