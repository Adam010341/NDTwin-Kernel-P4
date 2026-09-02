#!/usr/bin/env python3
"""Collapse one probe CSV into the three visibility fractions. [Co-developed with claude code -- Adam]"""
import csv, sys, os
print("%-22s %5s %8s %8s %8s %8s %8s %s" % ("cell","n","winA>0","winB(3s)","winC(15s)","decoyB","decoyC","liveness seen"))
for f in sys.argv[1:]:
    if not os.path.exists(f): continue
    rows = list(csv.DictReader(open(f)))
    n = len(rows)
    if n == 0:
        print("%-22s %5d  (empty)" % (os.path.basename(f), 0)); continue
    ka = [k for k in rows[0] if k.startswith("winA")][0]
    a = sum(1 for r in rows if int(r[ka]) > 0)
    b = sum(1 for r in rows if r["winB_default_present"] == "1")
    c = sum(1 for r in rows if r["winC_all_present"] == "1")
    db = sum(1 for r in rows if r["decoy_in_B"] == "1")
    dc = sum(1 for r in rows if r["decoy_in_C"] == "1")
    lv = ",".join(sorted(set(r["winC_liveness"] for r in rows if r["winC_liveness"])))
    print("%-22s %5d %8s %8s %8s %8d %8d %s" %
          (rows[0]["tag"], n, "%d/%d"%(a,n), "%d/%d"%(b,n), "%d/%d"%(c,n), db, dc, lv or "-"))
