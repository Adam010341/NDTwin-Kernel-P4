#!/usr/bin/env python3
"""Does `priority` mean anything in the kernel's flow API on the P4 plane?

The persona brief's hazard: "a modify that matches on the wrong key can silently rewrite the
controller's own route". Read-back is the P4 proxy's P4Runtime read (:8081), a different process,
never the kernel API that wrote the entry.

The instrument's own positive control is built in: it is the SAME read-back that shows
OUTPUT:1 -> OUTPUT:2 -> OUTPUT:3 changing, so it demonstrably can see a difference.
[Co-developed with claude code -- Adam]
"""
import json, time, urllib.request
K="http://127.0.0.1:8000"; PROXY="http://127.0.0.1:8081/stats/flow/1"; D="10.0.0.210"
def post(p,b):
    r=urllib.request.Request(K+p,data=json.dumps(b).encode(),headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(r,timeout=10) as x: return x.status, json.loads(x.read().decode())
def rows():
    with urllib.request.urlopen(PROXY,timeout=25) as r: d=json.loads(r.read().decode())
    out=[]
    for _k,es in d.items():
        for e in es: out.append("%s p=%s -> %s" % (e.get("match",{}).get("nw_dst"), e.get("priority"), ",".join(e.get("actions",[]))))
    return sorted(out)
def ctr():
    with urllib.request.urlopen(K+"/ndt/get_flow_dispatch_status",timeout=10) as r:
        return json.loads(r.read().decode())["counters"]
def show(t):
    rs=rows(); mine=[r for r in rs if D in r]
    print("  %-46s total_rows=%d  rows_for_%s=%s  counters=%s" % (t, len(rs), D, mine, ctr()))
    return rs
def body(op,prio,port):
    return {"dpid":1,"priority":prio,"match":{"eth_type":2048,"ipv4_dst":D},
            "actions":[{"type":"OUTPUT","port":port}]}
print("== step 0: baseline"); b0=show("baseline")
for label,path,prio,port in [
    ("1: install  priority=100 OUTPUT:1","/ndt/install_flow_entry",100,1),
    ("2: install  priority=500 OUTPUT:2  (same match, HIGHER priority)","/ndt/install_flow_entry",500,2),
    ("3: modify   priority=777 OUTPUT:3  (a priority NO rule was created with)","/ndt/modify_flow_entry",777,3),
]:
    st,bd=post(path,body(path,prio,port))
    print("== step %s -> HTTP %s %s" % (label, st, bd.get("status")))
    time.sleep(4); show("after step "+label.split(":")[0])
st,bd=post("/ndt/delete_flow_entry",body("del",999,9))
print("== step 4: delete priority=999 OUTPUT:9 (neither ever used) -> HTTP %s %s" % (st,bd.get("status")))
time.sleep(4); b4=show("after delete")
print("== baseline restored:", b0==b4)
