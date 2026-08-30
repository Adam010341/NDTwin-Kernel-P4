# A-7 — making a queued write's failure answerable after the fact

[Co-developed with claude code -- Adam]

Written by: 8/29 mainDev. Base `1208d22` (`git merge-base --is-ancestor 1208d22 HEAD` = true).
Measurement window (live-traffic round, claim to 01:24) was open throughout, so this package is
**written but not compiled and not run**. Nothing below is a measurement except §4, which is a
source read.

---

## §0 Predictions, registered before anything is built or run

The window forbids building, so these are pre-registered in the strong sense: there was no way to
peek. Recording them because a prediction written after the first green run is worth nothing.

| # | Prediction | How it gets checked | If it comes out otherwise |
|---|---|---|---|
| P1 | The package compiles with **no** change to any `CMakeLists.txt` except adding one test file. | `cmake --build` post-window | `DispatchOutcomeLog` was wrongly assumed header-only-able; add it to the routing lib and say so |
| P2 | All 9 `DispatchOutcomeLogTest` cases pass first run. | ctest | Investigate before touching the test — a first-run failure here is a design error, not a flake |
| P3 | `ConcurrentRecordersLoseNothing` is the one that could be **flaky**, and only under M5/M6. | 20 consecutive runs | If it flakes unmutated, the counters are wrong, not the test |
| P4 | Deleting the `outcomes_.record(...)` line in `Controller.cpp` turns **exactly 3** tests red (the three in `test_Controller.cpp` under the A-7 heading) and **zero** in `test_DispatchOutcomeLog.cpp`. | M11 | If the unit file also goes red it is reaching into Controller and is not a unit test |
| P5 | Live: after a POST naming a **nonexistent port**, `failed` increments and the entry appears in `recent_failures`, while `GET /ndt/get_switch_openflow_table_entries` shows nothing was programmed. | §5 recipe | If `failed` stays 0, the southbound is reporting success for a rule it did not program — a **bigger** finding than A-7 and it gets its own ticket |
| P6 | `dispatched` will exceed the number of POSTed entries on a live fabric, because other subsystems enqueue too. | §5 recipe | If it exactly equals the POST count, find the other writers before believing the counter |

P5 is the one worth being nervous about. It is also the one that decides whether this endpoint
reports anything at all in practice.

---

## §1 What A-7 actually is, at the line level

The chain, verified by reading every hop:

1. `HttpSession.cpp:1058` — `m_controller->dispatcher().enqueue(std::move(acceptedJobs))`.
   **This is the only `enqueue` call site in the repo.**
2. `HttpSession.cpp` (same handler) — answers `200 {"status":"queued", ...}`.
3. `FlowDispatcher::workerLoop_` (`FlowDispatcher.cpp:127-129`) — `sender_(burst)`.
   **`SenderFn` returns `void`** (`FlowDispatcher.hpp:38`), so the dispatcher never learns the
   outcome and structurally cannot.
4. `Controller.cpp` sender lambda — calls `installAnEntry`/`modifyAnEntry`/`deleteAnEntry`, gets an
   `OpResult`, logs it on failure with `SPDLOG_LOGGER_ERROR`, and **the `OpResult` goes out of
   scope**.

So A-7 is precisely: *the last surviving copy of a dispatched job's outcome is a log line*. The
`OpResult` type, the strategy's status parsing and the log line all already existed — every part
of the mechanism was in place except a reader.

`FlowDispatcher::droppedAfterStop()` (`FlowDispatcher.hpp:116`, added `aabe605`) is the same shape
already solved once, for a **narrower** failure: jobs refused because the dispatcher was already
stopped. The auditor's brief noted it has zero callers under `http/`. Confirmed — and it is now
published by the new endpoint, so that counter has a reader too.

## §2 What was built

