#!/usr/bin/env python3
"""Runs p4pi on (A) static path enumeration, (B) synthesized send.py-shaped frames incl.
negative cases, (C) deliberately corrupted JSONs, (D) every frame of the bmv2 pcaps the
2026-09-18/24/25 tutorial runs left in /home/adam/tutorials/exercises/*/pcaps/.

[Co-developed with claude code -- Adam]

Output: plain text on stdout (tee'd to run_tests.log by the caller) + results.json.
Exit code 0 only if every case in (B) and (C) matched its expectation.
"""
import copy
import glob
import hashlib
import json
import os
import struct
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import p4pi  # noqa: E402
from p4pi import (Program, interpret, enumerate_paths, classify_path, describe_path,  # noqa
                  native_identify, parse_hints, hints_identify)
from pkts import *  # noqa: F401,F403,E402

J = lambda n: os.path.join(HERE, "json", n + ".json")  # noqa: E731
CAP = 128   # link_telemetry.py:75 LINK_SAMPLE_TRUNC, sflow_emitter.py:88 DEFAULT_MAX_HEADER_BYTES

PROGS = {n: Program(J(n)) for n in [
    "basic", "basic_tunnel", "calc", "ecn", "firewall_basic", "firewall_fw", "flowcache",
    "link_monitor", "load_balance", "mri", "multicast", "p4runtime", "qos", "source_routing",
    "ndtwin_switch", "syn_pvs", "syn_varbit_ok", "syn_meta_key", "syn_deep_stack", "syn_ipip"]}

HINTS_TEXT = {
    "basic_tunnel": "0x1212 fixed 4 next=u16@0",
    "p4runtime": "0x1212 fixed 4 next=u16@0",
    "source_routing": "0x1234 stack 2 until=bit0 next=0x0800",
}
HINTS = {k: parse_hints(v) for k, v in HINTS_TEXT.items()}

H1, H2, H3 = "10.0.1.1", "10.0.2.2", "10.0.3.3"
ING = lambda p: {"standard_metadata.ingress_port": p}  # noqa: E731

FAILS = []
PATHS = {n: enumerate_paths(pr) for n, pr in PROGS.items()}


def path_of(name, states, status, detail=""):
    """1-based index of the enumerated path a run walked, by its collapsed state sequence.
    A run that stopped early (refusal, parser error, truncation, or the reachability exit)
    is labelled with the set of paths it is a prefix of, never with a single path."""
    seq = []
    for s in states:
        if not seq or seq[-1] != s:
            seq.append(s)
    if name not in PATHS:
        return "?"
    early = status in ("REFUSE", "PARSER_ERROR", "TRUNCATED", "SANITY") or \
        detail.startswith("no IP-extracting state reachable")
    pre = [i for i, pth in enumerate(PATHS[name], 1) if pth["states"][:len(seq)] == seq]
    if early:
        tag = "x-early" if status == "NO_IP" else status.lower()
        return f"{tag}:{'|'.join('P%d' % i for i in pre)}"
    hits = [i for i, pth in enumerate(PATHS[name], 1) if pth["states"] == seq]
    if len(hits) == 1:
        return f"P{hits[0]}"
    if len(hits) > 1:
        return "P" + "/P".join(map(str, hits))
    return f"?:{'|'.join('P%d' % i for i in pre)}"


OUT = {"static": {}, "cases": [], "corrupt": [], "pcap": {}}


def p(*a):
    print(*a, flush=True)


# ============================================================================================
# A. static
# ============================================================================================

def part_a():
    p("=" * 100)
    p("A. STATIC PATH ENUMERATION (p4pi.enumerate_paths + classify_path on the compiled JSON)")
    p("=" * 100)
    for name, prog in PROGS.items():
        paths = enumerate_paths(prog)
        rows = []
        p(f"-- {name}: {len(paths)} path(s); json sha256[:12]="
          f"{hashlib.sha256(open(J(name), 'rb').read()).hexdigest()[:12]}")
        for i, path in enumerate(paths, 1):
            c = classify_path(prog, path)
            rows.append({"path": describe_path(path), **c})
            p(f"   P{i:<2} {c['class']:<2} ip_off=[{c['ip_offset_min']},{c['ip_offset_max']}]"
              f" N={','.join(x[2:] for x in c['n_constructs']) or '-'}"
              f" tags={','.join(t for t in c['tags'] if not t.startswith('N:')) or '-'}")
            p(f"        {describe_path(path)}")
        OUT["static"][name] = rows


# ============================================================================================
# B. synthesized frames
# ============================================================================================

def T(src, dst, proto, sp, dp):
    return (src, dst, proto, sp, dp)


