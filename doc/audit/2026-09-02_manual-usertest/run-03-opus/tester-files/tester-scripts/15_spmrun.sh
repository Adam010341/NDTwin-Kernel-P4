#!/bin/bash
echo "=== I09/I10: run the manager the way the User Manual says, with /mnt/nfs/sim ABSENT ==="
ls -ld /mnt/nfs/sim 2>&1
cd ~/Simulation-Platform-Manager
tmux kill-session -t SPM 2>/dev/null
tmux new-session -d -s SPM
tmux send-keys -t SPM 'cd ~/Simulation-Platform-Manager && sudo ./simulation_platform_manager' Enter
sleep 12
echo "--- pane ---"
tmux capture-pane -t SPM -p | tail -25
echo "--- is anything listening on 9000/8003? ---"
ss -lntp 2>/dev/null | grep -E ':9000|:8003' || echo "(nothing on 9000/8003)"
echo "--- mount table mentions nfs? ---"
mount | grep -i nfs || echo "(no nfs mounts)"
tmux send-keys -t SPM C-c
sleep 2
tmux kill-session -t SPM 2>/dev/null
date +%H:%M
