"""Clean sFlow accuracy run: one fixed-rate UDP flow, twin vs kernel byte counters.

Design notes (each one is a mistake avoided, not a preference):

  * 4 Hz sampling, not 1 Hz. The twin refreshes link_bandwidth_usage_bps once per second
    (measured: 32 changes in 31.8 s). Sampling at the same rate as the signal aliases; the
    prior round's 25 s interval saw only ~4% of the seconds, which is the `coverage`
    correction that made those numbers unusable.

  * Integrate time-weighted, not by counting transitions. A value can hold for two seconds
    (observed once in the 32 s characterisation run), so "one sample per change" silently
    drops a second. value x dt is correct whatever the cadence does.

  * Ground truth is the tx_bytes delta on the same interface over the same wall-clock
    window, read in the same pass as the twin. Not the iperf3 target rate -- the offered
    rate is not what crosses the link.

[Co-developed with claude code -- Adam]
"""
import json, urllib.request, time, sys, re

DUR = float(sys.argv[1])
HZ = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
OUT = sys.argv[3] if len(sys.argv) > 3 else "scratch/sflow/run.jsonl"

IFACE = re.compile(r"^s\d+-eth\d+$")
URL = "http://localhost:8000/ndt/get_graph_data"


def netdev():
    d = {}
    for line in open("/proc/net/dev"):
        if ":" not in line:
            continue
        name, rest = line.split(":", 1)
        name = name.strip()
        if not IFACE.match(name):
            continue
        d[name] = int(rest.split()[8])  # tx_bytes
    return d


g0 = json.load(urllib.request.urlopen(URL, timeout=20))
SW = {n["dpid"] for n in g0["nodes"] if n.get("vertex_type") == 0}

t_end = time.time() + DUR
period = 1.0 / HZ
n = 0
with open(OUT, "w") as fh:
    while time.time() < t_end:
        t = time.time()
        try:
            nd = netdev()
            g = json.load(urllib.request.urlopen(URL, timeout=20))
        except Exception as exc:                      # a dropped sample must be visible,
            fh.write(json.dumps({"t": round(t, 3), "error": str(exc)}) + "\n")   # not silently
            fh.flush()                                # interpolated over in the post-pass
            time.sleep(period)
            continue
        twin = {
            f"s{e['src_dpid']}-eth{e['src_interface']}": e["link_bandwidth_usage_bps"]
            for e in g["edges"]
            if e["src_dpid"] in SW and e["dst_dpid"] in SW
        }
        fh.write(json.dumps({"t": round(t, 3), "twin": twin, "tx": nd}) + "\n")
        fh.flush()
        n += 1
        slp = period - (time.time() - t)
        if slp > 0:
            time.sleep(slp)
print(f"done: {n} samples -> {OUT}")
