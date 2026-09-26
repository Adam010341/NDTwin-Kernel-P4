"""
Which fabric gets the heartbeat watchdog, what `reroute` then says, and what switch_state discloses.

[Co-developed with claude code -- Adam]

TICKET-P4-heartbeat segment W, section 1:

  * the watchdog on a foreign fabric is fed by the heartbeat, and ONLY there -- NDTwin's own
    pipeline keeps LLDP (段 W: "NDTwin 自己的 pipeline（LLDP）不啟動心跳"), and an external
    control plane is left exactly as it was (it reads only; the first cut's 2.2-4);
  * the LLDP beacon watchdog stays off on a foreign fabric and stays named in
    `control_plane.skipped` -- it rides a controller header those programs do not have
    (TICKET-P4-roles M-R10). The heartbeat watchdog is a different evidence source through the
    same pass, and it is disclosed on its own;
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
if HAVE_PROXY:
    EXTERNAL = app_package.Package(dir="/packages/p4runtime", name="p4runtime", mode="external",
                                   election_id=(0, 65535))


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

    def test_the_lldp_watchdog_stays_off_and_stays_named_skipped(self):
        topo = HeartbeatTopo()
        summary, _ = run_startup(clients_bound(bound("ndtwin"), bound("ndtwin")), topo=topo,
                                 package=a_foreign_package(owner="ndtwin"))
        self.assertNotIn("lldp", topo.started)
        self.assertNotIn("watchdog", topo.started)
        self.assertIn(main.SKIP_LLDP, summary["control_plane"]["skipped"])
        self.assertIn(main.SKIP_WATCHDOG, summary["control_plane"]["skipped"])

    def test_an_all_ndtwin_fabric_does_not_start_it(self):
        topo = HeartbeatTopo()
        run_startup({1: FakeClient(1), 2: FakeClient(2)}, topo=topo,
                    package=app_package.baseline())
        self.assertEqual(topo.heartbeat_calls, [])
        self.assertIn("watchdog", topo.started, "the LLDP watchdog runs there as before")
        self.assertIsNone(main.heartbeat_report())

    def test_an_external_fabric_does_not_start_it(self):
        topo = HeartbeatTopo()
        run_startup({1: FakeClient(1)}, topo=topo, package=EXTERNAL)
        self.assertEqual(topo.heartbeat_calls, [])
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
