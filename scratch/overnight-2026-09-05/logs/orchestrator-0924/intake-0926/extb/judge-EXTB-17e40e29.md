# JUDGE: external detect-only 17e40e29

I only read files. Nothing was executed, and I used no git. "OBSERVED" means I read it in the cited file. Path prefixes used below:
- WT = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927
- GL = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910 (files `<gate>.extb1-17e40e29.log`)
- RAW = /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep

## Verdict: MERGE AFTER FIXES

**The code itself is correct.**
- Detect-only holds on two independent layers. I found no path by which the proxy writes to a switch on an external fabric.
- `reroute` is false with reason `external_control_plane` in every state after startup.
- Every gate number is in its log for sha 17e40e29. Red-first is real and red for the right reasons.

**The evidence plan cannot yet close the side-effect question.** These must be fixed before merge:
- **F1:** the live comparison can print NO DIFFERENCE without the heartbeat ever having run.
- **F2:** the baseline is not "same code except B", and its noisy fields come with a pre-declared excuse.
- **F3:** the blind spot for external programs in general is not disclosed.
- **F4:** "a cut is told to the twin" is not exercised live anywhere in the plan.

F5–F9 are small text, doc and robustness fixes.

## 1. Q1 — detect only (OBSERVED: no write path)

**Clients cannot write.**
- `arbitration=package.arbitration` (WT/p4_proxy/proxy_agent/main.py:257) is False under external (WT/p4_proxy/mininet/app_package.py:288-300). `start()` then opens no stream (WT/p4_proxy/proxy_agent/p4_client.py:634-637).
- Every Update or pipeline RPC calls `_refuse_write` first (p4_client.py:495-506). Call sites: packet-out 592, pipeline 730, clone 831, multicast 943, table entry 1344, 5-tuple 1774/1813/1852, ipv4 1879/1958/2004.
- The liveness loop only calls `probe`, which is GetForwardingPipelineConfig COOKIE_ONLY, a read (693-723).

**Startup never reaches a write on external.**
- Every startup write site is behind `read_only`: main.py:1931, 1968, 1991, 2025, 2299, 2318.
- The new branch at main.py:2234-2248 only seeds the graph. `seed_declared_links` (WT/p4_proxy/proxy_agent/topology_manager.py:743-793) touches neither kernel nor switch.
- main.py:2277-2282 starts the heartbeat watchdog: evidence plus `start_link_watchdog(seed_expected=False)` (topology_manager.py:2423-2445). No LLDP is started.

**A transition does not reroute.**
- `routes_to_attached_hosts_only = SKIP_ROUTES in skipped` (main.py:2258) is True, because EXTERNAL_SKIPS contains install_initial_routes (main.py:345-346) and nothing removes it on external.
- The watchdog pass then only logs and calls `push_destination_paths` to the kernel (topology_manager.py:2153-2165).
- Even without the flag, `install_initial_routes` would hit `_refuse_write`, which is caught at 2158-2164.

**The kernel does not push flows back.**
- `/ndt/link_failure_detected` marks the edges down and emits `LinkFailureDetected` (WT/src/ndt_core/http/HttpSession.cpp:841-843, 870-872).
- No `registerHandler` exists anywhere under WT/src, so nothing consumes that event.
- Any flow write the kernel does send reaches `/stats/flowentry/*` and gets a 409 (WT/p4_proxy/proxy_agent/api_routes.py:172-186, 540/613/646).

**`reroute` in every state.**
- `_fabric_reroute` checks `external` first and returns False with `external_control_plane` whatever the heartbeat says (main.py:1267-1280).
- The capabilities overlay uses the same function (1302-1311).
- The recorded `reroute` is lldp AND watchdog; both stay False on external.
- The only other answer is None, before startup has run (1265-1266).

## 2. Classification of the report's verdicts

