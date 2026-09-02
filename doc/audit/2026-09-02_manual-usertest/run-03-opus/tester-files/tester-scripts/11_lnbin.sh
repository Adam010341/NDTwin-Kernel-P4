#!/bin/bash
echo "=== restore the fresh-machine state: remove ~/.local/bin (and ~/.local if I made it) ==="
rm -rf ~/.local/bin
rmdir ~/.local 2>/dev/null && echo "(~/.local removed too - it was mine)" || echo "(~/.local kept: not empty)"
ls -la ~/.local 2>&1 | head -5
echo
echo "=== now run the User Manual command EXACTLY as printed ==="
echo '$ ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt'
ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt
echo "LN_EXIT=$?"
echo
echo "=== second time (repeat), same result? ==="
ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt
echo "LN_EXIT_2=$?"
echo
echo "=== workaround: mkdir first, then the manual command ==="
mkdir -p ~/.local/bin
ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt
echo "LN_EXIT_3=$?"
ls -l ~/.local/bin/ndt
date +%H:%M
echo "=== p4 build progress ==="
tail -2 ~/logs/06a_p4.log
