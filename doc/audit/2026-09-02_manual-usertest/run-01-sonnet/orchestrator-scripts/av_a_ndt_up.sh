#!/bin/bash
# auditor 4(a): reproduce BUG-004 deliberately inside the run-01 VM, keeping the root tmux pane alive.
# Run as ndt inside the guest: bash /tmp/av_a_ndt_up.sh   (outputs in ~/auditor-verification)
# [Co-developed with claude code -- Adam]
set -u
OUT=$HOME/auditor-verification; mkdir -p "$OUT"; cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
N=$HOME/.local/bin/ndt; LAB=/usr/local/sbin/ndtwin-lab; T="sudo -n tmux -L ndtwinlab"
{ echo "### $(date -u +%FT%TZ) sudo -n -l"; sudo -n -l 2>&1 | tail -3
  echo "### /home/adam"; ls -ld /home/adam 2>&1
  echo "### paths ndtwin-lab hardcodes"; for f in /home/adam/miniconda3/envs/ntg-env/bin/python /home/adam/Network-Traffic-Generator/testbed_topo.py /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/ntg_bmv2_topo.py /home/adam/Energy-Saving-App /home/adam/Simulation-Platform-Manager; do ls -ld "$f" 2>&1; done
  echo "### $LAB"; ls -la "$LAB"; sed -n '26,32p' "$LAB"
} > "$OUT/a0_env.txt" 2>&1
{ echo "### pre: root tmux"; $T ls 2>&1; echo "### pre: ndt status --check"; timeout 60 "$N" status --check < /dev/null 2>&1; echo "rc=$?"; } > "$OUT/a1_pre.txt" 2>&1
run_up() {  # $1 = ovs|p4, $2 = tag
  ( timeout 600 "$N" up "$1" < /dev/null > "$OUT/$2_ndt_up_$1.txt" 2>&1; echo "rc=$?" >> "$OUT/$2_ndt_up_$1.txt" ) & local up=$!
  for i in $(seq 1 45); do sleep 2
    if $T has-session -t topo 2>/dev/null; then echo "--- t+$((i*2))s ---" >> "$OUT/$2_topo_pane_during_$1.txt"; $T capture-pane -t topo -p -S -50 >> "$OUT/$2_topo_pane_during_$1.txt" 2>&1; fi
  done
  wait "$up"
  { echo "### post $1: root tmux"; $T ls 2>&1; echo "### topo-out"; sudo -n "$LAB" topo-out 50 2>&1; echo "### ndtwin-lab status"; sudo -n "$LAB" status 2>&1
    echo "### ndt status --check"; timeout 60 "$N" status --check < /dev/null 2>&1; echo "rc=$?"
    echo "### manifest"; ls -la /tmp/ndtwin_p4_switches.json 2>&1; head -c 600 /tmp/ndtwin_p4_switches.json 2>/dev/null; echo
    echo "### .test_run"; ls -la .test_run/pids .test_run/logs 2>&1; for f in .test_run/logs/*.log; do [ -f "$f" ] && { echo "-- $f"; tail -15 "$f"; }; done
  } > "$OUT/$2_post_$1.txt" 2>&1
}
run_up ovs a2
# the exact ovs-topo-start command, pane kept alive so its last words survive
$T kill-session -t topo 2>/dev/null
$T new-session -d -s topo -c /home/adam/Network-Traffic-Generator "/home/adam/miniconda3/envs/ntg-env/bin/python /home/adam/Network-Traffic-Generator/testbed_topo.py; echo EXIT=\$?; sleep 90" > "$OUT/a3_pane_repro_ovs.txt" 2>&1; echo "tmux new-session rc=$?" >> "$OUT/a3_pane_repro_ovs.txt"
sleep 3; $T capture-pane -t topo -p -S -50 >> "$OUT/a3_pane_repro_ovs.txt" 2>&1; $T kill-session -t topo 2>/dev/null
timeout 120 "$N" down < /dev/null > "$OUT/a4_ndt_down.txt" 2>&1; echo "rc=$?" >> "$OUT/a4_ndt_down.txt"
run_up p4 a5
$T kill-session -t topo 2>/dev/null
$T new-session -d -s topo -c "$HOME/Desktop/NDTwin-Kernel/p4_proxy/mininet" "/home/adam/miniconda3/envs/ntg-env/bin/python /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/ntg_bmv2_topo.py; echo EXIT=\$?; sleep 90" > "$OUT/a6_pane_repro_p4.txt" 2>&1; echo "tmux new-session rc=$?" >> "$OUT/a6_pane_repro_p4.txt"
sleep 3; $T capture-pane -t topo -p -S -50 >> "$OUT/a6_pane_repro_p4.txt" 2>&1; $T kill-session -t topo 2>/dev/null
timeout 120 "$N" down < /dev/null > "$OUT/a7_ndt_down2.txt" 2>&1; echo "rc=$?" >> "$OUT/a7_ndt_down2.txt"
date -u +%FT%TZ > "$OUT/A_DONE"
