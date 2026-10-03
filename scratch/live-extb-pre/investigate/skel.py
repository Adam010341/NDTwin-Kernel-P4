import os, sys, glob
sys.path.insert(0, "/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1")
import external_evidence as ev
P = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs"
for rep in sorted(glob.glob(P + "/2026-09-*_p4runtime_skeleton_ndtwin.md")):
    e = dict(ev.controller_evidence(ev.controller_log(rep)), **ev.report_evidence(rep))
    try: ev.settled(("p4runtime", "skeleton"), e); st = "settled"
    except ev.Unreadable: st = "UNREADABLE"
    print(os.path.basename(rep)[:18], e["counters_final"].get("s1 MyIngress.ingressTunnelCounter 100"), e["pings_h1_h2"], e["_counters_before"] == e["counters_final"], st)
print("flowcache expected:", ev.expected_s1_in(("flowcache", "solution"), {}))
