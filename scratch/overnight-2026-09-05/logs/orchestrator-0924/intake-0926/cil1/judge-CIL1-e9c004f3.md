# JUDGE: CI-L1 e9c004f3

## Verdict: MERGE (no blocking findings)

I found no case where a skip hides a failure that exists today. Every new skip is scoped to a prerequisite. Where the prerequisite is present, the skip still fails. The one deleted check had a false premise, and I verified the chain behind that.

There are 14 notes below. Two cheap ones are worth doing before or right after merge: N3 (show the negative grpc regex red on its own) and N5 (split one route_binding case). The worker's summary also has four number errors; they are listed in the last section and affect the record, not the code.

Method: I read the code in the worktree and the base checkout, and the raw logs in `logs/ci-l1-0928` and `logs/ci-l1-0927`. I did not use git or run anything.
- **fullci2 is e9c004f3's tree.** `fullci2.log:1` gives the sha, and `scripts-batch3/batch3.sh:17` refuses to run unless the clone's HEAD matches the worktree HEAD. I spot-checked the sandbox tree (`/tmp/claude-1000/.../cil1/ls/fullci2`) against HEAD in five changed files and all matched: the lane at 521-523, `test_ndt_ovs_topo_script.sh:65`, `test_fabric_bring_up.py:367`, `test_grpc_port_block.py:465` and `test_ovs4_sflow.py:59`.
- **The clone has full history** (no `.git/shallow`).
- **Nothing compiled was added.** The fresh e9c004f3 clone `cil1/head2/NDTwin-Kernel-P4` has no `p4_src/build` and no `.pyc`, `.so`, `.o` or `.p4info.txt` files.

## Answers to the eight checks

**1. Do skips hide real failures?**
- **The 82 fabric cases are exactly the ones that fail without the artefact.**
  - p4A has 30 passing and 82 red cases (`ci-l1-0927/p4A.test_fabric_bring_up.diag-4ff4eee8.log:25-189`, summary `:1873` failures=4, errors=78).
  - fullci2 has 30 ok and 82 skipped (`lane-logs/fullci2/l1_python_test_fabric_bring_up.log:115-117`).
  - The 30 passing test ids are identical in both.
  - Decorator count: 9 class-level decorators cover 40 cases and 42 method-level decorators cover the rest, 82 in total. The file gains exactly 51 decorator lines and no test was added or removed.
  - p4B, with only the artefact added, runs 112 and all pass (`p4B...:378-380`). No case is over- or under-decorated.
- **route_binding: the 2 skipped are the 2 that failed in p4A** (`p4A.test_route_binding...:62,64` against `lane-logs/fullci2/l1_python_test_route_binding.log:38,40`).
  - The brief's "2 of 48" is wrong: every log says 46 ran.
- **The lab still runs them, and a skip there fails.**
  - `p4-fabric-lab.log:369-371`: 112 ran, OK.
  - `p4-route-lab.log:56-58`: 46 ran, OK.
  - `ls-lab-P4-alwaysskip-MUTANTb.log:32`: the lane in lab shape prints `FAIL 82 of 112 ... with both prerequisites present`.
  - For the kernel side there is lane-level proof that the declared files run on the lab (`ls-lab-S.log:28-30`). That a skip there becomes FAIL-SKIP is shown only at unit level (D8, and the mutation at `mutate_l1_shell_scoring.log:33`).
  - No full lab-shape lane run at HEAD exists.

**2. Declared-skip logic**
- **Order:** FAIL-RC comes first, then DECLARED-SKIP, then FAIL-SKIP (`l1_unit_tests.sh:134-143`; D4-D6 and the matching mutations were killed).
- **Red check before SKIP (shell suites):** any `^\s*(FAILED|FAIL )` line anywhere in the log removes the excuse (`:182`, D13).
- **Unprobed needs excuse nothing** (`:186`; D12, D14, D22).
- **py-plot probe:** it asks the suite's exact question, on the same file and environment (`:203`, `-x || -f`, against `test_gate_exit_code_not_tee.sh:106`). `mkdir` is stubbed (D16 plus its mutation). round.env currently runs nothing except exports, `unset` and that `mkdir` (round.env:13-73).
- **Caveats:** N1, N2 and N4 (declaration regex, self-excusal, probe independence).

**3. G-60 (retiring the ovs4_sflow cell)**
- Every cited location is true on this tree:
  - `ndt:4303-4304`, `:4454`, `:55`.
  - `ndtwin-lab:98`, `:244-246`, `:552`, `:571-579` (the brief says 577), `:1711`, `:1725-1736`.