def build_cases():
    C = []

    def add(cid, prog, link, frame, expect, wire, ctx=None, note="", sanity=True,
            early_x=True, expect_path=None, expect_l4=None, added=None):
        # SUITE=v1 reproduces the suite as it stood before the mutation run: no cases added
        # because of a surviving mutant, no expect_l4 assertions.
        if os.environ.get("SUITE") == "v1" and added:
            return
        C.append(dict(id=cid, prog=prog, link=link, frame=frame, expect=expect, wire=wire,
                      ctx=ctx, note=note, sanity=sanity, early_x=early_x,
                      expect_path=expect_path,
                      expect_l4=None if os.environ.get("SUITE") == "v1" else expect_l4))

    # ---- basic (send.py:35-36: Ether/IP/TCP dport 1234)
    f = eth(0x0800) + ipv4(H1, H2, 6, tcp(50001, 1234, payload=b"hello"))
    add("basic-1", "basic", "h1->s1 ingress", f, ("IP", 14), (14, T(H1, H2, 6, 50001, 1234)), ING(1))
    f = eth(0x0806) + bytes(28)
    add("basic-2-arp", "basic", "ARP", f, ("NO_IP",), None, ING(1))

    # ---- basic_tunnel (send.py: --dst_id -> Ether(0x1212)/MyTunnel/IP/TCP; else Ether/IP/TCP)
    f = eth(0x1212) + mytunnel(0x0800, 2) + ipv4(H1, H2, 6, tcp(50002, 1234, payload=b"hi"))
    add("btun-1-tunnel", "basic_tunnel", "h1->s1 ingress (host sends the tunnel header)", f,
        ("IP", 18), (18, T(H1, H2, 6, 50002, 1234)), ING(1))
    add("btun-1b-tunnel-egress", "basic_tunnel", "s2->h2 egress (tunnel header kept to host)", f,
        ("IP", 18), (18, T(H1, H2, 6, 50002, 1234)), ING(2),
        note="egress sample; switch never pops myTunnel (basic_tunnel.p4:147-157)")
    f = eth(0x0800) + ipv4(H1, H2, 6, tcp(50003, 1234))
    add("btun-2-plain", "basic_tunnel", "h1->s1 ingress, no --dst_id", f, ("IP", 14),
        (14, T(H1, H2, 6, 50003, 1234)), ING(1))
    f = eth(0x1212) + mytunnel(0x86DD, 2) + ipv6_udp(1111, 2222)
    add("btun-3-tunnel-v6", "basic_tunnel", "tunnel carrying IPv6 (not in send.py)", f,
        ("NO_IP",), (18, "IPV6"), ING(1),
        note="program parses only proto_id 0x0800 behind myTunnel: X by the program, IPv6 on wire")

    # ---- calc (calc.py:88 Ether(type=0x1234)/P4calc)
    f = eth(0x1234, dst=mac(0x00)) + p4calc("+", 2, 3)
    add("calc-1", "calc", "h1->s1", f, ("NO_IP",), None, ING(1))
    f = eth(0x1234, dst=mac(0x00)) + p4calc("+", 2, 3)
    add("calc-1-full", "calc", "h1->s1, reachability exit OFF: lookahead select must pick P1", f,
        ("NO_IP",), None, ING(1), early_x=False, expect_path="P1",
        note="runs check_p4calc's lookahead<p4calc_t> and its 3-field select")
    f = eth(0x1234, dst=mac(0x00)) + p4calc("+", 2, 3, p=b"Q")
    add("calc-1-full-badmagic", "calc", "reachability exit OFF, first byte 'Q'", f, ("NO_IP",),
        None, ING(1), early_x=False, expect_path="P2")
    f = eth(0x1234, dst=mac(0x00)) + b"XY" + bytes(14)
    add("calc-2-badmagic", "calc", "h1->s1, not 'P4'", f, ("NO_IP",), None, ING(1))

    # ---- ecn (send.py:35 IP tos=1 / UDP 1234->4321)
    f = eth(0x0800) + ipv4(H1, H2, 17, udp(1234, 4321, b"m"), tos=1)
    add("ecn-1", "ecn", "h1->s1", f, ("IP", 14), (14, T(H1, H2, 17, 1234, 4321)), ING(1))

    # ---- firewall: s1 runs firewall.p4, s2..s4 basic.p4 (pod-topo/topology.json)
    f = eth(0x0800) + ipv4(H1, H3, 6, tcp(40000, 80, flags=0x02))
    add("fw-1-s1", "firewall_fw", "h1->s1 ingress (firewall.p4)", f, ("IP", 14),
        (14, T(H1, H3, 6, 40000, 80)), ING(1), expect_l4=34)
    add("fw-2-s3", "firewall_basic", "s1->s3 ingress at s3 (basic.p4)", f, ("IP", 14),
        (14, T(H1, H3, 6, 40000, 80)), ING(1))

    f = eth(0x0800) + ipv4(H1, H3, 17, udp(5353, 53))
    add("fw-3-s1-udp", "firewall_fw", "h1->s1 UDP (non-TCP branch)", f, ("IP", 14),
        (14, T(H1, H3, 17, 5353, 53)), ING(1))

    # ---- flowcache (README: h1 ping h2). Parser start selects on standard_metadata.ingress_port
    f = eth(0x0800) + ipv4(H1, H2, 1, icmp_echo())
    add("fc-1-ctx", "flowcache", "h1->s1 ingress, port given", f, ("IP", 14),
        (14, T(H1, H2, 1, 8, 0)), ING(1))
    add("fc-2-noctx", "flowcache", "same frame, no port context", f,
        ("REFUSE", "standard_metadata.ingress_port"), (14, T(H1, H2, 1, 8, 0)), None,
        note="NEGATIVE: class N construct")

    # ---- link_monitor (send.py: Probe(hop_cnt=0)/9x ProbeFwd)
    f = eth(0x0812) + probe(0, [], [4, 1, 4, 1, 3, 2, 3, 2, 1])
    add("lm-1-probe0", "link_monitor", "h1->s1", f, ("NO_IP",), None, ING(1))
    f = eth(0x0812) + probe(3, [(1, 2, 1000, 1, 2), (2, 3, 2000, 3, 4), (3, 1, 3000, 5, 6)],
                            [4, 1, 4, 1, 3, 2, 3, 2, 1])
    add("lm-2-probe3", "link_monitor", "after 3 hops", f, ("NO_IP",), None, ING(2))
    f = eth(0x0812) + probe(3, [(1, 2, 1000, 1, 2), (2, 3, 2000, 3, 4), (3, 1, 3000, 5, 6)],
                            [4, 1, 4, 1, 3, 2, 3, 2, 1])
    add("lm-2-probe3-full", "link_monitor", "after 3 hops, reachability exit OFF", f, ("NO_IP",),
        None, ING(2), early_x=False, expect_path="P3",
        note="runs both stacks: probe_data until bos, probe_fwd for hop_cnt+1 entries")
    f = eth(0x0812) + probe(0, [], [4, 1, 4, 1, 3, 2, 3, 2, 1])
    add("lm-1-probe0-full", "link_monitor", "hop_cnt=0, reachability exit OFF", f, ("NO_IP",),
        None, ING(2), early_x=False, expect_path="P2")
    f = eth(0x0812) + probe(8, [(i, 1, 1, 1, 1) for i in range(8)], [1] * 9)
    add("lm-3-probe8-truncated", "link_monitor", "after 8 hops, 167 B > 128 B capture", f[:CAP],
        ("NO_IP",), None, ING(2), note="decided by reachability before the truncation bites")
    f = eth(0x0800) + ipv4(H1, H2, 17, udp(5000, 6000))
    add("lm-4-ipv4", "link_monitor", "plain IPv4", f, ("IP", 14), (14, T(H1, H2, 17, 5000, 6000)),
        ING(1))

    # ---- load_balance (send.py:35 IP dst=10.0.0.1 / TCP 1234)
    f = eth(0x0800) + ipv4(H1, "10.0.0.1", 6, tcp(50004, 1234))
    add("lb-1", "load_balance", "h1->s1", f, ("IP", 14), (14, T(H1, "10.0.0.1", 6, 50004, 1234)),
        ING(1))

    f = eth(0x0800) + ipv4(H1, "10.0.0.1", 17, udp(5000, 1234))
    add("lb-2-udp", "load_balance", "h1->s1 UDP (non-TCP branch)", f, ("IP", 14),
        (14, T(H1, "10.0.0.1", 17, 5000, 1234)), ING(1))

    # ---- mri (send.py: IP(options=IPOption_MRI(count=0))/UDP 1234->4321)
    def mri(n):
        return eth(0x0800) + ipv4(H1, H2, 17, udp(1234, 4321, b"m"),
                                  options=mri_option([(i + 1, 0) for i in range(n)]))
    add("mri-0", "mri", "h1->s1 (count=0, ihl=6)", mri(0), ("IP", 14),
        (14, T(H1, H2, 17, 1234, 4321)), ING(2))
    add("mri-1", "mri", "s1->s2 (count=1, ihl=8)", mri(1), ("IP", 14),
        (14, T(H1, H2, 17, 1234, 4321)), ING(3))
    add("mri-3", "mri", "s2->h2 via s3 (count=3, ihl=12)", mri(3), ("IP", 14),
        (14, T(H1, H2, 17, 1234, 4321)), ING(2))
    add("mri-4", "mri", "count=4, ihl=14 (most that fits ihl's 4 bits)", mri(4), ("IP", 14),
        (14, T(H1, H2, 17, 1234, 4321)), ING(2))
    f = eth(0x0800) + ipv4(H1, H2, 17, udp(1234, 4321, b"m"),
                           options=mri_option([(i + 1, 0) for i in range(5)]), ihl_override=0)
    add("mri-5-ihl-wrap", "mri", "5th hop: add_swtrace's ihl+2 wraps the 4-bit field to 0", f,
        ("PARSER_ERROR", "IPHeaderTooShort"), (14, T(H1, H2, 17, 1234, 4321)), ING(2),
        note="LIMIT (an app bug, mri.p4:206): nothing in the header says where L4 is any more")
    f = eth(0x0800) + ipv4(H1, H2, 17, udp(1234, 4321))
    add("mri-plain", "mri", "IPv4 ihl=5", f, ("IP", 14), (14, T(H1, H2, 17, 1234, 4321)), ING(2))
    f = eth(0x0800) + ipv4(H1, H2, 17, udp(1234, 4321), options=b"\x01\x01\x01\x00")
    add("mri-nop-opt", "mri", "IPv4 with a non-MRI option (NOP,NOP,NOP,EOL)", f, ("IP", 14),
        (14, T(H1, H2, 17, 1234, 4321)), ING(2))
    f = eth(0x0800) + ipv4(H1, H2, 17, udp(1, 2), ihl_override=4)
    add("mri-ihl4", "mri", "malformed ihl=4", f, ("PARSER_ERROR", "IPHeaderTooShort"), None, ING(2),
        note="verify(ihl>=5) evaluated from the bytes")

    # ---- multicast (README: h1 ping h2) -- parser extracts ethernet only
    f = eth(0x0800) + ipv4(H1, H2, 1, icmp_echo())
    add("mc-1", "multicast", "h1->s1 ping", f, ("NO_IP",), (14, T(H1, H2, 1, 8, 0)), ING(1),
        note="X by the program, IPv4 on the wire")

    # ---- p4runtime (advanced_tunnel.p4: tunnel pushed at s1, popped at s2; ping h1->h2)
    f = eth(0x0800) + ipv4(H1, H2, 1, icmp_echo())
    add("p4rt-1-hostlink", "p4runtime", "h1->s1 ingress (plain IPv4)", f, ("IP", 14),
        (14, T(H1, H2, 1, 8, 0)), ING(1))
    f = eth(0x1212) + mytunnel(0x0800, 100) + ipv4(H1, H2, 1, icmp_echo())
    add("p4rt-2-tunnel", "p4runtime", "s1->s2 ingress at s2 (tunnel)", f, ("IP", 18),
        (18, T(H1, H2, 1, 8, 0)), ING(2))

    # ---- qos (send.py:38/47 IP tos=1 / UDP or TCP)
    f = eth(0x0800) + ipv4(H1, H2, 17, udp(1234, 4321), tos=1)
    add("qos-1", "qos", "h1->s1 UDP", f, ("IP", 14), (14, T(H1, H2, 17, 1234, 4321)), ING(1))
    f = eth(0x0800) + ipv4(H1, H2, 6, tcp(20, 80), tos=1)
    add("qos-2", "qos", "h1->s1 TCP", f, ("IP", 14), (14, T(H1, H2, 6, 20, 80)), ING(1))

    # ---- source_routing (send.py: SourceRoute* then IP/UDP 1234->4321; last hop rewrites
    #      etherType to 0x0800, source_routing.p4 srcRoute_finish)
    def sr(ports):
        return eth(0x1234) + srcroutes(ports) + ipv4(H1, H2, 17, udp(1234, 4321, b"m"))
    add("sr-1-host", "source_routing", "h1->s1 ingress, route '2 3 1'", sr([2, 3, 1]), ("IP", 20),
        (20, T(H1, H2, 17, 1234, 4321)), ING(1))
    add("sr-2-core", "source_routing", "s1->s2 ingress after one pop", sr([3, 1]), ("IP", 18),
        (18, T(H1, H2, 17, 1234, 4321)), ING(2))
    add("sr-9-max", "source_routing", "9 entries (stack size)", sr([2] * 8 + [1]), ("IP", 32),
        (32, T(H1, H2, 17, 1234, 4321)), ING(1))
    f = eth(0x0800) + ipv4(H1, H2, 17, udp(1234, 4321, b"m"))
    add("sr-last-hop", "source_routing", "s->h2 egress: plain 0x0800 after srcRoute_finish", f,
        ("NO_IP",), (14, T(H1, H2, 17, 1234, 4321)), ING(1),
        note="the program's parser has no 0x0800 branch: X by the program, IPv4 on the wire")
    add("sr-10-overflow", "source_routing", "10 entries > stack size 9", sr([2] * 9 + [1]),
        ("PARSER_ERROR", "StackOutOfBounds"), (34, T(H1, H2, 17, 1234, 4321)), ING(1),
        note="bmv2 would also raise StackOutOfBounds; the wire still has IPv4 at 34")

    # ---- ndtwin_switch (start selects on standard_metadata.ingress_port == 255)
    f = eth(0x0800) + ipv4(H1, H2, 6, tcp(33000, 5201))
    add("ndt-1-ctx", "ndtwin_switch", "host->switch ingress, port 1", f, ("IP", 14),
        (14, T(H1, H2, 6, 33000, 5201)), ING(1))
    add("ndt-2-noctx", "ndtwin_switch", "same frame, no port context", f,
        ("REFUSE", "standard_metadata.ingress_port"), (14, T(H1, H2, 6, 33000, 5201)), None,
        note="NEGATIVE: NDTwin's own program is class N on every path without port context")
    add("ndt-3-wrongctx", "ndtwin_switch", "same frame, port context 255 (wrong)", f,
        ("SAFE", 14), (14, T(H1, H2, 6, 33000, 5201)), ING(255),
        note="NEGATIVE: wrong context must not yield the right answer")

    for cid, proto, l4, tup in [
            ("ndt-4-udp", 17, udp(4000, 4001), T(H1, H2, 17, 4000, 4001)),
            ("ndt-5-icmp", 1, icmp_echo(), T(H1, H2, 1, 8, 0)),
            ("ndt-6-ospf", 89, b"\x00" * 24, T(H1, H2, 89, 0, 0))]:
        f = eth(0x0800) + ipv4(H1, H2, proto, l4)
        add(cid, "ndtwin_switch", "host->switch ingress, port 1", f, ("IP", 14), (14, tup), ING(1))
    f = eth(0x0800) + ipv4(H1, H2, 6, b"\x00" * 24, flags_frag=0x00B9)
    add("ndt-7-fragment", "ndtwin_switch", "non-first fragment (offset 185) of TCP", f, ("IP", 14),
        (14, T(H1, H2, 6, 0, 0)), ING(1), note="parse_ipv4 selects on (fragOffset, protocol)")
    for cid, proto, l4, tup in [
            ("ndt-8-pktout-tcp", 6, tcp(1, 2), T(H1, H2, 6, 1, 2)),
            ("ndt-9-pktout-udp", 17, udp(3, 4), T(H1, H2, 17, 3, 4)),
            ("ndt-10-pktout-icmp", 1, icmp_echo(), T(H1, H2, 1, 8, 0)),
            ("ndt-11-pktout-other", 89, b"\x00" * 24, T(H1, H2, 89, 0, 0))]:
        f = pkt_ndtwin_packet_out(2) + eth(0x0800) + ipv4(H1, H2, proto, l4)
        add(cid, "ndtwin_switch", "CPU port 255 (packet_out) -- never on a sampled veth", f,
            ("IP", 16), (16, tup), ING(255),
            note="exists only on the P4Runtime stream channel; run for path coverage only")

    # ---- synthetic negatives / limits
    f = eth(0x0800) + ipv4(H1, H2, 17, udp(1, 2))
    add("syn-pvs-ipv4", "syn_pvs", "0x0800 is matched before the value set", f, ("IP", 14),
        (14, T(H1, H2, 17, 1, 2)), ING(1))
    f = eth(0x88B6) + struct.pack(">HH", 0x0800, 1) + ipv4(H1, H2, 17, udp(1, 2))
    add("syn-pvs-tun", "syn_pvs", "ethertype that may or may not be in the runtime vset", f,
        ("REFUSE", "parse_vset"), (18, T(H1, H2, 17, 1, 2)), ING(1), note="NEGATIVE")
    f = eth(0x0800) + ipv4(H1, H2, 6, tcp(7, 8), options=b"\x01\x01\x01\x01" * 2)
    add("syn-varbit", "syn_varbit_ok", "IPv4 + 8 B options parsed as varbit", f, ("IP", 14),
        (14, T(H1, H2, 6, 7, 8)), ING(1), note="extract_VL length evaluated from ihl",
        expect_l4=42)
    f = eth(0x88B5) + struct.pack(">HH", 0x0800, 1) + ipv4(H1, H2, 17, udp(1, 2))
    add("syn-meta-noctx", "syn_meta_key", "no port context", f,
        ("REFUSE", "standard_metadata.ingress_port"), (18, T(H1, H2, 17, 1, 2)), None,
        note="NEGATIVE: key is a scalar computed from ingress_port")
    f4 = eth(0x0800) + ipv4(H1, H2, 17, udp(1, 2))
    add("syn-meta-ipv4-core", "syn_meta_key", "IPv4 on port 4: needs the (_, 0x0800) mask", f4,
        ("IP", 14), (14, T(H1, H2, 17, 1, 2)), ING(4), expect_path="P2", added="M4",
        note="added after mutant M4 (mask ignored) survived suite v1")
    add("syn-meta-core", "syn_meta_key", "port 4 (core): tunnel parsed", f, ("IP", 18),
        (18, T(H1, H2, 17, 1, 2)), ING(4))
    add("syn-meta-edge", "syn_meta_key", "port 1 (edge): same bytes, tunnel not parsed", f,
        ("NO_IP",), (18, T(H1, H2, 17, 1, 2)), ING(1),
        note="same bytes, different program answer: the definition of class N")

    inner = ipv4("192.168.0.1", "192.168.0.2", 17, udp(7000, 7001))
    f = eth(0x0800) + ipv4(H1, H2, 4, inner)
    add("syn-ipip", "syn_ipip", "IPv4-in-IPv4: innermost IP is the identity (design choice)", f,
        ("IP", 34), (34, T("192.168.0.1", "192.168.0.2", 17, 7000, 7001)), ING(1), added="M11",
        note="native today reports the OUTER header (proto 4, no ports); policy question")

    def deep(n):
        hops = b"".join(hop16(1 if i == n - 1 else 0, i, i) for i in range(n))
        return eth(0x1235) + hops + ipv4(H1, H2, 17, udp(9, 10, b"x" * 40))
    add("syn-deep-2", "syn_deep_stack", "2 x 16 B entries", deep(2)[:CAP], ("IP", 46),
        (46, T(H1, H2, 17, 9, 10)), ING(1))
    add("syn-deep-5", "syn_deep_stack", "5 x 16 B entries (IP@94, ports end at 118)", deep(5)[:CAP],
        ("IP", 94), (94, T(H1, H2, 17, 9, 10)), ING(1))
    add("syn-deep-6", "syn_deep_stack", "6 x 16 B entries (IP@110, header ends at 130)",
        deep(6)[:CAP], ("TRUNCATED",), (110, T(H1, H2, 17, 9, 10)), ING(1),
        note="LIMIT: 128-byte capture")
    add("syn-deep-8", "syn_deep_stack", "8 x 16 B entries (IP@142)", deep(8)[:CAP],
        ("TRUNCATED",), (142, T(H1, H2, 17, 9, 10)), ING(1), note="LIMIT: 128-byte capture")
    return C


