#!/usr/bin/env python3
"""
The three figures of the three-group telemetry round, as .png and .pdf.

[Co-developed with claude code -- Adam]

🔴 WHAT IS ALLOWED ON A FIGURE, and nothing else (CLAUDE.md, TICKET-P3 section 2.8):
      the title, the axis labels, the tick labels, and the value labels.
Method, caveats, conditions, the reconciliation, what a bar does NOT mean -- all of that goes in
FINDINGS.md beside the figure. There is no legend box either: a series is named by its tick
label (figures 1 and 2) or by a short word at the end of its own line (figure 3), which is a
series label rather than a block of prose parked on the plot.

🔴 IT READS summary.json, NEVER raw/. Every number on a figure has therefore passed through
analyse.py, which the unit tests cover. A figure that recomputed its own numbers would be a
second implementation of the analysis with no tests and no way to notice it had drifted -- and
the 08-20 round found two disagreements exactly by checking a figure against its report.

🔴 n/a IS NOT A BAR OF HEIGHT ZERO. The `none` group has no sampling error to plot; figure 2
prints the word n/a where its bar would be. Drawing a zero would put an absence on the axis as a
measurement, which is the single thing PREREG section 5.2 forbids for that cell.

matplotlib is imported lazily so that everything above rendering -- the layout, the labels, the
n/a decision -- is importable and testable under p4_proxy/venv/bin/python, which has no
matplotlib. `render` is the only function that needs it.

Usage:
    plot.py --summary <summary.json> [--out <directory>] [--check]

`--check` builds every figure's data and prints it without drawing anything, so the figures can
be reviewed before a machine with matplotlib is involved.
"""
import argparse
import json
import os
import sys

GROUP_ORDER = ("none", "cooperative", "link")
#: How much vertical room one end-of-line label needs before the next one touches it. The labels
#: are drawn at fontsize 9 and matplotlib's line height is 1.2x the font size, so a label owns
#: about 11 points of the axes. It is a display quantity and it is in display units, which is the
#: whole of the correction below.
LABEL_HEIGHT_PT = 11.0
#: The short words that appear as tick labels. Deliberately shorter than the group names used in
#: prose: a tick label is read at a glance and has no room for a sentence.
GROUP_TICK = {"none": "none", "cooperative": "coop", "link": "link"}
FIGURES = ("fig1_pps_ceiling", "fig2_sampling_error", "fig3_cpu")


def load_summary(path):
    with open(path) as fh:
        return json.load(fh)


# --- figure 1: the pps ceiling ---------------------------------------------------------------

def figure1_data(summary):
    """[(tick label, value, value label)] -- one bar per (group, frame) cell, frames grouped.

    An unresolved cell (two arms more than one rung apart) is drawn at its mean with its value
    label carrying both arm values, because the mean of two values a factor apart is not a
    reading and the figure must not present it as one.
    """
    cells = summary.get("cells") or {}
    parsed = {}
    for key, cell in cells.items():
        group, frame = key.split("|")
        parsed[(group, int(frame))] = cell
    bars = []
    for frame in sorted({frame for (_g, frame) in parsed}):
        for group in GROUP_ORDER:
            cell = parsed.get((group, frame))
            if not cell:
                continue
            mean = cell.get("mean")
            arms = sorted(v for v in (cell.get("arms") or {}).values() if v is not None)
            if mean is None:
                label = "n/a"
            elif cell.get("resolved"):
                label = "%.1f" % mean
            else:
                label = "%.1f*" % mean if not arms else "%.1f* (%s)" % (
                    mean, "/".join("%g" % a for a in arms))
            bars.append({"tick": "%s\n%dB" % (GROUP_TICK.get(group, group), frame),
                         "value": mean or 0.0, "label": label,
                         "resolved": bool(cell.get("resolved"))})
    return {"title": "Clean forwarding rate by telemetry source and frame size",
            "xlabel": "telemetry source / Ethernet frame size",
            "ylabel": "highest clean rate (kpps)",
            "bars": bars}


# --- figure 2: the sampling error --------------------------------------------------------------

