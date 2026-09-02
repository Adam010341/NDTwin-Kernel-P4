import json,time,urllib.request,sys
K="http://localhost:8000"; P="http://localhost:8081"
def req(u,data=None,method=None,to=20):
    r=urllib.request.Request(u,data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type":"application/json"},method=method)
    try:
        with urllib.request.urlopen(r,timeout=to) as f: return f.status,json.loads(f.read().decode())
    except urllib.error.HTTPError as e: return e.code,e.read().decode()[:300]
    except Exception as e: return 0,str(e)
def kernel_dpid1():
    s,j=req(K+"/ndt/get_switch_openflow_table_entries")
    if not isinstance(j,list): return s,None,j
    for sw in j:
        f=sw.get("flows",{})
        if "1" in f: return s,f["1"],None
    return s,None,j
def switch_dpid1():
    s,j=req(P+"/stats/flow/1")
    if isinstance(j,dict) and "1" in j: return s,j["1"]
    return s,j
def snap(tag):
    ks,kf,kerr=kernel_dpid1(); ss,sf=switch_dpid1()
    kn=len(kf) if isinstance(kf,list) else -1
    sn=len(sf) if isinstance(sf,list) else -1
    kdst=sorted([str(e.get("match",{}).get("ipv4_dst",e.get("match"))) for e in kf]) if isinstance(kf,list) else kerr
    sdst=sorted([str(e.get("match",{}).get("ipv4_dst",e.get("match"))) for e in sf]) if isinstance(sf,list) else sf
    print("%-28s kernel_rows=%-3d switch_rows=%-3d  AGREE=%s"%(tag,kn,sn,kn==sn))
    print("      kernel matches: %s"%kdst)
    print("      switch matches: %s"%sdst)
    return kn,sn
print("#### RANK 3 -- is m_cachedOpenFlowTables invalidated after POST /p4/readopt/{dpid}? ####")
print("# kernel channel: GET /ndt/get_switch_openflow_table_entries (reads m_cachedOpenFlowTables)")
print("# ground-truth channel: GET :8081/stats/flow/1 (P4Runtime read_table_entries, a different process)")
print(time.strftime("%FT%T"))
snap("A. baseline")
for d in ("10.0.0.231","10.0.0.232","10.0.0.233"):
    s,j=req(K+"/ndt/install_flow_entry",{"dpid":1,"match":{"ipv4_dst":d+"/32"},
        "actions":[{"type":"OUTPUT","port":1}],"table":"ipv4_lpm"})
    print("   install %s -> HTTP %s %s"%(d,s,json.dumps(j)[:120]))
time.sleep(3); snap("B. after 3 installs")
time.sleep(12); snap("C. +12s (cache worker is ~10s)")
t0=time.time()
s,j=req(P+"/p4/readopt/1",{},method="POST",to=60)
print(">>> POST :8081/p4/readopt/1 -> HTTP %s %s   (%.2fs)"%(s,json.dumps(j)[:250],time.time()-t0))
for dt in (0.5,2,5,10,15,25,40):
    while time.time()-t0 < dt: time.sleep(0.2)
    snap("D. readopt +%.1fs"%(time.time()-t0))
