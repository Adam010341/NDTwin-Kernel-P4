#!/usr/bin/env python3
"""Does the fixture have the same SHAPE as a real run directory?

[Co-developed with claude code -- Adam]

🔴 THE THIRD TIME IS A RULE, NOT A COINCIDENCE (ruling 35(3)). Three defects in this round were
invisible to a green suite for the same reason -- the fixture and the real raw disagreed about
what a run directory contains, so the tests were asserting about a tree the round never
produces:

    ruling 27     the switch manifest's `argv` is a STRING, the stub wrote a LIST
    ruling 32(1)  C3's two throwaway ladder arms exist, the fixture never wrote them
    ruling 35(1)  a window's `keys` is 32 edges and `per_edge_peak_bps` is 4, the fixture
                  wrote 4 and 4 -- which is what made `links=len(keys)` look correct

None of the three was an error in the analysis, and no test of the analysis could have found
them. What finds them is comparing the fixture to the real thing, by structure, every run.

The real side is tests/fixtures/real_run_inventory.json, extracted by tests/inventory.py from
raw/2026-09-19T105759Z_full -- the fourth campaign, twelve ladder arms, two control arms,
twenty-seven windows, three controls. It is committed so this test does not depend on that
directory still existing, and it is regenerated with:

    tests/inventory.py <run directory> > tests/fixtures/real_run_inventory.json

🔴 THE TWO DECLARED LISTS BELOW ARE ASSERTED TO BE EXACT, in both directions. A real key that
stops being written, a fixture key nobody real has, a new file class in either tree -- each of
them fails here and has to be looked at. A list that only said "these are allowed to differ"
would grow silently and be worth nothing.
"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import inventory                                    # noqa: E402
import synthetic                                    # noqa: E402

REAL_INVENTORY = os.path.join(HERE, "fixtures", "real_run_inventory.json")

#: File classes a real run writes that the fixture deliberately does not, and why. Every one of
#: them is a file the analysis never opens -- which is the point: this is the list of raw the
#: analysis is blind to, and it is meant to be read, not just satisfied.
NOT_WRITTEN = {
    "ladder arm": {
        "cpu_probe.log": "the probe's own stderr; the analysis reads cpu.jsonl",
        "k<N>_rep<N>.json": "iperf3's per-rep output; the ladder is summarised in ladder.tsv",
        "k<N>_repc<N>.json": "the confirmation reps of the top rung, same",
        "netdev_before.txt": "/proc/net/dev either side of the arm; run_group_arm.sh reads it",
        "netdev_after.txt": "same",
        "sflow_before.json": "the arm-level counter pair; the deltas are in arm.meta",
        "sflow_after.json": "same",
        "switch_state_before.json": "the group assertion; its verdict is in arm.meta",
        "switch_state_after.json": "same",
        "link_telemetry_manifest.json": "the emitter manifest, copied in by the link arms",
    },
    "control arm": {
        "cpu_probe.log": "as above",
        "k<N>_rep<N>.json": "as above",
        "k<N>_repc<N>.json": "as above",
        "netdev_before.txt": "as above",
        "netdev_after.txt": "as above",
        "sflow_before.json": "as above",
        "sflow_after.json": "as above",
        "switch_state_before.json": "as above",
        "switch_state_after.json": "as above",
    },
    "sampling window": {
        "emitter.log": "the emitter's statistics; the analysis reads the ARM's copy",
        "iperf<N>.json": "the generator's own report; the window's numbers are in window.json",
        "sflow_before.json": "counter pair; the deltas are in window.json",
        "sflow_after.json": "same",
        "switch_state.json": "the group assertion; its result is in window.json",
    },
    "control": {
        "c<N>a.log": "gate_control's stdout for the no-burner arm",
        "c<N>b.log": "and for the burner arm",
        "pps.txt": "the sender control's three reps; the ceiling is in control.meta",
        "rep<N>.json": "iperf3's own output for those reps",
    },
    "generation": {
        "<N>_up.txt": "ndt up's log; the driver reads it, the analysis does not",
        "<N>_verify.txt": "the generation check's log, same",
        "<N>_down.txt": "the teardown log, same",
        "sampling_error.log": "the window block's stdout",
        "none_f<N>_a.log": "each arm's stdout, tee'd by the driver",
        "none_f<N>_b.log": "same",
        "cooperative_f<N>_a.log": "same",
        "cooperative_f<N>_b.log": "same",
        "link_f<N>_a.log": "same",
        "link_f<N>_b.log": "same",
    },
    "run root": {
        "driver.log": "the whole round's stdout",
        "<N>_down.txt": "the final teardown",
        "<N>_release.txt": "the release",
        "<N>_host_count_override.entry": "the knob bytes the round found on entry",
        "summary.json": "analyse.py's OUTPUT -- it is written into the run directory, not read",
    },
}

#: Keys a real arm.meta carries that the fixture does not write. Nothing reads any of them
#: today; they are listed so that "nothing reads them" stays a statement somebody checked.
NOT_WRITTEN_KEYS = {
    "arm.meta": [
        "clone_sessions", "gate", "link_emitter_alive", "link_emitter_pid", "link_emitter_rate",
        "rep_rule", "sflow_registered", "switch_count", "switch_pids", "telemetry_knob",
        "telemetry_package", "top_rung_confirmation",
    ],
}


class RealRunShapeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(REAL_INVENTORY) as fh:
            cls.real = json.load(fh)
        cls.tmp = tempfile.TemporaryDirectory()
        synthetic.build(cls.tmp.name)
        cls.mine = inventory.inventory(cls.tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_a_real_run_has_the_six_directory_classes_and_so_does_the_fixture(self):
        # 🔴 ruling 32(1) in one line: `control arm` is a class of its own, and a fixture that
        # does not have one cannot see anything that happens to control arms.
        self.assertEqual(sorted(self.real["directory_classes"]),
                         ["control", "control arm", "generation", "ladder arm", "run root",
                          "sampling window"])
        for kind in self.real["directory_classes"]:
            if kind in ("run root", "generation"):
                continue        # the fixture has no driver logs, so these hold no files at all
            self.assertIn(kind, self.mine["directory_classes"],
                          "the fixture has no %s directory at all" % kind)

    def test_the_file_classes_the_fixture_skips_are_exactly_the_declared_ones(self):
        for kind, classes in self.real["directory_classes"].items():
            missing = sorted(set(classes) - set(self.mine["directory_classes"].get(kind, [])))
            declared = sorted(NOT_WRITTEN.get(kind, {}))
            self.assertEqual(missing, declared,
                             "%s: the difference from a real run is not what is declared" % kind)

    def test_the_fixture_invents_no_file_class_a_real_run_does_not_have(self):
        for kind, classes in self.mine["directory_classes"].items():
            invented = sorted(set(classes) - set(self.real["directory_classes"].get(kind, [])))
            self.assertEqual(invented, [], "%s: the fixture writes files no real run has" % kind)

    def test_every_file_the_analysis_reads_carries_the_real_key_set(self):
        # The half that matters most: for the files analyse.py actually opens, the fixture's
        # keys and the real keys are the same set, apart from the declared twelve.
        for file_class, keys in self.real["file_keys"].items():
            mine = set(self.mine["file_keys"].get(file_class, []))
            missing = sorted(set(keys) - mine)
            self.assertEqual(missing, NOT_WRITTEN_KEYS.get(file_class, []),
                             "%s: keys a real run has and the fixture does not" % file_class)

    def test_the_fixture_invents_no_key_in_a_file_the_analysis_reads(self):
        # 🔴 The other direction, and the one that would have caught ruling 35(1) at the source:
        # a fixture key no real file carries is a shape the analysis will never meet.
        for file_class, keys in self.mine["file_keys"].items():
            invented = sorted(set(keys) - set(self.real["file_keys"].get(file_class, [])))
            self.assertEqual(invented, [], "%s: keys the fixture invents" % file_class)

    def test_every_file_the_analysis_reads_has_the_real_CARDINALITIES(self):
        # 🔴 A KEY SET IS NOT A SHAPE, AND RULING 35(1)'s DEFECT LIVES HERE. `keys` and
        # `per_edge_peak_bps` are present in both trees under the same names; what differed was
        # that the real `keys` holds 32 edges and the fixture's held 4, which is precisely what
        # made `links=len(keys)` look right. Names alone would have called that fixture faithful.
        for file_class, sizes in self.real["file_sizes"].items():
            mine = self.mine["file_sizes"].get(file_class, {})
            for key, bounds in sizes.items():
                self.assertEqual(mine.get(key), bounds,
                                 "%s: %s is %s in a real run and %s in the fixture"
                                 % (file_class, key, bounds, mine.get(key)))

    def test_a_window_really_does_carry_more_edges_than_the_flow_crosses(self):
        # The defect stated as the shape it is, read off the REAL inventory rather than off a
        # number I chose: a window lists every fabric edge and marks the few that carried the
        # flow, and those two counts are not the same number.
        sizes = self.real["file_sizes"]["window.json"]
        self.assertEqual(sizes["keys"], [32, 32])
        self.assertEqual(sizes["per_edge_peak_bps"], [0, 4])       # 0 in the none windows
        self.assertGreater(sizes["keys"][0], sizes["per_edge_peak_bps"][1])
        # and the fixture's own constants are the same two sets
        self.assertEqual(len(synthetic.ALL_EDGE_KEYS), 32)
        self.assertEqual(len(synthetic.ONPATH_KEYS), 4)
        self.assertEqual(sorted(set(synthetic.ONPATH_KEYS) - set(synthetic.ALL_EDGE_KEYS)), [])


if __name__ == "__main__":
    unittest.main()
