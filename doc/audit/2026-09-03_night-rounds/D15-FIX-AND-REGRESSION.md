# D15 -- the bmv2-liveness startup race: the fix, and what it was NOT possible to verify

[Co-developed with claude code -- Adam]

🔴 **READ THIS FIRST. The gate was written but never run.** The session hit its wall-clock cap
with the build unfinished, so **no assertion in this document has been executed**: the test was
never compiled, never seen red, never seen green, and the fabric was never brought up. By the
project's own rule -- *測試沒看過紅就不算交付* -- **the mutation gate is NOT delivered**:
**0 mutations run, 0 killed, gate SURVIVOR.** The four regression rows are **all UNRUN**.

What *is* delivered is the code change and an exact, executable recipe for everything left.

Branch: `fix/d15-dataplane-kind-race`, one commit on top of **`128bfc6b`** (trunk at the time the
work was commissioned). Not pushed. Built from an isolated worktree at that commit, never from the
shared working tree -- see "Why an isolated worktree" below.

---

## 1. The defect, restated only as far as the fix needs it

Established by round 3 lead C and round 2 D15; not re-derived here.

`TopologyAndFlowMonitor::start()` only *spawned* the thread that parses the topology JSON and
returned. `main.cpp:409` called it, ran on through the collector, historical data and the event
handler, and at `:432` called `DeviceConfigurationAndPowerManager::start()`, which asks
`getSwitchKindGroups()` whether the fabric is all-bmv2 and **caches the answer for the process
lifetime**. Nothing sequenced the two. An empty switch-kind index is not "not bmv2", but it
answered like one.

Measured: the power manager won 5/8 at 310 B, 5/8 at 587 B, and **0 of 44 at >= 7.8 KB** (0/20 on
the shipped 4-host P4 model). Consequence: **0 `GET /p4/switch_state` against 108 topology polls.**

## 2. The fix (two halves, deliberately)

**Ordering** -- `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`, `start()`:
the static load, `initializeMappingsFromGraph()` and `configureTopologyApiUrls()` move out of
`run()` (the spawned thread) into `start()`, **on the caller's thread, before any thread of this
class exists**. After `start()` returns the switch-kind index is populated by construction, at any
file size. Published as `isStaticTopologyLoaded()` and `staticTopologyLoadedOnThread()` so the
postcondition can be asserted instead of trusted to a comment. This also closes the pre-existing
data race that `loadStaticTopologyFromFile`'s own note describes: `add_vertex`/`add_edge` no longer
run concurrently with `flushEdgeFlowLoop`.

**Synchronisation** -- `DeviceConfigurationAndPowerManager::refreshDataPlaneKind()`:
an answer derived from an *unloaded* topology is no longer an answer. It is refused, logged as an
ERROR naming D15, left **undetermined** (`m_dataPlaneKindDetermined`), and re-derived at the point
of use by the new `dataPlaneIsBmv2()`, which the ping worker now calls instead of reading the
cached bool. "No switches read yet" and "these are not bmv2" were the same value; they are now
different values. This is what survives someone reintroducing the race on a small file.

This is not a speed change. 587 bytes still lost 3 times in 8; nothing here makes the parse faster.

**Files changed** (6): `include/ndt_core/collection/TopologyAndFlowMonitor.hpp`,
`src/ndt_core/collection/TopologyAndFlowMonitor.cpp`,
`include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp`,
`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`,
`tests/test_DataPlaneKindOrdering.cpp` (new), `tests/CMakeLists.txt` (one entry).

## 3. The gate -- written, NOT RUN

`tests/test_DataPlaneKindOrdering.cpp`, four tests. It asserts the **ordering**, not the outcome,
because a "does a `GET /p4/switch_state` appear?" test would pass again the day someone puts the
load back on the spawned thread behind a small enough topology file. Its fixture is deliberately a
**310-byte-class one-switch topology** -- the file size at which the racy implementation *wins* --
so none of these can be satisfied by luck:

| test | what makes it red |
|---|---|
| `StartLoadsTheStaticTopologyBeforeItReturns` | `isStaticTopologyLoaded()` false, or the kind index empty, when `start()` returns |
| `TheLoadRunsOnTheCallersThreadNotOnTheSpawnedPollThread` | the loader's `std::thread::id` is not the caller's. **Speed-independent**: which thread ran the load does not depend on how fast the parse is |
| `AVerdictTakenBeforeTheTopologyExistsIsNotCached` | a verdict taken with nothing loaded is recorded as *determined*, or is still believed after the topology arrives |
| `TheStartupSequenceMainUsesYieldsABmv2Verdict` | the outcome, in main.cpp's order. Kept separate so a green here can never stand in for the three above |

**To run it and close the gate** (this is the task the next session should do first):

```
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/<session>/scratchpad
flock $SP/lock/build.lock env PATH=$SP/shim:$PATH SHIM_JOBS=2 \
  cmake --build build-d15 --target test_routing_strategy
./build-d15/bin/test_routing_strategy --gtest_filter='DataPlaneKindOrderingTest.*'
```
Expect 4/4 PASS. **A cold build of this target took longer than 10 minutes at `-j2`; budget 20.**

**Mutations that must each be seen RED** (none of these was run):

