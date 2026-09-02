# Round 3 (night) -- restarts and concurrency. SUMMARY.

[Co-developed with claude code -- Adam]

**Binary of record: `a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06`**, verified by
`sha256sum build/bin/ndtwin_kernel` at 01:48:34 **before** anything ran and again at 02:52 **after**
everything (`00_binary_and_env.log`, `15_teardown.log`) -- it did not move under me, and the running
kernel's `/proc/<pid>/exe` was the same hash (`05_`). Repo HEAD moved `f29b46b3 -> 38b4651e` during
the round (another session's commit); the binary predates both. Nothing built, nothing committed,
nothing pushed. Lab claim `auditor` **kept** -- 283 min left at 02:52.

Plane: fabric-free kernel restarts for Lead C's 60 starts, then **P4 / bmv2, 10 switches, 4 hosts**
(`ndt up p4 4`) for leads D and E.

---

## 0. The three assigned leads, all three settled

### Lead C -- is the bmv2-liveness startup race lost sometimes or always? **SETTLED: it is a real race, and it is tipped by the topology file's parse time. On every shipped topology it loses 100% of the time.**

Structure first (`main.cpp:409` vs `:432`): `TopologyAndFlowMonitor::start()` only *spawns* the
thread that loads the topology, and `DeviceConfigurationAndPowerManager::start()` calls
`refreshDataPlaneKind()` on **main** about a millisecond later, with no synchronisation between
them. `refreshDataPlaneKind()` answers TRUE if the kind index holds >=1 entry and all are BMV2, and
the index is filled *incrementally inside the node loop* (`TopologyAndFlowMonitor.cpp:308-309`) --
so the only losing state is a **completely empty** index, and the losing window is dominated by
`file >> j`, the whole-file JSON parse at `:214`.

Instrument: with no proxy running anywhere, a **won** race makes `pingWorker` (1 s) call
`fetchP4SwitchState()`, which logs `cannot read bmv2 liveness from the proxy`; a **lost** race never
calls it. Binary and self-latching -- a win is hundreds of calls, a loss is zero, never in between.

**60 cold kernel starts:**

| topology file | bytes | race WON |
|---|---|---|
| `topo_1sw.json` (mine) | 310 | **5/8** |
| `topo_2sw.json` (mine) | 587 | **5/8** |
| `topo_10sw_0host.json` (mine) | 7 834 | 0/8 |
| `topo_4host_compact.json` (mine) | 9 486 | 0/8 |
| **shipped `…P4_10Switches_4Hosts.json`** | 16 960 | **0/20** |
| **shipped `…P4_10Switches_128Hosts.json`** | 138 820 | 0/8 |

`01_`, `02_`, `raw/*/run*.out`. **0 wins in 44 starts on files >= 7.8 KB.** The 10 WON verdicts at
310/587 B are the positive control that gives the instrument its power. `All-bmv2 topology` was
logged in **all 60** runs, so the identical predicate answers TRUE moments later on the load thread
-- the loss is timing, not topology.

Confirmed on the **live** fabric too (`05_`): 0 `GET /p4/switch_state` in 951 proxy log lines, 0
warnings, re-counted 30 s later, still 0, while `/v1.0/topology/*` polls do appear.

**So: "always loses" is the right sentence for any real fabric, and the fix must be an ordering or
synchronisation change, not a performance tweak.** Making the file smaller is not a fix -- it moves a
coin flip, and at 587 bytes it still lost 3 times in 8.

### Lead D -- is the lost power-off a poll overwriting a command? **SETTLED: yes, and the phase dependence is measured.**

`TopologyAndFlowMonitor.cpp:768-772` writes `isUp = true; isEnabled = true` for **every** switch the
proxy still lists, unconditionally, once per poll -- and there is **no else-branch that ever writes
`isUp = false`**, which is why a resurrection is permanent. Poll period: 5 s for the first 90 s
(`kConvergingFor`), then **30 s** (`:2506-2508`); the fetch triple spans 0.42 s (`06_`).

| arm | recipe | lost |
|---|---|---|
| **phase A** | fire the power-off ~1.5 s **before** the next poll | **8 / 14** |
| **phase B** | fire it ~2 s **after** a poll (next poll ~28 s away) | **0 / 4** |

`08_`, `09_`, `11_`. In **every** lost trial the `is_up` 0->1 transition is at **t_off + 2.31 s** --
the poll that reached the proxy at t_off+1.86 s being applied 0.45 s later. Round 2's single observed
re-up at 3.08 s is the same event.

The residual inside phase A is the proxy's own drop delay, and it too is measured (`10_`, `11_`), by
sampling `/v1.0/topology/switches` at 10 Hz:

| proxy drop delay | 0.00 s | 1.85 s | 1.95 s | 2.76 s | 2.88 s | 2.88 s |
|---|---|---|---|---|---|---|
| outcome | KEPT | KEPT | LOST | LOST | LOST | LOST |

The cut sits exactly at the kernel poll's arrival (~1.85 s). "Was the dpid still listed when the
kernel's poll arrived" predicts the outcome in **5/6** trials, the one miss being 0.10 s off the
boundary. `07_` measured D = 3.06 s independently, by killing a switch **out of band** with no kernel
command involved at all.

**Operator-facing rate:** ~D/30 once converged, ~D/5 during the first 90 s. Round 2's 2-in-9 is
consistent with a mix of the two regimes.

### Lead E -- what else blocks behind `routing_lock`? **SETTLED, and the answer is: nothing.**

Held hostage at `ttl 300`, exactly as a wedged Energy-Saving-App holds it (`http.cpp:425`), and never
released. All 10 kernel endpoints and both `ndt` subcommands returned **the same status and the same
latency as the control sweep** taken minutes earlier in the same script (`12_`): `install_flow_entry`
200/0.001 s, `delete_flow_entry` 200/0.001 s, `set_switches_power_state` off 0.237 s and on 1.474 s
(**both did real work**), `get_graph_data`, `get_path_switch_count`, `get_average_link_usage`,
`ndt status --check` rc=0, `ndt check` rc=0 in 8.1 s. **Nothing hung, nothing timed out, nothing was
refused.**

The lock was genuinely held throughout -- a competing `acquire_lock` returned **423**
`retry_after_s 299` at t+0, +15, +30, +45, +60, +75 and +90 s -- so this is not a null experiment.
`LockManager` is consumed by no routing, power, topology or flow path (only `main.cpp:392`, the three
`HttpSession` lock endpoints and `ControllerAndOtherEventHandler`), and the **Energy-Saving-App is the
lock's only client anywhere in the deployment** (`grep -rn acquire_lock` over the kernel repo,
`/home/adam/Energy-Saving-App` and `/home/adam/Simulation-Platform-Manager`).

