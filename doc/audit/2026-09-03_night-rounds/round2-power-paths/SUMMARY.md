# Round 2 (night) -- powering switches on and off, and what path recomputation does about it. SUMMARY.

[Co-developed with claude code -- Adam]

**Binary of record: `a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06`**
(`sha256sum build/bin/ndtwin_kernel`, verified at 00:47:34 before anything ran -- `00_binary_and_env.log`).
This is the CHECKPOINT binary the coordinator restored at the round boundary, **not** the `ae8b752f`
round 1 measured. Repo HEAD at round start `6157d02a` ("Night round 1: the OVS plane, closed out");
the binary predates it. Nothing under `power_management/` was uncommitted at the time (re-checked 00:49).

**Plane: P4 / bmv2, 10 switches, 4 hosts (`ndt up p4 4`).** Chosen deliberately: round 1's D4 showed
`ovs4` has no telemetry at all, so it cannot separate "the app had no input" from "the app decided
not to act". The P4 plane can, and does (C0 below).

🔴 **MININET caveat on every line below.** "Power" here is a graph flag plus a `SIGTERM` to a
`simple_switch_grpc` process. **No wattage was measured anywhere in this round.** Every energy figure
quoted is a model output.

---

## 0. The two assigned leads, settled

### Lead A -- the Energy app did nothing on ovs4. **SETTLED. The input-starvation hypothesis is REFUTED.**

The direction was the question, and the code answers it: `energy_saving_app.cpp:926` is
`if (*avgLinkUtilization <= LOW_WATER_MARK)` with `LOW_WATER_MARK 0.40` (`settings.hpp:7`), so
**0.0 utilisation satisfies the condition and fires the power-DOWN branch.** Zero input means "power
it all off", not "cannot decide".

Live on P4 (`04_`), with the app's own log captured -- the instrument round 1 said it needed and could
not reach -- the app read `avgLinkUtilization 0`, `0`, `0.079` for groups s9/s7/s5, called
`easy_disable_switch` for all three, passed its own connectivity check (`Checking Switch N: true`) and
**sent three power-off simulation cases**. It decided, three times.

The real blocker is downstream: **every case is rejected 502 because the Simulation-Platform-Manager
is not running.** Round 1's `25_apps_energy.sh` starts only `energy`, never `sim`, so `ovs4` was under
this same gate. Proved by construction in `15_`: with the simulator up **first**, a fresh Energy app
powered off s7, then s9, then s5 in about two minutes (10 -> 7 bmv2 processes).

And there is a defect underneath, which is why round 1 saw four quiet cycles rather than one
(**A3, HIGH**): *one rejected case wedges the app permanently.* See §1.

### Lead B -- A-8 compares a bit with itself. **SETTLED: CONFIRMED, and the reality is worse.**

The hypothesis holds structurally. `spec.py:433` computes
`unexplained_down = [n for n in down if n['dpid'] not in power.off_dpids]`, where `down` comes from
`is_up` in `/ndt/get_graph_data` and `off_dpids` from `/ndt/get_switches_power_state`, and
`queryMininet:305` returns `OFF` exactly when `isUp == false`. The only runtime writer of
`isUp = false` on a **switch** vertex is `setVertexDown`, whose callers are all power paths
(`P4PowerStrategy:205`, `OVSPowerStrategy:541`, `DeviceConfigurationAndPowerManager:697/744/772/1477`);
`TopologyAndFlowMonitor.cpp:1313` is guarded to HOSTs and `:243` is the initial load. So the two sets
are the same bit and `unexplained_down` is provably always empty.

