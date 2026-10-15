[Co-developed with claude code -- Adam]

# Review r5: P4 health check, Cut 2 offline. r5 fix diff only (`feat/p4-health-cut2`, ed6dce9b → 269251f1; code head 59d6b014)

## Verdict: MERGE AFTER FIXES

- **Before trunk:** a docs-only SUMMARY commit (findings 1, 2 text, 9). It needs no gate re-run.
- **Before the first live run:** findings 1–5, as listed under Conditions at the end.
- **Can it go to trunk now?** Yes for the code at 59d6b014, as offline code. Nothing in it touches the lab unless someone runs `probe.py lab`, and that needs Adam's authorization. Land the SUMMARY corrections first, because §6 is the procedure the first live run will follow.

**What is sound.**
- Every r4 item #2–#6 and NITs 7–13 has:
  - a red on the old code (behavioural, or carried by a caught mutant where the red is only an interface error);
  - a green;
  - caught mutants.
- **The gate at 59d6b014 holds.** I read all four shard logs, not only GATE.log:
  - same commit (:1 and :6), tree fbf5a13c (:7), subject sha 71b732e6 (:8);
  - baseline, negative control, byte-identical lines and after-check are green;
  - 100/99/99/99 = 397 mutations, 69 C2R5 headers, 397 "caught" lines;
  - no SURVIVED, WRONG TEST, HUNG, NO-SUITE or ENOSPC line; `rc=0`;
  - the run1 survivors C2R4-F4b and F4d are caught (shard3:483-486, shard1:489-492).
- **No refusal is loosened.**
  - The clean check (probe.py:155-164) and the identity refusal (:209-214) are unchanged.
  - The freeze gains refusals: an existing `<run>/frozen`, an unpinnable HEAD, a failing mkdir.
  - `run_verdict` only gains a non-zero outcome (SEE-RED-NOT-SEEN).

## How I judged it