**Consequence for triage: round 2's A3 is a single-app liveness bug, not a system-wide concurrency
hazard.** A wedged Energy app stops the Energy app and nothing else. The other half of the same fact
is that route installs, flow deletes and power commands are serialised by nothing at all.

---

## 1. Confirmed defects that are new this round

**C2. The kernel's sockets outlive the kernel.** HIGH. `03_` A and D.
Every `popen`'d `sh`/`curl` child inherits the listening fds, so after the kernel pid is provably
gone `:8000` (TCP) and `:6343` (UDP) stay bound for **2.01-2.22 s**. `ss` shows one socket with users
`ndtwin_kernel fd=8` + `curl fd=8` + `sh fd=8`; after SIGKILL only the curl/sh users remain. Observed
in **48/48** runs of step 02 plus a dedicated trial for each protocol. The width is set by curl's own
bounds (`--connect-timeout 2` on the topology poll; other call sites carry `--max-time 8`).

**C3. A kernel restart inside that window fails 6/6, and the message names a culprit that does not
exist.** HIGH. `03_` B, with `03_` C as the negative control.
The blocker is UDP `:6343`; the kernel prints *"Another NDTwin kernel is almost certainly still
running and holding it"* and exits 1. There was no other kernel -- the holder was the previous
kernel's own orphaned `curl`/`sh`. Refusing to run without telemetry is right; the diagnosis sends an
operator hunting a phantom process. **Control: the identical sequence with a 3.0 s gap started 3/3
and answered `200`.** This is also the natural trigger for round 1's D1 (a failed bring-up is not
rolled back).

