"""Marker frames, built and parsed with struct alone, and pcap files read and written.

[Co-developed with claude code -- Adam]

design section 2.1 "marker": every active stimulus carries the sender's MAC, the cell's own UDP
dport (40001-40099), and a payload that starts b"NDTHC" + run id + cell id + sequence number.
S0's offline self-checks run the program on a throwaway bmv2 in pcap mode and need the same
frames without scapy (the p4_proxy venv has none); the live sender (Cut 2) uses scapy in the
p4dev venv and must produce byte-identical markers -- test_p4_health_cells pins the layout.
"""
from __future__ import annotations

import struct

MAGIC = b"NDTHC"
ETH_IPV4, ETH_IPV6, ETH_VLAN, ETH_HB = 0x0800, 0x86DD, 0x8100, 0x88B5
ETH_TUNNEL, ETH_SRCROUTE, ETH_HCL2, ETH_UALT = 0x1212, 0x1234, 0x1236, 0x1238
PROTO_UDP, PROTO_TCP, PROTO_SHIM = 17, 6, 0xFD
FLAG_RESUB, FLAG_RECIRC = 0x04, 0x08


def mac_bytes(mac):
    return bytes(int(x, 16) for x in mac.split(":"))


def mac_str(raw):
    return ":".join("%02x" % b for b in raw)


def ip_bytes(ip):
    return bytes(int(x) for x in ip.split("."))


def ip_str(raw):
    return ".".join(str(b) for b in raw)