The discrimination test then showed the failure is worse than that (`09_`). Killing s9 by its exact
manifest pid with no power-off commanded produced **no reaction at all**: 260 samples over 270 s plus
the 2m34s before them -- about 7.5 minutes -- of `is_up=True, is_enabled=True, down_reason=none` and
`/ndt/get_switches_power_state -> "ON"`, with `ps` showing the pid gone and `ss` showing :30059 closed.
The A-8 check printed nothing about it, `power : all switches powered on`, and
`get_switches_power_state` **PASSED**. The case that should have made the check red never even enters
`down`. Only the *edge* invariant noticed (`6 edge(s) down/disabled`), and two of s9's eight edges were
laundered into the "accounted for" bucket for touching a legitimately-off s7.

---

## 1. Confirmed defects, with recipes

**D15. On the P4 plane the twin has no switch-liveness detection at all -- a startup race silently
disables it for the whole process lifetime.** HIGH. `09_`. **This is the root of most of what follows.**
The bmv2 liveness fetch is gated on `m_dataPlaneIsBmv2` (`DeviceConfigurationAndPowerManager.cpp:675`),
which `refreshDataPlaneKind()` computes **once** in `start()` (:124) and caches. This run's kernel.log:

```
00:48:22.689  TopologyAndFlowMonitor.cpp:211 loadStaticTopologyFromFile] Load Static Topology File
00:48:22.690  DeviceConfigurationAndPowerManager.cpp:121 start] ...Starts Up      <- refreshDataPlaneKind() here
00:48:22.692  TopologyAndFlowMonitor.cpp:145 configureTopologyApiUrls] All-bmv2 topology: polling ...
```

The identical all-bmv2 predicate answered **TRUE 2 ms after** `refreshDataPlaneKind()` answered FALSE,
because `m_dpidToSwitchKind` is filled inside `loadStaticTopologyFromFile` (`TopologyAndFlowMonitor.cpp:309`)
on another thread. The comment at :122 asserts the opposite ("the switch-kind index is populated by now").
*Evidence it never ran:* **0** kernel requests to `/p4/switch_state` in the proxy access log for the whole
fabric life (the only 2 are my own curls), against 154 `/v1.0/...` and 94 `/stats/flow/<n>` per switch in
the same window, and **0** `cannot read bmv2 liveness` warnings, so it never tried and failed.
`p4LivenessFor` therefore always receives `nullopt` -> `Unknown` -> the graph is never written.
*The proxy had the right answer the whole time*: `probe_ok:false, probe_age_s:1.756,
last_lldp_age_s:259.4, stream_alive:false`, which `p4LivenessFor`'s own policy maps unambiguously to Down.
*Not one unlucky race:* four proxy logs over several hours and multiple kernel runs show 2/4/0/1 requests
-- never the ~1/s a live poll makes.
*Recipe:* `ndt up p4 4`; `grep -c 'GET /p4/switch_state' .test_run/logs/p4_proxy.log`.

**B2/B3. `/ndt/get_switches_power_state` is a record of commands the kernel issued, not a measurement
of the fabric -- and it reports dead switches as "ON".** HIGH. `09_`. The control: two switches, both
processes provably gone, differing only in whether the kernel was told.

| | dpid 7 (commanded off) | dpid 9 (died uncommanded) |
|---|---|---|
| bmv2 process | gone | gone |
| gRPC port | closed (30057) | closed (30059) |
| graph `is_up` | **False** | **True** |
| `down_reason` | none | none |
| `get_switches_power_state` | **OFF** | **ON** |
| A-8 `inv_all_switches_up` | "accounted for" | says nothing |

*Aside:* the "accounted for" text asserts *"a powered-down switch is the Energy-Saving-App doing its
job"* -- an attribution it cannot make. No Energy app was running; I issued that POST by hand.

