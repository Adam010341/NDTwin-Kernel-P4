"""What `app_package` says the fabric is, and what it refuses to say.

[Co-developed with claude code -- Adam]

🔴 THE FIRST CLASS IS THE POINT OF THE WHOLE FEATURE. Every literal this module replaced -- the
election id, the CPU port, the two pipeline artefact paths, the /24, the gRPC base, the topology
choice, the host commands -- is asserted here against the value it had before anything moved, one
assertion per value. "With no package the fabric behaves exactly as it did" is not a claim in a
commit message; it is `BaselineIsTheLiteralsItReplacedTest`, and it goes red the moment one of
those literals drifts.

The rest is refusals. A package that cannot be built is refused HERE -- before `mn -c` tears down
a running fabric, before a switch is started, before a pingall reports 100% loss that an operator
then debugs as a data-plane bug. Each refusal has its own test naming its own field, because a
single `test_bad_packages_are_refused` is green whichever of the eight checks is doing the work.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests" -- a pytest-style module runs as a script that asserts
nothing and is reported as NO TESTS RAN.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
REPO = os.path.dirname(PROXY_DIR)
sys.path.insert(0, os.path.join(PROXY_DIR, "mininet"))

import app_package  # noqa: E402
import topo_from_json  # noqa: E402

FOUR_HOST_MODEL = os.path.join(REPO, "setting", "StaticNetworkTopologyP4_10Switches_4Hosts.json")
HOST_128_MODEL = os.path.join(REPO, "setting", "StaticNetworkTopologyP4_10Switches_128Hosts.json")


# --- the baseline ---------------------------------------------------------------------------


class BaselineIsTheLiteralsItReplacedTest(unittest.TestCase):
    """
    One test per replaced literal. The value on the right of each assertion is transcribed from
    the site the reader replaced, named in the test, not from app_package's own constants -- a
    test that compared a constant against itself would be green for any value at all.
    """

    def setUp(self):
        self.pkg = app_package.baseline()

    def test_the_baseline_election_id_is_the_literal_zero_one(self):
        # p4_client.py start(): `req.arbitration.election_id.high = 0` / `.low = 1`, and the
        # same pair on each of the eight unary requests.
        self.assertEqual(self.pkg.election_id, (0, 1))

    def test_the_baseline_cpu_port_is_the_literal_255(self):
        # p4_testbed_topo.py BMv2Switch.start(): `args.append('255')` after '--cpu-port'.
        self.assertEqual(self.pkg.cpu_port, 255)

    def test_the_baseline_pipeline_is_ndtwins_own_two_artefacts(self):
        # main.build_p4_client's p4info_path and json_path, and MultiSwitchTopo's json_path.
        self.assertEqual(
            self.pkg.pipeline,
            ("p4_src/build/ndtwin_switch.p4info.txt", "p4_src/build/ndtwin_switch.json"))

    def test_the_baseline_pipeline_resolves_under_the_proxy_root_for_every_switch(self):
        # The same two paths main.build_p4_client used to os.path.join by hand, for any dpid:
        # phase 1 has no per-switch pipeline, and a package that appeared to have one would be
        # running on NDTwin's pipeline while looking as though it ran on its own.
        for dpid in (1, 7, 10):
            self.assertEqual(
                self.pkg.pipeline_for(dpid, "/base"),
                ("/base/p4_src/build/ndtwin_switch.p4info.txt",
                 "/base/p4_src/build/ndtwin_switch.json"))

    def test_the_baseline_host_prefix_length_is_the_literal_24(self):
        # p4_testbed_topo.py MultiSwitchTopo: `self.addHost(name, ip=f"{ip}/24", ...)`.
        self.assertEqual(self.pkg.prefix_len, 24)
        self.assertEqual(self.pkg.host_prefix_len("h1"), 24)

    def test_the_baseline_grpc_base_is_the_one_grpc_ports_declares(self):
        # grpc_ports.GRPC_PORT_BASE. Compared against the module rather than against 30050 so
        # that moving the block (F-15 moved it once already) cannot leave this file behind.
        import grpc_ports
        self.assertEqual(self.pkg.grpc_base, grpc_ports.GRPC_PORT_BASE)
        self.assertEqual(self.pkg.grpc_base, 30050)

    def test_the_baseline_names_no_topology_so_the_host_count_still_picks_one(self):
        # `topology is None` is what makes app_package.topology_path fall through to
        # topo_from_json.model_path -- i.e. to the rule the fabric has always used.
        self.assertIsNone(self.pkg.topology)
        self.assertEqual(app_package.topology_path(self.pkg, 4), FOUR_HOST_MODEL)
        self.assertEqual(app_package.topology_path(self.pkg, 128), HOST_128_MODEL)

    def test_the_baseline_runs_no_host_commands_and_says_so_with_none_not_empty(self):
        # None means "there is no package, run the all-pairs static ARP you have always run".
        # {} would mean "a package asked for nothing", which would turn that ARP fan-out off.
        self.assertIsNone(self.pkg.host_commands())

    def test_the_baseline_control_plane_is_ndtwins_own_and_writes(self):
        self.assertEqual(self.pkg.mode, "ndtwin")
        self.assertTrue(self.pkg.arbitration)
        self.assertFalse(self.pkg.read_only)

    def test_the_baseline_device_id_scheme_is_the_dpid(self):
        self.assertEqual(self.pkg.device_id, "dpid")

    def test_the_baseline_declares_no_package_directory_and_no_entries(self):
        self.assertIsNone(self.pkg.dir)
        self.assertTrue(self.pkg.is_baseline)
        self.assertEqual(self.pkg.entries_recorded(), {})
        self.assertEqual(self.pkg.links, ())

    def test_no_knob_file_means_the_baseline(self):
        with tempfile.TemporaryDirectory() as d:
            missing = os.path.join(d, "app_package_override")
            self.assertIsNone(app_package.read_knob(missing))
            self.assertEqual(app_package.current(missing), app_package.baseline())


class TheSwitchListComesFromTheModelTest(unittest.TestCase):
    """
    `DEFAULT_SWITCH_DPIDS` and MultiSwitchTopo's switch loop were both `range(1, 11)`. Both now
    read the model, and both baseline models say the same ten -- which is the statement that
    makes the replacement a refactor rather than a new fabric.
    """

    def test_both_baseline_models_declare_dpids_one_to_ten(self):
        for path in (FOUR_HOST_MODEL, HOST_128_MODEL):
            model = topo_from_json.load(path)
            got = tuple(dpid for dpid, _ in topo_from_json.switches(model))
            self.assertEqual(got, tuple(range(1, 11)), f"{os.path.basename(path)}")

    def test_both_baseline_models_name_their_switches_s1_to_s10(self):
        for path in (FOUR_HOST_MODEL, HOST_128_MODEL):
            model = topo_from_json.load(path)
            got = [name for _dpid, name in topo_from_json.switches(model)]
            self.assertEqual(got, [f"s{i}" for i in range(1, 11)])


# --- the knob -------------------------------------------------------------------------------


def write_knob(directory, text):
    path = os.path.join(directory, "app_package_override")
    with open(path, "w") as fh:
        fh.write(text)
    return path


class TheKnobTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_knob_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.package = build_package(self.tmp)

    def test_a_knob_naming_a_package_directory_is_read(self):
        knob = write_knob(self.tmp, self.package + "\n")
        self.assertEqual(app_package.read_knob(knob), self.package)

    def test_comments_and_blank_lines_are_ignored_like_the_sibling_override_files(self):
        knob = write_knob(self.tmp, f"# was: /old/pkg\n\n   \n{self.package}\n/second/pkg\n")
        self.assertEqual(app_package.read_knob(knob), self.package)

    def test_a_relative_path_is_refused_rather_than_resolved_against_some_cwd(self):
        knob = write_knob(self.tmp, "packages/basic\n")
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.read_knob(knob)
        self.assertIn("absolute", str(caught.exception))

    def test_a_directory_that_does_not_exist_is_refused(self):
        knob = write_knob(self.tmp, os.path.join(self.tmp, "nope") + "\n")
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.read_knob(knob)
        self.assertIn("does not exist", str(caught.exception))

    def test_a_knob_that_exists_but_says_nothing_is_refused_not_treated_as_baseline(self):
        # `ndt down` removes the file. A file with no directive is a write that stopped
        # halfway, and answering "baseline" to it silently runs the wrong fabric.
        knob = write_knob(self.tmp, "# nothing here\n\n")
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.read_knob(knob)
        self.assertIn("names no package directory", str(caught.exception))

    def test_a_knob_naming_a_package_is_the_package_not_the_baseline(self):
        # The whole knob-to-package path in one assertion: if `current` ignored the knob, every
        # other test here would still pass and the feature would do nothing.
        knob = write_knob(self.tmp, self.package + "\n")
        got = app_package.current(knob)
        self.assertEqual(got.dir, self.package)
        self.assertFalse(got.is_baseline)
        self.assertNotEqual(got, app_package.baseline())


# --- packages -------------------------------------------------------------------------------


MANIFEST = {
    "format": 1,
    "name": "basic",
    "source": {"kind": "p4lang-tutorials", "exercise_dir": "/nonexistent/exercises/basic"},
    "topology": "ndtwin/topology.json",
    "hosts": {
        "h1": {"ip": "10.0.0.1", "prefix_len": 24, "mac": "08:00:00:00:01:11",
               "commands": ["route add default gw 10.0.0.10 dev eth0"]},
        "h2": {"ip": "10.0.0.2", "prefix_len": 24, "mac": "08:00:00:00:02:22", "commands": []},
    },
    "switches": {
        "1": {"name": "s1", "pipeline": None, "entries": "s1-runtime.json"},
        "2": {"name": "s2", "pipeline": None, "entries": None},
    },
    "control_plane": {"mode": "ndtwin", "election_id": [0, 65535], "grpc_base": 30050,
                      "device_id": "dpid"},
    "bmv2": {"cpu_port": 255},
    "links": [{"a": ["h1", 1], "b": ["s1", 1], "bandwidth_bps": 1000000000}],
}

RUNTIME = {"target": "bmv2", "p4info": "build/basic.p4.p4info.txtpb",
           "table_entries": [{"table": "MyIngress.ipv4_lpm"}, {"table": "MyIngress.ipv4_lpm"},
                             {"table": "MyIngress.ipv4_lpm"}]}


def build_package(root, manifest=None, runtime=None, name="pkg"):
    """A valid package on disk, whose topology is the real 4-host model. Returns its path."""
    directory = os.path.join(root, name)
    os.makedirs(os.path.join(directory, "ndtwin"), exist_ok=True)
    shutil.copyfile(FOUR_HOST_MODEL, os.path.join(directory, "ndtwin", "topology.json"))
    with open(os.path.join(directory, "s1-runtime.json"), "w") as fh:
        json.dump(RUNTIME if runtime is None else runtime, fh)
    with open(os.path.join(directory, "package.json"), "w") as fh:
        json.dump(MANIFEST if manifest is None else manifest, fh)
    return directory


def with_manifest(**changes):
    """MANIFEST with top-level keys replaced. Deep-copied so tests cannot leak into each other."""
    doc = json.loads(json.dumps(MANIFEST))
    doc.update(changes)
    return doc


class AValidPackageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_ok_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.pkg = app_package.load(build_package(self.tmp))

    def test_its_topology_is_an_absolute_path_inside_the_package(self):
        self.assertTrue(os.path.isabs(self.pkg.topology))
        self.assertTrue(self.pkg.topology.endswith(os.path.join("ndtwin", "topology.json")))

    def test_its_topology_wins_over_the_host_count_rule(self):
        self.assertEqual(app_package.topology_path(self.pkg, 4), self.pkg.topology)
        # ... and the host count it would otherwise have used is not even consulted: 7 hosts
        # matches no model at all, and this must not raise.
        self.assertEqual(app_package.topology_path(self.pkg, 7), self.pkg.topology)

    def test_its_election_id_is_the_packages_not_the_baselines(self):
        self.assertEqual(self.pkg.election_id, (0, 65535))
        self.assertNotEqual(self.pkg.election_id, app_package.baseline().election_id)

    def test_its_host_commands_are_a_dict_even_when_one_host_asked_for_none(self):
        self.assertEqual(self.pkg.host_commands(),
                         {"h1": ["route add default gw 10.0.0.10 dev eth0"], "h2": []})

    def test_its_entries_are_counted_and_reported_as_recorded_not_applied(self):
        self.assertEqual(self.pkg.entries_recorded(), {"1": 3, "2": 0})

    def test_it_still_runs_ndtwins_own_pipeline_because_g4_is_not_built(self):
        self.assertEqual(self.pkg.pipeline, app_package.baseline().pipeline)

    def test_an_ndtwin_mode_package_still_arbitrates(self):
        self.assertTrue(self.pkg.arbitration)
        self.assertFalse(self.pkg.read_only)

    def test_switch_names_come_from_the_package(self):
        self.assertEqual(self.pkg.switch_names(), {1: "s1", 2: "s2"})

    def test_links_are_recorded_verbatim_and_applied_by_nobody(self):
        self.assertEqual(len(self.pkg.links), 1)
        self.assertEqual(self.pkg.links[0]["bandwidth_bps"], 1000000000)


class AnExternalPackageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_ext_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        doc = with_manifest(control_plane={"mode": "external"})
        self.pkg = app_package.load(build_package(self.tmp, manifest=doc))

    def test_it_reads_only(self):
        self.assertEqual(self.pkg.mode, "external")
        self.assertTrue(self.pkg.read_only)
        self.assertFalse(self.pkg.arbitration)

    def test_it_still_gets_an_election_id_even_though_it_will_not_bid_one(self):
        # Carried rather than dropped: a reader of `ndt status` should be able to see what the
        # package declared, and the field is what makes switching mode back to `ndtwin` a
        # one-word edit rather than a schema change.
        self.assertEqual(self.pkg.election_id, app_package.PACKAGE_DEFAULT_ELECTION_ID)


class RefusalTest(unittest.TestCase):
    """One refusal per test, each naming the field it is about."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_bad_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def refuses(self, manifest, fragment, runtime=None):
        directory = build_package(self.tmp, manifest=manifest, runtime=runtime,
                                  name=f"pkg_{len(os.listdir(self.tmp))}")
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.load(directory)
        self.assertIn(fragment, str(caught.exception))
        return str(caught.exception)

    def test_a_directory_that_is_not_a_package_is_refused(self):
        with self.assertRaises(app_package.AppPackageError):
            app_package.load(os.path.join(self.tmp, "not-here"))

    def test_a_manifest_that_is_not_json_is_refused(self):
        directory = build_package(self.tmp)
        with open(os.path.join(directory, "package.json"), "w") as fh:
            fh.write("{not json")
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.load(directory)
        self.assertIn("not valid JSON", str(caught.exception))

    def test_another_format_version_is_refused_rather_than_read_with_todays_meanings(self):
        self.refuses(with_manifest(format=2), "'format' must be 1")

    def test_a_missing_topology_field_is_refused(self):
        doc = with_manifest()
        del doc["topology"]
        self.refuses(doc, "'topology' is missing")

    def test_a_topology_file_that_is_not_there_is_refused(self):
        self.refuses(with_manifest(topology="ndtwin/nope.json"), "does not exist")

    def test_a_host_whose_name_does_not_match_its_address_is_refused(self):
        # 🔴 topo_from_json.hosts() names a host from the LAST OCTET of its address. An h3 at
        # 10.0.1.7 means half the fabric calls it h3 and half calls it h7, and nothing reports it.
        doc = with_manifest(hosts={"h3": {"ip": "10.0.1.7"}})
        message = self.refuses(doc, "does not match the last octet")
        self.assertIn("h3", message)

    def test_a_host_not_named_h_something_is_refused(self):
        self.refuses(with_manifest(hosts={"server1": {"ip": "10.0.0.1"}}), "must be h<N>")

    def test_a_host_with_no_address_is_refused(self):
        self.refuses(with_manifest(hosts={"h1": {"mac": "08:00:00:00:01:11"}}), "'ip' is missing")

    def test_an_impossible_prefix_length_is_refused(self):
        self.refuses(with_manifest(hosts={"h1": {"ip": "10.0.0.1", "prefix_len": 33}}),
                     "prefix_len must be an integer 1..32")

    def test_host_commands_that_are_not_strings_are_refused(self):
        self.refuses(with_manifest(hosts={"h1": {"ip": "10.0.0.1", "commands": [{"run": "x"}]}}),
                     "commands must be a list of strings")

    def test_a_per_switch_pipeline_is_refused_because_g4_is_not_built(self):
        doc = with_manifest(switches={"1": {"name": "s1",
                                            "pipeline": ["basic.p4info.txt", "basic.json"]}})
        message = self.refuses(doc, "pipeline must be null")
        self.assertIn("G4", message)

    def test_a_switch_key_that_is_not_a_dpid_is_refused(self):
        self.refuses(with_manifest(switches={"s1": {"name": "s1", "pipeline": None}}),
                     "must be positive integers")

    def test_two_switches_with_one_name_are_refused(self):
        doc = with_manifest(switches={"1": {"name": "s1", "pipeline": None},
                                      "2": {"name": "s1", "pipeline": None}})
        self.refuses(doc, "are both named")

    def test_an_entries_file_that_is_not_there_is_refused(self):
        doc = with_manifest(switches={"1": {"name": "s1", "pipeline": None,
                                            "entries": "s9-runtime.json"}})
        self.refuses(doc, "does not exist")

    def test_an_entries_file_that_cannot_be_parsed_is_refused_rather_than_counted_as_zero(self):
        directory = build_package(self.tmp, name="pkg_unparseable")
        with open(os.path.join(directory, "s1-runtime.json"), "w") as fh:
            fh.write("{oops")
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.load(directory)
        self.assertIn("not readable JSON", str(caught.exception))

    def test_an_unknown_control_plane_mode_is_refused(self):
        self.refuses(with_manifest(control_plane={"mode": "observer"}),
                     "control_plane.mode must be one of")

    def test_a_zero_election_id_is_refused_because_it_is_not_a_bid(self):
        self.refuses(with_manifest(control_plane={"mode": "ndtwin", "election_id": [0, 0]}),
                     "non-zero")

    def test_a_grpc_base_other_than_the_fabrics_is_refused(self):
        message = self.refuses(
            with_manifest(control_plane={"mode": "ndtwin", "grpc_base": 50050}),
            "control_plane.grpc_base must be 30050")
        self.assertIn("F-15", message)

    def test_a_device_id_scheme_other_than_the_dpid_is_refused(self):
        self.refuses(with_manifest(control_plane={"mode": "ndtwin", "device_id": "index"}),
                     "control_plane.device_id must be 'dpid'")

    def test_a_cpu_port_outside_bmv2s_range_is_refused(self):
        self.refuses(with_manifest(bmv2={"cpu_port": 99999}), "cpu_port must be an integer")


