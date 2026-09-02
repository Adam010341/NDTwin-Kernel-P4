#!/usr/bin/env python3
"""Round 4 probe: for one flow key, ask the three windows and record which say it is there.

  window A (2 s)  : POST /ndt/get_num_of_flows_passing_a_switch  -> sum of edge.flowSet sizes
  window B (3 s)  : GET  /ndt/get_detected_flow_data             -> API default = ActiveOnly
  window C (15 s) : GET  /ndt/get_detected_flow_data?liveness=all

Prints one CSV line per poll. [Co-developed with claude code -- Adam]
"""
import json, socket, struct, sys, time, urllib.request

K = "http://127.0.0.1:8000"

def ip2u(s):
    # The API publishes the 4 octets read little-endian: 10.0.0.1 -> 16777226 (0x0100000A),
    # not 167772161. Verified against a live row before any cell ran.
    return struct.unpack("<I", socket.inet_aton(s))[0]

def get(path, timeout=4.0):
    with urllib.request.urlopen(K + path, timeout=timeout) as r:
        return json.loads(r.read().decode())

def post(path, body, timeout=4.0):
    req = urllib.request.Request(K + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def match(rows, s, d):
    out = []
    for r in rows:
        if r.get("src_ip") == s and r.get("dst_ip") == d:
            out.append(r)
    return out

def main():
    src, dst, dpid, secs, tag = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
    # decoy: a flow key that is NOT running, to prove the detector can say "absent"
    dsrc, ddst = (sys.argv[6], sys.argv[7]) if len(sys.argv) > 7 else ("10.0.0.3", "10.0.0.4")
    s, d = ip2u(src), ip2u(dst)
    ds, dd = ip2u(dsrc), ip2u(ddst)
    print("ts,tag,winA_edgeflows_dpid%d,winB_default_present,winC_all_present,winC_liveness,"
          "winB_rate_bps,decoy_in_B,decoy_in_C,n_default,n_all" % dpid, flush=True)
    t_end = time.time() + secs
    while time.time() < t_end:
        t = time.time()
        try:
            a = post("/ndt/get_num_of_flows_passing_a_switch", {"dpid": dpid}).get("num_of_flows", -1)
        except Exception as e:
            a = -1
        try:
            b = get("/ndt/get_detected_flow_data")
        except Exception:
            b = []
        try:
            c = get("/ndt/get_detected_flow_data?liveness=all")
        except Exception:
            c = []
        mb, mc = match(b, s, d), match(c, s, d)
        db, dc = match(b, ds, dd), match(c, ds, dd)
        live = mc[0].get("liveness") if mc else ""
        rate = mb[0].get("estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot", mb[0].get("estimated_flow_sending_rate_bps_in_the_last_sec", "")) if mb else ""
        print("%.3f,%s,%d,%d,%d,%s,%s,%d,%d,%d,%d" %
              (t, tag, a, 1 if mb else 0, 1 if mc else 0, live, rate,
               1 if db else 0, 1 if dc else 0, len(b), len(c)), flush=True)
        dt = 1.0 - (time.time() - t)
        if dt > 0:
            time.sleep(dt)

main()