def figure2_data(summary):
    """One bar per (group, rate); the `none` group gets the word n/a where its bar would be."""
    rows = summary.get("sampling_error") or []
    by_key = {(row["group"], row["offered_mbit"]): row for row in rows}
    rates = sorted({rate for (_g, rate) in by_key})
    bars = []
    for rate in rates:
        for group in GROUP_ORDER:
            row = by_key.get((group, rate))
            tick = "%s\n%gM" % (GROUP_TICK.get(group, group), rate)
            if row is None:
                continue
            error = row.get("median_abs_error")
            if error is None:
                # 🔴 The absence is drawn as an absence. PREREG 5.2.
                bars.append({"tick": tick, "value": None, "label": "n/a", "na": True})
            else:
                bars.append({"tick": tick, "value": 100.0 * error,
                             "label": "%.1f" % (100.0 * error), "na": False})
    return {"title": "Twin bandwidth error against /proc/net/dev, by telemetry source",
            "xlabel": "telemetry source / offered rate",
            "ylabel": "median |twin / ground truth - 1|  (%)",
            "bars": bars}


# --- figure 3: CPU ------------------------------------------------------------------------------

def figure3_data(summary):
    """Three panels (bmv2, kernel, proxy+emitter), one line per group, x = offered kpps.

    The series are labelled at the right-hand end of their own line rather than in a legend box:
    the group word sits where the reader's eye already is, and nothing else is added to the plot.
    """
    panels = []
    kernel = summary.get("cpu_kernel") or {}
    bmv2 = summary.get("cpu_bmv2") or {}
    for label, source in (("bmv2", bmv2), ("kernel", kernel)):
        per_group = source.get("per_group") or {}
        series = []
        for group in GROUP_ORDER:
            points = sorted((float(k), v.get("cpu")) for k, v in (per_group.get(group) or {}).items()
                            if v.get("cpu") is not None)
            if points:
                series.append({"name": GROUP_TICK.get(group, group), "points": points})
        panels.append({"panel": label, "series": series})
    # proxy + emitter share a panel: together they are "the control plane's share of sampling",
    # and under `none` and `cooperative` the emitter does not exist at all.
    per_group = (kernel.get("per_group") or {})
    series = []
    for group in GROUP_ORDER:
        points = sorted((float(k), v.get("_proxy_plus_emitter"))
                        for k, v in (per_group.get(group) or {}).items()
                        if v.get("_proxy_plus_emitter") is not None)
        if points:
            series.append({"name": GROUP_TICK.get(group, group), "points": points})
    panels.append({"panel": "proxy + emitter", "series": series})
    return {"title": "CPU by telemetry source and offered rate (1024 B frames)",
            "xlabel": "offered rate (kpps)",
            "ylabel": "CPU (% of one core)",
            "panels": panels}


def end_label_offsets(ends, ylim, height_points, label_points=LABEL_HEIGHT_PT):
    """[(y, x, name)] -> the same, in y order, each with the offset its label must be drawn at.

    🔴 WHETHER TWO LABELS COLLIDE IS A QUESTION ABOUT THE DISPLAY, NOT ABOUT THE VALUES. This
    used to ask whether two ends were closer than 3% of the SPREAD OF THE ENDS, which has no
    relation to the picture: the ends can be spread over a hundredth of the axes (three lines
    that converge) or over all of it, and 3% of their own spread says the same thing in both
    cases. Figure 3's bmv2 panel in the fourth campaign is the second case: the three ends are
    725.92, 725.92 and 764.86 on an axis running from about 27 to 765, so `coop` sits 38.9 units
    -- about one label height -- above the other two, the old rule called that "far apart" (38.9
    > 3% of 38.9) and gave it offset 0, while `none` had already been nudged 9 points up into
    exactly that space. Two names were printed on top of each other and the figure showed one
    illegible word.
    So: convert each end to a position on THE AXES, in points, and require a label height
    between consecutive labels. A label that has been displaced carries its displacement into
    the next comparison -- the staggering is what created the collision the old rule could not
    see. Nothing here moves the data; only the text beside it.

    `ylim` is the axes' own (low, high) and `height_points` its height in points, both read from
    the figure after the layout is fixed. The y axis is linear (only x is logarithmic here), so
    the conversion is one ratio.
    """
    ordered = sorted(ends)
    low, high = ylim
    span = float(high) - float(low)
    scale = (float(height_points) / span) if (span > 0 and height_points > 0) else 0.0
    placed, previous = [], None
    for index, (y, x, name) in enumerate(ordered):
        natural = (y - low) * scale
        final = natural if previous is None else max(natural, previous + label_points)
        placed.append({"name": name, "x": x, "y": y, "natural_points": natural,
                       "display_points": final, "offset": final - natural})
        previous = final
    return placed


