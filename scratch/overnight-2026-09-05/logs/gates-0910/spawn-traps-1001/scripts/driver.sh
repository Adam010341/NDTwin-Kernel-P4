#!/usr/bin/env bash
# driver.sh -- every run of this round, one run.sh log per item, red first. Overview: driver.log.
# [Co-developed with claude code -- Adam]
set -uo pipefail
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/traps
R=$L/scripts/run.sh; MT=$L/scripts/make_tree.sh; V=$L/scripts/variant.py
PYP=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python
GATE=tests/shell/mutate_fixture_spawn_helpers.sh
SIGT=tests/shell/test_fixture_suites_end_on_signal.sh
BASE=d452d111
item() { local n="$1" d="$2"; shift 2; printf '%-36s %s  %s\n' "$n" "$($R "$n.log" "$d" "$@")" \
    "$(grep -E '^Ran |survivor|cells ok|^static check|refused' "$L/$n.log" | tail -1 | cut -c1-150)"; }
echo "# driver started $(date -Is) at $(git -C "$WT" rev-parse HEAD)"

# --- trees ------------------------------------------------------------------------------------
{
  "$MT" $BASE "$SP/tb-sig" "$SIGT=$WT/$SIGT"
  "$MT" $BASE "$SP/tb-newgate" "$GATE=$WT/$GATE"
  "$MT" $BASE "$SP/tb-review1"
  "$V" "$SP/tb-review1/tests/shell/test_faults_topo_pid.sh" $'spawn "$DECOYP"; DECOY="$FIXTURE_PID"\n' $'(\nspawn "$DECOYP"; DECOY="$FIXTURE_PID"\n)\n'
  "$MT" HEAD "$SP/th-review1"
  "$V" "$SP/th-review1/tests/shell/test_faults_topo_pid.sh" $'spawn "$DECOYP"; DECOY="$FIXTURE_PID"\n' $'(\nspawn "$DECOYP"; DECOY="$FIXTURE_PID"\n)\n'
  git -C "$WT" show "$BASE:$GATE" > "$SP/gate-$BASE.sh"
  "$MT" HEAD "$SP/th-unreadable" "tests/shell/mutate_fixture_spawn_helpers.$BASE.sh=$SP/gate-$BASE.sh"
  "$V" "$SP/th-unreadable/tests/shell/test_ndtwin_lab_sweep.sh" '"${argv[0]:-nothing readable} (pid $pid' '"${argv[0]:-unreadable} (pid $pid'
  "$MT" HEAD "$SP/th-anchor-missing"
  "$V" "$SP/th-anchor-missing/tests/shell/test_faults_topo_pid.sh" '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]-}" == "$want" ]]'
  "$MT" HEAD "$SP/th-anchor-doubled"
  "$V" "$SP/th-anchor-doubled/tests/shell/test_faults_topo_pid.sh" $'FIXTURE_ARGV_WAIT=30\n' $'FIXTURE_ARGV_WAIT=30\n# a comment that quotes [[ "${argv[0]:-}" == "$want" ]]\n'
} > "$L/trees.log" 2>&1 || { echo "tree prep failed, see trees.log"; exit 2; }
echo "trees ready (trees.log)"

# --- red first --------------------------------------------------------------------------------
item red-signal-test-d452d111      "$SP/tb-sig"       bash $SIGT
item red-gate-subshell-d452d111    "$SP/tb-newgate"   bash $GATE
item red-review1-topo119-d452d111  "$SP/tb-review1"   bash $GATE topo_pid
EXTRA_PATH=$SP/shim124 item red-forced124-old-gate "$SP/tb-sig" bash $GATE sweep
item red-unreadable-old-gate       "$SP/th-unreadable" bash tests/shell/mutate_fixture_spawn_helpers.$BASE.sh sweep
item anchor-missing-head           "$SP/th-anchor-missing" bash $GATE topo_pid
item anchor-doubled-head           "$SP/th-anchor-doubled" bash $GATE topo_pid

# --- green ------------------------------------------------------------------------------------
item green-signal-test-head        "$WT" bash $SIGT
item green-gate-head               "$WT" bash $GATE
item green-review1-topo119-head    "$SP/th-review1"   bash $GATE topo_pid
EXTRA_PATH=$SP/shim124 item green-forced124-new-gate "$WT" bash $GATE sweep
item green-unreadable-new-gate     "$SP/th-unreadable" bash $GATE sweep

# --- the seven suites, before and after -------------------------------------------------------
for s in test_ndt_app_orphans test_ndt_apps_liveness test_ndtwin_lab_sweep test_ndt_helper_apps_window \
         test_faults_topo_pid test_ndt_ovs_claim test_ndt_down_stops_only_ours; do
    item "suite-before-$s" "$SP/tb-sig" bash "tests/shell/$s.sh"
    item "suite-after-$s"  "$WT"        bash "tests/shell/$s.sh"
done

# --- every gate and check that reads or runs these suites, at HEAD ----------------------------
item g-redirection-order   "$WT" bash tests/shell/mutate_redirection_order.sh
item g-g6-liveness         "$WT" bash tests/shell/mutate_g6_apps_liveness.sh
item g-te-stdin            "$WT" bash tests/shell/mutate_te_launcher_stdin.sh
item g-ovs-claim           "$WT" bash tests/shell/mutate_ndt_ovs_claim.sh
item g-window              "$WT" bash tests/shell/mutate_ndt_helper_apps_window.sh
item g-g9-sweep            "$WT" bash tests/shell/mutate_g9_cleanup_no_pkill_f.sh
item g-g9-faults           "$WT" bash tests/shell/mutate_g9_faults_topo_pid.sh
item g-by-name             "$WT" bash tests/shell/mutate_check_process_by_name.sh
item g-l1-scoring          "$WT" bash tests/shell/mutate_l1_shell_scoring.sh
item g-probe-stubs-pyproxy "$WT" env PY_PROXY=$PYP bash tests/shell/mutate_probe_stubs.sh
item l1-scoring            "$WT" bash tests/shell/test_l1_shell_scoring.sh
item redirection-order     "$WT" bash tests/shell/test_redirection_order.sh
item by-name-checker       "$WT" python3 tests/shell/check_process_by_name.py
item tmpdirs               "$WT" python3 tests/shell/check_test_tmpdirs.py
item anchors-head          "$WT" python3 tests/shell/check_gate_anchors.py HEAD
item anchors-base-and-head "$WT" python3 tests/shell/check_gate_anchors.py --gates-from HEAD $BASE HEAD
echo "# driver ended $(date -Is)"
