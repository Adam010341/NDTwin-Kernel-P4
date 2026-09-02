#!/bin/bash
cd ~/Desktop/NDTwin-Kernel
echo "=== Step 2.6.2: the manual shows 3 values but not WHERE. Grep for them. ==="
grep -n "static_topology_file_path" intelligent_router.py | head -10
echo "---"
grep -n "^is_mininet\|^switch_num\|is_mininet *=\|switch_num *=" intelligent_router.py | head -10
echo "--- context around them ---"
n=$(grep -n "static_topology_file_path *=" intelligent_router.py | head -1 | cut -d: -f1)
echo "first assignment at line $n"
sed -n "$((n-8)),$((n+14))p" intelligent_router.py
echo "=== whoami ==="; whoami
