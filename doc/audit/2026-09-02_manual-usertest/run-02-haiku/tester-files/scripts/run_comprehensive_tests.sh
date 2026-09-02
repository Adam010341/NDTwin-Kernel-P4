#!/bin/bash
START_TIME=$(date +%s)
TEST_DURATION=5400  # 90 minutes in seconds
TEST_COUNT=0

echo "Starting comprehensive test loop at $(date)" >> ~/comprehensive_test.log

while [ $(($(date +%s) - START_TIME)) -lt $TEST_DURATION ]; do
  TEST_COUNT=$((TEST_COUNT + 1))
  ELAPSED=$(($(date +%s) - START_TIME))
  MINUTES=$((ELAPSED / 60))
  
  echo "" >> ~/comprehensive_test.log
  echo "=== Test Iteration $TEST_COUNT at $(date +%H:%M:%S) - $MINUTES min elapsed ===" >> ~/comprehensive_test.log
  
  # Check kernel API
  FLOWS=$(curl -s http://localhost:8000/ndt/get_detected_flow_data | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
  echo "Flows detected: $FLOWS" >> ~/comprehensive_test.log
  
  # Check Ryu
  curl -s http://localhost:8080/v1.0/topology/switches > /dev/null 2>&1 && echo "Ryu: OK" >> ~/comprehensive_test.log || echo "Ryu: FAIL" >> ~/comprehensive_test.log
  
  # Check processes
  RYU_PROCS=$(ps aux | grep ryu-manager | grep -v grep | wc -l)
  TOPO_PROCS=$(ps aux | grep testbed_topo | grep -v grep | wc -l)
  KERN_PROCS=$(ps aux | grep ndtwin_kernel | grep -v grep | wc -l)
  echo "Processes - Ryu: $RYU_PROCS, Topo: $TOPO_PROCS, Kernel: $KERN_PROCS" >> ~/comprehensive_test.log
  
  sleep 60  # Wait 60 seconds between iterations
done

echo "" >> ~/comprehensive_test.log
echo "Comprehensive testing completed at $(date)" >> ~/comprehensive_test.log
