#!/bin/bash
source ~/miniconda3/etc/profile.d/conda.sh
conda activate ryu-env
cd ~/Desktop/NDTwin-Kernel
echo "Starting Ryu controller at $(date)" >> ~/logs/ryu.log
ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link 2>&1 | tee -a ~/logs/ryu.log
