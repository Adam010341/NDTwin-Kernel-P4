# Scoped review of `be3c242..576dd2a` — summary

[Co-developed with claude code -- Adam]

24 commits, 46 files, +4566/−216. Reviewed in an isolated worktree at `/tmp/audit-576dd2a`
(pristine and left in place; `git status --porcelain` is empty). Nothing outside
`doc/audit/2026-08-03_scoped/` was modified — mutation testing used `cp` backups and restored every file,
never `git checkout`.

Detail: [P1-tests.md](P1-tests.md) · [P2-concurrency.md](P2-concurrency.md) ·
[P3-logic.md](P3-logic.md) · [P4-tooling.md](P4-tooling.md)

## Findings by severity

| | finding | where |
|---|---|---|
| **high** | `test_OvsPowerStrategy.cpp` segfaults 3 tests under `ctest` — L1 is red on this commit | P1 |
| **high** | the route-reinstall debounce discards every topology change that arrives during a reinstall | P2 |
| **high** | `KeyedFailureLog`'s hold-off resets on any quiet pass — an intermittent failure is reported never | P3 |
| **high** | `wait_for_port`'s "is the port ours?" check is unreachable; the stray-kernel case still passes | P4 |
| medium | `AFailedPortCommandFailsTheWholeOperation` checks a port attached *before* the failing one | P1 |
| medium | the whole `simulation_completed` `app_id` fix is untested; reintroducing it leaves 207/207 green | P1 |
| medium | no FlowDispatcher test fails when the lost-wakeup fix is reverted (500 attempts) | P1 |
| medium | `test_unsupported_match.py` never calls `route_flow`; removing all three `raise`s leaves 9/9 green | P1 |
| medium | `test_unsupported_match.py` cannot import — `networkx` is on none of the three interpreters | P1 |
| medium | static-mode startup allows a second, concurrent `install_all_pair_paths`; last writer wins | P2 |
| medium | `endPass()`'s "called twice" comment describes the wrong consequence (false *recovery*) | P3 |
| medium | `describeCommandStatus` blames `ovs-vsctl`/sudo for `curl`'s and `snmpget`'s exit 1 and 127 | P3 |
| medium | `_is_routable_unicast` lets `inv_flow_paths_non_empty` pass having examined zero flows | P4 |
| medium | `kernel_owns_log` cannot see a root-started kernel → false FAIL on the documented startup | P4 |
| medium | two allowlist patterns are far broader than their rewritten justifications | P4 |
| low | `on_link_delete` gates the graph update on a `requests.post` with no timeout | P2 |
| low | `handleGetNickname` logs a bad dpid under the name `inform_switch_entered` | P3 |
| low | `2026-07-29_HANDOFF.md` credits `topology_manager` with 9 pre-existing tests it does not have | P1 |
| low | `refreshDestinationPathsPeriodically` deep-copies the whole path map to test `.empty()` | P2 |
| low | `stack.sh down` fails on any listener on 8000/8080/8081 and asserts it is not ours | P4 |
| low | `enqueue()` drops jobs silently after `stop()` while the endpoint answers 200 (shutdown only) | P2 |
| low | `FlowDispatcher::stop()` called concurrently returns before the workers stop (no caller today) | P2 |

---

## 1. Which of the new tests would not fail if the defect it names returned?

Five, with the exact edit for each. All verified by running the mutant.

**a. `SimulationCompletedAppIdTest` — the entire `app_id` fix.**
Replace the validation block in `HttpSession::handleSimulationCompleted`
(`src/ndt_core/http/HttpSession.cpp:1160-1176`) with the original `const int appId =
std::stoi(appIdText);`. **All 207 tests pass.** The four tests in that suite only exercise
`utils::tryParseUint64`; nothing reaches the handler. The narrower mutant — deleting just
`|| *parsedAppId > static_cast<uint64_t>(std::numeric_limits<int>::max())` — also survives, and
`SomethingTooBigForIntIsRejectedNotWrapped`'s only real assertion is `4294967296 > INT_MAX`, which
is arithmetic on two literals.

**b. `OvsPowerStrategyTest.AFailedPortCommandFailsTheWholeOperation`.**
Add `if (m_lastCommandFailed) { break; }` to the end of the port loop in `OVSPowerStrategy::powerOn`
(`src/ndt_core/power_management/OVSPowerStrategy.cpp:99`). **20/20 pass.** The test fails on
`s1-eth2` and then asserts `s1-eth1` was attached — but `s1-eth1` is attached first, so the
assertion labelled "should not abort the remaining ports" holds no matter what the code does after
the failure.

**c. `FlowDispatcherTest.StopReturnsRatherThanDeadlockingOnAnIdleWorker`.**
Revert `start()` to `void FlowDispatcher::start() { running_ = true; }` and move `running_ = false`
out from under `mtx_` in `stop()` — the pre-`d5f5bfa` shape for the lost wakeup, leaving the other
two fixes in place. **Survives 300 repeats of that test and 200 repeats of all six.** No test in the
file catches this fault.

