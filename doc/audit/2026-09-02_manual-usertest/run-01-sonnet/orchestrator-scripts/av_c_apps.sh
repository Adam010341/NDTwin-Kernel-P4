#!/bin/bash
# auditor 4(c): `ndt apps sim|energy|nsr` once each, with tmux + process evidence before/after, plus the exact
# sim-start tmux command with its pane kept alive. Run as ndt: bash /tmp/av_c_apps.sh
# [Co-developed with claude code -- Adam]
set -u
OUT=$HOME/auditor-verification; mkdir -p "$OUT"; cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
N=$HOME/.local/bin/ndt; T="sudo -n tmux -L ndtwinlab"
snap() { echo "--- $1 ---"; $T ls 2>&1; echo "pids/: $(ls .test_run/pids 2>/dev/null | tr '\n' ' ')"
  for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null); case "$c" in *simulation_platform_manager*|*energy_saving_app*|*network_state_recorder*) echo "${p#/proc/} $c";; esac; done; }
for a in sim energy nsr; do
  { snap "before $a"; echo "### ndt apps $a  $(date -u +%T)"; timeout 60 "$N" apps "$a" < /dev/null 2>&1; echo "rc=$?"; sleep 3; snap "after $a (3s)"
    echo "### pane"; $T capture-pane -t "$a" -p -S -30 2>&1 | tail -15; echo "### .test_run/logs/app_$a.log"; tail -10 ".test_run/logs/app_$a.log" 2>&1
  } > "$OUT/c_$a.txt" 2>&1
done
$T kill-session -t sim 2>/dev/null
$T new-session -d -s sim -c /home/adam/Simulation-Platform-Manager "./simulation_platform_manager; echo EXIT=\$?; sleep 60" > "$OUT/c_sim_pane_repro.txt" 2>&1; echo "tmux new-session rc=$?" >> "$OUT/c_sim_pane_repro.txt"
sleep 2; $T capture-pane -t sim -p -S -20 >> "$OUT/c_sim_pane_repro.txt" 2>&1; $T kill-session -t sim 2>/dev/null
timeout 60 "$N" apps stop all < /dev/null > "$OUT/c_stop_all.txt" 2>&1; echo "rc=$?" >> "$OUT/c_stop_all.txt"
date -u +%FT%TZ > "$OUT/C_DONE"
