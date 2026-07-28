"""
Synthesises sFlow v5 datagrams from P4 sampled packets and sends them to NDTwin's collector.

[Co-developed with claude code -- Adam]

Phase 5 of doc/p4_bmv2_support_plan.md. bmv2 has no sFlow agent, so in P4 mode the kernel's
telemetry is entirely empty: every rate, link utilisation and flow path reads zero. The P4
pipeline clones 1-in-256 packets to the CPU (see p4_src/ndtwin_switch.p4); this module turns
those into sFlow datagrams aimed at UDP 6343, which is where the kernel already listens.

The point of doing it this way is that FlowLinkUsageCollector, Classifier and every /ndt/
metric then work unmodified -- the kernel cannot tell OVS from P4.

WHY THE LAYOUT IS EXACTLY THIS
------------------------------
The kernel's parser is hand-written with fixed word offsets, not a general sFlow library, so
"valid sFlow" is not sufficient -- it has to be the *same shape* OVS produces. That shape was
measured from a real capture (tests/fixtures/, 2863 samples, 100% consistent) rather than read
off the spec:

    word  0  version = 5
          1  agent address type = 1 (IPv4)
          2  agent IP, network order
          3  sub-agent id
          4  datagram sequence number
          5  switch uptime, ms
          6  number of samples
          7  sample type = 1 (flow_sample)
          8  sample length, BYTES, counted from word 9 to the end of the sample
          9  sample sequence number
         10  source id  = (2 << 24) | ifIndex
         11  sampling rate
         12  sample pool (running total of candidate packets)
         13  dropped packets
         14  input interface
         15  output interface
         16  flow record count = 2
         17  record[0] format = 1001 (extended_switch)
         18  record[0] length  = 16 bytes
         19..22  src_vlan, src_priority, dst_vlan, dst_priority
         23  record[1] format = 1 (raw packet header)
         24  record[1] length, bytes
         25  header protocol = 1 (Ethernet)
         26  original frame length
         27  stripped bytes
         28  captured header length
         29..    the frame, zero-padded to a 4-byte boundary

The extended_switch record is NOT optional here, even though sFlow permits a flow sample with
only a raw-header record. In MININET mode the parser reads record[0]'s length and skips that
many words before reading anything about the packet:

    flowDataLength = data[index + 11];
    index += flowDataLength / 4 + 2;

Emitting a single-record sample would make it skip six words it should have read, landing in
the middle of the Ethernet frame, and every field after that -- frame length, ethertype,
protocol, addresses, ports -- would be garbage. Nothing would error; the twin would just show
wrong numbers. tests/test_GoldenFixture.cpp asserts this shape, and
tests/test_sflow_emitter.py checks the emitter reproduces it.
"""

from __future__ import annotations

import socket
import struct
from dataclasses import dataclass, field
from typing import Optional

# --- sFlow constants -------------------------------------------------------------

SFLOW_VERSION = 5
ADDRESS_TYPE_IPV4 = 1

SAMPLE_TYPE_FLOW = 1

RECORD_FORMAT_RAW_HEADER = 1
RECORD_FORMAT_EXTENDED_SWITCH = 1001

HEADER_PROTOCOL_ETHERNET = 1

# Matches `header=128` in testbed_topo.py's ovs-vsctl configuration. The kernel reads the
# 5-tuple out of the first ~40 bytes, so 128 is ample, and matching OVS keeps the datagram
# sizes comparable for the L4 differential.
DEFAULT_MAX_HEADER_BYTES = 128

# sFlow's "source id" packs a type into the top byte. 2 means the value is an ifIndex.
SOURCE_ID_TYPE_IFINDEX = 2

DEFAULT_COLLECTOR = ("127.0.0.1", 6343)


def _pad_to_word(data: bytes) -> bytes:
    """sFlow is 32-bit aligned; the raw header record is padded, not truncated, to fit."""
    remainder = len(data) % 4
    return data if remainder == 0 else data + b"\x00" * (4 - remainder)


@dataclass
class SampledPacket:
    """
    One packet cloned to the CPU by the P4 pipeline.

    Mirrors the `sample` controller header in ndtwin_switch.p4 plus the frame itself. The
    ports and the original length are carried in that header precisely because they do not
    survive on the wire.
    """

    ingress_port: int
    egress_port: int
    frame_length: int          # length before any truncation
    sampling_rate: int
    frame: bytes               # the frame as received by the CPU, possibly already truncated


