"""
Tests for the liveness evidence behind GET /p4/switch_state.

[Co-developed with claude code -- Adam]

The kernel's pingWorker used to call setVertexUp for every bmv2 switch once a second with no
evidence at all, so a switch that had been killed reported healthy again within one second and the
twin could never show a fault. `is_up` also gates the power, CPU and temperature reports and
getAvgLinkUsage, so that one fabricated field made several others meaningless.

This side produces facts; the kernel decides. The split matters and is tested here: the proxy must
report "no probe has completed yet" as something different from "the probe failed", because
collapsing those on the wire is how a single unreachable component marks an entire fabric dead --
which already happened once on the OVS side, where a failed `ovs-vsctl list-br` was
indistinguishable from a machine with no bridges.

The verdict itself is tested in tests/test_P4Liveness.cpp.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests" -- a pytest-style module runs as a script that asserts
nothing and is reported as NO TESTS RAN.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from proxy_agent import api_routes  # noqa: E402
from proxy_agent import main  # noqa: E402
# `p4_proxy/mininet` -- the fabric side. `main` puts it on sys.path at import (via profile), so
# this line only names what these tests read: ticket B's manifest writer and its liveness
# predicate, used to BUILD the fixture rather than to describe it.
# [Co-developed with claude code -- Adam]
import link_telemetry  # noqa: E402
from proxy_agent.rule_install_times import RuleInstallTimes  # noqa: E402
from proxy_agent.topology_manager import (  # noqa: E402
    LIVENESS_PROBE_INTERVAL_S,
    LIVENESS_PROBE_TIMEOUT_S,
    TopologyManager,
)


class FakeClock:
    """A clock a test moves by hand, so an age is asserted rather than slept for."""

    def __init__(self, start=0.0):
        self.now = start

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class FakeClient:
    """Stands in for a P4RuntimeClient. Records probes so a test can count them."""

    def __init__(self, ok=True, detail="ok", grpc_addr="127.0.0.1:50051", raises=False,
                 monotonic=None, wall=None):
        self.ok = ok
        self.detail = detail
        self.grpc_addr = grpc_addr
        self.raises = raises
        self.probe_calls = 0
        self.stream_alive = True
        self.packet_in_callback = None
        # [Co-developed with claude code -- Adam]
        # The real RuleInstallTimes, not a stub of one. switch_liveness reports len() of this
        # and its oldest stamp, and a stub would let those two agree with each other while
        # disagreeing with the record the flow-stats renderer reads off the same attribute.
        # Clocks are injectable for the same reason they are on the real thing: so an age is a
        # thing a test states rather than a thing it waits for.
        self.rule_install_times = RuleInstallTimes(monotonic=monotonic, wall=wall)
        self._table_read = None

    def probe(self, timeout_s=None):
        self.probe_calls += 1
        if self.raises:
            raise RuntimeError("channel exploded")
        return {"ok": self.ok, "detail": self.detail}

    def note_table_read(self, rows, age_s=0.0):
        """What a real read_table_entries leaves behind, with the age set instead of waited."""
        self._table_read = (rows, age_s)

    def last_table_read(self):
        return self._table_read


def lldp(dpid, port=1):
    """A beacon exactly as create_lldp_packet builds it, so the parser under test really parses it."""
    return (
        bytes.fromhex("0180c200000e")
        + bytes.fromhex(f"0000000000{dpid:02x}")
        + bytes.fromhex("88cc")
        + f"DPID:{dpid},PORT:{port}".encode()
    )


def wait_until(predicate, limit=10.0):
    """Polls rather than sleeping a fixed time, so these neither flake nor waste seconds."""
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


class ReportedEvidenceTest(unittest.TestCase):
    """What switch_liveness() says, given state."""

    def test_a_switch_with_no_probe_yet_reports_none_not_false(self):
        # The distinction the whole design rests on. If this were False the kernel would answer
        # Down, and every run would report the entire fabric dead for its first two seconds.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())

        state = topo.switch_liveness()["switches"]["1"]
        self.assertIsNone(state["probe_ok"])
        self.assertIsNone(state["probe_age_s"])

    def test_a_completed_probe_is_reported_with_its_detail_and_age(self):
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())
        topo._last_probe[1] = {"ok": True, "detail": "answered", "at": time.monotonic()}

        state = topo.switch_liveness()["switches"]["1"]
        self.assertIs(state["probe_ok"], True)
        self.assertEqual(state["probe_detail"], "answered")
        self.assertGreaterEqual(state["probe_age_s"], 0)
        self.assertLess(state["probe_age_s"], 1.0)

    def test_a_failed_probe_keeps_the_reason(self):
        # bmv2 returns an empty details() for some failures, so the status code name travels too --
        # a report of "" is unactionable, and that cost a real investigation once with a clone
        # session.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())
        topo._last_probe[1] = {
            "ok": False,
            "detail": "UNAVAILABLE: failed to connect to all addresses",
            "at": time.monotonic(),
        }

        state = topo.switch_liveness()["switches"]["1"]
        self.assertIs(state["probe_ok"], False)
        self.assertIn("UNAVAILABLE", state["probe_detail"])

    def test_ages_are_ages_not_timestamps(self):
        # The reader cannot align its own monotonic clock with this process's, and "never" has to be
        # representable as something other than "very long ago" -- hence ages, with None for never.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())
        topo._last_lldp_from[1] = time.monotonic() - 7.5

        age = topo.switch_liveness()["switches"]["1"]["last_lldp_age_s"]
        self.assertGreater(age, 7.4)
        self.assertLess(age, 8.0)

    def test_switches_the_proxy_does_not_manage_are_absent_rather_than_down(self):
        # A dpid in the kernel's topology file but not in the proxy's switch table is a
        # configuration disagreement. Reporting it as a switch that is down would send someone
        # looking at hardware.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())

        self.assertNotIn("9", topo.switch_liveness()["switches"])

    def test_the_report_carries_the_probe_interval_so_a_reader_can_judge_staleness(self):
        # The kernel's staleness threshold is its own, but it can only be justified against the rate
        # the proxy actually probes at, so the rate travels with the data.
        topo = TopologyManager()
        self.assertEqual(topo.switch_liveness()["probe_interval_s"], LIVENESS_PROBE_INTERVAL_S)

    def test_an_empty_proxy_reports_no_switches_rather_than_failing(self):
        # Before any switch connects. An exception here would answer 500 to the kernel once a
        # second.
        topo = TopologyManager()
        report = topo.switch_liveness()
        self.assertEqual(report["status"], "success")
        self.assertEqual(report["switches"], {})


class TheRuleClockOnTheLivenessPayloadTest(unittest.TestCase):
    """
    KNOWN-ISSUES G-13. Whether `duration 0/0` means "old" or "unknown", answered on the payload
    the kernel already polls.

    [Co-developed with claude code -- Adam]
    A bmv2 table entry has no age, so the only ages on this plane come from this proxy's own
    record of writing the rules; a rule it did not write reports 0/0, which `ndt` reads as
    UNKNOWN. From `/stats/flow/<dpid>` alone that is indistinguishable from a table full of
    genuinely new rules, and it is the first thing an operator asks once G-13 lands. Only the
    pair -- how many rules are dated, out of how many rows are there -- answers it.

    It belongs on this endpoint rather than a new one for the same reason `table_generation`
    does: the kernel already polls it once a second and reads named keys out of each entry, so
    an added key is inert to the existing parse and there is no second poll to forget.
    """

    LPM = "MyIngress.ipv4_lpm"

    def a_switch(self, monotonic=None, wall=None):
        topo = TopologyManager()
        client = FakeClient(monotonic=monotonic, wall=wall)
        topo.add_switch(1, client)
        return topo, client

    def state(self, topo, dpid=1):
        return topo.switch_liveness()["switches"][str(dpid)]

    def a_route(self, last_octet):
        """One ipv4_lpm entry's match, in the shape read_table_entries returns."""
        return {"hdr.ipv4.dstAddr": {"type": "lpm",
                                     "value": bytes((10, 0, 0, last_octet)),
                                     "prefix_len": 32}}

    def test_a_switch_reports_how_many_of_its_rules_this_proxy_can_date(self):
        topo, client = self.a_switch()
        client.rule_install_times.record(1, self.LPM, 0, self.a_route(4))
        client.rule_install_times.record(1, self.LPM, 0, self.a_route(5))

        self.assertEqual(self.state(topo)["rules_timed"], 2)

    def test_the_count_is_of_records_not_of_the_rows_on_the_switch(self):
        # 🔴 The number an operator divides, and the mutation that matters most: reporting the
        # row count in both places makes every switch read as fully dated -- which is the
        # reassuring answer, arrived at without consulting the record at all.
        topo, client = self.a_switch()
        client.rule_install_times.record(1, self.LPM, 0, self.a_route(4))
        client.note_table_read(rows=9)

        state = self.state(topo)
        self.assertEqual((state["rules_timed"], state["rules_total"]), (1, 9))

    def test_a_switch_whose_tables_nobody_has_read_reports_no_total_rather_than_zero(self):
        # "Nobody has counted" is not "there is nothing there". A 0 here would describe an empty
        # switch, and `0 of 0` reads as a table that is entirely accounted for -- the same
        # collapse of unknown into a confident number that G-13 exists to undo.
        topo, _ = self.a_switch()

        state = self.state(topo)
        self.assertIsNone(state["rules_total"])
        self.assertIsNone(state["rules_total_age_s"])
        self.assertEqual(state["rules_timed"], 0)

    def test_the_total_carries_the_age_of_the_read_it_came_from(self):
        # The count is from the last read, never from one taken here: read_table_entries blocks
        # on a gRPC stream and this report answers an `async def` endpoint, which is how one
        # SIGSTOPed bmv2 took the whole agent down on 2026-08-13. Without the age, a switch
        # nobody has polled for an hour would serve an hour-old count as though it were current.
        topo, client = self.a_switch()
        client.note_table_read(rows=40, age_s=73.5)

        state = self.state(topo)
        self.assertEqual(state["rules_total"], 40)
        self.assertAlmostEqual(state["rules_total_age_s"], 73.5)

    def test_the_record_reaches_back_to_its_oldest_stamp_in_epoch_seconds(self):
        clock, wall = FakeClock(), FakeClock(1_700_000_000.0)
        topo, client = self.a_switch(monotonic=clock, wall=wall)
        client.rule_install_times.record(1, self.LPM, 0, self.a_route(4))
        clock.advance(600)
        wall.advance(600)
        client.rule_install_times.record(1, self.LPM, 0, self.a_route(5))

        # Epoch rather than an age, because what it is compared against -- the rule journal, the
        # kernel log -- is stamped in epoch seconds. Oldest rather than newest, because the
        # question is how far back the record reaches: a reach of seconds means every older rule
        # on this switch will report 0/0 forever, however long it sits there.
        self.assertAlmostEqual(self.state(topo)["oldest_rule_installed_at"], 1_700_000_000.0)

    def test_a_switch_this_proxy_has_installed_nothing_on_has_no_reach(self):
        topo, _ = self.a_switch()

        self.assertIsNone(self.state(topo)["oldest_rule_installed_at"])

    def test_a_dpid_known_only_from_a_beacon_reports_all_four_as_null(self):
        # This report lists dpids it has probe or beacon evidence for even when self.switches has
        # no client for them. Answering 0 there would credit the proxy with a record it does not
        # have, and raising would 500 the endpoint the kernel polls once a second.
        topo = TopologyManager()
        topo._last_lldp_from[7] = time.monotonic()

        state = self.state(topo, dpid=7)
        self.assertIsNone(state["rules_timed"])
        self.assertIsNone(state["rules_total"])
        self.assertIsNone(state["rules_total_age_s"])
        self.assertIsNone(state["oldest_rule_installed_at"])


