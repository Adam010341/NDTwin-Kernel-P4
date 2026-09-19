#!/usr/bin/env python3
"""A netlink message in, an sFlow datagram out -- with no kernel and no socket in the room.

[Co-developed with claude code -- Adam]

TICKET-P3 sections 2.2 and 2.5. `psample_sflow_emitter.py` is the process the bring-up starts
as root; this file exercises everything in it except the two lines that open a socket, by
ENCODING netlink messages here and feeding them to the decoder. The encoder below is written
independently of the module's own `nla()` -- little-endian spelled out, lengths computed by
hand -- so a decoder that agreed with a shared encoder about the wrong layout would still be
caught.

🔴 THE FOUR THINGS THAT ARE NOT COSMETIC, each the shape of a wrong twin rather than a crash:

  1. `frame_length` IS ORIGSIZE, NOT `len(DATA)`. `trunc 128` caps DATA whatever the packet
     was, and the kernel multiplies frameLength by the sampling rate to get link bytes -- so
     the captured length would report a 1500-byte packet as 128 and the whole fabric's link
     usage would come out an order of magnitude low, plausibly.
  2. DIRECTION IS WHICH ATTRIBUTE IS PRESENT (measured 2026-09-17: an ingress filter emits
     IIFINDEX and no OIFINDEX, an egress one the reverse). An ingress sample must become
     `ingress_port=p, egress_port=0`, an egress one `ingress_port=0, egress_port=p` -- section
     2.2's shape, and the one the kernel banks as egress-only and credits to the switch->host
     edge. A port number in the ingress field of an egress sample books it against the
     host->switch edge instead: the same bytes, on the wrong side of the cable.
  3. THE IFINDEX IS SIXTEEN BITS. The map is keyed on `& 0xFFFF` and a sample whose key is not
     in the map is DROPPED AND COUNTED -- never attributed to the nearest thing.
  4. THE BYTES ARE `sflow_emitter.build_datagram`'s. The kernel's parser is asserted against
     that builder by tests/test_SFlowEmitterRoundtrip.cpp; a second wire format here would be
     a second thing to keep in step with C++.
"""

import json
import os
import shutil
import signal
import struct
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(PROXY_DIR, "mininet"))
sys.path.insert(0, os.path.join(PROXY_DIR, "proxy_agent"))

import psample_sflow_emitter as emitter_module  # noqa: E402
import sflow_emitter  # noqa: E402

FAMILY_ID = 29


# --- an encoder, written here rather than borrowed from the module under test ----------------

def encode_attr(attr_type, payload):
    """One nlattr, little-endian, padded to four bytes. `<` rather than `=` on purpose."""
    length = 4 + len(payload)
    pad = (-length) % 4
    return struct.pack("<HH", length, attr_type) + payload + b"\x00" * pad


def encode_sample(attrs, cmd=0, family_id=FAMILY_ID):
    """A whole PSAMPLE_CMD_SAMPLE netlink message: nlmsghdr + genlmsghdr + attributes."""
    body = struct.pack("<BBH", cmd, 1, 0) + b"".join(
        encode_attr(t, p) for t, p in attrs)
    total = 16 + len(body)
    return struct.pack("<IHHII", total, family_id, 0, 0, 0) + body


def u16(value):
    return struct.pack("<H", value)


def u32(value):
    return struct.pack("<I", value)


def a_sample(iifindex=None, oifindex=None, origsize=1500, group=27, rate=256,
             data=b"\xaa" * 64):
    """The attributes an `action sample` filter's notification carries."""
    attrs = []
    if iifindex is not None:
        attrs.append((emitter_module.PSAMPLE_ATTR_IIFINDEX, u16(iifindex)))
    if oifindex is not None:
        attrs.append((emitter_module.PSAMPLE_ATTR_OIFINDEX, u16(oifindex)))
    if origsize is not None:
        attrs.append((emitter_module.PSAMPLE_ATTR_ORIGSIZE, u32(origsize)))
    if group is not None:
        attrs.append((emitter_module.PSAMPLE_ATTR_SAMPLE_GROUP, u32(group)))
    if rate is not None:
        attrs.append((emitter_module.PSAMPLE_ATTR_SAMPLE_RATE, u32(rate)))
    if data is not None:
        attrs.append((emitter_module.PSAMPLE_ATTR_DATA, data))
    return attrs


