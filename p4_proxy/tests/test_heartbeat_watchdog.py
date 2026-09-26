"""
The heartbeat on a foreign fabric takes the beacon's path: detection, and rerouting where allowed.

[Co-developed with claude code -- Adam]

TICKET-P4-heartbeat segment W, section 1: "外來 fabric 在心跳跑著時，走和 beacon 逾時／恢復同一條路
（`_notify_link`＋watchdog pass），常數與自家 fabric 共用、不另寫一份". So nothing here has a
timeout of its own. The report is turned into beacon EVIDENCE -- "this direction was last heard at
t" -- through the entry the first cut reserved, `TopologyManager.report_external_link_state`
(TICKET-P4-roles 2.4), now with an `at`; and `check_link_beacons` decides with
LINK_BEACON_TIMEOUT_S / LINK_STARTUP_GRACE_S exactly as it does for LLDP.

What is asserted, and what each stands against:

  * a cut is called at the beacon timeout and not a tenth of a second before -- the proxy's own
    constant, not a second copy;
  * both directions, the kernel told through `_notify_link`, the direction withheld from the
    topology reply, and back up the same way when the heartbeat is heard again;
  * the reroute happens only on a fabric whose routes NDTwin owns; a fabric that skips its routes
    (an unbound or package-owned table) DETECTS and does not reroute (section 1, 段 W bullet 2);
  * a heartbeat that is dead, stale, stopped or untrusted freezes every link where it was: the
    daemon's death is not the network's (H.7 item 2);
  * a new session never brings back a link nobody has heard, and a gap never takes down a link
    only because nobody could hear it;
  * an LLDP fabric's watchdog pass is the pass it was.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

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
    from proxy_agent import link_heartbeat as hb
    from proxy_agent import topology_manager as tm
    from proxy_agent.topology_manager import TopologyManager
    from tests.test_link_heartbeat import (CUT, POD_CABLES, POD_DIRECTIONS, Clock, ReportDir,
                                           a_report)
    from tests.test_switch_state import FakeClient

TIMEOUT = tm.LINK_BEACON_TIMEOUT_S if HAVE_PROXY else 15
GRACE = tm.LINK_STARTUP_GRACE_S if HAVE_PROXY else 30


class RecordingNotifier:
    def __init__(self):
        self.calls = []

    def link_failure(self, *link):
        self.calls.append(("link_failure", link))
        return True

    def link_recovery(self, *link):
        self.calls.append(("link_recovery", link))
        return True

    def all_destination_paths(self, paths):
        self.calls.append(("all_destination_paths",))
        return True

    def of(self, kind):
        return sorted(link for k, *rest in self.calls if k == kind for link in rest)


class CountingManager(TopologyManager if HAVE_PROXY else object):
    """A real TopologyManager whose route installer is counted rather than run."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.installs = 0

    def install_initial_routes(self, only_dpid=None):
        self.installs += 1
        return 0, 0


