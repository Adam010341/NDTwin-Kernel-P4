I had no Write tool, so the full report is below. Save it as `logs/orchestrator-0924/intake-0926/extb/judge-EXTB-5311f3f6-r6.md`. I worked read-only, ran nothing and used no git history.

# Re-review of B round 6 at 5311f3f6 (scoped like r5)

## Verdict: MERGE AFTER FIXES. All four fixes are README-only.

- **Code, tools and gates:** product code, tools, decision rules, the S-9 disclosure and the 44-gate evidence are good enough for the live comparison. Round-5 Musts 1–4 and S-8 are met.
- **What blocks:** read as an operator, the procedure still has three outcomes that are not pre-registered and one rollback flaw. Together they can leave the shared main checkout in a bad state (F1–F4 below). The fix is about 15 lines of README text.
- **Gates still stand:** no script or gate reads `live-p1/README.md`. A grep finds only a docstring mention (`external_evidence.py:13`) and a fixture string (`test_live_p1_external_evidence.sh:118`). A README-only commit therefore changes nothing the 44 gates tested; `git diff --stat 5311f3f6..<new>` should show only README.md.
- **Alternative:** commit the four amendments as an orchestrator addendum before any live data and keep B_SHA=5311f3f6. README:579 allows either.
- **After the fix:** no further re-review is needed unless the decision rules change.

## Q1. The round-5 Musts and S-8

**Must 1, the procedure: met, with the gaps in F1–F4.**
- H1–H4 run under the local merge, before the decision (README:477, 501-502).
- Ancestor or merge-tree pre-check (446-451).
- HEAD==T_MERGE is checked before `reset --keep` (487-489).
- Outcomes registered for:
  - a refused merge (525-526);
  - an identity refusal caused by someone else (522-524);
  - the one T rerun: rc 0, rc 1 on the same field, rc 1 on another field, rc 2, rc 3 (508-512);
  - DAEMON or 0x88B5 (505-506), UNREADABLE (514), UNDECIDED (515-518), UNDECIDED heard (519).

**Must 2, identity: met.**
- `code_identity.py`:
  - SAME now includes bmv2_libs and tutorials (:60-61); NOT_CODE matches the ruling (:64);
  - uncommitted files are recorded with sha (:87-105);
  - the tutorials digest also catches untracked files (:108-134); the libs digest is at :137-150;
  - tree and merge_tree are recorded (:194-203); `verify` refuses when tree ≠ merge_tree (:266-268).
- `external_evidence.py`:
  - before and after identities are required and must be equal (:681-697);
  - the controls' HEADs and SAME must be equal (:699-703); `verify` (:704-706);
  - p4c and JSON sha must be equal per arm across runs (:710-723).
- B's 06 records its own identity (06_thirteen.sh:99-106, :229); the C runs use README:453-461.
- Both identity paths record the same interpreter: the CTRL_PY default (code_identity.py:56) equals 06's VENV_PY (06_thirteen.sh:39).
- Both use the same tutorials: TUT is hard-coded to /home/adam/tutorials (drive_exercise.py:80), which is code_identity's default (:126).
- C and T use the same driver: `$M`'s drive_exercise.py has the same anchors at 369/773/1623/2350/2776. This is an observation of `$M`'s uncommitted working tree.
- Seen red: redfirst_b6:24-29.
- Two residuals, neither blocking:
  - the stock simple_switch's libs are not digested (it is only used in T);
  - identity is taken at two points, so a tracked file mutated in place and restored between them is invisible (handled by N1).

**Must 3, the heard rule: met.**
- Rule text README:421-428; push offset and heard window `external_evidence.py:524-587`; sampler `08_heartbeat.sh:878-982`.
- Seen red: redfirst_b6:14-23 and L86–L88 (heartbeat_w:284-286).
- Calibration holds. With 1-s reads and a 5-s period, any window of 10 s or more leaves at least 9 s between the two bracketing samples. So a working heartbeat always shows at least one growth per direction, and rc 3 cannot come from sampling phase alone.

