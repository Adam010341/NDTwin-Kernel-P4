#!/bin/bash
date +%H:%M
cd ~/Desktop/NDTwin-Kernel
echo "=== 4.2.2 prepare build dir ==="
rm -rf build
mkdir build && cd build
echo "=== 4.2.3 cmake -GNinja .. ==="
cmake -GNinja ..
echo "CMAKE_EXIT=$?"
echo "=== ninja clean ==="
ninja clean
echo "NINJACLEAN_EXIT=$?"
echo "=== ninja -j $(( $(nproc) / 2 )) ==="
ninja -j $(( $(nproc) / 2 ))
echo "NINJA_EXIT=$?"
echo "=== 4.2.4 cd back to project root ==="
cd ~/Desktop/NDTwin-Kernel
pwd
ls -l build/bin/ 2>&1
date +%H:%M
echo "BUILD_DONE"
