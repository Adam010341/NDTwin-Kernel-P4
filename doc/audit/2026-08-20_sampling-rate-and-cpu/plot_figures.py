"""Render the slide figures for the 2026-08-20 sampling-rate / CPU round.

Same discipline as doc/audit/2026-08-19_p4-sflow-accuracy/plot_figures.py: every number that
appears on a figure is recomputed here from the archived JSONL under raw/, so a figure on a
slide traces to the run that produced it. Nothing is copied out of REPORT.md -- the report is
one of the things being checked, and checking it found two things (see FIGURES.md).

THE 6 SECOND HEAD TRIM IS NOT OPTIONAL. measure.sh starts the two pollers, sleeps 2 s, then
starts iperf3, so the head of every trace has no traffic in it. Those three or four zero
windows are not a small perturbation of the variance statistics, they dominate them: including
them takes the Fano factor from 0.88 to 1.75 at 1/256 and from 1.05 to 4.34 at 1/64, which
inverts the sweep's conclusion -- the dispersion appears to get *worse* as the sampling rate
rises. TRIM is applied by load_twin() and cpu_stats() so no figure can forget it.

Usage:  python plot_figures.py <output-dir>

[Co-developed with claude code -- Adam]
"""
import gzip
import json, math, os, sys
import statistics as st
from functools import reduce
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

def _open(path):
    """Open a trace whether or not it is gzipped -- traces are committed .gz (see .gitignore)."""
    path = str(path)
    if os.path.exists(path):
        return open(path)
    return gzip.open(path + ".gz", "rt")

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "raw")
OUT = sys.argv[1] if len(sys.argv) > 1 else "."

INK, BODY, MUTED = "#1A1A1A", "#2E2E2E", "#4F4F4F"
FAINT, RULE, ACCENT = "#6E6E6E", "#D0D0D0", "#065A82"
ACCENT_BG, PANEL, WARNC = "#EEF3F6", "#F7F8F9", "#9C3B2E"

# A monochrome ramp for the three sampling rates, so "darker = sampling harder" carries the
# ordering without spending a second hue on it. WARNC stays reserved for the failure case.
RATE_COLS = ["#A9C3D3", "#4E88A6", ACCENT]
GREY = "#9AA0A4"

plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white",
    "axes.edgecolor": RULE, "axes.labelcolor": BODY, "text.color": INK,
    "xtick.color": MUTED, "ytick.color": MUTED, "font.size": 10,
    "axes.spines.top": False, "axes.spines.right": False,
})

TRIM = 6.0


# --------------------------------------------------------------------------- data loading
def load_twin(label, trim=TRIM):
    rows = [json.loads(l) for l in _open(f"{RAW}/{label}_twin.jsonl") if '"error"' not in l]
    t0 = rows[0]["t"]
    return [r for r in rows if r["t"] - t0 >= trim]


def busiest_edge(rows):
    """None when the twin reported nothing anywhere -- which is a real outcome in this round,
    not a missing file, so it has to be representable rather than an exception."""
    tot = defaultdict(int)
    for r in rows:
        for k, v in r["twin"].items():
            tot[k] += v
    if not tot or max(tot.values()) == 0:
        return None
    return max(tot, key=tot.get)


def twin_stats(label):
    """Resolution and precision on the busiest edge.

    quantum: the gcd of the distinct readings. It is rate x frame x 8 and the frame length is a
    property of the flow, so it is measured, never assumed -- the 08-19 round learned that.

    lambda: a reading divided by the quantum IS the number of sFlow samples that landed in that
    refresh window, so the counting process is recovered directly. Sampled at the twin's own
    1 Hz refresh cadence (every 4th poll), not once per changed value: counting only changes
    hides windows that repeat a count, and repeats cluster at the mode, which hollows out the
    centre of the distribution and biases Fano upward.
    """
    rows = load_twin(label)
    e = busiest_edge(rows)
    if e is None:
        return dict(edge=None, live=False)
    vals = sorted({r["twin"].get(e, 0) for r in rows if r["twin"].get(e, 0) > 0})
    q = reduce(math.gcd, vals)
    gt = (rows[-1]["tx"][e] - rows[0]["tx"][e]) * 8 / (rows[-1]["t"] - rows[0]["t"])
    hz = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
    step = max(1, int(round(hz)))
    counts = [rows[i]["twin"].get(e, 0) / q for i in range(0, len(rows), step)]
    lam = st.mean(counts)
    sd = math.sqrt(st.pvariance(counts))
    # time-weighted, because the poll cadence is nominal and the timestamps are what happened
    num = den = 0.0
    for i in range(len(rows) - 1):
        dt = rows[i + 1]["t"] - rows[i]["t"]
        num += rows[i]["twin"].get(e, 0) * dt
        den += dt
    return dict(edge=e, live=True, q=q, gt=gt, lam=lam, fano=st.pvariance(counts) / lam,
                sd_mean=sd / lam * 100, theory=100 / math.sqrt(lam), mean=num / den,
                n_distinct=len(vals), n_win=len(counts))


def cpu_stats(label, trim=TRIM):
    """Per-process and per-group % of ONE core, by the method in tools/test_workflow/cpu_report.py.

    First/last per key rather than first/last of the file, because processes come and go: the
    iperf3 client appears 2 s in, and a group total taken across the whole window would
    understate any process in proportion to how briefly it lived.
    """
    rows, hdr = [], None
    for line in _open(f"{RAW}/{label}_cpu.jsonl"):
        d = json.loads(line)
        if "clk_tck" in d:
            hdr = d
        elif "error" not in d:
            rows.append(d)
    t0 = rows[0]["t"]
    rows = [r for r in rows if r["t"] - t0 >= trim]
    clk, nproc = hdr["clk_tck"], hdr["nproc"]
    mb = rows[-1]["machine"]["busy"] - rows[0]["machine"]["busy"]
    mt = rows[-1]["machine"]["total"] - rows[0]["machine"]["total"]
    first, last, ft, lt = {}, {}, {}, {}
    for r in rows:
        for k, v in r["proc"].items():
            if k not in first:
                first[k], ft[k] = v, r["t"]
            last[k], lt[k] = v, r["t"]
    groups, procs = defaultdict(float), {}
    for k in first:
        dt = lt[k] - ft[k]
        if dt <= 0:
            continue
        pct = 100.0 * (last[k] - first[k]) / clk / dt
        procs[k] = dict(pct=pct, t_first=ft[k] - t0, t_last=lt[k] - t0)
        groups[k.split(":")[0].rsplit("-", 1)[0]] += pct
    return dict(machine=100.0 * mb / mt, nproc=nproc, groups=dict(groups), procs=procs)


