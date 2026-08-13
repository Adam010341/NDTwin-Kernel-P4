# AUDIT B — Test-script completeness

VERDICT: 6 CONFIRMED, 0 SUSPECTED

### The sFlow version guard is pinned only by "does not throw" — deleting it survives the whole suite
GRADE: CONFIRMED
WHERE: tests/test_SFlowParsing.cpp:192-200 guarding src/ndt_core/collection/FlowLinkUsageCollector.cpp:955-959
WHAT: `IgnoresUnsupportedVersion` feeds versions 0/4/6/0xFFFFFFFF and asserts only `EXPECT_NO_THROW(feed(b))`. The guard under test is a silent drop (`if (version != 5) { WARN; return; }`); the test checks neither that zero flows were extracted nor any counter, and no other suite feeds non-v5 input.
BITES/MUTATION: delete the guard (or change `!= 5` to `!= 4`): the datagrams flow into sample parsing without throwing, this test stays green, every other suite stays green (all feed v5). Fix shape: assert `getFlowInfoTable().empty()` after each feed. The `Rejects*/Ignores*` family in this file shares the shape; this is where it demonstrably fails to bite.

### The real executeSystemCommand bodies — the historical "failed action reported success" site — are outside every test's reach
GRADE: CONFIRMED
WHERE: src/ndt_core/power_management/P4PowerStrategy.cpp:28-37 and OVSPowerStrategy.cpp:14-17 (`const int rc = std::system(cmd.c_str()); if (rc != 0)`); real construction only at DeviceConfigurationAndPowerManager.cpp:56-57
WHAT: Every test in both power suites overrides `executeSystemCommand` to record instead of run, so the `std::system` + rc check — which the code's own comments identify as the exact site of the old failed-looks-like-success bug — never executes under test. The 9afd647 mutations all sit in powerOn/powerOff, none in this function.
BITES/MUTATION: change `if (rc != 0)` to `if (false)` in either strategy: zero tests go red. Closing it needs one test per strategy running the real seam against `/bin/false` and `/bin/true`.

### emitted_multi.bin has no drift guard, and the generator's docstring claims otherwise
GRADE: CONFIRMED
WHERE: p4_proxy/tests/generate_emitted_fixtures.py:16-17 (claim) vs :130-139 (multi built in main(), outside gen.FIXTURES); guard loop test_sflow_emitter.py:585 iterates only gen.FIXTURES; sole consumer tests/test_SFlowEmitterRoundtrip.cpp:244
WHAT: The docstring: "test_sflow_emitter.py::CommittedFixtureTest fails if they drift, so a forgotten regeneration is caught rather than leaving the C++ test validating a stale layout." True for the six single-sample fixtures, false for `emitted_multi.bin` — the one carrying the parser's only multi-sample-chain coverage.
BITES/MUTATION: reorder samples in build_datagram (bytes change only for len>1): CommittedFixtureTest green, MultiSampleTest green (checks count/type/chain only), C++ WalksEverySample green on the stale committed bytes. Nothing reddens; the C++ test silently validates July's layout. (Theme-A cross-ref: the docstring itself is a false claim — filed here.)

### l1 header claims Python-skip parity with gtest; a partially-skipped Python suite passes green
GRADE: CONFIRMED
WHERE: tools/test_workflow/l1_unit_tests.sh:27-28 (claim) vs :203-204 (behavior); gtest counterpart :118-122
WHAT: "A skipped Python test is treated the same way as a skipped gtest one -- reported, not counted as a pass" — but the all-skipped FAIL branch fires only when skipped == ran; a strict subset of skips prints `PASS N ran, M skipped`, exit 0, even when a P4-capable interpreter exists and there is no environmental excuse. The same condition on the gtest side is a hard FAIL.
BITES/MUTATION: give any gRPC-dependent test in test_switch_state.py an `except ImportError: raise unittest.SkipTest` guard that starts triggering: l1 and CI stay green while the suite asserts less than it did yesterday.