1. **"18 gates rc 0; first line 17e40e29…; last line `# rc=0`"**: SUPPORTED. I checked all 18 logs in GL.
2. **§5 gate table numbers**: SUPPORTED, with small nits (see §6).
   - proxy_unit:57 says 46 files, 1672 tests: 1671 passed, 1 skipped. I summed lines 11-56 and got 1671.
   - Suites: test_ndt_heartbeat:89 61/0; test_ndt_app_package:449 395/0; test_ndt_up_down_robust:484 424/0; test_live_p1_common:246 204/0; test_live_p1_thirteen:69 45/0; test_live_p1_external_evidence:54 34/0; selftest_08:151 PASS; test_drive_exercise:82-84 178 OK.
   - Mutation gates: heartbeat_w:253/256 117/117 and 219/0; mutate_live_p1_common:361 56/0 with 4 controls; mutate_live_p1_thirteen:122 12/0; mutate_live_p1_external_evidence:24-25 9/0 with sha unchanged; mutate_roles_binding:619/622 196/196 and 179/0; mutate_app_package:69 48/0.
   - check_gate_anchors:139 122/122. nolab_tripwire:22-23 0 lab calls; all 1980 shim lines contain `file://`.
3. **Red-first P: 8 red at base, 5 guards green at base, HEAD 40 OK**: SUPPORTED. GL/redfirst_b:13-21 and GL/redfirst_b.extb1-17e40e29.kept/p_base_main.out lines 1-13 and 209. The 8 are 7 FAIL tests plus 1 ERROR (`not_started` read from a missing heartbeat block). One test fails in 2 subtests, which is why the log says "failures=8, errors=1".
4. **Guards killed by X2, X2b, X3, X8, M01b**: SUPPORTED (heartbeat_w:76, 96-98, 103).
5. **ndt 3 red at base; N03c kills the non-external check**: SUPPORTED (redfirst:22-24; heartbeat_w:140-142).
6. **08 6 red; `_common` 6 red plus the 03/04 pins; 06 3 red**: SUPPORTED (redfirst:25-38).
7. **Evidence suite: 4 cells green without the tool, killed by E3, E4, E9**: SUPPORTED (redfirst:39-44; evidence gate:16-17, 22).
8. **Detect-only on two layers; `reroute` false/external in every state**: SUPPORTED (see §1).
9. **`link_discovery` is declared/heartbeat; `none` only for external on NDTwin's pipeline; prediction updated**: SUPPORTED (main.py:1161-1166, 1195; WT/p4_proxy/tests/test_heartbeat_fabric.py:384-447).
10. **Ruling E applies; the external Skipped line is printed after the decision**: SUPPORTED (main.py:2281-2285; tests 410-441).
11. **"`ndt up p4 --app` now starts the heartbeat on all 20 of segment S's arms"** (§1, and HEARTBEAT_CENSUS at main.py:1343-1347): UNDER-EVIDENCED.
    - It is inferred from `heartbeat_wanted` (WT/tools/test_workflow/ndt:2962-2964) and has never been observed on B.
    - It is served verbatim on switch_state, inside a constant whose own comment calls it "Measured numbers" (main.py:1324-1329).
    - H5 would show it; H5 has not run on B.
12. **"OLD_06 = 074635Z, same rc and verdict as 185505Z arm for arm"**: SUPPORTED. I compared the two `00_table.tsv` files row by row.
13. **"074635Z is the no-heartbeat baseline"**: two parts.
    - No heartbeat on the external arms: SUPPORTED. The ndt status in those arms reads "heartbeat stopped (stopped by SIGTERM), 47 s ago" (RAW/live-p1/runs/2026-09-27T074635Z_06_thirteen/p4runtime_solution.log:185; flowcache_solution.log:191).
    - As a same-code baseline for an A/B comparison: UNDER-EVIDENCED. See F2.
14. **Self-compare of 074635Z against itself gives NO DIFFERENCE, with the quoted readings** (§4).
    - The readings are SUPPORTED against the raw logs:
      - p4runtime solution: RAW/runs/2026-09-27T081205Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log:121-125.
      - p4runtime skeleton: …081131Z…:57-61.
      - flowcache solution: …081256Z_flowcache_solution_ndtwin/driver-controller-flowcache.log:12-45. That log has 6 PacketIns, 5 cache entries, every payload ethertype 0x0800, and 1 gRPC error.
    - The self-compare itself proves nothing: an A-vs-A of identical files cannot fail, and its output is not archived.
15. **"The flowcache controller died after the 6th packet-in; G1 passed anyway"**: SUPPORTED (controller log :37-45; RAW/runs/2026-09-27T081256Z_flowcache_solution_ndtwin/link_usage/iperf_client.txt:10).
16. **"An unreadable arm prints no conclusion"**: partly supported.
    - SUPPORTED for a missing table, row or log (WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/external_evidence.py:158-160, 184-192).
    - NOT for an OSError or UnicodeDecodeError: those escape `main`, print a traceback, and exit 1, which is the tool's "difference" code.
