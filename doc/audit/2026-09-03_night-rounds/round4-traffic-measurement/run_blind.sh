#!/usr/bin/env bash
# The round's own theme: does MEASUREMENT break under load, and does anything say so?
# Three cells, identical real traffic in all three; only the collector's offered load changes.
#   A  20 Mbit/s iperf3 alone                      (control before)
#   B  20 Mbit/s iperf3 + sFlow flood at max       (the load)
#   C  20 Mbit/s iperf3 alone                      (control after, same command, close in time)
# [Co-developed with claude code -- Adam]
set -u
R="$(cd "$(dirname "$0")" && pwd)"
source "$R/lib_r4.sh"
OUT="$R/raw/blind"; mkdir -p "$OUT"
KLOG=/home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log

cell() {  # cell <tag> <flood: yes|no>
  local tag="$1" flood="$2"
  echo; echo "======== cell $tag  real traffic 20 Mbit/s, sFlow flood=$flood ========"
  date -Is; uptime; free -m | sed -n 2p
  "$R/udpdrops.sh"
  local L0; L0=$(wc -l < "$KLOG")
  ( r4_in h1 iperf3 -c 10.0.0.2 -u -b 20M -l 1400 -t 55 --forceflush > "$OUT/iperf_$tag.log" 2>&1 ) &
  local IP=$!
  sleep 12
  if [[ "$flood" == "yes" ]]; then
    ( python3 "$R/sflow_blast.py" max 32 "$tag" > "$OUT/blast_$tag.log" 2>&1 ) &
    sleep 1
  fi
  python3 "$R/probe.py" 10.0.0.1 10.0.0.2 5 30 "$tag" > "$OUT/probe_$tag.csv" 2>&1
  wait
  echo "-- avg link usage right after --"; curl -s --max-time 5 http://127.0.0.1:8000/ndt/get_average_link_usage; echo
  echo "-- every endpoint's status field right after (does ANY of them admit a problem?) --"
  for e in get_average_link_usage get_detected_flow_data get_graph_data get_openflow_capacity; do
    printf "   %-34s " "$e"
    curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" --max-time 8 "http://127.0.0.1:8000/ndt/$e"
  done
  echo "-- iperf3 ground truth --"; grep "sender$" "$OUT/iperf_$tag.log" | tail -1
  [[ "$flood" == "yes" ]] && { echo "-- blaster --"; cat "$OUT/blast_$tag.log"; }
  "$R/udpdrops.sh"
  echo "-- kernel.log lines about sFlow loss during this cell --"
  tail -n +$((L0+1)) "$KLOG" | grep -c "sFlow samples lost" || true
  sleep 20
}

echo "#### what this step proves: under collector overload the twin's published traffic numbers"
echo "#### collapse while every endpoint keeps returning 200/success and no field says why."
date -Is
cell A_control_before no
cell B_flood          yes
cell C_control_after  no
echo "======== done $(date -Is) ========"
