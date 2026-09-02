#!/usr/bin/env bash
# Hold the OFFERED DATAGRAM RATE fixed at 60 000/s -- a rate that lost nothing with one flow key --
# and move only the WORK PER SAMPLE (number of distinct 5-tuples). Separates "too many packets"
# from "too much work per packet". [Co-developed with claude code -- Adam]
set -u
R="$(cd "$(dirname "$0")" && pwd)"
KLOG=/home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
KPID=$(cat /home/adam/Desktop/NDTwin-Kernel/.test_run/pids/kernel.child.pid)

arm() {  # arm <tag> <nkeys>
  echo; echo "======== arm $1: 60 000 datagrams/s for 10 s, $2 distinct flow key(s) ========"
  date -Is; uptime; free -m | sed -n 2p
  "$R/udpdrops.sh"
  local L0; L0=$(wc -l < "$KLOG")
  local C0; C0=$(awk '{print $14+$15}' /proc/$KPID/stat)
  python3 "$R/sflow_blast.py" 60000 10 "$1" "$2"
  local C1; C1=$(awk '{print $14+$15}' /proc/$KPID/stat)
  sleep 4
  "$R/udpdrops.sh"
  echo "kernel CPU ticks consumed during the arm: $((C1-C0)) (100 ticks = 1 core-second)"
  echo "flow table rows now: $(curl -s --max-time 8 'http://127.0.0.1:8000/ndt/get_detected_flow_data?liveness=all' | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
  echo "-- counter lines logged during the arm --"
  tail -n +$((L0+1)) "$KLOG" | grep "sFlow samples lost" | sed 's/\x1b\[[0-9;]*m//g' | tail -3
  tail -n +$((L0+1)) "$KLOG" | grep -c "sFlow samples lost" | sed 's/^/   WARN lines: /'
  sleep 25   # let the 15 s table drain before the next arm
}

echo "#### what this step proves: at a FIXED offered rate that loses nothing with one flow key,"
echo "#### does raising the WORK PER SAMPLE reach the app-level (round-robin) drop path?"
date -Is
arm w_1key      1
arm w_5000keys  5000
arm w_1key_again 1
echo "======== done $(date -Is) ========"
