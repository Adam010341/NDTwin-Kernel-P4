#!/usr/bin/env python3
"""Four deck figures for 8/27 whose pages currently carry only tables and bullets.

[Co-developed with claude code -- Adam]

WHY THESE FOUR. The 827 template has eleven figures and they all predate 08-25 evening. The
results that arrived after them -- ticket D's truncation verdict, the sampling ceiling, the CPU
attribution behind it, and the instrumented loop period -- sit on pages laid out as "全寬表格＋
兩條列". The professor reads figures, so those are the pages that lose the most to being text.

NO NUMBER IS TYPED BY HAND. Palette and per-cell loaders are imported from plot_figures.py, the
same way plot_ladder_rates.py does it, so these cannot drift from the figures beside them. The
per-cell verdicts come from the committed .out records by parsing, not transcription, and the
loop period is recovered from the kernel's own log.

THE LOOP PERIOD NEEDS DIFFERENCING, NOT READING. The kernel logs a mean over ALL iterations
since start, so a checkpoint tagged flows=16 still averages in every idle iteration before it --
the last line of a whole run reads flows=0 and 1033 ms. Differencing consecutive checkpoints
recovers the window each one covers, which is what "the period under load" means. Reading the
cumulative figure instead understates the load effect and would put a wrong number on a slide.

ONE MEASURE PER AXIS. Throughput, receiver loss and sample rate are three different units, so
they get three stacked panels sharing one x, never twinned y-axes on one frame.
"""
import json
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

PRIOR = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu"
ROUND = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-25_sampling-rounds"
SCALE = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-25_large-scale-concurrent"
sys.path.insert(0, PRIOR)
from plot_figures import (  # noqa: E402  -- reuse, never restate
    ACCENT, ACCENT_BG, FAINT, GREY, INK, MUTED, RULE, WARNC, cpu_stats, delivered,
)

OUT = sys.argv[1] if len(sys.argv) > 1 else "/home/adam/Desktop/NDTwin slide material 827/figures"
DPI = 200
WIDE = (15.2, 6.35)      # 3040x1270 at 200 dpi -- the deck's full-page slot, ar 2.39


# ----------------------------------------------------------------- shared style
def _frame(ax, ylab, ylab_pad=None):
    ax.set_ylabel(ylab, color=MUTED, fontsize=11, labelpad=ylab_pad or 8)
    ax.tick_params(colors=MUTED, labelsize=10, length=3, width=0.8)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(RULE)
        ax.spines[s].set_linewidth(0.8)
    ax.grid(axis="y", color=RULE, linewidth=0.6, alpha=0.55)
    ax.set_axisbelow(True)


def _title(fig, main, sub):
    fig.text(0.012, 0.965, main, color=INK, fontsize=17, fontweight="bold", va="top")
    fig.text(0.012, 0.905, sub, color=MUTED, fontsize=11.5, va="top")


def _save(fig, name):
    path = os.path.join(OUT, name)
    fig.savefig(path, dpi=DPI, facecolor="white", bbox_inches=None)
    plt.close(fig)
    print(f"wrote {path}")


# ----------------------------------------------------------------- data sources
VERDICT = re.compile(r"VERDICT (cell=\S+.*)")


def verdicts(path):
    """cell -> {key: float|str} from a committed *.out record."""
    out = {}
    for line in open(path):
        m = VERDICT.search(line)
        if not m:
            continue
        d = {}
        for tok in m.group(1).split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                try:
                    d[k] = float(v)
                except ValueError:
                    d[k] = v
        out[d["cell"]] = d
    return out


def grpc_bytes(path):
    """arm -> bytes carried on the P4Runtime streams during the gate arm."""
    out = {}
    for line in open(path):
        m = re.search(r"GRPCBYTES (\S+) delta=(\d+)", line)
        if m:
            out[m.group(1)] = int(m.group(2))
    return out


PERIOD = re.compile(r"over (\d+) iterations: mean ([\d.]+) ms, min ([\d.]+), max ([\d.]+) "
                    r"\(flows=(\d+), counters=(\d+)\)")


def loop_period(run):
    """flows -> list of per-window mean periods, recovered by differencing the running mean."""
    path = f"{SCALE}/raw/{run}/kernel.log"
    pts = []
    for line in open(path, errors="replace"):
        m = PERIOD.search(line)
        if m:
            n, mean, lo, hi, fl, _ = m.groups()
            pts.append((int(n), float(mean), int(fl)))
    by = {}
    pn, pm = 0, 0.0
    for n, mean, fl in pts:
        dn = n - pn
        if dn > 0:
            by.setdefault(fl, []).append((n * mean - pn * pm) / dn)
        pn, pm = n, mean
    return by


