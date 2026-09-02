#!/bin/bash
B=http://localhost:8000
echo "=== kernel graph check for run 2 ==="
tmux capture-pane -t KERNEL -p -S -400 | grep -E "topology from the control plane|Pulled .* paths" | tail -3
echo
echo "########## D08 set_switches_power_state -- doc: MININET adds/removes the OVS bridge ##########"
echo "-- BEFORE: bridges --"; sudo ovs-vsctl list-br | tr '\n' ' '; echo
echo "-- BEFORE: power state of s10 (192.168.123.20) --"; curl -sS "$B/ndt/get_switches_power_state?ip=192.168.123.20"; echo
echo "-- turn s10 OFF --"
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST "$B/ndt/set_switches_power_state?ip=192.168.123.20&action=off"
sleep 6
echo "-- AFTER off: bridges --"; sudo ovs-vsctl list-br | tr '\n' ' '; echo
echo "-- AFTER off: power state --"; curl -sS "$B/ndt/get_switches_power_state?ip=192.168.123.20"; echo
echo "-- AFTER off: does the kernel graph show s10 down? --"
curl -sS $B/ndt/get_graph_data | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d['nodes']:
    if n.get('vertex_type')==0 and n.get('dpid')==10:
        print('   s10 node: is_up=%s is_enabled=%s' % (n['is_up'],n['is_enabled']))
"
echo "-- turn s10 back ON --"
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST "$B/ndt/set_switches_power_state?ip=192.168.123.20&action=on"
sleep 8
echo "-- AFTER on: bridges --"; sudo ovs-vsctl list-br | tr '\n' ' '; echo
echo "-- AFTER on: power state --"; curl -sS "$B/ndt/get_switches_power_state?ip=192.168.123.20"; echo
echo "-- bad action value --"
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST "$B/ndt/set_switches_power_state?ip=192.168.123.20&action=banana"
echo "-- missing params --"
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST "$B/ndt/set_switches_power_state"
echo "-- unknown ip --"
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST "$B/ndt/set_switches_power_state?ip=9.9.9.9&action=off"
date +%H:%M:%S