class PacketInEvidenceTest(unittest.TestCase):
    """What arriving packets are allowed to prove."""

    def test_a_packet_in_records_liveness_for_the_receiving_switch(self):
        # Every CPU packet proves the receiving switch's stream and CPU port work right now.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())
        topo.add_switch(2, FakeClient())

        topo.handle_packet_in(2, 1, lldp(1))

        state = topo.switch_liveness()["switches"]
        self.assertIsNotNone(state["2"]["last_packet_in_age_s"], "receiver not recorded")
        self.assertLess(state["2"]["last_packet_in_age_s"], 1.0)

    def test_a_beacon_records_liveness_for_the_switch_that_sent_it(self):
        # The beacon's own DPID field proves that switch is still forwarding, which the gRPC probe
        # cannot show: bmv2 answers control-plane RPCs whether or not its pipeline moves packets.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())
        topo.add_switch(2, FakeClient())

        topo.handle_packet_in(2, 1, lldp(1))

        state = topo.switch_liveness()["switches"]
        self.assertIsNotNone(state["1"]["last_lldp_age_s"], "originator not recorded")
        self.assertLess(state["1"]["last_lldp_age_s"], 1.0)

    def test_evidence_is_recorded_even_once_the_link_is_already_known(self):
        # The regression that motivated recording at all. handle_packet_in returns early when the
        # edge already exists, and the topology converges within seconds -- so every beacon after
        # the first of each pair used to be discarded. Thousands of proofs of life per minute,
        # thrown away, while the switch that sent them would have looked stale.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())
        topo.add_switch(2, FakeClient())

        topo.handle_packet_in(2, 1, lldp(1))  # discovers the link
        self.assertTrue(topo.net.has_edge(1, 2), "the link should be known by now")

        # Let it go stale first, then beacon again. Reading before the sleep would compare two
        # sub-millisecond ages that both round to 0.0 -- which is how the first version of this test
        # failed, having asserted nothing.
        time.sleep(0.05)
        stale = topo.switch_liveness()["switches"]["1"]["last_lldp_age_s"]
        self.assertGreater(stale, 0.02, "the age is not advancing at all")

        topo.handle_packet_in(2, 1, lldp(1))  # the edge now exists: the early-return path
        refreshed = topo.switch_liveness()["switches"]["1"]["last_lldp_age_s"]

        self.assertLess(
            refreshed,
            stale,
            "a beacon on an already-known link did not refresh the timestamp, so a switch would "
            "look stale while beaconing perfectly well",
        )

    def test_a_self_addressed_beacon_still_counts_as_evidence(self):
        # handle_packet_in returns early for src_dpid == device_id to avoid a self-loop edge. That
        # is about the topology, not about liveness: the packet still arrived and still proves the
        # switch is alive.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())

        topo.handle_packet_in(1, 1, lldp(1))

        state = topo.switch_liveness()["switches"]["1"]
        self.assertIsNotNone(state["last_packet_in_age_s"])
        self.assertIsNotNone(state["last_lldp_age_s"])

    def test_a_non_lldp_packet_counts_for_the_receiver_but_not_as_a_beacon(self):
        # A telemetry sample or a stray frame proves the receiver's CPU path works. It says nothing
        # about who forwarded it, and must not be credited to another switch.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())
        topo.add_switch(2, FakeClient())

        topo.handle_packet_in(2, 1, b"\x00" * 40)  # ethertype is not 0x88cc

        state = topo.switch_liveness()["switches"]
        self.assertIsNotNone(state["2"]["last_packet_in_age_s"])
        self.assertIsNone(state["1"]["last_lldp_age_s"])
        self.assertIsNone(state["2"]["last_lldp_age_s"])

    def test_a_truncated_packet_does_not_raise(self):
        # parse_lldp_packet is fed whatever arrives on the CPU port. This runs on the gRPC receiver
        # thread, where an exception would end that switch's packet handling for the rest of the run.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())

        for payload in (b"", b"\x00", b"\x01" * 13, bytes.fromhex("88cc")):
            topo.handle_packet_in(1, 1, payload)

        self.assertIsNotNone(
            topo.switch_liveness()["switches"]["1"]["last_packet_in_age_s"],
            "a short frame is still a frame and still proves the CPU path works",
        )