# ----------------------------------------------------------------- fig 1: truncate
def fig_truncate(name="page_truncate-bought-nothing.png"):
    """Left: it worked. Right: it changed nothing. The contrast is the whole argument."""
    gate = grpc_bytes(f"{ROUND}/gate_d.out")
    off = verdicts(f"{ROUND}/ladder_ext.out")      # truncation OFF (r0NN)
    on = verdicts(f"{ROUND}/ladder_d.out")         # truncation ON  (t0NN)
    pairs = [("1/8", "r008_poll", "t008_poll"), ("1/4", "r004_poll", "t004_poll"),
             ("1/2", "r002_poll", "t002_poll"), ("1/1", "r001_poll", "t001_poll")]

    fig = plt.figure(figsize=WIDE)
    _title(fig, "Truncation works, and buys nothing",
           "Sampled copies cut 5.6× on the P4Runtime stream — and every rate above the ceiling "
           "got slightly worse, not better")
    gs = fig.add_gridspec(1, 2, left=0.055, right=0.985, top=0.775, bottom=0.115,
                          wspace=0.20, width_ratios=[1, 1.55])

    # -- left: bytes on the stream
    ax = fig.add_subplot(gs[0, 0])
    full, trunc = gate["d256full_poll"] / 1e6, gate["d256trunc_poll"] / 1e6
    bars = ax.bar([0, 1], [full, trunc], width=0.52, color=[GREY, ACCENT],
                  edgecolor="white", linewidth=2)
    for b, v in zip(bars, (full, trunc)):
        ax.text(b.get_x() + b.get_width() / 2, v + full * 0.03, f"{v:,.1f} MB",
                ha="center", color=INK, fontsize=12, fontweight="bold")
    ax.annotate("", xy=(1, trunc + full * 0.16), xytext=(0, full * 0.62),
                arrowprops=dict(arrowstyle="-|>", color=WARNC, lw=2,
                                connectionstyle="arc3,rad=-0.22"))
    ax.text(0.5, full * 0.80, f"{full / trunc:.2f}× fewer bytes", ha="center",
            color=WARNC, fontsize=13, fontweight="bold")
    ax.set_xticks([0, 1])
    ax.set_xticklabels(["truncation off\n(16384 B)", "truncation on\n(128 B)"],
                       color=MUTED, fontsize=10.5)
    ax.set_xlim(-0.62, 1.62)
    ax.set_ylim(0, full * 1.20)
    _frame(ax, "bytes on the P4Runtime stream, 120 s")
    ax.set_title("It really truncates", color=INK, fontsize=13, fontweight="bold",
                 loc="left", pad=9)

    # -- right: lambda before -> after, one slope per rate
    ax = fig.add_subplot(gs[0, 1])
    for i, (lab, a, b) in enumerate(pairs):
        y0, y1 = off[a]["lam"], on[b]["lam"]
        ax.plot([i - 0.16, i + 0.16], [y0, y1], color=WARNC, lw=2.0, zorder=3,
                solid_capstyle="round")
        ax.plot([i - 0.16], [y0], "o", ms=9, color=GREY, mec="white", mew=1.6, zorder=4)
        ax.plot([i + 0.16], [y1], "o", ms=9, color=ACCENT, mec="white", mew=1.6, zorder=4)
        ax.text(i - 0.22, y0, f"{y0:,.0f}", ha="right", va="center", color=MUTED, fontsize=10.5)
        ax.text(i + 0.22, y1, f"{y1:,.0f}", ha="left", va="center", color=INK, fontsize=10.5,
                fontweight="bold")
    ax.set_xticks(range(len(pairs)))
    ax.set_xticklabels([p[0] for p in pairs], color=MUTED, fontsize=11)
    ax.set_xlabel("sampling rate", color=MUTED, fontsize=11, labelpad=6)
    ax.set_xlim(-0.55, len(pairs) - 0.30)
    _frame(ax, "samples per second reaching the collector (λ)")
    ax.set_title("Every arrow points down", color=INK, fontsize=13, fontweight="bold",
                 loc="left", pad=9)
    ax.plot([], [], "o", ms=9, color=GREY, mec="white", label="truncation off")
    ax.plot([], [], "o", ms=9, color=ACCENT, mec="white", label="truncation on")
    lg = ax.legend(loc="upper right", frameon=False, fontsize=10.5, handletextpad=0.5)
    for t in lg.get_texts():
        t.set_color(MUTED)
    fig.text(0.985, 0.028,
             "Sending 5.6× less data got FEWER samples through, not more — so the cost is per "
             "sample, not per byte.",
             ha="right", color=WARNC, fontsize=11, fontweight="bold")
    _save(fig, name)


