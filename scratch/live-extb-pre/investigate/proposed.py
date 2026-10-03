"""Read-only: the proposed settled rule (not written into any code) applied to every p4runtime/solution round.
settled iff last == before, or (s2 egress 100 == s1 ingress 100 in the last block and
pings + D <= s1 <= pings + D + 10), D = iperf Sent - 1 (= the server report's Total in every acked earlier round)."""
import os, re, sys, glob
sys.path.insert(0, "/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1")
import external_evidence as ev
P = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs"
TOTAL = re.compile(r"(\d+)/\s*(\d+) \(")
for rep in sorted(glob.glob(P + "/*_p4runtime_solution_ndtwin.md")):
    e = dict(ev.controller_evidence(ev.controller_log(rep)), **ev.report_evidence(rep))
    last, before = e["counters_final"], e["_counters_before"]
    s1 = last.get("s1 MyIngress.ingressTunnelCounter 100", (None,))[0]
    s2e = last.get("s2 MyIngress.egressTunnelCounter 100", (None,))[0]
    ip = e["iperf"]
    cli = ev.read_text(os.path.join(ev.round_dir(rep), "link_usage", "iperf_client.txt"))
    tot = TOTAL.findall(cli)
    acked = bool(tot) and not ip["no_ack"]
    if before == last:
        verdict = "settled (repeat)"
    elif acked and ip["target"] == "10.0.2.2":
        lo = e["pings_h1_h2"] + ip["sent"] - 1
        lo_t = e["pings_h1_h2"] + int(tot[-1][1])
        ok = s2e == s1 and lo <= s1 <= lo + ev.IPERF_FIN_RETRIES
        ok_t = s2e == s1 and lo_t <= s1 <= lo_t + ev.IPERF_FIN_RETRIES
        verdict = f"{'settled' if ok else 'UNREADABLE'} (Sent-1: [{lo},{lo+10}]; Total: {'settled' if ok_t else 'UNREADABLE'} [{lo_t},{lo_t+10}]; s2e==s1 {s2e == s1})"
    else:
        verdict = "UNREADABLE (no server report: only a repeated block can settle it)"
    print(os.path.basename(rep)[:18], s1, verdict)
