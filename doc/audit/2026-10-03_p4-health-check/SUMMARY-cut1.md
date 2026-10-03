# P4 health check, Cut 0 + Cut 1: summary
[Co-developed with claude code -- Adam]

Branch `feat/p4-health-cut1` from trunk 995bdfd0. Worktree: scratch/overnight-2026-09-05/wt-p4-health-cut1.

- **Nothing touched the lab:** no `ndt up`/`claim`, no Mininet, no sudo, no C++ build, no push.
- **Only bmv2 run:** a stock `simple_switch` in pcap mode, argv[0] `ndt-hc-selfcheck-bmv2`, Thrift port 29500-29599. The drop check runs its own `ndt-hbdrop-bmv2`.
- **LOG** = scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut1/

## 1. OBSERVED

**S0** (`LOG/s0-final/probe.log`, run at e7300c06, probe tree b6b4688a, rc 0, 41/41 ok, `S0 COMPLETE`)

Six builds, each under `nice -n 19`, one at a time. p4c is 1.2.5.15, binary sha256[:16] `226f3f66df515c9e`. Values are sha256[:16]:

| build | json | p4info |
|---|---|---|
| build/hc_main | 72d5a8b6b1304c59 | 5ce0a5595d5a65f1 |
| build/hc_alt (-DHC_ALT) | 1b457cef29221482 | b7490e9eb9979888 |
| build-mutant/hc_main (NO_COUNT, NO_TTL, NO_QSTAMP) | 33b31bc78eb30770 | 5ce0a5595d5a65f1 |
| build-mutant/hc_alt | 5c2e57a938455281 | b7490e9eb9979888 |
| build-fwd/hc_main (FWD_88B5) | 78829f68fdf2c3eb | 5ce0a5595d5a65f1 |
| build-fwd/hc_alt | 21ae1e3c7e5c19a1 | b7490e9eb9979888 |

- **Program:**
  - Each mutant's and FWD's p4info equals its plain build's (§12 item 5).
  - hc_alt adds exactly one object: `HcIngress.alt_port_stamp`.
  - Both programs contain all 29 inventoried constructs, including action profile/selector, idle timeout, value_set, recirculate, resubmit, hash, random, header_union and varbit. So everything compiles together; no split was needed.
- **Packages:**
  - Pre-flight passes for A, B and C with 0 FAIL rows.
  - PF-T is rc 1, and its only FAIL row is "entries match p4info: 1 problem … TERNARY match -- G5 not done".
  - Drop check: A, B and C rc 0, FWD rc 1.
- **Throwaway self-checks:**
  - main (s2 entries) and alt (s1 entries): all 7 self-checks ok.
  - mutant: exactly SC-count, SC-qstamp and SC-ttl fail.
  - The entries were installed 0.28-0.30 s after launch; bmv2 waits 8 s before reading its input.
- **Probes on the throwaway:**
  - With every entry installed, 0 heartbeat (0x88B5) frames left the switch.
  - Custom headers are parsed and forwarded: tunnel, 0x1236, 0x1238, source route, VLAN, the shim between IPv4 and UDP, the varbit tail, and the shim after L4.
  - Punt carries packet_in. Clone gives 2 copies on p1. The id=1 control is not stamped. Every IPv4 checksum is valid.
  - Multicast group 1 goes to {1, 2}. Hash and random each use both uplinks {4, 5}.
  - bmv2 holds a ternary entry.
- **openapi**, read in-process over raw ASGI: 200, 15 paths, openapi_url `/openapi.json`. `main.py:38` passes only title and description.
- **PF-T**: RED, phase cannot, attribution structural + bmv2|static, ok.

**Tests and gates**

| check | result | log |
|---|---|---|
| test_p4_health_cells.py | Ran 62, OK (py3.8.20 and py3.13) | l1sim_test_p4_health_cells.log |
| test_p4_health_collect.py | Ran 36, OK; seal checked 36 tests: tripwire 0, lab ports 0, spawns 0 | test_collect.hermetic.log, seal_report.green.json |
| non-hermetic H1 (real Runner) | FAIL test_the_oracle_is_thrifts_and_never_the_proxys: "a fail-loud stub was run: simple_switch_CLI --thrift-port 9092" | test_collect.nonhermetic.H1.log, seal_report.H1.json |
| non-hermetic H2 (own HTTP client) | 2 tests red: "a lab port was dialled", ('localhost', 8081) | test_collect.nonhermetic.H2.log, seal_report.H2.json |
| test_p4_health_recover.sh | Ran 17 checks, 0 failed | l1sim_test_p4_health_recover.log |
| mutate_p4_health.sh | 52 mutations, 0 survived; comment-only control green; original byte-identical | mutate_p4_health.try2.log |
| first gate run | 2 survived (12-1, D7); see §3 rows 11-12 | mutate_p4_health.try1.log |
| check_test_tmpdirs --repo . | 412 files, 0 fixed temp paths | check_test_tmpdirs.log |
| check_gate_anchors HEAD --gates mutate_p4_health.sh | ok(53) | check_gate_anchors.p4_health.log |
| check_gate_anchors HEAD | 132/132 ok | check_gate_anchors.all.log |
| test_l1_shell_scoring.sh | Ran 163 checks, 0 failed | test_l1_shell_scoring.log |
| L1 lane's own shell_summary / l1_lane_verdict | PASS on all 3 new files | l1_lane_sim.log (script: l1_lane_sim.sh) |
| disk | 4086 MB at start, 3960 MB at end; no ndt-hc-* or ndt-hbdrop* processes left | — |