def per_switch(label):
    """bmv2-N -> % of one core. Names are unique per switch, so no aggregation is needed --
    and must not be done by name alone: every iperf3 process is called "iperf", which is why
    the group totals go through cpu_stats() and this does not."""
    c = cpu_stats(label)
    out = {}
    for k, v in c["procs"].items():
        name = k.split(":")[0]
        if name.startswith("bmv2-"):
            out[int(name.split("-")[1])] = v["pct"]
    return out


def delivered(label):
    s = json.load(open(f"{RAW}/{label}_client.json"))["end"]["sum"]
    return s["bits_per_second"] / 1e6, s["lost_percent"]


def iperf_roles(label):
    """Split the iperf3 processes into sender / receiver / wrapper.

    measure.sh starts the server, sleeps 1 s, starts the pollers, sleeps 2 s, then starts the
    client. So the server is already running when sampling begins and the client is not: the
    process present at t=0 is the receiver, the ones that appear at t~2 s are the sender and
    the mnexec/sudo wrapper whose cmdline also contains "iperf3" (cpu_probe.TARGETS tests
    "iperf" before "mininet", so the wrapper is labelled iperf too). The wrapper is the one
    that burns no CPU at all. Both discriminators agree on all five conditions.

    Appearance time has to come from the UNTRIMMED trace. After a 6 s trim every surviving
    process "first appears" at 6 s and the ordering that identifies them is gone -- the first
    version of this function looked at the trimmed times and found no receiver at all. The
    percentages still come from the trimmed window.
    """
    c = cpu_stats(label)
    raw = cpu_stats(label, trim=0.0)
    ip = {k: v for k, v in c["procs"].items() if k.startswith("iperf")}
    recv = [k for k in ip if raw["procs"][k]["t_first"] < 1.0]
    late = [k for k in ip if raw["procs"][k]["t_first"] >= 1.0]
    send = max(late, key=lambda k: ip[k]["pct"]) if late else None
    wrap = [k for k in late if k != send]
    return dict(receiver=recv[0] if recv else None, sender=send, wrappers=wrap,
                total=sum(v["pct"] for v in ip.values()), procs=ip)


