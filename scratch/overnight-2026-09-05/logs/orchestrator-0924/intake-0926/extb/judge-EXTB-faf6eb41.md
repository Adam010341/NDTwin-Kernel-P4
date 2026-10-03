# Audit of feat/external-detect-only-0927, rounds 3–4 (head faf6eb41)

## Verdict: MERGE AFTER FIXES

The product code is sound and well tested. This covers the proxy's "no guessed paths" change (item a), the offline drop check (item b) and how ndt calls it. All 27 gates are sound evidence for faf6eb41.

What still blocks the merge is the merge gate itself. The pre-registered live comparison (procedure a) cannot be run as written:
- It produces an H5 FAIL line on every run that its rules never mention.
- It does not secure the local merge it depends on.
- It can still pass when the heartbeat sent no frames at all.

Separately, the drop-check mutation gate launched throwaway switches that break the orchestrator's own conditions. Trunk has also moved (m4 must be redone). Fix M-1..M-5 before the live run.

How I checked: read-only. No commands run, no git. I read the SUMMARY (all of it), INTAKE, both earlier judge reports, the patch, the files at faf6eb41, every `*.extb4*-faf6eb41.log`, the frozen drivers and both shim logs (tripwire logs).

Path prefixes used below:
- WT = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927
- LP = WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
- LOGS = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
- SUM = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/EXTERNAL-DETECT-ONLY-SUMMARY.md
- INTAKE = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/extb/INTAKE.md
- PATCH = the diff-r3r4-14921f98..faf6eb41.patch file in the same directory as INTAKE
- HDC = WT/tools/test_workflow/heartbeat_drop_check.py
- EV = LP/external_evidence.py

## Q1. Round 2's fix list

**M1 (executable procedure) — PARTLY.**
- Done:
  - Trees named and no root step needed (LP/README.md:380-382).
  - Controls C1/C2 on trunk (:384-397).
  - Only one kind of treatment (:399-407).
  - Decision rule written (:414-442).
  - The end-of-arm switch_state check removed (:440-442).
- Broken:
  - C1 is `ONLY=p4runtime,flowcache`, which gives 4 arms (LP/06_thirteen.sh:77-82, 188-191).
  - The procedure then sets `OLD_06=<C1>` (README:399-401; LP/08_heartbeat.sh:58-64).
  - `v_same_06` returns BAD for any reference that is not 26 arms (08:631-634), and `judge` turns that into `fail` (08:724-730, 2333).
  - So every treatment run ends `FAIL 08_heartbeat -- H5 06 against <C1>: the reference table has 4 arms, not 26`. That contradicts README:282 and is not covered by README:432-434.
  - The local merge into the shared main checkout (README:398) has no push freeze, no rollback, and no check that T's merge parent is C1/C2's HEAD.
  - README:380 says the main checkout is the tree /etc/ndtwin-lab.conf names. That file does not exist; ndt falls back to its built-in default (ndt:1409, 1479-1494). The conclusion still holds.

**M2 (compare cannot be fooled) — DONE.**
- Refuses without `--samples` or `--control2`, and refuses duplicate controls or a treatment that is also a control (EV:506-518).
- Requires the session to be running across the arm window: refuses never-sampled, STALE (written_wall), stop_reason, gaps, restarts, a stop before the controller's last write, and any other session (EV:383-418).
- The sampler records written_wall and stop_reason (08:854-873).
- The N4 counters are relabelled as pre-pipeline (EV:497-498).
- Controls with any heartbeat trace are refused (EV:421-429).
- Red at base: LOGS/redfirst_b3.extb4-faf6eb41.log:31-49. Killed by E33–E44.
- Residual: daemon counters missing from a sample read as 0 (EV:362-367). Frames heard are not checked (new defect 3).

**M3 (rc 130/143, the `_common.sh` window) — DONE.**
- Code: LP/_common.sh:312, 321-334, 348; 08:814.
- Pinned: self-test 08:2131-2147 (selftest_08 log:148-149) and test_live_p1_common §19.
- Red at base: redfirst_b3:13-14, 20.

