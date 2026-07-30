# NDTwin Changelog

All notable changes to this project (NDTwin source code, Ryu controller program, ...) are documented in this file.

Refer to the git log for more details if you wish.

---

## Unreleased — P4/bmv2 support (branch `fix/flow-rate-divide-by-zero`)

Adds the ability to drive a P4/bmv2 data plane under Mininet alongside the existing
Open vSwitch/Ryu support. NDTwin applications and the Intent Translator are unchanged:
the P4 proxy agent impersonates Ryu's northbound API, and the proxy synthesises sFlow v5
into the kernel's existing UDP:6343 collector, so `FlowLinkUsageCollector`, `Classifier`
and every `/ndt/` metric work without modification.

Progress, remaining work and the per-phase plan: `doc/p4_bmv2_support_plan.md`.
Test procedure and measured results: `doc/p4_status_and_test_guide.md`.
Machine-specific setup traps: `doc/environment_gotchas.md`.
What is still open: `doc/HANDOFF.md`.

### Fixed (crashes and silent failures)

1. **Fix SIGFPE crash in flow-rate calculation.** The `hopsCounter == 0` divide-by-zero
   guard had been removed; any tracked flow idle for one 1-second tick killed the process.
   Rate arithmetic extracted into `computeEstimatedRates` as a testable seam.

2. **Fix null dereference that crashed the kernel on Ryu's table-miss rule.**
   `Classifier.cpp` called `outputPorts.front()` on rules with no output action — Ryu reports
   a drop as `"actions": []`. Latent until flow tables were actually readable. Note the
   trap: the call sites are `SPDLOG_LOGGER_TRACE`, and spdlog evaluates its arguments even
   when the level is disabled.

3. **Bounds-check the sFlow parser.** It is an externally reachable input surface (anything
   that can send UDP to 6343). Verified with ASan: removing the check reproduces a
   heap-buffer-overflow.

4. **Make southbound failures visible.** Strategy methods return
   `OpResult { ok, httpStatus, message }` and capture curl's real HTTP status; a 200 whose
   body contains `{"status":"error"}` also counts as failure. Previously a dead proxy and a
   successful install were indistinguishable.

5. **Fix data race and unbounded growth** in the ifIndex→ofport map (`operator[]` without
   holding the mutex, which also mapped every unknown port to 0).

### Added (P4 data plane)

6. **Typed `SwitchKind` dispatch** (`OVS`/`BMV2`/`HARDWARE`) replacing a case-sensitive
   substring match on the topology *filename*. O(1) lookup, no per-operation deep copy of
   the graph. Unknown DPIDs log a warning and return an error instead of silently falling
   back to Ryu. Topology homogeneity is validated at load time.

7. **Extended P4 pipeline** (`ndtwin_switch.p4`): a ternary `flow_5tuple` table with real
   priority ahead of `ipv4_lpm`, ARP/TCP/UDP/ICMP parsing, an L2 table so non-IPv4 frames
   are no longer silently dropped, a TTL guard, direct and per-port counters, and 1-in-256
   clone-to-CPU sampling for telemetry.

8. **sFlow synthesis in the proxy** (`sflow_emitter.py`), byte-layout compatible with what
   OVS emits — proven by a cross-language round trip that feeds the Python emitter's real
   output into the C++ parser the kernel actually uses.

9. **Telemetry sample path**: PRE clone session 250 programmed over P4Runtime, and samples
   separated from genuine packet-ins by a `reason` field inside `packet_in` (a third
   controller header compiles but is silently ignored by P4Runtime, which matches
   `packet_in`/`packet_out` by name).

10. **Identity ifIndex→port mapping for all-bmv2 topologies**, skipping `ovs-vsctl`, which
    knows nothing about bmv2 interfaces. Decided lazily so it does not race the topology load.

11. **Headless startup**: `--mode`, `--topology`, `--ai`/`--no-ai` replacing interactive
    `std::cin` prompts.

12. **P4 declares its limits**: group/meter operations return `501 unsupported` rather than
    silently redirecting to Ryu.

### Added (test tooling)

