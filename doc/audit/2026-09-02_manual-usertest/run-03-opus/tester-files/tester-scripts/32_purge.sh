#!/bin/bash
B=http://localhost:8000
echo "########## B20: 'A flow disappears 15 seconds after its last packet' ##########"
echo "-- stop all traffic in the Mininet CLI --"
tmux send-keys -t MN 'h1 pkill -INT iperf3' Enter
sleep 1
tmux send-keys -t MN 'h50 pkill -INT iperf3' Enter
sleep 1
tmux send-keys -t MN 'h2 pkill -INT iperf3' Enter
sleep 2
echo "-- poll until the array is empty, timing it --"
t0=$(date +%s)
for i in $(seq 1 40); do
  n=$(curl -sS $B/ndt/get_detected_flow_data | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
  now=$(date +%s)
  echo "  t+$((now-t0))s : $n records"
  if [ "$n" = "0" ]; then echo "  EMPTY at t+$((now-t0))s after traffic stop"; break; fi
  sleep 2
done
echo "-- confirm [] is what is returned (the manual says [] after traffic stopped is healthy) --"
curl -sS $B/ndt/get_detected_flow_data; echo
date +%H:%M:%S
