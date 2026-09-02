#!/bin/bash
date +%H:%M
echo "=== provenance of the tracked binary: when was it committed, and is it the same file? ==="
cd ~/Simulation-Platform-Manager
git log -1 --format='%h %ci %s' -- registered/energy_saving_simulator/1.0/executable
git stash list >/dev/null 2>&1
echo "--- committed version vs the one make all just wrote ---"
git show HEAD:registered/energy_saving_simulator/1.0/executable | sha256sum
sha256sum registered/energy_saving_simulator/1.0/executable
echo
echo "=== I08: build the Simulation Platform Manager ==="
cd ~/Simulation-Platform-Manager
make all 2>&1 | tail -12
echo "SPM_MAKE_ALL_EXIT=$?"
ls -l simulation_platform_manager 2>&1 | tail -1
echo
echo "=== I10 claim: it needs /mnt/nfs/sim to already exist. Does that dir exist now? ==="
ls -ld /mnt/nfs/sim 2>&1
echo "=== p4 build progress ==="
date +%H:%M
tail -1 ~/logs/06a_p4.log | head -c 160; echo
grep -E "install *: *[0-9]+ sec" ~/logs/06a_p4.log | tail -5
