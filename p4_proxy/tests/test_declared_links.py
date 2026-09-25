"""
Declared links: a foreign fabric's inter-switch cables come from its package, not from LLDP.

[Co-developed with claude code -- Adam]

TICKET-P4-roles section 2.3. On a fabric with a foreign switch there is no LLDP -- the programs
carry no controller header -- so the proxy's graph never learned an inter-switch edge, served
none on /v1.0/topology/links, and the kernel's topology poll never enabled one: live
`2026-09-19T062604Z_02_app_basic` has all eight of pod-topo's inter-switch directions at
`is_enabled: false, is_up: false`. The package already carries the topology, so the cables are
entered from it.

What is asserted, and what each assertion stands against:

  * the eight directions reach `net` and `render_links` -- the whole point (M-R6);
  * the kernel is told NOTHING: no link_recovery_detected, no link_failure_detected -- a
    declaration is "this cable exists", not "this cable just came back", and a recovery report
    would fight the kernel's own guard against resurrecting a link declared down (M-R7);
  * the beacon evidence the watchdog reads is untouched, and every declared link is marked
    `source: "declared"` with `down: null` -- nobody is checking it (2.3-4);
  * a fabric that runs LLDP seeds nothing;
  * the routes come back exactly when EVERY foreign switch binds roles.ipv4_route with owner
    ndtwin, and stay skipped with one unbound switch or one package-owned table (M-R8, M-R9);
  * LLDP and the watchdog stay skipped on a foreign fabric whatever the roles say (M-R10).

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
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
sys.path.insert(0, PROXY_DIR)
sys.path.insert(0, os.path.join(PROXY_DIR, "mininet"))

try:
    import proxy_agent.main as main
    from proxy_agent import route_binding, ryu_topology
    from proxy_agent.topology_manager import TopologyManager
    from tests.test_startup import FakeClient, FakeTopo, run_startup

    HAVE_PROXY = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_PROXY = False

import app_package  # noqa: E402

BASIC_POD = os.path.join(REPO, "tools", "p4_exercise", "tests", "fixtures", "basic")

#: pod-topo's four cables, transcribed from exercises/basic/pod-topo/topology.json (the same
#: transcription tools/p4_exercise/tests/test_convert.py keeps) -- and both directions of each.
POD_CABLES = ((1, 3, 3, 1), (1, 4, 4, 2), (2, 3, 4, 1), (2, 4, 3, 2))
POD_DIRECTIONS = sorted(POD_CABLES + tuple((d, dp, s, sp) for s, sp, d, dp in POD_CABLES))


def a_pod_topo_model(root):
    """The NDTwin model convert.py writes for tutorials' basic pod-topo. Returns its path."""
    tools = os.path.join(REPO, "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    from p4_exercise import convert  # noqa: E402

    out = os.path.join(root, "basic")
    convert.convert(BASIC_POD, "pod-topo/topology.json", out, p4_rel="solution/basic.p4")
    return os.path.join(out, "ndtwin", "topology.json")


class RecordingNotifier:
    """Everything the kernel would have been told. KernelNotifier's surface, all of it."""

    def __init__(self):
        self.calls = []

    def link_failure(self, *link):
        self.calls.append(("link_failure", link))
        return True

    def link_recovery(self, *link):
        self.calls.append(("link_recovery", link))
        return True

    def all_destination_paths(self, paths):
        self.calls.append(("all_destination_paths", len(paths)))
        return True

    def switch_entered(self, dpid):
        self.calls.append(("switch_entered", dpid))
        return True


class Switch:
    """What add_switch touches on a client."""

    packet_in_callback = None


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class SeedingTheGraphTest(unittest.TestCase):
    """TopologyManager.seed_declared_links against a real converted pod-topo model."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_declared_links_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.model = a_pod_topo_model(self.tmp)
        self.kernel = RecordingNotifier()
        self.topo = TopologyManager(kernel_notifier=self.kernel)
        for dpid in (1, 2, 3, 4):
            self.topo.add_switch(dpid, Switch())

    def rendered(self):
        return sorted((int(link["src"]["dpid"], 16), int(link["src"]["port_no"], 16),
                       int(link["dst"]["dpid"], 16), int(link["dst"]["port_no"], 16))
                      for link in ryu_topology.render_links(self.topo.net,
                                                            self.topo.down_link_endpoints()))

    def test_all_eight_directions_are_served_to_the_kernels_topology_poll(self):
        # Before: the state live 062604Z_02 shows the kernel -- nothing to enable.
        self.assertEqual(self.rendered(), [])
        self.assertEqual(self.topo.seed_declared_links(self.model), 8)
        self.assertEqual(self.rendered(), POD_DIRECTIONS)

    def test_the_kernel_is_told_nothing_by_a_declaration(self):
        self.topo.seed_declared_links(self.model)
        self.assertEqual([c for c in self.kernel.calls
                          if c[0] in ("link_recovery", "link_failure")], [],
                         "a declared cable was reported to the kernel as a link transition")

    def test_a_watchdog_pass_after_seeding_still_tells_the_kernel_nothing(self):
        # The evidence map is untouched, so there is nothing for a pass to time out and report.
        self.topo.seed_declared_links(self.model)
        self.assertEqual(self.topo.check_link_beacons(now=10_000.0),
                         {"down": [], "up": [], "unacked": []})
        self.assertEqual(self.kernel.calls, [])

    def test_the_beacon_evidence_the_watchdog_reads_is_untouched(self):
        self.topo.seed_declared_links(self.model)
        self.assertEqual(self.topo._link_beacons, {})
        self.assertEqual(self.topo.down_link_endpoints(), set())

    def test_every_declared_link_says_it_is_declared_and_that_nobody_checks_it(self):
        self.topo.seed_declared_links(self.model)
        links = self.topo.link_liveness()
        self.assertEqual(sorted(links),
                         sorted(f"{s}:{sp}->{d}:{dp}" for s, sp, d, dp in POD_DIRECTIONS))
        for name, entry in links.items():
            with self.subTest(link=name):
                self.assertEqual(entry["source"], "declared")
                self.assertIsNone(entry["down"], "down: false would claim a check nobody made")

    def test_seeding_twice_enters_each_direction_once(self):
        self.assertEqual(self.topo.seed_declared_links(self.model), 8)
        self.assertEqual(self.topo.seed_declared_links(self.model), 0)
        self.assertEqual(len(self.topo.declared_links()), 8)

    def test_a_link_to_a_switch_that_never_connected_is_not_entered(self):
        topo = TopologyManager(kernel_notifier=self.kernel)
        for dpid in (1, 2, 3):
            topo.add_switch(dpid, Switch())
        entered = topo.seed_declared_links(self.model)
        self.assertEqual(entered, 4, "s4's two cables are 4 of the 8 directions")
        self.assertNotIn(4, topo.net.nodes, "an untyped node would be routed THROUGH")

    def test_the_routes_over_declared_links_are_computable(self):
        # install_initial_routes' search sees the declared cables: h1 (s1) reaches h3 (s2).
        self.topo.seed_declared_links(self.model)
        self.topo.add_host("10.0.1.1", "08:00:00:00:01:11", 1, 1)
        self.topo.add_host("10.0.3.3", "08:00:00:00:03:33", 2, 1)
        paths = self.topo.calculate_all_paths()
        self.assertEqual(len(paths["10.0.3.3"][1]["path"]), 4)  # s1 -> s3|s4 -> s2 -> h3


# --- startup: which fabrics seed, and when the routes come back --------------------------------


class SeedingTopo(FakeTopo):
    """FakeTopo plus the two calls a foreign fabric's startup now makes."""

    def __init__(self, seed_result=8):
        super().__init__()
        self.seeded = []
        self.installs = 0
        #: What seed_declared_links answers: a count, or an exception it raises.
        self.seed_result = seed_result

    def seed_declared_links(self, path=None):
        self.seeded.append(path)
        if isinstance(self.seed_result, BaseException):
            raise self.seed_result
        return self.seed_result

    def install_initial_routes(self, only_dpid=None):
        self.installs += 1
        return 12, 12


def a_foreign_package(dpids=(1, 2), owner=None):
    switches = tuple(app_package.SwitchSpec(dpid=dpid, name=f"s{dpid}",
                                            pipeline=("build/basic.p4info.txtpb",
                                                      "build/basic.json"),
                                            entries=None)
                     for dpid in dpids)
    roles = None
    if owner is not None:
        roles = app_package.Roles(ipv4_route=app_package.RouteRole(
            owner=owner, table="MyIngress.ipv4_lpm", match_field="hdr.ipv4.dstAddr",
            action="MyIngress.ipv4_forward", dst_mac="dstAddr", port="port"))
    return app_package.Package(dir="/packages/basic", name="basic", switches=switches,
                               roles=roles)


def bound(owner):
    """A package binding with `owner`, as build_p4_client would have resolved it on basic."""
    return route_binding.RouteBinding(
        table="MyIngress.ipv4_lpm", match_field="hdr.ipv4.dstAddr",
        action="MyIngress.ipv4_forward", dst_mac_param="dstAddr", port_param="port",
        owner=owner, source=route_binding.SOURCE_PACKAGE)


def clients_bound(*bindings):
    """{dpid: FakeClient} with each client's route_binding as given (None = unbound)."""
    out = {}
    for dpid, binding in enumerate(bindings, start=1):
        client = FakeClient(dpid)
        client.route_binding = binding
        out[dpid] = client
    return out


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class WhichFabricsSeedAndWhenRoutesComeBackTest(unittest.TestCase):
    """2.3-1 and 2.3-3, decided in startup()."""

    def setUp(self):
        saved = (dict(main._fabric), dict(main._capabilities))

        def restore():
            main._fabric.clear()
            main._fabric.update(saved[0])
            main._capabilities.clear()
            main._capabilities.update(saved[1])
        self.addCleanup(restore)

    def start(self, clients, package):
        topo = SeedingTopo()
        summary, _parts = run_startup(clients, topo=topo, package=package)
        return summary, topo

    def test_an_all_ndtwin_fabric_seeds_nothing_and_runs_lldp_as_before(self):
        summary, topo = self.start({1: FakeClient(1), 2: FakeClient(2)}, app_package.baseline())
        self.assertEqual(topo.seeded, [])
        self.assertIn("lldp", topo.started)
        self.assertIn("watchdog", topo.started)
        self.assertEqual(summary["control_plane"]["skipped"], [])

    def test_a_foreign_fabric_seeds_its_declared_links(self):
        _summary, topo = self.start(clients_bound(None, None), a_foreign_package())
        self.assertEqual(len(topo.seeded), 1)

    def test_a_fabric_that_skips_its_routes_tells_the_route_writer(self):
        # Section 7 ruling 5 item 1: the declared cables are in `net` now, so the fabric's
        # route skip has to reach whatever writes routes later (readopt), not only startup.
        _summary, topo = self.start(clients_bound(None, None), a_foreign_package())
        self.assertIs(topo.routes_to_attached_hosts_only, True)

    def test_a_fabric_whose_routes_ndtwin_owns_does_not_restrict_the_writer(self):
        _summary, topo = self.start(clients_bound(bound("ndtwin"), bound("ndtwin")),
                                    a_foreign_package(owner="ndtwin"))
        self.assertIs(topo.routes_to_attached_hosts_only, False)
        self.assertEqual(topo.installs, 1)

    def test_an_all_ndtwin_fabric_does_not_restrict_the_writer(self):
        _summary, topo = self.start({1: FakeClient(1), 2: FakeClient(2)}, app_package.baseline())
        self.assertIs(topo.routes_to_attached_hosts_only, False)

    def test_every_foreign_switch_owned_by_ndtwin_brings_the_routes_back(self):
        summary, topo = self.start(clients_bound(bound("ndtwin"), bound("ndtwin")),
                                   a_foreign_package(owner="ndtwin"))
        self.assertNotIn(main.SKIP_ROUTES, summary["control_plane"]["skipped"])
        self.assertEqual(topo.installs, 1)
        self.assertEqual(summary["owned_routes"], {"installed": 12, "attempted": 12})

    def test_one_unbound_switch_keeps_the_routes_skipped_for_the_whole_fabric(self):
        summary, topo = self.start(clients_bound(bound("ndtwin"), None),
                                   a_foreign_package(owner="ndtwin"))
        self.assertIn(main.SKIP_ROUTES, summary["control_plane"]["skipped"])
        self.assertEqual(topo.installs, 0)
        self.assertIsNone(summary["owned_routes"])

    def test_one_package_owned_table_keeps_the_routes_skipped_for_the_whole_fabric(self):
        summary, topo = self.start(clients_bound(bound("ndtwin"), bound("package")),
                                   a_foreign_package(owner="ndtwin"))
        self.assertIn(main.SKIP_ROUTES, summary["control_plane"]["skipped"])
        self.assertEqual(topo.installs, 0)

    def test_no_roles_at_all_keeps_all_three_skipped_exactly_as_before(self):
        summary, topo = self.start(clients_bound(None, None), a_foreign_package())
        self.assertEqual(summary["control_plane"]["skipped"],
                         sorted([main.SKIP_LLDP, main.SKIP_WATCHDOG, main.SKIP_ROUTES]))
        self.assertEqual(topo.installs, 0)

    def test_lldp_and_the_watchdog_stay_off_on_a_foreign_fabric_even_when_every_table_is_owned(
            self):
        summary, topo = self.start(clients_bound(bound("ndtwin"), bound("ndtwin")),
                                   a_foreign_package(owner="ndtwin"))
        self.assertNotIn("lldp", topo.started)
        self.assertNotIn("watchdog", topo.started)
        self.assertIn(main.SKIP_LLDP, summary["control_plane"]["skipped"])
        self.assertIn(main.SKIP_WATCHDOG, summary["control_plane"]["skipped"])

    def test_an_external_fabric_seeds_nothing_this_cut_leaves_it_as_it_was(self):
        package = app_package.Package(dir="/packages/p4runtime", name="p4runtime",
                                      mode="external", election_id=(0, 65535))
        _summary, topo = self.start({1: FakeClient(1)}, package)
        self.assertEqual(topo.seeded, [])

    def test_a_topology_double_without_the_seeding_call_does_not_stop_startup(self):
        # Every pre-roles FakeTopo is this. Round 2 (TICKET-P4-roles section 7 ruling 5, item
        # 8): the fabric's MODE is still "declared" -- the seed failing does not make it an
        # external fabric -- and the failure is disclosed at fabric level instead.
        summary, _parts = run_startup(clients_bound(None), topo=FakeTopo(),
                                      package=a_foreign_package(dpids=(1,)))
        self.assertEqual(summary["capabilities"]["1"]["link_discovery"], "declared")
        self.assertIn("AttributeError", main.declared_links_report()["error"])


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class LinkDiscoveryIsTheModeNotTheSeedCountTest(unittest.TestCase):
    """
    TICKET-P4-roles section 7 ruling 5, item 8. [Co-developed with claude code -- Adam]

    Round 1 derived `link_discovery` from how many directions the seed entered, so a foreign
    fabric whose package declares no inter-switch cable -- or whose seed raised -- said "none",
    the word that also means an external control plane. A reader could not tell the two apart.
    The word is now the fabric's MODE (lldp / declared / none = external only), and what the
    seed actually did is a separate, fabric-level `declared_links` object on switch_state.
    """

    def setUp(self):
        saved = (dict(main._fabric), dict(main._capabilities))

        def restore():
            main._fabric.clear()
            main._fabric.update(saved[0])
            main._capabilities.clear()
            main._capabilities.update(saved[1])
        self.addCleanup(restore)

    def start(self, topo, package=None, clients=None):
        clients = clients_bound(None) if clients is None else clients
        package = a_foreign_package(dpids=(1,)) if package is None else package
        summary, _parts = run_startup(clients, topo=topo, package=package)
        return summary

    def test_a_foreign_fabric_that_declares_no_link_still_says_declared(self):
        summary = self.start(SeedingTopo(seed_result=0))
        self.assertEqual(summary["capabilities"]["1"]["link_discovery"], "declared")
        self.assertEqual(main.declared_links_report(), {"directions": 0, "error": None})

    def test_a_seed_that_raises_says_declared_and_names_the_error(self):
        summary = self.start(SeedingTopo(seed_result=OSError("no such model")))
        self.assertEqual(summary["capabilities"]["1"]["link_discovery"], "declared")
        self.assertEqual(main.declared_links_report(),
                         {"directions": 0, "error": "OSError: no such model"})

    def test_a_seed_that_worked_reports_its_count_and_no_error(self):
        self.start(SeedingTopo(seed_result=8))
        self.assertEqual(main.declared_links_report(), {"directions": 8, "error": None})

    def test_a_fabric_that_declares_nothing_reports_null(self):
        self.start(SeedingTopo(), package=app_package.baseline(),
                   clients={1: FakeClient(1)})
        self.assertIsNone(main.declared_links_report())
        external = app_package.Package(dir="/packages/p4runtime", name="p4runtime",
                                       mode="external", election_id=(0, 65535))
        self.start(SeedingTopo(), package=external, clients={1: FakeClient(1)})
        self.assertIsNone(main.declared_links_report())

    def test_none_is_for_an_external_control_plane_only(self):
        # An all-NDTwin fabric whose LLDP did not start is still an LLDP fabric by mode; that
        # nothing reroutes there is what `reroute: false` says.
        stopped = {"lldp": False, "watchdog": False, "declared_links": False}
        caps = main.capabilities_for("ndtwin", "baseline", True, False, stopped)
        self.assertEqual((caps["link_discovery"], caps["reroute"]), ("lldp", False))
        caps = main.capabilities_for("unbound", None, False, True, stopped)
        self.assertEqual(caps["link_discovery"], "none")


if __name__ == "__main__":
    unittest.main(verbosity=2)
