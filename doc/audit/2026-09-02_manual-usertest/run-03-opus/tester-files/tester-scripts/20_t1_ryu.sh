#!/bin/bash
date +%H:%M:%S
echo "=== load before starting (p4 toolchain is compiling in the background) ==="
uptime
echo "=== Terminal 1: Ryu Controller ==="
tmux kill-session -t RYU 2>/dev/null
tmux new-session -d -s RYU -x 200 -y 50
tmux send-keys -t RYU 'cd ~/Desktop/NDTwin-Kernel && conda activate ryu-env' Enter
sleep 2
tmux send-keys -t RYU 'source ~/miniconda3/etc/profile.d/conda.sh && conda activate ryu-env && python --version' Enter
sleep 3
tmux send-keys -t RYU 'ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link' Enter
sleep 20
echo "--- pane ---"
tmux capture-pane -t RYU -p | tail -30
echo "--- listening? (manual says Ryu listens on 6633; REST on 8080) ---"
ss -lntp 2>/dev/null | grep -E ':6633|:6653|:8080' || echo "(nothing yet)"
date +%H:%M:%S
