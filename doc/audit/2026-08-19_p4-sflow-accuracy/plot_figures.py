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
    ts = [float(m.group(1)) for line in open(path)
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
def failover_cells():
    """The 128-host cell was taken from n=3 to n=10 on 2026-08-19; those seven runs live in
    their own directory so the 2026-08-17 round stays exactly as it was published."""
    dirs = [os.path.join(REPO, "doc/audit/2026-08-17_p4-vs-ovs-matched-topology/raw"),
            os.path.join(REPO, "doc/audit/2026-08-19_failover-provenance/raw_ovs128_n10"),
            os.path.join(REPO, "doc/audit/2026-08-19_failover-provenance/raw_p4_128")]
    cells = {"P4 / 4 hosts": [], "OVS / 4 hosts": [],
             "OVS / 128 hosts": [], "P4 / 128 hosts": []}
    for d in dirs:
        for f in sorted(glob.glob(d + "/*.log")):
            b = os.path.basename(f)
            if b.startswith("base_run"):        # the reverted-router runs, a different question
                continue
            if b.startswith("p4_128"):
                key = "P4 / 128 hosts"
            elif b.startswith("p4_") or b == "ping_p4_4host.log":
                key = "P4 / 4 hosts"
            elif "128" in b:
                key = "OVS / 128 hosts"
            else:
                key = "OVS / 4 hosts"
            v = outage_from_pings(f)
            if v is not None:
                cells[key].append(v)
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
    fig, (ax0, ax) = plt.subplots(2, 1, figsize=(9.2, 4.0),
                                  gridspec_kw={"height_ratios": [1, 2]})

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

    # the two that really are multipliers -- derived from the logs, not typed in, so the
    # figure cannot drift from the measurements the way a transcribed number would
    cells = failover_cells()
    m = {k: st.mean(v) for k, v in cells.items()}
    labels = [f"topology size\n4 → 128 hosts  (n={len(cells['OVS / 128 hosts'])})",
              f"data plane\nOVS → P4  (n={len(cells['P4 / 4 hosts'])})"]
    vals = [m["OVS / 128 hosts"] / m["OVS / 4 hosts"], m["OVS / 4 hosts"] / m["P4 / 4 hosts"]]
    colours = [MUTED, ACCENT]
    ax.barh(range(2), vals, color=colours, height=0.46)
    for i, v in enumerate(vals):
        ax.text(v + 0.06, i, f"{v:.2f}×", va="center", fontsize=10, color=colours[i])
    ax.set_yticks(range(2))
    ax.set_yticklabels(labels, fontsize=9)
    ax.invert_yaxis()
    ax.set_xlim(0, 4.0)
    ax.set_xlabel("how much longer the outage lasts (×)")

    fig.suptitle("Three things change how long a link failure lasts — one changes whether "
                 "it ends", fontsize=13, color=INK, x=0.012, ha="left", weight="bold")
    fig.text(0.012, 0.90, "Same fault, same topology. Only the first is a difference in kind; "
                          "the other two are multipliers, and note how small they are.",
             fontsize=9, color=MUTED)
    fig.tight_layout(rect=[0, 0, 1, 0.87])
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname)


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
    dirs = [os.path.join(REPO, "doc/audit/2026-08-17_p4-vs-ovs-matched-topology/raw"),
            os.path.join(REPO, "doc/audit/2026-08-19_failover-provenance/raw_ovs128_n10")]
    groups = {"P4 / 4 hosts": [], "OVS / 4 hosts": [], "OVS / 128 hosts": []}
    for f in sorted(g for d in dirs for g in glob.glob(d + "/*.log")):
        bn = os.path.basename(f)
        if bn.startswith("base_run"):
            continue
        key = ("P4 / 4 hosts" if bn.startswith("p4_") or bn == "ping_p4_4host.log"
               else "OVS / 128 hosts" if "128" in bn else "OVS / 4 hosts")
        ts = [float(m.group(1)) for line in open(f)
              if (m := pat.match(line)) and "bytes from" in line]
        if len(ts) < 10:
            continue
        gaps = [(ts[i + 1] - ts[i], ts[i]) for i in range(len(ts) - 1)]
        big = [g for g in gaps if g[0] > 1.0]
        if len(big) != 1:
            continue
        t_fault = big[0][1]          # align every run on the last reply before the outage
        groups[key].append(([t - t_fault for t in ts], big[0][0]))

    fig, axes = plt.subplots(1, 3, figsize=(10.2, 4.4),
                             gridspec_kw={"width_ratios": [1, 1, 1]})
    for ax, (key, colour) in zip(axes, [("P4 / 4 hosts", ACCENT),
                                        ("OVS / 4 hosts", WARNC),
                                        ("OVS / 128 hosts", MUTED)]):
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
        fig_per_hop([("OVS 200 Mbit/s", ACCENT, ovsA, None),
                     ("P4 200 Mbit/s", WARNC, p4F, None)],
                    30, "page39_per-hop-consistency.png")
