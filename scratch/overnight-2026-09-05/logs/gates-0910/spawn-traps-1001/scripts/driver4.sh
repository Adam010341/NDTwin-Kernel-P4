#!/usr/bin/env bash
# driver4.sh -- round 3 of this branch, at the delivered head. Overview: driver4.log.
# [Co-developed with claude code -- Adam]
set -uo pipefail
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/traps
R=$L/scripts/run.sh; MT=$L/scripts/make_tree.sh; V=$L/scripts/variant.py
GATE=tests/shell/mutate_fixture_spawn_helpers.sh
SIGT=tests/shell/test_fixture_suites_end_on_signal.sh
TP=tests/shell/test_faults_topo_pid.sh; DN=tests/shell/test_ndt_down_stops_only_ours.sh; OC=tests/shell/test_ndt_ovs_claim.sh
item() { local n="$1" d="$2"; shift 2; printf '%-34s %s  %s\n' "$n" "$($R "$n.log" "$d" "$@")" \
    "$(grep -E '^Ran |survivor|cells ok|refused' "$L/$n.log" | tail -1 | cut -c1-150)"; }
GAP_OLD=$'LIVE_VIZ="$FIXTURE_PID"\npidf app_viz.pid "$LIVE_VIZ"\nOUT="$(drive \'app_pidfile_stale_row\')"\nhasnt "🔴 a pidfile naming a LIVE viz'
GAP_NEW=$'LIVE_VIZ="$FIXTURE_PID"\nkill -KILL "$LIVE_VIZ"; command sleep 8\npidf app_viz.pid "$LIVE_VIZ"\nOUT="$(drive \'app_pidfile_stale_row\')"\nhasnt "🔴 a pidfile naming a LIVE viz'
echo "# driver4 started $(date -Is) at $(git -C "$WT" rev-parse HEAD)"
{
  git -C "$WT" diff --stat d452d111 HEAD
  # N1: ovs_claim kills its first fixture at once and then sleeps 8 s with no fixture alive
  "$MT" 664500d3 "$SP/t4-gap-prev"; "$V" "$SP/t4-gap-prev/$OC" "$GAP_OLD" "$GAP_NEW"
  "$MT" HEAD "$SP/t4-gap-head";     "$V" "$SP/t4-gap-head/$OC" "$GAP_OLD" "$GAP_NEW"
  "$MT" d452d111 "$SP/t4-sig-base" "$SIGT=$WT/$SIGT"
  "$MT" HEAD "$SP/t4-d1a"
  "$V" "$SP/t4-d1a/$TP" $'trap cleanup EXIT\ntrap \'exit 130\' INT' $'trap \'exit 130\' INT'
  "$V" "$SP/t4-d1a/$DN" $'trap cleanup EXIT\ntrap \'exit 130\' INT' $'trap \'exit 130\' INT'
  "$MT" HEAD "$SP/t4-d1b"
  "$V" "$SP/t4-d1b/$TP" $'    [[ -f "$FIXTURE_REG" ]] && reap >/dev/null\n' $'    : no reap\n'
  "$V" "$SP/t4-d1b/$DN" '[[ "$(cat "/proc/$p/comm" 2>/dev/null)" == sleep ]] && kill -KILL "$p" 2>/dev/null' ': no kill'
  "$MT" HEAD "$SP/t4-d1c"
  "$V" "$SP/t4-d1c/$TP" '[[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/faults-topo-pid-* ]] && rm -rf "$TMPROOT"' ': no rm'
  "$V" "$SP/t4-d1c/$DN" '[[ -n "${FIX:-}" && "$FIX" == "${TMPDIR:-/tmp}/ndt-down-ours-"* ]] && rm -rf "$FIX"' ': no rm'
  "$MT" HEAD "$SP/t4-hung"
  "$V" "$SP/t4-hung/$TP" $'spawn "$FIXP"; FIX="$FIXTURE_PID"\n' $'spawn "$FIXP"; FIX="$FIXTURE_PID"\ntrap \'\' INT TERM; sleep 1000\n'
} > "$L/trees4.log" 2>&1 || { echo "tree prep failed, see trees4.log"; exit 2; }
echo "trees ready (trees4.log)"
# --- red ---
item r4-n1-gap-prev-test     "$SP/t4-gap-prev" env SIGNAL_FIRST_FIXTURE_WAIT=5 bash $SIGT ovs_claim
item r4-n1-gap-head-test     "$SP/t4-gap-head" env SIGNAL_FIRST_FIXTURE_WAIT=5 bash $SIGT ovs_claim
item r4-red-signal-test-d452d111 "$SP/t4-sig-base" bash $SIGT
item r4-d1a-no-exit-trap     "$SP/t4-d1a"  bash $SIGT topo_pid down
item r4-d1b-cleanup-skips-reap "$SP/t4-d1b" bash $SIGT topo_pid down
item r4-d1c-cleanup-skips-tree "$SP/t4-d1c" bash $SIGT topo_pid down
item r4-d2-hung-suite        "$SP/t4-hung" bash $SIGT topo_pid
item r4-d2-total-limit       "$WT" env SIGNAL_TOTAL_LIMIT=1 bash $SIGT topo_pid down
# --- green ---
for k in 1 2 3; do item "r4-green-signal-test-head-$k" "$WT" bash $SIGT; done
item r4-green-gate-head "$WT" bash $GATE
for s in test_ndt_app_orphans test_ndt_apps_liveness test_ndtwin_lab_sweep test_ndt_helper_apps_window \
         test_faults_topo_pid test_ndt_ovs_claim test_ndt_down_stops_only_ours; do
    item "r4-suite-$s" "$WT" bash "tests/shell/$s.sh"
done
item r4-l1-scoring     "$WT" bash tests/shell/test_l1_shell_scoring.sh
item r4-g-l1-scoring   "$WT" bash tests/shell/mutate_l1_shell_scoring.sh
item r4-tmpdirs        "$WT" python3 tests/shell/check_test_tmpdirs.py
item r4-anchors-head   "$WT" python3 tests/shell/check_gate_anchors.py HEAD
item r4-leftovers      "$WT" bash $L/scripts/leftovers.sh
echo "# driver4 ended $(date -Is)"