class PollerTest(unittest.TestCase):
    """The background prober."""

    def test_the_polling_thread_records_a_result_for_every_switch(self):
        topo = TopologyManager()
        for dpid in (1, 2, 3):
            topo.add_switch(dpid, FakeClient(ok=(dpid != 3)))

        topo.start_liveness_polling()
        try:
            wait_until(
                lambda: all(
                    topo.switch_liveness()["switches"][str(d)]["probe_ok"] is not None
                    for d in (1, 2, 3)
                )
            )
        finally:
            topo.stop_liveness_polling()

        state = topo.switch_liveness()["switches"]
        self.assertIs(state["1"]["probe_ok"], True)
        self.assertIs(state["2"]["probe_ok"], True)
        self.assertIs(state["3"]["probe_ok"], False, "a failing switch was reported as healthy")

    def test_a_probe_that_raises_does_not_stop_the_poller(self):
        # If one exception killed the loop, every switch would freeze at its last result and the
        # kernel would be handed stale facts forever -- and because the ages keep growing, it would
        # eventually answer Unknown for the whole fabric and never recover.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient(raises=True))
        topo.add_switch(2, FakeClient(ok=True))

        topo.start_liveness_polling()
        try:
            wait_until(
                lambda: all(
                    topo.switch_liveness()["switches"][str(d)]["probe_ok"] is not None
                    for d in (1, 2)
                )
            )
        finally:
            topo.stop_liveness_polling()

        state = topo.switch_liveness()["switches"]
        self.assertIs(state["1"]["probe_ok"], False)
        self.assertIn("RuntimeError", state["1"]["probe_detail"])
        self.assertIs(
            state["2"]["probe_ok"], True, "the switch after the raising one was never probed"
        )

    def test_starting_twice_does_not_start_two_pollers(self):
        # main.py's startup is not the only caller in a reload, and two pollers would double the
        # RPC rate against every switch while making the ages jitter.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())

        topo.start_liveness_polling()
        first = topo._liveness_thread
        topo.start_liveness_polling()
        try:
            self.assertIs(topo._liveness_thread, first, "a second poller thread was started")
        finally:
            topo.stop_liveness_polling()

    def test_the_probe_deadline_is_below_the_interval(self):
        # A hung switch must not make the poller fall behind on the other nine. Asserted rather than
        # left to the constants, because the failure would present as unrelated staleness.
        self.assertLess(LIVENESS_PROBE_TIMEOUT_S, LIVENESS_PROBE_INTERVAL_S)

    def test_a_switch_added_after_the_poller_started_is_probed(self):
        # main.py registers switches as their gRPC sessions come up, which can be after the poller
        # starts.
        topo = TopologyManager()
        topo.add_switch(1, FakeClient())
        topo.start_liveness_polling()
        try:
            wait_until(lambda: topo.switch_liveness()["switches"]["1"]["probe_ok"] is not None)
            topo.add_switch(2, FakeClient())
            found = wait_until(
                lambda: topo.switch_liveness()["switches"]["2"]["probe_ok"] is not None
            )
        finally:
            topo.stop_liveness_polling()

        self.assertTrue(found, "a late-joining switch was never probed")

    def test_registering_a_switch_during_a_polling_pass_does_not_break_the_pass(self):
        # The poller snapshots self.switches with list() before iterating. Without that, add_switch
        # landing mid-pass raises "dictionary changed size during iteration" inside the poller
        # thread, which kills it silently -- every switch then freezes at its last result forever.
        #
        # The obvious version of this test cannot reach that: with an instant probe the pass is over
        # in microseconds and then sleeps two seconds, so a registration almost never lands inside
        # it. Verified by mutation -- removing the list() left that test green. A slow probe widens
        # the pass to ~400 ms so the registration reliably lands inside one.
        class SlowClient(FakeClient):
            def probe(self, timeout_s=None):
                time.sleep(0.02)
                return super().probe(timeout_s)

        topo = TopologyManager()
        for dpid in range(1, 21):
            topo.add_switch(dpid, SlowClient())

        topo.start_liveness_polling()
        try:
            # Wait for the pass to be under way, then register into it.
            wait_until(lambda: topo.switch_liveness()["switches"]["1"]["probe_ok"] is not None)
            for dpid in range(21, 41):
                topo.add_switch(dpid, SlowClient())
                time.sleep(0.01)

            # The poller must still be alive and must reach the newcomers. If the pass died, nothing
            # after the mutation point is ever probed.
            reached = wait_until(
                lambda: topo.switch_liveness()["switches"]["40"]["probe_ok"] is not None,
                limit=15.0,
            )
        finally:
            topo.stop_liveness_polling()

        # There used to be an `assertTrue(topo._liveness_thread.is_alive() or reached)` above this
        # line. It could not fail on its own -- with `reached` true it passed regardless of the
        # thread, and with `reached` false the assertion below failed anyway -- so it was two lines
        # claiming to check the thread while checking nothing. It also read the thread handle after
        # stop_liveness_polling(), which now joins and clears it, so a thread that shut down
        # correctly looked like one that had died. `reached` is the real evidence: nothing after the
        # mutation point gets probed if the pass died. [Co-developed with claude code -- Adam]
        self.assertTrue(reached, "switches registered during a pass were never probed")


