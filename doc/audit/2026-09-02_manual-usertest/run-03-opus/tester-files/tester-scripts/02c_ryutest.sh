#!/bin/bash
date +%H:%M
which tmux || sudo DEBIAN_FRONTEND=noninteractive apt install -y tmux >/dev/null 2>&1
which tmux
echo "=== Step 2.5: Test Ryu in tmux session RYUTEST ==="
tmux kill-session -t RYUTEST 2>/dev/null
tmux new-session -d -s RYUTEST
tmux send-keys -t RYUTEST 'source ~/miniconda3/etc/profile.d/conda.sh && conda activate ryu-env && ryu-manager ryu.app.simple_switch_13' Enter
sleep 12
echo "--- capture-pane ---"
tmux capture-pane -t RYUTEST -p
