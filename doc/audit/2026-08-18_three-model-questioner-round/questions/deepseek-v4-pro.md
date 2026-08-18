Q1. Does the live model returned by `/ndt/get_graph_data` contain exactly the same nodes and edges as `/ndt/get_static_topology_json` (matching dpid/device_name/vertex_type for nodes and src/dst dpid+interface tuples for edges)?
  ASK ME TO RUN: `curl -s http://127.0.0.1:8000/ndt/get_graph_data` and `curl -s http://127.0.0.1:8000/ndt/get_static_topology_json`; compare the sets of node `(dpid, device_name, vertex_type)` and edge `(src_dpid, src_interface, dst_dpid, dst_interface)` between the two outputs.
  FINE IF:      The same 14 nodes (10 switches dpid 1–10, 4 hosts with 10.0.0.1–10.0.0.4) and the same 40 directed edges appear with identical dpid/interface tuples.
  WORRYING IF:  Any node or edge is missing, extra, or has a different dpid/interface, because that means the twin's running topology has diverged from the configured network and every topology-based decision becomes suspect.

Q2. If an existing up inter-switch link is reported failed via `/ndt/link_failure_detected`, does the matching edge in `/ndt/get_graph_data` become unusable, and then become usable again after `/ndt/link_recovery_detected`?
  ASK ME TO RUN: First `curl -s http://127.0.0.1:8000/ndt/get_graph_data` and choose a currently-up inter-switch edge (e.g. `(1,2)->(6,1)`); then `curl -s -X POST http://127.0.0.1:8000/ndt/link_failure_detected -H 'Content-Type: application/json' -d '{"src_dpid":1,"src_interface":2,"dst_dpid":6,"dst_interface":1}'`, re-fetch graph_data immediately; then POST the same body to `/ndt/link_recovery_detected`, re-fetch graph_data after a few seconds.
  FINE IF:      After failure the chosen edge has `is_up=false` or `is_enabled=false` and no other edge toggles; after recovery it returns to `is_up=true` and `is_enabled=true`.
  WORRYING IF:  The edge remains usable after the failure POST, or remains down/unusable after the recovery POST, because that means link-state events are being swallowed or stuck and re-route/power apps will act on a network that no longer exists.

Q3. After powering a currently-up switch off through the API, does the graph stop reporting that switch as `is_up`, and after powering it back on does `is_up` return?
  ASK ME TO RUN: Pick a currently-up switch you can tolerate losing briefly (e.g. s6, dpid 6, 192.168.123.16); `curl -s -X POST 'http://127.0.0.1:8000/ndt/set_switches_power_state?ip=192.168.123.16&action=off'`, wait 20 s, then `curl -s 'http://127.0.0.1:8000/ndt/get_switches_power_state?ip=192.168.123.16'` and `curl -s http://127.0.0.1:8000/ndt/get_graph_data`; then `... &action=on`, wait 20 s, and query both again.
  FINE IF:      After off, power state says OFF and graph node dpid 6 has `is_up=false`; after on, power state says ON and graph node dpid 6 has `is_up=true`.
  WORRYING IF:  Power state says OFF but graph still has `is_up=true` (or ON but graph stays false after restore), because liveness has gone stale or readopt failed, so power and routing apps will act on a switch whose actual state is opposite to the twin's model.

Q4. After the API returns `queued` for an install request, does the requested rule actually appear in the switch's OpenFlow table, and later disappear after a delete request?
  ASK ME TO RUN: `curl -s -X POST http://127.0.0.1:8000/ndt/install_flow_entry -H 'Content-Type: application/json' -d '{"dpid":1,"priority":54321,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.250"},"actions":[{"type":"OUTPUT","port":1}]}'`; wait 5 s; `curl -s http://127.0.0.1:8000/ndt/get_switch_openflow_table_entries` and find dpid 1; then `curl -s -X POST http://127.0.0.1:8000/ndt/delete_flow_entry -H 'Content-Type: application/json' -d '{"dpid":1,"priority":54321,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.250"}}'`; wait 5 s and query the table again.
  FINE IF:      The install returns 200 queued and the priority-54321 rule appears in dpid 1's table within a few seconds; after delete it is gone.
  WORRYING IF:  The install returns 200 queued but the rule never appears, or the delete returns 200 but the rule remains, because then the queueing layer is reporting acceptance without programming and callers cannot distinguish success from silent failure.

Q5. Does every switch-to-switch hop in every path returned by `/ndt/get_detected_flow_data` correspond to an existing live edge in `/ndt/get_graph_data`?
  ASK ME TO RUN: `curl -s http://127.0.0.1:8000/ndt/get_detected_flow_data` and `curl -s http://127.0.0.1:8000/ndt/get_graph_data`; for each flow's path, check each consecutive pair of switch nodes against the graph's edge list using `(node, interface)` hops; if no flows are present, first generate a 5-second flow between h1 and h3.
  FINE IF:      Every switch-to-switch hop resolves to an existing graph edge with `is_up=true` and `is_enabled=true`.
  WORRYING IF:  A flow traverses a hop that is missing from the graph or is marked down/disabled, because the twin is reporting traffic across a topology that no longer exists—a silent state divergence between flow paths and link state.

