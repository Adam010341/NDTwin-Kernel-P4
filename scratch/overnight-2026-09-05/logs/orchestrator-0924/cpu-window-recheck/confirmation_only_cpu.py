#!/usr/bin/env python3
"""The re-confirmation block's own CPU, beside the climb's, per arm and per re-confirmed rung.

[Co-developed with claude code -- Adam]

Judge item 7 of the recheck, round 2. DESCRIPTIVE ONLY: no verdict is made from any of it, and
it is not pooled -- each block is measured over its own span with analyse.py's cpu_for_window
(the function every CPU number of the round goes through), and the spans are analyse.py's own
rung_windows(). The loss of each rep is read from rungs.tsv; "confirmation passed" is the
driver's own rule (median of the three <= clean_pct, run_group_arm.sh:432-434), recomputed here
from the three losses for the reader's convenience.

Usage: confirmation_only_cpu.py <analyse.py directory> <run dir>
"""
import os
import statistics
import sys

sys.path.insert(0, sys.argv[1])
import analyse  # noqa: E402

arms, _windows, _controls = analyse.walk_raw(sys.argv[2])
print("%-22s %5s | %-24s %8s %8s %8s | %-24s %8s %8s %8s | %s"
      % ("arm", "kpps", "climb losses (%)", "kernel", "bmv2", "prx+emt",
         "confirmation losses (%)", "kernel", "bmv2", "prx+emt", "confirmation"))
for arm in arms:
    if arm.get("control"):
        continue
    header, rows = analyse.load_cpu(os.path.join(arm["dir"], "cpu.jsonl"))
    clk = header.get("clk_tck") or 100
    losses = {}
    for r in arm["rungs"]:
        part = "confirmation" if analyse.is_confirmation_rep(r.get("rep")) else "climb"
        losses.setdefault((float(r["kpps"]), part), []).append(float(r["loss"]))
    for kpps, spans in sorted(analyse.rung_windows(arm).items()):
        if not spans["confirmation"]:
            continue
        climb = analyse.cpu_for_window(rows, clk, *spans["climb"])
        conf = analyse.cpu_for_window(rows, clk, *spans["confirmation"])
        cl, co = losses[(kpps, "climb")], losses[(kpps, "confirmation")]
        print("%-22s %5g | %-24s %8.3f %8.2f %8.3f | %-24s %8.3f %8.2f %8.3f | %s (median %.4f)"
              % (arm["arm"], kpps, " ".join("%.4f" % x for x in cl), climb["kernel"],
                 climb["bmv2"], climb["_proxy_plus_emitter"], " ".join("%.4f" % x for x in co),
                 conf["kernel"], conf["bmv2"], conf["_proxy_plus_emitter"],
                 "passed" if statistics.median(co) <= 0.5 else "FAILED", statistics.median(co)))
