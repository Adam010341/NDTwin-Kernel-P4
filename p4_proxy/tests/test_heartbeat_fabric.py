"""
Which fabric gets the heartbeat watchdog, what `reroute` then says, and what switch_state discloses.

[Co-developed with claude code -- Adam]

TICKET-P4-heartbeat segment W, section 1:

  * the watchdog on a foreign fabric is fed by the heartbeat, and ONLY there -- NDTwin's own
    pipeline keeps LLDP (段 W: "NDTwin 自己的 pipeline（LLDP）不啟動心跳"). [Co-developed with
    claude code -- Adam] Since 09-27 that includes an external control plane on its own pipeline,
    DETECT ONLY: its links are declared and judged like any foreign fabric's, a cut is told to the
    kernel, and nothing is written to a switch -- `reroute` stays false with the reason
    `external_control_plane` whatever the heartbeat says. An external control plane on NDTwin's
    own pipeline is left as it was (no declared links, no heartbeat);
  * the LLDP beacons stay off on a foreign fabric and `lldp_discovery` stays named in
    `control_plane.skipped` -- they ride a controller header those programs do not have
    (TICKET-P4-roles M-R10). The heartbeat watchdog is a different evidence source through the
    same pass, and it is disclosed on its own. [Co-developed with claude code -- Adam] Adam's
    ruling E (09-27): while the heartbeat drives the watchdog, `link_watchdog` is NOT in
    `control_plane.skipped` -- it runs; it is named there only when the heartbeat watchdog did not
    start;
  * `capabilities.reroute` is true only when the heartbeat is usable AND every foreign switch
    binds its route table with owner ndtwin; otherwise false, and the reason is served, in the
    first cut's words (`unbound`, `owned_by_package`) where the tables are the cause;
  * `link_discovery` says `heartbeat` while the heartbeat is usable, `declared` otherwise;
  * the heartbeat's side effects -- the live counters and segment S's census -- are on
    switch_state (段 W bullet 6), and a frame that reached a host is named, not averaged away.

🔴 THE CAPABILITIES OBJECT KEEPS ITS FIVE KEYS. It is the contract the GUI draft and the third
cut's kernel read (TICKET-P4-roles appendix A, asserted word for word in test_switch_state.py);
the reason is a FABRIC fact, like `reroute` itself, and is served at the top level as `reroute`.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

from __future__ import annotations

import asyncio
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "mininet"))

# Only the THIRD-PARTY dependencies decide a skip; this ticket's own modules failing to import is
# a failure (the red-first run must be red, not skipped).
try:
    import fastapi  # noqa: F401
    import grpc  # noqa: F401
    import networkx  # noqa: F401

    HAVE_PROXY = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_PROXY = False

if HAVE_PROXY:
    import proxy_agent.main as main
    from proxy_agent import api_routes
    from proxy_agent import link_heartbeat as hb
    from proxy_agent import route_binding
    from tests.test_declared_links import SeedingTopo, a_foreign_package, bound, clients_bound
    from tests.test_startup import FakeClient, run_startup

import app_package  # noqa: E402


def a_reading(usable=True, reason=None, **kw):
    kw.setdefault("detail", "a reading made up by the test")
    kw.setdefault("session", "0102030405060708")
    kw.setdefault("pid", 4242)
    kw.setdefault("period_s", 5)
    kw.setdefault("age_s", 0.4)
    kw.setdefault("side_effects", {"foreign_frames": 0, "forwarded_between_switches": 0,
                                   "forwarded_to_hosts": 0, "misdelivered": 0})
    return hb.Reading(usable=usable, reason=reason, **kw)


class FakeEvidence:
    """What startup and the reports ask of the evidence: its path, its last reading."""

    def __init__(self, reading, path):
        self.reading = reading
        self.path = path

    def last(self):
        return self.reading


class HeartbeatTopo(SeedingTopo if HAVE_PROXY else object):
    """SeedingTopo plus the entry a foreign fabric's startup now calls."""

    def __init__(self, reading=None, raises=None):
        super().__init__()
        self.heartbeat_calls = []
        self.reading = reading if reading is not None else a_reading()
        self.raises = raises
        self.evidence = None

    def watchdog_passes(self):
        return list(getattr(self, "passes", []))

    def start_heartbeat_watchdog(self, path=None, owner_uid=None):
        self.heartbeat_calls.append((path, owner_uid))
        self.started.append("heartbeat-watchdog")
        if self.raises is not None:
            raise self.raises
        self.evidence = FakeEvidence(self.reading, path)
        return self.evidence


