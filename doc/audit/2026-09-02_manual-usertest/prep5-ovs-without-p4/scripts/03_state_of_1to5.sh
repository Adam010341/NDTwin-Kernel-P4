#!/bin/bash
# A-8 step 1b: what exactly did Sections 1-5 leave behind? (kernel build, conda envs, ryu, working-tree deltas)
# [Co-developed with claude code -- Adam]
R=~/Desktop/NDTwin-Kernel
echo "=== A-8 / STATE AFTER SECTIONS 1-5  $(date -u +%FT%TZ) ==="
echo
echo "########## KERNEL BUILD ##########"
ls -la "$R" 2>&1
echo "--- any build dirs / any ndtwin_kernel binary anywhere under Desktop ---"
find ~/Desktop -maxdepth 4 -name 'ndtwin_kernel' -o -maxdepth 4 -type d -name 'build' 2>/dev/null | sed 's/^/FOUND: /'
echo "(end find)"
echo "--- ~/logs (what the install run recorded) ---"
ls -la ~/logs 2>&1
for f in ~/logs/*; do [ -f "$f" ] && { echo "=== tail -15 $f ==="; tail -15 "$f"; }; done
echo
echo "########## CONDA ENVS ##########"
ls -la ~/miniconda3/envs 2>&1
~/miniconda3/bin/conda env list 2>&1 | head -20
echo "--- ryu in any conda env? ---"
for e in ~/miniconda3/envs/*/bin/ryu-manager ~/miniconda3/bin/ryu-manager; do [ -e "$e" ] && echo "PRESENT $e"; done
find ~/miniconda3 -maxdepth 4 -name 'ryu-manager' 2>/dev/null | sed 's/^/FOUND: /'
echo "(end find)"
echo "--- ryu_test.log / .pid from the install run ---"
cat ~/ryu_test.log 2>&1; echo "--- pid file: $(cat ~/ryu_test.pid 2>&1) ---"
P=$(cat ~/ryu_test.pid 2>/dev/null)
if [ -n "$P" ] && [ -d "/proc/$P" ]; then echo "STALE? /proc/$P exists, comm=$(cat /proc/$P/comm 2>/dev/null)"; else echo "pid $P not running (expected: this is a stale pid file from install time, VM was rebooted)"; fi
echo
echo "########## WORKING-TREE DELTAS (git says 2 files modified) ##########"
git -C "$R" status --porcelain
echo "--- diff --stat ---"
git -C "$R" diff --stat
echo "--- FULL DIFF (this matters: it is not the published snapshot) ---"
git -C "$R" diff
echo
echo "########## PYTHON / REQS ##########"
python3 --version
echo "--- what the OVS path's python scripts import ---"
head -40 "$R/testbed_topo.py" 2>&1
echo
echo "########## OVS + KERNEL SOURCE SANITY ##########"
sudo -n ovs-vsctl show 2>&1 | head
sudo -n ovs-ofctl --version 2>&1 | head -2
systemctl is-active openvswitch-switch 2>&1
echo
echo "########## ANY MANUAL/DOCS COPY AT ALL ##########"
find / -maxdepth 5 -type d -name 'ndtwin-docs' 2>/dev/null | sed 's/^/FOUND: /'
ls -la "$R"/*.md "$R"/docs 2>&1 | head -30
echo "(end)"
echo "STATE_EXIT=0"
