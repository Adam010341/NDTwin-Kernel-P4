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
FIREWALL = os.path.join(FIXTURES, "firewall")
CALC = os.path.join(FIXTURES, "calc")


def the_proxys_reader():
    """`p4_proxy/mininet/app_package`, imported by path the way common imports its sibling.

    [Co-developed with claude code -- Adam]
    Imported rather than described, because the claim these tests make is a claim about TWO
    programs: that pre-flight refuses exactly what the loader refuses. A test that only
    asserted a red row here would still be green on the day the two drift apart, which is the
    day an operator gets a green table and a dead `ndt up`.
    """
    if common.MININET_DIR not in sys.path:
        sys.path.insert(0, common.MININET_DIR)
    import app_package  # noqa: E402  (path has to be set first)

    return app_package


class PackageCase(unittest.TestCase):
    """A converted pod-topo package in a temp dir, plus helpers to corrupt it."""

    exercise = BASIC
    topology = "pod-topo/topology.json"
    p4 = None
    ndtwin_pipeline = False

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_exercise_preflight_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.pkg = os.path.join(self.tmp, "pkg")
        convert.convert(self.exercise, self.topology, self.pkg, p4_rel=self.p4,
                        ndtwin_pipeline=self.ndtwin_pipeline)

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


class PipelineCells(PackageCase):
    """G4: the per-switch pipeline rows, on the one exercise that has two programs."""

    exercise = FIREWALL
    p4 = "basic.p4"

    def rows(self):
        return {label: (status, detail) for status, label, detail in self.report().rows}

    def edit_bmv2(self, rel, fn):
        path = os.path.join(self.pkg, rel)
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        fn(data)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(common.dumps(data))

    def test_a_two_program_package_passes_every_check(self):
        self.assert_green()

    def test_each_switch_gets_its_own_row_with_the_p4info_sha_and_the_source(self):
        # The sha is the stable identifier -- the answer to "is this the program those entries
        # were written for" -- and `program` is where the source was when it was compiled.
        rows = self.rows()
        self.assertIn("build/firewall.json", rows["s1 pipeline"][1])
        self.assertIn("p4info sha256:", rows["s1 pipeline"][1])
        self.assertIn("firewall.p4", rows["s1 pipeline"][1])
        for switch in ("s2", "s3", "s4"):
            with self.subTest(switch=switch):
                self.assertIn("build/basic.json", rows[f"{switch} pipeline"][1])
        # s1 and s2 must not be reported as the same program.
        self.assertNotEqual(rows["s1 pipeline"][1], rows["s2 pipeline"][1])

    def test_the_printed_sha_is_the_p4infos_own(self):
        import hashlib

        with open(os.path.join(self.pkg, "build", "firewall.p4.p4info.txtpb"), "rb") as fh:
            want = hashlib.sha256(fh.read()).hexdigest()[:16]
        self.assertIn(f"p4info sha256:{want}", self.rows()["s1 pipeline"][1])

    def test_a_p4info_naming_a_table_the_bmv2_json_does_not_have_fails(self):
        # 🔴 The two halves must be one compile. There is no build id to compare, so what is
        # checked is containment: the json is the whole program, the p4info is its visible
        # subset. Dropping a table from the json is what a mismatched pair looks like.
        def drop_a_table(data):
            data["pipelines"][0]["tables"] = [
                t for t in data["pipelines"][0]["tables"]
                if t["name"] != "MyIngress.check_ports"]
        self.edit_bmv2("build/firewall.json", drop_a_table)
        self.assert_red("switches pipeline", "not one compile")

    def test_a_p4info_naming_an_action_the_bmv2_json_does_not_have_fails(self):
        self.edit_bmv2("build/firewall.json", lambda d: d.__setitem__(
            "actions", [a for a in d["actions"] if a["name"] != "MyIngress.set_direction"]))
        self.assert_red("switches pipeline", "not one compile")

    def test_a_missing_pipeline_file_fails_and_names_the_switch(self):
        os.remove(os.path.join(self.pkg, "build", "firewall.json"))
        self.assert_red("switches pipeline", "s1")

    def test_a_pipeline_that_is_a_list_rather_than_an_object_fails(self):
        # The phase-1 spelling. The two paths are not interchangeable: a swapped pair would
        # launch bmv2 on a p4info.
        self.edit_package(lambda d: d["switches"]["1"].__setitem__(
            "pipeline", ["build/firewall.p4.p4info.txtpb", "build/firewall.json"]))
        self.assert_red("switches pipeline", "not an object")

    def test_a_pipeline_missing_one_half_fails(self):
        self.edit_package(lambda d: d["switches"]["1"].__setitem__(
            "pipeline", {"bmv2_json": "build/firewall.json"}))
        self.assert_red("switches pipeline", "p4info")

    def test_entries_written_for_another_program_fail(self):
        # 🔴 s1 runs firewall.json, and its runtime file names firewall's p4info INSIDE the
        # file. Point it at basic's and every "entries match p4info" row above becomes true of
        # a program this switch is not running -- which is worse than a red row, because it
        # reads green.
        self.edit_entries("pod-topo/s1-runtime.json",
                          lambda d: d.__setitem__("p4info", "build/basic.p4.p4info.txtpb"))
        self.assert_red("entries p4info is the pipeline's", "not running")

    def test_entries_and_pipeline_agreeing_is_its_own_green_row(self):
        # The control for the row above: the shipped firewall package really does pair s1's
        # entries with firewall's p4info and s2-s4's with basic's.
        self.assertEqual(self.rows()["entries p4info is the pipeline's"][0], preflight.PASS)
        self.assertIn("4 switch(es)", self.rows()["entries p4info is the pipeline's"][1])

    # --- the rules the LOADER enforces, enforced here too ------------------------------------
    #
    # 🔴 A PRE-FLIGHT THAT IS MORE PERMISSIVE THAN THE LOADER IS WORSE THAN NONE. It hands the
    # operator a green table and then `ndt up p4 --app <dir>` dies inside app_package.load, over
    # a package this tool just approved, with `mn -c` possibly already run. Each of the two
    # cells below therefore asserts BOTH halves: red here, and refused by the real loader.

    def assert_loader_refuses(self):
        app_package = the_proxys_reader()
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.load(self.pkg)
        return str(caught.exception)

    def test_an_absolute_pipeline_path_fails_here_and_not_only_at_bring_up(self):
        absolute = os.path.join(self.pkg, "build", "firewall.json")
        self.edit_package(lambda d: d["switches"]["1"]["pipeline"].__setitem__(
            "bmv2_json", absolute))
        self.assert_red("switches pipeline", "absolute path")
        self.assertIn("absolute path", self.assert_loader_refuses())

    def test_a_pipeline_escaping_the_package_directory_fails_here_and_not_only_at_bring_up(self):
        # The file EXISTS, so existence is not what catches this.
        outside = os.path.join(self.tmp, "outside.json")
        with open(outside, "w", encoding="utf-8") as fh:
            fh.write("{}\n")
        self.edit_package(lambda d: d["switches"]["1"]["pipeline"].__setitem__(
            "bmv2_json", "../outside.json"))
        self.assert_red("switches pipeline", "OUTSIDE the package directory")
        self.assertIn("outside the package directory", self.assert_loader_refuses())

    def test_a_p4info_that_exists_but_does_not_parse_fails_by_name(self):
        # 🔴 "The file is there" is not "the file is a p4info". A truncated or half-written
        # p4info makes every id lookup the controller does come back empty, which arrives as
        # writes that are refused one at a time after the fabric is up.
        path = os.path.join(self.pkg, "build", "firewall.p4.p4info.txtpb")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("tables { preamble { name: \"unterminated\n")
        rows = self.rows()
        self.assertEqual(rows["switches pipeline"][0], preflight.FAIL, self.report().render())
        self.assertIn("pipeline.p4info", rows["switches pipeline"][1])
        self.assertIn("does not parse", rows["switches pipeline"][1])
        self.assertIn("s1", rows["switches pipeline"][1])

    def test_a_ternary_match_says_the_endpoint_answers_501(self):
        path = os.path.join(self.pkg, "build", "firewall.p4.p4info.txtpb")
        with open(path, encoding="utf-8") as fh:
            text = fh.read().replace("match_type: EXACT", "match_type: TERNARY", 1)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        self.assert_red("entries match p4info", "501")


