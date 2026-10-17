#!/usr/bin/env bash
# trial_run.sh <clone> <tag> : the Cut C trial under setsid --wait, with proc_scan.py before, during and after.
# Copied from merged-trunk-1015/trial_run.sh; only L changed (this directory). [Co-developed with claude code -- Adam]
# Kills nothing itself; trial.py stops only the switches it started, by their pids. [Co-developed with claude code -- Adam]
W="$1"; T="$2"; L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-journal-r5-tests; S=$L/proc_scan.py; WORK=$L/trial-work-$T
cd "$W" || exit 99
rm -rf "$WORK"
out=$L/trial-$T.log
{ echo "commit $(git rev-parse HEAD)"; echo "cwd $W  tracked-dirty=$(git status --porcelain --untracked-files=no | wc -l)  df_free_mb=$(df -m / | awk 'NR==2{print $4}')  command: setsid --wait p4_proxy/venv/bin/python $L/trial.py $W $WORK $L/trial-$T.json"; echo "interpreter $(realpath p4_proxy/venv/bin/python): $(p4_proxy/venv/bin/python --version 2>&1)"; echo "p4c $(command -v p4c-bm2-ss): $(p4c-bm2-ss --version 2>&1 | tr '\n' ' ')"; echo "p4 build: $(sha256sum p4_proxy/p4_src/build/ndtwin_switch.json | cut -c1-64) ndtwin_switch.json  $(sha256sum p4_proxy/p4_src/build/ndtwin_switch.p4info.txt | cut -c1-64) ndtwin_switch.p4info.txt"; } > "$out"
python3 "$S" pre "$L/trial-${T}_prescan.log"
PYTHONDONTWRITEBYTECODE=1 setsid --wait nice -n 19 p4_proxy/venv/bin/python $L/trial.py "$W" "$WORK" $L/trial-$T.json >> "$out" 2>&1 &
SPID=$!
python3 "$S" watch "$L/trial-${T}_procs.log" "$SPID" "$WORK" &
WPID=$!
wait "$SPID"; rc=$?
wait "$WPID"
python3 "$S" post "$L/trial-${T}_postscan.log" "$WORK" "$L/trial-${T}_procs.log"
echo "rc=$rc" >> "$out"
exit $rc
