"""Render the failover-budget figure: what the 51.75 s is actually made of.

[Co-developed with claude code -- Adam]

Companion to page36_failover-decomposition.png. That figure answers "what makes the outage
longer" (topology size 3.30x on OVS, data plane 3.12x at 128 hosts). This one answers the
question underneath it -- "what is the outage made OF" -- and retires the number the previous
round carried for its largest term.

Every value is read from committed data, not transcribed:

  * the 51.75 s total comes from the same `failover_cells()` the previous figure uses, so the
    two cannot drift. Importing it rather than re-deriving it is the point.
  * the walk terms are parsed out of walk_sweep.txt, the raw output of walk_sweep.sh.
  * the debounce is read out of intelligent_router.py, because it is a constant in live code
    and a figure that hard-codes it would keep asserting 3 s after somebody changes it.
  * the topology-query bound is the slowest endpoint median in ryu_topo_128host.json.

Usage:  python plot_budget.py <output-dir>
"""
import json
import os
import re
import statistics as st
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(REPO, "doc/audit/2026-08-19_p4-sflow-accuracy"))
from plot_figures import failover_cells          # noqa: E402  the single source for 51.75 s

OUT = sys.argv[1] if len(sys.argv) > 1 else HERE

INK, BODY, MUTED = "#1A1A1A", "#2E2E2E", "#4F4F4F"
FAINT, RULE, ACCENT = "#6E6E6E", "#D0D0D0", "#065A82"
ACCENT_BG, PANEL, WARNC = "#EEF3F6", "#F7F8F9", "#9C3B2E"
GAP = "#B9BEC3"          # the unattributed remainder: present, measured, unexplained

plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white",
    "axes.edgecolor": RULE, "axes.labelcolor": BODY, "text.color": INK,
    "xtick.color": MUTED, "ytick.color": MUTED, "font.size": 10,
    "axes.spines.top": False, "axes.spines.right": False,
})


# ------------------------------------------------------------------ committed data readers
def walk_terms():
    """{hosts: (walk, install, report)} parsed from the run's own log lines.

    Two sources, because the sweep script only greps the Ryu log for a cell whose `ndt up`
    returned success, and the 128-host cell returned "up, but not verified" -- the kernel
    reported 0 of 10 switches up, while the fabric built, the model matched and the data plane
    forwarded. The walk itself had already completed and logged, so its line is in the archived
    Ryu log rather than in walk_sweep.txt. Read both rather than retyping the number: the
    kernel-side liveness failure does not touch a measurement taken inside Ryu.
    """
    rx = re.compile(r"hosts=(\d+) pairs=(\d+) rules=(\d+) paths=(\d+) "
                    r"walk=([\d.]+)s install=([\d.]+)s report=([\d.]+)s")
    out = {}
    for name in ("walk_sweep.txt", "ryu_128host_walk.log"):
        path = os.path.join(HERE, name)
        if not os.path.exists(path):
            continue
        with open(path, errors="replace") as fh:
            for line in fh:
                m = rx.search(line)
                if m:
                    out[int(m.group(1))] = (float(m.group(5)), float(m.group(6)),
                                            float(m.group(7)))
    if 128 not in out:
        raise SystemExit("no 128-host walk line in walk_sweep.txt or ryu_128host_walk.log")
    return out


def debounce_seconds():
    """`reinstall_quiet_period` as it stands in the live control program."""
    src = os.path.join(REPO, "intelligent_router.py")
    with open(src) as fh:
        m = re.search(r"^reinstall_quiet_period\s*=\s*(\d+)", fh.read(), re.M)
    if not m:
        raise SystemExit("reinstall_quiet_period not found in intelligent_router.py")
    return float(m.group(1))


def detection_cells():
    """{'A'|'B'|'C': [detection seconds]} from the detection probe's raw output.

    A = 4 hosts at Ryu's default guard, B = 128 hosts at the default, C = 128 hosts with
    NDTWIN_RYU_LLDP_GUARD=0.01. Section letters rather than labels because the header text
    carries the settings and would have to be kept in sync twice.
    """
    path = os.path.join(HERE, "lldp_detection.txt")
    rx = re.compile(r"detection=([\d.]+)s")
    out, cur = {}, None
    with open(path) as fh:
        for line in fh:
            m = re.match(r"## ([ABC])\.", line)
            if m:
                cur = m.group(1)
                out[cur] = []
                continue
            d = rx.search(line)
            if d and cur:
                out[cur].append(float(d.group(1)))
    missing = [k for k in "ABC" if not out.get(k)]
    if missing:
        raise SystemExit(f"lldp_detection.txt has no cells for {missing}")
    return out


def topology_query_ms():
    """Slowest of the three topology endpoints at 128 hosts, in ms."""
    path = os.path.join(HERE, "ryu_topo_128host.json")
    with open(path) as fh:
        data = json.load(fh)
    best = 0.0
    for name, cell in data["endpoints"].items():
        if name == "paths":         # excluded: its 4-host control was mislabelled, see REPORT.md
            continue
        best = max(best, cell["ms_median"])
    return best


