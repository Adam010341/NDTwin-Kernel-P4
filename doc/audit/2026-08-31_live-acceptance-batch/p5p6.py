#!/usr/bin/env python3
"""A-7 §5 live verification: P5 (failure is visible) and P6 (dispatched counts other writers).

Runs the pre-registered recipe from FINDINGS.md §5 verbatim, including the force-green
control (step 3) and the 256-cap overflow (step 5). Prints one line per registered
expectation with PASS/FAIL so the verdict is on the state, not on an exit code.
"""
import json
import subprocess
import sys
import time

K = "localhost:8000"
BATCH = "/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries"


def curl(path, body=None):
    cmd = ["curl", "-s", "--max-time", "30", f"{K}{path}"]
    if body is not None:
        cmd += ["-X", "POST", "-H", "Content-Type: application/json", "-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return {"__unparsed__": out[:300]}


def status():
    return curl("/ndt/get_flow_dispatch_status")


def entry(ip, port, prio):
    return {"dpid": 1, "priority": prio,
            "match": {"eth_type": 2048, "ipv4_dst": ip},
            "actions": [{"type": "OUTPUT", "port": port}]}


def counters(s):
    return s.get("counters", {})


def show(label, s):
    c = counters(s)
    print(f"  {label:<26} dispatched={c.get('dispatched')} succeeded={c.get('succeeded')} "
          f"failed={c.get('failed')} recent_failures={len(s.get('recent_failures', []))} "
          f"evicted={s.get('recent_failures_evicted')}")


results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")


print("=== STEP 1: baseline (P6: pre-registered expectation is dispatched > 0 on a warm fabric) ===")
b = status()
show("baseline", b)
bd, bs, bf = counters(b).get("dispatched", 0), counters(b).get("succeeded", 0), counters(b).get("failed", 0)
b_rf = len(b.get("recent_failures", []))
check("P6 dispatched>0 on warm fabric", bd > 0,
      f"dispatched={bd} (registered expectation: >0 because other subsystems enqueue too)")

print("\n=== STEP 2: force a failure -- port 999 does not exist (P5) ===")
r = curl("/ndt/install_flow_entry", entry("10.0.0.241", 999, 915))
print(f"  POST -> {json.dumps(r)[:160]}")
time.sleep(3)
a = status()
show("after port-999", a)
ad, asuc, af = counters(a).get("dispatched", 0), counters(a).get("succeeded", 0), counters(a).get("failed", 0)
rf = a.get("recent_failures", [])
check("P5 failed incremented by 1", af == bf + 1, f"failed {bf} -> {af}")
check("P5 recent_failures gained an entry", len(rf) == b_rf + 1, f"recent_failures {b_rf} -> {len(rf)}")
if rf:
    e = rf[-1]
    print(f"  last recent_failures entry: {json.dumps(e)[:400]}")
    check("P5 entry has dpid==1", e.get("dpid") == 1, f"dpid={e.get('dpid')!r}")
    check("P5 entry has requested_priority==915",
          e.get("requested_priority") == 915, f"requested_priority={e.get('requested_priority')!r}")
    check("P5 entry match.ipv4_dst==10.0.0.241",
          (e.get("match") or {}).get("ipv4_dst") == "10.0.0.241",
          f"match={json.dumps(e.get('match'))}")
    cs = e.get("controller_status")
    check("P5 controller_status is non-zero", bool(cs) and cs != 0, f"controller_status={cs!r}")
else:
    check("P5 recent_failures non-empty", False, "recent_failures is empty -- nothing to inspect")

print("\n=== STEP 3: force-green control -- port 2 exists (a gate that only goes red is not a gate) ===")
r2 = curl("/ndt/install_flow_entry", entry("10.0.0.242", 2, 916))
print(f"  POST -> {json.dumps(r2)[:160]}")
time.sleep(8)
g = status()
show("after port-2", g)
gd, gs, gf = counters(g).get("dispatched", 0), counters(g).get("succeeded", 0), counters(g).get("failed", 0)
grf = len(g.get("recent_failures", []))
check("control succeeded incremented", gs == asuc + 1, f"succeeded {asuc} -> {gs}")
check("control failed unchanged", gf == af, f"failed {af} -> {gf}")
check("control recent_failures unchanged", grf == len(rf), f"recent_failures {len(rf)} -> {grf}")

print("\n=== STEP 5: overflow -- 260 failing entries in one batch, cap is 256 ===")
big = [entry(f"10.9.{i // 256}.{i % 256}", 999, 800 + (i % 50)) for i in range(260)]
r3 = curl(BATCH, {"install_flow_entries": big,
                  "modify_flow_entries": [], "delete_flow_entries": []})
print(f"  POST 260 -> {json.dumps(r3)[:200]}")
time.sleep(12)
o = status()
show("after 260 failures", o)
orf = len(o.get("recent_failures", []))
oev = o.get("recent_failures_evicted", 0)
cap = o.get("recent_failures_capacity")
check("recent_failures caps at capacity", orf <= (cap or 256), f"len={orf} capacity={cap}")
check("recent_failures_evicted > 0 (kills M15)", (oev or 0) > 0, f"recent_failures_evicted={oev}")
check("failed counter kept counting past the cap",
      counters(o).get("failed", 0) > gf, f"failed {gf} -> {counters(o).get('failed')}")

print("\n=== SUMMARY ===")
npass = sum(1 for _, ok, _ in results if ok)
for n, ok, d in results:
    if not ok:
        print(f"  FAILED: {n} -- {d}")
print(f"  {npass}/{len(results)} registered expectations held")
json.dump({"baseline": b, "after_999": a, "after_green": g, "after_overflow": o},
          open(sys.argv[1], "w"), indent=1)
print(f"  raw saved -> {sys.argv[1]}")