- `/usr/local/sbin/ndtwin-lab` has the same code on the same lines (552, 571, 1711, 1725).
- `ndt up ovs` runs `$KERNEL_DIR/testbed_topo.py` under NTG's interpreter, not NTG's copy.
- A residue remains and is disclosed: `ndt:4331` still shows the operator "128 comes from NTG's testbed_topo.py".

**4. test_ndt_ovs_topo_script fallback**
- The "kernel tree" marker is right: it is ndtwin-lab's own validation (`:244`). A kernel tree that is missing `testbed_topo.py` would still be tested and would fail loudly.
- The lab still tests its configured tree: there is no fallback note in `ovs-topo-lab-e9c0.log`.
- The subshells lose no state. The recorder writes to a file, `ovs_topo_start` keeps only a local, and the EXIT trap is not inherited by the subshell.
- Caveat: N6.

**5. grpc_port_block**
- I read all 21 allowlisted lines (`tools/p4_exercise`: 6 + 12 + 2 + 1). Each reason is true of its line; `test_run_external_controller.py:76` is one nit, see N12.
- The staleness check works: R4 is red on `test_every_allowed_line_is_still_there` (`grpc-R4.log:47`).
- That the regex still rejects `50050+` is not demonstrated: see N3.

**6. ci.yml**
- The venv step matches `p4_proxy/requirements.txt:4-6`; it uses `python` where the file says `python3`, which is the same setup-python interpreter.
- `fetch-depth: 0` is set only in build-and-test. The other three jobs are unchanged. The rest of the diff is comments.
- Nothing git-sensitive is affected: CMake uses no git, and no test uses `--all` refs.
- Caveat: N7.

**7. Logs**
- Every claimed number was found; locations are in the classification table.
- The fullci2 log is for e9c004f3.
- Claims made without a raw log: N11.
- The argument that the two unrun gates are safe holds by reading. Both gates copy the build into their sandboxes (`mutate_roles_binding.sh:145` uses `cp -r`, `mutate_p4_heartbeat_w.sh:155` uses `cp -rL`), and if the artefacts were missing a mutant would be reported SURVIVED, loudly.
- But MN2 (`mutate_roles_binding.sh:636-642`) depends directly on a decorated case, so running that one gate is the real check.

**8. Discipline**
- The `[Co-developed ...]` tag is present in every changed code file. ci.yml carries it only at file level, which is that file's existing convention.
- No `pkill`, `pgrep -f` or `killall` in the changed files or the worker's scripts.
- Temp dirs use mktemp (`test_l1_shell_scoring.sh:73`, `mutate_ndt_ovs_topo_script.sh:39`).
- Nothing compiled was added (see method above).
- Commit messages could not be checked without git.

## Findings (all notes; none blocking)

**N1 — An excuse can override a summary that counts failed checks.**
- `l1_lane_verdict` puts DECLARED-SKIP above FAIL-CHECKS (`l1_unit_tests.sh:137` against `:140`). Only the text grep at `:182` stops it.
- So `l1_lane_verdict 0 12 3 1 ryu` returns DECLARED-SKIP whenever a suite's failure lines aren't spelled `FAILED`/`FAIL `.
- It is safe today: the only declaring shell suite prints `  FAILED` (`test_gate_exit_code_not_tee.sh:61`).
- Fix: have `failed>0` veto the excuse inside the verdict function, and add a D-cell for it.

**N2 — The declaration regex is looser than "comment lines only".**
- `l1_unit_tests.sh:174` matches any line whose first non-blank character is `#`. That includes lines inside a Python docstring or a bash heredoc.
- D3 tests only an inline string.
- Also, a file can excuse any of its skips on CI just by declaring a need CI lacks; the lane never ties the skip's reason to the need.
- The lab still catches this. For `.py` files, requiring skipped == ran before excusing would tighten it at no cost today.

**N3 — The rewritten negative assertion has never been seen red.**
- `assertNotRegex(..., TOPOLOGY_RESTATES_THE_OLD_BASE)` is at `test_grpc_port_block.py:357,365`.
- R1 goes red on the positive regex first (`grpc-R1.log:52`: `Regex didn't match: 'grpc_port\s*=\s*grpc_ports...`), so the negative regex's firing is not shown.
- It is correct by reading. One mutant that keeps the module call and adds `grpc_port=50050 + dpid` would show it red, as the repo's red-first rule asks.

