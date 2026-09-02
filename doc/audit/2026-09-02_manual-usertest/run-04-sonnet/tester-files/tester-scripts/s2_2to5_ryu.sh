#!/bin/bash
exec > ~/logs/s2_2to5_ryu.log 2>&1
set -x
date +%H:%M
source ~/miniconda3/etc/profile.d/conda.sh
conda activate ryu-env
python --version

echo "=== Step 2.2: system build deps ==="
sudo apt update
sudo apt install -y build-essential python3-dev libssl-dev libffi-dev libxml2-dev libxslt1-dev
gcc --version | head -1

echo "=== Step 2.3.1: pip/setuptools/wheel ==="
pip install --upgrade "pip<24" "setuptools<68" wheel

echo "=== Step 2.3.2: install ryu ==="
pip install ryu

echo "=== Step 2.3.3: pin libs ==="
pip install eventlet==0.30.2
pip install "greenlet<3"
pip install "dnspython<2.3"

echo "=== Step 2.4: verify ==="
pip list | grep -E "eventlet|greenlet|dnspython|ryu"

date +%H:%M
echo "SECTION_2_2_TO_2_4_DONE"
