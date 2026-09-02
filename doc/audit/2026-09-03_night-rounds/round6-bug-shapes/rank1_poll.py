import json,subprocess,time,urllib.request,sys
B="http://localhost:8000"
def get(p):
    try:
        with urllib.request.urlopen(B+p,timeout=3) as r: return json.loads(r.read().decode())
    except Exception as e: return {"__err__":str(e)}
print("BASELINE liveness=all:",json.dumps(get("/ndt/get_detected_top_k_flow_data?k=10&liveness=all"))[:200])
t0=time.time()
cli=subprocess.Popen(["sudo","-n","mnexec","-a","1432565","iperf3","-c","10.0.0.2","-u","-b","50M","-l","1400","-t","10","-p","5201"],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
S=[]
while time.time()-t0 < 38:
    t=time.time()-t0
    a=get("/ndt/get_detected_top_k_flow_data?k=10&liveness=all")
    d=get("/ndt/get_detected_top_k_flow_data?k=10")
    S.append({"t":round(t,2),"all":a,"default":d}); time.sleep(0.5)
out=cli.communicate()[0].decode(errors="replace")
print("---- wire ground truth ----"); print(out[-400:])
json.dump(S,open(sys.argv[1],"w"),indent=1)
keys=set()
for s in S:
    for r in (s["all"] if isinstance(s["all"],list) else []): keys|=set(r.keys())
print("---- ALL distinct keys ever returned by the endpoint (%d) ----"%len(keys)); print(sorted(keys))
print("---- keys matching 'elephant': %r ----"%[k for k in keys if "elephant" in k.lower()])
print("---- t | n_all n_def | liveness | rate_last_sec | rate_proceeding_1s (the A-3 sort key) ----")
for s in S:
    a=s["all"] if isinstance(s["all"],list) else []
    d=s["default"] if isinstance(s["default"],list) else []
    r=a[0] if a else {}
    print("t=%6.2f | all=%d def=%d | %-8s | last=%-10s proc=%-10s pkt_proc=%s"%(
        s["t"],len(a),len(d),r.get("liveness","-"),
        r.get("estimated_flow_sending_rate_bps_in_the_last_sec","-"),
        r.get("estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot","-"),
        r.get("estimated_packet_rate_in_the_proceeding_1sec_timeslot","-")))