def place_end_labels(ends, ylim, height_points, label_points=LABEL_HEIGHT_PT):
    """-> ((low, high), placed): the axes limits these labels need, and where each one goes.

    🔴 STAGGERING CAN PUSH THE TOP LABEL OUT OF THE AXES, and on the fourth campaign's figure 3
    it did: the bmv2 panel is 206.5 pt tall, matplotlib's 5% margin leaves 9.4 pt above the
    highest line end -- less than one label height -- and `coop`, displaced 12.1 pt to clear
    `none`, ended with its glyph top at 214.7 pt, 8.2 pt ABOVE the axes and on top of the panel
    title (`annotate` does not clip). That is a defect this round's own fix introduced: the old
    rule left that label at offset 0, inside the axes, and illegibly on top of another label.
    Both are wrong, and they are not a trade-off.

    So the labels are not pushed back down -- that is the overlap again -- the AXES ARE GIVEN
    ROOM: the top limit is raised until the highest glyph fits under it. Raising the limit moves
    no data point, adds no text, and changes only how much blank sky the panel has.

    The needed limit is SOLVED, not approached. Stacking gives the i-th label (in y order)
    f_i = max_{j<=i} (natural_j + (i-j) x label), so the top one sits at
    max_j (natural_j + (n-1-j) x label) and has to satisfy `+ label/2 <= height`. Each j turns
    into one lower bound on the span, and the largest of them is the answer. Raising by the
    overflow instead, in a loop, only converges ON the answer from above -- it is still 1e-6 pt
    over after eight passes, which is invisible but is not what the code claims to do.
    """
    low, high = float(ylim[0]), float(ylim[1])
    ordered = sorted(ends)
    if ordered and height_points > 0 and high > low:
        count = len(ordered)
        needed = high - low
        for index, (y, _x, _name) in enumerate(ordered):
            headroom = height_points - (count - 1 - index) * label_points - label_points / 2.0
            if headroom <= 0:
                # 🔴 NO ROOM ABOVE THIS LABEL, whatever the span is: it needs (count-1-index)
                # label heights above it plus half its own, and that is the whole axes or more.
                # Below zero no limit fixes it. AT zero it fits only by sitting exactly on the
                # axes' bottom, where its bound (y-low)*H/headroom is a division by zero. Either
                # way this label contributes no bound -- and at zero, skipping it is what keeps
                # the function from dividing by zero (ruling 39(9c): test_plot's EXACTLY-zero
                # case, M-E41; below zero the guard is an equivalent mutation, because the
                # unguarded bound is negative and loses every max).
                #
                # What the caller gets in that case is EXACTLY the same 2-tuple as always: no
                # flag, no exception, no third element. The overflow is visible -- the returned
                # placement puts the top label's glyph above `height_points` and a caller can
                # subtract -- but nothing forces it to look, and _line_panels does not.
                # test_plot.py's `test_a_stack_taller_than_its_axes...` pins both halves of
                # that: the overflow is in the return, and the return has no signal in it.
                # (Ruling 37(5); the interface half is in the round 9 candidate list.)
                continue
            needed = max(needed, (y - low) * height_points / headroom)
        high = low + needed
    return (low, high), end_label_offsets(ends, (low, high), height_points, label_points)


def figure_data(summary):
    return {"fig1_pps_ceiling": figure1_data(summary),
            "fig2_sampling_error": figure2_data(summary),
            "fig3_cpu": figure3_data(summary)}


# --- the one function that needs matplotlib ------------------------------------------------------

def _pyplot():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt


def _bar_axes(plt, data, out_base):
    figure, axes = plt.subplots(figsize=(9, 4.5))
    ticks = [bar["tick"] for bar in data["bars"]]
    values = [0.0 if bar.get("value") is None else bar["value"] for bar in data["bars"]]
    positions = list(range(len(values)))
    axes.bar(positions, values, width=0.68)
    axes.set_xticks(positions)
    axes.set_xticklabels(ticks)
    axes.set_title(data["title"])
    axes.set_xlabel(data["xlabel"])
    axes.set_ylabel(data["ylabel"])
    top = max(values) if values else 1.0
    for position, bar in zip(positions, data["bars"]):
        height = 0.0 if bar.get("value") is None else bar["value"]
        axes.annotate(bar["label"], (position, height), textcoords="offset points",
                      xytext=(0, 4), ha="center", fontsize=9)
    axes.set_ylim(0, top * 1.18 if top else 1.0)
    figure.tight_layout()
    for extension in ("png", "pdf"):
        figure.savefig("%s.%s" % (out_base, extension), dpi=160)
    plt.close(figure)