**S1 — DONE as asked, but the replacement sentence is contradicted by its own source** (new defect 6).

**S2 — PARTLY.**
- Invariants are now judged against every control (EV:558-566), and the last counter block must have settled (EV:265-278).
- But the OLD_06=C1 guidance is the M1 defect above.

**S3 — DONE** (ndt:7134-7141; revised again in round 4).

**S4 — DONE** (README:435-439).

**m1 — DONE** (EV:151-154; suite cell at test:418-420; E42).

**m2 — DONE** (WT/p4_proxy/proxy_agent/main.py:1856-1860).

**m3 — DONE.**
- The up-told BAD, only-table_generation and restore 19.9 / 20.5 s cells (selftest_08 log:72-75).
- E45 (the counters branch of `within()`), and E34/E46/E47.
- The 03/04 consumer pins (redfirst_b3:21-22).
- Coverage 103/103 (LOGS/mutate_live_p1_external_evidence.extb4-faf6eb41.log:77-78).

**m4 — DONE for faf6eb41, now stale.** Trunk is at d452d111. INTAKE:63-64 itself says a full rerun is needed after merging it.

## Q2. Round 4 (only §R3.10 holds the plan; §R3.9 is now round 3's reboot procedure)

**(a) No guessed destination paths — implemented as specified, and seen red.**
- Code:
  - Flag set only in the external-plus-foreign branch (main.py:2284-2288).
  - Pull returns `[]` (api_routes.py:344-345).
  - Push returns False and prints why (topology_manager.py:2212-2219).
  - Default False (:547, :712).
  - Texts updated (ndt:4113-4118 and 7137-7138; README:369-372).
- Red at base: exactly 5 proxy tests, 3 of them the path cells (LOGS/redfirst_b4.extb4-faf6eb41.log:13). The status row: 2 cells (:18).
- Killed: X11–X14 at their named tests (mutate_p4_heartbeat_w.extb4:106-110); M28b (mutate_ndt_app_package.extb4r:307).
- Nit: the external status row says "none expected" but never flags a nonzero count. After (a), a nonzero count there would mean the guess came back.

**(b) Heartbeat only after the offline drop check — implemented, and seen red, with deviations:**
1. Uses the stock build of the same bmv2 commit, not the fabric's binary. Disclosed, but the versions are not compared at run time.
2. The plan said switch_state's heartbeat block would carry not_started and the reason. It does not; the reason appears only in `ndt up`, `ndt status` and the withheld file. Disclosed in §R4.5 as a limitation, not as a plan deviation.
3. The check runs earlier than planned (package pre-flight, ndt:3327-3332). That is better than the plan.

Evidence:
- The three tutorial programs DROPPED; the flood, punt, digest, clone and multicast fixtures NOT_DROPPED (LOGS/test_heartbeat_drop_check.extb4-faf6eb41.log:17-42).
- ndt wiring red at base: 16 cells (redfirst_b4:20). N40–N55 killed at named checks (mutate_p4_heartbeat_w.extb4:150-167).
- Checker cells: the no-tool red-first is degenerate (FileNotFoundError, redfirst_b4:26). It is compensated by 39 mutations / 0 survived and 61/61 non-control cells seen red (mutate_heartbeat_drop_check.extb4r:55-56).
- D1, D2, D3 are red on their named cells, but D2 and D3 only on the synthetic judge cells. The end-to-end punt and flood fixtures stay NOT_DROPPED through the pcap check. That is the intended design.
- Not end to end: every ndt suite stubs `hb_drop_check_run` (WT/tests/shell/test_ndt_heartbeat.sh:186-194; WT/tests/shell/test_ndt_app_package.sh:239). No test runs ndt → the real checker → bmv2.

## Q3. The orchestrator's two rulings

**Ruling 1 — done.** The 5 lines are README:24, 380, 394-396 (PATCH:6946, 7031, 7045-7047).

