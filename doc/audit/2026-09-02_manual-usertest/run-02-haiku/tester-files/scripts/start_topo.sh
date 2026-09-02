#!/bin/bash
cd ~/Desktop/NDTwin-Kernel
echo "Starting Mininet topology at $(date)" >> ~/logs/topo.log
sudo python3 testbed_topo.py 2>&1 | tee -a ~/logs/topo.log