class NdtwinPipelinePackage(PackageCase):
    """`--ndtwin-pipeline`: the phase-1 cell, still reachable and still green."""

    exercise = FIREWALL
    p4 = "basic.p4"
    ndtwin_pipeline = True

    def test_every_switch_is_null_and_the_row_says_so(self):
        self.assert_green()
        rows = {label: (status, detail) for status, label, detail in self.report().rows}
        self.assertEqual(rows["switches pipeline"][0], preflight.PASS)
        self.assertIn("all null", rows["switches pipeline"][1])

    def test_with_no_pipeline_the_entries_are_not_compared_to_one(self):
        # A null pipeline means NDTwin's own artefact, whose p4info an exercise's entries will
        # never name. Checking them against it would make every phase-1 package permanently red.
        labels = [label for _s, label, _d in self.report().rows]
        self.assertNotIn("entries p4info is the pipeline's", labels)
        self.assertIn("entries match p4info", labels)


class OneSwitchPackage(PackageCase):
    """exercises/calc: one switch, zero inter-switch links, and that is not an error."""

    exercise = CALC
    topology = "topology.json"
    p4 = "calc.p4"

    def test_a_single_switch_package_passes_every_check(self):
        self.assert_green()

    def test_the_zero_link_row_is_a_pass_not_a_failure(self):
        rows = {label: (status, detail) for status, label, detail in self.report().rows}
        self.assertEqual(rows["topo_from_json.switch_links"][0], preflight.PASS)
        self.assertEqual(rows["topo_from_json.switch_links"][1], "0 entries")
        self.assertIn("2 links in both", rows["links agree"][1])


