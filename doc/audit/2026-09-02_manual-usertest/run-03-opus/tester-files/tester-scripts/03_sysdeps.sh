#!/bin/bash
date +%H:%M
echo "=== Section 3 preamble: leave ryu-env ==="
# I never activated it in this shell, so verify the manual's check directly
python3 --version
echo "=== Step 3.1 ==="
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y build-essential cmake g++ make git \
    ninja-build xterm curl wireshark iperf3
echo "STEP31_EXIT=$?"
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
echo "STEP32_EXIT=$?"
echo "=== Step 3.3 Verify Network Components ==="
echo "--- systemctl is-active openvswitch-switch ---"
sudo systemctl is-active openvswitch-switch
echo "--- ovs-vsctl show ---"
sudo ovs-vsctl show
echo "OVSSHOW_EXIT=$?"
echo "--- versions actually installed ---"
mn --version 2>&1
ovs-vsctl --version 2>&1 | head -1
cmake --version | head -1
ninja --version
dpkg -l libboost-dev 2>/dev/null | tail -1
date +%H:%M
