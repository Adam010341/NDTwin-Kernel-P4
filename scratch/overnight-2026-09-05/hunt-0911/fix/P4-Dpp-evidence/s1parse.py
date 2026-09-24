import re, sys, collections
L = sys.argv[1]
line_re = re.compile(r"^\[(\d\d):(\d\d):(\d\d\.\d+)\] \[bmv2\] \[.\] \[thread (\d+)\] \[(\d+)\.(\d+)\] \[cxt 0\] (.*)$")
pk = collections.defaultdict(dict)
for ln in open(L, errors="replace"):
    m = line_re.match(ln.rstrip("\n"))
    if not m: continue
    h, mi, s, th, pid, sub, msg = m.groups()
    t = int(h)*3600 + int(mi)*60 + float(s)
    pid = int(pid)
    d = pk[pid]
    if msg.startswith("Processing packet received on port"):
        d["in_t"] = t; d["in_port"] = int(msg.split()[-1])
    elif "Egress port is" in msg:
        d["eport"] = int(msg.split()[-1])
    elif msg.startswith("Pipeline 'egress': start"):
        d.setdefault("eg_t", t)
    elif "enq_qdepth" in msg:
        d["mark"] = msg.endswith("is true")
    elif "hdr.ipv4.ecn == 1" in msg:
        d["ecn1"] = msg.endswith("is true")
    elif msg.startswith("Transmitting packet"):
        d["tx_t"] = t
t0 = min(d["in_t"] for d in pk.values() if "in_t" in d)
bg = sorted(d["in_t"] for d in pk.values() if d.get("in_port") == 1 and d.get("eport") == 3)
print("bg (port1->port3): n=%d first=%.2f last=%.2f (rel to log start)" % (len(bg), bg[0]-t0, bg[-1]-t0) if bg else "no bg")
bgt0 = bg[0] if bg else t0
# queue sojourn of bg packets over time (egress start - ingress)
soj = [(d["in_t"]-bgt0, d["eg_t"]-d["in_t"]) for d in pk.values() if d.get("in_port")==1 and d.get("eport")==3 and "eg_t" in d]
soj.sort()
for sec in range(0, int(soj[-1][0])+2, 1):
    xs = [s for (a,s) in soj if sec <= a < sec+1]
    ins = [d for d in pk.values() if d.get("in_port")==1 and d.get("eport")==3 and sec <= d["in_t"]-bgt0 < sec+1]
    dropped = [d for d in ins if "eg_t" not in d]
    if ins: print("  bg t=%2d..%2d s: in=%3d egressed=%3d dropped_at_queue=%3d  mean sojourn=%.3f s" % (sec, sec+1, len(ins), len(ins)-len(dropped), len(dropped), (sum(xs)/len(xs)) if xs else float('nan')))
print("probes (ecn==1 evaluated at egress, or port2 ingress):")
for pid, d in sorted(pk.items(), key=lambda kv: kv[1].get("in_t", 0)):
    if d.get("in_port") == 2:
        print("  pkt %5d in=%.2f eport=%s eg=%s mark=%s tx=%s" % (pid, d["in_t"]-bgt0, d.get("eport"),
              "%.2f" % (d["eg_t"]-bgt0) if "eg_t" in d else "DROPPED/none", d.get("mark"),
              "%.2f" % (d["tx_t"]-bgt0) if "tx_t" in d else "-"))
