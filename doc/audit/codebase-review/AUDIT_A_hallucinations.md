# AUDIT A — AI hallucinations / false assertions

VERDICT: 28 CONFIRMED, 0 SUSPECTED

Note on p4_proxy citations: a concurrent session's mutation gate transiently dirties `p4_proxy/proxy_agent/*` and `tools/p4_power_helper.py`; every proxy-file quote below was verified against HEAD (9afd647), which is what production content is.

### httpsPost docstring implies certificate validation occurs; verification is never enabled
GRADE: CONFIRMED
WHERE: include/utils/Utils.hpp:534-535 (claim) vs :570-571 (reality)
WHAT: The claim: `@note This helper uses system default verify paths; certificate validation behavior depends on platform configuration.` The reality:
```cpp
asio::ssl::context sslCtx{asio::ssl::context::tls_client};
sslCtx.set_default_verify_paths();
```
`set_verify_mode(asio::ssl::verify_peer)` is never called — not here, not anywhere in the project (`grep -rn set_verify_mode src/ include/` is empty). An asio client context defaults to `verify_none`, so on a stock platform no certificate validation happens at all; loading the verify paths is dead weight. "Depends on platform configuration" describes behaviour the code does not have.
BITES: The only caller is LLMAgent::callOpenAIApi (LLMAgent.cpp:115), which sends `Bearer $OPENAI_API_KEY` plus prompt content over this channel. Any MITM able to present a self-signed cert (lab proxy, captive portal) reads the key; the request succeeds and nobody notices. Cross-ref: the key is separately written to local logs — see AUDIT_C "OPENAI_API_KEY logged in plaintext".

### Three comments still claim a "1 s topology poll" that a fourth comment already corrected to 5 s/30 s
GRADE: CONFIRMED
WHERE: p4_proxy/proxy_agent/api_routes.py:51-52; p4_proxy/proxy_agent/ryu_topology.py:101-103; p4_proxy/proxy_agent/topology_manager.py:902-903 — vs the correction at topology_manager.py:1325-1328 and the kernel truth at src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1758-1760, 1793-1795
WHAT: The claims: `or the kernel's 1 s topology poll re-enables the edge within a second of the failure being reported` (api_routes.py:51-52); `it runs once a second -- so a link that stayed in this list was re-enabled within a second` (ryu_topology.py:101-102); `Switch-to-switch edges are enabled by the 1 s topology poll` (topology_manager.py:902-903). The reality — recorded in this same codebase: `The poll interval is 5 s for the kernel process's first 90 s and 30 s thereafter (TopologyAndFlowMonitor.cpp:1793-1795). This comment used to say 1 s, which was a misreading of the 1 s sleep slice` (topology_manager.py:1325-1327), and the kernel constants confirm it: `kWhileConverging = 5s; kOnceConverged = 30s; kConvergingFor = 90s`, interval ternary at :1793-1795, the 1 s slice at :1797 existing only so `stop()` returns promptly.
BITES: The design conclusion (omit down links from the topology reply) survives either number, but the stated size of the undo window is wrong by 5-30x in the very files serving the endpoint. Same failure shape as the project's known "one misread number spreads into four documents": corrected in one place, still asserted in three.

### intelligent_router.py's documented "Deployment mode" knob is dead — silently overridden 22 lines later
GRADE: CONFIRMED
WHERE: intelligent_router.py:27-28 (claim) vs :50 (override); sole consumer :421-422
WHAT: The claim: `# (2) Deployment mode` / `is_mininet = True   # True: Mininet, False: physical testbed`. The reality: line 50 unconditionally reassigns `is_mininet = True`, so editing the documented knob does nothing. Its only consumer is `if is_mininet: hub.sleep(60)` (:421-422). Both assignments date to the original import (6f32bca) — inherited, never cleaned up.
BITES: A physical-testbed operator following the comment flips line 28, and the controller still sleeps 60 s before installing any route — the knob reads as configuration and functions as a constant.

