"""
Tests for LLDP beacon-timeout link failure detection.

[Co-developed with claude code -- Adam]

Beacons arriving is how a link is discovered; beacons *stopping* is how a link failure is detected,
and only the first half was wired. `KernelNotifier.link_failure` existed, worked, was unit-tested,
and nothing called it -- so a link that went down stayed up in the twin for the rest of the run
while Ryu's side has reported it all along.

The behaviour asserted here comes from what the kernel does with the report
(HttpSession::handleLinkFailure sets the edge down in both directions and emits a
LinkFailureDetected event) and from Phase 6 of doc/2026-07-27_p4_bmv2_support_plan.md -- not from reading
check_link_beacons. The clock is injected for every test: a fifteen-second timeout tested by
waiting fifteen seconds is a test that gets deleted the first time someone is in a hurry.
"""

from __future__ import annotations

import os
import sys
import threading
import unittest

import networkx as nx

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent import ryu_topology  # noqa: E402
from proxy_agent.ryu_topology import render_links  # noqa: E402
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

    def test_a_beacon_arriving_during_the_failure_report_still_produces_a_recovery(self):
        # What this proves: a beacon that lands while the failure POST is in flight is not lost --
        # the next pass sees the fresh timestamp and reports the recovery.
        #
        # What it does NOT prove, despite its original name: the compare-and-set in the ack step.
        # A mutation removing that comparison survived this test, and the mutation was right --
        # a beacon only refreshes `at`, so the belief cannot change mid-report and the guard is
        # unreachable today. Recorded here rather than deleted: the two causes of a surviving
        # mutation are "the test is weak" and "the target cannot be hit", and conflating them is
        # how a good test gets deleted or a false one kept.
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
    Seeding is what makes a link that was *already* down at startup reportable. main.py enables it;
    the parameter defaults to False so it is never acquired by accident. Its one assumption -- that
    the topology file's interface numbers are the numbers bmv2 uses -- was verified live on
    2026-08-10, statically 32/32 and on the wire 16/16.
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

    def test_seeding_nothing_is_announced_as_a_failure_not_as_a_count_of_zero(self):
        # Seeding is the only route by which a link that was down before we started is ever
        # watched. If the topology file yields none, that capability is off again -- at the exact
        # moment an operator has asked for it. "seeded with 0 declared links" reads like a
        # successful startup; it has to read like the loss it is.
        import contextlib
        import io
        import json
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"nodes": [], "edges": []}, fh)
            empty_topo = fh.name
        self.addCleanup(os.unlink, empty_topo)

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.topo.start_link_watchdog(seed_expected=True, path=empty_topo)
        self.addCleanup(self.topo.stop_link_watchdog)

        printed = out.getvalue()
        self.assertIn("WARNING", printed)
        self.assertNotIn("seeded with 0 declared links", printed)


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