# --- the contract with the converter ---------------------------------------------------------
#
# [Co-developed with claude code -- Adam]
#
# 🔴 THESE TWO MANIFESTS ARE TRANSCRIBED FROM WHAT `tools/p4_exercise/convert.py` ACTUALLY
# WROTE, byte-for-byte in structure, not from TICKET-P1 section 1. The ticket is the agreement;
# these are the artefact, and they differ from the ticket in three ways that would each have
# been a refusal:
#
#   1. every referenced path is relative to the package directory, because convert.py now COPIES
#      the exercise's files in (`<pkg>/pod-topo/s1-runtime.json`, `<pkg>/build/basic.p4.p4info.txtpb`)
#      so a package no longer depends on ~/tutorials being present;
#   2. `source` carries keys the ticket did not list -- `p4info`, `bmv2_json`, `controller`.
#      `controller` is EXERCISE-relative, not package-relative, and this reader must not resolve
#      or check it;
#   3. `links[]` entries may carry `delay_ms` beside `bandwidth_bps`.
#
# The two packages themselves are not in version control (they are build output under another
# worktree), so the manifests are vendored here instead of read from disk. A test that skipped
# when a scratch directory was missing would be a partial skip, which
# tools/test_workflow/l1_unit_tests.sh fails on purpose -- and a contract held only in somebody's
# scratch directory is a contract nobody can re-check.

