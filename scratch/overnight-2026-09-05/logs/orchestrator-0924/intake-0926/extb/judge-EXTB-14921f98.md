# JUDGE: external detect-only round 2 14921f98

**Verdict: MERGE AFTER FIXES.** Round 2 closes most of the F and N items, and all 19 gates reproduce as reported. The blocking problems are in the evidence tool and the live procedure that decide the merge, not in the proxy or ndt code:
- The README's live comparison cannot be run as written (§6).
- `compare` still accepts a treatment whose only heartbeat evidence was captured before the exercise's pipeline existed (§2).
- N-1's exit code is not the 130/143 the code comments, README and judge say (§3).

Fix M1–M3 before running the live comparison or relying on it.

How I checked: read-only. I read the report under review (SUMMARY §0), the worktree at 14921f98, the 19 `*.extb2-14921f98.log` files plus `scripts-extb2-14921f98/tripwire.log`, and the raw the report cites. No git, no earlier judge reports, nothing executed.

Path prefixes used below:
- WT = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927`
- LP = `WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1`
- LOGS = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910`
- RAW = `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs`
- Short names: `ev.py` = LP/external_evidence.py, `08` = LP/08_heartbeat.sh, `hb_w` = LOGS/mutate_p4_heartbeat_w log, `ev-mut` = LOGS/mutate_live_p1_external_evidence log, `common-mut` = LOGS/mutate_live_p1_common log.

## 1. Item by item

**F1 — PARTLY FIXED.**
- Code: `ev.py:267-296`, `ev.py:376-379`.
- Red/kill: redfirst_b2:30-32 and :38; ev-mut:29-33 (E16–E20), :42 (E29), :45 (E32).
- Weaknesses: see §2.

**F2 — PARTLY FIXED.**
- Done: identity is printed (`ev.py:349-354`); the pre-declared excuse is gone (grep finds nothing in LP); invariants exist (`ev.py:232-264`); a truncated counter block is UNREADABLE (`ev.py:155-161`).
- Red/kill: redfirst_b2:33-35; ev-mut:34 (E21), :36-40 (E23–E27), :43-44 (E30–E31).
- Residual:
  - The procedure is not executable (§6).
  - Invariants are judged against C1 only (`ev.py:407-415`); C2 is ignored.
  - Nothing checks that the last counter block had settled.
  - `08:46-49` and `08:56-57` still direct the external comparison "against the same OLD_06" (074635Z). That contradicts README:356-366 and :385-388.

**F3 — FIXED, but one claim is overstated.**
- The disclosure is at README:332-352 and main.py:1352-1356.
- Red/kill: redfirst_b2:25; M28b (hb_w:128).
- The P4 reasoning checks out against `/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4:137-143,251-257` and `/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4:70-74,123-141,170-180`.
- "已量過 / measured" is not supported (finding S1).

**F4 — FIXED.**
- Code: `08:270-311`, `:2495`, `:2504`, `:2509`, `:2516`.
- Red/kill: redfirst_b2:16; L73–L75 (hb_w:244-246); selftest_08:65-71.
- Test gaps:
  - There is no BAD cell for "up at the proxy, kernel has not accepted it". `08:1548` is the only up-told cell, and it is OK.
  - There is no cell where only table_generation moves. The fixture at `08:1398` moves it together with pipeline_commits.

**F5 — FIXED except one line.**
- Fixed: ndt:2985-2989 and 4039-4042; main.py:1097-1111 and 1162-1164; topology_manager.py:2153-2160; test_declared_links.py:319; mutate_roles_binding.sh:744-745.
- Red/kill: redfirst_b2:27; N03d (hb_w:144); MN15 (mutate_roles_binding log:244).
- Residual: `WT/tools/test_workflow/ndt:7051`. `ndt status` still prints "N destination paths reported; none expected" for every foreign pipeline, external included. After B, an external fabric has its hosts (main.py:151-165) plus declared links, so the count is no longer 0.

**F6 — FIXED.** main.py:1348-1351; red at redfirst_b2:25.

**F7 — FIXED, one hole.**
- Code: `ev.py:94-100`, `:124-133`, `:177`.
- Red/kill: redfirst_b2:36-37; ev-mut:35 (E22), :28 (E15).
- Hole: an IPv4 packet-in whose payload is 14–23 bytes passes the length check. `ipv4_flow` (`ev.py:136-139`, called at `:168` outside any try) then raises IndexError, which prints a traceback with rc 1.

