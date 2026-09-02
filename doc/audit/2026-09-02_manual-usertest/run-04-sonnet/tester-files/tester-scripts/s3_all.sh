#!/bin/bash
exec > ~/logs/s3_all.log 2>&1
set -x
date +%H:%M
source ~/miniconda3/etc/profile.d/conda.sh
conda deactivate
python3 --version

echo "=== Step 3.1 ==="
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y build-essential cmake g++ make git \
    ninja-build xterm curl wireshark iperf3

echo "=== Step 3.2 ==="
sudo apt install -y \
    libboost-all-dev \
    libfmt-dev \
    libspdlog-dev \
    libssh-dev \
    nlohmann-json3-dev \
    python3-venv \
    mininet \
    openvswitch-switch

echo "=== Step 3.3 ==="
sudo systemctl is-active openvswitch-switch
sudo ovs-vsctl show
sudo mn --test pingall

date +%H:%M
echo SECTION_3_DONE
