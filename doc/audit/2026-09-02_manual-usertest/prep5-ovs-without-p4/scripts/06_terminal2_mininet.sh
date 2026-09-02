#!/bin/bash
# A-8 step 2, Terminal 2: Mininet topology, own tmux session, real pty (the CLI needs one).
# Manual, verbatim:
#     # Start the custom topology script
#     sudo python3 testbed_topo.py
# No deviation on this line.
# [Co-developed with claude code -- Adam]
echo "=== A-8 TERMINAL 2 (Mininet)  $(date -u +%FT%TZ) ==="
tmux has-session -t T2 2>/dev/null && { echo "T2 EXISTS"; tmux kill-session -t T2; } || echo "no stale T2"
tmux new-session -d -s T2 -x 200 -y 50
tmux pipe-pane -o -t T2 "cat >> $HOME/a8-logs/T2_mininet_pane.log"
sleep 1
CMD='cd ~/Desktop/NDTwin-Kernel && sudo python3 testbed_topo.py'
echo "SENDING (manual verbatim, prefixed only with the cd the manual's pre-flight assumes): $CMD"
echo "T2_START_UTC=$(date -u +%FT%TZ)  T2_START_EPOCH=$(date +%s)"
tmux send-keys -t T2 "$CMD" Enter

echo
echo "--- poll for the manual's convergence message: \"all-destination paths installed\" ---"
S=$(date +%s)
FOUND=0
for i in $(seq 1 60); do
  sleep 5
  if grep -qi 'all-destination paths installed' "$HOME/a8-logs/T2_mininet_pane.log" 2>/dev/null; then
    FOUND=1; echo "CONVERGENCE_MSG_SEEN_AFTER=$(( $(date +%s) - S ))s"; break
  fi
  if grep -qi 'all-destination paths installed' "$HOME/a8-logs/T1_ryu_pane.log" 2>/dev/null; then
    FOUND=2; echo "CONVERGENCE_MSG_SEEN_IN_T1_AFTER=$(( $(date +%s) - S ))s"; break
  fi
done
echo "CONVERGENCE_MSG_FOUND=$FOUND  (0 = never seen within 300 s)"
echo "--- the line itself, wherever it landed ---"
grep -ih 'all-destination paths installed\|install_all_pair_paths done' "$HOME/a8-logs/T2_mininet_pane.log" "$HOME/a8-logs/T1_ryu_pane.log" 2>/dev/null | tail -5
echo
echo "--- mininet prompt reached? pane snapshot ---"
tmux capture-pane -p -t T2 -S -40
echo
echo "--- switches registered in OVS ---"
sudo -n ovs-vsctl list-br 2>&1
echo "BRIDGE_COUNT=$(sudo -n ovs-vsctl list-br 2>/dev/null | wc -l)"
echo
echo "T2_SCRIPT_EXIT=0"
