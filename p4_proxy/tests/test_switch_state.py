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
import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from proxy_agent import api_routes  # noqa: E402
from proxy_agent.topology_manager import (  # noqa: E402
    LIVENESS_PROBE_INTERVAL_S,
    LIVENESS_PROBE_TIMEOUT_S,
    TopologyManager,
)


class FakeClient:
    """Stands in for a P4RuntimeClient. Records probes so a test can count them."""

    def __init__(self, ok=True, detail="ok", grpc_addr="127.0.0.1:50051", raises=False):
        self.ok = ok
        self.detail = detail
        self.grpc_addr = grpc_addr
        self.raises = raises
        self.probe_calls = 0
        self.stream_alive = True
        self.packet_in_callback = None

    def probe(self, timeout_s=None):
        self.probe_calls += 1
        if self.raises:
            raise RuntimeError("channel exploded")
        return {"ok": self.ok, "detail": self.detail}


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


if __name__ == "__main__":
    unittest.main()
