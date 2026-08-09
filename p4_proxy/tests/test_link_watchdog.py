"""
Tests for LLDP beacon-timeout link failure detection.

[Co-developed with claude code -- Adam]

Beacons arriving is how a link is discovered; beacons *stopping* is how a link failure is detected,
and only the first half was wired. `KernelNotifier.link_failure` existed, worked, was unit-tested,
and nothing called it -- so a link that went down stayed up in the twin for the rest of the run
while Ryu's side has reported it all along.

The behaviour asserted here comes from what the kernel does with the report
(HttpSession::handleLinkFailure sets the edge down in both directions and emits a
LinkFailureDetected event) and from Phase 6 of doc/p4_bmv2_support_plan.md -- not from reading
check_link_beacons. The clock is injected for every test: a fifteen-second timeout tested by
waiting fifteen seconds is a test that gets deleted the first time someone is in a hurry.
"""

from __future__ import annotations

import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent.topology_manager import (  # noqa: E402
    LINK_BEACON_TIMEOUT_S,
    LINK_STARTUP_GRACE_S,
    LLDP_BEACON_INTERVAL_S,
    TopologyManager,
)


class FakeClock:
    """A monotonic clock that only moves when a test says so."""

    def __init__(self, start=1000.0):
        self.now = float(start)

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class RecordingKernel:
    """Records link reports. `accept` decides whether the kernel took them."""

    def __init__(self, accept=True):
        self.failures = []
        self.recoveries = []
        self.accept = accept
        #: Called with (kind, link) just before returning, so a test can inject a beacon that
        #: arrives while the report is in flight.
        self.on_report = None

    def link_failure(self, src_dpid, src_port, dst_dpid, dst_port):
        self.failures.append((src_dpid, src_port, dst_dpid, dst_port))
        if self.on_report:
            self.on_report("failure", (src_dpid, src_port, dst_dpid, dst_port))
        return self.accept

    def link_recovery(self, src_dpid, src_port, dst_dpid, dst_port):
        self.recoveries.append((src_dpid, src_port, dst_dpid, dst_port))
        if self.on_report:
            self.on_report("recovery", (src_dpid, src_port, dst_dpid, dst_port))
        return self.accept