**F8 — FIXED.** E10–E15 in mutate_live_p1_external_evidence.sh:114-137; ev-mut:23-28 and :48 (32 mutations, 0 survived).

**F9 — FIXED in code, never seen red.**
- The restore is judged at the strict 20 s in `08:2509-2515`.
- No self-test cell or mutant covers `08:2510-2515`: no test under tests/shell mentions H4_REST or RESTORE_BOUND_S.

**N-1 — PARTLY FIXED.** Code at `08:797-808` and `:2244`; red at redfirst_b2:13-14, L68 (hb_w:239), selftest_08:143-144. The final rc is 1, not 143 (§3).

**N-3 — FIXED.** `08:763-790`.

**N-4 — FIXED.** `08:528-550` and `:2385`; redfirst_b2:15; L71 (hb_w:242); selftest_08:145-147.

**N-5 — FIXED.** `LP/_common.sh:376-408`; redfirst_b2:22; M56 (common-mut:333); test_live_p1_common log:238-241.

**N-6 — FIXED.** `_common.sh:410`.

**N-7 — FIXED.**
- Code: `LP/02_app_basic.sh:184-189`; `WT/tests/shell/test_live_p1_common.sh:1213-1237`.
- Red/kill: redfirst_b2:23; M50 and M52 (common-mut:319, :328).
- Minor: the "any spelling" pin (test_live_p1_common.sh:1220-1221) misses `!=` and `case` forms. The consumer lines in 03 (:125-126) and 04 (:113-114) are not pinned.

**N-11 — PARTLY FIXED.** main.py:1837-1840 still leaves out that `install_initial_routes` drops off the list when routes are owned (main.py:2221-2222).

**Extra self-test cells (H3 cut-short, early exit within 20 s, clean run) — FIXED.** `08:2072-2093`; L69/L70/L72 (hb_w:240-243); selftest_08:140-142.

**N-9 (driver) — FIXED.** proxy_unit log:57.

## 2. F1: can `compare` still be fooled? Yes.

**(a) Every treatment marker is captured before the controller runs.**
- drive_exercise.py records the N3 `ndt up` output (:2874-2878), the N4 switch_state (:2891-2896) and the N5 `ndt status` (:2902-2904). The controller only starts later, in Steps.run (:2914-2917).
- In 074635Z every switch at N4 reads `FAILED_PRECONDITION: No forwarding pipeline config set` (RAW/2026-09-27T081205Z_p4runtime_solution_ndtwin.md:314), and the controller step C1 comes after N5 (:519).
- Consequence 1: without `--samples`, a heartbeat that dies after N5 still passes `check_roles`.
- Consequence 2: the daemon counters that `compare` checks (`ev.py:79`, `:206-208`, `:416-422`) come from that pipeline-less N4 snapshot. They are 0 by construction on every real external arm.
  - The "!! DAEMON … ruling 4" branch can therefore never fire. Only the synthetic fixture triggers it (test_live_p1_external_evidence.sh:98-100).
  - The printed line "daemon … all 0" says nothing about the exercise's program.

**(b) With `--samples`, the check is still weak.**
- `ev.py:287` needs just one `running` sample for the N5 session.
- The sampler (`08:848-876`) records neither the report's written_wall nor its stop_reason.
  - A SIGKILLed daemon leaves `running` in its report forever, so it looks alive.
  - A daemon that stopped early still has earlier `running` rows, so it passes too.
- `ev.py:285-286` only looks at the N5 session. A replacement session inside the same arm is never examined.
- What `--samples` does give: cumulative forwarded counts for the whole session. That is the only evidence of what the loaded program did with 0x88B5 frames.

**(c) Controls are refused only on a `running (pid…)` row** (`ev.py:278`, `:378`). A control whose report contains the detect-only line or a heartbeat block, but whose N5 row reads STALE or stopped, is accepted.

**(d) Other holes.**
- `--control2` may be the same directory as the control. That silences the one-control warning without adding any spread.
- An IPv4 packet-in with a 14–23-byte payload crashes the tool with a traceback instead of reading UNREADABLE (see F7).

