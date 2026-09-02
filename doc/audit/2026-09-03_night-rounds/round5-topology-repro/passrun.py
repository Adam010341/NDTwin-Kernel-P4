#!/usr/bin/env python3
"""One reproducibility pass: identical fabric, identical routes, identical traffic, identical probes.

Run twice against two separately-built fabrics and diff the JSON. Every number the tool publishes
that the experiment could plausibly depend on is captured, so a difference cannot hide.

Switch-side read-back goes through the P4 proxy's GET :8081/stats/flow/<dpid>, a DIFFERENT PROCESS
doing a P4Runtime read -- never the kernel API that wrote the entries.

[Co-developed with claude code -- Adam]
"""
import json, subprocess, sys, time, urllib.request, urllib.error, os

K = "http://127.0.0.1:8000"
PROXY = "http://127.0.0.1:8081/stats/flow/1"
PASS = sys.argv[1]
OUT = sys.argv[2]

# ---- fixed experiment parameters; identical in both passes ----
RATE      = "20M"
LEN       = 1400
DURATION  = 100
SAMPLE_AT = [15, 50, 85]        # >= 30 s apart, as the persona brief requires
ROUTE_DSTS = ["10.0.0.201", "10.0.0.202", "10.0.0.203", "10.0.0.204"]
DISPATCH_SETTLE = 4

R = {"pass": PASS, "params": dict(rate=RATE, len=LEN, duration=DURATION,
                                  sample_at=SAMPLE_AT, dsts=ROUTE_DSTS)}

def get(path, timeout=10):
    try:
        with urllib.request.urlopen(K + path, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode())
    except Exception as e:
        return -1, {"_error": repr(e)}

