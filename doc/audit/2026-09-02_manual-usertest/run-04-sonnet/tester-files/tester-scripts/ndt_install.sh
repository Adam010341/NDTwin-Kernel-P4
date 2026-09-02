#!/bin/bash
LOG=~/logs/ndt_install.log
{
set -x
date +%H:%M
cd ~/Desktop/NDTwin-Kernel

mkdir -p ~/.local/bin
ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt
ls -l ~/.local/bin/ndt

sudo install -o root -g root -m 755 \
    tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
ls -l /usr/local/sbin/ndtwin-lab

echo "$USER ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-lab" \
    | sudo tee /etc/sudoers.d/ndtwin-lab
sudo cat /etc/sudoers.d/ndtwin-lab

date +%H:%M
echo NDT_INSTALL_DONE
} > "$LOG" 2>&1
cat "$LOG"