Outside that ruling, two shipping (non-.md) files also gained `/home/adam`: WT/tests/fixtures/heartbeat_drop/README (PATCH:313) and flowcache_solution.json. These reach main. The orchestrator should rule on them.

**Ruling 2, condition by condition:**

| Condition | Code | Tested | Notes |
|---|---|---|---|
| No root | runs as caller | uid cell (exempt control) | PARTLY: not enforced. HDC has no euid-0 refusal, ndt does not refuse root, and README:16 allows sudo. |
| Own TMPDIR for ipc and pcaps | mkdtemp; `ipc://notif.ipc` relative (HDC:253-259, 432) | test:367-368; D17 | — |
| Thrift port free right before start, outside the lab's | HDC:93-97, 193-214, 443-445 | ports.sh pinned (test:274-311); D14, D14b, D15, D15b | D14 launched nothing: no candidate passes the lab-range filter. |
| Device id unique | 900000 + pid % 90000 (HDC:440) | > 512 cell; D18 | Unique against fabrics. |
| Killed by exact pid in a trap | Popen pid TERM then KILL, `finally`, PDEATHSIG (HDC:280-291, 480-483, 231-236) | D19, D20 | The SIGTERM/SIGINT/SIGHUP handlers in `main()` (HDC:559-568) are never executed by any test. |
| Logged in the tripwire | wrapper (LOGS/scripts-extb4-faf6eb41/gates_b4.sh:38-46) | — | Only launches that pass through the wrapper are visible. |
| Not counted or reaped by ndt's by-name or orphan logic | — | while the switch runs (test:313-366): bmv2_count by comm (ndt:109-114), the helper's sweep_matches (WT/tools/test_workflow/ndtwin-lab:424-432), p4_testbed_topo's identity rule, the kernel scan rule (WT/src/ndt_core/http/OpenflowCapacityReport.cpp:54-59) | DONE at unit level. |
| No collision with the fabric it brings up | — | composition only: stub ordering (test_ndt_heartbeat.sh:313-314) plus "stopped by the time the check returns" | PARTLY. |

**The gate itself broke these conditions.**
- D16, D16b, D17 and D18 (WT/tests/shell/mutate_heartbeat_drop_check.sh:188-204) launched 64 throwaway switches outside the conditions:
  - 16 with argv[0] `simple_switch`;
  - 16 with argv[0] `/usr/local/bmv2-fast/bin/simple_switch_grpc` (e.g. LOGS/scripts-extb4r-faf6eb41/tripwire.log:903). These match the helper's sweep (ndtwin-lab:1713, 1829) and the kernel's scan;
  - 16 with the default /tmp notifications socket;
  - 16 with device id 1.
- The tripwire accepts every ALLOWED-LAUNCH line unchecked (LOGS/scripts-extb4r-faf6eb41/gates_b4r.sh:92-93).
- Its "still running" check matches only argv[0] `ndt-hbdrop-bmv2` (gates_b4r.sh:97-100), so it is blind to those 32 switch-named launches.

## Q4. The gate evidence

- **The count is 27, not 26.**
  - 22 extb4 gates plus 5 extb4r gates.
  - Every one has `faf6eb41…` as its first line and `# rc=0` as its last.
  - Labelled non-results: mutate_app_package.extb4 (`# rc=aborted`) and redfirst_b.extb4-89615935 (`# rc=stopped`).
  - The count is misstated in three places:
    - the SUMMARY says "跑完的 21 個" (21 completed, SUM:94) but lists 22;
    - gates_b4r.sh says "21 gates" in its header and "22 run lines removed" a line later (:2-6);
    - INTAKE:62 says "21 … all 26".
- **Numbers I re-derived:**
  - proxy_unit 1733 + 1 skipped (I summed proxy_unit.extb4:11-56).
  - Suites 88, 399, 424, 55, 112, 220, 45, 103 and 67, each with 0 failed.
  - Mutation gates: 256/0, 59/0, 12/0, 61/0, 179/0, 48/0, 77/0 and 39/0. Anchors 128/128.
