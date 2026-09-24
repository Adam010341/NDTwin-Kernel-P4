#!/usr/bin/env bash
# live-0925b.sh -- ruling 7's acceptance, on the trunk with D'' merged: ONLY=ecn five times (the
# fixed arm's false-fail estimate), then ONE full 06 run. No re-running to green: whatever the full
# run says is the answer. Afterwards the tools suite, for FixtureProvenance drift.
# [Co-developed with claude code -- Adam]
set -u
G=/home/adam/Desktop/NDTwin-Kernel; L=$G/scratch/overnight-2026-09-05/logs/orchestrator-0924/live-0925b
D=doc/audit/2026-09-04_p4-tutorial-exercise-prep
mkdir -p "$L"; cd "$G" || exit 9; export NDT_OWNER=orch-0924
say() { echo "== $(date '+%F %T') $*"; }
say "trunk $(git rev-parse --short HEAD); driver blob $(git hash-object $D/drive_exercise.py); committed $(git rev-parse HEAD:$D/drive_exercise.py); kernel $(sha256sum build/bin/ndtwin_kernel | cut -c1-16); disk $(df -h / | awk 'NR==2{print $4}')"
git diff -- p4_proxy/mininet/host_count_override > "$L/knob-before.diff"
for i in 1 2 3 4 5; do
    ONLY=ecn bash $D/live-p1/06_thirteen.sh > "$L/06_ecn_$i.log" 2>&1
    say "ecn $i rc=$?  $(grep -E '^   ecn +solution' "$L/06_ecn_$i.log" | cut -c1-60)"
done
[[ "$(df --output=avail -B1M / | tail -1)" -gt 1500 ]] || { say "STOP: disk under 1.5 G"; exit 1; }
say "start the ONE full 06"
bash $D/live-p1/06_thirteen.sh > "$L/06_thirteen_full.log" 2>&1
say "full 06 rc=$?  $(tail -1 "$L/06_thirteen_full.log")"
git diff -- p4_proxy/mininet/host_count_override > "$L/knob-after.diff"
cmp -s "$L/knob-before.diff" "$L/knob-after.diff" && say "knob unchanged" || say "knob CHANGED"
env PYTHONDONTWRITEBYTECODE=1 p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests > "$L/p4_exercise-after.log" 2>&1
say "p4_exercise rc=$?  $(grep -E '^(OK|FAILED)' "$L/p4_exercise-after.log")"
say "DONE"