class SavedGlobals:
    """main's module state, put back after every test."""

    def save(self, testcase):
        saved = (dict(main._fabric), dict(main._capabilities), dict(main._heartbeat))

        def restore():
            for target, value in zip((main._fabric, main._capabilities, main._heartbeat), saved):
                target.clear()
                target.update(value)
        testcase.addCleanup(restore)


EXTERNAL = None
EXTERNAL_FOREIGN = None
if HAVE_PROXY:
    #: An external control plane on NDTwin's own pipeline (no switch names a program of its own).
    EXTERNAL = app_package.Package(dir="/packages/p4runtime", name="p4runtime", mode="external",
                                   election_id=(0, 65535))
    #: [Co-developed with claude code -- Adam] What `convert.py` actually writes for
    #: exercises/p4runtime and flowcache: an external control plane on the EXERCISE'S OWN
    #: pipeline -- the 3 external arms of live-p1/06.
    EXTERNAL_FOREIGN = app_package.Package(
        dir="/packages/p4runtime", name="p4runtime", mode="external", election_id=(0, 65535),
        switches=tuple(app_package.SwitchSpec(dpid=dpid, name=f"s{dpid}",
                                              pipeline=("build/advanced_tunnel.p4.p4info.txtpb",
                                                        "build/advanced_tunnel.json"),
                                              entries=None)
                       for dpid in (1, 2)))

