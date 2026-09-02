#!/bin/bash
# Step 6.0 check + Step 6.1 kickoff (tmux, detached, per the manual's own recommended form)
LOG=~/logs/s6_0_check.log
{
set -x
date +%H:%M
cd ~/Desktop/NDTwin-Kernel
ls p4_proxy/p4_src/ndtwin_switch.p4
echo "S6_0_EXIT=$?"
} > "$LOG" 2>&1
cat "$LOG"

# Step 6.1: leave ryu-env check (should already be inactive in a fresh shell, but confirm)
source ~/miniconda3/etc/profile.d/conda.sh 2>/dev/null
conda deactivate 2>/dev/null
python3 --version > ~/logs/s6_1_pyversion.log 2>&1
cat ~/logs/s6_1_pyversion.log

cd ~
git clone https://github.com/jafingerhut/p4-guide 2> ~/logs/s6_1_clone.log
tail -5 ~/logs/s6_1_clone.log

tmux new-session -d -s p4 \
  'cd ~ && ./p4-guide/bin/install-p4dev-v8.sh 2>&1 | tee log.txt; \
   echo "SCRIPT_EXIT=${PIPESTATUS[0]}" >> log.txt'
sleep 2
tmux ls
date +%H:%M > ~/logs/s6_1_kickoff_time.log
cat ~/logs/s6_1_kickoff_time.log
echo P4_KICKOFF_DONE
