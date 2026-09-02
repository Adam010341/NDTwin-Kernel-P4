#!/bin/bash
echo "=== run the helper subcommand ndt uses, directly ==="
cd ~/Desktop/NDTwin-Kernel
sudo /usr/local/sbin/ndtwin-lab ovs-topo-start 2>&1 | head -25
echo "HELPER_EXIT=$?"
sleep 20
echo "--- status per the helper ---"
sudo /usr/local/sbin/ndtwin-lab status 2>&1 | head -15
echo "--- topo-out (its own output tail) ---"
sudo /usr/local/sbin/ndtwin-lab topo-out 40 2>&1 | tail -30
echo "--- bridges / procs ---"
sudo ovs-vsctl list-br | tr '\n' ' '; echo
ps -eo args= | grep -c '[m]ininet:'
echo "--- root tmux ---"
sudo tmux ls 2>&1 | head -5
date +%H:%M:%S