MANIFEST = {
    "pid": 4242,
    "rate": 256,
    "trunc": 128,
    "group": 27,
    "ifindex_width": 16,
    "collector": ["127.0.0.1", 6343],
    "sub_agent_id": 1,
    "switches": [
        {"dpid": 1, "name": "s1", "agent_ip": "192.168.123.11",
         "ports": {"1": {"ifname": "s1-eth1", "ifindex": 1011, "key": 1011,
                         "ingress": True, "egress": False},
                   "3": {"ifname": "s1-eth3", "ifindex": 1013, "key": 1013,
                         "ingress": True, "egress": True}}},
        {"dpid": 2, "name": "s2", "agent_ip": "192.168.123.12",
         "ports": {"1": {"ifname": "s2-eth1", "ifindex": 0x10014, "key": 0x0014,
                         "ingress": True, "egress": False}}},
    ],
    "tc_commands": [],
}


class RecordingSocket:
    """A datagram socket that keeps what was sent instead of sending it."""

    def __init__(self):
        self.sent = []

    def sendto(self, payload, address):
        self.sent.append((payload, address))
        return len(payload)

    def close(self):
        pass


class RecordingEmitter:
    """`SFlowEmitter`, reduced to what `run()` calls on it."""

    def __init__(self, accept=True):
        self.calls = []
        self.accept = accept

    def uptime_ms(self):
        return 1000

    def emit(self, dpid, sample, uptime_ms):
        self.calls.append((dpid, sample))
        return self.accept

    def flush(self):
        pass


class FakeNetlinkSocket:
    """One scripted `recv` per `select`, then nothing."""

    def __init__(self, datagrams):
        self.datagrams = list(datagrams)

    def recv(self, _size):
        return self.datagrams.pop(0) if self.datagrams else b""

    def fileno(self):
        return -1

    def close(self):
        pass


class PortMapFixture(unittest.TestCase):

    def setUp(self):
        self.ports = emitter_module.PortMap(json.loads(json.dumps(MANIFEST)))
        self.stats = emitter_module.Stats(started=0.0)

    def decode(self, attrs):
        message = encode_sample(attrs)
        bodies = [body for mtype, _f, _s, body in emitter_module.iter_nlmsg(message)
                  if mtype == FAMILY_ID]
        self.assertEqual(len(bodies), 1)
        return emitter_module.decode_sample(bodies[0])

    def made(self, attrs):
        return emitter_module.sample_for(self.decode(attrs), self.ports, self.stats)


class TheDecoderReadsWhatTheKernelWritesTest(PortMapFixture):

    def test_every_attribute_comes_back(self):
        decoded = self.decode(a_sample(iifindex=1011, origsize=1514, rate=256,
                                       data=b"\x01\x02\x03"))
        self.assertEqual(decoded["iifindex"], 1011)
        self.assertEqual(decoded["origsize"], 1514)
        self.assertEqual(decoded["group"], 27)
        self.assertEqual(decoded["rate"], 256)
        self.assertEqual(decoded["data"], b"\x01\x02\x03")
        self.assertNotIn("oifindex", decoded)

    def test_the_frame_comes_back_whole_and_unpadded(self):
        # The DATA attribute is padded to a four-byte boundary on the wire; its LENGTH is not,
        # and the padding is not part of the frame. An off-by-padding here would put up to
        # three zero bytes into every sFlow raw-header record.
        for size in (1, 2, 3, 4, 63, 64, 65):
            frame = bytes(range(256))[:size] * 1
            decoded = self.decode(a_sample(iifindex=1011, data=frame))
            self.assertEqual(decoded["data"], frame, f"size {size}")

    def test_a_truncated_message_does_not_raise(self):
        # A short read is a fact about a socket, not a reason to end telemetry for the fabric.
        message = encode_sample(a_sample(iifindex=1011))
        for cut in range(16, len(message)):
            list(emitter_module.iter_nlmsg(message[:cut]))

    def test_an_ifindex_the_kernel_wrote_as_four_bytes_is_still_read(self):
        # psample writes these with `nla_put_u16` today; the header gives no width, so the
        # decoder accepts 1/2/4/8 rather than assuming the one that was measured.
        decoded = self.decode([(emitter_module.PSAMPLE_ATTR_IIFINDEX, u32(1011)),
                               (emitter_module.PSAMPLE_ATTR_ORIGSIZE, u32(100)),
                               (emitter_module.PSAMPLE_ATTR_SAMPLE_GROUP, u32(27))])
        self.assertEqual(decoded["iifindex"], 1011)


