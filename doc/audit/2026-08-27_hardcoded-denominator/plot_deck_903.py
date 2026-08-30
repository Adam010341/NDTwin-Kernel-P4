#!/usr/bin/env python3
"""Four figures for the 9/03 deck: ticket Q (the assumed denominator) and ticket M (1 kHz -> 1 Hz).

[Co-developed with claude code -- Adam]

WHY THESE FOUR. The 8/27 deck's eleven figures all predate the evening of 08-27, so neither Q nor
M appears anywhere in it. Both are code changes with a mechanism a reader can follow, which is the
kind of result that loses the most to being presented as a table of numbers.

THE TWO TICKETS ARE AT DIFFERENT STAGES AND THE FIGURES MUST SAY SO. Q has measured arms; M has
none -- its code landed tonight and not one arm has run. So figures 1 and 2 are measurements and
figures 3 and 4 are labelled, on the figure itself, as mechanism and as pre-data arithmetic. A
reader who takes a screenshot of one panel must still be able to tell which kind it is; that is
why the label is inside the axes and not only in the caption.

NO NUMBER IS TYPED BY HAND. Every value is parsed from a committed log or computed from a closed
form. The parses assert their own yield (EXPECT_* below), because a regex that silently matches
nothing would render a confident empty figure -- this project has shipped that failure before.

WHAT FIGURE 2 DELIBERATELY DOES NOT CLAIM. The divisor gate proves the code now divides by the
interval it actually accumulated over. It does not prove the over-report is gone; that needs the
ratio, which is stage 2 and still running. The two are different claims and the figure carries the
distinction rather than leaving it to the speaker.

    <plotvenv>/bin/python3 plot_deck_903.py [outdir]
"""
import os
import re
import subprocess
import sys
import textwrap

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Rectangle  # noqa: E402

REPO = "/home/adam/Desktop/NDTwin-Kernel"
QDIR = f"{REPO}/doc/audit/2026-08-27_hardcoded-denominator"
MDIR = f"{REPO}/doc/audit/2026-08-27_1khz-path-recompute"
PRIOR = f"{REPO}/doc/audit/2026-08-20_sampling-rate-and-cpu"

# Reuse the palette and rcParams rather than restating them, the same way plot_deck_827.py does,
# so these figures cannot drift from the ones already in the deck.
sys.path.insert(0, PRIOR)
from plot_figures import (  # noqa: E402
    ACCENT, ACCENT_BG, FAINT, GREY, INK, MUTED, PANEL, RULE, WARNC,
)

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
DPI = 200
WIDE = (15.2, 6.35)          # 3040x1270 at 200 dpi -- the deck's full-page slot, ar 2.39

WARN_BG = "#FBF2F0"
OKC = "#2F6B4F"              # only where a gate passed; never for a measured value

# What each parse must find. A parse that yields anything else is a changed log, not a new result.
EXPECT_ARMS = 2              # drive_Q.log: Q_B1 and Q_Q1
EXPECT_SURVEY = 3            # survey_T64.log: three 64-flow reps
EXPECT_DIVISOR = 7           # raw/Q_Q1.divisor: seven live checks, matching the gate line