class PackageRedCells(PackageCase):
    def test_a_non_null_pipeline_on_a_package_that_carries_none_fails(self):
        # The basic pod-topo package is converted with no --p4, so every switch is null. A
        # pipeline pointing at files it does not carry is refused rather than loaded by nobody.
        self.edit_package(lambda d: d["switches"]["1"].__setitem__(
            "pipeline", {"p4info": "build/a.p4info.txtpb", "bmv2_json": "build/a.json"}))
        self.assert_red("switches pipeline", "is not at")

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


# --- TICKET-P3 2.6: the multicast exercise, its PRE entries, and the telemetry word ------------


MULTICAST = os.path.join(FIXTURES, "multicast")


class TheMulticastExerciseCase(PackageCase):
    """exercises/multicast/sig-topo -- one switch, four hosts, and a group in its runtime file.

    [Co-developed with claude code -- Adam]
    The first fixture in this tree whose runtime file declares anything but `table_entries`, and
    the first one-switch topology with FOUR hosts. Both matter: `multicast_group_entries` used
    to be carried through convert by accident (the file is copied whole) and nothing said so,
    and a group that replicates to a port the model does not build is accepted by the PRE and
    then silently delivers to nobody.
    """

    exercise = MULTICAST
    topology = "sig-topo/topology.json"
    p4 = "multicast.p4"