**d. `p4_proxy/tests/test_unsupported_match.py` — all nine tests.**
Replace all three `raise UnsupportedMatchError(bad)` statements in `route_flow`, `unroute_flow` and
`modify_flow` (`p4_proxy/proxy_agent/topology_manager.py:146, 194, 213`) with `pass`, restoring the
silent narrowing `c964946` exists to remove. **9/9 pass.** The file only imports the two
module-level helpers; it never constructs a `TopologyManager` and never touches `api_routes`, so
the brief's question — does the 400 reach the caller — is answered by nothing.

**e. `test_Controller.cpp`, only in a contrived way.** `sawLineContaining` matches bare substrings
anywhere in the line, so swapping `job.dpid` and `job.priority` in the format string leaves
`AFailedDispatchIsReportedWithTheDpidAndTheControllersReply` green (both "42" and "99" are still
present). Recorded for completeness — the file is otherwise the strongest in the diff, and the
mutation it was rewritten for (`if (!result.ok)` → `if (false)`) is caught by two tests.

---

## 2. What in this diff is a silent failure?

Ordered by how long the silence lasts.

- **`KeyedFailureLog` under an intermittent fault** (P3-1). Measured: a failure present in 99 % of
  600,000 passes over ten minutes is reported **zero** times, because any single pass without the
  key erases the entry and restarts the 15 s hold-off. The keys come from flows in
  `m_flowInfoTable`, which `purgeIdleFlows` removes and `handlePacket` re-creates, so their presence
  tracks traffic and is not monotonic. This is the machinery that replaced the warning which
  answered the P4 host-port bug; that answer would now be printed only if traffic ran continuously
  for 15,000 consecutive passes.

- **The route-reinstall debounce** (P2-1). A link failure arriving while `install_all_pair_paths`
  is running increments the sequence, hits `if self.reinstall_worker_running: return`, and is never
  acted on — the worker has already left the loop that watches the sequence. The window is the
  duration of the walk (16,256 host pairs; ~60 s). Verified with a deterministic simulation of the
  real scheduler. The log then prints "route reinstall done" for the *previous* change.

- **`wait_for_port`'s stray-process guard** (P4-1). The "not ours" branch is dead code — the same
  condition ran a few instructions earlier in the same iteration — so whether a stray listener is
  caught depends entirely on whether the just-forked component has already died at the first poll.
  It normally has not. The comment promises detection of "a port that opens because *something else*
  is already listening"; the code detects "the component we started is already gone."

- **`inv_flow_paths_non_empty` on a non-unicast sample** (P4-2). The new `_is_routable_unicast`
  filter can empty the candidate list entirely, and nothing counts how many flows survived it. PASS
  and "checked nothing" are indistinguishable in the output.

- **A `curl` or `snmpget` failure attributed to `ovs-vsctl`** (P3-3). Not silence exactly — the
  opposite: a confident, wrong statement. `describeCommandStatus` moved into `utils::execCommand`,
  which runs curl and 13 SNMP call sites, and still hardcodes "is ovs-vsctl installed?" for 127 and
  the sudo-prompt explanation for 1.

- **`handleGetNickname` logging under another endpoint's name** (P3-4). A bad `?dpid=` on
  `/ndt/get_nickname` writes `inform_switch_entered: dpid '…' is not an unsigned integer`.

- **The two allowlist patterns** (P4-4). Both suppress far more than the reason beside them claims:
  `field missing in P4: \[\]\.flows` (unanchored `re.search`) hides a missing `actions` or
  `priority` just as readily as a missing `dl_dst`.

- **`FlowDispatcher::enqueue` after `stop()`** (P2-6), bounded to shutdown: the job is dropped with
  no log and no counter while `processFlowBatch` answers 200 with `accepted: N`.

---

## 3. What did I check and find sound?

Listed so that absence from the findings means "examined and cleared", not "not looked at".

**Concurrency**
- The two-mutex `scoped_lock` in `setAllPaths` is the **only** site that takes both mutexes — I
  enumerated every use of each — so there is no second ordering to deadlock against. Nor is there a
  cycle with the graph mutex or `m_flowInfoTableMutex`: nothing that holds either path mutex
  acquires another lock while holding it, and the `pathKnown` lambda is explicitly scoped to keep
  the graph-taking body outside it.
