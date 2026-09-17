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
                      api_routes.entries_recorded_report)
        api_routes.topology = self.FakeTopology()
        self.addCleanup(self.restore)

    def restore(self):
        (api_routes.topology, api_routes.control_plane_report,
         api_routes.entries_recorded_report) = self.saved

    def state(self, report, recorded):
        api_routes.inject_control_plane(lambda: report, lambda: recorded)
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
