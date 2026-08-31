#!/usr/bin/env python3
import json, os, re, sys

S = "/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/258e9ef7-6035-4abb-b378-8b2ab1aa8200/scratchpad/mutrun"
sys.path.insert(0, S)
from mutations import MUT, ORDER, CONTROL  # noqa

L = os.path.join(S, "logs")
rows = []
for mid in ORDER:
    vp = os.path.join(L, "%s.verdict.json" % mid)
    if not os.path.exists(vp):
        rows.append({"id": mid, "state": "NOT-RUN"})
        continue
    with open(vp) as fh:
        v = json.load(fh)
    # independent re-reads
    v["grep_witness"] = 0
    gp = os.path.join(L, "%s.grep.log" % mid)
    if os.path.exists(gp):
        v["grep_witness"] = sum(1 for _ in open(gp))
    bp = os.path.join(L, "%s.baseline.log" % mid)
    v["restored_46"] = False
    if os.path.exists(bp):
        t = open(bp, errors="replace").read()
        v["restored_46"] = ("46 tests from 3 test suites ran." in t
                            and "[  PASSED  ] 46 tests." in t)
    v["desc"] = MUT[mid][0]
    rows.append(v)

print("| # | mutation | on disk | build rc | test rc | state | red (actual) | predicted | match | control | restored 46/46 |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    if r.get("state") == "NOT-RUN":
        print("| %s | | | | | **NOT-RUN** | | | | | |" % r["id"])
        continue
    red = "<br>".join(t.split(".", 1)[1] for t in r["failed"]) or "(none)"
    pred = "<br>".join(t.split(".", 1)[1] for t in r["predicted"])
    print("| %s | %s | grep %d | %d | %d | **%s** | %s | %s | %s | %s | %s |" % (
        r["id"], r["desc"], r["grep_witness"], r["build_rc"], r["test_rc"], r["state"],
        red, pred,
        "yes" if r.get("match") else "**NO**",
        "RED" if r["control_red"] else "green",
        "yes" if r["restored_46"] else "**NO**"))

print()
print("counts:")
from collections import Counter
c = Counter(r.get("state", "NOT-RUN") for r in rows)
for k, v in sorted(c.items()):
    print("  %-12s %d" % (k, v))
print("  killed-and-matched-prediction: %d" % sum(1 for r in rows if r.get("match")))
print("  extra reds:", {r["id"]: r["red_but_unpredicted"] for r in rows
                        if r.get("red_but_unpredicted")})
print("  predicted-but-stayed-green:", {r["id"]: r["predicted_but_green"] for r in rows
                                        if r.get("predicted_but_green")})