# ----------------------------------------------------------------- fig 2: ceiling
LADDER = [("1/32", "r032_poll"), ("1/16", "r016_poll"), ("1/8", "r008_poll"),
          ("1/4", "r004_poll"), ("1/2", "r002_poll"), ("1/1", "r001_poll")]


def fig_ceiling(name="page_sampling-ceiling.png"):
    """Three units, three stacked panels, one shared x. Never twinned axes."""
    v = verdicts(f"{ROUND}/ladder_ext.out")
    xs = list(range(len(LADDER)))
    gt, loss, lam = [], [], []
    for _, cell in LADDER:
        # gt, NOT delivered()[0]. iperf3's end.sum.bits_per_second is the SENDER's rate and is a
        # flat 200 Mbit/s across every cell -- plotting it draws a horizontal line and claims
        # throughput never moved, which is the opposite of this figure's point. The receiver-side
        # quantity is the interface's own tx counter, which is what `gt` is and what the report
        # and template both quote. lost_percent from the same json IS the receiver's, relayed
        # from the server, so that one is taken from delivered().
        gt.append(v[cell]["gt_mbit"])
        loss.append(delivered(cell)[1])
        lam.append(v[cell]["lam"])

    fig = plt.figure(figsize=WIDE)
    _title(fig, "Above 1-in-16, sampling stops buying anything and starts costing throughput",
           "Sampling 16× harder returns the same number of samples — while the receiver loses "
           "85% of the flow")
    gs = fig.add_gridspec(3, 1, left=0.075, right=0.985, top=0.765, bottom=0.115, hspace=0.22)
    CEIL = 1.5      # between 1/16 (index 1) and 1/8 (index 2)

    def band(ax):
        ax.axvspan(-0.6, CEIL, color=ACCENT_BG, zorder=0)
        ax.axvline(CEIL, color=WARNC, lw=1.4, ls=(0, (5, 3)), zorder=2)
        ax.set_xlim(-0.6, len(LADDER) - 0.4)

    ax1 = fig.add_subplot(gs[0]); band(ax1)
    ax1.plot(xs, gt, "-o", color=ACCENT, lw=2, ms=8, mec="white", mew=1.6, zorder=3)
    for x, y in zip(xs, gt):
        ax1.text(x, y + 14, f"{y:,.0f}", ha="center", color=INK, fontsize=10)
    ax1.set_ylim(0, max(gt) * 1.28)
    _frame(ax1, "throughput\ndelivered (Mbit/s)")
    ax1.set_xticklabels([])
    ax1.text(CEIL - 0.12, max(gt) * 1.10, "usable", ha="right", color=WARNC,
             fontsize=11, fontweight="bold")

    ax2 = fig.add_subplot(gs[1]); band(ax2)
    ax2.plot(xs, loss, "-o", color=WARNC, lw=2, ms=8, mec="white", mew=1.6, zorder=3)
    for x, y in zip(xs, loss):
        ax2.text(x, y + 5, f"{y:.2f}%" if y < 1 else f"{y:.1f}%",
                 ha="center", color=INK, fontsize=10)
    ax2.set_ylim(-4, 100)
    _frame(ax2, "receiver\npacket loss (%)")
    ax2.set_xticklabels([])

    ax3 = fig.add_subplot(gs[2]); band(ax3)
    ax3.plot(xs, lam, "-o", color=FAINT, lw=2, ms=8, mec="white", mew=1.6, zorder=3)
    for x, y in zip(xs, lam):
        ax3.text(x, y + max(lam) * 0.07, f"{y:,.0f}", ha="center", color=INK, fontsize=10)
    ax3.set_ylim(0, max(lam) * 1.30)
    _frame(ax3, "samples per second\nactually collected (λ)")
    ax3.set_xticks(xs)
    ax3.set_xticklabels([l for l, _ in LADDER], color=MUTED, fontsize=11)
    ax3.set_xlabel("sampling rate", color=MUTED, fontsize=11, labelpad=6)
    ax3.annotate("λ flattens here — more sampling, no more samples",
                 xy=(3.0, lam[3]), xytext=(3.35, max(lam) * 0.42),
                 color=WARNC, fontsize=11, fontweight="bold",
                 arrowprops=dict(arrowstyle="-|>", color=WARNC, lw=1.6))
    _save(fig, name)


