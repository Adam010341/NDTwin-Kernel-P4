#!/usr/bin/env bash
# redfirst_b6.sh <worktree> <keep dir> -- round 6 (the round-5 re-review on 4c18bf3d: M-1..M-3, S-8, S-9), red
# first: HEAD's new cells against round 5's code (B6_BASE, default 4c18bf3d). Every output KEPT.
# [Co-developed with claude code -- Adam]
#   A  test_live_p1_external_evidence over the base's external_evidence.py and code_identity.py, with no
#      external_survey.py (M-2 identity before/after, ~/tutorials, bmv2 libs, tree, the same p4c and JSON;
#      M-3 the controller's own window; S-9 the frozen survey). The base reads 00_identity.txt only, so
#      nearly every cell is red -- degenerate; the round's own cells are named below, and each cell's own
#      red is the evidence gate's coverage report.
#   B  test_live_p1_thirteen over the base's 06 (identity before and after the rounds)
#   C  08's self-test with the base's sampler spliced in (the ctrl_logs column)
#   D  test_l1_shell_scoring over the base's test_heartbeat_drop_check.py (S-8: the lab claim skip)
#   E  selfcheck_b6 over round 5's tripwire and wrappers (the cwd-under-TMPDIR condition), the wrappers'
#      real binaries replaced by /bin/true so a wrongly allowed launch starts nothing
set -u
WT="$1"; K="$2"; bad=0; BASE="${B6_BASE:-4c18bf3d}"; cd "$WT" || exit 2; mkdir -p "$K"
HERE_RF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE_RF/redfirst_lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/b6-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
echo "HEAD $(git rev-parse HEAD); base $(git rev-parse $BASE)"
same_set() {   # same_set <label> <got file> <want...>
    local label="$1" got="$2"; shift 2
    local want; want="$(printf '%s\n' "$@" | sort -u)"
    if [[ "$(sort -u "$got")" == "$want" ]]; then ok "$label: exactly the $# expected red"
    else nok "$label: red set differs"; diff <(printf '%s\n' "$want") <(sort -u "$got") | sed 's/^/      /'; fi
}
reds() { sed -n 's/^  FAILED   //p' "$1" | sed 's/[[:space:]]*$//'; }

echo "== A: test_live_p1_external_evidence over the base's tool and code_identity.py, no survey tool"
mkdir -p "$T/a"
git show "$BASE:$LIVE/external_evidence.py" > "$T/a/external_evidence.py"
git show "$BASE:$LIVE/code_identity.py" > "$T/a/code_identity.py"
cp "$LIVE/venv_fingerprint.sh" "$T/a/"
EVIDENCE_UNDER_TEST="$T/a/external_evidence.py" timeout 900 bash tests/shell/test_live_p1_external_evidence.sh > "$K/a_base_ev.out" 2>&1
n="$(reds "$K/a_base_ev.out" | wc -l)"; tot="$(sed -n 's/^Ran \([0-9]*\) checks.*/\1/p' "$K/a_base_ev.out")"
(( n > 0 )) && ok "  the base tool fails $n of ${tot:-?} cells (degenerate: it reads 00_identity.txt only)" \
            || nok "  the base tool passed HEAD's suite"
while IFS= read -r want; do
    [[ -n "$want" ]] || continue
    reds "$K/a_base_ev.out" | /usr/bin/grep -qxF -- "$want" && ok "  red: $want" || nok "  green on the base: $want"
done < "$HERE_RF/redfirst_b6.cells"
echo "    (green over the base, by accident: it refuses every compare for want of 00_identity.txt (rc 3), so the"
echo "     round's rc-3 cells -- heard only before the push or after the last write, a session first running after"
echo "     the push, no after-identity, code changed during a run, the tree, ~/tutorials, bmv2 libs, p4c, JSON --"
echo "     answer rc 3 there for the wrong reason. Each is seen red under its own mutant in the evidence gate:"
echo "     E62 E65 E81 E87 E72 E95 I20 I9 I11 I12 E91 E92 E93; and every cell's red is its coverage report)"
EVIDENCE_UNDER_TEST="$WT/$LIVE/external_evidence.py" timeout 900 bash tests/shell/test_live_p1_external_evidence.sh > "$K/a_head_ev.out" 2>&1 \
    && ok "  HEAD's tool: $(tail -1 "$K/a_head_ev.out")" || nok "  HEAD's tool is not green: $(tail -1 "$K/a_head_ev.out")"

echo "== B: test_live_p1_thirteen over the base's 06"
mkdir -p "$T/b"
git show "$BASE:$LIVE/06_thirteen.sh" > "$T/b/06_thirteen.sh"
cp "$LIVE/venv_fingerprint.sh" "$LIVE/code_identity.py" "$T/b/"
THIRTEEN_UNDER_TEST="$T/b/06_thirteen.sh" timeout 900 bash tests/shell/test_live_p1_thirteen.sh > "$K/b_base_06.out" 2>&1
reds "$K/b_base_06.out" > "$T/r"
same_set "base 06" "$T/r" "🔴 the raw records the code identity as 06 starts" \
    "🔴 and again as it ends, after the last round wrote its table row"

