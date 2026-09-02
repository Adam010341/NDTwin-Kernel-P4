#!/bin/bash
echo "=== does /usr/local/sbin/ndtwin-lab exist? ==="
ls -l /usr/local/sbin/ndtwin-lab 2>&1
ls /usr/local/sbin/ 2>&1
echo
echo "=== is there anything named ndtwin-lab in the checkout? ==="
find ~/Desktop/NDTwin-Kernel -name '*ndtwin-lab*' 2>/dev/null | head
echo "=== does any doc page mention it? ==="
grep -rn "ndtwin-lab" ~/ndtwin-docs/ 2>/dev/null | grep -v "github.com/ndtwin-lab" | head
echo "  (lines above exclude the github org name 'ndtwin-lab')"
echo
echo "=== how many times does the ndt tool reference it? ==="
grep -c "ndtwin-lab" ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt
grep -n "usr/local/sbin/ndtwin-lab" ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt | head -5
echo
echo "=== is there an installer for it anywhere in the repo? ==="
ls ~/Desktop/NDTwin-Kernel/tools/test_workflow/ 2>&1
echo
echo "=== state left behind by the failed 'ndt up ovs' ==="
~/.local/bin/ndt status 2>&1 | sed -n '/^running/,/^$/p'
sudo ovs-vsctl list-br 2>&1 | tr '\n' ' '; echo
echo
echo "=== clean up before my second by-hand run ==="
~/.local/bin/ndt down 2>&1 | tail -10
date +%H:%M:%S
