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
        # The same two paths main.build_p4_client used to os.path.join by hand, for any dpid.
        # The baseline declares no switches at all, so every dpid falls through to the
        # fabric-wide pair -- which is what "no package" has to keep meaning.
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
    # All four of the 4-host model's hosts, with the addresses and MACs that model gives them.
    # The loader refuses a manifest whose hosts and topology model describe different fabrics,
    # so a fixture that named two of the four would be a package that cannot exist.
    # [Co-developed with claude code -- Adam]
    "hosts": {
        "h1": {"ip": "10.0.0.1", "prefix_len": 24, "mac": "00:00:00:00:00:01",
               "commands": ["route add default gw 10.0.0.10 dev eth0"]},
        "h2": {"ip": "10.0.0.2", "prefix_len": 24, "mac": "00:00:00:00:00:02", "commands": []},
        "h3": {"ip": "10.0.0.3", "prefix_len": 24, "mac": "00:00:00:00:00:03", "commands": []},
        "h4": {"ip": "10.0.0.4", "prefix_len": 24, "commands": []},
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
                         {"h1": ["route add default gw 10.0.0.10 dev eth0"],
                          "h2": [], "h3": [], "h4": []})

    def test_a_host_that_declares_no_mac_takes_the_models(self):
        # `mac` is optional in the manifest -- the model is the authority the fabric builds
        # from, and a manifest MAC is a cross-check, not a second source.
        self.assertIsNone([h for h in self.pkg.hosts if h.name == "h4"][0].mac)

    def test_its_entries_are_counted_and_reported_as_recorded_not_applied(self):
        self.assertEqual(self.pkg.entries_recorded(), {"1": 3, "2": 0})

    def test_a_package_whose_switches_name_no_pipeline_runs_ndtwins_own(self):
        self.assertEqual(self.pkg.pipeline, app_package.baseline().pipeline)
        for dpid in (1, 2):
            self.assertTrue(self.pkg.pipeline_is_ndtwin(dpid, "/base"))

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

# 🔴 VERBATIM. Both dicts below are `json.load()` of the real package.json bytes, re-emitted with
# `pprint`; nothing is paraphrased, trimmed or "tidied". The first version of this fixture was
# hand-typed from a screenful of the real file and got p4runtime's host commands down to one
# each and invented a `delay_ms: 0.5` that is in neither package -- so the suite asserted a
# contract nobody had written, which is the exact failure a transcribed fixture exists to
# prevent (found by the P1-A judge against c3ecf7f8). `delay_ms` is a real part of the FORMAT and
# is exercised on its own, below, rather than smuggled into a copy of somebody's file.

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
        "h1": {"commands": ["route add default gw 10.0.1.10 dev eth0",
                            "arp -i eth0 -s 10.0.1.10 08:00:00:00:01:00"],
               "ip": "10.0.1.1", "mac": "08:00:00:00:01:11", "prefix_len": 24},
        "h2": {"commands": ["route add default gw 10.0.2.20 dev eth0",
                            "arp -i eth0 -s 10.0.2.20 08:00:00:00:02:00"],
               "ip": "10.0.2.2", "mac": "08:00:00:00:02:22", "prefix_len": 24},
        "h3": {"commands": ["route add default gw 10.0.3.30 dev eth0",
                            "arp -i eth0 -s 10.0.3.30 08:00:00:00:03:00"],
               "ip": "10.0.3.3", "mac": "08:00:00:00:03:33", "prefix_len": 24},
    },
    "links": [
        {"a": ["h1", 1], "b": ["s1", 1], "bandwidth_bps": 1000000000},
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
               "p4info": "build/advanced_tunnel.p4.p4info.txtpb",
               "topology_json": "topology.json"},
    "switches": {
        "1": {"entries": None, "name": "s1", "pipeline": None},
        "2": {"entries": None, "name": "s2", "pipeline": None},
        "3": {"entries": None, "name": "s3", "pipeline": None},
    },
    "topology": "ndtwin/topology.json",
}

#: What the two real `ndtwin/topology.json` files hold, as (nodes, edges). Asserted below, so a
#: fixture model that drifted from the artefact it stands for is visible rather than assumed.
CONVERTER_MODEL_SIZES = {"basic": (8, 16), "p4runtime": (6, 12)}


