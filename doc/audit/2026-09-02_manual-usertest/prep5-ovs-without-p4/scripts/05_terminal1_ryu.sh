#!/bin/bash
# A-8 step 2, Terminal 1: Ryu controller, in its own tmux session with a real pty.
# Manual (User Manual > NDTwin Kernel > Operate an Emulated (Software) Network > Native-Linux):
#     conda activate ryu-env
#     ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest \
#         --ofp-tcp-listen-port 6633 --observe-link
# DEVIATION (recorded): "conda activate" alone is 'command not found' on this guest -- conda was
# never `conda init`-ed into ~/.bashrc. We prepend the conda.sh source line. Nothing else changes.
# [Co-developed with claude code -- Adam]
R=~/Desktop/NDTwin-Kernel
mkdir -p ~/a8-logs
echo "=== A-8 TERMINAL 1 (Ryu)  $(date -u +%FT%TZ) ==="
echo "--- provenance of the two files the OVS path actually executes ---"
sha256sum "$R/intelligent_router.py" "$R/testbed_topo.py"
wc -l "$R/intelligent_router.py" "$R/testbed_topo.py"
echo "guest HEAD: $(git -C "$R" rev-parse HEAD)"
echo "NOTE: both files are modified relative to HEAD -- see 03_state_of_1to5.log for the full diff."
echo
echo "--- kill any stale session named T1 (there should be none) ---"
tmux has-session -t T1 2>/dev/null && { echo "T1 EXISTS ALREADY"; tmux kill-session -t T1; } || echo "no stale T1"
echo
echo "--- create tmux session T1 and start capturing the pane ---"
tmux new-session -d -s T1 -x 200 -y 50
tmux pipe-pane -o -t T1 "cat >> $HOME/a8-logs/T1_ryu_pane.log"
sleep 1
CMD='cd ~/Desktop/NDTwin-Kernel && source ~/miniconda3/etc/profile.d/conda.sh && conda activate ryu-env && ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link'
echo "SENDING: $CMD"
echo "T1_START_UTC=$(date -u +%FT%TZ)"
tmux send-keys -t T1 "$CMD" Enter
echo
echo "--- wait for Ryu to be listening on 6633 (poll up to 90 s) ---"
for i in $(seq 1 30); do
  sleep 3
  if ss -tlnH 'sport = :6633' | grep -q .; then echo "RYU_LISTENING_AFTER=$((i*3))s"; break; fi
done
echo "--- ss :6633 ---"; ss -tlnpH 'sport = :6633' 2>&1
echo "--- ss :8080 (ryu REST) ---"; ss -tlnpH 'sport = :8080' 2>&1
echo
echo "--- tmux session list ---"; tmux ls
echo "--- pane snapshot (capture-pane -p) ---"
tmux capture-pane -p -t T1 -S -60
echo
echo "--- ryu process, found WITHOUT pgrep -f (project rule) ---"
for p in /proc/[0-9]*; do
  c=$(cat "$p/comm" 2>/dev/null) || continue
  case "$c" in ryu-manager|python*) 
      cl=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
      case "$cl" in *ryu-manager*) echo "PID=${p#/proc/} COMM=$c CMD=$cl";; esac;;
  esac
done
echo "T1_SCRIPT_EXIT=0"