- **The 1585 "allowed launches"** are 625 switch launches plus 960 `--version` probes.
  - All of them came from mutate_heartbeat_drop_check (tripwire timestamps 09:45:12Z to 09:50:01Z).
  - "0 left running" covers only argv[0] `ndt-hbdrop-bmv2`.
- **The extb4 shim log was never checked by a gate.**
  - I recounted it: 2115 lines = 2075 curl `file://` lines + 40 ALLOWED-LAUNCH (16 switches, 24 probes), and no lab command.
  - Whether its 16 switches were all gone at the end was never checked, and cannot be now.
- **Anomalies:**
  - D10's suite run ended in an uncaught `ProcessLookupError` (mutate_heartbeat_drop_check.extb4r:24). The trip log shows that run reached the SIGKILL probe (tripwire.log:467-472). The cause cannot be recovered because the gate deletes each mutant's output (`$BK`). D10 still counts as caught: its named cell had already failed.
  - In the gate, the SIGKILL probe kills the wrapper before it ever executes simple_switch. No probe launch is ever logged: extb4 shows 16 switch launches for 17 launching calls.
  - D14 is red only because no switch was launched (41 cells failed).
  - Four directories left behind by D21 sit in LOGS/extb4r-1001/tmp/ndt-hbdrop-* (clhl5hf3, 035ber3a, j8lycb1y, xylo4dps).
- **Vacuity:** the red-first "suite fails without the tool" proves nothing by itself; the 61/61 coverage is what counts.

## Q5. Is the live comparison executable, and what must it show?

**Not as written.** Defects 1 and 2 below both have to be fixed first.

For B to be accepted, the live run must show:
1. **Same code apart from B.** C1, C2 (and C3, C4 if needed) and T run on the same trunk sha. T's merge parent is that sha, the uncommitted-file set is identical and touches nothing B touches, and the kernel/bmv2 binaries and `00_venv.txt` are identical.
2. **H5's own checks pass.** "where the heartbeat ran" is OK: the heartbeat ran on exactly the 20 expected arms, which includes the 3 external arms and so proves the drop check passed live. There is no ruling-4 STOP.
3. **Each external arm shows the treatment was on:** the drop-check line "every program drops its frame", the detect-only line, and a `heartbeat running` row.
4. **compare returns rc 0:**
   - every compared key is the same or inside the controls' spread;
   - every invariant holds, or is broken in a control too;
   - each external arm's session ran across the arm and stopped after the controller's last write;
   - its four daemon counters stayed 0;
   - no 0x88B5 packet-in.
5. **(Missing today) frames were heard** on every direction during each external arm's controller lifetime.
6. **H1–H4 run once.** If H4 fails only on `reported_to_kernel`, that is a kernel finding, not a failure of the comparison.

What a live run can still get wrong:
- The guaranteed H5 FAIL line (defect 1).
- Trunk moving between C and T in the shared worktree, or a routine trunk push publishing the unreviewed merge.
- The detect-only line falling past drive_exercise's 6000-character trim (WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py:501-506, 3127). The check adds a line ahead of it. If it falls off, compare refuses with rc 3 every time, which the README treats as "procedure not followed".
- The real checker running for the first time ever inside `ndt up`. If it crashes it exits rc 1, which ndt reports as "does NOT drop"; the heartbeat is then withheld and T is invalid.
- `heartbeat_drop_check.log` being overwritten by each arm (ndt:2989-2991), so README:430-431's "report that arm's output" can be impossible.
- 08 dying (rc 2) if the installed helper differs from the checkout's copy (08:2304-2306).
- Noise: with 4 controls, a continuous noisy field still lands outside their range with probability 2/5 when B has no effect.
- The arm sequence differs between C (4 arms, run first) and T (26 arms, external arms late).
- TERM sent to 08 is deferred while 06 is running.
- A daemon that runs but whose frames are never heard still passes.

## New defects, by severity

