#!/usr/bin/env bash
# live-0925.sh -- goal (4): roles live acceptance on the merged trunk 572d9462 (P4-R-SUMMARY section 8).
# 07 (L1-L6) -> 01 baseline -> 06 thirteen (13x2); each script claims and releases itself.
# Afterwards the p4_exercise suite, to see whether any tutorials build drifted from its fixture.
# [Co-developed with claude code -- Adam]
set -u
G=/home/adam/Desktop/NDTwin-Kernel; L=$G/scratch/overnight-2026-09-05/logs/orchestrator-0924/live-0925
D=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
mkdir -p "$L"; cd "$G" || exit 9
export NDT_OWNER=orch-0924
say() { echo "== $(date '+%F %T') $*"; }
say "trunk $(git rev-parse --short HEAD); kernel $(sha256sum build/bin/ndtwin_kernel | cut -c1-16); disk $(df -h / | awk 'NR==2{print $4}')"
git diff -- p4_proxy/mininet/host_count_override > "$L/knob-before.diff"
for s in 07_roles_basic 01_baseline 06_thirteen; do
    [[ "$(df --output=avail -B1M / | tail -1)" -gt 1500 ]] || { say "STOP: disk under 1.5 G before $s"; break; }
    say "start $s"
    bash "$D/$s.sh" > "$L/$s.log" 2>&1; rc=$?
    say "end $s rc=$rc  last: $(tail -1 "$L/$s.log")"
    NDT_OWNER=orch-0924 tools/test_workflow/ndt status 2>&1 | sed -n 2,3p
done
git diff -- p4_proxy/mininet/host_count_override > "$L/knob-after.diff"
cmp -s "$L/knob-before.diff" "$L/knob-after.diff" && say "knob unchanged" || say "🔴 knob CHANGED"
env PYTHONDONTWRITEBYTECODE=1 p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests > "$L/p4_exercise-after.log" 2>&1
say "p4_exercise after live rc=$?  $(grep -E '^(OK|FAILED)' "$L/p4_exercise-after.log")"
say "DONE"
