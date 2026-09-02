#!/bin/bash
LOG=~/logs/s6_2to6_setup.log
{
set -x
date +%H:%M
echo "=== verify toolchain binaries first ==="
simple_switch_grpc --version
echo "SSG_EXIT=$?"
p4c-bm2-ss --version
echo "P4C_EXIT=$?"

echo "=== Step 6.2: compile pipeline ==="
cd ~/Desktop/NDTwin-Kernel
mkdir -p p4_proxy/p4_src/build
p4c-bm2-ss --arch v1model \
    -o p4_proxy/p4_src/build/ndtwin_switch.json \
    --p4runtime-files p4_proxy/p4_src/build/ndtwin_switch.p4info.txt \
    p4_proxy/p4_src/ndtwin_switch.p4
echo "P4C_COMPILE_EXIT=$?"
ls -la p4_proxy/p4_src/build/

echo "=== Step 6.3: proxy venv ==="
python3 --version
cd ~/Desktop/NDTwin-Kernel
python3 -m venv p4_proxy/venv
p4_proxy/venv/bin/pip install -r p4_proxy/requirements.txt
p4_proxy/venv/bin/python --version

echo "=== Step 6.4: check AppConfig.hpp ==="
grep -n "P4_PROXY_IP_AND_PORT\|ALLOW_MIXED_DATAPLANE" setting/AppConfig.hpp

echo "=== Step 6.5: host_count_override ==="
echo 128 > p4_proxy/mininet/host_count_override
cat p4_proxy/mininet/host_count_override

echo "=== Step 6.6: bmv2_binary_override ==="
cat p4_proxy/mininet/bmv2_binary_override
echo "/usr/local/bin/simple_switch_grpc" > p4_proxy/mininet/bmv2_binary_override
p=$(grep -vE '^[[:space:]]*(#|$)' p4_proxy/mininet/bmv2_binary_override | head -1)
echo "selected: ${p:-<none>}"
[ -x "$p" ] && echo "OK: exists and is executable" || echo "PROBLEM: not executable"

date +%H:%M
echo S6_2TO6_DONE
} > "$LOG" 2>&1
cat "$LOG"
