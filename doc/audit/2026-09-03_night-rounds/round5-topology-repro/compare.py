#!/usr/bin/env python3
"""Two-column diff of every number in two passes, with the within-fabric pass as the control.

pass1a vs pass1b : SAME fabric, back to back  -> bounds the sampling artefact
pass1a vs pass2  : DIFFERENT fabric, same script -> anything outside that bound is not sampling
[Co-developed with claude code -- Adam]
"""
import json, sys
J = lambda n: json.load(open("doc/audit/2026-09-03_night-rounds/round5-topology-repro/raw/%s.json" % n))
a, b, c = J("pass1a"), J("pass1b"), J("pass2")

def flat(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items(): out.update(flat(v, prefix + "/" + str(k)))
    elif isinstance(d, list):
        if all(not isinstance(x, (dict, list)) for x in d):
            out[prefix] = tuple(d)
        else:
            for i, v in enumerate(d): out.update(flat(v, prefix + "[%d]" % i))
    else:
        out[prefix] = d
    return out

FA, FB, FC = flat(a), flat(b), flat(c)
keys = sorted(set(FA) | set(FB) | set(FC))

# keys whose difference is structurally uninteresting
def skip(k):
    for s in ("/t", "_ms", "first_sampled_time", "latest_sampled_time", "/offset_s",
              "C_host_pids", "C_iperf_pids_before", "_error"):
        if k.endswith(s) or s in k: return True
    return False

print("%-64s | %-22s | %-22s | %-22s | verdict" % ("key", "pass1a (fabric A)", "pass1b (fabric A, control)", "pass2 (fabric B)"))
print("-"*64 + "-+-" + "-"*22 + "-+-" + "-"*22 + "-+-" + "-"*22 + "-+--------")
same_all = diff_within = diff_between_only = 0
rows = []
for k in keys:
    va, vb, vc = FA.get(k, "<absent>"), FB.get(k, "<absent>"), FC.get(k, "<absent>")
    if va == vb == vc:
        same_all += 1
        if not skip(k): rows.append((k, va, vb, vc, "IDENTICAL in all three"))
        continue
    if skip(k): continue
    if va != vb:
        diff_within += 1
        rows.append((k, va, vb, vc, "varies WITHIN one fabric -> sampling/run-to-run"))
    else:
        diff_between_only += 1
        rows.append((k, va, vb, vc, "STABLE within fabric A, MOVED on fabric B"))
for k, va, vb, vc, verdict in rows:
    f = lambda v: (("%s" % (v,))[:22])
    print("%-64s | %-22s | %-22s | %-22s | %s" % (k[:64], f(va), f(vb), f(vc), verdict))
print()
print("counted: identical in all three = %d ; differs within fabric A = %d ; stable in A but moved on B = %d"
      % (same_all, diff_within, diff_between_only))