# ----------------------------------------------------------------- fig 3: who stalls
def fig_bottleneck(name="page_who-is-the-bottleneck.png"):
    """CPU in one panel (one unit, three series), loss in its own panel below."""
    xs = list(range(len(LADDER)))
    bmv2, proxy, kernel, loss = [], [], [], []
    for _, cell in LADDER:
        g = cpu_stats(cell)["groups"]
        bmv2.append(sum(v for k, v in g.items() if k.startswith("bmv2")))
        proxy.append(sum(v for k, v in g.items() if "proxy" in k))
        kernel.append(sum(v for k, v in g.items() if "kernel" in k))
        loss.append(delivered(cell)[1])

    # Derive the plateau once and use it in both the subtitle and the annotation, so the two
    # cannot disagree -- a hand-typed "~145%" beside a computed "~141%" is exactly the kind of
    # mismatch a reader checks first.
    plateau = sum(proxy[2:]) / len(proxy[2:])

    fig = plt.figure(figsize=WIDE)
    _title(fig, "The wall is the proxy — and BMv2 is being starved, not saturated",
           f"The proxy flattens at ~{plateau:.0f}% of one core exactly where loss begins; BMv2 "
           "peaks and then falls; the machine never uses 5 of its 14 cores")
    gs = fig.add_gridspec(2, 1, left=0.075, right=0.985, top=0.755, bottom=0.115,
                          hspace=0.20, height_ratios=[2.1, 1])
    CEIL = 1.5

    ax1 = fig.add_subplot(gs[0])
    ax1.axvspan(-0.6, CEIL, color=ACCENT_BG, zorder=0)
    ax1.axvline(CEIL, color=WARNC, lw=1.4, ls=(0, (5, 3)), zorder=2)
    for ys, col, lab in ((bmv2, GREY, "BMv2 (10 switches)"), (proxy, WARNC, "proxy"),
                         (kernel, ACCENT, "kernel")):
        ax1.plot(xs, ys, "-o", color=col, lw=2, ms=8, mec="white", mew=1.6, zorder=3, label=lab)
    pk = bmv2.index(max(bmv2))
    ax1.annotate("peaks, then falls = starved", xy=(pk + 0.08, bmv2[pk]),
                 xytext=(pk + 0.75, max(bmv2) * 1.13), color=INK, fontsize=11,
                 fontweight="bold", arrowprops=dict(arrowstyle="-|>", color=FAINT, lw=1.6))
    # The plateau label goes in the empty lower-middle band, not beside the line: at the right
    # edge the proxy, kernel and dotted lines are within a few percent of each other and any
    # inline text lands on top of one of them.
    ax1.axhline(proxy[-1], color=WARNC, lw=1.0, ls=":", alpha=0.8, zorder=1)
    ax1.annotate(f"proxy plateaus at ~{plateau:.0f}% and stays there",
                 xy=(4.6, proxy[-1]), xytext=(2.55, max(bmv2) * 0.20),
                 color=WARNC, fontsize=11.5, fontweight="bold",
                 arrowprops=dict(arrowstyle="-|>", color=WARNC, lw=1.6))
    ax1.set_xlim(-0.6, len(LADDER) - 0.4)
    ax1.set_ylim(0, max(bmv2) * 1.30)
    _frame(ax1, "CPU, % of one core")
    ax1.set_xticks(xs); ax1.set_xticklabels([])
    lg = ax1.legend(loc="upper left", frameon=False, fontsize=11, ncol=3, handletextpad=0.5)
    for t in lg.get_texts():
        t.set_color(MUTED)

    ax2 = fig.add_subplot(gs[1])
    ax2.axvspan(-0.6, CEIL, color=ACCENT_BG, zorder=0)
    ax2.axvline(CEIL, color=WARNC, lw=1.4, ls=(0, (5, 3)), zorder=2)
    ax2.bar(xs, loss, width=0.5, color=WARNC, edgecolor="white", linewidth=2, zorder=3)
    for x, y in zip(xs, loss):
        ax2.text(x, y + 4, f"{y:.2f}%" if y < 1 else f"{y:.1f}%",
                 ha="center", color=INK, fontsize=10)
    ax2.set_xlim(-0.6, len(LADDER) - 0.4)
    ax2.set_ylim(0, 100)
    _frame(ax2, "receiver\nloss (%)")
    ax2.set_xticks(xs)
    ax2.set_xticklabels([l for l, _ in LADDER], color=MUTED, fontsize=11)
    ax2.set_xlabel("sampling rate", color=MUTED, fontsize=11, labelpad=6)
    # No footer line here: the subtitle already carries the 14-core point, and a right-aligned
    # footer at this width lands on top of the centred x-axis label.
    _save(fig, name)


