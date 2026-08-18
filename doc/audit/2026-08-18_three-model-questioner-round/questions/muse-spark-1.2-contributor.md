Q1. If I power a switch off on your P4 instance, does the twin ever admit it is down or does a stale successful probe keep it UP forever?
  ASK ME TO RUN: Pick dpid 5 (s5, 192.168.123.15), snapshot `GET /ndt/get_graph_data` is_up for node 5 and all incident edges, `GET /ndt/get_switches_power_state?ip=192.168.123.15`, and `GET http://proxy:8080/p4/switch_state` probe_ok/probe_age_s for dpid 5; then `POST /ndt/set_switches_power_state?ip=192.168.123.15&action=off`, wait 20s polling all three every 2s, then action=on and poll again.
  FINE IF: Within ~5-10s graph `is_up` flips to false, incident edges flip to false, power_state is OFF, proxy probe_ok becomes false or null and probe_age_s increments, and on `on` they all return to true/ON.
  WORRYING IF: power_state says OFF but graph `is_up` stays true indefinitely, or proxy keeps `probe_ok:true` with probe_age_s climbing to 30s+ and kernel still reports Up — because P4 liveness treats `probe_ok==true` as Up regardless of age, a stalled poller hides a dead switch and Energy/TE apps will send traffic into a black hole.

Q2. When a link is declared DOWN, does the twin stop counting it as usable or does average link usage still include it?
  ASK ME TO RUN: Record `GET /ndt/get_graph_data` edges is_up/is_enabled and `GET /ndt/get_average_link_usage` avg_link_usage, then `POST /ndt/link_failure_detected` with src_dpid 1 dst_dpid 5 src_interface 1 dst_interface 1 (s1->s5), wait 5s, re-GET graph_data and avg_link_usage, then `POST /ndt/link_recovery_detected` same body and re-GET.
  FINE IF: Both directed edges 1->5 and 5->1 become is_up false (is_enabled fold unchanged), avg_link_usage changes excludes them if they had non-zero usage, and recovery flips them back.
  WORRYING IF: Edges stay is_up true, or avg_link_usage is identical before/after, because get_average_link_usage claims to use isUsable=isUp&&isEnabled&&!adminDisabled — if failure does not propagate, the Energy-Saving App evaluates savings on a fabric that no longer exists.

Q3. Does a 200 "queued" flow install ever actually reach the switch or does the API lie about success?
  ASK ME TO RUN: `GET /ndt/get_switch_openflow_table_entries` for dpid 5 snapshot, then `POST /ndt/install_flow_entry` dpid 5 priority 99 match {eth_type:2048, ipv4_dst:"10.0.0.99"} actions [{type:"OUTPUT",port:1}] and record response, wait 3s, then re-GET table entries for dpid 5 and grep kernel log for that dpid's controller reply in last 30s.
  FINE IF: Second table dump contains the new match/priority/action and log shows a controller 200 for dpid 5.
  WORRYING IF: API returned `{"status":"queued","accepted":1}` but table never shows the entry and log shows error/rejection or nothing — because all four flow endpoints are async queued with success reported before programming, a silent drop looks identical to success to every app.

Q4. Does a flow reported by the twin still claim to traverse a switch/link the twin already marks DOWN?
  ASK ME TO RUN: After Q2's link DOWN (1->5), immediately `GET /ndt/get_detected_flow_data` and `GET /ndt/get_graph_data`, compare every flow path's node list against edges/nodes where is_up==false; repeat after powering s5 OFF via Q1.
  FINE IF: No active flow path contains a node or directed edge that is now is_up false, or flows disappear/age out within one sFlow interval.
  WORRYING IF: Flows persist for >30s with path nodes that are DOWN or via failed edges — stale flow data that never expires is worse than missing data because TE will compute paths assuming that path is still valid.

Q5. Can any caller release any other caller's routing lock and be told it succeeded?
  ASK ME TO RUN: Client A `POST /ndt/acquire_lock {"type":"routing_lock","ttl":30}` -> 200 locked, Client B (different curl without sharing state) `POST /ndt/release_lock {"type":"routing_lock"}` and record status, then Client A `POST /ndt/renew_lock {"type":"routing_lock","ttl":30}`.
  FINE IF: B's release is rejected (412/423) and A's renew still succeeds, showing ownership enforcement.
  WORRYING IF: B gets `{"status":"released","type":"routing_lock"}` 200 and A's subsequent renew fails with 412 Lock expired/not held — because release is void and always answers 200, any app can silently break mutual exclusion between Energy-Saving and Traffic-Engineering.

