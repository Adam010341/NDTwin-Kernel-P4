# Review r7: P4 health check, Cut 2 offline (`feat/p4-health-cut2`, b518b9fb → 4a8cdf7b; the gate certifies code commit 7a7a2577)

(Opus judge, read-only, 2026-10-10 ~23:2x. Saved verbatim by the orchestrator from the hand-back.)

## Verdict: MERGE AFTER FIXES

- **Before trunk:** one docs-only SUMMARY commit, plus three archived checks that each take seconds (finding 6). No gate re-run is needed. None of these fixes touches a WATCHED path (mutate_p4_health.sh:64-74), so the GATE stays tied to `--commit 7a7a2577`.
- **Before the first live run:** run the pre-claim checks once offline against a real S0 process (they have never seen one). Add a stop instruction to §6 (finding 4). The standing items from r6 still apply.
- **Can the code at 7a7a2577 go to trunk?** Yes, as offline code. The fixes are correct, I found no live-path failure that is unsafe, and the 473-mutant gate holds. The SUMMARY at 4a8cdf7b does not record that gate yet (finding 1); fix that before trunk.

## How I judged it

- **Constraints.** Read-only. No git, nothing executed, no files written. The commit messages were only available to me as subjects (r7-commits.txt). Throughout, [read] means I saw it in a file, [inferred] means I reasoned it from code, and [claim] means it is asserted but no evidence was archived.
- **Paths.** R = …/scratch/overnight-2026-09-05; W = R/wt-p4-health-cut2; L7 = R/logs/gates-0910/p4-health-cut2/r7; N = R/logs/gates-0910/nslab-a13-1010; S = W/doc/audit/2026-10-03_p4-health-check/SUMMARY-cut2-offline.md; D = …/healthcut2/r7-diff.patch; J = …/intake-0926/OVERNIGHT-1004.md; SP = the session scratchpad (/tmp/claude-1000/…/6f189e52-…/scratchpad).
- **Read in full:** D (1129 lines), the r6 review and its hand-back, S §6 and §10–§11, J:199-232, the N README, GATE.nslab.log, driver.log, run_shard.sh, chain.sh and compare_shards.py.
- **nslab shard logs:** headers, tallies and every C2R6/C2R7 block of all four. Whole-file greps for counts and for bad lines.
- **Laptop shard 0:** lines 1-39 and 600-743. First-gate logs: headers, tails and the r6/r7 regions.
- **Other L7 logs:** every n1–n4 RED/GREEN log, repro.4c.*, partial_r7b_*, obs.grpc_threads.log, dev.quickmut_C2R7.log, final.*, both gate_disk_polls logs, both disk_watchdog logs, and partials.log.
- **Code read:** lab.py and throwaway.py in full; s0.py:140-340 and :585-743; frozen.py, probe.py, vs_trial.py and runner.py in full; lab_round.py:290-450; test_grpc_port_block.py:360-554; mutate_p4_health.sh:1-200 and :3296-3493; sum_p4_health_gate_shards.sh in full; the relevant parts of both suites.
- **Outside the named inputs:** only the helper scripts that the logs and S cite by name, in SP (partials.sh, partials2.sh, gate_driver.sh, gate_driver1700.sh, watchdog.sh, grpc_threads.py, pinb_by_hand.sh, quickmut.py).
- **Worktree caveat (uncommitted observation):** where I compared, W's files equal D's post-image. I cannot confirm that W is clean or at 4a8cdf7b.

## 1. The r6 findings and "Before trunk"