class TheMulticastPackageIsGreen(TheMulticastExerciseCase):
    def test_it_converts_and_passes_every_check(self):
        self.assert_green()

    def test_the_groups_survive_the_conversion(self):
        # convert copies the runtime file whole; this is the assertion that "whole" includes the
        # key nothing else in the pipeline reads.
        with open(os.path.join(self.pkg, "sig-topo", "s1-runtime.json"), encoding="utf-8") as fh:
            entries = json.load(fh)
        self.assertEqual(len(entries["multicast_group_entries"]), 1)
        self.assertEqual(entries["multicast_group_entries"][0]["multicast_group_id"], 1)
        self.assertEqual([r["egress_port"] for r in
                          entries["multicast_group_entries"][0]["replicas"]], [1, 2, 3])

    def test_the_pre_entries_row_counts_them(self):
        self.assertEqual(self.statuses()["PRE entries"], preflight.PASS)
        row = [r for r in self.report().rows if r[1] == "PRE entries"][0]
        self.assertIn("1 multicast group", row[2])

    def test_a_replica_on_a_port_the_model_does_not_build_fails(self):
        # s1 has ports 1..4 (four hosts). Port 9 is accepted by the PRE, replicates into
        # nothing, and reads downstream as "the exercise's forwarding is broken".
        self.edit_entries("sig-topo/s1-runtime.json",
                          lambda d: d["multicast_group_entries"][0]["replicas"]
                          .append({"egress_port": 9, "instance": 1}))
        self.assert_red("PRE entries", "egress_port 9 is not a port s1 has")

    def test_a_group_id_of_zero_fails(self):
        self.edit_entries("sig-topo/s1-runtime.json",
                          lambda d: d["multicast_group_entries"][0]
                          .__setitem__("multicast_group_id", 0))
        self.assert_red("PRE entries", "positive integer")

    def test_a_group_with_no_replicas_fails(self):
        self.edit_entries("sig-topo/s1-runtime.json",
                          lambda d: d["multicast_group_entries"][0].__setitem__("replicas", []))
        self.assert_red("PRE entries", "drop every packet")

    def test_the_same_replica_twice_fails(self):
        self.edit_entries("sig-topo/s1-runtime.json",
                          lambda d: d["multicast_group_entries"][0]["replicas"]
                          .append({"egress_port": 1, "instance": 1}))
        self.assert_red("PRE entries", "declared twice")

    def test_the_same_port_with_a_second_instance_is_accepted(self):
        # Two copies out of one port IS something the PRE does. The duplicate check must not
        # refuse the exercise that wants it.
        self.edit_entries("sig-topo/s1-runtime.json",
                          lambda d: d["multicast_group_entries"][0]["replicas"]
                          .append({"egress_port": 1, "instance": 2}))
        self.assert_green()

    def test_a_clone_session_replica_may_name_the_cpu_port(self):
        # The CPU port is not a link, so no model edge names it -- and a clone session's whole
        # purpose is to replicate to it. A check that did not know that would fail every
        # package that declares one.
        self.edit_entries("sig-topo/s1-runtime.json",
                          lambda d: d.__setitem__("clone_session_entries", [
                              {"clone_session_id": 250,
                               "replicas": [{"egress_port": 255, "instance": 1}]}]))
        self.assert_green()

    def test_a_clone_session_replica_on_a_port_that_is_neither_fails(self):
        self.edit_entries("sig-topo/s1-runtime.json",
                          lambda d: d.__setitem__("clone_session_entries", [
                              {"clone_session_id": 250,
                               "replicas": [{"egress_port": 77, "instance": 1}]}]))
        self.assert_red("PRE entries", "neither a port s1 has")


class TheTelemetryWord(PackageCase):
    """`telemetry.source` -- the value domain, and the one combination that cannot work."""

    def test_a_package_that_declares_nothing_is_a_note_not_a_failure(self):
        self.assertEqual(self.statuses()["telemetry.source"], preflight.INFO)

    def test_each_word_in_the_domain_is_accepted(self):
        for word in ("auto", "none", "cooperative", "link"):
            with self.subTest(word=word):
                self.edit_package(lambda d, w=word: d.__setitem__("telemetry", {"source": w}))
                rows = {label: status for status, label, _d in self.report().rows if label}
                self.assertEqual(rows["telemetry.source"], preflight.PASS)

    def test_a_word_outside_the_domain_fails(self):
        self.edit_package(lambda d: d.__setitem__("telemetry", {"source": "sflow"}))
        self.assert_red("telemetry.source", "not one of")

    def test_a_telemetry_that_is_not_an_object_fails(self):
        self.edit_package(lambda d: d.__setitem__("telemetry", "link"))
        self.assert_red("telemetry")


class TheCooperativeRefusal(PackageCase):
    """A package that carries its own program AND asks for the cooperative path."""

    p4 = "solution/basic.p4"

    def test_cooperative_on_a_program_with_no_controller_header_fails(self):
        # 🔴 The case the proxy refuses to start on. Caught here, before the switches exist:
        # such a fabric comes up, accepts the clone session and reports zero samples for the
        # whole run with every step green.
        self.edit_package(lambda d: d.__setitem__("telemetry", {"source": "cooperative"}))
        self.assert_red("telemetry cooperative is possible", "cannot clone to the CPU port")

    def test_the_failure_names_the_way_out(self):
        self.edit_package(lambda d: d.__setitem__("telemetry", {"source": "cooperative"}))
        joined = " ".join(r[2] for r in self.report().rows if r[0] == preflight.FAIL)
        self.assertIn("ndtwin_telemetry.p4", joined)

    def test_link_on_the_same_package_is_fine(self):
        self.edit_package(lambda d: d.__setitem__("telemetry", {"source": "link"}))
        self.assert_green()

    def test_auto_on_the_same_package_is_fine(self):
        # `auto` resolves per switch, and a switch running somebody else's program resolves to
        # `link` -- so there is nothing to refuse.
        self.edit_package(lambda d: d.__setitem__("telemetry", {"source": "auto"}))
        self.assert_green()