# --------------------------------------------------------------------------------- parsing
def _git(*args):
    """git stdout, stripped; None if the command failed."""
    p = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def _read(path):
    """Read a source file, but refuse unless git can hand the same bytes back.

    Two of these figures print "Source: ..., committed" in their footnote. That was a claim,
    not a check, and it was false for both Q panels: drive_Q.log had never been `git add`ed,
    and raw/*.divisor is excluded by .gitignore:60 (`doc/audit/*/raw*/*`). A `git clean -fd`
    would have deleted the evidence behind the headline number while the slide kept asserting
    it was safe. So the caption is now enforced here instead of written by hand: an untracked
    source cannot be plotted at all.

    [Co-developed with claude code -- Adam]
    2026-08-28: this guard and the pre-commit hook added in f1df56e were mutually exclusive,
    and each was right on its own. The hook refuses doc/audit/*/raw*/* on any branch but
    audit-raw; this guard demanded the cited readouts be tracked on the working branch. The Q
    figures could not be rendered from a clean checkout at all, and the remediation text below
    still told the reader to `git add -f`, a path the hook had just closed. 54551bc got the
    deck out by staging without committing, which is a workaround: the bytes were in nobody's
    history, so the very failure this guard exists to prevent was live while the guard passed.

    Resolved by asking what the guard is FOR rather than what it did. Its purpose is that a
    `git clean -fd` must not be able to destroy the evidence behind a plotted number -- that
    the bytes are recoverable from history by someone else. Tracked-on-this-branch was one way
    to satisfy that; committed-on-audit-raw is another, and it is where the raw now lives by
    rule. So either is accepted.

    The audit-raw arm compares CONTENT, not existence: it hashes the file being plotted and
    requires that hash to equal the blob stored at the same path on audit-raw. Existence alone
    would let a locally edited file be plotted while the footnote pointed at a stale copy that
    says something else -- a citation that resolves to the wrong bytes is worse than one that
    fails to resolve, because it renders and looks right.
    """
    rel = os.path.relpath(path, REPO)

    if _git("ls-files", "--error-unmatch", "--", rel) is not None:
        pass                                            # tracked here: unchanged, the common case
    else:
        local = _git("hash-object", "--", path)
        stored = _git("rev-parse", f"audit-raw:{rel}")
        if stored is None:
            raise AssertionError(
                f"{rel} is not tracked on this branch and is not on audit-raw, so the figure\n"
                f"cannot claim it as a source. Raw belongs on audit-raw:\n"
                f"    git worktree add /tmp/rawwt audit-raw\n"
                f"    mkdir -p /tmp/rawwt/{os.path.dirname(rel)} && cp {rel} /tmp/rawwt/{rel}\n"
                f"    git -C /tmp/rawwt add -A doc && git -C /tmp/rawwt commit\n"
                f"    git worktree remove /tmp/rawwt\n"
                f"(NOT `git add -f` -- the pre-commit hook from f1df56e refuses raw on this "
                f"branch, and that is deliberate.)")
        if local != stored:
            raise AssertionError(
                f"{rel} differs from the copy committed on audit-raw.\n"
                f"  plotting: {local}\n"
                f"  audit-raw: {stored}\n"
                f"The figure would cite bytes that nobody can retrieve. Commit the current file "
                f"to audit-raw, or plot the stored one -- do not caption the difference away.")

    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def q_arms():
    """[(arm, sha8, period_s, overreport_pct)] from the committed driver log, in run order."""
    txt = _read(f"{QDIR}/drive_Q.log")
    heads = re.findall(r"^#+\s+(Q_\w+)\s+binary=(\w+)", txt, re.M)
    pers = re.findall(r"period:\s+([\d.]+)\s+s over\s+(\d+)\s+gaps.*?over-report by \+([\d.]+)%", txt)
    assert len(heads) == EXPECT_ARMS, f"drive_Q.log: {len(heads)} arm headers, want {EXPECT_ARMS}"
    assert len(pers) == EXPECT_ARMS, f"drive_Q.log: {len(pers)} period lines, want {EXPECT_ARMS}"
    return [(h[0], h[1], float(p[0]), float(p[2])) for h, p in zip(heads, pers)]


def q_survey():
    """[(period_s, overreport_pct)] for the three 64-flow survey reps."""
    txt = _read(f"{QDIR}/survey_T64.log")
    rows = re.findall(r"period:\s+([\d.]+)\s+s over\s+(\d+)\s+gaps.*?over-report by \+([\d.]+)%", txt)
    assert len(rows) == EXPECT_SURVEY, f"survey_T64.log: {len(rows)} reps, want {EXPECT_SURVEY}"
    return [(float(r[0]), float(r[2])) for r in rows]


def q_divisor():
    """[(measured_interval_s, divisor_used_s)] from the fixed arm's gate instrument."""
    txt = _read(f"{QDIR}/raw/Q_Q1.divisor")
    rows = re.findall(r"measured_interval_s=([\d.]+)\s+divisor_used_s=([\d.]+)", txt)
    assert len(rows) == EXPECT_DIVISOR, f"Q_Q1.divisor: {len(rows)} checks, want {EXPECT_DIVISOR}"
    return [(float(a), float(b)) for a, b in rows]


def q_gate_line():
    """The driver's own gate verdict, quoted rather than recomputed."""
    m = re.search(r"GATE:\s+(\d+)/(\d+) live, worst \|measured-divisor\|/measured = ([\d.]+)%", _read(f"{QDIR}/drive_Q.log"))
    assert m, "drive_Q.log: no GATE line"
    return int(m.group(1)), int(m.group(2)), float(m.group(3))