**Facts S0 surfaced that the design does not record**
1. `pvs_add` through simple_switch_CLI aborts the stock bmv2: `parser.cpp:535`, assertion `new_v.size()==width`, with both 40055 and 0x9c97. A read-only `pvs_get` on an empty set did not. Tried only on the throwaway.
2. bmv2 dumps an optional match as `TERNARY … &&& ff` (fixture table_dump_optional.txt).
3. A clone session made with thrift `mirroring_add 7 1` reads `port=1, mgid=None`. The P4Runtime route makes mgid 0x8000+7. The parser accepts both shapes.
4. simple_switch_CLI's shebang python3 has no thrift module. `Config.thrift_cli` therefore defaults to the p4dev-venv python running /usr/local/bin/simple_switch_CLI.
5. Interpreters: PY_KERNEL is ryu-env Python 3.8.20, so tools/p4_health is written to be 3.8-compatible. Neither interpreter has fastapi plus httpx, so no TestClient is available.

## 2. INFERRED
1. **Proxy routes.** openapi_probe builds the app from main.py:38's kwargs plus api_routes.router (main.py:181) rather than importing main.py, which has import-time side effects. "No other routes" rests on grep: main.py has only `@app.on_event` (:2441, :2446).
2. **PF-T's RED.** It uses §2.1's "bmv2 or static": a stock bmv2 accepted and dumped the ternary entry over thrift. Whether the P4Runtime path behaves the same is a question for Cut 2's controller B.
3. **Q3(b) predictions** are read-code only: RC1, HR1, HR2 GREEN; HU1 PARTIAL(a).
4. **Rollups computed from the predictions** (a test asserts the first two): core 10/3/3/0, full over 16 keys 6/7/3/0, both matching DESIGN §5.1. Full over 22 keys is 8/8/6/0.
5. **Q1 needs live.** pcap mode always reads qdepth 0, so S0 proves only that the stamp flag is set.

## 3. Design points: where I could not follow the design literally, and what I did
1. **Test location.** The design put tests in tools/p4_health/tests (§5.2). They are in tests/python/test_p4_health_{cells,collect}.py and tests/shell/test_p4_health_recover.sh, matching the L1 glob (`l1_unit_tests.sh:589`).
2. **expected_today.tsv** is in doc/audit/2026-10-03_p4-health-check/, as the ticket says, not in tools/p4_health (§4.1).
3. **TestClient.** It is unavailable, so the fakes are in-process `FakeHttp` objects carried by Config (§12 item 9), and openapi is verified over raw ASGI in tools/p4_health/openapi_probe.py.
4. **T7.** "NOT RUN while T4 is red" conflicts with step 1 of the decision order. T7 therefore has no cannot step, only a gate on T4.
5. **K1's 503** is not in step 1's list, so it is judged RED at step 5 (`counter_reading`). Fixture: test_k1_503_is_not_a_zero.
6. **§12 item 8 (P4), decided:** packet-in received → PARTIAL(b); nothing received → RED, attributed to bmv2 only when B's controller is primary and its own writes work.
7. **§12 item 1 (SC-count):** compare with netdev when it is known. Otherwise, loss on the path → not judged (NOT RUN, and its dependants NOT RUN). Commit 2300cba7.
8. **CS1** is named a gate but no r6 dependency edge uses it. I followed the edge list; the table is row-driven, so adding an edge is one line.
9. **The `ndt status --measuring` check** lives in `lab_round.check_lab()`/`lab_busy()`, tested offline. S0 never calls ndt.
10. **telemetry.source=link:** convert has no flag for it, so S0 writes it into package.json after converting.
11. **Gate survivor 12-1:** SC-count's semantics were wrong; fixed as in row 7.
12. **Gate survivor D7:** the "Could not connect" guard was dead code behind the no-prompt check. I removed it and retargeted D7 at the no-prompt check.
13. **Package B:** `--mode external` needs a mycontroller.py (`convert.py:516-521`). `exercise/mycontroller.py` is a stub that exits 2 ("Cut 2").
14. **Run dir:** root `.gitignore:5` ignores every .gitignore, so the package cannot carry its own. `run.sh` defaults to .test_run/p4_health/<UTC>_p4_health/ (ignored by `.gitignore:21`).
15. **netem delete** uses the grant's own form, `del dev X root` (`faults.sh:54-56`).
16. **recover.sh** reads the claim file .test_run/lab.claim (`ndt:290-330`) instead of parsing `ndt status`. Its path is recorded in LAB_STATE.json.
17. **VB1** is NOT RUN by design, with the reason given in the cell and in §13.
18. **Beyond the design (S0 probes):** with all of A's entries on s1 and s2 installed, no 0x88B5 frame left the throwaway switch. This does not cover entries B's controller installs later.

