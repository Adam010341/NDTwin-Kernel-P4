"""Does pre-flight go red where it has to, and green where it has to?

[Co-developed with claude code -- Adam]

A pre-flight that only ever says PASS is worse than no pre-flight: it is a licence to bring up
a package nobody checked. So most of this file is red cells -- one per way a package can be
wrong -- and the green ones are there so the red ones mean something.

The subject is a real converted package (the fixtures are tutorials' own files), corrupted one
field at a time. Corrupting a real package rather than hand-writing a broken one matters: a
hand-written package can be wrong in ways convert.py would never produce, and then the test is
about a file shape nothing creates.

    p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests \
        -t tools/p4_exercise/tests -v
"""
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(os.path.dirname(HERE))
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

from p4_exercise import common, convert, preflight  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
BASIC = os.path.join(FIXTURES, "basic")
P4RUNTIME = os.path.join(FIXTURES, "p4runtime")


class PackageCase(unittest.TestCase):
    """A converted pod-topo package in a temp dir, plus helpers to corrupt it."""

    exercise = BASIC
    topology = "pod-topo/topology.json"
    p4 = None

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_exercise_preflight_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.pkg = os.path.join(self.tmp, "pkg")
        convert.convert(self.exercise, self.topology, self.pkg, p4_rel=self.p4)

    # --- reading the report ------------------------------------------------------------------

    def report(self):
        # compile_p4 off: p4c is the only slow check and none of these tests are about it.
        return preflight.run(self.pkg, compile_p4=False)

    def statuses(self):
        return {label: status for status, label, _detail in self.report().rows if label}

    def assert_green(self):
        report = self.report()
        self.assertEqual(report.failures, [], report.render())

    def assert_red(self, label, needle=None):
        report = self.report()
        rows = [r for r in report.rows if r[1] == label]
        self.assertTrue(rows, f"no check called {label!r} in:\n{report.render()}")
        self.assertEqual(rows[0][0], preflight.FAIL,
                         f"{label} should be red:\n{report.render()}")
        if needle is not None:
            joined = " ".join(r[2] for r in report.rows if r[0] == preflight.FAIL)
            self.assertIn(needle, joined, report.render())

    # --- corrupting it -----------------------------------------------------------------------

    def edit_package(self, fn):
        path = os.path.join(self.pkg, "package.json")
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        fn(data)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(common.dumps(data))

    def edit_entries(self, rel, fn):
        path = os.path.join(self.pkg, rel)
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        fn(data)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(common.dumps(data))

    def edit_model(self, fn):
        path = os.path.join(self.pkg, "ndtwin", "topology.json")
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        fn(data)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(common.dumps(data))


class GreenCells(PackageCase):
    def test_a_freshly_converted_package_passes_every_check(self):
        self.assert_green()

    def test_it_says_the_entries_are_recorded_and_not_applied(self):
        detail = {label: d for _s, label, d in self.report().rows}["entries match p4info"]
        self.assertIn("20 entries", detail)
        self.assertIn("NOT applied", detail)

    def test_the_four_readers_are_each_their_own_row(self):
        statuses = self.statuses()
        for name in ("switches", "hosts", "switch_links", "host_links"):
            self.assertEqual(statuses[f"topo_from_json.{name}"], preflight.PASS)


