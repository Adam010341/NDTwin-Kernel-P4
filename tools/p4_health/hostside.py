#!/usr/bin/env python3
"""The marker sender and sniffer, run INSIDE a Mininet host's namespace (Cut 2).

[Co-developed with claude code -- Adam]

    sudo -n mnexec -a <host pid> <p4dev python> hostside.py send  --run R --cell C ...
    sudo -n mnexec -a <host pid> <p4dev python> hostside.py sniff --run R --cells C1,C2 --seconds W

The design names scapy for this; the frames are built by frames.py instead (struct only) and
sent on an AF_PACKET socket, so the live markers are byte-identical to the ones S0's offline
self-checks put through a throwaway bmv2 -- the same function builds both. Standard library only.

What it prints is the contract collect/sniff.py reads (design 2.1 step 3: the stimulus count is
the sender's own report):

    SENT cell=<id> n=<frames actually sent> ident=<ip id> requested=<n asked for>
    READY iface=<name>                                   (the sniffer is listening)
    RX {"cell": .., "run": .., "seq": .., "ttl": .., "ident": .., ...}
    DONE received=<n>

The run id in a marker is 8 bytes (frames.payload); the probe passes an 8-character token.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from p4_health import frames as F  # noqa: E402

ETH_P_ALL = 0x0003
PACKET_OUTGOING = 4


def pick_iface(name):
    if name and name != "auto":
        return name
    names = sorted(n for n in os.listdir("/sys/class/net") if n != "lo")
    if len(names) != 1:
        raise SystemExit("hostside: cannot pick the host interface among %s" % names)
    return names[0]


def build(args, seq):
    kind = args.kind
    if kind == "udp":
        return F.udp_marker(args.src_mac, args.dst_mac, args.src_ip, args.dst_ip, args.dport,
                            run_id=args.run, cell=args.cell, seq=seq, sport=args.sport,
                            ttl=args.ttl, ident=args.ident)
    raise SystemExit("hostside: unknown frame kind %r" % kind)


def cmd_send(args):
    iface = pick_iface(args.iface)
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    s.bind((iface, 0))
    gap = 1.0 / args.pps if args.pps > 0 else 0.0
    sent = 0
    t0 = time.monotonic()
    for seq in range(args.count):
        frame = build(args, seq)
        try:
            if s.send(frame) == len(frame):
                sent += 1
        except OSError as exc:
            sys.stderr.write("hostside: send %d failed: %s\n" % (seq, exc))
        if gap:
            due = t0 + (seq + 1) * gap
            now = time.monotonic()
            if due > now:
                time.sleep(due - now)
    s.close()
    print("SENT cell=%s n=%d ident=%d requested=%d" % (args.cell, sent, args.ident, args.count))
    sys.stdout.flush()
    return 0 if sent == args.count else 1


def record(frame, run, cells):
    p = F.parse(frame)
    mark = p.get("marker")
    if not mark or mark[0] != run[:8] or mark[1] not in cells:
        return None
    rec = {"run": mark[0], "cell": mark[1], "seq": mark[2], "ethertype": p.get("ethertype"),
           "src": p.get("src"), "dst": p.get("dst")}
    for key in ("ttl", "ident", "diffserv", "ip_src", "ip_dst", "sport", "dport"):
        if key in p:
            rec[key] = p[key]
    return rec


def cmd_sniff(args):
    iface = pick_iface(args.iface)
    cells = set(c for c in args.cells.split(",") if c)
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    s.bind((iface, 0))
    s.settimeout(0.2)
    print("READY iface=%s" % iface)
    sys.stdout.flush()
    deadline = time.monotonic() + args.seconds
    n = 0
    while time.monotonic() < deadline:
        try:
            frame, addr = s.recvfrom(65535)
        except socket.timeout:
            continue
        if len(addr) > 2 and addr[2] == PACKET_OUTGOING:
            continue
        rec = record(frame, args.run, cells)
        if rec is not None:
            n += 1
            print("RX " + json.dumps(rec, sort_keys=True))
            sys.stdout.flush()
            if args.until and n >= args.until:
                break
    s.close()
    print("DONE received=%d" % n)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd")
    a = sub.add_parser("send")
    a.add_argument("--run", required=True)
    a.add_argument("--cell", required=True)
    a.add_argument("--iface", default="auto")
    a.add_argument("--kind", default="udp")
    a.add_argument("--count", type=int, required=True)
    a.add_argument("--pps", type=float, default=500.0)
    a.add_argument("--src-mac", required=True)
    a.add_argument("--dst-mac", required=True)
    a.add_argument("--src-ip", required=True)
    a.add_argument("--dst-ip", required=True)
    a.add_argument("--dport", type=int, required=True)
    a.add_argument("--sport", type=int, default=40000)
    a.add_argument("--ttl", type=int, default=64)
    a.add_argument("--ident", type=int, default=1)
    b = sub.add_parser("sniff")
    b.add_argument("--run", required=True)
    b.add_argument("--cells", required=True)
    b.add_argument("--iface", default="auto")
    b.add_argument("--seconds", type=float, required=True)
    b.add_argument("--until", type=int, default=0, help="stop early after this many records")
    args = ap.parse_args(argv)
    if args.cmd == "send":
        return cmd_send(args)
    if args.cmd == "sniff":
        return cmd_sniff(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
