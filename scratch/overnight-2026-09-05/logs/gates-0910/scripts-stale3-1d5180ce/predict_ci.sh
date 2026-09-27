#!/usr/bin/env bash
# predict_ci.sh <worktree> <keep dir> -- (b)'s CI prediction, on the tree CI would get: trunk
# c34a643a with fix/probe-suites-stub-0927 (A: \$PREDICT_A, default 356d4e4e) and this branch (HEAD) merged in. The three
# change sets (trunk, A, B since 8746c1bc) must not share a file -- then taking each changed file from
# its side IS the merge (and `git merge-tree` of each branch with c34a643a is asked to agree). In that
# tree the two suites whose CI groups should clear are run and scored with the lane's own
# shell_summary / skip count / l1_lane_verdict; test_gate_exit_code_not_tee is run with PY_PLOT
# pointed at a path that does not exist, the way CI has it. [Co-developed with claude code -- Adam]
set -u
WT="$1"; K="$2"; bad=0; cd "$WT" || exit 2
mkdir -p "$K"; T=$(mktemp -d "${TMPDIR:-/tmp}/predict-ci-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
TR=c34a643a; A="${PREDICT_A:-356d4e4e}"; B=$(git rev-parse HEAD); BASE=8746c1bc
echo "trunk $(git rev-parse $TR)  A $(git rev-parse $A)  B $B  base $(git rev-parse $BASE)"
for s in $A $B; do git merge-tree --write-tree $TR $s > /dev/null && ok "git merge-tree $TR ${s:0:8}: clean" || nok "git merge-tree $TR ${s:0:8}: CONFLICT"; done
git diff --name-only $BASE $TR > "$T/t"; git diff --name-only $BASE $A > "$T/a"; git diff --name-only $BASE $B > "$T/b"
shared="$(sort "$T/t" "$T/a" "$T/b" | uniq -d | paste -sd' ' -)"
[[ -z "$shared" ]] && ok "no file changed on more than one side ($(wc -l < "$T/t") trunk, $(wc -l < "$T/a") A, $(wc -l < "$T/b") B)" || nok "shared: $shared"
M="$T/merged"; mkdir -p "$M"; # the WHOLE tree: a path list is a guess at the suites' dependencies, and the first run's guess
# (stale-d2a9d641) missed doc/audit/2026-08-25_sampling-rounds/cell_verdict.py, which
# ratio_gate.py imports -- not_tee went rc 2 for the instrument's reason, not the tree's
git archive $TR | tar -x -C "$M"
for side in a b; do rev=$([[ $side == a ]] && echo $A || echo $B)
    while read -r f; do
        if git cat-file -e "$rev:$f" 2>/dev/null; then mkdir -p "$M/$(dirname "$f")"; git show "$rev:$f" > "$M/$f"; else rm -f "$M/$f"; fi
    done < "$T/$side"
done
chmod +x "$M"/tests/shell/*.sh 2>/dev/null
cd "$M" || exit 2
NDTWIN_L1_LIB_ONLY=1 source tools/test_workflow/l1_unit_tests.sh >/dev/null 2>&1
declare -F shell_summary >/dev/null && declare -F l1_lane_verdict >/dev/null || { echo "REFUSE: the lane's scorer did not load"; exit 2; }
score() {   # score <label> <suite> [env...] -> the lane's line for it
    local l="$1" s="$2"; shift 2
    env "$@" timeout 900 bash "tests/shell/$s.sh" < /dev/null > "$K/$l.log" 2>&1; local rc=$?
    local ran failed; read -r ran failed <<<"$(shell_summary "$K/$l.log")"
    local sk; sk=$(grep -cE "^[[:space:]]*SKIP:" "$K/$l.log")
    local v; v="$(l1_lane_verdict "$rc" "${ran:-0}" "${failed:-0}" "${sk:-0}")"
    echo "    $l: rc $rc  ran $ran  failed $failed  skips $sk  -> $v   ($(grep -v '^\s*$' "$K/$l.log" | tail -1 | cut -c1-70))"
    V[$l]="$v"
}
declare -A V
echo "== the merged tree (c34a643a + A + B), the lane's own scorer"
score test_start_bg_log_rotation test_start_bg_log_rotation
score test_l1_shell_scoring test_l1_shell_scoring
score not_tee.no-PY_PLOT test_gate_exit_code_not_tee PY_PLOT=/nonexistent/ci-has-no-miniconda/python3
score not_tee.this-laptop test_gate_exit_code_not_tee
[[ "${V[test_start_bg_log_rotation]}" == PASS ]] && ok "start_bg: PASS -- its CI group should clear" || nok "start_bg: ${V[test_start_bg_log_rotation]}"
[[ "${V[test_l1_shell_scoring]}" == PASS ]] && ok "l1_shell_scoring: PASS -- its CI group should clear" || nok "l1_shell_scoring: ${V[test_l1_shell_scoring]}"
[[ "${V[not_tee.no-PY_PLOT]}" == FAIL-SKIP ]] && ok "not_tee with no PY_PLOT: FAIL-SKIP -- its CI group stays, as CI has it today" || nok "not_tee, no PY_PLOT: ${V[not_tee.no-PY_PLOT]}"
[[ "${V[not_tee.this-laptop]}" == PASS ]] && ok "not_tee with this laptop's PY_PLOT: PASS" || nok "not_tee, this laptop: ${V[not_tee.this-laptop]}"
echo "PREDICT-CI: $([[ $bad == 0 ]] && echo 'start_bg and l1_shell_scoring PASS on the merged tree; not_tee still SKIPs without PY_PLOT' || echo BROKEN)"
exit $bad