| File | Change |
|---|---|
| `include/ndt_core/routing_management/DispatchOutcomeLog.hpp` | **New.** Header-only: atomic counters + a bounded ring of recent failures. |
| `include/ndt_core/routing_management/Controller.hpp` | Owns one, declared **before** `dispatcher_`; `dispatchOutcomes()` accessor (const). |
| `src/ndt_core/routing_management/Controller.cpp` | Sender calls `outcomes_.record(job, result)` for every job. |
| `src/ndt_core/http/HttpSession.cpp` | New route + handler `GET /ndt/get_flow_dispatch_status`; `detail` string now names it. |
| `include/ndt_core/http/HttpSession.hpp` | Handler declaration + docblock. |
| `tests/test_DispatchOutcomeLog.cpp` | **New**, 9 cases. |
| `tests/test_Controller.cpp` | +3 wiring cases. |
| `tests/CMakeLists.txt` | +1 source. |
| `tools/contract_test/components.py` | Endpoint registered in `KERNEL_ENDPOINTS` only. |

**Header-only was a deliberate choice**, not a stylistic one: it keeps the change to a single
`CMakeLists.txt` line at a time when nothing can be compiled to check. `FlowJob.hpp` in the same
directory is the precedent.

### Three design decisions that a reviewer should attack

1. **The ring stores failures only; successes are counted.** A ring of all outcomes is the obvious
   design and it is wrong here — one healthy 2000-job burst evicts every failure, so the endpoint
   would report a clean system *because* the system was busy. `ASuccessBurstDoesNotEvictAnEarlierFailure`
   is the test that fails under the obvious design.
2. **Eviction is counted and published** (`recent_failures_evicted`). A silently truncated failure
   list reads exactly like a healthier system — A-7's own shape, one level up.
3. **`record()` is called for successes too, and stores nothing for them.** This is the seam the
   brief asked for. "Has this entry been confirmed by the southbound?" is a question about
   successes, and the sender is the only place a job and its `OpResult` coexist. T-11 adds an index
   inside `record()` and re-threads no call sites. **Deliberately not built now** — an index with
   no reader is the false affordance that cost `FlowDispatcher` its `fencePerBurst` parameter.

### Boundaries respected

- Dispatch is **not** made synchronous. The response is still `200 queued`.
- The flow-table view's service semantics are **untouched** — no change to
  `handleGetSwitchOpenflowEntries` or `updateOpenFlowTables`. That is T-11's ground.
- The `detail` string was reworded (see §6 for why that is safe and why leaving it was not an
  option). `status` and `accepted` are unchanged.

## §3 Mutation list

Not run — the window forbids building. Each row is a prediction, and the point of writing them
before the build is that they can be wrong.

| # | File | Mutation | Expected RED |
|---|---|---|---|
| **M1** | `DispatchOutcomeLog.hpp` | `record()` returns early for failures too | `AFailureKeepsEnoughIdentityToActOn`, `Overflow…`, both Controller failure tests |
| **M2** | `DispatchOutcomeLog.hpp` | push successes into the ring as well | `ASuccessBurstDoesNotEvictAnEarlierFailure` |
| **M3** | `DispatchOutcomeLog.hpp` | delete `evicted_.fetch_add(1, …)` | `OverflowDropsTheOldestAndSaysHowMany`, `ConcurrentRecordersLoseNothing` |
| **M4** | `DispatchOutcomeLog.hpp` | `pop_back()` instead of `pop_front()` | `OverflowDropsTheOldestAndSaysHowMany` (front/back dpids) |
| **M5** | `DispatchOutcomeLog.hpp` | counters become plain `uint64_t` | `ConcurrentRecordersLoseNothing` — **probabilistic**, see note |
| **M6** | `DispatchOutcomeLog.hpp` | drop the `lock_guard` in `record()` | `ConcurrentRecordersLoseNothing` — **needs TSan to be deterministic** |
| **M7** | `DispatchOutcomeLog.hpp` | `capacity_(capacity)`, no zero guard | `ZeroCapacityStillKeepsOneRatherThanDividingByZero` |
| **M8** | `DispatchOutcomeLog.hpp` | `seq` taken from `failed_` instead of `dispatched_` | `SeqIsGlobalSoGapsBetweenFailuresAreVisible` |
| **M9** | `DispatchOutcomeLog.hpp` | `opName(Modify)` returns `"install"` | `EveryOpHasAName`, `EveryOperationsFailureIsRecorded…` |
| **M10** | `DispatchOutcomeLog.hpp` | record `job.dpid` into `requestedPriority` | `AFailureKeepsEnoughIdentityToActOn` |
| **🔴 M11** | `Controller.cpp` | **delete the `outcomes_.record(...)` call** | the 3 A-7 tests in `test_Controller.cpp`, and **nothing** in `test_DispatchOutcomeLog.cpp` (P4) |
| **M12** | `Controller.cpp` | move `record()` inside `case FlowOp::Install:` | `EveryOperationsFailureIsRecordedNotJustInstalls` |
| **M13** | `Controller.cpp` | call `record()` only when `!result.ok` | `ASuccessfulDispatchIsCountedEvenThoughNothingIsStored` |
| **M14** | `HttpSession.cpp` | delete the route line | §5 live: `404` |
| **M15** | `HttpSession.cpp` | hardcode `recent_failures_evicted` to `0` | §5 live overflow check |

