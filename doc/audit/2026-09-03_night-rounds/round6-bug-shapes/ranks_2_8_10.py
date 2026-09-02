import json,time,urllib.request,subprocess,sys
K="http://localhost:8000"; F="http://localhost:8081"
MODE=sys.argv[1]; LOG=sys.argv[2]
def get(u,to=8):
    try:
        with urllib.request.urlopen(u,timeout=to) as f: return f.status,json.loads(f.read().decode())
    except Exception as e: return 0,str(e)
def setmode(**kw):
    m={"links":"ok","switches":"ok","hosts":"ok","flows":{},"flows_default":"ok"}
    m.update(kw); open(MODE,"w").write(json.dumps(m)); return m
def graph():
    s,d=get(K+"/ndt/get_graph_data")
    if not isinstance(d,dict): return None
    e=d["edges"]
    return {"edges":len(e),"up":sum(1 for x in e if x.get("is_up")),
            "en":sum(1 for x in e if x.get("is_enabled")),
            "keys":{(x["src_dpid"],x["src_interface"]):(x.get("is_up"),x.get("is_enabled")) for x in e}}
def tables():
    s,d=get(K+"/ndt/get_switch_openflow_table_entries")
    out={}
    if isinstance(d,list):
        for sw in d:
            dp=sw.get("dpid"); fl=sw.get("flows",{})
            arr=fl.get(str(dp)) if isinstance(fl,dict) else None
            out[dp]={"n":len(arr) if isinstance(arr,list) else -1,
                     "dsts":sorted(e.get("match",{}).get("nw_dst") for e in arr) if isinstance(arr,list) else None,
                     "marks":{k:v for k,v in sw.items() if k in ("stale_since","stale_polls","last_error")}}
    return out
def kgrep(pat):
    return int(subprocess.run(["grep","-c",pat,sys.argv[3]],capture_output=True,text=True).stdout.strip() or 0)
def show_t(tag):
    t=tables()
    print("  %-22s %s"%(tag," ".join("d%s:n=%s%s"%(k,v["n"],("!"+",".join("%s=%s"%(a,b) for a,b in v["marks"].items())) if v["marks"] else "") for k,v in sorted(t.items()))))
    return t
print("#### RANKS 8 / 2 / 10 against a controllable southbound stand-in ####")
print("# kernel pid from ps; binary a8ba99c2; fake serves ryu_topology.py's exact shapes")
print(time.strftime("%FT%T"))

print("\n=== PHASE A -- control: everything healthy ===")
setmode(); time.sleep(12)
g=graph(); print("  graph: edges=%d up=%d enabled=%d"%(g["edges"],g["up"],g["en"]))
tA=show_t("tables")
print("  sample dsts d1: %s"%tA.get(1,{}).get("dsts"))
base_partial=kgrep("topology-round-partial")
print("  'topology-round-partial' lines so far: %d"%base_partial)

print("\n=== PHASE B1 (RANK 8) -- /links answers HTTP 500, /switches and /hosts stay healthy ===")
setmode(links="http500")
t0=time.time()
for dt in (10,30,50,75):
    while time.time()-t0<dt: time.sleep(1)
    g=graph(); print("  +%3ds edges=%d up=%d enabled=%d   partial-log-lines=%d"%(dt,g["edges"],g["up"],g["en"],kgrep("topology-round-partial")))
print("  any endpoint field that says the round was partial?")
s,d=get(K+"/ndt/get_graph_data")
print("   graph_data top-level keys: %s"%(sorted(d.keys()) if isinstance(d,dict) else d))
print("   an edge's keys:            %s"%sorted(d["edges"][0].keys()))

print("\n=== PHASE B2 (RANK 8b) -- /links answers 200 but OMITS 8 link directions (the watchdog's own 'down' signal) ===")
s,L=get(F+"/v1.0/topology/links"); setmode(links="ok",links_drop=8)
s,L2=get(F+"/v1.0/topology/links")
dropped=[(int(x["src"]["dpid"],16),int(x["src"]["port_no"],16)) for x in L[:8]]
print("  omitted (src_dpid,src_port): %s"%dropped)
t0=time.time()
for dt in (10,40,75):
    while time.time()-t0<dt: time.sleep(1)
    g=graph()
    st=[g["keys"].get(k) for k in dropped]
    print("  +%3ds edges_up=%d enabled=%d ; omitted edges (is_up,is_enabled)=%s"%(dt,g["up"],g["en"],st))

print("\n=== PHASE C (RANKS 2 + 10) -- one rule withdrawn fabric-wide; d3 malformed, d4 empty, d5 HTTP 500 ===")
setmode(links="ok",rules=["10.0.0.1","10.0.0.2","10.0.0.3"],
        flows={"3":"malformed","4":"empty","5":"http500"})
print("  fake now serves 3 rules (10.0.0.4 withdrawn) to every healthy switch")
t0=time.time()
for dt in (12,25,45,70):
    while time.time()-t0<dt: time.sleep(1)
    print("  +%3ds"%dt, end=""); t=show_t("")
    if dt==70:
        for dp in (1,3,4,5):
            print("     d%-2d dsts=%s marks=%s"%(dp,t.get(dp,{}).get("dsts"),t.get(dp,{}).get("marks")))

print("\n=== PHASE D -- everything healthy again: does a skipped switch recover? ===")
setmode(rules=["10.0.0.1","10.0.0.2","10.0.0.3"])
t0=time.time()
for dt in (15,35,60):
    while time.time()-t0<dt: time.sleep(1)
    print("  +%3ds"%dt, end=""); show_t("")
print("\n  final 'topology-round-partial' count: %d (base %d)"%(kgrep("topology-round-partial"),base_partial))