### A comment written to correct an earlier false claim now carries two stale citations of its own
GRADE: CONFIRMED
WHERE: p4_proxy/proxy_agent/topology_manager.py:902 and :906
WHAT: The claims: `(HttpSession.cpp:1080-1081)` for the setVertexUp/setVertexEnable pair, and `its only caller is IntentTranslator.cpp:227`. The reality in the current tree: the pair sits at src/ndt_core/http/HttpSession.cpp:1120-1121, and the sole `enableSwitchAndEdges` caller is src/ndt_core/intent_translator/IntentTranslator.cpp:259. Both citations were correct when written and drifted when 2026-08-11 commits inserted lines above them; the substantive claims (exactly those two flags; exactly one caller) are still true.
BITES: Anyone following the citations lands on a bad-request branch and a wrong line; in this project a stale citation has previously propagated into four documents as fact. Citation rot, not a wrong model — but this comment exists specifically to be the accurate correction.

### SPEC.md's one executable command cannot work from any directory
GRADE: CONFIRMED
WHERE: p4_proxy/proxy_agent/SPEC.md:48-51
WHAT: The claim (the documented run command): `PYTHONPATH=. p4_proxy/venv/bin/python proxy_agent/main.py`. The reality: the interpreter path resolves only from the repo root, while the script path and `PYTHONPATH=.` resolve only from inside p4_proxy/ — from the root the script does not exist, from p4_proxy/ the interpreter does not exist. The real launcher does it correctly and differently (tools/test_workflow/stack.sh:582-584: cd into p4_proxy with `PYTHONPATH="$KERNEL_DIR/p4_proxy"`).
BITES: Anyone following the SPEC gets an immediate FileNotFoundError/ImportError. Loud, so cheap — but the document's only run instruction is false as written.

### SPEC.md claims gRPC failures yield HTTP 400; two of the three flow endpoints answer 200 with a status:error body
GRADE: CONFIRMED
WHERE: p4_proxy/proxy_agent/SPEC.md:11 vs p4_proxy/proxy_agent/api_routes.py:106-109, :123-126 (200 + `{"status": "error", ...}`) and :145-146 (the only true 400)
WHAT: The claim: `Includes validation to ensure gRPC failures result in HTTP 400 errors.` The reality: only `/stats/flowentry/modify` raises `HTTPException(400)` on a failed write; `/add` and `/delete_strict` return HTTP 200 with `{"status": "error", "message": "Failed to add route"}` / `"Failed to delete route"`. (The 400s that do exist on all three are for unsupported-match validation, not gRPC failure.)
BITES: Operationally defused only because the kernel distrusts the proxy: src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:116-117 — "Some proxies answer 200 with {\"status\":\"error\"} in the body… a 2xx alone is not proof of success." Any consumer trusting the SPEC instead of that folklore treats a failed route install as success.

### Log claims "sending topology" — the send is commented out
GRADE: CONFIRMED
WHERE: src/ndt_core/intent_translator/LLMAgent.cpp:95-96
WHAT: The claim:
```cpp
SPDLOG_LOGGER_INFO(Logger::instance(), "First message in session {}, sending topology.", sessionId);
//instructions += this->getCurrentTopology(); // Append topology only for the first message
```
The only line that would send topology is commented out; `instructions` stays the bare system prompt. Same pattern at :100: `payload["instructions"] = instructions; //+ this->getCurrentFlowEntries();` — flow entries are not sent either, and `getCurrentTopology()`/`getCurrentFlowEntries()` (:203-292, ~90 lines) are now dead code kept alive by the false log line.
BITES: Anyone debugging intent-translation quality from logs believes the LLM was given the topology on session start. It never is — the model answers topology questions blind, and the log actively points away from the cause.

### Log announces a 45-second wait; the sleep is 20 seconds
GRADE: CONFIRMED
WHERE: src/ndt_core/intent_translator/LLMAgent.cpp:126-127
WHAT:
```cpp
SPDLOG_LOGGER_INFO(Logger::instance(), "Rate limit enabled, waiting for 45 seconds.");
std::this_thread::sleep_for(std::chrono::milliseconds(20000));
```
The stated number is 2.25x the real one. Reachability caveat: the branch is currently dead — `m_rateLimit` becomes true only for models containing neither "mini" nor "nano" (LLMAgent.cpp:38-41), and IntentTranslator.cpp:22, :28 hardcode "gpt-5-nano" for both agents, ignoring the `openaiModel` value main.cpp:349 computes. That ignored model parameter is itself a knob that asserts configurability the code does not honor.
BITES: The day someone selects a full-size model (by fixing the ignored parameter), the log misstates the stall by 2.25x; today, the model knob silently does nothing.