**M11 is the one that matters.** It is the "is it actually wired" mutation, and this project has
shipped a perfectly-correct-and-never-called component before (`memory: existence-is-not-wiring`,
EventBus with zero production subscribers). If M11 does not turn `test_Controller.cpp` red, the
package is decorative.

**M5/M6 honesty:** these are races. A green run under mutation does not clear them — it means the
race did not lose that time. M6 is only a real gate under `-fsanitize=thread`. Recorded so nobody
reads a green M5/M6 as "the counters are proven safe"; the deterministic evidence for those two is
the source, not the test.

### The control that must stay GREEN

**C1 — change the default capacity in `DispatchOutcomeLog.hpp` from `256` to `512`.**
Every test constructs the log with an explicit capacity, so **all 12 tests must stay green.**

This is not filler. A suite that goes red on every edit has no discriminating power, and this
project has twice shipped an instrument whose FAIL meant nothing (`tr3_f5_window.py` keying on the
one field that does not survive; the `spread`-based verdict in FINDING-06). C1 is the cheapest
available check that the suite is keyed on behaviour rather than on incidental constants.

**C2 (secondary)** — reword the `SPDLOG_LOGGER_INFO` line in the new handler. Nothing asserts on
it; all tests stay green.

## §4 🔴 A correction owed to FINDING-06 — the 10.70 s period is **not** the dispatch cycle

This is a **source read**, done while tracing A-7's chain, and it lands on tonight's in-flight
`FINDING-06_dispatch-is-a-10.7s-cycle-not-a-queue.md`. Reported to the auditor rather than edited
into their document.

FINDING-06 says, honestly, under *Not established*: *"The source of the 10.70 s period has not been
located in the code."* It is located. It is not in the dispatch path.

**`FlowDispatcher` has no clock at all.** `workerLoop_` blocks on `cv_.wait` and sends the moment a
job arrives (`FlowDispatcher.cpp:109-130`). There is no periodic tick anywhere in it, so it cannot
be the source of a 10.70 s cycle.

The period is in the **table-view cache**, which is the instrument FINDING-06 used to timestamp
"programmed at":

- `HttpSession.cpp`, at the line `// TODO: Immediately update the table` followed by
  `updateOpenFlowTables(...)`. The requested entry is written into the cache **synchronously on
  the HTTP thread**, which is what makes the phantom appear instantly and carry the requested
  priority.
  🔴 **Cite this one by its anchor text, not by line.** It was `:1060-1061` at base `1208d22`,
  `:1119-1120` after the A-7 commits, and `:1147` after the T-11 ones — **it moved twice in one
  evening, both times because of my own edits above it.** The auditor caught the first drift.
  `memory: cited-line-numbers-are-not-evidence`.