1. **MAJOR — H5 FAIL on every run.** OLD_06=<C1>, with C1 restricted to 4 arms, guarantees `BAD … 4 arms, not 26` and an 08 FAIL, which the pre-registered rules do not cover.
2. **MAJOR — the local merge is unprotected.** No push freeze, no rollback, and no check that T's code is C's code plus B. The tool prints code identities but never compares them (EV:482-487).
3. **MODERATE — the treatment can still be vacuous.** No check that heartbeat frames were heard during the external arms. The daemon records per-direction `heard` (ndtwin-lab:1121, 1131-1134), but the sampler drops it (08:870-873). Round 1's judge §5.1 asked for this check.
4. **MODERATE — the gate's mutants D16/D16b/D17/D18 broke the ruling's conditions,** and the tripwire cannot see it (Q3).
5. **MODERATE — the limit statement is incomplete.** LIMITS (HDC:104-106) do not say the check covers only the package's declared program. A pipeline the external controller pushes itself (SetForwardingPipelineConfig), or a default action it changes at runtime, is not covered.
6. **MINOR — the S1 sentence is contradicted by its source.** "No pipeline was loaded / 空的交換機 (empty switches)" (main.py:1367-1368; README:350-352) is contradicted by the file it cites. WT/doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh:63-65 says "their pipelines meet the heartbeat with the package's entries only". The bring-up code also loads the package's JSON (WT/p4_proxy/mininet/p4_testbed_topo.py:354-358, 217-218). N4's FAILED_PRECONDITION is what P4Runtime reports without a p4info; it does not mean the data plane is empty. Not verified live.
7. **MINOR — checker robustness.**
   - rc 1 collides with Python's uncaught-exception exit code.
   - No euid-0 refusal.
   - Never executed or mutated: `main()`, `settled()` / "did not settle", the `NDT_HB_CHECK_BMV2` override, the CPU port in `attached` (HDC:249).
   - An empty port set gives a vacuous DROPPED.
   - The injected frames are in the daemon's layout but not its field values: rx_dpid 0 and a synthetic MAC and session (HDC:118-126, 251). The byte-for-byte pin only holds for the arguments the test passes (test:140-143).
8. **MINOR —** switch_state does not carry the withheld reason (a plan deviation).
9. **MINOR —** WT/tests/shell/test_heartbeat_drop_check.py runs in no automated runner. WT/tools/test_workflow/l1_unit_tests.sh:584 only picks up `tests/shell/test_*.sh` and `tests/python/test_*.py`.
10. **MINOR —** the D10 crash is unexplained, and mutant outputs are not kept.

## How the report's claims hold up

**SUPPORTED**
- All gate shas and rcs (27 gates).
- Item (a) in full.
- Item (b)'s verdicts on the three programs and the fixtures.
- The ndt wiring and the withheld record and status row.
- M2, M3, S3, S4, m1–m3.
- Ruling 1.
- Unit-level invisibility to bmv2_count, the helper's sweep, p4_testbed_topo and the kernel scan.
- extb4r tripwire: 0 lab calls.
- extb4 shim log: only `file://` lines plus ALLOWED-LAUNCH.

**UNDER-EVIDENCED**
- "The injected frame is byte-identical to the daemon's" (only the layout is pinned).
- "A SIGKILLed checker takes its switch with it" (in the gate the wrapper is killed before it executes simple_switch; plus the D10 crash).
- "Stopped on SIGTERM/SIGINT/SIGHUP" (`main()` never run).
- "The tripwire confirms every pid is gone" (argv[0]-filtered).
- "Same bmv2 commit as the fabric" (observed once, not enforced; not checkable read-only).
- "The advanced_tunnel fixture equals the ~/tutorials build" (not checked).
- "No collision with the fabric" (composition only).
- "No root" (observed, not enforced).
- "M1 executable."
- The extb4 tripwire.