17. **`AnExternalFabricsCutIsToldAndRewritesNothingTest`, "real TopologyManager"**: SUPPORTED as described, but it is not end to end.
    - The kernel is a RecordingNotifier.
    - The TopologyManager is the test Fabric's own pod-topo instance, with only the flag copied from startup (test_heartbeat_fabric.py:462-477).
    - It asserts the same thing as the pre-existing WT/p4_proxy/tests/test_heartbeat_watchdog.py:240-243.
18. **"The kernel side is visible in live 06 or on a fabric with a controller"** (§7): CONTRADICTED for 06.
    - 06 never cuts a link.
    - The only planned external cut is H4, and H4 deliberately does not judge the kernel (08_heartbeat.sh:42-45, 273, 2330).
19. **"Expected twin-side changes (INFERRED)"** (§4): SUPPORTED as labelled, but incomplete. See F5.
20. **"merge-tree onto 149c8234 is clean, so the gates need not be rerun"**: UNDER-EVIDENCED. No output is archived, and a clean textual merge is not a tested merged tree. The risk is low if the caller's premise holds that trunk's commits after f7e2a128 do not touch B's files.
21. **Live behaviour of H4, 03/04 and the fingerprints**: UNTESTED; the report acknowledges this in §7.

## 3. Findings

**F1 (blocking for the live decision) — the comparison can pass vacuously.**
- WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/README.md:327-332 prescribes a plain 06 run plus `compare`.
- `external_evidence.py` reads only `00_table.tsv`, the controller logs and `00_venv.txt` (external_evidence.py:56-136). It never checks that the new run had a heartbeat.
- A start that fails is only a warning and never fails the bring-up (ndt:2982-2983). If that happens on an external arm, the new run is an A/A and prints NO DIFFERENCE.
- Required: the tool or the procedure must refuse a new run unless each external arm's log shows ndt's "detect only" start line and a `heartbeat running (pid, session)` status row. Preferably use `PART=h5`, whose sampler records the daemon's session per arm.

**F2 (blocking) — the baseline is not "same code except B", its fields are noisy, and the report pre-excuses one arm.**
- Every 074635Z arm records `code 5dc7fc9a +95 file(s) with uncommitted changes` (RAW/live-p1/runs/2026-09-27T074635Z_06_thirteen/p4runtime_solution.log:153; flowcache_solution.log:159).
  - That is neither f7e2a128 nor 149c8234.
  - The report never states the baseline's code identity, and the baseline has no venv fingerprint.
- The flowcache fields depend on a race.
  - The 6th PacketIn is the same flow on s1 again, and the gRPC UNKNOWN follows (controller log :32-45).
  - §4 already declares that any flowcache difference is "not the heartbeat", so that arm's comparison cannot fail.
- The p4runtime `counters_final` also depends on timing.
  - Tunnel 200 = 7 = 5 ping replies + iperf report datagrams.
  - The last counter block is whatever was printed before the controller was stopped. A SIGTERM mid-block gives a partial dict (external_evidence.py:92-100).

**F3 (disclosure) — external punts are invisible, and B applies to every external package.**
- On an external fabric, a heartbeat frame that a program punts goes to the user's controller.
  - The proxy has no stream there.
  - The daemon counts only frames leaving switch ports.
  - So switch_state's `side_effects` and `frames_reached_hosts` cannot see a punt.
- For the three measured programs a punt cannot happen (§4 Q2).
- But B asks for the heartbeat on every external package running its own pipeline (ndt:2962-2964).
- The helper refuses only a switch whose argv `.json` basename is `ndtwin_switch.json` (WT/tools/test_workflow/ndtwin-lab:883-887, 961-966).
- Any external program that punts or floods an unknown ethertype would hand these frames to its controller or its hosts. An L2 learning controller is the obvious case.
- Neither the summary nor the README says this. It should be disclosed in the README's external section and the census note, and an opt-out should be considered.

**F4 — "told to the twin" is not tested live.**
- H4 prints `reported_to_kernel` but does not judge it (08_heartbeat.sh:273, 2330). 06 has no cut.
- Fix: H4 should require `reported_to_kernel: true` on both directions after the cut and after the restore. It should also require that `pipeline_commits` and `rules_timed` on every switch are unchanged across the cut.

