"""Characterise the twin's link-usage update cadence before the real accuracy run.

Polls get_graph_data far faster than the kernel can plausibly refresh, and records every
(t, edge, value) so the post-pass can answer three questions the main experiment depends on:
  1. how often does link_bandwidth_usage_bps actually change?
  2. does a value ever repeat legitimately (which would break change-detection dedupe)?
  3. which of s1's two ECMP uplinks carries the flow?

[Co-developed with claude code -- Adam]
"""
import json, urllib.request, time, sys, re

DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0
HZ = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
OUT = sys.argv[3] if len(sys.argv) > 3 else "scratch/sflow/cadence.jsonl"

IFACE = re.compile(r"^s\d+-eth\d+$")


def netdev():
    d = {}
    for line in open("/proc/net/dev"):
        if ":" not in line:
            continue
        name, rest = line.split(":", 1)
        name = name.strip()
        if not IFACE.match(name):
            continue
        f = rest.split()
        d[name] = int(f[8])  # tx_bytes
    return d


g0 = json.load(urllib.request.urlopen("http://localhost:8000/ndt/get_graph_data", timeout=20))
SW = {n["dpid"] for n in g0["nodes"] if n.get("vertex_type") == 0}

t_end = time.time() + DUR
period = 1.0 / HZ
with open(OUT, "w") as fh:
    while time.time() < t_end:
        t = time.time()
        nd = netdev()
        g = json.load(urllib.request.urlopen("http://localhost:8000/ndt/get_graph_data", timeout=20))
        ss = {
            f"s{e['src_dpid']}-eth{e['src_interface']}": e["link_bandwidth_usage_bps"]
            for e in g["edges"]
            if e["src_dpid"] in SW and e["dst_dpid"] in SW
        }
        fh.write(json.dumps({"t": round(t, 3), "twin": ss, "tx": nd}) + "\n")
        fh.flush()
        slp = period - (time.time() - t)
        if slp > 0:
            time.sleep(slp)
print("done ->", OUT)
