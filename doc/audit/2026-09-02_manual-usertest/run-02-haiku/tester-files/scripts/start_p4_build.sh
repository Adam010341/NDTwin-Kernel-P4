#!/bin/bash
cd ~
echo "=== Starting P4/BMv2 Installation (Section 6) ===" >> ~/logs/p4_build.log
echo "Start time: $(date)" >> ~/logs/p4_build.log

# First verify the P4 files exist
if [ -f ~/Desktop/NDTwin-Kernel/p4_proxy/p4_src/ndtwin_switch.p4 ]; then
    echo "P4 files found" >> ~/logs/p4_build.log
else
    echo "ERROR: P4 files not found" >> ~/logs/p4_build.log
    exit 1
fi

# Check if we have enough space (needs ~25GB)
available=$(df ~ | awk 'NR==2 {print $4}')
if [ $available -lt 25000000 ]; then
    echo "WARNING: Only ${available}KB available, P4 build needs ~25GB" >> ~/logs/p4_build.log
fi

# Clone p4-guide and run installer
cd ~
git clone https://github.com/jafingerhut/p4-guide >> ~/logs/p4_build.log 2>&1
cd ~/p4-guide

# Run the v8 installer as recommended by manual
bash ./bin/install-p4dev-v8.sh 2>&1 | tee -a ~/logs/p4_build.log

echo "P4 build completed at $(date)" >> ~/logs/p4_build.log