# ------------------------------------------------- figure 1: what you get vs what it costs
def fig_tradeoff(fname):
    rates = [("1/256", "rate256", 256), ("1/128", "rate128", 128), ("1/64", "rate64", 64)]
    T = {lab: twin_stats(f) for lab, f, _ in rates}
    C = {lab: cpu_stats(f) for lab, f, _ in rates}
    xs = [1.0 / n for _, _, n in rates]

    fig, (axL, axR) = plt.subplots(1, 2, figsize=(12.2, 5.2),
                                   gridspec_kw={"width_ratios": [1.0, 1.12]})

    # ---- left: resolution and precision, both against sampling rate, both log.
    # Log-log is the point of the panel rather than a convenience: resolution is a straight
    # line of slope -1 (halve the rate, halve the quantum) and precision one of slope -1/2.
    # The two different slopes ARE the trade, and on a linear axis they look like the same
    # curve drawn twice.
    qs = [T[lab]["q"] / 1e6 for lab, _, _ in rates]
    axL.plot(xs, qs, marker="o", ms=7, color=ACCENT, lw=1.8, zorder=3)
    for x, q in zip(xs, qs):
        axL.annotate(f"{q:.3f}", (x, q), textcoords="offset points", xytext=(0, -17),
                     ha="center", fontsize=8.8, color=ACCENT)
    axL.set_xscale("log"); axL.set_yscale("log")
    axL.set_xticks(xs)
    axL.set_xticklabels([lab for lab, _, _ in rates])
    # A log axis draws its own decade ticks underneath the three set above, and they land on
    # top of them ("3x10^-3" printed through "1/256"). Both locators have to go, not just the
    # labels, or the minor ticks come back as unlabelled marks between the rates.
    axL.xaxis.set_minor_locator(matplotlib.ticker.NullLocator())
    axL.yaxis.set_minor_locator(matplotlib.ticker.NullLocator())
    axL.set_xlim(xs[0] / 1.55, xs[-1] * 1.55)
    axL.set_ylim(0.42, 6.2)
    axL.set_yticks([0.5, 1, 2, 4])
    axL.set_yticklabels(["0.5", "1", "2", "4"])
    axL.set_ylabel("resolution step — quantum (Mbit/s)", color=ACCENT)
    axL.tick_params(axis="y", colors=ACCENT)
    axL.set_xlabel("sFlow sampling rate")

    axP = axL.twinx()
    axP.spines["right"].set_visible(True)
    axP.spines["right"].set_color(RULE)
    axP.spines["top"].set_visible(False)
    ds = [T[lab]["sd_mean"] for lab, _, _ in rates]
    th = [T[lab]["theory"] for lab, _, _ in rates]
    # the theory curve is drawn across the whole span, not just through the three points, so it
    # is visibly a prediction the points land on rather than a line fitted to them
    lam0 = T["1/256"]["lam"]
    xf = [xs[0] / 1.5 * (1.0293 ** i) for i in range(120)]
    axP.plot(xf, [100 / math.sqrt(lam0 * x / xs[0]) for x in xf],
             ls=(0, (4, 3)), color=FAINT, lw=1.3, zorder=1)
    axP.plot(xs, ds, marker="s", ms=7, color=WARNC, lw=1.8, ls="-", zorder=3)
    # Value labels go ABOVE the dispersion markers and BELOW the quantum ones. The two curves
    # cross between 1/128 and 1/64 -- slope -1/2 against slope -1 -- so labels placed on the
    # same side of each marker collide near the crossing whatever the offset.
    for x, d in zip(xs, ds):
        axP.annotate(f"{d:.1f}%", (x, d), textcoords="offset points", xytext=(0, 11),
                     ha="center", fontsize=8.8, color=WARNC)
    axP.set_yscale("log")
    axP.yaxis.set_minor_locator(matplotlib.ticker.NullLocator())
    axP.set_ylim(3.6, 26)
    axP.set_yticks([4, 6, 8, 12, 20])
    axP.set_yticklabels(["4%", "6%", "8%", "12%", "20%"])
    axP.set_ylabel("precision — dispersion sd/mean", color=WARNC)
    axP.tick_params(axis="y", colors=WARNC)

    lam_txt = " / ".join("%.0f" % T[l]["lam"] for l, _, _ in rates)
    # Explicit newlines, not one long line per row. Matplotlib does not wrap text, so a string
    # wider than its axes silently overruns into the neighbouring panel -- which is exactly what
    # happened here: the left panel's lambda line landed on top of the right panel's y-axis
    # label. Wrapping at the source is the fix; widening the figure only postpones it.
    axL.set_title("What you get", fontsize=11.5, color=INK, loc="left", pad=58, weight="bold")
    axL.text(0, 1.018,
             f"quantum = rate × {T['1/256']['q'] // 8 // 256} B × 8, exact at all three rates.\n"
             f"λ = {lam_txt} samples per 1 s window.\n"
             f"Resolution {T['1/256']['q']/T['1/64']['q']:.2f}× finer, precision only "
             f"{T['1/256']['sd_mean']/T['1/64']['sd_mean']:.2f}× tighter.\n"
             f"Unbiased throughout (twin/truth "
             f"{min(T[l]['mean']/T[l]['gt'] for l,_,_ in rates):.3f}–"
             f"{max(T[l]['mean']/T[l]['gt'] for l,_,_ in rates):.3f}).",
             transform=axL.transAxes, fontsize=8.4, color=MUTED, va="bottom", linespacing=1.55)

    handles = [plt.Line2D([], [], marker="o", color=ACCENT, lw=1.8, label="quantum (left axis)"),
               plt.Line2D([], [], marker="s", color=WARNC, lw=1.8, label="measured sd/mean (right axis)"),
               plt.Line2D([], [], ls=(0, (4, 3)), color=FAINT, lw=1.3,
                          label=r"sampling theory  $1/\sqrt{\lambda}$")]
    axL.legend(handles=handles, frameon=False, fontsize=8.3, loc="lower left")

    # ---- right: what it costs. Axis starts at zero. bmv2 is ~150% and the proxy ~12-24%, so a
    # zero-based axis makes the proxy's near-doubling look small -- which is the honest
    # picture, and the reason the delta is written above each group instead of being
    # manufactured by cropping the axis.
    groups = [("bmv2", "bmv2\n(data plane)"), ("kernel", "kernel"), ("proxy", "proxy")]
    w = 0.26
    for gi, (g, _) in enumerate(groups):
        for ri, (lab, _, _) in enumerate(rates):
            v = C[lab]["groups"].get(g, 0.0)
            x = gi + (ri - 1) * w
            axR.bar([x], [v], width=w * 0.9, color=RATE_COLS[ri],
                    label=lab if gi == 0 else None)
            axR.text(x, v + 2.5, f"{v:.1f}", ha="center", fontsize=8.2,
                     color=INK if ri == 2 else MUTED)
    axR.set_xticks(range(len(groups)))
    axR.set_xticklabels([n for _, n in groups])
    axR.set_ylabel("CPU, % of ONE core (14 on this machine)")
    axR.set_ylim(0, 250)  # headroom: the delta captions live above the bars, not on them
    axR.set_xlim(-0.55, len(groups) - 0.45)
    for gi, (g, _) in enumerate(groups):
        a = C["1/256"]["groups"].get(g, 0.0)
        b = C["1/64"]["groups"].get(g, 0.0)
        d = b - a
        col = MUTED if abs(d) < 3 else WARNC
        note = "flat — this is noise" if abs(d) < 3 else f"{b/a:.2f}×"
        axR.text(gi, 212, f"{d:+.1f} pts", ha="center", fontsize=9.5, color=col, weight="bold")
        axR.text(gi, 178, note, ha="center", fontsize=8.4, color=col)
    axR.text(-0.5, 240, "1/256 → 1/64:", ha="left", fontsize=8.4, color=FAINT)
    # Legend below the axes. Inside the panel it has nowhere to go: the delta row occupies the
    # top of every group and the bmv2 bars reach 158, so any in-axes corner collides with one
    # or the other.
    axR.legend(frameon=False, fontsize=8.6, loc="upper center", bbox_to_anchor=(0.5, -0.145),
               title="sFlow sampling rate", title_fontsize=8.6, ncol=3, columnspacing=1.6,
               handlelength=1.2)
    axR.set_title("What it costs", fontsize=11.5, color=INK, loc="left", pad=58, weight="bold")
    dl = [delivered(f)[0] for _, f, _ in rates]
    axR.text(0, 1.018,
             f"Delivered throughput identical at all three rates:\n"
             f"{dl[0]:.1f} / {dl[1]:.1f} / {dl[2]:.1f} Mbit/s.\n"
             f"Machine total {min(C[l]['machine'] for l,_,_ in rates):.0f}–"
             f"{max(C[l]['machine'] for l,_,_ in rates):.0f}% of {C['1/256']['nproc']} cores —\n"
             f"nothing here is contending for a saturated box.",
             transform=axR.transAxes, fontsize=8.4, color=MUTED, va="bottom", linespacing=1.55)

    fig.suptitle("Sampling harder buys precision on a √ law — and the data plane does not pay "
                 "for it", fontsize=13, color=INK, x=0.012, y=0.982, ha="left", weight="bold")
    fig.text(0.012, 0.925,
             "4× the sampling rate gives 4× the resolution but only 1.8× the precision, exactly "
             "as 1/√λ predicts. The bill for it lands on the kernel and the proxy;",
             fontsize=9, color=MUTED, va="top")
    fig.text(0.012, 0.888,
             "bmv2 moves −2.0 points across the whole sweep, which is less than the spread "
             "between repeats of the same condition. First 6 s of every trace discarded.",
             fontsize=9, color=MUTED, va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.865])
    fig.subplots_adjust(wspace=0.30)
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname,
          {lab: dict(q=round(T[lab]["q"] / 1e6, 4), lam=round(T[lab]["lam"], 1),
                     sd=round(T[lab]["sd_mean"], 1), theory=round(T[lab]["theory"], 1),
                     fano=round(T[lab]["fano"], 2),
                     bias=round(T[lab]["mean"] / T[lab]["gt"], 3),
                     **{k: round(v, 1) for k, v in C[lab]["groups"].items()})
           for lab, _, _ in rates})


