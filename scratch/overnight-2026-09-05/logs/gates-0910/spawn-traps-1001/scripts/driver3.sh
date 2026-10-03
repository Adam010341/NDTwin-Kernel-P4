#!/usr/bin/env bash
# driver3.sh -- after e0bb7d7f (the signal test waits for a LIVE fixture): its red runs again on the
# new test, then green, three times over for the flake that prompted the change. Overview: driver3.log.
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
echo "# driver3 started $(date -Is) at $(git -C "$WT" rev-parse HEAD)"
{
  git -C "$WT" diff --stat d452d111 HEAD
  "$MT" d452d111 "$SP/tb-sig3" "$SIGT=$WT/$SIGT"
  "$MT" HEAD "$SP/th3-d1a"
  "$V" "$SP/th3-d1a/$TP" $'trap cleanup EXIT\ntrap \'exit 130\' INT' $'trap \'exit 130\' INT'
  "$V" "$SP/th3-d1a/$DN" $'trap cleanup EXIT\ntrap \'exit 130\' INT' $'trap \'exit 130\' INT'
  "$MT" HEAD "$SP/th3-d1b"
  "$V" "$SP/th3-d1b/$TP" $'    [[ -f "$FIXTURE_REG" ]] && reap >/dev/null\n' $'    : no reap\n'
  "$V" "$SP/th3-d1b/$DN" '[[ "$(cat "/proc/$p/comm" 2>/dev/null)" == sleep ]] && kill -KILL "$p" 2>/dev/null' ': no kill'
  "$MT" HEAD "$SP/th3-d1c"
  "$V" "$SP/th3-d1c/$TP" '[[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/faults-topo-pid-* ]] && rm -rf "$TMPROOT"' ': no rm'
  "$V" "$SP/th3-d1c/$DN" '[[ -n "${FIX:-}" && "$FIX" == "${TMPDIR:-/tmp}/ndt-down-ours-"* ]] && rm -rf "$FIX"' ': no rm'
  "$MT" HEAD "$SP/th3-hung"
  "$V" "$SP/th3-hung/$TP" $'spawn "$FIXP"; FIX="$FIXTURE_PID"\n' $'spawn "$FIXP"; FIX="$FIXTURE_PID"\ntrap \'\' INT TERM; sleep 1000\n'
} > "$L/trees3.log" 2>&1 || { echo "tree prep failed, see trees3.log"; exit 2; }
echo "trees ready (trees3.log)"
item r3-red-signal-test-d452d111  "$SP/tb-sig3"  bash $SIGT
item r3-d1a-no-exit-trap          "$SP/th3-d1a"  bash $SIGT topo_pid down
item r3-d1b-cleanup-skips-reap    "$SP/th3-d1b"  bash $SIGT topo_pid down
item r3-d1c-cleanup-skips-tree    "$SP/th3-d1c"  bash $SIGT topo_pid down
item r3-d2-hung-suite             "$SP/th3-hung" bash $SIGT topo_pid
item r3-d2-total-limit            "$WT" env SIGNAL_TOTAL_LIMIT=1 bash $SIGT topo_pid down
for k in 1 2 3; do item "r3-green-signal-test-head-$k" "$WT" bash $SIGT; done
item r3-suite-orphans   "$WT" bash tests/shell/test_ndt_app_orphans.sh
item r3-gate-orphans    "$WT" bash $GATE orphans
item r3-g-l1-scoring    "$WT" bash tests/shell/mutate_l1_shell_scoring.sh
item r3-l1-scoring      "$WT" bash tests/shell/test_l1_shell_scoring.sh
item r3-tmpdirs         "$WT" python3 tests/shell/check_test_tmpdirs.py
item r3-anchors-head    "$WT" python3 tests/shell/check_gate_anchors.py HEAD
item r3-leftovers       "$WT" bash $L/scripts/leftovers.sh
echo "# driver3 ended $(date -Is)"