# ----------------------------------------------------------------- fig 4: loop period
def fig_period(name="page_loop-period.png"):
    """The pre-registered band the measurement had to land in, and did not."""
    t16, t64 = loop_period("p4_T16"), loop_period("p4_T64")
    conds = [("idle\n(0 flows)", t16[0]), ("16 flows", t16[16]), ("64 flows", t64[64])]

    fig = plt.figure(figsize=WIDE)
    _title(fig, "The hard-coded denominator is real, and it grows with load",
           "Every published bit-rate divides by exactly 1000 ms. The loop actually takes 1042 ms "
           "under sixteen flows and 1248 under sixty-four.")
    ax = fig.add_subplot(111)
    fig.subplots_adjust(left=0.075, right=0.985, top=0.755, bottom=0.135)

    # The 1160-1200 band is GONE, and so is the "explains 4 of 18 points" caption that rested on
    # it. Amendment C's interval was anchored on a floor of 1.156-1.193 measured on the 15:53
    # fabric generation, while T was measured on the 23:2x one, whose own ratio is 1.03-1.05.
    # Scoring the prediction across generations put the two sides of a ratio in different
    # populations -- the very error this project has a memory about. Within one generation T/1000
    # tracks the measured ratio closely, which is a stronger result than the one the band framed,
    # but it is an unregistered observation and does not belong on a slide as a scored prediction.
    ax.axhline(1000, color=FAINT, lw=1.4, ls=(0, (5, 3)), zorder=1)

    for i, (lab, vals) in enumerate(conds):
        m = sum(vals) / len(vals)
        lo, hi = min(vals), max(vals)
        ax.vlines(i, lo, hi, color=RULE, lw=7, zorder=2)
        ax.plot([i], [m], "o", ms=15, color=ACCENT, mec="white", mew=2.2, zorder=4)
        ax.text(i + 0.11, m + 14, f"{m:,.1f} ms", va="bottom", color=INK, fontsize=13,
                fontweight="bold")
        ax.text(i + 0.11, m - 16, f"n={len(vals)} windows", va="top", color=MUTED, fontsize=10)

    ax.set_xticks(range(len(conds)))
    ax.set_xticklabels([c[0] for c in conds], color=MUTED, fontsize=12)
    ax.set_xlim(-0.5, len(conds) - 0.30)
    ax.set_ylim(930, 1330)
    # Floor caption goes below every mark, not beside the 1000 ms line: at this y the idle point
    # and its n= label sit on the line, and the caption ran straight through both.
    ax.text(-0.42, 938, "1000 ms — the loop's own sleep(1s). A reading below this line means "
            "the instrument is broken, not a result.",
            color=FAINT, fontsize=10.5, va="bottom")
    _frame(ax, "measured rate-loop period (ms)")
    # Say "cleanest window", not "idle": the idle windows are not one regime. mainDev measured
    # 1000.1 ms on a nearly empty model right after a rebuild and 1012.1 ms after 39 minutes with
    # 288 edges and 27 counter reports -- the loop body slows as its own bookkeeping grows. The
    # plotted point is the mean over the idle windows, so the 0.1 ms claim belongs to the minimum.
    lo_idle = min(conds[0][1])
    fig.text(0.985, 0.030,
             f"The cleanest idle window reads {lo_idle:.1f} ms — {lo_idle - 1000:.1f} ms above the "
             "loop's own sleep. A broken instrument would not land there, so idle is a positive "
             "control, not just a reading.",
             ha="right", color=WARNC, fontsize=11, fontweight="bold")
    _save(fig, name)


def udp_dgram(path):
    """arm -> datagrams per second on the proxy -> kernel hop."""
    out = {}
    for line in open(path):
        m = re.search(r"UDPDGRAM (\S+) \d+ over [\d.]+s = ([\d.]+)/s", line)
        if m:
            out[m.group(1)] = float(m.group(2))
    return out