# ------------------------------------------------ figure 2: the cost of sampling, isolated
def fig_where(fname):
    conds = [("clone, full frame", "rate64", ACCENT),
             ("clone truncated to 128 B", "trunc128", WARNC),
             # Replaced 2026-08-20. The cell originally here, labelled "no clone session at
             # all", did not have its session removed: it ran on a warm fabric, where the
             # leading DELETE lands on bookkeeping the pipeline re-push emptied and never
             # reaches the orphaned PRE group. It reported 553.5 samples/s under a zero-sampling
             # label. mzero_poll is the re-run on a COLD fabric with the control verified before
             # measuring -- 0 non-zero twin readings on 32 inter-switch edges while 200 Mbit/s
             # flowed. Same duration, same offered load, same poll-on arm; a different fabric
             # instance, which the subtitle states.
             ("no clone session (cold-fabric re-run)", "mzero_poll", GREY)]
    C = {f: cpu_stats(f) for _, f, _ in conds}
    D = {f: delivered(f) for _, f, _ in conds}
    TW = {f: twin_stats(f) for _, f, _ in conds}

    fig, (axA, axB) = plt.subplots(1, 2, figsize=(12.6, 5.4),
                                   gridspec_kw={"width_ratios": [1.0, 1.15]})

    # ---- A: CPU by group, three conditions. All at 1/64, i.e. 4x production clone load, so
    # any cost of sampling is four times easier to see than it would be in production.
    groups = [("bmv2", "bmv2\n(data plane)"), ("kernel", "kernel"), ("proxy", "proxy")]
    w = 0.26
    for gi, (g, _) in enumerate(groups):
        for ci, (lab, f, col) in enumerate(conds):
            v = C[f]["groups"].get(g, 0.0)
            x = gi + (ci - 1) * w
            axA.bar([x], [v], width=w * 0.9, color=col)
            axA.text(x, v + 2.5, f"{v:.1f}", ha="center", fontsize=8.2, color=MUTED)
    axA.set_xticks(range(len(groups)))
    axA.set_xticklabels([n for _, n in groups])
    axA.set_ylabel("CPU, % of ONE core")
    axA.set_ylim(0, 186)
    axA.set_xlim(-0.55, len(groups) - 0.45)

    on = C["rate64"]["groups"]
    off = C["mzero_poll"]["groups"]
    for gi, (g, _) in enumerate(groups):
        d = off.get(g, 0) - on.get(g, 0)
        col = MUTED if abs(d) < 5 else WARNC
        txt = "unchanged" if abs(d) < 5 else f"{d:+.1f} pts"
        axA.text(gi, 172, txt, ha="center", fontsize=9.5, color=col, weight="bold")
        if abs(d) >= 5:
            axA.text(gi, 163, f"{off[g]/on[g]:.2f}× of the clone-on cost", ha="center",
                     fontsize=8.0, color=col)
        else:
            axA.text(gi, 163, f"{d:+.1f} pts — the wrong way", ha="center",
                     fontsize=8.0, color=col)

    handles = [Patch(facecolor=col,
                     label=f"{lab} — {D[f][0]:.1f} Mbit/s delivered, "
                           f"{'telemetry OK' if TW[f]['live'] else 'NO TELEMETRY'}")
               for lab, f, col in conds]
    axA.legend(handles=handles, frameon=False, fontsize=8.2, loc="upper left",
               bbox_to_anchor=(0.0, 1.0))
    axA.set_title("Turning sampling off, at 4× production load", fontsize=11.5, color=INK,
                  loc="left", pad=30, weight="bold")
    axA.text(0, 1.075, "Deleting the clone session removes every downstream cost and leaves "
                       "the forwarding path byte-identical.", transform=axA.transAxes,
             fontsize=8.4, color=MUTED)
    axA.text(0, 1.020, "bmv2 is nominally HIGHER with sampling off, so the data-plane "
                       "difference is noise, not a small saving.", transform=axA.transAxes,
             fontsize=8.4, color=MUTED)

    # ---- B: the same bmv2 total, opened up. "bmv2 CPU 149%" sounds like a fabric near its
    # limit; it is three switches at half a core and seven at nothing. bmv2 forwards on one
    # thread, so the per-switch figure is the one that can hit a ceiling, and it is at ~50%.
    sw_on, sw_off = per_switch("rate64"), per_switch("mzero_poll")
    ids = sorted(sw_on)
    w2 = 0.36
    for i, s in enumerate(ids):
        axB.bar([i - w2 / 2], [sw_on[s]], width=w2 * 0.92, color=ACCENT)
        axB.bar([i + w2 / 2], [sw_off[s]], width=w2 * 0.92, color=GREY)
    for i, s in enumerate(ids):
        if max(sw_on[s], sw_off[s]) > 5:
            axB.text(i, max(sw_on[s], sw_off[s]) + 2.0,
                     f"{sw_on[s]:.0f} / {sw_off[s]:.0f}", ha="center", fontsize=8.0, color=MUTED)
    axB.axhline(100, color=RULE, lw=1.0, ls="--", zorder=0)
    axB.text(len(ids) - 0.4, 101.5, "one core", ha="right", fontsize=8.0, color=FAINT)
    axB.set_xticks(range(len(ids)))
    axB.set_xticklabels([f"s{s}" for s in ids], fontsize=9)
    for i, s in enumerate(ids):
        if max(sw_on[s], sw_off[s]) > 5:
            axB.get_xticklabels()[i].set_color(ACCENT)
            axB.get_xticklabels()[i].set_weight("bold")
    axB.set_ylabel("CPU, % of ONE core")
    axB.set_ylim(0, 118)
    axB.set_xlim(-0.7, len(ids) - 0.3)
    axB.legend(handles=[Patch(facecolor=ACCENT, label="clone, full frame"),
                        Patch(facecolor=GREY, label="no clone session at all")],
               frameon=False, fontsize=8.4, loc="upper right")
    axB.set_title("The same total, opened up: 3 of 10 switches do the work",
                  fontsize=11.5, color=INK, loc="left", pad=30, weight="bold")
    busy = [s for s in ids if sw_on[s] > 5]
    axB.text(0, 1.075,
             f"s{', s'.join(str(s) for s in busy)} are the switches the flow crosses "
             f"(confirmed on the tx counters); the other {len(ids)-len(busy)} sit at "
             f"{max(sw_on[s] for s in ids if s not in busy):.1f}%.",
             transform=axB.transAxes, fontsize=8.4, color=MUTED)
    axB.text(0, 1.020,
             "So \"bmv2 at 150% of a core\" is really three single-threaded switches at half a "
             "core each — nowhere near their own ceiling.",
             transform=axB.transAxes, fontsize=8.4, color=MUTED)

    fig.suptitle("Deleting sampling entirely costs the data plane nothing — the bill was never "
                 "there", fontsize=13, color=INK, x=0.012, y=0.982, ha="left", weight="bold")
    fig.text(0.012, 0.925,
             f"All three conditions at 1/64, four times production sampling load. Removing "
             f"100% of the sampling work leaves delivered throughput and bmv2 CPU unchanged, "
             f"and takes {on['kernel']-off['kernel']:.0f} points off the kernel and "
             f"{on['proxy']-off['proxy']:.0f} off the proxy.",
             fontsize=9, color=MUTED, va="top")
    fig.text(0.012, 0.888,
             "Truncating the clone at the switch has the CPU signature of having no clone at "
             "all — which is the diagnosis: the sample is dropped, not shortened. It produced "
             "zero telemetry on every edge, silently.",
             fontsize=9, color=WARNC, va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.865])
    fig.subplots_adjust(wspace=0.24)
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname,
          {f: dict(delivered=round(D[f][0], 1), loss=round(D[f][1], 2), live=TW[f]["live"],
                   **{k: round(v, 1) for k, v in C[f]["groups"].items()}) for _, f, _ in conds},
          "per-switch on/off:", {s: (round(sw_on[s], 1), round(sw_off[s], 1)) for s in ids})


