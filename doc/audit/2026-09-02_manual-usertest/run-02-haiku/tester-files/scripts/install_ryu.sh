#!/bin/bash
set -e
source ~/miniconda3/etc/profile.d/conda.sh
conda activate ryu-env

echo "=== Installing build dependencies ==="
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y build-essential python3-dev libssl-dev libffi-dev libxml2-dev libxslt1-dev

echo "=== Upgrading pip/setuptools/wheel ==="
pip install --upgrade "pip<24" "setuptools<68" wheel

echo "=== Installing Ryu ==="
pip install ryu

echo "=== Installing Ryu dependencies ==="
pip install eventlet==0.30.2
pip install "greenlet<3"
pip install "dnspython<2.3"

echo "=== Verifying installation ==="
pip list | grep -E "eventlet|greenlet|dnspython|ryu"

echo "=== Testing Ryu installation ==="
timeout 5 ryu-manager ryu.app.simple_switch_13 || true

echo "=== Installing additional libraries ==="
pip install -U networkx
pip install -U "requests<2.29" "urllib3<2"

echo "=== Ryu installation complete ==="
conda deactivate
