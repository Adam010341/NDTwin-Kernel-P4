#!/usr/bin/env python3
"""Round 4, lead 5: offer sFlow datagrams to the kernel's collector at a chosen rate.

The datagrams are built by the REPOSITORY'S OWN producer
(`p4_proxy/proxy_agent/sflow_emitter.build_datagram`), so their shape is the one the kernel is
written to parse -- not a hand-rolled guess. Exactly one datagram is built and then re-sent, so
`sent` is ground truth to the packet.

  usage: sflow_blast.py <rate-per-second|max> <seconds> [tag] [n-distinct-flow-keys]

With n-distinct-flow-keys > 1 the SAME datagram rate carries N different 5-tuples, so the
per-sample WORK the collector's workers must do rises while the offered rate is held. That is
the arm that separates "too many packets" from "too much work per packet".

[Co-developed with claude code -- Adam]
"""
import os, socket, struct, sys, time

sys.path.insert(0, "/home/adam/Desktop/NDTwin-Kernel/p4_proxy/proxy_agent")
sys.path.insert(0, "/home/adam/Desktop/NDTwin-Kernel/p4_proxy")
from sflow_emitter import SampledPacket, SwitchAgent, build_datagram  # noqa: E402

# A synthetic Ethernet/IPv4/UDP frame with source and destination addresses that exist nowhere on
# this fabric, so every row it produces in the flow table is provably mine.
SRC, DST = "10.99.0.1", "10.99.0.2"

def frame(idx=0):
    eth = b"\x00\x00\x00\x00\x00\x02" + b"\x00\x00\x00\x00\x00\x01" + struct.pack("!H", 0x0800)
    payload = b"\x00" * 64
    udp = struct.pack("!HHHH", 40000 + (idx & 0x3FFF), 40001, 8 + len(payload), 0) + payload
    total = 20 + len(udp)
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total, 0, 0, 64, 17, 0,
                     socket.inet_aton("10.99.%d.%d" % ((idx >> 8) & 0xFF, idx & 0xFF)),
                     socket.inet_aton(DST))
    return eth + ip + udp

def main():
    rate = sys.argv[1]
    secs = float(sys.argv[2])
    tag = sys.argv[3] if len(sys.argv) > 3 else "blast"
    nkeys = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    agent = SwitchAgent("192.168.123.11")           # dpid 1, the address the topology gives it
    bufs = [build_datagram([SampledPacket(ingress_port=1, egress_port=2, frame_length=1500,
                                          sampling_rate=256, frame=frame(i))], agent, 1000, 128)
            for i in range(nkeys)]
    buf = bufs[0]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
    s.connect(("127.0.0.1", 6343))
    sent = errs = 0
    t0 = time.monotonic()
    end = t0 + secs
    if rate == "max":
        while time.monotonic() < end:
            for _ in range(2000):
                try:
                    s.send(bufs[sent % nkeys]); sent += 1
                except OSError:
                    errs += 1
    else:
        r = float(rate)
        per_tick, tick = max(1, int(r / 1000)), 1.0 / max(1.0, r / max(1, int(r / 1000)))
        nxt = t0
        while True:
            now = time.monotonic()
            if now >= end:
                break
            if now < nxt:
                time.sleep(min(nxt - now, 0.002)); continue
            for _ in range(per_tick):
                try:
                    s.send(bufs[sent % nkeys]); sent += 1
                except OSError:
                    errs += 1
            nxt += tick
    el = time.monotonic() - t0
    print("tag=%s requested=%s keys=%d datagram_bytes=%d sent=%d send_errors=%d elapsed=%.3f achieved=%.0f/s"
          % (tag, rate, nkeys, len(buf), sent, errs, el, sent / el), flush=True)

main()
