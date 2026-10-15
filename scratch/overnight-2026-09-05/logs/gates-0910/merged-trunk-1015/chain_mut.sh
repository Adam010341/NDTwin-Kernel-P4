#!/usr/bin/env bash
# chain_mut.sh <clone> : the p4 health mutation gate's 4 shards, one at a time, in the gate clone, all in this one
# locale, then the shard sum (the way p4-health-ternary-d/r2 did). Each shard log: line 1 commit, line 2
# cwd/dirty/command, last line rc=N. Stops on low disk. [Co-developed with claude code -- Adam]
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1015; W="$1"
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/mg/tmp
mkdir -p "$TMPDIR"
cd "$W" || exit 99
echo "$(date -Is) chain start pid $$ locale LANG=${LANG:-} LC_ALL=${LC_ALL:-} LC_COLLATE=$(locale 2>/dev/null | sed -n 's/^LC_COLLATE=//p')" >> "$L/mut_driver.log"
for k in 0 1 2 3; do
  free=$(df -m / | awk 'NR==2{print $4}')
  if [ "$free" -lt 1800 ]; then echo "$(date -Is) shard $k NOT started: $free MB free" >> "$L/mut_driver.log"; exit 3; fi
  python3 "$L/procscan.py" "$L/mut_driver.log" || { echo "$(date -Is) shard $k NOT started: other mutate_/probe.py processes" >> "$L/mut_driver.log"; exit 4; }
  n=0
  until bash "$L/guard.sh" "$L/shard${k}.guard.log"; do
    grc=$?; [ "$grc" -eq 2 ] && { echo "$(date -Is) shard $k NOT started: a stop signal is blocked (shard${k}.guard.log)" >> "$L/mut_driver.log"; exit 5; }
    n=$((n+1)); [ "$n" -gt 120 ] && { echo "$(date -Is) shard $k NOT started: guard busy for 2 h (shard${k}.guard.log)" >> "$L/mut_driver.log"; exit 6; }
    sleep 60
  done
  log=$L/mutate_p4_health.shard${k}of4.log
  { echo "commit $(git rev-parse HEAD)"; echo "cwd $W  tracked-dirty=$(git status --porcelain --untracked-files=no | wc -l)  df_free_mb=$free  LANG=${LANG:-}  command: setsid --wait nice -n 19 timeout 21600 bash $L/shardwrap.sh $k  (=> exec env MUT_SHARD=$k/4 bash tests/shell/mutate_p4_health.sh)"; } > "$log"
  echo "$(date -Is) shard $k start" >> "$L/mut_driver.log"
  setsid --wait nice -n 19 timeout 21600 bash "$L/shardwrap.sh" "$k" >> "$log" 2>&1
  rc=$?; echo "rc=$rc" >> "$log"; echo "$(date -Is) shard $k rc=$rc" >> "$L/mut_driver.log"
  [ "$rc" -eq 0 ] || { echo "$(date -Is) chain stops at shard $k" >> "$L/mut_driver.log"; exit 1; }
done
c=$(git rev-parse HEAD)
{ echo "commit $c"; echo "cwd $W  command: bash tests/shell/sum_p4_health_gate_shards.sh --commit $c <4 shard logs>"; } > "$L/GATE.log"
bash tests/shell/sum_p4_health_gate_shards.sh --commit "$c" "$L"/mutate_p4_health.shard{0,1,2,3}of4.log >> "$L/GATE.log" 2>&1
rc=$?; echo "rc=$rc" >> "$L/GATE.log"; echo "$(date -Is) GATE sum rc=$rc" >> "$L/mut_driver.log"
exit $rc