class EntriesRedCells(PackageCase):
    def test_a_bad_table_name_fails(self):
        # 🔴 The single most consequential red cell. A typo'd table name is accepted by every
        # JSON parser, installs nothing, and leaves a switch that forwards nothing while the
        # twin reports it healthy -- GAP-ANALYSIS §5-①, "reports zero rather than an error".
        self.edit_entries("pod-topo/s1-runtime.json",
                          lambda d: d["table_entries"][1].__setitem__("table", "MyIngress.ipv4_lmp"))
        self.assert_red("entries match p4info", "is not in the p4info")

    def test_a_bad_match_field_name_fails(self):
        self.edit_entries(
            "pod-topo/s1-runtime.json",
            lambda d: d["table_entries"][1].__setitem__("match", {"hdr.ipv4.dstAddress": ["10.0.1.1", 32]}))
        self.assert_red("entries match p4info", "has no match field")

    def test_an_lpm_prefix_longer_than_the_field_fails(self):
        # 🔴 bmv2 builds the mask from this number. Out of range it is either refused at install
        # time (a switch with no route) or truncated (a route that matches the wrong traffic);
        # neither reaches the twin as an error.
        self.edit_entries(
            "pod-topo/s1-runtime.json",
            lambda d: d["table_entries"][1].__setitem__("match", {"hdr.ipv4.dstAddr": ["10.0.1.1", 33]}))
        self.assert_red("entries match p4info", "outside 0..32")

    def test_a_negative_lpm_prefix_fails(self):
        self.edit_entries(
            "pod-topo/s1-runtime.json",
            lambda d: d["table_entries"][1].__setitem__("match", {"hdr.ipv4.dstAddr": ["10.0.1.1", -1]}))
        self.assert_red("entries match p4info", "outside 0..32")

    def test_an_lpm_value_that_is_not_a_pair_fails(self):
        self.edit_entries(
            "pod-topo/s1-runtime.json",
            lambda d: d["table_entries"][1].__setitem__("match", {"hdr.ipv4.dstAddr": "10.0.1.1"}))
        self.assert_red("entries match p4info", "[value, prefix_len]")

    def test_a_bad_action_name_fails(self):
        self.edit_entries("pod-topo/s1-runtime.json",
                          lambda d: d["table_entries"][1].__setitem__("action_name", "MyIngress.forward"))
        self.assert_red("entries match p4info", "is not in the p4info")

    def test_an_unknown_action_parameter_fails(self):
        self.edit_entries(
            "pod-topo/s1-runtime.json",
            lambda d: d["table_entries"][1].__setitem__(
                "action_params", {"dstAddr": "08:00:00:00:01:11", "prt": 1}))
        self.assert_red("entries match p4info", "has no parameter")

    def test_a_value_too_wide_for_its_field_fails(self):
        # `port` is 9 bits in basic.p4.
        self.edit_entries(
            "pod-topo/s1-runtime.json",
            lambda d: d["table_entries"][1].__setitem__(
                "action_params", {"dstAddr": "08:00:00:00:01:11", "port": 512}))
        self.assert_red("entries match p4info", "512")

    def test_a_ternary_match_fails_with_g5_not_done(self):
        # basic.p4 has no ternary table, so the p4info is edited instead of the entry: the
        # point is that pre-flight refuses a match kind stage one cannot install, whatever
        # program brings it.
        path = os.path.join(self.pkg, "build", "basic.p4.p4info.txtpb")
        with open(path, encoding="utf-8") as fh:
            text = fh.read().replace("match_type: LPM", "match_type: TERNARY")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        self.assert_red("entries match p4info", "G5 not done")

    def test_a_default_action_entry_with_a_match_fails(self):
        self.edit_entries(
            "pod-topo/s1-runtime.json",
            lambda d: d["table_entries"][0].__setitem__("match", {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]}))
        self.assert_red("entries match p4info", "cannot also carry a match")

    def test_the_shipped_default_action_entry_is_accepted(self):
        # The control for the row above: entry 0 of every pod-topo runtime file IS a
        # default_action with no match, and it must stay green.
        with open(os.path.join(self.pkg, "pod-topo", "s1-runtime.json"), encoding="utf-8") as fh:
            entries = json.load(fh)
        self.assertTrue(entries["table_entries"][0]["default_action"])
        self.assert_green()


class PackageRedCells(PackageCase):
    def test_a_non_null_pipeline_fails_with_g4_not_done(self):
        self.edit_package(lambda d: d["switches"]["1"].__setitem__("pipeline", ["a.p4info", "a.json"]))
        self.assert_red("switches pipeline", "G4 not done")

    def test_a_grpc_base_other_than_30050_fails(self):
        self.edit_package(lambda d: d["control_plane"].__setitem__("grpc_base", 50050))
        self.assert_red("control_plane.grpc_base")

    def test_a_device_id_other_than_dpid_fails(self):
        self.edit_package(lambda d: d["control_plane"].__setitem__("device_id", "index"))
        self.assert_red("control_plane.device_id")

    def test_an_unknown_control_plane_mode_fails(self):
        self.edit_package(lambda d: d["control_plane"].__setitem__("mode", "onos"))
        self.assert_red("control_plane.mode")

    def test_a_wrong_format_number_fails_and_stops(self):
        self.edit_package(lambda d: d.__setitem__("format", 2))
        self.assert_red("format")

    def test_a_missing_referenced_file_fails(self):
        os.remove(os.path.join(self.pkg, "pod-topo", "s3-runtime.json"))
        self.assert_red("referenced files", "switches[3].entries")

    def test_a_host_whose_name_does_not_match_its_address_fails(self):
        self.edit_package(lambda d: d["hosts"]["h1"].__setitem__("ip", "10.0.1.7"))
        self.assert_red("hosts named h<last octet>", "would be built as h7")

    def test_a_switch_not_named_after_its_dpid_fails(self):
        self.edit_package(lambda d: d["switches"]["1"].__setitem__("name", "spine1"))
        self.assert_red("switches name")

    def test_a_model_that_disagrees_with_package_json_fails(self):
        self.edit_model(lambda d: d.__setitem__(
            "nodes", [n for n in d["nodes"] if n.get("dpid") != 4 or n["vertex_type"] != 0]))
        self.assert_red("switches agree")

    def test_a_model_the_proxys_reader_refuses_fails(self):
        # Two switches on one dpid: topo_from_json.switches() raises, and this is the check that
        # turns that into a FAIL row rather than a traceback.
        def dup(d):
            s = [n for n in d["nodes"] if n["vertex_type"] == 0][0]
            clone = dict(s, device_name="s1b", bridge_name="s1b", nickname="s1b")
            d["nodes"].append(clone)
        self.edit_model(dup)
        self.assert_red("topo_from_json.switches")

    def test_a_missing_package_json_fails(self):
        os.remove(os.path.join(self.pkg, "package.json"))
        self.assert_red("package.json")