**A3. One rejected simulation case wedges the Energy-Saving-App permanently, and it squats the kernel's
`routing_lock` while wedged.** HIGH. `07_`, `04_`, `06_`. `send_case` is `void`
(`energy_saving_app.cpp:472`): the 502 is logged at :530 and discarded, and `sentCase = true` is set
unconditionally at :622, so the only recovery branch -- `if (!sentCase) { canSendNextSimulation = true;
release_lock(); }` at :627 -- is skipped. The other route back (:366) needs a *completed* simulation.
*Live:* at 00:59:11 the lock TTL expired, the app re-acquired it (`Code 200 / acquire_lock succeeded`)
and immediately logged `:883 There is switch powering on/off, skip...`, then held the lock without
releasing it. Livelock, not deadlock. **Not self-healing once the simulator arrives** -- 3 cases stuck
in the map against 0 completions and no new case can be prepared (confirmed: 240 s with sim running,
0 power-offs, `06_`). This is what round 1 saw on `ovs4`: cycle 1 wedges, cycles 2-4 skip.

**D16 + D18. Both directions of the power API early-return `Success` on the unreliable `isUp` flag,
and can report success while doing nothing.** HIGH. `10_`, `13_`.
- *powerOn* (`P4PowerStrategy.cpp:176`): `action=on` on the dead s9 returned `200 Success` in
  **0.000821 s** and started nothing (8 procs before and after, :30059 closed, manifest pid `null`).
  Control: the same endpoint on s7, which the twin knew was off, took **1.480 s** and moved 8 -> 9 procs.
- *powerOff* (`:180`): in `13_` trial 2 the twin wrongly held s5 at `is_up=0` while its process ran;
  `action=off` returned `Success` and killed nothing -- the trial ended with 9 procs and :30055 **OPEN**.

**D17. A commanded power-off is sometimes LOST: the process dies, the API says Success, the twin goes
on reporting the switch powered ON.** HIGH. `12_`, `13_`. **2 of 9 commanded power-offs tonight.**
Trial 1 of `13_` caught the transition: s6 `is_up` went 1 -> **0** at t=1788369874.19 and back to
**1** at t=1788369877.27 -- **3.08 s later, with the process dead throughout**. So `setVertexDown`
landed and was then overwritten, most plausibly by the topology-discovery writer
`TopologyAndFlowMonitor.cpp:768` (`isUp = true` for every switch the proxy still lists), and by D15
nothing ever corrects it.

**D16b. D17 and D16 compose into a brick.** HIGH. `13_`. After D17 lost s6's power-off, `action=on`
for s6 returned `200 Success` in **0.001115 s** and started nothing, while the identical call for s5
seconds later took **1.471 s** and worked. **One `action=off` call can leave a switch dead and
unrecoverable through the API, with every subsequent call reporting Success.** Only the out-of-band
`sudo ndtwin-p4-power on s6` + proxy `readopt` recovered it.

**D12. The kernel reports a connection-refused as a 30-second timeout.** MEDIUM. `05_`.
`/ndt/received_a_simulation_case` returns 502 `"no response from the simulator server at
http://127.0.0.1:9000/submit within 30s"` in **6-9 ms**, 5/5 calls, with nothing listening on :9000.
`SimulationRequestManager.cpp:200-204` takes this branch on `curl.httpStatus == 0`, which covers
refused / DNS-failed / timed-out alike, and hard-codes the timeout wording; curl's own exit status
(7 vs 28) is in `outcome.status` and is discarded. It sends a reader hunting a slow simulator when
there is no simulator -- and this is the exact message an operator meets first, because it is what
the Energy app dies on.

**D14. `/ndt/get_power_report` is a pure function of dpid and nothing says so.** MEDIUM. `08_`.
All 10 values reproduce **exactly** from `syntheticPowerMilliwattsFor` (`:545`, splitmix64 of the
dpid) reimplemented independently in Python. Rows carry only `dpid` and `power_consumed` -- no
`source` field. F-1 gave cpu/memory/temperature a -1 sentinel; power was not included. Any
"we saved N% power" figure is arithmetic over vertices marked down -- and by B3 that marking is a
record of commands.