def baseline_instrument_absent():
    return "no divisor instrument" in _read(f"{QDIR}/drive_Q.log")


# The arm-to-arm spread the driver itself warns about, taken from its own caveat line rather than
# from the prereg prose, so the band on figure 1 moves if the driver's estimate ever does.
def arm_to_arm_ms():
    m = re.search(r"quiet arms of the SAME generation came out (\d+) ms apart", _read(f"{QDIR}/drive_Q.log"))
    if not m:
        m = re.search(r"quiet-arm period moved (\d+) ms", _read(f"{QDIR}/survey_T64.log"))
    assert m, "no arm-to-arm caveat found in either log"
    return float(m.group(1))


def m_constants():
    """The two lifetimes M trades between, parsed from M's prereg rather than retyped."""
    txt = _read(f"{MDIR}/PREREG.md")
    idle = re.search(r"FLOW_IDLE_TIMEOUT`?\s*=?\s*\*?\*?(\d+)\s*ms", txt)
    band = re.search(r"after\s+\*\*(\d+)[-–](\d+)%\*\*", txt)
    refute = re.search(r"churn-after 也\s*\*\*≥(\d+)%\*\*", txt)
    assert idle and band and refute, "M PREREG: could not parse idle timeout / band / refutation line"
    return int(idle.group(1)) / 1000.0, (int(band.group(1)), int(band.group(2))), int(refute.group(1))


def m_preflight():
    """[(dur_lo, dur_hi, sha8, cadence, [ratios])] from amendment M-ter's measured table.

    Parsed out of the committed prereg rather than transcribed, because these three rows are the
    reason the ten arms were not run and a slide is going to carry them.
    """
    rows = []
    for line in _read(f"{MDIR}/PREREG.md").splitlines():
        if not line.startswith("|") or "`" not in line:
            continue
        sha = re.search(r"`([0-9a-f]{8})`", line)
        dur = re.search(r"\*{0,2}(\d+)[–-](\d+) s", line)
        cad = re.search(r"（(1 m?s)）", line)
        if not (sha and dur and cad):
            continue
        ratios = [float(v) for v in re.findall(r"(?<![\d.])([01]\.\d{3})(?![\d])", line)]
        if len(ratios) == 3:
            rows.append((int(dur.group(1)), int(dur.group(2)), sha.group(1), cad.group(1), ratios))
    assert len(rows) == 3, f"M-ter pre-flight table: {len(rows)} rows parsed, want 3"
    return rows


# ---------------------------------------------------------------------------- shared style
def _frame(ax, ylab=None, xlab=None):
    if ylab:
        ax.set_ylabel(ylab, color=MUTED, fontsize=11, labelpad=8)
    if xlab:
        ax.set_xlabel(xlab, color=MUTED, fontsize=11, labelpad=7)
    ax.tick_params(colors=MUTED, labelsize=10, length=3, width=0.8)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(RULE)
        ax.spines[s].set_linewidth(0.8)
    ax.grid(axis="y", color=RULE, linewidth=0.6, alpha=0.55)
    ax.set_axisbelow(True)


# Vertical budget for a WIDE page, fixed once so no figure has to re-derive it. The stamp sits on
# its own row ABOVE the title rather than beside it: a long title and a long stamp on one baseline
# collide, and which one wins depends on the font the renderer happens to pick.
# foot was 0.105, which put the last line of every footer off the bottom of the canvas -- both
# 9/03 figures rendered with zero bottom margin and their source citation truncated mid-word.
# It reads fine in a notebook, where the figure is scaled to fit, and only shows in the file.
BAND = dict(stamp=0.975, title=0.905, sub=0.815, foot=0.163)
# Bottom raised 0.06 (top held) when foot moved up: the band was sized for a three-line footer
# and every figure in this deck has four or five, so the axes had to give back the difference.
AXES_Y, AXES_H = 0.285, 0.425


def _title(fig, main, sub, stamp, kind, sub_width=150):
    col, bg = (OKC, "#EFF4F1") if kind == "measured" else (WARNC, WARN_BG)
    fig.text(0.968, BAND["stamp"], stamp, fontsize=10.5, color=col, va="top", ha="right",
             fontweight="bold",
             bbox=dict(facecolor=bg, edgecolor=col, linewidth=0.9, boxstyle="round,pad=0.38"))
    fig.text(0.032, BAND["title"], main, fontsize=19, color=INK, fontweight="bold", va="top")
    fig.text(0.032, BAND["sub"], "\n".join(textwrap.wrap(sub, sub_width)),
             fontsize=12, color=MUTED, va="top", linespacing=1.45)


