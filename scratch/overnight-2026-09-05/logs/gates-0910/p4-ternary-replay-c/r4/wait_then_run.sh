#!/usr/bin/env bash
# wait_then_run.sh : poll every 5 minutes until no mutate_*/probe.py/simple_switch process of anybody is running (and still none 5 s later), then run, in order, with
# the SigBlk line logged before each: the table-journal mutation gate at the final head, the trial at the final head, and the sequence-only trial at the code before the fix.
# [Co-developed with claude code -- Adam]
G=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c; E=$G/r4
C=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/c-replay
busy() { ps -eo pid,cmd | grep -E 'mutate_|probe\.py|simple_switch' | grep -v grep | grep -v "wait_then_run.sh"; }
quiet() {
  while true; do
    if [[ -z "$(busy)" ]]; then sleep 5; [[ -z "$(busy)" ]] && return; fi
    echo "$(date +%T) busy: $(busy | wc -l) process(es), first: $(busy | head -1 | cut -c1-160)"
    sleep 300
  done
}
step() {   # step <name> <dir> <cmd...>
  local name="$1" dir="$2"; shift 2
  quiet
  echo "$(date +%T) quiet; launching $name"
  grep SigBlk /proc/$$/status | sed "s/^/$name: /"
  echo "$(ps -eo pid,cmd | grep -E 'mutate_|probe\.py|simple_switch' | grep -v grep | grep -v wait_then_run | wc -l) matching processes at launch"
  ( cd "$dir" && "$@" ); echo "$(date +%T) $name rc=$?"
}
step mutate_table_journal "$C/final" bash $E/runlog.sh $E/mutate_table_journal.log bash tests/shell/mutate_table_journal.sh
step trial_final "$C/final" bash $E/trial_run.sh $C/final r4
step trial_red_before_fix "$C/pre" env TRIAL_ONLY_M1=1 bash $E/trial_run.sh $C/pre r4red
echo "$(date +%T) all done"
touch $E/wait.done