def model_for(manifest):
    """The `ndtwin/topology.json` convert.py writes for this manifest.

    [Co-developed with claude code -- Adam]
    Built from the manifest's own `links` rather than vendored as a second 6 KB blob, and in the
    shape the real file has: switch nodes carry the twelve keys the 4-host NDTwin model uses
    (`brand_name "BMv2"`, agent ip `192.168.123.<10+N>`, `vertex_type 0`), host nodes carry
    `device_layer 3` / `dpid 0` / an integer MAC, and every edge is stored in both directions
    with dpid 0 on the host side. `CONVERTER_MODEL_SIZES` pins the node and edge counts against
    the real artefacts.

    It exists because the loader now REFUSES a package whose manifest hosts and topology model
    describe different fabrics, which is the point: a fixture pairing somebody's manifest with
    an unrelated NDTwin model would be testing a package that could not exist.
    """
    hosts, switches = manifest["hosts"], manifest["switches"]
    by_name = {spec["name"]: int(dpid) for dpid, spec in switches.items()}
    agent_ip = {name: f"192.168.123.{10 + dpid}" for name, dpid in by_name.items()}

    nodes = []
    for dpid, spec in sorted(switches.items(), key=lambda kv: int(kv[0])):
        name, n = spec["name"], int(dpid)
        nodes.append({"brand_name": "BMv2", "bridge_name": name, "device_layer": 2,
                      "device_name": name, "dpid": n, "ecmp_groups": [],
                      "ip": [agent_ip[name]], "mac": 0, "nickname": name,
                      "smart_plug_ip": "", "smart_plug_outlet": 0, "vertex_type": 0})
    for name in sorted(hosts, key=lambda h: int(h[1:])):
        spec = hosts[name]
        nodes.append({"brand_name": "", "device_layer": 3, "device_name": name, "dpid": 0,
                      "ip": [spec["ip"]], "mac": int(spec["mac"].replace(":", ""), 16),
                      "nickname": name, "vertex_type": 1})

    def endpoint(name, port):
        if name in by_name:
            return by_name[name], port, [agent_ip[name]]
        return 0, port, [hosts[name]["ip"]]

    edges = []
    for link in manifest["links"]:
        (a_name, a_port), (b_name, b_port) = link["a"], link["b"]
        bw = link.get("bandwidth_bps", 1000000000)
        a_dpid, a_port, a_ip = endpoint(a_name, a_port)
        b_dpid, b_port, b_ip = endpoint(b_name, b_port)
        for (s_dpid, s_port, s_ip), (d_dpid, d_port, d_ip) in (
                ((a_dpid, a_port, a_ip), (b_dpid, b_port, b_ip)),
                ((b_dpid, b_port, b_ip), (a_dpid, a_port, a_ip))):
            edges.append({"src_dpid": s_dpid, "src_interface": s_port, "src_ip": s_ip,
                          "dst_dpid": d_dpid, "dst_interface": d_port, "dst_ip": d_ip,
                          "link_bandwidth_bps": bw})
    return {"nodes": nodes, "edges": edges, "links": []}


def lay_out_converter_package(root, manifest, name, entry_files=()):
    """Write `manifest`, its model, and only the files this READER resolves -- no others.

    Deliberately does not create `source.p4info`, `source.bmv2_json`, `source.p4` or
    `source.controller`: this reader does not consume them, so a package that lacks them must
    still load. tools/p4_exercise/preflight.py is where those are checked.
    """
    directory = os.path.join(root, name)
    os.makedirs(os.path.join(directory, "ndtwin"), exist_ok=True)
    with open(os.path.join(directory, "ndtwin", "topology.json"), "w") as fh:
        json.dump(model_for(manifest), fh, sort_keys=True, indent=2)
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

    def test_the_fixture_models_are_the_size_the_real_artefacts_are(self):
        for name, manifest in (("basic", CONVERTER_BASIC), ("p4runtime", CONVERTER_P4RUNTIME)):
            model = model_for(manifest)
            self.assertEqual((len(model["nodes"]), len(model["edges"])),
                             CONVERTER_MODEL_SIZES[name], name)

    def test_the_fixture_models_pass_all_four_topo_from_json_readers(self):
        # The same four the converter's own tests run, and the same four the fabric uses.
        for manifest in (CONVERTER_BASIC, CONVERTER_P4RUNTIME):
            model = model_for(manifest)
            self.assertTrue(topo_from_json.switches(model))
            self.assertTrue(topo_from_json.hosts(model))
            self.assertTrue(topo_from_json.switch_links(model))
            self.assertTrue(topo_from_json.host_links(model))

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
        self.assertEqual(CONVERTER_P4RUNTIME["source"]["controller"], "mycontroller.py")
        self.assertFalse(os.path.exists(os.path.join(self.external.dir, "mycontroller.py")))

    def test_the_external_package_reads_only(self):
        self.assertEqual(self.external.mode, "external")
        self.assertTrue(self.external.read_only)
        self.assertFalse(self.external.arbitration)

    def test_a_switch_with_no_entries_records_zero_rather_than_failing(self):
        self.assertEqual(self.external.entries_recorded(), {"1": 0, "2": 0, "3": 0})

    def test_neither_real_package_declares_a_link_delay(self):
        # Pinned because the first version of this fixture invented one. `delay_ms` is part of
        # the format (see the next test); it is not part of these two artefacts.
        for manifest in (CONVERTER_BASIC, CONVERTER_P4RUNTIME):
            for link in manifest["links"]:
                self.assertNotIn("delay_ms", link)

    def test_every_host_of_both_packages_carries_two_commands(self):
        # A default gateway and ONE static ARP, for that gateway. Pinned because the first
        # version of this fixture had one command per host for p4runtime, which would have let
        # a converter that dropped the ARP line through.
        for manifest in (CONVERTER_BASIC, CONVERTER_P4RUNTIME):
            for name, spec in manifest["hosts"].items():
                self.assertEqual(len(spec["commands"]), 2, f"{manifest['name']}.{name}")

    def test_the_host_commands_replace_the_fabrics_all_pairs_arp(self):
        # pod-topo gives each host a default gateway and one static ARP. The baseline fabric's
        # all-pairs fan-out would pre-resolve every destination MAC, so the exercise's
        # forwarding tables would never be consulted and a broken data plane would ping
        # perfectly. `host_commands()` being a dict rather than None is what turns it off.
        commands = self.basic.host_commands()
        self.assertIsNotNone(commands)
        self.assertEqual(commands["h1"], ["route add default gw 10.0.1.10 dev eth0",
                                          "arp -i eth0 -s 10.0.1.10 08:00:00:00:01:00"])