## 4. Design item → file → test
| design item | file | test / log |
|---|---|---|
| Cut 0 predictions | doc/audit/…/expected_today.tsv (59 rows) | TestExpectedFile |
| §3 program and its variants | tools/p4_health/exercise/src/hc_main.p4 | S0 compile, inventory and p4info checks; test_the_dports_are_the_programs; test_the_heartbeat_drop_is_the_first_statement_of_ingress |
| §2.2 topology and runtime files | exercise/gen_runtime.py and its JSON output | test_the_committed_exercise_files_are_the_generators; S0 convert and pre-flight |
| §2.1 decision order, attribution, negative reads | cells/verdict.py | TestEveryCellHasItsFixtures, TestStaticCells, TestNamedFixtures |
| rule D | verdict.gate_problem / judge_all | TestRuleD, test_rule_d_edges_are_the_designs |
| expected refusals | table.cp2, Control | test_cp2s_409…, test_k1_neg_and_t3_neg_404_pass |
| self-checks (5 + 2) | table.SELF_CHECKS | TestSelfChecks; S0 throwaway runs |
| 47 cells + 9 Q3(b) cells | cells/table.py | test_counts (34/13/9; A 40, B 5, C 1, S0 1) |
| rollup | verdict.rollup | TestRollup |
| telemetry-none | verdict.telemetry_none_check | test_telemetry_none_… |
| Runner / Config | collect/runner.py, collect/config.py | TestThriftParsers, TestWhereTheNumbersComeFrom, TestConfig |
| reading layer | collect/*.py, observe.py | 28 real thrift fixtures; TestSmallOracles |
| §4.2/§4.5 lifecycle (offline) | lab_round.py | TestLabRound (17 tests) |
| recover.sh | tools/p4_health/recover.sh | tests/shell/test_p4_health_recover.sh |
| S0 | s0.py, throwaway.py, runtime_cli.py, frames.py, openapi_probe.py | LOG/s0-final; TestS0Pieces |
| §5.2-③ mutation gate | tests/shell/mutate_p4_health.sh | mutate_p4_health.try2.log |
| §12 items 1-12 | sc_count, sc_reg, sc_qstamp, hops_from_lpm, S0 p4info check, CH7 fixture, K3 dependency, p4(), the seal, teardown/run, recover.sh | fixtures plus gate mutations 12-x |

Gaps:
- report.py and `probe.py judge` have no fixture test yet; due in Cut 2.
- Observers exist only for K1/K3, M1, PL1 and routes; the rest are Cuts 2-4.

Gate coverage, each with its "also red" line in the log:
- M1-M18, with M17 split into a and b
- 12-1, 12-2, 12-3, 12-4, 12-7, 12-8, 12-10a, 12-10b, 12-12
- D1-D12
- Q3b-1 to Q3b-8
- H1, H2 (non-hermetic)
- R1, R2 (recover.sh)

## 5. Done-check → log
1. Mutants red, control green, copy-style: mutate_p4_health.try2.log — "52 mutations, 0 survived", "green: the suites do not react to a comment", "byte-identical tools/p4_health".
2. Hermetic: test_collect.hermetic.log plus seal_report.green.json (all-empty lists); non-hermetic red: test_collect.nonhermetic.H1.log and H2.log.
3. S0: s0-final/probe.log lines 24-27 (drop check), 28-39 (self-checks, mutant fails exactly three), 8-11 (p4info).
4. Repo checks: check_test_tmpdirs.log, check_gate_anchors.*.log, test_l1_shell_scoring.log.
5. Disk 3960 MB free. My scratchpad trial directories are deleted; no ndt-hc-* or p4h-* left in /tmp; LOG/s0-final (5 MB) is kept as evidence.

## 6. Files
- No existing file was changed; nothing outside my paths was touched.
- l1_unit_tests.sh is unchanged: its glob picks up the new tests, and check_gate_anchors finds the new gate.
- New files: tools/p4_health/**; tests/python/test_p4_health_{cells,collect}.py; tests/python/fixtures/p4_health/**; tests/shell/{test_p4_health_recover,mutate_p4_health}.sh; doc/audit/2026-10-03_p4-health-check/{DESIGN.md, expected_today.tsv}.