class TheCooperativeIncludeIsAccepted(PackageCase):
    """The same package built from basic_telemetry -- the include's whole point."""

    exercise = os.path.join(FIXTURES, "basic_telemetry")
    topology = None                       # set in setUp: this fixture borrows basic's topology

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_exercise_preflight_telemetry_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        # basic_telemetry is a program, not an exercise: it has no topology of its own. So the
        # package is built from basic's pod-topo and then pointed at the telemetry program's
        # compiled artefacts -- which is exactly what an author who included the header would
        # have, and is the shape the refusal above must NOT fire on.
        self.pkg = os.path.join(self.tmp, "pkg")
        convert.convert(BASIC, "pod-topo/topology.json", self.pkg)
        build = os.path.join(self.pkg, "build")
        os.makedirs(build, exist_ok=True)
        for name in ("basic_telemetry.p4.p4info.txtpb", "basic_telemetry.json"):
            shutil.copy(os.path.join(self.exercise, "build", name),
                        os.path.join(build, name))
        self.edit_package(self._point_at_the_telemetry_program)

    @staticmethod
    def _point_at_the_telemetry_program(data):
        data["telemetry"] = {"source": "cooperative"}
        for spec in data["switches"].values():
            spec["pipeline"] = {"p4info": "build/basic_telemetry.p4.p4info.txtpb",
                                "bmv2_json": "build/basic_telemetry.json"}
            spec["entries"] = None

    def test_cooperative_is_possible_on_a_program_that_included_the_header(self):
        rows = {label: status for status, label, _d in self.report().rows if label}
        self.assertEqual(rows["telemetry cooperative is possible"], preflight.PASS)


# --- roles.ipv4_route (TICKET-P4-roles section 2.1) ---------------------------------------------
#
# [Co-developed with claude code -- Adam]
# Pre-flight runs the proxy's own two functions -- app_package.parse_roles for the shape,
# route_binding.resolve for every foreign switch's p4info -- so a green row here is a switch the
# proxy will bind, and a red one is a startup it will refuse with the same sentence.

REPO = common.REPO
RENAMED = os.path.join(REPO, "p4_proxy", "tests", "fixtures", "renamed_route")
BASIC_FLAG = ("owner=ndtwin,table=MyIngress.ipv4_lpm,match_field=hdr.ipv4.dstAddr,"
              "action=MyIngress.ipv4_forward,dst_mac=dstAddr,port=port")
RENAMED_FLAG = ("owner=ndtwin,table=RouteIngress.dest_routes,match_field=hdr.ip4.dst,"
                "action=RouteIngress.send_via,dst_mac=next_mac,port=out_port")
BASIC_ROLE = {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm",
              "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward",
              "params": {"dst_mac": "dstAddr", "port": "port"}}


class RolesCase(PackageCase):
    """A package converted WITH --role-ipv4-route (or without, when `flag` is None)."""

    p4 = "solution/basic.p4"
    flag = BASIC_FLAG

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_exercise_preflight_roles_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.pkg = os.path.join(self.tmp, "pkg")
        convert.convert(self.exercise, self.topology, self.pkg, p4_rel=self.p4,
                        role_ipv4_route=(None if self.flag is None
                                         else convert.parse_role_flag(self.flag)))

    def row(self, label):
        rows = [r for r in self.report().rows if r[1] == label]
        self.assertTrue(rows, f"no {label!r} row in:\n{self.report().render()}")
        return rows[0]