### The mutation-verified relay-response tests pin a function only dead code calls
GRADE: CONFIRMED
WHERE: tests/test_RelayResponse.cpp over interpretRelayResponse, whose only caller is DeviceConfigurationAndPowerManager.cpp:826 — inside the 3-arg setSwitchPowerState (:808) that has zero call sites
WHAT: grep: `interpretRelayResponse` is called exactly once, from the overload nothing calls (both live callers use the 2-arg path — see AUDIT_D "live TESTBED power path"). The suite can never fail for a reason production would notice.
BITES/MUTATION: break the live `setPowerStateTestbed` (:1384-1396) any way you like — return `rc == 0` is already the bug — and every relay test stays green, because they test the fixed twin of the broken function.

### WIP test_readopt.py: the failure-step test asserts the key exists, never its value
GRADE: CONFIRMED (file is the other session's WIP, untracked at audit time)
WHERE: p4_proxy/tests/test_readopt.py:267-272 (`self.assertIn("step", result)`); the endpoint test that does check a value (:357-362) feeds a canned sentinel dict
WHAT: The test's own comment quotes the requirement — "report how far it got, and which step failed" — then asserts only key presence; the real readopt_switch's step labels are pinned nowhere.
BITES/MUTATION: label every failure `"step": "start"`: both tests stay green and the kernel log line the comment says this exists for reports the wrong step. Fix shape: `assertEqual(result["step"], "pipeline")`.

---

Golden-fixture provenance (the brief's explicit question): the emitted fixtures, both round-trip suites, and 36 lines of the parser under test landed in one commit (c3a1317) — a two-sided error mirrored in emitter and parser would have passed then. Mitigations verified: the OVS capture fixtures and test_GoldenFixture predate it in test-only commits (2d46e02, 74ef1d2), and the roundtrip expectations anchor to struct.pack frame layouts, not parser output. The remaining live exposure is exactly the unguarded emitted_multi.bin above.

Adjudicated clean (orchestrator's first-hand checks where stated):

- **tools/test_workflow/l1_unit_tests.sh** — read end to end. It does detect the traps this theme hunts: a gtest binary that ran zero tests FAILs (:123-125); any gtest skip FAILs (:118-122); a Python file whose tests all skipped FAILs unless it declares NDTWIN_L1_OPT_IN or no P4Runtime interpreter exists (:175-202, the "PROVED NOTHING" branch is deliberate, documented policy); kernel-side tests/python + tests/shell treat any skip as failure (:269-275) and zero-ran as failure (:276-278). Failure counts aggregate across every suite (FAILURES), not just the last.
- **Registration**: every tests/test_*.cpp on disk is named in tests/CMakeLists.txt (checked file-by-file); all 34 compile into the single test_routing_strategy binary, so none can silently not-build. Residual structural gap: nothing cross-checks *future* sources-on-disk against the CMake list, and the ctest-vs-gtest count mismatch check (:294-298) only warns — but today, zero orphans exist.
- **tests/test_LoggerEnvironment.cpp** — zero TEST macros is by design: it is a shared ::testing::Environment TU linked as a direct source into the one test binary (registration at :52 cannot be linker-dropped in this configuration). Its "runs in every process before any test" claim is true as built.
- **p4_proxy/tests/test_p4_client_writes.py** — the fbd8140 fix is real in the current tree: WriteDeadlineTest sits at :805, before unittest.main at :841.
- **tests/test_P4PowerStrategy.cpp** (committed as 9afd647 during this audit) — read end to end and executed: 8/8 green via `./build/bin/test_routing_strategy --gtest_filter='P4PowerStrategyTest.*'`. The suite tests real seams (a real TopologyAndFlowMonitor over a hand-built graph; only executeSystemCommand faked) and its assertions bite: inverting the isUp guard, dropping the setVertexUp/Down calls, swapping the 500/502 statuses, dropping curl's -f, or reordering helper/readopt each has a named assertion that goes red. The other session's commit message documents 11 replayable mutations.
- **Audit-process note**: during this verification the orchestrator briefly "remembered" a setVertexDown call inside powerOff's failure branch that does not exist (fresh grep + git show + the 8/8 run disproved it). Recorded here because it is this theme's core lesson in the other direction: the test suite was good and the reader was wrong, and only executing it settled the question.

Read: every cited line re-opened by the orchestrator at adjudication time (grep/sed against the current tree, or `git show HEAD:` for files inside the concurrent mutation window); full end-to-end file coverage per area by the five audit passes — their complete file lists are consolidated at the end of AUDIT_A_hallucinations.md.