def combined(native, proto_res):
    """Native first (today's identifyFrame model); program parser only when native has no L3."""
    fam, tup = native
    if fam in ("ipv4", "ipv6"):
        return ("native", fam, tup)
    if proto_res.status == "IP":
        return ("program", proto_res.ip_family, proto_res.five_tuple)
    return ("none", fam, None)


def wire_ok(identity_tuple, wire):
    if wire is None:
        return identity_tuple is None
    off, tup = wire
    if tup == "IPV6":   # only the family is asserted: an IPv6 address pair was found
        return identity_tuple is not None and isinstance(identity_tuple[0], str) \
            and len(identity_tuple[0]) == 32
    return identity_tuple == tup


def run_case(c, prog_override=None, label_prefix=""):
    prog = prog_override or PROGS[c["prog"]]
    frame = c["frame"]
    orig = len(frame) if len(frame) < CAP else max(len(frame), CAP + 64)
    if c["id"].startswith(("syn-deep-6", "syn-deep-8", "lm-3")):
        orig = CAP + 200    # the frame was longer than the capture
    r = interpret(prog, frame[:CAP], orig_len=orig, ctx=c["ctx"], sanity=c.get("sanity", True),
                  early_x=c.get("early_x", True))
    exp = c["expect"]
    kind = exp[0]
    if kind == "IP":
        ok = (r.status == "IP" and r.ip_offset == exp[1] and c["wire"] is not None
              and r.five_tuple == c["wire"][1])
    elif kind == "NOT":
        # documents a failure mode: passes whether the answer is refused or wrong
        ok = not (r.status == "IP" and r.ip_offset == exp[1])
    elif kind == "SAFE":
        # the safety property: either no identity is claimed, or the claimed one is right
        ok = r.status != "IP" or (r.ip_offset == exp[1] and c["wire"] is not None
                                  and r.five_tuple == c["wire"][1])
    elif kind in ("REFUSE", "PARSER_ERROR"):
        ok = r.status == kind and exp[1] in r.detail
    else:
        ok = r.status == kind
    walked = path_of(c["prog"], r.states, r.status, r.detail) if not prog_override else "-"
    if c.get("expect_path") and walked != c["expect_path"]:
        ok = False
    if c.get("expect_l4") is not None and r.l4_program_offset != c["expect_l4"]:
        ok = False
    nat = native_identify(frame[:CAP])
    hin = hints_identify(HINTS.get(c["prog"], {}), frame[:CAP])
    comb = combined(nat, r)
    row = {
        "id": label_prefix + c["id"], "prog": prog.path if prog_override else c["prog"],
        "link": c["link"], "ctx": c["ctx"], "expect": list(exp), "got": r.status,
        "got_short": r.short(), "states": r.states, "verdict": "PASS" if ok else "FAIL",
        "wire": c["wire"], "proto_vs_wire": wire_ok(r.five_tuple if r.status == "IP" else None,
                                                     c["wire"]),
        "native": [nat[0], nat[1]], "native_vs_wire": wire_ok(
            nat[1] if nat[0] in ("ipv4", "ipv6") else None, c["wire"]),
        "hints": [hin[0], hin[1]], "hints_vs_wire": wire_ok(
            hin[1] if hin[0] in ("ipv4", "ipv6") else None, c["wire"]),
        "combined": [comb[0], comb[1]], "combined_vs_wire": wire_ok(comb[2], c["wire"]),
        "l4_program_offset": r.l4_program_offset, "note": c["note"],
        "path": walked, "expect_path": c.get("expect_path"),
    }
    if not ok:
        FAILS.append(row["id"])
    return row


