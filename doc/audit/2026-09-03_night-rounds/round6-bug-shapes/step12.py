import json,time,subprocess,sys
MODE=sys.argv[1]; KLOG=sys.argv[2]
def setmode(**kw):
    m={"links":"ok","switches":"ok","hosts":"ok","flows":{},"flows_default":"ok"}; m.update(kw)
    open(MODE,"w").write(json.dumps(m))
def npart(): return int(subprocess.run(["grep","-c","topology-round-partial",KLOG],capture_output=True,text=True).stdout.strip() or 0)
def arm(name,**kw):
    setmode(); time.sleep(35); b=npart(); setmode(**kw); t0=time.time()
    while time.time()-t0<95: time.sleep(2)
    a=npart(); print("  %-40s partial: %d -> %d  fired=%s"%(name,b,a,a>b),flush=True); setmode(); time.sleep(2)
print("#### STEP 12 -- which non-empty bodies defeat the partial-round detector? ####")
print(time.strftime("%FT%T"))
arm("links: 200 + a JSON object (not an array)", links="malformed")
arm("links: 200 + non-JSON text",               links="garbage")
