#!/bin/bash
echo "T3_START $(date +%H:%M:%S)"
tmux kill-session -t KERNEL 2>/dev/null
tmux new-session -d -s KERNEL -x 200 -y 50
tmux send-keys -t KERNEL 'cd ~/Desktop/NDTwin-Kernel/build && sudo bin/ndtwin_kernel --mode mininet --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --no-ai --loglevel info' Enter
sleep 30
echo "--- pane (head of startup) ---"
tmux capture-pane -t KERNEL -p -S -400 | head -40
echo "--- pane (tail) ---"
tmux capture-pane -t KERNEL -p | tail -12
echo "--- is :8000 listening? ---"
ss -lntp 2>/dev/null | grep -E ':8000' || echo "(nothing on 8000)"
echo "T3_30S $(date +%H:%M:%S)"
