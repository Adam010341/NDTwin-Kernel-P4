"""Render the two after-fix comparison figures for the 8/27 deck.

[Co-developed with claude code -- Adam]

  page_ovs-before-after.png    OVS 128-host outage, before (n=10) vs after the fix (n=3),
                               with the term that moved annotated.
  page_ovs-vs-bmv2-after.png   OVS vs BMv2 at 4 and 128 hosts, after the fix, with the
                               before ghosted -- answers "does the scaling penalty survive?"

Discipline (check-against-prior-experiments): every "before" cell and every P4 cell is
imported from the 2026-08-19 round's `failover_cells()`, and the after-outages are parsed by
that round's own `outage_from_pings()` -- same instrument both sides of the comparison,
nothing retyped.

Usage:  python plot_after_fix.py <output-dir>
"""
import os
import statistics as st
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(REPO, "doc/audit/2026-08-19_p4-sflow-accuracy"))
from plot_figures import failover_cells, outage_from_pings   # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else HERE

INK, BODY, MUTED = "#1A1A1A", "#2E2E2E", "#4F4F4F"
RULE, ACCENT, WARNC = "#D0D0D0", "#065A82", "#9C3B2E"
# The OVS entity keeps its hue across states: full red = after (the number that matters
# now), pale red = before. Lightness carries the difference, so CVD readers keep it too.
OVS_BEFORE, OVS_AFTER, P4C = "#DCB4AC", "#9C3B2E", "#065A82"

plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white",
    "axes.edgecolor": RULE, "axes.labelcolor": BODY, "text.color": INK,
    "xtick.color": MUTED, "ytick.color": MUTED, "font.size": 10,
    "axes.spines.top": False, "axes.spines.right": False,
})


def after_cells():
    """{4: [outages], 128: [outages]} from this round's raw ping logs."""
    out = {4: [], 128: []}
    raw = os.path.join(HERE, "raw")
    for name in sorted(os.listdir(raw) if os.path.isdir(raw) else []):
        for size in out:
            if name.startswith(f"after_ovs{size}_"):
                v = outage_from_pings(os.path.join(raw, name))
                if v is not None:
                    out[size].append(v)
    if not out[128]:
        raise SystemExit("no 128-host after-fix ping logs in raw/ -- run after_fix_outage.sh")
    return out


def dotrow(ax, y, values, colour, label):
    ax.barh([y], [st.mean(values)], height=0.5, color=colour, zorder=2)
    ax.scatter(values, [y] * len(values), s=22, color=INK, alpha=0.55, zorder=3)
    ax.text(st.mean(values) + 0.7, y, f"{st.mean(values):.1f} s",
            va="center", fontsize=12, weight="bold", color=colour if colour != OVS_BEFORE else MUTED)
    ax.text(-1.2, y, label, va="center", ha="right", fontsize=10, color=BODY)


def fig_before_after(fname):
    before = failover_cells()["OVS / 128 hosts"]
    after = after_cells()[128]
    p4 = failover_cells()["P4 / 128 hosts"]

    fig, ax = plt.subplots(figsize=(9.6, 4.4))
    fig.subplots_adjust(left=0.30, right=0.96, top=0.80, bottom=0.14)

    fig.text(0.02, 0.95, "The same link failure, before and after the fix",
             fontsize=14.5, weight="bold", color=INK)
    fig.text(0.02, 0.885,
             f"128-host OVS, identical protocol both rows (ping-gap outage, "
             f"measure_failover.sh). Dots are individual runs.",
             fontsize=9.5, color=MUTED)

    dotrow(ax, 2, before, OVS_BEFORE, f"before\nLLDP guard 0.05 (Ryu default)\nn={len(before)}")
    dotrow(ax, 1, after, OVS_AFTER, f"after\nguard 0.01 + indexed walk\nn={len(after)}")

    ax.axvline(st.mean(p4), color=P4C, lw=1.2, ls=(0, (4, 3)))
    ax.text(st.mean(p4) + 0.6, 2.45, f"BMv2/P4 at 128 hosts ({st.mean(p4):.1f} s)",
            fontsize=9, color=P4C)

    ratio = st.mean(before) / st.mean(after)
    ax.text(st.mean(after) + 9.5, 1, f"— {ratio:.1f}× shorter; detection 44.9 → 11.5 s is "
            f"the moving term,\n    the six-miss death threshold is untouched",
            va="center", fontsize=9.5, color=MUTED)

    ax.set_ylim(0.5, 2.75)
    ax.set_yticks([])
    ax.set_xlim(0, max(before) * 1.06)
    ax.set_xlabel("outage (s)")
    path = os.path.join(OUT, fname)
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"wrote {path}")


def fig_ovs_vs_p4(fname):
    cells = failover_cells()
    after = after_cells()
    groups = [("4 hosts", cells["OVS / 4 hosts"], after[4], cells["P4 / 4 hosts"]),
              ("128 hosts", cells["OVS / 128 hosts"], after[128], cells["P4 / 128 hosts"])]

    fig, axes = plt.subplots(1, 2, figsize=(9.6, 4.6), sharey=True)
    fig.subplots_adjust(left=0.09, right=0.97, top=0.76, bottom=0.20, wspace=0.08)

    fig.text(0.02, 0.95, "OVS vs BMv2 after the fix: the scaling penalty is what changed",
             fontsize=14, weight="bold", color=INK)

    for ax, (title, ovs_b, ovs_a, p4) in zip(axes, groups):
        xs, labels = [0, 1, 2], ["OVS\nbefore", "OVS\nafter", "BMv2/P4"]
        series = [(ovs_b, OVS_BEFORE), (ovs_a, OVS_AFTER), (p4, P4C)]
        for x, (vals, colour) in zip(xs, series):
            if not vals:
                ax.text(x, 1, "not\nmeasured", ha="center", fontsize=8.5, color=MUTED)
                continue
            ax.bar([x], [st.mean(vals)], width=0.56, color=colour, zorder=2)
            ax.scatter([x + 0.36] * len(vals), vals, s=16, color=INK, alpha=0.5, zorder=3)
            ax.text(x, st.mean(vals) + 1.0, f"{st.mean(vals):.1f}",
                    ha="center", fontsize=11, weight="bold",
                    color=colour if colour != OVS_BEFORE else MUTED)
        ax.set_xticks(xs)
        ax.set_xticklabels(labels, fontsize=9)
        ax.set_title(title, fontsize=11, weight="bold", loc="left")
        ax.set_ylim(0, max(cells["OVS / 128 hosts"]) * 1.12)
    axes[0].set_ylabel("outage (s)")

    b4, b128 = st.mean(cells["OVS / 4 hosts"]), st.mean(cells["OVS / 128 hosts"])
    a4 = st.mean(after[4]) if after[4] else float("nan")
    a128 = st.mean(after[128])
    p1, p2 = st.mean(cells["P4 / 4 hosts"]), st.mean(cells["P4 / 128 hosts"])
    fig.text(0.02, 0.885,
             f"Growing 4 → 128 hosts: OVS before {b128/b4:.2f}×, "
             f"OVS after {'%.2f×' % (a128/a4) if a4 == a4 else '(4-host cell pending)'}, "
             f"BMv2/P4 {p2/p1:.2f}×. Bars are means; dots are runs; n varies and is the "
             f"point of the dots.",
             fontsize=9.5, color=MUTED)

    path = os.path.join(OUT, fname)
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"wrote {path}")


if __name__ == "__main__":
    fig_before_after("page_ovs-before-after.png")
    fig_ovs_vs_p4("page_ovs-vs-bmv2-after.png")