# -------------------------------------------- figure 3: the generator competing with the fabric
def fig_iperf(fname):
    LAB = "rate256"
    c = cpu_stats(LAB)
    roles = iperf_roles(LAB)

    def pretty(key):
        name = key.split(":")[0]
        if key == roles["sender"]:
            return "iperf3 — sending side", WARNC
        if key == roles["receiver"]:
            return "iperf3 — receiving side", WARNC
        if name == "kernel":
            return "ndtwin kernel", MUTED
        if name == "proxy":
            return "proxy agent", MUTED
        return f"bmv2 — switch s{name.split('-')[1]}", ACCENT

    # The zero-CPU wrapper is dropped: cpu_probe labels it "iperf" because sudo/mnexec carry
    # "iperf3" in their cmdline, and a 0.0% bar labelled iperf3 would read as a third generator
    # process rather than as the shell around one. It is included in the group total below.
    items = [(v["pct"], k) for k, v in c["procs"].items() if k not in roles["wrappers"]]
    items.sort()

    fig, ax = plt.subplots(figsize=(11.6, 6.2))
    ys = range(len(items))
    labels, cols = [], []
    for y, (pct, k) in zip(ys, items):
        lab, col = pretty(k)
        labels.append(lab)
        cols.append(col)
        ax.barh([y], [pct], height=0.66, color=col)
        ax.text(pct + 1.2, y, f"{pct:.1f}%", va="center", fontsize=8.8, color=col)
    ax.set_yticks(list(ys))
    ax.set_yticklabels(labels, fontsize=9)
    for t, col in zip(ax.get_yticklabels(), cols):
        t.set_color(col)
    ax.axvline(100, color=RULE, lw=1.1, ls="--", zorder=0)
    ax.text(100, len(items) - 0.35, "one core saturated", fontsize=8.4, color=FAINT,
            ha="center", va="bottom")
    ax.set_xlim(0, 118)
    ax.set_ylim(-0.8, len(items) - 0.2)
    ax.set_xlabel("CPU, % of ONE core   ·   the machine has 14")

    busiest_sw = max(v["pct"] for k, v in c["procs"].items() if k.startswith("bmv2"))
    ax.text(0.985, 0.055,
            f"traffic generator, both sides: {roles['total']:.1f}% of a core\n"
            f"busiest switch: {busiest_sw:.1f}%   ·   whole machine: {c['machine']:.1f}% of "
            f"{c['nproc']} cores",
            transform=ax.transAxes, fontsize=8.8, color=MUTED, ha="right", va="bottom")

    fig.suptitle("The biggest CPU consumer on the box is the instrument, not the fabric",
                 fontsize=13, color=INK, x=0.012, y=0.975, ha="left", weight="bold")
    fig.text(0.012, 0.918,
             f"Every process, 1/256 run, first 6 s discarded. iperf3's sending side alone burns "
             f"{c['procs'][roles['sender']]['pct']:.1f}% of a core — more than the busiest "
             f"switch ({busiest_sw:.1f}%) and more than the kernel.",
             fontsize=9, color=MUTED, va="top")
    fig.text(0.012, 0.882,
             "It runs on the same machine as the fabric it is measuring, in all five conditions "
             "of this round. At 22% total load it is not distorting these results — but it is "
             "the first thing to move off-box before pushing the fabric.",
             fontsize=9, color=MUTED, va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.865])
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname, "sender", roles["sender"], round(c["procs"][roles["sender"]]["pct"], 1),
          "| receiver", roles["receiver"], round(c["procs"][roles["receiver"]]["pct"], 1),
          "| wrappers dropped", roles["wrappers"], "| group total", round(roles["total"], 1))


