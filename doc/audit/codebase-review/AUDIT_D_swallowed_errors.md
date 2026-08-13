# AUDIT D — Silently swallowed errors

VERDICT: 12 CONFIRMED, 0 SUSPECTED

Note on p4_proxy citations: a concurrent session's mutation gate transiently dirties `p4_proxy/proxy_agent/*` and `tools/p4_power_helper.py`; every proxy-file quote below was verified against HEAD (9afd647).

### emit() failures are invisible in production: the "reports failure by return value" contract dead-ends in a discarded return
GRADE: CONFIRMED
WHERE: p4_proxy/proxy_agent/sflow_emitter.py:283-285 (contract), :316-320 (silent False), :325 (counter nobody exports); sole production caller p4_proxy/proxy_agent/p4_client.py:101-102
WHAT: The docstring promises `swallows nothing: emit() already reports failure by return value rather than by raising`. Not raising is correct (an exception would kill the per-switch gRPC stream thread) — but the return value is the only report and nothing consumes it: the caller is `if self.sample_callback: self.sample_callback(self.device_id, sample)` with the result dropped; the datagram-build failure branch (`except (ValueError, struct.error, OSError): return False`) has no log and no counter; the sendto branch increments `send_errors`, which is read by tests/test_sflow_emitter.py and exported by no endpoint (`/p4/switch_state` reports switches and links, not emitter counters).
BITES: A malformed agent IP in the topology JSON passes `register_switch` (no validation there), main.py prints its success line, then `socket.inet_aton` raises inside every `build_datagram` and every sample from that switch vanishes with zero evidence anywhere — the exact "telemetry attributed to nothing, no error" failure the module docstring was written to prevent, one step earlier.

### The live TESTBED power path reports any HTTP response as success; the fixed version is dead code
GRADE: CONFIRMED
WHERE: src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:1384-1396 (live), :808 (dead fixed overload); callers src/ndt_core/http/HttpSession.cpp:663 and src/ndt_core/intent_translator/IntentTranslator.cpp:272, :282
WHAT: The only reachable TESTBED path builds `curl -s -X POST "http://{}:8000/relay?..."` with no `-f`, no `%{http_code}`, no `--max-time`, then `int rc = std::system(cmd.c_str()); return rc == 0;` — curl exits 0 on any HTTP response, so a gateway 4xx/5xx returns true and the REST caller gets Success. Meanwhile the 3-arg `setSwitchPowerState` (:808) — the overload commit 6e156b3 "Stop the twin reporting a power request as if it were the outcome" rewrote around interpretRelayResponse, with mutation-verified tests — has zero call sites (grep: both live callers use the 2-arg), and per the pass-3 subagent's `git show`, had zero call sites the day it was written.
BITES: On the testbed — where the switches are real — a refused power change reports `{"<ip>": "Success"}`, the graph vertex is never updated, and the honest machinery sits unreachable beside it. Cross-ref AUDIT_B: the mutation-verified tests for interpretRelayResponse are pinning dead code.

### IntentTranslator::performTask answers "ok" for power operations that failed or targeted a nonexistent switch
GRADE: CONFIRMED
WHERE: src/ndt_core/intent_translator/IntentTranslator.cpp:269-274 (POWEROFF; POWERON at :279-284), fallthrough at :977-979; same discard shape for INSTALL/MODIFY/DELETE_FLOW_ENTRY OpResults (:306-310, :334-338, :355)
WHAT:
```cpp
if (deviceIpOpt.has_value())
{
    ...
    this->m_deviceConfigManager->setSwitchPowerState(deviceIpOpt.value(), "off");
}
break;
```
…then `return "ok";`. The bool is discarded; an unknown device name skips the call entirely with no else; both report "ok" to the intent caller. The DISABLE/ENABLE cases directly above return error JSON per failure, so the asymmetry is per-case, not design.
BITES: The layer directly above the Phase-7 chain throws away the honesty the chain just gained: a P4 powerOff whose helper is not installed answers "ok" to the LLM/user.