def _foot(fig, text, x=0.032, width=112):
    fig.text(x, BAND["foot"], "\n".join(textwrap.wrap(text, width)),
             fontsize=9.5, color=FAINT, va="top", linespacing=1.4)


def _title_clean(fig, main, params=""):
    # Adam's ruling, 2026-08-30: deck figures carry a centred title plus one terse parameter
    # line, nothing else -- every explanatory sentence, footer and epistemic stamp moves to
    # the slide template (903 template, §G), which is the single source of truth for prose.
    # _title/_foot remain for figures that have not been re-ruled.
    # [Co-developed with claude code -- Adam]
    fig.text(0.5, BAND["title"], main, fontsize=19, color=INK, fontweight="bold",
             va="top", ha="center")
    if params:
        fig.text(0.5, BAND["sub"], params, fontsize=12, color=MUTED, va="top", ha="center")


def _save(fig, name):
    path = os.path.join(OUT, name)
    fig.savefig(path, dpi=DPI, facecolor="white")
    plt.close(fig)
    print(f"  wrote {path}")


# =========================================================================== figure 1 (Q)
def fig_assumed_denominator():
    arms, survey = q_arms(), q_survey()
    noise_ms = arm_to_arm_ms()

    # Every reading, grouped by work point. The Q arms ran at burners=0; the survey at 64 flows.
    groups = [
        ("16 flows\n(ticket Q arms)", [(a[2], a[3], a[1][:8]) for a in arms]),
        ("64 flows\n(work-point survey)", [(p, o, None) for p, o in survey]),
    ]

    fig = plt.figure(figsize=WIDE)
    # Subtitle prose and both footers moved to the 903 slide template §G (clean-figure
    # ruling, 2026-08-30).
    _title_clean(fig,
                 "The denominator was assumed to be 1.000 s. It never was.",
                 "16-flow ticket-Q arms + 64-flow work-point survey · one fabric generation")

    axL = fig.add_axes([0.055, AXES_Y, 0.375, AXES_H])
    axR = fig.add_axes([0.545, AXES_Y, 0.425, AXES_H])

    # --- left: the periods themselves, against the assumption -------------------------------
    _frame(axL, ylab="Measured loop period  (s)")
    axL.axhline(1.0, color=WARNC, linewidth=1.7, linestyle="--", zorder=3)
    axL.text(1.94, 1.0015, "assumed divisor = 1.000 s", color=WARNC, fontsize=11.5,
             va="bottom", ha="right", fontweight="bold")

    labels = []
    for gi, (gname, rows) in enumerate(groups):
        base = gi * 1.0 + 0.5
        labels.append((base, gname))
        for k, (p, _o, _sha) in enumerate(rows):
            x = base + (k - (len(rows) - 1) / 2) * 0.19
            axL.plot([x, x], [1.0, p], color=ACCENT, linewidth=1.7, alpha=0.45, zorder=4)
            axL.plot([x], [p], "o", ms=11, color=ACCENT, zorder=5,
                     markeredgecolor="white", markeredgewidth=1.2)
            axL.annotate(f"{p:.4f}", (x, p), textcoords="offset points", xytext=(0, 11),
                         ha="center", fontsize=10, color=MUTED)
    axL.set_xticks([b for b, _ in labels])
    axL.set_xticklabels([n for _, n in labels], fontsize=11, color=MUTED)
    axL.set_xlim(0, 2.0)
    axL.set_ylim(0.996, 1.070)

    # --- right: what that costs, and the noise it has to beat -------------------------------
    _frame(axR, ylab="Over-report from the hard-coded 1 s  (%)")
    noise_pct = noise_ms / 10.0            # ms on a ~1000 ms period -> percentage points
    flat = [(f"{a[0]}\n{a[1][:8]}", a[3], ACCENT) for a in arms] + \
           [(f"64-flow\nrep {i + 1}", o, GREY) for i, (_p, o) in enumerate(survey)]
    top = max(o for _, o, _c in flat) * 1.44

    axR.axhspan(0, noise_pct, color=WARN_BG, zorder=1)
    axR.axhline(noise_pct, color=WARNC, linewidth=1.3, linestyle=":", zorder=3)
    axR.text(-0.60, top * 0.985,
             f"shaded: arm-to-arm spread within one generation, {noise_ms:.0f} ms ≈ {noise_pct:.1f} pts",
             color=WARNC, fontsize=11, va="top", ha="left", fontweight="bold")

    for i, (lab, o, col) in enumerate(flat):
        axR.bar(i, o, width=0.54, color=col, edgecolor="white", linewidth=1.0, zorder=5)
        axR.annotate(f"+{o:.1f}%", (i, o), textcoords="offset points", xytext=(0, 6),
                     ha="center", fontsize=11, color=INK, fontweight="bold")
    axR.set_xticks(range(len(flat)))
    axR.set_xticklabels([l for l, _o, _c in flat], fontsize=10, color=MUTED)
    axR.set_xlim(-0.7, len(flat) - 0.3)
    axR.set_ylim(0, top)

    _save(fig, "page_Q_assumed-denominator.png")


