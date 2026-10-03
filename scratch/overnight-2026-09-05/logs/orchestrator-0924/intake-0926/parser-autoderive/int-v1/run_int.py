#!/usr/bin/env python3
"""int-v1 (niloysh/int-v1 @84a3ebe8): does today's flow identity (native MODEL of identifyFrame)
or p4pi misread the 5-tuple of INT traffic?

[Co-developed with claude code -- Adam]

Frames are built with struct to the layout int-v1's own parser/deparser define:
  Ether / IPv4(dscp=0x17 when INT) / UDP|TCP / INT shim(4) / INT header(8) / metadata(4*w) / payload
(include/parser.p4:36-70 parse order, :96-116 emit order; include/int_source.p4:21-53 source action).
Every frame is truncated to 128 B like link_telemetry.py:75 / sflow_emitter.py:174, with the true
original length passed separately.
Exit 0 only if every expectation holds.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from p4pi import Program, interpret, native_identify  # noqa: E402
from pkts import csum, udp, tcp  # noqa: E402
import socket  # noqa: E402

CAP = 128
PROG = Program(os.path.join(HERE, "int.json"))
H1, H2 = "10.0.1.1", "10.0.2.2"
SPORT, DPORT = 8001, 8002                          # send.py:37-38
MAC_DST = bytes.fromhex("080000000222")            # send.py:37
MAC_SRC = bytes.fromhex("080000000111")
MSG = b"hello int"


def ipv4_hdr(proto, total_len, dscp=0, ttl=64):
    h = struct.pack(">BBHHHBBH4s4s", 0x45, (dscp << 2), total_len, 1, 0, ttl, proto, 0,
                    socket.inet_aton(H1), socket.inet_aton(H2))
    return h[:10] + struct.pack(">H", csum(h)) + h[12:]


def int_shim(words, orig_dscp=0):                   # headers.p4:73-78
    return struct.pack(">BBBB", 1, 0, words, orig_dscp << 2)


def int_header(hop_ml=8, remaining=4, m0003=0xF, m0407=0xF):   # headers.p4:82-96
    # ver4 rep2 c1 e1 m1 rsvd1:7 rsvd2:3 hop_ml:5 remaining:8 masks 4x4 rsvd3:16
    w0 = (0 << 28) | (0 << 26) | (0 << 25) | (0 << 24) | (0 << 23) | (0 << 16) \
        | (0 << 13) | ((hop_ml & 0x1F) << 8) | (remaining & 0xFF)
    w1 = (m0003 << 28) | (m0407 << 24) | (0 << 20) | (0 << 16) | 0
    return struct.pack(">II", w0, w1)


def frame(l4="udp", hops=None, ttl=64, int_between_ip_and_l4=False):
    """hops=None: no INT (before the source). hops=0: what int_source emits (shim+header, no
    metadata). hops=k>0: k nodes' metadata of hop_metadata_len=8 words each (INT v1.0 layout;
    int-v1 @84a3ebe8 has NO transit code that would add it -- hypothetical)."""
    if hops is None:
        intb, dscp = b"", 0
    else:
        md = b"".join(struct.pack(">I", 0x51000000 + (k << 8) + w)
                      for k in range(hops) for w in range(8))
        intb = int_shim(3 + 8 * hops) + int_header(remaining=4 - hops) + md
        dscp = 0x17
    if l4 == "udp":
        l4h = udp(SPORT, DPORT, MSG)
        l4h = l4h[:4] + struct.pack(">H", len(l4h) + len(intb)) + l4h[6:]
        proto = 17
    else:
        l4h = tcp(SPORT, DPORT, flags=0x18, payload=MSG)
        proto = 6
    hdr_l4, payload = l4h[: (8 if l4 == "udp" else 20)], l4h[(8 if l4 == "udp" else 20):]
    if int_between_ip_and_l4:
        body = intb + hdr_l4 + payload
    else:
        body = hdr_l4 + intb + payload              # parser.p4:96-103 emit order
    ip = ipv4_hdr(proto, 20 + len(body), dscp=dscp, ttl=ttl)
    return MAC_DST + MAC_SRC + b"\x08\x00" + ip + body


def truth(l4):
    return (H1, H2, 17 if l4 == "udp" else 6, SPORT, DPORT)


def p4pi_with_program_l4(res, fr):
    """Item 4: same run, ports read at l4_program_offset instead of ip_off+ihl*4."""
    if res.status != "IP" or res.l4_program_offset is None:
        return None
    o = res.l4_program_offset
    sp, dp = struct.unpack(">HH", fr[o:o + 4])
    s, d, p, _, _ = res.five_tuple
    return (s, d, p, sp, dp)


CASES = [
    # id, link (per the code), frame kwargs, which it is
    ("F0-before-source", "h1->s1 ingress (s1-eth1_in)", dict(hops=None), "REAL layout (send.py)"),
    ("F1-after-source", "s1->s3, s3->s2 ingress; s2->h2 egress (TTL differs only)",
     dict(hops=0), "REAL layout (int_source.p4:21-53)"),
    ("F1-at-h2", "s2->h2 egress after 3 TTL decrements", dict(hops=0, ttl=61),
     "REAL layout: no sink strip exists in this commit"),
    ("F2-1hop-md", "hypothetical: 1 node's 8-word metadata", dict(hops=1), "HYPOTHETICAL (INT v1.0)"),
    ("F3-2hop-md", "hypothetical: 2 nodes", dict(hops=2), "HYPOTHETICAL (INT v1.0)"),
    ("F4-4hop-md", "hypothetical: 4 nodes (remaining_hop_cnt=4 exhausted)", dict(hops=4),
     "HYPOTHETICAL (INT v1.0)"),
    ("F5-sink-stripped", "hypothetical: what a sink would deliver (= F0 + TTL)",
     dict(hops=None, ttl=61), "HYPOTHETICAL: no strip code in this commit"),
    ("T1-tcp-after-source", "INT over TCP after the source", dict(l4="tcp", hops=0),
     "REAL layout (parse_tcp also selects on dscp, parser.p4:36-45)"),
    ("T2-tcp-2hop-md", "INT over TCP, 2 nodes", dict(l4="tcp", hops=2), "HYPOTHETICAL"),
    ("X1-shim-between-ip-and-udp", "CONTROL: the layout PAPER-APPS-CANDIDATES.md section 3 claims",
     dict(hops=1, int_between_ip_and_l4=True), "NOT int-v1's layout -- control for the claim"),
]


def main():
    bad = 0
    print(f"int.json: {PROG.path}; parse paths enumerated separately (see static.log)")
    print(f"{'case':<28} {'orig':>4} {'cap':>4}  {'native-model':<46} {'p4pi as-is (ihl*4)':<58}"
          f" {'p4pi @l4_program_offset':<40} truth")
    for cid, link, kw, kind in CASES:
        fr = frame(**kw)
        cap = fr[:CAP]
        l4 = kw.get("l4", "udp")
        tru = truth(l4)
        nat = native_identify(cap)
        r = interpret(PROG, cap, orig_len=len(fr), ctx={"standard_metadata.ingress_port": 1})
        alt = p4pi_with_program_l4(r, cap)

        def judge(t):
            if t is None:
                return "none"
            return "RIGHT" if t == tru else "SILENT-WRONG"
        nat_t = nat[1] if nat[0] == "ipv4" else None
        nat_v = judge(nat_t) if nat[0] == "ipv4" else f"fallback:{nat[0]}"
        p_t = r.five_tuple if r.status == "IP" else None
        p_v = judge(p_t) if r.status == "IP" else f"refuse/none:{r.status}"
        a_v = judge(alt) if alt is not None else "n/a(no L4 extracted)"
        print(f"{cid:<28} {len(fr):>4} {len(cap):>4}  {nat_v + ' ' + str(nat_t):<46} "
              f"{p_v + ' ' + r.short()[:44]:<58} {a_v + ' ' + str(alt)[:26]:<40} {tru}")
        print(f"{'':<28} link: {link} [{kind}]; p4pi states: {' > '.join(r.states)};"
              f" extracted: {[(n, o, l) for n, o, l, _ in r.extracted]};"
              f" l4_program_offset={r.l4_program_offset}; detail={r.detail!r}")
        # expectations: int-v1's real layout puts L4 before INT -> both must be RIGHT
        if not cid.startswith("X1"):
            ok = nat_v == "RIGHT" and p_v == "RIGHT" and (alt is None or a_v == "RIGHT")
        else:
            # control: the misread layout must be detected as SILENT-WRONG for native
            ok = nat_v == "SILENT-WRONG"
        if not ok:
            bad += 1
            print(f"{'':<28} ** EXPECTATION FAILED")
    print(f"SUMMARY: {len(CASES) - bad}/{len(CASES)} expectations held")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