# ----------------------------------------------------------------------------- the figure
def fig_budget(fname):
    cells = failover_cells()
    total = st.mean(cells["OVS / 128 hosts"])
    p4 = st.mean(cells["P4 / 128 hosts"])
    n = len(cells["OVS / 128 hosts"])

    walk, install, report = walk_terms()[128]
    debounce = debounce_seconds()
    query_s = topology_query_ms() / 1000.0
    det = detection_cells()
    detect = st.mean(det["B"])                 # 128 hosts, Ryu default guard
    detect_fixed = st.mean(det["C"])           # 128 hosts, guard 0.01
    accounted = detect + walk + debounce + query_s
    gap = total - accounted

    fig = plt.figure(figsize=(10.6, 6.6))
    gs = fig.add_gridspec(2, 1, height_ratios=[1.0, 1.25], hspace=1.22,
                          left=0.205, right=0.955, top=0.815, bottom=0.085)
    ax, ax2 = fig.add_subplot(gs[0]), fig.add_subplot(gs[1])

    fig.text(0.019, 0.965,
             f"An OVS link failure at 128 hosts lasts {total:.1f} s, and "
             f"{detect / total * 100:.0f}% of it is waiting to notice",
             fontsize=14.5, weight="bold", color=INK, va="top")
    fig.text(0.019, 0.913,
             f"n={n} live runs for the total, n={len(det['B'])} for each measured term. "
             f"Ryu needs six consecutive unanswered LLDP probes to\ndeclare a link down, and it "
             f"probes every port in turn -- so adding hosts stretches the gap between two probes "
             f"of the same one.",
             fontsize=9.5, color=MUTED, va="top", linespacing=1.5)

    # ---------------------------------------------------------------- panel 1: the ledger
    segs = [
        (detect,   WARNC,     f"detect the failure {detect:.1f} s"),
        (debounce, MUTED,     f"debounce {debounce:.0f} s"),
        (walk,     "#3B8EA5", f"recompute {walk:.2f} s"),
        (query_s,  ACCENT,    f"topology query <{topology_query_ms():.1f} ms"),
        (gap,      GAP,       f"residual {gap:.1f} s"),
    ]
    left = 0.0
    for width, colour, label in segs:
        ax.barh([0], [width], left=left, height=0.46, color=colour,
                edgecolor="white", linewidth=0.8, label=label)
        left += width

    ax.set_xlim(0, total * 1.02)
    ax.set_ylim(-0.5, 0.5)
    ax.set_yticks([])
    ax.set_xlabel("seconds of the 128-host OVS outage")
    ax.spines["left"].set_visible(False)
    ax.text(detect / 2, 0, f"{detect:.1f} s", ha="center", va="center",
            fontsize=13, color="white", weight="bold")
    # No leader line to the three thin segments: it had to be parked under the axis label to
    # fit, and the legend below already prints all five values. One statement of a number.
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.62), frameon=False,
              fontsize=8.4, handlelength=0.95, handleheight=0.95, borderpad=0,
              ncol=5, columnspacing=1.15, handletextpad=0.5)

    # ------------------------------------------------------- panel 2: what one constant does
    rows = [
        (2.10, f"Ryu default\nLLDP_SEND_GUARD = 0.05 s", detect, WARNC),
        (1.05, f"one line changed\nLLDP_SEND_GUARD = 0.01 s", detect_fixed, ACCENT),
    ]
    for y, _label, value, colour in rows:
        ax2.barh([y], [value], height=0.44, color=colour)
        ax2.text(value + 0.9, y, f"{value:.1f} s", va="center", fontsize=11.5,
                 color=colour, weight="bold")
    ax2.text(detect_fixed + 6.0, 1.05,
             f"— {detect / detect_fixed:.1f}x faster; the whole outage becomes ~"
             f"{detect_fixed + debounce + walk:.0f} s",
             va="center", fontsize=9.5, color=MUTED)

    ax2.axvline(p4, color=INK, lw=1.0, ls=(0, (4, 3)))
    ax2.text(p4 + 0.8, 2.62, f"P4 at 128 hosts, whole outage ({p4:.1f} s)",
             ha="left", fontsize=9, color=INK)

    ax2.set_yticks([2.10, 1.05])
    ax2.set_yticklabels([r[1] for r in rows], fontsize=9)
    ax2.set_xlim(0, 52)
    ax2.set_ylim(0.35, 2.85)
    ax2.set_xlabel("seconds to detect a failed inter-switch link, 128 hosts")
    ax2.set_title("The threshold is untouched -- only the interval between probes",
                  loc="left", fontsize=12.5, weight="bold", pad=26)
    ax2.text(0, 1.075,
             "Still six consecutive misses before a link is called dead. Lowering THAT would "
             "trade against false positives; this does not.",
             transform=ax2.transAxes, fontsize=9.5, color=MUTED, va="bottom")

    path = os.path.join(OUT, fname)
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"wrote {path}")
    print(f"  total {total:.2f}s (n={n}) | detect {detect:.2f}s -> {detect_fixed:.2f}s | "
          f"walk {walk:.3f}s | debounce {debounce:.0f}s | query {query_s*1000:.2f}ms | "
          f"residual {gap:.2f}s | P4 {p4:.2f}s")


if __name__ == "__main__":
    fig_budget("page_failover-budget.png")