def part_b():
    p()
    p("=" * 100)
    p("B. SYNTHESIZED FRAMES (struct, mirroring each send.py), truncated to 128 B")
    p("   verdict = prototype vs what THIS program's parser must do; *_vs_wire = identity vs the")
    p("   L3 identity actually present in the bytes (independent of the program)")
    p("=" * 100)
    for c in build_cases():
        row = run_case(c)
        OUT["cases"].append(row)
        p(f"[{row['verdict']}] {row['id']:<24} prog={c['prog']:<15} path={row['path']:<10} ctx={c['ctx']}")
        p(f"        link: {c['link']}")
        p(f"        expect={tuple(c['expect'])}  got: {row['got_short']}")
        p(f"        states: {' > '.join(row['states'])}")
        p(f"        vs wire: program={row['proto_vs_wire']}  native-model={row['native_vs_wire']}"
          f" ({row['native'][0]})  hints={row['hints_vs_wire']} ({row['hints'][0]})"
          f"  combined={row['combined_vs_wire']} (via {row['combined'][0]})")
        if row["l4_program_offset"] is not None:
            p(f"        program-extracted L4 header at byte {row['l4_program_offset']}")
        if c["note"]:
            p(f"        note: {c['note']}")


# ============================================================================================
# C. corrupted JSONs
# ============================================================================================

