### OPERATOR ASSESSMENT CONTEXT: OBSERVED vs. INFERRED

**OBSERVED in the documents:**
- The API returns HTTP 200 with `{"status": "queued", "accepted": N}` for flow installation endpoints (9, 10, 11, 23) upon pushing to an internal queue, before any request reaches Ryu or the switch; per-entry outcomes are written only to the kernel log (`doc/2026-01-02_ndt_api.md`, §8–§11, §23).
- `handleReleaseLock` (§29) returns `200 {"status": "released"}` unconditionally without checking lock ownership or existence, and `LockManager` has no owner token concept.
- In P4 mode, switch liveness policy (`p4LivenessFor`, §3) marks a switch `Up` whenever `probe_ok == true` without inspecting `probe_age_s` or LLDP beacons; staleness checks apply only when `probe_ok == false`.
- `GET /ndt/get_average_link_usage` (§24) explicitly excludes host-facing links and any inter-switch links where `link_bandwidth_usage_bps` is zero.
- Link failure notification `POST /ndt/link_failure_detected` (§1) accepts single directed edge parameters (`src_dpid`, `src_interface`, `dst_dpid`, `dst_interface`).
- Switch CPU (§12), memory (§13), and temperature (§21) in Mininet mode are computed from deterministic IP hashes (`10 + hash(ip) % 50`, `25 + hash(ip) % 25`) and documented as frozen dummy values.
- `GET /ndt/get_path_switch_count` (§22) queries an internal lookup map populated by `POST /ndt/inform_all_destination_paths` (§40).
- Group (§31–§33) and meter (§34–§36) endpoints explicitly return HTTP 501 in P4 mode.

**INFERRED operational risks:**
- Downstream automation (e.g., Energy-Saving App powering down switches after rerouting) may execute destructive power actions under the false belief that rerouting succeeded, because the twin reports queue acceptance as HTTP 200 while controller-level rejections fail silently.
- Independent optimization applications can unilaterally break each other's concurrency locks without authentication.
- A stalled or dead P4 switch process whose last probe succeeded will be reported as `is_up: true` indefinitely.
- The average link usage metric will severely over-report network congestion in lightly loaded networks by discarding idle links.
- Bidirectional physical link cuts may leave one directed graph edge marked UP if notifications are directional.
- Synthetic telemetry may continue reporting plausible health metrics for physically or administratively disabled switches.

---

### QUESTIONS

Q1. Does the twin expose any API-visible error or status change when an asynchronously queued flow installation is subsequently rejected by the controller or switch?
  ASK ME TO RUN: `curl -s -X POST http://localhost:8000/ndt/install_flow_entry -H 'Content-Type: application/json' -d '{"dpid": 1, "priority": 500, "match": {"eth_type": 2048, "ipv4_dst": "10.0.0.99"}, "actions": [{"type": "OUTPUT", "port": 999}]}'` followed immediately and 2 seconds later by `curl -s http://localhost:8000/ndt/get_switch_openflow_table_entries` and checking the kernel logs.
  FINE IF:      The invalid port causes either an immediate API rejection, an eventual error status retrievable via an endpoint, or the rule's verified absence in `get_switch_openflow_table_entries` accompanied by a clear logged rejection.
  WORRYING IF:  The API answers `200 {"status": "queued", "accepted": 1}`, the rule never appears on the switch in `get_switch_openflow_table_entries`, and no API client can detect that the routing change was silently dropped before executing dependent actions like switch shutdown.

Q2. Can a secondary client unilaterally release a mutual-exclusion lock currently held by another application?
  ASK ME TO RUN: `curl -s -X POST http://localhost:8000/ndt/acquire_lock -H 'Content-Type: application/json' -d '{"type": "routing_lock", "ttl": 60}'`, followed by a release call `curl -s -X POST http://localhost:8000/ndt/release_lock -H 'Content-Type: application/json' -d '{"type": "routing_lock"}'`, followed by a new acquire call `curl -s -X POST http://localhost:8000/ndt/acquire_lock -H 'Content-Type: application/json' -d '{"type": "routing_lock", "ttl": 60}'`.
  FINE IF:      The second acquire call returns `423 Locked` because the release required an owner token or was rejected when called without matching credentials.
  WORRYING IF:  The second acquire call returns `200 {"status": "locked"}`, proving that any of the seven applications can accidentally or maliciously strip another application's critical routing or power lock.

Q3. In P4 mode, does the twin continue reporting a switch as operational if the proxy's polling thread stalls after a single successful probe?
  ASK ME TO RUN: In P4 mode, record `curl -s http://localhost:8000/ndt/get_graph_data | jq '.nodes[] | select(.device_name=="s1") | .is_up'`, freeze or terminate the switch/proxy polling, wait 20 seconds, and query `get_graph_data` again.
  FINE IF:      The node's `is_up` flag transitions to `false` (or unknown/down) once `probe_age_s` exceeds the liveness timeout window.
  WORRYING IF:  The node's `is_up` flag remains `true` despite no fresh successful probes for over 15 seconds, confirming that stale successes mask dead P4 switches indefinitely.

