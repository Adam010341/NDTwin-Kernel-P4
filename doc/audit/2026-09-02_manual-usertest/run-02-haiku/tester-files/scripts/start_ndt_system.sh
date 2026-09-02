#!/bin/bash
export PATH="/home/ndt/.local/bin:$PATH"
cd ~/Desktop/NDTwin-Kernel

echo "=== Starting NDTwin OVS Fabric with ndt launcher ===" >> ~/logs/ndt_system.log
echo "Time: $(date)" >> ~/logs/ndt_system.log

~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up ovs 2>&1 | tee -a ~/logs/ndt_system.log

echo "Fabric startup complete at $(date)" >> ~/logs/ndt_system.log