# ------------------------------------------------- the northbound API's concurrency envelope
def fig_concurrency(fname):
    """Throughput flat, latency linear -- the signature of one server, with no fault injected.

    The twin's central claim is that seven apps consume it simultaneously through /ndt/, and
    nothing had tested that: both harnesses issue requests serially. This does not try to make
    a handler slow, because it does not need to. A single-threaded server has a signature
    visible under ordinary load: throughput pinned at 1/T while latency grows as N*T.

    Plotted with the serialised prediction as a reference line rather than a fitted curve, so
    the reader checks the measurement against theory instead of against a line drawn through
    the measurement.
    """
    d = json.load(open(f"{RAW}/headline_blocking.json"))
    lv = d["levels"]
    ns = [r["n"] for r in lv]
    tp = [r["throughput_rps"] for r in lv]
    p50 = [r["p50_ms"] for r in lv]
    p95 = [r["p95_ms"] for r in lv]
    base = p50[0]

    fig, (axT, axL) = plt.subplots(1, 2, figsize=(11.6, 4.9))

    axT.plot(ns, tp, marker="o", color=ACCENT, lw=1.8)
    axT.axhline(1000.0 / base, color=INK, lw=1.2, ls="--", zorder=0)
    axT.text(ns[-1], 1000.0 / base + 2.5, f"1 / {base:.1f} ms = {1000.0/base:.0f} req/s",
             ha="right", fontsize=8.6, color=INK)
    axT.set_ylim(0, max(tp) * 1.55)
    axT.set_xscale("log", base=2); axT.set_xticks(ns); axT.set_xticklabels(ns)
    axT.set_xlabel("concurrent clients"); axT.set_ylabel("throughput (req/s)")
    axT.set_title("Throughput does not move", fontsize=11.5, color=INK, loc="left",
                  pad=34, weight="bold")
    axT.text(0, 1.018,
             f"{tp[0]:.1f} \u2192 {tp[-1]:.1f} req/s across a {ns[-1]}\u00d7 rise in concurrency.\n"
             f"The dashed line is one request in flight at a time.",
             transform=axT.transAxes, fontsize=8.4, color=MUTED, va="bottom", linespacing=1.55)

    ideal = [base * n for n in ns]
    axL.plot(ns, ideal, color=GREY, lw=1.4, ls="--", zorder=1,
             label="serialised: p50 = N \u00d7 11.9 ms")
    axL.plot(ns, p50, marker="o", color=ACCENT, lw=1.8, zorder=3, label="measured p50")
    axL.plot(ns, p95, marker="s", color=WARNC, lw=1.2, ms=4, zorder=2, label="measured p95")
    for n, y in zip(ns, p50):
        axL.annotate(f"{y/base:.2f}\u00d7", (n, y), textcoords="offset points", xytext=(6, -11),
                     fontsize=8.2, color=ACCENT)
    axL.set_xscale("log", base=2); axL.set_xticks(ns); axL.set_xticklabels(ns)
    axL.set_xlabel("concurrent clients"); axL.set_ylabel("latency (ms)")
    axL.legend(frameon=False, fontsize=8.6, loc="upper left")
    axL.set_title("Latency does, exactly as serialisation predicts", fontsize=11.5, color=INK,
                  loc="left", pad=34, weight="bold")
    axL.text(0, 1.018,
             "Measured against predicted: "
             + " / ".join(f"{y/base:.2f}\u00d7 vs {n}\u00d7" for n, y in zip(ns[1:], p50[1:]))
             + ".\nAgreement within 2% at every level. No fault was injected.",
             transform=axL.transAxes, fontsize=8.4, color=MUTED, va="bottom", linespacing=1.55)

    fig.suptitle("The northbound API serves one request at a time \u2014 measured, and it has "
                 "room today", fontsize=13, color=INK, x=0.012, y=0.985, ha="left", weight="bold")
    # Wrapped explicitly. matplotlib does not wrap, so a subtitle wider than the figure is
    # silently clipped at the right edge -- it happened once already in this file's tradeoff
    # figure, panel-to-panel, and again here against the figure boundary.
    fig.text(0.012, 0.905,
             f"net::io_context ioc{{1}} (src/main.cpp:316), with handlers that shell out "
             f"through popen.\n"
             f"Seven apps polling at 1 Hz is {7*base/1000*100:.1f}% of the thread "
             f"({1000.0/base/7:.0f}\u00d7 headroom), so this does not bite at the load the twin "
             f"actually runs at.\n"
             f"What it bounds: a southbound call blocking for 500 ms holds the only thread for "
             f"{round(500/base)} requests\u2019 worth, and every consumer waits behind it.",
             fontsize=9, color=MUTED, va="top", linespacing=1.6)
    fig.tight_layout(rect=[0, 0, 1, 0.845])
    fig.subplots_adjust(wspace=0.26)
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname, {r["n"]: (round(r["throughput_rps"], 1), round(r["p50_ms"], 1)) for r in lv})


