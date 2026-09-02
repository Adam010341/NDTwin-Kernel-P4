#!/bin/bash
echo "=== the named tmux socket the helper says to attach to ==="
sudo tmux -L ndtwinlab ls 2>&1
echo "--- start it again and look within 2 seconds ---"
cd ~/Desktop/NDTwin-Kernel
sudo /usr/local/sbin/ndtwin-lab ovs-topo-start 2>&1
sleep 2
echo "--- immediately after: ---"
sudo tmux -L ndtwinlab ls 2>&1
sudo /usr/local/sbin/ndtwin-lab topo-out 60 2>&1 | tail -35
echo "--- 15s later ---"
sleep 15
sudo tmux -L ndtwinlab ls 2>&1
sudo /usr/local/sbin/ndtwin-lab topo-out 60 2>&1 | tail -25
echo "--- is python3 mininet reachable as root at all? sanity check ---"
sudo python3 -c "import mininet; print('mininet importable as root:', mininet.__file__)" 2>&1
date +%H:%M:%S
