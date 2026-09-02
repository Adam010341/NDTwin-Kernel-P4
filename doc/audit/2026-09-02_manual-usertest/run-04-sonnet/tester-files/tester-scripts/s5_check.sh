#!/bin/bash
LOG=~/logs/s5_check.log
{
set -x
date +%H:%M
cd ~/Desktop/NDTwin-Kernel
ls -l testbed_topo.py
date +%H:%M
echo S5_CHECK_DONE
} > "$LOG" 2>&1
cat "$LOG"