class DirectionTest(PortMapFixture):

    def test_an_ingress_sample_fills_the_ingress_port_and_leaves_egress_zero(self):
        dpid, sample = self.made(a_sample(iifindex=1013))
        self.assertEqual(dpid, 1)
        self.assertEqual((sample.ingress_port, sample.egress_port), (3, 0))

    def test_an_egress_sample_fills_the_egress_port_and_leaves_ingress_zero(self):
        # 🔴 `ingress_port` MUST BE 0. The kernel banks a sample with inputPort 0 and a
        # non-zero outputPort as egress-only and credits it to the switch->host edge; a port
        # number here would book the same bytes against the host->switch edge instead.
        dpid, sample = self.made(a_sample(oifindex=1013))
        self.assertEqual(dpid, 1)
        self.assertEqual((sample.ingress_port, sample.egress_port), (0, 3))

    def test_a_sample_with_neither_attribute_is_dropped_and_counted(self):
        self.assertIsNone(self.made(a_sample()))
        self.assertEqual(self.stats.dropped_no_direction, 1)

    def test_a_sample_with_both_attributes_is_dropped_and_counted(self):
        # Measured to be impossible; counted rather than guessed at, because a guess would
        # silently double one direction if the kernel ever changed.
        self.assertIsNone(self.made(a_sample(iifindex=1013, oifindex=1013)))
        self.assertEqual(self.stats.dropped_ambiguous_direction, 1)

    def test_an_egress_sample_on_a_port_with_no_egress_filter_is_dropped(self):
        # s1-eth1 is inter-switch: ingress only. An egress sample naming it did not come from
        # this fabric's filters and must not be credited to one.
        self.assertIsNone(self.made(a_sample(oifindex=1011)))
        self.assertEqual(self.stats.dropped_unknown_ifindex, 1)


class TheSixteenBitsTest(PortMapFixture):

    def test_the_map_is_keyed_on_the_low_sixteen_bits(self):
        # s2-eth1's real ifindex is 0x10014; psample reports 0x0014.
        dpid, sample = self.made(a_sample(iifindex=0x0014))
        self.assertEqual((dpid, sample.ingress_port), (2, 1))

    def test_a_reported_index_is_masked_before_it_is_looked_up(self):
        # Belt and braces: if a kernel ever reported the full index, masking it still finds
        # the same port rather than dropping every sample from that switch.
        dpid, sample = self.made(a_sample(iifindex=0x10014 & 0xFFFF))
        self.assertEqual((dpid, sample.ingress_port), (2, 1))

    def test_an_unknown_ifindex_is_dropped_and_counted_not_attributed(self):
        self.assertIsNone(self.made(a_sample(iifindex=4095)))
        self.assertEqual(self.stats.dropped_unknown_ifindex, 1)
        self.assertEqual(self.stats.emitted, 0)


class FrameLengthTest(PortMapFixture):

    def test_the_frame_length_is_origsize_and_not_the_captured_length(self):
        # 🔴 `trunc 128`: DATA is 128 bytes and the packet was 1514. The kernel multiplies
        # frameLength by the sampling rate, so the captured length would under-report this
        # fabric's link usage by ~12x while every graph still drew.
        _dpid, sample = self.made(a_sample(iifindex=1011, origsize=1514, data=b"\x00" * 128))
        self.assertEqual(sample.frame_length, 1514)
        self.assertEqual(len(sample.frame), 128)

    def test_a_sample_with_no_origsize_is_dropped_rather_than_guessed(self):
        self.assertIsNone(self.made(a_sample(iifindex=1011, origsize=None)))
        self.assertEqual(self.stats.dropped_no_origsize, 1)

    def test_the_rate_the_kernel_reports_wins_over_the_manifests(self):
        # The manifest says what was PLANNED; the attribute says what was APPLIED. A filter
        # attached at another rate must not be reported at the planned one.
        _dpid, sample = self.made(a_sample(iifindex=1011, rate=1024))
        self.assertEqual(sample.sampling_rate, 1024)

    def test_the_manifests_rate_is_the_fallback_when_the_kernel_states_none(self):
        _dpid, sample = self.made(a_sample(iifindex=1011, rate=None))
        self.assertEqual(sample.sampling_rate, 256)


