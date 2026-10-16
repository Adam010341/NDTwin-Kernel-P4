#!/usr/bin/env python3
"""int-v1's own check, made into a verdict: send its frame from a host, read the INT header off it.

[Co-developed with claude code -- Adam]

Run INSIDE a Mininet host's namespace (`sudo -n mnexec -a <pid> <p4dev python> this file ...`),
by live-p1/09_paper_int_v1.sh. int-v1 @84a3ebe8 ships send.py (one UDP 8001 -> 8002 frame) and
receive.py (sniff dport 8002 and `show2()` it) and no verdict: its README stops at "look at the
packet". This file sends the same frame and turns "look at it" into assertions taken from the
program (include/int_source.p4:21-53, include/fwd.p4 ipv4_forward):

    on a frame that crossed s1 from h1 (the one INT source, runtime_cmds/s1.sh):
      DSCP 0x17; ipv4.len and udp.length_ each 12 more than the frame that was sent;
      right after the UDP header a 4-byte shim (int_type 1, len 3, dscp = the sent DSCP 0)
      and an 8-byte INT header with hop_metadata_len 8, remaining_hop_cnt 4 and both
      instruction masks 0xF; the sent payload after that, unchanged;
    on a frame from h3 (never through s1's port 1): DSCP 0, no shim, lengths as sent.

    send <dst_ip> <dst_mac> <count> <tag>        frames tagged <tag>-<seq>
    sniff <seconds>                              every UDP dport 8002 frame, raw hex, as JSON
                                                 on stdout; READY on stderr once capturing
    verdict <capture.json> <tag> int|plain <count> <want_ttl>
    selftest                                     the verdict against frames built here

Uses scapy for the wire (the p4dev venv has it), struct for the reading: the verdict must not
depend on scapy's idea of what follows a UDP header.
"""
import json
import struct
import sys
import time

SPORT, DPORT = 8001, 8002
SHIM_TYPE, SHIM_LEN = 1, 3
HOP_ML, RHC, MASK0003, MASK0407 = 8, 4, 0xF, 0xF
DSCP_INT = 0x17


def iface():
    from scapy.all import get_if_list
    for name in get_if_list():
        if "eth0" in name:
            return name
    raise SystemExit("no *eth0 interface in this namespace")


def payload(tag, seq):
    return ("%s-%04d" % (tag, seq)).encode().ljust(32, b".")


def cmd_send(dst_ip, dst_mac, count, tag):
    from scapy.all import Ether, IP, UDP, Raw, get_if_hwaddr, sendp
    ifc = iface()
    for seq in range(int(count)):
        pkt = (Ether(src=get_if_hwaddr(ifc), dst=dst_mac) / IP(dst=dst_ip) /
               UDP(sport=SPORT, dport=DPORT) / Raw(payload(tag, seq)))
        sendp(pkt, iface=ifc, verbose=False)
        time.sleep(0.05)
    print("sent %d frame(s) tagged %s on %s to %s" % (int(count), tag, ifc, dst_ip))


def cmd_sniff(seconds):
    """JSON on stdout and READY on stderr, never a file: this runs as root inside the host's
    namespace, and the caller's shell (not root) creates the files both are redirected into."""
    from scapy.all import sniff
    ifc = iface()
    got = sniff(iface=ifc, timeout=float(seconds),
                started_callback=lambda: print("READY", file=sys.stderr, flush=True),
                lfilter=lambda p: bytes(p)[12:14] == b"\x08\x00" and bytes(p)[23] == 17
                and struct.unpack("!H", bytes(p)[36:38])[0] == DPORT)
    frames = [bytes(p).hex() for p in got]
    json.dump({"iface": ifc, "seconds": float(seconds), "frames": frames}, sys.stdout, indent=1)
    print("sniffed %d UDP dport %d frame(s) on %s" % (len(frames), DPORT, ifc), file=sys.stderr)


def read_frame(raw):
    """What the verdict needs out of one Ethernet/IPv4/UDP frame, by offset."""
    ihl = (raw[14] & 0xF) * 4
    ip = raw[14:14 + ihl]
    udp_at = 14 + ihl
    sport, dport, ulen = struct.unpack("!HHH", raw[udp_at:udp_at + 6])
    after = raw[udp_at + 8:]
    return {"dscp": ip[1] >> 2, "ip_len": struct.unpack("!H", ip[2:4])[0], "ttl": ip[8],
            "sport": sport, "dport": dport, "udp_len": ulen, "after_udp": after}