**N4 — A degraded lab reads as passing.**
- The excuse depends on what the machine has, not on which machine it is. A lab that loses ryu-env, or whose round.env PY_PLOT default breaks, now reports DECLARED SKIP and "L1 passed" where it used to report FAIL-SKIP.
- The py-plot probe is not independent of the tree under test: it sources `round.env:62` (`l1_unit_tests.sh:198-204`).
- The probe also runs whatever round.env contains in the lane on every run. The `mkdir` stub covers only a bare `mkdir`, and N7 is about to edit round.env.
- The probe's `export ROUND=` has no effect, because `round.env:14` overwrites it.
- "lab 不會被靜音" (the lab won't be silenced) therefore holds only while the lab has its needs. Suggestion: allow the excuse only when `CI`/`GITHUB_ACTIONS` is set, or keep a list of needs the lab must have.

**N5 — One route_binding case bundles an assertion that needs no artefact.**
- `test_route_binding.py:514-518`: the whole case is skipped on CI, including the renamed-table `IPV4_LPM_TABLE` assertion at `:517`.
- That is the only per-client check of this key (`:288` covers only the class constant).
- Split the baseline half into its own decorated case.
- The class-level decorators in `test_fabric_bring_up.py` (for example `:672` and `:2158`) will also silently skip, on CI, any future case added to those classes.

**N6 — Nothing guards the lab side of the #7 fallback.**
- N4 and N5 in the gate (`mutate_ndt_ovs_topo_script.sh:246-257`) only require the fallback to stay green.
- A mutant that makes the suite always fall back stays green on the lab, so nothing protects "the lab tests the configured tree".
- A broken KERNEL_DIR resolution on the lab now shows only a note.

**N7 — The cost of `fetch-depth: 0` was never measured.**
- actions/checkout with depth 0 fetches every branch and tag, not just trunk's history.
- The 126 MiB estimate was for trunk only, local pack, with the public download explicitly not measured (DIAG §3.5).
- Watch the first run against the 30-minute timeout, or consider `filter: blob:none`.

**N8 — The venv step itself never ran.**
- It was simulated by bind-mounting venv313, a 3.13 copy, at `p4_proxy/venv`.
- The step's real behaviour on GitHub is untested; the worker labels this INFERRED.
- The sandbox also exposes host system packages. For example, host mininet let #7 section 5 run (`ovs-topo-ci-e9c0.log:60-61`); a real runner will print "2 checks not run", so 40 checks, not 42. The verdict is the same.

**N9 — The two heavy gates were not run at HEAD.**
- `mutate_roles_binding` and `mutate_p4_heartbeat_w`.
- Run at least `mutate_roles_binding`, because MN2 depends on a decorated case.

**N10 — The trunk-bwrap control for heartbeat is confounded.**
- `test_ndtwin_lab_heartbeat-bwrap-TRUNK.log:202-207`: two of its three reds are "no interpreter could import proxy_agent.topology_manager", because that cell had no venv.
- Only `:126` is the ownership check, which is the same red as in fullci2 (`fullci2.log:182`).
- The conclusion still stands, via `test_ndtwin_lab_heartbeat-cinh-HEAD.log:221` (194/0) and CI raw `:6875`.

**N11 — Claims labelled OBSERVED that have no raw log.**
- "`bwrap … stat -c %U /etc/hostname` → nobody": only the suites' own `65534` output supports it (`test_ndtwin_lab_config-bwrap-TRUNK.log:43,50,58`).
- "N7 branch has 0 commits": no log.
- The base anchor counts "34→41, 8→10": the new counts are logged at `check_gate_anchors-e9c0.log:67,90`. The old counts are not in this folder, though 34 does appear in `orchestrator-0924/intake-0926/queued/combined-check_gate_anchors.4ff4eee8.log`.
- The fullci2 header could not record the interpreter version (`fullci2.log:4`, "Permission denied"), so "3.13" holds by construction, not from the log.

**N12 — Documentation that is now stale or overstated.**
- `doc/2026-08-07_testing_tools_overview.md:110` still says any skip in tests/python is a FAIL.
- The ci.yml comment at `:119` attributes "78" to run 36319541715. That run shows only the first 8 lines (`raw.log:6824-6831`); 78 is the local reproduction.
- The allowlist reason for `test_run_external_controller.py:76`: 50050 is not an address a tutorials controller dials; that case is a refusal test.

**N13 — The lane also grants PROVED LESS when there is no P4 interpreter.**
- Besides HAVE_P4INFO, the lane excuses skips when PY_P4 is empty (`l1_unit_tests.sh:468-470`). This branch doesn't change that.
- The fabric decorator checks `ndtwin_switch.json` while the lane checks `ndtwin_switch.p4info.txt`. The mismatch can only fail loudly.

**N14 — The D22 corpus check has never been seen red.**
- Under the old lane it passes without checking anything (`l1_declared_needs` is undefined, and the error goes to /dev/null).
- There is no mutation for it.

## Classification of the report's verdicts

| Report claim | Class | Evidence |
|---|---|---|
| Per-group prediction #1-#12 (table) | SUPPORTED | `fullci2.log:44,69,98,148,153,155,167,107,117,121,134,141` |
| #1/#2 decorate exactly the failing cases | SUPPORTED | p4A/fullci2 comparison above; p4B `:378-380`, `:73-75` |
| Overall "L1 FAILED (1)"; the 3 extra reds come from bwrap | SUPPORTED, with the N10 caveat | `fullci2.log:212,163-182`; cinh-HEAD `:195/:89/:221`; CI raw `:6856,6874,6875` |
| "The other 136 files are all PASS" | CONTRADICTED | 136 is the total count of PASS lines, including `test_standin` and table rows #3-#8. The 134 files outside the table and the bwrap trio are 129 PASS, 4 PROVED LESS and 1 SKIPPED (`fullci2.log:37,49,62,64,74`). |
| "CI will gain 3 DECLARED SKIP and 6 PROVED LESS" | SUPPORTED as totals, CONTRADICTED as "gain" | 4 of the 6 were already PROVED LESS on CI (raw `:6686,6711,6726,6738`) |
| Scoring 119/5, then 136/0; 45/45 mutations killed | SUPPORTED | `l1score-olddriver-REDFIRST.log:158`; `l1score-lab.log:165`; `mutate_l1_shell_scoring.log:68` |
| Lane: old 3 FAIL-SKIP, new 3 DECLARED SKIP, lab 3 PASS | SUPPORTED | `ls-ci-S-oldlane-REDFIRST.log:58`; `ls-ci-S.log:58`; `ls-lab-S.log:28-30` |
| "The lab is not silenced" | UNDER-EVIDENCED | Unit level only (D8), and conditional (N4) |
| #3: 32/0 on 3.8 and 3.12; R1-R4 red | SUPPORTED (pre-commit tree; HEAD green in fullci2) | `grpc-G38/G312.log:47-49`; R-logs `:47` |
| #3 regex still rejects 50050+ | UNDER-EVIDENCED | N3 |
| #7: 42/0 in ci and lab; the M10/N4/N5 red-first runs | SUPPORTED | `ovs-topo-*-e9c0.log:72/58`; gates `-e9c0:31`, `-9942suite:28`, `-oldsuite:21,27` |
| #8 chain and installed copy; G-61 | SUPPORTED | Lines verified; `ovs4-sflow-lab-ryuenv.log:28,42` |
| mutate_app_package 48, mutate_link_telemetry 28, ovs4 24, gate_exit 6 | SUPPORTED | `:66`, `:45`, `:38`, `:22` |
| Anchors 122/122; tmpdirs 388/0; tripwire 0 lines | SUPPORTED | `check_gate_anchors-e9c0.log:136`; `fullci2.log:26`; all four tripwire logs empty; batch3 shims are byte-identical to step 1's per recorded SHA256SUMS |
| The two unrun gates are safe | UNDER-EVIDENCED | N9 |
| The venv step equals the CI step | UNTESTED | N8 |
| #11 is green after N7 | UNDER-EVIDENCED (hypothetical only) | `n11-hypothetical-N7-plus-venv.log:35` |

## Tests I would have run
1. A full lab-shape lane at e9c004f3 with artefacts, ryu-env and PY_PLOT present. The expected result is zero DECLARED SKIP and zero PROVED LESS; the only red should be G-61.
2. Lab-shape lane mutants that force the ryu files and not_tee to skip, with FAIL-SKIP expected. Plus one run with ryu-env hidden, to document the N4 behaviour.
3. The isolated negative-regex mutant from N3.
4. Scoring cells for `l1_lane_verdict 0 12 3 1 ryu` and for a declaration inside a docstring or heredoc.
5. An always-fallback mutant for #7 (N6).
6. `mutate_roles_binding` at HEAD.
7. The branch on real GitHub, measuring checkout size and time and the venv step.

## Internal inconsistencies
- "136 other files PASS" (summary §0): see the table.
- "Gain 6 PROVED LESS": 4 of them were already on CI.
- Trunk-bwrap "1, 5, 3": the 3 mixes two causes (N10).
- The brief's "2 of 48": it is 46.
- The #7 prediction of 42: a real runner will report 40.

Paths:
- Judged summary: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/CI-L1-FIX-SUMMARY.md`
- Main evidence: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/ci-l1-0928/fullci2.log`
- Worktree: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ci-l1-0927/`

[Co-developed with claude code -- Adam]