**F5 — operator text is now wrong, and one twin-side change is undisclosed.**
- ndt:2982-2983, the failure branch: says "the proxy reports reroute.reason heartbeat_not_running". On external the reason is `external_control_plane`.
- ndt:4013-4016 and 4029-4031, the external verify branch: says the proxy "starts no watchdog" and that "0 is the designed answer" for destination paths.
  - With B, `/ryu_server/all_destination_paths` renders a shortest-path search over the declared links, because the installed-routes map is empty on external (api_routes.py:343-344; WT/p4_proxy/proxy_agent/ryu_topology.py:226-239).
  - So the reading becomes nonzero, and the twin's path table on an external fabric is a guess rather than the exercise's actual forwarding.
  - This is not in the summary's INFERRED list.
- main.py:1087 and 1097-1107: comments still say external means `none` and "nothing seeds them".
- topology_manager.py:2154-2156: the log gives the unbound/owned-by-package reason on external.
- WT/p4_proxy/tests/test_declared_links.py:319: the test is still named "an external fabric seeds nothing", which is now true only on NDTwin's own pipeline.

**F6 — the census sentence is inference presented as measurement.**
- The "starts it on all 20 too" sentence (main.py:1343-1347) should read as an expectation until H5 confirms it.

**F7 — tool robustness in `external_evidence.py`.**
- Unreadable files: see item 16 (traceback, exit 1).
- A payload whose ethertype cannot be parsed returns None and is silently not counted (external_evidence.py:101, 108). A format drift would make `heartbeat_packet_ins` a guaranteed 0.
- Fix: report packet-ins that are non-IPv4 or cannot be parsed, not only 0x88B5, and treat any unparsed packet-in as unreadable.

**F8 — gaps in the evidence mutation gate.**
- WT/tests/shell/mutate_live_p1_external_evidence.sh:68-110 has no mutant that drops `packet_ins`, `cache_entries`, `grpc_errors`, `rc` or `verdict` from COMPARED.
- It has none that breaks ethertype parsing.
- The suite has checks for all of these (WT/tests/shell/test_live_p1_external_evidence.sh:137-162), but they have never been seen red.
- E1–E9 themselves are realistic.

**F9 — H4's restore bound silently differs.**
- H4 judges the restore at `RESTORE_BOUND_S + 15` = 35 s (08_heartbeat.sh:2340).
- The 08 header (08_heartbeat.sh:69-70) and README.md:300 say the restore is still judged at a strict 20 s.

## 4. Q2, Q3 and Q4 notes

**Q2 — what the three exercise programs do with a 0x88B5 frame (OBSERVED from the P4 sources):**
- **flowcache/solution:**
  - The parser accepts a non-0x0800 frame without further headers (/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4:137-143).
  - Ingress drops anything that is neither packet-out nor IPv4 (flowcache.p4:251-257).
  - So there is no punt, no cache entry and no counter hit. The counters only count packet-out at ingress (236-238) and the CPU-port egress (279-283).
- **p4runtime skeleton and solution** (same program; only the controller differs):
  - The parser has a default accept (/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4:70-74).
  - No table applies to such a frame (170-180), so `egress_spec` stays at its default 0.
  - Switch ports are `sX-ethN` from 1 (WT/p4_proxy/mininet/p4_testbed_topo.py:209-211; the helper enforces the names at ndtwin-lab:893-896). Port 0 has no interface, so the frame is dropped. This drop is INFERRED from bmv2's behaviour.
  - Tunnel counters only move inside the tunnel actions (123-141). There is no controller header, so a packet-in is impossible.
- **Census:** segment S ran the heartbeat by hand on all three arms, with zero host frames, `forwarded_between_switches=0` and `misdelivered=0` (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T052148Z_S_heartbeat/40_census.tsv:24-26).
- **What the plan measures:** the 0x88B5 punt at the flowcache controller and the p4runtime counters. It does not use the daemon's own `forwarded_*` counters, which are the direct measure of "not forwarded".
- **Disclosure:** the summary never states this P4-level reasoning.

**Q3 — where `ndt` now starts the heartbeat:**
- `app_pipe` is computed for every `--app` package (ndt:3251), and the mode is now ignored.
- NDTwin's own pipeline, the baseline and "unreadable" packages are never asked.
- Mixed fabrics (any `pipeline: null` switch) are asked, and the helper refuses them because that switch's argv names `ndtwin_switch.json` (p4_testbed_topo.py:355). The warning printed then has the wrong reason (F5).
- Stop paths are gated on the pidfile and do not depend on the mode: `ndt down` (ndt:5259), rollback (ndt:3075), topology replacement (ndt:3470). `up_started heartbeat` is recorded before the call (ndt:2972), so a rollback covers a half-start. All OK.

