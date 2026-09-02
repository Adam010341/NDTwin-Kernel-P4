#!/bin/bash
echo "=== what logs did ndt/ndtwin-lab leave? ==="
ls -la ~/Desktop/NDTwin-Kernel/.test_run/logs/
echo "=== mode file ==="
cat ~/Desktop/NDTwin-Kernel/.test_run/mode
echo "=== pids dir ==="
ls -la ~/Desktop/NDTwin-Kernel/.test_run/pids/
echo
echo "=== is there a topology/ovs log anywhere? ==="
find ~/Desktop/NDTwin-Kernel/.test_run -type f | head -20
echo
echo "=== does ndtwin-lab use a tmux/screen session that died? ==="
tmux ls 2>&1
sudo tmux ls 2>&1 | head -5
echo
echo "=== try the helper by hand to see its error ==="
sudo /usr/local/sbin/ndtwin-lab 2>&1 | head -25
echo "HELPER_EXIT=$?"
date +%H:%M:%S
