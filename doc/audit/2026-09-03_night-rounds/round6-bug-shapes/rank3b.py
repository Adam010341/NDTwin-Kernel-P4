import json,subprocess,time,urllib.request
K="http://localhost:8000"; P="http://localhost:8081"; D=6
def req(u,data=None,method=None,to=25):
    r=urllib.request.Request(u,data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type":"application/json"},method=method)
    try:
        with urllib.request.urlopen(r,timeout=to) as f: return f.status,json.loads(f.read().decode())
    except urllib.error.HTTPError as e: return e.code,e.read().decode()[:200]
    except Exception as e: return 0,str(e)
def kern():
    s,j=req(K+"/ndt/get_switch_openflow_table_entries")
    if not isinstance(j,list): return None,j,None
    for sw in j:
        f=sw.get("flows",{})
        if str(D) in f: return f[str(D)],None,{k:v for k,v in sw.items() if k!="flows"}
    return None,"dpid %d absent from response"%D,None
def sw():
    s,j=req(P+"/stats/flow/%d"%D)
    return (j.get(str(D)) if isinstance(j,dict) else None),(s,str(j)[:120])
def m(e): return str(e.get("match"))
def snap(tag):
    kf,kerr,meta=kern(); sf,serr=sw()
    kn=len(kf) if isinstance(kf,list) else -1; sn=len(sf) if isinstance(sf,list) else -1
    print("%-26s kernel_rows=%-3d switch_rows=%-3d AGREE=%-5s meta=%s"%(tag,kn,sn,kn==sn,meta))
    if isinstance(kf,list): print("        kernel: %s"%sorted(m(e) for e in kf))
    else: print("        kernel: ERR %s"%kerr)
    if isinstance(sf,list): print("        switch: %s"%sorted(m(e) for e in sf))
    else: print("        switch: ERR %s"%(serr,))
print("#### RANK 3 -- how long does the kernel serve flow-table rows a switch no longer has? ####")
print("# kernel channel : GET /ndt/get_switch_openflow_table_entries (m_cachedOpenFlowTables)")
print("# truth  channel : GET :8081/stats/flow/%d (P4Runtime read, different process)"%D)
print(time.strftime("%FT%T"))
snap("A. baseline")
for d in ("10.0.0.231","10.0.0.232","10.0.0.233"):
    s,j=req(K+"/ndt/install_flow_entry",{"dpid":D,"priority":1,
        "match":{"eth_type":2048,"ipv4_dst":d},"actions":[{"type":"OUTPUT","port":1}]})
    print("   install %s -> HTTP %s"%(d,s))
time.sleep(2); snap("B. installs +2s")
time.sleep(13); snap("C. installs +15s (cache worker ~10s)")
print(">>> out-of-band: sudo -n ndtwin-p4-power off s%d  (no kernel command involved)"%D)
print(subprocess.run(["sudo","-n","ndtwin-p4-power","off","s%d"%D],capture_output=True,text=True).stdout.strip())
t0=time.time()
for dt in (2,6,12,20,35,50):
    while time.time()-t0<dt: time.sleep(0.3)
    snap("D. powered off +%ds"%dt)
print(">>> out-of-band: sudo -n ndtwin-p4-power on s%d, then POST :8081/p4/readopt/%d"%(D,D))
print(subprocess.run(["sudo","-n","ndtwin-p4-power","on","s%d"%D],capture_output=True,text=True).stdout.strip())
time.sleep(2)
s,j=req(P+"/p4/readopt/%d"%D,{},method="POST",to=60)
print(">>> readopt -> HTTP %s %s"%(s,json.dumps(j)[:200]))
t1=time.time()
for dt in (1,5,12,25,40):
    while time.time()-t1<dt: time.sleep(0.3)
    snap("E. readopt +%ds"%dt)
