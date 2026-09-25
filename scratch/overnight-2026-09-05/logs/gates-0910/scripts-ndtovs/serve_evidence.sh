#!/usr/bin/env bash
# serve_evidence.sh -- read-only evidence for the ndt serve hand-off, at the worktree's HEAD.
# [Co-developed with claude code -- Adam]
#  1. git merge-tree HEAD feat/ndt-serve-0924: conflicted paths (none = clean)
#  2. every RC_SOURCE "code" anchor of feat/ndt-serve-0924's verbs.py, old line (base 62f76cf5)
#     -> new line at HEAD, mapped by difflib over equal blocks, and whether each line holds its needle
#  3. every RC_SOURCE "help" phrase and the manual rc table's quoted phrases, whitespace-normalised,
#     in HEAD's `ndt help`
# Exit: 0 when the merge is clean, every anchor maps and holds, and no phrase is missing; 1 otherwise.
# (`ndt help` itself always exits 2 -- it is the usage text -- so its rc is not read; its text is.)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

echo "== 1. merge-tree HEAD feat/ndt-serve-0924"
out="$(git merge-tree --write-tree --name-only HEAD feat/ndt-serve-0924)"; mrc=$?
printf '%s\n' "$out"
conf="$(printf '%s\n' "$out" | sed -n '2,$p' | grep -c .)"
echo "merge-tree rc=$mrc, conflicted paths after the tree id: $conf"

echo "== 2. RC_SOURCE code anchors"
anchors_out="$(python3 - <<'PYCODE'
import ast, difflib, subprocess, re
g = lambda *a: subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout
base = g("show", "62f76cf5:tools/test_workflow/ndt").split("\n")
head = g("show", "HEAD:tools/test_workflow/ndt").split("\n")
verbs = g("show", "feat/ndt-serve-0924:tools/ndt_serve/verbs.py")
m = re.search(r"^RC_SOURCE = (\{.*?^\})", verbs, re.S | re.M)
src = ast.literal_eval(m.group(1))
sm = difflib.SequenceMatcher(None, base, head, autojunk=False)
mp = {}
for tag, i1, i2, j1, j2 in sm.get_opcodes():
    if tag == "equal":
        for k in range(i2 - i1):
            mp[i1 + k + 1] = j1 + k + 1
bad = 0
for kind, s in src.items():
    for line, rc, needle in s.get("code", []):
        n = mp.get(line)
        ob = needle in base[line - 1]
        nb = n is not None and needle in head[n - 1]
        still = needle in head[line - 1] if line <= len(head) else False
        bad += (not ob) + (not nb)
        print(f"{kind:13} rc {rc}  old {line:5} {'ok' if ob else 'NO'} -> new {n} {'ok' if nb else 'NO'}"
              f"  (old line at HEAD holds it: {'yes' if still else 'no'})  [{needle}]")
print("anchors not mapped/holding:", bad)
PYCODE
)"
printf '%s\n' "$anchors_out"

echo "== 3. help phrases"
help_text="$(bash tools/test_workflow/ndt help 2>&1)"
phr_out="$(printf '%s' "$help_text" | python3 -c '
import sys, re, ast, subprocess
t = re.sub(r"\s+", " ", sys.stdin.read())
verbs = subprocess.run(["git", "show", "feat/ndt-serve-0924:tools/ndt_serve/verbs.py"],
                       capture_output=True, text=True).stdout
src = ast.literal_eval(re.search(r"^RC_SOURCE = (\{.*?^\})", verbs, re.S | re.M).group(1))
phr = [" ".join(p.split()) for s in src.values() for p in s.get("help", {}).values()]
man = open("doc/2026-08-17_testing-manual.md", encoding="utf-8").read()
tab = man[man.index("NDT-RC-TABLE:BEGIN"):man.index("NDT-RC-TABLE:END")]
phr += re.findall(r"\| `([^`]+)` \|", tab)
miss = [p for p in phr if p not in t]
for p in phr:
    print(("ok     " if p in t else "MISSING"), p)
print("help phrases missing:", len(miss))')"
printf '%s\n' "$phr_out"

an="$(sed -n 's/^anchors not mapped\/holding: //p' <<<"$anchors_out")"
ph="$(sed -n 's/^help phrases missing: //p' <<<"$phr_out")"
echo "== verdict: merge-tree rc=$mrc conflicted-paths=$conf anchors-bad=${an:-?} phrases-missing=${ph:-?}"
[[ "$mrc" == 0 && "$conf" == 0 && "$an" == 0 && "$ph" == 0 ]]