class Fabric:
    """pod-topo's four switches and four cables, a report directory, and a pass driven by hand."""

    def __init__(self, testcase, *, routes_skipped=False):
        self.rd = ReportDir(testcase)
        self.clock = Clock()
        self.kernel = RecordingNotifier()
        self.topo = CountingManager(kernel_notifier=self.kernel, clock=self.clock)
        for dpid in (1, 2, 3, 4):
            self.topo.add_switch(dpid, FakeClient())
        for s, sp, d, dp in POD_CABLES:
            self.topo.add_link(s, d, sp, dp)
        self.topo.routes_to_attached_hosts_only = routes_skipped
        self.evidence = hb.HeartbeatEvidence(POD_DIRECTIONS, period_s=tm.LLDP_BEACON_INTERVAL_S,
                                             clock=self.clock, path=self.rd.path,
                                             owner_uid=self.rd.uid)
        self.topo.attach_link_evidence(self.evidence)
        # The flag start_link_watchdog sets, without the thread (tests/test_link_state_entry.py's
        # way): the pass is driven by hand.
        self.topo._link_watchdog_running = True
        self.last_heard = {d: self.clock.now - 1.0 for d in POD_DIRECTIONS}
        self.started = self.clock.now - 60.0
        self.session = "0102030405060708"
        self.status = "running"

    def write(self, **kw):
        kw.setdefault("started", self.started)
        kw.setdefault("session", self.session)
        kw.setdefault("status", self.status)
        self.rd.write(a_report(self.clock.now, self.last_heard, **kw))

    def tick(self, seconds, heard=True, silent=()):
        """Advance the clock; every direction not in `silent` is heard at the new time."""
        self.clock.now += seconds
        if heard:
            for d in POD_DIRECTIONS:
                if d not in silent:
                    self.last_heard[d] = self.clock.now - 0.2

    def run(self, **kw):
        self.write(**kw)
        return self.topo.run_watchdog_pass()


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class TheHeartbeatDetectsACutWithTheBeaconRuleTest(unittest.TestCase):

    def setUp(self):
        self.f = Fabric(self)
        self.f.run()      # every direction heard: nothing to say

    def cut_for(self, seconds):
        """Silence CUT for `seconds` in one-second steps (every other direction keeps talking)."""
        result = {"down": [], "up": [], "unacked": []}
        for _ in range(int(seconds)):
            self.f.tick(1.0, silent=CUT)
            result = self.f.run()
        return result

    def test_a_cable_silent_for_exactly_the_beacon_timeout_is_still_up(self):
        # Last heard at t0; judged at t0 + LINK_BEACON_TIMEOUT_S: not "longer than", so up.
        t0 = self.f.last_heard[CUT[0]]
        self.f.clock.now = t0 + TIMEOUT
        for d in POD_DIRECTIONS:
            if d not in CUT:
                self.f.last_heard[d] = self.f.clock.now - 0.2
        result = self.f.run()
        self.assertEqual(result["down"], [])
        self.assertEqual(self.f.kernel.of("link_failure"), [])

    def test_a_tenth_past_the_beacon_timeout_both_directions_go_down_and_the_kernel_is_told(self):
        t0 = self.f.last_heard[CUT[0]]
        self.f.clock.now = t0 + TIMEOUT + 0.1
        for d in POD_DIRECTIONS:
            if d not in CUT:
                self.f.last_heard[d] = self.f.clock.now - 0.2
        result = self.f.run()
        self.assertEqual(sorted(result["down"]), sorted(CUT))
        self.assertEqual(self.f.kernel.of("link_failure"), sorted(CUT))

    def test_the_other_six_directions_stay_up(self):
        self.cut_for(TIMEOUT + 2)
        down = {link for link, e in self.f.topo._link_beacons.items() if e["down"]}
        self.assertEqual(down, set(CUT))

    def test_a_cut_link_is_withheld_from_the_topology_reply(self):
        self.cut_for(TIMEOUT + 2)
        self.assertEqual(self.f.topo.down_link_endpoints(), {(1, 3), (3, 1)})

    def test_heard_again_it_comes_back_up_and_the_kernel_is_told(self):
        self.cut_for(TIMEOUT + 2)
        self.f.tick(1.0)
        result = self.f.run()
        self.assertEqual(sorted(result["up"]), sorted(CUT))
        self.assertEqual(self.f.kernel.of("link_recovery"), sorted(CUT))
        self.assertEqual(self.f.topo.down_link_endpoints(), set())

    def test_link_liveness_names_the_heartbeat_as_the_source(self):
        self.cut_for(TIMEOUT + 2)
        links = self.f.topo.link_liveness()
        self.assertEqual(links["1:3->3:1"]["source"], "heartbeat")
        self.assertIs(links["1:3->3:1"]["down"], True)
        self.assertIs(links["1:4->4:2"]["down"], False)

    def test_a_direction_never_heard_gets_the_startup_grace_from_the_heartbeats_start(self):
        f = Fabric(self)
        f.started = f.clock.now - 1.0
        f.last_heard[CUT[0]] = None
        f.last_heard[CUT[1]] = None
        f.run()
        f.clock.now = f.started + GRACE
        for d in POD_DIRECTIONS:
            if d not in CUT:
                f.last_heard[d] = f.clock.now - 0.2
        self.assertEqual(f.run()["down"], [], "never heard, and still inside the startup grace")
        f.clock.now = f.started + GRACE + 0.1
        self.assertEqual(sorted(f.run()["down"]), sorted(CUT))

    def test_the_evidence_is_entered_through_the_reserved_entry(self):
        before = self.f.topo.external_link_report()["routed_through_watchdog"]
        self.f.tick(1.0)
        self.f.run()
        after = self.f.topo.external_link_report()
        self.assertEqual(after["routed_through_watchdog"] - before, len(POD_DIRECTIONS))
        self.assertEqual(after["last"]["source"], "heartbeat")


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class RerouteOnlyWhereNdtwinOwnsTheRoutesTest(unittest.TestCase):

    def cut(self, f):
        f.run()
        installs = f.topo.installs
        f.clock.now = f.last_heard[CUT[0]] + TIMEOUT + 0.1
        for d in POD_DIRECTIONS:
            if d not in CUT:
                f.last_heard[d] = f.clock.now - 0.2
        result = f.run()
        self.assertEqual(sorted(result["down"]), sorted(CUT))
        return f.topo.installs - installs

    def test_an_owned_fabric_reroutes_on_the_transition(self):
        f = Fabric(self, routes_skipped=False)
        self.assertEqual(self.cut(f), 1)
        self.assertIn(("all_destination_paths",), f.kernel.calls)

    def test_a_fabric_that_skips_its_routes_detects_and_does_not_reroute(self):
        f = Fabric(self, routes_skipped=True)
        self.assertEqual(self.cut(f), 0, "a route was rewritten on a fabric NDTwin may not route")
        self.assertEqual(f.kernel.of("link_failure"), sorted(CUT), "and the cut was still told")

    def test_nor_does_it_reroute_on_the_way_back(self):
        f = Fabric(self, routes_skipped=True)
        self.cut(f)
        f.tick(1.0)
        self.assertEqual(sorted(f.run()["up"]), sorted(CUT))
        self.assertEqual(f.topo.installs, 0)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class ADeadHeartbeatIsNotADeadNetworkTest(unittest.TestCase):

    def setUp(self):
        self.f = Fabric(self)
        self.f.run()

    def assert_nothing_went_down(self):
        self.assertEqual(self.f.kernel.of("link_failure"), [])
        self.assertEqual(self.f.topo.down_link_endpoints(), set())

    def test_a_stale_report_freezes_every_link_where_it_was(self):
        # The daemon stops writing (killed -9): the report stays "running" and ages.
        written = self.f.clock.now - 0.5
        for _ in range(12):
            self.f.tick(5.0, heard=False)
            self.f.run(written=written)
        self.assert_nothing_went_down()

    def test_a_stopped_heartbeat_freezes_too(self):
        self.f.status = "stopped"
        for _ in range(12):
            self.f.tick(5.0, heard=False)
            self.f.run()
        self.assert_nothing_went_down()

    def test_an_untrusted_report_freezes_too(self):
        for _ in range(12):
            self.f.tick(5.0, heard=False)
            self.f.write()
            os.chmod(self.f.rd.path, 0o666)
            self.f.topo.run_watchdog_pass()
        self.assert_nothing_went_down()

    def test_coming_back_does_not_take_down_the_links_it_could_not_hear_while_away(self):
        written = self.f.clock.now - 0.5
        for _ in range(12):                       # a minute away
            self.f.tick(5.0, heard=False)
            self.f.run(written=written)
        # Back, same session; the first report after the gap has heard nothing yet.
        self.f.tick(1.0, heard=False)
        self.f.run()
        self.f.tick(1.0, heard=False)
        self.f.run()
        self.assert_nothing_went_down()

    def test_a_link_down_before_the_heartbeat_died_stays_down_while_it_is_away(self):
        self.f.clock.now = self.f.last_heard[CUT[0]] + TIMEOUT + 0.1
        for d in POD_DIRECTIONS:
            if d not in CUT:
                self.f.last_heard[d] = self.f.clock.now - 0.2
        self.f.run()
        self.assertEqual(self.f.topo.down_link_endpoints(), {(1, 3), (3, 1)})
        self.f.status = "stopped"
        for _ in range(6):
            self.f.tick(5.0, heard=False)
            self.f.run()
        self.assertEqual(self.f.topo.down_link_endpoints(), {(1, 3), (3, 1)})
        self.assertEqual(self.f.kernel.of("link_recovery"), [])

    def test_a_new_session_does_not_bring_back_a_link_nobody_has_heard(self):
        self.f.clock.now = self.f.last_heard[CUT[0]] + TIMEOUT + 0.1
        for d in POD_DIRECTIONS:
            if d not in CUT:
                self.f.last_heard[d] = self.f.clock.now - 0.2
        self.f.run()
        # A restarted daemon: new session, just started, the cut still not heard.
        self.f.session = "ffffffffffffffff"
        self.f.started = self.f.clock.now + 1.0
        self.f.tick(2.0, silent=CUT)
        self.f.last_heard[CUT[0]] = self.f.last_heard[CUT[1]] = None
        self.f.run()
        self.assertEqual(self.f.kernel.of("link_recovery"), [],
                         "a new session's silence brought a dead link back")
        self.assertEqual(self.f.topo.down_link_endpoints(), {(1, 3), (3, 1)})

    def test_a_heartbeat_that_never_ran_judges_nothing(self):
        f = Fabric(self)
        for _ in range(12):
            f.tick(5.0, heard=False)
            f.topo.run_watchdog_pass()
        self.assertEqual(f.topo._link_beacons, {})
        self.assertEqual(f.kernel.calls, [])