class ExternalPackage(PackageCase):
    exercise = P4RUNTIME
    topology = "topology.json"
    p4 = "advanced_tunnel.p4"

    def test_an_external_package_passes_and_says_it_has_no_entries(self):
        self.assert_green()
        rows = {label: (status, detail) for status, label, detail in self.report().rows}
        self.assertEqual(rows["entries"][0], preflight.INFO)
        self.assertIn("external", rows["entries"][1])
        # With no entries there is still a p4info, and it must be parsed rather than skipped.
        self.assertEqual(rows["p4info parses"][0], preflight.PASS)

    def test_an_external_package_with_no_p4info_at_all_fails(self):
        self.edit_package(lambda d: d["source"].__setitem__("p4info", None))
        self.assert_red("p4info parses", "carries no p4info at all")


class CompileCheck(PackageCase):
    p4 = "solution/basic.p4"

    def test_an_absent_compiler_is_neither_pass_nor_fail(self):
        # 🔴 The one check allowed not to have an opinion. A machine without p4c can still run a
        # package built from an already-compiled artefact; claiming a compile that did not
        # happen is the failure this whole file exists to prevent.
        with mock.patch.object(preflight.shutil, "which", return_value=None):
            report = preflight.run(self.pkg, compile_p4=True)
        rows = {label: (status, detail) for status, label, detail in report.rows}
        self.assertEqual(rows["p4c-bm2-ss"][0], preflight.INFO)
        self.assertEqual(rows["p4c-bm2-ss"][1], "NOT COMPILED (p4c-bm2-ss absent)")
        self.assertEqual(report.failures, [], report.render())

    def test_a_package_without_a_p4_says_there_is_nothing_to_compile(self):
        self.edit_package(lambda d: d["source"].__setitem__("p4", None))
        rows = {label: (status, detail) for status, label, detail in
                preflight.run(self.pkg, compile_p4=True).rows}
        self.assertEqual(rows["p4c-bm2-ss"][0], preflight.INFO)
        self.assertIn("nothing to compile", rows["p4c-bm2-ss"][1])


class ValueWidths(unittest.TestCase):
    """The encoder pre-flight uses to decide whether a value fits its field."""

    def test_a_mac_is_six_bytes_and_an_ipv4_is_four(self):
        self.assertIsNone(preflight.check_value("08:00:00:00:01:11", 48))
        self.assertIsNone(preflight.check_value("10.0.1.1", 32))

    def test_a_mac_in_a_32_bit_field_is_refused(self):
        self.assertIn("6 byte", preflight.check_value("08:00:00:00:01:11", 32))

    def test_an_integer_that_does_not_fit_is_refused(self):
        self.assertIsNone(preflight.check_value(511, 9))
        self.assertIn("cannot be encoded", preflight.check_value(512, 9))

    def test_a_negative_number_is_refused(self):
        self.assertIn("cannot be encoded", preflight.check_value(-1, 9))

    def test_the_match_type_names_come_out_of_the_enum(self):
        # The transcribed table this replaced was off by one and called every lpm a ternary.
        self.assertEqual(preflight.match_type_name(2), "EXACT")
        self.assertEqual(preflight.match_type_name(3), "LPM")
        self.assertEqual(preflight.match_type_name(4), "TERNARY")


if __name__ == "__main__":
    unittest.main(verbosity=2)
