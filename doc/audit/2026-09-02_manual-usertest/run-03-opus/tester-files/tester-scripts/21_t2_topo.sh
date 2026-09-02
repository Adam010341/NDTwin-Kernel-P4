#!/bin/bash
echo "T2_START $(date +%H:%M:%S)"
cd ~/Desktop/NDTwin-Kernel
tmux kill-session -t MN 2>/dev/null
tmux new-session -d -s MN -x 200 -y 50
tmux send-keys -t MN 'cd ~/Desktop/NDTwin-Kernel && sudo python3 testbed_topo.py' Enter
sleep 45
echo "--- pane after 45s (tail) ---"
tmux capture-pane -t MN -p | tail -18
echo "--- bandwidth-limit warning the manual predicts? ---"
tmux capture-pane -t MN -p -S -3000 | grep -c "Bandwidth limit 10000 is outside supported range"
echo "--- switches registered with OVS? ---"
sudo ovs-vsctl list-br | tr '\n' ' '; echo
echo "T2_45S $(date +%H:%M:%S)"
