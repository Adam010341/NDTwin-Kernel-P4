#!/usr/bin/env python3
"""Which embedded programs does a self-test EXECUTE? Marked on the programs embedded_sweep2 finds.

[Co-developed with claude code -- Adam] The second version of embedded_cover.py: the programs come
from embedded_sweep2.find_programs (logical lines, backslash continuations joined -- the opus
judge's N2-2), and each marker goes where that finder says the program's text starts (`ins` for an
inline text, `body` for a heredoc or variable), so a program whose opener spans a continuation is
marked too. The marker creates $COV_DIR/<id> when the program RUNS and does nothing when COV_DIR is
unset. `mark FILE...` rewrites the files in place (the caller restores them from git) and prints the
id map; `report MAP COV_DIR` prints RAN / NOT per program.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import embedded_sweep2 as es  # noqa: E402

PY_MARK = ('import os as _cv; _cv.path.isdir(_cv.environ.get("COV_DIR", "")) and '
           '_cv.close(_cv.open(_cv.environ["COV_DIR"] + "/{id}", 0o101))')
PY_MARK_SQ = ("import os as _cv; _cv.path.isdir(_cv.environ.get('COV_DIR', '')) and "
              "_cv.close(_cv.open(_cv.environ['COV_DIR'] + '/{id}', 0o101))")
AWK_MARK = ('BEGIN {{ if (ENVIRON["COV_DIR"] != "") {{ printf "" > (ENVIRON["COV_DIR"] "/{id}"); '
            'close(ENVIRON["COV_DIR"] "/{id}") }} }} ')
AWK_MARK_DQ = ('BEGIN {{ if (ENVIRON[\\"COV_DIR\\"] != \\"\\") {{ printf \\"\\" > (ENVIRON[\\"COV_DIR\\"] \\"/{id}\\"); '
               'close(ENVIRON[\\"COV_DIR\\"] \\"/{id}\\") }} }} ')
SH_MARK = 'if [[ -d "${{COV_DIR:-}}" ]]; then : > "$COV_DIR/{id}"; fi'
JQP_MARK = ("(__import__('os').path.isdir(__import__('os').environ.get('COV_DIR', '')) and "
            "__import__('os').close(__import__('os').open(__import__('os').environ['COV_DIR'] + '/{id}', 0o101)) or 1) and ")


UNMARKED = []


def mark(files):
    idmap = {}
    for f in files:
        lines = open(f).read().split("\n")
        progs = es.find_programs(f)
        edits = []   # (line index, column or -1 for "insert a line before", text)
        for p in progs:
            pid = f"{os.path.basename(f)}-{p['start']}-{p['kind']}"
            n_same = sum(1 for q in idmap if q == pid or q.startswith(pid + "#"))
            if n_same:
                pid = f"{pid}#{n_same + 1}"
            k = p["kind"]
            if k == "sh-heredoc":
                edits.append((p["body"], -1, SH_MARK.format(id=pid)))
            elif k in ("py-heredoc", "py-var", "py-file"):
                # (an unquoted heredoc is marked the same way: the marker has no $ and no `)
                body = p["body"]
                if body < len(lines) and lines[body].lstrip().startswith("from __future__"):
                    body += 1
                edits.append((body, -1, PY_MARK.format(id=pid)))
            elif k == "py-c":
                li, col = p["ins"]
                edits.append((li, col, PY_MARK.format(id=pid) + "\n"))
            elif k == "py-c-dq":
                li, col = p["ins"]
                edits.append((li, col, PY_MARK_SQ.format(id=pid) + "\n"))
            elif k == "awk":
                li, col = p["ins"]
                edits.append((li, col, AWK_MARK.format(id=pid)))
            elif k == "awk-dq":
                if not p["text"] or "{" not in p["text"]:
                    UNMARKED.append(f"{os.path.basename(f)}:{p['start']} awk-dq (not an awk program text)")
                    continue
                li, col = p["ins"]
                edits.append((li, col, AWK_MARK_DQ.format(id=pid)))
            elif k == "py-jqp":
                li, col = p["ins"]
                n = p["span"]
                old = lines[li][col:col + n]
                edits.append((li, col, ("REPLACE", n, JQP_MARK.format(id=pid) + "(" + old + ")")))
            else:
                UNMARKED.append(f"{os.path.basename(f)}:{p['start']} {k} ({p['name'] or 'no literal text'})")
                continue
            idmap[pid] = {"file": f, "start": p["start"], "kind": k,
                          "first": (p["text"] or "").strip().splitlines()[0][:70] if p["text"] else p["name"]}
        # bottom-up, right to left: every edit's coordinates are still valid when it is applied
        for li, col, text in sorted(edits, key=lambda e: (e[0], e[1]), reverse=True):
            if col == -1:
                lines.insert(li, text)
            elif isinstance(text, tuple):
                _tag, n, new = text
                lines[li] = lines[li][:col] + new + lines[li][col + n:]
            else:
                lines[li] = lines[li][:col] + text + lines[li][col:]
        open(f, "w").write("\n".join(lines))
    json.dump({"programs": idmap, "unmarked": UNMARKED}, sys.stdout, indent=1)


def report(mapfile, cov):
    doc = json.load(open(mapfile))
    idmap = doc["programs"]
    # one sub-directory per run: which run executed each program is part of the answer
    by_run = {r: set(os.listdir(os.path.join(cov, r))) for r in sorted(os.listdir(cov))
              if os.path.isdir(os.path.join(cov, r))} if os.path.isdir(cov) else {}
    seen = set().union(*by_run.values()) if by_run else set()
    by_file = {}
    for pid, p in sorted(idmap.items(), key=lambda kv: (kv[1]["file"], kv[1]["start"])):
        ran = pid in seen
        who = ",".join(r for r, ids in by_run.items() if pid in ids)
        by_file.setdefault(os.path.basename(p["file"]), []).append(ran)
        print(f"  {os.path.basename(p['file']):22s} {p['start']:5d} {p['kind']:10s} {'RAN' if ran else 'NOT'}  "
              f"{who:40.40s} | {p['first'][:60]}")
    print("SUMMARY")
    for f, rs in by_file.items():
        print(f"  {f}: {len(rs)} marked, {sum(rs)} executed, {len(rs) - sum(rs)} NOT executed")
    print(f"UNMARKED ({len(doc['unmarked'])}, no literal text to mark): " + "; ".join(doc["unmarked"]))
    n = len(idmap)
    r = sum(1 for pid in idmap if pid in seen)
    print(f"EMBEDDED-COVER: {n} marked, {r} executed by a self-test, {n - r} not")


if __name__ == "__main__":
    if sys.argv[1] == "mark":
        mark(sys.argv[2:])
    else:
        report(sys.argv[2], sys.argv[3])