def corrupt(name, fn):
    j = copy.deepcopy(PROGS[name].j)
    fn(j)
    return Program(j)


def part_c():
    p()
    p("=" * 100)
    p("C. DELIBERATELY CORRUPTED JSON (the JSON no longer matches the wire)")
    p("=" * 100)

    def widen_srcroute(j):
        for ht in j["header_types"]:
            if ht["name"] == "srcRoute_t":
                ht["fields"] = [["bos", 1, False], ["port", 23, False]]

    def swap_tunnel_fields(j):
        for ht in j["header_types"]:
            if ht["name"] == "myTunnel_t":
                ht["fields"] = [["dst_id", 16, False], ["proto_id", 16, False]]

    def widen_tunnel(j):
        for ht in j["header_types"]:
            if ht["name"] == "myTunnel_t":
                ht["fields"] = [["proto_id", 16, False], ["dst_id", 32, False]]

    def rename_ipv4(j):
        for ht in j["header_types"]:
            if ht["name"] == "ipv4_t":
                ht["name"] = "zz_t"
                ht["fields"] = [[f"f{i}", f[1], f[2]] for i, f in enumerate(ht["fields"])]
        for h in j["headers"]:
            if h["header_type"] == "ipv4_t":
                h["header_type"] = "zz_t"

    sr = eth(0x1234) + srcroutes([2, 3, 1]) + ipv4(H1, H2, 17, udp(1234, 4321, b"m"))
    tun = eth(0x1212) + mytunnel(0x0800, 2) + ipv4(H1, H2, 6, tcp(50002, 1234, payload=b"hi"))
    wsr, wtun = (20, T(H1, H2, 17, 1234, 4321)), (18, T(H1, H2, 6, 50002, 1234))
    tests = [
        ("K1-srcroute-24bit", corrupt("source_routing", widen_srcroute), sr, ("SAFE", 20), wsr, True,
         "srcRoute_t widened 16->24 bits; sanity check on"),
        ("K1b-srcroute-24bit-nosanity", corrupt("source_routing", widen_srcroute), sr,
         ("NOT", 20), wsr, False, "same, version/ihl sanity check OFF"),
        ("K2-tunnel-fields-swapped", corrupt("basic_tunnel", swap_tunnel_fields), tun, ("SAFE", 18),
         wtun, True, "myTunnel_t field order swapped: key reads dst_id"),
        ("K3-tunnel-widened", corrupt("basic_tunnel", widen_tunnel), tun, ("SAFE", 18), wtun, True,
         "myTunnel_t dst_id 16->32 bits; sanity check on"),
        ("K3b-tunnel-widened-nosanity", corrupt("basic_tunnel", widen_tunnel), tun, ("NOT", 18),
         wtun, False, "same, sanity check OFF"),
        ("K4-ipv4-renamed", corrupt("basic_tunnel", rename_ipv4), tun, ("IP", 18), wtun, True,
         "POSITIVE control: IPv4 header type and every field renamed; structure unchanged"),
    ]
    for cid, prog, frame, exp, wire, sanity, note in tests:
        c = dict(id=cid, prog="(corrupted)", link="-", frame=frame, expect=exp, wire=wire,
                 ctx=ING(1), note=note, sanity=sanity)
        row = run_case(c, prog_override=prog)
        safe = "SAFE (refused / no identity)" if row["got"] != "IP" else (
            "CORRECT" if row["proto_vs_wire"] else "UNSAFE (wrong identity, no refusal)")
        row["safety"] = safe
        OUT["corrupt"].append(row)
        p(f"[{row['verdict']}] {cid:<30} {note}")
        p(f"        got: {row['got_short']}  -> {safe}")
        p(f"        states: {' > '.join(row['states'])}")


