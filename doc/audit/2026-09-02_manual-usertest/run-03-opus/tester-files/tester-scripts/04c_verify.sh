#!/bin/bash
cd ~/Desktop/NDTwin-Kernel
echo "=== ninja exit codes ==="
grep -E "^(CMAKE|NINJACLEAN|NINJA)_EXIT=" ~/logs/04b_build.log
echo "=== warnings/errors in build ==="
grep -icE "error:" ~/logs/04b_build.log
grep -icE "warning:" ~/logs/04b_build.log
echo "=== User Manual pre-flight check 2: does ndtwin_kernel exist in build/bin ? ==="
ls -l build/bin/
echo "=== does it run? ==="
./build/bin/ndtwin_kernel --help 2>&1 | head -40
echo "HELP_EXIT=$?"
echo "=== Step 6.0 recheck ==="
ls p4_proxy/p4_src/ndtwin_switch.p4
echo "=== Step 6.1 note: ldd check the manual suggests ==="
ldd build/bin/ndtwin_kernel | grep /usr/local || echo "(prints nothing - as the manual predicts, pre-P4)"
echo "=== Section 5: testbed_topo.py present, run from project root ==="
ls -l testbed_topo.py
echo "=== AppConfig.hpp created by cmake? (Step 6.4/6.0 claim) ==="
ls -l setting/AppConfig.hpp 2>&1
grep -n "P4_PROXY_IP_AND_PORT\|ALLOW_MIXED_DATAPLANE\|SIM_SERVER_URL" setting/AppConfig.hpp 2>&1
echo "=== git status (should be just intelligent_router.py) ==="
git status --short
date +%H:%M
