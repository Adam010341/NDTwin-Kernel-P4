#!/usr/bin/env python3
"""
Tests for plot.py: what goes on a figure, what stays off it, and that n/a is not a zero bar.

[Co-developed with claude code -- Adam]

The figure rules are a project rule, not a preference (CLAUDE.md: 圖上只留讀圖必需的字), so they
are asserted rather than reviewed: the data a figure is built from may carry a title, axis labels,
tick labels and value labels, and nothing else. A caption, a note, a method line or a legend block
appearing in that structure is this test going red.

matplotlib lives only inside render(), so everything here except the one rendering case runs
under p4_proxy/venv/bin/python, which does not have it.
"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import analyse                                       # noqa: E402
import plot                                          # noqa: E402
import synthetic                                     # noqa: E402

#: The only keys a figure's data may carry. A new one has to be added here deliberately, which is
#: the point: prose reaches a figure by someone adding a field, and this is the review.
FIGURE_KEYS = {"title", "xlabel", "ylabel", "bars", "panels"}
BAR_KEYS = {"tick", "value", "label", "resolved", "na"}


def build_summary(**kwargs):
    tmp = tempfile.TemporaryDirectory()
    synthetic.build(tmp.name, **kwargs)
    return analyse.analyse(tmp.name), tmp


class FigureContentRulesTest(unittest.TestCase):
    def setUp(self):
        self.summary, self.tmp = build_summary()
        self.addCleanup(self.tmp.cleanup)
        self.data = plot.figure_data(self.summary)

    def test_a_figure_carries_only_a_title_axes_and_labels(self):
        for name, figure in self.data.items():
            self.assertTrue(set(figure) <= FIGURE_KEYS,
                            "%s carries %s" % (name, set(figure) - FIGURE_KEYS))
            for bar in figure.get("bars", []):
                self.assertTrue(set(bar) <= BAR_KEYS, "%s: %s" % (name, set(bar) - BAR_KEYS))

    def test_no_value_label_is_a_sentence(self):
        # A value label is a number, possibly with a marker. Anything long enough to be prose has
        # been put on the plot instead of into FINDINGS.md.
        for name, figure in self.data.items():
            for bar in figure.get("bars", []):
                self.assertLessEqual(len(bar["label"]), 18, "%s: %r" % (name, bar["label"]))

    def test_every_figure_names_both_of_its_axes(self):
        for name, figure in self.data.items():
            self.assertTrue(figure["xlabel"], name)
            self.assertTrue(figure["ylabel"], name)
            self.assertTrue(figure["title"], name)


class Figure1Test(unittest.TestCase):
    def setUp(self):
        self.summary, self.tmp = build_summary()
        self.addCleanup(self.tmp.cleanup)
        self.figure = plot.figure1_data(self.summary)

    def bar(self, tick):
        return next(b for b in self.figure["bars"] if b["tick"].replace("\n", " ") == tick)

    def test_one_bar_per_cell_grouped_by_frame_size(self):
        ticks = [b["tick"].replace("\n", " ") for b in self.figure["bars"]]
        self.assertEqual(ticks, ["none 64B", "coop 64B", "link 64B",
                                 "none 1024B", "coop 1024B", "link 1024B"])

    def test_a_resolved_cell_is_labelled_with_its_mean_alone(self):
        self.assertEqual(self.bar("coop 1024B")["label"], "16.0")

    def test_an_unresolved_cell_is_marked_and_shows_BOTH_arm_values(self):
        # 🔴 The mean of two arms six rungs apart is a number no arm measured. The figure may
        # still place it, but it may not present it as a reading.
        bar = self.bar("link 64B")
        self.assertFalse(bar["resolved"])
        self.assertIn("*", bar["label"])
        self.assertIn("1", bar["label"])
        self.assertIn("20", bar["label"])


class Figure2Test(unittest.TestCase):
    def setUp(self):
        self.summary, self.tmp = build_summary()
        self.addCleanup(self.tmp.cleanup)
        self.figure = plot.figure2_data(self.summary)

    def bar(self, tick):
        return next(b for b in self.figure["bars"] if b["tick"].replace("\n", " ") == tick)

    def test_the_none_group_is_drawn_as_n_a_and_NOT_as_a_zero_bar(self):
        # 🔴 PREREG 5.2, and the single thing this figure must not do: a zero-height bar puts an
        # absence on the axis as a measurement, and a reader cannot tell it from a perfect twin.
        bar = self.bar("none 20M")
        self.assertIsNone(bar["value"])
        self.assertEqual(bar["label"], "n/a")
        self.assertTrue(bar["na"])

    def test_a_measured_group_is_drawn_as_a_percentage(self):
        bar = self.bar("coop 20M")
        self.assertAlmostEqual(bar["value"], 4.5, places=3)
        self.assertEqual(bar["label"], "4.5")
        self.assertFalse(bar["na"])

    def test_the_y_axis_says_what_the_number_is(self):
        self.assertIn("twin", self.figure["ylabel"])
        self.assertIn("%", self.figure["ylabel"])


class Figure3Test(unittest.TestCase):
    def setUp(self):
        self.summary, self.tmp = build_summary()
        self.addCleanup(self.tmp.cleanup)
        self.figure = plot.figure3_data(self.summary)

    def test_three_panels_one_per_process_class(self):
        self.assertEqual([p["panel"] for p in self.figure["panels"]],
                         ["bmv2", "kernel", "proxy + emitter"])

    def test_each_panel_has_one_series_per_group_named_by_a_single_word(self):
        for panel in self.figure["panels"]:
            names = [s["name"] for s in panel["series"]]
            self.assertEqual(sorted(names), ["coop", "link", "none"])
            for name in names:
                self.assertNotIn(" ", name)          # a series label, not a legend entry

    def test_the_kernel_panel_rises_with_offered_rate_for_a_sampling_group(self):
        panel = next(p for p in self.figure["panels"] if p["panel"] == "kernel")
        coop = next(s for s in panel["series"] if s["name"] == "coop")
        values = [y for _x, y in coop["points"]]
        self.assertEqual(values, sorted(values))
        none = next(s for s in panel["series"] if s["name"] == "none")
        self.assertAlmostEqual(max(y for _x, y in none["points"]), synthetic.KERNEL_BASE, delta=0.2)

    def test_the_x_axis_is_the_offered_rate(self):
        self.assertIn("kpps", self.figure["xlabel"])


class Figure3EndLabelTest(unittest.TestCase):
    """Figure 3's end-of-line labels, against the three values that overprinted.

    🔴 REAL NUMBERS, NOT CHOSEN ONES. These are the bmv2 panel's three end values at 110 kpps in
    raw/2026-09-19T105759Z_full/summary.json -- `cpu_bmv2.per_group.<group>.110.0.cpu` -- and the
    panel's lowest plotted value, which is where its axis starts. On that axis `coop` sits 38.9
    units above the other two: less than one label height, and 33 times more than 3% of the
    spread of the ends. That is the whole gap between the two rules.
    """
    #: cpu_bmv2.per_group.{none,cooperative,link}.110.0.cpu
    NONE_110 = 725.9226502651313
    COOP_110 = 764.8565261656065
    LINK_110 = 725.9201358978246
    #: the lowest value the same panel plots (link at 1 kpps), i.e. where the axis begins
    PANEL_LOW = 26.929742535323893

    def ends(self):
        return [(self.NONE_110, 110.0, "none"), (self.COOP_110, 110.0, "coop"),
                (self.LINK_110, 110.0, "link")]

    def test_three_ends_within_a_label_height_get_three_different_offsets(self):
        # The axes height is only known at draw time and depends on the figure's layout, so the
        # rule has to hold for any plausible height of a 4.2 inch panel rather than for one
        # number. At every one of these the three labels are inside one label height of each
        # other, and all three must be readable.
        for height_points in (160.0, 200.0, 216.0, 260.0):
            placed = plot.end_label_offsets(self.ends(), (self.PANEL_LOW, self.COOP_110),
                                            height_points)
            self.assertEqual([p["name"] for p in placed], ["link", "none", "coop"])
            offsets = {round(p["offset"], 6) for p in placed}
            self.assertEqual(len(offsets), 3,
                             "height %.0f pt: offsets %s" % (height_points, offsets))
            positions = [p["display_points"] for p in placed]
            for lower, upper in zip(positions, positions[1:]):
                self.assertGreaterEqual(
                    upper - lower, plot.LABEL_HEIGHT_PT - 1e-9,
                    "height %.0f pt: labels %.2f pt apart" % (height_points, upper - lower))

    def test_ends_that_are_far_apart_on_the_display_are_not_moved_at_all(self):
        # The control: a rule that staggered everything would be as wrong as one that staggered
        # nothing. These are the same summary's proxy+emitter ends (2.53 / 19.60 / 50.05) on
        # their own panel, tens of points apart.
        ends = [(2.532826735438453, 110.0, "none"), (19.59605387800606, 110.0, "link"),
                (50.045406725202014, 110.0, "coop")]
        placed = plot.end_label_offsets(ends, (2.1997066910093843, 50.045406725202014), 216.0)
        self.assertEqual([p["offset"] for p in placed], [0.0, 0.0, 0.0])


class Figure3LabelsStayInsideTest(unittest.TestCase):
    """Every end label must sit inside its own axes -- on all three real panels.

    🔴 THESE ARE THE THREE PANELS OF THE FOURTH CAMPAIGN'S FIGURE 3, with their real data range
    and their real ends (`cpu_bmv2` / `cpu_kernel` per_group at 110 kpps, and the lowest value
    each panel plots). The axes height 206.5 pt is what the real figure measured
    (question-a-label-headroom.p3e-f51ee88f.log). Ruling 35(2): staggering the labels apart
    pushed the bmv2 panel's top label 8.2 pt out of the axes and onto the panel title.
    """
    HEIGHT_PT = 206.5
    #: matplotlib's default autoscale margin, which is what produced the measured ylim below
    MARGIN = 0.05
    #: panel -> (lowest plotted value, [(y, x, name) at the right-hand end], measured ylim)
    PANELS = {
        "bmv2": (26.929742535323893,
                 [(725.9201358978246, 110.0, "link"), (725.9226502651313, 110.0, "none"),
                  (764.8565261656065, 110.0, "coop")], (-9.97, 801.75)),
        "kernel": (0.5999161507799824,
                   [(0.6665244667410422, 110.0, "none"), (14.250486351297475, 110.0, "coop"),
                    (15.26358265135838, 110.0, "link")], (-0.13, 16.00)),
        "proxy + emitter": (2.1997066910093843,
                            [(2.532826735438453, 110.0, "none"),
                             (19.59605387800606, 110.0, "link"),
                             (50.045406725202014, 110.0, "coop")], (-0.19, 52.44)),
    }

    def autoscaled(self, low_value, ends):
        """The ylim matplotlib gives a panel whose data runs from low_value to its highest end."""
        high_value = max(y for y, _x, _n in ends)
        span = high_value - low_value
        return (low_value - self.MARGIN * span, high_value + self.MARGIN * span)

    def test_the_computed_axes_match_the_ones_the_real_figure_drew(self):
        # 🔴 The geometry this class reasons about is pinned to a measurement, not assumed: if
        # matplotlib's autoscale ever stops producing these limits, this case says so before the
        # containment cases below start testing a figure nobody draws.
        for panel, (low_value, ends, measured) in self.PANELS.items():
            computed = self.autoscaled(low_value, ends)
            self.assertAlmostEqual(computed[0], measured[0], places=2, msg=panel)
            self.assertAlmostEqual(computed[1], measured[1], places=2, msg=panel)

    def test_no_label_is_drawn_above_the_top_of_its_own_axes(self):
        for panel, (low_value, ends, _measured) in self.PANELS.items():
            original = self.autoscaled(low_value, ends)
            ylim, placed = plot.place_end_labels(ends, original, self.HEIGHT_PT)
            for label in placed:
                glyph_top = label["display_points"] + plot.LABEL_HEIGHT_PT / 2.0
                # the tolerance is a millionth of a point: float noise in the solved limit, not
                # a claim about anything a reader could see.
                self.assertLessEqual(
                    glyph_top, self.HEIGHT_PT + 1e-6,
                    "%s: %s's label top is %.1f pt on a %.1f pt axes"
                    % (panel, label["name"], glyph_top, self.HEIGHT_PT))
            # and they are still a label height apart, which is what the room was made for
            positions = [p["display_points"] for p in placed]
            for lower, upper in zip(positions, positions[1:]):
                self.assertGreaterEqual(upper - lower, plot.LABEL_HEIGHT_PT - 1e-9, panel)
            # room is only ever ADDED at the top, and the bottom is never moved
            self.assertGreaterEqual(ylim[1], original[1] - 1e-9, panel)
            self.assertAlmostEqual(ylim[0], original[0], places=9, msg=panel)

    def test_only_the_panel_that_needs_room_is_given_any(self):
        # The control: a rule that inflated every axis would be as wrong as one that inflated
        # none. Only bmv2 has labels within a label height of each other at the top.
        for panel, (low_value, ends, _measured) in self.PANELS.items():
            original = self.autoscaled(low_value, ends)
            ylim, _placed = plot.place_end_labels(ends, original, self.HEIGHT_PT)
            if panel == "bmv2":
                self.assertGreater(ylim[1], original[1], panel)
            else:
                self.assertAlmostEqual(ylim[1], original[1], places=9, msg=panel)


class DescribeTest(unittest.TestCase):
    def test_check_mode_prints_every_figure_without_matplotlib(self):
        import io
        summary, tmp = build_summary()
        self.addCleanup(tmp.cleanup)
        buffer = io.StringIO()
        plot.describe(plot.figure_data(summary), buffer)
        text = buffer.getvalue()
        for name in plot.FIGURES:
            self.assertIn(name, text)
        self.assertIn("n/a", text)                   # the none cells survive into the output


class RenderTest(unittest.TestCase):
    def test_render_writes_a_png_and_a_pdf_for_each_figure(self):
        try:
            import matplotlib                        # noqa: F401
        except ImportError:
            self.skipTest("this interpreter has no matplotlib; run this case under one that has")
        summary, tmp = build_summary()
        self.addCleanup(tmp.cleanup)
        out = tempfile.TemporaryDirectory()
        self.addCleanup(out.cleanup)
        written = plot.render(summary, out.name)
        for name in plot.FIGURES:
            for extension in ("png", "pdf"):
                path = os.path.join(out.name, "%s.%s" % (name, extension))
                self.assertIn(path, written)
                self.assertGreater(os.path.getsize(path), 1000)


class SummaryIsTheOnlyInputTest(unittest.TestCase):
    def test_plot_never_reads_the_raw_tree(self):
        # 🔴 Every number on a figure has to have passed through analyse.py, which the tests
        # cover. A figure that recomputed its own would be a second, untested analysis -- and
        # 08-20 found two disagreements precisely by checking a figure against its report.
        with open(os.path.join(os.path.dirname(HERE), "plot.py")) as fh:
            source = fh.read()
        for forbidden in ("walk_raw", "arm.meta", "cpu.jsonl", "ladder.tsv", "window.json"):
            self.assertNotIn(forbidden, source)

    def test_figures_are_built_from_a_json_round_trip(self):
        # summary.json is what plot.py is handed on the command line, so the data must survive
        # being written and read: a tuple key or a non-string dict key would not.
        summary, tmp = build_summary()
        self.addCleanup(tmp.cleanup)
        round_tripped = json.loads(json.dumps(summary, default=str))
        self.assertEqual(plot.figure_data(round_tripped)["fig1_pps_ceiling"],
                         plot.figure_data(summary)["fig1_pps_ceiling"])


if __name__ == "__main__":
    unittest.main()