# =========================================================================== figure 2 (Q)
def fig_gate_after_fix():
    pairs = q_divisor()
    live, want, worst = q_gate_line()
    absent = baseline_instrument_absent()

    fig = plt.figure(figsize=WIDE)
    # Subtitle, the three verdict cards and the footer moved to the 903 slide template §G
    # (clean-figure ruling, 2026-08-30). The gate verdict is printed below for the audit
    # record, same precedent as the round-2 ratio.
    _title_clean(fig,
                 "After the fix, the divisor is the interval that was actually measured",
                 "one point per round · gate tolerance 1%")

    axL = fig.add_axes([0.34, AXES_Y, 0.32, AXES_H])

    # --- left: the pairs on y = x ------------------------------------------------------------
    _frame(axL, ylab="Divisor actually used  (s)", xlab="Measured interval  (s)")
    lo = min(min(a, b) for a, b in pairs) - 0.016
    hi = max(max(a, b) for a, b in pairs) + 0.016
    axL.plot([lo, hi], [lo, hi], color=RULE, linewidth=1.5, zorder=2)
    axL.text(hi - 0.002, hi - 0.008, "y = x", color=FAINT, fontsize=11, va="top", ha="right")
    for a, b in pairs:
        axL.plot([a], [b], "o", ms=12, color=OKC, zorder=5,
                 markeredgecolor="white", markeredgewidth=1.3)
    axL.axvline(1.0, color=WARNC, linewidth=1.3, linestyle="--", alpha=0.8, zorder=3)
    axL.text(1.0018, lo + 0.003, "old hard-coded 1.000 s", color=WARNC, fontsize=9.5,
             ha="left", va="bottom", fontweight="bold", rotation=90)
    axL.set_xlim(lo, hi)
    axL.set_ylim(lo, hi)
    axL.set_xticks([1.00, 1.02, 1.04, 1.06])
    axL.set_yticks([1.00, 1.02, 1.04, 1.06])
    axL.set_aspect("equal", adjustable="box")

    print(f"  [audit] Q gate: {live}/{want} live checks, worst disagreement {worst:.4f}% "
          f"(threshold 1%); intervals {min(a for a, _ in pairs):.3f}-{max(a for a, _ in pairs):.3f} s; "
          f"baseline instrument {'ABSENT (recorded as absent, not as a pass)' if absent else 'state unrecorded'}")
    _save(fig, "page_Q_gate-after-fix.png")


