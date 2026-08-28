# NDTwin Kernel — Chaos / Fuzz Action-Surface Specification

Status markers: **OBSERVED** = read in source with path:line. **INFERRED** = reasoned from code; not run.
"Would need X" = could not be established from source; do not assume.

## 0. Route table (OBSERVED, src/ndt_core/http/HttpSession.cpp:145-317)

The kernel serves HTTP on port 8000 (per task brief; port source not yet re-verified in this run).
Routing is a plain `if/else` chain on exact string match or `starts_with` (so `/ndt/set_switches_power_state` with any query string, and any prefix extension of `starts_with` routes, are matched).

| Method | Path (match) | Handler |
|---|---|---|
| OPTIONS | any | 204 (line 138-142) |
| POST | == `/ndt/link_failure_detected` | handleLinkFailure (147) |
| POST | == `/ndt/link_recovery_detected` | handleLinkRecovery (151) |
| GET | == `/ndt/get_graph_data` | handleGetGraphData (155) |
| GET | == `/ndt/get_detected_flow_data` | handleGetDetectedFlowData (159) |
| GET | starts_with `/ndt/get_detected_top_k_flow_data` | handleGetDetectedTopKFlowData (163) |
| GET | == `/ndt/get_switch_openflow_table_entries` | handleGetSwitchOpenflowEntries (167) |
| GET | == `/ndt/get_power_report` | handleGetPowerReport (171) |
| GET | starts_with `/ndt/get_switches_power_state` | handleGetSwitchesPowerState (175) |
| POST | starts_with `/ndt/set_switches_power_state` | handleSetSwitchesPowerState (179) |
| POST | == `/ndt/install_flow_entry` | handleInstallFlowEntry (183) |
| POST | == `/ndt/delete_flow_entry` | handleDeleteFlowEntry (187) |
| POST | == `/ndt/modify_flow_entry` | handleModifyFlowEntry (191) |
| POST | == `/ndt/install_group_entry` | handleInstallGroupEntry (195) |
| POST | == `/ndt/delete_group_entry` | handleDeleteGroupEntry (199) |
| POST | == `/ndt/modify_group_entry` | handleModifyGroupEntry (203) |
| POST | == `/ndt/install_meter_entry` | handleInstallMeterEntry (207) |
| POST | == `/ndt/delete_meter_entry` | handleDeleteMeterEntry (211) |
| POST | == `/ndt/modify_meter_entry` | handleModifyMeterEntry (215) |
| POST | == `/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries` | handleInstallModifyDeleteFlowEntries (220) |
| GET | == `/ndt/get_cpu_utilization` | handleGetCpuUtilization (224) |
| GET | == `/ndt/get_memory_utilization` | handleGetMemoryUtilization (228) |
| GET | starts_with `/ndt/inform_switch_entered` | handleInformSwitchEntered (232) |
| POST | starts_with `/ndt/modify_device_name` | handleModifyDeviceName (236) |
| POST | starts_with `/ndt/received_a_simulation_case` | handleReceivedSimulationCase (240) |
| POST | starts_with `/ndt/simulation_completed` | handleSimulationCompleted (245) |
| GET | starts_with `/ndt/get_static_topology_json` | handleGetStaticTopology (249) |
| POST | starts_with `/ndt/inform_all_destination_paths` | handleInformAllDestinationPaths (254) |
| POST | starts_with `/ndt/app_register` | handleAppRegister (258) |
| POST | starts_with `/ndt/intent_translator/text` | handleInputTextIntent (262) |
| GET | starts_with `/ndt/get_nickname` | handleGetNickname (266) |
| POST | == `/ndt/modify_nickname` | handleModifyNickname (270) |
| GET | starts_with `/ndt/get_temperature` | handleGetTemperature (274) |
| GET | starts_with `/ndt/get_path_switch_count` | handleGetPathSwitchCount (278) |
| GET | starts_with `/ndt/get_openflow_capacity` | handleGetOpenflowCapacity (282) |
| POST | starts_with `/ndt/historical_logging` | handleSetHistoricalLoggingState (286) |
| GET | starts_with `/ndt/get_average_link_usage` | handleGetAvgLinkUsage (290) |
| POST | starts_with `/ndt/get_total_input_traffic_load_passing_a_switch` | handleGetTotalInputTrafficLoadPassingASwitch (295) |
| POST | starts_with `/ndt/get_num_of_flows_passing_a_switch` | handleGetNumOfFlowsPassingASwitch (300) |
| POST | starts_with `/ndt/acquire_lock` | handleAcquireLock (304) |
| POST | starts_with `/ndt/renew_lock` | handleRenewLock (308) |
| POST | starts_with `/ndt/release_lock` | handleReleaseLock (312) |
| other | — | handleNotFound → 404 (316) |

Global exception mapping (OBSERVED, HttpSession.cpp:319-347):
- `json::exception` → **400** with `{"error":"JSON parsing error"}` body (321-322). Logged WARN.
- `std::exception` → **500** with details (333-334). Logged ERROR.
- unknown → 500 (341).
Note: a handler that parses the body *after* doing work, or parses only part of the body before mutating state, can answer 400 *after* the mutation happened. Every write handler must be checked for this ordering. (This is the prior finding "answered 400 but installed a rule anyway" — to be re-verified per-handler.)

Connection mechanics (OBSERVED, HttpSession.cpp:58-101, 350-392): one request at a time per connection, keep-alive honoured; `onWrite` takes `after_write_` and runs it on a **detached** `std::thread` (line 380). Detached thread running hook code after response write is a race surface for rapid repeats on one connection.

Startup/shutdown order (OBSERVED, src/main.cpp:393-428):
1. `topologyAndFlowMonitor->start()` (393)
2. `collector->start(20, 4096)` — throws → exit if sFlow socket bind fails (400-412)
3. `historicalDataManager->start()` (414)
4. `handler->start()` — this is presumably where the HTTP listener opens (415)
5. `deviceConfigurationAndPowerManager->start()` (416)
Then main loop polls `gShutdownRequested` (SIGINT sets it, main.cpp:150-154, 314) every 200 ms.
Shutdown order: topologyAndFlowMonitor->stop(), collector->stop(), historicalDataManager->stop(), handler->stop(), deviceConfigurationAndPowerManager->stop() (424-428).
INFERRED: there is a window in which the HTTP port is accepting while some subsystems are not yet started (between 415 and 416), and requests can arrive between SIGINT and handler->stop(). Need to check which handler is `handler` and whether its start() opens the acceptor before deviceConfigurationAndPowerManager->start().

## 1. Northbound HTTP API abuse

### 1.1 400-but-mutated probes (per write handler)
Prior finding to verify: "a request answered 400 was observed to install a rule anyway". From the code read so far:

- `handleLinkFailure` (HttpSession.cpp:403-461): parses payload via `parseLinkFailedEventPayload` **before** mutating; on failure returns 400 without touching state (406-412). BUT on a one-way topology the forward edge is set down and events emitted, then it answers **500** (428-455) — the caller gets an error status *after* partial mutation. A correct system should either not mutate or roll back; observable: retry of the same request after the 500 answers 404 "edge not found"? No — edge still exists, just down. Observable defect: after 500, `get_graph_data` shows the forward edge down while reverse is up.
- `handleLinkRecovery` (463-521): body is parsed field-by-field, all four fields checked first (467-475) → 400 before mutation. Same partial-mutation-on-missing-reverse-edge shape at 499-517: forward edge already `setEdgeUp`, reverse missing → 500 with half-done state. Also **no event emitted** for recovery (497: `// TODO: Emit LinkRecoveryDetected event`) — asymmetry vs failure (429-430, 458-459).
- `handleSetSwitchesPowerState` (647-673): query params validated (656-661) before `setSwitchPowerState`. Body is never read. Wrong-typed/extra body fields are irrelevant; only `ip` and `action` query params matter.
- `handleInstallFlowEntry/DeleteFlowEntry/ModifyFlowEntry` (675-718): `json::parse(m_req.body())` then single-entry arrays into `processFlowBatch`. Parse happens before dispatch — but must verify `processFlowBatch` validates each entry *before* applying any of them (an array/batch could fail on entry 3 after applying entries 1-2).
- Remaining write handlers (group/meter batch, simulation_case, modify_device_name, modify_nickname, app_register, inform_switch_entered, acquire/renew/release lock, historical_logging) still to be read.

### 1.2 Concrete abuse actions
(To be refined as each handler is read.)