**C4. No cleanup path checks `:6343`.** MEDIUM. `03_` D.
`grep -c 6343 tools/test_workflow/ndt` = **0**, `stack.sh` = **0**; the sweep is
`ndt:1112 for p in 8000 8080 8081`. The port that actually blocks a restart is one no tool looks at
-- the same shape as round 1's D8 for `:6653`/`:6633`.

**V1. The viz process chain, captured -- COMMON-BRIEF section 15's blocked fact.** `14_`.
It is **3 processes, not 4**:
```
pid 1320231  comm=network_traffic   /bin/bash ./network_traffic_visualizer.sh
 └ pid 1320234 comm=java  (214 MB)  …/java -classpath …/maven-wrapper.jar
                                     -Dmaven.multiModuleProjectDirectory=/home/adam/Network-Traffic-Visualizer
                                     org.apache.maven.wrapper.MavenWrapperMain javafx:run
    └ pid 1320294 comm=java (318 MB) …/java --module-path …/Network-Traffic-Visualizer/target/classes:…
                                     --add-modules org.example.ndtanimation
                                     --module org.example.ndtanimation/org.example.demo2.NetworkTopologyApp
```
Full argv of all three is in the log. Section 15's structural claim is confirmed: the launcher name
appears in **0** of the two JVMs' argv and `comm` is `java` for both, so neither a cmdline-name nor a
`comm` check can see them. **The discriminator a fix can key on is the directory string
`Network-Traffic-Visualizer`: 2 occurrences in the maven JVM's argv, 1 in the app JVM's, 0 in the
launcher's.**

**V2. `ndt apps stop viz` reports success and leaves 531 MB of JVM running; `ndt apps orphans` then
says there are no orphans.** HIGH. `14_`.
`ok viz stopped (was: running)`, `ndt apps` shows viz as `-`, both JVMs alive and re-parented, and
`ndt apps orphans` answers `ok no untracked app processes` -- the same answer it gives when there are
genuinely none, i.e. **zero discriminative power for this app**. The stop path also leaks
`ndt: line 1687: /proc/1320231/cmdline: No such file or directory` -- it reads the cmdline of the pid
it has just killed. I killed both orphans myself by exact pid; SIGTERM sufficed.

## 2. Existing findings this round sharpened

**Round 2's D16b is real but time-bounded, and the bound is 15 s.** `08_`/`09_` vs `11_`.
`P4PowerStrategy.hpp:45 kPostPowerOffDistrustWindow{15}`. Recovering a lost-power-off switch **within**
the window works -- 14/14 `action=on` calls took ~1.47 s and opened `:3005N`. **After** it,
`powerOn:73` early-returns on the resurrected `isUp`: **4/4** calls on lost switches returned
`200 Success` in **~1 ms** and started nothing, needing out-of-band `sudo ndtwin-p4-power on`. So the
brick is not unconditional, and there is an operator workaround: retry inside 15 s.

**`ndt down`'s own verify is not synchronised with the sweep it verifies.** `15_`.
It printed `XX bmv2 switches: 5 still running` and `not clean`; 20 s later `ps -eo comm=` counted
**0** bmv2, 0 kernels, 0 java, and every port free. Same shape as round 2's setsid-exit-code lesson,
one block over. The fabric was gone; the tool's verdict was a false negative.

## 3. Refuted -- doors closed, worth as much

- **"Two concurrent writers to the same flow match lose an update."** REFUTED by its own control
  (`13_`). Concurrent `install_flow_entry` for the same match with OUTPUT:1 and OUTPUT:2 left one
  entry on the switch (`0a000063/32 -> ipv4_forward - 00, 02`, read from bmv2's own thrift CLI on
  9091, never from the API that wrote it) while the twin counted **both** `succeeded` -- which looked
  like a lost update. **The sequential control does exactly the same**: install OUTPUT:1 -> switch
  shows `00, 01`, succeeded 8; install OUTPUT:2 -> `00, 02`, succeeded 9. Last-writer-wins is the
  semantic, not a race. What remains is milder and is not a concurrency defect: a replace is
  indistinguishable from an add in both the response body and the dispatch counters.
