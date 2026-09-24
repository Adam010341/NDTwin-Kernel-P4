#!/usr/bin/env bash
# live-0925-ecn-rerun.sh -- the one 06 arm that was not as expected (ecn solution, FAIL 1/4: h2 got 2
# packets, both tos 0x1). Three ONLY=ecn re-runs on the same merged trunk, to tell a chance outcome
# (few probe packets, marking only when enq_qdepth >= 10) from a deterministic change.
# [Co-developed with claude code -- Adam]
set -u
G=/home/adam/Desktop/NDTwin-Kernel; L=$G/scratch/overnight-2026-09-05/logs/orchestrator-0924/live-0925
cd "$G" || exit 9; export NDT_OWNER=orch-0924
for i in 1 2 3; do
    echo "== $(date '+%T') ecn re-run $i (trunk $(git rev-parse --short HEAD))"
    ONLY=ecn bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/06_thirteen.sh > "$L/06_ecn_rerun$i.log" 2>&1
    echo "   rc=$?  $(tail -1 "$L/06_ecn_rerun$i.log")"
    grep -E "^   ecn " "$L/06_ecn_rerun$i.log" | cut -c1-70
done
env PYTHONDONTWRITEBYTECODE=1 p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests > "$L/p4_exercise-after-ecn.log" 2>&1
echo "== p4_exercise rc=$?  $(grep -E '^(OK|FAILED)' "$L/p4_exercise-after-ecn.log")"
echo "== DONE"