class OptionalFormatFieldsTest(unittest.TestCase):
    """Parts of the format the two shipped packages happen not to use."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_opt_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def load(self, manifest, name):
        return app_package.load(lay_out_converter_package(self.tmp, manifest, name))

    def test_a_link_delay_is_carried_verbatim_and_applied_by_nobody(self):
        # Phase 1 does no shaping at all (G2-C is phase 3). Carried so `ndt status` and the
        # converter's round-trip can show what the exercise declared. Asserted on a manifest
        # built for it rather than by editing a copy of a real package: that is how the first
        # version of this suite came to claim a delay that was in neither artefact.
        manifest = json.loads(json.dumps(CONVERTER_P4RUNTIME))
        manifest["links"][0]["delay_ms"] = 0.5
        package = self.load(manifest, "with_delay")
        self.assertEqual(package.links[0]["delay_ms"], 0.5)
        self.assertEqual(len(package.links), 6)

    def test_a_package_that_names_no_election_id_gets_the_documented_default(self):
        # 🔴 The literal, not the constant compared against itself. (0, 65535) is chosen so an
        # impostor bidding the baseline (0, 1) loses -- refused with PERMISSION_DENIED rather
        # than accepted as primary and wiping every table (measured 2026-08-13).
        manifest = json.loads(json.dumps(CONVERTER_P4RUNTIME))
        manifest["control_plane"] = {"mode": "ndtwin"}
        package = self.load(manifest, "no_election_id")
        self.assertEqual(package.election_id, (0, 65535))
        self.assertEqual(app_package.PACKAGE_DEFAULT_ELECTION_ID, (0, 65535))
        self.assertGreater(package.election_id, app_package.BASELINE_ELECTION_ID,
                           "a package must outbid the baseline (0, 1) or an impostor "
                           "presenting it becomes primary and wipes the tables")


class TheManifestAndTheModelMustDescribeOneFabricTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam]

    A package carries two descriptions of one network: the manifest says which address and
    which commands h1 has, the model says where h1 plugs in and what MAC it gets. When they
    disagree the fabric builds one host while the proxy configures another, and nothing
    downstream notices -- the host comes up, the commands run, the pings go nowhere. This is
    the 2026-08-21 defect's shape (routes for 128 hosts on a 4-host fabric, every view correct).

    preflight.py checks this too. That is not a reason to skip it: the knob is a file an
    operator can edit, so a package reaching the proxy has not necessarily been through
    pre-flight, and "somebody else validated it" is not something this process can observe.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_agree_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def refuses(self, mutate, fragment, name):
        manifest = json.loads(json.dumps(CONVERTER_BASIC))
        directory = lay_out_converter_package(self.tmp, manifest, name,
                                              [f"pod-topo/s{i}-runtime.json" for i in range(1, 5)])
        # The model is written first, then the manifest is edited: that is the real shape of the
        # failure -- a hand-edited package.json beside a model nobody regenerated.
        mutate(manifest)
        with open(os.path.join(directory, "package.json"), "w") as fh:
            json.dump(manifest, fh, sort_keys=True, indent=2)
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.load(directory)
        self.assertIn(fragment, str(caught.exception))
        return str(caught.exception)

    def test_a_host_the_model_does_not_have_is_refused(self):
        def mutate(m):
            m["hosts"]["h9"] = {"ip": "10.0.9.9", "mac": "08:00:00:00:09:99", "commands": []}
        message = self.refuses(mutate, "describe different fabrics", "extra_host")
        self.assertIn("h9", message)

    def test_a_host_the_manifest_does_not_have_is_refused(self):
        message = self.refuses(lambda m: m["hosts"].pop("h4"),
                               "describe different fabrics", "missing_host")
        self.assertIn("h4", message)

    def test_an_address_the_two_disagree_on_is_refused(self):
        # h4 keeps its name (so the last-octet rule still passes) and changes its /24.
        message = self.refuses(lambda m: m["hosts"]["h4"].update({"ip": "10.0.9.4"}),
                               "but the topology model gives it", "wrong_ip")
        self.assertIn("10.0.9.4", message)

    def test_a_mac_the_two_disagree_on_is_refused(self):
        message = self.refuses(lambda m: m["hosts"]["h4"].update({"mac": "08:00:00:00:04:45"}),
                               "but the topology model gives it", "wrong_mac")
        self.assertIn("08:00:00:00:04:45", message)

    def test_a_manifest_that_declares_no_hosts_at_all_is_not_second_guessed(self):
        # Declaring none is legitimate -- the fabric is built entirely from the model and no
        # host commands run -- and it is a different statement from declaring the wrong ones.
        manifest = json.loads(json.dumps(CONVERTER_BASIC))
        model_hosts = manifest["hosts"]
        manifest["hosts"] = {}
        directory = os.path.join(self.tmp, "no_hosts")
        os.makedirs(os.path.join(directory, "ndtwin"))
        with open(os.path.join(directory, "ndtwin", "topology.json"), "w") as fh:
            json.dump(model_for(dict(manifest, hosts=model_hosts)), fh)
        manifest["switches"] = {k: dict(v, entries=None) for k, v in manifest["switches"].items()}
        with open(os.path.join(directory, "package.json"), "w") as fh:
            json.dump(manifest, fh)
        package = app_package.load(directory)
        self.assertEqual(package.hosts, ())
        self.assertEqual(package.host_commands(), {})


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


# --- G4: the per-switch pipeline ---------------------------------------------------------------


class PerSwitchPipelineTest(unittest.TestCase):
    """A package that carries its own program, one per switch (TICKET-P2 section 2.1).

    [Co-developed with claude code -- Adam]
    Until G4 this field had to be null and `load` said so. What it is for is exercises/firewall:
    s1 runs `firewall.json`, s2-s4 run `basic.json`, and a fabric that put one program on all
    four comes up, forwards, and is not the exercise. Everything here is about the reader, not
    about whether the program is any good -- tools/p4_exercise/preflight.py parses the p4info
    and checks the two halves against each other; this file only resolves and refuses.
    """

    #: Two switches, two different programs. `build/` names, because that is where the
    #: exercises' Makefile puts them and therefore where convert.py copies them.
    TWO_PROGRAMS = {
        "1": {"name": "s1", "entries": "s1-runtime.json",
              "pipeline": {"p4info": "build/fw.p4.p4info.txtpb", "bmv2_json": "build/fw.json"}},
        "2": {"name": "s2", "entries": None,
              "pipeline": {"p4info": "build/basic.p4.p4info.txtpb",
                           "bmv2_json": "build/basic.json"}},
    }
    ARTEFACTS = ("build/fw.p4.p4info.txtpb", "build/fw.json",
                 "build/basic.p4.p4info.txtpb", "build/basic.json")

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_g4_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def package(self, switches, artefacts=ARTEFACTS):
        """A loadable package whose switches are `switches`, with the artefacts on disk.

        The artefact files are empty JSON: this reader resolves them and never opens them, and
        a fixture that carried a real p4info would suggest it did.
        """
        directory = build_package(self.tmp, manifest=with_manifest(switches=switches),
                                  name=f"pkg_{len(os.listdir(self.tmp))}")
        for rel in artefacts:
            full = os.path.join(directory, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as fh:
                fh.write("{}\n")
        return directory

    def refuses(self, switches, fragment, artefacts=ARTEFACTS):
        directory = self.package(switches, artefacts=artefacts)
        with self.assertRaises(app_package.AppPackageError) as caught:
            app_package.load(directory)
        self.assertIn(fragment, str(caught.exception))
        return str(caught.exception)

    # --- what it resolves -------------------------------------------------------------------

    def test_the_loader_resolves_each_switchs_pipeline_to_two_absolute_paths(self):
        # 🔴 The field is READ, not merely permitted. A loader that parsed it and stored None
        # would leave every switch on NDTwin's pipeline while the manifest, the pre-flight and
        # `ndt status` all said otherwise -- the exact failure `pipeline: null` was mandatory
        # to prevent, arriving now through the door that was opened for it.
        directory = self.package(self.TWO_PROGRAMS)
        by_dpid = {s.dpid: s.pipeline for s in app_package.load(directory).switches}
        self.assertEqual(by_dpid[1], (os.path.join(directory, "build/fw.p4.p4info.txtpb"),
                                      os.path.join(directory, "build/fw.json")))
        self.assertEqual(by_dpid[2], (os.path.join(directory, "build/basic.p4.p4info.txtpb"),
                                      os.path.join(directory, "build/basic.json")))

    def test_pipeline_for_answers_per_switch_not_fabric_wide(self):
        pkg = app_package.load(self.package(self.TWO_PROGRAMS))
        self.assertTrue(pkg.pipeline_for(1, "/base")[1].endswith("build/fw.json"),
                        pkg.pipeline_for(1, "/base"))
        self.assertTrue(pkg.pipeline_for(2, "/base")[1].endswith("build/basic.json"),
                        pkg.pipeline_for(2, "/base"))
        self.assertNotEqual(pkg.pipeline_for(1, "/base"), pkg.pipeline_for(2, "/base"))

    def test_a_per_switch_pipeline_ignores_the_base_dir_because_it_is_already_absolute(self):
        # `base_dir` resolves NDTwin's own two relative paths. A package's own pipeline was
        # resolved against the PACKAGE at load time, so a proxy rooted at p4_proxy/ and a
        # Mininet script rooted anywhere get the same file.
        pkg = app_package.load(self.package(self.TWO_PROGRAMS))
        self.assertEqual(pkg.pipeline_for(1, "/base"), pkg.pipeline_for(1, "/somewhere/else"))

    def test_a_switch_that_names_no_pipeline_still_gets_ndtwins(self):
        mixed = json.loads(json.dumps(self.TWO_PROGRAMS))
        mixed["2"]["pipeline"] = None
        pkg = app_package.load(self.package(mixed))
        self.assertEqual(pkg.pipeline_for(2, "/base"),
                         app_package.baseline().pipeline_for(2, "/base"))

    # --- pipeline_is_ndtwin, the question every downstream skip is asked in ------------------

    def test_pipeline_is_ndtwin_is_false_for_a_package_that_brought_its_own(self):
        pkg = app_package.load(self.package(self.TWO_PROGRAMS))
        self.assertFalse(pkg.pipeline_is_ndtwin(1, "/base"))
        self.assertFalse(pkg.pipeline_is_ndtwin(2, "/base"))

    def test_pipeline_is_ndtwin_is_true_for_the_baseline_and_for_a_null_switch(self):
        self.assertTrue(app_package.baseline().pipeline_is_ndtwin(1, "/base"))
        mixed = json.loads(json.dumps(self.TWO_PROGRAMS))
        mixed["2"]["pipeline"] = None
        pkg = app_package.load(self.package(mixed))
        self.assertTrue(pkg.pipeline_is_ndtwin(2, "/base"))
        self.assertFalse(pkg.pipeline_is_ndtwin(1, "/base"))

    # --- the refusals -----------------------------------------------------------------------

    def test_a_pipeline_that_escapes_the_package_directory_is_refused(self):
        # 🔴 The file EXISTS, so existence is not what catches this. A package that reaches
        # outside itself pre-flights green on the machine that built it and loads a different
        # program -- or none -- anywhere else.
        outside = os.path.join(self.tmp, "outside.json")
        with open(outside, "w") as fh:
            fh.write("{}\n")
        switches = json.loads(json.dumps(self.TWO_PROGRAMS))
        switches["1"]["pipeline"]["bmv2_json"] = "../outside.json"
        message = self.refuses(switches, "outside the package directory")
        self.assertIn("outside.json", message)

    def test_an_absolute_pipeline_path_is_refused(self):
        switches = json.loads(json.dumps(self.TWO_PROGRAMS))
        switches["1"]["pipeline"]["bmv2_json"] = "/tmp/elsewhere.json"
        self.refuses(switches, "absolute path")

    def test_a_pipeline_missing_its_p4info_is_refused(self):
        switches = json.loads(json.dumps(self.TWO_PROGRAMS))
        del switches["1"]["pipeline"]["p4info"]
        message = self.refuses(switches, "names no 'p4info'")
        self.assertIn("switches.1", message)

    def test_a_pipeline_missing_its_bmv2_json_is_refused(self):
        switches = json.loads(json.dumps(self.TWO_PROGRAMS))
        del switches["1"]["pipeline"]["bmv2_json"]
        self.refuses(switches, "names no 'bmv2_json'")

    def test_a_pipeline_spelled_as_a_list_is_refused(self):
        # The phase-1 spelling, and the reason it is not quietly accepted: the two paths are
        # not interchangeable, so a swapped pair would launch bmv2 on a p4info.
        switches = json.loads(json.dumps(self.TWO_PROGRAMS))
        switches["1"]["pipeline"] = ["build/fw.p4.p4info.txtpb", "build/fw.json"]
        self.refuses(switches, "must be null or an object")

    def test_a_pipeline_with_a_misspelled_key_is_refused(self):
        switches = json.loads(json.dumps(self.TWO_PROGRAMS))
        switches["1"]["pipeline"] = {"p4info": "build/fw.p4.p4info.txtpb",
                                     "bmv2json": "build/fw.json"}
        self.refuses(switches, "unknown key(s) ['bmv2json']")

    def test_a_pipeline_half_that_is_not_a_string_is_refused(self):
        switches = json.loads(json.dumps(self.TWO_PROGRAMS))
        switches["1"]["pipeline"]["bmv2_json"] = 7
        self.refuses(switches, "must be a non-empty string")

    def test_a_pipeline_naming_a_file_the_package_does_not_carry_is_refused(self):
        switches = json.loads(json.dumps(self.TWO_PROGRAMS))
        switches["1"]["pipeline"]["bmv2_json"] = "build/never-compiled.json"
        message = self.refuses(switches, "does not exist")
        self.assertIn("pipeline.bmv2_json", message)


# --- one switch, no cable between switches -----------------------------------------------------


class AOneSwitchFabricHasNoInterSwitchLinksTest(unittest.TestCase):
    """`topo_from_json.switch_links` on a model with one switch, and on one with two.

    [Co-developed with claude code -- Adam]
    Lives in this file rather than in a reader suite of its own because it is a PACKAGE
    property: `exercises/calc` -- and basic_tunnel, load_balance, multicast -- declare one
    switch and two hosts, and until now `app_package.load` refused every one of them, at the
    `topo_from_json.switches`/`hosts` parse inside `load`, for having no cable. The one-switch
    package end to end is the last test here; the first three are the rule that lets it load.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_one_switch_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    @staticmethod
    def model(dpids, edges=()):
        return {"nodes": [{"vertex_type": 0, "dpid": d, "bridge_name": f"s{d}",
                           "device_name": f"s{d}"} for d in dpids],
                "edges": list(edges), "links": []}

    def test_one_switch_and_no_cable_is_an_empty_list_not_an_error(self):
        self.assertEqual(topo_from_json.switch_links(self.model([1])), [])

    def test_two_switches_with_no_cable_between_them_is_still_refused(self):
        # 🔴 The discriminator is the SWITCH count, not the edge count. Two switches and no
        # edge is a model whose `edges` were dropped: the fabric comes up as two islands, each
        # one healthy, forwarding nothing between them, and every topology view reads correct.
        with self.assertRaises(topo_from_json.TopologyModelError) as caught:
            topo_from_json.switch_links(self.model([1, 2]))
        message = str(caught.exception)
        self.assertIn("2 switches", message)
        self.assertIn("exactly one switch", message)

    def test_ten_switches_with_no_cable_is_refused_too(self):
        with self.assertRaises(topo_from_json.TopologyModelError):
            topo_from_json.switch_links(self.model(list(range(1, 11))))

    def test_two_switches_that_are_cabled_are_unaffected(self):
        # The control: the rule above must not turn a real cable into an empty list.
        edges = [{"src_dpid": 1, "src_interface": 3, "src_ip": ["192.168.123.11"],
                  "dst_dpid": 2, "dst_interface": 1, "dst_ip": ["192.168.123.12"]},
                 {"src_dpid": 2, "src_interface": 1, "src_ip": ["192.168.123.12"],
                  "dst_dpid": 1, "dst_interface": 3, "dst_ip": ["192.168.123.11"]}]
        self.assertEqual(topo_from_json.switch_links(self.model([1, 2], edges)),
                         [(1, 3, 2, 1)])

    def test_a_one_switch_package_loads_with_its_two_hosts(self):
        manifest = json.loads(json.dumps(MANIFEST))
        manifest["name"] = "calc"
        manifest["hosts"] = {
            "h1": {"ip": "10.0.1.1", "prefix_len": 24, "mac": "08:00:00:00:01:01",
                   "commands": []},
            "h2": {"ip": "10.0.1.2", "prefix_len": 24, "mac": "08:00:00:00:01:02",
                   "commands": []},
        }
        manifest["switches"] = {"1": {"name": "s1", "pipeline": None,
                                      "entries": "s1-runtime.json"}}
        manifest["links"] = [{"a": ["h1", 1], "b": ["s1", 1], "bandwidth_bps": 1000000000},
                             {"a": ["h2", 1], "b": ["s1", 2], "bandwidth_bps": 1000000000}]
        directory = lay_out_converter_package(self.tmp, manifest, "calc",
                                              entry_files=["s1-runtime.json"])
        pkg = app_package.load(directory)
        self.assertEqual([h.name for h in pkg.hosts], ["h1", "h2"])
        self.assertEqual(pkg.switch_names(), {1: "s1"})
        model = topo_from_json.load(pkg.topology)
        self.assertEqual(topo_from_json.switch_links(model), [])
        self.assertEqual(topo_from_json.host_links(model), [("h1", 1, 1), ("h2", 1, 2)])