# =========================================================================== figure 3 (M)
def fig_what_1khz_buys():
    idle_s, band, _refute = m_constants()

    fig = plt.figure(figsize=WIDE)
    _title(fig,
           "Ticket M: the path recompute ran at 1 kHz to keep one API field fresh",
           "One kernel thread recomputed every flow's path every millisecond. It has exactly one "
           "consumer — the `path` field of the flow API. Moving it to 1 Hz trades that freshness "
           "for the cost.",
           "MECHANISM · NO ARM HAS RUN YET", "predicted")

    axL = fig.add_axes([0.042, AXES_Y, 0.435, AXES_H])
    axR = fig.add_axes([0.575, AXES_Y, 0.395, AXES_H])

    # --- left: what the cadence buys, per flow lifetime --------------------------------------
    axL.set_xlim(0, 1)
    axL.set_ylim(0, 1)
    axL.axis("off")

    rows = [
        ("recompute cadence", "every 1 ms", "every 1 s", ACCENT),
        ("`path` staleness bound", "1 ms", "1 s", ACCENT),
        (f"recomputes per {idle_s:.0f} s idle timeout",
         f"{int(idle_s * 1000):,}", f"{int(idle_s):,}", ACCENT),
        ("thread CPU", "46.31%   prior attribution", "< 1%   predicted", WARNC),
        ("consumers that would notice", "1   API `path`", "1   API `path`", GREY),
    ]
    axL.text(0.545, 1.0, "1 kHz   before", fontsize=12.5, color=MUTED, ha="center",
             fontweight="bold", transform=axL.transAxes, va="top")
    axL.text(0.87, 1.0, "1 Hz   after", fontsize=12.5, color=ACCENT, ha="center",
             fontweight="bold", transform=axL.transAxes, va="top")
    axL.plot([0.0, 1.0], [0.925, 0.925], color=RULE, linewidth=1.0, transform=axL.transAxes)
    for i, (name, before, after, col) in enumerate(rows):
        y = 0.83 - i * 0.175
        axL.add_patch(Rectangle((0.0, y - 0.072), 1.0, 0.144, transform=axL.transAxes,
                                facecolor=PANEL if i % 2 == 0 else "white",
                                edgecolor="none", zorder=0))
        axL.text(0.012, y, name, fontsize=11.5, color=INK, transform=axL.transAxes, va="center")
        axL.text(0.545, y, before, fontsize=11.5, color=MUTED, ha="center",
                 transform=axL.transAxes, va="center")
        axL.text(0.87, y, after, fontsize=11.5, color=col, ha="center", fontweight="bold",
                 transform=axL.transAxes, va="center")

    # --- right: the cost of 1 Hz, as a function of how long a flow lives ---------------------
    _frame(axR, ylab="Share of a flow's life with a `path`  (%)",
           xlab="Mean flow lifetime  (s)   — log scale")
    xs = [0.3 * (1.02 ** i) for i in range(int(__import__("math").log(300 / 0.3, 1.02)) + 1)]
    ys = [max(0.0, 1.0 - 0.5 / x) * 100 for x in xs]
    axR.fill_between(xs, 0, ys, color=ACCENT_BG, zorder=2)
    axR.plot(xs, ys, color=ACCENT, linewidth=2.6, zorder=5)
    for lab, x, dx, dy, ha in (("churn arm\n1–4 s flows", 2.5, 12, -6, "left"),
                               ("steady arm\n300 s flows", 300.0, -12, -14, "right")):
        yv = max(0.0, 1.0 - 0.5 / x) * 100
        axR.plot([x], [yv], "o", ms=11, color=INK, zorder=6,
                 markeredgecolor="white", markeredgewidth=1.3)
        axR.annotate(f"{lab}\n{yv:.1f}%", (x, yv), textcoords="offset points", xytext=(dx, dy),
                     ha=ha, va="top", fontsize=10.5, color=INK)
    axR.set_xscale("log")
    axR.set_xlim(0.3, 400)
    axR.set_ylim(0, 108)
    axR.set_xticks([0.5, 1, 2.5, 5, 10, 30, 100, 300])
    axR.set_xticklabels(["0.5", "1", "2.5", "5", "10", "30", "100", "300"],
                        fontsize=10, color=MUTED)
    axR.minorticks_off()

    _foot(fig,
          "The 46.31% is a prior attribution and is itself under test this round: if the CPU does "
          "not drop, the thing the round refutes is that attribution, not the fix. Source: ticket M "
          "prereg and commit 2f57ba5; 617 unit tests pass, and they pin the constant, not the "
          "behaviour.", x=0.042, width=92)
    _foot(fig,
          "At 1 Hz a new flow waits half a second on average for its first path, so the share of its "
          "life without one is 0.5 / lifetime. Long flows never notice. Short flows are the entire "
          "risk of this change.", x=0.575, width=88)
    _save(fig, "page_M_what-1khz-buys.png")


