#!/bin/bash
B=http://localhost:8000
echo "########## D10 STRICT delete (priority present) -- does it spare the priority=10 rule? ##########"
echo "-- before --"; sudo ovs-ofctl dump-flows s2 | grep 'nw_dst=10.0.0.55'
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST -H 'Content-Type: application/json' \
  -d '{"dpid":2,"priority":77,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.55"},"actions":[{"type":"OUTPUT","port":3}]}' \
  $B/ndt/delete_flow_entry
sleep 3
echo "-- after strict delete (the priority=10 routing rule SHOULD survive) --"; sudo ovs-ofctl dump-flows s2 | grep 'nw_dst=10.0.0.55'
echo
echo "########## D18: did anything actually receive the forwarded result? ##########"
echo "-- is anything listening on 9000 (the URL I registered)? --"
ss -lntp 2>/dev/null | grep ':9000' || echo "   (nothing listening on 9000 -- yet the API said 'result forwarded')"
echo "-- what did the kernel log say around the forward? --"
tmux capture-pane -t KERNEL -p -S -600 | grep -iE "simulation|forward|app_id|9000" | tail -12
echo
echo "########## get_average_link_usage with traffic that actually crosses switches ##########"
echo "-- which switch is h50 on? check its routing port from s1 --"
sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.50 ' | head -1
echo "-- stop the old same-switch iperf, start h1 <-> h50 --"
tmux send-keys -t MN 'h50 iperf3 -s -p 5301 &' Enter
sleep 3
tmux send-keys -t MN 'h1 iperf3 -c h50 -p 5301 -t 60 &' Enter
sleep 15
echo "-- avg link usage now --"
curl -sS $B/ndt/get_average_link_usage; echo
echo "-- total input traffic at a middle switch (dpid 5) --"
curl -sS -X POST -H 'Content-Type: application/json' -d '{"dpid":5}' $B/ndt/get_total_input_traffic_load_passing_a_switch; echo
curl -sS -X POST -H 'Content-Type: application/json' -d '{"dpid":5}' $B/ndt/get_num_of_flows_passing_a_switch; echo
echo "-- path switch count h1->h50 (should be > 1 now) --"
curl -sS "$B/ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.50"; echo
echo "-- the flow record and its path --"
curl -sS $B/ndt/get_detected_flow_data | python3 -c "
import json,sys,struct
def ip(v): return '.'.join(str(b) for b in struct.pack('<I',v))
for r in json.load(sys.stdin):
    print('  %s:%s -> %s:%s  rate=%s  path=%s' % (ip(r['src_ip']),r['src_port'],ip(r['dst_ip']),r['dst_port'],
          r['estimated_flow_sending_rate_bps_in_the_last_sec'], [h['node'] for h in r['path']]))
"
date +%H:%M:%S