def judge(frame, tag, kind, want_ttl):
    """(tagged?, problems) for one captured frame."""
    f = read_frame(frame)
    after = f["after_udp"]
    mark = tag.encode() + b"-"
    has_shim, no_shim = after[12:].startswith(mark), after.startswith(mark)
    if not (has_shim or no_shim):
        return False, []
    problems = []
    if kind == "int" and not has_shim:
        problems.append("the payload follows the UDP header directly: no INT shim was inserted")
    if kind == "plain" and has_shim:
        problems.append("12 bytes sit between the UDP header and the payload: an INT shim")
    sent_udp_len = 8 + 32
    if f["ttl"] != want_ttl:
        problems.append("ttl %d, want %d (the path's hop count)" % (f["ttl"], want_ttl))
    if kind == "int":
        if f["dscp"] != DSCP_INT:
            problems.append("dscp %#x, want 0x17" % f["dscp"])
        if f["udp_len"] != sent_udp_len + 12:
            problems.append("udp.length_ %d, want %d" % (f["udp_len"], sent_udp_len + 12))
        if f["ip_len"] != 20 + sent_udp_len + 12:
            problems.append("ipv4.len %d, want %d" % (f["ip_len"], 20 + sent_udp_len + 12))
        shim = after[:4]
        hdr = after[4:12]
        if len(hdr) < 8 or shim[0] != SHIM_TYPE or shim[2] != SHIM_LEN or shim[3] >> 2 != 0:
            problems.append("shim %s, want int_type 1, len 3, dscp 0" % shim.hex())
        else:
            hop_ml, rhc = hdr[2] & 0x1F, hdr[3]
            m0003, m0407 = hdr[4] >> 4, hdr[4] & 0xF
            if (hop_ml, rhc, m0003, m0407) != (HOP_ML, RHC, MASK0003, MASK0407):
                problems.append("INT header hop_ml %d rhc %d masks %x/%x, want 8 4 f/f"
                                % (hop_ml, rhc, m0003, m0407))
    else:
        if f["dscp"] != 0:
            problems.append("dscp %#x, want 0 (no INT source on this path)" % f["dscp"])
        if f["udp_len"] != sent_udp_len or f["ip_len"] != 20 + sent_udp_len:
            problems.append("lengths ip %d udp %d, want %d %d (nothing inserted)"
                            % (f["ip_len"], f["udp_len"], 20 + sent_udp_len, sent_udp_len))
    return True, problems


def verdict(frames, tag, kind, count, want_ttl):
    """(ok, lines). ok: at least count-1 of `count` tagged frames arrived, and every one of
    them is what `kind` says. One lost frame of ten is allowed and said; a wrong header is not."""
    lines, seen, bad = [], 0, 0
    for raw in frames:
        tagged, problems = judge(raw, tag, kind, want_ttl)
        if not tagged:
            continue
        seen += 1
        if problems:
            bad += 1
            lines.append("  BAD %s" % "; ".join(problems))
    ok = seen >= int(count) - 1 and bad == 0
    lines.append("%s %s/%s: %d of %d tagged frame(s) arrived, %d with the wrong header"
                 % ("OK" if ok else "BAD", tag, kind, seen, int(count), bad))
    return ok, lines


def cmd_verdict(capture, tag, kind, count, want_ttl):
    with open(capture) as fh:
        frames = [bytes.fromhex(x) for x in json.load(fh)["frames"]]
    ok, lines = verdict(frames, tag, kind, count, int(want_ttl))
    print("\n".join(lines))
    return 0 if ok else 1


def _built(tag, seq, kind, ttl, dscp=None, hop_ml=HOP_ML):
    body = payload(tag, seq)
    insert = b""
    if kind == "int":
        insert = bytes([SHIM_TYPE, 0, SHIM_LEN, 0, 0, 0, hop_ml, RHC, 0xFF, 0, 0, 0])
    udp = struct.pack("!HHHH", SPORT, DPORT, 8 + len(body) + len(insert), 0)
    tos = ((DSCP_INT if kind == "int" else 0) if dscp is None else dscp) << 2
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, tos, 20 + len(udp) + len(insert) + len(body), 1, 0,
                     ttl, 17, 0, bytes([10, 0, 1, 1]), bytes([10, 0, 2, 2]))
    return b"\x08\x00\x00\x00\x02\x22" + b"\x08\x00\x00\x00\x01\x11" + b"\x08\x00" + ip + udp + \
        insert + body


def cmd_selftest():
    """Each verdict reads green on what it should and red on the near misses."""
    cases = [
        ("int frames read as int", [_built("a", i, "int", 61) for i in range(10)],
         "a", "int", 61, True),
        ("one lost of ten is allowed", [_built("a", i, "int", 61) for i in range(9)],
         "a", "int", 61, True),
        ("two lost of ten is not", [_built("a", i, "int", 61) for i in range(8)],
         "a", "int", 61, False),
        ("a plain frame is not an int frame", [_built("a", i, "plain", 61) for i in range(10)],
         "a", "int", 61, False),
        ("the wrong hop_metadata_len is caught",
         [_built("a", i, "int", 61, hop_ml=1) for i in range(10)], "a", "int", 61, False),
        ("the wrong path length is caught", [_built("a", i, "int", 62) for i in range(10)],
         "a", "int", 61, False),
        ("plain frames read as plain", [_built("c", i, "plain", 62) for i in range(10)],
         "c", "plain", 62, True),
        ("an int frame is not a plain frame", [_built("c", i, "int", 62) for i in range(10)],
         "c", "plain", 62, False),
        ("other tags are not counted", [_built("x", i, "int", 61) for i in range(10)],
         "a", "int", 61, False),
    ]
    failed = 0
    for name, frames, tag, kind, ttl, want in cases:
        ok, _lines = verdict(frames, tag, kind, 10, ttl)
        mark = "ok  " if ok == want else "FAIL"
        failed += ok != want
        print("%s %s (verdict %s, want %s)" % (mark, name, ok, want))
    print("selftest: %d case(s), %d wrong" % (len(cases), failed))
    return 1 if failed else 0


def main(argv):
    if not argv:
        raise SystemExit(__doc__)
    verb, args = argv[0], argv[1:]
    if verb == "send":
        cmd_send(*args)
        return 0
    if verb == "sniff":
        cmd_sniff(*args)
        return 0
    if verb == "verdict":
        return cmd_verdict(*args)
    if verb == "selftest":
        return cmd_selftest()
    raise SystemExit("unknown verb %r" % verb)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