**Must 4, S-9: met as ruled. I did not re-litigate the bound.**
- The heading states it as ruled: "（S-9；預先登記，orchestrator 第六輪接受）" (529).
- Point estimate 557; per-check bounds 558-560; family-wise figure 561-563 ("上界的和，不是估計", "orchestrator 第六輪接受這個規則，附這段揭露").
- I recomputed the arithmetic and it is consistent:
  - per-check bounds 0.71%, 1.49%, 4.88%, 5.68%;
  - per-arm sums 23.7, 11.5 and 19.2, total 54.3%;
  - 22 checks = 9 + 7 + 6.
- Demoted fields 550-553 and 570-571; p² power 572-573; FAIL cost 564-565; frozen inputs 429-432 and survey_34.log:11.
- Every INTAKE:91-93 requirement is present.

**S-8: met as ruled.**
- `test_heartbeat_drop_check.py:107-145`. The skip is decided once, at module start (:141-143).
- Claim mutants D32–D35 are caught (mutate_l1_shell_scoring:84-87); redfirst_b6:50-53.
- During this live run the protection is partial:
  - 06 and 08 claim per round and never declare measuring= (08_heartbeat.sh:97);
  - so a suite started in a claim gap runs its switches through the next round;
  - a gate runner using the operator's NDT_OWNER does not skip at all.
  - Handled operationally in N1.

### Walking through steps 0–7 as tomorrow's operator

**F1 (blocking): step 6 rollback (README:487-493).**
- (i) **`reset --keep` aborting is not registered, and the message is wrong.**
  - Cause: someone makes an uncommitted edit, during T, to a file B changes. tools/test_workflow/ndt is one; B changes it and GUI v2 work is active on it.
  - Then the `||` prints "STOP: HEAD is not T's merge", which is false.
  - Local trunk stays at T_MERGE, and their edit now sits on B's version of the file.
- (ii) **The reset target is `$C_HEAD`, not `$T_MERGE^1`.**
  - Case: someone commits to trunk between step 0 and step 2 (C1+C2 take hours). For what it's worth, the session-start git status showed `.codex/` and `AGENTS.md` untracked in `$M`, which hints that another agent works there.
  - The data side catches this: external_evidence.py:700 and code_identity.py:261-263.
  - But that sends the operator to "先回復（若已 merge）" (523), i.e. step 6. Step 6 passes its HEAD==T_MERGE check and resets trunk to C_HEAD, dropping that commit from the branch (only the reflog keeps it).
- (iii) **Step 7 unfreezes unconditionally.** README:491 says HEAD "應等於" C_HEAD, but nothing says what to do if it doesn't. A routine trunk push after that would publish an unpassed B.
- Fix (load-bearing text):
  ```
  : "${C_HEAD:?}" "${T_MERGE:?}"
  if [[ "$(git -C $M rev-parse HEAD)" != "$T_MERGE" ]]; then echo "STOP: HEAD is not T's merge -- no reset"
  elif ! git -C $M reset --keep "$T_MERGE^1"; then echo "STOP: reset --keep refused -- local edits to files B changes (listed above)"
  fi
  [[ "$(git -C $M rev-parse HEAD)" == "$C_HEAD" ]] && echo ROLLED-BACK || echo "STOP: HEAD is not C_HEAD -- do not unfreeze"
  ```
- Outcomes to register with it:
  - **reset refused:** keep the freeze. The owner moves their edit off (commit elsewhere or stash; never `--hard` or `checkout --`), then retry.
  - **HEAD ≠ C_HEAD after a successful reset:** someone's commit stays; report and restart from step 0.
  - **Step 7:** only after ROLLED-BACK or the PASS push.

**F2 (blocking): step 2's `|| echo STOP` (466-467) has no outcome.**
- Add a pre-merge check `[[ HEAD == $C_HEAD ]]`: if trunk moved, don't merge, and restart from step 0.
- For a post-merge STOP: run the F1 step 6 (it undoes exactly the merge), don't run T, report.

**F3 (blocking, pre-registration): rc 3 on the first compare has no cap.**
- README:520-521 says only "修正後重跑". The T-rerun's rc 3 is capped at one (512).
- Several rc-3 causes are properties of T's own data: session not running throughout, a direction not heard in the window, identity drift.
- Rerunning T until those clear is the repeated-rerun pattern INTAKE:92-93 and README:564-565 forbid.
- Fix:
  - a wrong command (missing `--samples`, `--control2` or `--b-sha`): fix it and compare again, with no new run;
  - a run refused for its own content: redo that run once (for a control, roll back first); a second refusal of the same kind ⇒ stop and report, neither pass nor fail.

