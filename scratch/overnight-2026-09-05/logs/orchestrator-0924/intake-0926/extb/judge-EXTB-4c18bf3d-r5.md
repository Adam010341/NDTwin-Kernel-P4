# Re-review of round 5 on feat/external-detect-only-0927 (head 4c18bf3d)

## Verdict: MERGE AFTER FIXES — not yet ready for the live run

Round 5 fixed most of what the round-4 review asked for, and the gate evidence holds up:
- 39 logs, each opening with `4c18bf3d…` and ending `# rc=0`.
- The tripwire re-checked 2508 switch launches and 5734 `--version` runs: 0 lab calls, 0 rule-breaking launches, 0 refused, 0 still running.
- No mutant now launches a switch that breaks the orchestrator's conditions.
- S-6 is a real end-to-end test.

Four problems remain in what the live run will execute or decide. They must be fixed before any live data exists, because the procedure is pre-registered:
1. The pre-registered command order runs H1–H4 after the push, or after the rollback.
2. The code-identity check misses the compared arms' own code, refuses T over unrelated edits in the shared checkout, and the rollback has no guard.
3. The "every direction heard" rule is weak or refusing for short controller lifetimes.
4. S-9 does not state its family-wise false-fail rate.

## How I checked

Read-only: INTAKE (including the round-5 rulings at lines 71-75), the round-5 handback, SUMMARY §R5, the patch, the files at 4c18bf3d, the extb5c logs, the files under `extb5/`, and the notes log. I also spot-checked the main checkout's untracked raw data. No commands were run and git was not used.

Path prefixes:
- WT = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927
- LP = WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
- LOGS = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
- EV = LP/external_evidence.py
- CI = LP/code_identity.py
- HDC = WT/tools/test_workflow/heartbeat_drop_check.py
- TDC = WT/tests/shell/test_heartbeat_drop_check.py

## Your six questions

### (1) Can T differ from C in a way the identity does not record? Yes.