CONVERTER_BASIC = {
    "bmv2": {"cpu_port": 255},
    "control_plane": {"device_id": "dpid", "election_id": [0, 65535], "grpc_base": 30050,
                      "mode": "ndtwin"},
    "format": 1,
    "hosts": {
        "h1": {"commands": ["route add default gw 10.0.1.10 dev eth0",
                            "arp -i eth0 -s 10.0.1.10 08:00:00:00:01:00"],
               "ip": "10.0.1.1", "mac": "08:00:00:00:01:11", "prefix_len": 24},
        "h2": {"commands": ["route add default gw 10.0.2.20 dev eth0",
                            "arp -i eth0 -s 10.0.2.20 08:00:00:00:02:00"],
               "ip": "10.0.2.2", "mac": "08:00:00:00:02:22", "prefix_len": 24},
        "h3": {"commands": ["route add default gw 10.0.3.30 dev eth0",
                            "arp -i eth0 -s 10.0.3.30 08:00:00:00:03:00"],
               "ip": "10.0.3.3", "mac": "08:00:00:00:03:33", "prefix_len": 24},
        "h4": {"commands": ["route add default gw 10.0.4.40 dev eth0",
                            "arp -i eth0 -s 10.0.4.40 08:00:00:00:04:00"],
               "ip": "10.0.4.4", "mac": "08:00:00:00:04:44", "prefix_len": 24},
    },
    "links": [
        {"a": ["h1", 1], "b": ["s1", 1], "bandwidth_bps": 1000000000},
        {"a": ["h2", 1], "b": ["s1", 2], "bandwidth_bps": 1000000000},
        {"a": ["s1", 3], "b": ["s3", 1], "bandwidth_bps": 1000000000},
        {"a": ["s1", 4], "b": ["s4", 2], "bandwidth_bps": 1000000000},
        {"a": ["h3", 1], "b": ["s2", 1], "bandwidth_bps": 1000000000},
        {"a": ["h4", 1], "b": ["s2", 2], "bandwidth_bps": 1000000000},
        {"a": ["s2", 3], "b": ["s4", 1], "bandwidth_bps": 1000000000},
        {"a": ["s2", 4], "b": ["s3", 2], "bandwidth_bps": 1000000000},
    ],
    "name": "basic",
    "source": {"bmv2_json": "build/basic.json", "controller": None,
               "exercise_dir": "/home/adam/tutorials/exercises/basic", "kind": "p4lang-tutorials",
               "p4": "solution/basic.p4", "p4info": "build/basic.p4.p4info.txtpb",
               "topology_json": "pod-topo/topology.json"},
    "switches": {
        "1": {"entries": "pod-topo/s1-runtime.json", "name": "s1", "pipeline": None},
        "2": {"entries": "pod-topo/s2-runtime.json", "name": "s2", "pipeline": None},
        "3": {"entries": "pod-topo/s3-runtime.json", "name": "s3", "pipeline": None},
        "4": {"entries": "pod-topo/s4-runtime.json", "name": "s4", "pipeline": None},
    },
    "topology": "ndtwin/topology.json",
}

