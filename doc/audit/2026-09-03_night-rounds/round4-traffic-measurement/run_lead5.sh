#!/usr/bin/env bash
# Lead 5: does the collector lose samples under load, do the counters move, and is there any
# API path to them? Ground truth is the number of datagrams MY sender put on the wire.
# [Co-developed with claude code -- Adam]
set -u
R="$(cd "$(dirname "$0")" && pwd)"
KLOG=/home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log

cell() {   # cell <tag> <rate|max> <seconds>
  local tag="$1" rate="$2" secs="$3"
  echo
  echo "======== cell $tag  offered=$rate for ${secs}s ========"
  date -Is
  echo "-- machine noise: $(uptime | sed 's/^ *//')"
  free -m | sed -n 2p
  echo "-- /proc/net/udp for :6343 BEFORE (independent of the collector's own counters) --"
  "$R/udpdrops.sh"
  local L0; L0=$(wc -l < "$KLOG")
  echo "-- link usage BEFORE --"
  curl -s --max-time 4 http://127.0.0.1:8000/ndt/get_average_link_usage; echo
  python3 "$R/sflow_blast.py" "$rate" "$secs" "$tag"
  sleep 3
  echo "-- /proc/net/udp for :6343 AFTER --"
  "$R/udpdrops.sh"
  echo "-- link usage AFTER --"
  curl -s --max-time 4 http://127.0.0.1:8000/ndt/get_average_link_usage; echo
  echo "-- the ONLY channel to the four counters: new kernel.log lines mentioning sFlow ingest --"
  tail -n +$((L0+1)) "$KLOG" | grep -E "sFlow samples lost|sFlow ingest healthy|no sFlow datagram" \
      | sed 's/\x1b\[[0-9;]*m//g' || echo "   (none -- the counters said nothing at all)"
  echo "-- did the synthetic flow 10.99.0.1 -> 10.99.0.2 reach the flow table? --"
  curl -s --max-time 4 "http://127.0.0.1:8000/ndt/get_detected_flow_data?liveness=all" \
    | python3 -c "
import json,sys,socket,struct
d=json.load(sys.stdin)
mine=[r for r in d if r['src_ip']==struct.unpack('<I',socket.inet_aton('10.99.0.1'))[0]]
print('   rows total=%d, mine=%d' % (len(d), len(mine)))
for r in mine[:2]:
    print('   ', r['liveness'], 'rate_bps(proceeding)=', r['estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot'], 'pkt_rate=', r['estimated_packet_rate_in_the_proceeding_1sec_timeslot'], 'path_len=', len(r['path']))
"
  sleep 10   # quiet gap before the next cell
}

echo "#### what this step proves: LEAD 5 -- sFlow samples are dropped, the four counters move,"
echo "#### the ONLY place they appear is a log line, and no /ndt/ endpoint carries them."
echo "# The offered load is built by the repository's own producer, p4_proxy/proxy_agent/"
echo "# sflow_emitter.build_datagram, so the datagram shape is the one the kernel parses."
echo "# Ground truth for every cell is the sender's own count."
date -Is
sha256sum /home/adam/Desktop/NDTwin-Kernel/build/bin/ndtwin_kernel

cell forcedgreen_trickle 20 6
cell b2k     2000   10
cell b20k    20000  10
cell b60k    60000  10
cell b150k   150000 10
cell bmax    max    10
echo
echo "======== done $(date -Is) ========"