Untracked files inside the repo are mostly harmless. The code path is tracked, and `runs/` is rightly excluded (CI:15-16). Two ignored kinds of state do reach the code path:
- `p4_proxy/p4_src/build/` (NDTwin's compiled pipeline, used by the 23 other arms and 01);
- `.test_run/` (ndt's runtime state).

The real gaps are outside the repo, on the compared arms' own code path:
- **`~/tutorials`.** drive_exercise reads the exercises from `TUT=/home/adam/tutorials` (WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py:80). That includes the P4 sources, the exercises' own controllers (`mycontroller.py`) and `utils/p4runtime_lib`. None of it is recorded.
- **p4c and the compiled program.** drive_exercise already writes p4c's sha256 and version (:723-728) and each compiled JSON's sha256 (:792-793) into every round report. `compare` never checks that they are equal across C1, C2 and T.
- **The fabric's bmv2 libraries.** Only the binaries are hashed (CI:136-139). The data-plane code lives in `/usr/local/bmv2-fast/lib/*.so`.
- **In-place edits inside the venvs.** The venv fingerprint hashes the list of installed packages, not the files.

Three more holes:
- **Timing.** C's identity is recorded after its run (README:431-436), T's at its start. A change during a C run would go unseen; recording before and after would catch it.
- **The merge content.** `verify` (CI:167-188) checks the parents, not the tree. An amended or hand-resolved merge passes.
- **Over-strictness.** The uncommitted comparison includes sha256s of every tracked file (CI:68-84), docs included. Today the main checkout carries tracked files other sessions are editing (`doc/audit/2026-09-02_fix-design-campaign/LEDGER.md`, `agents.tsv`). One edit during the multi-hour window makes `compare` refuse T with rc 3. The freeze (README:422; INTAKE:73) covers only pushes and merges.

### (2) Can a 2-sample controller lifetime pass vacuously? Not strictly, but it is weak, and short lifetimes get refused.

How the rule works (EV:497-521): `heard` must grow between the first and the last sample that saw the controller's pid.
- The daemon sends one round of frames every 5 s (WT/tools/test_workflow/ndtwin-lab:734) and rewrites its report within 0.5 s of hearing frames (:765, :1335-1341).
- So two reads about 1 s apart pass only if a round lands in that second, roughly 1 time in 5. The counted frames may also have been heard just before the controller was first sampled.

What a pass shows, and what it does not:
- At best it shows one round heard right when the controller process was alive. That can be before the controller has pushed its pipeline or installed any entries, which is the no-entries case the offline drop check already covers.
- "Heard at least once" is weaker than "heard throughout".

The other side of the problem:
- Lifetimes under about 6 samples are refused with high probability, and the refusal is rc 3, "procedure not followed".
- In 074635Z the flowcache controller died with gRPC UNKNOWN 32 s after the round's stamp (the 074635Z flowcache controller log, line 42). That arm could be refused again on every rerun.

Test coverage: the fixtures add one heard per 2-s read and keep the controller alive for 120 s (WT/tests/shell/test_live_p1_external_evidence.sh:228-241). There is no cell with the real cadence or a short lifetime.

### (3) M-4: is every condition red in the self-checks? No.

The mechanism is sound:
- A guard inside the test process: TDC:119-190.
- A wrapper that refuses bad launches: LOGS/extb5/make_hbwrap.sh:33-57.
- A tripwire that re-checks every launch line and checks liveness by pid plus start time: LOGS/extb5/aeg/tripwire_b5.sh:31-66.

The self-check logs do not show every condition red:
- **Tripwire** (LOGS/extb5/tripwire_selfcheck.log:2-10): fixtures exist for argv0, Thrift port, device id, ipc, cwd, refused, still alive, and lab call. None for:
  - uid 0;
  - an argument naming `simple_switch`;
  - missing `--use-files`;
  - a bad `-i`;
  - an absolute `--log-file`;
  - a probe with other arguments or another argv0;
  - a switch launched through the fabric wrapper;
  - a `ndt-hbdrop-ver-*` cwd;
  - an unreadable allowed line.
- **Wrapper** (LOGS/extb5/wrapper_selfcheck.log:2-7): refusals for device id, argv0, ipc, Thrift port, and a non-`--version` call to the fabric binary. None for:
  - a `simple_switch` argument;
  - cwd;
  - `-i`;
  - `--use-files`;
  - `--log-file`.
  - euid 0 needs root to test; that should be said.

Both the wrapper and the tripwire check only the cwd's basename (make_hbwrap.sh:40; tripwire_b5.sh:51), not that the directory sits under TMPDIR.

### (4) S-9: honestly pre-registered? Is ">5%" acceptable? Partly, and not as written.

- **Before any T data: yes.** No live run has happened.
- **Survey inputs: listed by rule, not frozen.** The README gives runs/, the dates 09-19 to 09-27 and the counts. I recounted the files: 11 skeleton, 12 solution, 11 flowcache. Still open:
  - `survey.py` globs the whole directory (LOGS/extb5/survey.py:9), so a rerun after C1, C2 and T would include them.
  - It never checks that those rounds had no heartbeat.
  - The rounds span several code versions, so "varied before" partly measures code changes.
- **Power cost, not stated.** That rule demotes p4runtime/solution's tunnel counters and both traffic invariants, plus flowcache's packet-in, cache-entry and gRPC-error counts (EV:118-127). The rerun rule then detects an intermittent effect of probability p only p² of the time. A PASS therefore cannot rule out a change in forwarding volume.
- **Family-wise rate, understated.** README:517 says only "超過 5%" (over 5%). Summing the README's own per-check bounds (README:513-516) over the 22 decisive checks gives about 52%: about 23% skeleton, 11% solution, 18.5% flowcache. The ruling (INTAKE:74) asked for a stated rate. That number, or a justified tighter bound, needs to be written down and explicitly accepted.
- **Rerun outcomes, partly specified.** README:477-478 does not say what happens when the rerun is rc 1 on a different field, or rc 2 or 3.

### (5) Is the command list executable as written, with the `reset --keep` rollback? Steps 1–4 yes; the end and the guards no.

- **H1–H4 is in the wrong place.** The list runs it after "pass → push" or after the rollback (handback lines 116-118; SUMMARY:894-897).
  - After a rollback it tests trunk, which has no B.
  - After a push, B is already public before the only live check of "detect a cut, write nothing" runs on an external fabric.
  - It must run under the local merge, before the decision.
- **No check that trunk has not moved.** Nothing checks, before C1, that trunk's head is an ancestor of `B_SHA`. If trunk moved before the freeze, T's tree is not the tree the gates passed.
- **`reset --keep` is the right primitive but lacks two guards.**
  - It needs a pre-check that HEAD is still T's merge commit.
  - The freeze must also forbid commits. Otherwise another session's commit landing on top of the merge would be dropped from trunk, and its files reset in the worktree.
- **Step 2.** "merge --abort" does not apply when the merge refuses because of local changes.
- **Identity refusals.** An identity refusal caused by someone else's edit needs a pre-registered outcome (restart from C1) rather than "fix and rerun".

### (6) Does S-6 really run ndt → the real checker → a throwaway switch? Yes.

- TDC:221-356 and 904-940 source the real ndt and stub only what touches the machine. `hb_drop_check_run` runs the checker as its own `python3` process, and that process launches a real stock switch, through the wrapper in gates.
- A probe at topo-start confirms no throwaway is still running, with a positive control at TDC log :96.
- NE1–NE3 are each caught (mutate_heartbeat_drop_check.extb5c:75-77).
- The tests pass: LOGS/test_heartbeat_drop_check.extb5c-4c18bf3d.log:130-142.

## Status of each item

| Item | Status | Evidence / gap |
|---|---|---|
| **M-1** | DONE | Full-06 controls (README:425-430); refuses a non-26-arm reference (LP/08_heartbeat.sh:131-143); H5's "06 against C1" line is reported only (README:467-472); L79 and L79b caught. |
| **M-2** | PARTLY | CI; 06 writes `00_identity.txt`; EV:609-634; 08:2446-2450; E69–E72, I1–I8, L82–L85 caught. Gaps as in (1) and (5). |
| **M-3** | PARTLY | Sampler (08:876-929), EV:497-521, non-numeric values give rc 2 (EV:434-438); E61–E68, L80–L81 caught. Gaps as in (2). |
| **M-4** | DONE in substance; the claim "every condition red" is contradicted | (3). Mutants D16–D18 caught with 0 tripwire violations (mutate_heartbeat_drop_check.extb5c:35-38; nolab_tripwire.extb5c:15). |
| **M-5** | DONE | Two merges whose trees matched merge-tree's prediction (extb5-notes:3, :48); 39 gates rc 0. |
| **S-1** | DONE | SUMMARY corrections at :90, :94, :135, :591, :678. |
| **S-2** | DONE | HDC:36-41, 128-131; ndt; census; README. |
| **S-3** | DONE | Raw confirmed: census_p4runtime_solution/30_report.json names advanced_tunnel.json on every switch, and every direction sent 5 and heard 5. Nit: the stale comment at WT/p4_proxy/proxy_agent/main.py:1382-1384 contradicts the new text. |
| **S-4** | DONE | HDC:96-102, 213-218, 336-338, 510-512, 614-622, 657-694; D32–D44 caught. A SyntaxError is still rc 1 (disclosed). |
| **S-5** | DONE | One drop-check log per bring-up; N44c caught. |
| **S-6** | DONE | (6). |
| **S-7** | DONE | Kept mutant outputs: 0 this time. The D10 cause is only inferred. The SIGKILL probe still gives the switch 3 s to die (TDC:689-692), which may flake red under MemoryHigh. |
| **S-8** | DONE, with a ruling needed | l1 now runs the suite (D27–D31; mutate_l1_shell_scoring 58/0). On the lab, l1 launches real throwaway switches outside any tripwire; the orchestrator should say whether ruling 2 covers that. |
| **S-9** | PARTLY | (4). |
| **Nits** | DONE | M28c caught; fixture README now uses `~/`; the phase_for flake fixed. |

## New defects, by severity

1. **Major — the identity check is incomplete and too strict**, and the rollback is unguarded ((1), (5)).
2. **Major — H1–H4 is ordered after the push or rollback**, and nothing checks that trunk is an ancestor of B ((5)).
3. **Moderate — the heard rule's window and its rc-3 outcome for short controller lifetimes** ((2)).
4. **Moderate — S-9's family-wise rate and power cost are unstated, and its inputs are not frozen** ((4)).
5. **Minor — self-check coverage** for the wrapper and tripwire, and the basename-only cwd check ((3)).
6. **Minor — S-8 policy point:** l1 on the lab launches throwaway switches.
7. **Minor — housekeeping.**
   - The stale main.py comment.
   - Per-bring-up drop-check logs pile up in `.test_run/logs` with no cleanup.
   - The tripwire's lab-call pattern still omits changing forms of tc, ip and ovs; this was already so before round 5, and the shims refuse those anyway.

## Fix list (all must land before the live run)

1. **README procedure** (LP/README.md:422-486), plus the handback command list:
   - run H1–H4 under the local merge, before the push or rollback decision;
   - step 0: freeze all commits, merges and pushes on trunk, and all edits to tracked files in the main checkout, or narrow the uncommitted comparison to code paths;
   - pre-check that `git merge-base --is-ancestor <trunk HEAD> $B_SHA` holds, or that merge-tree gives B's tree;
   - pre-check that HEAD equals T's merge commit before `reset --keep`;
   - pre-register outcomes for a merge refusal, an identity refusal caused by someone else's edit, and a rerun that is rc 1 on another field, rc 2 or rc 3.
2. **Code identity and compare:**
   - record `~/tutorials` (HEAD plus porcelain status, or sha256s of exercises/p4runtime, exercises/flowcache and utils) and the bmv2 lib directories;
   - have `compare` refuse unless each external arm's compiled-JSON sha256 and p4c sha256 (already in the round reports) are equal across C1, C2 and T;
   - record C's identity before and after each run and require them equal;
   - check T's tree against merge-tree's result.
3. **Heard rule:**
   - start the window at the controller's pipeline push or first entry, from its own log, and end it at its last write;
   - require at least one round heard per direction inside it;
   - a lifetime shorter than two 5-s periods gives UNDECIDED (rc 2, reported), not rc 3;
   - add a fixture with the real cadence (+1 per 5 s, 1-s reads) and a short lifetime.
4. **S-9 pre-registration:**
   - freeze the 34 survey inputs: report paths plus sha256, and a check that they had no heartbeat;
   - state the family-wise bound (about 52% by the README's own numbers, or a justified tighter one) and what a PASS does not show (the demoted fields, the p² power of the rerun rule);
   - get explicit orchestrator or Adam acceptance before C1.

**Should:**
- self-check fixtures for every wrapper and tripwire condition, saying that euid 0 needs root;
- check that the cwd is under TMPDIR;
- an orchestrator ruling on l1 launching switches on the lab;
- give the SIGKILL probe at least 10 s;
- fix the main.py comment.

Commit 868e4ed0's own statement of its pre-registration says the rule is not to be changed after the live run, so all of the above must be committed and re-gated first.