class BasicWithRolesTest(RolesCase):
    def test_a_converted_owned_package_passes_every_check(self):
        self.assert_green()

    def test_the_binding_row_names_what_every_switch_resolved_to(self):
        status, _label, detail = self.row("roles.ipv4_route resolves")
        self.assertEqual(status, preflight.PASS)
        self.assertIn("4 switch(es): MyIngress.ipv4_lpm hdr.ipv4.dstAddr -> "
                      "MyIngress.ipv4_forward(dstAddr, port bit<9>), owner ndtwin", detail)

    def test_the_kept_default_action_is_disclosed_not_refused(self):
        status, _label, detail = self.row("owned table default action")
        self.assertEqual(status, preflight.INFO)
        self.assertIn("s1 entry 0: default action MyIngress.drop", detail)

    def test_no_suggestion_is_printed_for_a_package_that_declared_its_roles(self):
        self.assertNotIn("roles suggestion", self.statuses())

    def test_the_owned_tables_match_entries_fail_and_each_one_is_named(self):
        # 2.1-5 / ruling 8-1: put basic's own four routes back into s1 and s2.
        for n in (1, 2):
            original = common.load_json(os.path.join(BASIC, f"pod-topo/s{n}-runtime.json"))
            path = os.path.join(self.pkg, f"pod-topo/s{n}-runtime.json")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(common.dumps(original))
        report = self.report()
        failed = [d for status, label, d in report.rows if status == preflight.FAIL]
        self.assert_red("owned table has no package entries", "8 match entries")
        named = [d for d in failed if "MyIngress.ipv4_lpm" in d and "-> MyIngress.ipv4_forward"
                 in d]
        self.assertEqual(len(named), 8, report.render())
        self.assertTrue(any(d.startswith("s2 entry 4") or "s2 entry 4:" in d for d in named))

    def test_a_dst_mac_that_is_not_48_bits_fails_here_before_the_proxy_refuses(self):
        self.edit_package(lambda d: d["roles"]["ipv4_route"]["params"].update(
            dst_mac="port", port="dstAddr"))
        self.assert_red("roles.ipv4_route resolves", "is 9 bits; a MAC address is 48")

    def test_a_table_the_program_does_not_have_fails_and_names_the_switch(self):
        self.edit_package(lambda d: d["roles"]["ipv4_route"].update(table="MyIngress.routes"))
        self.assert_red("roles.ipv4_route resolves", "s1: roles.ipv4_route.table")

    def test_a_shape_the_loader_refuses_is_refused_here_with_the_loaders_sentence(self):
        self.edit_package(lambda d: d["roles"]["ipv4_route"].update(priority=5))
        self.assert_red("roles", "unknown ['priority']")

    def test_the_message_is_the_one_the_proxy_raises(self):
        # One function, two callers (2.1-4): the row IS route_binding's exception text.
        route_binding = common.import_route_binding()
        self.edit_package(lambda d: d["roles"]["ipv4_route"].update(action="MyIngress.fwd"))
        report = self.report()
        detail = [r[2] for r in report.rows if r[1] == "roles.ipv4_route resolves"][0]
        p4info = preflight.P4InfoIndex.parse(
            os.path.join(self.pkg, "build", "basic.p4.p4info.txtpb")).p4info
        with self.assertRaises(route_binding.RouteBindingError) as caught:
            route_binding.resolve(dict(BASIC_ROLE, action="MyIngress.fwd"), p4info,
                                  max_port=4, where="s1: roles.ipv4_route")
        self.assertIn(str(caught.exception), detail)


class RenamedRolesTest(RolesCase):
    exercise = RENAMED
    p4 = "renamed_route.p4"
    flag = RENAMED_FLAG

    def test_the_renamed_package_passes_and_binds_the_renamed_names(self):
        self.assert_green()
        _status, _label, detail = self.row("roles.ipv4_route resolves")
        self.assertIn("RouteIngress.dest_routes hdr.ip4.dst -> "
                      "RouteIngress.send_via(next_mac, out_port bit<8>)", detail)

    def test_a_port_too_narrow_for_the_topology_fails_here(self):
        # The model is what the proxy sizes the port against; give s1 a port 300.
        def widen(model):
            for edge in model["edges"]:
                if edge["src_dpid"] == 1 and edge["src_interface"] == 4:
                    edge["src_interface"] = 300
                if edge["dst_dpid"] == 1 and edge["dst_interface"] == 4:
                    edge["dst_interface"] = 300
        self.edit_model(widen)
        self.assert_red("roles.ipv4_route resolves",
                        "out_port is 8 bits and the topology gives this switch port 300")

    def test_the_owned_table_rows_speak_only_of_the_switches_whose_binding_resolved(self):
        # s1 cannot bind (port 300 in an 8-bit field) and carries its own dest_routes entries
        # again; the resolve row already fails for s1. The owned-table rows are about the three
        # switches NDTwin would bind -- not a second verdict on the one it will not.
        def widen(model):
            for edge in model["edges"]:
                if edge["src_dpid"] == 1 and edge["src_interface"] == 4:
                    edge["src_interface"] = 300
                if edge["dst_dpid"] == 1 and edge["dst_interface"] == 4:
                    edge["dst_interface"] = 300
        self.edit_model(widen)
        original = common.load_json(os.path.join(RENAMED, "pod-topo/s1-runtime.json"))
        with open(os.path.join(self.pkg, "pod-topo/s1-runtime.json"), "w",
                  encoding="utf-8") as fh:
            fh.write(common.dumps(original))
        report = self.report()
        self.assertEqual([d for status, _label, d in report.rows
                          if status == preflight.FAIL and "s1 entry" in d], [], report.render())
        status, _label, detail = self.row("owned table has no package entries")
        self.assertEqual((status, detail),
                         (preflight.PASS, "RouteIngress.dest_routes is NDTwin's on 3 switch(es)"))