class ConcurrencyTest(unittest.TestCase):
    def test_concurrent_packet_ins_and_reads_do_not_corrupt_the_report(self):
        # handle_packet_in runs on each client's gRPC receiver thread while an HTTP handler reads.
        #
        # What this does and does not show, because the first version of this comment claimed more
        # than the test delivers: removing _liveness_lock entirely leaves this test passing, which
        # was verified by mutation. On CPython the GIL makes `d[k] = v` and `set(d)` single
        # uninterrupted C calls, so these particular operations cannot interleave badly and no
        # test written at this level can prove the lock is load-bearing here.
        #
        # The lock stays for two reasons that are real but not demonstrable from outside: a reader
        # holding it gets every field of every switch from one instant rather than a mixture of two,
        # and the GIL guarantee it would otherwise be leaning on does not exist on a free-threaded
        # build.
        #
        # So what this test actually asserts is narrower than its name suggests: ten writers and
        # three readers running flat out produce no exception and no corrupt report. That is worth
        # having -- it is how a genuinely unsafe change here would surface -- but it is not proof of
        # the lock.
        topo = TopologyManager()
        for dpid in range(1, 11):
            topo.add_switch(dpid, FakeClient())

        stop = threading.Event()
        errors = []

        def writer(dpid):
            while not stop.is_set():
                try:
                    topo.handle_packet_in(dpid, 1, lldp(dpid))
                except Exception as e:  # noqa: BLE001
                    errors.append(e)
                    return

        def reader():
            while not stop.is_set():
                try:
                    topo.switch_liveness()
                except Exception as e:  # noqa: BLE001
                    errors.append(e)
                    return

        threads = [threading.Thread(target=writer, args=(d,)) for d in range(1, 11)]
        threads += [threading.Thread(target=reader) for _ in range(3)]
        for t in threads:
            t.start()
        time.sleep(0.5)
        stop.set()
        for t in threads:
            t.join(timeout=5)

        self.assertEqual(errors, [])


