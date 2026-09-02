#!/bin/bash
date +%H:%M:%S
tmux new-session -d -s P4T1 "cd ~/Desktop/NDTwin-Kernel && sudo python3 p4_proxy/mininet/p4_testbed_topo.py"
sleep 3
tmux capture-pane -t P4T1 -p -S -20
