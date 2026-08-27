"""Tests for the per-dpid datagram batching in sflow_emitter.py (ticket R).

[Co-developed with claude code -- Adam]
Implementation by `8/25 mainDev`; these tests are the rescue, not the feature.

WHY THIS FILE EXISTS. The batching lived in the working tree, uncommitted, with zero Python
tests, while tickets D, E, F and G were all measured against it. Four rounds of results were
therefore anchored to a file that a single `git checkout` would have erased. Two of the tests
below are load-bearing for those results rather than for the feature:

  * test_default_one_is_byte_for_byte_the_old_behaviour pins the claim the source comment makes
    in capitals -- "DEFAULT 1 IS EXACTLY THE OLD BEHAVIOUR, byte for byte". Every baseline arm in
    D/E/F/G ran at batch_size=1 and is only comparable to pre-batching runs if that holds. A
    comment is a claim; this is the test it never had.

  * test_two_switches_never_share_a_datagram pins a protocol requirement. An sFlow datagram
    carries exactly one agent address, so mixing two switches' samples attributes bytes to the
    wrong switch -- and does it silently, producing plausible numbers for the wrong node.

Run with the venv interpreter, not conda's python3:
    PYTHONDONTWRITEBYTECODE=1 ./p4_proxy/venv/bin/python3 -m unittest tests.python.test_sflow_emitter_batching
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "p4_proxy"))

from proxy_agent.sflow_emitter import (          # noqa: E402
    SFlowEmitter, SampledPacket, build_datagram,
)

UPTIME = 123456


class RecordingSocket:
    """Captures sendto instead of touching the network. Tests need no collector at all."""

    def __init__(self):
        self.sent = []

    def sendto(self, data, addr):
        self.sent.append((bytes(data), addr))
        return len(data)

    def close(self):
        pass


def sample(seed: int) -> SampledPacket:
    """A distinguishable sample. The frame differs per seed so datagrams cannot compare equal
    by accident -- two identical samples would make a mixing bug look like correct output."""
    return SampledPacket(ingress_port=1, egress_port=2, frame_length=1500,
                         sampling_rate=256, frame=bytes([seed & 0xFF]) * 64)


def emitter(batch_size=1, delay=0.2, dpids=((1, "192.168.123.11"),)):
    sock = RecordingSocket()
    em = SFlowEmitter(sock=sock, batch_size=batch_size, batch_max_delay_s=delay)
    for dpid, ip in dpids:
        em.register_switch(dpid, ip)
    return em, sock


class BatchingDefaultIsOldBehaviour(unittest.TestCase):

    def test_default_one_is_byte_for_byte_the_old_behaviour(self):
        """LOAD-BEARING. Kill this and D/E/F/G's baseline arms lose their justification.

        The old behaviour was exactly `build_datagram([one_sample], agent, uptime, max_header)`
        per emit. Reproduced here on a second emitter whose agent evolves through the same
        sequence numbers, because the agent is stateful and comparing against a single fresh
        datagram would only test the first send.
        """
        em, sock = emitter(batch_size=1)
        ref_em, _ = emitter(batch_size=1)
        expected = []
        for i in range(5):
            s = sample(i)
            self.assertTrue(em.emit(1, s, UPTIME + i))
            expected.append(build_datagram([s], ref_em._agents[1], UPTIME + i,
                                           ref_em.max_header_bytes))
        self.assertEqual([d for d, _ in sock.sent], expected)
        self.assertEqual(em.datagrams_sent, 5)
        self.assertEqual(em.samples_sent, 5)

    def test_default_one_sends_immediately_and_buffers_nothing(self):
        """batch_size=1 must not go through the buffer at all -- 'accepted' and 'on the wire'
        are the same thing at the default, which is what makes it comparable to pre-batching."""
        em, sock = emitter(batch_size=1)
        em.emit(1, sample(0), UPTIME)
        self.assertEqual(len(sock.sent), 1)
        self.assertEqual(em._pending, {})
        self.assertEqual(em.batches_flushed_full, 0)
        self.assertEqual(em.batches_flushed_aged, 0)


class BatchingKeepsSwitchesApart(unittest.TestCase):

    def test_two_switches_never_share_a_datagram(self):
        """LOAD-BEARING. An sFlow datagram carries one agent address; mixing is silent.

        Byte-equality against independently built per-dpid datagrams rather than parsing the
        wire format: parsing would test the parser, and a mixing bug that happened to produce a
        parseable datagram would slip through.
        """
        em, sock = emitter(batch_size=2, dpids=((1, "192.168.123.11"), (2, "192.168.123.12")))
        ref, _ = emitter(batch_size=2, dpids=((1, "192.168.123.11"), (2, "192.168.123.12")))

        s1a, s1b = sample(10), sample(11)
        s2a, s2b = sample(20), sample(21)
        em.emit(1, s1a, UPTIME)
        em.emit(2, s2a, UPTIME)
        em.emit(1, s1b, UPTIME)          # dpid 1 reaches batch_size -> flushes
        em.emit(2, s2b, UPTIME)          # dpid 2 reaches batch_size -> flushes

        self.assertEqual(len(sock.sent), 2, "one datagram per switch, not one shared")
        want1 = build_datagram([s1a, s1b], ref._agents[1], UPTIME, ref.max_header_bytes)
        want2 = build_datagram([s2a, s2b], ref._agents[2], UPTIME, ref.max_header_bytes)
        self.assertEqual(sock.sent[0][0], want1)
        self.assertEqual(sock.sent[1][0], want2)

    def test_a_quiet_switch_does_not_hold_a_busy_one(self):
        """The sweep exists so a switch going quiet mid-batch cannot park its samples until it
        speaks again -- for a failing link that is exactly when the telemetry matters."""
        em, sock = emitter(batch_size=10, delay=0.0,
                           dpids=((1, "192.168.123.11"), (2, "192.168.123.12")))
        em.emit(2, sample(20), UPTIME)               # dpid 2 buffers, then goes quiet
        self.assertEqual(len(sock.sent), 0)
        em.emit(1, sample(10), UPTIME)               # dpid 1 speaks; the sweep ages dpid 2 out
        self.assertEqual(em.batches_flushed_aged, 1)
        self.assertEqual(len(sock.sent), 1, "the aged-out switch's samples went, not dpid 1's")
        self.assertNotIn(2, em._pending)


class BatchingFlushPaths(unittest.TestCase):

    def test_full_batch_counts_as_full_not_aged(self):
        em, sock = emitter(batch_size=3)
        for i in range(3):
            em.emit(1, sample(i), UPTIME)
        self.assertEqual((em.batches_flushed_full, em.batches_flushed_aged), (1, 0))
        self.assertEqual(len(sock.sent), 1)
        self.assertEqual(em.samples_sent, 3)

    def test_flush_empties_every_pending_switch(self):
        em, sock = emitter(batch_size=10,
                           dpids=((1, "192.168.123.11"), (2, "192.168.123.12")))
        em.emit(1, sample(1), UPTIME)
        em.emit(2, sample(2), UPTIME)
        self.assertEqual(len(sock.sent), 0)
        em.flush(UPTIME)
        self.assertEqual(len(sock.sent), 2)
        self.assertEqual(em._pending, {})

    def test_close_flushes_before_the_socket_goes(self):
        """Order matters: closing first would discard the last partial batches silently."""
        em, sock = emitter(batch_size=10)
        em.emit(1, sample(1), UPTIME)
        em.close()
        self.assertEqual(len(sock.sent), 1, "close() must flush, not drop")


class QuietFabricTailIsPinnedNotFixed(unittest.TestCase):
    """Ticket R records this defect rather than repairing it -- a fix is a behaviour change.

    The ageing sweep only runs when a sample arrives. If the WHOLE fabric goes quiet, nothing
    arrives, so every switch's last partial batch sits in memory until close(). flush()'s own
    docstring says a long-running caller should also call it on a timer -- and main.py never
    does. The mitigation exists and has no caller, which is this repository's largest defect
    family. Harmless at batch_size=1; it bites if truncate/merge is adopted.
    """

    def test_whole_fabric_quiet_leaves_the_tail_buffered(self):
        em, sock = emitter(batch_size=10, delay=0.0)
        em.emit(1, sample(1), UPTIME)
        self.assertEqual(len(sock.sent), 0)
        # No further emit from anyone: the sweep never runs, so this stays buffered. Asserted as
        # current behaviour so that a future fix has to come here and change it deliberately.
        self.assertIn(1, em._pending)
        self.assertEqual(len(sock.sent), 0)


if __name__ == "__main__":
    unittest.main()