# ============================================================================================
# D. real wire frames from the bmv2 pcaps
# ============================================================================================

EX_DIR = "/home/adam/tutorials/exercises"
PCAP_PROG = {   # exercise -> (switch -> program), topology file
    "basic": ({}, "basic", "pod-topo/topology.json"),
    "basic_tunnel": ({}, "basic_tunnel", "topology.json"),
    "calc": ({}, "calc", "topology.json"),
    "ecn": ({}, "ecn", "topology.json"),
    "firewall": ({"s1": "firewall_fw"}, "firewall_basic", "pod-topo/topology.json"),
    "flowcache": ({}, "flowcache", "topology.json"),
    "link_monitor": ({}, "link_monitor", "pod-topo/topology.json"),
    "load_balance": ({}, "load_balance", "topology.json"),
    "mri": ({}, "mri", "topology.json"),
    "multicast": ({}, "multicast", "sig-topo/topology.json"),
    "p4runtime": ({}, "p4runtime", "topology.json"),
    "qos": ({}, "qos", "topology.json"),
    "source_routing": ({}, "source_routing", "topology.json"),
}
# which run wrote the pcaps (pcap time window vs doc/audit/.../runs/*.md timestamps)
PCAP_RUN = {
    "basic": "2026-09-18T110845Z solution", "basic_tunnel": "2026-09-24T095344Z solution",
    "calc": "2026-09-24T095418Z solution", "ecn": "2026-09-25T045407Z solution",
    "firewall": "2026-09-18T111149Z SKELETON (parser identical to solution)",
    "flowcache": "2026-09-24T131516Z solution",
    "link_monitor": "2026-09-18T113038Z SKELETON (parser identical to solution)",
    "load_balance": "2026-09-24T095641Z solution", "mri": "2026-09-24T095524Z solution",
    "multicast": "2026-09-24T095816Z solution", "p4runtime": "2026-09-24T131543Z solution",
    "qos": "2026-09-24T100048Z solution", "source_routing": "2026-09-18T110948Z solution",
}


def read_pcap(path):
    b = open(path, "rb").read()
    if len(b) < 24:
        return []
    magic = struct.unpack("<I", b[:4])[0]
    e = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
    off, out = 24, []
    while off + 16 <= len(b):
        _ts, _tu, incl, orig = struct.unpack(e + "IIII", b[off:off + 16])
        off += 16
        out.append((b[off:off + incl], orig))
        off += incl
    return out