def checksum16(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def payload(run_id, cell, seq):
    """b"NDTHC" | run id (8 bytes) | cell id (8 bytes) | seq (4 bytes)."""
    rid = run_id.encode("ascii")[:8].ljust(8, b"\0")
    cid = cell.encode("ascii")[:8].ljust(8, b"\0")
    return MAGIC + rid + cid + struct.pack("!I", seq)


def parse_payload(raw):
    """(run_id, cell, seq) out of a marker payload, or None when it is not one."""
    if len(raw) < 25 or not raw.startswith(MAGIC):
        return None
    rid = raw[5:13].rstrip(b"\0").decode("ascii", "replace")
    cid = raw[13:21].rstrip(b"\0").decode("ascii", "replace")
    (seq,) = struct.unpack("!I", raw[21:25])
    return rid, cid, seq


def ipv4_header(src, dst, proto, body_len, ttl=64, ident=1, diffserv=0, options=b""):
    if len(options) % 4:
        raise ValueError("IPv4 options must be a multiple of 4 bytes")
    ihl = 5 + len(options) // 4
    head = struct.pack("!BBHHHBBH4s4s", (4 << 4) | ihl, diffserv, ihl * 4 + body_len, ident, 0,
                       ttl, proto, 0, ip_bytes(src), ip_bytes(dst)) + options
    csum = checksum16(head)
    return head[:10] + struct.pack("!H", csum) + head[12:]


def udp(sport, dport, body):
    return struct.pack("!HHHH", sport, dport, 8 + len(body), 0) + body


def ethernet(dst, src, ethertype, body):
    return mac_bytes(dst) + mac_bytes(src) + struct.pack("!H", ethertype) + body


def udp_marker(src_mac, dst_mac, src_ip, dst_ip, dport, run_id="s0", cell="", seq=0, sport=40000,
               ttl=64, ident=1, diffserv=0, options=b"", extra=b""):
    """An IPv4/UDP marker. `extra` is put between the UDP header and the payload (VB1's length
    byte and tail, CH6's shim)."""
    body = udp(sport, dport, extra + payload(run_id, cell, seq))
    ip = ipv4_header(src_ip, dst_ip, PROTO_UDP, len(body), ttl=ttl, ident=ident,
                     diffserv=diffserv, options=options)
    return ethernet(dst_mac, src_mac, ETH_IPV4, ip + body).ljust(60, b"\0")


def ipv6_marker(src_mac, dst_mac, src_lo, dst_lo, run_id="s0", cell="HU1", seq=0, hop_limit=64):
    """An IPv6/UDP-shaped marker to fd00::<dst_lo> (the program keys on the low 32 bits)."""
    body = udp(40000, 40097, payload(run_id, cell, seq))
    src = b"\xfd" + b"\0" * 11 + struct.pack("!I", src_lo)
    dst = b"\xfd" + b"\0" * 11 + struct.pack("!I", dst_lo)
    head = struct.pack("!IHBB", 6 << 28, len(body), PROTO_UDP, hop_limit) + src + dst
    return ethernet(dst_mac, src_mac, ETH_IPV6, head + body).ljust(60, b"\0")


def heartbeat_like(src_mac="02:4e:44:00:00:01"):
    """An 0x88B5 frame (only the ethertype matters to the program)."""
    return ethernet("02:4e:44:54:48:42", src_mac, ETH_HB, b"NDHB" + b"\0" * 46)


def tunnel_frame(src_mac, dst_mac, dst_id, src_ip, dst_ip, run_id="s0", cell="CH1", seq=0):
    inner = udp_marker(src_mac, dst_mac, src_ip, dst_ip, 40001, run_id, cell, seq)[14:]
    return ethernet(dst_mac, src_mac, ETH_TUNNEL, struct.pack("!HH", ETH_IPV4, dst_id) + inner)


def hcl2_frame(src_mac, dst_mac, dst_id, run_id="s0", cell="CH7", seq=0):
    return ethernet(dst_mac, src_mac, ETH_HCL2,
                    struct.pack("!HHI", dst_id, 0, seq) + payload(run_id, cell, seq)).ljust(60, b"\0")


def alt6_frame(src_mac, dst_mac, dst_id, run_id="s0", cell="HU1x", seq=0):
    return ethernet(dst_mac, src_mac, ETH_UALT,
                    struct.pack("!HH", dst_id, 1) + payload(run_id, cell, seq)).ljust(60, b"\0")


def srcroute_frame(src_mac, dst_mac, ports, src_ip, dst_ip, run_id="s0", cell="CH2", seq=0):
    stack = b""
    for i, port in enumerate(ports):
        bos = 1 if i == len(ports) - 1 else 0
        stack += struct.pack("!H", (bos << 15) | port)
    inner = udp_marker(src_mac, dst_mac, src_ip, dst_ip, 40002, run_id, cell, seq)[14:]
    return ethernet(dst_mac, src_mac, ETH_SRCROUTE, stack + inner)


def vlan_frame(src_mac, dst_mac, vid, src_ip, dst_ip, run_id="s0", cell="CH5", seq=0):
    inner = udp_marker(src_mac, dst_mac, src_ip, dst_ip, 40005, run_id, cell, seq)[14:]
    return ethernet(dst_mac, src_mac, ETH_VLAN, struct.pack("!HH", vid & 0x0FFF, ETH_IPV4) + inner)


def shim_frame(src_mac, dst_mac, src_ip, dst_ip, run_id="s0", cell="CH4", seq=0):
    """CH4: IPv4 protocol 0xFD, a 4-byte shim, then UDP."""
    body = struct.pack("!BBH", PROTO_UDP, 4, 0xC4C4) + udp(40000, 40004, payload(run_id, cell, seq))
    ip = ipv4_header(src_ip, dst_ip, PROTO_SHIM, len(body))
    return ethernet(dst_mac, src_mac, ETH_IPV4, ip + body).ljust(60, b"\0")


# --- parsing what came out ---------------------------------------------------------------------

def parse(frame):
    """A dict of what this module can say about a frame (enough for the offline self-checks)."""
    out = {"len": len(frame)}
    if len(frame) < 14:
        return out
    out["dst"], out["src"] = mac_str(frame[0:6]), mac_str(frame[6:12])
    (etype,) = struct.unpack("!H", frame[12:14])
    out["ethertype"] = etype
    off = 14
    if etype == ETH_IPV4 and len(frame) >= off + 20:
        vihl, ds, total, ident, _ff, ttl, proto, csum = struct.unpack("!BBHHHBBH", frame[off:off + 12])
        ihl = vihl & 0x0F
        out.update({"ttl": ttl, "ident": ident, "diffserv": ds, "proto": proto,
                    "ip_src": ip_str(frame[off + 12:off + 16]),
                    "ip_dst": ip_str(frame[off + 16:off + 20]), "ihl": ihl,
                    "ip_csum_ok": checksum16(frame[off:off + ihl * 4]) == 0})
        off += ihl * 4
        if proto == PROTO_UDP and len(frame) >= off + 8:
            sport, dport, _ulen, _uc = struct.unpack("!HHHH", frame[off:off + 8])
            out["sport"], out["dport"] = sport, dport
            mark = frame.find(MAGIC, off + 8)
            if mark >= 0:
                out["marker"] = parse_payload(frame[mark:])
        else:
            mark = frame.find(MAGIC, off)
            if mark >= 0:
                out["marker"] = parse_payload(frame[mark:])
    elif etype == ETH_IPV6 and len(frame) >= off + 40:
        out["hop_limit"] = frame[off + 7]
        (out["v6_dst_lo"],) = struct.unpack("!I", frame[off + 36:off + 40])
    else:
        mark = frame.find(MAGIC, off)
        if mark >= 0:
            out["marker"] = parse_payload(frame[mark:])
    return out


def packet_in_split(frame):
    """(ingress_port, rest) for a frame that left on the CPU port with the 2-byte packet_in."""
    if len(frame) < 2:
        return None, frame
    (word,) = struct.unpack("!H", frame[:2])
    return word >> 7, frame[2:]


def write_pcap(path, frames):
    with open(path, "wb") as fh:
        fh.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        for i, frame in enumerate(frames):
            fh.write(struct.pack("<IIII", 1 + i, 0, len(frame), len(frame)))
            fh.write(frame)


def read_pcap(path):
    """Every frame in a pcap file, in order; None when the file is missing or is not a pcap
    (unreadable is not "no frames")."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    if len(data) < 24 or data[:4] not in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4"):
        return None
    frames, off = [], 24
    while off + 16 <= len(data):
        incl = struct.unpack_from("<I", data, off + 8)[0]
        frames.append(data[off + 16:off + 16 + incl])
        off += 16 + incl
    return frames
