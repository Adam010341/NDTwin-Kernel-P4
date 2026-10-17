#!/usr/bin/env python3
"""ONTAS's own check, made into a verdict: frames in at h1, compared at h2 with a hand model.

[Co-developed with claude code -- Adam]

Used by live-p1/10_paper_ontas.sh. ONTAS (Princeton-Cabernet/p4-projects @e5c7cca1,
ONTAS/bmv2_p4_16) ships no verdict: its README says to tcpreplay smallFlows.pcap from h1, tcpdump
at h2 and compare by eye. This file builds the frames, sends them, captures them and compares every
one with doc/audit/2026-10-16_p4-paper-apps/ontas_model.py, a hand model of p4anony.p4.

    frames <ontas_model dir> <pcap> <n> <out.hex>   the crafted frames, then the first n pcap
                                                    frames the program parses whole, one hex
                                                    line each (run as the user; reads the pcap
                                                    as DATA with struct, never runs anything
                                                    from it)
    send <in.hex> [<tag>]                           sendp every frame (inside h1, as root)
    sniff <seconds>                                 every frame on *eth0 as JSON on stdout, READY
                                                    on stderr once capturing (inside h2, as root)
    verdict <ontas_model dir> <capture.json> <in.hex>
                                                    each sent frame's modelled output must be in
                                                    the capture, byte for byte; "OK n/n" or "BAD"
    none-arrived <ontas_model dir> <capture.json> <in.hex>
                                                    no sent frame arrived, neither as sent nor as
                                                    the model would rewrite it (the port-2 side:
                                                    forward_tb has no entry for it)
    selftest <ontas_model dir>                      the verdicts against frames built here

Run with -I from a directory outside the repo; paths are arguments.
"""
import json
import os
import struct
import sys
import time


def model(model_dir):
    sys.path.insert(0, os.path.abspath(model_dir))
    import ontas_model  # noqa: E402
    return ontas_model


def iface():
    from scapy.all import get_if_list
    for name in get_if_list():
        if "eth0" in name:
            return name
    raise SystemExit("no *eth0 interface in this namespace")


def read_pcap(path):
    """Every frame of a classic pcap (either byte order), as bytes. Data only."""
    with open(path, "rb") as fh:
        data = fh.read()
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian = "<"
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian = ">"
    else:
        raise SystemExit("%s is not a classic pcap" % path)
    frames, off = [], 24
    while off + 16 <= len(data):
        incl = struct.unpack_from(endian + "I", data, off + 8)[0]
        frames.append(data[off + 16:off + 16 + incl])
        off += 16 + incl
    return frames


def _eth(dst, src, ethertype, body):
    mac = lambda m: bytes(int(x, 16) for x in m.split(":"))  # noqa: E731
    return (mac(dst) + mac(src) + struct.pack("!H", ethertype) + body).ljust(60, b"\0")


def _ipv4(src, dst, proto, body):
    ip = lambda a: bytes(int(x) for x in a.split("."))  # noqa: E731
    head = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(body), 1, 0, 64, proto, 0, ip(src),
                       ip(dst))
    total = sum(struct.unpack("!10H", head))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return head[:10] + struct.pack("!H", ~total & 0xFFFF) + head[12:] + body


def crafted(tag):
    """The live counterparts of offline_ontas.py's g1-g7 (g8 needs port 2; A4 covers it)."""
    src, dst = "aa:bb:cc:12:34:56", "00:11:22:ab:cd:ef"
    udp = lambda s, d, n: _ipv4(s, d, 17, struct.pack("!HHHH", 5000, 6000, 8 + 24, 0)  # noqa
                                + ("%s-%02d" % (tag, n)).encode().ljust(24, b"."))
    ip = lambda a: bytes(int(x) for x in a.split("."))  # noqa: E731
    mac = lambda m: bytes(int(x, 16) for x in m.split(":"))  # noqa: E731
    arp = struct.pack("!HHBBH", 1, 0x0800, 6, 4, 2) + mac(src) + ip("72.14.213.9") \
        + mac(dst) + ip("72.14.213.10")
    tcp = struct.pack("!HHIIBBHHH", 80, 1234, 1000, 0, 5 << 4, 0x18, 512, 0xBEEF, 0) \
        + ("%s-07" % tag).encode().ljust(24, b".")
    return [
        _eth(dst, src, 0x0800, udp("72.14.213.5", "72.14.213.77", 1)),
        _eth(dst, src, 0x0800, udp("10.1.2.3", "10.4.5.6", 2)),
        _eth("ff:ff:ff:ff:ff:ff", src, 0x0800, udp("72.14.213.5", "10.4.5.6", 3)),
        _eth("01:00:5e:00:00:fb", src, 0x0800, udp("72.14.213.5", "10.4.5.6", 4)),
        _eth(dst, src, 0x0806, arp),
        _eth(dst, src, 0x8100, struct.pack("!HH", 7, 0x0800) + udp("72.14.213.5", "10.9.9.9", 6)),
        _eth(dst, src, 0x0800, _ipv4("72.14.213.200", "72.14.213.1", 6, tcp)),
    ]