A1. `POST /ndt/link_failure_detected` with malformed JSON / missing fields / wrong types → expect 400 and `get_graph_data` unchanged. Defect if any edge went down.
A2. `POST /ndt/link_failure_detected` with a valid but **nonexistent** (src,dst) pair → expect 404 (424) and no mutation.
A3. `POST /ndt/link_failure_detected` then immediately `POST /ndt/link_recovery_detected` (rapid repeat on one keep-alive connection) → expect edges up/down flips; watch for lost updates in the flowSet/leftBandwidth bookkeeping (get_graph_data:551-567).
A4. Failure on one direction then recovery on the *reverse* direction → expect symmetric handling.
A5. `POST /ndt/set_switches_power_state?ip=<valid>&action=on` repeated rapidly, alternating on/off → this is the known-defect area (power-on reported success without acting). Expect each response to reflect actual state via `get_switches_power_state`.
A6. All three flow-entry endpoints with: empty body `{}`, missing dpid, dpid as string, priority as string/float, match as array vs object, actions as string. Expect 400 and no change in `get_switch_openflow_table_entries`.

## 2. Power management (src/ndt_core/power_management/)
Not yet read this run. Prior audit found "power-on reports success without acting" — to re-verify in `DeviceConfigurationAndPowerManager::setSwitchPowerState` and `P4PowerStrategy` / `OVSPowerStrategy`.

## 3. Topology perturbation — to be written after reading TopologyAndFlowMonitor edge handling.

## 4. Traffic-pattern abuse — to be written after reading FlowLinkUsageCollector.

## 5. Lifecycle abuse — partially above (main.cpp order); refine after reading ControllerAndOtherEventHandler start/stop and HttpSession acceptor creation.

## 6. EventBus subscriber check
`src/event_system/EventBus.cpp` is 36 bytes — almost certainly an empty file. `include/event_system/EventBus.hpp` to be read. Prior round: zero production subscribers. HttpSession *emits* LinkFailureDetected (429-430, 458-459) but LinkRecovery has a TODO (497). If nobody subscribes, link-failure events go nowhere; any action that assumes an event triggers recovery must not.
### 1.3 Handler-by-handler findings (OBSERVED, all in src/ndt_core/http/HttpSession.cpp)

**Flow batch endpoints** (`/ndt/install_flow_entry|delete_flow_entry|modify_flow_entry|install_flow_entries_modify_flow_entries_and_delete_flow_entries`, all funnel to `processFlowBatch` 890-1099):
- Shape validation happens **before** any mutation (collectShapeProblems 929-961): bad shape → 400 and "nothing was queued". Good: the 400-does-not-mutate property is claimed and appears to hold here — no dispatch before the 400 return. VERIFY with: send `{"install_flow_entries":[{"dpid":1,"match":[],"actions":[]}]}` (wrong-typed match) → expect 400 and `get_switch_openflow_table_entries` unchanged.
- BUT mutation-after-validation ordering: `m_deviceConfigurationAndPowerManager->updateOpenFlowTables(j)` runs at 1061 **after** `enqueue` at 1058 — and it is called with the *raw request json `j`*, not the filtered accepted jobs. INFERRED: if `updateOpenFlowTables` stores `j` wholesale, the in-memory OpenFlow table copy can contain entries whose dpids were rejected (or entries rejected by shape? No — shape rejection returns earlier; but unknown-dpid entries DO reach line 1061 inside `j`). Probe: batch with one known dpid + one unknown dpid → response 200 with `rejected:1`; then check `get_switch_openflow_table_entries` — if the unknown-dpid entry appears there, the kernel's table diverges from what was queued. This is a "should replace / can only add"-shaped defect candidate (TODO at 1060: "Immediately update the table").
- `makeInstallJob` uses `entry.at("dpid")` → `json::out_of_range` → caught at 983-991 → 400. Missing dpid is a 400 with no mutation. OK.
- Accept response is 200 `{"status":"queued"}` — asynchronous dispatcher; per-entry outcomes only in logs (1079-1098). A correct system must not claim installation.

**Link failure/recovery** (`handleLinkFailure` 403-461, `handleLinkRecovery` 463-521):
- Failure: payload validated by `parseLinkFailedEventPayload` first (406); unknown edge → 404 with **no mutation** (421-427). Then forward edge `setEdgeDown` + event **before** checking the reverse edge exists (428-432, 432-456). If reverse missing → 500 with forward already down. Defect observable: half-down edge pair; recovery request for the same pair afterwards does the mirror image (recovery sets forward up at 496, then 500 at 499-517). A ping-pong failure/recovery against a one-way edge can leave edges in mismatched states while both requests "failed".
- Recovery emits **no** event (TODO, 497) while failure emits two LinkFailureDetected events (429-430, 458-459). Asymmetric; and `LinkRecoveryDetected` exists in the enum but nothing emits it here. (EventBus subscribers checked below.)
- Both handlers ignore `src_interface`/`dst_interface` for edge lookup — only (srcDpid,dstDpid) used (421, 489). Wrong interface values are accepted silently. Probe: valid dpids, absurd interfaces → 200 and edge down. Defect if the caller's report of *which* interface failed is meant to be honoured (link-level vs edge-level semantics).

**Power state** (`handleSetSwitchesPowerState` 647-673): query-param driven; `ip`+`action` checked (656-661) before `setSwitchPowerState` (663). Body ignored entirely. Return of `setSwitchPowerState` mapped to 200 `{ip:"Success"}` or 500 (664-672). The known "reported success without acting" defect would live inside `DeviceConfigurationAndPowerManager::setSwitchPowerState` (read next).

**inform_switch_entered** (1123-1175): `?dpid=` parsed from target; bad/non-numeric → 400 (1129-1162); unknown switch → 404 (1164-1170); else `setVertexUp` + `setVertexEnable` (1172-1173). Note: `setVertexEnable` immediately follows `setVertexUp` — can never be disabled by this route; no way to inform a switch *left*. Mutates after all validation. Rapid-repeat abuse: repeated same-dpid requests are idempotent; but there is no debounce — a fuzz loop of alternating unknown/known dpids is cheap.

**modify_device_name** (1177-1232): `body.at("vertex_type").get<int>()` — a missing `vertex_type` throws `json::out_of_range` → global catch → **400** (before mutation, fine). BUT wrong-typed `new_name` (e.g. number) throws `json::type_error` → also 400. `vertex_type` out of {0,1} → 400 (1216-1221). Mutation (`setVertexDeviceName`, 1230) happens last. Prior finding "400 installed a rule anyway" does NOT match this handler by inspection — but note the MAC branch parses mac (1198-1214) before lookup. No write-after-400 path found here. Still: probe type-confusion, e.g. `vertex_type: "0"` (string) vs 0.

**received_a_simulation_case** (1234-1261): validates 5 required fields via `SimulationRequestManager::validateRequestBody` → 400 before `requestSimulation` (1244-1255). Then wraps `requestSimulation`'s *return string* in `{"status":"<resp>"}` and answers **202 always** (1257-1260). INFERRED: if `requestSimulation` fails internally (curl error, bad response from SIM server) and returns an error string, the kernel still answers 202 with `{"status":"<error string>"}` — success-shaped status with failure content. Defect observable: point `SIM_SERVER_URL` at a dead port, POST a valid case → expect 202 with a status string that is not "accepted"; a correct system would reflect failure in the HTTP status.

**simulation_completed** (1263-1292): app_id parsed via tryParseUint64 → 400 on garbage (1273-1284); then `onSimulationResult` then 200 (1287-1291). Note: body other than app_id is forwarded unvalidated.

**inform_all_destination_paths** (1304-1355): `body.at("all_destination_paths")` — missing key → json::out_of_range → 400 before mutation. Each hop validated by `tryParsePathNode` → 400 with **no partial application** (rejects whole request, 1331-1345) — but note: earlier hops already parsed into `tempPath` are local; nothing published before the reject. Empty path list → `setAllPaths({})` with 200 `{"status":"success"}` (1348-1354) — this **wipes** all learned paths with a single empty body. That is a "replace with nothing" surface: if the collector's path table is the basis of switch-count queries (`get_path_switch_count`, `getSwitchCount`), an empty POST silently destroys it. Probe: POST valid paths → check counts; POST `{"all_destination_paths":[]}` → counts should become empty; then GET path counts. Also abuse: non-array `all_destination_paths` (e.g. string) — `for (const auto& pathJson : allPathsJson)` iterates a string → each `pathJson` is a one-char string; `tryParsePathNode(char)` should fail → 400. Check `setAllPaths` semantics in collector for replace-vs-append (next read).

**app_register** (1357-1397): validates `app_name` and `simulation_completed_url` presence+type → 400 before `registerApplication` (1365-1385). `registerApplication` assigns an appId and returns 200 always (1387-1396). INFERRED accumulation risk: does ApplicationManager ever evict app ids? Repeated registrations grow the table — "should replace, can only add" candidate: register the same app name repeatedly and watch the table (needs ApplicationManager read).