def _line_panels(plt, data, out_base):
    panels = data["panels"]
    figure, axes_list = plt.subplots(1, len(panels), figsize=(4.2 * len(panels), 4.2), sharex=True)
    if len(panels) == 1:
        axes_list = [axes_list]
    panel_ends = []
    for axes, panel in zip(axes_list, panels):
        ends = []
        for series in panel["series"]:
            xs = [x for x, _y in series["points"]]
            ys = [y for _x, y in series["points"]]
            axes.plot(xs, ys, marker="o", markersize=3)
            if xs:
                ends.append((ys[-1], xs[-1], series["name"]))
        panel_ends.append((axes, ends))
        axes.set_title(panel["panel"])
        axes.set_xlabel(data["xlabel"])
        axes.set_xscale("log")
        # room on the right for the end-of-line labels, which would otherwise be clipped
        axes.margins(x=0.22)
    axes_list[0].set_ylabel(data["ylabel"])
    figure.suptitle(data["title"])
    # 🔴 THE LAYOUT IS FIXED BEFORE THE LABELS ARE PLACED, because where a label goes is decided
    # in points on the axes and the axes' height is not known until then. tight_layout() moves
    # the axes; annotate() with an offset in points does not.
    figure.tight_layout()
    inches = figure.get_size_inches()[1]
    for axes, ends in panel_ends:
        # The series name at the end of its own line, not in a legend block. Two lines whose ends
        # land within a label height of each other on the DISPLAY would print their names on top
        # of one another, so those labels are staggered -- which moves the text, never the data.
        height_points = axes.get_position().height * inches * 72.0
        ylim, labels = place_end_labels(ends, axes.get_ylim(), height_points)
        # 🔴 the axes get the room, the labels keep their separation. set_ylim after
        # tight_layout() changes the scale inside the box, not the box, so height_points holds.
        axes.set_ylim(*ylim)
        for label in labels:
            axes.annotate(label["name"], (label["x"], label["y"]), textcoords="offset points",
                          xytext=(5, label["offset"]), ha="left", va="center", fontsize=9)
    for extension in ("png", "pdf"):
        figure.savefig("%s.%s" % (out_base, extension), dpi=160)
    plt.close(figure)


def render(summary, out_dir):
    """Draw all three figures. Returns the list of files written."""
    plt = _pyplot()
    data = figure_data(summary)
    written = []
    _bar_axes(plt, data["fig1_pps_ceiling"], os.path.join(out_dir, "fig1_pps_ceiling"))
    _bar_axes(plt, data["fig2_sampling_error"], os.path.join(out_dir, "fig2_sampling_error"))
    _line_panels(plt, data["fig3_cpu"], os.path.join(out_dir, "fig3_cpu"))
    for name in FIGURES:
        for extension in ("png", "pdf"):
            path = os.path.join(out_dir, "%s.%s" % (name, extension))
            if os.path.exists(path):
                written.append(path)
    return written


def describe(data, stream=sys.stdout):
    """What each figure would show, as text -- `--check`, and what the tests read."""
    write = stream.write
    for name in ("fig1_pps_ceiling", "fig2_sampling_error"):
        figure = data[name]
        write("%s: %s\n" % (name, figure["title"]))
        write("  x: %s   y: %s\n" % (figure["xlabel"], figure["ylabel"]))
        for bar in figure["bars"]:
            write("    %-14s %-10s %s\n"
                  % (bar["tick"].replace("\n", " "),
                     "n/a" if bar.get("value") is None else "%.3f" % bar["value"], bar["label"]))
    figure = data["fig3_cpu"]
    write("fig3_cpu: %s\n" % figure["title"])
    write("  x: %s   y: %s\n" % (figure["xlabel"], figure["ylabel"]))
    for panel in figure["panels"]:
        write("    panel %s\n" % panel["panel"])
        for series in panel["series"]:
            write("      %-6s %s\n" % (series["name"],
                                       " ".join("%g:%.1f" % point for point in series["points"])))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Render the three figures of the E round")
    parser.add_argument("--summary", required=True, help="summary.json written by analyse.py")
    parser.add_argument("--out", help="directory for the figures (default: beside this script)")
    parser.add_argument("--check", action="store_true",
                        help="print what each figure would show and draw nothing")
    args = parser.parse_args(argv)
    summary = load_summary(args.summary)
    data = figure_data(summary)
    if args.check:
        describe(data)
        return 0
    out_dir = args.out or os.path.dirname(os.path.abspath(__file__))
    try:
        written = render(summary, out_dir)
    except ImportError:
        print("plot.py: this interpreter has no matplotlib. Use one that does, or --check.",
              file=sys.stderr)
        return 2
    for path in written:
        print("wrote %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
