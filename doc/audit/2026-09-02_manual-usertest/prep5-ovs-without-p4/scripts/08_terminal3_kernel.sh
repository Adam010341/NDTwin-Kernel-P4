#!/bin/bash
# A-8 step 2, Terminal 3: the NDTwin Kernel, own tmux session, real pty.
# Manual, verbatim:
#   cd ~/Desktop/NDTwin-Kernel/build
#   sudo bin/ndtwin_kernel --mode mininet \
#       --topology ../setting/StaticNetworkTopologyMininet_10Switches.json \
#       --no-ai --loglevel info
# No deviation.
# [Co-developed with claude code -- Adam]
echo "=== A-8 TERMINAL 3 (NDTwin Kernel)  $(date -u +%FT%TZ) ==="
tmux has-session -t T3 2>/dev/null && { echo "T3 EXISTS"; tmux kill-session -t T3; } || echo "no stale T3"
tmux new-session -d -s T3 -x 220 -y 50
tmux pipe-pane -o -t T3 "cat >> $HOME/a8-logs/T3_kernel_pane.log"
sleep 1
CMD='cd ~/Desktop/NDTwin-Kernel/build && sudo bin/ndtwin_kernel --mode mininet --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --no-ai --loglevel info'
echo "SENDING: $CMD"
echo "T3_START_UTC=$(date -u +%FT%TZ)"
tmux send-keys -t T3 "$CMD" Enter

echo
echo "--- poll for the kernel's own convergence line (up to 300 s) ---"
S=$(date +%s)
for i in $(seq 1 60); do
  sleep 5
  if grep -qiE 'topology from the control plane' "$HOME/a8-logs/T3_kernel_pane.log" 2>/dev/null; then
    echo "KERNEL_CONVERGENCE_AFTER=$(( $(date +%s) - S ))s"; break
  fi
done
echo
echo "########## THE LINE ITSELF (this is the claim under test) ##########"
grep -ihE 'topology from the control plane' "$HOME/a8-logs/T3_kernel_pane.log" 2>/dev/null | tail -5 || echo "NOT FOUND"
echo "########## end ##########"
echo
echo "--- kernel listening on :8000 ? ---"
for i in $(seq 1 20); do ss -tlnH 'sport = :8000' | grep -q . && break; sleep 3; done
ss -tlnpH 'sport = :8000' 2>&1
echo
echo "--- any error/warn lines mentioning p4 / bmv2 / grpc / proxy / 8081 / 50051 ---"
grep -inE 'p4|bmv2|grpc|proxy|8081|5005[0-9]' "$HOME/a8-logs/T3_kernel_pane.log" 2>/dev/null | head -30 || echo "NONE -- the kernel never mentions P4/BMv2/proxy on this path"
echo "(end grep)"
echo
echo "--- error / critical lines in the kernel log so far ---"
grep -icE '\[error\]|\[critical\]' "$HOME/a8-logs/T3_kernel_pane.log" 2>/dev/null | sed 's/^/error+critical line count: /'
grep -ihE '\[error\]|\[critical\]' "$HOME/a8-logs/T3_kernel_pane.log" 2>/dev/null | head -20
echo "(end)"
echo
echo "--- pane snapshot, last 45 lines ---"
tmux capture-pane -p -t T3 -S -45
echo
echo "--- all three tmux sessions still alive? ---"
tmux ls
echo "T3_SCRIPT_EXIT=0"
