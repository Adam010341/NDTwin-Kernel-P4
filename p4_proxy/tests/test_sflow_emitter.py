"""
Tests for the synthesised sFlow emitter.

[Co-developed with claude code -- Adam]

The emitter's only real requirement is that the kernel's parser understands its output, and
that parser is hand-written with fixed word offsets rather than a general sFlow library. So
"valid sFlow" is not the bar: the datagram has to have the *same shape* OVS produces.

These tests therefore compare against real captured OVS datagrams in tests/fixtures/ field by
field, rather than against the emitter's own idea of correct. The C++ side closes the loop --
tests/test_sflow_emitter_roundtrip.cpp feeds emitter output through the actual parser and
checks the recovered 5-tuple -- but that is expensive to iterate on, so the byte-level
comparison lives here where it is fast.

Run with:  python3 -m pytest p4_proxy/tests/test_sflow_emitter.py
       or:  python3 p4_proxy/tests/test_sflow_emitter.py
"""

from __future__ import annotations

import os
import socket
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent.sflow_emitter import (  # noqa: E402
    DEFAULT_MAX_HEADER_BYTES,
    RECORD_FORMAT_EXTENDED_SWITCH,
    RECORD_FORMAT_RAW_HEADER,
    SAMPLE_TYPE_FLOW,
    SFLOW_VERSION,
    SFlowEmitter,
    SampledPacket,
    SwitchAgent,
    build_datagram,
    build_flow_sample,
    PKTIN_META_EGRESS_PORT,
    PKTIN_META_FRAME_LENGTH,
    PKTIN_META_INGRESS_PORT,
    PKTIN_META_REASON,
    PKTIN_META_SAMPLING_RATE,
    PKTIN_REASON_PACKET_IN,
    PKTIN_REASON_SAMPLE,
    metadata_by_id,
    load_switch_agent_ips,
    sample_from_packet_in,
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE_DIR = os.path.join(REPO_ROOT, "tests", "fixtures")


def words(data: bytes) -> list[int]:
    return [struct.unpack(">I", data[i * 4:i * 4 + 4])[0] for i in range(len(data) // 4)]


def load_fixture(name: str) -> bytes:
    with open(os.path.join(FIXTURE_DIR, name), "rb") as fh:
        return fh.read()


def any_tcp_fixture() -> bytes:
    names = sorted(n for n in os.listdir(FIXTURE_DIR) if n.startswith("tcp_"))
    if not names:
        raise unittest.SkipTest("no tcp_*.bin fixtures")
    return load_fixture(names[0])


def build_ethernet_ipv4_tcp(src_ip: str = "10.0.0.1",
                            dst_ip: str = "10.0.0.2",
                            src_port: int = 5001,
                            dst_port: int = 40000,
                            payload_len: int = 20) -> bytes:
    """A minimal but structurally valid Ethernet/IPv4/TCP frame."""
    eth = (bytes.fromhex("000000000002") + bytes.fromhex("000000000001")
           + struct.pack(">H", 0x0800))
    payload = b"\x00" * payload_len
    total_len = 20 + 20 + payload_len
    ip = struct.pack(">BBHHHBBH", 0x45, 0, total_len, 1, 0, 64, 6, 0) \
        + socket.inet_aton(src_ip) + socket.inet_aton(dst_ip)
    tcp = struct.pack(">HHIIBBHHH", src_port, dst_port, 0, 0, 0x50, 0x10, 0, 0, 0)
    return eth + ip + tcp + payload


def a_sample(frame: bytes | None = None, **kwargs) -> SampledPacket:
    frame = frame if frame is not None else build_ethernet_ipv4_tcp()
    defaults = dict(ingress_port=1, egress_port=2, frame_length=len(frame),
                    sampling_rate=256, frame=frame)
    defaults.update(kwargs)
    return SampledPacket(**defaults)


class DatagramHeaderTest(unittest.TestCase):
    """The datagram header, compared field by field against a real OVS capture."""

    def setUp(self):
        self.real = words(any_tcp_fixture())
        agent = SwitchAgent("192.168.123.11")
        self.mine = words(build_datagram([a_sample()], agent, uptime_ms=125000))

    def test_version_and_address_type_match_ovs(self):
        self.assertEqual(self.mine[0], SFLOW_VERSION)
        self.assertEqual(self.mine[0], self.real[0])
        self.assertEqual(self.mine[1], self.real[1], "agent address type must be 1 (IPv4)")

    def test_agent_ip_is_raw_network_order(self):
        # The parser reads word 2 without ntohl and hands it straight to ipToString, so the
        # byte order here is not cosmetic.
        self.assertEqual(self.mine[2], struct.unpack(">I", socket.inet_aton("192.168.123.11"))[0])

    def test_sample_count_word_is_where_ovs_puts_it(self):
        self.assertEqual(self.mine[6], 1)
        # The parser hardcodes index 7 as the first sample, so the header must be 7 words.
        self.assertEqual(self.mine[7], SAMPLE_TYPE_FLOW)
        self.assertEqual(self.real[7], SAMPLE_TYPE_FLOW)


class FlowSampleLayoutTest(unittest.TestCase):
    """
    The layout the kernel's fixed offsets depend on.

    Each assertion here corresponds to a specific read in FlowLinkUsageCollector::handlePacket;
    getting any of them wrong yields plausible-looking but wrong telemetry rather than an error.
    """

    def setUp(self):
        self.frame = build_ethernet_ipv4_tcp()
        self.agent = SwitchAgent("192.168.123.11")
        self.datagram = build_datagram([a_sample(self.frame)], self.agent, 125000)
        self.w = words(self.datagram)
        self.real = words(any_tcp_fixture())

    def test_sample_length_counts_the_body_only(self):
        # w[8] is the sample length in bytes, measured from w[9] to the end of the sample.
        declared = self.w[8]
        actual = (len(self.datagram) - 9 * 4)
        self.assertEqual(declared, actual,
                         "sample length must cover words 9..end, as OVS does")

    def test_sampling_rate_is_at_the_offset_the_parser_reads(self):
        # samplingRate = data[index + 4], index = 7
        self.assertEqual(self.w[11], 256)
        self.assertEqual(self.real[11], 256, "the capture was taken at sampling=256")

    def test_input_interface_is_at_the_offset_the_parser_reads(self):
        # inputPort = data[index + 7]
        self.assertEqual(self.w[14], 1)

    def test_has_exactly_two_flow_records_like_ovs(self):
        # flow record count at index + 9
        self.assertEqual(self.w[16], 2)
        self.assertEqual(self.real[16], 2)

    def test_first_record_is_extended_switch_with_sixteen_bytes(self):
        # This is the load-bearing one. The parser reads record[0]'s length at index + 11 and
        # skips that many words before reading anything about the packet. A single-record
        # sample would send it six words into the Ethernet frame.
        self.assertEqual(self.w[17], RECORD_FORMAT_EXTENDED_SWITCH)
        self.assertEqual(self.w[18], 16)
        self.assertEqual(self.real[17], RECORD_FORMAT_EXTENDED_SWITCH)
        self.assertEqual(self.real[18], 16)

    def test_second_record_is_the_raw_header(self):
        self.assertEqual(self.w[23], RECORD_FORMAT_RAW_HEADER)
        self.assertEqual(self.real[23], RECORD_FORMAT_RAW_HEADER)

    def test_frame_length_and_ethertype_land_where_the_parser_looks(self):
        # After skipping record[0], the parser's index becomes 13, so:
        #   frameLength = w[13 + 13] = w[26]
        #   etherType   = w[13 + 19] >> 16 = w[32] >> 16
        #   protocol    = w[13 + 21] & 0xFF = w[34] & 0xFF
        self.assertEqual(self.w[26], len(self.frame), "frame length at the parser's offset")
        self.assertEqual((self.w[32] >> 16) & 0xFFFF, 0x0800, "ethertype at the parser's offset")
        self.assertEqual(self.w[34] & 0xFF, 6, "protocol (TCP) at the parser's offset")

    def test_ethernet_frame_starts_at_word_29(self):
        self.assertEqual(self.datagram[29 * 4:29 * 4 + 6], b"\x00\x00\x00\x00\x00\x02")

    def test_word_offsets_of_every_field_match_the_real_capture(self):
        # A structural diff: for every field the parser reads, our datagram and a real one must
        # agree on *where* it is. Values differ, positions must not.
        for offset, label in [(7, "sample type"), (16, "record count"),
                              (17, "record0 format"), (18, "record0 length"),
                              (23, "record1 format"), (25, "header protocol")]:
            self.assertEqual(self.w[offset], self.real[offset],
                             f"{label} differs at word {offset}")


class TruncationTest(unittest.TestCase):
    def test_long_frames_are_truncated_but_report_the_original_length(self):
        # A collector estimates bytes-on-the-wire from frame_length, so truncating the captured
        # header must not change the reported length -- otherwise every rate is understated.
        frame = build_ethernet_ipv4_tcp(payload_len=2000)
        sample = a_sample(frame)
        w = words(build_datagram([sample], SwitchAgent("192.168.123.11"), 0))

        self.assertEqual(w[26], len(frame), "original frame length must be preserved")
        self.assertEqual(w[28], DEFAULT_MAX_HEADER_BYTES, "captured length is the truncated one")

    def test_frames_are_padded_to_a_word_boundary(self):
        # 4-byte alignment is a hard requirement: the parser rejects any datagram whose length
        # is not a multiple of 4.
        for payload_len in range(0, 8):
            frame = build_ethernet_ipv4_tcp(payload_len=payload_len)
            datagram = build_datagram([a_sample(frame)], SwitchAgent("192.168.123.11"), 0)
            self.assertEqual(len(datagram) % 4, 0,
                             f"unaligned datagram for payload_len={payload_len}")

    def test_captured_length_is_the_unpadded_length(self):
        # header_length reports real bytes, not padded bytes, or the parser would read padding
        # as packet content.
        frame = build_ethernet_ipv4_tcp(payload_len=1)  # 55 bytes: not a multiple of 4
        w = words(build_datagram([a_sample(frame)], SwitchAgent("192.168.123.11"), 0))
        self.assertEqual(w[28], len(frame))
        self.assertNotEqual(len(frame) % 4, 0, "test frame should be unaligned to be meaningful")


class SequenceAndPoolTest(unittest.TestCase):
    def test_datagram_and_sample_sequences_increment(self):
        agent = SwitchAgent("192.168.123.11")
        first = words(build_datagram([a_sample()], agent, 0))
        second = words(build_datagram([a_sample()], agent, 0))

        self.assertEqual(first[4], 1)
        self.assertEqual(second[4], 2, "datagram sequence must be monotonic")
        self.assertEqual(first[9], 1)
        self.assertEqual(second[9], 2, "sample sequence must be monotonic")

    def test_sample_pool_advances_by_the_sampling_rate(self):
        # The pool is how a collector estimates the true packet count from a 1-in-N sample; a
        # static pool would make the estimate meaningless.
        agent = SwitchAgent("192.168.123.11")
        first = words(build_datagram([a_sample()], agent, 0))
        second = words(build_datagram([a_sample()], agent, 0))

        self.assertEqual(first[12], 256)
        self.assertEqual(second[12], 512)

    def test_counters_wrap_at_32_bits_instead_of_raising(self):
        # struct.pack(">I", ...) rejects values >= 2**32. sample_pool in particular climbs by
        # the sampling rate on every sample, so a busy switch reaches that ceiling in hours --
        # these must wrap like real 32-bit counters instead of raising and killing telemetry
        # from that switch permanently.
        agent = SwitchAgent("192.168.123.11")
        agent.datagram_sequence = 0xFFFFFFFF
        agent.sample_sequence = 0xFFFFFFFF
        agent.sample_pool = 0xFFFFFFFF

        w = words(build_datagram([a_sample()], agent, 0))

        self.assertEqual(w[4], 0, "datagram sequence must wrap, not raise")
        self.assertEqual(w[9], 0, "sample sequence must wrap, not raise")
        self.assertEqual(w[12], 255, "pool must wrap, not raise")

    def test_each_switch_keeps_its_own_agent_state(self):
        # The kernel keys telemetry on AgentKey{agentIP, port}; sharing one agent across
        # switches would collapse ten switches into one node's statistics.
        emitter = SFlowEmitter(sock=_FakeSocket())
        emitter.register_switch(1, "192.168.123.11")
        emitter.register_switch(2, "192.168.123.12")

        self.assertIsNot(emitter.agent_for(1), emitter.agent_for(2))
        self.assertEqual(emitter.agent_for(1).agent_ip, "192.168.123.11")
        self.assertEqual(emitter.agent_for(2).agent_ip, "192.168.123.12")


class MultiSampleTest(unittest.TestCase):
    def test_several_samples_share_one_datagram(self):
        agent = SwitchAgent("192.168.123.11")
        datagram = build_datagram([a_sample(), a_sample(), a_sample()], agent, 0)
        w = words(datagram)
        self.assertEqual(w[6], 3, "sample count must match the number emitted")

        # Walk them the way the parser does, and confirm we land exactly at the end.
        index = 7
        for _ in range(3):
            self.assertEqual(w[index], SAMPLE_TYPE_FLOW)
            index += w[index + 1] // 4 + 2
        self.assertEqual(index, len(w),
                         "sample lengths must chain exactly to the end of the datagram")

    def test_empty_sample_list_is_rejected(self):
        with self.assertRaises(ValueError):
            build_datagram([], SwitchAgent("192.168.123.11"), 0)


class FakeMetadata:
    def __init__(self, metadata_id: int, value: bytes):
        self.metadata_id = metadata_id
        self.value = value


class FakePacketIn:
    """
    Stands in for a P4Runtime PacketIn.

    Deliberately encodes values the way P4Runtime does -- canonical byte strings with leading
    zero bytes stripped -- because that variable width is the thing most likely to be
    mishandled, and a fake that always used a fixed width would hide it.
    """

    def __init__(self, payload: bytes, **fields: int):
        self.payload = payload
        self.metadata = [FakeMetadata(mid, self._canonical(v)) for mid, v in fields.values()]

    @staticmethod
    def _canonical(value: int) -> bytes:
        if value == 0:
            return b"\x00"
        width = (value.bit_length() + 7) // 8
        return value.to_bytes(width, "big")


def a_packet_in(payload: bytes = b"FRAME",
                reason: int = PKTIN_REASON_SAMPLE,
                ingress: int = 3,
                egress: int = 7,
                frame_length: int = 1514,
                sampling_rate: int = 256,
                omit: tuple[int, ...] = ()) -> FakePacketIn:
    fields = {
        "reason": (PKTIN_META_REASON, reason),
        "ingress": (PKTIN_META_INGRESS_PORT, ingress),
        "egress": (PKTIN_META_EGRESS_PORT, egress),
        "frame_length": (PKTIN_META_FRAME_LENGTH, frame_length),
        "sampling_rate": (PKTIN_META_SAMPLING_RATE, sampling_rate),
    }
    fields = {k: v for k, v in fields.items() if v[0] not in omit}
    return FakePacketIn(payload, **fields)


class PacketInDecodingTest(unittest.TestCase):
    """
    Turning a CPU packet into a SampledPacket.

    The fields arrive as typed P4Runtime metadata rather than as bytes in the payload, because
    PI matches @controller_header by name and only knows "packet_in"/"packet_out" -- a separate
    "sample" header is compiled into the p4info and then silently ignored, so this is the only
    working shape. See the header comment in ndtwin_switch.p4.
    """

    def test_reads_every_field_from_metadata(self):
        sample = sample_from_packet_in(a_packet_in())
        self.assertIsNotNone(sample)
        self.assertEqual(sample.ingress_port, 3)
        self.assertEqual(sample.egress_port, 7)
        self.assertEqual(sample.frame_length, 1514)
        self.assertEqual(sample.sampling_rate, 256)
        self.assertEqual(sample.frame, b"FRAME")

    def test_a_genuine_packet_in_is_not_a_sample(self):
        # LLDP beacons and unmatched traffic come up the same channel and must reach the
        # discovery path instead. Returning None rather than raising is what lets the caller
        # tell them apart.
        self.assertIsNone(sample_from_packet_in(a_packet_in(reason=PKTIN_REASON_PACKET_IN)))

    def test_a_missing_reason_is_treated_as_a_packet_in(self):
        # Defaulting the other way would feed arbitrary discovery traffic into the telemetry
        # path, inventing flows the network does not have.
        self.assertIsNone(sample_from_packet_in(a_packet_in(omit=(PKTIN_META_REASON,))))

    def test_handles_the_widest_values(self):
        # bit<9> ports: 511 is the maximum; frame_length and sampling_rate are bit<16>.
        sample = sample_from_packet_in(
            a_packet_in(ingress=511, egress=511, frame_length=65535, sampling_rate=65535))
        self.assertEqual(sample.ingress_port, 511)
        self.assertEqual(sample.egress_port, 511)
        self.assertEqual(sample.frame_length, 65535)
        self.assertEqual(sample.sampling_rate, 65535)

    def test_zero_valued_fields_survive_canonical_encoding(self):
        # P4Runtime strips leading zeros, so zero encodes as a single 0x00 byte rather than the
        # field's declared width. Port 0 is a legitimate value.
        sample = sample_from_packet_in(a_packet_in(ingress=0, egress=0))
        self.assertEqual(sample.ingress_port, 0)
        self.assertEqual(sample.egress_port, 0)

    def test_a_zero_sampling_rate_is_rejected(self):
        # The kernel multiplies by the sampling rate, so zero would report zero throughput for
        # real traffic. Dropping the sample is the lesser failure, and a zero rate can only mean
        # the switch is running a pipeline that does not match this p4info.
        self.assertIsNone(sample_from_packet_in(a_packet_in(sampling_rate=0)))
        self.assertIsNone(sample_from_packet_in(a_packet_in(omit=(PKTIN_META_SAMPLING_RATE,))))

    def test_an_empty_frame_is_rejected(self):
        self.assertIsNone(sample_from_packet_in(a_packet_in(payload=b"")))

    def test_a_missing_frame_length_falls_back_to_the_frame_size(self):
        # Better to under-report one sample than to scale it to zero bytes.
        sample = sample_from_packet_in(
            a_packet_in(payload=b"0123456789", omit=(PKTIN_META_FRAME_LENGTH,)))
        self.assertEqual(sample.frame_length, 10)

    def test_metadata_by_id_collapses_the_list(self):
        self.assertEqual(metadata_by_id(a_packet_in(reason=1, ingress=2, egress=3,
                                                    frame_length=4, sampling_rate=5)),
                         {PKTIN_META_REASON: 1, PKTIN_META_INGRESS_PORT: 2,
                          PKTIN_META_EGRESS_PORT: 3, PKTIN_META_FRAME_LENGTH: 4,
                          PKTIN_META_SAMPLING_RATE: 5})


class P4InfoAgreementTest(unittest.TestCase):
    """
    The metadata ids are positional: reordering packet_in_header_t's fields renumbers them, and
    nothing at runtime would complain -- the proxy would just read the wrong field. This pins
    the constants to the p4info the switches are actually loaded with.
    """

    P4INFO = os.path.join(REPO_ROOT, "p4_proxy", "p4_src", "build", "ndtwin_switch.p4info.txt")

    def test_constants_match_the_generated_p4info(self):
        if not os.path.exists(self.P4INFO):
            self.skipTest("p4info not built; run tools/test_workflow/l0_build_check.sh p4")

        import re
        with open(self.P4INFO) as fh:
            text = fh.read()
        block = None
        for m in re.finditer(r"controller_packet_metadata \{(.*?)\n\}", text, re.S):
            if 'name: "packet_in"' in m.group(1):
                block = m.group(1)
        self.assertIsNotNone(block, "no packet_in controller_packet_metadata in the p4info")

        ids = {name: int(i) for i, name in
               re.findall(r'id: (\d+)\s+name: "([^"]+)"\s+bitwidth: \d+', block)}

        self.assertEqual(ids.get("reason"), PKTIN_META_REASON)
        self.assertEqual(ids.get("ingress_port"), PKTIN_META_INGRESS_PORT)
        self.assertEqual(ids.get("egress_port"), PKTIN_META_EGRESS_PORT)
        self.assertEqual(ids.get("frame_length"), PKTIN_META_FRAME_LENGTH)
        self.assertEqual(ids.get("sampling_rate"), PKTIN_META_SAMPLING_RATE)

    def test_there_is_no_separate_sample_controller_header(self):
        # A third @controller_header would compile fine and be silently ignored by PI, so its
        # absence is a property worth asserting rather than remembering.
        if not os.path.exists(self.P4INFO):
            self.skipTest("p4info not built")
        with open(self.P4INFO) as fh:
            text = fh.read()
        import re
        names = re.findall(r'controller_packet_metadata \{\s+preamble \{\s+id: \d+\s+name: "([^"]+)"',
                           text)
        self.assertEqual(sorted(names), ["packet_in", "packet_out"])


class _FakeSocket:
    """Captures sendto instead of touching the network."""

    def __init__(self, fail: bool = False):
        self.sent: list[tuple[bytes, tuple[str, int]]] = []
        self.fail = fail
        self.closed = False

    def sendto(self, data, addr):
        if self.fail:
            raise OSError("simulated send failure")
        self.sent.append((data, addr))
        return len(data)

    def close(self):
        self.closed = True


class EmitterBehaviourTest(unittest.TestCase):
    def test_emits_to_the_collector_and_counts_it(self):
        sock = _FakeSocket()
        emitter = SFlowEmitter(collector=("127.0.0.1", 6343), sock=sock)
        emitter.register_switch(1, "192.168.123.11")

        self.assertTrue(emitter.emit(1, a_sample(), uptime_ms=1000))
        self.assertEqual(len(sock.sent), 1)
        self.assertEqual(sock.sent[0][1], ("127.0.0.1", 6343))
        self.assertEqual(emitter.datagrams_sent, 1)

    def test_unregistered_switch_is_refused_rather_than_guessed(self):
        # Emitting under the wrong agent address would attribute telemetry to another switch,
        # which is worse than emitting nothing.
        sock = _FakeSocket()
        emitter = SFlowEmitter(sock=sock)
        self.assertFalse(emitter.emit(99, a_sample(), uptime_ms=0))
        self.assertEqual(sock.sent, [])

    def test_send_failure_is_reported_not_raised(self):
        # This runs on the gRPC receive thread; an exception there kills the stream and ends
        # telemetry for that switch silently.
        emitter = SFlowEmitter(sock=_FakeSocket(fail=True))
        emitter.register_switch(1, "192.168.123.11")

        self.assertFalse(emitter.emit(1, a_sample(), uptime_ms=0))
        self.assertEqual(emitter.send_errors, 1)
        self.assertEqual(emitter.datagrams_sent, 0)

    def test_malformed_agent_ip_is_reported_not_raised(self):
        # socket.inet_aton raises OSError (not ValueError/struct.error) for a non-IPv4 string.
        # That call happens inside build_datagram, called from emit() on the gRPC receive
        # thread -- an uncaught exception there would kill the thread and end telemetry for
        # the whole switch, not just this one datagram.
        emitter = SFlowEmitter(sock=_FakeSocket())
        emitter.register_switch(1, "not-an-ip-address")

        self.assertFalse(emitter.emit(1, a_sample(), uptime_ms=0))

    def test_emitted_bytes_are_a_parseable_datagram(self):
        sock = _FakeSocket()
        emitter = SFlowEmitter(sock=sock)
        emitter.register_switch(1, "192.168.123.11")
        emitter.emit(1, a_sample(), uptime_ms=1000)

        data = sock.sent[0][0]
        self.assertEqual(len(data) % 4, 0)
        self.assertGreaterEqual(len(data), 28, "shorter than the parser's minimum")
        self.assertEqual(words(data)[0], SFLOW_VERSION)


class RealFixtureComparisonTest(unittest.TestCase):
    """
    Re-emits the packet from a real OVS sample and compares the two datagrams structurally.

    This is the strongest check available in Python: it takes a frame a switch really sent,
    wraps it with the emitter, and requires every field the parser reads to sit at the same
    word offset with an equivalent value.
    """

    def test_reemitting_a_captured_frame_reproduces_the_layout(self):
        real = any_tcp_fixture()
        rw = words(real)

        # Extract the frame from the real sample: record[0] is 16 bytes, then record[1]'s
        # 4-word preamble, so the frame starts at word 29.
        captured_len = rw[28]
        frame = real[29 * 4:29 * 4 + captured_len]
        original_len = rw[26]
        ingress = rw[14]

        agent = SwitchAgent("192.168.123.11")
        mine = build_datagram(
            [SampledPacket(ingress_port=ingress, egress_port=2,
                           frame_length=original_len, sampling_rate=rw[11], frame=frame)],
            agent, uptime_ms=rw[5])
        mw = words(mine)

        # Structural equivalence for every field the parser touches.
        self.assertEqual(mw[0], rw[0], "version")
        self.assertEqual(mw[1], rw[1], "address type")
        self.assertEqual(mw[6], rw[6], "sample count (both single-sample)")
        self.assertEqual(mw[7], rw[7], "sample type")
        self.assertEqual(mw[11], rw[11], "sampling rate")
        self.assertEqual(mw[14], rw[14], "input interface")
        self.assertEqual(mw[16], rw[16], "flow record count")
        self.assertEqual(mw[17], rw[17], "record0 format")
        self.assertEqual(mw[18], rw[18], "record0 length")
        self.assertEqual(mw[23], rw[23], "record1 format")
        self.assertEqual(mw[25], rw[25], "header protocol")
        self.assertEqual(mw[26], rw[26], "original frame length")
        self.assertEqual(mw[28], rw[28], "captured header length")

        # And the frame itself must be byte-identical, since that is what carries the 5-tuple.
        self.assertEqual(mine[29 * 4:29 * 4 + captured_len],
                         real[29 * 4:29 * 4 + captured_len],
                         "the re-emitted frame differs from the captured one")

        # Same total size follows from all of the above; assert it so a padding mistake shows up
        # as one clear failure rather than several.
        self.assertEqual(len(mine), len(real))


class CommittedFixtureTest(unittest.TestCase):
    """
    Guards the fixtures the C++ round-trip test depends on.

    tests/test_SFlowEmitterRoundtrip.cpp parses committed bytes rather than invoking Python, so
    the C++ suite needs no interpreter. The cost is that changing the emitter without
    regenerating leaves that test validating a layout the emitter no longer produces -- it would
    keep passing while the real thing was broken. This fails instead.

    [Co-developed with claude code -- Adam]
    Regeneration goes through gen.build_fixture rather than being re-implemented here. It used
    to be re-implemented -- a single-sample build_datagram call over a 4-tuple -- which is what
    kept emitted_multi.bin outside the guard: the generator built it in main() because this
    loop could not express it. Calling the generator's own builder means a fixture that this
    test does not cover is now a fixture the generator does not write either.
    """

    def test_emitter_still_produces_the_committed_bytes(self):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import generate_emitted_fixtures as gen

        for name, samples in gen.FIXTURES:
            with self.subTest(fixture=name):
                path = os.path.join(FIXTURE_DIR, name)
                if not os.path.exists(path):
                    self.fail(f"{name} missing; run generate_emitted_fixtures.py")

                regenerated = gen.build_fixture(samples)

                with open(path, "rb") as fh:
                    committed = fh.read()

                self.assertEqual(
                    regenerated, committed,
                    f"{name} is stale: the emitter's output changed. Re-run\n"
                    f"  python3 p4_proxy/tests/generate_emitted_fixtures.py\n"
                    f"and re-run the C++ round-trip test, which parses these bytes.")

    def test_every_committed_emitted_fixture_is_in_the_guarded_list(self):
        # [Co-developed with claude code -- Adam]
        # The guard above can only protect what FIXTURES names. This is the other half: an
        # emitted_*.bin on disk that nothing in FIXTURES accounts for is a fixture with no
        # drift guard -- exactly what emitted_multi.bin was. Reads the directory rather than a
        # second hand-maintained list, so it cannot fall out of date the same way.
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import generate_emitted_fixtures as gen

        guarded = {name for name, _ in gen.FIXTURES}
        on_disk = {f for f in os.listdir(FIXTURE_DIR)
                   if f.startswith("emitted_") and f.endswith(".bin")}

        self.assertEqual(
            on_disk - guarded, set(),
            "these committed fixtures are not in generate_emitted_fixtures.FIXTURES, so "
            "nothing notices when the emitter stops producing them")


class AgentIpLoadingTest(unittest.TestCase):
    """
    Reading dpid -> agent IP from the kernel's own topology file.

    Wrong addresses here do not fail: the kernel receives the datagrams and matches them against
    no edge, so the twin is simply empty. That makes it worth pinning against the real file.
    """

    import json as _json
    import tempfile as _tempfile

    REAL_TOPO = os.path.join(REPO_ROOT, "setting",
                             "StaticNetworkTopologyP4_10Switches_4Hosts.json")

    def write_topo(self, nodes):
        fh = self._tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        self._json.dump({"nodes": nodes}, fh)
        fh.close()
        self.addCleanup(os.unlink, fh.name)
        return fh.name

    def test_reads_the_shipped_p4_topology(self):
        if not os.path.exists(self.REAL_TOPO):
            self.skipTest("P4 topology file not present")
        agents = load_switch_agent_ips(self.REAL_TOPO)
        self.assertEqual(len(agents), 10, "expected the 10 bmv2 switches")
        self.assertEqual(agents[1], "192.168.123.11")
        self.assertEqual(agents[10], "192.168.123.20")

    def test_hosts_are_excluded(self):
        # Hosts carry vertex_type 1, dpid 0 and a 10.0.0.x address. Including them registered a
        # bogus agent and collapsed all four onto dpid 0, so only the last one survived.
        agents = load_switch_agent_ips(self.write_topo([
            {"vertex_type": 0, "dpid": 1, "ip": ["192.168.123.11"]},
            {"vertex_type": 1, "dpid": 0, "ip": ["10.0.0.1"]},
            {"vertex_type": 1, "dpid": 0, "ip": ["10.0.0.2"]},
        ]))
        self.assertEqual(agents, {1: "192.168.123.11"})

    def test_a_switch_with_no_address_is_skipped(self):
        agents = load_switch_agent_ips(self.write_topo([
            {"vertex_type": 0, "dpid": 1, "ip": []},
            {"vertex_type": 0, "dpid": 2},
            {"vertex_type": 0, "dpid": 3, "ip": ["192.168.123.13"]},
        ]))
        self.assertEqual(agents, {3: "192.168.123.13"})

    def test_the_first_address_is_the_agent_address(self):
        agents = load_switch_agent_ips(self.write_topo([
            {"vertex_type": 0, "dpid": 1, "ip": ["192.168.123.11", "10.99.0.1"]},
        ]))
        self.assertEqual(agents[1], "192.168.123.11")

    def test_an_unreadable_file_yields_no_agents_rather_than_raising(self):
        # The proxy must still start: flow installs and discovery work without telemetry.
        self.assertEqual(load_switch_agent_ips("/nonexistent/topology.json"), {})

    def test_malformed_json_yields_no_agents(self):
        fh = self._tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        fh.write("{not json")
        fh.close()
        self.addCleanup(os.unlink, fh.name)
        self.assertEqual(load_switch_agent_ips(fh.name), {})


class EndToEndCallbackTest(unittest.TestCase):
    """
    The whole proxy-side path: a P4Runtime PacketIn in, a datagram on the wire out.

    Each piece is covered above; this checks they are actually connected, which is the part that
    silently does nothing if a callback is never assigned.
    """

    class CapturingSocket:
        def __init__(self):
            self.sent = []

        def sendto(self, data, addr):
            self.sent.append((data, addr))

        def close(self):
            pass

    def test_a_sample_packet_in_becomes_a_datagram(self):
        sock = self.CapturingSocket()
        emitter = SFlowEmitter(sock=sock)
        emitter.register_switch(1, "192.168.123.11")

        frame = build_ethernet_ipv4_tcp()
        packet_in = FakePacketIn(
            frame,
            reason=(PKTIN_META_REASON, PKTIN_REASON_SAMPLE),
            ingress=(PKTIN_META_INGRESS_PORT, 2),
            egress=(PKTIN_META_EGRESS_PORT, 3),
            frame_length=(PKTIN_META_FRAME_LENGTH, len(frame)),
            sampling_rate=(PKTIN_META_SAMPLING_RATE, 256))

        sample = sample_from_packet_in(packet_in)
        self.assertTrue(emitter.handle_sample(1, sample))

        self.assertEqual(len(sock.sent), 1)
        datagram, addr = sock.sent[0]
        self.assertEqual(addr, ("127.0.0.1", 6343))

        w = words(datagram)
        self.assertEqual(w[0], SFLOW_VERSION)
        self.assertEqual(w[2], struct.unpack(">I", socket.inet_aton("192.168.123.11"))[0])
        self.assertEqual(w[7], SAMPLE_TYPE_FLOW)
        self.assertEqual(w[14], 2, "ingress port survived the whole path")
        self.assertEqual(w[16], 2, "two flow records, as the kernel's parser requires")

    def test_an_unregistered_switch_does_not_send(self):
        # Better to drop than to emit under an address the kernel cannot attribute.
        sock = self.CapturingSocket()
        emitter = SFlowEmitter(sock=sock)
        self.assertFalse(emitter.handle_sample(99, a_sample()))
        self.assertEqual(sock.sent, [])

    def test_uptime_is_monotonic_and_fits_32_bits(self):
        emitter = SFlowEmitter(sock=self.CapturingSocket(), started_at=0.0)
        first = emitter.uptime_ms()
        second = emitter.uptime_ms()
        self.assertGreaterEqual(second, first)
        self.assertLess(emitter.uptime_ms(), 1 << 32)


if __name__ == "__main__":
    unittest.main(verbosity=2)
