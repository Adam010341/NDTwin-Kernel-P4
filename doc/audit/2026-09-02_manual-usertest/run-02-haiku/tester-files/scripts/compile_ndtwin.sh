#!/bin/bash
set -e
cd ~/Desktop/NDTwin-Kernel

echo "Starting NDTwin Kernel compilation at $(date)" >> ~/logs/ndtwin_compile.log

rm -rf build
mkdir build && cd build

echo "Running CMake at $(date)" >> ~/logs/ndtwin_compile.log
cmake -GNinja .. >> ~/logs/ndtwin_compile.log 2>&1

echo "Cleaning build at $(date)" >> ~/logs/ndtwin_compile.log
ninja clean >> ~/logs/ndtwin_compile.log 2>&1

echo "Building with Ninja at $(date)" >> ~/logs/ndtwin_compile.log
ninja -j $(( $(nproc) / 2 )) >> ~/logs/ndtwin_compile.log 2>&1

echo "Build completed at $(date)" >> ~/logs/ndtwin_compile.log
ls -lh bin/ndtwin_kernel >> ~/logs/ndtwin_compile.log 2>&1

cd ~/Desktop/NDTwin-Kernel
echo "Returned to project root" >> ~/logs/ndtwin_compile.log