- **"A wedged Energy app is a system-wide concurrency hazard."** REFUTED -- see Lead E.
- **"The `:909x` listener surviving teardown is a leaked bmv2 thrift port."** REFUTED (`15_`): it is
  `:9090`, held by an unrelated `python3` (pid 78285) started at 12:37 the previous day. bmv2's own
  thrift ports are 9091-9100 and all ten are free.
- **My own instrument was wrong once and it is recorded, not deleted** (`10_`, `11_`): `wait_for_poll`
  compared `len(deque(maxlen=50))` against a snapshot, so once the deque filled it never reported
  another poll -- it cost step 10 four of its five trials ("no poll seen" x4). The kernel was fine.
  Fixed with a monotonic counter and re-run as `11_`.
- **`ORPHANS_RC=0` in `14_` is `head`'s exit code, not `ndt`'s** -- the pipeline-tail mistake round 1
  warned about (H-21). V2 rests on the printed text, not on that rc.

## 4. Not done, and why

| id | why |
|---|---|
| Hunt item 2 (signal the kernel at 0.5 / 2 / 10 s into startup) | Time. Lead C's 60 restarts consumed the restart budget and answered a bigger question. B-5's SIGINT abort is known and owned (COMMON-BRIEF section 14). |
| Hunt item 3, the pid-recycling half | `.test_run/pids/kernel.child.pid` = 1286422 (the real kernel) and `kernel.pid` = 1286418 (supervise.sh) were both correct all round, so the premise did not arise. |
| Hunt item 5 (route churn under ping, black-holing in the gap) | Round 2's `11_`/`12_` already measured the 14-19 s black hole on the power path; a rule-churn variant would characterise, not discover. |
| OVS-plane arms of C2/C3/D1 | This round was P4 by design. C1-C4 are plane-independent (they are the kernel's own sockets and startup), but were measured on P4 + the fabric-free harness only. |

## 5. For a human to decide

1. **Lead C's fix is an ordering change, not a tuning one.** At 310 bytes the race still lost 3 times
   in 8, so no amount of making the load faster fixes it. `refreshDataPlaneKind()` needs to run after
   the load completes (or be recomputed rather than cached once).
2. **Lead D and Lead C are the same fix.** With liveness actually running, a poll-resurrected switch
   would be corrected within a second; today `isUp = true` is written by the poll and by nothing else,
   and never written false. Separately: the poll loop should write `isUp = false` for a switch the
   proxy has dropped, or stop writing `isUp` at all.
3. **A3's priority should drop.** It wedges the Energy app; it wedges nothing else, and the lock it
   holds is consulted by no code path in the kernel.
4. **`routing_lock` protects nothing.** Either wire it into the routing/power handlers or stop
   offering it -- a lock with one client and no enforcement is a claim the system does not honour.
5. **V1 unblocks the viz fix**; the string to key on is `Network-Traffic-Visualizer`.

## 6. Lab state at end of round

`15_teardown.log`. Fabric down and verified through channels other than the tool's claim: the three
pids captured before teardown (kernel 1286422, proxy 1286210, bmv2 1285832) are all gone by `ps` on
the exact pid; **0** bmv2, **0** `ndtwin_kernel`, **0** `java` by `ps -eo comm=` (never `pgrep -f`);
0 mininet namespaces; and 8000 / 8080 / 8081 / 9000 / **6653** / **6633** / **6343** / 3005x /
9091-9100 all free. 2.8 GB free, 7.9 GB available.

**Tracked files:** exactly one was changed, and not by hand -- `ndt up p4 4` rewrote
`p4_proxy/mininet/host_count_override` 128 -> 4. Restored to 128 by explicit single-file path
(`git checkout -- p4_proxy/mininet/host_count_override`), never a directory pathspec; `git status`
for that path is now empty. Everything else in `git status` belongs to other sessions. This round's
own files are all untracked, under `doc/audit/2026-09-03_night-rounds/round3-restart-concurrency/`
(16 numbered logs, `raw/`, `topo/`, FINDINGS.md, SUMMARY.md). **Nothing committed, nothing pushed.**
Claim `auditor` **kept**, as instructed.
