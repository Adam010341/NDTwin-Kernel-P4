"""Row-by-row comparison of two live-p1 06_thirteen runs (the table, then each arm's report).

[Co-developed with claude code -- Adam]

usage: compare_06.py <baseline run dir> <trial run dir>

For every arm: the table row (rc, verdict), then the report's section 5 verdict table row by row
(result, expectation, want, got), then section 3b (switch_state disclosure) with numbers kept.
Prints SAME / DIFF per item and a closing count. Reads only.
"""
import csv
import os
import re
import sys


def table(run):
    with open(os.path.join(run, "00_table.tsv")) as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    return {(r["exercise"], r["which"]): r for r in rows}, [(r["exercise"], r["which"]) for r in rows]


def section(md, start_pat, stop_pat):
    out, on = [], False
    for line in md.splitlines():
        if re.match(start_pat, line):
            on = True
            continue
        if on and re.match(stop_pat, line):
            break
        if on:
            out.append(line)
    return out


def verdict_rows(md):
    rows = []
    for line in section(md, r"^## 5\. ", r"^## "):
        if line.startswith("| ") and not line.startswith("| 結果") and not line.startswith("|---"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            rows.append(cells)
    return rows


def disclosure(md):
    lines = section(md, r"^### 3b\. ", r"^## ")
    return [l for l in lines if l.strip() and not l.startswith("```")]


def read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError as e:
        return "<unreadable: %s>" % e


base, trial = sys.argv[1], sys.argv[2]
bt, order = table(base)
tt, torder = table(trial)
same = diff = 0
print("baseline:", base)
print("trial   :", trial)
if order != torder:
    print("!! arm ORDER differs:", order, torder)
for key in order:
    b, t = bt.get(key), tt.get(key)
    print("\n=== %s / %s" % key)
    if t is None:
        print("   DIFF  arm missing from the trial table")
        diff += 1
        continue
    for col in ("rc", "verdict"):
        tag = "SAME" if b[col] == t[col] else "DIFF"
        same += tag == "SAME"
        diff += tag == "DIFF"
        print("   %s  %-8s base=%r trial=%r" % (tag, col, b[col], t[col]))
    bm, tm = read(b["report"]), read(t["report"])
    bv, tv = verdict_rows(bm), verdict_rows(tm)
    if len(bv) != len(tv):
        print("   DIFF  verdict-table rows: base=%d trial=%d" % (len(bv), len(tv)))
        diff += 1
    for i in range(max(len(bv), len(tv))):
        r1 = bv[i] if i < len(bv) else None
        r2 = tv[i] if i < len(tv) else None
        if r1 is None or r2 is None:
            print("   DIFF  row %d only on one side: base=%r trial=%r" % (i, r1, r2))
            diff += 1
            continue
        # result, expectation, source, want, got, basis
        key_same = r1[:4] == r2[:4]
        got_same = r1[4:5] == r2[4:5]
        tag = "SAME" if key_same and got_same else ("DIFF-got" if key_same else "DIFF")
        same += tag == "SAME"
        diff += tag != "SAME"
        print("   %-8s [%s] %s | want %s | got base=%s trial=%s" % (
            tag, r2[0], r2[1][:70], r2[3][:40], r1[4][:60], r2[4][:60]))
    bd, td = disclosure(bm), disclosure(tm)
    tag = "SAME" if bd == td else "DIFF"
    same += tag == "SAME"
    diff += tag == "DIFF"
    print("   %-8s section 3b switch_state disclosure (%d lines)" % (tag, len(td)))
    if tag == "DIFF":
        for l1, l2 in zip(bd, td):
            if l1 != l2:
                print("      base : %s\n      trial: %s" % (l1, l2))
        if len(bd) != len(td):
            print("      line count base=%d trial=%d" % (len(bd), len(td)))
print("\n# items SAME=%d DIFF=%d" % (same, diff))
