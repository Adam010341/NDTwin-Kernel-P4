#!/usr/bin/env python3
# Rank 1 -- does an elephant-flow flag latch after the flow goes idle?
# [Co-developed with claude code -- Adam]
#
# Burst then idle. Poll /ndt/get_detected_top_k_flow_data with liveness=all (so a retained
# flow is still returned after it stops sending) and record both elephant flags every 0.5 s.
# The claim under test: is_elephant_flow_immediately stays true while the flow is idle.
import json, subprocess, sys, time, urllib.request

BASE = "http://localhost:8000"
DUR = int(sys.argv[1]) if len(sys.argv) > 1 else 15
TAIL = int(sys.argv[2]) if len(sys.argv) > 2 else 40
H1, H2 = "1432565", "1432568"


def get(path):
    try:
        with urllib.request.urlopen(BASE + path, timeout=3) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {"__err__": str(e)}


def rows(j):
    if isinstance(j, dict):
        for k in ("flows", "data", "top_k_flows", "flow_data"):
            if isinstance(j.get(k), list):
                return j[k]
        for v in j.values():
            if isinstance(v, list):
                return v
        return []
    return j if isinstance(j, list) else []


print("#### Rank 1: elephant-flow flag after the flow goes idle ####")
print("burst %ds, then %ds idle; poll every 0.5s with liveness=all" % (DUR, TAIL))

base = get("/ndt/get_detected_top_k_flow_data?k=10&liveness=all")
print("BASELINE (no traffic):", json.dumps(base)[:400])

subprocess.run(["sudo", "-n", "mnexec", "-a", H2, "iperf3", "-s", "-D", "-p", "5201"],
               capture_output=True)
time.sleep(1)
t0 = time.time()
cli = subprocess.Popen(
    ["sudo", "-n", "mnexec", "-a", H1, "iperf3", "-c", "10.0.0.2", "-u", "-b", "50M",
     "-l", "1400", "-t", str(DUR), "-p", "5201", "--json"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

samples = []
end = t0 + DUR + TAIL
while time.time() < end:
    t = time.time() - t0
    j = get("/ndt/get_detected_top_k_flow_data?k=10&liveness=all")
    rr = rows(j)
    rec = {"t": round(t, 2), "n": len(rr), "rows": []}
    for r in rr:
        if not isinstance(r, dict):
            continue
        rec["rows"].append({k: v for k, v in r.items()
                            if "elephant" in k or "rate" in k or "state" in k
                            or "liveness" in k or "ip" in k or "port" in k})
    samples.append(rec)
    time.sleep(0.5)

out = cli.communicate()[0].decode(errors="replace")
print("---- iperf3 client json (wire ground truth) ----")
try:
    d = json.loads(out)
    s = d["end"]["sum"]
    print("bytes=%d packets=%d lost=%d (%.2f%%) bits_per_second=%.0f"
          % (s["bytes"], s["packets"], s["lost_packets"], s["lost_percent"], s["bits_per_second"]))
except Exception:
    print(out[-1500:])

with open(sys.argv[3] if len(sys.argv) > 3 else "rank1_samples.json", "w") as f:
    json.dump(samples, f, indent=1)

print("---- per-sample elephant flags (t, n_rows, flags per row) ----")
for rec in samples:
    flags = []
    for r in rec["rows"]:
        imm = r.get("is_elephant_flow_immediately", r.get("isElephantFlowImmediately"))
        per = r.get("is_elephant_flow_periodically", r.get("isElephantFlowPeriodically"))
        ri = r.get("estimated_flow_sending_rate_bps_in_the_last_sec")
        rp = r.get("estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot")
        flags.append("imm=%s per=%s r_imm=%s r_per=%s" % (imm, per, ri, rp))
    print("t=%6.2f n=%d | %s" % (rec["t"], rec["n"], " ; ".join(flags) if flags else "(no rows)"))
