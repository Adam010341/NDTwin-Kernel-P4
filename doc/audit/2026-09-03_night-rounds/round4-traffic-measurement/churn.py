#!/usr/bin/env python3
"""Round 4 extra: can the flow-dispatch counters be made to DISAGREE with the switch's own table?

Round 3 refuted "concurrent writers lose an update" and left this behind: a replace and an add
are indistinguishable in the response body and in the counters. If that is so, then under churn
the counters are not a count of rules -- and the switch is the only place the truth lives.

Two arms, same rate, same switch, differing ONLY in whether the matches are distinct:
  arm DISTINCT : N installs, N different ipv4_dst  -> table must grow by N
  arm SAME     : N installs, ONE ipv4_dst          -> table must grow by 1
The switch's table is read from bmv2's own thrift CLI, never from the API that wrote it.

[Co-developed with claude code -- Adam]
"""
import json, subprocess, sys, time, urllib.request

K = "http://127.0.0.1:8000"
# Switch-side channel. bmv2's own thrift CLI is unusable on this machine right now (the p4dev
# venv has no `thrift` module -- checked, `find / -name Thrift.py` returns nothing), so the read
# goes through the P4 proxy's GET /stats/flow/<dpid>, which is a DIFFERENT PROCESS calling
# P4Runtime read_table_entries against the switch. It is not the API that wrote the entries
# (that is the kernel on :8000) and it does not consult the kernel at all.
PROXY = "http://127.0.0.1:8081/stats/flow/1"

def post(path, body):
    req = urllib.request.Request(K + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=6) as r:
        return r.status, r.read().decode()

def counters():
    with urllib.request.urlopen(K + "/ndt/get_flow_dispatch_status", timeout=6) as r:
        return json.loads(r.read().decode())["counters"]

def table():
    with urllib.request.urlopen(PROXY, timeout=20) as r:
        d = json.loads(r.read().decode())
    rows = []
    for _dpid, entries in d.items():
        for e in entries:
            rows.append("%s -> %s" % (e.get("match", {}).get("nw_dst"), ",".join(e.get("actions", []))))
    return sorted(rows)

def install(dst, port):
    return post("/ndt/install_flow_entry",
                {"dpid": 1, "priority": 99,
                 "match": {"eth_type": 2048, "ipv4_dst": dst},
                 "actions": [{"type": "OUTPUT", "port": port}]})

def delete(dst):
    return post("/ndt/delete_flow_entry",
                {"dpid": 1, "priority": 99,
                 "match": {"eth_type": 2048, "ipv4_dst": dst},
                 "actions": [{"type": "OUTPUT", "port": 1}]})

def arm(name, dsts, n, gap):
    c0, t0 = counters(), table()
    print("\n--- arm %s: %d installs, %d distinct match(es), %.2f s apart ---" % (name, n, len(set(dsts)), gap))
    print("    counters before : %s" % c0)
    print("    switch rows before: %d" % len(t0))
    t_start = time.time()
    codes = {}
    for i in range(n):
        st, _ = install(dsts[i % len(dsts)], 1 + (i % 3))
        codes[st] = codes.get(st, 0) + 1
        if gap:
            time.sleep(gap)
    el = time.time() - t_start
    time.sleep(4)   # let the async dispatcher drain
    c1, t1 = counters(), table()
    print("    %d POSTs in %.1f s (%.1f/s), HTTP: %s" % (n, el, n/el, codes))
    print("    counters after  : %s" % c1)
    print("    switch rows after : %d" % len(t1))
    print("    COUNTER delta dispatched=%d succeeded=%d failed=%d" %
          (c1["dispatched"]-c0["dispatched"], c1["succeeded"]-c0["succeeded"], c1["failed"]-c0["failed"]))
    print("    SWITCH  delta rows=%d" % (len(t1)-len(t0)))
    new = [r for r in t1 if r not in t0]
    for r in new[:6]:
        print("      + %s" % r)
    if len(new) > 6:
        print("      ... %d more" % (len(new)-6))
    return c1["succeeded"]-c0["succeeded"], len(t1)-len(t0)

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    gap = float(sys.argv[2]) if len(sys.argv) > 2 else 0.05
    print("#### what this step proves: whether the twin's flow-dispatch counters can be made to")
    print("#### disagree with the switch's own table, and by how much, under rule churn at rate")
    print(time.strftime("%FT%T"))
    print("switch-side channel: %s  (P4Runtime read_table_entries, in the proxy process, not the kernel)" % PROXY)
    base = table()
    print("\nbaseline switch rows: %d" % len(base))
    for r in base:
        print("   %s" % r)

    d1 = ["10.0.0.%d" % (100+i) for i in range(n)]
    s1c, s1t = arm("DISTINCT (control: counters SHOULD equal rows)", d1, n, gap)
    s2c, s2t = arm("SAME MATCH (all %d POSTs are ipv4_dst 10.0.0.99)" % n, ["10.0.0.99"], n, gap)

    print("\n=== the disagreement ===")
    print("  distinct arm : counters +%d, switch +%d  -> ratio %.2f" % (s1c, s1t, (s1c/s1t) if s1t else float('inf')))
    print("  same-match   : counters +%d, switch +%d  -> ratio %.2f" % (s2c, s2t, (s2c/s2t) if s2t else float('inf')))

    print("\n--- cleanup: delete everything this step added, then re-read the switch ---")
    for d in d1 + ["10.0.0.99"]:
        delete(d)
    time.sleep(5)
    after = table()
    print("  switch rows now: %d (baseline was %d)" % (len(after), len(base)))
    leftover = [r for r in after if r not in base]
    print("  leftover rows this step added and could not remove: %d" % len(leftover))
    for r in leftover:
        print("     ! %s" % r)
    print("  counters at end: %s" % counters())

main()