def cmd_frames(model_dir, pcap, n, out):
    M = model(model_dir)
    frames = crafted("ontas")
    replay = [f for f in read_pcap(pcap) if M.needed_length(f) <= len(f) <= 1514][:int(n)]
    with open(out, "w") as fh:
        for f in frames + replay:
            fh.write(f.hex() + "\n")
    print("%d crafted + %d replayed frame(s) -> %s" % (len(frames), len(replay), out))


def cmd_send(path):
    from scapy.all import sendp, conf
    ifc = iface()
    frames = [bytes.fromhex(line.strip()) for line in open(path) if line.strip()]
    sock = conf.L2socket(iface=ifc)
    try:
        for f in frames:
            sock.send(f)
            time.sleep(0.02)
    finally:
        sock.close()
    print("sent %d frame(s) on %s" % (len(frames), ifc))
    del sendp


def cmd_sniff(seconds):
    from scapy.all import sniff
    ifc = iface()
    got = sniff(iface=ifc, timeout=float(seconds),
                started_callback=lambda: print("READY", file=sys.stderr, flush=True))
    json.dump({"iface": ifc, "frames": [bytes(p).hex() for p in got]}, sys.stdout)
    print("sniffed %d frame(s) on %s" % (len(got), ifc), file=sys.stderr)


def verdict(M, captured, sent):
    """(ok, lines): every sent frame's modelled output is in `captured` (bytes, multiset)."""
    pool = {}
    for f in captured:
        pool[f] = pool.get(f, 0) + 1
    lines, missing = [], 0
    for i, f in enumerate(sent):
        port, want = M.apply(f, 1)
        if want is None:
            continue
        if pool.get(want, 0):
            pool[want] -= 1
        else:
            missing += 1
            if missing <= 3:
                lines.append("  BAD frame %d: its modelled output was not captured (want %s)"
                             % (i, want.hex()))
    n = len(sent)
    ok = missing == 0 and n > 0
    lines.append("%s %d/%d sent frame(s) arrived as the model computes them" %
                 ("OK" if ok else "BAD", n - missing, n))
    return ok, lines


def none_arrived(M, captured, sent):
    seen = set(captured)
    hits = [i for i, f in enumerate(sent) if f in seen or M.apply(f, 1)[1] in seen]
    ok = not hits and len(sent) > 0
    return ok, ["%s %d of %d sent frame(s) arrived (want 0)%s" % (
        "OK" if ok else "BAD", len(hits), len(sent), (": frames %s" % hits[:5]) if hits else "")]


def cmd_none_arrived(model_dir, capture, sent_path):
    M = model(model_dir)
    with open(capture) as fh:
        captured = [bytes.fromhex(x) for x in json.load(fh)["frames"]]
    sent = [bytes.fromhex(line.strip()) for line in open(sent_path) if line.strip()]
    ok, lines = none_arrived(M, captured, sent)
    print("\n".join(lines))
    return 0 if ok else 1


def cmd_verdict(model_dir, capture, sent_path):
    M = model(model_dir)
    with open(capture) as fh:
        captured = [bytes.fromhex(x) for x in json.load(fh)["frames"]]
    sent = [bytes.fromhex(line.strip()) for line in open(sent_path) if line.strip()]
    ok, lines = verdict(M, captured, sent)
    print("\n".join(lines))
    return 0 if ok else 1


def cmd_selftest(model_dir):
    M = model(model_dir)
    sent = crafted("t")
    good = [M.apply(f, 1)[1] for f in sent]
    cases = [
        ("the modelled frames read OK", good, True),
        ("the frames as sent (nothing anonymised) read BAD", list(sent), False),
        ("one frame missing reads BAD", good[1:], False),
        ("one byte changed reads BAD", good[:-1] + [good[-1][:-1] + bytes([good[-1][-1] ^ 1])],
         False),
        ("extra frames do not hide a missing one", good[1:] + [good[2]] * 3, False),
    ]
    cases += [
        ("none-arrived: an empty capture reads OK", [], True, none_arrived),
        ("none-arrived: one frame as sent reads BAD", [sent[3]], False, none_arrived),
        ("none-arrived: one frame as modelled reads BAD", [good[0]], False, none_arrived),
    ]
    wrong = 0
    for case in cases:
        name, captured, want = case[:3]
        fn = case[3] if len(case) > 3 else verdict
        ok, _lines = fn(M, captured, sent)
        wrong += ok != want
        print("%s %s (verdict %s, want %s)" % ("ok  " if ok == want else "FAIL", name, ok, want))
    print("selftest: %d case(s), %d wrong" % (len(cases), wrong))
    return 1 if wrong else 0


def main(argv):
    verb, args = (argv[0], argv[1:]) if argv else ("", [])
    if verb == "frames":
        cmd_frames(*args)
        return 0
    if verb == "send":
        cmd_send(args[0])
        return 0
    if verb == "sniff":
        cmd_sniff(*args)
        return 0
    if verb == "verdict":
        return cmd_verdict(*args)
    if verb == "none-arrived":
        return cmd_none_arrived(*args)
    if verb == "selftest":
        return cmd_selftest(*args)
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