**What the operator must pass today for a result that means anything:**
- Command: `python3 LP/external_evidence.py compare <C1> <T> --control2 <C2> --samples <08 H5 run>/50_samples.tsv`.
- T is the 06 raw started by that same `PART=h5` run (08 prints `06 rc …, raw …`).
- C1 and C2 are two `ONLY=p4runtime,flowcache` runs of 06 from a tree without B, on the same machine and venv.
- Only rc 0 is a pass.
- README:364-365 currently allows T without samples ("或 B 上的 06 一次", `[--samples …]`). That is not a valid treatment.

## 3. N-1

- **FAIL instead of PASS: yes.** A TERM now ends `FAIL 08_heartbeat -- interrupted by SIGTERM before the run finished` (selftest_08:143). On the base it ended `PASS` with rc 0 (redfirst_b2:14).
- **rc 143: no.**
  - `w_interrupted` calls `exit 143` (`08:806`). That runs the EXIT trap `w_finish`, which calls `finish`, whose `exit "$VERDICT_RC"` (`_common.sh:309`) replaces the status with 1.
  - The self-test pins rc 1 (`08:2109`: `"$rc_t" == 1`).
  - `08:99-101`, `08:795-796` and README:287-288 all claim 130/143, so they are contradicted by the code.
- **TERM while waiting on a foreground child:** bash defers the trap until the child exits. The self-test's `command sleep 2` covers exactly this.
  - In H5 the foreground child is `bash 06_thirteen.sh` (`08:2286`). Stopping 08 by pid therefore only takes effect after the rest of 06 has run, still bringing fabrics up.
- **Interaction with `w_finish` is correct.**
  - Cleanup runs once: traps are reset at `08:769` and again at `_common.sh:241`.
  - NOTE lines still print above the verdict (`_common.sh:303-308`).
- **Remaining window:** `start_step` installs `trap finish EXIT INT TERM` (`_common.sh:324`), and 08 only replaces it at `08:2244`.
  - A TERM in between runs `finish` with the interrupted command's status (0), which can print `PASS 08_heartbeat`.
  - Every other script that uses `start_step` (01–05, 07) has the same shape. The root cause is in `_common.sh`, not in 08.
- **Pre-existing (not a regression):** both teardowns reset INT/TERM to default. A second signal therefore kills the teardown mid-way.

## 4. Regressions and anchors

- I found no behavioural regression in the files touched this round:
  - main.py, topology_manager.py and ndt changes are text or log-only.
  - 02's consumer line is intact.
  - `heartbeat_skips_verdict` produces exactly one line on every path I traced: `SystemExit` passes the outer `except Exception`, and a dead interpreter falls to the `||` line.
- Anchors: 123/123 (check_gate_anchors log:140).
- Trunk has moved past 9ef10250 (the session snapshot shows f253ed08, with merges that touch ndt). The merge-tree check and the gates must be redone against current trunk before merging. I could not verify this without git.

## 5. Round-2 gate table: every number matches its log

| Gate | Result | Log line |
|---|---|---|
| redfirst_b | ALL-AS-EXPECTED | :57 |
| redfirst_b2 | ALL-AS-EXPECTED | :69 |
| proxy_unit | 46 files, 1674 tests, 1673 passed, 1 skipped, 0 files FAILED (I summed lines 11-56 to 1673) | :57 |
| test_ndt_heartbeat | 63/0 | :91 |
| test_ndt_app_package | 395/0 | :449 |
| test_ndt_up_down_robust | 424/0 | :484 |
| selftest_08 | SELF-TEST PASS | :166 |
| test_live_p1_common | 211/0 | :253 |
| test_live_p1_thirteen | 45/0 | :69 |
| test_live_p1_external_evidence | 77/0 | :101 |
| test_drive_exercise | OK | :82 |
| mutate_p4_heartbeat_w | 229/0; 118/118 new proxy tests seen red; 63 ndt checks, all red except 12 controls | :266, :263, :181 |
| mutate_live_p1_common | 57/0, 4 controls | :368 |
| mutate_live_p1_thirteen | 12/0, 1 control | :122 |
| mutate_live_p1_external_evidence | 32/0, tool sha256 unchanged | :47-48 |
| mutate_roles_binding | 179/0 | :622 |
| mutate_app_package | 48/0 | :69 |
| check_gate_anchors | 123/123 | :140 |
| nolab_tripwire | 0 lab calls, 2001 shim-log lines | :22-23 |

