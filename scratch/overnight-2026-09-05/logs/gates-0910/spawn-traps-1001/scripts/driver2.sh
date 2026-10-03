#!/usr/bin/env bash
# driver2.sh -- round 2 of this branch: the follow-up evidence, red first. Overview: driver2.log.
# [Co-developed with claude code -- Adam]
set -uo pipefail
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/traps
R=$L/scripts/run.sh; MT=$L/scripts/make_tree.sh; V=$L/scripts/variant.py
GATE=tests/shell/mutate_fixture_spawn_helpers.sh
SIGT=tests/shell/test_fixture_suites_end_on_signal.sh
TP=tests/shell/test_faults_topo_pid.sh; DN=tests/shell/test_ndt_down_stops_only_ours.sh
item() { local n="$1" d="$2"; shift 2; printf '%-34s %s  %s\n' "$n" "$($R "$n.log" "$d" "$@")" \
    "$(grep -E '^Ran |survivor|cells ok|refused' "$L/$n.log" | tail -1 | cut -c1-150)"; }
echo "# driver2 started $(date -Is) at $(git -C "$WT" rev-parse HEAD)"
{
  git -C "$WT" diff --stat d452d111 HEAD
  # D1: (a) no EXIT trap, (b) cleanup skips the reap, (c) cleanup skips the temp tree -- topo_pid (a
  # /tmp suite) and down (a TMPDIR suite) in each tree
  "$MT" HEAD "$SP/th-d1a"
  "$V" "$SP/th-d1a/$TP" $'trap cleanup EXIT\ntrap \'exit 130\' INT' $'trap \'exit 130\' INT'
  "$V" "$SP/th-d1a/$DN" $'trap cleanup EXIT\ntrap \'exit 130\' INT' $'trap \'exit 130\' INT'
  "$MT" HEAD "$SP/th-d1b"
  "$V" "$SP/th-d1b/$TP" $'    [[ -f "$FIXTURE_REG" ]] && reap >/dev/null\n' $'    : no reap\n'
  "$V" "$SP/th-d1b/$DN" '[[ "$(cat "/proc/$p/comm" 2>/dev/null)" == sleep ]] && kill -KILL "$p" 2>/dev/null' ': no kill'
  "$MT" HEAD "$SP/th-d1c"
  "$V" "$SP/th-d1c/$TP" '[[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/faults-topo-pid-* ]] && rm -rf "$TMPROOT"' ': no rm'
  "$V" "$SP/th-d1c/$DN" '[[ -n "${FIX:-}" && "$FIX" == "${TMPDIR:-/tmp}/ndt-down-ours-"* ]] && rm -rf "$FIX"' ': no rm'
  # D2: a suite that hangs after its first fixture, ignoring both signals
  "$MT" HEAD "$SP/th-hung"
  "$V" "$SP/th-hung/$TP" $'spawn "$FIXP"; FIX="$FIXTURE_PID"\n' $'spawn "$FIXP"; FIX="$FIXTURE_PID"\ntrap \'\' INT TERM; sleep 1000\n'
  # D4: the review's test 2 -- down's old cleanup-and-return trap back, the guard kept
  "$MT" HEAD "$SP/th-test2"
  "$V" "$SP/th-test2/$DN" $'trap cleanup EXIT\ntrap \'exit 130\' INT\ntrap \'exit 143\' TERM\n' $'trap cleanup EXIT INT TERM\n'
} > "$L/trees2.log" 2>&1 || { echo "tree prep failed, see trees2.log"; exit 2; }
echo "trees ready (trees2.log)"

# --- red ----------------------------------------------------------------------------------------
item d1a-no-exit-trap        "$SP/th-d1a"  bash $SIGT topo_pid down
item d1b-cleanup-skips-reap  "$SP/th-d1b"  bash $SIGT topo_pid down
item d1c-cleanup-skips-tree  "$SP/th-d1c"  bash $SIGT topo_pid down
item d2-hung-suite           "$SP/th-hung" bash $SIGT topo_pid
SIGNAL_TOTAL_LIMIT=1 item d2-total-limit "$WT" env SIGNAL_TOTAL_LIMIT=1 bash $SIGT topo_pid down
item d4-test2-returning-trap "$SP/th-test2" bash $GATE down
item d5-old-gate-full-d452d111 "$SP/tb-sig" bash $GATE

# --- green --------------------------------------------------------------------------------------
item r2-green-signal-test-head "$WT" bash $SIGT
item r2-green-gate-head        "$WT" bash $GATE
for s in test_ndt_app_orphans test_ndt_apps_liveness test_ndtwin_lab_sweep test_ndt_helper_apps_window \
         test_faults_topo_pid test_ndt_ovs_claim test_ndt_down_stops_only_ours; do
    item "r2-suite-$s" "$WT" bash "tests/shell/$s.sh"
done
item r2-g-l1-scoring  "$WT" bash tests/shell/mutate_l1_shell_scoring.sh
item r2-l1-scoring    "$WT" bash tests/shell/test_l1_shell_scoring.sh
item r2-tmpdirs       "$WT" python3 tests/shell/check_test_tmpdirs.py
item r2-anchors-head  "$WT" python3 tests/shell/check_gate_anchors.py HEAD
item r2-leftovers     "$WT" bash $L/scripts/leftovers.sh
echo "# driver2 ended $(date -Is)"
