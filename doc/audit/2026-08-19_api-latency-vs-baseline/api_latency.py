"""Latency of the twin's read endpoints. Same script for both kernels.

Reports p50/p90/p99 over N calls after a warm-up, and asserts the topology it measured
against -- a latency number from a different graph size is not comparable, and the baseline
kernel is started by piping answers to prompts, which is exactly the way to load the wrong one.
"""
import json, sys, time, urllib.request
import statistics as st

N = int(sys.argv[1]) if len(sys.argv) > 1 else 200
BASE = "http://localhost:8000"
ENDPOINTS = ["/ndt/get_graph_data", "/ndt/get_switches_power_state", "/ndt/get_cpu_utilization"]

g = json.load(urllib.request.urlopen(BASE + "/ndt/get_graph_data", timeout=30))
sw = [n for n in g["nodes"] if n.get("vertex_type") == 0]
print(f"TOPOLOGY ASSERT: nodes={len(g['nodes'])} switches={len(sw)} edges={len(g['edges'])}")

for ep in ENDPOINTS:
    for _ in range(10):                       # warm-up, not measured
        try: urllib.request.urlopen(BASE + ep, timeout=30).read()
        except Exception: pass
    ts = []
    for _ in range(N):
        t0 = time.perf_counter()
        try:
            urllib.request.urlopen(BASE + ep, timeout=30).read()
        except Exception as exc:
            print(f"  {ep}: ERROR {exc}"); break
        ts.append((time.perf_counter() - t0) * 1000)
    if not ts: continue
    ts.sort()
    print(f"{ep:38s} n={len(ts)} p50={st.median(ts):7.2f}ms "
          f"p90={ts[int(len(ts)*0.90)]:7.2f}ms p99={ts[int(len(ts)*0.99)]:7.2f}ms "
          f"min={ts[0]:6.2f} max={ts[-1]:7.2f}")
