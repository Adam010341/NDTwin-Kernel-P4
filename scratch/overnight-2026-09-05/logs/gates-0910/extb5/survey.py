# historic variability of external_evidence's COMPARED fields over every external round in the
# main checkout's runs/ (read-only). [Co-developed with claude code -- Adam]
import glob, os, sys, collections, re
sys.path.insert(0, sys.argv[1])
import external_evidence as ev
R = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs"
for tag, arm in (("p4runtime_skeleton", ("p4runtime","skeleton")), ("p4runtime_solution", ("p4runtime","solution")), ("flowcache_solution", ("flowcache","solution"))):
    vals = collections.defaultdict(list); n = 0; bad = []
    for md in sorted(glob.glob(f"{R}/*_{tag}_ndtwin.md")):
        try:
            c = ev.controller_evidence(ev.controller_log(md)); r = ev.report_evidence(md)
        except Exception as e:
            bad.append(f"{os.path.basename(md)[:17]}: {type(e).__name__}"); continue
        n += 1
        verdict = re.search(r"^>>> (.*)$", open(md).read(), re.M)
        vals["verdict"].append(verdict.group(1)[:40] if verdict else "?")
        for k in ("rules_installed", "counters_final", "packet_ins", "cache_entries", "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors"):
            v = c[k]
            vals[k].append(str(sorted(v.items())) if isinstance(v, dict) else (str(len(v)) + ":" + str(hash(tuple(v)) % 10**6) if isinstance(v, list) else str(v)))
        inv = ev.invariants(arm, dict(c, **r))
        vals["invariants"].append("|".join("ok" if ok else "BAD" for ok, _ in inv.values()))
    print(f"== {tag}: {n} rounds readable, {len(bad)} not ({'; '.join(bad)})")
    for k, v in vals.items():
        cnt = collections.Counter(v)
        print(f"   {k:22} {len(cnt)} distinct: " + "; ".join(f"{x[:70]} x{m}" for x, m in cnt.most_common(4)))