| r6 item | r7 | Evidence |
|---|---|---|
| 1 (the mask only covers one thread) | **Fixed in code** | Fix: s0.py:156-169 and :597-600 (the trial runs blocked); lab.py:132-169 and :282-289 (refuse before the first claim); throwaway.py:106-109. The test r6 asked for (the finish-hook test plus one running thread) exists as collect:3268-3324 and the three `test_a_running_thread_*` tests. Reds on the old code: n1.collect.RED.log:85-191 (3 behavioural: two `ndt claim`s each); :5-82 (5 interface-only, `PROC_TASK` missing); n1.cells.RED.log:126-187 (6). All 18 C2R7-1x mutants are caught in the gate. **Not done:** the real-S0 thread count r6 asked for (S:603). |
| 2 (stops and disk text) | Fixed | Corrected stop text S:518-523 (19:39:23, ~21 min, the r5 watchdog; shard 1 17:31:53–17:32:53); run1 comparison cited at S:537; log-format sentence at S:475. |
| 3 (pin re-check caught only by its message) | Fixed | Commit moved to lab.py with the behavioural assertion first: D:522-534. Red: n2.pinb_by_hand.RED.log:14 `(None, <Frozen>) != (2, None)`. Gate: nslab shard2:659-663 caught. S:494 corrected; C2R6-5b recorded at S:610. |
| 4 (stale §6 citations, two sentences) | Fixed (one residual: finding 2) | I checked every new number against the code and all are right: probe.py:174, :61-69, :160, :233-242; frozen.py:42-44; s0.py:698, :265, :307, :329; lab_round.py:395-398, :416-419. Sentence 1 fixed at S:198; sentence 2 fixed at S:196 and probe.py:47-52, plus the code re-check at lab.py:274-275. |
| 5 (gaps §10.2 did not list) | Recorded, not changed (allowed) | S:612-616 |
| Before trunk 1 (docs commit) | Done (67af72b3, 4a8cdf7b) | — |
| Before trunk 2 (SIGCONT watcher gone) | [claim] | S:596-597 and J:202. No `ps` output archived. |
| Before the live run 1 (code fix, finding 3's test, the re-check) | Done | See above. |

## 2. The production code

**s0.py: `stops_held` around the ValueSet trial.**
- Correct [read]. It blocks the three signals, restores the old mask in `finally`, and covers both `VT.trial` calls.
- grpc is imported inside `trial` (vs_trial.py:64), so the import and every gRPC thread happen under the block. Nothing else in the package imports grpc into the probe process: grep finds only vs_trial.py:64, and controller_ext.py imports `p4runtime_lib` lazily at :93-96, only in its subprocess [read + inferred].
- obs.grpc_threads.log:101-118 shows threads started under the block keep SigBlk 0x4003 after the caller unblocks.
- What it does beyond what the commit message says, by reading [inferred]:
  - (a) Every child forked during the trial inherits the block, not only the bmv2. The `simple_switch_CLI` calls (vs_trial.py:120 → throwaway.py:205-213 → runner.py:49) run with the three signals blocked. This is harmless: they are short-lived, and `subprocess.run` kills with SIGKILL on timeout.
  - (b) A SIGINT during the trial surfaces as a KeyboardInterrupt from the restore at s0.py:169. Nothing catches it: s0.py:601 catches `Exception`, and probe.py:299-319 catches only SignalAbort and Exception. The process ends with Python's exit-by-SIGINT, before any claim and with no health.json. The docstring's "the default action ends the process" is exact only for SIGTERM and SIGHUP.
  - (c) A hung trial now ignores SIGTERM: vs_trial.py:95 `next(stream)` has no deadline, so only SIGKILL ends it. S:575 says so; §6 does not (finding 4).
- All three of these happen in S0, before any lab action, and the throwaway switches die by PDEATHSIG (throwaway.py:101). **Not unsafe.**

**throwaway.py:106-109.** Correct. The unblock applies to every throwaway child (:190), which is harmless.

**lab.py: thread check.**
- Correct as a point-in-time check [read]: the bits sum to 0x4003 (:129); the caller is skipped by native id (:147, :150); a thread that vanished is skipped (:158-159); an unreadable status, a missing or non-hex SigBlk, or an unlistable /proc is a refusal (:144-146, :157-161).
- Placement: after set-up and before `_stop_on_signals` (:296) and `_rounds` (:298). A refusal takes the existing INCOMPLETE rc 2 path, which writes health.json.

**lab.py: exercise re-check.**
- Runs only when `frozen.head` is set, which is the live path (probe.py:203). `Refused` is a RuntimeError (frozen.py:52), so a refusal takes the "could not be set up" path (lab.py:279-281). Correct.
- Gaps, both fail-safe:
  - The check, like S0's, ignores `build*` (frozen.py:49, :121-131). So the p4info files `expectations` reads (lab.py:51-53) and B's build dir (:229) are never re-checked. This is unstated.
  - The ctrl_trial ordering issue (finding 2).

**lab_round.py, probe.py, frozen.py.** Comment and docstring changes only (D:916-926, :1020-1053).

**test_grpc_port_block.py (ae753c29).** Correct and minimal [read].
- It adds one entry keyed on file plus exact stripped line (:446), and that key matches controller_ext.py:42.
- The staleness test (:530-540) holds the key to the file.
- controller_ext.py:42 is the only 5005x literal under tools/p4_health, and its reason text matches :135 (the controller dials 50050+dpid).
- doc/audit is excluded as a tree (:394), so the SUMMARY's own mentions of 50050 do not trip it.
- Red on b09cd060's test (n4.grpc_port_block.RED.log:38-50), green at 4a8cdf7b (final.grpc_port_block.log:38-41). Public trunk stays red until this branch lands.

## 3. The test fix for the first gate's REFUSED

**The stated cause is SUPPORTED** [read].
- repro.4c.collect.log:157-163: a KeyboardInterrupt is raised inside `_signal.pthread_sigmask`, called from `background_thread`'s `SETMASK({SIGTERM, SIGHUP})` (test file line 3260 at 67af72b3).
- Relative to a leaked {TERM, INT, HUP} mask, SIGINT is the only signal that call unblocks. So a SIGINT was pending, and a signal can only be pending if the mask was blocked.
- The log has no `Ran N` line. Cells under 4c is green (repro.4c.cells.log:373-375). The gate turns NO-SUITE into REFUSED at mutate_p4_health.sh:3375 and :3429-3430.
- Not shown: which earlier test sent the SIGINT (it does not matter for the mechanism). The log also has no `rc=` line, which fits Python exiting by SIGINT [inferred].

**The fix removes the cause; it does not mask the catch** [read].
- Every collect class derives from `Sealed`, and the subclasses with their own setUp call it (collect:754-755, :2015-2016, :2492-2493). The restore is at :257-273.
- Under 4c, the same mutated copy now runs to `Ran 183 … failures=4`, the expected test among them (repro.4c.fixed.collect.log:5-65). It is also caught in partial_r7b_C2R6-4c.log:17-21 and nslab shard3:635-639.
- No assertion was weakened: D:250-273 and :539-560 only add setUp and cleanup.
- 1n was a WRONG TEST before (partial_…first_01ba2a41.log:95-99) and is caught after (partial_r7b_C2R7-1.log:134-136; nslab shard3:707-711).

**Caveat (finding 3).** Both cleanups repair a leaked mask silently. A leak now fails nothing by itself, and two restore sites have no mutant: lab.py:181 and lab_round.py:316. Only C2R6-4c, C2R7-1n, 1o and 1r touch a restore.

**Do other tests leave the mask changed?** In unmutated code, none. Every mask site restores: cells:1529, :1770-1792 (queries), :1819-1836, :1880-1885; collect:261-273, :3277-3283, :3293-3322. The SIGTERM-handler set/restore pairs I saw in the grep, not each in context. Under mutants, the only mask-changing production paths are LabRound (in collect, where every class is protected) and `S0.vs_trial`. In cells, only TestS0Cut2Checks calls the real `vs_trial` (cells:1641, :1717, :1759-1765); every other S0 user is a FakeS0. So no unprotected carry-over path remains [read + inferred].

## 4. Gate evidence for 7a7a2577

**Shard headers agree** [read]. All four nslab shard logs show:
- line 1 `commit 7a7a2577…`; :2 `tracked-dirty=0`; :5 `/usr/bin/python3.12 (3.12.3)`; :7 HEAD 7a7a2577; :8 tree 349e5ab0 with no `+UNCOMMITTED`; :9 subject sha d2a38f99dbaaf3b3; :10 gates sum e4082a69a7af6149.
- Shards ran 119/118/118/118, every one with `0 survived`, `SHARD k/4 of 473` and `rc=0` (shard0:740-743; shards 1-3:734-737).
- Baseline, negative control, byte-identical lines and after-check are green in each.

**Sum and run record** [read]. GATE.nslab.log:3 reads `GATE: 473 mutations, 0 survived, shards 4/4 ok, commit 7a7a2577…, tree 349e5ab0…, subject sha d2a38f99dbaaf3b3`, rc=0. driver.log:1-10 shows the shards ran one at a time, each rc=0.

**Counts add up** [read].
- 473 "caught by" lines; 481 `===` headers = 473 + 8; 477 `anchor occurrences: 1` lines = 473 + 4 controls, with no other value.
- Zero lines match SURVIV, NO-SUITE, HUNG, REFUSE, WRONG TEST, ENOSPC, Errno, No space, Terminated, Killed, NOT UNIQUE or UNCOMMITTED.
- D:734-911 adds exactly 23 C2R7 rows and removes none: 450 + 23 = 473.
- There are 23 C2R7 headers (6/5/6/6), covering every label 1a–1r and 3a–3e, and 53 C2R6 headers (13/14/13/13).

**Interpreter.** The certifying gate ran on 3.12.3. S:588 names 3.8 as "the gate's interpreter", and the live interpreter (p4_proxy/venv) looks like 3.13 (n1.collect.RED.log:11 paths) [inferred].
- 3.8 results exist that agree with 3.12 for all but 15 shard-3 mutants [spot-checked]:
  - laptop shard 0 (3.8.20) against nslab shard 0: lines 1-39 and 600-743 are identical apart from paths and two hashes;
  - first-gate shards 1-2 (3.8) against nslab: identical caught-by lines in the r6/r7 region (:590-723), apart from the order of names;
  - first-gate shard 3 against nslab: identical up to :632.
- The compare_shards.py output is not archived.

**Whether 7a7a2577..4a8cdf7b is docs only: UNDER-EVIDENCED.**
- The evidence is the commit subject (r7-commits.txt:1), S:542, and README:14-16.
- The tools tree is the same at 67af72b3 and 7a7a2577 (first-gate shard*:8 against nslab shard*:8). Nothing shows that the tests are unchanged after 7a7a2577.

**Line 84: the orchestrator's reading is verified** [read].
- `find … | sort | xargs sha256sum | sha256sum` sorts by LC_COLLATE. In en_US.UTF-8, `_`, `.` and `/` are ignored at the first level; in C they are bytes. The line order, and so the hash, changes.
- Corroboration:
  - The byte-identical hash, from the same `find | sort` (:3355, :3475), also differs: 6d9e486d69ca0806 against 86a08ac3a8121ab3 (shard0:736 on each machine).
  - `gates_sum`, which does not sort, is equal on both machines (:10).
  - `sort -u` at :3376 orders `test_an_error…` before `test_a_write…` on the laptop (first-gate shard1:651) and the reverse on nslab (shard1:651). That is exactly what the two collations give.
- The LC_ALL swap experiment (J:225, README:33) is not archived.

**Fix line 84 now or wait? Wait.**
- It fails safe: the sum script refuses logs whose subject shas differ (sum_p4_health_gate_shards.sh:139-142).
- The GATE was produced on a single machine.
- A fix edits a WATCHED file that is itself a mutation subject, so it needs a full new gate.
- Record it in the SUMMARY now. When it is fixed:
  - put `LC_ALL=C` on the `sort` at :84, :3355, :3475 and :3376, not as a global export, which would change the suites' locale;
  - add a test that is seen red first;
  - add an interpreter check to the sum script. Today the locale mismatch is the only thing that stops shards from two machines or interpreters being summed: the script compares commit, tree and subject sha only, and never reads the interpreter line.

## 5. Claims audit (commit subjects and S §11; other files where they disagree)

| Claim | Class | Evidence |
|---|---|---|
| Subjects of aa526f97, 4658e981, dcca2505, 611630e3, 004f204f, af2b3490, ae753c29, 01ba2a41, 7a7a2577 | SUPPORTED | As above. dcca2505 also carries the throwaway unblock, which its subject does not mention. |
| c8c2cef8 / S:558 "the edited gen_runtime.py was not executed" | SUPPORTED only on the test's path (convert → run_lab; n3.cells.RED2.log:6) | In a full S0, ctrl_trial execs the copy after convert.py and before the re-check (s0.py:726, :731; ctrl_trial.py:37-43). |
| 67af72b3 and 4a8cdf7b are docs only | UNDER-EVIDENCED | No per-commit diff available. |
| S:542 tree and head; tools last changed at af2b3490 | SUPPORTED | Tree 349e5ab0 at 67af72b3 and at 7a7a2577. |
| S:543 "every LOG7 log starts `commit` and ends `rc=`, except two" | CONTRADICTED | repro.4c.collect.log (no `rc=`), gate_disk_polls.log:1 (both copies), gate-chain.out:1, r7b/partials.log:1, disk_watchdog.r7b.log:1. |
| S:547, S:553 (23 mutants, 473; 9 collect + 6 cells tests) | SUPPORTED | — |
| S:568 reds and greens | SUPPORTED except one description | "Not restored after the trial raises": the red at n1.cells.RED.log:172-178 is the block missing inside the trial. Restore-on-raise is shown only by mutant C2R7-1o (nslab shard0:713-717). |
| S:573 "second run: 3 threads" | CONTRADICTED by the cited log | The second run has 16 gRPC threads plus a python thread (obs.grpc_threads.log:64-82). The rest of that sentence is SUPPORTED. |
| S:574 "my first test had 1 claim" | UNDER-EVIDENCED | No log. Determinism is SUPPORTED: 3 red runs. |
| S:579-584 "no GATE line yet"; S:588 "py3.8 is the gate interpreter" | Stale | GATE.nslab.log:3; nslab shard*:5. |
| S:583 dev.quickmut as evidence | Weak | It runs only the named test (quickmut.py:30), which hid 1n: CAUGHT at dev.quickmut_C2R7.log:16, WRONG TEST at partial_…first_01ba2a41.log:98. |
| S:586 ok(438) arithmetic | SUPPORTED | final.check_gate_anchors.log:109. My count of D's anchors: 5 more duplicate rows (31→36), 4 more shared anchors (26→30), 18 new distinct anchors (419→437), plus the control = 438. |
| S:592 phase 1 "1281–1300 MB" | CONTRADICTED | The same sentence gives min 1177; disk_watchdog.log:14-37 has samples of 1177–1258. "310 samples" includes the end record (:311). |
| S:596 final `ps` check | UNDER-EVIDENCED | Not archived. The helper scripts in SP send no signals [read]. |
| S:621-629 (§11.7) | SUPPORTED | "1n would also have stopped the first gate" is loose: 1n is a WRONG TEST (rc 1), not a refusal. |
| J:225 "121/121 identical"; README:33 "same files give 4651b09c under LC_ALL=en_US.UTF-8 in the guest" | UNDER-EVIDENCED | Not archived. My spot checks agree. |
| README:32 "the only difference is the subject sha" | CONTRADICTED | The byte-identical hash (shard0:736, same cause) and the interpreter line (:5) also differ. |
| J:225 "laptop ~90 min" | Disagrees | The second-gate laptop shard 0 took 104 min (gate_disk_polls.log:33-34). |
| r7b/partials.log:3 "C2R7-1 rc=0" | CONTRADICTED | partial_…first_01ba2a41.log:134-136 shows 1 survived, rc=1. partials.sh:8 reads `$?` after `$(date)`, so lines 1-4 record no real exit codes; partials2.sh fixed it. gate_driver*.sh:22 have the same pattern (not exercised). |
| First gate | (incidental) | It was driven as `gate_driver.sh ae753c29` while the shards ran at 67af72b3. Its sum would have been refused (sum_p4_health_gate_shards.sh:188-189). Moot now. |

## Tests I would have run

1. An offline rehearsal of the pre-claim checks on a real S0: a small harness that runs `S0.run()` with throwaway switches, then `lab.stop_signal_threads_refusal()` and `frozen.check_exercise(<run>/exercise)`, archiving a `/proc/self/task` SigBlk listing. An alternative is `probe.py lab --bringups ,`: probe.py:221 turns that into an empty tuple, so lab.py:207 and :228 start no round. Use it only if the identity step (probe.py:234-250) can complete offline.
2. The S0 order test: run packages() with the fake convert.py, then ctrl_trial. Does the edited model run before run_lab refuses?
3. Mutants that remove the restore at lab.py:181 and at lab_round.py:316, plus an assert-in-cleanup.
4. compare_shards.py on nslab shard 0 against the laptop, and on nslab shards 1-2 against first-gate shards 1-2, with archived output.
5. The subject sha under LC_ALL=C and under LC_ALL=en_US.UTF-8 on the laptop, archived.
6. A SIGTERM during a real offline ValueSet trial: time to exit, and no throwaway left behind.
7. r6's tests 4, 5 and 7, still open.

## Findings, ranked (no BLOCKER, no MAJOR)

1. **MINOR (record). S does not record the gate that certifies the code.** It still says there is no GATE line, and names 3.8 as the gate interpreter. Add: GATE.nslab.log:3; python 3.12.3 and C.UTF-8 on nslab; the laptop shard 0 as a cross-check only; why its subject sha differs. *Re-run: none.*
2. **MINOR (scope).** S0's controller trial execs `<run>/exercise/gen_runtime.py` after convert.py and before run_lab's re-check. This is fail-safe, because the re-check then refuses before any claim. probe.py:47-52, S:196 and c8c2cef8 should say so. A code fix is optional: call `check_exercise_copy` again right after packages(). *Re-run: none now; with the code fix, a new mutant plus a full gate.*
3. **MINOR (tests).** The cleanups added in 01ba2a41 and 7a7a2577 repair the mask silently, and the two `_swap_handlers` restores (lab.py:181, lab_round.py:316) have no mutant. *Re-run: with the next code round, a full gate.*
4. **MINOR (procedure).** §6 says nothing about S0's deferred stops. A stop sent during the ValueSet trial waits for the trial to end. SIGKILL is the only escape for a hung trial and is safe only before the first claim; after a claim, use recover.sh. *Re-run: none.*
5. **MINOR (gate script, can wait).** The subject sha is locale-dependent (:84, also :3355, :3475, :3376), and fixing it must come with an interpreter check (section 4). *Re-run: none now; a full gate when fixed.*
6. **MINOR (evidence).** Not archived: the compare_shards output, the LC_ALL experiment, the final `ps` check, and a diff showing 7a7a2577..4a8cdf7b is docs only. *Re-run: compare_shards.py twice, `git diff --stat 7a7a2577 4a8cdf7b`, and the LC_ALL pair, all archived. Seconds each.*
7. **NIT.** The `$?` pitfall in partials.sh:8 and gate_driver*.sh:22. Annotate partials.log:1-4.
8. **NIT (S text).** The LOG7 exceptions; "second run 3"; the n1.cells red description; the phase-1 disk range; 310 vs 309 samples; S:628's wording; dev.quickmut cited as evidence.
9. **NIT.** README:32 ("the only difference") and J:225 ("~90 min").
10. **NIT.** `build*` is not re-checked: the p4info files `expectations` reads and B's build dir. Say so in §6, premise 3.
11. **NIT.** The first-gate driver's `--commit` did not match the HEAD the shards ran at. Use the shards' HEAD in future drivers.
12. **NIT.** `stops_held`'s docstring: for SIGINT the "default action" is a KeyboardInterrupt.

## Before trunk

1. One docs-only SUMMARY commit: finding 1, the text of findings 2 and 5, and findings 8-10, plus a note on partials.log.
2. Archive the checks in finding 6.
3. Nothing in code.

## Before the first live run

1. Test 1 (the offline rehearsal).
2. Finding 4 (the §6 stop instruction).
3. Standing items:
   - Free disk above 2500 MB (S:210). On 10-10 the laptop was at 1264–1817 MB (disk_watchdog.r7b.log:322, :372).
   - The announcement to every session and the helper-tree check (S:175-180).
   - Adam's authorization for this run.
   - The `repo_untracked` decision (S:197).
4. Optional, with the next code change: findings 2 (in code), 3 and 5, then all four shards at the new head.
