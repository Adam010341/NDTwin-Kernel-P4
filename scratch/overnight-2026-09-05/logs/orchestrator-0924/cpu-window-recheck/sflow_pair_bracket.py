#!/usr/bin/env python3
"""Does the per-rung get_sflow_stats pair bracket the climb only? Read-only over the raw.

[Co-developed with claude code -- Adam]

addressed_total is a monotone counter, so the snapshots can be ordered by it. If the pair of the
re-confirmed rung k had been read around the confirmation, rung<k>_after would sit ABOVE every
later climb snapshot. Instead it equals the next rung's `before` exactly, and the samples taken
during the re-confirmation appear only in the arm-level sflow_after.json.
"""
import json, os, sys
R = sys.argv[1]
def addr(p):
    d = json.load(open(p)); return (d.get("telemetry_health") or {}).get("addressed_total", d.get("addressed_total"))
for arm in ("G2/cooperative_f1024_a", "G3/link_f1024_a", "G4/link_f1024_b", "G5/cooperative_f1024_b", "G4/link_f64_b"):
    a = os.path.join(R, arm)
    seq = []
    for k in [1, 2, 3, 5, 8, 12, 20, 30, 45, 70, 110]:
        for side in ("before", "after"):
            p = os.path.join(a, "sflow_rung%d_%s.json" % (k, side))
            if os.path.exists(p):
                seq.append(("%d_%s" % (k, side), addr(p)))
    seq.append(("arm_after", addr(os.path.join(a, "sflow_after.json"))))
    d = dict(seq)
    mono = all(x[1] <= y[1] for x, y in zip(seq, seq[1:]))
    kc = int(open(os.path.join(a, "arm.meta")).read().split("highest_clean_kpps=")[1].split()[0])
    nxt = [v for n, v in seq if n.endswith("_before") and int(n.split("_")[0]) > kc]
    print("%-24s clean=%d  monotone in climb order: %s  rung%d_after=%d  next rung's before=%s  equal: %s  "
          "110_after=%d  arm sflow_after=%d  samples after the last climb pair: %d"
          % (arm, kc, mono, kc, d["%d_after" % kc], nxt[0] if nxt else None,
             bool(nxt) and d["%d_after" % kc] == nxt[0], d["110_after"], d["arm_after"],
             d["arm_after"] - d["110_after"]))
