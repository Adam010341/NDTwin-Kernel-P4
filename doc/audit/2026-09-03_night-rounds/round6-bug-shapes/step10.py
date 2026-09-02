import json,time,urllib.request,sys
K="http://localhost:8000"; MODE=sys.argv[1]
def get(u,to=10):
    try:
        with urllib.request.urlopen(u,timeout=to) as f: return f.status,json.loads(f.read().decode())
    except Exception as e: return 0,str(e)
def setmode(**kw):
    m={"links":"ok","switches":"ok","hosts":"ok","flows":{},"flows_default":"ok"}; m.update(kw)
    open(MODE,"w").write(json.dumps(m))
def raw(dp):
    s,d=get(K+"/ndt/get_switch_openflow_table_entries")
    for sw in d if isinstance(d,list) else []:
        if sw.get("dpid")==dp: return sw
    return None
print("#### STEP 10 -- the one unreadable shape that carries NO staleness marker ####")
print(time.strftime("%FT%T"))
for trial in (1,2):
    print("\n---- trial %d ----"%trial)
    setmode(rules=["10.0.0.1","10.0.0.2","10.0.0.3","10.0.0.4"]); time.sleep(16)
    print("  healthy baseline d3: n=%s"%len((raw(3) or {}).get("flows",{}).get("3",[])))
    # withdraw a rule fabric-wide, and make three switches unreadable in three different ways
    setmode(rules=["10.0.0.1","10.0.0.2"],
            flows={"3":"malformed","5":"http500","6":"garbage"})
    time.sleep(40)
    for dp in (1,3,5,6):
        sw=raw(dp)
        body=json.dumps(sw)
        print("  d%-2d  %s"%(dp, body[:420]))
    print("  ---- what a consumer sees for d3's 'flows' value: %s"%type((raw(3) or {}).get("flows",{}).get("3")).__name__)
setmode(rules=["10.0.0.1","10.0.0.2","10.0.0.3","10.0.0.4"])
