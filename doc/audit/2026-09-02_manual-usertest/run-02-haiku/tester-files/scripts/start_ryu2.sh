#!/bin/bash
export PATH="/home/ndt/miniconda3/envs/ryu-env/bin:$PATH"
cd ~/Desktop/NDTwin-Kernel
echo "Starting Ryu controller at $(date)" >> ~/logs/ryu.log
/home/ndt/miniconda3/envs/ryu-env/bin/python -m ryu.cmd.manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link 2>&1 | tee -a ~/logs/ryu.log