**intent_translator/text** (1399-1445): guarded null translator → **503** when `--no-ai` (1414-1422). Body parsed, `body["prompt"]` and `body["session"]` via `.get<std::string>()` — missing key → json::out_of_range → caught → 400. Wrong type (number prompt) → `json::type_error` → 400. No mutation on 400. With AI enabled: absurd prompt length / special chars goes to OpenAI (out-of-process); TBD whether IntentTranslator has timeout.

**get_nickname** (1447-1559): reads only; `?dpid=`, `?mac=`, `?name=` params; bad dpid/mac → 400 (1483-1529); name search only compares `deviceName` (1539), not nickName, despite the comment at 1538. Finding: after `modify_nickname` changes nickName only, `get_nickname?name=<old deviceName>` still finds it; `get_nickname?name=<new nickname>` does NOT (would need to verify setVertexNickname only touches nickName). Probe: modify nickname, then query by new nickname name → expect 404, showing name-search ignores nickName. Minor but observable inconsistency.

**modify_nickname** (1561-1644): try/catch around everything; `body.at("identifier").at("type")` — missing → 400 via local catch (1639-1642). Invalid `type` string throws `runtime_error` → 400 (1619, 1641). Mutation at 1633 after lookups. No mutation-before-400 found. BUT: identifier `type:"dpid", value:"abc"` → `get<uint64_t>` throws type_error → 400 (local catch) — fine. Note the local catch answers 400 for *any* exception, including ones thrown by `setVertexNickname` internals — if that ever throws mid-mutation, the client sees 400 after a possible partial mutation. Low-probability, flag for stress.

**get_path_switch_count** (1653-1743): GET; both params → validated by tryIpStringToUint32 → 400 (1676-1691); single param silently falls to the all-counts branch (1713-1740) — asymmetric: `?src_ip=` only returns the full table, not an error. Correctness question: a client that dropped `dst_ip` believes it got the path count. Abuse: `?src_ip=10.0.0.1&src_ip=10.0.0.2` (duplicate param) — depends on `utils::queryParam` (read later; if it takes first or last occurrence).

**get_openflow_capacity** (1745-1763): reads `../doc/2026-01-02_OpenflowCapacity.json` **relative to CWD**. If the file is missing: logs ERROR and `return`s with **no status and empty body** → response stays at whatever buildResponse set (200) with empty body (1749-1754). Defect observable: rename the file, GET the endpoint → 200 with empty body, which clients parse as valid JSON? No — empty body is not JSON; a client would fail to parse a 200. Probe. Also this is the only handler reading a local file — cwd-dependent behaviour.

**historical_logging** (1765-1819): `?state=enable|disable` validated before `setLoggingState` (1774-1790). MININET mode: `canRecord()` false → 200 with `recording:false` (1801-1809). Good.

**get_total_input_traffic_load_passing_a_switch / get_num_of_flows_passing_a_switch** (1831-1898): POST with body; missing dpid → 400 (1860-1867, 1891-1897). Body `dpid` as string → `get<uint64_t>` throws type_error → global 400. Wrong `dpid` type number → ok. Non-object body (e.g. array) → `contains` works, `.at` throws → 400. Reads only.

**Lock endpoints** (1911-2076):
- acquire (1911-1955): **swallows JSON parse failures** and proceeds with defaults (1928-1931)! A body that is present-but-garbage still acquires the *default* lock and answers 200. Direct violation of the "rejection means nothing happened" property — the request isn't even rejected; it is silently reinterpreted. Probe: POST `/ndt/acquire_lock` body `{{{` → expect 200 `{"status":"locked","type":...,"ttl":...}`. This is a fuzz-visible defect by construction.
- `ttl` from JSON is not validated: `jsonBody.value("ttl", ...)` with a string value → `get<int>` throws → caught by inner catch(...) → defaults used, lock still acquired with default TTL. Negative/absurd ttl (e.g. -1, 2^31) accepted as-is if numeric (1925-1926) — need LockManager read to see clamping. Rapid acquires of the same type: second → 423 Locked (1943-1947). Renew without holding → 412 (1989-1994). Release with unparseable non-empty body → 400 **before** unlocking (2018-2032) — good. Release with `type` non-string → 400 before unlock (2040-2047) — good. Release unknown type → 412 (2058-2065). TTL-expiry race: acquire with ttl=1, sleep, release → 412. Defect probe: acquire ttl=1, wait, then release → expect 412 (expired); then re-acquire should succeed — if LockManager never actually expires the lock, re-acquire returns 423 forever (stale lock that never disappears — an ingest/accumulation defect).

**CPU/memory/temperature/power-report/graph/flow-data endpoints**: pure reads (1110-1121, 1647-1651, 613-624). get_detected_top_k_flow_data: bad `k` (non-numeric) → WARN and k stays 50 (591-601); `k<0` → 0 (603-606); huge k → to `getTopKFlowInfoJson` (TBD: sorting cost per request — a repeat-loop of huge-k requests is a CPU-abuse action).
## 2. Power management (OBSERVED)

Files: src/ndt_core/power_management/{DeviceConfigurationAndPowerManager.cpp, P4PowerStrategy.cpp, OVSPowerStrategy.cpp}.

### 2.1 Entry point
`setSwitchPowerState(ip, action)` (DeviceConfigurationAndPowerManager.cpp:1328-1353):
- TESTBED: looks up `switchSmartPlugTable` by switch IP; unknown IP → false → HTTP 500 (1334-1344). Note asymmetry: unknown IP gives **500**, not 404, and HttpSession maps false → 500 "Failed to change switch power state".
- MININET: `utils::ipStringToUint32(ip)` (1349) — HttpSession only checked `ip.empty()`. A non-numeric ip **throws** here; the throw propagates to HttpSession's global `std::exception` catch → **500** (HttpSession.cpp:333-334). Probe: `action=off&ip=abc` → expect 500 with `details: stoi...`; a correct system answers 400. OBSERVED shape (ipStringToUint32 to be confirmed in Utils.cpp — flag: verify it throws).

### 2.2 MININET path (setPowerStateMininet, 1438-1500)
- Finds vertex by ipUint; missing → false (1441-1445). Strategy chosen by dpid via `getPowerStrategyForDpid` (1459); null → false.
- Strategy result is honoured: failure → false → HTTP 500 (1487-1495); success → true → HTTP 200 (1498-1499). **The prior "power-on reports success without acting" shape is closed here by inspection** — `OpResult` is checked and both strategies return failure when their commands fail (OVSPowerStrategy.cpp:114-125, P4PowerStrategy.cpp:55-63). BUT the seam is `std::system()` and the command **strings**: OVS runs `"sudo ovs-vsctl add-br ... && sudo ovs-vsctl set bridge ..."` (OVSPowerStrategy.cpp:101-102). If sudo is passwordless-but-broken, or the bridge already exists, `add-br` exits 1 → allOk=false → 500. Correct system: also verify `set-controller` result (line 112) — it is checked (run()). Note: on powerOn for an already-up switch both strategies return success immediately (OVS:73-77, P4:46-49) — idempotent.

### 2.3 TESTBED path (setPowerStateTestbed, 1355-1436)
- Validates action (1370-1378); runs `buildRelayPowerCommand(GW_IP, si, action)` via `utils::execCommand`, then `interpretRelayResponse` (1382-1383).
- If relay reports !ok → **graph left as it was**, returns false → 500 (1385-1399). Honest.
- If relay ok but no graph vertex → plug switched, graph not updated → false → **500** with network/twin disagreement (1401-1413). Defect-observable: power actually flipped but caller told failure; subsequent `get_switches_power_state` disagrees with reality.
- On success: setVertexUp/Down then true (1415-1429).
- Chaos surface here is about the *relay*: GW_IP from AppConfig; slow/hung relay (execCommand blocking — need to check whether execCommand has a timeout; if not, a hung curl blocks the HTTP thread). Probe: point GW_IP at a blackhole IP → how long does the HTTP request hang? (execCommand timeout TBD).

### 2.4 The known prior finding is *not* gone from the twin's view
`getSwitchesPowerState` / `get_power_report` / CPU / memory / temperature are all served from **caches** written by `statusUpdateWorker` every 10 s (m_cachedPowerReport etc., getters at 1919-1938; worker loop 1860-1873 with 10×1 s sleep). So after a successful power-on/off, the API's own power-state endpoint can lag reality by up to 10 s. Probe: power off → immediately GET power state → expect the cached (stale) state; defect if the *graph*-derived endpoint claims Up while the switch is down (need to read getSwitchesPowerState to see if it reads cache or graph — TBD).

