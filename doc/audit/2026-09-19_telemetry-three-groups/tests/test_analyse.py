#!/usr/bin/env python3
"""
Tests for analyse.py against synthetic raw whose correct answers are known in advance.

[Co-developed with claude code -- Adam]

Every case here exists because a mutation can make it go red -- see mutate_analyse.sh, which
names the case each mutation must kill. A test nobody has seen fail is a decoration, and this
file is where the round's registered branches (PREREG sections 5, 6, 8) stop being prose.

Run:  p4_proxy/venv/bin/python -m unittest discover -s doc/audit/2026-09-19_telemetry-three-groups/tests
"""
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

    def test_an_error_at_the_prediction_is_H_B1(self):
        row = self.row("cooperative", 20)
        self.assertAlmostEqual(row["median_abs_error"], 0.045, places=6)
        self.assertTrue(row["verdict"].startswith("H-B1"))

    def test_an_error_far_above_the_band_with_one_sign_is_H_B2(self):
        row = self.row("link", 20)
        self.assertAlmostEqual(row["median_abs_error"], 0.150, places=6)
        self.assertTrue(row["verdict"].startswith("H-B2"))
        self.assertLess(row["median_signed_error"], 0)   # the prior is that the twin reads LOW


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
        self.assertTrue(analyse.cpu_verdict(per_sample).startswith("H-C2"))


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