class ConnectedSwitchListTest(unittest.TestCase):
    """Which switches `GET /v1.0/topology/switches` admits to being connected to.

    [Co-developed with claude code -- Adam]
    Driven through the endpoint rather than through connected_switch_dpids alone, because the
    defect was in the *caller*: render_switches has always documented "a switch the proxy cannot
    reach does not appear", and topology_switches handed it `switches.keys()` -- every client
    ever built, dead ones included. A test of the helper by itself would stay green while
    someone put `switches.keys()` back.

    Why it mattered: the kernel's updateSwitches sets isUp = true unconditionally for every dpid
    listed here, so a dead switch appearing in this list made the twin announce it alive once per
    topology poll, until the 1 Hz liveness worker took it back down a second later.
    """

    def setUp(self):
        self._saved_topology = api_routes.topology

    def tearDown(self):
        api_routes.topology = self._saved_topology

    @staticmethod
    def listed(topo):
        """The dpids the endpoint reports, decoded from Ryu's hex-string shape."""
        api_routes.topology = topo
        return sorted(int(s["dpid"], 16) for s in asyncio.run(api_routes.topology_switches()))

    def test_a_switch_whose_probe_failed_is_not_reported_as_connected(self):
        topo = TopologyManager()
        for dpid in (1, 2, 3):
            topo.add_switch(dpid, FakeClient())
        topo._last_probe[1] = {"ok": True, "detail": "answered", "at": time.monotonic()}
        topo._last_probe[2] = {"ok": False, "detail": "connection refused", "at": time.monotonic()}
        topo._last_probe[3] = {"ok": True, "detail": "answered", "at": time.monotonic()}

        self.assertEqual(self.listed(topo), [1, 3],
                         "a switch the proxy cannot reach was still offered to the kernel, which "
                         "turns membership of this list into isUp = true")

    def test_a_switch_that_answers_its_probe_is_reported(self):
        # The accept path. Without this the suite could pass by reporting nothing at all, and a
        # fabric where no switch is ever listed never comes up.
        topo = TopologyManager()
        topo.add_switch(7, FakeClient())
        topo._last_probe[7] = {"ok": True, "detail": "answered", "at": time.monotonic()}

        self.assertEqual(self.listed(topo), [7])

    def test_a_switch_with_no_probe_yet_is_reported(self):
        # Three states, not two. "Never asked" is not "asked and told no": excluding it would
        # report an empty fabric for the first seconds of every run, which is the same mistake
        # p4LivenessFor avoids by answering Unknown rather than Down.
        topo = TopologyManager()
        topo.add_switch(4, FakeClient())

        self.assertEqual(self.listed(topo), [4],
                         "a switch that has simply not been probed yet was reported as "
                         "disconnected")

    def test_a_switch_that_comes_back_is_reported_again(self):
        # Power-on has to be able to reverse this, or a switch that failed one probe would be
        # withheld from the kernel forever.
        topo = TopologyManager()
        topo.add_switch(6, FakeClient())
        topo._last_probe[6] = {"ok": False, "detail": "connection refused", "at": time.monotonic()}
        self.assertEqual(self.listed(topo), [])

        topo._last_probe[6] = {"ok": True, "detail": "answered", "at": time.monotonic()}
        self.assertEqual(self.listed(topo), [6])