# =========================================================================== figure 4 (M)
def fig_dose_response():
    idle_s, band, _refute = m_constants()

    pre = m_preflight()

    fig = plt.figure(figsize=WIDE)
    _title(fig,
           "A two-minute pre-flight refuted the arithmetic, before ten arms ran",
           "The prediction was written down first, so it could be checked cheaply. It was wrong — "
           "and wrong in the opposite direction, which is what made the cause findable rather than "
           "just the number wrong.",
           "PRE-FLIGHT · THE TEN ARMS WERE NOT RUN", "predicted")

    ax = fig.add_axes([0.052, AXES_Y, 0.545, AXES_H])
    _frame(ax, ylab="Share of listed flows with a `path`  (%)",
           xlab="Mean flow lifetime under churn  (s)")

    xs = [1.0 + i * 0.02 for i in range(int((11.0 - 1.0) / 0.02) + 1)]
    ax.plot(xs, [(1.0 - 0.5 / x) * 100 for x in xs], color=GREY, linewidth=2.4,
            linestyle="--", zorder=4)
    ax.axhspan(band[0], band[1], color=ACCENT_BG, zorder=1)
    ax.text(10.8, 89.2, f"predicted band  {band[0]}–{band[1]}%", fontsize=11,
            color=ACCENT, ha="right", va="top", fontweight="bold")
    ax.text(6.2, 79.0, "predicted:  1 − 0.5 / lifetime", fontsize=11.5, color=GREY,
            ha="left", va="top", fontweight="bold")

    # measured pre-flight points, at the midpoint of each dose range
    for lo, hi, sha, cad, ratios in pre:
        x = (lo + hi) / 2
        col = ACCENT if cad == "1 s" else FAINT
        for r in ratios:
            ax.plot([x], [r * 100], "o", ms=13, color=col, zorder=7, alpha=0.85,
                    markeredgecolor="white", markeredgewidth=1.6)
        lab = f"{lo}–{hi} s @ {cad}"
        ax.annotate(lab, (x, min(ratios) * 100), textcoords="offset points",
                    xytext=(0, -16), ha="center", va="top", fontsize=10.5, color=col,
                    fontweight="bold")

    # the contradiction, drawn
    ax.annotate("", xy=(2.5, 99.0), xytext=(2.5, 81.5),
                arrowprops=dict(arrowstyle="-|>", color=WARNC, linewidth=2.4))
    ax.text(2.85, 90.0, "measured 19 points\nABOVE the prediction —\nand rising as flows shorten",
            fontsize=11, color=WARNC, ha="left", va="center", fontweight="bold")

    ax.set_xlim(1.0, 11.0)
    ax.set_ylim(74, 103)

    # --- what it turned out to be ------------------------------------------------------------
    axT = fig.add_axes([0.642, AXES_Y, 0.328, AXES_H])
    axT.set_xlim(0, 1)
    axT.set_ylim(0, 1)
    axT.axis("off")
    axT.add_patch(Rectangle((0, 0), 1, 1, transform=axT.transAxes, facecolor=PANEL,
                            edgecolor=RULE, linewidth=1.0))
    axT.text(0.05, 0.955, "What the metric was actually counting", fontsize=13.5, color=INK,
             fontweight="bold", transform=axT.transAxes, va="top")
    body = [
        (f"The denominator is \"flows the API lists\", and a finished flow stays "
         f"listed for the {idle_s:.0f} s idle timeout — already holding a path.", INK),
        ("So the denominator fills with flows that cannot fail the test, and the "
         "ratio pins near 1 whatever the cadence is.", WARNC),
        ("Shortening flows makes it worse: the tail is set by the idle timeout, "
         "not by how long flows live. Hence the reversed direction.", MUTED),
        ("The metric was replaced instead. The pre-flight cost two minutes; the ten "
         "arms would have produced a confident wrong verdict.", ACCENT),
    ]
    y = 0.845
    for text, col in body:
        wrapped = "\n".join(textwrap.wrap(text, 50))
        axT.text(0.05, y, wrapped, fontsize=10.5, color=col, transform=axT.transAxes,
                 va="top", linespacing=1.45)
        y -= 0.052 * (wrapped.count("\n") + 1) + 0.040

    _foot(fig,
          "Measured rows are amendment M-ter's pre-flight table (committed); the dashed curve is the "
          "closed form 1 − 0.5/lifetime that they refute. The judgement table would have read the flat "
          "~1.00 as \"the mechanism is refuted\", when what is refuted is the metric's ability to see "
          "it. The size of the dilution is in the pre-flight readout (868fa0e); its raw output is not "
          "yet committed, so it is not plotted here.",
          x=0.052, width=150)
    _save(fig, "page_M_dose-response.png")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    print(f"out: {OUT}")
    fig_assumed_denominator()
    fig_gate_after_fix()
    fig_what_1khz_buys()
    fig_dose_response()
