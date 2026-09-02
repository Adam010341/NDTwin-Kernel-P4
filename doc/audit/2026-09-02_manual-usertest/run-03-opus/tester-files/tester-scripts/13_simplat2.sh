#!/bin/bash
date +%H:%M
cd ~/Energy-Saving-App
echo "=== is energy_saving_simulator tracked in git (i.e. shipped, not built)? ==="
git ls-files | grep -E "energy_saving_simulator|executable" || echo "(not tracked here)"
echo "--- SPM side ---"
cd ~/Simulation-Platform-Manager
git ls-files | grep -E "registered/" || echo "(nothing under registered/ tracked)"
echo
echo "=== so: redo I07 honestly. Remove the binaries, then run BARE make. ==="
cd ~/Energy-Saving-App
rm -f energy_saving_simulator ../Simulation-Platform-Manager/registered/energy_saving_simulator/1.0/executable include/app/settings.hpp
echo "--- state before: ---"
ls -l energy_saving_simulator 2>&1 | tail -1
ls -l ../Simulation-Platform-Manager/registered/energy_saving_simulator/1.0/executable 2>&1 | tail -1
echo "--- run: make ---"
make
echo "MAKE_EXIT=$?"
echo "--- state after bare make: ---"
ls -l energy_saving_simulator 2>&1 | tail -1
ls -l ../Simulation-Platform-Manager/registered/energy_saving_simulator/1.0/executable 2>&1 | tail -1
ls -l include/app/settings.hpp 2>&1 | tail -1
echo
echo "=== now I06: make all ==="
make all 2>&1 | tail -15
echo "MAKE_ALL_EXIT=$?"
ls -l energy_saving_simulator 2>&1 | tail -1
ls -l ../Simulation-Platform-Manager/registered/energy_saving_simulator/1.0/executable 2>&1 | tail -1
date +%H:%M