- `DeviceConfigurationAndPowerManager.cpp:1885` — `fetchOpenFlowTablesInternal()` polls the
  southbound; `:1890` overwrites `m_cachedOpenFlowTables` wholesale.
- `DeviceConfigurationAndPowerManager.cpp:1900-1901` —
  `// 3. Sleep for 10 seconds` / `for (int i = 0; i < 10; ++i) // 10 * 1s = 10s sleep`.
- `handleGetSwitchOpenflowEntries` (`HttpSession.cpp`) returns that cache and nothing else.

**Period = 10 s fixed sleep + one southbound poll ≈ 10.7 s.** The 0.7 s is the poll of ten
switches / 1285 entries. An existing comment at `DeviceConfigurationAndPowerManager.cpp:2001-2002`
already describes this exact mechanism for a sibling symptom: *"dpid 999999999999 visible for ~7s,
until `openflowTablesUpdateWorker` re-polled Ryu and overwrote the cache."*

### What survives, and what does not

| FINDING-06 claim | Verdict |
|---|---|
| An exposure window exists, bounded ~10.7 s, mean ~5.35 s, phase-distributed | ✅ **Stands** — and is now explained rather than measured |
| Four rules posted 9 s apart "programmed at the same instant, to within 0 ms" | ✅ **Observation stands** — they were replaced by **one cache write**, which is why 0 ms |
| A caller reading back sees its own values confirmed for that window | ✅ **Stands**, and is the real consumer-facing consequence |
| The methodological section on the non-discriminating statistic | ✅ **Stands**, and is the best part of the document |
| **"a 10.70 s dispatch cycle"** (title, thesis) | 🔴 **Not supported.** It is the table-cache refresh cycle. Dispatch is event-driven. |
| **"the phantom ends exactly when programming begins"** | 🔴 **Not supported.** The phantom ends when the cache is overwritten. Programming plausibly happened seconds earlier; nothing here measured it. The 35–55 ms "handover" is the resolution around a single cache write. |
| **"set by a clock … load cannot lengthen it"** | 🔴 **Half wrong.** The 10 s sleep is fixed; the *period* is sleep + poll duration, and the poll scales with switches and entries. The measured 10.70 vs the constant 10.00 **is** that term. |
| "Fabric size is uncontrolled … the one comparison that would let this speak to T-4" | ✅ Correctly flagged — and now answerable by source read, not another live run |

**The window is real and the number is right. The mechanism and the title are not.** The practical
difference is large: under "dispatch cycle" the rule is unprogrammed for up to 10.7 s; under
"cache refresh" the rule is very likely programmed almost immediately and only *invisible* for up
to 10.7 s. Those imply different fixes and different severities.

🔑 The instrument's own refresh period became the finding's headline number — the shape in
`memory: instrument-must-not-mimic-its-own-finding`. FINDING-06 caught this exact class of error
twice in its own text and then landed on it once more, one level out.

**Not established by me:** *when* the rule is actually programmed. Establishing it needs a
southbound-side observation (proxy log, or bmv2 table dump) rather than the kernel's cached view.
That is the measurement that would settle severity, and it is cheap. I have not run it.

**This directly shaped A-7's design:** `get_flow_dispatch_status` is served from the dispatcher's
own counters and **not** through `DeviceConfigurationAndPowerManager`. A failure counter behind a
10.7 s cache would answer "no failures" for precisely the window in which the caller is asking
whether its write failed.

## §5 Live verification (post-window, needs a fabric)

Not run. Preconditions: `ndt status` shows `measuring` empty and the claim released.

```bash
curl -s localhost:8000/ndt/get_flow_dispatch_status | python3 -m json.tool
```

1. **Baseline** — record `counters`. Expect `dispatched` > 0 on a warm fabric (P6).
2. **Force a failure.** Port 999 does not exist; FINDING-07 established such rules are correctly
   not programmed, which makes this the cheapest real failure available:

