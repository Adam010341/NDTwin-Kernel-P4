#!/usr/bin/env python3
"""Read-only: apply B's settled() rule to every p4runtime/solution round in runs/ (and print the counter history).
Run with PYTHONDONTWRITEBYTECODE=1 so nothing is written into B's worktree."""
import os, re, sys, glob
B_WT = "/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927"
LP = "doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1"
sys.path.insert(0, os.path.join(B_WT, LP))
import external_evidence as ev  # noqa: E402

PREP = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep"
S1 = "s1 MyIngress.ingressTunnelCounter 100"
S2E = "s2 MyIngress.egressTunnelCounter 100"
S2I = "s2 MyIngress.ingressTunnelCounter 200"
TOTAL = re.compile(r"(\d+)/\s*(\d+) \(")

def blocks_of(log):
    out, cur = [], None
    for line in open(log, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("----- Reading tunnel counters"):
            cur = {}; out.append(cur); continue
        m = ev.COUNTER.match(line)
        if m and cur is not None:
            cur[m.group(1)] = (int(m.group(2)), int(m.group(3)))
        elif not line.strip():
            cur = None
    return out

today = set(sys.argv[1:])  # stamps to SKIP the decisive part for (only settled verdict printed)
reports = sorted(glob.glob(os.path.join(PREP, "runs", "*_p4runtime_solution_ndtwin.md")))
print("stamp\tblocks\tbefore(s1,s2e,s2i)\tfinal(s1 pk/bytes,s2e,s2i pk/bytes)\tsent\tsrv_total\tno_ack\tpings\texp\tfinal==before\tsettled_now\ts1-(pings+sent)\tbytes_check")
for rep in reports:
    stamp = os.path.basename(rep)[:18]
    rd = ev.round_dir(rep)
    try:
        log = ev.controller_log(rep)
    except ev.Unreadable as e:
        print(stamp, "NO LOG", e); continue
    c = ev.controller_evidence(log)
    r = ev.report_evidence(rep)
    e = dict(c, **r)
    bl = blocks_of(log)
    fin, bef = e["counters_final"], e["_counters_before"]
    exp = ev.expected_s1_in(("p4runtime", "solution"), e)
    try:
        ev.settled(("p4runtime", "solution"), e); st = "settled"
    except ev.Unreadable:
        st = "UNREADABLE"
    srv = "?"
    sp = os.path.join(rd, "link_usage", "iperf_server.txt")
    cp = os.path.join(rd, "link_usage", "iperf_client.txt")
    for p in (cp, sp):
        if os.path.exists(p):
            m = TOTAL.findall(open(p).read())
            if m: srv = m[-1][1]
    s1 = fin.get(S1, (None, None)); s2e = fin.get(S2E, (None, None)); s2i = fin.get(S2I, (None, None))
    if stamp.startswith("2026-10-02"):
        s2i = ("masked", "masked")  # today's: only what the settled check reads
    b1 = bef.get(S1, (None,))[0] if bef else None
    b2 = bef.get(S2E, (None,))[0] if bef else None
    b3 = bef.get(S2I, (None,))[0] if bef else None
    if stamp.startswith("2026-10-02"):
        b3 = "masked"
    sent, pings = r["iperf"]["sent"], r["pings_h1_h2"]
    # bytes: pings 98 B each, datagrams 1242 B each (1200 payload + 8 + 20 + 14)
    if s1[1] is not None and pings is not None:
        dg = (s1[1] - pings * 98) / 1242
        bc = f"(bytes-{pings}*98)/1242={dg:.3f}"
    else:
        bc = "-"
    print(f"{stamp}\t{len(bl)}\t({b1},{b2},{b3})\t({s1[0]}/{s1[1]},{s2e[0]},{s2i[0]}/{s2i[1]})\t{sent}\t{srv}\t"
          f"{r['iperf']['no_ack']}\t{pings}\t{exp}\t{bef == fin}\t{st}\t"
          f"{(s1[0] - pings - sent) if s1[0] is not None else '-'}\t{bc}")