### powerOn's failure message promises "retrying this power-on retries the readopt" — the retry can never reach the readopt
GRADE: CONFIRMED
WHERE: src/ndt_core/power_management/P4PowerStrategy.cpp:79-83 (promise) vs :46-49 (wedge); accomplices at DeviceConfigurationAndPowerManager.cpp:431-435 and :737-740, tools/p4_power_helper.py:257-260 (HEAD)
WHAT: The 502 message ends `"…retrying this power-on retries the readopt."` But after helper-on succeeded and readopt failed, the bmv2 process is running and answers the proxy's unary probe: `if (probeOkIt->get<bool>()) { … return OvsLiveness::Up; }` (:431-435), and the 1 Hz pingWorker then calls `setVertexUp(v)` (:737-740). A retry now takes one of two paths, neither reaching readopt: (a) vertex already marked Up → powerOn early-returns success at :46-49 (`// Already up: nothing to do, and reporting success is accurate.` — certifying a pipeline-less switch); (b) retry lands before the probe → the helper refuses (`'{name}' already appears to be running (pid {pid}); refusing to start a second instance`, helper :258-260) and powerOn reports the wrong step as failed ("could not start"). The only working recovery is off-then-on, which the message does not say.
BITES: An operator (or Energy-Saving-App) follows the message, retries, gets 200 success, and the twin certifies Up a switch that cannot forward one packet — the exact half-state the readopt step exists to catch. The design doc records the Up-illusion residual but not that it also disables the advertised retry.

### Helper docstring: "off exits 0 only once the process is gone" — the orphan from a timed-out "on" is invisible to it
GRADE: CONFIRMED
WHERE: tools/p4_power_helper.py (HEAD) :33-34 (claim) vs :302-306 and :308-311 (pid saved only on success) and :211-224 ("off" trusts the manifest pid)
WHAT: The claim: `The twin-facing caller gets an honest answer: "off" exits 0 only once the process is gone`. The reality: in `cmd_on`'s timeout path the freshly launched `proc.pid` is never written to the manifest (`entry["pid"] = proc.pid; save_manifest(...)` lives only inside the port-open branch, :302-304) before `fail(f"… it was left running -- … the caller can run 'off' once it has decided")` (:308-311). The advised `off` then reads `pid = entry.get("pid")` → None → prints `{"status": "already-stopped"}` and exits 0 (:211-215) while the orphan bmv2 keeps running — and may later occupy the gRPC port.
BITES: One slow bmv2 start (>15 s to bind) produces a process the helper created but can never address again; every subsequent "off" reports success-while-false, and the next "on" fails on the occupied port with a message pointing away from the cause.

### "Costs us this poll, not the process" — a missing dpid still terminates the kernel
GRADE: CONFIRMED
WHERE: src/ndt_core/collection/TopologyAndFlowMonitor.cpp:513-518 (comment; copies at ~:604-609, ~:697-702) vs :479-480; also :548, :581, :643
WHAT: The claim: `// A control plane answering with "mac": 1 instead of "mac": "..." should cost us this poll, not the process.` guarding `catch (const json::exception& err)` (:511). The reality three lines above: `string switchDpidStr = switchInfoJson.value("dpid", ""); uint64_t switchDpidUint64 = stoull(switchDpidStr, nullptr, 16);` — a switches entry with no `dpid` yields `""`, and `stoull("")` throws `std::invalid_argument`, which is not a `json::exception`. The catches in this file (grep: :429, :442, :455 wrap the execCommand calls; :511/:602/:695 are json-only) leave no handler between here and the `run()` thread entry — uncaught exception, `std::terminate`. Same class via `macToUint64` (:548) and non-hex dpid strings (:643).
BITES: The comment's literal example (wrong *type*) is caught; the generalized claim is false — a malformed control-plane reply of the missing-key or non-hex flavor kills the whole kernel, the exact outcome the comment says was fixed.