- The disk ranges (4594–4816 MB when queued, 4594–4817 MB under the lock) match the logs.
- All 2001 lines of tripwire.log contain `file://`; I counted.
- Not checkable read-only: "17 files, +1165/−288" and the merge-tree rc.

## 6. The judge-requested live procedure (README:354-393) is NOT executable as written

1. **T cannot run from B's worktree.**
   - The worktree has no `build/bin/ndtwin_kernel`, so ndt's preflight fails (ndt:2699).
   - `guard_lab_acts_in_this_tree` (ndt:1526-1561) refuses unless root rewrites `/etc/ndtwin-lab.conf` so KERNEL_DIR names this worktree. It "names ONE tree" (ndt:1558), so the controls on trunk need it pointed back afterwards.
   - None of this is written down, including who does the root step.
   - README:24 still names the old worktree `wt-app-ndt-0917`.
2. **The control tree is wrong.**
   - "trunk（例如 149c8234）" predates 9ef10250, which B now contains. The control should be B's merge parent.
   - The main checkout is f253ed08 plus other sessions' uncommitted files.
   - Trunk's 06 writes no `00_venv.txt`, so "same venv" is never recorded for C1 and C2.
3. **The alternative control is not implemented.** README:361-362 says to stop the heartbeat after `ndt up` and adds "要另外接到 driver 裡" (must be wired into the driver separately). That wiring does not exist.
4. **The treatment options are too loose.** T may be "或 B 上的 06 一次" and `--samples` is optional. Both are invalid per §2.
5. **There is no decision rule.** Nothing says what rc 0/1/2/3 mean for the merge, or whether an H5 FAIL invalidates T. H5 is judged `same_06` against a 5dc7fc9a+95 baseline, so it can fail for unrelated reasons.
6. **README:382-383 asks for end-of-arm switch_state checks that the raw cannot answer.** 06 records switch_state only once, at bring-up (drive_exercise.py:2891).
7. **Expect false DIFFs without any heartbeat effect.**
   - With only two controls, a third draw of a continuous noisy value lands outside their range with probability 2/3.
   - flowcache is racy: in 074635Z its controller died after the 6th packet-in (flowcache controller log :39-45).
   - p4runtime's last counter block is only right if a read happened after iperf ended. In 074635Z the last two blocks read 3267 then 3505 (controller log :115-125).
   - Pre-register the rules: more controls, an unsettled last block counts as UNREADABLE, and an invariant only counts when both controls keep it.
8. **Output trimming (a risk, estimated).**
   - drive_exercise keeps 6000 characters per step (:3127). In 074635Z, N3 (6019) and N4 (6547) were already cut (report :218 and :441).
   - By my estimate the detect-only line (around character 5000) and `side_effects` (around character 4000) still fit. If they fall off, the tool refuses rather than passes.
9. **Live risk in H4.** H4 now needs HTTP 200 (kernel_notifier.py:80) for link reports about switches the kernel holds Down. Nothing shows the kernel does that; pre-register what happens if it doesn't.

## Findings

- **M1 (must fix).** Make §6 items 1–6 executable: name the trees, the root step, the kernel binary for B's worktree, the control sha and the decision rule.
- **M2 (must fix).** In `ev.py`:
  - Refuse any result without `--samples`.
  - Require the N5 session to be `running` across the whole arm window, using arm windows as `08:624-635` does, and reject any other session inside that window.
  - Add written_wall and stop_reason to the sampler (`08:848-876`).
  - Drop or relabel the N4 daemon counters (`ev.py:416-422`).
  - Refuse controls whose report has the detect-only line or a heartbeat block.
- **M3 (must fix).** Carry 130/143 through `finish`, or correct `08:99-101`, `08:795-796` and README:287-288. Close the `_common.sh:324` window at its source in `_common.sh`.
- **S1.** Several texts call the three external programs measured: README:340 and 348-349, the SUMMARY (§2 and §0.1 F3), test_heartbeat_fabric.py:525, and the census text main.py:1352-1356. The last also serves "egress port 0 does not exist" as fact.
  - Segment S never started those controllers (WT/doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh:63-65). For external packages that means no pipeline was loaded, so census rows 24-26 measured empty switches.
  - H5 will be the first measurement with the programs loaded; the texts should say so.