- Read-only: no git, nothing executed, no files written.
- **Read in full:** r5-diff.patch (42 commits), the handback (as claims), SHA-MAP.txt, every r5 log cited below, and the shipped code and tests.
- **Read only for the finding definitions the handback answers:** the r4 review (#1–#14, NITs 7–13).
- **Not read:** INTAKE.md, the r1–r3 reviews, the other handbacks, DESIGN.md.
- **Spot-checked, because the code or SUMMARY relies on them:**
  - `tools/test_workflow/ndt` (claim file, `down`, the `up` tree guard);
  - controller_ext.py, report.py, cells/table.py, cells/verdict.py, round_a.py, collect/config.py;
  - the scratchpad `delta.py` that delta_counts.log names as its command.
- **One read outside the worktree, of an uncommitted file:** the main checkout's `p4_proxy/mininet/host_count_override` reads `4` (it shows as modified in the session-start git status). It does not matter for this run: `ndt up p4 --app` takes the host count from the package (ndt:3254-3257).
- **Paths.**
  - W = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/
  - L5 = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut2/r5/
  - SUMMARY = W/doc/audit/2026-10-03_p4-health-check/SUMMARY-cut2-offline.md
  - `file:line` means W at 269251f1 unless a prefix says otherwise.

## Findings

### 1. MAJOR (blocks the first live run; docs fix): under ruling (A), `ndt down` from any other checkout still tears down the probe's fabric, and §6 does not say so (SUMMARY:165-195)

**What (A) does and does not fix.** Running in the main checkout puts the probe's claim where main-checkout sessions see it. Other checkouts still cannot see it:
- the claim file is per checkout (ndt:341);
- `foreign_claim` reads only that file (ndt:686-696);
- `ndt down` refuses only on its own checkout's claim, its own declared measurement and four in-flight drivers (ndt:5141-5215);
- it then runs `sudo -n ndtwin-lab topo-stop` on the lab tree (ndt:5356-5357);
- the one-tree guard protects `ndt up` (ndt:2686, 1526-1561), not `ndt down`.

**Scenario.** During the 13–18 minute run, a session in any worktree under scratch/ runs `NDT_OWNER=x ndt down` to tidy up. Its `ndt status` shows `claim none`. Its `down` passes and stops the probe's fabric in the middle of A or B. §6 names this mechanism (SUMMARY:171) only as the reason not to run the probe elsewhere.

**The same family: no check of which tree the helper acts in.** §6 asserts the main checkout is the helper's tree but gives no command to confirm it.
- The default is /home/adam/Desktop/NDTwin-Kernel (ndt:1409); /etc/ndtwin-lab.conf can move it (ndt:1479-1494).
- If it points elsewhere, A's `ndt up` is refused (lab_round.py:376-377).
- The round's teardown still runs `ndt down` (:394-397), which stops whatever the lab tree is running. That is r4 #1 again.

**Fix (§6).**
- Add a precondition: while either run holds the lab, no `ndt down`, `ndt clean` or `sudo ndtwin-lab …` from any checkout. Announce the run to every session.
- Add a command: /etc/ndtwin-lab.conf is absent, or its KERNEL_DIR is the main checkout.
- (A code fix in ndt, making `cmd_down` read `$(lab_kernel_dir)/.test_run/lab.claim`, is outside this branch.)

### 2. MINOR (live run; text now, code optional): more code runs from the shared tree after the clean check than §6 and probe.py say

**"No probe code is read after the check" is false.** probe.py:38-40 and SUMMARY:175 say so, but:
- **The controller trial reads the shared tree's model file.** S0's controller trial (s0.py:694, about 1–2 minutes after the check) execs `<main>/tools/p4_health/exercise/gen_runtime.py` inside the probe process (ctrl_trial.py:37-41, :47). That file supplies the model: hosts, routes, runtime(2).
- **S0 copies `exercise/` without a HEAD check.** s0.py:186-188 makes the copy at S0's start. s0.py:313-316 and lab.py:34-38 then exec it, and it feeds every T1/PL1 expectation.
- **`LAB_PATH_MODULES` cannot see either.** Both files are exec'd by path under the names `hc_gen` and `hc_gen_lab`, which are never registered in `sys.modules`. The list test also skips `exercise/` on purpose (r5-diff.patch:1696).

**SUMMARY:178 is false for some files.** It says an edit made after the check but before the freeze is refused. The freeze checks only the 7 files (frozen.py:36-38), so an edit to `exercise/**` or `openapi_probe.py` is used, not refused. This also contradicts SUMMARY:180.

**SUMMARY:173 is false.** It says other sessions' uncommitted changes elsewhere in the main checkout do not affect the run.
- The clean check covers only `tools/p4_health` (probe.py:155).
- The run also executes, from the shared tree:
  - `tools/p4_exercise/convert.py` and `preflight.py` (s0.py:233, :275);
  - `tools/test_workflow/heartbeat_drop_check.py` (s0.py:297);
  - `ndt` and `qdisc_snapshot.sh`, throughout the run (config.py:114, :125-126);
  - `doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/code_identity.py` and `venv_fingerprint.sh` (probe.py:197-206; identity.py:112, :149).
- The two live-p1 scripts produce `system_under_test` and the interpreters part of the baseline fingerprint, which is exactly what #5 was about.
- An uncommitted edit to any of these, made before the run or during it, is used. `repo_tracked` records its hash at about minute 3; nothing refuses it.
- The worker's list (SUMMARY:180, :365) misses the in-process gen_runtime exec, the two live-p1 scripts, `ndt` and `qdisc_snapshot.sh`.

**Does it matter in a shared main checkout?** Yes, mildly. The window is minutes, and other sessions work in that tree. The session-start git status shows untracked `runs/` directories under live-p1. That is an uncommitted observation of activity there, not of edits to the scripts.

**Fix.**
- Text: correct SUMMARY:173-180, the probe.py:38-47 comment, and the list in §8.3.
- Extend §6's `git status --porcelain` command to `tools/p4_exercise`, `tools/test_workflow` and the two live-p1 scripts.
- Code, before the live run (or Adam defers it):
  - make `ctrl_trial` load `<run>/exercise` (S0 passes `self.ex`);
  - check the exercise copy against `frozen.head` right after `compile_all`, with the same `hash-object --no-filters` comparison.

### 3. MINOR (code; contradicts #2's contract): a stop can still end `probe.py lab` with Python's status 1, which is the see-red pass, and no health.json

- `main()` catches only `Exception` (probe.py:249). SignalAbort is a `BaseException` (lab_round.py:54).
- The run-level raiser (lab.py:117-123) stays installed:
  - from `_stop_on_signals()` until the `try:` (lab.py:205-206);
  - while the `except SignalAbort` / `except Exception` bodies run (:210-222), which now include take_unrecorded's file copies;
  - until the `finally` has restored all three handlers (:223-226).
- A second stop in that window raises out of run_lab and out of `main()`. Python exits 1 and run.sh prints `rc=1`. Example: `kill <pid>` twice in quick succession.
- This contradicts probe.py:11-14 and SUMMARY:233 ("rc 1 means PROBE-BROKEN only"). I found it by reading; it was not exercised.
- **Fix:** catch SignalAbort in `main()` as rc 2 ("stopped; INCOMPLETE"), and/or make the run-level raiser one-shot the way the round's now is (swap in a noter before raising).

### 4. MINOR (code; new in r5): a stop that lands between `_finish` and the handler restore is lost, and B is still claimed

- lab_round.py:402-403 runs `_finish(rec, t0)`, which reads `teardown_signal` on its first line (:407).
- Only then does `_restore_handlers()` run, and its mask begins inside `_swap_handlers` (:311).
- A stop between those two points:
  - goes to `_noter` (:299-304) and sets `teardown_signal` after it was read;
  - is never read again, so `run()` returns a record with no "aborted by signal";
  - `_rounds` sees `signalled()` False (lab.py:140), treats A as ended clean, and claims and brings up B.
- Before r5 the check ran after the restore (r5-diff.patch:2281-2301), so that stop was recorded. The window is tens of bytecodes, but the stop is disobeyed.
- **Fix:** put `_finish` and the restore under one `pthread_sigmask` block. A stop then reaches the run-level raiser when the mask lifts, and take_unrecorded keeps the final record. Alternatively, re-check `teardown_signal` after the restore.
- **NITs at the same place.**
  - A first stop between the end of the try body and the swap inside `_handlers(False)` (:394-395) still raises inside `finally` and skips the teardown. It fails safe through recover.sh.
  - `take_unrecorded` (lab.py:101-109) then writes into health.json a record that `_finish` never touched: `complete` can still be True (set at :389) with `down_rc` and `release_rc` None. Mark records taken before `_finish` as incomplete.
- **No deadlock.** The probe process has no threads (no `threading` under tools/p4_health), so masking the main thread is effective, and nothing waits on a lock.

### 5. MINOR (code; the catch-all, given today's disk): rc 2 can contradict a health.json that already carries a verdict

- run_lab writes health.json at lab.py:257. `report.dump` (report.py:75-78) writes the file in place, not through tmp + replace.
- observations.json (:258-263) and the log lines (:264-267) come after it.
- An `OSError` there reaches `main()`'s catch-all. The probe exits rc 2 and prints "refused: … it is INCOMPLETE, not a verdict", while health.json may say PROBE-BROKEN with empty `problems`.
- ENOSPC is the likely cause: the disk is at 2485 MB, against §6's own "> 2500" (SUMMARY:191).
- §6 tells the operator to read health.json's verdict rather than rc (SUMMARY:233), so this would be read as the see-red pass.
- The handback's "that case has a traceback but no health.json" is false for this path.
- The catch-all message also starts with `refused:`, the same prefix as a deliberate refusal. Since 59d6b014 the tests tell the two apart only by the presence of "Traceback".
- **Fix:**
  - write observations.json first and health.json last, via tmp + `os.replace`;
  - in the catch-all, rename or mark an existing health.json;
  - in §6, say a result counts only when rc and health.json's verdict agree.

### 6. MINOR (the instrument): the GATE line does not name the commit it certifies, and the uncommitted-changes check misses the gate's own scripts

**The GATE line.**
- sum_p4_health_gate_shards.sh:144-145 prints counts only. The script never compares the shards' commit with the commit under review.
- GATE.log:1 shows the commit of the checkout the aggregator ran in, not the shards' commit. GATE.run1_61c19eab.log:1 also says 59d6b014, over logs made at 61c19eab.
- So "GATE: … ok" printed over stale shards would look exactly like this round's GATE.log.

**The uncommitted-changes check.** The `+UNCOMMITTED` pathspec (mutate_p4_health.sh:60-61) leaves out:
- the gate's three scripts, which are now mutation subjects;
- `tools/p4_exercise/*` and `p4_proxy/mininet/grpc_ports.py`, which `fresh_copy` puts under test (:2776-2780).
An uncommitted edit there runs under a log that claims a clean commit, and the aggregator's uncommitted check (:73-74) cannot see it.

**This round's evidence still holds.** Each shard log independently shows 59d6b014 / fbf5a13c / 71b732e6.

**The brief's other questions about the aggregator.**
- Logs from different heads: refused (:118-121, tested).
- A missing shard: refused (:132-133, tested).
- A duplicated shard: refused (:111-112, tested).

**Self-mutation is sound.**
- Only copies are mutated (:2819-2826).
- The inner gate runs with `PYTHON=/bin/true` and `env -u MUT_SHARD …` (test_p4_health_gate_scripts.sh:36), so it cannot run a real baseline.
- The originals are checked byte-identical at the end (:2894-2896).

**Fix:**
- print commit, tree and subject sha in the GATE line;
- refuse when they differ from the checkout's HEAD (or from a required `--commit`);
- widen the pathspec.

### 7. NIT (the instrument)

- **The `(( MUTATIONS == SELECTED ))` guard (mutate_p4_health.sh:2901) cannot fail.**
  - MUTATIONS is incremented at the top of every `mutate()` (:2814), and the loop calls it once per selected index (:2868-2871).
  - The handback lists the guard as "needs a whole shard"; in fact it is unreachable.
  - The aggregator's per-shard share check (sum:134-138) is the real guard.
- **GATES_SUM depends on paths.** It (:2772, :2894) hashes `sha256sum` output, which includes absolute paths. The partial F4 log shows fc6727630a451269 (:82); the shards show 004904542fd1ca40, for identical scripts. Do not compare it across logs.

### 8. NIT (test doubles that encode a guess)

- **FakeController's not-primary s2** (r5-diff.patch:746-747) keeps `set_pipeline_ok: True` and lets every attribution confirm.
  - P4Runtime refuses pipeline pushes and writes from a backup client. The real controller would record `set_pipeline_ok: False` plus `set_pipeline_error` (controller_ext.py:150-156).
  - It is a fair worst case for the rule, but it is not "copied from controller_ext.py" as the handback and SUMMARY:344 say. Label it hypothetical, as was done for `ctrl_garbage_result`.
  - The connected and never-answered shapes are faithful (controller_ext.py:137-157, :334-339; "Empty: " is what `_rpc_error(queue.Empty())` produces).
- **NIT 12's launch uses `sys.executable`,** not the p4dev interpreter B uses (round_b.py:119). "B's exact argv" holds for the argv's shape, not its interpreter.
- **#5's detector** counts only `sys.modules` names starting with `p4_health`. Files exec'd by path (finding 2) are invisible to it by construction.

### 9. MINOR (text): SUMMARY r5 statements the logs do not support

- **SUMMARY:334** says every log opens with `commit <sha> tree <tree> …`.
  - The shard logs and GATE.log open with `commit <sha>` only.
  - disk_watchdog.log has no commit line and no `rc=` line.
  - partial_early_m2 and m2a have no snapshot line; they ran in W at 8437dba4 with uncommitted changes (m2:6-7).
- **SUMMARY:377** says the r5 worker re-ran the b1efe699 archive and got cells 120, collect 130. There is no log of that run in L5. This is the same class as r4 #14's unlogged "re-run alone".
- **SUMMARY:221 and :378, the delta counts.** The output is archived. Its generator is the session scratchpad's `delta.py` (delta_counts.log:2), which is not archived. I read it: 17 lines that run the fake-fabric full run and count deltas. Copy it into L5.
- **SUMMARY:388** lists 9a, 6d, 6o and mC as what the early partial runs caught.
  - partial_early_m2:61-63 also shows a red negative control ("A COMMENT TURNED A SUITE RED: test_an_s0_with_a_failing_check…").
  - That test was red in the gate's copy under every mutant, so in that run 2a and 2b were "caught" for an unrelated reason.
  - d4fb721e then fixed the test's predictions path (r5-diff.patch:271-274). The final gate supersedes it, but the SUMMARY does not mention it.
- **SUMMARY:389, disk.** disk_watchdog.log records only new minima, from 23:40:49 to 23:47:30, and has no end record. Neither "never fired" for the whole gate nor the ~2400 MB upper value is in the log.
- **SUMMARY:78 (§1.3)** still describes the r4 freeze: `git hash-object <copy>` against `HEAD:<path>`. That contradicts :174 and frozen.py:13-24.

### 10. Pre-existing (focus 10): `probe.py judge` cannot read observations.json; this does not block the first live run

- Confirmed by reading: after the JSON round trip, table.py:335 calls `set()` on lists of lists, which raises TypeError.
- Also by reading: once that TypeError is fixed, M1, M2 and C1 compare against frozensets (table.py:414, :425, :434). `[1, 2] != frozenset({1, 2})`, so all three would read RED offline, silently.
- **Why it does not block the first run.** run_lab judges in-process, and §6 never calls `probe.py judge`.
- **What it does mean.** NIT 11's fix is shown only on hand-built recordings. The archived observations.json cannot be used to reconcile the first run with later runs.
- **Fix:** add a round-trip test (run_lab → observations.json → `probe.py judge` → same headline and cells) before any offline re-judgment is used as evidence.

**Smaller NIT on NIT 7.** The freeze pins HEAD only after `load_lab_path` and the clean check. A commit to tools/p4_health in that one second makes `frozen_head` name a commit the preloaded modules were not read from. Pin first, and use the same sha for the clean check.

## Each r4 finding

| r4 | fixed? | red on the old code | green | mutants |
|---|---|---|---|---|
| #1 | §6 rewritten per (A); the procedure is incomplete (findings 1, 2) | — | — | — |
| #2 | yes for the named paths; SignalAbort route remains (finding 3) | behavioural: n2.collect.RED.log:3 (FEEEE), n2.cells.RED.log:12, n2b.cells.RED.log:5-18 | n2.*.GREEN | 2a–2h caught |
| #3 | yes | behavioural: n3.*.RED, `('COMPLETE', 0)` | n3.*.GREEN | 3a–3c caught |
| #4 | yes | behavioural: n4.RED.log:3 (`('COMPLETE', 0)` ×2); n4b is an interface error | n4.GREEN | 4a–4d caught |
| #5 | partly: modules preloaded and S0 runs the copies; gen_runtime exec and the identity scripts remain (finding 2) | n5.RED.log:3: 4 behavioural (identity not loaded during S0, :78), 3 interface | n5.GREEN | 5a–5g caught |
| #6 | yes; gaps in findings 6, 7 | n6.RED.log: 38 of 43; n6.old.* show the old script ending rc 0 after 0 mutations (subject sha 58e7ab10 = r4's) | n6.GREEN, 43/0 | 6a–6z caught (26) |
| NIT 7/8/9 | yes | n789.RED.log:3: 6 behavioural, 2 interface; n9b | n789.GREEN | 7a–e, 8, 9a–c caught |
| NIT 10 | yes for the two named seams; new window (finding 4) | n10_13.RED.log:27, :47, :64 | n10_13.GREEN | 10a–d caught |
| NIT 11 | yes on hand-built recordings only (finding 10) | n11.*.RED | n11.*.GREEN | 11a–f caught |
| NIT 12 | yes | none, by design; the test carries its own control | n12.cells.GREEN | C2R5-12 caught (shard2:567-571) |
| NIT 13 | yes | n10_13.RED.log:37 | n10_13.GREEN | C2R5-13 caught (shard3:555-559) |
| #14 / numbers | mostly; finding 9 | — | — | — |

## Answers to the brief

**2. #1 under ruling (A).**
- **Claim per checkout:** right for main-checkout sessions; other checkouts are blind to it (finding 1).
- **The root helper's single tree:** right while the default stands, but §6 has no check (finding 1).
- **`ndt down` from any checkout:** not handled (finding 1).
- **The `tools/p4_health`-only clean check:** narrower than what the run executes (finding 2).
- **Shared-tree reads after the freeze:** they matter, and the worker's list is incomplete (finding 2).

**3. #5, the preload design.**
- **Is `LAB_PATH_MODULES` complete?** For `p4_health.*` modules, yes:
  - the list test pins it to the package's `.py` files minus four scripts;
  - every lazy import in s0.py and probe.py names a listed module;
  - there is no other `importlib.import_module` or `__import__` of `p4_health`, and no `-m` launch.
- **Where it is not complete:** in-process code exec'd by path (gen_runtime.py), and subprocess launches of shared-tree files (finding 2).
- **Is the worker's argument against re-verifying right?** Half right.
  - A file check does not prove which code was loaded. But preloading has the same hole for an edit made and undone between import and the clean check (the worker concedes this in §8.2). The gain is a shorter window, from about two minutes to under a second.
  - "Cannot cover a module loaded after the check" applies to re-verifying a fixed list. It does not apply to an audit of `sys.modules` at the end of S0, which would catch any late `p4_health` import and back up the list.
  - The choice is defensible, but the stated reason overstates it. Neither approach covers gen_runtime.py.

**4. The catch-all.**
- **The MustNotRun change is sound.** Every "must not start" double on the `probe.main(["lab", …])` path now raises MustNotRun (test_p4_health_cells.py:37, 1680-1681, 1692, 1707-1708, 1739, 1776-1778, 1903, 2272). No code under test has `except BaseException` or a bare `except:`, so nothing can swallow it.
- **Every remaining rc-2 test can tell a refusal from a crash** by a second check:
  - the freeze tests require no "Traceback" (since 59d6b014);
  - the identity test uses `fp.assert_called_once()` with a MustNotRun on run_lab;
  - the F8 test needs gate_fingerprint.json to exist.
  The final gate has 0 survivors.
- **What it can still hide:** finding 5 (an exception after health.json is written) and finding 3 (SignalAbort is not caught, so rc 1 remains reachable).

**9. The disk floor.**
- **This gate:** no sign the low disk changed a verdict. No ENOSPC, Errno 28, HUNG, NO-SUITE or WRONG TEST line appears in the four shards, and the controls and after-checks are green. The long "also red" lists belong to mutants that break shared fixtures by design (H1–H4, hostside, C2R5-2g), spread across all shards.
- **How it could have mattered:**
  - an ENOSPC turns many tests red, and the gate counts a catch whenever the named test is among them (mutate_p4_health.sh:2852). That gives a false catch, not a skip;
  - a watchdog stop, had it fired, could push a suite past `timeout 300`, giving HUNG and a survivor. That fails safe.
- **For the live run the floor matters more:** finding 5, and §6's own "> 2500 MB" precondition fails today.

## Claims audit (the handback)

| claim | class |
|---|---|
| 269251f1 delivered; code and tests final at 59d6b014; tools tree fbf5a13c; two docs-only commits follow (:1) | SUPPORTED (patch :3891-3997; shard :7) |
| not pushed, tracked-clean (:1) | UNTESTED (no evidence quoted; the 59d6b014 test logs show tracked-dirty=0 at that time) |
| every log opens with `commit` and ends `rc=`; exceptions are delta_counts.log and partial_early_* (:3) | CONTRADICTED in detail (see "Numbers that don't agree") |
| the rewrite changed messages only; trees identical (:6) | UNDER-EVIDENCED (SHA-MAP pairs the shas; no log shows a new sha's tree) |
| disk minimum 1915 MB; watchdog never fired; swung up to ~2400 (:8-10) | minimum SUPPORTED for 23:40–23:47; the rest UNDER-EVIDENCED |
| #1: §6 rewritten per (A) (:11-14) | SUPPORTED as text; "works against ndt's real behaviour" UNDER-EVIDENCED (findings 1, 2) |
| an edit before the freeze gives rc 2 (:12) | CONTRADICTED for exercise/** and openapi_probe.py (frozen.py:36-38) |
| after the freeze the run uses only the copies and the loaded modules (:13) | CONTRADICTED in part (ctrl_trial.py:37-41) |
| GATE 397/0, 4/4; 397 = 328 + 69; 100/99/99/99 (:16-18) | SUPPORTED |
| run1 at 61c19eab had two survivors and reads NOT THE GATE (:19-20) | SUPPORTED |
| final checks: 133/133 ok(373), 416/0, 162, 153, 163/0, 43/0 (:22-25) | SUPPORTED |
| #2 reds, greens, mutants 2a–2h (:29-32) | SUPPORTED |
| the catch-all case has a traceback but no health.json (:33) | CONTRADICTED after lab.py:257 (finding 5) |
| the doubles now raise a BaseException (:34) | SUPPORTED |
| #3; #4's rule and red; #5's preload and `S0(frozen=)`; NITs 7/8/9; NIT 13 | SUPPORTED |
| the fake controller's shapes are copied from controller_ext.py (:42) | SUPPORTED except the not-primary shape (finding 8) |
| #5: no probe code is read after the check (probe.py:38-40) | CONTRADICTED (finding 2) |
| #6: refusals, banners, aggregator, 43 checks, red 38 of 43, old-script proofs, 26 mutants (:54-66) | SUPPORTED |
| NIT 10 (:74-80) | SUPPORTED for the named seams; the new window is not covered (finding 4) |
| NIT 11 (:81-86) | SUPPORTED on hand-built recordings; UNTESTED on run_lab's own file |
| NIT 12 (:87-94) | SUPPORTED; "exact argv" holds for its shape, not its interpreter |
| #14 corrections (:98-100) | SUPPORTED except the cells-120 run and delta.py (finding 9) |
| the footer banner and the MUTATIONS == SELECTED guard need a whole shard (:104) | footer: shown in the real shard logs (:620, :626); guard: it cannot fail (finding 7) |
| two survivors explained and fixed (:109-112) | SUPPORTED |
| the observations.json TypeError (:114) | SUPPORTED by reading (table.py:335) |
| S0 still reads shared-tree files (:115) | SUPPORTED but incomplete (finding 2) |

## Tests I would have run

1. Two SIGTERMs about 5 ms apart, sent while run_lab is in its `except SignalAbort` body: check rc and whether health.json exists (finding 3).
2. A stop sent from a hook inside `_finish`, after it has read `teardown_signal`: check whether B is claimed (finding 4).
3. An OSError injected into the observations.json write: compare rc with health.json's verdict (finding 5).
4. In a scratch repo, edit gen_runtime.py after the clean check, with S0 calling the real `ctrl_trial.gen()`: check whether the edit runs (finding 2).
5. An uncommitted edit to live-p1/venv_fingerprint.sh before `probe.py lab`: refused, or only recorded (finding 2)?
6. Two scratch checkouts sharing a fake helper; a fake `ndt down` from the second one during A. Read the headline, `problems`, and the K1/TTL1 reasons for both the full run and the see-red run (finding 1).
   - Related, pre-existing: A's per-step exceptions go only to `A/problems.json` (round_a.py:148-150, :160-163), never into health.json's `problems`. §6 step 5 is the only guard for them.
7. The aggregator, run at a newer HEAD over four clean shards from an older commit: what GATE.log says (finding 6).
8. An uncommitted edit to test_p4_health_gate_scripts.sh during a shard: does the shard log say UNCOMMITTED (finding 6)?
9. The round trip run_lab → observations.json → `probe.py judge`, including M1, M2 and C1 (finding 10).
10. /etc/ndtwin-lab.conf pointing at another tree, with a fake helper: what the probe's teardown `ndt down` stops (finding 1).

## Numbers that don't agree

- **handback:3** says delta_counts.log has no commit line. delta_counts.log:1 is `commit dd2e7300… tracked-dirty=0`. The unlisted exception is disk_watchdog.log, which has neither a commit line nor `rc=`.
- **SUMMARY:342 (the #2 row)** says "4 ERROR … 1 FAIL". That is n2.collect.RED.log alone; n2.cells.RED.log adds a second FAIL.
- **GATE.run1_61c19eab.log:1** says commit 59d6b014, over shards made at 61c19eab (finding 6).
- **GATES_SUM** reads fc6727630a451269 in the partial F4 log (:82) and 004904542fd1ca40 in the shards (:615, :621), for identical scripts (finding 7).
- **The early partial runs.** SUMMARY:388 accounts for 9a, 6d, 6o and mC. The logs show m2 with 1 survivor (the red control), mall with 1 (9a), and mB with 2 (6d, 6o).
- **Counts that add up:**
  - 100 + 99 + 99 + 99 = 397 = 328 + 69;
  - 69 C2R5 headers, 26 of them C2R5-6x; 397 catches;
  - `===` headers per shard = N + 2 (102/101/101/101);
  - collect 147 + 15 new tests = 162; cells 130 + 23 new tests = 153; recover 163, unchanged.

## Conditions before Adam's authorization for the first live run

1. §6 adds the cross-checkout rule and the helper-tree check (finding 1).
2. §6 states what the clean check and the freeze actually cover, and its `git status` command also covers `tools/p4_exercise`, `tools/test_workflow` and the two live-p1 scripts. Alternatively, the code closes the exercise/gen_runtime gap (finding 2).
3. Findings 3, 4 and 5 are fixed. Or Adam defers them explicitly, and §6 then says:
   - a result counts only when rc and health.json agree;
   - after a stop, check that B was not claimed.
4. Free disk is back above §6's floor, with margin for the run's builds and captures. Today it is 2485 MB against "> 2500".
5. If any code changes: all shards are re-run at the new head, the GATE line is shown with the four logs, and that diff gets its own review.
6. Adam's per-run authorization (Q6(a)). The decision on untracked-file churn (`repo_untracked`) is needed before the first record becomes a standing authorization, not before the first run.

Files cited: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/{probe.py, lab.py, lab_round.py, s0.py, ctrl_trial.py, frozen.py, identity.py, round_b.py, report.py, cells/table.py, cells/verdict.py}; .../tests/shell/{mutate_p4_health.sh, sum_p4_health_gate_shards.sh, test_p4_health_gate_scripts.sh}; .../tools/test_workflow/ndt; /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut2/r5/ (GATE*.log, mutate_p4_health.shard*of4.log, partial_early_m2.log, disk_watchdog.log, delta_counts.log); /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/delta.py (unarchived).