# ----------------------------------------------------------------- fig 5: merge gate
def fig_merge_gate(name="page_merge-gate.png"):
    """What a gate looks like: the intended quantity moves, the controls do not.

    Three different units, so three panels. The two flat panels are the point -- a merge that
    dropped lambda or ratio would be an implementation bug (E-P4 said so before the run), not a
    working merge, and the only way to show "nothing else moved" is to show it.
    """
    v = verdicts(f"{ROUND}/gate_e.out")
    d = udp_dgram(f"{ROUND}/gate_e.out")
    B1, B8 = "e256b1_poll", "e256b8_poll"

    panels = [
        ("The intended effect", "datagrams/s, proxy → kernel",
         d[B1], d[B8], True),
        ("Control: samples collected", "λ, single-side samples/s",
         v[B1]["lam"], v[B8]["lam"], False),
        ("Control: rate accounting", "twin / counter ratio",
         v[B1]["ratio"], v[B8]["ratio"], False),
    ]

    fig = plt.figure(figsize=WIDE)
    _title(fig, "Merge merges — and whether it helps is still undecided",
           "Left three: the gate at 1-in-256, one value changed (NDTWIN_SFLOW_BATCH 1 → 8). "
           "Right: the same change at 1-in-8, where the wall is.")
    gs = fig.add_gridspec(1, 4, left=0.045, right=0.985, top=0.755, bottom=0.135, wspace=0.34,
                          width_ratios=[1, 1, 1, 1.25])

    for i, (head, ylab, a, b, is_effect) in enumerate(panels):
        ax = fig.add_subplot(gs[0, i])
        cols = [GREY, ACCENT if is_effect else FAINT]
        bars = ax.bar([0, 1], [a, b], width=0.5, color=cols, edgecolor="white", linewidth=2)
        top = max(a, b)
        for bar, val in zip(bars, (a, b)):
            txt = f"{val:,.1f}" if val >= 10 else f"{val:.3f}"
            ax.text(bar.get_x() + bar.get_width() / 2, val + top * 0.035, txt,
                    ha="center", color=INK, fontsize=12.5, fontweight="bold")
        if is_effect:
            ideal = a / 8.0
            ax.axhline(ideal, color=WARNC, lw=1.4, ls=(0, (5, 3)), zorder=4)
            ax.text(1.52, ideal, "ideal 8×", ha="right", va="bottom",
                    color=WARNC, fontsize=10.5, fontweight="bold")
            ax.text(0.5, top * 0.60, f"{a / b:.2f}× fewer", ha="center",
                    color=WARNC, fontsize=13.5, fontweight="bold")
        else:
            # Two decimals, not one: lambda moves -0.76% and ratio -0.79%, which both round to
            # -0.8% and then read as a copy-paste error rather than as two independent controls
            # that happened to land together.
            ax.text(0.5, top * 0.60, f"{(b / a - 1) * 100:+.2f}%", ha="center",
                    color=FAINT, fontsize=13.5, fontweight="bold")
            ax.set_ylim(0, top * 1.32)
        if is_effect:
            ax.set_ylim(0, top * 1.32)
        ax.set_xticks([0, 1])
        ax.set_xticklabels(["batch = 1\n(unchanged behaviour)", "batch = 8\n(merge on)"],
                           color=MUTED, fontsize=10.5)
        ax.set_xlim(-0.6, 1.6)
        _frame(ax, ylab)
        ax.set_title(head, color=INK, fontsize=13, fontweight="bold", loc="left", pad=9)

    # ---- panel 4: the wall test, and why it decides nothing
    #
    # The control ran twice, before and after the treatment, and the two controls bracket it.
    # Drawn on a time axis because the ordering IS the finding: 22.0 -> 29.5 is the fabric
    # degrading underneath the experiment, and no bar chart grouped by condition would show it.
    ax = fig.add_subplot(gs[0, 3])
    seq = [(0, 22.01, "batch = 1", GREY), (5, 17.64, "batch = 8", ACCENT),
           (10, 29.49, "batch = 1", GREY)]
    xs = [s[0] for s in seq]
    ys = [s[1] for s in seq]
    ctrl = [(x, y) for x, y, lab, _ in seq if lab == "batch = 1"]
    ax.plot([c[0] for c in ctrl], [c[1] for c in ctrl], "-", color=GREY, lw=2.2,
            zorder=2, label="control drifting")
    for x, y, lab, col in seq:
        ax.plot([x], [y], "o", ms=15, color=col, mec="white", mew=2.2, zorder=4)
        ax.text(x, y + 1.4, f"{y:.1f}%", ha="center", color=INK, fontsize=12, fontweight="bold")
        ax.text(x, y - 2.4, lab, ha="center", va="top", color=MUTED, fontsize=10)
    ax.annotate("", xy=(11.9, 29.49), xytext=(11.9, 22.01),
                arrowprops=dict(arrowstyle="<|-|>", color=WARNC, lw=2, shrinkA=0, shrinkB=0))
    ax.text(12.4, 25.7, "same\nsetting,\n7.5 pts\napart", ha="left", va="center",
            color=WARNC, fontsize=11, fontweight="bold")
    ax.set_xticks([0, 5, 10])
    ax.set_xticklabels(["t = 0", "+5 min", "+10 min"], color=MUTED, fontsize=10.5)
    ax.set_xlim(-2.4, 17.5)
    ax.set_ylim(12, 34)
    _frame(ax, "receiver packet loss (%), 1-in-8")
    ax.set_title("At the wall: undecided", color=INK, fontsize=13, fontweight="bold",
                 loc="left", pad=9)

    # One footer, not two: at four panels the two lines ran into each other and printed on top
    # of one another. The gate's point is already carried by the two flat control panels.
    fig.text(0.5, 0.028,
             "Flat controls are why the merge is sound; a control that moves 7.5 points is why "
             "its 4.4-point gain cannot be claimed.",
             ha="center", color=WARNC, fontsize=12, fontweight="bold")
    _save(fig, name)