- **S2.** Replace the OLD_06 guidance at `08:46-49` and `:56-57`. Judge invariants against both controls. Add a check that the last counter block had settled.
- **S3.** Fix the "none expected" text at ndt:7051.
- **S4.** Pre-register the H4 `reported_to_kernel` risk (§6.9).
- **m1.** Catch the short-IPv4-payload IndexError (`ev.py:136-139`, called at `:168`).
- **m2.** Complete the N-11 docstring (main.py:1837-1840).
- **m3.** Test gaps:
  - An up-told BAD cell, and a cell where only table_generation moves.
  - A red for F9 (`08:2510-2515`).
  - A mutant on the counters_final branch of `within()` (`ev.py:334-343`). No test runs it with `--control2`, so `return True` there would survive.
  - Three evidence cells never seen red; see "Under-evidenced" below.
  - The 03/04 consumer pins.
- **m4.** Re-merge current trunk and re-run the gates.

## Classification of the report's round-2 verdicts

**SUPPORTED**
- F1's refusals, as code and tests.
- F2: identity printing, the excuse removed, the truncated-block rule.
- 074635Z's own readings, which I re-derived from the raw: 3505 = 5 pings + 3500 datagrams; s2 egress 3505; the 200-direction counters 7 and 7; skeleton 5 and zeros; flowcache 6 IPv4 packet-ins, 5 matching cache entries, 1 gRPC error.
- `code 5dc7fc9a +95` (RAW/../live-p1/runs/2026-09-27T074635Z_06_thirteen/p4runtime_solution.log:153).
- F3's disclosure and its P4 reasoning.
- F4, F5 (except ndt:7051), F6, F7 (except the IndexError), F8.
- N-1 "never PASS".
- N-3 through N-7.
- Every red-first count in redfirst_b2:13-38.
- The whole gate table, and "tripwire all file://".

**UNDER-EVIDENCED**
- F1's daemon-counter refusal and its "ruling 4" DIFF: they read a pre-pipeline snapshot.
- F4 "self-test 有 OK/BAD 各格" (an OK and a BAD cell for each check): up-told has no BAD cell.
- redfirst_b2:39 "the evidence gate kills each". Three cells are green on the base tool (redfirst_b2:52, :61, :62), green with no tool (redfirst_b:46, :55, :56) and named by no E mutant:
  - "and no one-control warning"
  - the report-is-a-directory "and no traceback"
  - "a compare with one run: usage, rc 2"

**CONTRADICTED**
- N-1 exit codes 130/143 (the self-test pins rc 1).
- "三個量過的程式" (the three measured programs); see S1.

**UNTESTED**
- F9's restore judgment.
- The live procedure (§6).

**Not verifiable without git**
- File and line counts, merge-tree rc, the secret scan.

## Internal inconsistencies in the report

1. §4:177 says `compare 074635Z 074635Z` prints NO DIFFERENCE with rc 0. The round-2 tool refuses that with rc 3 (`ev.py:273-277`).
2. The 狀態 (status) section still says "實際是 4148–4525 MB" (the measured range was 4148–4525 MB), which §0.5 corrects.
3. §1:131 states "現在在段 S 的 20 臂上都啟動" (it now starts on all 20 arms) as fact; F6 turned that into an expectation.
4. §4:180 says the external arms had "以前沒有任何 inter-switch edge" (no inter-switch edge before B). The cited raw shows `kernel: 3 switches in the graph, 12 edges` and `links 12 total, 6 down` (report :202, :496).
5. The 08 header (:46-49, :56-57) and the README (:356-388) disagree on what 074635Z is for.

## Tests I would have run

- `compare` fixtures that should refuse but are accepted today:
  - a session sampled `running` once, then stopped before the controller;
  - a stale `running` report left by a killed daemon;
  - a second session inside the arm window;
  - a control with the detect-only line and a heartbeat block but a STALE N5 row.
- Spread and invariant cases: counters_final differing with `--control2`, and an invariant broken in C2 only.
- `show` on a real B-produced round report, to confirm the detect-only line and `side_effects` survive the 6000-character trim.
- 08: assert rc 143 on TERM, and send a TERM before `arm_traps` runs.
- H4: an up-told BAD cell, a table_generation-only cell, and restore over 20 s leading to FAIL.
- An IPv4 packet-in with a 20-byte payload, expecting UNREADABLE.
- merge-tree and the gates against current trunk.
- A dry run of ndt's preflight from B's worktree.
- The kernel's HTTP answer to link reports about Down switches.
