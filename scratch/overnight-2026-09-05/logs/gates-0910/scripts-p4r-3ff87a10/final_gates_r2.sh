#!/usr/bin/env bash
# Worker R's final gate run, round 2 (TICKET-P4-roles section 7 ruling 5), on the worktree's HEAD.
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

# --- section 3.4 ---------------------------------------------------------------------------------
run p4_proxy_suite 0 - "$WT/p4_proxy" env PYTHONPATH="$WT/p4_proxy" PYTHONDONTWRITEBYTECODE=1 \
    "$PY" -m unittest $MODS
run p4_exercise_suite 1 "FixtureProvenance only -- ~/tutorials/exercises/p4runtime/build/advanced_tunnel.json was recompiled 2026-09-24 17:59 by somebody else; red at the base too (fixture_provenance_at_base)" \
    "$WT" env PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest discover -s tools/p4_exercise/tests \
    -t tools/p4_exercise/tests
reds=$(/usr/bin/grep -E '^(FAIL|ERROR):' "$L/p4_exercise_suite.p4r-$sha.log" | sort -u)
[[ "$reds" == "FAIL: test_every_fixture_is_still_byte_identical_to_its_tutorials_original (test_convert.FixtureProvenance.test_every_fixture_is_still_byte_identical_to_its_tutorials_original)" ]] \
    && echo "   (its one red is FixtureProvenance, nothing else)" \
    || { echo "   🔴 p4_exercise_suite's reds are not exactly FixtureProvenance: $reds"; fail=1; }
run p4_exercise_suite_notutorials 0 - "$WT" env HOME="$EMPTYHOME" PYTHONDONTWRITEBYTECODE=1 "$PY" \
    -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests
run fixture_provenance_at_base 0 - "$WT" bash "$SP/provenance_at_base.sh"
run mutate_roles_binding 0 - "$WT" bash tests/shell/mutate_roles_binding.sh
run mutate_app_package 0 - "$WT" bash tests/shell/mutate_app_package.sh
run mutate_table_entry 0 - "$WT" bash tests/shell/mutate_table_entry.sh
run mutate_p4_exercise_tools 0 - "$WT" env HOME="$EMPTYHOME" bash tests/shell/mutate_p4_exercise_tools.sh
run contract_selftest 0 - "$WT/tools/contract_test" python3 run_contract_test.py --self-test
run live07_selftest 0 - "$WT" env \
    SELFTEST_OLD_RUN=/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs/2026-09-19T062604Z_02_app_basic \
    SELFTEST_OLD_TOPO=/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic/ndtwin/topology.json \
    bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/07_roles_basic.sh --self-test
# merged_checks.sh's seven, in this worktree:
run check_process_by_name 0 - "$WT" python3 tests/shell/check_process_by_name.py
run check_gate_anchors 0 - "$WT" python3 tests/shell/check_gate_anchors.py "$sha"
run kiref 0 - "$WT" python3 -m unittest tests.python.test_known_issues_references
run check_test_tmpdirs 0 - "$WT" python3 tests/shell/check_test_tmpdirs.py
run test_redirection_order 0 - "$WT" bash tests/shell/test_redirection_order.sh
run test_log_suffix_idempotent 0 - "$WT" bash tests/shell/test_log_suffix_idempotent.sh
run test_topo_from_json 0 - "$WT" python3 tools/test_workflow/test_topo_from_json.py

# --- round 2's own evidence ------------------------------------------------------------------------
run round2_red_first 0 - "$WT" bash "$SP/round2_red_first.sh"
run baseline_chain 0 - "$WT" bash "$SP/baseline_chain.sh"
run offline_5-3_six_plus_four 0 - "$WT" env WT="$WT" OUT="$SP/offline53f" bash "$SP/offline_roles_check.sh"
# item 7: its anchor is in api_routes.py, which this ticket changed. --python-only: the two lanes
# that need no build; the cpp lane is not run here (no C++ builds, ticket 0-3). It mutates the
# WORKING TREE in place and restores it on exit -- the next gate's pre-check would stop the round
# if it had not.
run mutate_a7_dispatch_status_python_only 0 - "$WT" env PROXY_PY="$PY" \
    bash tests/shell/mutate_a7_dispatch_status.sh --python-only

# --- not in section 3.4: gates anchored in files this ticket changed -------------------------------
run mutate_p4_priority_refusal 0 - "$WT" bash tests/shell/mutate_p4_priority_refusal.sh
run mutate_path_determinism 0 - "$WT" bash tests/shell/mutate_path_determinism.sh
run mutate_telemetry_by_name 0 - "$WT" bash tests/shell/mutate_telemetry_by_name.sh
run mutate_link_telemetry 0 - "$WT" bash tests/shell/mutate_link_telemetry.sh
run mutate_p4_rule_install_time 2 "baseline red at 6291db35 too: the gate copies p4_proxy/{proxy_agent,tests,mininet} with no setting/ beside it, and main.py loads the 128-host model at import" \
    "$WT" bash tests/shell/mutate_p4_rule_install_time.sh
run mutate_rule_journal_is_wired 2 "same pre-existing cause as mutate_p4_rule_install_time" \
    "$WT" bash tests/shell/mutate_rule_journal_is_wired.sh
run mutate_p4_rule_install_time_withmodel 0 - "$WT" env NDTWIN_P4_TOPO_FILE="$MODEL128" \
    bash tests/shell/mutate_p4_rule_install_time.sh
run mutate_rule_journal_is_wired_withmodel 0 - "$WT" env NDTWIN_P4_TOPO_FILE="$MODEL128" \
    bash tests/shell/mutate_rule_journal_is_wired.sh
echo "FINAL-GATES $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
