#!/bin/bash
LOG=~/logs/simplatform_install_part1.log
{
set -x
date +%H:%M
cd ~
git clone https://github.com/ndtwin-lab/Simulation-Platform-Manager.git
git clone https://github.com/ndtwin-lab/Energy-Saving-App.git

sudo apt install -y nlohmann-json3-dev libboost-all-dev libspdlog-dev libfmt-dev libssl-dev

echo "=== NFS server ==="
sudo apt update
sudo apt install -y nfs-kernel-server
sudo systemctl enable --now nfs-kernel-server
sudo mkdir -p /srv/nfs/sim
sudo chown nobody:nogroup /srv/nfs/sim
sudo chmod 777 /srv/nfs/sim
echo "/srv/nfs/sim localhost(rw,sync,no_subtree_check,all_squash)" | sudo tee -a /etc/exports
sudo systemctl restart nfs-kernel-server
cat /etc/exports

echo "=== NFS client ==="
sudo apt install -y nfs-common
sudo mkdir -p /mnt/nfs/sim
sudo mkdir -p /mnt/nfs/app

date +%H:%M
echo SIMPLATFORM_PART1_DONE
} > "$LOG" 2>&1
cat "$LOG"
