#!/bin/bash
date +%H:%M
echo "=== Step 2.2: Install System Build Dependencies ==="
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y build-essential python3-dev libssl-dev libffi-dev libxml2-dev libxslt1-dev
echo "=== enter ryu-env ==="
source ~/miniconda3/etc/profile.d/conda.sh
conda activate ryu-env
python --version
which pip
echo "=== Step 2.3.1 upgrade pip/setuptools/wheel ==="
pip install --upgrade "pip<24" "setuptools<68" wheel
echo "=== Step 2.3.2 install ryu ==="
pip install ryu
echo "=== Step 2.3.3 pins ==="
pip install eventlet==0.30.2
pip install "greenlet<3"
pip install "dnspython<2.3"
echo "=== Step 2.4 Verify ==="
pip list | grep -E "eventlet|greenlet|dnspython|ryu"
date +%H:%M