echo "== C: 08's self-test with the base's sampler"
src="$(sed -n '/^ltree() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
run08() {   # run08 <08 copy> <out>
    ( REPO="$WT"; LIVE_DIR_REL="$LIVE"; LIVE08="$WT/$LIVE/08_heartbeat.sh"; eval "$src"
      rm -rf "$T/lt"; ltree "$T/lt"; cp "$1" "$T/lt/$LIVE/08_heartbeat.sh"
      cd "$T/lt" && TMPDIR="$T/lt/tmp" PYTHONDONTWRITEBYTECODE=1 timeout 300 bash "$LIVE/08_heartbeat.sh" --self-test > "$2" 2>&1 )
}
git show "$BASE:$LIVE/08_heartbeat.sh" > "$T/08_base.sh"
python3 - "$LIVE/08_heartbeat.sh" "$T/08_base.sh" "$T/08_c.sh" <<'PY'
import sys
head, base, out = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
def between(s, a, b):
    i = s.index(a); j = s.index(b, i)
    return s[i:j]
h = between(head, "SAMPLER_HEADER=", "\nSAMPLER\n)\"")
b = between(base, "SAMPLER_HEADER=", "\nSAMPLER\n)\"")
assert h != b
open(out, "w").write(head.replace(h, b))
PY
run08 "$T/08_c.sh" "$K/c_08_base_sampler.out"
exactly_red "08 with the base's sampler" "$K/c_08_base_sampler.out" "H5 sampler rows" "🔴 H5 sampler ctrl_logs column"
run08 "$LIVE/08_heartbeat.sh" "$K/c_08_head.out"
green "HEAD's own 08" "$K/c_08_head.out"

echo "== D: test_l1_shell_scoring over the base's test_heartbeat_drop_check.py"
mkdir -p "$T/d/tools/test_workflow" "$T/d/tests/shell/fixtures"
cp tools/test_workflow/l1_unit_tests.sh tools/test_workflow/components.env tools/test_workflow/ndt "$T/d/tools/test_workflow/"
cp tests/shell/test_*.sh tests/shell/test_*.py "$T/d/tests/shell/"; cp -r tests/shell/fixtures/l1_shell_scoring "$T/d/tests/shell/fixtures/"
git show "$BASE:tests/shell/test_heartbeat_drop_check.py" > "$T/d/tests/shell/test_heartbeat_drop_check.py"
timeout 600 bash "$T/d/tests/shell/test_l1_shell_scoring.sh" > "$K/d_base_l1.out" 2>&1
reds "$K/d_base_l1.out" > "$T/r"
same_set "base drop-check suite, the lab claim" "$T/r" \
    "D32 🔴 somebody else's live claim: the suite skips before anything" \
    "D33 🔴 a declared measurement, even under my own claim: it skips"
echo "    (D34 and D35 are green over the base: a claim that does not hold the lab is told by the other skip,"
echo "     which the base also gives; the gate's D34/D35 mutants turn them red)"

echo "== E: selfcheck_b6 over round 5's tripwire and wrappers (real binaries -> /bin/true)"
B5=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/extb5
fakewrap() {   # fakewrap <make_hbwrap.sh> <dir>
    bash "$1" "$2" > /dev/null
    sed -i -e 's#real=/usr/local/bin/simple_switch #real=/bin/true #' \
           -e 's#real=/usr/local/bmv2-fast/bin/simple_switch_grpc #real=/bin/true #' "$2/simple_switch" "$2/simple_switch_grpc"
    /usr/bin/grep -q 'real=/bin/true' "$2/simple_switch" && /usr/bin/grep -q 'real=/bin/true' "$2/simple_switch_grpc"
}
fakewrap "$B5/make_hbwrap.sh" "$T/w5" || nok "  round 5's wrappers could not be faked"
TMPDIR="$T" bash "$HERE_RF/selfcheck_b6.sh" "$B5/aeg/tripwire_b5.sh" "$T/w5" > "$K/e_b5.out" 2>&1
sed -n 's/^  BAD   //p' "$K/e_b5.out" | sed -E 's/: rc .*//' > "$T/r"
same_set "round 5's tripwire and wrappers" "$T/r" "tripwire a cwd outside TMPDIR" "wrapper a cwd outside TMPDIR"
fakewrap "$HERE_RF/make_hbwrap.sh" "$T/w6" || nok "  round 6's wrappers could not be faked"   # (the driver copies make_hbwrap.sh beside this script)
TMPDIR="$T" bash "$HERE_RF/selfcheck_b6.sh" "$HERE_RF/tripwire_b6.sh" "$T/w6" > "$K/e_b6.out" 2>&1 \
    && ok "  round 6's: $(tail -1 "$K/e_b6.out")" || nok "  round 6's tripwire or wrappers: $(tail -1 "$K/e_b6.out")"

echo "REDFIRST-B6: $([[ $bad == 0 ]] && echo ALL-AS-EXPECTED || echo UNEXPECTED)"
exit $bad
