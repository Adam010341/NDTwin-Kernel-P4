#!/bin/bash
# Installation Manual Step 6.1 -- run EXACTLY as printed, from ~
echo "START $(date +%H:%M:%S)"
echo "=== the manual's red check: which python3? ==="
python3 --version
echo "=== conda active? (must be no) ==="
echo "CONDA_DEFAULT_ENV=[${CONDA_DEFAULT_ENV}]"
echo "=== disk free before ==="
df -h / | tail -1
cd ~
git clone https://github.com/jafingerhut/p4-guide
echo "CLONE_EXIT=$?"
./p4-guide/bin/install-p4dev-v8.sh |& tee log.txt
echo "SCRIPT_EXIT=${PIPESTATUS[0]}"
echo "=== the check that decides it, per the manual ==="
simple_switch_grpc --version
echo "SSG_EXIT=$?"
p4c-bm2-ss --version
echo "P4C_EXIT=$?"
echo "=== disk free after ==="
df -h / | tail -1
echo "=== which mn (manual says should stay packaged 2.3.0) ==="
which mn; mn --version
echo "=== venv interpreter check the manual mentions ==="
cat ~/p4dev-python-venv/pyvenv.cfg 2>&1
echo "END $(date +%H:%M:%S)"
echo "P4_INSTALL_FINISHED"
