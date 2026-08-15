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

Progress, remaining work and the per-phase plan: `doc/2026-07-27_p4_bmv2_support_plan.md`.
Test procedure and measured results: `doc/2026-07-29_p4_status_and_test_guide.md`.
Machine-specific setup traps: `doc/2026-07-29_environment_gotchas.md`.
What is still open: `doc/2026-07-29_HANDOFF.md`.

### Fixed (crashes and silent failures)

0. **App registration now provisions a writable workspace without root** (2026-08-15,
   `fe6a577`). `setupNFSForApp` chmods the per-app directory instead of chowning it to
   nobody — chown needs root, and on the non-root deployment its failure left the
   directory unwritable through the all_squash export: the Energy app's first simulation
   case write was denied and its decision loop wedged permanently while looking healthy.
   The per-app `/etc/exports` line is now best-effort with a truthful message (a parent
   export covers the directory here), and cleanup checks the exports file before invoking
   sudo, so a start with nothing to clean is silent. The whole non-root lifecycle
   (register → writable dir → silent destructor cleanup) is unit-tested with no root,
   sudo, or NFS server; mutation gate 4/4. Companion tooling fixes from the same
   integration round: stack.sh logs rotate to `.prev` instead of being erased each
   restart, and the proxy's switch-entered push retries in the background instead of
   dying once and declaring the graph permanently degraded.

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

16. **Document the byte order of `src_ip`/`dst_ip` unambiguously** (`doc/2026-01-02_ndt_api.md`, 3 places).
    The existing note, "in network order", is correct — these fields carry `in_addr::s_addr` — but
    it is easy to misread `16777226` as `1.0.0.10` when it is `10.0.0.1`. The note now says so
    explicitly and gives the conversion. Also enumerates the legal `acquire_lock` types
    (`routing_lock`, `graph_lock`, `power_lock`), which were never documented; anything else is
    rejected with a message that does not distinguish "invalid type" from "busy".

17. **The full test stack is green in both modes** (2026-07-31, first time). L0 build check and
    L1 unit tests (141 C++ tests under ctest and direct execution, plus six Python suites);
    L2 API contract and L3 component contract at 31/36 with an *identical* failure set in OVS and
    P4 — the five remaining are pre-existing input-validation gaps, not P4 issues; the log
    allowlist check clean in both; and **L4 differential PASS**, P4 matching the OVS baseline with
    14 accepted differences. Twelve allowlist entries that existed only because P4 could not yet
    serve flow tables or resolve paths were removed, each verified obsolete against the live stack
    rather than inferred from the comparison.

18. **Fix three lifecycle faults in FlowDispatcher** (`d5f5bfa`), which had no tests at all:
    `stop()` iterated and cleared `workers_` unlocked while `enqueue()` inserted under the mutex; a
    lost wakeup deadlocked `stop()` itself because `running_` was written outside the mutex; and
    `enqueue()` spawned workers after `stop()` had moved the map out, leaving a joinable thread with
    no owner. Six lifecycle tests added.

19. **Connect the OpResult chain** (`8c25dbc`). Phase 2 made the routing methods return `OpResult`;
    `Controller`'s sender then discarded every one, so nothing could act on a rejected rule --
    `HttpSession`'s comment claimed otherwise. Unknown dpids are now rejected at request time with
    404 (knowable then, unlike a southbound outcome), and asynchronous outcomes are logged with the
    operation, dpid and the controller's reply. L2 31/36 -> 32/36.

20. **Lock `m_allPathMap` and `m_switchCountMap`** (`0596dd1`), whose mutex was declared and never
    used. Six accesses were unsynchronised while readers took a `shared_lock`, which protects
    readers from each other and nothing else. The periodic destination-path refresh added earlier in
    this branch turned a startup-only race into a permanent one.

21. **Recompute routes when the topology changes** (`2c81b26`). A link failure previously changed
    nothing: `intelligent_router.py` notified the twin and stopped, there was no `remove_edge`
    anywhere in the file, and `install_all_pair_paths` ran exactly once per process. Verified live
    over a full down/up cycle -- traffic moved from s5 to s6 and back.

22. **Answer 400 for a malformed query parameter** (`832d75c`) instead of 500. `?src_ip=not.an.ip`
    and `?dpid=abc` threw out of the parsers into the outermost catch. The new `tryParseUint64` is
    deliberately stricter than `stoull`, which reads "12abc" as 12 and wraps "-1" to 2^64-1.

23. **Report loop failures on their edges** (`f5281a8`). The path-walk loop warned once per
    millisecond per flow: one misconfigured port produced 270,991 lines and a 41 MB log, burying the
    one line that named the fault. `utils::KeyedFailureLog` reports a failure once it has outlasted
    a hold-off, and once more when it clears.