```bash
curl -s -X POST localhost:8000/ndt/install_flow_entry -H 'Content-Type: application/json' \
  -d '{"dpid":1,"priority":915,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.241"},"actions":[{"type":"OUTPUT","port":999}]}'
sleep 2
curl -s localhost:8000/ndt/get_flow_dispatch_status | python3 -m json.tool
```

   Expect `failed` +1 and a `recent_failures` entry with `dpid: 1`, `requested_priority: 915`,
   `match.ipv4_dst: "10.0.0.241"`, and a non-zero `controller_status`. **This is P5.**
3. **Force-green control** — repeat with `"port":2`. Expect `succeeded` +1, `failed` unchanged,
   `recent_failures` unchanged. A gate that only ever goes red is not a gate
   (`memory: failures-that-report-success`, mirrored side).
4. **Cross-check against the log** — `grep 'dispatched install failed' kernel.log`. The endpoint
   and the log must agree; they are now two views of one event and disagreement means the new
   record is lying.
5. **Overflow** — post 260+ failing entries in one batch, confirm `recent_failures` caps at 256
   and `recent_failures_evicted` > 0 (kills M15).

## §6 The `detail` reword, and why it is not a contract break

`install_flow_entry`'s `detail` said outcomes were *"reported in the kernel log, not in this
response"* — a true sentence and the whole of A-7. Leaving it would have made the new endpoint
undiscoverable to exactly the caller that needs it.

Safe because the auditor's cross-repo check (`12_auditor-rulings.md` §3, 21:00–21:04) established
that both in-repo consumers log this body and neither parses it; TE never reads `status_code` at
all. `status` and `accepted` — the fields something *could* key on — are unchanged.

Honest boundary, inherited from that check: whether an operational script outside these two repos
parses `detail` was not established by either of us. It is free text in a `200` body, which is the
weakest thing in the response to depend on, but "weak to depend on" is not "nobody depends on it".

## §7 Not established

- **Nothing here has been compiled or run.** Every claim about behaviour is a prediction (§0).
- **The endpoint is unauthenticated and unbounded in read cost**, like every other `GET /ndt/`
  here. `recentFailures()` copies up to 256 records with their JSON matches under a lock on each
  call. Fine for a dashboard polling at 1 Hz; not fine as a hot loop. No rate limit was added
  because none of the neighbours have one and inventing one endpoint's worth of policy is worse
  than the consistency.
- **`dispatched` counts jobs handed to the southbound, not entries POSTed.** Entries rejected at
  the HTTP layer (unknown dpid, shape problems) never reach the dispatcher and are invisible here.
  That is B-1's territory, not A-7's, and conflating them would make the counter mean two things.
- **Counters reset on kernel restart** and are not persisted. Deliberate; a persistent store is a
  different ticket with different failure modes.
- **`droppedAfterStop` is published but still has no test at the HTTP layer.** Its unit test in
  `test_FlowDispatcher.cpp` predates this work and is unchanged.

---

## §8 Results (window closed 21:53; run 2026-08-30 22:0x). §0 is left exactly as written

Kernel HEAD `1e0665b` (the live-traffic round landed `68c3209` meanwhile);
`git merge-base --is-ancestor 1208d22 HEAD` still true.

| Prediction | Outcome |
|---|---|
| **P1** no `CMakeLists` change beyond the test source | ✅ **Held.** Clean build, 12 targets, no library CMake edit |
| **P2** all 9 unit cases pass first run | ✅ **Held.** 20/20 for the filter, first run |
| **P3** the concurrency case is the flaky candidate | ⬜ not stressed; it passed every run (~14 builds) but 20 consecutive runs were not done |
| **P4** M11 reddens exactly 3 in `test_Controller.cpp`, 0 in the unit file | ✅ **Held exactly** |
| **P5 / P6** live behaviour | ⬜ **Not run — needs a fabric.** Still the ones worth being nervous about |

**Full suite: 647/647.** `ndtwin_kernel` also builds.

