#!/usr/bin/env python3
"""
Generates sFlow datagrams from the emitter for the C++ round-trip test.

[Co-developed with claude code -- Adam]

The emitter is Python and the parser that has to understand it is C++, so neither side's tests
can verify the pair on their own. This writes the emitter's output to tests/fixtures/emitted_*
so tests/test_sflow_emitter_roundtrip.cpp can feed it through the actual parser and assert the
5-tuple that comes out. Committing the bytes keeps the C++ suite free of a Python dependency.

The fixtures must be regenerated whenever the emitter's layout changes:

    python3 p4_proxy/tests/generate_emitted_fixtures.py

test_sflow_emitter.py::CommittedFixtureTest fails if they drift, so a forgotten regeneration
is caught rather than leaving the C++ test validating a stale layout. It covers every entry in
FIXTURES, and FIXTURES is the only way this script writes a file -- see the note there for why
that matters.

Output is deterministic: each datagram uses a fresh SwitchAgent, so sequence numbers and the
sample pool start from a known point and the bytes do not change between runs.
"""

from __future__ import annotations

import os
import socket
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent.sflow_emitter import (  # noqa: E402
    SampledPacket,
    SwitchAgent,
    build_datagram,
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE_DIR = os.path.join(REPO_ROOT, "tests", "fixtures")

AGENT_IP = "192.168.123.11"
UPTIME_MS = 125000


def ethernet(dst_mac: str, src_mac: str, ethertype: int) -> bytes:
    return bytes.fromhex(dst_mac) + bytes.fromhex(src_mac) + struct.pack(">H", ethertype)


def ipv4(src: str, dst: str, proto: int, payload: bytes) -> bytes:
    total_len = 20 + len(payload)
    header = struct.pack(">BBHHHBBH", 0x45, 0, total_len, 1, 0, 64, proto, 0) \
        + socket.inet_aton(src) + socket.inet_aton(dst)
    return header + payload


def tcp(src_port: int, dst_port: int, flags: int = 0x10, payload: bytes = b"") -> bytes:
    # dataOffset 5 (<<4), then flags; ACK is 0x10, which the parser reads to detect pure ACKs.
    return struct.pack(">HHIIBBHHH", src_port, dst_port, 0, 0, 0x50, flags, 0, 0, 0) + payload


def udp(src_port: int, dst_port: int, payload: bytes = b"") -> bytes:
    return struct.pack(">HHHH", src_port, dst_port, 8 + len(payload), 0) + payload


def icmp(icmp_type: int, code: int, payload: bytes = b"") -> bytes:
    return struct.pack(">BBH", icmp_type, code, 0) + payload


def frame_tcp() -> bytes:
    return ethernet("000000000002", "000000000001", 0x0800) + \
        ipv4("10.0.0.1", "10.0.0.4", 6, tcp(5001, 40997, payload=b"\x00" * 20))


def frame_udp() -> bytes:
    return ethernet("000000000002", "000000000001", 0x0800) + \
        ipv4("10.0.0.2", "10.0.0.3", 17, udp(5201, 33333, payload=b"\x00" * 20))


def frame_icmp() -> bytes:
    # Echo request: type 8, code 0. The kernel stores these in the port fields.
    return ethernet("000000000002", "000000000001", 0x0800) + \
        ipv4("10.0.0.1", "10.0.0.2", 1, icmp(8, 0, payload=b"\x00" * 20))


def frame_icmp_unreachable() -> bytes:
    # Type 3 code 1 (destination unreachable, host unreachable). Both fields non-zero, so the
    # round-trip test cannot pass by accident on a default-initialised zero.
    return ethernet("000000000002", "000000000001", 0x0800) + \
        ipv4("10.0.0.3", "10.0.0.4", 1, icmp(3, 1, payload=b"\x00" * 20))


def frame_arp() -> bytes:
    # Non-IPv4: the parser must skip it without inventing a flow.
    return ethernet("ffffffffffff", "000000000001", 0x0806) + b"\x00" * 28


def frame_large_tcp() -> bytes:
    # Longer than the 128-byte capture limit, so truncation is exercised end to end.
    return ethernet("000000000002", "000000000001", 0x0800) + \
        ipv4("10.0.0.1", "10.0.0.4", 6, tcp(5001, 40998, payload=b"\xab" * 1400))


# Every committed fixture, as (filename, [(frame, ingress_port, egress_port), ...]).
#
# [Co-developed with claude code -- Adam]
# A list of samples per fixture rather than one frame, so emitted_multi.bin belongs here
# instead of being assembled separately in main(). It was built there, outside this list, and
# the drift guard iterates this list -- so the docstring's promise held for the six
# single-sample fixtures and not for the multi-sample one, which is the fixture carrying the
# parser's only sample-chain coverage (test_SFlowEmitterRoundtrip.cpp WalksEverySample). The
# shape change is what closes it: there is no longer a way to write a fixture that the guard
# does not see, because main() and the guard now build from the same list through the same
# function.
FIXTURES = [
    ("emitted_tcp.bin", [(frame_tcp(), 1, 2)]),
    ("emitted_udp.bin", [(frame_udp(), 3, 4)]),
    ("emitted_icmp.bin", [(frame_icmp(), 1, 3)]),
    ("emitted_icmp_unreachable.bin", [(frame_icmp_unreachable(), 2, 4)]),
    ("emitted_arp.bin", [(frame_arp(), 2, 1)]),
    ("emitted_tcp_truncated.bin", [(frame_large_tcp(), 1, 2)]),
    # Several samples in one datagram, so the C++ side also walks the sample chain.
    ("emitted_multi.bin", [(frame_tcp(), 1, 2), (frame_udp(), 3, 4), (frame_icmp(), 1, 3)]),
]


def build_fixture(samples) -> bytes:
    """
    Builds one fixture's datagram from its (frame, ingress, egress) list.

    The single place a fixture's bytes are defined: the generator writes what this returns and
    test_sflow_emitter.py::CommittedFixtureTest compares against what this returns, so the two
    cannot disagree about how a fixture is built. A fresh SwitchAgent per fixture keeps the
    output deterministic -- sequence numbers and the sample pool start from a known point.
    """
    agent = SwitchAgent(AGENT_IP)
    return build_datagram(
        [SampledPacket(ingress_port=ingress,
                       egress_port=egress,
                       frame_length=len(frame),
                       sampling_rate=256,
                       frame=frame)
         for frame, ingress, egress in samples],
        agent,
        UPTIME_MS)


def main() -> int:
    os.makedirs(FIXTURE_DIR, exist_ok=True)
    for name, samples in FIXTURES:
        datagram = build_fixture(samples)
        path = os.path.join(FIXTURE_DIR, name)
        with open(path, "wb") as fh:
            fh.write(datagram)
        print(f"  wrote {name}: {len(datagram)} bytes ({len(datagram) // 4} words)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