Q6. For the highest-rate detected flow, does every inter-switch edge on its path list that flow's 5-tuple in `flow_set`, and does the edge's reported usage at least not contradict the flow's estimated rate?
  ASK ME TO RUN: `curl -s http://127.0.0.1:8000/ndt/get_detected_flow_data` and `curl -s http://127.0.0.1:8000/ndt/get_graph_data`; pick the flow with the largest `estimated_flow_sending_rate_bps_in_the_last_sec`, then inspect each inter-switch edge on its path and look for a matching `(src_ip, dst_ip, protocol_number, src_port, dst_port)` in `flow_set` and compare rates.
  FINE IF:      The flow appears in `flow_set` on every inter-switch edge along its path, and each edge's `link_bandwidth_usage_bps` is roughly consistent with the flow rate.
  WORRYING IF:  An edge on the path omits that flow from its `flow_set`, or an edge reports far less usage than a high-rate flow traversing it (e.g. 1 Mbps edge load while the flow claims 100 Mbps), because that means flow/path/load data disagree and traffic engineering will mis-count load on active links.

Q7. Does `/ndt/get_num_of_flows_passing_a_switch` for dpid 1 exactly equal the sum of `flow_set` entry counts over all incoming edges to dpid 1 in `/ndt/get_graph_data`?
  ASK ME TO RUN: `curl -s -X POST http://127.0.0.1:8000/ndt/get_num_of_flows_passing_a_switch -H 'Content-Type: application/json' -d '{"dpid":1}'`; then `curl -s http://127.0.0.1:8000/ndt/get_graph_data` and sum `flow_set` lengths for every edge with `dst_dpid=1`.
  FINE IF:      The two numbers are exactly equal.
  WORRYING IF:  They differ by any amount, because two endpoints that describe the same underlying fact are disagreeing and at least one consumer is acting on a wrong flow count.

Q8. Does `/ndt/get_total_input_traffic_load_passing_a_switch` for dpid 1 match the sum of `link_bandwidth_usage_bps` over all incoming edges to dpid 1 in `/ndt/get_graph_data`?
  ASK ME TO RUN: `curl -s -X POST http://127.0.0.1:8000/ndt/get_total_input_traffic_load_passing_a_switch -H 'Content-Type: application/json' -d '{"dpid":1}'`; then `curl -s http://127.0.0.1:8000/ndt/get_graph_data` and sum `link_bandwidth_usage_bps` for every edge with `dst_dpid=1`.
  FINE IF:      The two values match closely, allowing only for an instant's timing difference between the two reads.
  WORRYING IF:  The endpoint reports a significantly different number from the graph's edge sum, because the switch-load endpoint and the topology graph are computing from different or stale data and a reroute/power decision based on it could be wrong.

Q9. Does `/ndt/get_average_link_usage` equal the average `link_bandwidth_utilization_percent` over all usable inter-switch edges with non-zero usage in `/ndt/get_graph_data`?
  ASK ME TO RUN: `curl -s http://127.0.0.1:8000/ndt/get_average_link_usage`; then `curl -s http://127.0.0.1:8000/ndt/get_graph_data`; from the graph, select edges with neither `src_dpid` nor `dst_dpid` equal to 0, `is_up=true`, `is_enabled=true`, and `link_bandwidth_usage_bps>0`, and average their `link_bandwidth_utilization_percent`.
  FINE IF:      The returned `avg_link_usage` matches the graph-computed average to a few decimal places.
  WORRYING IF:  It does not match, because the headline utilization figure consumed by Energy-Saving-App is inconsistent with the underlying edge data and can drive wrong power-saving decisions.

Q10. After a short test flow between h1 (10.0.0.1) and h3 (10.0.0.3) stops, does that flow disappear from `/ndt/get_detected_flow_data` and from all edge `flow_set`s within 30 seconds?
  ASK ME TO RUN: Generate a 5-second TCP iperf flow between 10.0.0.1 and 10.0.0.3 if possible (otherwise any steady 5+ second flow); note the 5-tuple; wait 30 s; then `curl -s http://127.0.0.1:8000/ndt/get_detected_flow_data` and `curl -s http://127.0.0.1:8000/ndt/get_graph_data`.
  FINE IF:      After 30 s there is no detected flow with that 5-tuple and no edge `flow_set` entry with that 5-tuple remains.
  WORRYING IF:  The flow or an edge `flow_set` entry persists with a nonzero rate long after the source stopped, because stale traffic data looks live and can keep routes and switches powered on for traffic that no longer exists.

Q11. Does `/ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.3` return the same switch count as the number of switch nodes in the observed path for that host pair in `/ndt/get_detected_flow_data`?
  ASK ME TO RUN: `curl -s 'http://127.0.0.1:8000/ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.3'`; then `curl -s http://127.0.0.1:8000/ndt/get_detected_flow_data` and count switch-dpid nodes in any path whose endpoints are 10.0.0.1 and 10.0.0.3.
  FINE IF:      `switch_count` equals the number of switch nodes in the observed flow path (5 for a path like s1-s5-s9-s7-s3).
  WORRYING IF:  The two numbers disagree, because the stored path/switch-count table and the actually observed flow path are not the same, so downstream calculations using path count are based on a stale route.

Q12. Is the list returned by `/ndt/get_detected_top_k_flow_data` sorted in descending order by `estimated_packet_rate_in_the_proceeding_1sec_timeslot`?
  ASK ME TO RUN: `curl -s http://127.0.0.1:8000/ndt/get_detected_top_k_flow_data` and inspect the sequence of `estimated_packet_rate_in_the_proceeding_1sec_timeslot` values.
  FINE IF:      Every consecutive pair is non-increasing in that field.
  WORRYING IF:  The list is out of order, because consumers that trust the contract and take the first K without re-sorting will see the wrong set of top flows.

THE SINGLE THING I would most want to see with my own eyes: the `/ndt/get_graph_data` edge statuses and flow sets for the edges on the active flow path at the exact moment a link failure is injected, because that reveals whether the twin's central graph actually moves in lockstep with the network changes it claims to model.
