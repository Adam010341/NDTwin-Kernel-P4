#!/bin/bash
LOG=~/logs/s4_2_build.log
{
set -x
date +%H:%M
cd ~/Desktop/NDTwin-Kernel
rm -rf build
mkdir build && cd build
cmake -GNinja ..
echo "CMAKE_EXIT=$?"
ninja clean
NJOBS=$(( $(nproc) / 2 ))
echo "NJOBS=$NJOBS"
ninja -j "$NJOBS"
echo "NINJA_EXIT=$?"
cd ~/Desktop/NDTwin-Kernel
pwd
ls -la build/bin/ 2>&1
date +%H:%M
echo BUILD_SCRIPT_DONE
} > "$LOG" 2>&1
