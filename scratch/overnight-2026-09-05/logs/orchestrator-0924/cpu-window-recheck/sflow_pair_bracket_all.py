#!/usr/bin/env python3
"""Does the per-rung get_sflow_stats pair bracket the climb only? EVERY ladder arm, every campaign.

[Co-developed with claude code -- Adam]

Round 2 of the recheck (judge item 6): round 1 checked five arms of the fifth campaign; all
twelve of its ladder arms carry c-rows. Read-only over the raw.

addressed_total is a monotone counter. For every rung k that has c-rows (a re-confirmed rung,
walk-down included), if the pair sflow_rung<k>_{before,after} had been read around the
re-confirmation, rung<k>_after would sit ABOVE the next climbed rung's `before`. The check is
that rung<k>_after == next climbed rung's before (no sample between them), and that the whole
climb sequence is monotone. A re-confirmed rung with no rung climbed after it (C3's six-rung
ladder stops at 12) has nothing to compare against and is reported as such.

Also printed (descriptive, NOT attributed): samples between the LAST climb pair's `after` and the
arm-level sflow_after.json -- the re-confirmation reps ran in that interval, and so did whatever
else happened before the arm's last read; nothing here separates the two.
"""
import json
import os
import sys

RAW = sys.argv[1]


def addr(path):
    doc = json.load(open(path))
    return (doc.get("telemetry_health") or {}).get("addressed_total", doc.get("addressed_total"))


def read_tsv(path):
    lines = [l.rstrip("\n") for l in open(path) if l.strip()]
    head = lines[0].split("\t")
    return [dict(zip(head, l.split("\t"))) for l in lines[1:]]


bad = checked = 0
for campaign in sorted(os.listdir(RAW)):
    base = os.path.join(RAW, campaign)
    if not os.path.isdir(base):
        continue
    for root, dirs, files in os.walk(base):
        dirs.sort()
        if "rungs.tsv" not in files or "controls" in os.path.relpath(root, base).split(os.sep):
            continue
        rows = read_tsv(os.path.join(root, "rungs.tsv"))
        climbed = []
        for r in rows:
            k = int(float(r["kpps"]))
            if not r["rep"].startswith("c") and k not in climbed:
                climbed.append(k)
        confirmed = sorted({int(float(r["kpps"])) for r in rows if r["rep"].startswith("c")})
        seq = []
        for k in climbed:
            seq.append((k, "before", addr(os.path.join(root, "sflow_rung%d_before.json" % k))))
            seq.append((k, "after", addr(os.path.join(root, "sflow_rung%d_after.json" % k))))
        mono = all(a[2] <= b[2] for a, b in zip(seq, seq[1:]))
        arm_after = addr(os.path.join(root, "sflow_after.json"))
        results = []
        for k in confirmed:
            i = climbed.index(k)
            after = seq[2 * i + 1][2]
            if i + 1 < len(climbed):
                nxt = seq[2 * (i + 1)][2]
                ok = after == nxt
                results.append("%d: after=%d next(%d).before=%d %s" % (k, after, climbed[i + 1], nxt,
                                                                     "EQUAL" if ok else "NOT EQUAL"))
                checked += 1
                bad += not ok
            else:
                results.append("%d: no rung climbed after it -- nothing to compare" % k)
        print("%-26s %-26s monotone=%s  %s  | after last climb pair -> arm sflow_after: %d samples"
              % (campaign, os.path.relpath(root, base), mono, "; ".join(results) or "no c-rows",
                 arm_after - seq[-1][2]))
        bad += not mono
print("\nre-confirmed rungs compared: %d   not equal (or non-monotone arms): %d" % (checked, bad))
