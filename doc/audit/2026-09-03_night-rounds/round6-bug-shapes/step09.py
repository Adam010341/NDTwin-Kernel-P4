import json,time,urllib.request,subprocess,sys
K="http://localhost:8000"; F="http://localhost:8081"
MODE=sys.argv[1]; KLOG=sys.argv[2]
def get(u,to=10):
    try:
        with urllib.request.urlopen(u,timeout=to) as f: return f.status,json.loads(f.read().decode())
    except Exception as e: return 0,str(e)
def setmode(**kw):
    m={"links":"ok","switches":"ok","hosts":"ok","flows":{},"flows_default":"ok"}; m.update(kw)
    open(MODE,"w").write(json.dumps(m)); return m
def npart(): return int(subprocess.run(["grep","-c","topology-round-partial",KLOG],capture_output=True,text=True).stdout.strip() or 0)
def partlines(): return subprocess.run(["grep","topology-round-partial",KLOG],capture_output=True,text=True).stdout
def graph():
    s,d=get(K+"/ndt/get_graph_data")
    if not isinstance(d,dict): return None
    e=d["edges"]
    return {"n":len(e),"up":sum(1 for x in e if x.get("is_up")),"en":sum(1 for x in e if x.get("is_enabled")),
            "keys":{(x["src_dpid"],x["src_interface"]):(x.get("is_up"),x.get("is_enabled")) for x in e}}
def tables():
    s,d=get(K+"/ndt/get_switch_openflow_table_entries")
    out={}
    if isinstance(d,list):
        for sw in d:
            dp=sw.get("dpid"); fl=sw.get("flows",{})
            arr=fl.get(str(dp)) if isinstance(fl,dict) else None
            out[dp]={"n":len(arr) if isinstance(arr,list) else -1,
                     "dsts":sorted(str(e.get("match",{}).get("nw_dst")) for e in arr) if isinstance(arr,list) else None,
                     "marks":{k:v for k,v in sw.items() if k in ("stale_since","stale_polls","last_error")}}
    return out
def show(pre):
    t=tables()
    print("%s %s"%(pre," ".join("d%s=%s%s"%(k,v["n"],("["+",".join("%s"%b for a,b in v["marks"].items())+"]") if v["marks"] else "") for k,v in sorted(t.items()))),flush=True)
    return t
def wait(t0,dt):
    while time.time()-t0<dt: time.sleep(1)

print("#### STEP 09 -- rank 8 mutation gate, rank 8b link omission, ranks 2+10 per-switch flow query ####")
print(time.strftime("%FT%T")); print("partial-round lines at start: %d"%npart())

print("\n=== B1b MUTATION GATE for rank 8: /links returns an EMPTY 200 body (a wedged curl looks like this) ===")
print("    if the partial-round warning cannot fire here, the '0 lines' under HTTP 500 proves nothing.")
setmode(links="emptybody"); t0=time.time()
for dt in (35,70,100):
    wait(t0,dt); print("  +%3ds partial-lines=%d  graph up/en=%d/%d"%(dt,npart(),graph()["up"],graph()["en"]),flush=True)
print("  --- the warning text, if any ---"); print(partlines()[:1200])

print("\n=== B1c: back to a healthy /links, then /links = HTTP 500 with a JSON error body ===")
setmode(); time.sleep(35); base=npart(); print("  healthy again; partial-lines=%d"%base)
setmode(links="http500"); t0=time.time()
for dt in (35,70,100):
    wait(t0,dt); print("  +%3ds partial-lines=%d (base %d)  graph up/en=%d/%d"%(dt,npart(),base,graph()["up"],graph()["en"]),flush=True)

print("\n=== B2 (rank 8b): /links answers 200 and simply OMITS 8 link directions ===")
setmode(); time.sleep(3)
s,L=get(F+"/v1.0/topology/links")
dropped=[(int(x["src"]["dpid"],16),int(x["src"]["port_no"],16)) for x in L[:8]]
print("  omitted (src_dpid,src_port): %s"%dropped)
setmode(links_drop=8); t0=time.time()
for dt in (35,70):
    wait(t0,dt); g=graph()
    print("  +%3ds up=%d en=%d ; omitted edges (is_up,is_enabled)=%s"%(dt,g["up"],g["en"],[g["keys"].get(k) for k in dropped]),flush=True)

print("\n=== C (ranks 2 + 10): withdraw 10.0.0.4 fabric-wide; d3 malformed, d4 empty, d5 HTTP 500, d6 garbage ===")
setmode(rules=["10.0.0.1","10.0.0.2","10.0.0.3"],flows={"3":"malformed","4":"empty","5":"http500","6":"garbage"})
t0=time.time()
for dt in (15,30,50,80):
    wait(t0,dt); show("  +%3ds"%dt)
t=tables()
for dp in (1,3,4,5,6):
    print("    d%-2d n=%s dsts=%s marks=%s"%(dp,t.get(dp,{}).get("n"),t.get(dp,{}).get("dsts"),t.get(dp,{}).get("marks")))

print("\n=== D: everything healthy again (still 3 rules) -- does a skipped switch recover? ===")
setmode(rules=["10.0.0.1","10.0.0.2","10.0.0.3"]); t0=time.time()
for dt in (15,35,60):
    wait(t0,dt); show("  +%3ds"%dt)
print("\nfinal partial-round line count: %d"%npart())
