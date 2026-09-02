#!/bin/bash
echo "=== stop NSR the documented Option 2 way (Ctrl+C in its own terminal) ==="
tmux send-keys -t NSR C-c
sleep 4
tmux capture-pane -t NSR -p | grep -v '^$' | tail -5
pgrep -af network_state_recorder.py || echo "   (stopped)"
echo
echo "########## B03: ndt status with the whole stack running ##########"
~/.local/bin/ndt status 2>&1
echo
echo "########## B03b: ndt status --check ##########"
~/.local/bin/ndt status --check 2>&1 | tail -20
echo "STATUS_CHECK_EXIT=$?"
echo
echo "########## B05: ndt check ##########"
~/.local/bin/ndt check 2>&1 | tail -25
echo "CHECK_EXIT=$?"
date +%H:%M:%S
