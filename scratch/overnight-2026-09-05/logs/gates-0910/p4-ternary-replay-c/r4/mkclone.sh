#!/usr/bin/env bash
# mkclone.sh <dir> <rev> [p4build.log] : a throwaway clone of the Cut C worktree at <rev>, the venv linked, the P4 build made (r2/p4build.log line 2).
# [Co-developed with claude code -- Adam]
set -e
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-replay-c
d="$1"; rev="$2"
git clone -q --no-hardlinks "$WT" "$d"
cd "$d"
git checkout -q "$rev"
ln -s /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv p4_proxy/venv
mkdir -p p4_proxy/p4_src/build
p4c-bm2-ss --arch v1model -o p4_proxy/p4_src/build/ndtwin_switch.json --p4runtime-files p4_proxy/p4_src/build/ndtwin_switch.p4info.txt p4_proxy/p4_src/ndtwin_switch.p4 > "${3:-/dev/null}" 2>&1
echo "clone $d at $(git rev-parse HEAD)"
