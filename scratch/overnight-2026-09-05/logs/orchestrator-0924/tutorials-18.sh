#!/usr/bin/env bash
# REPORT-P3 §1② / phase-4 goal (7): tutorials control arms, 9 exercises x {skeleton, solution}.
# Commands are P3-D-SUMMARY §7.1 verbatim (absolute driver path = the sudoers grant).
# [Co-developed with claude code -- Adam]
set -u
MC=/home/adam/Desktop/NDTwin-Kernel
L=$MC/scratch/overnight-2026-09-05/logs/orchestrator-0924/tutorials-18
N=$MC/tools/test_workflow/ndt
PY=/home/adam/p4dev-python-venv/bin/python
DRV=$MC/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py
export NDT_OWNER=orch-0924
{
  echo "start $(date -Is)  trunk $(git -C $MC rev-parse --short HEAD)"
  echo "driver blob $(git -C $MC hash-object $DRV)  committed-blob $(git -C $MC rev-parse HEAD:doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py)"
  echo "driver dirty: $(git -C $MC status --porcelain -- $DRV | wc -l)"
  df -h / | tail -1
} > $L/_header.txt
$N claim 150 "tutorials control 18 arms (REPORT-P3 §1②, phase-4 goal 7)" > $L/_claim.txt 2>&1 || { echo "claim failed" >> $L/_header.txt; exit 3; }
for ex in basic_tunnel calc ecn mri flowcache load_balance multicast p4runtime qos; do
  for which in skeleton solution; do
    t0=$(date +%s)
    sudo -n $PY $DRV $ex --which $which > $L/${ex}_${which}.log 2>&1; rc=$?
    printf '%-13s %-9s rc=%s  %ss  %s\n' $ex $which $rc $(( $(date +%s)-t0 )) "$(grep -E '^(PASS|RED ARM|FAIL|ERROR)' $L/${ex}_${which}.log | tail -1)" >> $L/_summary.txt
  done
done
echo "end $(date -Is)" >> $L/_header.txt
$N release >> $L/_claim.txt 2>&1
echo DONE >> $L/_summary.txt
