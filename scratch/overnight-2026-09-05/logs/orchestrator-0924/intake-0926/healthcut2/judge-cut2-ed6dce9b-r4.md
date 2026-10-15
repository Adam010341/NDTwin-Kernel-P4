# Judge r4: P4 health check, Cut 2 offline. r4 fix diff only (`feat/p4-health-cut2`, b1efe699 → ed6dce9b; code head 2e630d34)

[Co-developed with claude code -- Adam]

## How I judged it

I worked read-only: no git, nothing executed, no files written.

- **Read:**
  - r3 §5 (the F1–F10 definitions) and the orchestrator's F3 decision as quoted in the brief;
  - r4-diff.patch and r4-merges-cc.txt;
  - the handback, as claims to check;
  - the code and tests at the checkout;
  - every log under r4/, including item11/;
  - the SUMMARY, because it is part of the diff.
- **Spot-checked**, because the SUMMARY or the code cites them: tools/test_workflow/ndt, tools/p4_exercise/*, recover.sh, run.sh, .gitattributes, and four r2 logs that SUMMARY §2 rows name.
- **Not read:** INTAKE.md, the r1 and r2 reviews, the other handbacks, DESIGN.md.

**Paths.**
- W = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/
- L4 = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut2/r4/
- SUMMARY = W/doc/audit/2026-10-03_p4-health-check/SUMMARY-cut2-offline.md
- `file:line` refers to W unless a prefix says otherwise.

## Verdict: MERGE AFTER FIXES

**What is sound.**
- **The fixes:** F1, F2 (every exit with no controller result), the F3 decision (a) and (b) inside run_lab, F4(a), F4(b), F6, F8 and F9. Each has:
  - a red on the old code (behavioural, or carried by a caught mutant where the red is only an import, attribute or type error);
  - a green;
  - caught mutants.
- **The gate:** 328 mutations, 0 survived. I checked all four shard logs:
  - same commit (2e630d34), tree (e42f47f9) and subject sha (58e7ab10);
  - 82 mutations each, 84 `===` headers each (baseline + 82 + control);
  - in every shard the baseline is green, the control is green, the files are byte-identical and the after-check is green;
  - `rc=0` in each (shard*of4.log:1, 6-8, 11, 507-515).
- **The merges:** both are clean. r4-merges-cc.txt has two headers and no hunks.
- **No refusal is loosened:**
  - the clean check is unchanged (probe.py:114-123);
  - the freeze adds a refusal before S0 (probe.py:126-134);
  - the identity refusal is unchanged (probe.py:162-167);
  - run_verdict only adds INCOMPLETE outcomes (verdict.py:371-376);
  - run_lab's unchecked freeze (lab.py:170) runs only when no `frozen` is passed; cmd_lab always passes one (probe.py:170-172), and C2R4-F4i pins that (shard2:493-497).

**What blocks:** #1, a MAJOR defect in SUMMARY §6 text that would break the first live run. #2–#6 should be fixed, or explicitly deferred by Adam, before that run. The rest are NITs.

## Findings

### 1. MAJOR: §6's "dedicated clean worktree" cannot be followed as written; forced, it separates the lab claim from the lab (SUMMARY:168-170, 174-183; commit cecea49b)

**Where.**
- SUMMARY:168 says to run in a dedicated clean worktree built on the trunk sha, not the main checkout. :174-183 run every command from `<checkout>`.
- **run.sh** (run.sh:8-9) exits 2 unless `<checkout>/p4_proxy/venv/bin/python` exists or P4_PROXY_PY is set.
  - Under W, Glob finds no `p4_proxy/venv/bin/python` and no `build/bin/ndtwin_kernel`. It does find `build/bin/ndtwin_kernel` in the main checkout.
  - The r4 logs ran the main checkout's interpreter (L4/f1.RED.log:2).
- **`ndt up p4` refuses from such a tree.** It runs preflight (ndt:3423), which refuses:
  - unless `sudo ndtwin-lab` acts in this checkout (ndt:2691, guard at 1526-1561: "It names ONE tree, so two worktrees cannot both be live at the same time", :1558);
  - unless the kernel binary, the proxy venv and the compiled pipeline exist in it (ndt:2699-2703).
  - ndt:1507-1508 records the helper acting in the main checkout on 09-10.
- **The claim is per checkout.**
  - `CLAIM="$REPO/.test_run/lab.claim"` (ndt:341); ".test_run/ is per checkout" (ndt:6513).
  - The probe uses the ndt and the claim file of its own checkout (config.py:114, 117, 143-144; lab_round.py:248-257, 336).
- **`ndt down` acts on the lab tree whatever checkout runs it.** It refuses only on its own checkout's claim, its declared measurement and four in-flight drivers (ndt:5141-5215). It then runs `sudo -n ndtwin-lab topo-stop`, which acts on the lab's tree (ndt:5356-5357).

**What happens if §6 is followed literally.**
1. run.sh exits 2 at once. The operator sets P4_PROXY_PY.
2. S0 and identity run (about 3 min). A claims the lab in `<worktree>/.test_run/lab.claim`, a file no session on the main checkout reads.
3. Preflight refuses `ndt up p4 --app`. LabRound's teardown runs `ndt down` from the worktree. That down passes its local checks and topo-stops whatever fabric the lab tree has, for example one another session brought up from the main checkout in those minutes under a claim the worktree cannot see.
4. A non-zero down leaves the probe's claim unreleased (lab_round.py:470-474). The run reads INCOMPLETE.

If root instead re-points KERNEL_DIR (ndt:1551-1557) and the kernel, venv and pipeline are built in the worktree, the run can work. But for 13–18 minutes the lab's claim lives in the worktree:
- `ndt status` on the main checkout prints `claim none`;
- an `ndt down` from the main checkout topo-stops the probe's fabric.

**Fix (needs Adam's ruling: the root helper config, and Q6(a)).** Pick one:
- **(A)** Run in the tree `ndtwin-lab` acts in. The r4 freeze and HEAD check now cover what root and B execute. Settle the untracked-file churn in the fingerprint separately (identity.py:91-97), and fix #5.
- **(B)** Keep the dedicated worktree, and §6 must list:
  - the root re-point, and putting it back afterwards;
  - building the kernel, venv and pipeline there;
  - setting P4_PROXY_PY;
  - that every session reads `ndt status` from that worktree while it holds the lab.

r3's F4 fix bullet asked for the worktree without any of these steps. The gap is in that recommendation as much as in r4's text.

**Class:** CONTRADICTED, by ndt's own code.

### 2. MINOR (fix before the first live run): rc 1 still means three things on the see-red path

- **Where:**
  - S0 not COMPLETE returns 1 with no health.json (probe.py:143-145; lab.py:163-165).
  - run_lab catches only SignalAbort (lab.py:175-185). Any other exception exits with Python's status 1 and no health.json:
    - LabRound's StateInUse (lab_round.py:176-179, raised at lab.py:124 or 145);
    - a failure in load_model or expectations (lab.py:166-167).
- **Scenario:** `--mutant --only K1,TTL1 --bringups A` is re-run in a run dir with an unfinished LAB_STATE.json, or S0 has one failing check. run.sh prints `rc=1`, the value §6 calls the pass (SUMMARY:221).
  - SUMMARY:222 says such a run reads INCOMPLETE rc 2. That is false for these paths.
- **Fix:**
  - in lab mode, return 2 when S0 is not COMPLETE;
  - catch Exception around `_rounds`, record it as a run problem, and still write health.json;
  - say in §6 that the pass is health.json's PROBE-BROKEN with the K1 and TTL1 reasons, never rc alone.

### 3. MINOR: a see-red run whose mutant is not caught reads COMPLETE rc 0 (verdict.py:371-380; lab.py:199)

- This is the "the probe cannot see red" outcome, and run.sh and anything else that reads rc see it as success. The worker states it as a residual (SUMMARY:292).
- **Does it block the first live run?** No, if §6 is followed: §6 predicts PROBE-BROKEN rc 1.
- **Fix (one line):** when `see_red` is set and no cell is PROBE-BROKEN, return a non-zero verdict. Add a test with `count_k1=True`, `ttl_decrements=True` and `mutant=True`, plus a mutant.

### 4. MINOR: a B that ran but confirmed nothing reads COMPLETE rc 0, and SUMMARY:214-215 overstates F2

- **Where:**
  - `failed` is set only when the result is None (round_b.py:168-172);
  - the controller writes its result whether or not it connected or became primary (controller_ext.py:330-359, writes at :348 and :359);
  - an unconfirmed item counts as False (attribution.py:187-190).
- **Scenario:** every switch has a `connect_error`, or s2 is not primary. Every attribution is unconfirmed, `failed` stays None, and the run reads COMPLETE rc 0 with no problems. That is r2's N2 consequence by a seventh route.
  - SUMMARY:215's "(第 4 輪 F2 已修)" implies "COMPLETE plus no problems means B did its part". The code enforces only the result-None half.
  - Step 6 of §6 (SUMMARY:241-244) still catches it by hand.
- **Fix:** mark B failed when nothing except the expected `register` is confirmed, or when s2 is not primary with `set_pipeline_ok`. Add a run_lab test where the controller's result carries `connect_error` on every switch.

### 5. MINOR: residual of F4(a). Probe code that runs after the clean check is outside the freeze

- **Where:**
  - `identity` and `vs_trial` are first imported after S0 (probe.py:148-149), about 2 minutes after the check at :114. identity.py computes the gate fingerprint that becomes the standing authorization's baseline (:156-160).
  - S0 imports `vs_trial` and `ctrl_trial` lazily (s0.py:527, 559, 584-585, 611).
  - S0's controller trial runs the shared tree's controller_ext.py (ctrl_trial.py:77). The worker did not list this residual.
  - S0's adapter dry-run runs the shared tree's adapter (s0.py:645, 649). The worker did list this one.
  - frozen.py:5-8 and SUMMARY:79 name three places probe code runs. The probe process itself is a fourth.
- **Scenario:** in a shared checkout (option A), someone edits identity.py during S0. The baseline fingerprint is then computed by unchecked code, and nothing records that.
- **Fix:**
  - import every module the lab path uses before the clean check, or re-verify each loaded `p4_health` module's file against its HEAD blob just before run_lab;
  - pass `frozen` into S0, so the controller trial and the dry-run use the copies. That also closes the worker's stated residual.

### 6. MINOR (the measuring instrument): a sharded or prefixed gate can run nothing and exit 0; nothing adds up the shards (tests/shell/mutate_p4_health.sh:2375-2385, 2412-2415)

- **What is correct:**
  - malformed `MUT_SHARD` values are refused;
  - every shard runs its own baseline (:2364-2368), negative control (:2387-2402), byte-identity check and after-check (:2404-2410);
  - a red baseline exits 2.
- **The gap:** a well-formed `MUT_SHARD=400/500`, or an `ONLY_LABEL_PREFIX` that matches nothing, runs 0 mutations and ends `rc=0`. A single shard's `rc=0` is not the gate, and no script checks that n logs share one HEAD, tree and sha and that their counts add up to the table.
- **This round:** the four logs do add up. Nothing in the script makes them.
- **Fix:**
  - refuse n > `${#MUT_LABEL[@]}` and `MUTATIONS == 0`;
  - add an aggregator, or print "NOT THE GATE" on every shard log.

### 7–13. NITs

7. **HEAD is resolved again for every file** (frozen.py:81), and `repo_identity` reads HEAD after the freeze (probe.py:137). A commit that lands mid-freeze gives a frozen set that matches no single commit.
   - Fix: pin `git rev-parse --verify HEAD` once, compare against `<sha>:tools/<rel>`, and record that sha.
8. **`git hash-object` runs without `--no-filters`** (frozen.py:80), so the check compares the copy after input filters. Today no attribute applies to these files (.gitattributes:18-35 covers doc/audit only; there is no .git/info/attributes). Only core.autocrlf could act, and CRLF does not change what Python runs. So there is no practical bypass. Adding `--no-filters` would make the check byte-for-byte.
9. **The freeze follows symlinks at the destination** (frozen.py:71-76). A symlink already at `<run>/frozen/<rel>` is written through, both hashes read through it, and root then runs the link's target, which stays editable after the freeze. A reused run dir also loses its earlier frozen evidence without a word.
   - Fix: refuse when `<run>/frozen` exists, or open with O_EXCL|O_NOFOLLOW.
10. **Signal windows in lab_round.py:**
    - A second signal after the body's SignalAbort but before the noter is installed (:373-378, :307-312) raises inside `except` or `finally` and skips the teardown. The run still ends with "outside a bring-up's body … recover.sh", so it fails safe.
    - A signal just after `_restore_handlers()` (:382) raises out of `run()` before `return rec`, and that round's record is missing from health.json.
    - Fix: have the raiser install the noter before it raises, or block signals with pthread_sigmask across the switch.
11. **`probe.py judge` ignores the F3 decision** (probe.py:88). It never passes `stopped` or `see_red`, so a recording that carries "aborted by signal" plus a PROBE-BROKEN cell reads PROBE-BROKEN offline.
12. **Test doubles and labels:**
    - `ctrl_garbage_result` ("cut off mid-write", test_p4_health_collect.py:1400, 1869-1871) models a failure the real controller cannot produce: it writes through a tmp file and `os.replace` (controller_ext.py:399-404). Label it hypothetical.
    - "runner.py:62-65" (test :1399; SUMMARY §7.1) points at the env lines. The OSError → None return is at runner.py:66-71.
    - The frozen-set test (test_p4_health_cells.py:1745-1761) runs `sys.executable -I`, loads controller_ext through importlib, and calls the adapter only with `--help`. The real B launch (p4dev Python, no `-I`, adapter → runpy) is never exercised offline.
    - The `adapter_argv` docstring "S0 runs the same argv" (round_b.py:45-48) is no longer true.
13. **`rec["complete"]` ignores `knobs_restored`** (lab_round.py:466-469, 387-388). If the telemetry knob fails to restore while the release still succeeds, the round reads complete, so a see-red run can still pass. This predates r4, but it matters for F3(b)'s "complete and clean". Step 2 of §6 catches it by hand.

### 14. MINOR (text): SUMMARY r4 statements the logs do not support

- **§7.1 F4 counts** (:264, :269). The SUMMARY says two tests failed only because the module did not exist yet, and that cells had 5 behavioural reds. The logs show:
  - three module-missing errors: f4.RED.log:5-31 has two, f4.collect.RED.log:5-11 has one;
  - three behavioural cells tests, with 11 failing subtests (f4.RED.log:3, :215).
- **§6 delta, "57 cells: same 30, not observed 27"** (:209). No output is archived. test_a_then_b_then_the_verdicts pins only VB1 and "no cell flipped" (test_p4_health_collect.py:2473-2475).
- **§7.2 S0 dry-run** (:291), "it runs after the freeze, so it is the same HEAD content". This does not follow: the HEAD check is of the copies, not of the shared file S0 runs later. It also leaves out ctrl_trial (#5).
- **§6 :178**, "`--measuring` prints only declared and measuring rows". It can also print an `orphaned` row (ndt:6803-6807; recover.sh:309-316 relies on that row).
- **§2 :115**, "m3's red is an interface error". m5's is (r2/m5.OLD_red.log:2-3). m3's archived red is shared with MAJOR-2 and has two FAIL lines (r2/major2_m3.OLD_red.log:58-61), so the log alone does not show that.
- **§7.3 :304**, "both mutants re-run alone and caught". There is no log of that. The full re-run supersedes it: shard0:433-437 and :445-449 show both caught.

## The r3 items and the F3 decision

- **F1: fixed. SUPPORTED.**
  - Code: lab_round.py:307-312 and 383-385.
  - Red at 5391a7f4: f1.RED.log:31 and :38 show `(2, 2) != (1, 1)`, with two claims and two ups in the ndt list; :47 shows `('COMPLETE', 0)` for the stop in B's teardown.
  - Green: f1.GREEN.log.
  - Mutants C2R4-F1a–d caught (shard2:457-461, shard3:457-461, shard0:463-467, shard1:463-467).
  - The tests use the rounds' real handlers (test_p4_health_collect.py:1176, 2586).
  - Edge windows: NIT 10.
- **F2: fixed for every exit with no controller result. SUPPORTED as scoped.**
  - Code: round_b.py:148-153 and 168-172.
  - f2.RED.log:3 reads `...F.F`: exits 4 (sniffer) and 6 (unreadable result) are red; exits 1, 2, 3 and 5 were already correct, so their tests are new coverage only.
  - Mutants C2R4-F2a–f caught.
  - The broader claim is wrong: #4.
- **F3 and the decision: (a) and (b) are SUPPORTED inside run_lab.**
  - Code: lab.py:196-199 and verdict.py:371-376.
  - f3.RED.log has 5 behavioural reds, each PROBE-BROKEN 1 instead of INCOMPLETE 2.
  - The red in f3.cells.RED.log:12 is only a TypeError; F3a and F3d carry that behaviour.
  - Mutants F3a–f caught. F3e was re-pointed after it went wrong-test in a partial run (see "Numbers that don't agree"); the re-point is justified, because rule (a) is what makes the old expected test green.
  - Outside run_lab the rc is still ambiguous: #2.
- **F4.**
  - **(a) Early freeze and HEAD check: SUPPORTED.**
    - Code: probe.py:126-134 and frozen.py:62-88.
    - Red: f4.RED.log reaches S0 ("(None, True)") for an edit to each of the seven files and for each of the three git failure shapes.
    - Mutants F4a–d caught.
    - Residuals: #5, #7, #8, #9.
  - **(b) B runs from the copy: SUPPORTED.**
    - The argv uses the copies (round_b.py:117-118; lab.py:171-173); the red is f4.collect.RED.log:29-42.
    - Mutants F4e–g and F4j caught.
    - By reading, the imports also resolve to the copy: the adapter puts `<run>/frozen` at sys.path[0] before `from p4_exercise import common` (run_external_controller.py:34-36). controller_ext then finds that directory already on sys.path (controller_ext.py:38-40), and its `frames` imports (:300, :311) resolve there, ahead of PYTHONPATH.
    - Caveat: in the copy, `common.REPO` is the run dir (common.py:15-17). The adapter does not use it today.
    - The real launch is UNTESTED (NIT 12).
  - **(c) The dedicated worktree: CONTRADICTED** (#1).
- **F5:** fixed on the merged branch, which is reviewed separately. My spot-check: test_p4_health_cells.py:1198-1207 checks text only, and :1234 and :1246 skip when the files are absent.
- **F6: fixed. SUPPORTED.**
  - Code: round_b.py:127.
  - The teardown (lab_round.py:278, 397) and recover.sh (:159-165, 174-179) both compare against the stored marker. Sniffers use the token (hosts.py:123) and are unaffected.
  - Red: f6.RED.log:12.
  - Mutant C2R4-F6 caught (shard0:499-503). C2-RB2 was re-anchored and is caught (shard2:385-389).
- **F7:** the text was changed; see #1, #2, #4 and #14.
- **F8: SUPPORTED through its mutants.**
  - The red is an AttributeError only (f8.RED.log:17).
  - C2R4-F8a and F8b are caught (shard1:499-503, shard2:499-503), and a control test with a readable override passes.
- **F9: SUPPORTED.**
  - The red is an ImportError only (f9.RED.log:11).
  - C2R4-F9 is caught (shard3:499-503).
  - The spawn-None and no-result exits now have run_lab tests (test_p4_health_collect.py:2715, 2738).
  - `show_ports_trial` still has no unit test, as stated.
- **F10:** not done, as stated. It does not block: `CPU_PORT = 510` is skipped either way (observe_a.py:604).

## Answers to the brief's other points

- **Freeze timing:** it runs before anything touches the lab.
- **Can the HEAD check be fooled?**
  - two empty answers: refused;
  - git missing, rc 128, or a timeout: refused;
  - a copy outside the repo: works, as the green control test shows (git hash-object on /tmp copies against a scratch repo);
  - symlinks: NIT 9;
  - filters: NIT 8;
  - HEAD moving mid-freeze: NIT 7.
- **F1's windows:**
  - a second signal is handled: the first is kept;
  - a signal during B's teardown is handled (:2605);
  - between the freeze and S0 the probe has no handler (run_lab installs it at lab.py:174). The default action kills it: no lab touched, no health.json. S0's throwaway switches could be orphaned, which predates r4.
- **The two survivors at 56b27f60:**
  - run1 shard0:433-436 and :444-447 show them;
  - the 2e630d34 stubs (test_p4_health_cells.py:1529, 1556) make reaching the freeze an error, so rc 2 must now come from the check before it;
  - this restores the test's discrimination and does not hide the ambiguity: final shard0:433-437 and :445-449 show both caught.
- **Test doubles:** these are faithful copies of the real tools:
  - the self-SIGTERM inside the fake `ndt down` (the handler runs, then the wait resumes). It models a stop sent to the probe's pid only: a process-group stop would also kill `ndt down` itself, which then fails safe through down-failed;
  - spawn returning None;
  - real git in a scratch repo;
  - the "deaf" sniffer.

  The exceptions are listed in NIT 12.
- **The worker's stated residuals:** none of them blocks the first live run.
  - the S0 dry-run on the shared tree: fold it into #5;
  - a see-red run with nothing PROBE-BROKEN reading COMPLETE rc 0: #3;
  - F10;
  - the claim left after a SIGTERM during `ndt claim`: this fails safe. recover.sh prints the release command only when its run-dir argument spells the same `state=` path the probe used (recover.sh:231).

## Claims audit (the handback)

| claim | class |
|---|---|
| F1 fixed, with real handlers; the predicted red | SUPPORTED |
| F2: six exits, two behavioural reds | SUPPORTED |
| F3 (a) and (b) | SUPPORTED within run_lab; CONTRADICTED at the rc level (#2) |
| F4: early freeze, 7 files checked against HEAD, B from the copies | SUPPORTED; the real B launch UNTESTED |
| §6: run in a dedicated clean worktree | CONTRADICTED (#1) |
| F6, including "still red after F4 alone" | SUPPORTED (that sub-claim is unarchived, but mutant F6 at the final head gives the same evidence) |
| F8 and F9 behaviour carried by mutants | SUPPORTED |
| 328 mutations, 0 survived; 4 shards × 82; controls green | SUPPORTED |
| collect 147, cells 130, recover 163, seal 147, anchors ok(306), tmpdirs 414/0 | SUPPORTED (logs) |
| Item 11: 241/35/24, no partial claim files, recover rc 2 | SUPPORTED (claim_kill_300.log:3-5, recover_claiming.log, release_states.log, probe_side.log) |
| "both survivors re-run alone and caught" | UNDER-EVIDENCED (no log); superseded by the full re-run |
| Delta 30/27 over 57 cells, "checked on a fake run" | UNDER-EVIDENCED |
| "Three doc-only commits follow" 2e630d34 | CONTRADICTED: the patch and the handback's own list show two |
| Commit messages are clean | SUPPORTED (I scanned the patch's messages) |

## Tests I would have run

1. Preflight's tree guard and its kernel/venv checks from a fresh worktree, and what LabRound plus recover.sh do after the refused `ndt up` and the `ndt down` that follows (#1).
2. A see-red run where S0 is PROBE-BROKEN, and one with a leftover LAB_STATE.json: rc, and whether health.json exists (#2).
3. A see-red run whose mutant is not caught (#3).
4. run_lab with a controller result that has `connect_error` on every switch, and one where s2 is not primary (#4).
5. identity.py edited during a fake S0 (#5).
6. A commit landed between two files of the freeze (#7); a symlink planted at the frozen destination (#9).
7. `MUT_SHARD=400/500`, and `ONLY_LABEL_PREFIX=NOPE` (#6).
8. A second SIGTERM injected while `_handlers(False)` is switching handlers (NIT 10).
9. The frozen adapter launched exactly as B launches it, then a check that `sys.modules` holds nothing from the shared tree.
10. `probe.py judge` on a stopped recording (NIT 11).

## Numbers that don't agree

- **The handback:** "Three doc-only commits follow it" (handback:3). There are two: d8ce630b and ed6dce9b.
- **"Every log ends with `rc=`"** (handback:3; SUMMARY:252). stopped_by_me_at_18_to_shard.log ends at the M18 header (:121-123).
- **recover_claiming.log:3, 18, 33** label the states with 39, 18 and 187 out of 300. Those counts come from the unarchived run; the archived claim_kill_300.log has 35, 24 and 241.
- **partial_F1-F3.log:97-100 and :117-119:** C2R4-F3e was a WRONG-TEST survivor at 551b2751. cbc47503 fixed it, and neither the SUMMARY nor the handback mentions it.
- **The F3 targeted green** (f3.GREEN.log, at 0fa6902a) predates 3b283c48's flag rewrite. The shipped code is covered by the full-suite green at 2e630d34 and by mutants F3b and F3c.
- **Counts that do add up:**
  - 298 + 30 = 328 = 4 × 82;
  - collect: 130 + 17 new = 147;
  - recover: 163, unchanged;
  - 241 + 35 + 24 = 300, and 187 + 39 + 18 + 56 = 300.
- **Cells:** 119 + 10 new = 129, but the logs show 130. The extra test presumably comes from the merged branch; I did not verify it.

## Conditions for merging

1. Adam rules on which tree the first live run uses, (A) or (B), and §6 is rewritten to match (#1).
2. #2, #3 and #4 are fixed, each with a test seen red and a mutant, or Adam explicitly defers them and §6 says how to read rc and the headline.
3. #5 is fixed if Adam chooses (A).
4. #6 is fixed before the next gate is used as evidence.
5. The #14 text and the numbers that don't agree are corrected.
6. If any code changes: all shards are re-run at the new head with a line that adds them up, followed by a judge pass on that diff only.
7. No live run before all of the above.
