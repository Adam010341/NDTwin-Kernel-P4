#!/usr/bin/env bash
# driver5.sh -- the N1 demonstration done right: ovs_claim kills its first fixture at once, then
# runs 60 s of 0.5 s sleeps (processes of the run, none in its register; TERM is handled between
# them). Previous test (664500d3's tree) vs the delivered one. Overview: driver5.log.
# [Co-developed with claude code -- Adam]
set -uo pipefail
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/traps
R=$L/scripts/run.sh; MT=$L/scripts/make_tree.sh; V=$L/scripts/variant.py
SIGT=tests/shell/test_fixture_suites_end_on_signal.sh; OC=tests/shell/test_ndt_ovs_claim.sh
item() { local n="$1" d="$2"; shift 2; printf '%-34s %s  %s\n' "$n" "$($R "$n.log" "$d" "$@")" \
    "$(grep -E '^Ran ' "$L/$n.log" | tail -1 | cut -c1-150)"; }
GAP_OLD=$'LIVE_VIZ="$FIXTURE_PID"\npidf app_viz.pid "$LIVE_VIZ"\nOUT="$(drive \'app_pidfile_stale_row\')"\nhasnt "🔴 a pidfile naming a LIVE viz'
GAP_NEW=$'LIVE_VIZ="$FIXTURE_PID"\nkill -KILL "$LIVE_VIZ"; for _ in $(seq 120); do command sleep 0.5; done\npidf app_viz.pid "$LIVE_VIZ"\nOUT="$(drive \'app_pidfile_stale_row\')"\nhasnt "🔴 a pidfile naming a LIVE viz'
echo "# driver5 started $(date -Is) at $(git -C "$WT" rev-parse HEAD)"
{
  "$MT" 664500d3 "$SP/t5-gap-prev"; "$V" "$SP/t5-gap-prev/$OC" "$GAP_OLD" "$GAP_NEW"
  "$MT" HEAD "$SP/t5-gap-head";     "$V" "$SP/t5-gap-head/$OC" "$GAP_OLD" "$GAP_NEW"
} > "$L/trees5.log" 2>&1 || { echo "tree prep failed, see trees5.log"; exit 2; }
item r5-n1-gap-prev-test "$SP/t5-gap-prev" env SIGNAL_FIRST_FIXTURE_WAIT=25 bash $SIGT ovs_claim
item r5-n1-gap-head-test "$SP/t5-gap-head" env SIGNAL_FIRST_FIXTURE_WAIT=25 bash $SIGT ovs_claim
# d452d111's down alone: the d452d111 red run above used up SIGNAL_TOTAL_LIMIT before reaching it
item r5-red-signal-test-d452d111-down "$SP/t4-sig-base" bash $SIGT down
item r5-leftovers "$WT" bash $L/scripts/leftovers.sh
echo "# driver5 ended $(date -Is)"
