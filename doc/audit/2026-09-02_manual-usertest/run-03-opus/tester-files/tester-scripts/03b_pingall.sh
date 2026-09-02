#!/bin/bash
date +%H:%M
echo "=== Step 3.3: sudo mn --test pingall ==="
sudo mn --test pingall 2>&1
echo "MN_EXIT=$?"
echo "=== the line the manual says decides it ==="
date +%H:%M