class TheTopologyReplyStopsMentioningFailedLinksTest(WatchdogTestBase):
    """
    Reporting a link failure is not sufficient on its own, and this is the test that says so.

    [Co-developed with claude code -- Adam]
    The kernel's `updateLinks` only ever sets isUp/isEnabled to **true** -- it has no path that sets
    either false -- and it polls once a second, keyed on (src dpid, src port). This side never
    forgets a link: `add_link` has no counterpart. So the watchdog would report a failure, the kernel
    would take the edge down, and the next poll would put it straight back up. The report was real
    and its effect lasted under a second.

    These tests fail against a `render_links` that lists every discovered link, which is what
    shipped before this was found.
    """

    def setUp(self):
        super().setUp()
        for dpid in (1, 5):
            self.topo.net.add_node(dpid, type="switch")

    def rendered(self):
        return render_links(self.topo.net, self.topo.down_link_endpoints())

    def endpoints(self):
        return {(e["src"]["dpid"], e["src"]["port_no"]) for e in self.rendered()}

    def test_a_discovered_link_is_reported(self):
        self.beacon(1, 1, 5, 2)
        self.assertIn(("0000000000000001", "00000001"), self.endpoints())

    def test_a_failed_link_is_not_reported(self):
        self.beacon(1, 1, 5, 2)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.check_link_beacons()
        self.assertEqual(self.endpoints(), set(),
                         "the kernel's next poll would re-enable the edge the watchdog just "
                         "reported as failed, because updateLinks cannot set isEnabled false")

    def test_a_recovered_link_is_reported_again(self):
        self.beacon(1, 1, 5, 2)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.check_link_beacons()
        self.beacon(1, 1, 5, 2)
        self.topo.check_link_beacons()
        self.assertIn(("0000000000000001", "00000001"), self.endpoints())

    def test_only_the_failed_direction_is_withheld(self):
        # A one-way failure is a real thing; withholding both would tell the kernel less than we know.
        self.beacon(1, 1, 5, 2)
        self.beacon(5, 2, 1, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.beacon(5, 2, 1, 1)
        self.topo.check_link_beacons()
        self.assertEqual(self.endpoints(), {("0000000000000005", "00000002")})

    def test_the_key_is_the_source_endpoint_the_kernel_enables_on(self):
        # add_link does not type its nodes, and render_links only walks switch-to-switch edges, so
        # these two have to be declared or the reply is empty for a reason unrelated to the filter.
        for dpid in (3, 9):
            self.topo.net.add_node(dpid, type="switch")
        self.beacon(3, 4, 9, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.check_link_beacons()
        # The healthy link is the control: without it, an empty reply would satisfy this test for
        # any reason at all, including render_links being broken outright.
        self.beacon(1, 1, 5, 2)
        # The beacon's own source endpoint is the one the kernel enables the edge under, so that is
        # the one that has to disappear from the *reply* -- not merely from down_link_endpoints,
        # which is an intermediate the kernel never sees.
        self.assertEqual(self.endpoints(), {("0000000000000001", "00000001"),
                                            ("0000000000000005", "00000002")})

    def test_a_link_that_is_up_is_never_withheld_by_an_unrelated_failure(self):
        for dpid in (2, 6):
            self.topo.net.add_node(dpid, type="switch")
        self.beacon(1, 1, 5, 2)
        self.beacon(2, 1, 6, 2)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.beacon(2, 1, 6, 2)
        self.topo.check_link_beacons()
        self.assertEqual(self.endpoints(), {("0000000000000002", "00000001"),
                                            ("0000000000000006", "00000002")})


class DownEndpointsCoverTheInferredReverseTest(WatchdogTestBase):
    """
    `down_link_endpoints`' own contract, asserted on the set rather than on the reply.

    [Co-developed with claude code -- Adam]
    These two used to sit in the class above, whose name promises something about the kernel-facing
    reply -- and a review was right that they proved nothing about it: they read an intermediate the
    kernel never sees, so a `render_links` that ignored the set entirely would leave them green.
    Splitting them out is the honest fix. The wiring is pinned by the class above, and measured:
    disabling the filter in `render_links` fails `test_a_failed_link_is_not_reported`,
    `test_only_the_failed_direction_is_withheld` and
    `test_a_link_that_is_up_is_never_withheld_by_an_unrelated_failure`.

    What is left here is worth keeping at this level because the reverse-inference rule is a
    property of this method, and at the reply level it is indistinguishable from the plain
    withholding already covered above.
    """

    def test_the_inferred_reverse_direction_of_a_dead_link_is_withheld_too(self):
        # add_link creates both directions from one beacon, so the reverse edge is usually an
        # inference. No beacon tuple exists for it, so it can never time out -- and if the far
        # switch is the one that died, its beacons never arrived anywhere to be missed. Left in,
        # half the edge stays lit on a wholly dead link.
        self.beacon(1, 1, 5, 2)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.check_link_beacons()
        self.assertEqual(self.topo.down_link_endpoints(), {(1, 1), (5, 2)})

    def test_a_reverse_direction_still_passing_beacons_is_kept(self):
        self.beacon(1, 1, 5, 2)
        self.beacon(5, 2, 1, 1)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.beacon(5, 2, 1, 1)
        self.topo.check_link_beacons()
        self.assertEqual(self.topo.down_link_endpoints(), {(1, 1)},
                         "a one-way failure must not withhold the direction that demonstrably works")


class PathsArePushedOnATransitionTest(WatchdogTestBase):
    """
    A link failure changes the paths, and nothing told the kernel that.

    [Co-developed with claude code -- Adam]
    `refreshDestinationPathsPeriodically` pulls every 60 s once it has paths, so
    `get_path_switch_count` answers from routes over the dead link for up to a minute after the
    failure is reported. These tests pin the push that closes that window, and -- more importantly --
    that the pushed snapshot does not itself traverse the link just reported as down.
    """

    def setUp(self):
        super().setUp()
        self.pushed = []
        self.kernel.all_destination_paths = self._record
        # h1 -- s1 =(p1/p2)= s5 -- h2, so every h1<->h2 path must cross the link under test.
        for dpid in (1, 5):
            self.topo.net.add_node(dpid, type="switch")
        self.topo.add_host("10.0.0.1", 1, 1, 3)
        self.topo.add_host("10.0.0.2", 2, 5, 4)
        self.topo.add_link(1, 5, 1, 2)

    def _record(self, paths):
        self.pushed.append(paths)
        # Mirrors KernelNotifier.all_destination_paths, which refuses an empty snapshot. A double
        # wider than the thing it stands in for is how the last one of these went wrong: a stub that
        # accepted a call the real class rejects made a broken test look green.
        return bool(paths)

    def fail_the_link(self):
        self.beacon(1, 1, 5, 2)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        return self.topo.check_link_beacons()

    def test_a_healthy_pass_pushes_nothing(self):
        self.beacon(1, 1, 5, 2)
        self.topo.run_watchdog_pass()
        self.assertEqual(self.pushed, [], "a pass with no transition has nothing to tell the kernel")

    def test_the_watchdog_pass_itself_pushes_on_a_failure(self):
        # Through run_watchdog_pass, not push_destination_paths: the wiring is the part that was
        # missing, and a mutation deleting the call from the loop survived every test that called
        # the push directly.
        self.beacon(1, 1, 5, 2)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.run_watchdog_pass()
        self.assertEqual(len(self.pushed), 1, "the failing pass must push a fresh path snapshot")

    def test_the_watchdog_pass_pushes_on_a_recovery_too(self):
        self.beacon(1, 1, 5, 2)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.run_watchdog_pass()
        self.pushed.clear()
        self.beacon(1, 1, 5, 2)
        self.topo.run_watchdog_pass()
        self.assertEqual(len(self.pushed), 1, "a link coming back changes the paths as much as one "
                                              "going down")

    def test_a_pass_whose_check_raises_reports_none_and_does_not_push(self):
        def boom(now=None):
            raise RuntimeError("beacon check exploded")

        self.topo.check_link_beacons = boom
        self.assertIsNone(self.topo.run_watchdog_pass())
        self.assertEqual(self.pushed, [])

    def test_the_push_carries_paths_before_any_failure(self):
        self.assertTrue(self.topo.push_destination_paths())
        self.assertEqual(len(self.pushed), 1)
        hops = self.pushed[0]
        self.assertTrue(hops, "h1 and h2 are connected, so there must be at least one path")

    def test_the_pushed_snapshot_reroutes_around_the_failed_link(self):
        # A detour has to exist for this to say anything: s1 =p3/p4= s9 =p5/p6= s5 is the long way
        # round. Without it the graph partitions and "no path over the dead link" is satisfied
        # trivially by there being no path at all.
        self.topo.net.add_node(9, type="switch")
        self.topo.add_link(1, 9, 3, 4)
        self.topo.add_link(9, 5, 5, 6)

        self.fail_the_link()
        self.assertTrue(self.topo.push_destination_paths(),
                        "the detour exists, so there is still something to tell the kernel")

        snapshot = self.pushed[-1]
        self.assertTrue(snapshot)
        for path in snapshot:
            # Each entry is [node, egress port towards the next hop], so s1 leaving by port 1 is
            # exactly "this path uses the link the watchdog reported down".
            self.assertNotIn([1, 1], path,
                             f"path {path} egresses s1 on the port whose link just failed")
        # And the detour really is being used, rather than h1<->h2 having quietly vanished.
        crossing = [p for p in snapshot
                    if [hop[0] for hop in p][:1] == ["10.0.0.1"] and p[-1][0] == "10.0.0.2"]
        self.assertTrue(crossing, "h1 -> h2 must still have a path, the long way round")
        self.assertIn(9, [hop[0] for hop in crossing[0]], "the detour switch must appear on it")

    def test_a_detour_is_not_advertised_unless_the_switches_were_told_about_it(self):
        """
        The 2026-08-10 defect, as a test.

        A mid-path link broke, the search found a way round it, and the proxy advertised that
        route while every switch went on forwarding into the dead link. Ping stopped; the twin
        reported all twelve paths and 38% of the packets were dropped. `install_initial_routes`
        has one caller, guarded by `if not edge_exists`, so nothing reprograms a switch when a
        link disappears -- which makes any recomputed detour fiction until failover exists.
        """
        self.topo.net.add_node(9, type="switch")
        self.topo.add_link(1, 9, 3, 4)
        self.topo.add_link(9, 5, 5, 6)
        # What the switches were actually told, back when the direct link was healthy.
        self.topo._installed_routes = {
            (1, "10.0.0.2"): 1,   # s1 -> s5 over the link that is about to fail
            (5, "10.0.0.2"): 4,   # s5 -> h2
            (5, "10.0.0.1"): 2,   # s5 -> s1
            (1, "10.0.0.1"): 3,   # s1 -> h1
        }

        self.fail_the_link()
        self.topo.push_destination_paths()

        for path in self.pushed[-1] if self.pushed else []:
            self.assertNotIn(9, [hop[0] for hop in path],
                             "s9 is only reachable by a route no switch has been programmed with")

    def test_a_total_partition_pushes_nothing_and_leaves_the_kernel_holding_stale_paths(self):
        # The failed link is the only one between h1 and h2, so there is no snapshot to send --
        # and setAllPaths refuses an empty one by design, so the kernel keeps the routes it has,
        # including the one over the dead link. Documented here because it is a real consequence
        # of that refusal, not an oversight: with 32 inter-switch edges in the shipped topology a
        # single failure never empties the snapshot, so the wholesale replace does the work.
        self.fail_the_link()
        self.assertFalse(self.topo.push_destination_paths())

    def test_pushing_an_empty_graph_reports_failure(self):
        # Nothing discovered yet, so there is nothing the kernel can act on. The refusal itself lives
        # in KernelNotifier.all_destination_paths and is asserted against the real class in
        # test_kernel_notifier.py; what this pins is that the empty result is propagated as a failure
        # rather than reported as a successful push.
        bare = TopologyManager(kernel_notifier=self.kernel, clock=self.clock)
        self.pushed.clear()
        self.assertFalse(bare.push_destination_paths())

    def test_a_push_that_raises_does_not_escape(self):
        def boom(paths):
            raise RuntimeError("kernel exploded")

        self.kernel.all_destination_paths = boom
        self.assertFalse(self.topo.push_destination_paths(),
                         "a raising push must be reported as a failure, not kill the watchdog")

    def test_no_notifier_means_no_push(self):
        bare = TopologyManager(clock=self.clock)
        self.assertFalse(bare.push_destination_paths())


class FailoverTest(WatchdogTestBase):
    """
    A link failure must move the traffic, not just be reported.

    [Co-developed with claude code -- Adam]
    Measured on 2026-08-10, before this existed: breaking a mid-path link stopped the ping dead
    and lost 38% of 40000 packets, because `install_initial_routes` was only ever called when a
    link was *discovered*. The two properties below are what "failover" means here -- the
    recomputation must avoid the failed link, and something must actually call it.
    """

    class RecordingClient:
        """Stands in for P4Client, recording the routes it is asked to install."""

        def __init__(self):
            self.routes = {}

        def insert_ipv4_route(self, dst_ip, prefix_len, next_hop_mac, port):
            self.routes[dst_ip] = port
            return True

    def setUp(self):
        super().setUp()
        # h1 -- s1 =p1/p2= s5 -- h2, with a longer way round through s9.
        for dpid in (1, 5, 9):
            self.topo.net.add_node(dpid, type="switch")
        self.topo.add_host("10.0.0.1", 1, 1, 3)
        self.topo.add_host("10.0.0.2", 2, 5, 4)
        self.topo.add_link(1, 5, 1, 2)
        self.topo.add_link(1, 9, 5, 6)
        self.topo.add_link(9, 5, 7, 8)
        self.clients = {dpid: self.RecordingClient() for dpid in (1, 5, 9)}
        self.topo.switches = self.clients

    def fail_the_direct_link(self):
        self.beacon(1, 1, 5, 2)
        self.beacon(1, 5, 9, 6)   # the detour keeps beaconing, so s1 is not "all inbound quiet"
        self.beacon(9, 7, 5, 8)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.beacon(1, 5, 9, 6)
        self.beacon(9, 7, 5, 8)

    def test_the_recomputed_route_avoids_the_failed_link(self):
        self.fail_the_direct_link()
        self.topo.check_link_beacons()
        self.topo.install_initial_routes()
        # s1 reaching h2 must now leave by port 5, the detour, not port 1.
        self.assertEqual(self.clients[1].routes.get("10.0.0.2"), 5)

    def test_the_watchdog_pass_reprograms_the_switches(self):
        # The wiring, not the computation: deleting the install call from the loop must fail here.
        self.fail_the_direct_link()
        self.topo.run_watchdog_pass()
        self.assertEqual(self.clients[1].routes.get("10.0.0.2"), 5)

    def test_a_pass_with_no_transition_does_not_reprogram(self):
        self.beacon(1, 1, 5, 2)
        self.topo.run_watchdog_pass()
        self.assertEqual(self.clients[1].routes, {})

    def test_a_destination_with_no_route_left_keeps_the_rule_it_has(self):
        # Adam's decision: leave the old rule so traffic resumes by itself on recovery, rather than
        # deleting it and needing a reinstall. Nothing may be written for that destination.
        topo = TopologyManager(kernel_notifier=self.kernel, clock=self.clock)
        for dpid in (1, 5):
            topo.net.add_node(dpid, type="switch")
        topo.add_host("10.0.0.1", 1, 1, 3)
        topo.add_host("10.0.0.2", 2, 5, 4)
        topo.add_link(1, 5, 1, 2)
        client = self.RecordingClient()
        topo.switches = {1: client, 5: self.RecordingClient()}
        payload = topo.create_lldp_packet(1, 1)
        topo.handle_packet_in(5, 2, payload)
        client.routes.clear()

        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        topo.check_link_beacons()
        topo.install_initial_routes()
        self.assertNotIn("10.0.0.2", client.routes,
                         "with the only link down there is no route to write, and the existing "
                         "rule must be left alone rather than replaced or deleted")


class SwitchLevelSilenceIsNotARerouteReasonTest(WatchdogTestBase):
    """
    One bmv2 interface going down stalls that switch's whole packet-in path, so every link into
    it falls silent at once and the watchdog reports them all. Measured: one real break produced
    five down directions, three of them healthy links. Rerouting on those three would pull traffic
    off working links and put it back on recovery.

    The two causes are distinguishable: a real single-link failure leaves the switch's other
    inbound links beaconing, while a stalled CPU path silences them together *and* the switch goes
    on answering P4Runtime.
    """

    def setUp(self):
        super().setUp()
        for dpid in (1, 5, 9):
            self.topo.net.add_node(dpid, type="switch")
        self.topo.add_link(5, 1, 1, 1)
        self.topo.add_link(9, 1, 2, 2)

    def probe(self, dpid, ok):
        with self.topo._liveness_lock:
            self.topo._last_probe[dpid] = {"ok": ok, "detail": "", "at": self.clock()}

    def silence_everything_into_s1(self):
        self.beacon(5, 1, 1, 1)
        self.beacon(9, 2, 1, 2)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.topo.check_link_beacons()

    def test_all_inbound_quiet_while_the_switch_answers_grpc_is_not_a_reroute_reason(self):
        self.probe(1, True)
        self.silence_everything_into_s1()
        self.assertEqual(self.topo.reroutable_down_endpoints(), set())

    def test_the_twin_still_reports_them_as_down(self):
        # Suppressing the *reroute* must not suppress the report: over-reporting is safe there,
        # and the kernel has always been told.
        self.probe(1, True)
        self.silence_everything_into_s1()
        self.assertTrue(self.topo.down_link_endpoints())

    def test_a_switch_that_stopped_answering_grpc_is_a_reroute_reason(self):
        # Then it really is gone, and routing around it is correct.
        self.probe(1, False)
        self.silence_everything_into_s1()
        self.assertTrue(self.topo.reroutable_down_endpoints())

    def test_the_genuinely_broken_link_is_still_a_reroute_reason_at_a_suspect_switch(self):
        """
        The switch that stalls is the switch whose interface was taken down, so the one real
        failure is always among the reports being forgiven. Forgiving it too keeps routing traffic
        into a physically dead link. A real break kills both directions; the stall silences only
        the inbound one.
        """
        # s1<->s5 is the link that physically broke: both directions go quiet.
        self.beacon(5, 1, 1, 1)
        self.beacon(1, 1, 5, 1)
        # s1<->s9 is healthy; only the inbound half falls silent, because s1 cannot deliver what
        # it receives while it can still send.
        self.beacon(9, 2, 1, 2)
        self.beacon(1, 2, 9, 2)
        self.probe(1, True)

        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.beacon(1, 2, 9, 2)   # s1 still sends on the healthy port
        self.topo.check_link_beacons()

        reroutable = self.topo.reroutable_down_endpoints()
        self.assertIn((5, 1), reroutable,
                      "both directions of s1<->s5 are down, so it is a real break and traffic "
                      "must stop being routed into it")
        self.assertNotIn((9, 2), reroutable,
                         "s9->s1 fell silent only because s1 stopped delivering to its CPU; the "
                         "link carries traffic perfectly well")

    def test_the_measured_incident_yields_exactly_the_two_real_directions(self):
        """
        The 2026-08-10 fault, replayed from the proxy log verbatim.

        `sudo ifconfig s5-eth4 down` produced five down reports:
            (1,1,5,1) (9,1,5,3) (2,1,5,2)   -- false, s5 stopped delivering to its CPU
            (5,4,10,1) (10,1,5,4)           -- real, both directions of the broken link
        Only the last two may drive a reroute.
        """
        alive_reverses = [(5, 1, 1, 1), (5, 3, 9, 1), (5, 2, 2, 1)]
        for link in [(1, 1, 5, 1), (9, 1, 5, 3), (2, 1, 5, 2),
                     (5, 4, 10, 1), (10, 1, 5, 4)] + alive_reverses:
            self.beacon(*link)
        self.probe(5, True)

        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        for link in alive_reverses:      # s5 can still send, just not receive
            self.beacon(*link)
        self.topo.check_link_beacons()

        self.assertEqual(self.topo.reroutable_down_endpoints(), {(5, 4), (10, 1)})

    def test_one_link_failing_while_the_others_beacon_is_a_reroute_reason(self):
        # The ordinary case, which must not be caught by the suppression.
        self.beacon(5, 1, 1, 1)
        self.beacon(9, 2, 1, 2)
        self.probe(1, True)
        self.clock.advance(LINK_BEACON_TIMEOUT_S + 1)
        self.beacon(9, 2, 1, 2)          # this one is still alive
        self.topo.check_link_beacons()
        self.assertEqual(self.topo.reroutable_down_endpoints(), {(5, 1)})


class ThePushComputesOverASnapshotTest(WatchdogTestBase):
    """
    The push reads the whole graph from the watchdog thread while the gRPC receive threads write it.

    [Co-developed with claude code -- Adam]
    `net` is append-only, so a reader cannot see a deletion -- but networkx walks the adjacency
    dicts directly, so an insertion partway through a traversal raises
    `RuntimeError: dictionary changed size during iteration`. That lands in the `except Exception`
    that keeps the watchdog thread alive, so the symptom is a push that silently does not happen,
    which is the exact window the push was added to close.

    These pin the mechanism rather than trying to race it: whether a real interleaving raises is a
    scheduling accident, but "the walk is handed a private copy" is decidable.
    """

    def setUp(self):
        super().setUp()
        self.pushed = []
        self.kernel.all_destination_paths = lambda paths: (self.pushed.append(paths), bool(paths))[1]
        for dpid in (1, 5):
            self.topo.net.add_node(dpid, type="switch")
        self.topo.add_host("10.0.0.1", 1, 1, 3)
        self.topo.add_host("10.0.0.2", 2, 5, 4)
        self.topo.add_link(1, 5, 1, 2)

    def test_the_walk_is_handed_a_copy_that_a_concurrent_writer_cannot_reach(self):
        seen = {}
        real = ryu_topology.render_destination_paths

        # Signature must track the real function: it now also receives the installed routes, and
        # a double narrower than what it stands for turns into a TypeError the caller reports as a
        # failed push -- the same trap as commit 990b0c1.
        def watching_render(net, down_endpoints=(), installed=None):
            seen["was_the_live_graph"] = net is self.topo.net
            # Stand in for the LLDP thread discovering a neighbour mid-walk.
            self.topo.add_link(1, 9, 7, 8)
            seen["writer_reached_the_live_graph"] = self.topo.net.has_edge(1, 9)
            seen["walk_saw_the_write"] = net.has_edge(1, 9)
            return real(net, down_endpoints, installed)

        ryu_topology.render_destination_paths = watching_render
        try:
            self.assertTrue(self.topo.push_destination_paths())
        finally:
            ryu_topology.render_destination_paths = real

        self.assertFalse(seen["was_the_live_graph"],
                         "the walk must not be handed the graph the LLDP threads write")
        self.assertTrue(seen["writer_reached_the_live_graph"],
                        "the stand-in writer must really have mutated the live graph, or this "
                        "test proves nothing about isolation")
        self.assertFalse(seen["walk_saw_the_write"],
                         "a write during the walk leaked into the graph being walked")

    def test_the_graph_lock_is_released_before_the_liveness_lock_is_taken(self):
        # Nesting the two would fix an ordering that nothing else in this class promises to keep,
        # and handle_packet_in takes _liveness_lock first on the very path that then calls add_link.
        free = {}
        real = self.topo.down_link_endpoints

        def probing_down_link_endpoints():
            # From another thread on purpose: _net_lock is re-entrant, so acquiring it from the
            # thread that already holds it would succeed and prove nothing.
            result = []

            def probe():
                got = self.topo._net_lock.acquire(blocking=False)
                if got:
                    self.topo._net_lock.release()
                result.append(got)

            t = threading.Thread(target=probe)
            t.start()
            t.join()
            free["net_lock_was_free"] = result[0]
            return real()

        self.topo.down_link_endpoints = probing_down_link_endpoints
        self.topo.push_destination_paths()
        self.assertTrue(free["net_lock_was_free"],
                        "the graph lock was still held while the liveness lock was being taken")


class ThePathSearchWalksASnapshotTest(WatchdogTestBase):
    """calculate_all_paths runs on a gRPC receive thread; the other switches' threads write."""

    def setUp(self):
        super().setUp()
        # h1 -- s1 == s5 -- h2. Nodes added directly: add_switch also wants a P4Client, and
        # nothing here talks to a switch.
        for dpid in (1, 5):
            self.topo.net.add_node(dpid, type="switch")
        self.topo.add_link(1, 5, 1, 1)
        self.topo.add_host("10.0.0.1", 1, 1, 3)
        self.topo.add_host("10.0.0.2", 2, 5, 3)

    def test_a_concurrent_add_during_the_search_does_not_raise(self):
        # The failure this reproduces: handle_packet_in on switch A calls install_initial_routes ->
        # calculate_all_paths, and switch B's receive thread calls add_link mid-walk. Iterating the
        # live NodeView while it grows raises RuntimeError("dictionary changed size during
        # iteration"), which _stream_receiver does not catch -- it only catches grpc.RpcError -- so
        # switch A's receive thread dies for the rest of the run.
        #
        # CATCHES: reverting calculate_all_paths to walk self.net directly.
        real = nx.shortest_path
        fired = {"n": 0}

        def writing_shortest_path(g, source, target):
            fired["n"] += 1
            if fired["n"] == 1:
                # Stand in for another switch's receive thread discovering a neighbour.
                self.topo.net.add_node(99, type="switch")
            return real(g, source, target)

        nx.shortest_path = writing_shortest_path
        try:
            self.topo.calculate_all_paths()
        finally:
            nx.shortest_path = real

        self.assertGreater(fired["n"], 0,
                           "the stand-in writer never ran, so this test proves nothing")
        self.assertTrue(self.topo.net.has_node(99),
                        "the writer must really have mutated the live graph")

    def test_the_search_does_not_see_a_write_that_lands_during_it(self):
        # Isolation, not just survival: a node added mid-walk must not appear in the graph being
        # walked, or two calls to the same function would disagree about the topology.
        #
        # CATCHES: taking the lock around the walk instead of copying (survives, but the walk
        # would then see nothing at all because the writer would block -- and any read of
        # self.net inside the loop would still see the write).
        seen = {}
        real = ryu_topology.down_edges

        def watching_down_edges(net, exclude_endpoints=()):
            seen["was_the_live_graph"] = net is self.topo.net
            self.topo.net.add_node(77, type="switch")
            seen["walk_saw_the_write"] = net.has_node(77)
            return real(net, exclude_endpoints)

        ryu_topology.down_edges = watching_down_edges
        try:
            self.topo.calculate_all_paths()
        finally:
            ryu_topology.down_edges = real

        self.assertFalse(seen["was_the_live_graph"],
                         "the search must not be handed the graph the receive threads write")
        self.assertTrue(self.topo.net.has_node(77),
                        "the stand-in writer must really have mutated the live graph")
        self.assertFalse(seen["walk_saw_the_write"],
                         "a write during the search leaked into the graph being searched")


class RestRouteChangesUpdateInstalledRoutesTest(WatchdogTestBase):
    """
    route_flow / unroute_flow / modify_flow all reach a switch through /stats/flowentry/*, the
    same door Traffic-Engineering and Energy-Saving use to reroute a flow by hand.

    [Co-developed with claude code -- Adam]
    _installed_routes had exactly one writer before this -- install_initial_routes -- so a REST
    caller\'s add/modify/delete never touched it. render_destination_paths reads this map to decide
    what the twin is allowed to claim (decision B); a rewrite through this door left it claiming
    the *old* hop, and a delete left it claiming a route to a destination with nothing on the wire
    for it at all. Both are the same lie decision B exists to prevent, re-entering through REST.
    """

    class RecordingClient:
        """Stands in for P4Client. Controllable success/failure per call."""

        def __init__(self):
            self.insert_result = True
            self.delete_result = True
            self.modify_result = True
            self.inserted = []
            self.deleted = []
            self.modified = []

        def insert_ipv4_route(self, dst_ip, prefix_len, next_hop_mac, port):
            self.inserted.append((dst_ip, port))
            return self.insert_result

        def delete_ipv4_route(self, dst_ip, prefix_len):
            self.deleted.append(dst_ip)
            return self.delete_result

        def modify_ipv4_route(self, dst_ip, prefix_len, next_hop_mac, port):
            self.modified.append((dst_ip, port))
            return self.modify_result

    def setUp(self):
        super().setUp()
        self.client = self.RecordingClient()
        self.topo.add_switch(1, self.client)

    def test_a_successful_add_is_recorded(self):
        # CATCHES: route_flow not writing to _installed_routes at all (the reported defect).
        ok = self.topo.route_flow(1, {"nw_dst": "10.0.0.5"}, [{"type": "OUTPUT", "port": 3}])
        self.assertTrue(ok)
        self.assertEqual(self.topo.installed_routes().get((1, "10.0.0.5")), 3)

    def test_a_failed_add_is_not_recorded(self):
        # CATCHES: recording unconditionally instead of gating on the switch's own answer --
        # the same "success reported for work not done" shape decision B was written to close.
        self.client.insert_result = False
        ok = self.topo.route_flow(1, {"nw_dst": "10.0.0.5"}, [{"type": "OUTPUT", "port": 3}])
        self.assertFalse(ok)
        self.assertNotIn((1, "10.0.0.5"), self.topo.installed_routes())

    def test_a_successful_delete_withdraws_the_record(self):
        # CATCHES: unroute_flow leaving the entry in place, which would have the twin claim a
        # route to a destination the switch now has no rule for at all.
        self.topo.route_flow(1, {"nw_dst": "10.0.0.5"}, [{"type": "OUTPUT", "port": 3}])
        self.assertIn((1, "10.0.0.5"), self.topo.installed_routes())

        ok = self.topo.unroute_flow(1, {"nw_dst": "10.0.0.5"})
        self.assertTrue(ok)
        self.assertNotIn((1, "10.0.0.5"), self.topo.installed_routes())

    def test_a_failed_delete_leaves_the_record_alone(self):
        # CATCHES: withdrawing the record even when the switch refused the delete -- the twin
        # would then claim no route exists for a rule that is still live on the wire.
        self.topo.route_flow(1, {"nw_dst": "10.0.0.5"}, [{"type": "OUTPUT", "port": 3}])
        self.client.delete_result = False

        ok = self.topo.unroute_flow(1, {"nw_dst": "10.0.0.5"})
        self.assertFalse(ok)
        self.assertEqual(self.topo.installed_routes().get((1, "10.0.0.5")), 3)

    def test_a_successful_modify_moves_the_record_to_the_new_port(self):
        # CATCHES: modify_flow not updating the record, or deleting instead of moving it -- a
        # renderer would send packets down the pre-modify port, or show no route at all.
        self.topo.route_flow(1, {"nw_dst": "10.0.0.5"}, [{"type": "OUTPUT", "port": 3}])

        ok = self.topo.modify_flow(1, {"nw_dst": "10.0.0.5"}, [{"type": "OUTPUT", "port": 7}])
        self.assertTrue(ok)
        self.assertEqual(self.topo.installed_routes().get((1, "10.0.0.5")), 7)

    def test_a_failed_modify_leaves_the_old_port_recorded(self):
        # CATCHES: recording the new port even though the switch rejected the modify.
        self.topo.route_flow(1, {"nw_dst": "10.0.0.5"}, [{"type": "OUTPUT", "port": 3}])
        self.client.modify_result = False

        ok = self.topo.modify_flow(1, {"nw_dst": "10.0.0.5"}, [{"type": "OUTPUT", "port": 7}])
        self.assertFalse(ok)
        self.assertEqual(self.topo.installed_routes().get((1, "10.0.0.5")), 3)


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