**Q4 — the evidence tool:** parsing matches the real log formats (`ast.literal_eval` works on the flowcache `ret=` lines). Unreadable handling is covered in item 16; the remaining gaps are F7 and F8.

## 5. What the live run must show before I consider the side-effect question closed

For p4runtime/skeleton, p4runtime/solution and flowcache/solution:

1. **The treatment was applied.**
   - ndt's "detect only" start line appears.
   - `ndt status` shows `heartbeat running` with a session.
   - That session's report has every direction heard during the controller's lifetime (via H5's sampler).
2. **Identity is recorded.** The arm logs name B's code, and `00_venv.txt` is present.
3. **The daemon forwarded nothing.** `forwarded_to_hosts`, `forwarded_between_switches`, `misdelivered` and `foreign_frames` are all 0 on each arm.
4. **flowcache:**
   - Every PacketIn is ethertype 0x0800. Zero are 0x88B5 and zero are unparsable.
   - Every cache entry belongs to a driver flow.
   - Count differences are acceptable only inside a control's spread (item 8).
5. **p4runtime:**
   - `rules_installed` is identical to the baseline.
   - Solution counters meet an invariant from the same arm, independent of the baseline:
     - s1 ingress 100 = pings + iperf datagrams (+ FIN retries), with the datagram count from `link_usage/iperf_client.txt` ("Sent 3500 datagrams" in the baseline).
     - s2 egress 100 = s1 ingress 100.
   - Skeleton: 5 on s1 ingress 100, 0 everywhere else.
6. **The proxy wrote nothing.**
   - On every switch, `pipeline_commits` is 0 and `table_generation` is null at the end of each arm.
   - No refused write originates from the proxy's own threads.
   - The count of kernel-initiated 409s is recorded and compared with the baseline arms. A rise is expected now that the twin has a graph; disclose it.
7. **rc and verdict** match 074635Z for every arm.
8. **A same-session control exists.** Run the same three arms with the heartbeat stopped after `ndt up`, or on trunk 149c8234, with the same venv. A DIFF counts only if it falls outside that control's spread, and it may not be explained away after the fact.
9. **H4 runs once with F4's assertions.**

## 6. Tests I would have run, and inconsistencies in the report's own numbers

**Tests I would have run that the report did not:**
- Startup with a real TopologyManager and real `P4RuntimeClient(arbitration=False)` objects on an external package running its own pipeline. The stub should fail the test on any Write, SetForwardingPipelineConfig or StreamChannel. Then drive a cut through `run_watchdog_pass`. The shipped tests never combine the real client layer with the new branch; they use HeartbeatTopo and FakeClient.
- An offline data-plane check of the three programs with a 0x88B5 frame, using bmv2 or p4testgen.
- ndt with an external mixed package, to see the helper refusal and the text printed.
- For the tool:
  - an A/A comparison of two independent no-heartbeat runs;
  - fixtures for a truncated counter block and an unparsable packet-in line;
  - a new run without a heartbeat, which the tool must refuse.

**Inconsistencies in the report's numbers:**
- **X mutants:** the report says "X1–X10", but there is no X4 (WT/tests/shell/mutate_p4_heartbeat_w.sh:713-781; heartbeat_w log:95-105). There are nine numbered X mutants plus X2b and X3b.
- **Red-first count:** "exactly 8 red" against "FAILED (failures=8, errors=1)". This reconciles only through subtests, and the report does not explain it.
- **Disk:** "4148–4525 MB" is the under-lock range only. The queued readings span 4147–4712 (heartbeat_w log:7; mutate_live_p1_common log:7).
- **Restore bound:** the report says the restore is still judged at a strict 20 s; H4 uses 35 s (F9).
- **Kernel side:** §7 says the kernel side is visible in live 06, but 06 has no cut (F4).

**Discipline:**
- The `[Co-developed with claude code -- Adam]` tag is on every new block I read.
- There is no `pkill`/`pgrep`. 08_heartbeat.sh:1494 is the pre-existing self-test killing its own sampler by pid.
- Temp dirs are `mktemp` under TMPDIR, which is the session scratchpad, with trap cleanup.
- Commit messages were not checked (no git).
