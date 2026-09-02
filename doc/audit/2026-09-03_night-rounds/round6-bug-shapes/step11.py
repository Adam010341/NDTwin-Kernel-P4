import json,time,subprocess,sys,urllib.request
K="http://localhost:8000"; MODE=sys.argv[1]; KLOG=sys.argv[2]
def setmode(**kw):
    m={"links":"ok","switches":"ok","hosts":"ok","flows":{},"flows_default":"ok"}; m.update(kw)
    open(MODE,"w").write(json.dumps(m))
def npart(): return int(subprocess.run(["grep","-c","topology-round-partial",KLOG],capture_output=True,text=True).stdout.strip() or 0)
def graph():
    with urllib.request.urlopen(K+"/ndt/get_graph_data",timeout=10) as f: d=json.loads(f.read().decode())
    e=d["edges"]; n=d["nodes"]
    return len(n),len(e),sum(1 for x in e if x.get("is_up")),sum(1 for x in n if x.get("is_up"))
def arm(name,**kw):
    setmode(); time.sleep(35); b=npart()
    setmode(**kw); t0=time.time()
    while time.time()-t0<100: time.sleep(2)
    a=npart(); nn,ne,eu,nu=graph()
    print("  %-34s partial: %d -> %d  (fired=%s)   nodes=%d nodes_up=%d edges=%d edges_up=%d"%(name,b,a,a>b,nn,nu,ne,eu),flush=True)
    setmode(); time.sleep(2)
print("#### STEP 11 -- does the partial-round detector see an HTTP 5xx on ANY of the three roles? ####")
print("# the detector's test is `!body.empty()` (TopologyAndFlowMonitor.cpp:588-590), which never")
print("# looks at the status line. Each arm runs >=3 poll intervals (30s each once converged).")
print(time.strftime("%FT%T"))
arm("links = HTTP 500 (json error body)",  links="http500")
arm("switches = HTTP 500",                 switches="http500")
arm("hosts = HTTP 500",                    hosts="http500")
arm("switches = EMPTY 200 body (control)", switches="emptybody")
print("\n# contrast, same binary, same round: the FLOW-TABLE fetch does check the status --")
print("# step 09/10 showed dpid5 (HTTP 500) marked last_error=reported_failure and dpid6")
print("# (non-JSON body) marked last_error=unparseable.")
