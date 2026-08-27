"""
Synthesises sFlow v5 datagrams from P4 sampled packets and sends them to NDTwin's collector.

[Co-developed with claude code -- Adam]

Phase 5 of doc/2026-07-27_p4_bmv2_support_plan.md. bmv2 has no sFlow agent, so in P4 mode the kernel's
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

import json
import os
import socket
import struct
import time
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
        # Wrapped to 32 bits: these fields are unbounded Python ints, but struct.pack(">I", ...)
        # rejects anything >= 2**32. sample_pool in particular climbs by sampling_rate on every
        # sample, so a busy switch reaches that ceiling in hours, not years -- without the wrap,
        # every future emit() would raise struct.error and telemetry from that switch would go
        # silently and permanently dark.
        self.datagram_sequence = (self.datagram_sequence + 1) & 0xFFFFFFFF
        return self.datagram_sequence

    def next_sample_sequence(self) -> int:
        self.sample_sequence = (self.sample_sequence + 1) & 0xFFFFFFFF
        return self.sample_sequence

    def advance_pool(self, sampling_rate: int) -> int:
        """
        Advances the candidate-packet count by one sampling interval.

        Exact per-packet counts are not available -- the switch clones without telling us how
        many it skipped -- so the pool advances by the sampling rate for each sample received,
        which is the standard estimate and what a 1-in-N sampler implies.
        """
        self.sample_pool = (self.sample_pool + sampling_rate) & 0xFFFFFFFF
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
                 sock: Optional[socket.socket] = None,
                 started_at: Optional[float] = None,
                 batch_size: int = 1,
                 batch_max_delay_s: float = 0.2):
        self.collector = collector
        self.max_header_bytes = max_header_bytes
        # [Co-developed with claude code -- Adam]
        # Datagram batching -- build_datagram has always accepted a list, and until now the only
        # production caller passed a list of one. The capability shipped with tests and zero
        # users, and its own docstring said either was fine ("the kernel handles either, so
        # callers may send one at a time"), so nothing was ever measured about the difference.
        #
        # DEFAULT 1 IS EXACTLY THE OLD BEHAVIOUR, byte for byte, and that is deliberate: this is
        # here to be measured against, not to be switched on because batching is what OVS does.
        # Batching trades syscalls for latency and for blast radius -- one lost UDP datagram now
        # costs `batch_size` samples instead of one -- and neither side of that trade has a
        # number yet.
        #
        # Per-dpid, because an sFlow datagram carries exactly one agent address: samples from two
        # switches cannot legally share one. So the buffer is keyed by dpid and a busy switch
        # never waits on a quiet one.
        self.batch_size = max(1, int(batch_size))
        self.batch_max_delay_s = batch_max_delay_s
        self._pending: dict[int, list] = {}
        self._pending_since: dict[int, float] = {}
        self.batches_flushed_full = 0
        self.batches_flushed_aged = 0
        # Injectable so tests do not need a socket at all.
        self._sock = sock or socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._agents: dict[int, SwitchAgent] = {}
        # Monotonic, because sysUpTime must not move backwards: a wall-clock step (NTP, DST)
        # would make the kernel see time run in reverse between two samples.
        self._started_at = started_at if started_at is not None else time.monotonic()
        self.datagrams_sent = 0
        self.samples_sent = 0
        self.send_errors = 0

    def uptime_ms(self) -> int:
        """Milliseconds since this emitter started, as sFlow's sysUpTime (a 32-bit field)."""
        return int((time.monotonic() - self._started_at) * 1000) & 0xFFFFFFFF

    def handle_sample(self, dpid: int, sample: SampledPacket) -> bool:
        """
        Callback shape for P4RuntimeClient.sample_callback.

        Fills in sysUpTime so the gRPC receive path does not have to track it, and swallows
        nothing: emit() already reports failure by return value rather than by raising, because
        an exception here would kill the stream thread and end telemetry for that switch.
        """
        return self.emit(dpid, sample, self.uptime_ms())

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
        Sends one sampled packet, or buffers it when batching is on.

        Returns False when the switch is unregistered or the send fails, rather than raising:
        this runs on the gRPC receive path, where an exception would kill the stream thread
        and silently end telemetry for that switch. With batching on, True means "accepted",
        not "already on the wire" -- the send happens at flush.
        """
        agent = self._agents.get(dpid)
        if agent is None:
            return False

        if self.batch_size > 1:
            self._pending.setdefault(dpid, []).append(sample)
            self._pending_since.setdefault(dpid, time.monotonic())
            ok = True
            if len(self._pending[dpid]) >= self.batch_size:
                self.batches_flushed_full += 1
                ok = self._flush_one(dpid, uptime_ms)
            # Sweep every dpid, not just this one: a switch that goes quiet mid-batch would
            # otherwise hold its samples until it spoke again, which for a failing link is
            # exactly when the telemetry matters most.
            for other in [d for d, t in self._pending_since.items()
                          if d != dpid and time.monotonic() - t >= self.batch_max_delay_s]:
                self.batches_flushed_aged += 1
                self._flush_one(other, uptime_ms)
            return ok

        try:
            datagram = build_datagram([sample], agent, uptime_ms, self.max_header_bytes)
        except (ValueError, struct.error, OSError):
            # OSError covers socket.inet_aton raising on a malformed agent_ip: that call lives
            # inside build_datagram, and letting it escape here would kill the gRPC receive
            # thread that calls this method, ending telemetry for the whole switch.
            return False

        try:
            self._sock.sendto(datagram, self.collector)
        except OSError:
            self.send_errors += 1
            return False

        self.datagrams_sent += 1
        self.samples_sent += 1
        return True

    def _flush_one(self, dpid: int, uptime_ms: int) -> bool:
        """Send whatever is buffered for one switch. Empties the buffer either way."""
        samples = self._pending.pop(dpid, [])
        self._pending_since.pop(dpid, None)
        if not samples:
            return True
        agent = self._agents.get(dpid)
        if agent is None:
            return False
        try:
            datagram = build_datagram(samples, agent, uptime_ms, self.max_header_bytes)
        except (ValueError, struct.error, OSError):
            return False
        try:
            self._sock.sendto(datagram, self.collector)
        except OSError:
            self.send_errors += 1
            return False
        self.datagrams_sent += 1
        self.samples_sent += len(samples)
        return True

    def flush(self, uptime_ms: Optional[int] = None) -> None:
        """Send every buffered sample now.

        [Co-developed with claude code -- Adam]
        Batching without this has a tail: the last partial batch of a switch that stops sending
        sits in memory until it sends again, which may be never. Called from close(), and a
        caller running the emitter for long periods should call it on a timer as well.
        """
        if uptime_ms is None:
            uptime_ms = self.uptime_ms()
        for dpid in list(self._pending):
            self._flush_one(dpid, uptime_ms)

    def close(self) -> None:
        # Flush BEFORE closing the socket, or shutting down silently discards whatever the last
        # partial batches held.
        try:
            self.flush()
        except Exception:                # noqa: BLE001 -- close must not raise
            pass
        try:
            self._sock.close()
        except OSError:
            pass


# --- interpreting a CPU packet ----------------------------------------------------

# Metadata ids of packet_in_header_t in ndtwin_switch.p4, as they appear in the generated
# p4info. They are positional, so reordering the header's fields renumbers them -- which is
# why these are named constants rather than literals at the use site.
PKTIN_META_REASON = 1
PKTIN_META_INGRESS_PORT = 2
PKTIN_META_EGRESS_PORT = 3
PKTIN_META_FRAME_LENGTH = 4
PKTIN_META_SAMPLING_RATE = 5

PKTIN_REASON_PACKET_IN = 0
PKTIN_REASON_SAMPLE = 1


def metadata_by_id(packet_in) -> dict[int, int]:
    """
    Collapses a P4Runtime PacketIn's metadata list into {id: int}.

    P4Runtime's canonical byte-string representation strips leading zero bytes, so a field's
    encoded width varies with its value and cannot be assumed -- int.from_bytes handles any
    length. Absent ids are simply missing from the result; callers decide what that means.
    """
    return {m.metadata_id: int.from_bytes(m.value, "big") for m in packet_in.metadata}


def sample_from_packet_in(packet_in) -> Optional[SampledPacket]:
    """
    Builds a SampledPacket from a telemetry-sample packet-in, or returns None.

    Returns None for a genuine packet-in (unmatched traffic or an LLDP beacon), which belongs
    to the discovery path instead. The distinction comes from the `reason` field rather than
    from the payload's shape: PI strips the controller header into typed metadata before the
    proxy sees it, so there is nothing left in the bytes to tell the two apart.

    Also returns None when the frame is empty or the sampling rate is zero. A zero rate would
    make the kernel's rate arithmetic report zero throughput for real traffic, which is worse
    than dropping the sample, and it can only mean the switch is running a pipeline that does
    not match this p4info.
    """
    meta = metadata_by_id(packet_in)
    if meta.get(PKTIN_META_REASON, PKTIN_REASON_PACKET_IN) != PKTIN_REASON_SAMPLE:
        return None

    frame = bytes(packet_in.payload)
    if not frame:
        return None

    sampling_rate = meta.get(PKTIN_META_SAMPLING_RATE, 0)
    if sampling_rate == 0:
        return None

    # frame_length is the length before truncation. Fall back to the frame we actually have if
    # the switch reported nothing, so a sample still counts rather than scaling to zero bytes.
    frame_length = meta.get(PKTIN_META_FRAME_LENGTH, 0) or len(frame)

    return SampledPacket(
        ingress_port=meta.get(PKTIN_META_INGRESS_PORT, 0),
        egress_port=meta.get(PKTIN_META_EGRESS_PORT, 0),
        frame_length=frame_length,
        sampling_rate=sampling_rate,
        frame=frame,
    )


# --- topology file ----------------------------------------------------------------

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_TOPO_FILE = os.path.join(
    REPO_ROOT, "setting", "StaticNetworkTopologyP4_10Switches_4Hosts.json")


# VertexType in include/common_types/GraphTypes.hpp. Hosts carry dpid 0 and their own
# 10.0.0.x address, so including them would both register a bogus agent and collapse all four
# onto dpid 0.
VERTEX_TYPE_SWITCH = 0


def load_switch_agent_ips(path: Optional[str] = None) -> dict[int, str]:
    """
    Reads dpid -> agent IP for the *switches* in the topology JSON the kernel loads.

    The kernel attributes a sample to a graph edge by AgentKey{agentIP, port}, so these must be
    the addresses in its topology file or the telemetry arrives and is attributed to nothing --
    no error, just an empty twin. Reading the kernel's own file is what keeps the two in step,
    and NDTWIN_TOPO_FILE is honoured for the same reason the kernel honours it.

    Returns {} if the file is unreadable, leaving the proxy to run without telemetry rather than
    refusing to start: flow installs and discovery are still useful without it.
    """
    path = path or os.environ.get("NDTWIN_TOPO_FILE") or DEFAULT_TOPO_FILE
    try:
        with open(path) as fh:
            topology = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"[sflow] could not read topology {path}: {e}; no sFlow will be emitted")
        return {}

    agents: dict[int, str] = {}
    for node in topology.get("nodes", []):
        if node.get("vertex_type") != VERTEX_TYPE_SWITCH:
            continue
        dpid = node.get("dpid")
        addresses = node.get("ip") or []
        if not dpid or not addresses:
            # dpid 0 is not a switch address the kernel will ever look up.
            continue
        # The kernel treats the first address as the agent address.
        agents[int(dpid)] = addresses[0]
    return agents
