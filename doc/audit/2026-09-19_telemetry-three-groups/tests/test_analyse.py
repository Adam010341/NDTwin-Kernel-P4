#!/usr/bin/env python3
"""
Tests for analyse.py against synthetic raw whose correct answers are known in advance.

[Co-developed with claude code -- Adam]

Every case here exists because a mutation can make it go red -- see mutate_analyse.sh, which
names the case each mutation must kill. A test nobody has seen fail is a decoration, and this
file is where the round's registered branches (PREREG sections 5, 6, 8) stop being prose.

Run:  p4_proxy/venv/bin/python -m unittest discover -s doc/audit/2026-09-19_telemetry-three-groups/tests
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
import synthetic                                     # noqa: E402


class MetaParsingTest(unittest.TestCase):
    def test_a_value_with_a_trailing_comment_still_parses_as_its_number(self):
        # `external=-1  # no samples` is a line run_group_arm.sh really writes, and reading it
        # as "unparseable" would turn a declared failure into a silent absence.
        meta = analyse.parse_meta("external=-1  # no samples\nclean=0.5\n")
        self.assertEqual(analyse.as_float(meta["external"]), -1.0)
        self.assertEqual(analyse.as_float(meta["clean"]), 0.5)

    def test_an_absent_counter_is_not_zero(self):
        self.assertIsNone(analyse.as_int("absent"))
        self.assertIsNone(analyse.as_int("absent", None))


class CellTableTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        synthetic.build(self.tmp.name)
        self.arms, self.windows, self.controls = analyse.walk_raw(self.tmp.name)
        self.cells = analyse.cell_table(self.arms)

    def tearDown(self):
        self.tmp.cleanup()

    def test_every_arm_was_found_and_none_of_them_is_invalid(self):
        # twelve measurement arms plus C3's two throwaway ladders: fourteen arm.meta files, which
        # is what a full round really writes (raw/2026-09-19T105759Z_full has exactly these).
        self.assertEqual(len(self.arms), 14)
        self.assertEqual([a["arm"] for a in self.arms if a["invalid"]], [])

    def test_the_two_C3_throwaway_ladders_are_found_and_tagged_as_controls(self):
        # 🔴 FOUND, AND TAGGED. Both halves matter: they must be read (they are raw, and an
        # analysis that skipped a directory would be hiding it) and they must be distinguishable
        # from a measurement arm, because they declare `group=none frame_bytes=1024` exactly as
        # one does. Everything else in this file rests on that one bit.
        self.assertEqual(len(self.arms), 14)
        self.assertEqual(sorted(a["arm"] for a in self.arms if a.get("control")),
                         ["c3a_noburn", "c3b_burn"])
        for arm in self.arms:
            self.assertIn("control", arm)
            if arm["arm"].startswith("c3"):
                continue
            self.assertFalse(arm["control"], arm["arm"])

    def test_the_none_1024_cell_is_the_two_ladder_arms_only(self):
        # 🔴 THE DEFECT, AS A NUMBER. The fourth campaign's summary.json read
        #   "none|1024": n=4, mean=21.0, arms {c3a_noburn: 12, c3b_burn: 12,
        #                                      none_f1024_a: 30, none_f1024_b: 30}
        # -- an unresolved cell (rung gap 2), a figure-1 label of `21.0* (12/12/30/30)`, both
        # 1024 B ratios pushed to H-A0 and reconciliation (a) comparing 21.0 against 16.0.
        cell = self.cells[("none", 1024)]
        self.assertEqual(sorted(cell["arms"]), ["none_f1024_a", "none_f1024_b"])
        self.assertEqual(cell["n"], 2)
        self.assertAlmostEqual(cell["mean"], 20.0)
        self.assertTrue(cell["resolved"])
        self.assertEqual(cell["rung_gap"], 0)

    def test_a_cell_whose_arms_are_one_rung_apart_is_resolved(self):
        cell = self.cells[("cooperative", 1024)]
        self.assertEqual(cell["rung_gap"], 1)
        self.assertTrue(cell["resolved"])
        self.assertAlmostEqual(cell["mean"], 16.0)

    def test_a_cell_whose_arms_are_six_rungs_apart_is_NOT_resolved(self):
        # PREREG 5.1's H-A0 branch, which 1b section 4 says every ratio round must register:
        # averaging 1 and 20 produces a number no arm measured and no repeat would reproduce.
        cell = self.cells[("link", 64)]
        self.assertEqual(cell["rung_gap"], 6)
        self.assertFalse(cell["resolved"])


class CeilingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        synthetic.build(self.tmp.name)
        arms, _windows, _controls = analyse.walk_raw(self.tmp.name)
        self.rows = analyse.ceiling_comparisons(analyse.cell_table(arms))

    def tearDown(self):
        self.tmp.cleanup()

    def row(self, group, frame):
        return next(r for r in self.rows if r["group"] == group and r["frame"] == frame)

    def test_a_ratio_inside_one_realised_rung_is_H_A1(self):
        row = self.row("cooperative", 1024)
        self.assertAlmostEqual(row["ratio"], 0.8)
        self.assertTrue(row["verdict"].startswith("H-A1"))

    def test_a_ratio_below_the_registered_interval_is_H_A2(self):
        row = self.row("link", 1024)
        self.assertAlmostEqual(row["ratio"], 0.4)
        self.assertTrue(row["verdict"].startswith("H-A2"))

    def test_an_unresolved_cell_produces_NO_ratio_at_all(self):
        row = self.row("link", 64)
        self.assertIsNone(row["ratio"])
        self.assertTrue(row["verdict"].startswith("H-A0"))
        self.assertIn("rung", row["why_unresolved"])

    def test_the_interval_boundaries_are_the_realised_step_not_the_nominal_one(self):
        self.assertEqual((analyse.RATIO_LO, analyse.RATIO_HI), (0.60, 1.67))
        self.assertTrue(analyse.ratio_verdict(0.61).startswith("H-A1"))
        self.assertTrue(analyse.ratio_verdict(0.59).startswith("H-A2"))
        self.assertTrue(analyse.ratio_verdict(1.68).startswith("H-A3"))


class SamplingErrorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        synthetic.build(self.tmp.name)
        _arms, self.windows, _controls = analyse.walk_raw(self.tmp.name)
        self.rows = analyse.sampling_summary(self.windows)

    def tearDown(self):
        self.tmp.cleanup()

    def row(self, group, rate):
        return next(r for r in self.rows
                    if r["group"] == group and r["offered_mbit"] == rate)

    def test_the_none_group_is_n_a_and_is_NOT_zero(self):
        # 🔴 PREREG 5.2. A zero would put an absence on the axis as a measurement.
        row = self.row("none", 20)
        self.assertIsNone(row["median_abs_error"])
        self.assertIsNone(row["median_signed_error"])
        self.assertIn("n/a", row["note"])

    def test_N_counts_the_edges_that_carried_the_flow_not_every_edge_in_the_fabric(self):
        # 🔴 PREREG 5.2 REGISTERS FOUR EDGES, AND THE FIXTURE NOW HAS THE REAL SHAPE: 32 keys
        # (every inter-switch port of the ten switches) and 4 per-edge peaks (the ones the flow
        # crossed). Counting `keys` made N eight times too large, the predicted median 2.83x
        # too tight, and five of the fourth campaign's six treated cells "above the band" when
        # they were inside it. At 2 Mbit/s over 1400 B payloads for 8 s, N = 4 x 178.571 x 8 /
        # 256 = 22.32 and the prediction is 0.674 / sqrt(22.32) = 0.1427.
        row = self.row("cooperative", 2)
        self.assertAlmostEqual(row["predicted"]["n_samples"], 22.32, places=2)
        self.assertAlmostEqual(row["predicted"]["median_abs"], 0.1427, places=4)
        self.assertEqual(row["links_used"], 4)
        self.assertEqual(row["keys_total"], 32)
        self.assertIsNone(row["links_note"])          # it agrees with PREREG, so nothing to say

    def test_a_group_with_no_twin_readings_falls_back_to_the_registered_four_and_says_so(self):
        # The `none` windows have an EMPTY per_edge_peak_bps -- nothing was ever seen to carry
        # anything -- so the count cannot be measured there. Falling back is allowed; doing it
        # silently is not.
        row = self.row("none", 2)
        self.assertEqual(row["links_used"], analyse.DEFAULT_ONPATH_LINKS)
        self.assertEqual(row["keys_total"], 32)
        self.assertIn("no edge reported traffic", row["links_note"])
        self.assertIn("registered 4", row["links_note"])

    def test_a_fabric_where_more_edges_carried_the_flow_is_reported_not_hidden(self):
        # The other half of the same rule: when the measurement disagrees with PREREG's 4, the
        # row says which edges and how many, instead of quietly using a different number.
        window = {"keys": ["e%d" % i for i in range(32)], "payload_bytes": 1400,
                  "duration_s": 8.0,
                  "per_edge_peak_bps": {"s1-eth2": 10.0, "s6-eth4": 10.0, "s8-eth2": 10.0,
                                        "s10-eth4": 10.0, "s5-eth1": 10.0, "s9-eth2": 0}}
        links, keys_total, note = analyse.links_for_prediction(window)
        self.assertEqual((links, keys_total), (5, 32))
        self.assertIn("5 edges carried the flow, not the 4", note)
        self.assertIn("s5-eth1", note)

    def test_the_shot_noise_prediction_is_the_registered_formula(self):
        predicted = analyse.shot_noise_prediction(20, 1400, 8.0, links=4, divisor=256)
        self.assertAlmostEqual(predicted["n_samples"], 223.214, places=2)
        self.assertAlmostEqual(predicted["median_abs"], 0.0451, places=4)

    # 🔴 A CELL GETS A DESCRIPTION, NEVER A REGISTERED LABEL (ruling 38). These two cases used to
    # be called `..._is_H_B1` / `..._is_H_B2` and asserted exactly the per-cell labelling that
    # PREREG 5.2 does not register: H-B1 is registered over the three rates together and H-B2 at
    # 100 Mbit/s only. What a cell can honestly say is where it sits against its own band.
    def test_an_error_at_the_prediction_is_described_as_inside_the_band(self):
        row = self.row("cooperative", 20)
        self.assertAlmostEqual(row["median_abs_error"], 0.045, places=6)
        self.assertEqual(row.get("description"), "inside the shot-noise band")

    def test_an_error_far_above_the_band_with_one_sign_is_described_as_such(self):
        row = self.row("link", 20)
        self.assertAlmostEqual(row["median_abs_error"], 0.150, places=6)
        self.assertEqual(row.get("description"),
                         "above the shot-noise band, every window the same sign")
        self.assertLess(row["median_signed_error"], 0)   # the prior is that the twin reads LOW


class RegisteredLevelTest(unittest.TestCase):
    """Ruling 38: each registered H-B label is made at the level PREREG 5.2 registers it.

    PREREG 5.2 (`PREREG.md:251-254`):
      H-B1  "三個速率的 median|ratio-1| 都落在 [0.5, 2.0] x 0.674/sqrt(N)"  -- the three rates TOGETHER
      H-B2  "100 Mbit/s 那格 > 2.0x 預測, 且 三個視窗的 ratio-1 同號"        -- ONE rate, with a sign rule
      H-B4  "E(link,r)/E(coop,r) in [0.5, 2.0], 三個速率都是"                 -- the three rates TOGETHER
    The analysis used to paste those labels on every (group, rate) cell. The cell keeps a
    description -- that is data -- and the label is decided once per group.

    The per-rate errors below are chosen against the registered prediction at N over the four
    on-path edges: 0.1427 at 2 Mbit/s, 0.0451 at 20 and 0.0202 at 100 (band = [0.5, 2.0] x that).
    """

    def summary(self, **kwargs):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name, **kwargs)
        return analyse.analyse(tmp.name)

    @staticmethod
    def cells(summary, group):
        return {row["offered_mbit"]: row for row in summary["sampling_error"]
                if row["group"] == group}

    @staticmethod
    def registered(summary):
        # .get(), deliberately: on a tree with no group level at all this has to FAIL with the
        # finding in its message, not ERROR with a KeyError that says nothing about it.
        return {row["group"]: row for row in summary.get("sampling_error_by_group") or []}

    def group(self, summary, name):
        registered = self.registered(summary)
        self.assertIn(name, registered,
                      "no registered H-B label at the group level at all -- PREREG 5.2 "
                      "registers H-B1 over the three rates together")
        return registered[name]

    def description(self, summary, group, rate):
        return self.cells(summary, group)[rate].get("description")

    def test_two_rates_inside_and_one_outside_is_NOT_H_B1_for_the_group(self):
        # 🔴 THE CASE RULING 38 NAMES. 2 and 20 Mbit/s sit on the prediction; 100 Mbit/s is three
        # times it with mixed signs. The outside rate is deliberately NOT the first one: a
        # roll-up that consulted only the first cell would call this group H-B1 (M-E37).
        summary = self.summary(coop_error={2: 0.1427, 20: 0.0451,
                                           100: (-0.0606, 0.0606, -0.0667)})
        group = self.group(summary, "cooperative")
        self.assertIs(group["H-B1"]["holds"], False)
        self.assertIs(group["H-B2"]["holds"], False)          # 100 M is above, but signs mix
        self.assertFalse(group["label"].startswith("H-B1"), group["label"])
        # ... and every cell is still described correctly, on its own terms
        self.assertEqual(self.description(summary, "cooperative", 2), "inside the shot-noise band")
        self.assertEqual(self.description(summary, "cooperative", 20), "inside the shot-noise band")
        self.assertEqual(self.description(summary, "cooperative", 100),
                         "above the shot-noise band, signs mixed")

    def test_the_fifth_campaigns_shape_outside_at_the_FIRST_rate_is_not_H_B1_either(self):
        # The other placement, and the real one: raw/2026-09-19T115737Z_full's cooperative 2 M
        # windows read -0.3508, -0.2953, +0.1865 (median 0.2953, above the 0.285318 top of the
        # band -- 2 x 0.674/sqrt(22.3214); it read "0.2854" until ruling 40(e)) while 20 and
        # 100 Mbit/s are inside. A roll-up that looked at the LAST cell only
        # would call this H-B1.
        summary = self.summary(coop_error={2: (-0.3508, -0.2953, 0.1865), 20: 0.0451,
                                           100: 0.0202})
        group = self.group(summary, "cooperative")
        self.assertIs(group["H-B1"]["holds"], False)
        self.assertEqual(self.description(summary, "cooperative", 2),
                         "above the shot-noise band, signs mixed")

    def test_all_three_rates_inside_IS_H_B1(self):
        # the positive control: a roll-up that never said H-B1 would pass both cases above
        summary = self.summary(coop_error={2: 0.1427, 20: 0.0451, 100: 0.0202})
        group = self.group(summary, "cooperative")
        self.assertIs(group["H-B1"]["holds"], True)
        self.assertTrue(group["label"].startswith("H-B1"), group["label"])
        self.assertEqual([rate["offered_mbit"] for rate in group["H-B1"]["rates"]],
                         [2, 20, 100])

    def test_a_same_sign_excess_at_2_Mbit_is_NOT_H_B2(self):
        # 🔴 THE FOURTH CAMPAIGN'S PRE-FIX `link 2M: H-B2`, AS A CASE. Every window low and far
        # above the band -- at 2 Mbit/s, where H-B2 was never registered. The cell may say what
        # it is; the group is judged at 100 Mbit/s, which is inside here (M-E38).
        summary = self.summary(coop_error={2: 0.5, 20: 0.0451, 100: 0.0202})
        self.assertEqual(self.description(summary, "cooperative", 2),
                         "above the shot-noise band, every window the same sign")
        h_b2 = self.group(summary, "cooperative")["H-B2"]
        self.assertEqual(h_b2["offered_mbit"], 100)
        self.assertIs(h_b2["holds"], False)

    def test_a_100_Mbit_cell_with_only_two_valid_windows_cannot_be_H_B2(self):
        # 🔴 ruling 40(c): PREREG :252 is "三個視窗的 ratio-1 同號" -- THREE windows of one sign.
        # The same excess as the positive case below, with one of the three windows invalid:
        # two same-sign windows do not satisfy it, however far above the band they are. (M-E46)
        summary = self.summary(coop_error={2: 0.1427, 20: 0.0451, 100: 0.0606},
                               invalid_windows={("cooperative", 100, "p3")})
        cell = self.cells(summary, "cooperative")[100]
        self.assertEqual(cell["windows"], 2)
        self.assertEqual(cell.get("description"),
                         "above the shot-noise band, every window the same sign")
        group = self.group(summary, "cooperative")
        self.assertIs(group["H-B2"]["holds"], False, group["H-B2"])
        self.assertFalse(group["label"].startswith("H-B2"), group["label"])

    def test_a_registered_rate_with_no_reading_leaves_the_group_not_decided(self):
        # every 20 Mbit/s window of the group invalid: that registered rate has no cell at all,
        # and the other two are inside. Missing is not inside -- H-B1 is not decided. (M-E47)
        summary = self.summary(coop_error={2: 0.1427, 20: 0.0451, 100: 0.0202},
                               invalid_windows={("cooperative", 20, label)
                                                for label in ("p1", "p2", "p3")})
        self.assertNotIn(20, self.cells(summary, "cooperative"))
        group = self.group(summary, "cooperative")
        self.assertIsNone(group["H-B1"]["holds"])
        self.assertTrue(group["label"].startswith("not decided"), group["label"])

    def test_one_signed_excess_at_100_Mbit_IS_H_B2(self):
        summary = self.summary(coop_error={2: 0.1427, 20: 0.0451, 100: 0.0606})
        group = self.group(summary, "cooperative")
        self.assertIs(group["H-B2"]["holds"], True)
        self.assertIs(group["H-B1"]["holds"], False)
        self.assertTrue(group["label"].startswith("H-B2"), group["label"])

    def test_H_B4_needs_all_three_rates_and_each_rate_keeps_its_description(self):
        # link equal to coop at 2 and 20 Mbit/s, three times it at 100: two rates inside
        # [0.5, 2.0] and one outside, the outside one again not first.
        summary = self.summary(coop_error={2: 0.1427, 20: 0.0451, 100: 0.0202},
                               link_error={2: 0.1427, 20: 0.0451, 100: 0.0606})
        cross = summary.get("sampling_error_cross_group_registered") or {}
        self.assertIs(cross.get("holds"), False, cross)
        self.assertFalse((cross.get("label") or "").startswith("H-B4"), cross)
        rows = {row["offered_mbit"]: row for row in summary["sampling_error_cross_group"]}
        self.assertEqual([rows[r].get("inside") for r in (2, 20, 100)], [True, True, False])

    def test_H_B4_holds_when_all_three_rates_are_inside(self):
        summary = self.summary(coop_error={2: 0.1427, 20: 0.0451, 100: 0.0202},
                               link_error={2: 0.1427, 20: 0.0451, 100: 0.0202})
        cross = summary.get("sampling_error_cross_group_registered") or {}
        self.assertIs(cross.get("holds"), True, cross)
        self.assertTrue(cross["label"].startswith("H-B4"), cross["label"])

    def test_no_cell_or_rate_row_carries_a_label_registered_at_the_group_level(self):
        # 🔴 FINDINGS may quote only the group-level verdicts (ruling 38); a per-cell string that
        # still read "H-B1 ..." would be one copy-paste away from being quoted as one. H-B3 is
        # the exception PREREG itself makes: it is registered per rate ("在該視窗").
        summary = self.summary()
        for row in summary["sampling_error"] + summary["sampling_error_cross_group"]:
            for key, value in row.items():
                if not isinstance(value, str) or key == "attribution":
                    continue
                for label in ("H-B1", "H-B2", "H-B4"):
                    self.assertNotIn(label, value, "%s=%r in %s" % (key, value, row))

    def test_summary_json_carries_the_cell_descriptions_AND_the_group_verdicts(self):
        # both, so a reader can see that "this cell's description" and "this group's registered
        # verdict" are two different things
        summary = json.loads(json.dumps(self.summary(), default=str))
        self.assertTrue(all("description" in row for row in summary["sampling_error"]
                            if row["group"] != "none"))
        self.assertEqual(sorted(row["group"] for row in summary["sampling_error_by_group"]),
                         ["cooperative", "link"])
        self.assertIn("holds", summary["sampling_error_cross_group_registered"])


class EmitterAttributionTest(unittest.TestCase):
    def test_the_last_statistics_line_wins(self):
        counters = analyse.emitter_drops(
            "psample_sflow_emitter: samples=1 emitted=1 enobufs=0 elapsed=10.0s\n"
            "psample_sflow_emitter: samples=99 emitted=98 dropped_decode_error=1 enobufs=7 "
            "elapsed=20.0s\n")
        self.assertEqual(counters["samples"], 99)
        self.assertEqual(counters["enobufs"], 7)

    def test_sample_loss_is_NOT_attributed_when_every_drop_counter_is_zero(self):
        # 🔴 ROLE-5's finding as a test: a mechanism that was not observed does not enter a
        # verdict. The link group is three times worse here and the counters are all zero.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name, emitter_dropped=0)
        arms, windows, _controls = analyse.walk_raw(tmp.name)
        counters = {}
        for arm in arms:
            path = os.path.join(arm["dir"], "emitter.log")
            if os.path.exists(path):
                with open(path) as fh:
                    for key, value in analyse.emitter_drops(fh.read()).items():
                        counters[key] = counters.get(key, 0) + value
        rows = analyse.link_vs_cooperative(analyse.sampling_summary(windows), counters)
        row = next(r for r in rows if r["offered_mbit"] == 20)
        self.assertGreater(row["ratio"], 2.0)
        self.assertIn("NOT attributed", row["attribution"])

    def test_sample_loss_IS_attributed_once_a_drop_counter_has_moved(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name, emitter_dropped=250)
        arms, windows, _controls = analyse.walk_raw(tmp.name)
        counters = {}
        for arm in arms:
            path = os.path.join(arm["dir"], "emitter.log")
            if os.path.exists(path):
                with open(path) as fh:
                    for key, value in analyse.emitter_drops(fh.read()).items():
                        counters[key] = counters.get(key, 0) + value
        rows = analyse.link_vs_cooperative(analyse.sampling_summary(windows), counters)
        row = next(r for r in rows if r["offered_mbit"] == 20)
        self.assertIn("H-B3", row["attribution"])


class CpuTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        synthetic.build(self.tmp.name)
        self.arms, _windows, _controls = analyse.walk_raw(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_process_alive_before_the_window_is_not_charged_its_lifetime(self):
        # 🔴 The single arithmetic error that would make every CPU number meaningless: the
        # kernel's first reading inside a window is a lifetime total, and adding it charges
        # hours of CPU to eight seconds. The synthetic kernel sits at exactly 10% under `none`.
        arm = next(a for a in self.arms if a["arm"] == "none_f1024_a")
        by_rung = analyse.cpu_by_rung(arm)
        self.assertTrue(by_rung)
        for measured in by_rung.values():
            self.assertAlmostEqual(measured["kernel"], synthetic.KERNEL_BASE, places=3)

    def test_the_ten_bmv2_processes_are_folded_into_one_class_and_SUMMED(self):
        # 🔴 THE FOLD, ASSERTED (ruling 37(4)). label_of() turns ten pids into one class and
        # cpu_for_window sums them; every bmv2 number in the round goes through it, and in
        # production it always has -- a real cpu.jsonl has carried ten bmv2 pids all along.
        # What had never happened is a TEST executing it: the fixture wrote one process, and
        # when it grew to ten it gave them equal shares, which makes "sum the ten" and "take
        # one and multiply by ten" the same function. The weights are unequal now, so only a
        # real sum gives the total.
        arm = next(a for a in self.arms if a["arm"] == "none_f1024_a")
        by_rung = analyse.cpu_by_rung(arm)
        self.assertTrue(by_rung)
        for kpps, measured in by_rung.items():
            self.assertAlmostEqual(measured["bmv2"], synthetic.BMV2_BASE, places=3,
                                   msg="rung %s" % kpps)
        # and the fixture cannot make the two arithmetics agree by accident
        self.assertEqual(len(set(synthetic.BMV2_WEIGHTS)), 10)
        self.assertNotAlmostEqual(max(synthetic.BMV2_WEIGHTS) * 10.0, synthetic.BMV2_BASE)
        self.assertEqual(sum(synthetic.BMV2_WEIGHTS), synthetic.BMV2_BASE)

    def test_a_process_that_appears_inside_the_window_IS_charged_from_zero(self):
        rows = [
            {"t": 0.0, "machine": {"user": 0, "nice": 0, "system": 0, "idle": 0, "iowait": 0,
                                   "irq": 0, "softirq": 0, "steal": 0},
             "proc": {"kernel:1": 100000}},
            {"t": 1.0, "machine": {"user": 0, "nice": 0, "system": 0, "idle": 100, "iowait": 0,
                                   "irq": 0, "softirq": 0, "steal": 0},
             "proc": {"kernel:1": 100010, "iperf3:9": 40}},
            {"t": 2.0, "machine": {"user": 0, "nice": 0, "system": 0, "idle": 200, "iowait": 0,
                                   "irq": 0, "softirq": 0, "steal": 0},
             "proc": {"kernel:1": 100020, "iperf3:9": 120}},
        ]
        measured = analyse.cpu_for_window(rows, 100, 0.0, 2.0)
        self.assertAlmostEqual(measured["kernel"], 10.0)     # 20 jiffies over 2 s of one core
        self.assertAlmostEqual(measured["iperf3"], 60.0)     # 120 jiffies, all of them inside

    def test_samples_per_second_comes_from_the_rung_pair_not_from_the_offered_rate(self):
        # 🔴 ASSERTED ON THE LINK ARM ON PURPOSE. The link path has one more sampling point than
        # the cooperative one (the host-facing egress filter), and LLDP/ARP add a background the
        # offered rate does not predict -- so the counter and the naive `5 * pps / 256` disagree.
        # On a fixture where they agreed, "read the counter" and "assume the formula" would be
        # the same function and the mutation swapping them would be equivalent. It was, once.
        arm = next(a for a in self.arms if a["arm"] == "link_f1024_a")
        measured = analyse.rung_samples_per_second(arm, 20.0)
        self.assertAlmostEqual(measured, synthetic.samples_per_second(20, "link"), places=1)
        naive = 5 * 20 * 1000.0 / 256.0
        self.assertNotAlmostEqual(measured, naive, places=1)

    def test_the_fit_recovers_the_fixed_and_marginal_costs_and_calls_it_H_C1(self):
        comparison = analyse.cpu_comparison(self.arms, frame=1024, label="kernel")
        entry = comparison["fits"]["cooperative"]
        self.assertIsNotNone(entry["fit"], entry["verdict"])
        # The tolerances are the instrument's, not slack: /proc reports whole jiffies, so a
        # percentage recovered over an 8 s window is quantised at 100/(clk_tck * 8) = 0.125
        # points, and the fixture writes integer jiffies for that reason. Asserting to more
        # places than the counter carries would be asserting the fixture's rounding.
        self.assertAlmostEqual(entry["fit"]["fixed_percent"], synthetic.KERNEL_FIXED, delta=0.2)
        self.assertAlmostEqual(entry["fit"]["marginal_us_per_sample"], 206.0, delta=10.0)
        self.assertTrue(entry["verdict"].startswith("H-C1"))

    def test_a_delta_smaller_than_its_spread_is_H_C0_and_no_line_is_fitted(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        # 40 points of swing between the two arms of every cell: larger than any Delta here.
        synthetic.build(tmp.name, kernel_spread=40.0)
        arms, _windows, _controls = analyse.walk_raw(tmp.name)
        comparison = analyse.cpu_comparison(arms, frame=1024, label="kernel")
        entry = comparison["fits"]["cooperative"]
        self.assertIsNone(entry["fit"])
        self.assertTrue(entry["verdict"].startswith("H-C0"))

    def test_the_cpu_verdict_names_a_mixed_decomposition_as_a_result(self):
        # share = 3.0 / (3.0 + 0.09*100) = 0.25: above H-C2's 0.2 and below H-C1's 0.5, with a
        # marginal outside [103, 618] us/sample. That is the band PREREG 5.3 calls a RESULT.
        mixed = {"fixed_percent": 3.0, "marginal_percent_per_sample": 0.09,
                 "marginal_us_per_sample": 900.0, "points": 3, "max_samples_per_s": 100.0}
        self.assertTrue(analyse.cpu_verdict(mixed).startswith("H-C3"))
        per_sample = {"fixed_percent": 0.1, "marginal_percent_per_sample": 0.09,
                      "marginal_us_per_sample": 900.0, "points": 3, "max_samples_per_s": 1000.0}
        # 🔴 ruling 40(a): this used to assert "H-C2", which is one of H-C2's two conditions
        self.assertTrue(analyse.cpu_verdict(per_sample).startswith("not decided: H-C2"))

    # --- ruling 40(a): H-C2 cannot be decided this round --------------------------------------
    # PREREG 5.3 :271 registers H-C2 as "F/(F+m*S_top) <= 0.2 且 Δ(高階)/Δ(低階) ≈ S(高)/S(低)".
    # The second condition has no registered tolerance, and choosing one after the data would be
    # deciding the hypothesis, so no string may start with "H-C2" while it is unevaluated.
    NOT_DECIDED = "not decided: H-C2 condition 1 holds (share <= 0.2); condition 2 (delta ratio ~ S ratio) has no registered tolerance"

    def fixture_comparison(self, **kwargs):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name, **kwargs)
        arms, _windows, _controls = analyse.walk_raw(tmp.name)
        return tmp.name, analyse.cpu_comparison(arms, frame=1024, label="kernel")

    def test_H_C2_is_NOT_DECIDED_while_its_second_condition_has_no_tolerance(self):
        # share = 0.1 / (0.1 + 0.09 x 1000) << 0.2 and m = 900 us/sample, outside H-C1's band:
        # exactly the fifth campaign's link shape. (M-E44)
        per_sample = {"fixed_percent": 0.1, "marginal_percent_per_sample": 0.09,
                      "marginal_us_per_sample": 900.0, "points": 3, "max_samples_per_s": 1000.0}
        verdict = analyse.cpu_verdict(per_sample)
        self.assertEqual(verdict, self.NOT_DECIDED)
        self.assertFalse(verdict.startswith("H-C2"), verdict)

    def test_the_fit_block_carries_both_H_C2_conditions_and_the_two_ratios(self):
        # a kernel whose fixed share is tiny and whose marginal is 900 us/sample
        _root, comparison = self.fixture_comparison(kernel_fixed=0.1, kernel_marginal=0.09)
        entry = comparison["fits"]["cooperative"]
        self.assertEqual(entry["verdict"], self.NOT_DECIDED)
        block = entry.get("H-C2")
        self.assertIsNotNone(block, "no machine-readable H-C2 block in the fit")
        self.assertIs(block["condition_1"], True)
        self.assertIsNone(block["condition_2"])
        self.assertLessEqual(block["share"], analyse.FIXED_SHARE_PER_SAMPLE)
        # the ratios are the lowest and the highest rung of the fit (PREREG 8(b) :357 names those
        # two points), reported and not judged
        rows = sorted((r for r in comparison["rows"] if r["group"] == "cooperative"),
                      key=lambda r: r["kpps"])
        self.assertEqual((block["low_kpps"], block["high_kpps"]), (rows[0]["kpps"], rows[-1]["kpps"]))
        self.assertAlmostEqual(block["delta_ratio"],
                               rows[-1]["delta_percent"] / rows[0]["delta_percent"])
        self.assertAlmostEqual(block["s_ratio"],
                               rows[-1]["samples_per_s"] / rows[0]["samples_per_s"])

    def test_when_H_C1_holds_the_block_still_says_H_C2_condition_1_held(self):
        # the fifth campaign's cooperative shape: m in [103, 618] (H-C1) AND share <= 0.2. The
        # label is H-C1, as registered, and FINDINGS must be able to disclose the other half.
        _root, comparison = self.fixture_comparison(kernel_fixed=0.1, kernel_marginal=0.0206)
        entry = comparison["fits"]["cooperative"]
        self.assertTrue(entry["verdict"].startswith("H-C1"), entry["verdict"])
        block = entry.get("H-C2")
        self.assertIsNotNone(block, "no machine-readable H-C2 block in the fit")
        self.assertIs(block["condition_1"], True)
        self.assertIsNone(block["condition_2"])

    def test_the_reconciliation_row_and_the_render_say_what_the_fit_says(self):
        import io
        root, _comparison = self.fixture_comparison(kernel_fixed=0.1, kernel_marginal=0.09)
        summary = analyse.analyse(root)
        fit_entry = summary["cpu_kernel"]["fits"]["cooperative"]
        row = next(r for r in summary["reconciliation"]
                   if r["id"] == "b" and r["group"] == "cooperative")
        self.assertEqual(row["verdict"], self.NOT_DECIDED)
        self.assertIsNotNone(row.get("H-C2"), "the reconciliation row carries no H-C2 block")
        self.assertEqual(row.get("H-C2"), fit_entry.get("H-C2"))
        buffer = io.StringIO()
        analyse.render(summary, buffer)
        self.assertIn(self.NOT_DECIDED, buffer.getvalue())
        self.assertNotIn("H-C2 cost is per sample", buffer.getvalue())

    def test_bmv2_gets_no_H_C0_either_when_no_rung_resolves(self):
        # 🔴 ruling 40(b): the round-10 fix kept H-C labels off bmv2's FIT, but the H-C0 branch
        # ran before the `registered` check, so a bmv2 panel whose arms disagree more than the
        # groups do still printed "H-C0 ...". Here the two arms of every cell differ by 150% of
        # one core (pass a at 1.5x, pass b at 0.5x) while the groups do not differ at all. (M-E45)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name, bmv2_spread=0.5)
        summary = analyse.analyse(tmp.name)
        bmv2 = summary["cpu_bmv2"]
        self.assertTrue(bmv2["rows"])
        self.assertFalse(any(row["resolved"] for row in bmv2["rows"]), "a rung resolved")
        for group, entry in bmv2["fits"].items():
            self.assertNotIn("H-C", entry.get("verdict") or "", group)
        # the kernel, on the same tree, keeps its registered label
        self.assertTrue(summary["cpu_kernel"]["fits"]["cooperative"]["verdict"].startswith("H-C1"))

    # --- where PREREG 5.3 registers the CPU hypotheses, and whether the code labels there --------
    # PREREG 5.3 (`PREREG.md:262-266`): the main axis is "1024 B 梯子上三組共同有的每一階", the
    # quantity is Delta-kernel(g, k) = kernel(g, k) - kernel(none, k), and "擬合 Delta-kernel = F + m*S"
    # -- one fit per treated group over those rungs, which H-C1/H-C2/H-C3 then judge. The bmv2
    # statement is registered separately (`:276-277`): bmv2_total(cooperative)/bmv2_total(none)
    # "在相同階 in [0.90, 1.15]" -- a ratio at each rung, NOT a fit and NOT an H-C hypothesis.

    def test_the_H_C_verdict_is_made_once_per_treated_group_over_every_common_rung(self):
        # 🔴 THE LEVEL, PINNED (task C): the code already matched PREREG here, so this case is
        # what keeps it matching. One verdict per treated group, from a fit over EVERY rung the
        # three groups share -- not from the first few (M-E42), and never on a rung row.
        comparison = analyse.cpu_comparison(self.arms, frame=1024, label="kernel")
        self.assertEqual(sorted(comparison["fits"]), ["cooperative", "link"])
        for group in ("cooperative", "link"):
            entry = comparison["fits"][group]
            self.assertIsNotNone(entry["fit"], entry["verdict"])
            self.assertEqual(entry["fit"]["points"], len(synthetic.LADDER), group)
            self.assertTrue(entry["verdict"].startswith("H-C"), entry["verdict"])
        for row in comparison["rows"]:
            for key, value in row.items():
                self.assertFalse(isinstance(value, str) and "H-C" in value, (key, row))

    def test_a_rung_one_group_does_not_have_is_in_NO_groups_fit(self):
        # 🔴 "三組共同有的每一階" -- common to all THREE groups. The code intersected each treated
        # group with `none` only, so a rung the link arms never reached still went into the
        # cooperative fit. Here link stops at 8 kpps, and 20 must leave both fits (M-E39).
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name, ladders={"link": [1, 8]})
        arms, _windows, _controls = analyse.walk_raw(tmp.name)
        comparison = analyse.cpu_comparison(arms, frame=1024, label="kernel")
        rungs = sorted(row["kpps"] for row in comparison["rows"] if row["group"] == "cooperative")
        self.assertEqual(rungs, [1.0, 8.0],
                         "the cooperative fit used rungs the link group never measured")
        self.assertEqual(comparison["fits"]["cooperative"]["fit"]["points"], 2)

    def test_with_no_rung_all_three_groups_share_there_is_no_fit_and_it_says_why(self):
        # Without one group at 1024 B there is no registered axis at all. That is NOT H-C0 (a
        # spread larger than the effect) and must not be reported as one.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cells = {key: value for key, value in synthetic.DEFAULT_CELLS.items()
                 if key != ("link", 1024)}
        synthetic.build(tmp.name, cells=cells)
        arms, _windows, _controls = analyse.walk_raw(tmp.name)
        comparison = analyse.cpu_comparison(arms, frame=1024, label="kernel")
        entry = comparison["fits"]["cooperative"]
        self.assertIsNone(entry["fit"], entry["verdict"])
        self.assertIn("common to all three groups", entry["verdict"])
        self.assertNotIn("H-C0", entry["verdict"])

    def test_bmv2_carries_NO_H_C_label(self):
        # 🔴 A REGISTERED LABEL ON A QUANTITY IT WAS NOT REGISTERED FOR. analyse() ran the same
        # fit-and-verdict over bmv2 and printed H-C1/H-C2/H-C3 for it; PREREG 5.3 registers those
        # for Delta-kernel only. The fit's numbers may stay as a description (M-E40).
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name)
        summary = analyse.analyse(tmp.name)
        for group, entry in summary["cpu_bmv2"]["fits"].items():
            self.assertNotIn("H-C", entry.get("verdict") or "", group)
        # and the kernel, where it IS registered, keeps it
        self.assertTrue(summary["cpu_kernel"]["fits"]["cooperative"]["verdict"].startswith("H-C1"))

    def test_the_registered_bmv2_comparison_is_coop_over_none_at_each_rung(self):
        # The fixture gives every group the same ten shares, so the ratio is 1.0 at every rung.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name)
        block = analyse.analyse(tmp.name).get("cpu_bmv2_ratio") or {}
        self.assertEqual(block.get("interval"), [0.90, 1.15], block)
        rows = block.get("rows") or []
        self.assertEqual(sorted(row["kpps"] for row in rows), [1.0, 8.0, 20.0])
        for row in rows:
            self.assertAlmostEqual(row["ratio"], 1.0, places=6)
            self.assertIs(row["inside"], True)

    def test_a_bmv2_ratio_outside_090_115_is_reported_outside(self):
        # cooperative's ten switches at twice the none level: 300% vs 150% of one core, ratio 2.0
        # at every rung (every weight is even, so the jiffies stay whole). (M-E43)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name, bmv2_factor={"cooperative": 2.0})
        rows = (analyse.analyse(tmp.name).get("cpu_bmv2_ratio") or {}).get("rows") or []
        self.assertTrue(rows, "no registered bmv2 comparison at all")
        for row in rows:
            self.assertAlmostEqual(row["ratio"], 2.0, places=6)
            self.assertIs(row["inside"], False)


class RungWindowTest(unittest.TestCase):
    """🔴 A RUNG'S WINDOW IS ITS OWN REPS (the 2026-09-24 recheck of the stage-3 CPU analysis).

    run_group_arm.sh re-confirms the highest clean rung AFTER the climb has gone on to the rungs
    above it (:420-440), and files those three reps as `c1 c2 c3` rows with the rung's own kpps.
    rung_windows() took (min t_start, max t_end) over every row of a kpps, so the confirmed
    rung's window ran from its first climb rep to its last confirmation rep and contained every
    rung in between: the fifth campaign's link_f64_b read 20 kpps over 110 s that include 30,
    45, 70 and 110 kpps. Every real ladder arm of the fourth and fifth campaigns has this shape
    and the fixture had none of it.

    What PREREG fixes and what it does not (PREREG.md line numbers):
      * S(k) = the rung's addressed_total delta / "該階的秒數", from the ONE get_sflow_stats pair
        read per rung (AMENDMENT-1 A1.5, :503-509). That pair brackets the climb reps only
        (run_group_arm.sh:378, :393), so S's seconds are the climb's. Not a reading -- the only
        seconds the counter delta covers.
      * kernel_CPU(g, k) at "每一階" (5.3, :262-264): no reading puts 30-110 kpps in rung 20.
      * whether the confirmation reps are PART of rung k's CPU: PREREG does not say. 4.1 (:161-162)
        names the confirmation as part of the ladder procedure ("梯頂三 rep 再確認＋walk-down",
        from 08-28's (3) AMENDMENT-2 11.1(b), a loss re-check), and nothing registers which
        seconds CPU(k) is taken over. So both readings are computed, and neither is called the
        registered one; the cases below pin each reading's arithmetic.
      * which one the primary summary keys use: "climb", decided by Adam on 2026-09-24
        (TICKET-P4 section 7 ruling 4) and NOT registered by PREREG. That choice is pinned where
        it reaches a reader -- figure 3's title and the render (test_plot.py, M-E54) -- and every
        downstream CPU output must name its reading (M-E56).
    """

    REAL_ROWS = ("rungs.115737Z.G4.link_f64_b.tsv",          # the orchestrator's example
                 "rungs.115737Z.G3.link_f64_a.tsv",          # walk-down: 30, 20, 12 re-confirmed
                 "rungs.115737Z.G2.cooperative_f1024_a.tsv")  # a 1024 B arm: 12 over 117 s

    def real_arm(self, name):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        directory = synthetic.write_cpu_following_real_rungs(
            tmp.name, os.path.join(HERE, "fixtures", name))
        return {"dir": directory,
                "rungs": analyse.read_tsv(os.path.join(directory, "rungs.tsv"))}

    def confirmed_tree(self, kernel_extra=0.0):
        """The default tree, with both cooperative 1024 B arms re-confirming 8 kpps after 20."""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name, confirm={("cooperative", 1024): {"kpps": 8,
                                                                   "kernel_extra": kernel_extra}})
        arms, _windows, _controls = analyse.walk_raw(tmp.name)
        return tmp.name, arms

    @staticmethod
    def level_at(kpps, group="cooperative"):
        """What the fixture's kernel runs at on rung `kpps`: built on the samples/s the counter
        can actually give back (write_arm's `recoverable`), not on the ideal rate."""
        recoverable = int(round(synthetic.samples_per_second(kpps, group) * 8.0)) / 8.0
        return synthetic.KERNEL_BASE + synthetic.KERNEL_FIXED + synthetic.KERNEL_MARGINAL * recoverable

    def assert_has_reading_parameter(self):
        import inspect
        self.assertIn("reading", inspect.signature(analyse.cpu_by_rung).parameters,
                      "cpu_by_rung has no `reading`: the confirmation reps have no reading of "
                      "their own to be computed under")

    def test_on_the_real_rows_every_rungs_cpu_is_that_rungs_own(self):
        # 🔴 THE DEFECT ON THE ROWS IT HAPPENED ON (M-E49). Three real rungs.tsv files, verbatim;
        # the kernel's level is 2 x kpps from each rep's start to the next rep's start, so a
        # window that stays on its rung reads exactly 2 x kpps and one that reaches into the
        # rungs after it reads more. The union window read 20 kpps on link_f64_b as ~2.5x that.
        for name in self.REAL_ROWS:
            arm = self.real_arm(name)
            by_rung = analyse.cpu_by_rung(arm)
            self.assertTrue(by_rung, name)
            for kpps, measured in sorted(by_rung.items()):
                self.assertAlmostEqual(measured["kernel"], synthetic.real_rung_level(kpps),
                                       delta=0.1, msg="%s: rung %g kpps" % (name, kpps))

    def test_on_the_real_rows_the_climb_plus_confirmation_reading_stays_on_its_rung_too(self):
        # the other reading pools the confirmation block with the climb -- and must not get
        # there by stretching one window across the rungs between them (M-E51 also sees this)
        self.assert_has_reading_parameter()
        for name in self.REAL_ROWS:
            arm = self.real_arm(name)
            by_rung = analyse.cpu_by_rung(arm, reading="climb+confirmation")
            self.assertTrue(by_rung, name)
            for kpps, measured in sorted(by_rung.items()):
                self.assertAlmostEqual(measured["kernel"], synthetic.real_rung_level(kpps),
                                       delta=0.1, msg="%s: rung %g kpps" % (name, kpps))

    def test_the_confirmed_rungs_climb_window_does_not_reach_the_rungs_climbed_after_it(self):
        # the synthetic version, with the arithmetic known: cooperative re-confirms 8 kpps after
        # climbing to 20. Rung 8's CPU is its own 8 s rep, whatever came after.
        # The climb reading is asked for BY NAME where it exists: which reading the primary keys
        # use is a placeholder no case may pin (the gate's control C-E3 flips it). On a
        # cpu_by_rung that has no readings at all -- the pre-fix one -- the call is its only
        # window, which is the one under test.
        import inspect
        _root, arms = self.confirmed_tree()
        arm = next(a for a in arms if a["arm"] == "cooperative_f1024_a")
        named = ({"reading": "climb"}
                 if "reading" in inspect.signature(analyse.cpu_by_rung).parameters else {})
        by_rung = analyse.cpu_by_rung(arm, **named)
        self.assertAlmostEqual(by_rung[8.0]["kernel"], self.level_at(8), delta=0.2)
        self.assertAlmostEqual(by_rung[8.0]["_elapsed_s"], 8.0, places=3)
        self.assertAlmostEqual(by_rung[20.0]["kernel"], self.level_at(20), delta=0.2)

    def test_samples_per_second_at_the_confirmed_rung_is_over_its_own_pairs_seconds(self):
        # 🔴 A1.5: S(k) = the pair's delta / "該階的秒數". The pair brackets the climb (the
        # fixture's is 8 s); the old window divided it by 48 s -- the climb, the 20 kpps rung, two
        # gaps and the confirmation -- and read 8 kpps at a sixth of its rate. (M-E50)
        _root, arms = self.confirmed_tree()
        arm = next(a for a in arms if a["arm"] == "cooperative_f1024_a")
        recoverable = int(round(synthetic.samples_per_second(8, "cooperative") * 8.0)) / 8.0
        self.assertAlmostEqual(analyse.rung_samples_per_second(arm, 8.0), recoverable, places=6)

    def test_the_climb_plus_confirmation_reading_pools_the_reps_own_seconds_only(self):
        # confirmation reps 4 points hotter than the climb: 8 s at L and 24 s at L + 4 pool to
        # L + 3 over 32 s. The climb reading stays at L over 8 s. A window stretched from the
        # climb to the confirmation would also hold the 20 kpps rep and two idle gaps. (M-E51)
        self.assert_has_reading_parameter()
        _root, arms = self.confirmed_tree(kernel_extra=4.0)
        arm = next(a for a in arms if a["arm"] == "cooperative_f1024_a")
        pooled = analyse.cpu_by_rung(arm, reading="climb+confirmation")[8.0]
        self.assertAlmostEqual(pooled["kernel"], self.level_at(8) + 3.0, delta=0.2)
        self.assertAlmostEqual(pooled["_elapsed_s"], 32.0, places=3)
        climb = analyse.cpu_by_rung(arm, reading="climb")[8.0]
        self.assertAlmostEqual(climb["kernel"], self.level_at(8), delta=0.2)
        # S is the climb's under both readings: the confirmation reps have no pair of their own
        self.assertEqual(pooled["_samples_per_s"], climb["_samples_per_s"])

    def test_both_readings_are_in_the_summary_side_by_side_and_neither_is_called_registered(self):
        # 🔴 NOT A REGISTERED READING. The summary carries every CPU quantity under both
        # readings, says which one the primary keys (cpu_kernel, cpu_bmv2, cpu_bmv2_ratio,
        # reconciliation (b)) were computed under, WHO decided that (Adam, TICKET-P4 section 7
        # ruling 4), and that PREREG did not. (M-E52: the two readings collapse; M-E53: the
        # summary says PREREG decided it.)
        import io
        root, _arms = self.confirmed_tree(kernel_extra=4.0)
        summary = analyse.analyse(root)
        self.assertTrue("cpu_window" in summary,
                        "the summary does not say which rung window its CPU was taken over")
        block = summary["cpu_window"]
        self.assertIs(block["decided_by_prereg"], False)
        self.assertEqual(block.get("decided_by"), "Adam 2026-09-24, TICKET-P4 §7 ruling 4")
        self.assertEqual(sorted(block["readings"]), sorted(analyse.CPU_WINDOW_READINGS))
        self.assertIn(block["primary"], analyse.CPU_WINDOW_READINGS)
        self.assertEqual(block.get("secondary"),
                         [r for r in analyse.CPU_WINDOW_READINGS if r != block["primary"]])
        per_reading = {reading: block["readings"][reading]["cpu_kernel"]["per_group"]
                       ["cooperative"][8.0]["cpu"] for reading in analyse.CPU_WINDOW_READINGS}
        self.assertAlmostEqual(per_reading["climb"], self.level_at(8), delta=0.2)
        self.assertAlmostEqual(per_reading["climb+confirmation"], self.level_at(8) + 3.0,
                               delta=0.2)
        primary = block["readings"][block["primary"]]
        self.assertEqual(summary["cpu_kernel"], primary["cpu_kernel"])
        self.assertEqual(summary["cpu_bmv2"], primary["cpu_bmv2"])
        self.assertEqual(summary["cpu_bmv2_ratio"], primary["cpu_bmv2_ratio"])
        self.assertEqual([r for r in summary["reconciliation"] if r["id"] == "b"],
                         primary["reconciliation_b"])
        buffer = io.StringIO()
        analyse.render(summary, buffer)
        self.assertIn("NOT registered by PREREG", buffer.getvalue())
        self.assertIn("decided by Adam 2026-09-24, TICKET-P4 §7 ruling 4", buffer.getvalue())

    def test_every_downstream_cpu_output_names_the_rung_window_it_was_taken_over(self):
        # 🔴 TICKET-P4 section 7 ruling 4: the registered bmv2 ratio and reconciliation (b) are
        # computed over a reading Adam chose and PREREG did not register, so each of them -- in
        # summary.json and in the render -- says which reading it is. A number that reaches
        # FINDINGS without its reading is the round-1 state this case exists to refuse. (M-E56)
        import io
        root, _arms = self.confirmed_tree(kernel_extra=4.0)
        summary = analyse.analyse(root)
        primary = summary["cpu_window"]["primary"]
        for key in ("cpu_kernel", "cpu_bmv2", "cpu_bmv2_ratio"):
            self.assertEqual((summary.get(key) or {}).get("rung_window_reading"), primary, key)
        rows_b = [r for r in summary["reconciliation"] if r["id"] == "b"]
        self.assertTrue(rows_b)
        for row in rows_b:
            self.assertEqual(row.get("rung_window_reading"), primary, row["group"])
        buffer = io.StringIO()
        analyse.render(summary, buffer)
        text = buffer.getvalue()
        named = "rung window: %s (decided by Adam 2026-09-24, TICKET-P4 §7 ruling 4; NOT " \
                "registered by PREREG)" % primary
        kernel_header = next(line for line in text.splitlines() if "=== (3) CPU" in line)
        self.assertIn(named, kernel_header)
        bmv2_header = next(line for line in text.splitlines() if "=== (3b) bmv2" in line)
        self.assertIn("rung window: %s" % primary, bmv2_header)
        for line in text.splitlines():
            if line.strip().startswith("(b) "):
                self.assertIn("[rung window: %s]" % primary, line)
            if line.strip().startswith("(a) "):
                self.assertNotIn("rung window", line)     # (a) is the pps ceiling, not CPU

    def test_the_default_tree_has_no_confirmation_rows_so_both_readings_agree_there(self):
        # the tree every other case is pinned to: one rep per rung, no c-rows. The two readings
        # must give the same numbers on it, or the fix moved something it had no business moving.
        # (M-E55: the second reading keeps only the rungs that were re-confirmed -- round 1 had no
        # behavioural mutant here; this case was red on the pre-fix code only because
        # cpu_by_rung had no `reading` at all.)
        self.assert_has_reading_parameter()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name)
        arms, _windows, _controls = analyse.walk_raw(tmp.name)
        for arm in arms:
            self.assertFalse(any(str(row.get("rep", "")).startswith("c") for row in arm["rungs"]))
            self.assertEqual(analyse.cpu_by_rung(arm, reading="climb"),
                             analyse.cpu_by_rung(arm, reading="climb+confirmation"), arm["arm"])


class LoadGateTest(unittest.TestCase):
    def test_the_gate_is_within_group_so_the_link_treatment_does_not_fire_it(self):
        # 🔴 PREREG 6.2. The link arms sit at 0.30 against 0.05 elsewhere -- a global median
        # would demand a rerun of every arm carrying the link result, and every rerun would fire
        # again. That is the disease 08-28's AMENDMENT-1 removed, in a new place.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name)
        arms, _windows, _controls = analyse.walk_raw(tmp.name)
        rows = analyse.external_gate(arms)
        self.assertTrue(rows)
        self.assertEqual([r["arm"] for r in rows if r["fires"]], [])
        link = [r for r in rows if r["group"] == "link"]
        self.assertTrue(link)
        for row in link:
            self.assertAlmostEqual(row["group_median"], 0.30, places=4)

    def test_the_none_group_gate_median_counts_the_ladder_arms_only(self):
        # 🔴 THE GATE'S POSITIVE CONTROL MOVED THE GATE'S OWN REFERENCE. `c3b_burn` runs four
        # burners on purpose; in the fourth campaign it sat in the `none` group's row list with
        # fires=true and pulled that group's median to 0.03665 -- so the threshold every real
        # `none` arm was judged against had been raised by the arm built to prove the threshold
        # works. Here the four `none` arms all report 0.0500 and the controls 0.0538 / 0.2262;
        # pooling gives 0.0519, the ladder arms alone give exactly 0.0500.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name)
        arms, _windows, _controls = analyse.walk_raw(tmp.name)
        rows = analyse.external_gate(arms)
        none_rows = [r for r in rows if r["group"] == "none"]
        self.assertEqual(sorted(r["arm"] for r in none_rows),
                         ["none_f1024_a", "none_f1024_b", "none_f64_a", "none_f64_b"])
        for row in none_rows:
            self.assertAlmostEqual(row["group_median"], synthetic.DEFAULT_EXTERNAL["none"],
                                   places=6)
        self.assertEqual([r["arm"] for r in rows if r["arm"].startswith("c3")], [])

    def test_a_genuinely_foreign_arm_inside_a_group_still_fires(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name)
        arms, _windows, _controls = analyse.walk_raw(tmp.name)
        for arm in arms:
            if arm["arm"] == "none_f64_a":
                arm["external"] = 0.40                      # 0.35 above its group's median
        rows = analyse.external_gate(arms)
        self.assertIn("none_f64_a", [r["arm"] for r in rows if r["fires"]])


class ReconciliationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        synthetic.build(self.tmp.name)
        self.summary = analyse.analyse(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def rows(self, identifier):
        return [r for r in self.summary["reconciliation"] if r["id"] == identifier]

    def test_a_is_reported_for_BOTH_the_none_and_the_cooperative_cell(self):
        rows = self.rows("a")
        self.assertEqual(sorted(r["group"] for r in rows), ["cooperative", "none"])
        matched = next(r for r in rows if r["matched"])
        self.assertEqual(matched["group"], "cooperative")

    def test_a_uses_the_registered_interval_and_says_outside_is_not_a_refutation(self):
        row = next(r for r in self.rows("a") if r["group"] == "none")
        self.assertEqual(row["interval"], [0.60, 1.67])
        self.assertAlmostEqual(row["ratio"], 20.0 / 16.0)
        self.assertTrue(row["consistent"])
        self.assertIn("NOT a refutation", row["outside_means"])

    def test_a_for_none_is_the_ladder_cell_and_not_C3s_throwaway_ladders(self):
        # 🔴 WHAT THE POOLING COST AT THE END OF THE PIPE. Reconciliation (a) is the round's
        # comparison against 08-28's 16.0 kpps, and in the fourth campaign it was handed 21.0 --
        # the average of two real 30s and two control ladders that stop at 12 by construction.
        # The number this row divides has to be the cell's, and the cell has two members.
        row = next(r for r in self.rows("a") if r["group"] == "none")
        cell = self.summary["cells"]["none|1024"]
        self.assertEqual(sorted(cell["arms"]), ["none_f1024_a", "none_f1024_b"])
        self.assertAlmostEqual(row["mine_kpps"], 20.0)
        self.assertAlmostEqual(row["mine_kpps"], cell["mean"])
        # and the controls are still in the record -- excluded from the cell, not deleted
        self.assertEqual(sorted(a["arm"] for a in self.summary["control_arms"]),
                         ["c3a_noburn", "c3b_burn"])
        self.assertEqual([a["arm"] for a in self.summary["arms"] if a["arm"].startswith("c3")],
                         [])

    def test_b_compares_the_marginal_slope_against_08_20s_206_microseconds(self):
        row = next(r for r in self.rows("b") if r["group"] == "cooperative")
        self.assertEqual(row["theirs_us_per_sample"], 206.0)
        self.assertEqual(row["interval"], [103.0, 618.0])
        self.assertTrue(row["consistent"])

    def test_c_forbids_dividing_any_cell_of_its_table_by_another(self):
        row = self.rows("c")[0]
        self.assertIn("may be divided", row["forbidden"])
        self.assertEqual(len(row["table"]), 4)

    def test_the_sender_control_passes_only_at_five_times_the_measured_ceiling(self):
        c1 = next(r for r in self.summary["reconciliation"] if r["id"] == "C1")
        self.assertTrue(c1["passes"])
        self.assertAlmostEqual(c1["required_pps"], 5 * 20000.0)

    def test_a_sender_control_below_five_times_FAILS(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name, c1_ceiling=50000.0)       # 2.5x, not 5x
        summary = analyse.analyse(tmp.name)
        c1 = next(r for r in summary["reconciliation"] if r["id"] == "C1")
        self.assertFalse(c1["passes"])
        self.assertIn("generator-limited", c1["outside_means"])


class EndToEndTest(unittest.TestCase):
    def test_analyse_renders_without_raising_and_carries_the_family_counts(self):
        import io
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        synthetic.build(tmp.name)
        summary = analyse.analyse(tmp.name)
        buffer = io.StringIO()
        analyse.render(summary, buffer)
        text = buffer.getvalue()
        self.assertIn("pps ceiling", text)
        self.assertIn("sampling error", text)
        self.assertIn("load gate", text)
        # worker A's samples_by_family deltas must be visible, not assumed away
        families = summary["families"]["cooperative_f1024_a"]
        self.assertEqual(families["ipv4"], 3500)
        self.assertEqual(families["l2"], 100)


if __name__ == "__main__":
    unittest.main()
