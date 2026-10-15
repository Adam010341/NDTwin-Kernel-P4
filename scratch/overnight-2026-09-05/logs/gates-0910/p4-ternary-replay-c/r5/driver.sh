#!/usr/bin/env bash
# driver.sh : the round-5 checks at the final head, one at a time, each behind guard.sh (it waits, polling every 60 s, until nothing
# mutate_*/probe.py/simple_switch of anybody is running). Each step's rc is read from the LAST LINE of its own log, never from $?.
# [Co-developed with claude code -- Adam]
E=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r5
C=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/c-replay
step() {   # step <name> <logfile> <dir> <cmd...>
  local name="$1" log="$2" dir="$3"; shift 3
  until bash $E/guard.sh $E/$name.guard.log; do echo "$(date +%T) $name: busy or masked, waiting (see $name.guard.log)"; sleep 60; done
  echo "$(date +%T) $name: launching"
  ( cd "$dir" && "$@" ) >/dev/null 2>&1
  echo "$(date +%T) $name: finished; last line of $(basename $log): $(tail -1 $log)"
}
cd $C/final
step two_test_files_whole $E/two_test_files_whole.log $C/final bash $E/runlog.sh $E/two_test_files_whole.log bash $E/unit.sh tests.test_table_entry_replay tests.test_table_entry_journal
step health_cells $E/p4_health_cells_tests.log $C/final bash $E/runlog.sh $E/p4_health_cells_tests.log p4_proxy/venv/bin/python -m unittest tests.python.test_p4_health_cells
step gate_anchors $E/gate_anchors.log $C/final bash $E/runlog.sh $E/gate_anchors.log p4_proxy/venv/bin/python tests/shell/check_gate_anchors.py HEAD
step mutate_table_journal $E/mutate_table_journal.log $C/final bash $E/runlog.sh $E/mutate_table_journal.log bash tests/shell/mutate_table_journal.sh
step trial_final $E/trial-r5.log $C/final bash $E/trial_run.sh $C/final r5
step trial_m2_red_at_7f69609b $E/trial-r5red.log $C/pre env TRIAL_ONLY_M2=1 bash $E/trial_run.sh $C/pre r5red
echo "$(date +%T) all done"
touch $E/driver.done