def wire_oracle(frame, orig_len):
    """Independent of every JSON: lowest offset holding a plausible IPv4 header (version 4,
    ihl>=5, and a valid header checksum OR totalLen consistent with the frame length), or
    IPv6 right after an 0x86dd ethertype."""
    n = len(frame)
    if n >= 54 and frame[12:14] == b"\x86\xdd" and frame[14] >> 4 == 6:
        return 14, "ipv6"
    for o in range(14, n - 19):
        v = frame[o]
        if v >> 4 != 4 or (v & 0xF) < 5:
            continue
        ihl = (v & 0xF) * 4
        if o + ihl > n:
            continue
        total = struct.unpack(">H", frame[o + 2:o + 4])[0]
        if csum(frame[o:o + ihl]) == 0 or (total >= ihl and o + total == orig_len):
            return o, "ipv4"
    return None, None


def host_ports(topo):
    hp = set()
    for link in topo["links"]:
        a, b = link[0], link[1]
        for x, y in ((a, b), (b, a)):
            if x.startswith("h") and "-p" in y:
                sw, port = y.split("-p")
                hp.add((sw, int(port)))
    return hp


def part_d():
    p()
    p("=" * 100)
    p("D. REAL WIRE FRAMES: every frame in /home/adam/tutorials/exercises/*/pcaps/ (bmv2 --pcap,")
    p("   per switch port), truncated to 128 B. Sampled set = what link_telemetry.py:332-351")
    p("   would sample: every *_in (ingress filter on every port) + *_out on host-facing ports.")
    p("   Program applied: the RECEIVING switch's program for *_in (ingress_port = N from sN-ethN);")
    p("   for host-facing *_out (egress, receiver is a host) the SENDING switch's program.")
    p("=" * 100)
    grand = Counter()
    for ex, (override, default_prog, topo_rel) in PCAP_PROG.items():
        topo = json.load(open(os.path.join(EX_DIR, ex, topo_rel)))
        hp = host_ports(topo)
        files = sorted(glob.glob(os.path.join(EX_DIR, ex, "pcaps", "*.pcap")))
        tally = Counter()
        path_tally = Counter()
        examples = {}
        shas = {}
        for fpath in files:
            base = os.path.basename(fpath)[:-5]           # s1-eth2_in
            ifn, direction = base.rsplit("_", 1)
            sw, port = ifn.split("-eth")
            port = int(port)
            sampled = direction == "in" or (sw, port) in hp
            if not sampled:
                continue
            shas[base] = hashlib.sha256(open(fpath, "rb").read()).hexdigest()[:12]
            prog = PROGS[override.get(sw, default_prog)]
            for frame, orig in read_pcap(fpath):
                cap = frame[:CAP]
                ctx = ING(port) if direction == "in" else ING(port)  # see note in report
                r = interpret(prog, cap, orig_len=orig, ctx=ctx)
                woff, wfam = wire_oracle(cap, orig)
                nat = native_identify(cap)
                hin = hints_identify(HINTS.get(override.get(sw, default_prog), {}), cap)
                et = cap[12:14].hex()
                pname = override.get(sw, default_prog)
                pid = path_of(pname, r.states, r.status, r.detail)
                path_tally[(pname, pid, r.status)] += 1
                # prototype vs wire
                if woff is None:
                    pv = "agree-no-ip" if r.status != "IP" else "WRONG-ip-claimed"
                elif r.status == "IP":
                    pv = "agree-ip" if r.ip_offset == woff else "WRONG-offset"
                else:
                    pv = f"miss({r.status})"
                nv = ("agree-ip" if (woff is not None and nat[0] == wfam) else
                      "agree-no-ip" if (woff is None and nat[0] not in ("ipv4", "ipv6")) else
                      "miss" if woff is not None else "WRONG")
                hv = ("agree-ip" if (woff is not None and hin[0] == wfam) else
                      "agree-no-ip" if (woff is None and hin[0] not in ("ipv4", "ipv6")) else
                      "miss" if woff is not None else "WRONG")
                cb = "agree-ip" if (woff is not None and (nat[0] == wfam or (
                    r.status == "IP" and r.ip_offset == woff))) else (
                    "agree-no-ip" if woff is None else "miss")
                key = (direction, et, pv, nv, hv, cb)
                tally[key] += 1
                examples.setdefault(key, (base, r.short(), nat[0], woff))
        OUT["pcap"][ex] = {"run": PCAP_RUN[ex], "files_sha256_12": shas,
                           "paths": [[list(k), v] for k, v in sorted(path_tally.items())],
                           "tally": [[list(k), v] for k, v in sorted(tally.items())],
                           "examples": {"|".join(k): v for k, v in examples.items()}}
        p(f"-- {ex}  [pcaps from run {PCAP_RUN[ex]}]  sampled files={len(shas)}")
        p(f"   {'dir':<4} {'ethtype':<7} {'program-vs-wire':<18} {'native-model':<12}"
          f" {'hints':<12} {'combined':<12} frames  example")
        for k, v in sorted(tally.items(), key=lambda kv: (-kv[1], kv[0])):
            exn = examples[k]
            p(f"   {k[0]:<4} {k[1]:<7} {k[2]:<18} {k[3]:<12} {k[4]:<12} {k[5]:<12} {v:>6}  "
              f"{exn[0]}: {exn[1][:60]}")
            grand[(ex,) + k] += v
        p("   paths walked: " + ", ".join(f"{k[0]}:{k[1]}({k[2]})={v}"
                                          for k, v in sorted(path_tally.items())))
    OUT["pcap_grand"] = [[list(k), v] for k, v in grand.items()]


# ============================================================================================
# E. rates, computed from A/B/D above (so the report's numbers come from this run)
# ============================================================================================

CORPUS = ["basic", "basic_tunnel", "calc", "ecn", "firewall_basic", "firewall_fw", "flowcache",
          "link_monitor", "load_balance", "mri", "multicast", "p4runtime", "qos",
          "source_routing", "ndtwin_switch"]
CUSTOM7 = ["basic_tunnel", "calc", "flowcache", "link_monitor", "mri", "p4runtime",
           "source_routing"]
CPU_LABEL = {"flowcache": "0x01fe", "ndtwin_switch": "0x00ff"}   # topology.json / .p4:45


