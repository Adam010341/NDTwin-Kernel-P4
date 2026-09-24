#!/usr/bin/env python3
"""Draw figure 3 through the REAL plot._line_panels and measure where each end label landed.

[Co-developed with claude code -- Adam]

Ruling 37(9a) asked for the drawn figure to be measured, not a geometric reconstruction of it;
round 9 did that once and kept only the output (ruling 39(9b)). Ruling 39(6) then found that
its "glyph top" was still a MODEL -- `display_points + LABEL_HEIGHT_PT / 2`, 11 pt assumed --
so "the figure really fits" was half measured: the axes box was read from matplotlib, the text
was not. This reads BOTH from matplotlib:

  * each panel's axes height, via axes.get_position(), immediately before and after the
    set_ylim that _line_panels makes (so "height_points still holds" is a reading);
  * each end label's real text box, via Annotation.get_window_extent(renderer) after the
    figure is drawn, against the axes' own window extent -- the top of the glyphs matplotlib
    actually laid out, in points, next to the 11 pt model's top.

Nothing is monkeypatched inside plot.py's logic: plt.subplots is wrapped only to learn which
figure and axes _line_panels creates, and plt.close only to keep that figure alive long enough
to be read. The figure files go to --out (a scratch directory), never beside plot.py.

Usage:  tests/postcheck_real_render.py --summary <summary.json> --out <scratch dir>
Exit:   0 every label's real box is inside its axes and no axes box moved, 1 otherwise.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import plot                                         # noqa: E402


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    plt = plot._pyplot()
    import matplotlib
    print("# matplotlib %s, backend %s" % (matplotlib.__version__, matplotlib.get_backend()))
    captured = {}
    real_subplots, real_close = plt.subplots, plt.close

    def subplots(*a, **k):
        figure, axes = real_subplots(*a, **k)
        captured["figure"], captured["axes"] = figure, list(axes) if hasattr(axes, "__len__") \
            else [axes]
        heights = captured.setdefault("heights", {})
        for ax in captured["axes"]:
            original = ax.set_ylim

            def set_ylim(*ya, _ax=ax, _original=original, **yk):
                before = _ax.get_position().height
                result = _original(*ya, **yk)
                heights[id(_ax)] = (before, _ax.get_position().height)
                return result
            ax.set_ylim = set_ylim
        return figure, axes

    def close(figure=None):
        if figure is not captured.get("figure"):
            real_close(figure)

    plt.subplots, plt.close = subplots, close
    try:
        summary = plot.load_summary(args.summary)
        data = plot.figure_data(summary)["fig3_cpu"]
        plot._line_panels(plt, data, os.path.join(args.out, "fig3_cpu"))
    finally:
        plt.subplots, plt.close = real_subplots, real_close
    figure = captured["figure"]
    figure.canvas.draw()
    renderer = figure.canvas.get_renderer()
    to_points = 72.0 / figure.dpi
    inches = figure.get_size_inches()[1]
    all_inside, all_unmoved, rows = True, True, 0
    for ax, panel in zip(captured["axes"], data["panels"]):
        before, after = captured["heights"][id(ax)]
        unmoved = before == after
        all_unmoved &= unmoved
        box = ax.get_window_extent(renderer)
        print("panel %-16s axes height BEFORE set_ylim %.4f pt  AFTER %.4f pt  %s  (drawn box "
              "%.4f pt)" % (panel["panel"], before * inches * 72.0, after * inches * 72.0,
                            "UNCHANGED" if unmoved else "MOVED", box.height * to_points))
        for text in ax.texts:
            extent = text.get_window_extent(renderer)
            offset = text.xyann[1]
            anchor = ax.transData.transform(text.xy)[1]
            centre = (anchor - box.y0) * to_points + offset
            model_top = centre + plot.LABEL_HEIGHT_PT / 2.0
            real_top = (extent.y1 - box.y0) * to_points
            real_bottom = (extent.y0 - box.y0) * to_points
            inside = extent.y1 <= box.y1 and extent.y0 >= box.y0
            all_inside &= inside
            rows += 1
            print("    %-5s centre %7.2f pt   model top %7.2f   REAL box %7.2f .. %7.2f pt "
                  "(height %5.2f)   axes top %7.2f   margin %+6.2f pt   %s"
                  % (text.get_text(), centre, model_top, real_bottom, real_top,
                     extent.height * to_points, box.height * to_points,
                     (box.y1 - extent.y1) * to_points, "inside" if inside else "OUTSIDE"))
    real_close(figure)
    print("\nlabels measured: %d" % rows)
    print("EVERY LABEL'S REAL TEXT BOX INSIDE ITS OWN AXES: %s" % all_inside)
    print("EVERY AXES BOX UNMOVED BY set_ylim: %s" % all_unmoved)
    return 0 if (all_inside and all_unmoved) else 1


if __name__ == "__main__":
    sys.exit(main())