**CONTRADICTED**
- "21 completed / 26 total" (22 / 27).
- "/home/adam only in flowcache_solution.json" (SUM:135 vs PATCH:313).
- "H5 with OLD_06=C1 checks rc/verdict against the same session" and README:282's expected PASS.
- The S1 sentence "no pipeline loaded".
- README:380's /etc/ndtwin-lab.conf premise.
- SUM:591 (paths are still described as shortest-path guesses, against §R4.1).
- SUM:678 / §R4.3 ("not yet DELIVERED", 5 gates not run) is stale against INTAKE:57-62.

**UNTESTED**
- Everything live.
- ndt → the real checker → bmv2.
- `main()` and its signal handling.
- The "did not settle" path.
- The detect-only line against the 6000-character trim.

## Tests I would have run

1. An 08 H5 self-test cell with a 4-arm OLD_06.
2. Sourced ndt with the real `hb_drop_check_run` on a converted package, wrapper in place: assert the one-line answer, and that no `ndt-hbdrop-bmv2` process exists when the topo-start stub runs. Repeat with the flood variant.
3. `main()` sent SIGTERM mid-check: rc 143, switch gone, directory gone.
4. The SIGKILL probe after notif.ipc exists, so a real switch is running.
5. A compare fixture where the session runs but no direction is heard: must refuse.
6. A "did not settle" cell and its mutant.
7. A tripwire that rejects condition-violating launch lines and checks liveness by pid.
8. An offline measurement of where the detect-only line falls in B's `ndt up` output.
9. The checker run under the interpreter drive_exercise's PATH yields.
10. Merge-tree onto d452d111 and the full rerun.

## Fix list (for MERGE AFTER FIXES)

**Must, before the live run:**
- **M-1.** Run C1/C2 (and C3/C4) as the full 06 without `ONLY=`, or pre-register that H5's "06 against" line is not a criterion and keep a 26-arm reference for it. Update README:282, 384-388, 399-401, 432-434 and 08:58-64, and add a self-test cell for the chosen shape.
- **M-2.** Pre-register the local-merge protocol:
  - freeze trunk pushes until the decision;
  - record C's HEAD, uncommitted-file list and binary sha256s;
  - refuse T unless its merge parent and those match;
  - write the rollback step for a failing T.
- **M-3.** Have the sampler record per-direction `heard`, and have compare refuse an external arm whose session did not hear every direction during the controller's lifetime. Add a fixture and a mutant.
- **M-4.** D16/D16b/D17/D18 must not launch: assert on `Launch.argv` without calling `start()`, or use a recorder in place of the switch. The tripwire must flag launch lines with argv[0] ≠ `ndt-hbdrop-bmv2`, a Thrift port outside 29400-29499, a device id < 900000, or no own-directory ipc socket, and check liveness by pid. The orchestrator should confirm.
- **M-5.** Merge current trunk and rerun all 27 gates, with a gated tripwire over every driver's shim log.

**Should:**
- **S-1.** Correct the counts (22 / 27; 1585 = 625 switches + 960 probes), SUM:135, SUM:591, SUM:678 and the "§R3.9–§R3.10" reference.
- **S-2.** Extend LIMITS, README and the census text to say that controller-pushed pipelines and runtime default-action changes are not covered.
- **S-3.** Rewrite or verify the S1 sentence against segment S's raw data.
- **S-4.** Harden the checker:
  - a top-level try/except so any crash exits rc 2;
  - refuse euid 0;
  - a cell that runs `main()` with a signal;
  - mutants for `settled` and the env override;
  - an empty port set means "not applicable";
  - compare the stock binary's version with the fabric's.
- **S-5.** Keep one drop-check log per arm.
- **S-6.** Add the end-to-end ndt cell (test 2 above).
- **S-7.** Keep mutant outputs when a suite crashes, and find D10's cause.
- **S-8.** Run test_heartbeat_drop_check.py from l1, with a declared skip when simple_switch is absent.
- **S-9.** Pre-register the 2/5 false-fail rate.

**Nits:** flag a nonzero external path count in `ndt status`; delete D21's leftover directories; rule on `/home/adam` in the shipped fixtures.

