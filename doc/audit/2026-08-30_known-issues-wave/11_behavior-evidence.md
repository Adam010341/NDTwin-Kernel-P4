# Bundle 2 — the three "demo behaviour" defects: A-1, A-4e, A-2

Opened 2026-08-30 on Adam's selection of bundle 2. Branch `fix-demo-behavior`, based on
`1208d22` ("Auditor acceptance: a hand-applied mutation, and what '13 OK' does and does not
prove").

Follows the honesty pattern of `doc/audit/2026-08-28_chaos-harness/08_t7b-evidence.md` §0-bis:
the status block says what was and was not evidence **at the time it was written**, and is not
rewritten later — §0 is superseded by appending, not by editing.

**A-1 supersession, recorded because it reverses a standing ruling.** `doc/KNOWN-ISSUES.md` A-1
carried "報告前不改碼，用操作繞過（2026-08-19 裁定）". Adam re-ruled on 2026-08-30 by selecting
this bundle. The 08-19 ruling is superseded, not forgotten: the workaround it prescribed ("power
off, wait 15 seconds, power on") is the source of the constant this fix uses, and that lineage is
recorded in `P4PowerStrategy::kPostPowerOffDistrustWindow`'s comment rather than only here.

---

## 0. Status: **written, NOT compiled, NOT run**

🔴 **Nothing below has been built or executed.** A measurement window was live for the whole of
this work — lab claim `live-traffic-round`, running until roughly 01:24 — and the dispatch
instruction was explicit: no `git commit`, no compiling, no test runs, no processes beyond file
reads, greps and writes. This file was written under that constraint and every claim in it is
**read, not executed**, and must be quoted that way until §4 and §5 are filled in.

The three defects were each re-derived from the source before anything was designed; that part is
reading, and reading is what this repo's `claim-verb-decides-the-evidence` rule says a
"the mechanism is X" claim needs. It is **not** what a "the fix works" claim needs. No such claim
is made here.

### 0.0 What is verified, and by what

| Claim | Status | How |
|---|---|---|
| A-1's adjudicated mechanism matches today's code | **verified by reading** | `P4PowerStrategy.cpp` early return + `DeviceConfigurationAndPowerManager.cpp` `p4LivenessFor`/`pingWorker`, quoted in §1 |
| A-4e's adjudicated mechanism matches today's code | **verified by reading** | `HttpRoutingStrategyBase.cpp` delete vs modify, line numbers in KNOWN-ISSUES have **not** drifted |
| A-2's adjudicated mechanism matches today's code | **verified by reading** | `utils::execCommand` is a bare `popen`; the three curls carried no deadline |
| The code compiles | **NOT verified** | nothing was built |
| The new tests pass | **NOT verified** | nothing was run |
| The new tests can fail | **NOT verified** | §4 mutation gate is pre-registered, not executed |
| A-1 behaves this way on a live fabric | **NOT verified** | §5.1 recipe |
| Ryu's `ofctl_rest` serves `/stats/flowentry/modify_strict` | **NOT verified — BLOCKING, see §3.3** | Ryu is not vendored in this checkout |
| No sibling-repo caller breaks | **NOT verified** | those repos are absent from this machine (§3.4) |

### 0.1 The one thing that could make A-4e worse rather than better

`doc/2026-07-29_p4_status_and_test_guide.md:329` enumerates the routes this project believes
`ryu.app.ofctl_rest` serves as `POST /stats/flowentry/{add,modify,delete,delete_strict}`.
**`modify_strict` is not in that list.** `intelligent_router.py:856-876` uses
`OFPFC_MODIFY_STRICT` internally but never calls the REST route, so the checkout contains no
evidence either way.

If that list is complete rather than merely stale, this fix converts a modify that edits the wrong
rule into a modify that 404s — and because the flow path is asynchronous, the caller is told
`200 {"status":"queued"}` either way, so the regression would be **silent**. That is the same
failure direction the defect already has.

**§3.3 is therefore a blocking pre-merge check, not a nice-to-have.** It is one command and it
does not need the fix.

---

## 1. A-1 — power-off then power-on inside ~10s reports success and does nothing

### 1.1 The mechanism, re-derived

KNOWN-ISSUES A-1 adjudicates: `powerOff` marks the vertex down, the 1 Hz liveness worker flips it
back up, and `powerOn`'s first line then early-returns success. Confirmed against the source, and
the ~10 second window is a consequence of two constants rather than an observation that needs to
be taken on trust:

1. `P4PowerStrategy::powerOff` → helper `off` exits 0 only once the process is gone →
   `topoMonitor->setVertexDown(node)`.
2. Within one tick, `DeviceConfigurationAndPowerManager::pingWorker` (started at
   `DeviceConfigurationAndPowerManager.cpp:129` with `interval_sec = 1`) calls
   `fetchP4SwitchState()` once per tick and then `p4LivenessFor(dpid, …)` per switch.
3. `p4LivenessFor` returns **Up** on `probe_ok == true` alone
   (`DeviceConfigurationAndPowerManager.cpp:431-435`). The proxy's cached `probe_ok` is still
   `true` for up to its own probe period after the kill. The worker calls `setVertexUp(v)` — on a
   switch it has already been told is dead.
4. Once `probe_ok` goes false, the LLDP branch (`:456-468`) returns **Unknown** while
   `last_lldp_age_s <= kLldpFreshSeconds` (`= 12.0`,
   `DeviceConfigurationAndPowerManager.hpp:259`). The worker's `Unknown` case
   (`:743-748`) deliberately **does not touch the graph**, so the wrong `Up` from step 3 stands.
5. `powerOn`'s first line was `if (topoMonitor->getVertexIsUp(node)) return OpResult::success();`
   — 200, 0.01s, no command run.

So the window closes when the beacon ages out: at most 12s after the kill, plus one worker tick.
The measured ~10s and the prescribed 15s workaround both sit exactly where that arithmetic puts
them. **This is derivation, not confirmation** — `arithmetic-that-fits-is-not-the-mechanism`
applies, and what makes it more than arithmetic is that the entry's own live evidence
(`scratch/phase2/FINDINGS.md` E2) already showed the discriminating second call: the identical
POST, sent after the graph settled to `is_up=false`, took 1.27s and moved the process count 9→10.

Also confirmed, and load-bearing for the design: `tools/p4_power_helper.py` `cmd_off` sets
`entry["pid"] = None` on success, and `cmd_on` refuses only when the manifest pid is alive or the
gRPC port is listening. After a successful power-off **neither refusal applies**, so running the
helper inside the window really does start the switch. The fix is not asking the helper to do
something it will decline.

### 1.2 The design, and what was rejected

**Chosen:** `powerOn` keeps its early return, but the early return now requires two things —
the graph says up **and** this strategy did not itself confirm that switch stopped within
`kPostPowerOffDistrustWindow` (15s).

Rejected, with reasons, because each is the obvious first idea:

- **Delete the early return, always run the helper.** Breaks the documented invariant that an
  already-up power-on is a no-op success. `cmd_on` refuses a live pid, so every repeat
  desired-state request from the Energy-Saving-App would become a 500.
- **Ask the helper for the true state (a new `status` verb).** The helper is a *root-owned
  installed copy* at `/usr/local/sbin/ndtwin-p4-power`, pinned by a sudoers line. A `powerOn` that
  depends on a new verb fails outright on every machine that has not re-installed it — the fix
  would break the normal path on exactly the machines nobody remembered to update.
- **Ask the proxy instead of the graph.** The proxy's `probe_ok` is the *source of the lie*. In
  the window it says Up, then Unknown. Consulting it harder cannot help.
- **Trust the twin's own act instead.** The kernel issued the kill and the helper confirmed the
  process was gone. That is local, first-hand, and no stale cache can contradict it. This is what
  was implemented.

**Why the window is bounded rather than a latch cleared only by evidence.** Past 15s the graph is
the only source there is, and by then `p4LivenessFor` has had a Down verdict available for
several ticks. An unbounded latch would send the helper at a live process and collect
"refusing to start a second instance".

**Why the window closes on helper-on success rather than at the end of `powerOn`.** The window
asks one question — "is the process I killed still gone" — and helper-on exiting 0 answers it. If
it stayed open across the readopt (502) path, the next power-on would re-run the helper against
the process the previous call had just started, and a switch that needs a readopt would report a
500 naming the wrong step. The pipeline-less half-state is what step 2's failure message and its
named recovery are for.

### 1.3 Invariants each change preserves

| # | Invariant | Preserved because | Pinned by |
|---|---|---|---|
| I1 | A genuinely already-up switch runs **zero** commands and returns success | outside the window the guard is byte-for-byte the old condition | `PowerOnOnAnAlreadyUpSwitchRunsNothing` (pre-existing, unmodified) + `PowerOnTrustsTheGraphAgainOnceTheDistrustWindowHasPassed` |
| I2 | `powerOff` is unchanged except for one timestamp on the success path | `notePowerOff` is below the helper-failure return | `PowerOffFailureLeavesTheVertexUp`, `AFailedPowerOffDoesNotOpenTheDistrustWindow` |
| I3 | The vertex is marked up only when **both** helper and readopt succeed | neither return was moved | `PowerOnReadoptFailureIsA502AndDoesNotMarkUp` |
| I4 | No command ever name-matches a process (`pkill`/`killall`) | the new path runs the same two commands | `expectNoNameMatchingKills` in every scenario |
| I5 | A repeated power-on inside the window is still a no-op | window closes on helper-on success | `ASuccessfulPowerOnClosesTheWindowSoAnImmediateRepeatIsStillANoOp` |
| I6 | One switch's power-off does not make another switch's power-on act | the record is keyed by switch name | `TheDistrustWindowIsPerSwitchNotFabricWide` |

### 1.4 Residual, stated rather than hidden

Within 15s of a successful power-off, if something **outside the twin** starts that switch, the
next `powerOn` runs the helper, the helper answers "already appears to be running", and the call
returns 500 instead of the 200 it would have returned before. This is a real behaviour change in a
real (if exotic) case. It is accepted because the direction is loud-and-pessimistic rather than
silent-and-optimistic, and because the helper's own message names the situation precisely in the
kernel log. It is written here so that nobody has to rediscover it as a bug.

### 1.5 The OVS analogue — examined, and **not** changed

`OVSPowerStrategy::powerOn` has the same-shaped early return at `:73`. It is not touched, and the
entry's scoping to P4 is correct — but for a reason worth writing down, because "same shape"
invites someone to "fix" it symmetrically later:

`ovsLivenessFor` (`DeviceConfigurationAndPowerManager.cpp:344-357`) decides from the live output
of `ovs-vsctl list-br`, re-read every tick. `OVSPowerStrategy::powerOff` runs `del-br`, so the
bridge is absent from the very next `list-br` → **Down**, immediately. There is no cached
evidence to go stale, so there is no window. And the dangerous direction is unreachable: for the
worker to wrongly report the bridge up, `list-br` would have to still list it, which means `del-br`
failed, in which case `powerOff` returned 500 and never marked the vertex down in the first place.

**This is read-not-executed reasoning about a path with no live evidence collected tonight.** It
is a reason to leave OVS alone, not a certificate that OVS is correct.

---

## 2. A-4e — `modify_flow_entry` ignores `priority` and can edit another app's rule

### 2.1 The mechanism, re-derived

Confirmed verbatim, and the line numbers KNOWN-ISSUES cites have **not** drifted: the correct
delete is at `HttpRoutingStrategyBase.cpp:158-164` and the defective modify at `:195-201`. The
modify set `body["priority"]` and then posted the **non-strict** `/stats/flowentry/modify`, where
OpenFlow does not compare priority at all. The priority travelled the whole way and was ignored.

Corroboration found while reading, which strengthens the entry: `intelligent_router.py:856-876`
uses `OFPFC_MODIFY_STRICT` for the router's *own* internal modifies. The project already knew
which command identifies an entry; the REST caller was the one that did not.

### 2.2 Two findings that change the fix, both corrections to the entry

**(a) The `-1` sentinel does not exist on the modify side.** `HttpSession::makeModifyJob` defaults
an absent `priority` to **0**; only `makeDeleteJob` defaults to `-1`. So "just copy the delete
branch" produces a branch nothing reaches, plus a new hazard at `priority: 0`.

The tempting repair — change `makeModifyJob`'s default to `-1` — was **rejected**.
`FlowJob.hpp:70-72` records that `ad49347` deliberately aligned the flow-table cache with the
dispatcher on "absent means 0". De-aligning them again is a second defect, not a fix.

An omitted priority therefore still arrives as 0 and now takes the strict route, which is safe in
a way the old code was not: strict compares the caller's own match fields too, so `priority 0` with
a non-empty match hits the caller's entry or nothing. Non-strict hit anybody's. The change is an
improvement in **both** the explicit-priority and the omitted-priority case.

**(b) KNOWN-ISSUES says "P4 的 modify 走不同路徑". Only half true, and the false half is dangerous.**
`P4RoutingStrategy` does **not** override `modifyAnEntry` — both planes run this identical C++.
The divergence is server-side: the P4 proxy reads `priority` out of the body itself
(`proxy_agent/topology_manager.py` `modify_flow`, which uses it to identify the entry on the
ternary five-tuple table) and serves **no** `modify_strict` route.

So an unconditional switch to `modify_strict` would 404 every P4 modify, invisibly. Hence the
virtual `strictModifyPath()`: OVS gets `modify_strict`, P4 keeps `modify`, and the P4 override
carries the reason. The KNOWN-ISSUES entry has been corrected in place.

### 2.3 What was asked for and **not** built: the 400/412 decide-first path

The dispatch asked for T-7b's decide-first-act-second shape with 400/412 semantics. It is not
implemented, and that is a decision for Adam rather than an omission:

- **A 412 cannot reach the caller.** `/ndt/modify_flow_entry` answers `200 {"status":"queued"}`
  from `HttpSession::processFlowBatch` *before* the southbound request is made; the strategy's
  `OpResult` only ever reaches `Controller.cpp:53-63`'s log line. A refusal computed in the
  strategy would be invisible exactly where the defect is invisible.
- **Deciding first needs a read the twin cannot trust.** Checking "does this entry exist" means
  either a southbound read per modify (a new round trip inside a FlowDispatcher worker, on the
  path A-2 shows can wedge) or the cached flow table — which is a poll snapshot up to 8s stale, and
  refusing a legitimate modify on stale cache is a worse failure than the one being fixed.
- **A 400 for an omitted `priority`** *is* cheap and is the honest reading of "do not touch a
  different rule". It was **not** taken because `describeFlowEntryShapeProblem` currently accepts
  it, `FlowJob.hpp` documents it as optional, and the one known caller
  (Energy-Saving-App) is in a repo that is not on this machine and **discards the response**
  (`HttpSession.cpp:1010-1011` cites `energy_saving_app.cpp:225` and `:241`). Rejecting would
  silently stop its modifies. That trade is Adam's to make, not mine.

Recorded as an open question in §6, not silently dropped.

### 2.4 Invariants preserved

| # | Invariant | Pinned by |
|---|---|---|
| I7 | A modify naming a priority can only touch the entry with that match **and** that priority | `ModifyWithPriorityUsesTheStrictRouteSoItCanOnlyHitThatEntry` |
| I8 | Modify and delete agree on what a supplied priority means | `ModifyAndDeleteAgreeOnWhatAPriorityMeans` |
| I9 | A P4 modify keeps posting a route the proxy actually serves | `ModifyOnTheP4ProxyKeepsTheRouteTheProxyActuallyServes` |
| I10 | `-1` is a sentinel and never travels as a priority | `ModifyWithoutAPriorityStaysOnTheNonStrictRoute` |
| I11 | install and delete wire formats unchanged | the 12 pre-existing tests in `test_RoutingStrategies.cpp` |

---

## 3. A-2 — the topology poll can block forever with zero log

### 3.1 The mechanism, re-derived

`utils::execCommand` (`include/utils/Utils.hpp`) is a bare `popen()`/`fgets`/`pclose`. It has no
deadline, and the three topology GETs carried no `--max-time` either. `pclose`'s status is checked
only to write one line to `std::cerr` — not to spdlog — and the return value is the accumulated
stdout, so **"curl hung", "curl failed" and "the controller had nothing to say" are the same empty
string** to every caller.

The three `try/catch` blocks around the calls could only ever fire on `popen()` itself failing.
They cannot fire on the failure that happened.

The "zero log" half is a second, independent mechanism and it is worth separating: `run()`'s poll
loop logs only when `graphLivenessSummary()` **changes**. A poll that never returns never changes
it. So even a poll that returned instantly with an empty body would have been silent — bounding
the wait does not by itself make the failure visible, which is why the fix has two halves.

### 3.2 The design

- **A bounded variant, not a change to `execCommand`.** `execCommand` has 21 call sites, ten of
  them `snmpget`/`snmpwalk` on the TESTBED path with no bound of any kind. Putting a deadline
  inside the shared helper would change all of them. `Utils.hpp`'s own comment records a previous
  incident of exactly that shape. The bound goes on the command string, at the three call sites
  that need it, exactly as `buildFlowStatsCommand` / `buildSwitchStateCommand` /
  `buildRelayPowerCommand` already do in the sibling class.
- **`--connect-timeout 2` *and* `--max-time 5`.** Two flags because two failures: the connect
  bound is the one that mattered in `FlowLinkUsageCollector`, where a curl at a `localhost` that
  resolved to an unattended IPv6 loopback sat for **131 seconds** because the SYNs were dropped
  rather than refused — and these URLs are built from `AppConfig::RYU_IP_AND_PORT`, so that
  spelling is reachable here too. `--max-time` bounds a controller that accepts and then stalls,
  which is the Ryu wedge itself.
- **5 seconds.** Three sequential requests per pass; the poll runs every 5s while converging and
  every 30s after. A fully wedged pass therefore costs ~15s instead of the rest of the run. The
  nearest in-repo numbers are the 1 Hz liveness poll's `--max-time 3` and this exact wedge's
  `--connect-timeout 2 --max-time 10`.
- **`-sS`, not `-s`.** `-s` silences curl's own errors as well as its progress meter, which is
  half of why the wedge produced no output. `-S` restores the one-line diagnosis on stderr.
  `execCommand` captures stdout only, so it cannot corrupt the reply.
- **One log line, edge-triggered, per pass.** The run is counted per **pass**, not per endpoint,
  so a pass where two of three answer cannot report itself recovered while one is still silent.
  The message names the silent URL(s), the elapsed time, both bounds, what the twin will now show
  and why it may be wrong, and a one-line confirmation command — the same shape as
  `fetchOpenFlowTablesInternal`'s warning, and the same one-liner the KNOWN-ISSUES entry already
  recommends for the runbook. A matching recovery line closes the run.
- **Control flow deliberately unchanged.** All three are still fetched, then applied together;
  `updateSwitches`/`updateHosts`/`updateLinks` each already return early on an empty body. An
  earlier draft of this fix returned early on the first empty reply, which would have silently
  changed partial-update behaviour. That is a separate decision from bounding the wait, and it was
  backed out.

### 3.3 🔴 Blocking pre-merge check (A-4e, not A-2 — filed here because it is one command)

Ryu is not vendored in this checkout, so nothing here can confirm `ofctl_rest` serves
`modify_strict`, and `doc/2026-07-29_p4_status_and_test_guide.md:329` lists the routes **without**
it. Run against the installed Ryu, with a fabric up:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  http://localhost:8080/stats/flowentry/modify_strict \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"priority":100,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.254"},
       "actions":[{"type":"OUTPUT","port":1}]}'
```

`200` (or any non-404) ⇒ the route exists, the fix stands. **`404` ⇒ do not merge A-4e**: the fix
would convert "edits the wrong rule" into "edits nothing", equally silently, and the answer is
then the proxy-style alias route rather than the strict spelling. `10.0.0.254` is a probe address,
matching `spec.py`'s convention of not aiming flow writes at a real host.

### 3.4 What no test can reach, and what has to be checked live

Stated plainly, because `verify-the-purpose-not-the-mechanism` and the note already in
`tests/test_FlowStatsTimeout.cpp:181-186` both say an untestable seam must be recorded as a gap
rather than papered over.

- **`TopologyAndFlowMonitor` has no virtual methods at all**, and `execCommand` is a free `inline`
  function in a namespace — no vtable, no link seam. The new tests assert the **wire format** and
  nothing else. They cannot observe a timeout happening, the WARN firing, the WARN firing *once*,
  or the recovery line.
- **The cross-repo caller scan for A-4e is not verifiable here.** `components.env` names
  `Energy-Saving-App`, `Web-GUI`, `Traffic-Engineering-App` and four others under
  `$WORKSPACE_ROOT`; **none of those directories exist on this machine**. The in-repo map at
  `tools/contract_test/components.py:138-203` lists Energy-Saving-App as the one direct
  `modify_flow_entry` caller (`:147`) and Energy-Saving-App + Web-GUI as batch callers
  (`:149`, `:174`). That file is hand-maintained and its own header says so. Treat as a claim.
- **`tools/contract_test` cannot see this fix.** `spec.py:652-659` always sends `priority: 1`,
  expects `{status, accepted}`, and the endpoint answers `200 queued` regardless of the southbound
  outcome. Nothing in the spec predicts a break — which is an argument that it is safe, **not** a
  run, and not evidence that the fix works.

---

## 4. Mutation gate — PRE-REGISTERED, not executed

Registered **before** any of these were run, which is the only time registering them means
anything. Each row: apply the mutation by hand, rebuild, run; the named test **must** go red. If
one stays green the test is decoration and the fix is unverified.

Build and run (see §5.0 for the interpreter/build caveats):

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j"$(nproc)" --target test_routing_strategy
./build/tests/test_routing_strategy --gtest_filter='P4PowerStrategyTest.*:RoutingStrategyFixture.*:RequestDeadlines.*'
```

### A-1 — `src/ndt_core/power_management/P4PowerStrategy.cpp` / `.hpp`

| # | Mutation | Must go red |
|---|---|---|
| M1 | Restore the old guard: drop `&& !poweredOffWithinDistrustWindow(swName)` | `PowerOnActsWhenTheGraphSaysUpButThisStrategyJustStoppedTheSwitch` |
| M2 | Make the window unbounded: `poweredOffWithinDistrustWindow` returns `it != m_lastPowerOffAt.end()` | `PowerOnTrustsTheGraphAgainOnceTheDistrustWindowHasPassed` |
| M3 | Delete the `clearPowerOffRecord(swName)` call after helper-on | `ASuccessfulPowerOnClosesTheWindowSoAnImmediateRepeatIsStillANoOp` |
| M4 | Move `notePowerOff(swName)` above the helper-off failure return | `AFailedPowerOffDoesNotOpenTheDistrustWindow` |
| M5 | Replace the map with one process-wide timestamp (ignore `swName`) | `TheDistrustWindowIsPerSwitchNotFabricWide` |

**Control, and the point of it:** `PowerOnOnAnAlreadyUpSwitchRunsNothing` must stay **green**
under M1–M5 and under the unmutated fix. It is the invariant the fix is not allowed to buy its
result with. A run where it reddens means the fix broke the normal path, whatever else passed.

### A-4e — `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp`, `P4RoutingStrategy.hpp`

| # | Mutation | Must go red |
|---|---|---|
| M6 | Post the literal `"/stats/flowentry/modify"` instead of `strictModifyPath()` | `ModifyWithPriorityUsesTheStrictRouteSoItCanOnlyHitThatEntry` **and** `ModifyAndDeleteAgreeOnWhatAPriorityMeans` |
| M7 | Delete the `if (priority == -1)` branch (always strict) | `ModifyWithoutAPriorityStaysOnTheNonStrictRoute` |
| M8 | Delete `P4RoutingStrategy::strictModifyPath()` | `ModifyOnTheP4ProxyKeepsTheRouteTheProxyActuallyServes` |
| M9 | Set `body["priority"] = priority;` **above** the `-1` branch | `ModifyWithoutAPriorityStaysOnTheNonStrictRoute` (its no-priority assertion) |

M6 must redden **two** tests. If only one reddens, say which and why in §5 — the second is the
symmetry property and its independence from the route-name assertion is the reason it exists.

### A-2 — `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`

| # | Mutation | Must go red |
|---|---|---|
| M10 | Drop `--max-time` from `buildTopologyFetchCommand` | `TheTopologyPollIsBounded` |
| M11 | Drop `--connect-timeout` | `TheTopologyPollBoundsTheConnectAndNotJustTheTransfer` |
| M12 | Raise `kTopologyRequestTimeoutSeconds` to 15 | `TheWholeTopologyPassFitsInsideItsOwnPollInterval` |
| M13 | `-sS` → `-s` | `TheTopologyRequestKeepsCurlsOwnDiagnosisOnStderr` |

**Predicted NOT caught by any mutation above, and known in advance:** deleting the WARN block
entirely, deleting the recovery INFO, or making the failure counter per-endpoint instead of
per-pass. No unit test can see any of them (§3.4). They are covered only by §5.3.

---

## 5. Post-window live verification — recipes, none of them run

### 5.0 Before anything

- Re-read the lab claim first; `ndt status`'s `measuring` column is the source of truth for
  whether a run is live, not `pgrep`.
- `NDT_OWNER` must be set on every `ndt` command; `ndt up`/`ndt down` kill the shell that calls
  them (exit 144), so wrap in `setsid` and verify by the log's `up. ready`, not by return code.
- `ndt up` does **not** recompile `.p4`.
- Python tests need the venv interpreter, not conda's.
- Every run must name the binary it measured, by commit, not by mtime.

### 5.1 A-1 — the demo, exactly as a human would do it

The fix's whole claim is about a few-second gap, so the test is the gap.

```bash
# 🔴 CORRECTED 2026-08-31 after the live run (raw/drive_a1_power.sh): the original block here
# had three defects and, followed verbatim, could neither pass nor fail.
#   R1: it said :8081 -- /ndt/* is the KERNEL's :8000; :8081 is the proxy (verbatim run => 404).
#   R2: it said switch_ip= -- the kernel takes ip= (spec.py:773); with switch_ip= nothing is
#       ever powered off and every later assertion is vacuous.
#   R3: it counted with `pgrep -c simple_switch_grpc` -- 19 chars vs comm's 15-char cap, which
#       returns 0 on a live fabric always, so 0->0->0 reads as "back to baseline" for ANY
#       behaviour. Zero discriminating power; the instrument mimicked the pass condition.
SW=s1; IP=10.0.0.1   # whichever switch/IP the topology gives
ps -eo comm= | grep -c '^simple_switch'            # baseline process count (comm prefix, not pgrep)
curl -s -X POST "http://localhost:8000/ndt/set_switches_power_state?action=off&ip=$IP"
sleep 3                                            # inside the old window
time curl -s -X POST "http://localhost:8000/ndt/set_switches_power_state?action=on&ip=$IP"
ps -eo comm= | grep -c '^simple_switch'            # must be back to baseline
```

**Pass:** the power-on takes on the order of a second (not 0.01s), the process count returns to
baseline, and a ping through `$SW` recovers.
**Fail, in the way that matters:** 200 in ~0.01s with the count unchanged — the defect, still
there.

Then the control, which is the half that is easy to skip: repeat with `sleep 20`. It must still
work, and `curl` twice in a row inside 15s must return 200 both times having run the helper only
once (check the kernel log). That is I1 and I5 live.

Do **not** use `pkill -f`/`pgrep -f` to kill anything at any point.

### 5.2 A-4e — read the table back, do not trust the 200

The endpoint answers `200 queued` whatever happens, so the only real evidence is the switch's own
table. Install two rules at different priorities matching the same destination, modify the
high-priority one, and read back:

```bash
curl -s http://localhost:8080/stats/flow/1 | python3 -m json.tool
```

**Pass:** the priority-100 entry's actions changed; the priority-10 entry's `duration_sec` and
`n_packets` are consistent with never having been touched. That "same entry, unchanged counters"
check is how the original defect was confirmed, so it is the right instrument here too.
**Also required:** grep the kernel log for a `modify` failure from `Controller.cpp` — a 404 from
`modify_strict` surfaces nowhere else. §3.3 should already have ruled this out.

### 5.3 A-2 — the part no unit test can reach

Wedge the control plane and watch the clock and the log, since these are the two things the fix
changed and neither is observable from a test binary.

```bash
# with the fabric up and the kernel running, make the controller accept and never answer:
sudo iptables -I INPUT -p tcp --dport 8080 -j DROP
# wait through two poll intervals, then:
grep -n "topology poll got no answer" kernel.log
sudo iptables -D INPUT -p tcp --dport 8080 -j DROP
grep -n "topology poll answered again" kernel.log
```

**Pass:** exactly **one** "no answer" line appears no matter how many polls elapse; it names the
URL and an elapsed time in the region of 15s (three requests × 5s), not 733s; the poll keeps
running; and exactly one "answered again" line appears after the rule is removed.
**Fail:** one line per poll (edge-triggering broken), no line at all (the WARN is unreachable), or
the thread never returning (the bound is not on the command that runs).

Copy `kernel.log` elsewhere **before** the next stack cycle — A-5: every kernel restart truncates
the previous round's log, including this evidence.

---

## 6. Open questions for Adam

1. **A-4e 400-on-missing-priority.** Should `modify_flow_entry` reject a request with no
   `priority` (400) instead of defaulting to 0? Safer, and it is the literal reading of
   "do not touch a different rule" — but it can silently stop Energy-Saving-App's modifies, and
   that repo is not on this machine to check. §2.3.
2. **A-4e decide-first/412.** Confirm that not building it is right, given that a 412 cannot reach
   the caller through the async dispatcher. §2.3.
3. **A-2 partial application.** A pass where switches answers and links does not still applies the
   half it got. Pre-existing, deliberately left alone tonight. Worth a separate ticket?
4. **`FailureRun` duplication.** A-2 re-implements two lines of it rather than pulling
   `DeviceConfigurationAndPowerManager.hpp` into `TopologyAndFlowMonitor.hpp`. Hoist it to
   `include/utils/` as a follow-up?
