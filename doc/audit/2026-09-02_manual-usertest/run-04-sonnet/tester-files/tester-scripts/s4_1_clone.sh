#!/bin/bash
LOG=~/logs/s4_1_clone.log
{
set -x
date +%H:%M
mkdir -p ~/Desktop
cd ~/Desktop
git clone https://github.com/ndtwin-lab/NDTwin-Kernel-P4-public.git NDTwin-Kernel
echo "CLONE_EXIT=$?"
cd ~/Desktop/NDTwin-Kernel
git log -1 --format="%H %ci"
git status
ls -la
date +%H:%M
} > "$LOG" 2>&1
echo SCRIPT_DONE