#: What a client is asked to do that puts something on a switch (FakeClient.events).
WRITE_EVENTS = {"pipeline", "clone", "multicast", "table_entry"}


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class WhichFabricGetsTheHeartbeatWatchdogTest(unittest.TestCase):

    def setUp(self):
        SavedGlobals().save(self)

    def test_a_foreign_fabric_starts_it_on_the_helpers_report(self):
        topo = HeartbeatTopo()
        run_startup(clients_bound(bound("ndtwin"), bound("ndtwin")), topo=topo,
                    package=a_foreign_package(owner="ndtwin"))
        self.assertEqual(topo.heartbeat_calls,
                         [(main.HEARTBEAT_REPORT_PATH, main.HEARTBEAT_REPORT_UID)])
        self.assertEqual(main.HEARTBEAT_REPORT_PATH, hb.REPORT_PATH)
        self.assertEqual(main.HEARTBEAT_REPORT_UID, 0)

    def test_an_unbound_foreign_fabric_starts_it_too_detection_is_not_rerouting(self):
        topo = HeartbeatTopo()
        run_startup(clients_bound(None, None), topo=topo, package=a_foreign_package())
        self.assertEqual(len(topo.heartbeat_calls), 1)

    def test_the_lldp_beacons_stay_off_and_named_skipped_but_the_watchdog_runs(self):
        # [Co-developed with claude code -- Adam] Adam's ruling E (09-27): the heartbeat drives the
        # watchdog, so the watchdog is not skipped -- only the beacons are. (This test used to
        # assert link_watchdog IN the list.)
        topo = HeartbeatTopo()
        summary, _ = run_startup(clients_bound(bound("ndtwin"), bound("ndtwin")), topo=topo,
                                 package=a_foreign_package(owner="ndtwin"))
        self.assertNotIn("lldp", topo.started)
        self.assertNotIn("watchdog", topo.started, "the LLDP beacon watchdog itself stays off")
        self.assertIn("heartbeat-watchdog", topo.started)
        self.assertIn(main.SKIP_LLDP, summary["control_plane"]["skipped"])
        self.assertNotIn(main.SKIP_WATCHDOG, summary["control_plane"]["skipped"])
        self.assertEqual(main.control_plane_report()["skipped"], summary["control_plane"]["skipped"],
                         "switch_state serves the same list")

    def test_an_unbound_fabric_reports_its_watchdog_running_too(self):
        # [Co-developed with claude code -- Adam] Ruling E: detecting without rerouting is still
        # the watchdog running -- 07's unbound expectation, [install_initial_routes, lldp_discovery].
        topo = HeartbeatTopo()
        summary, _ = run_startup(clients_bound(None, None), topo=topo, package=a_foreign_package())
        self.assertEqual(sorted(summary["control_plane"]["skipped"]),
                         sorted([main.SKIP_LLDP, main.SKIP_ROUTES]))

    def test_a_heartbeat_watchdog_that_did_not_start_leaves_the_watchdog_named_skipped(self):
        # [Co-developed with claude code -- Adam] Ruling E's other half: when the heartbeat watchdog
        # did not start, nothing watches the links, and the list must still say so.
        for topo in (HeartbeatTopo(raises=OSError("the report cannot be read")), SeedingTopo()):
            with self.subTest(topo=type(topo).__name__):
                summary, _ = run_startup(clients_bound(bound("ndtwin"), bound("ndtwin")), topo=topo,
                                         package=a_foreign_package(owner="ndtwin"))
                self.assertEqual(main.heartbeat_report()["watchdog"], "not_started")
                self.assertIn(main.SKIP_WATCHDOG, summary["control_plane"]["skipped"])
                self.assertIn(main.SKIP_LLDP, summary["control_plane"]["skipped"])

    def test_the_startup_log_names_the_same_skipped_list_switch_state_serves(self):
        # [Co-developed with claude code -- Adam] The opus judge's F2 (09-27): the foreign fabric's
        # startup line was printed before the heartbeat decision, so it named link_watchdog skipped
        # on every fabric the heartbeat drives. Both halves: started (not named), not started
        # (named).
        import contextlib
        import io
        for topo, named in ((HeartbeatTopo(), False),
                            (HeartbeatTopo(raises=OSError("the report cannot be read")), True)):
            with self.subTest(named=named):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    summary, _ = run_startup(clients_bound(bound("ndtwin"), bound("ndtwin")),
                                             topo=topo, package=a_foreign_package(owner="ndtwin"))
                line = [x for x in out.getvalue().splitlines()
                        if "run the app package's own pipeline" in x]
                self.assertEqual(len(line), 1, out.getvalue())
                listed = line[0].split("Skipped: ", 1)[1].split(". ", 1)[0].split(", ")
                self.assertEqual(sorted(listed), sorted(summary["control_plane"]["skipped"]))
                self.assertEqual(main.SKIP_WATCHDOG in listed, named)

    def test_an_all_ndtwin_fabric_does_not_start_it(self):
        topo = HeartbeatTopo()
        run_startup({1: FakeClient(1), 2: FakeClient(2)}, topo=topo,
                    package=app_package.baseline())
        self.assertEqual(topo.heartbeat_calls, [])
        self.assertIn("watchdog", topo.started, "the LLDP watchdog runs there as before")
        self.assertIsNone(main.heartbeat_report())

    def test_an_external_fabric_on_ndtwins_own_pipeline_does_not_start_it(self):
        # [Co-developed with claude code -- Adam] Renamed 09-27 (was
        # test_an_external_fabric_does_not_start_it): the helper refuses NDTwin's own pipeline and
        # `ndt up` asks for no heartbeat there, so nothing is declared and nothing is watched.
        topo = HeartbeatTopo()
        run_startup({1: FakeClient(1)}, topo=topo, package=EXTERNAL)
        self.assertEqual(topo.heartbeat_calls, [])
        self.assertEqual(topo.seeded, [])
        self.assertIsNone(main.heartbeat_report())

    def test_a_topology_without_the_entry_does_not_stop_startup_and_says_so(self):
        summary, _ = run_startup(clients_bound(bound("ndtwin"), bound("ndtwin")),
                                 topo=SeedingTopo(), package=a_foreign_package(owner="ndtwin"))
        report = main.heartbeat_report()
        self.assertEqual(report["watchdog"], "not_started")
        self.assertIn("start_heartbeat_watchdog", report["error"])
        self.assertIs(summary["capabilities"]["1"]["reroute"], False)

    def test_an_entry_that_raises_does_not_stop_startup(self):
        topo = HeartbeatTopo(raises=OSError("no /run"))
        run_startup(clients_bound(bound("ndtwin"), bound("ndtwin")), topo=topo,
                    package=a_foreign_package(owner="ndtwin"))
        self.assertEqual(main.heartbeat_report()["error"], "OSError: no /run")
        self.assertEqual(main.reroute_report()["reason"], "heartbeat_watchdog_not_started")


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class RerouteNeedsTheHeartbeatAndEveryTableOwnedTest(unittest.TestCase):

    def setUp(self):
        SavedGlobals().save(self)

    def start(self, clients, package, reading=None):
        topo = HeartbeatTopo(reading=reading)
        summary, _ = run_startup(clients, topo=topo, package=package)
        return summary, topo

    def owned(self, reading=None):
        return self.start(clients_bound(bound("ndtwin"), bound("ndtwin")),
                          a_foreign_package(owner="ndtwin"), reading)

    def test_owned_and_usable_reroutes_and_discovers_by_heartbeat(self):
        summary, _ = self.owned()
        for dpid in ("1", "2"):
            caps = summary["capabilities"][dpid]
            self.assertEqual((caps["reroute"], caps["link_discovery"]), (True, "heartbeat"))
        self.assertEqual(main.reroute_report()["available"], True)
        self.assertIsNone(main.reroute_report()["reason"])

    def test_the_capabilities_keep_their_five_keys(self):
        summary, _ = self.owned()
        self.assertEqual(sorted(summary["capabilities"]["1"]),
                         ["binding_source", "five_tuple", "ipv4_route", "link_discovery",
                          "reroute"])

    def test_unbound_detects_by_heartbeat_and_does_not_reroute_and_says_why(self):
        summary, _ = self.start(clients_bound(None, None), a_foreign_package())
        caps = summary["capabilities"]["1"]
        self.assertEqual((caps["reroute"], caps["link_discovery"]), (False, "heartbeat"))
        self.assertEqual(main.reroute_report()["reason"], route_binding.REASON_UNBOUND)

    def test_one_unbound_switch_is_enough(self):
        self.start(clients_bound(bound("ndtwin"), None), a_foreign_package(owner="ndtwin"))
        self.assertEqual(main.reroute_report()["reason"], route_binding.REASON_UNBOUND)
        self.assertIs(main.capabilities_report()["1"]["reroute"], False)

    def test_a_package_owned_table_says_owned_by_package(self):
        self.start(clients_bound(bound("ndtwin"), bound("package")),
                   a_foreign_package(owner="ndtwin"))
        self.assertEqual(main.reroute_report()["reason"], route_binding.REASON_OWNED_BY_PACKAGE)
        self.assertIs(main.capabilities_report()["2"]["reroute"], False)

    def test_owned_without_a_running_heartbeat_does_not_reroute_and_is_declared(self):
        summary, _ = self.owned(a_reading(False, hb.REASON_NOT_RUNNING))
        caps = summary["capabilities"]["1"]
        self.assertEqual((caps["reroute"], caps["link_discovery"]), (False, "declared"))
        self.assertEqual(main.reroute_report()["reason"], hb.REASON_NOT_RUNNING)

    def test_owned_with_a_period_mismatch_does_not_reroute(self):
        self.owned(a_reading(False, hb.REASON_PERIOD_MISMATCH))
        self.assertEqual(main.reroute_report()["reason"], hb.REASON_PERIOD_MISMATCH)
        self.assertIs(main.capabilities_report()["1"]["reroute"], False)

    def test_owned_without_the_watchdog_does_not_reroute(self):
        run_startup(clients_bound(bound("ndtwin"), bound("ndtwin")), topo=SeedingTopo(),
                    package=a_foreign_package(owner="ndtwin"))
        self.assertEqual(main.reroute_report()["reason"], "heartbeat_watchdog_not_started")
        self.assertEqual(main.capabilities_report()["1"]["link_discovery"], "declared")

    def test_the_answer_follows_the_heartbeat_after_startup(self):
        _summary, topo = self.owned()
        self.assertIs(main.capabilities_report()["1"]["reroute"], True)
        topo.evidence.reading = a_reading(False, hb.REASON_STALE)
        self.assertEqual((main.capabilities_report()["1"]["reroute"],
                          main.capabilities_report()["1"]["link_discovery"],
                          main.reroute_report()["reason"]), (False, "declared", hb.REASON_STALE))

    def test_an_all_ndtwin_fabric_is_what_it_was(self):
        summary, _ = self.start({1: FakeClient(1), 2: FakeClient(2)}, app_package.baseline())
        self.assertEqual((summary["capabilities"]["1"]["reroute"],
                          summary["capabilities"]["1"]["link_discovery"]), (True, "lldp"))
        self.assertEqual(main.reroute_report(), {"available": True, "reason": None,
                                                 "detail": main.reroute_report()["detail"]})

    def test_an_external_fabric_says_external_control_plane(self):
        self.start({1: FakeClient(1)}, EXTERNAL)
        self.assertEqual(main.reroute_report()["reason"], "external_control_plane")
        self.assertEqual(main.capabilities_report()["1"]["link_discovery"], "none")


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class AnExternalControlPlaneOnItsOwnPipelineDetectsOnlyTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam] 09-27: an external control plane on its own pipeline
    (live-p1/06's p4runtime x2 and flowcache/solution) runs the heartbeat watchdog DETECT ONLY.
    Adam's standing condition (09-25) is that the heartbeat must not change what a user's own
    forwarding does, so what is asserted here is first what does NOT happen: no client is asked
    to write, the route writer is left skipping, and `reroute` stays false with the reason
    `external_control_plane` even when every table is bound to NDTwin and the heartbeat is usable.
    """

    def setUp(self):
        SavedGlobals().save(self)

    def start(self, clients=None, reading=None):
        clients = clients if clients is not None else {1: FakeClient(1), 2: FakeClient(2)}
        topo = HeartbeatTopo(reading=reading)
        summary, _ = run_startup(clients, topo=topo, package=EXTERNAL_FOREIGN)
        return summary, topo, clients

    def test_it_declares_its_links_and_starts_the_heartbeat_watchdog(self):
        summary, topo, _ = self.start()
        self.assertEqual(len(topo.seeded), 1, "the package's cables were not declared")
        self.assertEqual(topo.heartbeat_calls,
                         [(main.HEARTBEAT_REPORT_PATH, main.HEARTBEAT_REPORT_UID)])
        self.assertEqual(main.heartbeat_report()["watchdog"], "running")
        self.assertEqual(main.declared_links_report(), {"directions": 8, "error": None})
        self.assertEqual(summary["control_plane"]["mode"], "external")

    def test_the_route_writer_is_left_skipping_so_a_cut_rewrites_nothing(self):
        # The one flag the watchdog pass reads to choose "report and do not reroute"
        # (TopologyManager.run_watchdog_pass); startup sets it from control_plane.skipped.
        summary, topo, _ = self.start()
        self.assertIs(topo.routes_to_attached_hosts_only, True)
        self.assertIn(main.SKIP_ROUTES, summary["control_plane"]["skipped"])
        self.assertEqual(topo.installs, 0)

    def test_no_client_is_asked_to_write_anything(self):
        _summary, _topo, clients = self.start()
        for dpid, client in clients.items():
            self.assertEqual([e for e in client.events if e in WRITE_EVENTS], [],
                             f"switch {dpid} was written on an external control plane")

    def test_reroute_is_false_for_the_external_reason_even_when_the_heartbeat_is_usable(self):
        self.start()
        answer = main.reroute_report()
        self.assertEqual((answer["available"], answer["reason"]),
                         (False, "external_control_plane"))
        self.assertIn("detected by the heartbeat", answer["detail"])
        caps = main.capabilities_report()
        for dpid in ("1", "2"):
            self.assertEqual((caps[dpid]["reroute"], caps[dpid]["link_discovery"]),
                             (False, "heartbeat"))

    def test_even_with_every_table_bound_to_ndtwin_it_does_not_reroute(self):
        # The case in which, without `external` asked first, _fabric_reroute would answer True:
        # usable heartbeat and no route table blocked.
        self.start(clients_bound(bound("ndtwin"), bound("ndtwin")))
        self.assertEqual(main.reroute_report()["reason"], "external_control_plane")
        self.assertIs(main.capabilities_report()["1"]["reroute"], False)

    def test_an_unusable_heartbeat_is_declared_and_still_external(self):
        summary, _topo, _ = self.start(reading=a_reading(False, hb.REASON_NOT_RUNNING))
        self.assertEqual(summary["capabilities"]["1"]["link_discovery"], "declared")
        self.assertEqual(main.reroute_report()["reason"], "external_control_plane")
        self.assertIn("not detected either", main.reroute_report()["detail"],
                      "the detail must follow the report, not the watchdog's start")
        self.assertEqual(main.heartbeat_report()["state"], hb.REASON_NOT_RUNNING)

    def test_link_watchdog_leaves_the_list_while_the_heartbeat_drives_it(self):
        # Adam's ruling E, on this fabric too: every other EXTERNAL_SKIPS step stays named.
        summary, _topo, _ = self.start()
        self.assertEqual(sorted(summary["control_plane"]["skipped"]),
                         sorted(set(main.EXTERNAL_SKIPS) - {main.SKIP_WATCHDOG}))

    def test_a_heartbeat_watchdog_that_did_not_start_names_all_six(self):
        topo = HeartbeatTopo(raises=OSError("the report cannot be read"))
        summary, _ = run_startup({1: FakeClient(1)}, topo=topo, package=EXTERNAL_FOREIGN)
        self.assertEqual(sorted(summary["control_plane"]["skipped"]), sorted(main.EXTERNAL_SKIPS))
        self.assertEqual(main.reroute_report()["reason"], "external_control_plane")
        self.assertEqual(main.heartbeat_report()["watchdog"], "not_started")

    def test_the_startup_log_names_the_skipped_list_switch_state_serves(self):
        # The external line's Skipped list, printed after the heartbeat decision (as the foreign
        # line's is): no link_watchdog while the heartbeat drives the watchdog, and named when the
        # heartbeat watchdog did not start.
        import contextlib
        import io
        for topo, named in ((HeartbeatTopo(), False),
                            (HeartbeatTopo(raises=OSError("the report cannot be read")), True)):
            with self.subTest(named=named):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    summary, _ = run_startup({1: FakeClient(1)}, topo=topo,
                                             package=EXTERNAL_FOREIGN)
                line = [x for x in out.getvalue().splitlines()
                        if x.startswith("[Proxy Agent] external control plane, skipped: ")]
                self.assertEqual(len(line), 1, out.getvalue())
                listed = line[0].split("skipped: ", 1)[1].split(". ", 1)[0].split(", ")
                self.assertEqual(sorted(listed), sorted(summary["control_plane"]["skipped"]))
                self.assertEqual(main.SKIP_WATCHDOG in listed, named)

    def test_the_prediction_before_startup_says_declared(self):
        caps = main._capabilities_blank(EXTERNAL_FOREIGN, [1, 2])
        self.assertEqual((caps["1"]["reroute"], caps["1"]["link_discovery"]), (False, "declared"))
        caps = main._capabilities_blank(EXTERNAL, [1])
        self.assertEqual(caps["1"]["link_discovery"], "none")


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class AnExternalFabricsCutIsToldAndRewritesNothingTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam] 09-27, end to end in two halves: the flag startup
    leaves on an external control plane, handed to a REAL TopologyManager watching pod-topo's
    cables with a real report (tests/test_heartbeat_watchdog.py's Fabric), and one cut. The
    kernel must be told, and the route installer must not be reached.
    """

    def setUp(self):
        SavedGlobals().save(self)

    def test_the_cut_is_told_to_the_kernel_and_no_route_is_rewritten(self):
        from tests.test_heartbeat_watchdog import TIMEOUT, Fabric
        from tests.test_link_heartbeat import CUT, POD_DIRECTIONS

        topo = HeartbeatTopo()
        run_startup({1: FakeClient(1), 2: FakeClient(2)}, topo=topo, package=EXTERNAL_FOREIGN)
        f = Fabric(self, routes_skipped=topo.routes_to_attached_hosts_only)
        f.run()
        f.clock.now = f.last_heard[CUT[0]] + TIMEOUT + 0.1
        for d in POD_DIRECTIONS:
            if d not in CUT:
                f.last_heard[d] = f.clock.now - 0.2
        result = f.run()
        self.assertEqual(sorted(result["down"]), sorted(CUT))
        self.assertEqual(f.kernel.of("link_failure"), sorted(CUT), "the cut was not told")
        self.assertEqual(f.topo.installs, 0, "a route was rewritten on an external control plane")


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class AnExternalFabricReportsNoGuessedPathsTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam] Adam's ruling, 09-28: on an external control plane
    running its own pipeline the forwarding is the exercise's controller's and nothing installed
    is known to the proxy, so `/ryu_server/all_destination_paths` reports NO path -- "unknown",
    not a shortest path over the declared links (what it served from 09-27). The declared links
    still seed the graph: the heartbeat judges them. A REAL TopologyManager (pod-topo's cables,
    two hosts on different switches, so a shortest path exists to be withheld), with the flag
    startup leaves on it; the controls are the same manager with startup's flag from NDTwin's own
    pipeline and from a foreign fabric that is not external -- both still render the paths.
    """

    def setUp(self):
        SavedGlobals().save(self)
        saved = api_routes.topology
        self.addCleanup(lambda: setattr(api_routes, "topology", saved))

    def flag_after_startup(self, package):
        topo = HeartbeatTopo()
        run_startup({1: FakeClient(1), 2: FakeClient(2)}, topo=topo, package=package)
        return getattr(topo, "destination_paths_unknown", False)

    def fabric(self, paths_unknown):
        from tests.test_heartbeat_watchdog import Fabric
        f = Fabric(self, routes_skipped=True)
        f.topo.destination_paths_unknown = paths_unknown
        f.topo.add_host("10.0.1.1", "08:00:00:00:01:11", 1, 10)
        f.topo.add_host("10.0.2.2", "08:00:00:00:02:22", 2, 10)
        return f

    def served(self, f):
        api_routes.topology = f.topo
        return asyncio.run(api_routes.get_all_paths())

    def test_startup_marks_an_external_fabric_on_its_own_pipeline_only(self):
        self.assertIs(self.flag_after_startup(EXTERNAL_FOREIGN), True)
        self.assertIs(self.flag_after_startup(app_package.baseline()), False)
        self.assertIs(self.flag_after_startup(a_foreign_package()), False)
        self.assertIs(self.flag_after_startup(EXTERNAL), False)

    def test_the_declared_links_still_seed_the_graph(self):
        topo = HeartbeatTopo()
        run_startup({1: FakeClient(1), 2: FakeClient(2)}, topo=topo, package=EXTERNAL_FOREIGN)
        self.assertEqual(len(topo.seeded), 1, "the heartbeat has no links to judge")

    def test_an_external_fabric_serves_no_path_over_its_declared_links(self):
        f = self.fabric(self.flag_after_startup(EXTERNAL_FOREIGN))
        self.assertEqual(self.served(f), {"status": "success", "all_destination_paths": []})

    def test_the_same_graph_without_the_flag_does_have_a_path_to_withhold(self):
        # The control: the graph above is not empty of paths -- the flag is what withholds them.
        for package in (app_package.baseline(), a_foreign_package()):
            with self.subTest(package=package.name):
                body = self.served(self.fabric(self.flag_after_startup(package)))
                self.assertEqual(body["status"], "success")
                self.assertEqual(len(body["all_destination_paths"]), 2, body)

    def test_a_cut_on_an_external_fabric_pushes_no_path(self):
        from tests.test_heartbeat_watchdog import TIMEOUT
        from tests.test_link_heartbeat import CUT, POD_DIRECTIONS
        for unknown, pushed in ((True, 0), (False, 1)):
            with self.subTest(paths_unknown=unknown):
                f = self.fabric(unknown)
                f.run()
                f.clock.now = f.last_heard[CUT[0]] + TIMEOUT + 0.1
                for d in POD_DIRECTIONS:
                    if d not in CUT:
                        f.last_heard[d] = f.clock.now - 0.2
                f.run()
                self.assertEqual(f.kernel.of("link_failure"), sorted(CUT), "the cut was not told")
                self.assertEqual(sum(1 for c in f.kernel.calls if c[0] == "all_destination_paths"),
                                 pushed)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class TheHeartbeatIsDisclosedOnSwitchStateTest(unittest.TestCase):

    def setUp(self):
        SavedGlobals().save(self)

    def start(self, reading=None):
        topo = HeartbeatTopo(reading=reading)
        run_startup(clients_bound(bound("ndtwin"), bound("ndtwin")), topo=topo,
                    package=a_foreign_package(owner="ndtwin"))
        return topo

    def test_the_block_carries_the_live_counters_and_segment_s_census(self):
        self.start()
        report = main.heartbeat_report()
        self.assertEqual(report["watchdog"], "running")
        self.assertEqual(report["state"], "usable")
        self.assertEqual(report["side_effects"]["forwarded_to_hosts"], 0)
        self.assertIs(report["frames_reached_hosts"], False)
        census = report["census"]
        self.assertEqual((census["arms"], census["heartbeat_ran"], census["no_inter_switch_link"],
                          census["not_built"], census["arms_where_a_host_saw_a_frame"]),
                         (26, 20, 4, 2, 0))
        self.assertIn("2026-09-26T052148Z_S_heartbeat", census["raw"])
        self.assertEqual(report["frame"]["ethertype"], "0x88B5")

    def test_the_census_says_which_of_its_arms_ndt_up_starts_the_heartbeat_on(self):
        # [Co-developed with claude code -- Adam] The fable judge's 2.1 on 1a3ebd7f: the census's
        # 20 arms were started BY HAND (segment S), and the text says which of them `ndt up p4
        # --app` starts it on. 17 until 09-27; all 20 since -- the 3 external control planes
        # (p4runtime x2, flowcache solution) detect only.
        self.start()
        census = main.heartbeat_report()["census"]
        text = census["summary"]
        self.assertIn("by hand", text)
        self.assertIn("external control plane", text)
        self.assertIn("EXPECTED to start it on all 20 too", text)
        self.assertIn("not yet measured under ndt", text)
        # [Co-developed with claude code -- Adam] Adam's 09-28 ruling: on an external control plane
        # only after the offline drop check proves the program drops the frame.
        self.assertIn("only after ndt's offline drop check proves the program drops the frame", text)
        self.assertIn("detect only", text)
        self.assertNotIn("17", text)
        self.assertIn("ndt up", text)

    def test_the_census_names_the_punt_blind_spot_on_external_control_planes(self):
        # [Co-developed with claude code -- Adam] The external judge's F3 (09-28): a heartbeat frame
        # an external program punts to its own controller is invisible to the proxy and the daemon;
        # served beside the census, with the P4-level reason the 3 programs' source drops it (read
        # from the source, not measured with the programs loaded -- S1, round 2).
        self.start()
        text = main.heartbeat_report()["census"]["summary"]
        self.assertIn("punts to ITS OWN controller", text)
        self.assertIn("Any other external program is checked the same way before the heartbeat "
                      "starts on it; what its controller installs later is not covered", text)
        self.assertIn("the drop check agrees on a throwaway bmv2", text)
        self.assertIn("flowcache drops every non-IPv4 frame at ingress", text)
        # [Co-developed with claude code -- Adam] The external judge's S1 (09-28): a reading of the
        # P4 source, not a measurement -- segment S ran these arms with no controller.
        self.assertIn("The P4 SOURCE of these 3 programs drops it", text)
        self.assertIn("is the first measurement with these programs loaded", text)
        self.assertIn("inferred from bmv2", text)

    def test_the_watchdogs_passes_are_served(self):
        topo = self.start()
        topo.passes = [{"start_mono": 10.0, "end_mono": 10.01, "down": 0, "up": 0}]
        self.assertEqual(main.heartbeat_report()["watchdog_passes"], topo.passes)

    def test_a_frame_that_reached_a_host_is_named(self):
        self.start(a_reading(side_effects={"foreign_frames": 0, "forwarded_between_switches": 0,
                                           "forwarded_to_hosts": 1, "misdelivered": 0}))
        self.assertIs(main.heartbeat_report()["frames_reached_hosts"], True)

    def test_a_stopped_heartbeat_is_reported_as_what_it_is(self):
        self.start(a_reading(False, hb.REASON_NOT_RUNNING, detail="status 'stopped'"))
        report = main.heartbeat_report()
        self.assertEqual((report["state"], report["detail"]),
                         (hb.REASON_NOT_RUNNING, "status 'stopped'"))

    def test_both_blocks_reach_the_endpoint_at_the_top_level(self):
        self.start()

        class FakeTopology:
            def switch_liveness(self):
                return {"status": "success", "switches": {"1": {}}}

        saved = (api_routes.topology, api_routes.heartbeat_report, api_routes.reroute_report)
        self.addCleanup(lambda: setattr(api_routes, "topology", saved[0]))
        self.addCleanup(lambda: api_routes.inject_heartbeat_reports(saved[2], saved[1]))
        api_routes.topology = FakeTopology()
        api_routes.inject_heartbeat_reports(main.reroute_report, main.heartbeat_report)
        body = asyncio.run(api_routes.switch_state())
        self.assertEqual(body["reroute"]["available"], True)
        self.assertEqual(body["heartbeat"]["state"], "usable")
        self.assertNotIn("heartbeat", body["switches"]["1"])

    def test_an_uninjected_reporter_adds_no_key(self):
        class FakeTopology:
            def switch_liveness(self):
                return {"status": "success", "switches": {}}

        saved = (api_routes.topology, api_routes.heartbeat_report, api_routes.reroute_report)
        self.addCleanup(lambda: setattr(api_routes, "topology", saved[0]))
        self.addCleanup(lambda: api_routes.inject_heartbeat_reports(saved[2], saved[1]))
        api_routes.topology = FakeTopology()
        api_routes.inject_heartbeat_reports(None, None)
        body = asyncio.run(api_routes.switch_state())
        self.assertNotIn("heartbeat", body)
        self.assertNotIn("reroute", body)

    def test_main_injects_both(self):
        self.assertIs(api_routes.heartbeat_report, main.heartbeat_report)
        self.assertIs(api_routes.reroute_report, main.reroute_report)


if __name__ == "__main__":
    unittest.main(verbosity=2)
