#!/bin/bash
echo "=== ndt status right after the failure ==="
~/.local/bin/ndt status 2>&1
echo
echo "=== ports ==="
ss -lntp 2>/dev/null | grep -E ':6633|:8080|:8000|:8081'
echo
echo "=== OVS bridges ==="
sudo ovs-vsctl list-br 2>&1 | tr '\n' ' '; echo
echo "=== any mininet host processes? ==="
ps -eo args= | grep -c '[m]ininet:'
echo "=== the lab session the helper uses ==="
ls -la ~/Desktop/NDTwin-Kernel/.test_run/ 2>&1 | head -20
echo "--- session log, if any ---"
for f in ~/Desktop/NDTwin-Kernel/.test_run/*.log ~/Desktop/NDTwin-Kernel/.test_run/**/*.log; do
  [ -f "$f" ] && { echo "### $f"; tail -25 "$f"; }
done 2>/dev/null | head -60
echo
echo "=== host_count_override (Step 6.5 -- I have NOT done Section 6.5 yet) ==="
cat ~/Desktop/NDTwin-Kernel/p4_proxy/mininet/host_count_override 2>&1
echo "=== bmv2_binary_override (Step 6.6 -- also not done yet) ==="
cat ~/Desktop/NDTwin-Kernel/p4_proxy/mininet/bmv2_binary_override 2>&1
date +%H:%M:%S
