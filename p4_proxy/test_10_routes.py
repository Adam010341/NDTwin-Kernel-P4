import requests
import time

PROXY_URL = "http://127.0.0.1:8080/stats/flowentry/add"

def push_rule(dpid, ip_dst, out_port):
    payload = {
        "dpid": dpid,
        "priority": 10,
        "match": {
            "dl_type": 2048,
            "nw_dst": ip_dst
        },
        "actions": [
            {"type": "OUTPUT", "port": out_port}
        ]
    }
    resp = requests.post(PROXY_URL, json=payload)
    if resp.status_code == 200:
        print(f"✅ Successfully pushed: DPID {dpid} | {ip_dst} -> Port {out_port}")
    else:
        print(f"❌ Failed to push: DPID {dpid} | {ip_dst} -> Port {out_port}")

print("=========================================================")
print("🚀 Pushing 10 rules for full bidirectional path: h1 <-> h4")
print("=========================================================")

# Path: h1(10.0.0.1) -> s1 -> s5 -> s9 -> s7 -> s4 -> h4(10.0.0.4)

# 1. Forward Path (h1 to h4)
push_rule(dpid=1, ip_dst="10.0.0.4", out_port=1) # s1 to s5
push_rule(dpid=5, ip_dst="10.0.0.4", out_port=3) # s5 to s9
push_rule(dpid=9, ip_dst="10.0.0.4", out_port=3) # s9 to s7
push_rule(dpid=7, ip_dst="10.0.0.4", out_port=2) # s7 to s4
push_rule(dpid=4, ip_dst="10.0.0.4", out_port=3) # s4 to h4

print("---------------------------------------------------------")

# 2. Return Path (h4 to h1)
push_rule(dpid=4, ip_dst="10.0.0.1", out_port=1) # s4 to s7
push_rule(dpid=7, ip_dst="10.0.0.1", out_port=3) # s7 to s9
push_rule(dpid=9, ip_dst="10.0.0.1", out_port=1) # s9 to s5
push_rule(dpid=5, ip_dst="10.0.0.1", out_port=1) # s5 to s1
push_rule(dpid=1, ip_dst="10.0.0.1", out_port=3) # s1 to h1

print("=========================================================")
print("All rules sent! You can now run `h1 ping h4` in Mininet.")

# Developed in collaboration with Gemini 3.1 Pro.
