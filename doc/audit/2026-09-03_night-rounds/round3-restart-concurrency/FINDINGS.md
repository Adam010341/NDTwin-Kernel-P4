# Round 3 (night) -- restart & concurrency. Running FINDINGS.

[Co-developed with claude code -- Adam]

**Binary of record:** `a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06`
(`sha256sum build/bin/ndtwin_kernel`, verified 01:48:34 before anything ran -- `00_binary_and_env.log`).
**Repo HEAD at round start:** `f29b46b3` ("Night round 2: powering switches on and off...").
`p4_proxy/mininet/host_count_override` was **128** at round start; `ndt up` rewrites it; restore by
explicit single-file path at the end.

NEXT: nothing -- round closed. SUMMARY.md written, fabric down and verified (`15_teardown.log`),
`host_count_override` restored to 128 by explicit single-file path, binary re-verified as `a8ba99c2`
at 02:52, claim `auditor` kept.

## Table

| # | claim | severity | evidence log | control | reproduced | status |
|---|---|---|---|---|---|---|
| -- | (round opened) | -- | `00_binary_and_env.log` | -- | -- | -- |
| **C1** | **Lead C settled: the bmv2-liveness startup race is a REAL race, and it is LOST on every shipped topology.** Win rate is a step function of topology-file size: 310 B 5/8 won, 587 B 5/8 won, 7834 B 0/8, 9486 B 0/8, shipped 4-host 16960 B **0/20**, shipped 128-host 138820 B 0/8. **0 wins in 44 starts on files >=7.8 KB.** | HIGH | `01_leadC_20_restarts_4host.log`, `02_leadC_parse_time_positive_control.log`, `raw/{t4host,topo_1sw,topo_2sw,topo_10sw_0host,topo_4host_compact,t128host}/run*.out` | positive control = the 310/587 B arms (10 WON verdicts prove the instrument discriminates); `allbmv2=1` in **all 60** runs proves the identical predicate answers TRUE later, so the loss is timing, not topology | 60 kernel starts, 6 topologies | **CONFIRMED** |
| **C2** | **The kernel's sockets outlive the kernel: `:8000` (TCP) and `:6343` (UDP) stay bound ~2.0-2.2 s after the kernel pid is provably gone**, because every `popen`'d `sh`/`curl` child inherits the listening fds. `ss` lists one socket with users `ndtwin_kernel fd=8` + `curl fd=8` + `sh fd=8` (TCP) and `... fd=3` (UDP); after SIGKILL only the curl/sh users remain. | HIGH | `03_port_inherited_by_forked_children.log` A and D | window closes by itself at t+2.5 s in the same trials | 48/48 in step 02 + 1 dedicated trial each for TCP and UDP | **CONFIRMED** |
| **C3** | **A kernel restart inside that window fails 6/6, and the message names the wrong culprit.** The blocker is UDP `:6343`, and the kernel says `"Another NDTwin kernel is almost certainly still running and holding it"` -- there was none; the holder was the previous kernel's own orphaned `curl`/`sh`. Kernel exits 1 (refusing to run without telemetry is right; the diagnosis is not). | HIGH | `03_port_inherited_by_forked_children.log` B | **negative control C: identical sequence with a 3.0 s gap -> 3/3 start and answer `200`** | 6/6 fail inside, 0/3 outside | **CONFIRMED** |
| **C1b** | Lead C holds on the **live** fabric: the kernel `ndt up p4 4` started (pid 1286422, `/proc/<pid>/exe` = `a8ba99c2...`) issued **0** `GET /p4/switch_state` in 951 proxy log lines, logged **0** `cannot read bmv2 liveness`, while `All-bmv2 topology` was logged once. Load at 02:06:32.342, DCPM start at 02:06:32.342, homogeneity validated at .344. | HIGH | `05_leadC_confirmed_on_live_fabric.log` | count re-taken 30 s later, still 0; contrast `/v1.0/topology/*` polls do appear | 1 live fabric + 44 harness starts | **CONFIRMED** |
| **D1** | **Lead D settled: a commanded power-off is lost exactly when a topology poll is applied while the proxy still lists the switch.** `TopologyAndFlowMonitor.cpp:768-772` writes `isUp=true; isEnabled=true` for every switch the proxy lists and **has no else-branch that writes false**, so a resurrection is permanent. **Phase A (fire ~1.5 s before a poll): LOST 8/14. Phase B (fire ~2 s after a poll, next poll ~28 s away): LOST 0/4.** In *every* lost trial the `is_up` 0->1 transition is at **t_off + 2.31 s**, i.e. the poll that reached the proxy at t_off+1.86 s being applied 0.45 s later. | HIGH | `08_leadD_phase_experiment.log`, `09_leadD_phaseA_more_trials.log`, `11_leadD_proxy_list_at_poll_instant_rerun.log` | phase B is the negative control: identical switches, endpoint and fabric, only the phase changed, 0/4 lost. Process death verified independently every trial (`:3005N` closed, bmv2 procs 10->9) | 18 commanded power-offs | **CONFIRMED** |
| **D2** | **The residual within phase A is the proxy's own drop delay, measured.** Sampling `/v1.0/topology/switches` at 10 Hz: drop delay 0.00 s -> KEPT, 1.85 s -> KEPT, 1.95 s -> LOST, 2.76 s -> LOST, 2.88 s -> LOST (x2). The cut sits at the kernel poll's arrival, ~1.85 s. So "was the dpid still listed when the kernel's poll arrived" predicts the outcome in **5/6** trials, the one miss being 0.10 s off the boundary. Poll period is 5 s for the first 90 s (`kConvergingFor`) then **30 s** (`TopologyAndFlowMonitor.cpp:2506-2508`), so the loss rate an operator sees is ~D/30 once converged and ~D/5 during the first 90 s. | HIGH | `10_`, `11_`, `07_leadD_proxy_drop_delay.log` (D=3.06 s measured out-of-band, no kernel command involved) | out-of-band kill in `07_` establishes D with the kernel's power path removed entirely | 6 traced trials | **CONFIRMED** |
| **D3** | **Round 2's D16b is real but time-bounded, and the bound is 15 s.** `P4PowerStrategy.hpp:45 kPostPowerOffDistrustWindow{15}`. Recovering a lost-power-off switch **within** the window works: 14/14 `action=on` calls took ~1.47 s and opened `:3005N`. **After** it, `powerOn:73` early-returns on the resurrected `isUp`: 4/4 calls on lost switches returned `200 Success` in **~1 ms** and started nothing, needing out-of-band `sudo ndtwin-p4-power on`. | HIGH | `08_`, `09_` (restore at ~40 s: 4/4 fail) vs `11_` (restore at ~12 s: 3/3 succeed) | the fast/slow split is itself the control -- same call, same switches, only the elapsed time differs | 8 fast + 14 slow calls | **CONFIRMED** |
| **X1** | *Instrument fault of mine, recorded not deleted:* step 10 lost 4 of its 5 trials to my own harness -- `wait_for_poll` compared `len(deque(maxlen=50))` against a snapshot, so once the deque filled it never reported another poll ("no poll seen" x4). The kernel was fine. Fixed with a monotonic counter and re-run as `11_`; step 10's one completed trial is carried forward. | -- | `10_`, `11_` | -- | -- | (my error) |
| **E1** | **Lead E settled, and the answer is the opposite of the worry: NOTHING blocks behind `routing_lock`.** Held hostage at `ttl 300` exactly as a wedged Energy app holds it, all 10 kernel endpoints and both `ndt` subcommands returned the same status and the same latency as the control taken minutes earlier: `install_flow_entry` 200/0.001 s, `delete_flow_entry` 200/0.001 s, `set_switches_power_state` off 0.237 s + on 1.474 s (**both did real work**), `get_graph_data` 200, `get_path_switch_count` 200, `ndt status --check` rc=0, `ndt check` rc=0/8.1 s. Nothing hung, nothing timed out, nothing was refused. | HIGH | `12_leadE_routing_lock_hostage.log` | the same sweep with the lock free, taken first, in the same script | 1 hostage sweep + 1 control sweep, 24 calls | **CONFIRMED** |
| **E2** | **The lock is genuinely held and protects nothing.** A competing `acquire_lock` returns **423** `retry_after_s 299` at t+0, +15, +30, +45, +60, +75, +90 s -- so the instrument has power and the exclusion is real. But `LockManager` is consumed by no routing, power, topology or flow path, and **the Energy-Saving-App is the lock's only client in the whole deployment** (`grep -rn acquire_lock` over the kernel repo, `/home/adam/Energy-Saving-App`, `/home/adam/Simulation-Platform-Manager`: production hits only in `Energy-Saving-App/src/app/http.cpp:421-455`, ttl 300). So round 2's A3 wedge stops the Energy app and **nothing else** -- it is a single-app liveness bug, not a system-wide concurrency hazard. | HIGH | `12_` | -- | 7 competing acquires | **CONFIRMED** |
| **E3** | *Hypothesis of mine, REFUTED by its control.* Two `install_flow_entry` fired simultaneously for the same match with different actions left **one** entry on the switch (`0a000063/32 -> ipv4_forward - 00, 02`, read from bmv2's own thrift CLI on 9091) while the twin counted **both** as `succeeded` -- which looked like a lost update. **The sequential control does exactly the same**: install OUTPUT:1 -> switch shows `00, 01`, succeeded 8; install OUTPUT:2 -> switch shows `00, 02`, succeeded 9. Last-writer-wins is the semantic, not a race. What is left is milder and not a concurrency defect: a replace is indistinguishable from an add in both the response body and the dispatch counters. | LOW | `13_two_writers_same_match.log` | the sequential arm in the same log | 1 concurrent + 1 sequential | **REFUTED** (as a race) |
| **V1** | **The viz chain is CAPTURED (COMMON-BRIEF section 15's blocked fact) and it is 3 processes, not 4.** `bash ./network_traffic_visualizer.sh` (comm `network_traffic`) -> `java ... org.apache.maven.wrapper.MavenWrapperMain javafx:run` (214 MB) -> `java ... --module org.example.ndtanimation/org.example.demo2.NetworkTopologyApp` (318 MB). Full argv of all three is in the log. **The launcher name appears in 0 of the 2 JVMs' argv and `comm` is `java` for both** -- so section 15's structural claim is confirmed. The usable discriminator a fix can key on: the string `Network-Traffic-Visualizer` appears **2x** in the maven JVM's argv and **1x** in the app JVM's, and **0x** in the launcher's. | HIGH (unblocks) | `14_viz_process_chain.log` | -- | 1 capture, full argv | **CONFIRMED** |
| **V2** | **`ndt apps stop viz` reports `ok viz stopped (was: running)` while leaving both JVMs alive (531 MB), and `ndt apps orphans` then answers `ok no untracked app processes`.** `ndt apps` shows viz as `-`. The stop path also leaks a shell error, `ndt: line 1687: /proc/1320231/cmdline: No such file or directory` -- it reads the cmdline of the pid it has just killed. I killed both orphans myself by exact pid; SIGTERM was enough. | HIGH | `14_viz_process_chain.log` | after my kill, `ps -eo comm=` java count 0 and orphans still says the same thing -- i.e. the check gives the same answer with and without orphans, so for viz it has **zero discriminative power** | 1 stop | **CONFIRMED** |
| **X2** | *My own recording error, kept:* `ORPHANS_RC=0` in `14_` is `head`'s exit code, not `ndt`'s -- the pipeline-tail mistake round 1 warned about (H-21). The evidence for V2 is the printed text, not that rc. | -- | `14_` | -- | -- | (my error) |
| **C4** | No cleanup path checks `:6343`. `grep -c 6343 tools/test_workflow/ndt` = **0**, `stack.sh` = **0**; the sweep is `ndt:1112 for p in 8000 8080 8081`. So the port that actually blocks a restart is one no tool looks at -- the same shape as round 1's D8 for `:6653`/`:6633`. | MEDIUM | `03_port_inherited_by_forked_children.log` D | -- | grep, deterministic | **CONFIRMED** |

## Structural reading done before any run (code only, no measurement)

- `main.cpp:409` `topologyAndFlowMonitor->start()` only **spawns** `m_thread = thread(&...::run)`
  (`TopologyAndFlowMonitor.cpp:156-160`); the topology load runs on that thread.
  `main.cpp:432` `deviceConfigurationAndPowerManager->start()` -> `refreshDataPlaneKind()` runs on
  **main**. Between them main does `collector->start(20,4096)` (418), `historicalDataManager->start()`
  (430), `handler->start()` (431). No synchronisation of any kind between the two threads => Lead C is
  structurally a race, not a fixed order.
- `refreshDataPlaneKind()` (`DeviceConfigurationAndPowerManager.cpp:107-116`) returns **true if the
  kind index contains >=1 entry and they are all BMV2**. `m_dpidToSwitchKind` is filled *incrementally
  inside the node loop* (`TopologyAndFlowMonitor.cpp:308-309`), so a partially-loaded index still
  answers TRUE. The only losing state is a **completely empty** index. The losing window is therefore
  [thread start ... first switch node indexed], whose dominant cost is `file >> j` at
  `TopologyAndFlowMonitor.cpp:214` -- the whole-file JSON parse. **Prediction: topology file size tips
  the race.**
- The outcome is binary and self-latching: a win makes `pingWorker` (1 s period,
  `DeviceConfigurationAndPowerManager.cpp:616`) call `fetchP4SwitchState()` **every second for the
  whole process lifetime**; a loss makes it never call it. There is no intermediate count.
- `fetchP4SwitchState()` (`:482`) logs `cannot read bmv2 liveness from the proxy (...)` on failure.
  => **a kernel started with no proxy at all discriminates a won race from a lost one**, with no
  fabric needed. That is this round's Lead-C instrument, and arm 2 is its positive control.
- Lead E, structural half: `routing_lock` is **advisory only**. `LockManager` is referenced from
  `main.cpp:392`, `HttpSession.cpp` (the three lock endpoints) and `ControllerAndOtherEventHandler`.
  **No routing, power, topology or flow endpoint consults it.** So "what blocks behind the lock" is
  predicted to be *nothing in the kernel* -- only clients that voluntarily call `acquire_lock`.

## Closing note

Binary re-verified after everything: `a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06`,
unchanged from the pre-round sample (`15_teardown.log`). Repo HEAD moved `f29b46b3 -> 38b4651e` during
the round, by another session; the binary predates both. 16 numbered logs, `raw/` (60 kernel-start
captures + the timed proxy trace), `topo/` (four topology files I generated for the Lead-C parse-time
arm -- all untracked, none of them a shipped file). Nothing built, nothing committed, nothing pushed.
