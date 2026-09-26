#!/usr/bin/env python3
"""Which embedded programs does a self-test EXECUTE? Answered by marking them, not by LINENO.

[Co-developed with claude code -- Adam] bash's xtrace LINENO is wrong inside $( ) within functions
(off by twenty lines in 08's self-test), so a line-based answer would lie. Instead every literal
embedded program found by embedded_sweep.find_programs gets, as its first statement, a marker that
creates $COV_DIR/<id> when the program RUNS (and does nothing, never raises, when COV_DIR is unset):
  python  import os as _cv; _cv.path.isdir(...) and _cv.close(_cv.open(... + "/<id>", 0o101))
  awk     BEGIN { if (ENVIRON["COV_DIR"] != "") { printf "" > (ENVIRON["COV_DIR"] "/<id>") ... } }
  jqp     (marker-expression or 1) and (<expr>)
Modes:
  mark  FILE...        rewrite the files IN PLACE (the caller restores them from git) and print
                       the id map as JSON on stdout;
  report MAP COV_DIR   one row per program: RAN / NOT, from the markers found.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import embedded_sweep as es  # noqa: E402

PY_MARK = ('import os as _cv; _cv.path.isdir(_cv.environ.get("COV_DIR", "")) and '
           '_cv.close(_cv.open(_cv.environ["COV_DIR"] + "/{id}", 0o101))')
AWK_MARK = ('BEGIN {{ if (ENVIRON["COV_DIR"] != "") {{ printf "" > (ENVIRON["COV_DIR"] "/{id}"); '
            'close(ENVIRON["COV_DIR"] "/{id}") }} }} ')
PY_MARK_SQ = ("import os as _cv; _cv.path.isdir(_cv.environ.get('COV_DIR', '')) and "
              "_cv.close(_cv.open(_cv.environ['COV_DIR'] + '/{id}', 0o101))")
AWK_MARK_DQ = ('BEGIN {{ if (ENVIRON[\\"COV_DIR\\"] != \\"\\") {{ printf \\"\\" > (ENVIRON[\\"COV_DIR\\"] \\"/{id}\\"); '
               'close(ENVIRON[\\"COV_DIR\\"] \\"/{id}\\") }} }} ')
JQP_MARK = ("(__import__('os').path.isdir(__import__('os').environ.get('COV_DIR', '')) and "
            "__import__('os').close(__import__('os').open(__import__('os').environ['COV_DIR'] + '/{id}', 0o101)) or 1) and ")


def mark(files):
    idmap = {}
    for f in files:
        lines = open(f).read().split("\n")
        progs = es.find_programs(f)
        # edit bottom-up so earlier line numbers stay valid
        for k, p in sorted(enumerate(progs), key=lambda kp: -kp[1]["start"]):
            pid = f"{os.path.basename(f)}-{p['start']}"
            if p["kind"] == "py-c-var":
                continue
            li = p["start"] - 1
            if p["kind"] in ("py-heredoc", "py-var"):
                # the program's first line is the one after the opener (heredoc, NAME=' or NAME="$(cat <<'X')
                body0 = li + 1
                if lines[body0].lstrip().startswith("from __future__"):
                    body0 += 1
                lines.insert(body0, PY_MARK.format(id=pid))
            elif p["kind"] == "py-c":
                line = lines[li]
                m = es.PY_C_SQ.search(line)
                lines[li] = line[:m.end()] + PY_MARK.format(id=pid) + "\n" + line[m.end():]
            elif p["kind"] == "py-c-dq":
                line = lines[li]
                m = es.PY_C_DQ.search(line)
                lines[li] = line[:m.end()] + PY_MARK_SQ.format(id=pid) + "\n" + line[m.end():]
            elif p["kind"] == "awk-dq":
                if not p["text"] or "{" not in p["text"]:
                    continue   # not an awk program the pattern could read (e.g. a -v "$(cat ...)" argument)
                line = lines[li]
                ms = list(es.AWK_DQ.finditer(line))
                if len(ms) != 1:
                    continue
                m = ms[0]
                lines[li] = line[:m.end()] + AWK_MARK_DQ.format(id=pid) + line[m.end():]
            elif p["kind"] == "awk":
                line = lines[li]
                # the n-th awk on this line that starts here
                ms = list(es.AWK.finditer(line))
                m = [x for x in ms][0] if len(ms) == 1 else None
                if m is None:
                    continue
                lines[li] = line[:m.end()] + AWK_MARK.format(id=pid) + line[m.end():]
            elif p["kind"] == "py-jqp":
                line = lines[li]
                ms = list(es.JQP.finditer(line))
                if len(ms) != 1:
                    continue
                m = ms[0]
                lines[li] = line[:m.start(1)] + JQP_MARK.format(id=pid) + "(" + line[m.start(1):m.end(1)] + ")" + line[m.end(1):]
            else:
                continue
            idmap[pid] = {"file": f, "start": p["start"], "kind": p["kind"],
                          "first": (p["text"] or "").strip().splitlines()[0][:70] if p["text"] else p["name"]}
        open(f, "w").write("\n".join(lines))
    json.dump(idmap, sys.stdout, indent=1)


def report(mapfile, cov):
    idmap = json.load(open(mapfile))
    seen = set(os.listdir(cov)) if os.path.isdir(cov) else set()
    by_file = {}
    for pid, p in sorted(idmap.items(), key=lambda kv: (kv[1]["file"], kv[1]["start"])):
        ran = pid in seen
        by_file.setdefault(p["file"], []).append(ran)
        print(f"  {os.path.basename(p['file']):22s} {p['start']:5d} {p['kind']:10s} {'RAN' if ran else 'NOT'}  | {p['first']}")
    print("SUMMARY")
    for f, rs in by_file.items():
        print(f"  {os.path.basename(f)}: {len(rs)} marked, {sum(rs)} executed, {len(rs) - sum(rs)} NOT executed")


if __name__ == "__main__":
    if sys.argv[1] == "mark":
        mark(sys.argv[2:])
    else:
        report(sys.argv[2], sys.argv[3])