### Flow-stats ingest checks `vlan_vid` but reads `vlan_id` — one VLAN rule poisons every subsequent poll
GRADE: CONFIRMED
WHERE: src/ndt_core/collection/Classifier.cpp:771-773
WHAT:
```cpp
if (match.contains("vlan_vid"))
{
    outValue.vlanTci = static_cast<uint16_t>(parseU64(match.at("vlan_id")));
```
Guard on one key, read of another: a flow carrying `vlan_vid` without `vlan_id` makes `.at()` throw `json::out_of_range`, which propagates up to openflowTablesUpdateWorker's `catch (const std::exception&)` (DeviceConfigurationAndPowerManager.cpp:1821) — logged and swallowed, every poll, always at the same flow.
BITES: While the VLAN rule persists: the poisoned switch's mark-and-sweep never runs, switches later in the loop never update, and the /ndt/get_switch_openflow_table_entries cache never refreshes — visible only as a repeated one-line worker error. Latent today (neither Ryu's `dl_vlan` rendering nor the P4 proxy emits `vlan_vid`; Ryu VLAN matches are currently ignored outright), which is exactly why it will surface as a mystery.

### Reverse-edge lookups discard boost::edge()'s found-flag and can hand back a garbage descriptor inside an engaged optional
GRADE: CONFIRMED
WHERE: src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1174-1175 (and the NoLock twin ~:1152); same shape at :2541 (`boost::edge(v2, v1, *m_graph).first; // Get the reverse edge`)
WHAT:
```cpp
auto reverseEdge = boost::edge(targetNode, sourceNode, *m_graph).first;
return reverseEdge;
```
`.second` is never consulted; a missing reverse edge returns a singular descriptor wrapped in an engaged optional — the miss becomes a hit. Production consumer on the sFlow hot path: FlowLinkUsageCollector.cpp:1540-1545 `touchEdgeFlow(edgeOpt.value(), key)` writes through it. :2541 likewise serves reverse-direction bandwidth with `.second` unchecked while the forward direction is checked.
BITES: In the asymmetric-graph state this repo already acknowledges as reachable (7f738e6 exists precisely to report half-processed link transitions), per-edge flow bookkeeping and reverse bandwidth answers are built on an invalid edge, with no error anywhere. A dropped error flag, not a race — no sanitizer flags an unchecked `.second`.

### /ndt/release_lock answers 200 "released" no matter what
GRADE: CONFIRMED
WHERE: src/ndt_core/http/HttpSession.cpp:1930-1937; accomplice include/ndt_core/lock_management/LockManager.hpp:94 (`if (type == LockType::Unknown) return;`)
WHAT:
```cpp
catch (...)
{
}

m_lockManager->unlock(lockType);

res.result(http::status::ok);
res.body() = json{{"status", "released"}, {"type", lockType}}.dump();
```
`unlock` is void and bare-returns on an unknown type; releasing a non-held lock is a silent no-op; the empty catch means a malformed body degrades to releasing the DEFAULT type instead of 400. The sibling renew handler proves the intended contract: renew returns bool and answers 412 for the same inputs.
BITES: An app that typos its release gets `{"status":"released","type":"bogus"}` with 200 and believes the lock is free; the real lock stays held until TTL expiry, blocking other apps' acquires with no error anywhere.

### getPathBetweenHostsJson returns a JSON string on error paths and a JSON object on success; the caller double-encodes the errors
GRADE: CONFIRMED
WHERE: src/ndt_core/collection/FlowLinkUsageCollector.cpp:2427 (`return errorJson.dump();`) and :2441 (`return "{\"error\":\"No active or known path found...\"}";`) vs :2471 (`return result;`); consumer src/ndt_core/intent_translator/IntentTranslator.cpp:480-485 (`json path = ...; return path.dump();`)
WHAT: The function returns `json`; both error paths convert to a JSON *string value* that merely looks like JSON, so the caller's `.dump()` yields a quoted, escaped string for errors while success parses as an object.
BITES: A GET_PATH intent client doing `parsed["error"]` hits a type mismatch exactly and only when something went wrong — failure is structurally unconsumable while success is fine. Low live exposure (intent translator disabled under --no-ai).

### Missing dpid answers 200 with an error body on both per-switch stat endpoints
GRADE: CONFIRMED
WHERE: src/ndt_core/http/HttpSession.cpp:1777-1778 and :1804-1805
WHAT:
```cpp
SPDLOG_LOGGER_WARN(Logger::instance(), "dpid missing");
res.body() = json{{"status", "error"}, {"message", "dpid missing"}}.dump();
```
Neither branch sets `res.result(...)`, so the 200 from buildResponse's initialization (:119) stands for get_total_input_traffic_load_passing_a_switch and get_num_of_flows_passing_a_switch called with `{}`.
BITES: A status-code-only client reads success and gets an error object it never parses. Adjacent to, and distinct from, the adjudicated item (dpid present-but-unknown answering success/0): this is the absent-parameter row, which the adjudication does not cover.