class ThePortMapTest(unittest.TestCase):

    def test_it_reads_the_agents_the_rate_and_the_collector(self):
        ports = emitter_module.PortMap(json.loads(json.dumps(MANIFEST)))
        self.assertEqual(ports.switches(), [1, 2])
        self.assertEqual(ports.agents, {1: "192.168.123.11", 2: "192.168.123.12"})
        self.assertEqual(ports.collector, ("127.0.0.1", 6343))
        self.assertEqual(ports.rate, 256)
        self.assertEqual(ports.sub_agent_id, 1)

    def test_only_host_facing_ports_are_in_the_egress_map(self):
        ports = emitter_module.PortMap(json.loads(json.dumps(MANIFEST)))
        self.assertEqual(sorted(ports.ingress.values()), [(1, 1), (1, 3), (2, 1)])
        self.assertEqual(sorted(ports.egress.values()), [(1, 3)])

    def test_a_manifest_that_is_not_there_yet_is_waited_for_and_then_refused(self):
        # The bring-up starts this process and THEN writes the manifest, because the manifest
        # carries this process's pid. Missing after the wait is a refusal: a running emitter
        # with no map would join the group and drop every sample.
        slept = []
        with self.assertRaises(emitter_module.SetupError) as ctx:
            emitter_module.load_manifest("/nonexistent/manifest.json", wait_s=0.0,
                                         sleep=slept.append, exists=lambda _p: False)
        self.assertIn("every sample would be dropped", str(ctx.exception))

    def test_a_manifest_that_appears_during_the_wait_is_read(self):
        tmp = tempfile.mkdtemp(prefix="ndtwin_emitter_manifest_")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, "m.json")
        with open(path, "w") as fh:
            json.dump(MANIFEST, fh)
        seen = []

        def exists(p):
            seen.append(p)
            return len(seen) > 2          # not there for the first two looks
        ports = emitter_module.load_manifest(path, wait_s=5.0, sleep=lambda _s: None,
                                             exists=exists)
        self.assertEqual(ports.switches(), [1, 2])