class SwitchAgent:
    """
    Per-switch sFlow agent state.

    One instance per bmv2 switch, because sFlow identifies a source by its agent address and
    the kernel keys telemetry on AgentKey{agentIP, interfacePort} to associate samples with
    graph edges. Using a single shared agent address for all ten switches would collapse them
    into one node's worth of statistics.

    Sequence numbers and the sample pool are per-agent and monotonic, as the spec requires:
    the pool is the running count of packets that *could* have been sampled, which is how a
    collector estimates the true rate.
    """

    def __init__(self, agent_ip: str, sub_agent_id: int = 0):
        self.agent_ip = agent_ip
        self.sub_agent_id = sub_agent_id
        self.datagram_sequence = 0
        self.sample_sequence = 0
        self.sample_pool = 0
        self.dropped = 0

    def next_datagram_sequence(self) -> int:
        self.datagram_sequence += 1
        return self.datagram_sequence

    def next_sample_sequence(self) -> int:
        self.sample_sequence += 1
        return self.sample_sequence

    def advance_pool(self, sampling_rate: int) -> int:
        """
        Advances the candidate-packet count by one sampling interval.

        Exact per-packet counts are not available -- the switch clones without telling us how
        many it skipped -- so the pool advances by the sampling rate for each sample received,
        which is the standard estimate and what a 1-in-N sampler implies.
        """
        self.sample_pool += sampling_rate
        return self.sample_pool


def build_flow_sample(sample: SampledPacket,
                      agent: SwitchAgent,
                      max_header_bytes: int = DEFAULT_MAX_HEADER_BYTES) -> bytes:
    """
    Builds one flow_sample, including its type and length prefix.

    Returns the bytes from `sample type` through the end of the padded frame.
    """
    frame = sample.frame[:max_header_bytes]
    padded = _pad_to_word(frame)

    # record[0]: extended_switch. All zeros -- Mininet links are untagged, so there is no VLAN
    # or priority to report. Present because the parser requires it (see the module docstring),
    # not because it carries information.
    extended_switch = struct.pack(
        ">IIII",
        0,  # src_vlan
        0,  # src_priority
        0,  # dst_vlan
        0,  # dst_priority
    )
    record0 = struct.pack(">II", RECORD_FORMAT_EXTENDED_SWITCH, len(extended_switch)) \
        + extended_switch

    # record[1]: the raw packet header.
    #
    # `stripped` is how many bytes were removed from the end of the original frame -- the
    # Ethernet FCS, which neither bmv2 nor a captured frame includes, so 0.
    raw_header_body = struct.pack(
        ">IIII",
        HEADER_PROTOCOL_ETHERNET,
        sample.frame_length,   # original length, not the truncated one
        0,                     # stripped
        len(frame),            # captured length, before padding
    ) + padded
    record1 = struct.pack(">II", RECORD_FORMAT_RAW_HEADER, len(raw_header_body)) \
        + raw_header_body

    body = struct.pack(
        ">IIIIIIII",
        agent.next_sample_sequence(),
        (SOURCE_ID_TYPE_IFINDEX << 24) | (sample.ingress_port & 0x00FFFFFF),
        sample.sampling_rate,
        agent.advance_pool(sample.sampling_rate),
        agent.dropped,
        sample.ingress_port,
        sample.egress_port,
        2,                     # flow record count: extended_switch + raw header
    ) + record0 + record1

    # The length field counts the body only, i.e. everything after type and length.
    return struct.pack(">II", SAMPLE_TYPE_FLOW, len(body)) + body


def build_datagram(samples: list[SampledPacket],
                   agent: SwitchAgent,
                   uptime_ms: int,
                   max_header_bytes: int = DEFAULT_MAX_HEADER_BYTES) -> bytes:
    """
    Builds a complete sFlow v5 datagram carrying one or more flow samples.

    Batching several samples per datagram is what OVS does and reduces syscalls, but the
    kernel handles either, so callers may send one at a time.
    """
    if not samples:
        raise ValueError("a datagram must carry at least one sample")

    header = struct.pack(
        ">II",
        SFLOW_VERSION,
        ADDRESS_TYPE_IPV4,
    ) + socket.inet_aton(agent.agent_ip) + struct.pack(
        ">III",
        agent.sub_agent_id,
        agent.next_datagram_sequence(),
        uptime_ms,
    ) + struct.pack(">I", len(samples))

    payload = b"".join(
        build_flow_sample(s, agent, max_header_bytes) for s in samples)
    return header + payload