class WatchdogTestBase(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.kernel = RecordingKernel()
        self.topo = TopologyManager(kernel_notifier=self.kernel, clock=self.clock)

    def beacon(self, src_dpid, src_port, dst_dpid, dst_port):
        """Deliver one LLDP beacon from src_dpid:src_port, received on dst_dpid:dst_port."""
        payload = self.topo.create_lldp_packet(src_dpid, src_port)
        self.topo.handle_packet_in(dst_dpid, dst_port, payload)


class SilenceIsReportedTest(WatchdogTestBase):
    def test_a_fresh_link_is_not_reported(self):
        self.beacon(1, 1, 5, 1)
        self.clock.advance(LLDP_BEACON_INTERVAL_S)
        self.assertEqual(self.topo.check_link_beacons(), {"down": [], "up": [], "unacked": []})
        self.assertEqual(self.kernel.failures, [])

    def test_a_link_silent_past_the_timeout_is_reported_failed(self):
        self.beacon(1, 1, 5, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        result = self.topo.check_link_beacons()
        self.assertEqual(result["down"], [(1, 1, 5, 1)])
        self.assertEqual(self.kernel.failures, [(1, 1, 5, 1)])

    def test_the_report_carries_the_four_values_in_the_order_the_kernel_reads_them(self):
        # The kernel looks the edge up by (src_dpid, dst_dpid) and would 404 on a transposed pair;
        # the interfaces go into the log line and the event payload.
        self.beacon(3, 2, 9, 4)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.check_link_beacons()
        self.assertEqual(self.kernel.failures, [(3, 2, 9, 4)])

    def test_a_failure_is_reported_once_not_on_every_pass(self):
        # Each report makes the kernel tear the edge down, drop it from BFS and recompute paths.
        self.beacon(1, 1, 5, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        for _ in range(4):
            self.topo.check_link_beacons()
            self.clock.advance(LLDP_BEACON_INTERVAL_S)
        self.assertEqual(len(self.kernel.failures), 1)

    def test_exactly_at_the_timeout_is_not_yet_a_failure(self):
        # Strictly greater, so the boundary is silence *longer* than the allowance.
        self.beacon(1, 1, 5, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S)
        self.assertEqual(self.topo.check_link_beacons()["down"], [])

    def test_one_missed_beacon_is_not_a_failure(self):
        # The timeout leaves room for two consecutive misses; a link reported down every time a scan
        # landed just before a beacon would flap.
        self.beacon(1, 1, 5, 1)
        self.clock.advance(2 * LLDP_BEACON_INTERVAL_S)
        self.assertEqual(self.topo.check_link_beacons()["down"], [])

    def test_a_link_never_seen_is_not_reported_at_all(self):
        # The twin cannot tell "this link broke" from "this link was already broken when I started",
        # and reporting the second as the first would be inventing evidence.
        self.clock.advance(10 * LINK_BEACON_TIMEOUT_S)
        self.assertEqual(self.topo.check_link_beacons()["down"], [])
        self.assertEqual(self.kernel.failures, [])

    def test_each_direction_is_tracked_independently(self):
        # A one-way failure is a real thing, and the kernel decides what to do about it.
        self.beacon(1, 1, 5, 1)
        self.beacon(5, 1, 1, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.beacon(5, 1, 1, 1)  # only this direction is still alive
        self.assertEqual(self.topo.check_link_beacons()["down"], [(1, 1, 5, 1)])

    def test_a_beacon_from_the_switch_that_received_it_is_not_a_link(self):
        self.beacon(4, 2, 4, 2)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.assertEqual(self.topo.check_link_beacons()["down"], [])


class RecoveryTest(WatchdogTestBase):
    def _fail_then_return(self):
        self.beacon(1, 1, 5, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.check_link_beacons()
        self.beacon(1, 1, 5, 1)

    def test_a_link_whose_beacons_return_is_reported_recovered(self):
        self._fail_then_return()
        result = self.topo.check_link_beacons()
        self.assertEqual(result["up"], [(1, 1, 5, 1)])
        self.assertEqual(self.kernel.recoveries, [(1, 1, 5, 1)])

    def test_recovery_is_reported_once(self):
        self._fail_then_return()
        for _ in range(3):
            self.topo.check_link_beacons()
            self.clock.advance(LLDP_BEACON_INTERVAL_S)
            self.beacon(1, 1, 5, 1)
        self.assertEqual(len(self.kernel.recoveries), 1)

    def test_a_link_that_never_failed_is_never_reported_recovered(self):
        # inform_switch_entered already enabled every edge touching the switch, so up is the
        # kernel's starting assumption and telling it again is noise it acts on.
        for _ in range(3):
            self.beacon(1, 1, 5, 1)
            self.clock.advance(LLDP_BEACON_INTERVAL_S)
            self.topo.check_link_beacons()
        self.assertEqual(self.kernel.recoveries, [])

    def test_a_link_can_fail_and_recover_more_than_once(self):
        for expected in range(1, 4):
            self.beacon(1, 1, 5, 1)
            self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
            self.topo.check_link_beacons()
            self.beacon(1, 1, 5, 1)
            self.topo.check_link_beacons()
            self.assertEqual(len(self.kernel.failures), expected)
            self.assertEqual(len(self.kernel.recoveries), expected)


class ReportsAreRetriedTest(WatchdogTestBase):
    def test_a_report_the_kernel_did_not_accept_is_retried(self):
        # A kernel that is restarting must not cost us the notification permanently: the symptom --
        # a failed link shown as up for the rest of the run -- is the bug this feature fixes.
        self.kernel.accept = False
        self.beacon(1, 1, 5, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        first = self.topo.check_link_beacons()
        self.assertEqual(first["unacked"], [(1, 1, 5, 1)])
        self.assertEqual(first["down"], [])

        self.kernel.accept = True
        second = self.topo.check_link_beacons()
        self.assertEqual(second["down"], [(1, 1, 5, 1)])
        self.assertEqual(len(self.kernel.failures), 2, "the failed report was not retried")

    def test_an_accepted_report_is_not_retried(self):
        self.beacon(1, 1, 5, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.check_link_beacons()
        self.topo.check_link_beacons()
        self.assertEqual(len(self.kernel.failures), 1)

    def test_a_beacon_arriving_while_the_report_is_in_flight_is_not_acknowledged_away(self):
        # The pass drops the lock before the HTTP call, so the link can come back mid-report. If the
        # in-flight belief were acknowledged anyway, the kernel would be left holding "down" with
        # nothing remaining to correct it -- a permanently dark edge on a working link.
        self.beacon(1, 1, 5, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.kernel.on_report = lambda kind, link: self.beacon(1, 1, 5, 1)
        self.topo.check_link_beacons()
        self.kernel.on_report = None

        result = self.topo.check_link_beacons()
        self.assertEqual(result["up"], [(1, 1, 5, 1)],
                         "the link came back during the failure report and was never corrected")
        self.assertEqual(self.kernel.recoveries, [(1, 1, 5, 1)])

    def test_a_notifier_that_raises_does_not_end_the_pass(self):
        class Exploding(RecordingKernel):
            def link_failure(self, *args):
                raise RuntimeError("kernel notifier broke its promise not to raise")

        topo = TopologyManager(kernel_notifier=Exploding(), clock=self.clock)
        payload = topo.create_lldp_packet(1, 1)
        topo.handle_packet_in(5, 1, payload)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.assertEqual(topo.check_link_beacons()["unacked"], [(1, 1, 5, 1)])


class NoNotifierTest(unittest.TestCase):
    def test_transitions_are_still_tracked_without_a_kernel_to_tell(self):
        clock = FakeClock()
        topo = TopologyManager(clock=clock)
        topo.handle_packet_in(5, 1, topo.create_lldp_packet(1, 1))
        clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.assertEqual(topo.check_link_beacons()["down"], [(1, 1, 5, 1)])

    def test_bookkeeping_only_mode_does_not_accumulate_an_unacked_backlog(self):
        clock = FakeClock()
        topo = TopologyManager(clock=clock)
        topo.handle_packet_in(5, 1, topo.create_lldp_packet(1, 1))
        clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        topo.check_link_beacons()
        self.assertEqual(topo.check_link_beacons()["down"], [],
                         "with no kernel to tell, the transition must not be re-reported forever")


class SeededLinksTest(WatchdogTestBase):
    """
    Seeding is what makes a link that was *already* down at startup reportable. It is off by
    default because it assumes the topology file's interface numbers are the numbers bmv2 uses,
    and the receiving half of that assumption is unverified against a live P4 stack.
    """

    def test_seeding_enters_the_links_the_topology_file_declares(self):
        seeded = self.topo.seed_expected_links()
        self.assertGreater(seeded, 0, "the topology file declared no inter-switch links")
        self.assertEqual(len(self.topo.link_liveness()), seeded)

    def test_a_seeded_link_is_not_reported_before_the_startup_grace_expires(self):
        # A link that has never spoken may just be waiting for the far switch's pipeline.
        self.topo.seed_expected_links()
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.assertEqual(self.topo.check_link_beacons()["down"], [])

    def test_a_seeded_link_that_never_speaks_is_eventually_reported(self):
        self.topo.seed_expected_links()
        self.clock.advance(LINK_STARTUP_GRACE_S + 1)
        self.assertGreater(len(self.topo.check_link_beacons()["down"]), 0)

    def test_a_seeded_link_that_speaks_graduates_to_the_steady_state_timeout(self):
        # Without this the grace period would apply for the whole run and a real failure on that
        # link would take LINK_STARTUP_GRACE_S to notice.
        self.topo.seed_expected_links()
        link = sorted(self.topo._link_beacons)[0]
        src_dpid, src_port, dst_dpid, dst_port = link
        self.beacon(src_dpid, src_port, dst_dpid, dst_port)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.assertIn(link, self.topo.check_link_beacons()["down"])

    def test_seeding_does_not_overwrite_a_link_that_has_already_spoken(self):
        self.beacon(1, 1, 5, 1)
        self.topo.seed_expected_links()
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.assertIn((1, 1, 5, 1), self.topo.check_link_beacons()["down"])

    def test_the_watchdog_does_not_seed_unless_asked(self):
        self.topo.start_link_watchdog()
        self.addCleanup(self.topo.stop_link_watchdog)
        self.assertEqual(self.topo.link_liveness(), {})


class LinkLivenessReportTest(WatchdogTestBase):
    def test_it_reports_the_age_the_down_state_and_whether_the_kernel_knows(self):
        self.beacon(1, 1, 5, 1)
        self.clock.advance(4.0)
        entry = self.topo.link_liveness()["1:1->5:1"]
        self.assertEqual(entry, {"last_beacon_age_s": 4.0, "down": False,
                                 "reported_to_kernel": True})

    def test_a_seeded_link_that_has_never_spoken_has_no_age(self):
        # None rather than a very large number: "never" has to be representable as something other
        # than "very old", which is the same reason switch_liveness reports ages.
        self.topo.seed_expected_links()
        ages = {e["last_beacon_age_s"] for e in self.topo.link_liveness().values()}
        self.assertEqual(ages, {None})

    def test_it_appears_in_the_switch_state_payload_the_kernel_polls(self):
        self.beacon(1, 1, 5, 1)
        self.assertIn("1:1->5:1", self.topo.switch_liveness()["links"])
        # Additive only: the kernel looks up "switches" by name and must keep finding it.
        self.assertIn("switches", self.topo.switch_liveness())


class ThreadLifecycleTest(unittest.TestCase):
    """
    The LLDP beacon thread had no stop flag and its handle was assigned to a discarded local, so
    main.py's shutdown tore down every P4RuntimeClient underneath a loop still calling
    send_packet_out on them. Found by the p4-proxy commit review (H3).
    """

    def setUp(self):
        self.topo = TopologyManager()

    def test_the_beacon_thread_can_be_stopped(self):
        self.topo.start_lldp_discovery()
        thread = self.topo._lldp_thread
        self.assertTrue(thread.is_alive())
        self.topo.stop_lldp_discovery()
        self.assertFalse(thread.is_alive(), "the beacon thread outlived stop_lldp_discovery")

    def test_stopping_waits_rather_than_only_setting_a_flag(self):
        # A flag alone leaves the thread inside its sleep while shutdown continues to tear down the
        # clients it is about to use.
        self.topo.start_lldp_discovery()
        self.topo.stop_lldp_discovery()
        self.assertNotIn("lldp-beacon", [t.name for t in threading.enumerate()])

    def test_starting_twice_does_not_leave_two_beacon_threads(self):
        self.topo.start_lldp_discovery()
        self.addCleanup(self.topo.stop_lldp_discovery)
        first = self.topo._lldp_thread
        self.topo.start_lldp_discovery()
        self.assertIs(self.topo._lldp_thread, first)
        self.assertEqual(len([t for t in threading.enumerate() if t.name == "lldp-beacon"]), 1)

    def test_the_watchdog_thread_can_be_stopped(self):
        self.topo.start_link_watchdog()
        thread = self.topo._link_watchdog_thread
        self.assertTrue(thread.is_alive())
        self.topo.stop_link_watchdog()
        self.assertFalse(thread.is_alive())

    def test_the_liveness_thread_can_be_stopped(self):
        self.topo.start_liveness_polling()
        thread = self.topo._liveness_thread
        self.topo.stop_liveness_polling()
        self.assertFalse(thread.is_alive(), "stop_liveness_polling returned before the thread ended")

    def test_stopping_a_loop_that_was_never_started_does_not_raise(self):
        self.topo.stop_lldp_discovery()
        self.topo.stop_link_watchdog()
        self.topo.stop_liveness_polling()


if __name__ == "__main__":
    unittest.main()