| # | mutation | which test must go red |
|---|---|---|
| 1 | move the three load calls from `start()` back to the top of `run()` (the original defect verbatim) | `TheLoadRunsOnTheCallersThreadNotOnTheSpawnedPollThread` -- deterministically, at any file size |
| 2 | in `refreshDataPlaneKind()`, drop the `isStaticTopologyLoaded()` guard | `AVerdictTakenBeforeTheTopologyExistsIsNotCached` |
| 3 | make `dataPlaneIsBmv2()` a plain getter (delete the re-derive on `!determined`) | `AVerdictTakenBeforeTheTopologyExistsIsNotCached` |
| 4 | set `m_dataPlaneKindDetermined = true` on the refusal path | `AVerdictTakenBeforeTheTopologyExistsIsNotCached` |
| 5 | drop `configureTopologyApiUrls()` from `start()` | none of the four -- **an expected SURVIVOR, and it should be recorded as one**: the poll aiming is covered by `test_TopologyUrlAndPathJson.cpp`, not here |

A compile failure, a moved anchor, or the wrong test going red all count as SURVIVOR.
State the result as `N mutations, M survived`.

## 4. Regression table -- the four HIGH findings

**Every row is UNRUN.** The fabric was never brought up: the build did not finish inside the cap.
Predictions are stated so they can be falsified, and are marked as predictions, not results.

| # | finding | result | prediction, and how to test it |
|---|---|---|---|
| 1 | `/ndt/get_switches_power_state` reports the command issued, not a measurement: two equally dead switches report OFF (commanded) and ON (self-died) | **UNRUN** | *Predicted: changed shape, not gone.* Liveness now runs, so the self-died switch should flip to `is_up=false` within ~1 s and read OFF -- but the endpoint still reads the same `isUp` bit, which still carries two meanings. Recipe: `ndt up p4 4`; POST `set_switches_power_state` off for s7; `sudo ndtwin-p4-power off s9` out of band; wait 5 s; compare both in `get_switches_power_state` and `get_graph_data`. Round 2 `09_` is the control. |
| 2 | both power API directions early-return Success off a stale `isUp` (power-on 0.8 ms vs 1.48 ms when it acts) | **UNRUN** | *Predicted: survives, with a much narrower window.* The early return in `P4PowerStrategy.cpp:176` is unchanged; what changes is that `isUp` stops being stale. Recipe: kill s9 by pid, wait 3 s (one liveness tick), then `action=on` and **time it**: >= ~1.4 s and 8->9 bmv2 processes = corrected; ~1 ms and no new process = survives. Time it *before* the tick too, to separate the two. |
| 3 | a commanded power-off is lost 2 times in 9; `is_up` 1->0->1, the last transition at t_off+3.08 s, when a poll that reached the proxy at 1.86 s is applied | **UNRUN** | 🔴 **This fix does not address the writer.** `TopologyAndFlowMonitor.cpp:768-772` still writes `isUp=true` unconditionally with no false branch -- **a second, independent defect, untouched here and not to be claimed.** What this fix can do is *correct* the resurrection within ~1 s instead of never. Recipe: round 3's phase-A arm (fire the power-off ~1.5 s before the next poll), >= 9 trials, sample `is_up` at 10 Hz; expect the 0->1 at +2.31 s still to happen and a new 1->0 to follow it within ~1 s. If the second transition does not appear, the fix did not take. |
| 4 | a switch killed by pid still reported `is_up=True` and power ON seven and a half minutes later | **UNRUN** | *Predicted: gone -- this is the row the fix is aimed at.* Recipe: `ndt up p4 4`; `sudo ndtwin-p4-power off s9`; poll `get_graph_data` for 60 s. Expect `is_up=false` within ~1-2 s. **First check the mechanism actually ran**: `grep -c 'GET /p4/switch_state' .test_run/logs/p4_proxy.log` must be roughly one per second, not 0. If that count is 0 the fix did not take and rows 1-4 say nothing. |

**Run row 4 first.** It is the cheapest, and its proxy-log count is the single fact that decides
whether any of the other rows are interpretable.

## 5. Machine and worktree notes for whoever picks this up

- **Why an isolated worktree.** Another session was mid-refactor of
  `TopologyAndFlowMonitor.{hpp,cpp}` -- the same two files this fix touches -- and left them in a
  non-compiling state (`noteAndAnnouncePollRound` declared with `EndpointReply` in the header,
  defined with `const std::string&` in the .cpp). The shared build failed on *their* half-applied
  change. The fix was therefore applied to a detached worktree pinned at `128bfc6b` and committed
  from there, so the branch contains this change and nothing else. **The same edits are also in the
  shared working tree** (that is where they were written first) -- they are *uncommitted
  observations* there, mixed with other sessions' work; do not read the shared tree as this branch.
- **HEAD was already moved off trunk by another agent** before this session created its worktree:
  the shared worktree was on `fix/ports-that-block-restart` @ `62a3aea8`. This session did not move
  it and did not move it back. Reported to the coordinator.
- `build/bin/ndtwin_kernel` (sha `a8ba99c2`) was **not touched**; nothing was built into `build/`.
- Nothing was pushed. `p4_proxy/mininet/host_count_override` was never rewritten -- `ndt up` was
  never run.

## 6. Honest ledger

| claim | evidence |
|---|---|
| the ordering change is correct C++ | **none -- it was never compiled.** This is the largest open risk in the change |
| the gate is red on the unfixed ordering | **none -- never run.** 0 mutations, gate SURVIVOR |
| any of the four HIGH findings is fixed | **none -- never run** |
| the defect is as described | round 3 `01_`/`02_`/`05_` and round 2 `09_`, read, not re-measured |