Q4. When a link failure is reported on a single directed edge, does the twin mark both directions of the physical link as down in the graph?
  ASK ME TO RUN: `curl -s -X POST http://localhost:8000/ndt/link_failure_detected -H 'Content-Type: application/json' -d '{"src_dpid": 1, "src_interface": 1, "dst_dpid": 5, "dst_interface": 1}'` followed by `curl -s http://localhost:8000/ndt/get_graph_data | jq '.edges[] | select((.src_dpid==1 and .dst_dpid==5) or (.src_dpid==5 and .dst_dpid==1)) | {src: .src_dpid, dst: .dst_dpid, is_up: .is_up, is_enabled: .is_enabled}'`.
  FINE IF:      Both directed edges `1->5` and `5->1` report `is_up: false` and `is_enabled: false`.
  WORRYING IF:  Edge `1->5` is marked `is_up: false` while edge `5->1` remains `is_up: true`, causing traffic engineering algorithms to route reverse traffic directly into a dead link.

Q5. Does the average link usage calculation exclude idle inter-switch links, thereby reporting artificially high utilization during low network traffic?
  ASK ME TO RUN: While running a single active flow between h1 and h2, query `curl -s http://localhost:8000/ndt/get_average_link_usage` and compare its `avg_link_usage` against the manual arithmetic mean of all usable inter-switch edge utilization percentages from `curl -s http://localhost:8000/ndt/get_graph_data`.
  FINE IF:      `avg_link_usage` represents the total inter-switch network utilization across all available operational inter-switch links (e.g., returning ~1–5% when only 1 out of 16 links is busy).
  WORRYING IF:  `avg_link_usage` equals the utilization of only the single active link (e.g., 80%), misleading the Energy-Saving App into believing the entire network is congested when 90% of links are completely idle.

Q6. Do completed flows and their associated bandwidth usage actively expire and clear from the twin, or do they linger as stale ghost flows?
  ASK ME TO RUN: Start a 5-second traffic burst between two hosts, query `curl -s http://localhost:8000/ndt/get_detected_flow_data` during the burst, stop the traffic, wait 15 seconds, and query `get_detected_flow_data` and `curl -s http://localhost:8000/ndt/get_graph_data` again.
  FINE IF:      The stopped flow disappears from `get_detected_flow_data` and edge `flow_set`, and edge `link_bandwidth_usage_bps` returns to 0.
  WORRYING IF:  The flow remains listed in `get_detected_flow_data` with frozen non-zero throughput and stale timestamps, corrupting downstream routing decisions with phantom traffic.

Q7. When a switch is powered off, do synthetic telemetry endpoints immediately stop reporting metrics for it?
  ASK ME TO RUN: `curl -s -X POST "http://localhost:8000/ndt/set_switches_power_state?ip=192.168.123.11&action=off"` followed by `curl -s http://localhost:8000/ndt/get_cpu_utilization`, `curl -s http://localhost:8000/ndt/get_memory_utilization`, and `curl -s http://localhost:8000/ndt/get_temperature`.
  FINE IF:      Switch `192.168.123.11` is either omitted from the response objects, returns `-1`, or returns `"The switch is down."`.
  WORRYING IF:  Switch `192.168.123.11` continues returning normal positive CPU and memory utilization numbers (e.g. 28%), demonstrating that monitoring endpoints operate completely decoupled from physical state.

Q8. Does the total incoming traffic load reported for a switch match the sum of bandwidth usages on its incoming edges in the graph?
  ASK ME TO RUN: During active traffic across switch s5 (DPID 5), run `curl -s -X POST http://localhost:8000/ndt/get_total_input_traffic_load_passing_a_switch -H 'Content-Type: application/json' -d '{"dpid": 5}'` and compare `total_input_traffic_load_bps` with `curl -s http://localhost:8000/ndt/get_graph_data | jq '[.edges[] | select(.dst_dpid==5) | .link_bandwidth_usage_bps] | add'`.
  FINE IF:      The values are identical or differ only within a single polling interval's delta.
  WORRYING IF:  The two endpoints return contradictory numbers or `get_total_input_traffic_load_passing_a_switch` returns 0 while incoming edges report active traffic, indicating internal data aggregation bugs.

Q9. When an intermediate switch is disabled, does the path switch count endpoint invalidate stale cached paths?
  ASK ME TO RUN: `curl -s "http://localhost:8000/ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.3"`, then disable switch s5 via power-off or link failure, and immediately query `get_path_switch_count` again before any new path computation is posted.
  FINE IF:      The endpoint returns `404 Not Found` ("Path not found for the given IPs.") or updates to an alternate active route length.
  WORRYING IF:  The endpoint returns the exact same switch count as before without verifying whether the path's constituent switches and links are currently operational.

Q10. How does the batch flow programming endpoint behave in P4 mode when supplied with OpenFlow match/action structures?
  ASK ME TO RUN: In P4 mode, send `curl -s -X POST http://localhost:8000/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries -H 'Content-Type: application/json' -d '{"install_flow_entries":[{"dpid":1,"priority":100,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.2"},"actions":[{"type":"OUTPUT","port":2}]}],"modify_flow_entries":[],"delete_flow_entries":[]}'`.
  FINE IF:      The call returns an explicit error stating OpenFlow batch installation is unsupported on bmv2, or successfully translates and populates the P4Runtime table entry on switch s1.
  WORRYING IF:  The call returns `200 {"status": "queued", "accepted": 1}` while the P4 proxy silently discards the payload, giving applications a false confirmation of programmed forwarding state.

---

THE SINGLE THING you would most want to see with your own eyes, if you were allowed exactly one look at the running system:
A side-by-side terminal displaying a live stream of the C++ kernel's raw internal dispatch logs alongside the real OpenFlow/P4Runtime tables on the physical/emulated switches while an application executes a flow modification sequence.