#: A heartbeat frame as segment H's daemon builds it: dst 02:4e:44:54:48:42, ethertype 0x88B5,
#: magic NDHB, padded to 60 bytes. Only its shape matters here -- it is not LLDP.
HEARTBEAT_FRAME = (bytes.fromhex("024e44544842") + bytes.fromhex("0200000003e1") + b"\x88\xb5"
                   + b"NDHB" + bytes(42))


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class AHeartbeatFramePuntedToTheControllerIsNotLinkEvidenceTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam] The orchestrator's 09-26 note on segment S's judge
    report: the census's `mode ndtwin` arms had the proxy's StreamChannel up, and nobody checked
    whether a heartbeat frame a pipeline punts to its CPU port reaches `handle_packet_in` as
    liveness. Whatever such a packet-in proves about the SWITCH (its stream works:
    `_last_packet_in`), it must not be LINK evidence: on this fabric the only link evidence is the
    report, so a cut stays a cut however many heartbeat frames a switch punts meanwhile.
    """

    def test_punted_heartbeat_frames_do_not_keep_a_cut_link_alive(self):
        f = Fabric(self)
        f.run()
        before = dict(f.topo._link_beacons[CUT[0]])
        for _ in range(int(TIMEOUT) + 2):
            f.tick(1.0, silent=CUT)
            for dpid, port in ((3, 1), (1, 3)):      # the cut cable's own two ports
                f.topo.handle_packet_in(dpid, port, HEARTBEAT_FRAME)
            f.run()
        self.assertEqual(f.kernel.of("link_failure"), sorted(CUT))
        self.assertEqual(f.topo._link_beacons[CUT[0]]["at"], before["at"],
                         "a punted heartbeat frame moved the cut direction's evidence")

    def test_they_are_switch_liveness_and_nothing_more(self):
        f = Fabric(self)
        f.run()
        links = dict((k, dict(v)) for k, v in f.topo._link_beacons.items())
        f.topo.handle_packet_in(3, 1, HEARTBEAT_FRAME)
        self.assertEqual(f.topo._last_packet_in[3], f.clock.now)
        self.assertEqual(f.topo._link_beacons, links)
        self.assertNotIn(3, f.topo._last_lldp_from)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class ReportExternalLinkStateWithATimeTest(unittest.TestCase):
    """The `at` the first cut's entry grew -- evidence as of a time, not as of now."""

    LINK = (1, 3, 3, 1)

    def setUp(self):
        self.clock = Clock()
        self.topo = TopologyManager(kernel_notifier=RecordingNotifier(), clock=self.clock)
        self.topo._link_watchdog_running = True

    def entry(self):
        return self.topo._link_beacons[self.LINK]

    def test_a_heard_report_enters_the_time_it_was_heard_not_now(self):
        self.topo.report_external_link_state(*self.LINK, up=True, source="heartbeat",
                                             at=self.clock.now - 7.0)
        self.assertEqual(self.entry()["at"], self.clock.now - 7.0)
        self.assertIs(self.entry()["seen"], True)

    def test_evidence_only_moves_forward(self):
        self.topo.report_external_link_state(*self.LINK, up=True, source="heartbeat",
                                             at=self.clock.now - 2.0)
        self.topo.report_external_link_state(*self.LINK, up=True, source="heartbeat",
                                             at=self.clock.now - 9.0)
        self.assertEqual(self.entry()["at"], self.clock.now - 2.0)

    def test_a_not_heard_report_on_a_new_direction_gives_it_the_startup_grace(self):
        self.topo.report_external_link_state(*self.LINK, up=False, source="heartbeat",
                                             at=self.clock.now - 4.0)
        self.assertEqual((self.entry()["at"], self.entry()["seen"]),
                         (self.clock.now - 4.0, False))

    def test_a_not_heard_report_on_a_down_direction_moves_nothing(self):
        self.topo.report_external_link_state(*self.LINK, up=True, source="heartbeat",
                                             at=self.clock.now - 100.0)
        self.topo.check_link_beacons()
        self.assertIs(self.entry()["down"], True)
        self.topo.report_external_link_state(*self.LINK, up=False, source="heartbeat",
                                             at=self.clock.now - 1.0)
        self.assertEqual(self.entry()["at"], self.clock.now - 100.0)
        self.assertEqual(self.topo.check_link_beacons()["up"], [])

    def test_the_source_is_recorded_on_the_evidence(self):
        self.topo.report_external_link_state(*self.LINK, up=True, source="heartbeat",
                                             at=self.clock.now)
        self.assertEqual(self.entry()["source"], "heartbeat")

    def test_without_a_watchdog_it_is_recorded_only_whatever_the_time(self):
        self.topo._link_watchdog_running = False
        result = self.topo.report_external_link_state(*self.LINK, up=True, source="heartbeat",
                                                      at=self.clock.now)
        self.assertFalse(result["applied"])
        self.assertEqual(self.topo._link_beacons, {})


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class AnLldpFabricsPassIsThePassItWasTest(unittest.TestCase):

    def test_no_evidence_is_attached_by_default(self):
        topo = TopologyManager()
        self.assertIsNone(topo.heartbeat_evidence())

    def test_a_beacon_that_stops_still_times_out_on_the_proxys_clock(self):
        clock, kernel = Clock(), RecordingNotifier()
        topo = TopologyManager(kernel_notifier=kernel, clock=clock)
        topo._link_beacons[(1, 3, 3, 1)] = {"at": clock.now, "down": False, "acked": True,
                                            "seen": True}
        clock.now += TIMEOUT + 0.1
        self.assertEqual(topo.run_watchdog_pass()["down"], [(1, 3, 3, 1)])
        self.assertNotIn("source", topo.link_liveness()["1:3->3:1"],
                         "an LLDP entry's shape changed")


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class TheWatchdogsPassesAreOnRecordTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam] The orchestrator's 09-26 addendum: H1 at the worst
    phase can only be verified if the watchdog's pass times are observable -- its phase relative
    to the heartbeat's rounds drifts by the passes' own durations, which nothing measured. So every
    pass is recorded (its start and end on the proxy's monotonic clock, and how many directions it
    turned down and up), a bounded log served in switch_state's heartbeat block.
    """

    def test_every_pass_is_recorded_with_its_times_and_its_transitions(self):
        f = Fabric(self)
        f.run()
        f.clock.now = f.last_heard[CUT[0]] + TIMEOUT + 0.1
        for d in POD_DIRECTIONS:
            if d not in CUT:
                f.last_heard[d] = f.clock.now - 0.2
        f.run()
        passes = f.topo.watchdog_passes()
        self.assertEqual(len(passes), 2)
        self.assertEqual((passes[1]["start_mono"], passes[1]["down"], passes[1]["up"]),
                         (f.clock.now, 2, 0))
        self.assertEqual((passes[0]["down"], passes[0]["up"]), (0, 0))
        self.assertLessEqual(passes[1]["start_mono"], passes[1]["end_mono"])

    def test_the_log_is_bounded(self):
        f = Fabric(self)
        for _ in range(tm.WATCHDOG_PASS_LOG + 5):
            f.tick(1.0)
            f.run()
        self.assertEqual(len(f.topo.watchdog_passes()), tm.WATCHDOG_PASS_LOG)

    def test_a_frozen_pass_is_recorded_too(self):
        f = Fabric(self)
        f.status = "stopped"
        f.run()
        self.assertEqual(len(f.topo.watchdog_passes()), 1)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class StartingTheHeartbeatWatchdogTest(unittest.TestCase):

    def test_it_watches_the_declared_links_and_runs_the_one_watchdog_thread(self):
        rd = ReportDir(self)
        topo = TopologyManager()
        topo._declared_links = set(POD_DIRECTIONS)
        evidence = topo.start_heartbeat_watchdog(path=rd.path, owner_uid=rd.uid)
        self.addCleanup(topo.stop_link_watchdog)
        self.assertIs(topo.heartbeat_evidence(), evidence)
        self.assertEqual(evidence.declared, POD_DIRECTIONS)
        self.assertTrue(topo._link_watchdog_running)
        self.assertEqual(topo._link_beacons, {}, "nothing is seeded: evidence comes from reports")

    def test_it_reads_the_report_once_at_once_so_the_state_is_known_before_the_first_pass(self):
        rd = ReportDir(self)
        clock = Clock()
        topo = TopologyManager(clock=clock)
        topo._declared_links = set(POD_DIRECTIONS)
        rd.write(a_report(clock.now))
        evidence = topo.start_heartbeat_watchdog(path=rd.path, owner_uid=rd.uid)
        self.addCleanup(topo.stop_link_watchdog)
        self.assertTrue(evidence.last().usable, evidence.last().detail)


if __name__ == "__main__":
    unittest.main(verbosity=2)
