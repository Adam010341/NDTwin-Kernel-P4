#!/usr/bin/env bash
# evidence_coverage.sh <worktree> <base-tool run of the suite> <keep dir> -- which checks of
# test_live_p1_external_evidence.sh does ANY E mutant of mutate_live_p1_external_evidence.sh turn red?
# Runs an instrumented copy of the gate (its mutate() also keeps each mutant's full suite output) and
# answers, check by check (by position: names repeat), for every check that is GREEN over the base
# tool: red under which mutants, or under none. [Co-developed with claude code -- Adam]
set -u
WT="$1"; BASEOUT="$2"; K="$3"; mkdir -p "$K"
G="$WT/tests/shell/mutate_live_p1_external_evidence.sh"
C="$K/instrumented_gate.sh"
python3 - "$G" "$C" "$WT" "$K" <<'PY'
import sys
g, c, wt, k = sys.argv[1:5]
s = open(g).read()
a = 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
assert s.count(a) == 1; s = s.replace(a, f'HERE="{wt}/tests/shell"')
b = '    out="$(run_test "$d/external_evidence.py")"\n'
assert s.count(b) == 1
s = s.replace(b, b + f'    printf \'%s\\n\' "$out" > "{k}/out.$(printf \'%s\' "$label" | cut -d: -f1)"\n')
open(c, "w").write(s)
PY
( cd "$WT" && bash "$C" ) > "$K/gate.out" 2>&1; echo "instrumented gate rc=$? ($(tail -1 "$K/gate.out"))"
python3 - "$BASEOUT" "$K" <<'PY'
import glob, os, re, sys
base, k = sys.argv[1:3]
rx = re.compile(r"^  (ok|FAILED) +(.*)$")
def checks(p):
    return [(m.group(1), m.group(2).rstrip()) for m in map(rx.match, open(p, errors="replace").read().splitlines()) if m]
b = checks(base)
muts = {os.path.basename(p)[4:]: checks(p) for p in sorted(glob.glob(f"{k}/out.E*"))}
print(f"{len(muts)} mutant outputs; the base-tool run has {len(b)} checks, {sum(1 for s,_ in b if s=='ok')} green")
bad = 0
for i, (st, name) in enumerate(b):
    if st != "ok":
        continue
    reds = [m for m, cs in muts.items() if len(cs) == len(b) and cs[i][1] == name and cs[i][0] == "FAILED"]
    odd = [m for m, cs in muts.items() if len(cs) != len(b) or cs[i][1] != name]
    if not reds: bad += 1
    print(f"  {'red under ' + ','.join(reds) if reds else 'NEVER RED':<40} #{i+1:<3} {name}" + (f"   (shape differs in {odd})" if odd else ""))
print(f"EVIDENCE-COVERAGE: {bad} green-over-base check(s) no E mutant turns red")
PY
