"""The proxy side of the app package: the host table, the switch list, and what it discloses.

[Co-developed with claude code -- Adam]

🔴 THE FIRST CLASS IS THE PROOF THE REFACTOR IS ONE. `main.build_host_table` replaced a formula
--

    for i in range(1, HOST_NUM + 1):
        topo.add_host(ip=f"10.0.0.{i}", mac=f"00:00:00:00:00:{i:02x}",
                      switch_dpid=1 + (i - 1) // (HOST_NUM // 4),
                      port=3 + (i - 1) % (HOST_NUM // 4))

-- which decided, in the proxy, where every host in the fabric was plugged in. Getting that wrong
does not raise: the routes install, the twin looks healthy, and packets go to the wrong port. So
the formula is transcribed below and the derived table is compared to it element by element, at
the two sizes this project has ever run. tools/test_workflow/test_topo_from_json.py makes the
same comparison for the Mininet side; this is the proxy's half, which had never been checked
against anything at all.

The rest is disclosure: `GET /p4/switch_state` has to say which startup steps did not run, or an
external-control-plane fabric reports no telemetry, no links and no routes and every one of those
reads as a fault.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
REPO = os.path.dirname(PROXY_DIR)
sys.path.insert(0, PROXY_DIR)
sys.path.insert(0, os.path.join(PROXY_DIR, "mininet"))

import app_package  # noqa: E402
import topo_from_json  # noqa: E402

# main imports grpc and the P4Runtime protobufs, which are not installed for every interpreter
# L1 might pick (tools/test_workflow/l1_unit_tests.sh). Guarded so this file reports a clean skip
# instead of crashing the whole run with ModuleNotFoundError.
try:
    import proxy_agent.main as main
    from proxy_agent import api_routes
    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- environment, not behaviour
    main = None
    api_routes = None
    HAVE_P4RUNTIME = False

# [Co-developed with claude code -- Adam]
# 🔴 READ AT IMPORT, BEFORE ANY TEST HAS RUN. What is asserted below is that PRODUCTION wired
# these -- main.py's own import-time inject_* calls -- and every test in this file that touches
# `switch_state` replaces them with stubs and puts them back. Reading them inside a test would
# therefore assert only that the previous test's cleanup worked. Finding #71 is the whole reason
# this distinction is worth four lines: rule_journal.py shipped with 33 green tests and no
# production caller, because every one of them injected the journal itself.
WIRED_AT_IMPORT = None if not HAVE_P4RUNTIME else {
    "control_plane": api_routes.control_plane_report,
    "entries_recorded": api_routes.entries_recorded_report,
    "pipelines": api_routes.pipelines_report,
    "table_entries": api_routes.table_entries_report,
    "note_api_write": api_routes.note_api_table_entry_write,
    "readopt_runner": api_routes.readopt_runner,
}

# l0_build_check.sh p4 writes this. Without it there is no p4info to build a client from, which
# is the second prerequisite l1_unit_tests.sh allows a skip to blame.
P4INFO = os.path.join(PROXY_DIR, "p4_src", "build", "ndtwin_switch.p4info.txt")
HAVE_P4INFO = os.path.isfile(P4INFO)

FOUR_HOST_MODEL = os.path.join(REPO, "setting", "StaticNetworkTopologyP4_10Switches_4Hosts.json")
HOST_128_MODEL = os.path.join(REPO, "setting", "StaticNetworkTopologyP4_10Switches_128Hosts.json")


def literal_host_table(host_num):
    """The formula `main.build_host_table` replaced, transcribed from the block it deleted.

    `(ip, mac, switch_dpid, port)` per host, in the argument order `topo.add_host` takes.
    """
    per_switch = host_num // 4
    return sorted(
        (f"10.0.0.{i}", f"00:00:00:00:00:{i:02x}",
         1 + (i - 1) // per_switch, 3 + (i - 1) % per_switch)
        for i in range(1, host_num + 1)
    )


def pod_topo_shaped_model(hosts=((1, "10.0.1.1", 0x080000000111),
                                 (2, "10.0.2.2", 0x080000000222),
                                 (3, "10.0.3.3", 0x080000000333),
                                 (4, "10.0.4.4", 0x080000000444))):
    """An NDTwin model in the shape `tools/p4_exercise/convert.py` writes for pod-topo.

    [Co-developed with claude code -- Adam]
    Four hosts on four DIFFERENT switches, each on switch port 1, each in its own /24 -- the
    layout the quarters formula cannot describe. One inter-switch link so switch_links() has
    something to return. Written out here rather than imported from the converter's fixtures:
    what this file needs is a model the formula and the reader disagree about, and spelling it
    is shorter than depending on another test module's generator.
    """
    nodes, edges = [], []
    for dpid, ip, mac in hosts:
        nodes.append({"brand_name": "BMv2", "bridge_name": f"s{dpid}", "device_layer": 2,
                      "device_name": f"s{dpid}", "dpid": dpid, "ecmp_groups": [],
                      "ip": [f"192.168.123.{10 + dpid}"], "mac": 0, "nickname": f"s{dpid}",
                      "smart_plug_ip": "", "smart_plug_outlet": 0, "vertex_type": 0})
        nodes.append({"brand_name": "", "device_layer": 3, "device_name": f"h{dpid}", "dpid": 0,
                      "ip": [ip], "mac": mac, "nickname": f"h{dpid}", "vertex_type": 1})
        agent = [f"192.168.123.{10 + dpid}"]
        edges.append({"src_dpid": 0, "src_interface": 1, "src_ip": [ip],
                      "dst_dpid": dpid, "dst_interface": 1, "dst_ip": agent,
                      "link_bandwidth_bps": 1000000000})
        edges.append({"src_dpid": dpid, "src_interface": 1, "src_ip": agent,
                      "dst_dpid": 0, "dst_interface": 1, "dst_ip": [ip],
                      "link_bandwidth_bps": 1000000000})
    for a, b in ((1, 2), (3, 4), (1, 3)):
        for s, d in ((a, b), (b, a)):
            edges.append({"src_dpid": s, "src_interface": 2 + d, "src_ip": [],
                          "dst_dpid": d, "dst_interface": 2 + s, "dst_ip": [],
                          "link_bandwidth_bps": 1000000000})
    return {"nodes": nodes, "edges": edges, "links": []}


class RecordingTopo:
    """Records add_host exactly as TopologyManager receives it, and nothing else."""

    def __init__(self):
        self.rows = []

    def add_host(self, ip, mac, switch_dpid, port):
        self.rows.append((ip, mac, switch_dpid, port))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheHostTableMatchesTheFormulaItReplacedTest(unittest.TestCase):
    def table_for(self, model_path):
        topo = RecordingTopo()
        main.build_host_table(topo, topo_from_json.load(model_path),
                              package=app_package.baseline())
        return sorted(topo.rows)

    def test_the_proxy_host_table_matches_the_formula_it_replaces_at_four_hosts(self):
        self.assertEqual(self.table_for(FOUR_HOST_MODEL), literal_host_table(4))

    def test_the_proxy_host_table_matches_the_formula_it_replaces_at_128_hosts(self):
        # The size the formula was wrong at in the other direction: before it existed the proxy
        # held four literal add_host calls, so at 128 it knew four hosts and placed two of them
        # on the wrong switch. Both failures are excluded by comparing the whole table.
        self.assertEqual(self.table_for(HOST_128_MODEL), literal_host_table(128))

    def test_every_host_in_the_model_is_in_the_table_exactly_once(self):
        rows = self.table_for(HOST_128_MODEL)
        self.assertEqual(len(rows), 128)
        self.assertEqual(len({ip for ip, _m, _d, _p in rows}), 128)

    def test_a_pod_topo_shaped_model_is_followed_where_the_formula_would_be_wrong(self):
        # 🔴 The assertion that makes the two above mean something. The quarters formula and the
        # two NDTwin models AGREE at 4 and at 128 hosts -- that agreement is the equivalence
        # proof, and it also means "put the formula back" changes nothing those two tests can
        # see. pod-topo is the shape that separates them: four hosts on four DIFFERENT switches,
        # each on port 1, each in its own /24. The formula answers port 3 and 10.0.0.<i> for
        # every one of them; the model answers port 1 and the exercise's real address.
        model = pod_topo_shaped_model()
        topo = RecordingTopo()
        main.build_host_table(topo, model, package=app_package.baseline())
        self.assertEqual(sorted(topo.rows), [
            ("10.0.1.1", "08:00:00:00:01:11", 1, 1),
            ("10.0.2.2", "08:00:00:00:02:22", 2, 1),
            ("10.0.3.3", "08:00:00:00:03:33", 3, 1),
            ("10.0.4.4", "08:00:00:00:04:44", 4, 1),
        ])
        self.assertNotEqual(sorted(topo.rows), literal_host_table(4),
                            "this model is chosen precisely because the formula cannot "
                            "describe it; if they match, the fixture stopped discriminating")

    def test_a_host_with_no_access_link_is_refused_rather_than_skipped(self):
        # A host the proxy routes to and can never install a rule for presents as an empty path,
        # not as an error. topo_from_json.host_links raises for a host attached twice; this is
        # the other half of that check and it had no test.
        model = topo_from_json.load(FOUR_HOST_MODEL)
        model["edges"] = [e for e in model["edges"]
                          if "10.0.0.4" not in (e.get("src_ip") or []) + (e.get("dst_ip") or [])]
        with self.assertRaises(topo_from_json.TopologyModelError) as caught:
            main.build_host_table(RecordingTopo(), model, package=app_package.baseline())
        self.assertIn("h4", str(caught.exception))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheSwitchListComesFromTheModelTest(unittest.TestCase):
    def test_the_baseline_model_still_produces_the_ten_dpids_the_literal_named(self):
        self.assertEqual(main.switch_dpids(topo_from_json.load(FOUR_HOST_MODEL)),
                         tuple(range(1, 11)))
        self.assertEqual(main.DEFAULT_SWITCH_DPIDS, tuple(range(1, 11)))

    def test_the_switch_list_comes_from_the_model_not_from_a_range(self):
        # 🔴 The assertion that makes the previous one mean something. `range(1, 11)` satisfies
        # "ten dpids" for every model this repo ships, so only a model that says something else
        # can tell a reader from a constant.
        model = {"nodes": [
            {"vertex_type": 0, "dpid": 4, "bridge_name": "s4"},
            {"vertex_type": 0, "dpid": 9, "bridge_name": "s9"},
        ]}
        self.assertEqual(main.switch_dpids(model), (4, 9))


@unittest.skipUnless(HAVE_P4RUNTIME and HAVE_P4INFO,
                     "needs the P4Runtime protobufs and the compiled p4info "
                     "(tools/test_workflow/l0_build_check.sh p4)")
class TheClientTheProxyBuildsTest(unittest.TestCase):
    """
    `build_p4_client` is the single place a dpid becomes an address, a pair of artefact paths,
    an election id and a permission. grpc connects lazily, so none of this touches a switch.
    """

    def tearDown(self):
        for client in getattr(self, "built", []):
            client.channel.close()

    def build(self, package):
        client = main.build_p4_client(3, package=package)
        self.built = getattr(self, "built", []) + [client]
        return client

    def test_without_a_package_it_is_the_client_the_proxy_has_always_built(self):
        client = self.build(app_package.baseline())
        self.assertEqual(client.device_id, 3)
        self.assertEqual(client.grpc_addr, "localhost:30053")
        self.assertEqual(client.json_path,
                         os.path.join(PROXY_DIR, "p4_src/build/ndtwin_switch.json"))
        self.assertEqual(client.election_id, (0, 1))
        self.assertTrue(client.arbitration)

    def test_an_ndtwin_package_hands_the_client_its_election_id(self):
        package = app_package.baseline().__class__(dir="/pkg", name="basic",
                                                   election_id=(0, 65535))
        client = self.build(package)
        self.assertEqual(client.election_id, (0, 65535))
        self.assertTrue(client.arbitration)

    def test_an_external_package_hands_the_client_no_arbitration(self):
        package = app_package.baseline().__class__(dir="/pkg", name="p4runtime", mode="external")
        client = self.build(package)
        self.assertFalse(client.arbitration)
        # Mastership is never claimed, and the flag says so rather than being left ambiguous.
        self.assertFalse(client.mastership_confirmed)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class SwitchStateDisclosesTheControlPlaneTest(unittest.TestCase):
    """
    The endpoint the kernel polls once a second is where "this fabric has no telemetry because
    we were told not to program any" has to be readable. Additive: the kernel looks up
    "switches" and then named keys inside each entry, so neither field disturbs its parse.
    """

    class FakeTopology:
        def switch_liveness(self):
            return {"status": "success", "probe_interval_s": 2.0,
                    "switches": {"1": {"probe_ok": True}, "2": {"probe_ok": None}},
                    "boot_id": "b", "boot_at": 1.0}

    def setUp(self):
        self.saved = (api_routes.topology, api_routes.control_plane_report,
                      api_routes.entries_recorded_report, api_routes.pipelines_report,
                      api_routes.table_entries_report,
                      api_routes.note_api_table_entry_write)
        api_routes.topology = self.FakeTopology()
        self.addCleanup(self.restore)

    def restore(self):
        (api_routes.topology, api_routes.control_plane_report,
         api_routes.entries_recorded_report, api_routes.pipelines_report,
         api_routes.table_entries_report,
         api_routes.note_api_table_entry_write) = self.saved

    def state(self, report, recorded, pipelines=None, written=None):
        api_routes.inject_control_plane(lambda: report, lambda: recorded)
        api_routes.inject_package_reports(lambda: pipelines or {}, lambda: written or {},
                                          lambda dpid: None)
        return asyncio.run(api_routes.switch_state())

    def test_the_pre_existing_keys_are_untouched(self):
        body = self.state({"mode": "ndtwin", "package": None, "skipped": []}, {})
        self.assertEqual(body["status"], "success")
        self.assertEqual(body["probe_interval_s"], 2.0)
        self.assertEqual(body["boot_id"], "b")
        self.assertEqual(body["switches"]["1"]["probe_ok"], True)
        self.assertEqual(body["switches"]["2"]["probe_ok"], None)

    def test_the_baseline_fabric_says_it_skipped_nothing_rather_than_saying_nothing(self):
        body = self.state({"mode": "ndtwin", "package": None, "skipped": []}, {})
        self.assertEqual(body["control_plane"],
                         {"mode": "ndtwin", "package": None, "skipped": []})

    def test_a_skipped_step_is_named_on_the_endpoint(self):
        body = self.state({"mode": "external", "package": "/pkg",
                           "skipped": ["lldp_discovery", "pipeline_push"]}, {})
        self.assertEqual(body["control_plane"]["mode"], "external")
        self.assertEqual(body["control_plane"]["package"], "/pkg")
        self.assertIn("pipeline_push", body["control_plane"]["skipped"])

    def test_before_startup_has_run_skipped_is_null_which_is_not_an_empty_list(self):
        # "nothing was skipped" and "nobody has started yet" are the two answers this field
        # exists to keep apart; JSON null is the only value that cannot be read as the first.
        body = self.state({"mode": "ndtwin", "package": None, "skipped": None}, {})
        self.assertIsNone(body["control_plane"]["skipped"])

    def test_every_switch_reports_how_many_package_entries_were_recorded_but_not_applied(self):
        body = self.state({"mode": "ndtwin", "package": "/pkg", "skipped": []}, {"1": 5})
        self.assertEqual(body["switches"]["1"]["entries_recorded"], 5)
        # 0, not absent: a switch the package declares no entries for is a different statement
        # from a switch nobody asked about, and both must be answerable from one poll.
        self.assertEqual(body["switches"]["2"]["entries_recorded"], 0)

    def test_every_switch_says_which_pipeline_it_is_running_and_names_it(self):
        # [Co-developed with claude code -- Adam] TICKET-P2 2.2. Without this a fabric with no
        # telemetry and no discovered links is indistinguishable from a broken one: the reason
        # is which program is loaded, and nothing else on this endpoint says.
        body = self.state(
            {"mode": "ndtwin", "package": "/pkg", "skipped": []}, {},
            pipelines={"1": {"ndtwin": False, "p4info": "/pkg/build/basic.p4info.txtpb",
                             "p4info_sha256": "9213871cee36bd93"},
                       "2": {"ndtwin": True, "p4info": "/p/ndtwin_switch.p4info.txt",
                             "p4info_sha256": "d54ff55208340f3a"}})
        self.assertFalse(body["switches"]["1"]["pipeline"]["ndtwin"])
        self.assertEqual(body["switches"]["1"]["pipeline"]["p4info_sha256"],
                         "9213871cee36bd93")
        self.assertTrue(body["switches"]["2"]["pipeline"]["ndtwin"])

    def test_every_switch_reports_what_was_written_and_that_none_of_it_is_journaled(self):
        body = self.state(
            {"mode": "ndtwin", "package": "/pkg", "skipped": []}, {},
            written={"1": {"recorded": 5, "applied": 4, "failed": 1, "api_writes": 2,
                           "journaled": False}})
        self.assertEqual(body["switches"]["1"]["table_entries"],
                         {"recorded": 5, "applied": 4, "failed": 1, "api_writes": 2,
                          "journaled": False})
        # A switch nobody reported on still answers, with zeroes and the same `journaled: false`.
        # Absent would be readable as "this proxy is too old to say", which is the shape the
        # whole disclosure exists to close.
        self.assertEqual(body["switches"]["2"]["table_entries"],
                         {"recorded": 0, "applied": 0, "failed": 0, "api_writes": 0,
                          "journaled": False})

    def test_journaled_is_false_even_when_entries_were_applied(self):
        # 🔴 The one number a reader could misread as reassurance. `applied: 4` says four rules
        # are on the switch; `journaled: false` says all four are gone after a proxy restart and
        # nothing replays them (Adam 2026-09-18, option a).
        body = self.state({"mode": "ndtwin", "package": "/pkg", "skipped": []}, {},
                          written={"1": {"recorded": 4, "applied": 4, "failed": 0,
                                         "api_writes": 0, "journaled": False}})
        self.assertIs(body["switches"]["1"]["table_entries"]["journaled"], False)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ProductionWiresTheDisclosureItselfTest(unittest.TestCase):
    """
    Importing `proxy_agent.main` is what wires `GET /p4/switch_state` and the readopt endpoint.

    [Co-developed with claude code -- Adam]
    Every other test in this file injects its own stubs, which is the right way to test what the
    endpoint DOES and says nothing about whether anybody calls inject_* in production. That gap
    is finding #71 exactly, and it shipped once with 33 green tests behind it.
    """

    def test_main_injected_every_report_the_endpoint_reads(self):
        for name, wired in WIRED_AT_IMPORT.items():
            self.assertIsNotNone(wired, f"main.py never injected {name}; the endpoint would "
                                        f"serve a switch_state with that field missing, which "
                                        f"reads as a proxy too old to have it")

    def test_they_are_mains_own_functions_and_not_somebody_elses_copies(self):
        self.assertIs(WIRED_AT_IMPORT["pipelines"], main.pipelines_report)
        self.assertIs(WIRED_AT_IMPORT["table_entries"], main.table_entries_report)
        self.assertIs(WIRED_AT_IMPORT["note_api_write"], main.note_api_table_entry_write)
        self.assertIs(WIRED_AT_IMPORT["readopt_runner"], main.readopt_switch)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class WhichPipelineEachSwitchRunsTest(unittest.TestCase):
    """
    `main._pipeline_is_ndtwin`, the predicate every TICKET-P2 branch turns on.

    [Co-developed with claude code -- Adam]
    Computed as an equivalence against what `baseline()` answers for the same switch rather than
    as "did the manifest declare an override". A package that names NDTwin's own artefacts
    explicitly is running NDTwin's pipeline however it spelled it, and the client is built from
    the VALUE, so the value is what decides.
    """

    def package(self, pipeline):
        spec = app_package.SwitchSpec(dpid=1, name="s1", pipeline=pipeline, entries=None)
        return app_package.Package(dir="/pkg", name="exercise", switches=(spec,))

    def test_the_baseline_fabric_runs_ndtwins_own_pipeline(self):
        self.assertTrue(main._pipeline_is_ndtwin(app_package.baseline(), 1))

    def test_a_package_that_overrides_nothing_still_runs_ndtwins_own_pipeline(self):
        self.assertTrue(main._pipeline_is_ndtwin(self.package(None), 1))

    def test_a_package_naming_its_own_artefacts_does_not(self):
        self.assertFalse(main._pipeline_is_ndtwin(
            self.package(("build/basic.p4.p4info.txtpb", "build/basic.json")), 1))

    def test_a_package_that_names_ndtwins_own_paths_is_not_called_foreign(self):
        # 🔴 The discriminating case. "Did the manifest declare a pipeline" answers False here
        # and would switch off telemetry, LLDP and the routes on a fabric running our own
        # program -- a fabric-wide degradation caused by how a file was written.
        self.assertTrue(main._pipeline_is_ndtwin(
            self.package(app_package.BASELINE_PIPELINE), 1))

    def test_a_switch_the_package_does_not_mention_follows_the_fabric_wide_answer(self):
        self.assertTrue(main._pipeline_is_ndtwin(
            self.package(("build/basic.p4.p4info.txtpb", "build/basic.json")), 7))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class WhatTheProxySaysAboutOneSwitchesPipelineTest(unittest.TestCase):
    """
    `main._p4info_fingerprint` and `main.pipeline_report_for`.

    [Co-developed with claude code -- Adam]
    The fingerprint is the stable identifier for "which program is this", which CLAUDE.md
    requires of anything that names a binary. It had no test at all until round 2 -- it was
    only ever seen through `pipeline_report_for`, which on this tree answers `None` for every
    package fixture because their artefact paths do not exist, so the success path of the one
    function that produces the identifier was never executed.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_p4info_sha_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_a_real_file_gets_sixteen_lowercase_hex_characters(self):
        path = os.path.join(self.tmp, "x.p4info.txt")
        with open(path, "wb") as fh:
            fh.write(b"pkg_info { name: \"basic\" }\n")
        digest = main._p4info_fingerprint(path)
        self.assertEqual(len(digest), 16)
        self.assertTrue(all(c in "0123456789abcdef" for c in digest), digest)

    def test_it_is_the_first_sixteen_of_the_files_sha256(self):
        import hashlib
        path = os.path.join(self.tmp, "y.p4info.txt")
        body = b"tables { preamble { id: 1 } }\n"
        with open(path, "wb") as fh:
            fh.write(body)
        self.assertEqual(main._p4info_fingerprint(path),
                         hashlib.sha256(body).hexdigest()[:16])

    def test_two_different_programs_do_not_share_a_fingerprint(self):
        paths = []
        for name, body in (("a", b"one"), ("b", b"two")):
            path = os.path.join(self.tmp, name)
            with open(path, "wb") as fh:
                fh.write(body)
            paths.append(path)
        self.assertNotEqual(main._p4info_fingerprint(paths[0]),
                            main._p4info_fingerprint(paths[1]))

    def test_a_missing_file_is_none_rather_than_an_invented_identifier(self):
        # None says "nobody could read this program". A zero-length digest, or the hash of an
        # empty string, would be an identifier -- and two switches whose p4info is missing would
        # then report the SAME program.
        self.assertIsNone(main._p4info_fingerprint(os.path.join(self.tmp, "not-there")))

    def test_the_real_ndtwin_p4info_fingerprints_when_it_is_on_disk(self):
        if not HAVE_P4INFO:  # pragma: no cover -- depends on l0_build_check.sh p4
            self.skipTest("p4_src/build/ndtwin_switch.p4info.txt is not built")
        self.assertEqual(len(main._p4info_fingerprint(P4INFO)), 16)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class EachSwitchNamesItsOwnSkippedStepsTest(unittest.TestCase):
    """
    TICKET-P2 round 2: the per-switch half of the disclosure lives on that switch.

    [Co-developed with claude code -- Adam]
    🔴 The clone session and the sFlow registration are programmed into ONE switch's PRE, so on
    a mixed fabric they are skipped for the package's switches and done for every other one.
    Saying `clone_session` in the fabric-wide `control_plane.skipped` there is a true sentence
    about one switch told about ten, and an operator who acts on it goes looking for a telemetry
    fault on nine switches that have none. (Round 1 did exactly that; the judge caught it.)
    """

    def package(self, pipeline):
        spec = app_package.SwitchSpec(dpid=1, name="s1", pipeline=pipeline, entries=None)
        return app_package.Package(dir="/pkg", name="exercise", switches=(spec,))

    def test_a_foreign_switch_names_the_two_steps_it_does_not_get(self):
        report = main.pipeline_report_for(
            1, self.package(("build/basic.p4info.txtpb", "build/basic.json")))
        self.assertFalse(report["ndtwin"])
        self.assertEqual(report["skipped"], sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]))

    def test_an_ndtwin_switch_says_it_skipped_nothing_rather_than_saying_nothing(self):
        report = main.pipeline_report_for(1, self.package(None))
        self.assertTrue(report["ndtwin"])
        self.assertEqual(report["skipped"], [])

    def test_the_names_are_the_same_constants_the_fabric_wide_list_uses(self):
        # One vocabulary, two scopes. A second spelling would mean a reader had to learn which
        # list a name came from before knowing what it meant.
        self.assertEqual(main.FOREIGN_PIPELINE_SWITCH_SKIPS, (main.SKIP_CLONE,
                                                              main.SKIP_TELEMETRY))
        self.assertEqual(main.FOREIGN_PIPELINE_FABRIC_SKIPS, (main.SKIP_LLDP, main.SKIP_WATCHDOG,
                                                              main.SKIP_ROUTES))
        for name in main.FOREIGN_PIPELINE_SWITCH_SKIPS + main.FOREIGN_PIPELINE_FABRIC_SKIPS:
            self.assertIn(name, main.EXTERNAL_SKIPS)

    def test_the_two_scopes_do_not_overlap(self):
        # 🔴 The property the round-1 bug violated: a step is disclosed at one scope or the
        # other, never both, or a reader counting either list double-counts.
        self.assertEqual(set(main.FOREIGN_PIPELINE_SWITCH_SKIPS)
                         & set(main.FOREIGN_PIPELINE_FABRIC_SKIPS), set())


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheProxyReadsTheSameModelTheFabricBuildsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_app_pkg_proxy_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_a_package_topology_is_what_the_proxy_loads(self):
        directory = os.path.join(self.tmp, "pkg")
        os.makedirs(os.path.join(directory, "ndtwin"))
        shutil.copyfile(FOUR_HOST_MODEL, os.path.join(directory, "ndtwin", "topology.json"))
        with open(os.path.join(directory, "package.json"), "w") as fh:
            json.dump({"format": 1, "name": "basic", "topology": "ndtwin/topology.json",
                       "hosts": {}, "switches": {}, "control_plane": {"mode": "ndtwin"}}, fh)
        package = app_package.load(directory)
        # host_count 9999 matches no model at all, so reaching a model here can only have come
        # from the package: the proxy and the fabric size themselves the same way, and when the
        # package names a model the count is not consulted.
        model = main.load_fabric_model(package=package, host_count=9999)
        self.assertEqual(len(topo_from_json.hosts(model)), 4)


if __name__ == "__main__":
    unittest.main(verbosity=2)

# [Co-developed with claude code -- Adam]