### 2.5 OpenFlow-table cache (`updateOpenFlowTables`, 1986-2148) — the 400-but-applied finding, re-verified
- The comment block at 1971-1984 records the measured defect: "A body missing only `priority` therefore programmed the switch and answered 400 ... measured live 2026-08-17 on a bmv2 fabric, switch 1 going from five entries to six while the caller was told its request had been rejected." Root cause was `.at()` here vs `.value()` defaults in makeInstallJob. **Current code uses `.value()` with the same defaults (2038-2087)**, and doc/audit/2026-08-17_install-rejected-but-applied.md exists. So the specific trigger appears fixed on this branch; the *shape* remains probeable: any field that makeInstallJob tolerates but updateOpenFlowTables rejects would re-create it. Current mismatch candidates: `match` fields. `extractKey` uses `match.value("ipv4_src"/"ipv4_dst")` → `parseIpv4U32` **throws runtime_error** on invalid IP string (1960-1968) — and this throw happens in the HTTP thread *after* `m_controller->dispatcher().enqueue(...)` (HttpSession.cpp:1058) and *after* some cache writes may have been done for earlier entries in the same batch. An install entry with `match.ipv4_src:"not-an-ip"` therefore: (a) gets queued to the real data plane (shape check passes — need to confirm describeFlowEntryShapeProblem doesn't validate IPs), (b) throws in updateOpenFlowTables → global 500. **Probe: POST install with match ipv4_src:"abc" → expect 500 AND check whether the flow was programmed** (get_switch_openflow_table_entries after worker refresh / switch table on bmv2). This is a live re-instantiation of "error status, mutation happened" — must verify describeFlowEntryShapeProblem first (TBD).
- **Accumulation, not replacement** (the second prior finding, OBSERVED): `installOne` always `flows->push_back(newFlow)` (2089) — no dedup by (match, priority). Repeated installs of the same rule accumulate duplicates in `m_cachedOpenFlowTables` until `openflowTablesUpdateWorker` overwrites the cache from Ryu every 10 s (1877-1910). `modifyOne` only fixes the **first** match and silently no-ops if the key doesn't match (2102-2114); `deleteOne` removes all matches (2127-2130). Probes:
  - Install the same rule 5× in a burst (within one 10 s window) → GET `get_switch_openflow_table_entries` shows 5 copies. Correct system: cache mirrors switch semantics (same match+priority replaces).
  - Install with `table_id:1`, then modify with `table_id` omitted (defaults to 0) → extractKey differs → cache modify no-ops while dispatcher sends the modify to the real switch. Cache/reality divergence within the 10 s window.
  - Install with `priority` omitted, then delete with `priority` omitted: delete uses `extractKey` on cached entry which has priority default 0 — matches. OK.
  - Burst of deletes after an install in the same window → cache drops them; real switch may still be processing. Races between 10 s cache refresh and just-applied entries: an install at t=0, worker refresh at t=0.5 fetched *before* the proxy applied → cache loses the entry until next poll (10 s). Defect observable: entry absent from GET for a full poll cycle despite "queued".

### 2.6 P4 specifics (P4PowerStrategy.cpp)
- powerOn: helper `sudo -n /usr/local/sbin/ndtwin-p4-power on <swName>` then `curl --max-time 30 POST http://<P4_PROXY_IP_AND_PORT>/p4/readopt/<dpid>` (55-84). Failure of readopt → 502 with the measured caveat that the 1 Hz probe will still mark the switch Up within a second (86-129). **Documented defect surface**: after a failed readopt, twin can report Up while switch cannot forward; retrying powerOn early-returns success without retrying readopt (46-49, 97-99). Probe: block the readopt endpoint (e.g. stop proxy), power on → expect 502; then GET power state after 2 s → if it reports Up, the twin lies. This is *known* residual per the comment.
- powerOff: helper SIGTERM by manifest PID; failure → vertex left up (151-158). Success → setVertexDown (161).
- Environment deps: helper must exist (`/usr/local/sbin/ndtwin-p4-power`), sudo -n, curl ≥ 7.76 for `--fail-with-body` (81). Actions that depend on these will fail *loudly* if absent — good for the harness, but a chaos run that assumes a fabric can lose switches must check them first.

### 2.7 OVS specifics (OVSPowerStrategy.cpp)
- powerOn builds bridge + ports + controller; every command's rc observed (79-125). Partial failure → 500, vertex not marked up, but the bridge may half-exist (e.g. ports added, controller not set) — twin says Down, network half-built. Retry powerOn on such a state hits `add-br` exit 1 → 500 forever. Recovery action: manual cleanup. Defect observable: after 500, subsequent `ovs-vsctl show` has a bridge; twin still reports switch down.
- powerOff records ports first (157-164); if `list-ports` fails, **leaves switch running** and returns 500 — honest. If del-br fails after ports set down (173-178): returns 500, vertex stays Up, but interfaces are down → twin says Up while data plane is dead. Partial-failure defect shape.

## 3. Prior findings — verification status
1. "400 but installed anyway" (flow installs): root cause documented at DeviceConfigurationAndPowerManager.cpp:1971-1984 and doc/audit/2026-08-17_install-rejected-but-applied.md; shape validation moved before enqueue (HttpSession.cpp:929-962). Looks fixed for the priority case; residual re-instantiation candidate via `parseIpv4U32` throw after enqueue (2.5 above). Status: FIXED-BY-INSPECTION, needs live probe.
2. "Should replace, can only add": CONFIRMED OBSERVED in `updateOpenFlowTables` installOne (push_back at 2089, no dedup) and recorded in DEFECT-INVENTORY.md A-5 as `setAllPaths` that only ever adds (in FlowLinkUsageCollector — to re-verify in current branch).
3. EventBus zero production subscribers: CONFIRMED OBSERVED. Only `registerHandler` is the definition (include/event_system/EventBus.hpp:37); the only emit sites are HttpSession.cpp:429 and 458 (LinkFailureDetected ×2). Nothing calls registerHandler anywhere in src/ or p4_proxy/. Components store `m_eventBus` but never use it (grep: only assignments). `LinkRecoveryDetected` is never emitted (TODO at HttpSession.cpp:497). → Any chaos action relying on event-driven recovery has nothing to trigger.
## 3. Topology perturbation (OBSERVED in TopologyAndFlowMonitor.cpp + HttpSession link handlers)

- Static topology is loaded once in `TopologyAndFlowMonitor::run()` before polling starts (TopologyAndFlowMonitor.cpp:2062), and `loadStaticTopologyFromFile` **refuses a second load** if vertices exist (192-201). Vertices start `isUp=false, isEnabled=false` (243-244).
- Poll cadence: every 5 s during first 90 s, then every 30 s (2055-2057, 2090-2097). Poll target: Ryu or (all-bmv2 MININET) the P4 proxy `/v1.0/topology` (128-148). Poll failure → `execCommand` empty body → update functions early-return **silently** (documented at 72-75). If the control plane dies, the twin keeps its last topology forever and says nothing.
- `updateLinks` "only ever sets isUp = true" per the design comment at 2042-2046 — **links are only ever taken down by the HTTP push path** (`/ndt/link_failure_detected`). No poll path can mark a link down. So:
  - Link-down semantics in the twin = whatever `handleLinkFailure` does (both directions, as read earlier).
  - If the intelligent router stops pushing failures (or pushes only one direction), the twin shows phantom links as up.
- `setEdgeDown/Up` take the graph lock and flip `isUp` (1739-1770). No edge-liveness re-derivation from vertex state: powering a switch off via `setSwitchPowerState` calls `setVertexDown` (DeviceConfigurationAndPowerManager.cpp:1421) but **does not** take its incident edges down. `get_graph_data` will show a down switch with up edges. Probe: power off a switch → GET graph → edges into/out of the down switch still `is_up:true`. Defect if consumers route by edge state.
- Edge `flowSet` TTL is 2 s, pruned at 1 Hz (2997-3035); `touchEdgeFlow` refreshes (3038-3050). Host churn: "nothing ever pushes a host" (comment 2038-2040) — hosts are only learned by the poll; a host disappearing is caught on the next poll (≤30 s) — chaos action "remove a host from Mininet" will take up to 30 s to appear.

### Perturbation actions
T1. Link down (valid pair) → expect both directions `is_up:false` in `get_graph_data`, and `get_graph_data` stays consistent. Defect: only one direction, or edges unaffected.
T2. Link down for nonexistent pair → 404, graph unchanged.
T3. Link down then recovery within the same second (rapid repeat, keep-alive) → final state up; watch for flow_set/leftBandwidth counters left over.
T4. Link down **while** a flow batch is queued to a dpid behind that link → expect either 200-queued with later rejection logged, or an error; defect: response claims queued and log shows success for a switch now unreachable.
T5. Power off a switch (MININET OVS or P4) → expect vertex down, CPU/temp reports -1, edges... (see above — probe and judge per product semantics; at minimum the response of `get_switches_power_state` must agree with the graph).
T6. Kill the control plane (Ryu/proxy) while the kernel runs → expect: kernel keeps answering from last state (no crash), and at minimum a log line or degraded response appears. OBSERVED risk: poll failures are silent (TopologyAndFlowMonitor.cpp:74-75), so the only observable of a dead control plane may be *nothing* — treat "no log, no flag" as the defect if a caller cannot distinguish live from stale.
T7. Kill and restart the control plane mid-run → expect re-convergence ≤ poll interval; defect: hosts/switches remain down after control plane is healthy (poll resets only up, never down — actually it sets up; recovery should work).
T8. `inform_switch_entered` for a dpid that is already up (repeat) → idempotent; no defect expected.
T9. `inform_switch_entered` during the first 90 s (before first poll completes) for a switch the static file already knows → `setVertexUp+Enable` immediately; expect graph shows it up before the poll confirms.

## 4. Traffic-pattern abuse (OBSERVED in FlowLinkUsageCollector.cpp)

- sFlow samples land per (flowKey, agentKey) in `m_flowInfoTable`; counters accumulate `ingressByteCountCurrent` etc. (1486-1547). FlowKey = {srcIp,dstIp,srcPort,dstPort,proto} or ICMP variant (1431-1439).
- Idle flows: `purgeIdleFlows` erases keys idle ≥ `FLOW_IDLE_TIMEOUT` = **15000 ms** (FlowLinkUsageCollector.hpp:35, purge at 2230-2281, 1 Hz). Edge flowSet TTL 2 s (above). So old flow data *does* disappear — two independent TTLs.
- `getFlowInfoJson` serves the whole table (2291-2328); top-k endpoint sorts a copy of all flows by packet rate (2336-2352). Costs are O(n log n) per request — a repeat loop of top-k requests during an elephant storm is a CPU-abuse action.
- Elephant flag: `isElephantFlowPeriodically` now has a clearing else (1929-1936; was latched — KNOWN-ISSUES A-3 / DEFECT-INVENTORY A-5). Rate estimates zeroed when no active hops (1889-1914).
- Byte accounting depends on sampling: `inputByteCountOnALinkMultiplySampingRate += frameLength * samplingRate` (1446-1448). A fabricated/malicious sFlow datagram with huge `frameLength` or samplingRate inflates link usage; sFlow parser is shared with the real network (ingest trust boundary — see flow ingestion code for field validation TBD).
- Path map: `setAllPaths` now **replaces** both maps and refuses empty snapshots (2382-2396) — the A-5 "only ever adds" shape is fixed here; a POST `{"all_destination_paths":[]}` is ignored, does NOT wipe (corrects my earlier 1.3 note). Fresh paths fetched on a 5–60 s timer via `refreshDestinationPathsPeriodically` (2358-2366 comment; curl with 2 s connect / 10 s max time, 2496-2500).
- Flow churn stress: start/stop N short flows (e.g. iperf bursts of 1 s) → expect flows to appear in `get_detected_flow_data` and vanish after 15 s idle; defect: flows linger (purge broken) or vanish immediately (TTL wrong).
- Elephant flows: one 100 Mbps flow among background → expect top-k rank 1 and `is_elephant`-style rates; end the flow → expect it to leave top-k within ~1-2 intervals (this exact case was a measured defect, now fixed: 1900-1913).
- Flows to nonexistent destinations: traffic to an IP not in the topology → still becomes a flow entry (ingest does not check the graph — need to verify at ingest; see sFlow parse section). Expect: flow appears in table even though no host owns dst — judge whether that is a defect for the product (at minimum it should not crash or corrupt the path map).

## 5. Lifecycle abuse (partial; OBSERVED)

- Start order (main.cpp:393-416): topology monitor → collector (fatal on bind failure, 400-412) → historical recorder → `handler->start()` (HTTP acceptor, presumed) → power manager. So HTTP requests can arrive **before** `deviceConfigurationAndPowerManager->start()` has started its workers: power-state reads return whatever cache was initialised at construction; `get_switch_openflow_table_entries` returns empty cache. Actions: fire GETs at t+0.1 s after process spawn → expect 200 with empty/initial data, never a crash, never a hang.
- Shutdown (main.cpp:418-428): SIGINT → flag; loop exits within 200 ms; stops subsystems in order monitor, collector, historical, handler, power. Requests racing the shutdown window (between SIGINT and acceptor close) → expect clean close, no crash. Requests after `handler->stop()` → connection refused. Defect: a request mid-stop hangs or crashes.
- `onWrite` runs `after_write_` on a detached thread (HttpSession.cpp:373-380). Whatever sets `after_write_` (TBD — likely the sFlow-triggered hooks?) can run after the owning session is destroyed? after_write_ is moved so runs at most once, but the thread is detached — if it touches `this` members after socket teardown it is a use-after-free. Grep `after_write_` next.
- Restart ordering: `loadStaticTopologyFromFile` refuses second loads (see §3), so restarting the monitor thread after a stop would need a fresh process — restart the whole kernel rather than the component. An action "restart only the topology poll" is not supported; restart the process.

## Corrections to earlier sections
- §1.3 inform_all_destination_paths: `{"all_destination_paths":[]}` does NOT wipe the maps — `setAllPaths` returns early on empty (FlowLinkUsageCollector.cpp:2382-2385).
- §1.3 acquire_lock garbage body: confirm — inner `catch (...)` swallows parse failure and proceeds with defaults (HttpSession.cpp:1921-1931). Still true.
## 6. Southbound write path and locking (OBSERVED)

### 6.1 Flow dispatch chain
HttpSession.processFlowBatch → `partitionFlowBatchByKnownDpid` (FlowJob.hpp:140-165) → `m_controller->dispatcher().enqueue(jobs)` (HttpSession.cpp:1058). Dispatcher (FlowDispatcher.cpp):
- One worker thread per dpid, spawned lazily; FIFO per-dpid queue; bursts up to 2000 to the sender (77-103, 117-130). Jobs are fire-and-forget; per-entry outcomes only logged (Controller.cpp:27-63).
- Shutdown window: jobs enqueued after `stop()` are dropped with one WARN, and the HTTP handler that already answered "queued" will not deliver (FlowDispatcher.cpp:50-63, 66-85). Chaos action: SIGINT the kernel while a batch is in flight → caller may have been told "queued" for jobs that are silently dropped. Defect if the drop is only visible in logs.
- `sender_` runs on the worker thread; no try/catch in `workerLoop_` (105-131). Any exception escaping the strategy (popen failure throws runtime_error, execCommand) would terminate the process — `utils::execCommand` throws only if popen fails (Utils.hpp:549-551), which is fork/pipe exhaustion — the end-state of a long "many concurrent writes" storm. Probe conservatively: N parallel flow batches for M dpids → watch for fd exhaustion (popen per entry; each curl forks).
- **Shell interpolation of request fields**: `HttpRoutingStrategyBase::post` builds `curl ... -d '<body.dump()>'` with single quotes and the comment admits json::dump does not escape `'` (HttpRoutingStrategyBase.cpp:76-84). Any string field (match value, device name via other paths) containing `'` breaks the command; containing `'; cmd; '` executes it. Fuzz action: flow-entry match/actions strings with `'`, backticks, `$()`. A correct system must reject or escape them; executing them is a defect. (Device name values reach IntentTranslator's path only, not this curl — verify if any other endpoint interpolates user strings into shells: grep `execCommand(` sites with string concat.)

### 6.2 The 400-but-acted shape is RE-INSTANTIABLE (OBSERVED by code path)
`describeFlowEntryShapeProblem` checks only: object, dpid non-negative integer, actions present for install/modify (FlowJob.hpp:76-105). It does **not** validate match values. Path for `match: {"ipv4_src": "not-an-ip"}` on install:
1. Shape passes → job built → enqueue to dispatcher (HttpSession.cpp:1058) → real switch will receive it.
2. Then `updateOpenFlowTables(j)` (HttpSession.cpp:1061) → `extractKey` → `parseIpv4U32("not-an-ip")` **throws runtime_error** (DeviceConfigurationAndPowerManager.cpp:2050, 1959-1968).
3. Throw escapes processFlowBatch → global `std::exception` catch → **500** (HttpSession.cpp:331-334).
Net: caller sees 500, rule already queued to the data plane. This is the same defect shape as the measured 2026-08-17 one (comment DeviceConfigurationAndPowerManager.cpp:1971-1984). Priority fuzz probe. Related: `match` as an array passes shape and poisons the cache (extractKey's `.value` on an array doesn't throw).
- Also note the earlier `handleSetSwitchesPowerState` in MININET with non-numeric `ip`: `ipStringToUint32` throws invalid_argument (Utils.hpp:123-132) → no catch in the power path → global 500. GET `get_switches_power_state?ip=abc` (MININET): `queryMininet` line 296 throws invalid_argument but the handler catches only `std::runtime_error` (HttpSession.cpp:639) → global 500. Expected correct: 400. Unparseable vs unknown: `ip=1.2.3.4` → runtime_error → 404. Probe pair to distinguish.

### 6.3 Group/meter endpoints
`dispatchByPayloadDpid` (FlowRoutingManager.cpp:149-189): missing dpid → OpResult 400 → mapped to HTTP 400 by respondToOpResult; unreadable dpid → 400; unknown dpid → 404. All synchronous: response reflects the controller outcome (501 for bmv2 refusing group/meter; 502 unreachable). Prior "200 unconditional" shape fixed (HttpSession.cpp:772-777 comments). Fuzz: valid dpid but garbage group fields — passed verbatim to curl; Ryu/proxy answer non-2xx → status mapped; no local validation, no 400-but-acted risk since nothing is queued.

### 6.4 LockManager (include/ndt_core/lock_management/LockManager.hpp)
- Acquire checks `state.isLocked && now < state.expiryTime` → expired locks are acquirable (77-80). Negative TTL accepted: expiry in the past → lock granted but instantly expired; response says `{"status":"locked","ttl":-1}`. Defect: no TTL validation.
- **unlock ignores expiry**: `unlock` returns true whenever `isLocked` is true (103-118), even after expiry. HttpSession's own comment claims release answers 412 for "expired, not held, invalid type" (HttpSession.cpp:2052-2057) — the code cannot produce 412 for expired. Probe: acquire ttl=1 → sleep 2 s → release → expect per doc 412, code gives 200 "released". OBSERVED contradiction between doc/comment and code.
- `m_locks` keyed by 3-valued enum → bounded; no leak. Unknown type: acquire → false → 423 (HttpSession.cpp:1943-1947 maps failure to 423 even for invalid type — "System busy or invalid lock type" body covers both).
- Renew of expired lock: `renew` checks only isLocked (131) → renews an expired lock. So the 15 s TTL semantics: TTL never actually releases anything; "expiry" only affects acquire. An expired-but-unreleased lock can be renewed indefinitely and still blocks nobody — the "lock" never disappears on its own, it only yields on a later acquire. Defect shape if apps rely on TTL to free locks.
- acquire_lock with malformed JSON body proceeds with defaults (HttpSession.cpp:1921-1931) — silently reinterprets garbage as "lock the default routing_lock for 5 s". OBSERVED.

### 6.5 HTTP server mechanics / lifecycle (OBSERVED)
- Port 8000: include/ndt_core/event_handling/ControllerAndOtherEventHandler.hpp:37 (`#define NDT_PORT 8000`); acceptor bound in `start()` (ControllerAndOtherEventHandler.cpp:90); io_context run by `hardware_concurrency()` threads (201-211). So up to hw_concurrency concurrent handlers; all handler work (including `updateOpenFlowTables`, graph copies, execCommand curls) blocks an io thread.
- `stop()` order: io_context.stop() BEFORE acceptor close (107-114), closes active sockets (125-134), then pokes 127.0.0.1:8000 to unblock accept (136-170), joins thread (178-187). Note `runServer`'s `doAccept` continues while m_serverRunning; accept callback checks flag. Race surface: an accepted-but-unread connection gets its socket shut down at 127-134 — client sees connection reset mid-request. Chaos action: hold many idle keep-alive connections during shutdown → expect clean resets, no hang.
- `after_write_` hook: only read/cleared in onWrite (HttpSession.cpp:374-375); **nothing in src sets it** → dead seam, no production hazard. (Tests may set it via friendship.)
- Startup window: acceptor opens at handler->start() (main.cpp:415) which is *after* collector and monitor start, but the monitor's `run()` loads the static topology on its own thread (TopologyAndFlowMonitor.cpp:2062) — so HTTP requests can be served **before the static topology is loaded**: flow batches answer 404 "unknown dpid" (topology empty), `get_graph_data` returns empty graph. Expect: no crash; correct system would either wait or answer 503. Defect candidate: a 404 "unknown dpid" for a real switch during startup is indistinguishable from a mistyped dpid (and contract tools run right after bring-up — see DEFECT-INVENTORY A-3 for the sibling path-map case).

## 7. Pending reads
Classifier ingest (flow trust boundary), HistoricalDataManager, ApplicationManager, SimulationRequestManager, IntentTranslator, P4RoutingStrategy, getSwitchesPowerState staleness verified (MININET reads graph live — good), doc/ Chinese-language check.
# 8. CONSOLIDATED CHAOS ACTION TABLE

Legend: **P** = predicted behaviour if correct; **D** = observable that indicates a defect. All "why" references are file:line read this run.

## 8.1 Northbound HTTP API abuse (port 8000; routes HttpSession.cpp:145-317)

| # | Action | Why meaningful | P (correct) | D (defect) |
|---|---|---|---|---|
| H1 | POST /ndt/install_flow_entry with `match:{"ipv4_src":"not-an-ip"}` | Shape check does not validate match values (FlowJob.hpp:76-105); job is enqueued (HttpSession.cpp:1058) before `parseIpv4U32` throws in `updateOpenFlowTables` (DeviceConfigurationAndPowerManager.cpp:2050,1960-1968) | 400 before anything is queued; nothing programmed | Response 500 (HttpSession.cpp:331-334) while the entry was already enqueued to the data plane → error-status-but-acted, same class as the measured 2026-08-17 defect (comment 1971-1984) |
| H2 | Batch flow write with 1 known + 1 unknown dpid | Partial application is deliberate (HttpSession.cpp:994-1056); unknown-dpid entries must be absent from the in-memory table too | 200, `rejected:1`, `get_switch_openflow_table_entries` shows only the known-dpid entry | Unknown-dpid entry appears in the cached table (getFlowsArrayForDpid should refuse it at 2008-2024 — verify at runtime) |
| H3 | Install the same rule (same dpid/match/priority) 5× within one 10 s poll window | `installOne` always `push_back`s; no dedup (DeviceConfigurationAndPowerManager.cpp:2089) | Table shows 1 entry (switch semantics: same match+priority replaces) | `get_switch_openflow_table_entries` shows 5 copies until the 10 s poll overwrites (1877-1910) — "should replace, can only add" |
| H4 | Install with `table_id:1`, then modify same rule with `table_id` omitted | `extractKey` includes table_id (2037-2064); modify only fixes first match (2102-2114) | Cache mirrors the switch | Cache no-ops the modify while the dispatcher sends it south → cache/reality divergence for ≤10 s |
| H5 | POST /ndt/acquire_lock with body `{{{` | Parse failure swallowed, defaults used (HttpSession.cpp:1921-1931) | 400, no lock granted | 200 `{"status":"locked","type":"routing_lock","ttl":5}` — garbage body acquires the default lock |
| H6 | acquire ttl=1 → sleep 2 s → POST /ndt/release_lock | HttpSession comment says 412 for expired (2052-2057) but `unlock` checks only `isLocked`, never expiry (LockManager.hpp:112-117) | Per contract/doc: 412 | 200 "released" for an expired lock |
| H7 | acquire with `ttl:-1` | No TTL validation (LockManager.hpp:84; HttpSession.cpp:1925-1926) | 400 or refusal | 200 "locked" with ttl -1 → lock instantly expired; second acquire also succeeds |
| H8 | POST /ndt/set_switches_power_state?ip=abc&action=off (MININET) | `ipStringToUint32` throws invalid_argument (Utils.hpp:123-132), no catch in the power path | 400 | 500 (HttpSession.cpp:333-334) — client error reported as kernel fault |
| H9 | GET /ndt/get_switches_power_state?ip=abc (MININET) | Handler catches only `std::runtime_error` (HttpSession.cpp:639); `queryMininet` throws `invalid_argument` first (DeviceConfigurationAndPowerManager.cpp:296) | 400 | 500. Contrast `ip=1.2.3.4` (unknown, parseable) → 404 — probe both, expect different codes |
| H10 | POST /ndt/link_failure_detected for nonexistent (src,dst) | Checked before mutation (HttpSession.cpp:421-427) | 404, graph unchanged | Any edge flips down |
| H11 | Link failure/recovery ping-pong at high rate on one keep-alive connection | per-request handlers, no debounce (403-521) | Final state matches last request; graph consistent | Divergent `is_up` between the two directions, or counters (flowSet/leftBandwidth) left stale |
| H12 | Link recovery for a pair whose reverse edge is missing | Forward edge is set up before the reverse is checked (496, 499-517) | Atomic: either both directions up or none | 500 while forward is up and reverse down — half-done state |
| H13 | Install entry with a single-quote/backtick/`$()` in a string field | `body.dump()` interpolated into a shell command in single quotes; comment admits no escaping (HttpRoutingStrategyBase.cpp:76-84) | Refused or escaped; at worst 502 | Command executed by the shell (quote breakout), or curl mis-invoked while response still claims queued |
| H14 | POST /ndt/received_a_simulation_case, valid shape, SIM_SERVER_URL dead | Validation is shape-only (SimulationRequestManager.cpp:56-113); any curl result is wrapped and answered **202** (HttpSession.cpp:1255-1260) | Failure reflected in HTTP status | 202 with `{"status":"<curl error>"}` — success status carrying failure |
| H15 | received_a_simulation_case with `inputfile: "'; touch /tmp/x; '"` | Body interpolated raw into curl (SimulationRequestManager.cpp:123-125); comment admits deferred fix (118-122) | Refused/escaped | Shell injection executes |
| H16 | POST /ndt/simulation_completed with app_id whose registered URL is attacker-controlled; body with quote | Body and app-supplied URL interpolated raw into curl, on a **detached thread per call**, no --max-time (SimulationRequestManager.cpp:135-156) | Escaped; bounded | Command injection; SSRF to registered URL; 10k posts → 10k detached threads + hung curls (fd/thread exhaustion) |
| H17 | Loop POST /ndt/app_register 1000× | id counter and map only grow; per registration writes /etc/exports + `exportfs -ra && systemctl reload nfs-server` **synchronously in the handler thread** (ApplicationManager.cpp:34-45, 169-185, 250-262) | Bounded, fast, or rejected when unhealthy | App ids grow unbounded, /etc/exports grows (if root), io threads stall on systemctl reload |
| H18 | POST /ndt/intent_translator/text with --no-ai; with --ai and huge prompt | Guarded → 503 (HttpSession.cpp:1414-1422). With --ai, whole LLM round trip + task execution is synchronous on an io thread, no timeout (IntentTranslator.cpp:44-106) | Fast refusal; bounded latency | With --ai: io threads blocked for minutes per request; parallel requests starve all other endpoints |
| H19 | GET /ndt/get_detected_top_k_flow_data?k=1000000000 and ?k=abc | Non-numeric → WARN, k=50 (HttpSession.cpp:591-601); huge k sorts the full flow table per request (FlowLinkUsageCollector.cpp:2336-2352) | Bounded CPU | O(n log n) × concurrent requests saturates io threads |
| H20 | GET /ndt/get_openflow_capacity after removing/renaming ../doc/2026-01-02_OpenflowCapacity.json | Reads CWD-relative file; on failure returns with no status/body set (HttpSession.cpp:1749-1754) | 404/503 with a body | 200 with empty body (status was pre-set at 118-120) — a 200 that is not JSON |
| H21 | modify_nickname then GET /ndt/get_nickname?name=<new nickname> | Name search compares only `deviceName` (HttpSession.cpp:1535-1544), not nickName | The new nickname should be findable (or documented otherwise) | 404 — nickname lookup by name ignores nicknames |
| H22 | GET /ndt/inform_switch_entered?dpid=abc / ?dpid=-1 / ?dpid=12345678901234567890 | tryParseUint64 strict (HttpSession.cpp:1144-1162) | 400 for all | 500, or wrap-around to another switch |
| H23 | POST /ndt/inform_all_destination_paths `{"all_destination_paths":[]}` | Empty snapshot refused (FlowLinkUsageCollector.cpp:2382-2385) | 200, path map unchanged | Path map wiped → `get_path_switch_count` 404s everywhere |
| H24 | inform_all_destination_paths with one malformed hop in a 100-path list | Whole request rejected before publish (HttpSession.cpp:1331-1345) | 400, nothing applied | Some paths applied before the 400 (partial publish) |
| H25 | POST /ndt/modify_device_name vertex_type:"0" (string) or 2 | Type reads via `.get<int>()` → type_error → 400; 2 → 400 (1182-1221) | 400 | 500 or mutation |
| H26 | POST /ndt/renew_lock without holding | `renew` returns false → 412 (LockManager.hpp:123-138; HttpSession.cpp:1983-1995) | 412 | 200 |
| H27 | 32 concurrent threads: install/delete/modify the same rule repeatedly | Dispatcher is per-dpid FIFO (FlowDispatcher.cpp:105-131); cache updates concurrent with 10 s poll (DeviceConfigurationAndPowerManager.cpp:1887-1891) | Final switch state = some serialisable order; cache consistent within 10 s | Crash (popen/pipe exhaustion), or cache permanently diverged from switch |
| H28 | Any write at t+0.1 s after process start | Acceptor opens before static topology load completes (main.cpp:415 vs TopologyAndFlowMonitor.cpp:2062 on its own thread) | 503/clear "not ready" | 404 "unknown dpid" for a real switch — indistinguishable from a typo; or partial graph reads |
| H29 | Batch flow write, then SIGINT immediately | Jobs after dispatcher stop are dropped with one WARN (FlowDispatcher.cpp:50-63, 73-76) | In-flight "queued" responses are honoured or retracted | Caller got 200 "queued" for jobs silently dropped (only a log line records it) |
| H30 | POST /ndt/install_group_entry to a bmv2 dpid | P4RoutingStrategy refuses → OpResult unsupported → 501 (P4RoutingStrategy.cpp:12-25; HttpSession.cpp:738-740) | 501 with reason | 200/ignored or forwarded to Ryu |
| H31 | POST /ndt/delete_flow_entry `{"dpid":<real>}` (no match) | Delete needs only dpid — "delete everything on this switch" (FlowJob.hpp:73-74) | Correct per spec, but MUST be treated as destructive: full table wipe on a live switch | Wipe not reflected in cache until poll; twin disagrees for ≤10 s |
| H32 | Install with `priority:1.5` / `priority:"high"` / `priority:-5` | `.value("priority",0)` then int conversion throws for float/string → 400 before enqueue (HttpSession.cpp:856, 983-991); negative is *not* shape-rejected (FlowJob.hpp:76-105) | 400 for float/string; negative either refused or forwarded verbatim | Negative priority accepted and cached, then silently rejected by Ryu → cache shows a rule that does not exist |
| H33 | GET with duplicate query params (`?ip=a&ip=b`) | queryParam returns the **first** occurrence (Utils.hpp:457-487) | Documented/consistent | Second value wins somewhere else, or handler misparses |

## 8.2 Topology perturbation

| # | Action | Why | P | D |
|---|---|---|---|---|
| T1 | POST link_failure (valid pair) | Both directions set down + events (HttpSession.cpp:428-459) | Both edges `is_up:false` in `get_graph_data`; consistent with recovery later | One direction only, or edges unchanged while 200 returned |
| T2 | link_failure + link_recovery within 1 s | handlers independent; no debounce | Final state up | Stale flowSet/leftBandwidth on the edge, or `is_up` mismatch |
| T3 | Power off a switch (OVS/P4) then GET graph | power off calls setVertexDown but nothing touches incident edges (DeviceConfigurationAndPowerManager.cpp:1415-1422, 1468-1476) | Edges of a down switch are down (product semantics TBD — at minimum twin must be internally consistent) | `get_graph_data` shows vertex down with all incident edges `is_up:true` |
| T4 | Kill Ryu/proxy mid-run | Poll failures are silent (TopologyAndFlowMonitor.cpp:72-75); links only ever set up by poll (2042-2046) | Degraded flag or log | Twin serves stale topology with no indication at all |
| T5 | Restart control plane after T4 | poll re-syncs ≤30 s (2055-2057) | State re-converges | Hosts/switches stay down after control plane healthy |
| T6 | inform_switch_entered for already-up dpid, repeated | idempotent setVertexUp+Enable (1172-1173) | No change | Duplicate events or state flaps |
| T7 | Remove a host from Mininet | Hosts only learned by poll (comment 2038-2040), ≤30 s cadence | Host gone within one poll interval | Host stays "up" indefinitely |
| T8 | Link down behind a dpid then batch flow write to that dpid | Dispatcher sends regardless of link state (Controller.cpp:27-63) | Rejected per-entry and logged | Response "queued", log shows success, switch unreachable |
| T9 | OVS powerOn fails mid-way (break sudo) | allOk collected, vertex not marked up (OVSPowerStrategy.cpp:114-125) | 500, vertex down, but bridge may half-exist → subsequent powerOn always fails on `add-br` (exit 1) | Twin reports down forever; manual bridge cleanup needed — recovery requires external action |

## 8.3 Traffic-pattern abuse

| # | Action | Why | P | D |
|---|---|---|---|---|
| F1 | 1 s iperf bursts × many flows | flows expire after 15 s idle (FlowLinkUsageCollector.hpp:35; purge 2230-2281) | Flows appear then vanish ≈15 s after last sample | Flows linger forever (purge broken) or vanish while active (TTL too short) |
| F2 | One elephant flow then stop it | Elephant flag now has clearing else (1929-1936); rates zeroed on no-active-hops (1889-1914) | Leaves top-k within 1-2 intervals | Stays in top-k with frozen rate (the measured defect E9/A-3 — regression probe) |
| F3 | Traffic to a nonexistent destination IP | Ingest does not check topology membership (FlowLinkUsageCollector.cpp:1486-1547) | No crash; flow either ignored or reported honestly | Path map / switch-count polluted, or query errors |
| F4 | Flood sFlow UDP 6343 with truncated/malformed datagrams | BoundedWords + try/catch in workers + sampleCount cap (928-989, 902-918) | No crash, WARN logs, counters sane | Process death, or counter corruption (e.g. rates ~1.8e19 from the fixed duplicate-key race, 1465-1482 — regression probe) |
| F5 | Flood 6343 faster than workers drain | Bounded queues, drops counted (860-868) | Drops counted, no crash | Queue growth unbounded (memory) or drop counter saturates silently |
| F6 | Concurrent top-k requests during elephant storm | O(n log n) per request (2336-2352) | Latency bounded | io threads saturated → API unresponsive |
| F7 | Fabricated sFlow with absurd samplingRate/frameLength | Byte counters multiply by samplingRate (1446-1448) | Rejected or clamped | Link usage inflated arbitrarily — twin reports load that never existed |

## 8.4 Lifecycle abuse

| # | Action | Why | P | D |
|---|---|---|---|---|
| L1 | GETs at t+0.1 s (acceptor up, topology not loaded) | see H28 | Empty/initial data, no crash | Crash, hang, or 404-for-real-switch |
| L2 | Hold keep-alive connections during SIGINT shutdown | sockets shut down while accepted (ControllerAndOtherEventHandler.cpp:125-134) | Clean resets | Hang in stop() or process crash |
| L3 | Fire a write batch between SIGINT and acceptor close | dispatcher may already be stopped (FlowDispatcher.cpp:73-76) | Either delivered or explicitly refused | "queued" answered then dropped |
| L4 | Restart only the topology monitor | not supported: second load refused (TopologyAndFlowMonitor.cpp:192-201) | N/A — restart whole process | N/A (document that component-level restart is out of scope) |
| L5 | Kill the process hard (SIGKILL) mid-batch, then restart | queues/caches are in-memory only | Clean start, no stale state claimed | Stale NFS exports (cleanupStaleEntries) or stale /etc/exports lines accumulate across restarts (ApplicationManager.cpp:408-443) |

## 8.5 Power management

| # | Action | Why | P | D |
|---|---|---|---|---|
| P1 | set_switches_power_state on → off → on rapid (OVS) | every rc observed; early success when already in target state (OVSPowerStrategy.cpp:73-77, 133-136) | Each response matches actual bridge state | 200 for a bridge that doesn't exist (e.g. del-br failed earlier but vertex marked down? no — verify at runtime) |
| P2 | power on then immediately GET get_switches_power_state (MININET) | reads graph live (queryMininet 294-303) | "ON" | "OFF" (stale cache) — or the reverse |
| P3 | P4 powerOn with proxy reachable but readopt returning 502 | powerOn returns 502 but 1 Hz probe will setVertexUp within ~1 s (P4PowerStrategy.cpp:86-129, documented residual) | Twin does not certify Up until pipeline adopted | GET power state shows ON within 2 s of a 502 — known documented defect, probe to keep it visible |
| P4 | P4 powerOn twice after failed readopt | second call early-returns success without retrying readopt (46-49) | Retry re-attempts adoption | Second call 200 with switch still unable to forward |
| P5 | TESTBED power command against dead relay GW | curl --max-time 8 (buildRelayPowerCommand 819-826) | 500 within ~8 s | Hang (no timeout) or 200 success without acting (regression probe for the known form) |
| P6 | TESTBED GET get_switches_power_state with dead gateway | queryTestbed curl has **no** --max-time (222-225) | Bounded latency | HTTP GET hangs indefinitely, blocking an io thread |
| P7 | Power off a switch then immediately query CPU/temperature | status caches refresh every 10 s (statusUpdateWorker 1860-1873); down switches get -1 sentinel (1534-1537) | -1 within ≤10 s | 0% (rendered as idle) or stale number >10 s |

## 8.6 EventBus note (blocks some classic chaos actions)
OBSERVED: only two emit sites exist (HttpSession.cpp:429, 458, LinkFailureDetected) and **zero** registerHandler calls anywhere in src/ or p4_proxy/. LinkRecoveryDetected is never emitted (TODO HttpSession.cpp:497). Actions like "expect the watchdog to react to a LinkFailure event" have no subscriber to react — do not propose them; the event fire is a no-op today.

## 9. Search-method notes
- Chinese-language search performed in doc/: "混沌" (chaos) → 0 matches; "模糊测试" (fuzz testing) → 0 matches. The doc corpus read this run was English; the API doc (doc/2026-01-02_ndt_api.md, 89 KB) and KNOWN-ISSUES.md were not fully read this run — flag as unread if a contract claim is needed.
- Claim discipline: everything above is marked OBSERVED from source or INFERRED. Behavioural predictions (P columns) are what the code *says* will happen, not measurements.

## 10. Actions too destructive to run unattended
1. **H15 / H14 shell injection probes** (`received_a_simulation_case`, and H13 flow-entry string fields): if the injection succeeds, arbitrary commands run as the kernel's user; and the probe itself (quoting variants) can wedge the shell-out or the SIM server. Run only with a sandboxed kernel process, non-root, and a fake SIM_SERVER_URL — never against the shared lab.
2. **H31 / delete_flow_entry with no match**: wipes an entire real switch's flow table. Only on a scratch switch, and only with re-install ready.
3. **P4/P5/P6 power actions on TESTBED**: they flip **real** smart-plug power. An unattended off can take down production hardware; the relay path and GW_IP must be verified against a lab rack explicitly cleared for it.
4. **T9 OVS power failure injection** (breaking sudo or ovs-vsctl): leaves half-built bridges that need manual `ovs-vsctl` cleanup; repeated failures can wedge Mininet such that only a full stack teardown recovers.
5. **H17 app_register loops**: as root, each registration appends to /etc/exports and reloads the NFS server — flooding this perturbs host NFS for everyone; run only in a VM/container with no real NFS clients.
6. **F4/F5 raw sFlow floods to 6343**: 6343 is INADDR_ANY on the lab network; a flood from a fuzz harness can displace real telemetry or starve the collector for the duration. Keep rate-limited and prefer a loopback path.
7. **H27 concurrent write storms** at max parallelism can exhaust fds/processes via popen-per-entry (each flow entry is a curl fork); run with modest fan-out first and watch for the "popen() failed" 500s.
8. **L2/L3 shutdown-race probes** can leave NDTwin in a half-stopped state that only a restart fixes — acceptable, but they need a watchdog that restarts the kernel automatically or the harness will sit dead.

## 11. Recommended probe priorities (defect-shaped, low-destructiveness)
1. H1 (500-but-queued via invalid match value) — directly re-tests the two prior findings.
2. H3/H4 (cache accumulate/diverge vs real table).
3. H5/H6/H7 (lock semantics contradictions between code, comments, and contract docs).
4. H8/H9 (client error → 500 mapping in the power endpoints).
5. H14/H16 validation + response-shape honesty for the simulation endpoints (with sandboxed URLs).
6. T3 (down switch with up edges), T4 (silent stale topology).
7. P3/P4 (P4 readopt residual) and P6 (unbounded testbed power-state GET).
## 12. Corrections after final verification

- §1.1 said link-failure "wrong-typed fields" → 400. **Wrong**: `parseLinkFailedEventPayload` (include/event_system/RequestParser.hpp:11-52) returns nullopt only for *missing* keys; a wrong-typed field **throws** (`runtime_error` at :50, or `std::stoul` on non-numeric strings) and `handleLinkFailure` has no local catch → global `std::exception` → **500** (HttpSession.cpp:331-334). Malformed JSON itself → global `json::exception` → 400. So the three-way split for this endpoint is: bad JSON → 400, missing key → 400, wrong type / "123abc" string → 500, unknown edge → 404 (no mutation, HttpSession.cpp:421-427), valid → 200.
  Updated probe A1: send `src_dpid: []` or `src_interface:"abc"` → expect 400 (correct system) — code gives 500; and verify no mutation after each.
- §0 "A handler that parses the body after doing work…" — for `handleLinkFailure`/`handleLinkRecovery` parsing and validation precede mutation, so 400-no-mutation holds for the *missing-key* path; the mutation-then-error shape remains only for the reverse-edge-missing case (HttpSession.cpp:432-456, 496-517) which answers 500 after the forward direction was already changed.