Q6. If I ask to program one real switch and one fictional switch in one batch, will I notice the partial drop if I only check the HTTP status?
  ASK ME TO RUN: `POST /ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries` with install_flow_entries: [{dpid:5 valid},{dpid:999999999999 invalid}] each with match/actions, record HTTP code and body keys.
  FINE IF: 200 body contains `rejected:1` and `rejected_dpids:[999999999999]` and `accepted:1`, or a strict client would see 404 only when all unknown.
  WORRYING IF: 200 body has no `rejected` keys and client checking only status code assumes both installed — this contract explicitly says presence of rejected is the only signal for partial acceptance, so a naive client silently loses half its intent.

Q7. Are CPU, memory, temperature, and power numbers measurements or frozen fixtures that an app will mistake for load?
  ASK ME TO RUN: `GET /ndt/get_cpu_utilization` and `GET /ndt/get_memory_utilization` and `GET /ndt/get_temperature` and `GET /ndt/get_power_report` twice 15s apart; between them generate heavy iperf between h1 (10.0.0.1->10.0.0.3) for 10s, then compare values per IP/dpid.
  FINE IF: Values are either flagged -1/unavailable or you document they are synthetic frozen (`cpu=10+hash(ip)%50` constant, power 30-150W deterministic per dpid) and no app treats them as load signals.
  WORRYING IF: Seven apps read these as live utilisation and the numbers never move despite traffic, because in MININET they are deterministic constants by design — any autoscaling or energy model built on them is optimizing noise and will make confident wrong decisions.

Q8. On this P4/bmv2 fabric do OpenFlow group/meter operations fail honestly or pretend to be OVS?
  ASK ME TO RUN: `POST /ndt/install_group_entry {"dpid":5,"type":"ALL","group_id":1,"buckets":[{"actions":[{"type":"OUTPUT","port":1}]}]}` and `POST /ndt/install_meter_entry {"dpid":5,"meter_id":1,"flags":["KBPS"],"bands":[{"type":"DROP","rate":1000}]}` and record status/controller_status.
  FINE IF: Both return 501 Not Implemented with controller_status 501 on P4, while same call on OVS would return 200 — boundary is explicit.
  WORRYING IF: Either returns 200 "installed" or 500 opaque on P4, because the same API serves both data planes and a caller that worked on OVS will assume multicast/meters work on P4 and never check.

Q9. Is the `is_enabled` folding invariant actually held and could an operator disable be ignored?
  ASK ME TO RUN: `GET /ndt/get_graph_data` and for every node/edge compute `is_enabled == (isEnabled && !adminDisabled)` by inspecting `is_enabled` and `admin_disabled` fields; also `GET /ndt/get_static_topology_json` and verify all dpids 1-10 and 4 hosts appear with matching bridge_name/ip.
  FINE IF: No object has `admin_disabled:true` with `is_enabled:true`, static topology matches graph node count (10 switches + 4 hosts) and currently admin_disabled is uniformly false because --no-ai disables the Intent Translator path.
  WORRYING IF: Any violation or a static-vs-live dpid mismatch appears, because four consumers treat folded is_enabled as "usable" — a missed fold means Energy-Saving thinks an admin-disabled switch is still available to shut down or keep up.

Q10. Do the two IP encodings in the same system agree or does the network-byte-order integer silently alias the wrong host?
  ASK ME TO RUN: `GET /ndt/get_graph_data` note a node's `ip` numeric array vs `GET /ndt/get_static_topology_json` same node's dotted-quad string, and `GET /ndt/get_detected_flow_data` sample flow src_ip/dst_ip integers; convert integers with `ntohl()` / little-endian bytes and compare to dotted-quad.
  FINE IF: `168430090` decodes via ntohl to 192.168.123.11 (s1) and flow IPs round-trip to the 10.0.0.x host strings; string fields are dotted-quad, integer fields are network-order as documented.
  WORRYING IF: Flow path IPs match numerically only if read as host-order (e.g., `16777226` shown as 1.0.0.10 instead of 10.0.0.1), because every app that formats flows without ntohl will correlate flows to the wrong hosts/links while appearing internally consistent.

THE SINGLE THING I would most want to see with my own eyes is you killing one P4 switch (POST set_switches_power_state off for s5) while tailing the kernel log and simultaneously polling `GET /p4/switch_state` on the proxy and `GET /ndt/get_graph_data` — to watch whether a stale `probe_ok:true` ever ages into Unknown/Down or freezes the twin UP forever and keeps traffic assigned to a dead switch.