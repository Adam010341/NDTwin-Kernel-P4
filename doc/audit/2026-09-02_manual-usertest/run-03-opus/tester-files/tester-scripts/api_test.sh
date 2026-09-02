#!/bin/bash
# Walk every documented endpoint once, with the manual's own example values where they exist.
# Saves each response verbatim; prints status + body head.
B=http://localhost:8000
OUT=~/logs/api_$1
mkdir -p $OUT
g(){ # name, url
  local n="$1"; shift
  local code
  code=$(curl -sS -m 20 -o $OUT/$n.txt -w '%{http_code}' "$@" 2>$OUT/$n.err)
  echo "### $n -> HTTP $code"
  head -c 700 $OUT/$n.txt 2>/dev/null; echo
  [ -s $OUT/$n.err ] && { echo "[stderr] $(head -c 200 $OUT/$n.err)"; }
  echo "-----"
}
p(){ # name, path, json
  local n="$1" path="$2" body="$3"
  local code
  code=$(curl -sS -m 20 -o $OUT/$n.txt -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$body" "$B$path" 2>$OUT/$n.err)
  echo "### $n -> HTTP $code   BODY SENT: $body"
  head -c 700 $OUT/$n.txt 2>/dev/null; echo
  [ -s $OUT/$n.err ] && { echo "[stderr] $(head -c 200 $OUT/$n.err)"; }
  echo "-----"
}
echo "===== API sweep $(date +%H:%M:%S) ====="
g D03_get_graph_data                 "$B/ndt/get_graph_data"
g D04_get_detected_flow_data         "$B/ndt/get_detected_flow_data"
g D05_get_switch_openflow_table_entries "$B/ndt/get_switch_openflow_table_entries"
g D06_get_power_report               "$B/ndt/get_power_report"
g D07_get_switches_power_state_all   "$B/ndt/get_switches_power_state"
g D07b_get_switches_power_state_ip   "$B/ndt/get_switches_power_state?ip=192.168.123.11"
g D07c_power_state_unknown_ip        "$B/ndt/get_switches_power_state?ip=9.9.9.9"
g D12_get_cpu_utilization            "$B/ndt/get_cpu_utilization"
g D13_get_memory_utilization         "$B/ndt/get_memory_utilization"
g D14_inform_switch_entered          "$B/ndt/inform_switch_entered?dpid=1"
g D19_get_nickname_dpid              "$B/ndt/get_nickname?dpid=1"
g D19b_get_nickname_name             "$B/ndt/get_nickname?name=h1"
g D19c_get_nickname_none             "$B/ndt/get_nickname"
g D21_get_temperature                "$B/ndt/get_temperature"
g D22_get_path_switch_count_all      "$B/ndt/get_path_switch_count"
g D22b_get_path_switch_count_pair    "$B/ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.2"
g D24_get_average_link_usage         "$B/ndt/get_average_link_usage"
g D30_get_detected_top_k_flow_data   "$B/ndt/get_detected_top_k_flow_data"
g D30b_top_k_with_k                  "$B/ndt/get_detected_top_k_flow_data?k=3"
g D37_get_openflow_capacity          "$B/ndt/get_openflow_capacity"
g D38_get_static_topology_json        "$B/ndt/get_static_topology_json"
p D25_total_input_traffic  /ndt/get_total_input_traffic_load_passing_a_switch '{"dpid": 1}'
p D26_num_flows_passing    /ndt/get_num_of_flows_passing_a_switch '{"dpid": 1}'
p D27_acquire_lock         /ndt/acquire_lock '{"type": "routing_lock", "ttl": 30}'
p D28_renew_lock           /ndt/renew_lock   '{"type": "routing_lock", "ttl": 30}'
p D29_release_lock         /ndt/release_lock '{"type": "routing_lock"}'
p D27b_acquire_lock_notype /ndt/acquire_lock '{"ttl": 30}'
p D28b_renew_lock_nobody   /ndt/renew_lock   '{}'
p D29b_release_lock_badtype /ndt/release_lock '{"type": "banana_lock"}'
p D16_app_register         /ndt/app_register '{"app_name": "MyApp", "simulation_completed_url": "http://127.0.0.1:9000/simulation_completed"}'
p D20_modify_nickname      /ndt/modify_nickname '{"identifier": {"type": "dpid", "value": 1}, "new_nickname": "Sinica-Switch-01"}'
p D15_modify_device_name   /ndt/modify_device_name '{"vertex_type": 1, "mac": "00:00:00:00:00:01", "new_name": "HstA"}'
p D41_intent_translator    /ndt/intent_translator/text '{"prompt": "Disable switch s5", "session": "default"}'
p D39_historical_enable    "/ndt/historical_logging?state=enable" ''
p D39b_historical_disable  "/ndt/historical_logging?state=disable" ''
p D39c_historical_bogus    "/ndt/historical_logging?state=banana" ''
p D42_malformed_json       /ndt/get_num_of_flows_passing_a_switch '{"dpid": '
p D01_link_failure_manualvals /ndt/link_failure_detected '{"src_dpid": 106225808402492, "src_interface": 23, "dst_dpid": 106225808387660, "dst_interface": 23}'
echo "===== end $(date +%H:%M:%S) ====="