class TheLoopTest(PortMapFixture):
    """`run()` over scripted datagrams: what is counted, what is emitted, what is dropped."""

    def run_over(self, datagrams, emitter=None, group_filter=True):
        emitter = emitter or RecordingEmitter()
        ports = self.ports
        if not group_filter:
            ports.group = None
        stop = [False]
        clock = [0.0]

        def now():
            clock[0] += 0.4
            return clock[0]
        said = []
        sock = FakeNetlinkSocket(datagrams)
        real_select = emitter_module.select.select
        emitter_module.select.select = lambda r, w, x, t: (
            (r, [], []) if sock.datagrams else (stop.__setitem__(0, True), ([], [], []))[1])
        try:
            emitter_module.run(sock, FAMILY_ID, ports, emitter, self.stats,
                               lambda: stop[0], stats_interval=1.0, report=said.append,
                               now=now)
        finally:
            emitter_module.select.select = real_select
        return emitter, said

    def test_every_sample_in_one_datagram_is_handled(self):
        message = b"".join(encode_sample(a_sample(iifindex=1011)) for _ in range(3))
        emitter, _said = self.run_over([message])
        self.assertEqual(len(emitter.calls), 3)
        self.assertEqual(self.stats.samples, 3)
        self.assertEqual(self.stats.emitted, 3)

    def test_a_sample_from_another_groups_filter_is_dropped_and_counted(self):
        # Somebody else's `action sample` on this machine, reported into a group this fabric
        # did not plan. Its ifindex would not be in the map either -- this is the first of two
        # nets, and the counter says which one caught it.
        emitter, _said = self.run_over([encode_sample(a_sample(iifindex=1011, group=99))])
        self.assertEqual(emitter.calls, [])
        self.assertEqual(self.stats.dropped_other_group, 1)
        self.assertEqual(self.stats.samples, 0)

    def test_a_non_sample_command_is_ignored(self):
        emitter, _said = self.run_over([encode_sample(a_sample(iifindex=1011), cmd=2)])
        self.assertEqual(emitter.calls, [])
        self.assertEqual(self.stats.samples, 0)

    def test_a_message_from_another_family_is_ignored(self):
        emitter, _said = self.run_over(
            [encode_sample(a_sample(iifindex=1011), family_id=FAMILY_ID + 1)])
        self.assertEqual(emitter.calls, [])

    def test_an_emit_the_collector_refused_is_counted_as_such(self):
        emitter, _said = self.run_over([encode_sample(a_sample(iifindex=1011))],
                                       emitter=RecordingEmitter(accept=False))
        self.assertEqual(self.stats.emit_failed, 1)
        self.assertEqual(self.stats.emitted, 0)

    def test_the_statistics_line_is_printed_periodically_and_once_at_the_end(self):
        _emitter, said = self.run_over([encode_sample(a_sample(iifindex=1011))])
        self.assertTrue(said)
        self.assertTrue(all(line.startswith("psample_sflow_emitter: ") for line in said))
        self.assertIn("samples=1", said[-1])
        self.assertIn("emitted=1", said[-1])
        self.assertIn("s1:1", said[-1])


class TheStatisticsLineTest(unittest.TestCase):

    def test_it_is_one_line_with_every_counter_in_a_fixed_order(self):
        # The format `ndt status` and an operator's `grep` both read. `k=v` throughout and a
        # stable order, so a new counter cannot shift a column somebody is cutting on.
        stats = emitter_module.Stats(started=0.0)
        stats.samples = 5
        stats.emitted = 4
        stats.dropped_unknown_ifindex = 1
        stats.credit("s1")
        stats.credit("s2")
        stats.credit("s1")
        line = stats.line(now=12.3)
        self.assertEqual(
            line,
            "psample_sflow_emitter: samples=5 emitted=4 dropped_unknown_ifindex=1 "
            "dropped_no_direction=0 dropped_ambiguous_direction=0 dropped_no_origsize=0 "
            "dropped_other_group=0 dropped_decode_error=0 emit_failed=0 enobufs=0 "
            "per_switch=s1:2,s2:1 elapsed=12.3s")
        self.assertEqual(len(line.splitlines()), 1)

    def test_every_drop_has_a_name_rather_than_being_a_gap_in_a_graph(self):
        self.assertEqual(
            [f for f in emitter_module.Stats.FIELDS if f.startswith("dropped_")],
            ["dropped_unknown_ifindex", "dropped_no_direction", "dropped_ambiguous_direction",
             "dropped_no_origsize", "dropped_other_group", "dropped_decode_error"])