24. **Answer 400 for a malformed simulation case** (`05353d5`) instead of 202 Accepted.
    `/ndt/received_a_simulation_case` never parsed the body -- it went straight into a curl command
    line -- so `{not json` was "accepted" and the empty reply wrapped as `{"status":""}`. The five
    required fields are Simulation-Platform-Manager's own (`get_to(std::string)` on each), so a body
    that fails the new check would have thrown in a process with no way to answer the caller;
    `2026-01-02_ndt_api.md` §17 already documented 400. Also replaces `std::stoi` for `app_id` in
    `/ndt/simulation_completed`, where a mistyped id was a 500 and `"1abc"` silently became app 1
    under a 200 OK. The body still reaches a shell unescaped -- that boundary is stated in the
    header, at the interpolation, and pinned by a test asserting the check is shape-only.

25. **Stop `powerOff` destroying the state it could not read** (`65aaa38`).
    `OVSPowerStrategy::executeListPorts` returned an empty vector both for a bridge with no ports and
    for a failed `ovs-vsctl list-ports` -- pclose's status was discarded, and a nonexistent bridge
    writes nothing and exits 1, so the status was the only difference. `powerOff` wrote that empty
    list over the graph's saved ports *before* checking anything and then deleted the bridge,
    destroying both records of what `powerOn` must reattach; the switch then came back up with no
    ports and was marked UP. Now returns `std::optional` and refuses the whole operation when the
    port list is unknown. Also moves `describeCommandStatus` into `utils` -- this class logged
    `std::system`'s raw wait status, so an exit code of 1 appeared as "status 256".

