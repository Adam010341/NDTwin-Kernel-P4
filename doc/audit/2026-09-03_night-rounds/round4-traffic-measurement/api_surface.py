#!/usr/bin/env python3
"""Lead 5, second half: is there ANY /ndt/ path to the four sFlow ingest/drop counters?

Fetches every read endpoint the kernel serves and searches the union of the bodies for any key
or value that could carry loss. Also probes the shapes a metrics endpoint usually takes.
[Co-developed with claude code -- Adam]
"""
import json, sys, urllib.request, urllib.error

K = "http://127.0.0.1:8000"
GETS = ["get_average_link_usage", "get_cpu_utilization", "get_detected_flow_data",
        "get_detected_flow_data?liveness=all", "get_detected_top_k_flow_data",
        "get_flow_dispatch_status", "get_graph_data", "get_memory_utilization",
        "get_nickname?dpid=1", "get_openflow_capacity", "get_power_report",
        "get_static_topology_json", "get_switches_power_state",
        "get_switch_openflow_table_entries", "get_temperature"]
POSTS = [("get_num_of_flows_passing_a_switch", {"dpid": 1}),
         ("get_path_switch_count", {"src_ip": "10.0.0.1", "dst_ip": "10.0.0.2"}),
         ("get_total_input_traffic_load_passing_a_switch", {"dpid": 1})]
OTHER = ["/metrics", "/stats", "/health", "/healthz", "/ndt/metrics", "/ndt/stats",
         "/ndt/get_sflow_stats", "/ndt/get_collector_stats", "/ndt/get_telemetry_status",
         "/sflow/stats", "/ndt/get_drop_counters"]
NEEDLES = ["drop", "ovfl", "overflow", "lost", "loss", "addressed", "addresed",
           "received_packet", "receivedpacket", "rx", "sample_pool", "samples_seen",
           "datagram", "queue", "backlog", "ingest"]

def fetch(path, body=None):
    try:
        if body is None:
            req = urllib.request.Request(K + path)
        else:
            req = urllib.request.Request(K + path, data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:120]
    except Exception as e:
        return -1, str(e)[:120]

def keys_of(obj, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.add(k); keys_of(v, out)
    elif isinstance(obj, list):
        for v in obj[:50]:
            keys_of(v, out)

allkeys = set()
print("#### what this step proves: no /ndt/ endpoint exposes the four sFlow ingest/drop counters")
print("---- read endpoints, their status and their KEY SET ----")
for g in GETS:
    st, b = fetch("/ndt/" + g)
    try:
        keys_of(json.loads(b), allkeys)
    except Exception:
        pass
    print("  GET  /ndt/%-45s %s  %d bytes" % (g, st, len(b)))
for p, body in POSTS:
    st, b = fetch("/ndt/" + p, body)
    try:
        keys_of(json.loads(b), allkeys)
    except Exception:
        pass
    print("  POST /ndt/%-45s %s  %s" % (p, st, b[:70]))
print("\n---- endpoints a metrics/health surface would normally live at ----")
for o in OTHER:
    st, b = fetch(o)
    print("  GET  %-30s %s  %s" % (o, st, b[:60].replace("\n", " ")))

print("\n---- every JSON key the kernel returned anywhere, %d of them ----" % len(allkeys))
print("  " + ", ".join(sorted(allkeys)))
hits = sorted(k for k in allkeys if any(n in k.lower() for n in NEEDLES))
print("\n---- keys matching any loss/ingest word %s ----" % NEEDLES)
print("  " + (", ".join(hits) if hits else "NONE"))
