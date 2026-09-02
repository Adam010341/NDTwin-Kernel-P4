#!/usr/bin/env python3
"""The paired A/B figure: two kernels one constant apart, at zero sampling and at 1/1024.

[Co-developed with claude code -- Adam]

Usage:  plot_ab.py

Project rule: keep the words off the figure. Only what is needed to read it -- title, axes,
value labels, legend. The mechanism, the caveats, the provenance and the reconciliation with
the 09-01 round all live in REPORT.md next to this file, not on the image.

Cell selection and the traffic guard are imported from analyse_ab rather than repeated, so the
figure cannot end up drawing a different set of cells than the table describes.
"""
import importlib.util
import os
import statistics as st

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("aa", os.path.join(HERE, "analyse_ab.py"))
aa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aa)

CONDS = ["zero", "s1024"]
XLAB = {"zero": "none", "s1024": "1/1024"}
ARMS = ["1hz", "1khz"]
ARMLAB = {"1hz": "1 Hz", "1khz": "1 kHz"}
COL = {"1hz": "#2b7bba", "1khz": "#c8442b"}

d = aa.cells()

# Same guard as the table: a pair whose two arms did not do the same work is not drawn.
good = set()
for c in CONDS:
    for r in aa.REPS:
        ka, kb = (c, "1hz", r), (c, "1khz", r)
        if ka in d and kb in d and d[ka]["tx"]:
            if abs(d[kb]["tx"] / d[ka]["tx"] - 1.0) <= 0.05:
                good.add((c, r))

vals = {}
for c in CONDS:
    for a in ARMS:
        v = [d[(c, a, r)]["kernel"] for r in aa.REPS if (c, r) in good and (c, a, r) in d]
        if v:
            vals[(c, a)] = (st.mean(v), st.pstdev(v) if len(v) > 1 else 0.0, v)

diffs = {}
for c in CONDS:
    ds = [d[(c, "1khz", r)]["kernel"] - d[(c, "1hz", r)]["kernel"]
          for r in aa.REPS if (c, r) in good]
    if ds:
        diffs[c] = st.mean(ds)

fig, (axL, axR) = plt.subplots(1, 2, figsize=(11, 4.6),
                               gridspec_kw={"width_ratios": [1.55, 1]})

# ---- left: the 2x2 itself ------------------------------------------------------------------
W = 0.34
xs = range(len(CONDS))
for i, a in enumerate(ARMS):
    off = (i - 0.5) * W
    ys = [vals.get((c, a), (0, 0, []))[0] for c in CONDS]
    es = [vals.get((c, a), (0, 0, []))[1] for c in CONDS]
    bars = axL.bar([x + off for x in xs], ys, W, yerr=es, capsize=4,
                   color=COL[a], label=ARMLAB[a], zorder=3)
    for b, v in zip(bars, ys):
        axL.annotate(f"{v:.1f}", (b.get_x() + b.get_width() / 2, v),
                     textcoords="offset points", xytext=(0, 7),
                     ha="center", fontsize=10, fontweight="bold", color=COL[a])
axL.set_title("Kernel CPU: one constant apart")
axL.set_xlabel("sampling rate")
axL.set_ylabel("kernel CPU, % of ONE core")
axL.set_xticks(list(xs))
axL.set_xticklabels([XLAB[c] for c in CONDS])
axL.legend(frameon=False, loc="upper left")
axL.grid(axis="y", alpha=0.25, zorder=0)
top = max((v[0] + v[1]) for v in vals.values()) if vals else 1.0
axL.set_ylim(0, top * 1.22)

# ---- right: the paired difference ----------------------------------------------------------
ys = [diffs.get(c, 0.0) for c in CONDS]
bars = axR.bar(list(xs), ys, 0.5, color="#4a4a4a", zorder=3)
for b, v in zip(bars, ys):
    axR.annotate(f"{v:+.1f}", (b.get_x() + b.get_width() / 2, v),
                 textcoords="offset points", xytext=(0, 7 if v >= 0 else -16),
                 ha="center", fontsize=11, fontweight="bold")
axR.axhline(0, color="#888", lw=1)
axR.set_title("1 kHz minus 1 Hz")
axR.set_xlabel("sampling rate")
axR.set_ylabel("difference, points of ONE core")
axR.set_xticks(list(xs))
axR.set_xticklabels([XLAB[c] for c in CONDS])
axR.grid(axis="y", alpha=0.25, zorder=0)
hi = max(ys) if ys else 1.0
lo = min(ys + [0.0])
axR.set_ylim(min(lo * 1.35, -1), hi * 1.25 if hi > 0 else 1)

fig.tight_layout()
for ext in ("png", "pdf"):
    fig.savefig(os.path.join(HERE, f"page_paired-ab.{ext}"), dpi=170)
print("wrote page_paired-ab.png / .pdf")
for c in CONDS:
    for a in ARMS:
        if (c, a) in vals:
            m, s, v = vals[(c, a)]
            print(f"  {c:>6} {a:>5}: {m:6.2f}% sd {s:4.2f} n={len(v)}")
    if c in diffs:
        print(f"  {c:>6} delta: {diffs[c]:+.2f}")
