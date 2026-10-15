#!/usr/bin/env bash
# s0_run.sh <clone> : one offline S0 at the clone's head under setsid --wait, with proc_scan.py before, during (its
# parent chains, every 0.1 s) and after. Kills nothing itself. [Co-developed with claude code -- Adam]
W="$1"; L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r2; RUN=$L/s0-run; S=$L/proc_scan.py
cd "$W" || exit 99
out=$L/s0.log
rm -rf "$RUN"
{ echo "commit $(git rev-parse HEAD)"; echo "cwd $W  tracked-dirty=$(git status --porcelain --untracked-files=no | wc -l)  df_free_mb=$(df -m / | awk 'NR==2{print $4}')  LANG=${LANG:-}  command: P4_HEALTH_RUN_DIR=$RUN setsid --wait tools/p4_health/run.sh s0"; echo "p4c $(command -v p4c-bm2-ss): $(p4c-bm2-ss --version 2>&1 | tr '\n' ' ')"; echo "p4 build: $(sha256sum p4_proxy/p4_src/build/ndtwin_switch.json | cut -c1-64) ndtwin_switch.json  $(sha256sum p4_proxy/p4_src/build/ndtwin_switch.p4info.txt | cut -c1-64) ndtwin_switch.p4info.txt"; } > "$out"
python3 "$S" pre "$L/s0_prescan.log"
P4_HEALTH_RUN_DIR=$RUN setsid --wait tools/p4_health/run.sh s0 >> "$out" 2>&1 &
SPID=$!
python3 "$S" watch "$L/s0_procs.log" "$SPID" "$RUN" &
WPID=$!
wait "$SPID"; rc=$?
wait "$WPID"
python3 "$S" post "$L/s0_postscan.log" "$RUN" "$L/s0_procs.log"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("S0 verdict (s0-run/s0.json):", d.get("verdict"))' "$RUN/s0.json" >> "$out" 2>&1
echo "rc=$rc" >> "$out"
exit $rc
