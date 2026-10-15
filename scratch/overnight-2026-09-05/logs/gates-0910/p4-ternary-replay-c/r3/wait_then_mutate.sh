#!/usr/bin/env bash
# wait_then_mutate.sh <clone> : wait until no mutate_/probe.py process is running (checked every 2 seconds -- the other gate chains
# its runs with gaps of seconds -- and again 5 s after the first empty look, right before the start), then run tests/shell/mutate_table_journal.sh in the clone through runlog.sh.
# Never runs beside another gate. [Co-developed with claude code -- Adam]
E=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r3
cd "$1" || exit 2
n=0
while :; do
    others=$(ps -eo pid,cmd | grep -E 'mutate_|probe\.py' | grep -v grep | grep -v "wait_then_mutate")
    if [[ -z "$others" ]]; then
        echo "$(date -Is) nothing else running" >> $E/wait.log
        sleep 5
        others=$(ps -eo pid,cmd | grep -E 'mutate_|probe\.py' | grep -v grep | grep -v "wait_then_mutate")
        [[ -z "$others" ]] && break
    fi
    n=$((n+1)); [[ $((n % 150)) -eq 1 ]] && echo "$(date -Is) waiting: $(echo "$others" | wc -l) mutate_/probe.py processes, first: $(echo "$others" | head -1 | cut -c1-120)" >> $E/wait.log
    sleep 2
done
echo "$(date -Is) start mutate_table_journal in $PWD" >> $E/wait.log
bash $E/runlog.sh $E/mutate_table_journal.log bash tests/shell/mutate_table_journal.sh
echo "$(date -Is) end rc=$?" >> $E/wait.log
