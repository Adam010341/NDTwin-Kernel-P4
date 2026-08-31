#!/usr/bin/env bash
# Runs M1..M13 one at a time. Stops immediately if a restore ever fails to put the
# worktree and the binary back to the 46/46 baseline -- because after that point no
# later verdict means anything.
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/258e9ef7-6035-4abb-b378-8b2ab1aa8200/scratchpad/mutrun

for i in $(seq ${START:-1} 13); do
  MID="M$i"
  echo "==================== $MID ====================" >> "$S/logs/DRIVER.log"
  bash "$S/run_one.sh" "$MID" >> "$S/logs/DRIVER.log" 2>&1
  rc=$?
  echo "RUNONE_RC $MID $rc" >> "$S/logs/DRIVER.log"
  echo "PROGRESS $MID rc=$rc" >> "$S/logs/PROGRESS"
  if [ "$rc" -ge 30 ]; then
    echo "HARNESS-STOP at $MID rc=$rc" >> "$S/logs/PROGRESS"
    break
  fi
done
echo "DRIVER-DONE" >> "$S/logs/PROGRESS"