### Two more cross-file citations drifted to unrelated code
GRADE: CONFIRMED
WHERE: src/ndt_core/collection/FlowLinkUsageCollector.cpp:2150-2152 and include/ndt_core/collection/TopologyAndFlowMonitor.hpp:275
WHAT: The claims: `the push path at HttpSession.cpp:1230 does not [guard its empty case], so a POST carrying {"all_destination_paths": []} would otherwise clear everything` — HttpSession.cpp:1230 is today the "Invalid app_id" line of a different handler; the setAllPaths push is at :1290. And `the one caller (IntentTranslator.cpp:367) passes the result of getSwitchIpByName` — :367 is today `getCpuUtilization()`; the call is at :416. Both were exact when written (introducing commits verified) and were shifted by the 2026-08-11 fix commits.
BITES: Both surrounding claims are still true, but each citation now sends a reader into an unrelated handler — in a repo where one rotted line number has previously propagated into four documents.

### loadStaticTopologyFromFile's nineteen-line docblock is attached to logGraph()
GRADE: CONFIRMED
WHERE: include/ndt_core/collection/TopologyAndFlowMonitor.hpp:62-80
WHAT: `@brief Loads and constructs the static network topology from a JSON configuration file.` … `@param path The file system path to the JSON topology file.` — terminating at `void logGraph();`, a parameterless debug printer. The real `loadStaticTopologyFromFile(const std::string&)` is declared later with its own accurate comment.
BITES: The header's public section teaches that logGraph() mutates the graph from a file; a reader wiring startup from the header calls the wrong function.

### get_average_link_usage header still teaches the pre-fix filter the implementation deliberately abandoned
GRADE: CONFIRMED
WHERE: include/ndt_core/http/HttpSession.hpp:571-572 vs src/ndt_core/collection/TopologyAndFlowMonitor.cpp:2455
WHAT: The claim: `The average is calculated by TopologyAndFlowMonitor::getAvgLinkUsage() using only: - links that are currently UP (edge.isUp == true), …` The reality: `if (!isUsable(g[e]))` — the full up AND enabled AND not-admin-disabled intersection, with the .cpp comment above it recording precisely why the isUp-only filter was wrong (admin-disabled links with residual traffic polluted the figure Energy-Saving-App reads).
BITES: Anyone auditing what feeds the Energy-Saving-App average from the header trusts the superseded predicate.

### Orphaned docblock documents the deleted setAllPath (singular)
GRADE: CONFIRMED
WHERE: include/ndt_core/collection/FlowLinkUsageCollector.hpp:131-136
WHAT: A full `@brief Update the path for one specific (srcIp,dstIp) pair.` docblock floats in front of an unrelated declaration; FlowLinkUsageCollector.cpp:2316-2319 records the method's removal (`setAllPath (singular) was removed here. It had no callers…`) — the header half was left behind.
BITES: Documents an API that does not exist, with exactly the single-pair semantics whose trap motivated the removal.

## doc/ vs code (docs pass)