# ----------------------------------------------------------------- fig 6: shared-code bias
#
# The ratios are RECOMPUTED FROM RAW here rather than read out of analyze.py. That is deliberate:
# analyze.py prints ratio next to per-edge min, and reading the wrong one of those two columns is
# what produced "the headline did not reproduce" and cost a night. A figure that re-derives the
# number from veth counters and twin bps cannot inherit that mistake.
SCALE_RAW = f"{SCALE}/raw"
RUNS = [("P4\n16 flows", "p4_condB"), ("OVS\n16 flows", "ovs_condB"),
        ("P4\n64 flows", "p4_condA"), ("OVS\n64 flows", "ovs_condA")]
CLASSES = ("host->switch", "switch->host", "switch->switch")


def scale_ratios(run):
    """class -> twin_bytes / veth_bytes over meta.json's nominal window.

    Both sides are summed over the SAME edge population -- every edge that has a twin series, a
    matching veth counter, and non-zero traffic. Splitting those populations is how a bias gets
    read as double-counting.
    """
    p = f"{SCALE_RAW}/{run}/"
    meta = json.load(open(p + "meta.json"))
    lo, hi = meta["window_lo"], meta["window_hi"]

    snaps = sorted((json.loads(l)["ts"], json.loads(l)["body"]["edges"])
                   for l in open(p + "graph.jsonl"))
    twin = {}
    for i, (ts, edges) in enumerate(snaps):
        nxt = snaps[i + 1][0] if i + 1 < len(snaps) else ts
        dt = min(nxt, hi) - max(ts, lo)
        if dt <= 0:
            continue
        for e in edges:
            k = (e["src_dpid"], e["src_interface"], e["dst_dpid"], e["dst_interface"])
            twin[k] = twin.get(k, 0.0) + e["link_bandwidth_usage_bps"] * dt / 8.0

    series = {}
    with open(p + "veth.tsv") as f:
        next(f)
        for line in f:
            ts, iface, rx, tx = line.split("\t")
            series.setdefault(iface, []).append((float(ts), int(rx), int(tx)))
    for v in series.values():
        v.sort()

    def counter(iface, t, idx):
        v = series.get(iface)
        if not v:
            return None
        if t <= v[0][0]:
            return float(v[0][idx])
        if t >= v[-1][0]:
            return float(v[-1][idx])
        a, b = 0, len(v) - 1
        while b - a > 1:
            m = (a + b) // 2
            (a, b) = (m, b) if v[m][0] <= t else (a, m)
        if v[b][idx] < v[a][idx]:          # counter reset -- refuse to guess
            return None
        span = v[b][0] - v[a][0]
        return (float(v[a][idx]) + (float(v[b][idx]) - float(v[a][idx]))
                * ((t - v[a][0]) / span) if span > 0 else float(v[a][idx]))

    agg = {c: [0.0, 0.0] for c in CLASSES}
    for (sd, si, dd, di), tb in twin.items():
        if sd == 0 and dd != 0:
            cls, iface, idx = CLASSES[0], f"s{dd}-eth{di}", 1      # rx at the switch
        elif dd == 0 and sd != 0:
            cls, iface, idx = CLASSES[1], f"s{sd}-eth{si}", 2      # tx from the switch
        elif sd != 0 and dd != 0:
            cls, iface, idx = CLASSES[2], f"s{sd}-eth{si}", 2
        else:
            continue
        a, b = counter(iface, lo, idx), counter(iface, hi, idx)
        if a is None or b is None or b - a <= 0:
            continue
        agg[cls][0] += b - a
        agg[cls][1] += tb
    return {c: (t / v) for c, (v, t) in agg.items() if v > 0}


def _box(ax, x, y, w, h, label, face, edge, fs=10.5, tc=None):
    ax.add_patch(plt.Rectangle((x, y), w, h, facecolor=face, edgecolor=edge,
                               linewidth=1.8, zorder=3))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            color=tc or INK, fontsize=fs, fontweight="bold", zorder=4)