**P3. With both paths off, the twin says "no path" and the switch keeps a route pointing into the
hole.** MEDIUM. `12_`. s5 and s6 both off: `/ndt/get_path_switch_count` for 10.0.0.1->10.0.0.2 returns
`{"message":"Path not found for the given IPs.","status":"error"}` -- honest -- while **s1's own
`ipv4_lpm` still forwards `10.0.0.2` out port 2, towards the powered-off s6**, and nothing withdraws
or repairs it. Ping: 0 replies for the remaining 62 s.

**D19.** The P4 proxy answers **HTTP 200 with `{"status":"error","message":"Failed to add route"}`**.
LOW. `14_`. The kernel handles it correctly and says so explicitly, so nothing is lost here -- but a
200 carrying an error is a trap for any other client.

**D13.** `ndt apps start energy` prints `XX unknown app: start`, starts energy anyway, exits **0**.
LOW. `04_`.

**D20.** The Energy app's `release_lock` returns 412 `"Lock 'routing_lock' is not held"` at the end of
a cycle. LOW, SUSPECTED (noted from its log, not chased). `15_`.

---

## 2. Measurements (not defects)

**P1/P2. Powering off a switch that is carrying traffic: RE-ROUTED, after a black hole of 14-19 s.**
`11_`, `12_`. h1->h2 at 10 Hz ICMP across s1-s5-s2, `set_switches_power_state(s5, off)` at t_off:

| run | last reply before | first reply after | black hole | packets lost |
|---|---|---|---|---|
| `11_` | t_off - 0.012 s | t_off + 14.131 s | **14.14 s** | 135 |
| `12_` | t_off - 0.019 s | t_off + 18.491 s | **18.51 s** | 177 |

One contiguous gap each; clean traffic before and after. **Not a stale cache**: switch-side ground
truth from bmv2's own CLI on s1's thrift port (never the API that wrote the route) shows
`10.0.0.2 -> port 2` (towards s6) while s5 is off, and back to `port 1` (towards s5) after s5 is
powered on. Recovery direction: power-on 1.481 s, graph re-converged 40/40 in 12 s.

**C0. The P4 plane has a working link-utilisation input** -- avg 0.0 idle -> 0.335 under iperf3,
8/40 edges non-zero, peak 60.44%. `03_`. Round 1's D4 is `ovs4`-only. *(Per-flow rates seen here carry
the COMMON-BRIEF §11 bias; the per-link figures the energy decision uses do not.)*

**T-15 PASS -- first real run of `tools/p4_power_helper.py`** (hunt item 6). `09_`.
`sudo -n ndtwin-p4-power off s9` -> `{"status":"stopped","name":"s9","pid":1213762}` in 0.24 s, and it
did the thing: `ps` on that exact pid finds nothing, `ss` shows :30059 closed, procs 10 -> 9, manifest
`s9.pid` -> `null`. Verified through channels other than its own exit code. `on` works too (0.24 s).

---

## 3. Refuted -- doors closed, worth as much

- **Lead A's input-starvation hypothesis: REFUTED.** Zero utilisation is on the *acting* side of the
  threshold. See §0.
- **Hunt item 5 -- "a rejected request may still have had an effect": REFUTED, and the kernel comes
  out well.** `14_`. Installing a flow entry to a powered-OFF switch returns the same
  `200 {"accepted":1,"status":"queued"}` as to a live one, but that is an *async accept*, and
  `/ndt/get_flow_dispatch_status` -- which the response body names -- keeps the promise:
  `dispatched 3, succeeded 1, failed 2`, both failures listed with dpid, match, op, timestamp and
  reason. The positive control (install to a live s5) really landed on the switch (`0a636363` in its
  own table). Same result for an install fired concurrently with a power-off. The twin's table view
  matches the switch's afterwards. Neither silently lost nor secretly applied.
- **My own first read of P4 per-edge utilisation was wrong** (`03_`): I filtered on
  `link_bandwidth_utilization`, a key that does not exist, and printed "0 non-zero edges". That was
  "we failed to ask", not "the twin said 0". Corrected in place; the real key is
  `link_bandwidth_utilization_percent`.
