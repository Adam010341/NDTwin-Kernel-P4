#!/usr/bin/env bash
# Segment W's gate run (TICKET-P4-heartbeat), on the worktree's HEAD. [Co-developed with claude code -- Adam]
#
# Every gate runs through tools/build_guard/guarded_build.sh with JOBS=1 LOCK_WAIT=10800 and writes
# logs/gates-0910/<gate>.p4hbw-<sha8>.log whose FIRST line is the full sha and whose LAST line is the
# real rc (`# rc=<n>`). A gate with a known non-zero rc is declared with that rc and why; the summary
# says ALL-AS-EXPECTED or RED. Before every gate HEAD and the tracked files are re-checked.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-heartbeat-w-0926
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
PY=$WT/p4_proxy/venv/bin/python
GUARD=$WT/tools/build_guard/guarded_build.sh
ONLY="${ONLY:-}"
sha=$(git -C "$WT" rev-parse --short=8 HEAD)
full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree; the gates must run on a commit"; exit 2; }
export TMPDIR="$SP/tmp"; mkdir -p "$TMPDIR"
S="$L/scripts-p4hbw-$sha"; mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$SP/ndt_suites.sh" "$SP/red_first_w.sh" "$SP/baseline_and_helper.sh" "$S/" 2>/dev/null
( cd "$S" && sha256sum * > SHA256SUMS )
fail=0
run() {   # run <gate> <expected rc> <why, or -> <cwd> <cmd...>
    local name="$1" want="$2" why="$3" cwd="$4" log="$L/$1.p4hbw-$sha.log" rc
    shift 4
    [[ -n "$ONLY" && " $ONLY " != *" $name "* ]] && return
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists (never overwrite a round)"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then
        echo "REFUSE: HEAD moved or tracked files changed under the round"; exit 3
    fi
    find "$WT/p4_proxy" "$WT/tools" "$WT/tests" "$WT/doc" -name __pycache__ -type d -not -path '*/venv/*' \
        -prune -exec rm -rf {} + 2>/dev/null
    { echo "$full"
      echo "# worktree $WT  $(date -u +%FT%TZ)"
      echo "# cwd $cwd"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"
      [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-40s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: |ResourceWarning|^  for index|^ResourceWarning' "$log" | tail -1)"
    [[ "$rc" == "$want" ]] || fail=1
}
EMPTYHOME="$SP/emptyhome"; mkdir -p "$EMPTYHOME"
MODS=$(ls "$WT"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
PREP_DIR=doc/audit/2026-09-04_p4-tutorial-exercise-prep

# --- this segment's own ------------------------------------------------------------------------
run p4_proxy_suite 0 - "$WT/p4_proxy" env PYTHONPATH="$WT/p4_proxy" PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest $MODS
run test_ndt_heartbeat 0 - "$WT" bash tests/shell/test_ndt_heartbeat.sh
run live08_selftest 0 - "$WT" bash "$PREP_DIR/live-p1/08_heartbeat.sh" --self-test
run mutate_p4_heartbeat_w 0 - "$WT" bash tests/shell/mutate_p4_heartbeat_w.sh
run check_gate_anchors 0 - "$WT" python3 tests/shell/check_gate_anchors.py "$sha"
run red_first 0 - "$WT" bash "$S/red_first_w.sh" "$WT"
run baseline_and_helper 0 - "$WT" bash "$S/baseline_and_helper.sh" "$WT"
# --- the ticket's named suites -----------------------------------------------------------------
run p4_exercise_suite 0 - "$WT" env PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests
run p4_exercise_suite_notutorials 0 - "$WT" env HOME="$EMPTYHOME" PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests
run drive_exercise_suite 0 - "$WT" env PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest discover -s "$PREP_DIR/tests" -t "$PREP_DIR/tests"
# --- every shell suite that sources or drives ndt ---------------------------------------------
run ndt_suites 0 - "$WT" bash "$S/ndt_suites.sh" "$WT"
# --- the existing gates whose anchors or suites this segment touched ----------------------------
run mutate_roles_binding 0 - "$WT" bash tests/shell/mutate_roles_binding.sh
run mutate_app_package 0 - "$WT" bash tests/shell/mutate_app_package.sh
run mutate_table_entry 0 - "$WT" bash tests/shell/mutate_table_entry.sh
run mutate_p4_priority_refusal 0 - "$WT" bash tests/shell/mutate_p4_priority_refusal.sh
run mutate_a7_dispatch_status_python_only 0 - "$WT" bash tests/shell/mutate_a7_dispatch_status.sh --python-only
run mutate_path_determinism 0 - "$WT" bash tests/shell/mutate_path_determinism.sh
run mutate_telemetry_by_name 0 - "$WT" bash tests/shell/mutate_telemetry_by_name.sh
run mutate_ndt_app_package 0 - "$WT" bash tests/shell/mutate_ndt_app_package.sh
run mutate_ndt_down_claim_guard 0 - "$WT" bash tests/shell/mutate_ndt_down_claim_guard.sh
run mutate_ndt_up_down_robust 0 - "$WT" bash tests/shell/mutate_ndt_up_down_robust.sh
run mutate_ndt_ovs_claim 0 - "$WT" bash tests/shell/mutate_ndt_ovs_claim.sh
run mutate_ndt_status_check 0 - "$WT" bash tests/shell/mutate_ndt_status_check.sh
run mutate_ndt_honesty 0 - "$WT" bash tests/shell/mutate_ndt_honesty.sh
run mutate_ndt_round_baseline 0 - "$WT" bash tests/shell/mutate_ndt_round_baseline.sh
run mutate_ndt_up_target 0 - "$WT" bash tests/shell/mutate_ndt_up_target.sh
run mutate_ndt_sudo_surface 0 - "$WT" bash tests/shell/mutate_ndt_sudo_surface.sh
run mutate_rule_journal_is_wired 0 - "$WT" bash tests/shell/mutate_rule_journal_is_wired.sh
run mutate_p4_rule_install_time 0 - "$WT" bash tests/shell/mutate_p4_rule_install_time.sh
run mutate_stack_await_convergence 0 - "$WT" bash tests/shell/mutate_stack_await_convergence.sh
echo "FINAL-GATES $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
