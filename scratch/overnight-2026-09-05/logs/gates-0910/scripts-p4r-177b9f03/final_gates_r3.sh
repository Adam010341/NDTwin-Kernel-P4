#!/usr/bin/env bash
# Worker R's gate run, round 3 (TICKET-P4-roles section 7 ruling 6), on the worktree's HEAD.
# Scoped by the orchestrator: mutate_roles_binding, the p4_proxy suite, the 07 self-test and
# check_gate_anchors -- plus round 3's own red-first and the recording wrapper (F4).
# [Co-developed with claude code -- Adam]
#
# Every gate runs through tools/build_guard/guarded_build.sh with JOBS=1 (the orchestrator's
# round-2 instruction): its own memory-capped scope, the shared build lock. Nothing here builds
# C++; the guard is there so nothing here can take the machine down either.
#
# Every gate writes <gate>.p4r-<sha>.log under logs/gates-0910 and prints
# `<gate> rc=<rc> [expected <rc>] <last line>`. A gate with a KNOWN non-zero rc is declared with
# its expected rc and its reason, and counts as red only if it answers anything else; the summary
# line says ALL-AS-EXPECTED or RED. Before every gate HEAD and the tracked files are re-checked:
# a commit landing mid-round, or a gate that failed to restore the tree, stops the round.
#
# merged_checks.sh is NOT run whole: its line 20 is `cd /home/adam/Desktop/NDTwin-Kernel`, the
# SHARED main checkout (ticket 0-5). Its seven items run one by one here, in this worktree, with
# check_gate_anchors given this sha; the orchestrator runs it whole on the merged tree (ruling 5).
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-roles-0924
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
PY=$WT/p4_proxy/venv/bin/python
GUARD=$WT/tools/build_guard/guarded_build.sh
sha=$(git -C "$WT" rev-parse --short=8 HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree; the gates must run on a commit"; exit 2; }
export TMPDIR="$SP/tmp"; mkdir -p "$TMPDIR"
fail=0
run() {   # run <gate> <expected rc> <why, or -> <cwd> <cmd...>
    local name="$1" want="$2" why="$3" cwd="$4" log="$L/$1.p4r-$sha.log" rc
    shift 4
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists (never overwrite a round)"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse --short=8 HEAD)" != "$sha" || -n "$(tree_state)" ]]; then
        echo "REFUSE: HEAD moved or tracked files changed under the round (was $sha)"; exit 3
    fi
    find "$WT/p4_proxy" "$WT/tools" "$WT/tests" -name __pycache__ -type d -not -path '*/venv/*' \
        -prune -exec rm -rf {} + 2>/dev/null
    { echo "# worktree $WT  HEAD $(git -C "$WT" rev-parse HEAD)  $(date -u +%FT%TZ)"
      echo "# cwd $cwd"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"
      [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-40s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: |ResourceWarning' "$log" | tail -1)"
    [[ "$rc" == "$want" ]] || fail=1
}
EMPTYHOME="$SP/emptyhome"; mkdir -p "$EMPTYHOME"
MODS=$(ls "$WT"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
MODEL128="$WT/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"

# --- the four gates the orchestrator named for round 3 ------------------------------------------
run p4_proxy_suite 0 - "$WT/p4_proxy" env PYTHONPATH="$WT/p4_proxy" PYTHONDONTWRITEBYTECODE=1 \
    "$PY" -m unittest $MODS
run mutate_roles_binding 0 - "$WT" bash tests/shell/mutate_roles_binding.sh
run live07_selftest 0 - "$WT" env \
    SELFTEST_OLD_RUN=/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs/2026-09-19T062604Z_02_app_basic \
    SELFTEST_OLD_TOPO=/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic/ndtwin/topology.json \
    bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/07_roles_basic.sh --self-test
run check_gate_anchors 0 - "$WT" python3 tests/shell/check_gate_anchors.py "$sha"
# --- round 3's own evidence ------------------------------------------------------------------------
run round3_red_first 0 - "$WT" bash "$SP/round3_red_first.sh"
run record_at_base 0 - "$WT" bash "$SP/record_at_base.sh"
echo "FINAL-GATES $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