class StoppingIsAFlagAndNotARaiseTest(unittest.TestCase):
    """TICKET-P3 section 9 ruling 19(1): SIGHUP is how this process actually dies."""

    def test_all_three_stop_signals_are_installed(self):
        # 🔴 SIGHUP ABOVE ALL. `ndtwin-lab topo-stop` ends with `kill-session`, which SIGHUPs
        # the tmux pane's process group -- and this process is in it, because the topology
        # script started it. With the default disposition it died on the spot, mid-datagram,
        # with no last statistics line, which is half of why the 2026-09-19 live runs ended
        # with a manifest naming a pid that was gone.
        installed = []
        stopping = []
        names = emitter_module.install_stop_handlers(
            stopping, install=lambda number, handler: installed.append((number, handler)))
        self.assertEqual(names, ["SIGTERM", "SIGINT", "SIGHUP"])
        self.assertEqual([number for number, _h in installed],
                         [signal.SIGTERM, signal.SIGINT, signal.SIGHUP])

    def test_the_handler_sets_the_flag_rather_than_raising(self):
        # A handler that raised would unwind out of `sock.recv` and lose whatever was buffered.
        # Teardown SIGTERMs this process on purpose: that path is the normal one.
        installed = []
        stopping = []
        emitter_module.install_stop_handlers(
            stopping, install=lambda number, handler: installed.append(handler))
        self.assertEqual(stopping, [])
        installed[0](signal.SIGTERM, None)
        self.assertEqual(stopping, [True])

    def test_the_loop_stops_on_that_flag_and_prints_a_last_line(self):
        stopping = []
        stats = emitter_module.Stats(started=0.0)
        said = []
        emitter_module.run(FakeNetlinkSocket([]), FAMILY_ID,
                           emitter_module.PortMap(json.loads(json.dumps(MANIFEST))),
                           RecordingEmitter(), stats, lambda: True,
                           stats_interval=1000.0, report=said.append, now=lambda: 0.0)
        self.assertEqual(len(said), 1)
        self.assertTrue(said[0].startswith("psample_sflow_emitter: samples=0"))


class TheBytesAreTheProxysBuilderTest(PortMapFixture):
    """The datagram on the wire is `sflow_emitter.build_datagram`'s, byte for byte."""

    def test_an_ingress_sample_reaches_the_collector_as_the_builder_writes_it(self):
        _dpid, sample = self.made(a_sample(iifindex=1013, origsize=1514, data=b"\x5a" * 128))
        sock = RecordingSocket()
        emitter = sflow_emitter.SFlowEmitter(collector=self.ports.collector, sock=sock)
        emitter = emitter_module.build_emitter(self.ports, emitter=emitter)
        self.assertTrue(emitter.emit(1, sample, 123456))

        # 🔴 The expectation is built from a FRESH agent with the same inputs, not read back
        # from the emitter: `build_flow_sample` advances a sequence number and a sample pool,
        # so an expectation taken from the same object would be the answer comparing itself.
        expected = sflow_emitter.build_datagram(
            [sample], sflow_emitter.SwitchAgent("192.168.123.11", sub_agent_id=1), 123456)
        self.assertEqual(sock.sent, [(expected, ("127.0.0.1", 6343))])

    def test_this_path_says_it_is_sub_agent_one(self):
        # The proxy's cooperative emitter is sub-agent 0. On a mixed fabric both are in play,
        # and a datagram has to be able to say which produced it.
        emitter = emitter_module.build_emitter(
            self.ports, emitter=sflow_emitter.SFlowEmitter(sock=RecordingSocket()))
        self.assertEqual(emitter.agent_for(1).sub_agent_id, 1)
        self.assertEqual(emitter.agent_for(2).sub_agent_id, 1)

    def test_every_switch_in_the_manifest_gets_its_own_agent_address(self):
        # One shared address would collapse ten switches into one node's worth of statistics.
        emitter = emitter_module.build_emitter(
            self.ports, emitter=sflow_emitter.SFlowEmitter(sock=RecordingSocket()))
        self.assertEqual(emitter.agent_for(1).agent_ip, "192.168.123.11")
        self.assertEqual(emitter.agent_for(2).agent_ip, "192.168.123.12")

    def test_an_egress_sample_carries_ingress_port_zero_onto_the_wire(self):
        # The section 2.2 contract, asserted where it is actually spent: in the bytes the
        # kernel parses, not only in the dataclass.
        _dpid, sample = self.made(a_sample(oifindex=1013, origsize=64, data=b"\xff" * 64))
        expected = sflow_emitter.build_datagram(
            [sample], sflow_emitter.SwitchAgent("192.168.123.11", sub_agent_id=1), 1)
        # flow sample body: sequence, source id, rate, pool, drops, input, output, records.
        # The two ports are the sixth and seventh words after the 28-byte datagram header and
        # the 8-byte sample type/length pair.
        offset = 28 + 8 + 5 * 4
        input_port, output_port = struct.unpack_from(">II", expected, offset)
        self.assertEqual((input_port, output_port), (0, 3))


if __name__ == "__main__":
    unittest.main()

# [Co-developed with claude code -- Adam]
