#!/usr/bin/env bash
# tutorials-ecn-0925.sh -- Adam 09-25 (grill Q8): re-run REPORT-P3 appendix A's ecn control arms on the
# tutorials fabric with the ruling-7 driver (60 probes). Same command shape as tutorials-18.sh.
# [Co-developed with claude code -- Adam]
set -u
MC=/home/adam/Desktop/NDTwin-Kernel
L=$MC/scratch/overnight-2026-09-05/logs/orchestrator-0924/tutorials-ecn-0925
N=$MC/tools/test_workflow/ndt
PY=/home/adam/p4dev-python-venv/bin/python
DRV=$MC/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py
export NDT_OWNER=orch-0924
mkdir -p "$L"
{
  echo "start $(date -Is)  trunk $(git -C $MC rev-parse --short HEAD)"
  echo "driver blob $(git -C $MC hash-object $DRV)  committed-blob $(git -C $MC rev-parse HEAD:doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py)"
  echo "driver dirty: $(git -C $MC status --porcelain -- $DRV | wc -l)"
  df -h / | tail -1
} > $L/_header.txt
$N claim 20 "tutorials ecn control arms, ruling-7 driver (REPORT-P3 appendix A)" > $L/_claim.txt 2>&1 || { echo "claim failed" >> $L/_header.txt; exit 3; }
for which in skeleton solution; do
  t0=$(date +%s)
  sudo -n $PY $DRV ecn --which $which > $L/ecn_${which}.log 2>&1; rc=$?
  printf '%-13s %-9s rc=%s  %ss  %s\n' ecn $which $rc $(( $(date +%s)-t0 )) "$(grep -E '^>>> (PASS|RED ARM|FAIL|ERROR)' $L/ecn_${which}.log | tail -1)" >> $L/_summary.txt
done
echo "end $(date -Is)" >> $L/_header.txt
$N release >> $L/_claim.txt 2>&1; echo "release rc=$?" >> $L/_claim.txt
env PYTHONDONTWRITEBYTECODE=1 $MC/p4_proxy/venv/bin/python -m unittest discover -s $MC/tools/p4_exercise/tests -t $MC/tools/p4_exercise/tests > $L/p4_exercise-after.log 2>&1
echo "p4_exercise rc=$? $(grep -E '^(OK|FAILED)' $L/p4_exercise-after.log)" >> $L/_summary.txt
echo DONE >> $L/_summary.txt
