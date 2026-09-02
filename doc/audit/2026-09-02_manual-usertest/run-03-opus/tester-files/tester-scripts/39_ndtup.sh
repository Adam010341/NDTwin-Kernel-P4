#!/bin/bash
echo "NDTUP_START $(date +%H:%M:%S)"
tmux kill-session -t UP 2>/dev/null
tmux new-session -d -s UP -x 210 -y 60
tmux send-keys -t UP 'ndt up ovs; echo "NDT_UP_EXIT=$?"' Enter
