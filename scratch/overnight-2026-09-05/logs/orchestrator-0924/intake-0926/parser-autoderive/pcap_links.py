#!/usr/bin/env python3
"""Where on the wire each custom header actually appeared: per bmv2 pcap file (= one switch
port, one direction), non-IPv6 ethertypes with the custom-header shape, plus max frame length.
[Co-developed with claude code -- Adam]"""
import collections, glob, json, os, struct, hashlib
from run_tests import read_pcap
EX = "/home/adam/tutorials/exercises"
TOPO = {"basic_tunnel": "topology.json", "p4runtime": "topology.json",
        "source_routing": "topology.json", "mri": "topology.json",
        "link_monitor": "pod-topo/topology.json", "calc": "topology.json"}
for ex, t in TOPO.items():
    links = json.load(open(f"{EX}/{ex}/{t}"))["links"]
    print("=====", ex, "links:", [l[:2] for l in links])
    for f in sorted(glob.glob(f"{EX}/{ex}/pcaps/*.pcap")):
        c = collections.Counter(); mx = 0
        for fr, orig in read_pcap(f):
            et = fr[12:14].hex()
            if et == "86dd":
                continue
            k = et
            if et == "0800" and ex == "mri":
                k = f"0800/ihl{fr[14] & 15}"
            if et == "1234" and ex == "source_routing":
                n = 0
                while 14 + 2 * n + 2 <= len(fr):
                    n += 1
                    if fr[14 + 2 * (n - 1)] >> 7:
                        break
                k = f"1234/{n}entries"
            if et == "0812":
                k = f"0812/hop_cnt{fr[14]}/len{orig}"
            c[k] += 1; mx = max(mx, orig)
        if c:
            print("  ", os.path.basename(f), dict(c), "max_frame", mx,
                  "sha256[:12]", hashlib.sha256(open(f, "rb").read()).hexdigest()[:12])