def part_e():
    p()
    p("=" * 100)
    p("E. SUCCESS RATES (computed from parts A, B, D of this run)")
    p("=" * 100)
    ran_paths = defaultdict(set)
    import re
    exact = re.compile(r"^P\d+$")   # a run counts as coverage only if it walked ONE whole path
    for row in OUT["cases"]:
        if row["verdict"] == "PASS" and exact.match(str(row["path"])):
            ran_paths[row["prog"]].add(row["path"])
    pcap_paths = defaultdict(Counter)
    for ex, d in OUT["pcap"].items():
        for (pname, pid, status), v in d["paths"]:
            if exact.match(str(pid)):
                pcap_paths[pname][pid] += v
    table = []
    for name in CORPUS:
        for i, row in enumerate(OUT["static"][name], 1):
            pid = f"P{i}"
            cpu_only = name in CPU_LABEL and row["path"].startswith(f"start -[{CPU_LABEL[name]}]")
            table.append(dict(prog=name, pid=pid, klass=row["class"], cpu_only=cpu_only,
                              ran_case=pid in ran_paths[name],
                              pcap_frames=pcap_paths[name].get(pid, 0)))
    OUT["path_table"] = table
    p("  per path: program path class cpu_only synthesized_case_PASS pcap_frames_walking_it")
    for r in table:
        p(f"    {r['prog']:<15} {r['pid']:<4} {r['klass']:<2} cpu_only={str(r['cpu_only']):<5}"
          f" case={'yes' if r['ran_case'] else 'no':<3} pcap_frames={r['pcap_frames']}")

    def rate(rows, label):
        ip = [r for r in rows if r["klass"] != "X"]
        x = [r for r in rows if r["klass"] == "X"]
        strict = [r for r in ip if r["klass"] in ("D1", "D2")]
        wire = [r for r in ip if not r["cpu_only"]]
        wire_strict = [r for r in wire if r["klass"] in ("D1", "D2")]
        p(f"  {label}: paths={len(rows)}  X={len(x)}  IP-bearing={len(ip)} "
          f"(D1={sum(r['klass']=='D1' for r in ip)} D2={sum(r['klass']=='D2' for r in ip)} "
          f"N={sum(r['klass']=='N' for r in ip)})")
        p(f"      strict (bytes+JSON only): {len(strict)}/{len(ip)} IP-bearing paths derivable;"
          f" with the sample's ingress port as context: {len(ip)}/{len(ip)}")
        p(f"      excluding CPU-port-only paths (never on a sampled veth): strict "
          f"{len(wire_strict)}/{len(wire)}, with port context {len(wire)}/{len(wire)}")
        ran = [r for r in ip if r["ran_case"]]
        p(f"      IP-bearing paths with a PASSing synthesized case: {len(ran)}/{len(ip)};"
          f" with >=1 real pcap frame: {sum(1 for r in ip if r['pcap_frames'])}/{len(ip)}")
        return dict(paths=len(rows), x=len(x), ip=len(ip), strict=len(strict),
                    wire=len(wire), wire_strict=len(wire_strict))

    OUT["rates"] = {"corpus": rate(table, "ALL 15 programs"),
                    "custom7": rate([r for r in table if r["prog"] in CUSTOM7],
                                    "7 custom-header exercises")}
    p("  per program (IP-bearing paths derivable strict / with port ctx / total; X paths):")
    perprog = {}
    for name in CORPUS:
        rows = [r for r in table if r["prog"] == name]
        ip = [r for r in rows if r["klass"] != "X"]
        s = sum(r["klass"] in ("D1", "D2") for r in ip)
        perprog[name] = (s, len(ip), len(ip), len(rows) - len(ip))
        verdict = ("no IP path" if not ip else "ALL" if s == len(ip) else
                   "NONE strict" if s == 0 else "PARTIAL")
        p(f"    {name:<15} {s}/{len(ip)} strict, {len(ip)}/{len(ip)} ctx, X={len(rows)-len(ip)}"
          f"  -> {verdict}")
    OUT["perprog"] = perprog
    have_ip = [n for n in CORPUS if perprog[n][1] > 0]
    full = [n for n in have_ip if perprog[n][0] == perprog[n][1]]
    p(f"  programs with >=1 IP path: {len(have_ip)}/{len(CORPUS)}; fully derivable strict: "
      f"{len(full)}/{len(have_ip)}; with port ctx: {len(have_ip)}/{len(have_ip)}")
    c7 = [n for n in CUSTOM7 if perprog[n][1] > 0]
    c7full = [n for n in c7 if perprog[n][0] == perprog[n][1]]
    p(f"  custom-header 7: with IP path {len(c7)}/7 ({', '.join(c7)}); fully derivable strict "
      f"{len(c7full)}/{len(c7)}; with port ctx {len(c7)}/{len(c7)}")

    # frame level
    p("  real frames (part D), sampled set, truncated to 128 B:")
    tot = Counter()
    for k, v in OUT["pcap_grand"]:
        ex, direction, et, pv, nv, hv, cb = k
        has_ip = not pv.startswith("agree-no-ip") and pv != "WRONG-ip-claimed"
        tot["frames"] += v
        if has_ip:
            tot["ip_on_wire"] += v
            tot["prog_ok"] += v * (pv == "agree-ip")
            tot["native_ok"] += v * (nv == "agree-ip")
            tot["hints_ok"] += v * (hv == "agree-ip")
            tot["comb_ok"] += v * (cb == "agree-ip")
            if nv != "agree-ip" and pv == "agree-ip":
                tot["prog_adds"] += v
            if et == "86dd":
                tot["ipv6"] += v
        else:
            tot["no_ip"] += v
        tot["wrong"] += v * (pv.startswith("WRONG") or nv == "WRONG")
    for k in ("frames", "ip_on_wire", "no_ip", "ipv6", "prog_ok", "native_ok", "hints_ok",
              "comb_ok", "prog_adds", "wrong"):
        p(f"    {k:<11} {tot[k]}")
    OUT["frame_rates"] = dict(tot)


if __name__ == "__main__":
    part_a()
    part_b()
    part_c()
    if os.environ.get("SKIP_PCAP") != "1":
        part_d()
        part_e()
    with open(os.path.join(HERE, "results.json"), "w") as fh:
        json.dump(OUT, fh, indent=1, default=str)
    p()
    p("=" * 100)
    n_b = len(OUT["cases"]) + len(OUT["corrupt"])
    p(f"SUMMARY: {n_b - len(FAILS)}/{n_b} synthesized+corrupted cases matched expectation; "
      f"failures: {FAILS or 'none'}")
    sys.exit(1 if FAILS else 0)
