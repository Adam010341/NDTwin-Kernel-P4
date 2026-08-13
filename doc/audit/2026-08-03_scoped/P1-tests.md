# P1 — the new tests

Scope: `be3c242..576dd2a` only. Worktree `/tmp/audit-576dd2a`.

[Co-developed with claude code -- Adam]

Everything below was checked by **mutation**: reintroduce the defect the test names, rebuild, run.
The harness is `/tmp/claude-1000/.../scratchpad/mutate.sh` (and `mutate_repeat.sh` for the racy
ones). It refuses to report a result unless the patch actually changed the file — the same
self-check the OVS mutation run needed — and it `cd`s into the worktree, because
`test_SFlowEmitterRoundtrip` resolves its `.bin` fixtures relative to `$PWD` and running the binary
from elsewhere fails four unrelated tests that read as a kill. Both of those bit me once each
before the numbers below were trustworthy.

---

### `test_OvsPowerStrategy.cpp` segfaults in three of its twelve tests under `ctest`

- **File:line** — `tests/test_OvsPowerStrategy.cpp:100` (the `Fixture`, which never initialises the
  logger), introduced in `65aaa38`
- **Severity** — **high**. L1 is red on this commit. `tools/test_workflow/l1_unit_tests.sh:89` runs
  `ctest` and counts a non-zero exit as a failure, so the whole test workflow fails at layer 1 —
  and `doc/2026-07-29_HANDOFF.md` (updated in this same range) records L1 as green, "207 C++ 直接跑 + ctest ✅".
  Whoever runs the workflow next meets three SEGFAULTs the handoff says cannot be there.
- **Confidence** — verified
- **How I checked**

  ```
  $ ctest --test-dir build
  99% tests passed, 3 tests failed out of 207
        201 - OvsPowerStrategyTest.PowerOnRecreatesTheBridgeWithTheSavedPorts (SEGFAULT)
        203 - OvsPowerStrategyTest.PowerOnDoesNotMarkUpWhenACommandFails (SEGFAULT)
        204 - OvsPowerStrategyTest.AFailedPortCommandFailsTheWholeOperation (SEGFAULT)

  $ ./build/bin/test_routing_strategy                       # the direct run
  [  PASSED  ] 207 tests.

  $ ./build/bin/test_routing_strategy \
        --gtest_filter='OvsPowerStrategyTest.PowerOnRecreatesTheBridgeWithTheSavedPorts'
  Segmentation fault (core dumped)          # exit 139
  ```

  gdb names the cause exactly:

  ```
  #0  spdlog::logger::should_log(spdlog::level::level_enum) const ()
  #3  OVSPowerStrategy::powerOn(unsigned long, ..., TopologyAndFlowMonitor*) ()
  #4  OvsPowerStrategyTest_PowerOnRecreatesTheBridgeWithTheSavedPorts_Test::TestBody() ()
  ```

  `powerOn` logs `SPDLOG_LOGGER_DEBUG(Logger::instance(), "sudo ovs-vsctl add-port {} {}", ...)`
  inside its port loop (`OVSPowerStrategy.cpp:95`), and `Logger::instance()` is a null
  `shared_ptr` until `Logger::init` runs. `test_OvsPowerStrategy.cpp` has no fixture and never
  calls it. The three failing tests are exactly the three that reach that loop with a non-empty
  saved-port list; the other nine either early-return or use `powerOff`, which the fake fully
  overrides and which never logs.
- **Failure scenario** — `ctest` (or any single-test run, or any future reordering of the sources
  in `tests/CMakeLists.txt`) runs `PowerOnRecreatesTheBridgeWithTheSavedPorts` in a process where
  nothing else has initialised the logger → null `shared_ptr` deref → SIGSEGV. In the full direct
  run it passes only because an earlier suite happened to call `Logger::init` first; that is a
  property of file ordering in the CMake source list, not of this test.