13. **Layered test harness** (`tools/test_workflow/`): L0 build check, L1 unit tests
    (C++ under both ctest and direct execution, plus the P4 proxy's Python tests), L2 API
    contract, L3 component contract, L4 OVS/P4 differential, and `stack.sh` orchestration
    that starts each mode in the order that mode requires.

14. **Fix OVS switch liveness, which reported the whole fabric dead** (`pingWorker`). Two
    independent bugs, whose combined symptom was every node red in the Web GUI with
    `is_up: 0` while traffic was demonstrably flowing:
    `ovs-vsctl list-br` *failing* was indistinguishable from it reporting *no bridges* (both
    yielded an empty vector, read as "everything is down", and `pclose`'s exit status was
    never checked) — so one dropped call marked all ten switches dead; and the branch only
    ever called `setVertexDown`, never `setVertexUp`, so "down" was permanent until Ryu
    happened to re-announce the switch on reconnect. Liveness is now a tested policy
    (`ovsLivenessFor`) over three states, where `Unknown` leaves the graph untouched: "cannot
    tell" must not be reported as "dead". Failure logging is edge-triggered — the query runs
    at 1 Hz and the first occurrence of this bug produced 3596 log lines in a single run.
    Verified live: 0/10 → 10/10 as bridges appear, one bridge deleted drops only that switch,
    and re-adding it brings it back.

15. **Fix the synthetic power figure, which was reporting 1.9x10^14 watts.** MININET mode has no
    PSU to read, so it makes the number up — with
    `uniform_int_distribution<uint64_t>(0, UINT64_MAX >> 4)`, uniform over [0, 2^60), re-rolled
    every poll. Observed: `power_consumed: 193112054821787525` mW. The Energy-Saving application
    consumes this figure, so its decisions were made on noise. There were also two independent
    copies of the RNG, so `/ndt/get_power_report` and the Intent Translator's per-device query
    disagreed about the same switch at the same instant. Now one seeded helper, giving a stable
    30–150 W per switch (measured live: 33.5–147.6 W across the ten, unchanged across polls). The
    useful signal — 0 W when a switch is powered off — is unaffected. The neighbouring synthetic
    CPU (10–59%) and temperature (25–49 °C) values were already plausible.

16. **Document the byte order of `src_ip`/`dst_ip` unambiguously** (`doc/ndt_api.md`, 3 places).
    The existing note, "in network order", is correct — these fields carry `in_addr::s_addr` — but
    it is easy to misread `16777226` as `1.0.0.10` when it is `10.0.0.1`. The note now says so
    explicitly and gives the conversion. Also enumerates the legal `acquire_lock` types
    (`routing_lock`, `graph_lock`, `power_lock`), which were never documented; anything else is
    rejected with a message that does not distinguish "invalid type" from "busy".

### Known limitations

- P4 switch liveness is still a stub: `pingWorker` reports every bmv2 switch up
  unconditionally, so a powered-off switch reports UP within 1 second and the twin cannot
  report a fault. Needs the proxy's gRPC channel state plus LLDP freshness. Remaining
  Phase 6 work, tracked in `doc/HANDOFF.md`.
- Every southbound command is still built as `popen("curl … -d '" + json.dump() + "'")`.
  `nlohmann::json::dump()` does not escape single quotes and the JSON comes from
  unauthenticated REST bodies and LLM output. Deliberately deferred; 22 sites in 3 files.

---

## tag v3.1.0
Tagger: nslab RA <nslab@citi.edu.tw>
Date:   Wed Jun 25 17:33:53 2025 +0800

Major update:
- Enhanced get_graph_data with device_name, mac, and IP array
- Fixed Mininet link bandwidth field bug
- Added APIs: inform_switch_entered, modify_device_name
- Fixed flow handling (add-delete-add crash)
- Improved switch status detection via ping
- Updated host<->switch link stats (bandwidth, flow set)
- Prevented path selection with disabled switches
---

## tag v3.2.0
Tagger: nslab RA <nslab@citi.edu.tw>
Date:   Fri Jul 4 09:32:01 2025 +0800

feat: major NDT enhancements

- Use StaticNetworkTopology.json to describe the complete network topology.
  (get_graph_data API now retrieves the full topology instead of detected topology)
- Refactored ControllerAndOtherEventHandler to use async I/O.
- Store link bandwidth usage every 5 minutes for model training.
- Add device_layer and brand_name metadata at each node. (get_graph_data API can retrieve now)
- Change start_time and end_time to first_sampled_time and latest_sampled_time. (get_graph_data API)
---

## tag v4.0.0
Tagger: nslab RA <nslab@citi.edu.tw>
Date:   Tue Jul 15 12:10:51 2025 +0800

Release v4.0.0: major API and functionality updates

- Changed to preinstalled all-destination routing entries for scalability (no packet-in per flow; removed initial routing policy selection)
- Updated disable_switch to recalculate all-destination routes and return differences (see ndt_api.md)
- Renamed APIs:
    - get_openflow_flow_table -> get_switch_openflow_table_entries
    - get_flow_table_data -> get_detected_flow_data
- Added ability for modify_device_name results to be written to StaticNetworkTopology.json
- Improved get_detected_flow_data to return correct flow 5-tuple information
- Updated get_graph_data API:
    - Flows in flow_set now inserted when detected via sFlow
    - Flows removed if undetected for more than 15 seconds
---

## tag v4.0.1
Tagger: nslab RA <nslab@citi.edu.tw>
Date:   Tue Jul 22 15:55:52 2025 +0800

v4.0.1 major changes:

- Add SimulationRequestManager Module to relay messages between application and simulation server
- Add ApplicationManager Module to handle application registration and setup NFS
- Fix Bugs (like weird doubling topology after 5000s)
- Move HttpSessions function from .hpp to .cpp
- API changes: add /app_register (see ndt_api.md)
- Optimize mutex locks and request sending method

---

## tag v4.1.0
Tagger: nslab RA <nslab@citi.edu.tw>
Date:   Fri Jul 25 11:54:28 2025 +0800

v4.1.0 major changes:

- Change API parameter names ('src_port', 'dst_port', or 'port'), when they don’t denote the flow 5‑tuple ports, to 'interface' for clarity.
- Add 'received_a_simulation_case' and 'simulation_completed' APIs for applications to communicate with the simulation server.
- Fix the 'setPowerStateMininet' bug.
- Add the 'findVertexByMininetBridgeName' function for the intent‑to‑tasks translator module.
- received_a_simulation_case API can get response from simulation server.
- Change NFS server folder authority after application registration.
---

## tag v4.1.1
Tagger: nslab RA <nslab@citi.edu.tw>
Date:   Tue Aug 12 14:43:11 2025 +0800

v4.1.1 major changes:

- Add 'GET /ndt/get_nickname' to retrieve a device's alias by DPID, MAC, or name.
- Add 'POST /ndt/modify_nickname' to update a device's alias.
- Add 'GET /ndt/get_temperature' for polling switch operating temperatures.
- Add 'GET /ndt/get_path_switch_count' to calculate the number of switches between two IP addresses.
- Change to larger topology (10 switches).
---

## tag v4.2.0
Tagger: nslab RA <nslab@citi.edu.tw>
Date:   Mon Aug 25 10:21:01 2025 +0800

Release v4.2.0

1.tag v4.2.0
Tagger: nslab RA <nslab@citi.edu.tw>
Date:   Mon Aug 25 10:21:01 2025 +0800

Release v4.2.0

1. Reparse sFlow datagram for HPE 5520 switch and consider both ingress and egress sampling when calculating average sFlow sending rate.

2. In get_detected_flow_data API, change 'first_sampled_time_ms' and 'latest_sampled_time_ms' to 'first_sampled_time' and 'latest_sampled_time', and return time string.

3. Check whether there are remaining NFS folders for applications.

4. Address CORS issue.

5. Add a new API, install_flow_entries_modify_flow_entries_and_delete_flow_entries, to install/modify/delete flow entries at once (see ndt_api.md).
---


## tag v4.3.0

Tagger: nslab RA [nslab@citi.edu.tw](mailto:nslab@citi.edu.tw)
Date:   Thu Aug 28 10:21:01 2025 +0800

Release v4.3.0



1. Add new APIs for OpenFlow **group entries**:

   * **POST `/ndt/install_group_entry`**: Install a new OpenFlow group entry in a switch.
   * **POST `/ndt/delete_group_entry`**: Delete a group entry from a switch.
   * **POST `/ndt/modify_group_entry`**: Modify an existing group entry in a switch.

2. Add new APIs for OpenFlow **meter entries**:

   * **POST `/ndt/install_meter_entry`**: Install a new meter entry in a switch.
   * **POST `/ndt/delete_meter_entry`**: Delete a meter entry from a switch.
   * **POST `/ndt/modify_meter_entry`**: Modify an existing meter entry in a switch.

3. Add **GET `/ndt/get_openflow_capacity`** to retrieve supported OpenFlow capabilities (groups, meters, tables, etc.) from switches.

4. Add **GET `/ndt/historical_logging`** with query parameter `state=enable|disable` to enable or disable historical data logging.

5. Update **GET `/ndt/get_path_switch_count`**. If omitted source and destination IPs, all paths counts will be returned.

6. Fix `get_openflow_capacity` API output.

7. Fix `PurgeIdleFlows`, `flow set`, `flow sending rate` bug.

8. ICMP parsing. For ICMP flows, the 5-tuple reuses the "port" fields: src_port -> ICMP type, dst_port -> ICMP code. For non-ICMP flows, src_port/dst_port keep their usual meaning. (see ndt_api.md)
---