**F4 (blocking-small; the operator is an agent): shell variables.**
- C_HEAD, S, R and T_MERGE exist only in the shell (445, 455-458, 465, 487). Agent tool calls don't keep shell state, and 06 runs for hours.
- Most failures are loud.
- The one silent case: with T_MERGE set and C_HEAD empty, `git reset --keep $C_HEAD` becomes `git reset --keep`, a successful no-op. No STOP prints and B stays merged.
- Fix:
  - keep a vars file, written as each value is learned and sourced by every step;
  - use `: "${X:?}"` guards in each step;
  - say how to recover the values: C_HEAD = `head` in `<C1>/00_identity.after.txt`; T_MERGE = `head` in `<T>/00_identity.after.txt`, whose `parents` give C_HEAD and B_SHA.

**Not blocking: live-day instructions.**
- **N1, the freeze announcement should also say:**
  - no uncommitted edits in `$M` to `git diff --name-only $C_HEAD $B_SHA`;
  - no regenerating figures or writing other tracked non-.md/.tsv files in `$M`, which the ruling says are compared;
  - no lab claims by others from step 1 to step 4. If an arm is lost to someone else's claim, H5 goes BAD for a reason that has nothing to do with B, and that outcome is not registered;
  - no gate or mutation drivers on this machine (see the two-point identity and S-8 residuals above);
  - the operator's NDT_OWNER is distinct from any gate runner's.
- **N2:** after C1, diff its before and after identities (ignoring `recorded_at`) before starting C2. Otherwise drift is only found at step 5. extb6-notes.log:2 supports that the tutorials dirs stay clean.
- **N3:** in the rolled-back state (C3/C4 or a control rerun), run `$B_WT/$LP/external_evidence.py`, not the README:481 path. `$M`'s live-p1 has no .py files (uncommitted observation), so that path fails, loudly.
- **N4:** an UNREADABLE control (514) needs a rollback before the rerun and a re-merge after, as 516-517 already says for C3/C4.
- **N5:** a first compare with both a DIFF and a controls disagreement gives rc 1. The T rerun then cannot do better than rc 2, which means "no third run" (511), and C3/C4 is lost. It is registered, just wasteful.
- **N6:** before any PASS push, run GUI v2's tests and the ndt_serve mutation gates on the merged head. They were not run (REPORT-r6:78), and ndt was auto-merged (REPORT-r6:5).

## Q2. Are the new checks seen red? Yes, SUPPORTED

- **Evidence gate:** E61–E65 (:75-79), E81–E90 (:80-89), E91–E94 (:90-93), E95 (:94), E72 (:101), I9–I20 (:118-129), S1–S7 (:130-136); "123 mutations, 0 survived" (:139) and "202/202" (:140).
- **heartbeat_w:** L86–L88 are each caught by the named cell "🔴 H5 sampler ctrl_logs column" (heartbeat_w:284-286). All three rest on that one cell. The comment-only control C1 stayed green (:301); 269/0 (:306).
- **thirteen:** M13 (:122), M14 (:125), 14/0 (:131).
- **l1:** D32–D35 (:84-87), 62 killed (:90).
- **redfirst_b6 section A is degenerate, as the worker says.**
  - Its line 13 reads: "the base tool fails 147 of 202 cells (degenerate: it reads 00_identity.txt only)".
  - 20 named cells are red (14-33).
  - The 13 rc-3 cells are green by accident, and each is named with its own mutant (34-38), all caught at the evidence-gate lines above. So the red comes from the mutation gate, not from old code, which satisfies the mutation-gate rule.
- B–E behaved as expected (40-56); ALL-AS-EXPECTED (57).
- `patch_old_redfirsts_r6.py` rewrites the old expected sets. Each change gives its reason, and every expected red it removes gets a replacement.

## Q3. Does the gate run support "44 rc 0 on 5311f3f6"? Yes, SUPPORTED