- **My own teardown verification was wrong before it was right** (`16_`). I read `DOWN_RC=0` as
  `ndt down`'s exit code and checked 5 s later, and the log briefly read "ndt down exited 0 leaving
  7 bmv2 switches and the topo session up". It is **setsid's** exit code: setsid forks to become a
  session leader and returns immediately unless `--wait` is given. Phase [2/3] was still working.
  Re-verified after it finished -- 0 bmv2 processes, no lab session, 0 mininet namespaces, every port
  free. **`ndt down` is not impeached.** Same shape as the COMMON-BRIEF's "sudo forks rather than
  execs" warning, one tool over.
- **My first two parsers for the twin's flow-table shape were wrong** (`14_` E/F) -- a KeyError and an
  AttributeError, both annotated in place rather than deleted. The third read the shape first.

---

## 4. Not done, and why

| id | why |
|---|---|
| Hunt item 4 (power-cycle repeatedly, faster each time) | Time. `13_` did 3 cycles at a fixed 8 s spacing and already found D17/D18 at that rate; a rate sweep would characterise the race rather than discover it. |
| Hunt item 7 (recompute under churn: manual route change vs a power event in flight) | Time. `14_` covers the adjacent case (install vs power-off) and it came out clean. |
| `viz` process chain (COMMON-BRIEF §15) | **`viz` was never started this round**, so there was nothing to capture. Free RAM sat at 2.3-3.9 GB against the 3 GB floor and round 1 had already deferred the viz JVM for the same reason. Still blocked, still worth someone's ten seconds. |
| OVS-plane arms of D15/D17 | This round was P4 by design (see the header). D15 is stated for the P4 plane only; `ovsLivenessFor` is a different branch and was not exercised. |

---

## 5. For a human to decide

1. **D15 is the one to fix first.** It is a two-line ordering problem
   (`refreshDataPlaneKind()` runs before the switch-kind index exists, and caches the answer), and it
   is what makes B2, B3, D16, D16b, D17 and D18 unrecoverable rather than merely transient. With
   liveness actually running, a lost power-off would self-correct within a second or two.
2. **The `isUp` flag carries two incompatible meanings** -- "an operator commanded this off" and
   "this switch is reachable" -- and every power decision, the A-8 invariant, and
   `get_switches_power_state` all read it. Separating commanded-state from observed-liveness is a
   design decision, not a patch.
3. **A-8's "accounted for" message names the Energy-Saving-App as the cause.** It cannot know that;
   any `set_switches_power_state` caller produces the same state. Worth rewording whoever fixes it.
4. **The Energy app cannot power anything off without the Simulation-Platform-Manager**, and nothing
   says so -- not `ndt apps`, not the app's startup, not `25_apps_energy.sh`. Any future energy round
   that starts `energy` without `sim` will measure nothing and, because of A3, will also leave the
   app wedged holding `routing_lock`.

---

## 6. Lab state at end of round

Fabric torn down and verified through independent channels (`16_teardown.log`): the two pids captured
before teardown are gone, **0** bmv2 processes (`ps -eo comm=`, never `pgrep -f`), no lab tmux session,
**0** mininet namespaces, and 8000 / 8080 / 8081 / 6653 / 6633 / 6343 / 9000 / 3005x / 909x all free.
No apps running. 3.9 GB free. Claim `auditor` **kept**, as instructed -- 354 min left.

**Tracked files:** exactly one was changed, and not by hand -- `ndt up p4 4` rewrites
`p4_proxy/mininet/host_count_override` as a designed side effect and announces it (128 -> 4, `01_`).
Restored to its round-start value of 128 by explicit single-file path
(`git checkout -- p4_proxy/mininet/host_count_override`), never a directory pathspec. Nothing else
tracked was touched; everything else in `git status` belongs to other sessions. **Nothing committed,
nothing pushed.**
