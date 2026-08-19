"""analyse.py with the quantum as an argument -- it is per-flow, so it must be measured."""
import json, sys, math, statistics as st
PATH=sys.argv[1]; EDGE=sys.argv[2]; QUANTUM=int(sys.argv[3])
rows=[json.loads(l) for l in open(PATH) if '"error"' not in l]
HZ=(len(rows)-1)/(rows[-1]["t"]-rows[0]["t"])
print(f"{len(rows)} samples, span {rows[-1]['t']-rows[0]['t']:.0f}s, {HZ:.2f} Hz, quantum {QUANTUM:,}")
def twin(a,b):
    n=d=0.0
    for i in range(a,b-1):
        dt=rows[i+1]["t"]-rows[i]["t"]; n+=rows[i]["twin"].get(EDGE,0)*dt; d+=dt
    return n/d if d else 0.0
def gt(a,b):
    dt=rows[b-1]["t"]-rows[a]["t"]; db=rows[b-1]["tx"][EDGE]-rows[a]["tx"][EDGE]
    return db*8/dt if dt else 0.0
def agg_twin(a,b):
    n=d=0.0
    for i in range(a,b-1):
        dt=rows[i+1]["t"]-rows[i]["t"]; n+=sum(rows[i]["twin"].values())*dt; d+=dt
    return n/d if d else 0.0
SS=set(rows[0]["twin"].keys())
def agg_gt(a,b):
    dt=rows[b-1]["t"]-rows[a]["t"]
    if not dt: return 0.0
    return sum(rows[b-1]["tx"][k]-rows[a]["tx"][k] for k in SS if k in rows[a]["tx"] and k in rows[b-1]["tx"])*8/dt
for label,tw,g_ in (("PER-LINK "+EDGE,twin,gt),("AGGREGATE (%d edges)"%len(SS),agg_twin,agg_gt)):
    print(f"\n=== {label} ===")
    print(f"{'T(s)':>5}{'n':>5}{'gt Mbps':>9}{'min':>7}{'Q1':>7}{'med':>7}{'Q3':>7}{'max':>7}{'spread±%':>9}{'theory±%':>9}")
    for T in (1,2,5,10,30,60,150,300):
        step=max(1,int(round(T*HZ))); r=[];gs=[];i=0
        while i+step<len(rows):
            gg=g_(i,i+step+1); ww=tw(i,i+step+1)
            if gg>1e6: r.append(ww/gg); gs.append(gg)
            i+=step
        if len(r)<2: continue
        gm=st.mean(gs); c=gm*T/QUANTUM; th=196/math.sqrt(c)
        q=st.quantiles(sorted(r),n=4) if len(r)>=4 else [min(r),st.median(r),max(r)]
        print(f"{T:>5}{len(r):>5}{gm/1e6:>9.1f}{min(r):>7.3f}{q[0]:>7.3f}{st.median(r):>7.3f}{q[2]:>7.3f}{max(r):>7.3f}{1.96*st.pstdev(r)*100:>9.1f}{th:>9.1f}")