- `FlowDispatcher::stop()` **drains** rather than discarding: a worker whose queue is non-empty
  sends the remaining burst before exiting. `enqueue` before `start()` is unreachable in production
  (`Controller`'s constructor starts the dispatcher, and it is the sole owner). The destructor's
  second `stop()` is safe sequentially, and `StopIsIdempotentBecauseTheDestructorCallsItToo` covers
  it. Two of the three lifecycle fixes do have teeth: reverting `stop()`'s `workers_` locking hangs
  `StopIsSafeWhileJobsAreStillArriving` on the first iteration, and removing the `!running_` guard
  is caught immediately by `EnqueueAfterStopIsDroppedRatherThanSpawningAnUnownedThread`.
- `Classifier::knowsSwitch` is monotonic (`updateFromQueriedTables` never erases), so the
  `no-table:` / `no-rule:` keys cannot alternate for that reason.

**The OpResult chain**
- Wired correctly in both directions. I looked specifically for a failure reported as success and
  for a success reported as a failure, and found neither: the only `SPDLOG_ERROR` is inside
  `if (!result.ok)`, `OpResult::ok` defaults to `false` so a future unhandled `FlowOp` would log
  rather than pass silently, and `ASuccessfulDispatchReportsNothing` pins the quiet path. Mutant M6
  (`if (!result.ok)` → `if (false)`) is killed by two tests. `test_Controller.cpp`'s capturing sink
  is the right instrument and its `LogCapture` is destroyed after the dispatcher, so the sink
  outlives the worker threads.

**Power management**
- `powerOff`'s refusal cannot strand a switch: the bridge is untouched, a transient failure clears
  on retry, and if the bridge is genuinely gone the `ovsLivenessFor` probe marks the vertex down
  independently. The empty-saved-ports `powerOn` really is the only remaining hole in that class,
  and the test that records it says so first.
- `describeCommandStatus`'s `errno` read is valid at all three call sites — nothing runs between the
  `pclose`/`std::system` and the call at any of them — and the `status == -1` check correctly
  precedes `WIFSIGNALED`/`WIFEXITED`.

**Utils**
- The new `<sys/wait.h>` and `<cstring>` in the near-universally-included `Utils.hpp` break nothing:
  clean `-Werror` build of every target, no warnings, 207 tests green.
- `tryIpStringToUint32` does not widen what the endpoints accept — it uses the same `inet_aton` as
  the pre-existing throwing version, so the short forms were already accepted and the test records
  rather than introduces them. `tryParseUint64` is genuinely stricter than `stoull` in every way its
  tests claim, and out-of-range is refused rather than wrapped.
- `test_ParamParsing.cpp` and `test_IpToString.cpp` are honest throughout: the IP round-trip goes
  through a *different* function (`inet_ntop` vs `inet_aton`) so it is not a tautology, and
  `test_IpToString.cpp`'s header states up front that it does not distinguish `inet_ntop` from
  `inet_ntoa` and explains why.

**P4 proxy**
- `HONOURED_MATCH_FIELDS` is complete for what actually calls it. I read both real callers rather
  than reasoning about them: `Traffic-Engineering-App.py:337`/`:501` and
  `Energy-Saving-App/src/app/http.cpp:153` both send exactly `{eth_type: 2048, ipv4_dst: …}`, which
  is inside the honoured set. Nothing that works today starts getting a 400.
- The 400 does reach the caller: all three endpoints in `api_routes.py` catch
  `UnsupportedMatchError` and raise `HTTPException(400, …)` with the field list. What is missing is
  a test of it, not the behaviour.

**Kernel HTTP layer**
- `getFlowsArrayForDpid`'s new `json*` return cannot dangle — the pointer is taken after the
  `push_back` and re-obtained per entry — and its `nullptr` path is unreachable in practice because
  `processFlowBatch` rejects unknown dpids with 404 before `updateOpenFlowTables` is called
  (`HttpSession.cpp:983` is its only caller).
- `validateRequestBody` is shape-only and says so in three places, exactly as the brief describes.
  I looked for the failure mode the brief asked about — could its comments or placement lead a
  reader to think the body is sanitised — and the answer is no: the header carries an `@warning`,
  the interpolation site carries a NOTE, and
  `ChecksShapeOnlyAndIsNotAnInjectionDefence` asserts a shell metacharacter is *accepted*, with
  instructions for what to change when the injection work lands. That is the right construction.

**Tooling**
- The P4 convergence gate fix is correct: `hosts * (hosts - 1)` ordered pairs expected, and
  `observed_counts` now reads inside the envelope rather than `len()`-ing its two keys.
- `mark_log`'s repeated-run detection warns rather than silently adjusting, and names the fix.
- The `warning_allowlist.txt` change removes suppression rather than adding it, and deliberately
  does not allowlist the new `KeyedFailureLog` lines. Correct direction — its value now hinges
  entirely on P3-1.
- `compare_baseline.py` reports zero-hit allowlist rules, so over-narrow entries are cheap.
- `l1_unit_tests.sh` runs `ctest` *and* each binary directly and treats SKIPPED / no-tests-ran as
  failures. The layering is right, which is precisely why the three ctest segfaults matter.

---

## Notes on method

- Both mutation harnesses verify the patch actually landed before drawing a conclusion, and `cd`
  into the worktree before running the binary. Both guards earned their place during this review:
  my first `--gtest_filter='*'` run reported a kill that was really four unrelated
  `test_SFlowEmitterRoundtrip` failures caused by fixture paths resolving against `$PWD`, and my
  first `OvsPowerStrategyTest.*`-only mutation reported a kill that was really the segfault in
  finding P1-1.
- Race-dependent mutants were run 200–300 times, not once. The lost-wakeup mutant survived all of
  them; the `workers_` mutant died on iteration 1. A single green run would have been worthless for
  either.
- Where I could not run something — Ryu, bmv2, a live baseline — I said so and gave the reasoning
  chain instead, and labelled the finding *probable* rather than *verified*. Three findings are
  labelled that way: P2-2, P2-3 and the regression-hiding half of P4-4.