### get_power_report documented as "watts" and "random values"; the code emits deterministic milliwatts
GRADE: CONFIRMED
WHERE: doc/ndt_api.md:533, :535, :549 ↔ src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:548, :556-559, :1283, :1296
WHAT: Doc: "Returns the estimated power consumption (in watts, W)" / "In MININET mode, random values are generated". Code: `constexpr uint64_t kBaselineMilliwatts = 30'000;` into `uint64_t power_mW` — milliwatts, range 30 000–149 999 — via splitmix64 on the dpid, explicitly "reproducible across platforms and runs" (deterministic since 0e84234; the doc's example value 851157966 is impossible).
BITES: Energy-Saving-App consumes `power_consumed`; a consumer trusting the documented unit is off by 1000x, and "random" sends anyone diffing runs looking for nondeterminism that is not there.

### test_coverage_gaps.md §1.2 describes a logcheck failure that was dismantled before the doc's own correction pass
GRADE: CONFIRMED
WHERE: doc/test_coverage_gaps.md:158-169 ↔ src/ndt_core/http/HttpSession.cpp:319-330 and tools/contract_test/warning_allowlist.txt:123-130
WHAT: The doc claims malformed-input requests log `[error] Standard exception in request handler` (citing an unguarded `std::stoull` at :924), that `warning_allowlist.txt` covers none of it, and concludes "`./run_layers.sh api p4` 的第三層**永遠是紅的**". Code: the malformed-JSON catch answers 400 and logs WARN; stoull is gone from inform_switch_entered (tryParseUint64 → 400 + WARN); and warning_allowlist.txt:123-130 covers exactly these messages, each annotated with the provoking L2 check. Both fixes (78b822a, 832d75c) predate the doc's 2026-08-10 correction pass (93d6491) — §1.2 was wrong the day it was corrected.
BITES: The doc instructs readers to expect and tolerate a permanently red L3, training them to ignore the layer that would catch real regressions.

### The liveness table's Up condition requires a fresh probe; the code returns Up on probe_ok alone
GRADE: CONFIRMED
WHERE: doc/ndt_api.md:188-190 ↔ src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:431-435
WHAT: Doc: `**Up** | probe_ok == true and probe_age_s ≤ 15 s` (stale age listed under Unknown). Code: `if (probeOkIt->get<bool>()) { … return OvsLiveness::Up; }` — Up is returned before any age check; the staleness branch is reachable only on the probe_ok==false path.
BITES: A proxy poller stalled after a success reads Up per code, Unknown per doc; anyone debugging liveness from the table chases the wrong verdict. (Same probe_ok-alone behavior underlies the powerOn-retry finding above.)

### release_lock failure statuses (423 in ndt_api.md, 412 in testing_workflow.md) cannot be produced
GRADE: CONFIRMED
WHERE: doc/ndt_api.md:2201-2207, doc/testing_workflow.md:214 ↔ src/ndt_core/http/HttpSession.cpp:1930-1942, LockManager.hpp:91-94
WHAT: Doc: "Busy / Invalid Type * Status: **423 Locked** … {"error": "Lock release failed", "detail"…}"; testing doc: "release_lock 用過期的 lock → 412". Code: unlock is void, the handler answers unconditional 200 "released"; the only non-200 is a catch-all 500 with a different body. No path yields 423 or 412. (Behavioral half filed in AUDIT_D.)
BITES: Contract tests or apps written to the documented statuses can never see them; test_coverage_gaps.md:135 already flags the 412 as "目前不成立", yet both source docs still teach it.

### Four flow-write endpoint sections omit the 404 unknown-dpid refusal and the partial-batch fields
GRADE: CONFIRMED
WHERE: doc/ndt_api.md §9/§10/§11/§23 error catalogs ↔ src/ndt_core/http/HttpSession.cpp:975-991, :1042-1049
WHAT: Since 8c25dbc, an all-unknown batch answers 404 with `unknown_dpids`, and a partially-known batch answers 200 with `rejected`/`rejected_dpids`. Grep of the whole doc for `unknown_dpids|rejected_dpids`: zero hits — none of the four sections documents either, though f2498e8 rewrote them ten days after the contract landed.
BITES: A consumer coded from the doc treats the 404 as an outage and silently drops the partial-acceptance information the response carries.

### get_nickname: missing identifier documented as 404; the code answers 400
GRADE: CONFIRMED
WHERE: doc/ndt_api.md:1362-1363 ↔ src/ndt_core/http/HttpSession.cpp:1396-1400
WHAT: Doc: "Returned if no identifier parameter … * Status: **404 Not Found**". Code: `res.result(http::status::bad_request);` with the matching body — 400, body text right, status wrong. The section's invalid-dpid body (`"Invalid DPID format"`/`"stoull"`) likewise no longer exists (removed with the stoull fix; current body is the tryParseUint64 shape).
BITES: Status-code dispatch written to the doc misroutes the missing-parameter case.

### inform_switch_entered's documented 400 body never existed in src
GRADE: CONFIRMED
WHERE: doc/ndt_api.md:996-1000 ↔ src/ndt_core/http/HttpSession.cpp:1102-1108
WHAT: Doc: `{"error": "Invalid dpid format"}`. Code: `{"status":"error","error":"invalid dpid","dpid":…,"detail":"dpid must be an unsigned integer"}`. Per the docs pass's `git log -S`, the documented string never appeared in src/ in this repo's history.
BITES: Anyone matching on the documented error string matches nothing, in the endpoint that is the only path setting isEnabled on a vertex.

### set_switches_power_state: documented 400 body wrong, real 500 failure body undocumented
GRADE: CONFIRMED
WHERE: doc/ndt_api.md:706-727 ↔ src/ndt_core/http/HttpSession.cpp:659, :670-671
WHAT: Doc 400 body: `"Missing or malformed query parameters"`; code: `{"error":"Missing or invalid ip/action"}`. The endpoint's actual operational-failure answer — 500 `{"error":"Failed to change switch power state"}`, what a caller sees when the Phase-7 helper is absent — appears nowhere in the doc (grep: zero hits). The new bmv2 prose itself (b0c82df) is accurate.
BITES: The Phase-7 failure mode operators will actually hit is the one response shape the reference does not contain.

### p4_bmv2_support_plan.md still reports Phase 7 as half-done and powerOn as an empty shell
GRADE: CONFIRMED
WHERE: doc/p4_bmv2_support_plan.md:21, :156 ↔ src/ndt_core/power_management/P4PowerStrategy.cpp (all of it)
WHAT: The status table — presented as current state — says `**7** 電源管理 | 🟨 一半 | … P4PowerStrategy 還沒用它`, and :156 says powerOn "是個什麼都沒做就回傳 true 的空殼", citing a line that now lands inside executeSystemCommand. Since 624946d/1978292 both operations are real (helper + readopt, verified by execution in this audit).
BITES: The planning doc's reader starts re-implementing Phase 7 or distrusts a mechanism that is done and mutation-tested. (phase7_power_mechanism_design.md:10 has the same overtaken premise, but frames it as day-of-writing state.)

### Five f2498e8-era line citations in ndt_api.md have all drifted
GRADE: CONFIRMED
WHERE: doc/ndt_api.md:142 (→ HttpSession.cpp "line 530", now :567), :183 (→ hpp "lines 319-360", now :330-370), :197 (→ topology_manager.py "lines 716-758" as the code emitting `links` — that range now spans the tail of `install_initial_routes`, the `installed_routes` property at :719, and `readopt_switch` at :731, i.e. Phase-7 code added by 1978292; the `"links"` key is actually emitted at :1032), :2746 ("lines 1624-1642", handler now :1683-1700), :2883-2884 ("lines 1644-1678", handler now :1702-1736)
WHAT: All five were exact at f2498e8 and rotted via 7f738e6 (+37 lines) and 1978292 (+~275 lines). I re-opened :142/:2746/:183/:197/:2883 and their current targets; the surrounding behavioral claims still hold.
BITES: Every one now sends a reader into unrelated code; :197's range lands in code that did not exist when the sentence was written.

### Three code citations in p4_status_and_test_guide.md point at unrelated lines
GRADE: CONFIRMED
WHERE: doc/p4_status_and_test_guide.md:451 (TopologyAndFlowMonitor.cpp:2245 — actually a BFS `continue;`, host-edge exclusion lives in getAvgLinkUsage ~:2441+), :343 (intelligent_router.py:282 for `hub.sleep(60)` — the sleep is at :422), :580 (main.py:142 as the inform_switch_entered sender — :142 is a comment; the sender is kernel_notifier.py)
WHAT: Mechanisms described are correct; all three pointers are wrong in the current tree.
BITES: The debugging playbook's "先查" steps land the reader on a BFS guard, a dpid assignment, and a comment.

### Test-count claims in three testing docs are stale again, two days after being "實跑更正"
GRADE: CONFIRMED
WHERE: doc/testing_workflow.md:134, doc/testing_tools_overview.md:55, doc/full_test_runbook.md:103 ↔ `git ls-files`
WHAT: All three teach "31 個 .cpp、414 個 case" (and "12 個檔案、312 個測試" for Python); the tree has 34 tracked tests/*.cpp and 13 p4_proxy test files (42d86cd and 9afd647 added files after the 2026-08-10 correction). full_test_runbook.md:103 presents `[  PASSED  ] 414 tests.` as the expected pass line.
BITES: A reader running the suite "fails" the runbook's acceptance criterion by having more tests than documented — the counts were corrected once and rotted within 48 hours, which is the argument against baking counts into prose at all.

### HANDOFF.md's coverage table: three ❌ rows are now covered
GRADE: CONFIRMED
WHERE: doc/HANDOFF.md:408, :410-411 ↔ tests/ in the current tree
WHAT: `HttpSession … ❌`, `P4PowerStrategy … ❌`, `TopologyAndFlowMonitor … ❌ 無獨立測試` — the tree has test_HttpSessionRouting.cpp, test_P4PowerStrategy.cpp (mutation-verified), test_TopologyAndFlowMonitor.cpp and the _mininet variant. Mitigation: the file self-dates "最後更新 2026-07-31" at line 1, 400 lines away from the table.
BITES: The onboarding doc steers a new contributor toward writing tests that exist; ranked last because the staleness is technically declared.

---

Status of previously known doc errors (not re-reported): p4_manual_test_runbook.md's :2429 citations are fixed (now :2441 with an erratum note); ovs_manual_test_runbook.md §5i's divisor claim is fixed at :766, but its own :621 copy of the `TopologyAndFlowMonitor.cpp:2429` citation did not get the correction (per the docs pass). ndt_api.md's --no-ai warning stands as the documented mitigation.
Cross-ref: a false "drift is caught" claim in p4_proxy/tests/generate_emitted_fixtures.py:16-17 is filed in AUDIT_B (emitted_multi.bin has no drift guard).

Read: my own opens — LLMAgent.cpp (full), Utils.hpp:500-640, P4PowerStrategy.cpp (full, plus executed its committed test suite 8/8), TopologyAndFlowMonitor.cpp:{47-48,425-702 catches,479-481,513-518,1756-1800,1955-1982,2245,2385-2404,2449-2456,2538-2544,1150-1177}, Classifier.cpp:771-774, HttpSession.cpp:{119,432-439 via 7f738e6,567,659-671,975-991,1042-1049,1102-1108,1120-1121,1230,1290,1396-1400,1683-1703,1775-1805,1890-1942}, DeviceConfigurationAndPowerManager.cpp:{56-57,431-435,548-559,737-741,1283-1296,1345-1396,1817-1824}+hpp:330, IntentTranslator.cpp:{22-28,259,269-284,367,416,480-485,977-979}+hpp:324-326, FlowLinkUsageCollector.cpp:{262-273,955-959,1540-1545,2149-2152,2316-2319,2427-2471}+hpp:131-136, TopologyAndFlowMonitor.hpp:{62-81,275-277}, HttpSession.hpp:571-574, LockManager.hpp:93-95, ControllerAndOtherEventHandler.{cpp:41-70,243;hpp:126}, HistoricalDataManager.cpp:{27,61,116-124,140}, ApplicationManager.cpp:{112-117,132,210,217,254}, AppConfig.hpp, main.cpp:{339,349,368-385}, tools/p4_power_helper.py (HEAD):{33-34,211-224,257-260,302-311}, p4_proxy HEAD blobs of main.py/api_routes.py/topology_manager.py/sflow_emitter.py/p4_client.py/kernel_notifier.py/SPEC.md (cited ranges), intelligent_router.py:{25-50,283-311,421-422,788,846}, doc lines quoted above, adjudication doc, git: log/show on 9afd647,b0c82df,1978292,624946d,42d86cd,900d60b,7f738e6,44fa86e,fbd8140. Five audit passes read the remainder end-to-end (their file lists are in the task outputs); every finding above was re-verified by me at the cited lines.
