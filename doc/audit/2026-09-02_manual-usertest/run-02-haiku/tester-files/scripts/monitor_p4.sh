#!/bin/bash
PID=$(cat ~/p4_install.pid)
while ps -p $PID > /dev/null 2>&1; do
  sleep 60
done
echo "P4 Build COMPLETED at $(date +%H:%M:%S)" >> ~/p4_build_complete.txt
ls -lh ~/logs/p4dev_v8.log >> ~/p4_build_complete.txt
echo "" >> ~/p4_build_complete.txt
echo "Last 20 lines:" >> ~/p4_build_complete.txt
tail -20 ~/logs/p4dev_v8.log >> ~/p4_build_complete.txt