class SFlowEmitter:
    """
    Sends synthesised sFlow to the kernel's collector.

    Holds one SwitchAgent per dpid so each switch reports under its own agent address, which
    is how the kernel attributes samples to the right graph vertex.
    """

    def __init__(self,
                 collector: tuple[str, int] = DEFAULT_COLLECTOR,
                 max_header_bytes: int = DEFAULT_MAX_HEADER_BYTES,
                 sock: Optional[socket.socket] = None):
        self.collector = collector
        self.max_header_bytes = max_header_bytes
        # Injectable so tests do not need a socket at all.
        self._sock = sock or socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._agents: dict[int, SwitchAgent] = {}
        self.datagrams_sent = 0
        self.samples_sent = 0
        self.send_errors = 0

    def register_switch(self, dpid: int, agent_ip: str) -> None:
        """
        Associates a dpid with the IP the kernel knows it by.

        This must be the switch's address in the topology JSON (192.168.123.11 upward for the
        shipped files): the kernel looks up samples by AgentKey{agentIP, port} to find the
        matching edge, so an address it does not recognise produces telemetry attributed to
        nothing.
        """
        self._agents[dpid] = SwitchAgent(agent_ip)

    def agent_for(self, dpid: int) -> Optional[SwitchAgent]:
        return self._agents.get(dpid)

    def emit(self, dpid: int, sample: SampledPacket, uptime_ms: int) -> bool:
        """
        Sends one sampled packet as a single-sample datagram.

        Returns False when the switch is unregistered or the send fails, rather than raising:
        this runs on the gRPC receive path, where an exception would kill the stream thread
        and silently end telemetry for that switch.
        """
        agent = self._agents.get(dpid)
        if agent is None:
            return False

        try:
            datagram = build_datagram([sample], agent, uptime_ms, self.max_header_bytes)
        except (ValueError, struct.error):
            return False

        try:
            self._sock.sendto(datagram, self.collector)
        except OSError:
            self.send_errors += 1
            return False

        self.datagrams_sent += 1
        self.samples_sent += 1
        return True

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass


# --- decoding the P4 sample header ------------------------------------------------

# Layout of `sample_header_t` in ndtwin_switch.p4:
#   bit<9> ingress_port, bit<9> egress_port, bit<16> frame_length,
#   bit<16> sampling_rate, bit<6> _pad   -> 56 bits, 7 bytes
SAMPLE_HEADER_BYTES = 7


def parse_sample_header(payload: bytes) -> Optional[tuple[SampledPacket, bytes]]:
    """
    Splits a CPU-bound packet into its `sample` header and the frame behind it.

    Returns None when the payload is too short to contain the header, which means it is a
    normal packet-in (unmatched traffic or an LLDP beacon) rather than a telemetry sample and
    should be handled by the discovery path instead.

    The fields are not byte-aligned -- 9 + 9 + 16 + 16 + 6 bits -- so they are unpacked from a
    big-endian bit string rather than with struct.
    """
    if len(payload) < SAMPLE_HEADER_BYTES:
        return None

    bits = int.from_bytes(payload[:SAMPLE_HEADER_BYTES], "big")
    # Peel fields off the top, most significant first, mirroring the header declaration.
    pad_and_rate = bits
    _pad = pad_and_rate & 0x3F
    pad_and_rate >>= 6
    sampling_rate = pad_and_rate & 0xFFFF
    pad_and_rate >>= 16
    frame_length = pad_and_rate & 0xFFFF
    pad_and_rate >>= 16
    egress_port = pad_and_rate & 0x1FF
    pad_and_rate >>= 9
    ingress_port = pad_and_rate & 0x1FF

    frame = payload[SAMPLE_HEADER_BYTES:]
    return (
        SampledPacket(
            ingress_port=ingress_port,
            egress_port=egress_port,
            frame_length=frame_length,
            sampling_rate=sampling_rate,
            frame=frame,
        ),
        frame,
    )