26. **Report bmv2 switch liveness from evidence** (`a8db425`) instead of asserting it.
    `pingWorker` called `setVertexUp` for every bmv2 switch once a second with no evidence at all,
    so a killed switch reported healthy again within a second and the twin could never show a
    fault -- and `is_up` gates the power, CPU and temperature reports and `getAvgLinkUsage`. The
    proxy now exposes `GET /p4/switch_state` carrying a round-tripped P4Runtime probe plus LLDP
    freshness, and the kernel applies the same three-state policy as the OVS side: Unknown leaves
    the graph alone, because one unreachable proxy must not black out all ten switches. Also
    removes the host force-up, now redundant since the proxy serves `/v1.0/topology/hosts`.
    Two bugs found while testing are fixed here too: one dead bmv2 stopped the whole proxy from
    starting (an unguarded pipeline push, fatal to uvicorn's startup event), and an empty
    `/stats/flow/<dpid>` body produced 216 unallowlisted error lines during one four-minute
    outage.

27. **P4 liveness reported from evidence** (`a8db425`). `pingWorker` called `setVertexUp` for every
    bmv2 switch once a second with no evidence at all, so a killed switch reported healthy again
    within a second. The proxy now exposes `GET /p4/switch_state` carrying a round-tripped P4Runtime
    probe plus LLDP freshness, and the kernel applies the same three-state policy as the OVS side --
    Unknown leaves the graph alone, because one unreachable proxy must not black out ten switches.

28. **The graph keeps up with the control plane** (`71d27c1`). `TopologyAndFlowMonitor::run()`
    fetched once and returned -- measured at 88 milliseconds, after which nothing re-read the
    topology for the life of the process. Whether the graph was complete depended on how long after
    Mininet the kernel happened to start. Now polls every 5s for the first 90s then every 30s, and
    reports only when the counts move.

29. **A snapshot replaces rather than accumulates** (`820c2a2`, `eb9c860`). `Classifier` skipped a
    switch reported with an empty flow table, so `updateOneSwitch`'s sweep never ran and stale rules
    survived indefinitely; `setAllPaths` never cleared its two maps, so a destination path outlived
    the control plane reporting it. Both would keep the twin computing from state that no longer
    exists -- worse than an empty answer, because it looks confident.

30. **Diagnostics that named the wrong thing** (`1b50982`, `1404183`). `describeCommandStatus`
    blamed `ovs-vsctl` for every tool's exit codes once it moved into `utils` and reached 13
    snmpget/snmpwalk call sites; `handleGetNickname` logged a bad `?dpid=` under
    `inform_switch_entered`. Neither changed behaviour; both sent the reader to the wrong place.

31. **Refusals that were wrong in either direction** (`c18b4c9`, `6e156b3`). A hex-string
    `eth_type` -- how OpenFlow tooling normally writes it -- was rejected with 400, and a `match`
    that was not an object became a 500. TESTBED `setSwitchPowerState` updated the graph to whatever
    state the caller *asked for*, regardless of whether the smart-plug gateway accepted the request.

### Known limitations
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
- Updated disable_switch to recalculate all-destination routes and return differences (see 2026-01-02_ndt_api.md)
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
- API changes: add /app_register (see 2026-01-02_ndt_api.md)
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

5. Add a new API, install_flow_entries_modify_flow_entries_and_delete_flow_entries, to install/modify/delete flow entries at once (see 2026-01-02_ndt_api.md).
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

8. ICMP parsing. For ICMP flows, the 5-tuple reuses the "port" fields: src_port -> ICMP type, dst_port -> ICMP code. For non-ICMP flows, src_port/dst_port keep their usual meaning. (see 2026-01-02_ndt_api.md)
---

---

## unreleased — P4/bmv2 support, and the shared-path defects it uncovered

Branch `fix/flow-rate-divide-by-zero`. Grouped by theme rather than by commit, because the
commits are fine-grained on purpose; each item names where the reasoning is written down.

⚠️ **Read this first if you are writing this work up.** A premise that shaped the plan turned out
to be false: the OVS/Mininet simulator was assumed to be functionally correct before the P4 work
began, making P4 support pure addition. Verified against the real baseline (`28b8b13`, the parent
of the P4 groundwork commit), **eleven defects were already present** — an unlocked flow-table
lookup on every sampled packet, two unsigned subtractions that underflow to 1.8e19, a latched
elephant-flow flag, `macToUint64` returning silently wrong MACs, three "snapshot that can only
add" cases, malformed parameters answering 500, and `poll()` with a 0 ms timeout burning 100% CPU
at idle. Every one is *silent* — nothing crashes, nothing logs, every endpoint answers 200 — which
is why the premise looked right. So this work is **two** things, and fixing the shared-path
correctness defects was a prerequisite for the other, because a baseline that lies cannot verify a
new data plane. See `doc/2026-07-29_HANDOFF.md` and the note below on the Ryu wedge for the clearest example.

### 1. Correctness defects in the shared kernel path (affect OVS and P4 alike)

1. **Flow-table data race.** `handlePacket` looked up `m_flowInfoTable` with no lock and then took
   one separately inside each branch, on every sampled packet on every sFlow worker, while the
   purge thread erases at 1 Hz. Also made find-then-branch non-atomic, so two workers on the same
   new key both took the "new flow" path and the loser's assignment discarded the winner's bytes.
   One lock now covers the lookup, both branches and the diagnostic between them.
2. **Unsigned counter deltas underflowing to ~1.8e19**, reported as a flow's bit rate and reaching
   the API. `sflow::counterDelta` saturates at zero. The elephant-flow flag's clearing `else` was
   commented out, so a single lost update latched it for the life of the process; restored.
3. **Three "should replace, can only add" cases**: the topology taken as one startup snapshot and
   never re-read (now polled), `Classifier` skipping empty flow tables so removed rules were never
   swept, and `setAllPaths` never clearing its maps so `get_path_switch_count` answered from routes
   a link failure had deleted. A fourth instance (`Answer::from_json`) is found and unfixed.
4. **`macToUint64` accepted malformed input and returned a wrong MAC** — `"00:11:22:33:44:5"` gave
   73588229125 silently, so the wrong host was looked up. `tryMacToUint64` validates and returns
   optional; the throwing form delegates so every caller inherits the check.
5. **Client errors answering 500 instead of 4xx**, and the same conflation in the log: three sites
   that answer 400 were logging at ERROR, which makes "an error line is never acceptable" unusable.
6. **An unparseable `/stats/flow` body returned `json::array()`**, indistinguishable from "this
   switch has no rules" — and applying that sweeps every rule for the dpid. Now `nullopt`.
7. **`OVSPowerStrategy` destroyed the state it could not read**; `powerOff` now refuses when the
   port list is unknown.

### 2. The Ryu flow-stats wedge

Restarting Ryu under a live Mininet wedges `/stats/flow` into returning an empty table forever.
Reproduced twice and characterised (`doc/audit/2026-08-07_ryu-wedge-trace.tsv`, 151 samples);
**root cause still unproven** after four falsified hypotheses. The harm is fixed without touching
Ryu: a wedged reply takes 1.011 s against 0.027–0.083 s healthy — and 1.0 s is `DEFAULT_TIMEOUT`
in `ryu/lib/ofctl_utils.py` — so an empty table that took ≥ 0.5 s is refused and the previous one
kept. Operationally: **never restart Ryu alone; restart Mininet with it.**

### 3. P4/bmv2 support

Phases 0–2 and 4 complete. Phase 5's flow-sample half is complete and verified against a golden
capture; **its counter-sample half was never implemented**, which turns out to be parity with OVS
rather than a gap, since MININET discards counter samples and derives link usage from flow samples.
Phase 6 is implemented across all six items — switch-entered and link failure/recovery
notifications, evidence-based liveness replacing an unconditional `setVertexUp`, the LLDP beacon
(ports derived from the topology, source MAC no longer colliding with the host range, a crash for
dpid ≥ 256), a real `/stats/flow` in Ryu's string-action shape, and destination paths — but its
test clause and end-to-end verification are outstanding. Phase 7 has its PID manifest and does not
yet use it. Phase 3 and 8 are not started.

### 4. Test and verification infrastructure

379 gtest tests across 43 suites and 240 Python tests, run both under `ctest` and as one process,
because either alone hides failures the other finds. **Every test ships with the mutation that
breaks it** — applied, observed, reverted — with the evidence in `doc/audit/mutation-evidence-*.md`;
this has caught 11 tests that passed while proving nothing. Four false PASSes were fixed in the
tooling itself, including one where `unittest` counts skipped tests inside `Ran N` so a
fully-skipped file reported green, and one where a skip check was dead from the day it was written.