# --- the telemetry disclosure on GET /p4/switch_state. TICKET-P3 2.6 --------------------------


class TheTelemetryDisclosureTest(unittest.TestCase):
    """
    Three keys that say why a switch is not sampling, when it is not sampling on purpose.

    [Co-developed with claude code -- Adam]
    🔴 `pipeline.skipped` ALREADY NAMES THE TWO STEPS AND STAYS EXACTLY AS IT WAS (TICKET-P2
    7-7): they really were skipped. What it cannot say is WHY, and "why" is the entire
    difference between a decision and a fault -- a `link` switch and a switch whose clone
    session failed produce identical `skipped` lists, identical zero sample counts, and
    identical empty edges in the twin.
    """

    class FakeTopology:
        def switch_liveness(self):
            return {"status": "success", "probe_interval_s": 2.0,
                    "switches": {"1": {"probe_ok": True}, "2": {"probe_ok": None}},
                    "boot_id": "b", "boot_at": 1.0}

    def setUp(self):
        self.saved = (api_routes.topology, api_routes.control_plane_report,
                      api_routes.entries_recorded_report, api_routes.pipelines_report,
                      api_routes.table_entries_report, api_routes.note_api_table_entry_write,
                      api_routes.telemetry_report, api_routes.pre_entries_report,
                      api_routes.control_plane_telemetry)
        self.addCleanup(self.restore)
        api_routes.topology = self.FakeTopology()
        api_routes.inject_control_plane(
            lambda: {"mode": "ndtwin", "package": None, "skipped": []}, lambda: {})
        api_routes.inject_package_reports(lambda: {}, lambda: {}, lambda dpid: None)

    def restore(self):
        (api_routes.topology, api_routes.control_plane_report,
         api_routes.entries_recorded_report, api_routes.pipelines_report,
         api_routes.table_entries_report, api_routes.note_api_table_entry_write,
         api_routes.telemetry_report, api_routes.pre_entries_report,
         api_routes.control_plane_telemetry) = self.saved

    def state(self, telemetry=None, pre=None, fabric=None):
        api_routes.inject_telemetry_reports(
            None if telemetry is None else (lambda: telemetry),
            None if pre is None else (lambda: pre),
            None if fabric is None else (lambda: fabric))
        return asyncio.run(api_routes.switch_state())

    A_COOPERATIVE_SWITCH = {"source": "cooperative", "clone_session": True,
                            "sflow_registered": True,
                            "packet_in_ids": {"reason": 1, "ingress_port": 2, "egress_port": 3,
                                              "frame_length": 4, "sampling_rate": 5},
                            "reason": "cooperative telemetry"}
    A_LINK_SWITCH = {"source": "link", "clone_session": False, "sflow_registered": False,
                     "packet_in_ids": None, "reason": "telemetry source 'link'"}

    def test_each_switch_carries_its_own_telemetry_object(self):
        body = self.state(telemetry={"1": self.A_COOPERATIVE_SWITCH, "2": self.A_LINK_SWITCH})
        self.assertEqual(body["switches"]["1"]["telemetry"], self.A_COOPERATIVE_SWITCH)
        self.assertEqual(body["switches"]["2"]["telemetry"], self.A_LINK_SWITCH)

    def test_the_five_ids_are_disclosed_by_name(self):
        # They stopped being something a reader can look up in the source the moment they became
        # a per-switch fact, so they are published.
        body = self.state(telemetry={"1": self.A_COOPERATIVE_SWITCH, "2": self.A_LINK_SWITCH})
        self.assertEqual(body["switches"]["1"]["telemetry"]["packet_in_ids"]["egress_port"], 3)
        self.assertIsNone(body["switches"]["2"]["telemetry"]["packet_in_ids"])

    def test_the_pre_existing_keys_are_untouched(self):
        body = self.state(telemetry={"1": self.A_COOPERATIVE_SWITCH})
        self.assertEqual(body["status"], "success")
        self.assertEqual(body["switches"]["1"]["probe_ok"], True)
        self.assertEqual(body["switches"]["2"]["probe_ok"], None)
        self.assertEqual(body["control_plane"]["skipped"], [])

    def test_a_switch_the_report_does_not_mention_gets_null_rather_than_no_key(self):
        # An absent key cannot be told from a proxy too old to have one; a null can.
        body = self.state(telemetry={"1": self.A_COOPERATIVE_SWITCH})
        self.assertIn("telemetry", body["switches"]["2"])
        self.assertIsNone(body["switches"]["2"]["telemetry"])

    def test_pre_entries_are_per_switch_and_default_to_zeroes(self):
        body = self.state(pre={"1": {"multicast": {"recorded": 1, "applied": 1, "failed": 0},
                                     "clone": {"recorded": 0, "applied": 0, "failed": 0}}})
        self.assertEqual(body["switches"]["1"]["pre_entries"]["multicast"]["applied"], 1)
        self.assertEqual(body["switches"]["2"]["pre_entries"],
                         {"multicast": {"recorded": 0, "applied": 0, "failed": 0},
                          "clone": {"recorded": 0, "applied": 0, "failed": 0}})

    def test_the_fabric_wide_telemetry_says_what_was_asked_for(self):
        body = self.state(fabric={"knob": "link", "package": "auto", "link_emitter": None})
        self.assertEqual(body["control_plane"]["telemetry"],
                         {"knob": "link", "package": "auto", "link_emitter": None})

    def test_an_uninjected_reporter_adds_no_key_at_all(self):
        # Belt and braces for the baseline: a proxy that has not wired these up must not grow a
        # `telemetry` key full of nulls, which a reader would take for a disclosure.
        body = self.state()
        self.assertNotIn("telemetry", body["switches"]["1"])
        self.assertNotIn("pre_entries", body["switches"]["1"])
        self.assertNotIn("telemetry", body["control_plane"])