| # | Verdict | Tests reddened |
|---|---|---|
| M1 | 🔴 RED | 9 — incl. `AFailureKeepsEnoughIdentityToActOn`, `Overflow…`, both Controller wiring cases |
| M2 | 🔴 RED | 5 — incl. `SuccessesAreCountedButNotStored`, `ASuccessBurstDoesNotEvict…` |
| M3 | 🔴 RED | `OverflowDropsTheOldestAndSaysHowMany`, `ConcurrentRecordersLoseNothing` |
| M4 | 🔴 RED | `OverflowDropsTheOldestAndSaysHowMany` |
| M7 | 🔴 RED | `ZeroCapacityStillKeepsOne…` |
| M8 | 🔴 RED | `SeqIsGlobalSoGapsBetweenFailuresAreVisible` |
| M9 | 🔴 RED | `EveryOpHasAName` |
| **M11** | 🔴 **RED — 3, all in `test_Controller.cpp`, 0 in the unit file** | the wiring is real |
| M12 | 🔴 RED | `ASuccessfulDispatchIsCountedEvenThoughNothingIsStored` |
| **C1** | ✅ **GREEN — all 20** | the suite is keyed on behaviour, not on the constant |

- **M13 was a duplicate of M12** (both are "call `record()` only on failure"). Recorded rather than
  quietly dropped: the list claimed 15 distinct mutations and had 14.
- **M5/M6 not run.** They are races; a green run would not clear them and they need TSan. Their
  evidence remains the source, not the suite. Unchanged from §3.
- **M10, M14, M15 not run.** M10 is a trivial variant of M1; M14/M15 need a live kernel.

### 🔴 The mutation harness reported the most severe outcome as a survival

**M1's first run came back GREEN.** By hand it is RED. The harness was wrong, not the mutation.

Under M1 nothing is ever pushed to the ring, so `OverflowDropsTheOldestAndSaysHowMany` — which
checked size with `EXPECT_EQ` and then called `failures.front()` — dereferenced an empty vector and
**segfaulted the binary** (`rc = -11`). gtest therefore printed no summary block, and the harness
decided the verdict by `re.findall(r"^\[  FAILED  \] (\S+)$")`, which only ever matches summary
lines. No summary → no matches → **"GREEN, mutant survived"**.

So the instrument turned *crash*, the worst available outcome, into *the mutation is harmless*.
It could go red and it could go green; what it could not do was distinguish "nothing failed" from
"nothing finished". `memory: failures-that-report-success`, and specifically its mirrored side.

Two real defects, both fixed:

1. **The test**: `EXPECT_EQ` before a `front()`/`back()` must be `ASSERT_EQ`. Same hardening applied
   to `EveryOperationsFailureIsRecordedNotJustInstalls`, where a moving counter was being used as a
   proxy for a non-empty ring — precisely what a count-but-do-not-store mutation defeats.
2. **The harness**: the verdict now reads the **return code** first (`CRASH-RED` for a signal),
   requires the `Ran N` line to exist, and treats a missing summary as `NO-SUMMARY`, never as green.

After both fixes every row above was re-run from a clean baseline, with restoration verified by
sha256 each time.

### 🔴 And a second one: the harness left a mutant *binary* behind

The full suite then failed 3 tests — exactly M11's three — while `git diff` showed the source
clean. The harness restores the source file and **does not rebuild**, so `test_routing_strategy` on
disk was still the M11 build. Rebuilding gave 647/647.

Worse than a leftover mutant source, because the source looks innocent: every instrument that reads
the *repository* says the tree is clean, and the thing actually under test is the artifact. The
final gate has to be **rebuild, then baseline green** — restoring the input is not restoring the
system. `memory: mutation-harness-must-guard-its-baseline` is now two-sided: guard the source
going in **and** the artifact coming out.

🔑 Both defects were found because a prediction in §0 said RED and the run said GREEN. A mutation
battery with no pre-registered expectation would have recorded "M1 survived" and moved on.