# --- TICKET-P3 section 2.1: one word, three readers ------------------------------------------


class TelemetrySourceTest(unittest.TestCase):
    """The knob, the package's declaration, and the per-switch `auto` rule -- in that order."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_telemetry_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.knob = os.path.join(self.tmp, "telemetry_override")

    def write_knob(self, text):
        with open(self.knob, "w") as fh:
            fh.write(text)
        return self.knob

    def package(self, source=None, name="telemetry"):
        manifest = json.loads(json.dumps(CONVERTER_BASIC))
        if source is not None:
            manifest["telemetry"] = {"source": source}
        return app_package.load(lay_out_converter_package(
            self.tmp, manifest, name,
            entry_files=[spec["entries"] for spec in manifest["switches"].values()]))

    # --- the domain --------------------------------------------------------------------

    def test_the_four_words_are_the_domain_and_auto_is_not_an_answer(self):
        # 🔴 The literals, not the constant compared with itself. `auto` is in the domain a
        # package and the knob may state, and NOT in what `telemetry_source()` may answer:
        # answering `auto` would make every caller implement the per-switch rule a second time.
        self.assertEqual(app_package.TELEMETRY_SOURCES,
                         ("auto", "none", "cooperative", "link"))
        self.assertEqual(app_package.TELEMETRY_RESOLVED, ("none", "cooperative", "link"))

    def test_a_package_that_says_nothing_means_auto(self):
        self.assertEqual(self.package().telemetry_source, "auto")
        self.assertEqual(app_package.baseline().telemetry_source, "auto")

    def test_each_word_of_the_domain_is_carried_verbatim(self):
        for i, word in enumerate(app_package.TELEMETRY_SOURCES):
            self.assertEqual(self.package(word, name=f"telemetry_{i}").telemetry_source, word)

    def test_a_word_outside_the_domain_is_refused_by_name(self):
        with self.assertRaises(app_package.AppPackageError) as ctx:
            self.package("linke", name="typo")
        self.assertIn("telemetry.source", str(ctx.exception))
        self.assertIn("'linke'", str(ctx.exception))

    def test_telemetry_that_is_not_an_object_is_refused(self):
        manifest = json.loads(json.dumps(CONVERTER_BASIC))
        manifest["telemetry"] = "link"
        with self.assertRaises(app_package.AppPackageError) as ctx:
            app_package.load(lay_out_converter_package(
                self.tmp, manifest, "telemetry_scalar",
                entry_files=[sp["entries"] for sp in manifest["switches"].values()]))
        self.assertIn("'telemetry' must be an object", str(ctx.exception))

    def test_the_field_is_additive_and_the_format_number_does_not_move(self):
        # Section 2.1: `format` stays 1, because a reader that does not know this key still
        # reads every other key correctly.
        self.assertEqual(app_package.FORMAT, 1)
        self.assertEqual(self.package("link", name="still_one").telemetry_source, "link")

    # --- the knob ----------------------------------------------------------------------

    def test_a_knob_that_does_not_exist_is_not_an_opinion(self):
        self.assertIsNone(app_package.read_telemetry_knob(
            os.path.join(self.tmp, "no_such_file")))

    def test_the_first_non_comment_line_wins(self):
        self.assertEqual(app_package.read_telemetry_knob(
            self.write_knob("# written by ndt\n\nlink\ncooperative\n")), "link")

    def test_a_knob_with_only_comments_is_not_an_opinion_either(self):
        # `host_count_override`'s shape, which section 2.1 names: an empty directive file
        # falls back rather than refusing. The refusing case is the word, below.
        self.assertIsNone(app_package.read_telemetry_knob(self.write_knob("# nothing\n")))

    def test_a_knob_word_outside_the_domain_refuses_the_run(self):
        # 🔴 REFUSED, not defaulted. `ndt` validates before writing, so a bad word here means
        # something else wrote the file -- and a fabric that came up on `auto` instead would
        # measure something nobody asked for, with every reading as plausible as a correct one.
        with self.assertRaises(app_package.AppPackageError) as ctx:
            app_package.read_telemetry_knob(self.write_knob("linkk\n"))
        self.assertIn("'linkk'", str(ctx.exception))
        self.assertIn("auto", str(ctx.exception))

    def test_the_default_knob_path_sits_beside_the_other_three(self):
        self.assertEqual(os.path.basename(app_package.TELEMETRY_KNOB_PATH),
                         "telemetry_override")
        self.assertEqual(os.path.dirname(app_package.TELEMETRY_KNOB_PATH),
                         os.path.dirname(app_package.KNOB_PATH))

    # --- the three layers --------------------------------------------------------------

    def test_the_knob_outranks_the_packages_own_declaration(self):
        package = self.package("cooperative", name="layered")
        self.write_knob("link\n")
        self.assertEqual(app_package.telemetry_source(package, 1, knob_path=self.knob), "link")

    def test_an_auto_knob_defers_to_the_package(self):
        package = self.package("none", name="auto_knob")
        self.write_knob("auto\n")
        self.assertEqual(app_package.telemetry_source(package, 1, knob_path=self.knob), "none")

    def test_with_neither_saying_anything_the_rule_decides_per_switch(self):
        package = self.package(name="auto_both")
        knob = os.path.join(self.tmp, "absent")
        # Every switch of `basic` says `pipeline: null`, i.e. NDTwin's own artefacts.
        self.assertEqual(app_package.telemetry_source(package, 1, knob_path=knob),
                         "cooperative")

    def test_auto_sends_a_foreign_pipeline_down_the_link_path(self):
        # 🔴 THE REASON THE RULE IS PER SWITCH. A tutorials program has no `packet_in` header
        # and no clone session, so cooperative telemetry on it produces nothing at all -- not
        # an error, an empty twin. `firewall` runs its own program on s1 and NDTwin's on the
        # other three, and this is that fabric.
        manifest = json.loads(json.dumps(CONVERTER_BASIC))
        for key, switch in manifest["switches"].items():
            if key == "1":
                switch["pipeline"] = {"p4info": "build/firewall.p4.p4info.txtpb",
                                      "bmv2_json": "build/firewall.json"}
        directory = lay_out_converter_package(
            self.tmp, manifest, "mixed_auto",
            entry_files=[sp["entries"] for sp in manifest["switches"].values()])
        for rel in ("build/firewall.p4.p4info.txtpb", "build/firewall.json"):
            full = os.path.join(directory, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as fh:
                fh.write("{}\n")
        package = app_package.load(directory)
        knob = os.path.join(self.tmp, "absent")
        self.assertEqual(app_package.telemetry_source(package, 1, knob_path=knob), "link")
        for dpid in (2, 3, 4):
            self.assertEqual(app_package.telemetry_source(package, dpid, knob_path=knob),
                             "cooperative")

    def test_a_resolved_answer_is_never_auto_whatever_the_inputs(self):
        package = self.package("auto", name="never_auto")
        for text in ("auto\n", "# nothing\n"):
            self.assertIn(app_package.telemetry_source(package, 1,
                                                       knob_path=self.write_knob(text)),
                          app_package.TELEMETRY_RESOLVED)


# --- TICKET-P3 section 2.4: which links this package actually shaped --------------------------


class ShapedLinksTest(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_shaping_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def load(self, edits, name):
        manifest = json.loads(json.dumps(CONVERTER_BASIC))
        edits(manifest["links"])
        return app_package.load(lay_out_converter_package(
            self.tmp, manifest, name,
            entry_files=[sp["entries"] for sp in manifest["switches"].values()]))

    def test_the_default_bandwidth_is_the_converters_own_literal(self):
        # 🔴 READ OUT OF tools/p4_exercise/common.py, not compared with itself. The two numbers
        # have to agree or `shaped_links` would shape every unshaped link in every converted
        # package; this module cannot import that file (it must stay importable by a root
        # Mininet script with only the standard library), so the duplication is CHECKED here.
        source = os.path.join(REPO, "tools", "p4_exercise", "common.py")
        with open(source) as fh:
            text = fh.read()
        import re
        match = re.search(r"^DEFAULT_LINK_BPS\s*=\s*(\d+)\s*$", text, re.M)
        self.assertIsNotNone(match, f"no DEFAULT_LINK_BPS in {source}")
        self.assertEqual(int(match.group(1)), app_package.DEFAULT_LINK_BPS)
        self.assertEqual(app_package.DEFAULT_LINK_BPS, 1000000000)

    def test_a_package_that_shaped_nothing_shapes_nothing(self):
        # Every one of pod-topo's eight links is the default 1 Gbit/s with no delay.
        self.assertEqual(app_package.shaped_links(self.load(lambda links: None, "plain")), [])
        self.assertEqual(app_package.shaped_links(app_package.baseline()), [])

    def test_a_bottleneck_is_reported_in_megabit_with_its_endpoints(self):
        # ecn's and mri's `["s1-p3", "s2-p3", "0", 0.5]` -- 500000 bps, which is the whole
        # point of both exercises and reads as zero queue depth without G2-C.
        package = self.load(lambda links: links[2].__setitem__("bandwidth_bps", 500000),
                            "bottleneck")
        self.assertEqual(app_package.shaped_links(package),
                         [(("s1", 3), ("s3", 1), 0.5, None)])

    def test_a_delay_alone_is_shaping(self):
        package = self.load(lambda links: links[0].__setitem__("delay_ms", 2.5), "delay_only")
        self.assertEqual(app_package.shaped_links(package),
                         [(("h1", 1), ("s1", 1), None, 2.5)])

    def test_a_declared_zero_delay_is_not_shaping(self):
        package = self.load(lambda links: links[0].__setitem__("delay_ms", 0), "zero_delay")
        self.assertEqual(app_package.shaped_links(package), [])

    def test_both_together(self):
        package = self.load(
            lambda links: links[3].update({"bandwidth_bps": 10000000, "delay_ms": 1}), "both")
        self.assertEqual(app_package.shaped_links(package),
                         [(("s1", 4), ("s4", 2), 10.0, 1.0)])

    def test_the_index_is_unordered_so_either_end_may_be_asked_first(self):
        # MultiSwitchTopo knows a cable as two (node, port) pairs and has no idea which of them
        # the manifest listed first: host links are built as (host, switch) and the manifest
        # writes hosts first, but an inter-switch cable has no such convention.
        package = self.load(lambda links: links[2].__setitem__("bandwidth_bps", 500000),
                            "unordered")
        index = app_package.shaping_index(package)
        self.assertEqual(app_package.link_shaping_kwargs(index, ("s1", 3), ("s3", 1)),
                         {"bw": 0.5})
        self.assertEqual(app_package.link_shaping_kwargs(index, ("s3", 1), ("s1", 3)),
                         {"bw": 0.5})

    def test_an_unshaped_cable_gets_no_keyword_at_all(self):
        # 🔴 `{}`, not `{"bw": None}`. An unshaped link inside a package that shapes one other
        # link has to reach addLink with the arguments it reaches it with today.
        package = self.load(lambda links: links[2].__setitem__("bandwidth_bps", 500000),
                            "one_only")
        index = app_package.shaping_index(package)
        self.assertEqual(app_package.link_shaping_kwargs(index, ("h1", 1), ("s1", 1)), {})

    def test_delay_is_spelled_the_way_mininet_hands_it_to_netem(self):
        package = self.load(lambda links: links[0].__setitem__("delay_ms", 0.5), "delay_fmt")
        index = app_package.shaping_index(package)
        self.assertEqual(app_package.link_shaping_kwargs(index, ("h1", 1), ("s1", 1)),
                         {"delay": "0.5ms"})

    def test_a_negative_or_zero_bandwidth_is_refused(self):
        for bad in (0, -1):
            with self.assertRaises(app_package.AppPackageError):
                app_package.shaped_links(
                    self.load(lambda links, b=bad: links[0].__setitem__("bandwidth_bps", b),
                              f"bad_bw_{bad}"))

    def test_the_status_line_names_both_ends_and_what_was_asked_for(self):
        # The string `ndt status` prints. Here rather than in `ndt` so the fabric that installs
        # the shaping and the line that claims it are reading one function.
        package = self.load(
            lambda links: links[2].update({"bandwidth_bps": 500000, "delay_ms": 5}), "status")
        self.assertEqual(app_package.format_shaped_link(app_package.shaped_links(package)[0]),
                         "s1:3<->s3:1 0.5 Mbit/s 5ms")


if __name__ == "__main__":
    unittest.main(verbosity=2)

# [Co-developed with claude code -- Adam]