- gates_extb6m.out:1-44 are all rc=0; trunk did not move (:45); ALL-AS-EXPECTED (:46).
- The counts agree:
  - 39 + 5 = 44 gates;
  - 103 non-control + 9 controls = 112 checks (mutate_heartbeat_drop_check:12, :82);
  - tripwire 267 + 6236 = 6503 lines. That includes the stopped extb6 run's log, and the result is 0 lab calls, 1317 launches and 2991 probes, 0 breaking, 0 refused, 0 still alive (nolab_tripwire:11-13).
- **"9 control(s), 8 of them red too" is expected.**
  - Controls are exempt from seen-red, with stated reasons (mutate_heartbeat_drop_check.sh:45-69).
  - The log lists which controls went red, not which mutant did it. The pattern fits the reasons:
    - observation-proof cells go red when a mutant breaks the run;
    - "machine fact" and "executable's name" cells go red when the guard refuses a root or argv mutant;
    - "and its switch is gone" goes red because the SIGKILL cell rests on PDEATHSIG alone (D19).
  - The one never red is the kernel-source pin "(that scan's rule, as the kernel has it)", which no tool or ndt mutation touches.
- Two summary-column tails are display artifacts:
  - :17 shows a fixture line, but the log has "Ran 32 checks, 0 failed" at :53 and the later lines are trap cleanup;
  - :40 shows "rc=0", and that gate's log has 19 mutations, 0 survivors (:42).
- mutate_p4_heartbeat_w was running when disk dipped to 809 MB (notes:9). Each kill names its cell and the control stayed green, so nothing suggests the environment produced kills. "From other activity" is the worker's attribution and is unchecked.
- I did not examine proxy_unit's one skipped test.

## Q4. Is anything on the not-done list blocking for the live run? No

- **PYTHONUNBUFFERED:** the inference is supported by code, and it fails safe.
  - drive_exercise.py:1622-1623 sets it, and :1639-1640 passes that env to `local_popen`, not through sudo or mnexec.
  - run_external_controller.py:184 runs the controller in-process with `runpy`.
  - If output were buffered anyway, the window would shrink to UNDECIDED (rc 2), never a false pass.
  - It is still not shown live; the first T run will show it.
- **ndt app validate's sha not compared:** the JSON the controller pushes is compared (:710-723; notes:3). Not blocking.
- **Malformed claim treated as free:** this matches ndt. Not blocking.
- **GUI v2 tests not run:** blocking for the PASS push only (N6).
- **TMPDIR leftovers from proxy_unit:** hygiene only.

## Q5

MERGE AFTER FIXES with F1–F4, all README-only. Live may start once they are in.

## The report's claims, classified

| Claim | Status |
|---|---|
| 44 gates rc 0, trunk did not move, tripwire clean | SUPPORTED |
| Tree == merge-tree | SUPPORTED (orchestrator's own check, INTAKE:100) |
| Must 2, Must 3, Must 4, S-8 | SUPPORTED |
| Must 1 | SUPPORTED with gaps F1–F4 |
| "ctrl_logs sees the push" | UNDER-EVIDENCED live (labelled as inferred) |
| euid 0 | UNTESTED (disclosed) |
| GUI v2 tests | UNTESTED (disclosed) |
| The procedure's git half | UNTESTED (never rehearsed; the worker never claimed it was) |
| "809 MB from other activity" | UNDER-EVIDENCED |

None of the report's numbers contradict each other.

## Tests I would have run

1. **Rehearse steps 0, 2 and 6 in a throwaway clone of `$M`, with no lab needed.** Three cases:
   - an edit to a B file made after the merge;
   - a commit between step 0 and step 2;
   - staged changes.

   This sees F1 and F2 red, and their fixes green.
2. **Run `code_identity.py record` twice on the real machine with nothing in between,** then check `unchanged_reasons` is empty. This is a one-minute pre-flight with no lab.
3. **Run GUI v2's python and browser tests and mutate_ndt_serve on 5311f3f6** before any push.

## Key paths

- Procedure: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/README.md (lines 393-591)
- Tools, in the same live-p1 directory: code_identity.py, external_evidence.py, 06_thirteen.sh, 08_heartbeat.sh
- Driver: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py
- Adapter: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927/tools/p4_exercise/run_external_controller.py
- Gate summary: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/extb6/gates_extb6m.out
- Gate logs: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/*.extb6m-5311f3f6.log
- Notes: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/extb6-notes.log
- Old red-first patch: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/extb6/aeg/patch_old_redfirsts_r6.py