def post(path, body, timeout=10):
    req = urllib.request.Request(K + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, {"_body": e.read().decode()[:300]}
    except Exception as e:
        return -1, {"_error": repr(e)}

def switch_rows():
    try:
        with urllib.request.urlopen(PROXY, timeout=25) as r:
            d = json.loads(r.read().decode())
    except Exception as e:
        return {"_error": repr(e)}
    rows = []
    for _dpid, entries in d.items():
        for e in entries:
            rows.append("%s p=%s -> %s" % (e.get("match", {}).get("nw_dst"),
                                           e.get("priority"), ",".join(e.get("actions", []))))
    return sorted(rows)

def host_pid(tag):
    out = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if parts and parts[-1] == "mininet:" + tag:
            return parts[0]
    return None

def edge_utils():
    st, g = get("/ndt/get_graph_data", timeout=20)
    if st != 200 or "edges" not in g:
        return {"_status": st, "_error": "no graph"}
    out = {}
    for e in g["edges"]:
        k = "%s:%s->%s:%s" % (e.get("src_dpid"), e.get("src_interface"),
                              e.get("dst_dpid"), e.get("dst_interface"))
        out[k] = e.get("link_bandwidth_utilization_percent")
    return out

def fingerprint(tag):
    """Everything the API will tell us at one instant."""
    f = {"t": round(time.time(), 3), "tag": tag}
    st, g = get("/ndt/get_graph_data", timeout=20)
    if st == 200 and "nodes" in g:
        f["graph_nodes"] = len(g["nodes"]); f["graph_edges"] = len(g["edges"])
        f["nodes_up"] = sum(1 for n in g["nodes"] if n.get("is_up"))
        f["edges_up"] = sum(1 for e in g["edges"] if e.get("is_up"))
        f["edges_enabled"] = sum(1 for e in g["edges"] if e.get("is_enabled"))
    else:
        f["graph_error"] = st
    f["avg_link_usage"] = get("/ndt/get_average_link_usage")[1].get("avg_link_usage")
    u = edge_utils(); f["edge_util"] = u
    if "_error" not in u:
        vals = [v for v in u.values() if isinstance(v, (int, float))]
        f["edge_util_nonzero"] = sum(1 for v in vals if v > 0)
        f["edge_util_sum"] = round(sum(vals), 6)
        f["edge_util_max"] = max(vals) if vals else None
    f["power_state_on"] = sum(1 for v in get("/ndt/get_switches_power_state")[1].values() if v == "ON") \
        if isinstance(get("/ndt/get_switches_power_state")[1], dict) else None
    f["num_flows_s1"] = post("/ndt/get_num_of_flows_passing_a_switch", {"dpid": 1})[1].get("num_of_flows")
    f["input_load_s1_bps"] = post("/ndt/get_total_input_traffic_load_passing_a_switch",
                                  {"dpid": 1})[1].get("total_input_traffic_load_bps")
    st, p = get("/ndt/get_path_switch_count?ip1=10.0.0.1&ip2=10.0.0.2")
    f["path_h1_h2"] = p
    st, fd = get("/ndt/get_detected_flow_data", timeout=15)
    f["flow_rows"] = len(fd) if isinstance(fd, list) else None
    # 10.0.0.1 -> 10.0.0.2, little-endian as round 4 established
    def le(ip):
        a = [int(x) for x in ip.split(".")]
        return a[3] << 24 | a[2] << 16 | a[1] << 8 | a[0]
    # Whole row, not a hand-picked subset: the first attempt picked key names that do not exist
    # in this build and recorded None for every rate. Capturing the row means a renamed field
    # cannot silently become a missing number.
    f["flows"] = []
    if isinstance(fd, list):
        for row in fd:
            if row.get("src_ip") == le("10.0.0.1") and row.get("dst_ip") == le("10.0.0.2"):
                f["flows"].append(row)
        f["flow_rate_bps"] = [r.get("estimated_flow_sending_rate_bps_in_the_last_sec")
                              for r in f["flows"]]
        f["flow_pps"] = [r.get("estimated_packet_rate_in_the_last_sec") for r in f["flows"]]
        f["flow_path"] = [[(h.get("node"), h.get("interface")) for h in r.get("path", [])]
                          for r in f["flows"]]
    f["dispatch"] = get("/ndt/get_flow_dispatch_status")[1].get("counters")
    return f

log = lambda *a: (print(*a, flush=True))

# ---------------- A: fabric fingerprint before anything ----------------
log("#### PASS %s ####" % PASS)
log("== A. idle fingerprint, before routes and before traffic")
R["A_idle_pre"] = fingerprint("idle_pre")
R["A_power_report"] = get("/ndt/get_power_report")[1]
R["A_static_topology_bytes"] = len(json.dumps(get("/ndt/get_static_topology_json", timeout=20)[1]))
R["A_switch_rows_pre"] = switch_rows()
log("   nodes=%s edges=%s edges_up=%s avg=%s switch_rows=%s"
    % (R["A_idle_pre"].get("graph_nodes"), R["A_idle_pre"].get("graph_edges"),
       R["A_idle_pre"].get("edges_up"), R["A_idle_pre"].get("avg_link_usage"),
       len(R["A_switch_rows_pre"]) if isinstance(R["A_switch_rows_pre"], list) else R["A_switch_rows_pre"]))

# ---------------- B: route set through the documented API, verified at the switch ----------------
log("== B. install 4 routes via /ndt/install_flow_entry, verify by reading the switch")
R["B_install"] = []
for d in ROUTE_DSTS:
    st, body = post("/ndt/install_flow_entry",
                    {"dpid": 1, "priority": 100,
                     "match": {"eth_type": 2048, "ipv4_dst": d},
                     "actions": [{"type": "OUTPUT", "port": 1}]})
    R["B_install"].append({"dst": d, "http": st, "body": body})
time.sleep(DISPATCH_SETTLE)
R["B_switch_rows_after_install"] = switch_rows()
R["B_dispatch_after_install"] = get("/ndt/get_flow_dispatch_status")[1].get("counters")
log("   switch rows after install: %s (was %s)" %
    (len(R["B_switch_rows_after_install"]) if isinstance(R["B_switch_rows_after_install"], list) else R["B_switch_rows_after_install"],
     len(R["A_switch_rows_pre"]) if isinstance(R["A_switch_rows_pre"], list) else R["A_switch_rows_pre"]))

log("== B2. modify ONE rule by priority (same match, same priority 100, new action port 2)")
st, body = post("/ndt/modify_flow_entry",
                {"dpid": 1, "priority": 100,
                 "match": {"eth_type": 2048, "ipv4_dst": ROUTE_DSTS[0]},
                 "actions": [{"type": "OUTPUT", "port": 2}]})
R["B2_modify_same_priority"] = {"http": st, "body": body}
time.sleep(DISPATCH_SETTLE)
R["B2_switch_rows"] = switch_rows()

log("== B3. modify the SAME match at a DIFFERENT priority (200) -- replace or add?")
st, body = post("/ndt/modify_flow_entry",
                {"dpid": 1, "priority": 200,
                 "match": {"eth_type": 2048, "ipv4_dst": ROUTE_DSTS[1]},
                 "actions": [{"type": "OUTPUT", "port": 3}]})
R["B3_modify_other_priority"] = {"http": st, "body": body}
time.sleep(DISPATCH_SETTLE)
R["B3_switch_rows"] = switch_rows()
R["B3_dispatch"] = get("/ndt/get_flow_dispatch_status")[1].get("counters")

# ---------------- C: traffic and three telemetry samples ----------------
h1, h2 = host_pid("h1"), host_pid("h2")
R["C_host_pids"] = {"h1": h1, "h2": h2}
log("== C. traffic h1(%s) -> h2(%s): iperf3 UDP %s len %s for %s s" % (h1, h2, RATE, LEN, DURATION))
def _iperf_pids_now():
    out = subprocess.run(["ps", "-eo", "pid=,comm="], capture_output=True, text=True).stdout
    return {l.split()[0] for l in out.splitlines() if l.split()[-1] == "iperf3"}
IPERF_BEFORE = _iperf_pids_now()
R["C_iperf_pids_before"] = sorted(IPERF_BEFORE)
srv = subprocess.Popen(["sudo", "-n", "mnexec", "-a", h2, "iperf3", "-s", "-1"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(2)
cli = subprocess.Popen(["sudo", "-n", "mnexec", "-a", h1, "iperf3", "-c", "10.0.0.2",
                        "-u", "-b", RATE, "-l", str(LEN), "-t", str(DURATION), "--json"],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
t0 = time.time()
R["C_samples"] = []
for at in SAMPLE_AT:
    while time.time() - t0 < at:
        time.sleep(0.3)
    fp = fingerprint("t+%ds" % at)
    fp["offset_s"] = round(time.time() - t0, 2)
    R["C_samples"].append(fp)
    log("   sample t+%ds: avg=%s nonzero_edges=%s flow_rows=%s h1h2_rate=%s pps=%s"
        % (at, fp.get("avg_link_usage"), fp.get("edge_util_nonzero"), fp.get("flow_rows"),
           fp.get("flow_rate_bps"), fp.get("flow_pps")))
out, err = cli.communicate(timeout=DURATION + 60)
try:
    j = json.loads(out)
    s = j.get("end", {}).get("sum", {})
    R["C_wire"] = {k: s.get(k) for k in
                   ("bytes", "seconds", "bits_per_second", "packets", "lost_packets",
                    "lost_percent", "jitter_ms")}
except Exception as e:
    R["C_wire"] = {"_parse_error": repr(e), "_stdout_head": out[:400], "_stderr": err[:300]}
log("   wire: %s" % R["C_wire"])
# NEVER pkill/pgrep. Exact pids only: iperf3 -s -1 should exit by itself; if it has not,
# kill only pids that appeared between the "before" and "after" snapshots of comm == iperf3.
def iperf_pids():
    out = subprocess.run(["ps", "-eo", "pid=,comm="], capture_output=True, text=True).stdout
    return {l.split()[0] for l in out.splitlines() if l.split()[-1] == "iperf3"}
try:
    srv.wait(timeout=10)
except Exception:
    leftover = iperf_pids() - IPERF_BEFORE
    R["C_iperf_leftover_pids"] = sorted(leftover)
    for pid in leftover:
        subprocess.run(["sudo", "-n", "mnexec", "-a", h2, "kill", "-KILL", pid],
                       capture_output=True)
    try:
        srv.wait(timeout=10)
    except Exception:
        pass

# ---------------- D: post-traffic ----------------
time.sleep(10)
R["D_idle_post"] = fingerprint("idle_post")
R["D_switch_rows_end"] = switch_rows()
R["D_dispatch_end"] = get("/ndt/get_flow_dispatch_status")[1].get("counters")

log("== D. cleanup: delete the 4 installed routes")
R["D_delete"] = []
for d in ROUTE_DSTS:
    st, body = post("/ndt/delete_flow_entry",
                    {"dpid": 1, "priority": 100,
                     "match": {"eth_type": 2048, "ipv4_dst": d},
                     "actions": [{"type": "OUTPUT", "port": 1}]})
    R["D_delete"].append({"dst": d, "http": st, "body": body})
time.sleep(DISPATCH_SETTLE)
R["D_switch_rows_after_delete"] = switch_rows()

open(OUT, "w").write(json.dumps(R, indent=1, sort_keys=True) + "\n")
log("== written %s" % OUT)