class TheLinkEmitterSummaryTest(unittest.TestCase):
    """`control_plane.telemetry.link_emitter` -- B's manifest, read with B's reader.

    [Co-developed with claude code -- Adam]
    🔴 THE FIXTURE IS BUILT BY `link_telemetry.manifest_document()`, NOT BY HAND (TICKET-P3
    section 9 ruling 5). Round 1 hand-wrote a dict from the ticket's prose, in which `switches`
    was a map; B writes a LIST of objects. The proxy iterated it as a map and produced a list of
    stringified dicts -- silently wrong, not None, not an exception -- and the hand-written
    fixture agreed with the mistake, so nothing could catch it. A fixture produced by the writer
    cannot disagree with the writer.
    """

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_link_manifest_")
        self.addCleanup(self._clean)

    def _clean(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def plan(self, dpids=(1, 2)):
        """A LinkTelemetryPlan, built with B's own dataclasses."""
        switches = []
        for dpid in dpids:
            ports = [link_telemetry.PortPlan(port=1, ifname=f"s{dpid}-eth1",
                                             ifindex=100 + dpid, key=100 + dpid,
                                             ingress=True, egress=True)]
            switches.append(link_telemetry.SwitchPlan(
                dpid=dpid, name=f"s{dpid}", agent_ip=f"192.168.123.{10 + dpid}", ports=ports))
        return link_telemetry.LinkTelemetryPlan(switches=tuple(switches), commands=(),
                                                rate=link_telemetry.LINK_SAMPLE_RATE)

    def manifest(self, pid, dpids=(1, 2)):
        path = os.path.join(self.tmp, "ndtwin_link_telemetry.json")
        document = link_telemetry.manifest_document(self.plan(dpids), pid)
        with open(path, "w") as fh:
            json.dump(document, fh)
        return path

    def test_no_manifest_is_none_rather_than_an_empty_summary(self):
        self.assertIsNone(main.link_emitter_report(os.path.join(self.tmp, "absent.json")))

    def test_the_switches_come_back_as_dpids_and_not_as_stringified_objects(self):
        # The judge's finding, pinned. `switches` is a list of {dpid, name, agent_ip, ports};
        # iterating it as a map gives a list whose entries are dicts rendered as text, and every
        # reader downstream sees a plausible-looking list of "switches" that names nothing.
        report = main.link_emitter_report(self.manifest(os.getpid(), dpids=(3, 1, 2)))
        self.assertEqual(report["switches"], [1, 2, 3])
        for entry in report["switches"]:
            self.assertIsInstance(entry, int)

    def test_the_rate_and_the_pid_come_from_the_document(self):
        report = main.link_emitter_report(self.manifest(os.getpid()))
        self.assertEqual(report["pid"], os.getpid())
        self.assertEqual(report["rate"], link_telemetry.LINK_SAMPLE_RATE)

    def test_a_pid_that_is_not_the_emitter_reads_dead(self):
        # 🔴 `alive` IS B'S `process_is_the_emitter`, NOT `/proc/<pid>` EXISTING (section 9
        # ruling 5). This test's own pid is a live process and is NOT the emitter, so round 1's
        # check would have called it alive -- which is the exact lie the field exists to avoid:
        # `link` telemetry with a dead emitter samples into nothing, zero on every edge.
        report = main.link_emitter_report(self.manifest(os.getpid()))
        self.assertFalse(report["alive"],
                         "this test process is not psample_sflow_emitter.py")

    def test_a_pid_whose_cmdline_is_the_emitter_reads_alive(self):
        # The positive half, with B's predicate pointed at a /proc tree written here: nothing is
        # launched, and the assertion is still about the real check rather than about a stub.
        proc = os.path.join(self.tmp, "proc", "4242")
        os.makedirs(proc, exist_ok=True)
        with open(os.path.join(proc, "cmdline"), "wb") as fh:
            fh.write(b"/usr/bin/python3\x00" + os.path.basename(
                link_telemetry.EMITTER_PATH).encode() + b"\x00--manifest\x00/tmp/m.json\x00")
        self.assertTrue(link_telemetry.process_is_the_emitter(
            4242, proc_root=os.path.join(self.tmp, "proc")))

        path = self.manifest(4242)
        with mock.patch.object(link_telemetry, "process_is_the_emitter",
                               lambda pid: pid == 4242):
            self.assertTrue(main.link_emitter_report(path)["alive"])

    def test_a_manifest_that_does_not_parse_is_none_rather_than_a_crash(self):
        path = os.path.join(self.tmp, "broken.json")
        with open(path, "w") as fh:
            fh.write("{not json")
        self.assertIsNone(main.link_emitter_report(path))

    def test_a_manifest_with_no_pid_is_not_alive(self):
        path = os.path.join(self.tmp, "ndtwin_link_telemetry.json")
        document = link_telemetry.manifest_document(self.plan(), None)
        with open(path, "w") as fh:
            json.dump(document, fh)
        report = main.link_emitter_report(path)
        self.assertFalse(report["alive"])
        self.assertIsNone(report["pid"])

    def test_the_proxy_reads_the_path_the_bring_up_writes(self):
        # One constant, B's. Two would be a proxy that reports "no link emitter" on a fabric
        # that has one.
        self.assertEqual(main.LINK_TELEMETRY_MANIFEST, link_telemetry.LINK_TELEMETRY_MANIFEST)


if __name__ == "__main__":
    unittest.main()