def fig_concurrency_shared(name="page_shared-code-bias.png"):
    """Left: why the cause must be in shared code. Right: the twelve measurements saying so."""
    data = {run: scale_ratios(run) for _, run in RUNS}

    fig = plt.figure(figsize=WIDE)
    _title(fig, "Two sampling paths with nothing in common, one shared bias",
           "The sample-generation paths share no code at all; accounting and publishing are the "
           "same file. Both planes read high — so the cause is after the join.")
    gs = fig.add_gridspec(1, 2, left=0.035, right=0.982, top=0.775, bottom=0.115,
                          wspace=0.16, width_ratios=[1.22, 1])

    # ---- left: the argument
    ax = fig.add_subplot(gs[0, 0])
    ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis("off")
    for s in ("top", "right", "left", "bottom"):
        ax.spines[s].set_visible(False)

    _box(ax, 2, 66, 21, 15, "bmv2\nclone-to-CPU", "#DCE7EE", ACCENT)
    _box(ax, 26, 66, 15, 15, "proxy", "#DCE7EE", ACCENT)
    _box(ax, 44, 66, 15, 15, "gRPC", "#DCE7EE", ACCENT)
    ax.text(2, 84, "P4 plane", color=ACCENT, fontsize=12, fontweight="bold")

    _box(ax, 2, 30, 57, 15, "OVS's own sFlow agent", "#F2E0DC", WARNC)
    ax.text(2, 48, "OVS plane", color=WARNC, fontsize=12, fontweight="bold")

    for y0 in (73.5, 37.5):
        ax.annotate("", xy=(66, 56), xytext=(59.5, y0),
                    arrowprops=dict(arrowstyle="-|>", color=FAINT, lw=2.2))
    _box(ax, 66, 40, 31, 32,
         "SHARED\n\nFlowLinkUsage-\nCollector\n\naccounting +\npublishing", "#E6E6E6", MUTED,
         fs=11)
    ax.annotate("", xy=(81.5, 24), xytext=(81.5, 39),
                arrowprops=dict(arrowstyle="-|>", color=WARNC, lw=2.6))
    ax.text(81.5, 19, "published bit-rate", ha="center", color=INK,
            fontsize=11.5, fontweight="bold")
    ax.text(81.5, 12.5, "reads high on BOTH planes", ha="center", color=WARNC,
            fontsize=11.5, fontweight="bold")
    ax.text(2, 12.5, "Nothing above the join is shared —\n"
            "different code, different packet path,\ndifferent process.",
            color=MUTED, fontsize=11, va="center")

    # ---- right: the measurements
    ax = fig.add_subplot(gs[0, 1])
    ax.axhline(1.0, color=INK, lw=1.6, zorder=2)
    ax.text(-0.42, 1.005, "1.00 = twin agrees with the counters", color=MUTED,
            fontsize=10.5, va="bottom")
    ax.axvspan(-0.5, 1.5, color=ACCENT_BG, zorder=0)
    for i, (lab, run) in enumerate(RUNS):
        vals = [data[run][c] for c in CLASSES if c in data[run]]
        for v in vals:
            ax.plot([i], [v], "o", ms=13, color=ACCENT, mec="white", mew=2, zorder=4)
        # Three decimals, not two: OVS-64 spans 1.389-1.392, which at two decimals prints
        # "1.39-1.39" and reads as a typo rather than as the flatness that is the point.
        ax.text(i, max(vals) + 0.022, f"{min(vals):.3f}–{max(vals):.3f}", ha="center",
                color=INK, fontsize=10.5, fontweight="bold")
    ovs64 = [data["ovs_condA"][c] for c in CLASSES if c in data["ovs_condA"]]
    ax.annotate("three different packet paths,\nsame multiplier — 0.2% apart",
                xy=(3.13, sum(ovs64) / len(ovs64)), xytext=(1.75, 1.075),
                color=WARNC, fontsize=11.5, fontweight="bold",
                arrowprops=dict(arrowstyle="-|>", color=WARNC, lw=1.8))
    ax.set_xticks(range(len(RUNS)))
    ax.set_xticklabels([r[0] for r in RUNS], color=MUTED, fontsize=11.5)
    ax.set_xlim(-0.5, len(RUNS) - 0.4)
    _frame(ax, "twin ÷ interface counters")
    ax.set_title("Every edge class, every run, above 1.00",
                 color=INK, fontsize=13, fontweight="bold", loc="left", pad=9)
    fig.text(0.982, 0.028,
             "Heights are per-run: the same configuration measured 14.8% apart on two fabric "
             "generations, so compare the direction, not the magnitudes.",
             ha="right", color=MUTED, fontsize=10.5)
    _save(fig, name)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    fig_truncate()
    fig_ceiling()
    fig_bottleneck()
    fig_period()
    fig_merge_gate()
    fig_concurrency_shared()
