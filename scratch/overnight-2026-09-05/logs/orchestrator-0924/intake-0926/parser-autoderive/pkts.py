"""Plain-struct packet builders mirroring the tutorials' send.py files (no scapy here).

[Co-developed with claude code -- Adam]
"""
import socket
import struct

BCAST = b"\xff" * 6


def mac(n: int) -> bytes:
    return bytes([0x08, 0x00, 0x00, 0x00, 0x00, n & 0xFF])


def eth(etype: int, dst: bytes = BCAST, src: bytes = mac(0x11)) -> bytes:
    return dst + src + struct.pack(">H", etype)


def csum(b: bytes) -> int:
    if len(b) % 2:
        b += b"\x00"
    s = sum(struct.unpack(">%dH" % (len(b) // 2), b))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def ipv4(src: str, dst: str, proto: int, payload: bytes, tos: int = 0, options: bytes = b"",
         ttl: int = 64, ident: int = 1, flags_frag: int = 0, ihl_override=None) -> bytes:
    assert len(options) % 4 == 0
    ihl = 5 + len(options) // 4 if ihl_override is None else ihl_override
    total = 20 + len(options) + len(payload)
    hdr = struct.pack(">BBHHHBBH4s4s", (4 << 4) | ihl, tos, total, ident, flags_frag, ttl,
                      proto, 0, socket.inet_aton(src), socket.inet_aton(dst)) + options
    c = csum(hdr)
    hdr = hdr[:10] + struct.pack(">H", c) + hdr[12:]
    return hdr + payload


def tcp(sport: int, dport: int, flags: int = 0x02, payload: bytes = b"") -> bytes:
    return struct.pack(">HHIIBBHHH", sport, dport, 0, 0, 5 << 4, flags, 8192, 0, 0) + payload


def udp(sport: int, dport: int, payload: bytes = b"") -> bytes:
    return struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload


def icmp_echo(ident: int = 1, seq: int = 1, payload: bytes = b"x" * 56) -> bytes:
    body = struct.pack(">BBHHH", 8, 0, 0, ident, seq) + payload
    c = csum(body)
    return body[:2] + struct.pack(">H", c) + body[4:]


def ipv6_udp(sport, dport, payload=b"") -> bytes:
    u = udp(sport, dport, payload)
    return struct.pack(">IHBB", 6 << 28, len(u), 17, 64) + \
        socket.inet_pton(socket.AF_INET6, "fe80::1") + \
        socket.inet_pton(socket.AF_INET6, "fe80::2") + u


# --- exercise headers ---------------------------------------------------------------------

def mytunnel(proto_id: int, dst_id: int) -> bytes:          # basic_tunnel / p4runtime
    return struct.pack(">HH", proto_id, dst_id)


def srcroutes(ports, bos_last=True) -> bytes:                # source_routing send.py
    out = b""
    for i, p in enumerate(ports):
        bos = 1 if (bos_last and i == len(ports) - 1) else 0
        out += struct.pack(">H", (bos << 15) | (p & 0x7FFF))
    return out


def mri_option(swtraces) -> bytes:                           # mri send.py IPOption_MRI
    count = len(swtraces)
    body = struct.pack(">BBH", 0x1F, 4 + 8 * count, count)   # copy=0 class=0 option=31
    for swid, qdepth in swtraces:
        body += struct.pack(">II", swid, qdepth)
    return body


def p4calc(op: str, a: int, b: int, p=b"P", four=b"4", ver=1) -> bytes:  # calc.py
    return p + four + bytes([ver]) + op.encode() + struct.pack(">III", a, b, 0xDEADBABE)


def probe(hop_cnt: int, data, fwd) -> bytes:                 # link_monitor probe_hdrs.py
    out = bytes([hop_cnt])
    for i, (swid, port, byte_cnt, last_t, cur_t) in enumerate(data):
        bos = 1 if i == len(data) - 1 else 0
        out += bytes([(bos << 7) | (swid & 0x7F), port]) + struct.pack(">I", byte_cnt) + \
            last_t.to_bytes(6, "big") + cur_t.to_bytes(6, "big")
    for e in fwd:
        out += bytes([e])
    return out


def hop16(last: int, hop: int, port: int) -> bytes:          # syn_deep_stack hop_t
    return bytes([(last << 7) | hop, 0]) + struct.pack(">HIQ", port, 7, 123456789)


def pkt_ndtwin_packet_out(egress_port: int) -> bytes:
    return struct.pack(">H", (egress_port & 0x1FF) << 7)