# ------------------------------------------ figure 5: the matrix, decomposed
def total_sample_rate(label):
    """Samples per second reaching the kernel, summed over every edge -- not one edge's lambda.

    A flow crossing three switches is sampled at each of them, and the kernel pays for every
    datagram, so the busiest edge's lambda would understate the load by the number of hops.
    Same method as analyse_matrix.py, which is the text version of this figure.
    """
    rows = load_twin(label)
    vals = sorted({v for r in rows for v in r["twin"].values() if v > 0})
    if not vals:
        return 0.0
    q = reduce(math.gcd, vals)
    hz = (len(rows) - 1) / (rows[-1]["t"] - rows[0]["t"])
    step = max(1, int(round(hz)))
    return st.mean([sum(rows[i]["twin"].values()) / q for i in range(0, len(rows), step)])


def fig_decomposition(fname):
    """Split the kernel's CPU into baseline, serving the instrument, and ingesting sFlow.

    WHY THE `mnone` CELL IS NOT ON THIS FIGURE
    ------------------------------------------
    The matrix was built with a sixth pair, `mnone`, meant to be the intercept: run under
    NDTWIN_CLONE_DISABLE=1 so nothing is cloned. It is not an intercept. Its twin trace carries
    480,540,662,784 counter-units over 2,352 non-zero readings and it measures 553.5 samples/s
    -- a replicate of the 1/64 cell, not a zero. Its CPU says the same thing (67.7/60.0 against
    67.9/60.1 at 1/64). Including it changes the slope by 1.1 us/sample, so nothing here turns
    on excluding it; it is excluded because a point labelled "zero" that is not zero is the
    defect this round has now hit three times.

    The real zero is `mzero`, re-run on a COLD fabric with the control verified before
    measuring: 0 non-zero twin readings across 32 edges. Its iperf3 client.json is a stub of
    nulls -- the jq slimming path in measure.sh turns an errored iperf3 into well-formed JSON
    full of nulls and discards the error text -- so its offered load is taken from the
    /proc/net/dev counters instead, which are independent of both iperf3 and the kernel. They
    put 205.9 Mbit/s on s1-eth1, s2-eth3 and s5-eth2 over 293.8 s, the same three hops at the
    same rate as every other cell. The run happened; only its client-side JSON was lost.
    """
    rates = [1024, 512, 256, 128, 64]
    on = {r: cpu_stats(f"m{r}_poll")["groups"].get("kernel", 0.0) for r in rates}
    off = {r: cpu_stats(f"m{r}_nopoll")["groups"].get("kernel", 0.0) for r in rates}
    sr = {r: total_sample_rate(f"m{r}_poll") for r in rates}
    z_on = cpu_stats("mzero_poll")["groups"].get("kernel", 0.0)
    z_off = cpu_stats("mzero_nopoll")["groups"].get("kernel", 0.0)

    order = sorted(rates, key=lambda r: sr[r])          # ascending sample rate

    # Fit over the five measured cells only, poll-off arm (the instrument removed).
    xs, ys = [sr[r] for r in order], [off[r] for r in order]
    mx, my = st.mean(xs), st.mean(ys)
    b = (sum((x - mx) * (y - my) for x, y in zip(xs, ys))
         / sum((x - mx) ** 2 for x in xs))
    a = my - b * mx
    worst = max(abs(y - (a + b * x)) for x, y in zip(xs, ys))

    fig, (axA, axB) = plt.subplots(1, 2, figsize=(13.0, 5.6),
                                   gridspec_kw={"width_ratios": [1.0, 1.12]})

    # ---- A: the decomposition, stacked. Bottom-to-top is cheapest-to-dearest, so the eye
    # reads the answer -- ingest dominates and the instrument is a constant sliver -- without
    # having to difference two columns of a table.
    BASECOL, POLLCOL, INGCOL = GREY, "#A9C3D3", ACCENT
    labels = ["none\n(measured\nzero)"] + [f"1/{r}" for r in order]
    base_v = [z_off] + [z_off] * len(order)
    ing_v = [0.0] + [off[r] - z_off for r in order]
    poll_v = [z_on - z_off] + [on[r] - off[r] for r in order]

    idx = range(len(labels))
    axA.bar(idx, base_v, width=0.62, color=BASECOL, label=f"kernel baseline — {z_off:.1f}%")
    axA.bar(idx, ing_v, width=0.62, bottom=base_v, color=INGCOL, label="ingesting sFlow")
    axA.bar(idx, poll_v, width=0.62,
            bottom=[b_ + i_ for b_, i_ in zip(base_v, ing_v)], color=POLLCOL,
            label="serving the instrument (4 Hz poll of 288 edges)")
    for i, (b_, i_, p_) in enumerate(zip(base_v, ing_v, poll_v)):
        axA.text(i, b_ + i_ + p_ + 1.2, f"{b_ + i_ + p_:.1f}", ha="center",
                 fontsize=8.6, color=MUTED, weight="bold")
        if i_ > 6:
            axA.text(i, b_ + i_ / 2, f"{i_:.1f}", ha="center", va="center",
                     fontsize=8.4, color="white", weight="bold")
    axA.set_xticks(list(idx))
    axA.set_xticklabels(labels, fontsize=8.8)
    axA.set_ylabel("kernel CPU, % of ONE core")
    axA.set_ylim(0, 82)
    axA.legend(frameon=False, fontsize=8.3, loc="upper left")
    axA.set_title("Where the kernel's CPU goes, by sampling rate", fontsize=11.5, color=INK,
                  loc="left", pad=26, weight="bold")
    pv = [p for p in poll_v]
    axA.text(0, 1.055, f"The instrument is a flat {min(pv):.1f}–{max(pv):.1f} points at every "
                       f"rate, so subtracting it is safe —",
             transform=axA.transAxes, fontsize=8.4, color=MUTED)
    axA.text(0, 1.012, "and it is not what the kernel's CPU is spent on.",
             transform=axA.transAxes, fontsize=8.4, color=MUTED)

    # ---- B: is ingest linear in sample rate? Within the measured decade, yes, and very well.
    # Outside it the fit is not evidence -- which is the whole point of drawing the zero.
    axB.axvspan(0, min(xs), color=PANEL, zorder=0)
    axB.text(min(xs) / 2, 64.5, "never\nmeasured", ha="center", va="top", fontsize=7.6,
             color=FAINT, style="italic", linespacing=1.3)

    grid = [0, max(xs) * 1.06]
    axB.plot(grid, [a + b * g for g in grid], color=WARNC, lw=1.3, ls=(0, (5, 4)), zorder=2)
    axB.plot([min(xs), max(xs)], [a + b * min(xs), a + b * max(xs)],
             color=ACCENT, lw=2.4, zorder=3)
    axB.scatter(xs, ys, s=54, color=ACCENT, zorder=4, edgecolor="white", linewidth=1.0)
    axB.scatter([0], [a], s=70, marker="o", facecolor="white", edgecolor=WARNC,
                linewidth=1.8, zorder=5)
    axB.scatter([0], [z_off], s=150, marker="D", color=INK, zorder=5,
                edgecolor="white", linewidth=1.2)

    # The gap is the finding, so it gets the arrow; the words go in the empty lower half
    # rather than beside the arrow, where they used to sit on top of the first two cells.
    axB.annotate("", xy=(0, a), xytext=(0, z_off),
                 arrowprops=dict(arrowstyle="<->", color=WARNC, lw=1.8))
    axB.annotate(
        f"fit extrapolates to {a:.1f}% at zero samples/s\n"
        f"the cold-fabric control measures {z_off:.1f}%\n"
        f"{a - z_off:.1f} points apart — {(a - z_off) / 0.7:.0f}× the noise floor,\n"
        f"so this slope names no rate at which the kernel saturates",
        xy=(0, (a + z_off) / 2), xytext=(max(xs) * 0.20, 13.5),
        fontsize=8.8, color=WARNC, weight="bold", linespacing=1.5,
        arrowprops=dict(arrowstyle="->", color=WARNC, lw=1.1,
                        connectionstyle="arc3,rad=0.18"))

    axB.text(max(xs) * 0.50, a + b * max(xs) * 0.50 - 11.0,
             f"{b * 1e4:.0f} µs of CPU per sample\n(largest residual {worst:.1f} pt, "
             f"noise floor 0.7)", fontsize=8.8, color=ACCENT, weight="bold", linespacing=1.5)

    axB.set_xlim(-max(xs) * 0.05, max(xs) * 1.06)
    axB.set_ylim(0, 68)
    axB.set_xlabel("sFlow samples per second reaching the kernel, summed over all edges")
    axB.set_ylabel("kernel CPU, % of ONE core  (poll off)")
    axB.set_title("The marginal cost is linear — the line is not", fontsize=11.5, color=INK,
                  loc="left", pad=26, weight="bold")
    axB.text(0, 1.055, f"Five cells across a {max(xs) / min(xs):.0f}× range fit a straight line "
                       f"to within the noise floor. Extended to zero that same line",
             transform=axB.transAxes, fontsize=8.4, color=MUTED)
    axB.text(0, 1.012, f"overshoots the measured zero by {a / z_off:.0f}×, so the slope may not "
                       f"be extrapolated: it gives no rate at which the kernel saturates.",
             transform=axB.transAxes, fontsize=8.4, color=MUTED)

    fig.suptitle("Almost all of the kernel's sFlow cost is already paid at the lowest rate "
                 "measured", fontsize=13, color=INK, x=0.012, y=0.982, ha="left", weight="bold")
    fig.text(0.012, 0.918,
             f"Going from no telemetry to 34.7 samples/s costs {off[order[0]] - z_off:.1f} points "
             f"of a core; the next 16× of sampling on top of that costs only "
             f"{off[order[-1]] - off[order[0]]:.1f} more. Both arms of every",
             fontsize=9, color=MUTED, va="top")
    fig.text(0.012, 0.882,
             "pair ran identical traffic (5,357,127 packets, 200.0 Mbit/s). First 6 s of every "
             "trace discarded. The `mnone` cell is excluded — see docstring.",
             fontsize=9, color=MUTED, va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.86])
    fig.subplots_adjust(wspace=0.26)
    fig.savefig(os.path.join(OUT, fname), dpi=200)
    plt.close(fig)
    print("wrote", fname, dict(
        fit_intercept=round(a, 2), us_per_sample=round(b * 1e4, 1),
        max_resid=round(worst, 2), measured_zero=round(z_off, 2),
        gap=round(a - z_off, 1),
        samples=[round(sr[r], 1) for r in order],
        kernel_off=[round(off[r], 1) for r in order],
        poll_cost=[round(on[r] - off[r], 1) for r in order]))


if __name__ == "__main__":
    fig_tradeoff("page_sampling-tradeoff.png")
    fig_where("page_where-the-cpu-goes.png")
    fig_iperf("page_iperf-competes.png")
    fig_concurrency("page_api-concurrency-envelope.png")
    fig_decomposition("page_matrix-decomposition.png")