CONVERTER_P4RUNTIME = {
    "bmv2": {"cpu_port": 255},
    "control_plane": {"device_id": "dpid", "election_id": [0, 65535], "grpc_base": 30050,
                      "mode": "external"},
    "format": 1,
    "hosts": {
        "h1": {"commands": ["route add default gw 10.0.1.10 dev eth0"],
               "ip": "10.0.1.1", "mac": "08:00:00:00:01:11", "prefix_len": 24},
        "h2": {"commands": ["route add default gw 10.0.2.20 dev eth0"],
               "ip": "10.0.2.2", "mac": "08:00:00:00:02:22", "prefix_len": 24},
        "h3": {"commands": ["route add default gw 10.0.3.30 dev eth0"],
               "ip": "10.0.3.3", "mac": "08:00:00:00:03:33", "prefix_len": 24},
    },
    # `delay_ms` is the third divergence: tutorials links carry a latency, and convert.py records
    # it. Phase 1 applies no shaping (G2-C is phase 3), so this is carried and not read.
    "links": [
        {"a": ["h1", 1], "b": ["s1", 1], "bandwidth_bps": 1000000000, "delay_ms": 0.5},
        {"a": ["s1", 2], "b": ["s2", 2], "bandwidth_bps": 1000000000},
        {"a": ["s1", 3], "b": ["s3", 2], "bandwidth_bps": 1000000000},
        {"a": ["s3", 3], "b": ["s2", 3], "bandwidth_bps": 1000000000},
        {"a": ["h2", 1], "b": ["s2", 1], "bandwidth_bps": 1000000000},
        {"a": ["h3", 1], "b": ["s3", 1], "bandwidth_bps": 1000000000},
    ],
    "name": "p4runtime",
    "source": {"bmv2_json": "build/advanced_tunnel.json", "controller": "mycontroller.py",
               "exercise_dir": "/home/adam/tutorials/exercises/p4runtime",
               "kind": "p4lang-tutorials", "p4": "advanced_tunnel.p4",
               "p4info": "build/advanced_tunnel.p4.p4info.txtpb", "topology_json": "topology.json"},
    "switches": {
        "1": {"entries": None, "name": "s1", "pipeline": None},
        "2": {"entries": None, "name": "s2", "pipeline": None},
        "3": {"entries": None, "name": "s3", "pipeline": None},
    },
    "topology": "ndtwin/topology.json",
}