### ControllerAndOtherEventHandler accepts a HistoricalDataManager and silently drops it — the toggle endpoint can never work
GRADE: CONFIRMED
WHERE: src/ndt_core/event_handling/ControllerAndOtherEventHandler.cpp:51 (parameter) vs :56-68 (init list ends at m_lockManager; m_historicalDataManager appears only at :243, passing the null member on); include/ndt_core/event_handling/ControllerAndOtherEventHandler.hpp:126
WHAT: The constructor takes `std::shared_ptr<HistoricalDataManager> historicalDataManager` and never stores it; the member stays null and doAccept hands null to every HttpSession, whose guard (HttpSession.cpp:1719-1723) then permanently answers 500 "Historical data manager not available." — even though main.cpp:368-369 built and :385 passed a real instance. Two more layers are dead even if wired: main.cpp:339 builds a *second*, separate HistoricalDataManager (the one actually started), and the flag the endpoint would set (`m_loggingEnabled`, stored at HistoricalDataManager.cpp:140) is read by nothing (grep: declaration + store only).
BITES: The REST set-historical-logging feature has three independent reasons to be dead; the caller just sees a 500, and no log explains any of them.

### After a readopt, shutdown stops the wrong gRPC client — and the design doc declared the swap safe over the exact reference that goes stale
GRADE: CONFIRMED
WHERE: p4_proxy/proxy_agent/topology_manager.py:803-810 (HEAD; swap + old.stop) vs p4_proxy/proxy_agent/main.py:274-276 (`global p4_clients` assigned once at startup) and :288-289 (shutdown iterates it); doc/phase7_power_mechanism_design.md:83-84
WHAT: `readopt_switch` swaps `self.switches[dpid]` under the liveness lock and stops the old client, but main's module-global `p4_clients` still references the pre-readopt client; `shutdown_event` then stops the already-stopped old client and never stops the new one. The design doc's step 3: 「持有 clients 引用的只有 api_routes 和 main（grep 過…），swap 安全。」 — main's copy is precisely the stale one.
BITES: Shutdown hygiene only (the new client's channel and receiver thread outlive orderly shutdown, silently) — but the doc's "grep 過, swap 安全" is a verified-sounding claim whose named holder is the counterexample.

### ApplicationManager's NFS cleanup discards every subprocess result
GRADE: CONFIRMED
WHERE: src/ndt_core/application_management/ApplicationManager.cpp:132, :210, :217, :254
WHAT: `system("sudo exportfs -ra");` (twice), `system(cmd.c_str());`, `system(sedCmd.c_str());` — all four discard exit status, while `reloadNFSServer` (:112-117) directly above checks and warns. The `sed -i` edits /etc/exports.
BITES: A failed sudo (password prompt on a detached process — the documented ovs-vsctl failure mode on this machine) leaves stale exports live and /etc/exports unedited while the log claims cleanup succeeded; cleanupStaleEntries runs from the constructor at every kernel start, in both modes.

### read_egress_counter folds "read failed", "counter missing from p4info", and "genuinely idle" into (0, 0)
GRADE: CONFIRMED
WHERE: p4_proxy/proxy_agent/p4_client.py:433-434 and :449-451
WHAT:
```python
if not counter_id:
    return 0, 0
...
except Exception as e:
    pass
return 0, 0
```
A dead switch, a pipeline/p4info mismatch, and an idle port all answer the identical `(0, 0)`; the exception is bound and discarded without a log — in a file whose other error paths are deliberately loud.
BITES: Mitigated today by caller absence: grep shows the only callers are p4_proxy/tests/test_p4_client_writes.py:701-723; no production path reads egress counters. A swallow-everything pattern waiting for its first production caller, which will inherit "0 bytes" as the answer to "the switch is down".

Read: every cited line re-opened by the orchestrator at adjudication time (grep/sed against the current tree, or `git show HEAD:` for files inside the concurrent mutation window); full end-to-end file coverage per area by the five audit passes — their complete file lists are consolidated at the end of AUDIT_A_hallucinations.md.