class TheSuggestionTest(RolesCase):
    """2.1-6: the heuristic, here and only here -- one INFO line, never fatal."""

    flag = None

    def test_a_foreign_route_shaped_table_without_roles_gets_one_pasteable_line(self):
        status, _label, detail = self.row("roles suggestion")
        self.assertEqual(status, preflight.INFO)
        block = detail.split('"roles": ', 1)[1].rsplit(" (owner ndtwin", 1)[0]
        self.assertEqual(json.loads(block), {"ipv4_route": BASIC_ROLE})

    def test_the_suggestion_is_not_a_failure(self):
        self.assert_green()

    def test_there_is_exactly_one_suggestion_row(self):
        self.assertEqual(len([r for r in self.report().rows if r[1] == "roles suggestion"]), 1)


class NoSuggestionWhereNothingFitsTest(RolesCase):
    exercise = CALC
    topology = "topology.json"
    p4 = "calc.p4"
    flag = None

    def test_calc_has_no_route_table_so_nothing_is_suggested(self):
        self.assertNotIn("roles suggestion", self.statuses())


class NoSuggestionOnNdtwinsOwnPipelineTest(RolesCase):
    p4 = None
    flag = None

    def test_an_all_null_package_gets_no_suggestion(self):
        self.assertNotIn("roles suggestion", self.statuses())


class ReverseControlsTest(RolesCase):
    """ANALYSIS section 3's four that cannot bind ipv4_lpm, from the fixtures that exist here:
    a roles block naming ipv4_lpm must FAIL and say what is missing (TICKET 5-3)."""

    flag = None

    def fails_on(self, exercise, topology, p4):
        pkg = os.path.join(self.tmp, os.path.basename(exercise))
        convert.convert(exercise, topology, pkg, p4_rel=p4)
        path = os.path.join(pkg, "package.json")
        data = common.load_json(path)
        data["roles"] = {"ipv4_route": BASIC_ROLE}
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(common.dumps(data))
        report = preflight.run(pkg, compile_p4=False)
        return {label: (status, detail) for status, label, detail in report.rows if label}

    def test_calc_has_no_ipv4_lpm_and_says_so(self):
        rows = self.fails_on(CALC, "topology.json", "calc.p4")
        self.assertEqual(rows["roles.ipv4_route resolves"][0], preflight.FAIL)
        self.assertIn("'MyIngress.ipv4_lpm' is not a table of this pipeline",
                      rows["roles.ipv4_route resolves"][1])

    def test_no_owned_table_row_is_claimed_for_a_table_the_program_does_not_have(self):
        rows = self.fails_on(CALC, "topology.json", "calc.p4")
        self.assertNotIn("owned table has no package entries", rows)

    def test_multicast_has_no_ipv4_lpm_and_says_so(self):
        rows = self.fails_on(os.path.join(FIXTURES, "multicast"), "sig-topo/topology.json",
                             "multicast.p4")
        self.assertEqual(rows["roles.ipv4_route resolves"][0], preflight.FAIL)
        self.assertIn("is not a table of this pipeline", rows["roles.ipv4_route resolves"][1])


class FirewallWithRolesTest(RolesCase):
    """firewall: s1 runs firewall.p4, s2-s4 basic.p4 -- one roles block, resolved per p4info
    (2.1-3), and every switch passes because both programs declare the table."""

    exercise = FIREWALL
    p4 = "basic.p4"

    def test_one_block_resolves_on_both_programs(self):
        self.assert_green()
        self.assertIn("4 switch(es)", self.row("roles.ipv4_route resolves")[2])


if __name__ == "__main__":
    unittest.main(verbosity=2)