def lay_out_converter_package(root, manifest, name, entry_files=()):
    """Write `manifest` plus only the files this READER resolves, and no others.

    Deliberately does not create `source.p4info`, `source.bmv2_json`, `source.p4` or
    `source.controller`: this reader does not consume them, so a package that lacks them must
    still load. tools/p4_exercise/preflight.py is where those are checked.
    """
    directory = os.path.join(root, name)
    os.makedirs(os.path.join(directory, "ndtwin"), exist_ok=True)
    shutil.copyfile(FOUR_HOST_MODEL, os.path.join(directory, "ndtwin", "topology.json"))
    for relpath in entry_files:
        full = os.path.join(directory, relpath)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as fh:
            json.dump({"target": "bmv2", "table_entries": [{"table": "MyIngress.ipv4_lpm"}] * 5},
                      fh)
    with open(os.path.join(directory, "package.json"), "w") as fh:
        json.dump(manifest, fh, sort_keys=True, indent=2)
    return directory


class WhatTheConverterActuallyWritesTest(unittest.TestCase):
    """Both real packages, loaded unchanged. This is the A-to-B contract in one place."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_conv_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.basic = app_package.load(lay_out_converter_package(
            self.tmp, CONVERTER_BASIC, "basic",
            [f"pod-topo/s{i}-runtime.json" for i in range(1, 5)]))
        self.external = app_package.load(lay_out_converter_package(
            self.tmp, CONVERTER_P4RUNTIME, "p4runtime"))

    def test_the_basic_package_loads_unchanged(self):
        self.assertEqual(self.basic.name, "basic")
        self.assertEqual(self.basic.mode, "ndtwin")
        self.assertEqual(self.basic.election_id, (0, 65535))
        self.assertEqual(self.basic.cpu_port, 255)
        self.assertEqual(self.basic.switch_names(), {1: "s1", 2: "s2", 3: "s3", 4: "s4"})

    def test_pod_topos_four_hosts_satisfy_the_last_octet_naming_rule(self):
        # 10.0.1.1 -> h1, 10.0.2.2 -> h2, 10.0.3.3 -> h3, 10.0.4.4 -> h4. The rule holds even
        # though each host is in a different /24, which is the case the NDTwin models never had.
        self.assertEqual([h.name for h in self.basic.hosts], ["h1", "h2", "h3", "h4"])
        self.assertEqual([h.ip for h in self.basic.hosts],
                         ["10.0.1.1", "10.0.2.2", "10.0.3.3", "10.0.4.4"])

    def test_every_referenced_path_resolves_inside_the_package_not_against_tutorials(self):
        self.assertTrue(self.basic.topology.startswith(self.basic.dir))
        for spec in self.basic.switches:
            self.assertTrue(spec.entries.startswith(self.basic.dir), spec.entries)
            self.assertTrue(os.path.isfile(spec.entries))

    def test_the_entries_the_converter_copied_in_are_counted(self):
        self.assertEqual(self.basic.entries_recorded(), {"1": 5, "2": 5, "3": 5, "4": 5})

    def test_source_keys_this_reader_does_not_consume_are_neither_resolved_nor_refused(self):
        # `source.p4info`, `source.bmv2_json`, `source.p4` and `source.controller` name files
        # that were deliberately NOT created by the fixture. A reader that validated them would
        # have refused both packages; a reader that resolved `controller` would have looked for
        # an exercise-relative path inside the package and not found it.
        self.assertEqual(self.external.name, "p4runtime")
        self.assertIsNone(self.basic.host_commands().get("nonexistent"))

    def test_the_external_package_reads_only(self):
        self.assertEqual(self.external.mode, "external")
        self.assertTrue(self.external.read_only)
        self.assertFalse(self.external.arbitration)

    def test_a_switch_with_no_entries_records_zero_rather_than_failing(self):
        self.assertEqual(self.external.entries_recorded(), {"1": 0, "2": 0, "3": 0})

    def test_a_link_delay_is_carried_verbatim_and_applied_by_nobody(self):
        # Phase 1 does no shaping at all (G2-C is phase 3). Carried so `ndt status` and the
        # converter's round-trip can show what the exercise declared.
        self.assertEqual(self.external.links[0]["delay_ms"], 0.5)
        self.assertEqual(len(self.external.links), 6)

    def test_the_host_commands_replace_the_fabrics_all_pairs_arp(self):
        # pod-topo gives each host a default gateway and ONE static ARP, for that gateway. The
        # baseline fabric's all-pairs fan-out would pre-resolve every destination MAC, so the
        # exercise's forwarding tables would never be consulted and a broken data plane would
        # ping perfectly. `host_commands()` being a dict rather than None is what turns it off.
        commands = self.basic.host_commands()
        self.assertIsNotNone(commands)
        self.assertEqual(len(commands["h1"]), 2)
        self.assertIn("route add default gw 10.0.1.10 dev eth0", commands["h1"])


class TopologyPathDisagreementTest(unittest.TestCase):
    """
    A package naming one model while `NDTWIN_P4_TOPO_FILE` names another is the 2026-08-21
    defect in a new costume: one of them builds the fabric, the other is handed to the kernel,
    and every topology view reads correct.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_topo_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.pkg = app_package.load(build_package(self.tmp))

    def test_an_env_override_that_disagrees_with_the_package_is_refused(self):
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.topology_path(self.pkg, 4, env={"NDTWIN_P4_TOPO_FILE": HOST_128_MODEL})
        self.assertIn("disagrees with the app package", str(caught.exception))

    def test_an_env_override_naming_the_same_model_is_fine(self):
        self.assertEqual(
            app_package.topology_path(self.pkg, 4,
                                      env={"NDTWIN_P4_TOPO_FILE": self.pkg.topology}),
            self.pkg.topology)

    def test_without_a_package_the_env_override_behaves_exactly_as_it_did(self):
        # topo_from_json.model_path still refuses an override whose host count disagrees with
        # the run's -- the check p4_testbed_topo._topology_model_path carried before the move.
        base = app_package.baseline()
        self.assertEqual(
            app_package.topology_path(base, 4, env={"NDTWIN_P4_TOPO_FILE": FOUR_HOST_MODEL}),
            FOUR_HOST_MODEL)
        with self.assertRaises(topo_from_json.TopologyModelError):
            app_package.topology_path(base, 128, env={"NDTWIN_P4_TOPO_FILE": FOUR_HOST_MODEL})


if __name__ == "__main__":
    unittest.main(verbosity=2)

# [Co-developed with claude code -- Adam]
