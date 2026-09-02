#!/bin/bash
date +%H:%M
echo "=== Step 4.1: clone. Manual: 'If you are not sure, clone the P4 one.' ==="
mkdir -p ~/Desktop
cd ~/Desktop
git clone https://github.com/ndtwin-lab/NDTwin-Kernel-P4-public.git NDTwin-Kernel
echo "EXIT=$?"
cd ~/Desktop/NDTwin-Kernel && git log -1 --format='%H %ci %s'
echo "=== Step 2.6.1: ls -l intelligent_router.py ==="
ls -l intelligent_router.py
echo "=== Step 5: ls -l testbed_topo.py ==="
ls -l testbed_topo.py
echo "=== Step 6.0: ls p4_proxy/p4_src/ndtwin_switch.p4 ==="
ls p4_proxy/p4_src/ndtwin_switch.p4
echo "=== top-level listing ==="
ls
echo "=== setting/ ==="
ls setting/
date +%H:%M
