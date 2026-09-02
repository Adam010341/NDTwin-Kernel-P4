#!/bin/bash
B=http://localhost:8000
pj(){ echo "### $1"; echo "    sent: $3"; curl -sS -m 15 -w '\n    [HTTP %{http_code}]\n' -X POST -H 'Content-Type: application/json' -d "$3" $B$2 | head -c 900; echo; }
edge(){ curl -sS $B/ndt/get_graph_data | python3 -c "
import json,sys
d=json.load(sys.stdin)
for e in d['edges']:
    if e['src_dpid']==1 and e['dst_dpid']==5:
        print('   edge s1->s5 : is_up=%s is_enabled=%s admin_disabled=%s' % (e['is_up'],e['is_enabled'],e.get('admin_disabled')))
    if e['src_dpid']==5 and e['dst_dpid']==1:
        print('   edge s5->s1 : is_up=%s is_enabled=%s admin_disabled=%s' % (e['is_up'],e['is_enabled'],e.get('admin_disabled')))
"; }
echo "########## D01/D02 link failure + recovery, with the graph checked before and after ##########"
echo "-- BEFORE --"; edge
pj "D01 link_failure_detected (REAL edge s1:1 <-> s5:1)" /ndt/link_failure_detected '{"src_dpid":1,"src_interface":1,"dst_dpid":5,"dst_interface":1}'
sleep 2; echo "-- AFTER failure --"; edge
pj "D02 link_recovery_detected (same edge)" /ndt/link_recovery_detected '{"src_dpid":1,"src_interface":1,"dst_dpid":5,"dst_interface":1}'
sleep 2; echo "-- AFTER recovery --"; edge
pj "D01b link_failure malformed (missing fields)" /ndt/link_failure_detected '{"src_dpid":1}'
echo
echo "########## D17/D18 simulation endpoints ##########"
pj "D17 received_a_simulation_case" /ndt/received_a_simulation_case '{"simulator":"MySimulator","version":"1.0.0","app_id":"1","case_id":"case_123","inputfile":"/srv/nfs/sim/1/case_123.json"}'
pj "D18 simulation_completed"       /ndt/simulation_completed '{"app_id":"1","case_id":"case_123","outputfile":"/srv/nfs/sim/1/case_123_result.json"}'
echo
echo "########## D23 combined install/modify/delete ##########"
echo "-- before: s2 rules for 10.0.0.55 --"; sudo ovs-ofctl dump-flows s2 | grep 'nw_dst=10.0.0.55'
pj "D23 combined" /ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries '{"install_flow_entries":[{"dpid":2,"priority":77,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.55"},"actions":[{"type":"OUTPUT","port":3}]}],"modify_flow_entries":[],"delete_flow_entries":[]}'
sleep 3; echo "-- after: s2 rules for 10.0.0.55 --"; sudo ovs-ofctl dump-flows s2 | grep 'nw_dst=10.0.0.55'
echo
echo "########## D31-D36 group and meter entries (effects checked with ovs-ofctl) ##########"
echo "-- before: groups on s3 --"; sudo ovs-ofctl -O OpenFlow13 dump-groups s3 2>&1 | head -4
pj "D31 install_group_entry" /ndt/install_group_entry '{"dpid":3,"type":"ALL","group_id":1,"buckets":[{"actions":[{"type":"OUTPUT","port":1}]},{"actions":[{"type":"OUTPUT","port":2}]}]}'
sleep 2; echo "-- after install --"; sudo ovs-ofctl -O OpenFlow13 dump-groups s3 2>&1 | head -4
pj "D32 modify_group_entry" /ndt/modify_group_entry '{"dpid":3,"type":"ALL","group_id":1,"buckets":[{"actions":[{"type":"OUTPUT","port":3}]}]}'
sleep 2; echo "-- after modify --"; sudo ovs-ofctl -O OpenFlow13 dump-groups s3 2>&1 | head -4
pj "D33 delete_group_entry" /ndt/delete_group_entry '{"dpid":3,"group_id":1}'
sleep 2; echo "-- after delete --"; sudo ovs-ofctl -O OpenFlow13 dump-groups s3 2>&1 | head -4
echo "-- before: meters on s3 --"; sudo ovs-ofctl -O OpenFlow13 dump-meters s3 2>&1 | head -4
pj "D34 install_meter_entry" /ndt/install_meter_entry '{"dpid":3,"meter_id":1,"flags":["KBPS"],"bands":[{"type":"DROP","rate":1000}]}'
sleep 2; echo "-- after install --"; sudo ovs-ofctl -O OpenFlow13 dump-meters s3 2>&1 | head -4
pj "D35 modify_meter_entry" /ndt/modify_meter_entry '{"dpid":3,"meter_id":1,"flags":["KBPS"],"bands":[{"type":"DROP","rate":2000}]}'
sleep 2; echo "-- after modify --"; sudo ovs-ofctl -O OpenFlow13 dump-meters s3 2>&1 | head -4
pj "D36 delete_meter_entry" /ndt/delete_meter_entry '{"dpid":3,"meter_id":1}'
sleep 2; echo "-- after delete --"; sudo ovs-ofctl -O OpenFlow13 dump-meters s3 2>&1 | head -4
date +%H:%M:%S
