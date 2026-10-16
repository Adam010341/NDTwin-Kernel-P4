"""ONTAS (p4anony.p4) on s1, computed by hand: what one frame looks like after the switch.

[Co-developed with claude code -- Adam]

An independent model, written from reading p4anony.p4 at Princeton-Cabernet/p4-projects
e5c7cca1 (ONTAS/bmv2_p4_16/src) together with its s1-runtime.json -- no line of either is copied
here -- and NOT from anything bmv2 printed. offline_ontas.py and the live step's host verdict
compare the switch's output with it, byte for byte.

What the program does to a frame that comes in on port 1, with the app's runtime entries
(every ingress_port-keyed table has a port-1 entry; the two ternary tables match 72.14.213.0/24):

  * MAC. The OUI halves are kept (nop_action). The id half of the SOURCE MAC is replaced by
    crc32(id as 3 bytes) mod 24 -- v1model's hash(out, algo, base=0, data, max=24) is
    base + (h mod max), and the program passes the literal 24 (`32w24`), not 2^24. The id half
    of the DESTINATION MAC likewise, unless the destination OUI or id is all ones (broadcast) or
    dst_oui & 0x110000 == 0x010000 (the program's multicast test; note 33:33:.. passes it).
  * ARP (ethertype 0x0806, protoType 0x0800): the sender hardware id becomes the new source id;
    on a reply (opcode 2) whose destination id was hashed, the target hardware id becomes the
    new destination id; sender/target protocol addresses are anonymised as IPv4 is.
  * IPv4 (ethertype 0x0800, or 0x0800 inside one 802.1Q tag): an address in 72.14.213.0/24
    keeps its first 24 bits and its last octet becomes crc16_custom(last octet as a 32-bit
    value, 4 bytes) mod 8 (the 24-bit branch, `hashing_*24_tb`, max literal 8). Any other
    address is left as it is. The IPv4 header checksum is recomputed over the 20-byte fixed
    header (options, if any, are not part of it -- the program's update_checksum list).
    TCP/UDP are parsed and re-emitted untouched: their checksums are NOT fixed.
  * Forwarding: port 1 -> port 2. A frame on any other port meets forward_tb's default
    (NoAction), keeps egress_spec 0, and leaves on port 0, which a two-port throwaway does not
    have.

crc16_custom is computed here as CRC-16/ARC (poly 0x8005 reflected, init 0, no final xor) --
the same as `crc16`. That is an ASSUMPTION about bmv2's default parameters for the custom
algorithm when nothing configures it (the app configures nothing, and P4Runtime cannot); the
offline check is what confirms or refutes it.
"""
import struct
import zlib

ANON_NET, ANON_MASK = 0x480ED500, 0xFFFFFF00     # 72.14.213.0/24, s1-runtime.json


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def crc16_arc(data):
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def checksum16(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def anon_ip(ip):
    """The 32-bit address the program writes back."""
    if ip & ANON_MASK != ANON_NET:
        return ip
    return (ip & ANON_MASK) | (crc16_arc((ip & 0xFF).to_bytes(4, "big")) % 8)


def mac_id_hash(mac_id):
    return crc32(mac_id.to_bytes(3, "big")) % 24


def apply(frame, ingress_port):
    """(egress port, frame out) -- or (None, None) when the frame leaves on no port the
    throwaway has. Only frames at least as long as every header the program extracts."""
    if ingress_port != 1:
        return None, None
    out = bytearray(frame)
    dst_oui, dst_id = int.from_bytes(frame[0:3], "big"), int.from_bytes(frame[3:6], "big")
    src_id = int.from_bytes(frame[9:12], "big")
    new_src_id = mac_id_hash(src_id)
    out[9:12] = new_src_id.to_bytes(3, "big")
    dst_hashed = (dst_oui != 0xFFFFFF and dst_id != 0xFFFFFF
                  and (dst_oui & 0x110000) != 0x010000)
    new_dst_id = mac_id_hash(dst_id) if dst_hashed else dst_id
    if dst_hashed:
        out[3:6] = new_dst_id.to_bytes(3, "big")
    ethertype = struct.unpack("!H", frame[12:14])[0]
    off = 14
    if ethertype == 0x8100:
        ethertype = struct.unpack("!H", frame[16:18])[0]
        off = 18
        if ethertype != 0x0800:
            return 2, bytes(out)
    if ethertype == 0x0806 and off == 14:
        opcode = struct.unpack("!H", frame[20:22])[0]
        proto = struct.unpack("!H", frame[16:18])[0]
        if proto != 0x0800:
            return 2, bytes(out)
        a = 22                                   # arp_rarp_ipv4: sha 6, spa 4, tha 6, tpa 4
        out[a + 3:a + 6] = new_src_id.to_bytes(3, "big")
        if opcode == 2 and dst_hashed:
            out[a + 13:a + 16] = new_dst_id.to_bytes(3, "big")
        spa = int.from_bytes(frame[a + 6:a + 10], "big")
        tpa = int.from_bytes(frame[a + 16:a + 20], "big")
        out[a + 6:a + 10] = anon_ip(spa).to_bytes(4, "big")
        out[a + 16:a + 20] = anon_ip(tpa).to_bytes(4, "big")
        return 2, bytes(out)
    if ethertype == 0x0800:
        src = int.from_bytes(frame[off + 12:off + 16], "big")
        dst = int.from_bytes(frame[off + 16:off + 20], "big")
        out[off + 12:off + 16] = anon_ip(src).to_bytes(4, "big")
        out[off + 16:off + 20] = anon_ip(dst).to_bytes(4, "big")
        out[off + 10:off + 12] = b"\0\0"
        out[off + 10:off + 12] = struct.pack("!H", checksum16(bytes(out[off:off + 20])))
    return 2, bytes(out)


def needed_length(frame):
    """The bytes the program's parser extracts from this frame (it must have them all)."""
    ethertype = struct.unpack("!H", frame[12:14])[0] if len(frame) >= 14 else None
    if ethertype is None:
        return 14
    off = 14
    if ethertype == 0x8100:
        if len(frame) < 18:
            return 18
        ethertype, off = struct.unpack("!H", frame[16:18])[0], 18
        if ethertype != 0x0800:
            return 18
    if ethertype == 0x0806 and off == 14:
        if len(frame) < 22:
            return 22
        return 42 if struct.unpack("!H", frame[16:18])[0] == 0x0800 else 22
    if ethertype == 0x0800:
        if len(frame) < off + 20:
            return off + 20
        proto = frame[off + 9]
        return off + 20 + (20 if proto == 6 else 8 if proto == 17 else 0)
    return 14
