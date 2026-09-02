#!/bin/bash
echo "=== is ryu listening? (before Ctrl-C) ==="
ss -lntp 2>/dev/null | grep -E "6653|8080" || echo "(nothing on 6653/8080)"
echo "=== send Ctrl-C as manual says ==="
tmux send-keys -t RYUTEST C-c
sleep 4
tmux capture-pane -t RYUTEST -p | tail -6
echo "=== after ==="
ss -lntp 2>/dev/null | grep -E "6653|8080" || echo "(nothing on 6653/8080 - stopped)"
tmux kill-session -t RYUTEST 2>/dev/null
echo "=== Step 2.6 says do Step 4.1 first. Is git present? ==="
which git || echo "NO GIT YET"
git --version 2>&1