- **Suggested fix** — the same `SetUpTestSuite` that `test_Controller.cpp:252` already uses, with
  its comment ("Logger::instance() is a null shared\_ptr until init runs -- the same trap
  documented in SwitchKindFixture"). This file was written after that one and did not inherit the
  guard. A `::testing::Environment` registered once for the binary would stop the next test file
  rediscovering it.

---

### `AFailedPortCommandFailsTheWholeOperation` cannot detect the abort it says it detects

- **File:line** — `tests/test_OvsPowerStrategy.cpp:296` (`65aaa38`)
- **Severity** — medium. The comment sells the test as covering "a bridge that comes up with some
  of its ports missing", which is the case an operator cannot diagnose. It does not cover it.
- **Confidence** — verified
- **How I checked** — the test fails `add-port s1 s1-eth2` and then asserts
  `EXPECT_TRUE(ovs.ran("add-port s1 s1-eth1")) << "should not abort the remaining ports"`. `s1-eth1`
  is attached *before* `s1-eth2` in `powerOn`'s loop (`OVSPowerStrategy.cpp:93-99`), so that
  assertion holds whatever the code does after the failure. Mutant M4 — add
  `if (m_lastCommandFailed) { break; }` to the end of the port loop:

  ```
  [==========] 20 tests from 2 test suites ran.
  [  PASSED  ] 20 tests.
  MUTANT SURVIVED (M4 powerOn abandons the remaining ports on first failure)
  ```

  (The filter is `ControllerTest.*:OvsPowerStrategyTest.*` rather than the OVS suite alone,
  because the OVS suite alone segfaults — see the finding above. This is the second-order cost of
  that bug: it makes the suite untestable in isolation.)
- **Failure scenario** — someone "tidies" `powerOn` to stop after the first failed command. Ports
  after the failing one are never attached, `powerOn` still reports failure so the vertex stays
  down — but the bridge now exists with a partial port set, and a later `powerOff` will record
  *that* partial set as the thing to restore. The suite stays green.
- **Suggested fix** — fail on the *first* port and assert the *second* one still ran:
  `failSubstring = "add-port s1 s1-eth1"`, then `EXPECT_TRUE(ovs.ran("add-port s1 s1-eth2"))`.
  That is the assertion the comment describes.

---

### `SomethingTooBigForIntIsRejectedNotWrapped` asserts arithmetic, not behaviour — and the whole `app_id` fix is untested

- **File:line** — `tests/test_SimulationRequestValidation.cpp:247` (`05353d5`)
- **Severity** — medium. Four tests and a suite named `SimulationCompletedAppIdTest` read as
  covering the `/ndt/simulation_completed` fix; none of them executes any of it.
- **Confidence** — verified
- **How I checked** — the test body is

  ```cpp
  const auto parsed = utils::tryParseUint64("4294967296");
  ASSERT_TRUE(parsed.has_value());
  EXPECT_GT(*parsed, static_cast<uint64_t>(std::numeric_limits<int>::max()))
      << "so the handler's INT_MAX check is what refuses it";
  ```

  The second line is `4294967296 > 2147483647` — true for any implementation of anything. The
  handler's range check lives at `src/ndt_core/http/HttpSession.cpp:1165` and is never called.
  Mutant M1, deleting `|| *parsedAppId > static_cast<uint64_t>(std::numeric_limits<int>::max())`:

  ```
  [==========] 4 tests from 1 test suite ran.
  [  PASSED  ] 4 tests.
  MUTANT SURVIVED (M1 drop the handler INT_MAX check)
  ```

  Mutant M1b goes further and reinstates the original defect verbatim — replacing the whole
  validation block with `const int appId = std::stoi(appIdText);` — then runs the **entire** suite:

  ```
  [==========] 207 tests from 28 test suites ran.
  [  PASSED  ] 207 tests.
  MUTANT SURVIVED (M1b reintroduce std::stoi for app_id (whole suite))
  ```

  So the bug `05353d5` exists to fix can come back in full with 207/207 green.
- **Failure scenario** — `{"app_id": "1abc"}` forwards the simulation result to application 1 with
  a 200 OK; `{"app_id": "abc"}` answers 500. Both are what the fix removed, and nothing fails.
- **Suggested fix** — the file's header is honest that "the handler is not directly reachable from
  a test", so the real fix is a seam, not a better assertion: lift the parse-and-range-check into a
  named function (`parseAppId(const std::string&) -> std::optional<int>`) and test that. Failing
  that, at minimum rename the test to say what it checks — it currently claims the opposite —
  and delete the tautological `EXPECT_GT`.

---

### No FlowDispatcher test fails when the lost-wakeup fix is reverted

- **File:line** — `tests/test_FlowDispatcher.cpp:98`
  (`StopReturnsRatherThanDeadlockingOnAnIdleWorker`), `d5f5bfa`
- **Severity** — medium. The lost wakeup is the fault whose symptom is "the kernel never exits",
  and it is the one of the three that has no coverage.
- **Confidence** — verified
- **How I checked** — mutant M2, moving `running_ = false` out from under `mtx_` in `stop()` and
  reverting `start()` to the unlocked one-liner, i.e. exactly the pre-`d5f5bfa` shape for that
  fault while leaving the `workers_` locking and the `enqueue` guard in place. Run against the
  named test 300 times, then against all six FlowDispatcher tests 200 times:

  ```
  exit=0  repeats=300   MUTANT SURVIVED (M2r ... StopReturnsRatherThanDeadlockingOnAnIdleWorker)
  exit=0  repeats=200   MUTANT SURVIVED (M2c ... ALL FlowDispatcher tests)
  ```

  The test enqueues once, waits for delivery, then calls `stop()` on another thread with a 10 s
  deadline. That exercises the interleaving exactly once, with no contention and nothing trying to
  land in the window between a worker's predicate evaluation and its sleep. 500 attempts produced
  zero hits.

  For contrast, the *other* two faults do have teeth. Mutant M3b reverts only `stop()`'s locking of
  `workers_` — `StopIsSafeWhileJobsAreStillArriving` hung on iteration 1 (`exit=124`, the 900 s
  timeout, `grep -c "Repeating all tests" = 1`). A fuller revert segfaulted on iteration 1. And
  `EnqueueAfterStopIsDroppedRatherThanSpawningAnUnownedThread` is a straightforward behavioural
  assertion that a removed `if (!running_) return;` would break immediately.
- **Failure scenario** — someone moves the `running_` write back out of the lock (it is
  `std::atomic<bool>`, so it looks safe, which is why the original author wrote it that way). The
  kernel hangs at shutdown, occasionally, on a machine under load. All six tests stay green.
- **Suggested fix** — unclear whether it is worth chasing, and that is the honest answer: a
  reliable regression test for this needs either a thread-sanitiser build in CI (TSan would flag
  the ordering directly) or an injected seam that parks the worker between the predicate and the
  wait. If neither is wanted, say so in the test's comment rather than letting the name imply
  coverage — the comment currently describes the interleaving as though the test reproduces it.

---

### `test_unsupported_match.py` never calls the code the fix changed

- **File:line** — `p4_proxy/tests/test_unsupported_match.py` (whole file), `c964946`
- **Severity** — medium
- **Confidence** — verified
- **How I checked** — the file imports only `unsupported_match_fields` and `UnsupportedMatchError`,
  both module-level. It never constructs a `TopologyManager` and never touches `api_routes`. Mutant
  M5 replaces all three `raise UnsupportedMatchError(bad)` statements in `route_flow`,
  `unroute_flow` and `modify_flow` with `pass` — the complete silent-narrowing behaviour the commit
  removed:

  ```
  mutated 3 sites
  Ran 9 tests in 0.000s
  OK
  ```

  (Run with a stub `networkx` on `PYTHONPATH`; see the next finding for why that was needed.)
- **Failure scenario** — the guard is removed or moved below the `ipv4_dst` extraction during a
  Phase 3 refactor. A Traffic-Engineering 5-tuple rule is once again installed as
  `10.0.0.4/32 -> port N` with a 200, covering all traffic to that destination. Nine green tests.
- **Suggested fix** — add two tests that use a `TopologyManager` with a fake client registered in
  `self.switches` and `assertRaises(UnsupportedMatchError)`, and one that drives
  `api_routes.add_flow_entry` through FastAPI's `TestClient` to assert the status is 400 and the
  body carries `fields`. The brief's own question — "does the 400 reach the caller rather than
  being swallowed" — is currently answered by nothing.

---

### `test_unsupported_match.py` cannot run on this machine at all

- **File:line** — `p4_proxy/tests/test_unsupported_match.py:26`, `c964946`
- **Severity** — medium. It is a new test file that reports FAIL, not a false pass — but
  `l1_unit_tests.sh` counts it as a failure, so it makes L1 red for a second, unrelated reason.
- **Confidence** — verified
- **How I checked**

  ```
  $ PYTHONPATH=. python3 p4_proxy/tests/test_unsupported_match.py
  ModuleNotFoundError: No module named 'networkx'      # from topology_manager.py:1

  $ for p in /usr/bin/python3 /home/adam/miniconda3/bin/python3 \
             /home/adam/p4dev-python-venv/bin/python3; do
        $p -c "import networkx"; done
  # all three: ModuleNotFoundError
  ```

  Those three are precisely the candidates `l1_unit_tests.sh:143` searches. It is also the **only**
  file under `p4_proxy/tests/` that imports `topology_manager`, so nothing else was already
  paying this cost — the import chain is new with this file. With a stub `networkx` module on the
  path the 9 tests run and pass, so the tests themselves are fine; the dependency is the problem.
- **Failure scenario** — `./run_layers.sh` L1 reports `FAIL (exit 1)` for `test_unsupported_match.py`
  on every run on this machine.
- **Suggested fix** — either `pip install networkx` into the p4dev venv and note it in
  `doc/2026-07-29_environment_gotchas.md`, or move `unsupported_match_fields` / `UnsupportedMatchError` into a
  module with no `networkx` import (they need none) and have `topology_manager` import *them*.
  The second is better: it keeps the pure validation logic testable without the graph library.

---

### `doc/2026-07-29_HANDOFF.md` §1h/§1i credit `topology_manager` with nine pre-existing tests it does not have

- **File:line** — `doc/2026-07-29_HANDOFF.md` §1h ("**事實錯誤** —— 24 + 13 + 9 個測試早就在") and §1i, both
  written in this range (`79506e4`, `fb6b95a`)
- **Severity** — low as code, medium as a record: it overturns an audit finding that was correct,
  and §1i is the table someone will consult before deciding what to test next.
- **Confidence** — verified
- **How I checked**

  ```
  $ grep -ln "topology_manager" p4_proxy/tests/*.py
  p4_proxy/tests/test_unsupported_match.py        # the new file, and nothing else

  $ grep -n "topology_manager\|TopologyManager" p4_proxy/tests/test_ryu_topology.py
  36:    A graph shaped the way TopologyManager builds one.
  39:    Both directions are added for links, mirroring TopologyManager.add_link.
                                                  # both are comments -- the documented grep trap

  $ for f in tests/test_*.py; do printf "%-32s %s\n" $f $(grep -cE '^\s+def test_' $f); done
  tests/test_kernel_notifier.py    13
  tests/test_ryu_topology.py       24
  tests/test_unsupported_match.py   9
  ```

  24 and 13 are right. The 9 is `test_unsupported_match.py`, added in this diff — it is not
  "早就在", and it tests two module-level helpers rather than the `TopologyManager` class.
- **Suggested fix** — correct the two rows: `topology_manager` had no tests before `c964946`, and
  still has none for the class itself. The audit was right about that one.

---

## Smaller test observations

These are real but low-value; recorded so they are not rediscovered.

- **`test_Controller.cpp` matches log fragments as bare substrings**
  (`tests/test_Controller.cpp:188`). `sawLineContaining({"install", "42", "99", "400", ...})` is
  satisfied by any line containing all five anywhere, so swapping `job.dpid` and `job.priority` in
  the format string would leave it green. Contrived, and everything else about this file is sound
  (see P4/checked-and-sound), but a `dpid 42` / `priority 99` fragment pair would cost nothing.
- **`RepeatsWithinOnePassCountAsOne` indexes an unchecked vector**
  (`tests/test_KeyedFailureLog.cpp:124`): `other.endPass().recovered[0].second`. If the recovery
  regressed to reporting nothing, this crashes the whole binary instead of failing one test —
  the same shape as the segfault above. `ASSERT_EQ(..., 1u)` first.
- **`test_SFlowEmitterRoundtrip` resolves fixtures relative to `$PWD`** (out of scope — not in this
  diff — but it cost me one wrong mutation result, so it is worth knowing: run the gtest binary
  from the repo root or four tests fail for the wrong reason).
