# Judge r3: P4 health check, Cut 2 offline: r3 fixes and merge resolutions (`feat/p4-health-cut2` @ 66f7f42d; r2 was 4f50e23d)

[Co-developed with claude code -- Adam]

**How this was judged.** I worked read-only: no git, nothing executed, no files written.
- **Read:**
  - the r2 review, only to get the definitions of N1–N8;
  - r3-diff.patch and r3-merges-cc.txt;
  - the code and tests at the checkout;
  - the r3 gate logs.
- **Not read, on purpose** (auditor rule: no handoff or narrative documents):
  - both REPORT-*.handback.txt files;
  - INTAKE.md;
  - the r1 review;
  - anything under doc/audit (the SUMMARY, DESIGN.md).

  So each item about document text (N5, N6, part of N8) is judged only from one fact: the r3 patch changes no documentation (its diff headers list only tests/ and tools/p4_health/).

**Paths cited.**
- **Inputs:**
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/judge-cut2-4f50e23d-r2.md
  - r3-diff.patch and r3-merges-cc.txt in the same directory
- **Code** (all under /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/):
  - tools/p4_health/:
    - lab.py, lab_round.py, round_a.py, round_b.py
    - probe.py, identity.py, observe_a.py, s0.py
    - controller_ext.py, hostside.py, vs_trial.py, run.sh
    - collect/hosts.py, collect/config.py
    - cells/table.py, cells/verdict.py
  - tools/test_workflow/ndt
  - tests/python/test_p4_health_collect.py, tests/python/test_p4_health_cells.py
  - tests/shell/mutate_p4_health.sh, tests/shell/mutate_chaos_c07_control.sh
- **Logs:** /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut2/r3/ and its 27672d83/ and b4194bed/ subdirectories.

In the text below, `file:line` refers to these files.

## Summary
- **What is sound.**
  - N3, N4 and N7 are fixed as r2 asked. Each has a red on the old code (N4's two diagnostics reds only fail because the key did not exist yet), a green, and mutants caught at 27672d83 (284 mutations, 0 survived).
  - N1 and N2 are fixed for every case r2 named.
  - Both survivors at 991c2b21 are resolved.
  - The lab_round.py merge resolution is correct, and the three mutate_p4_health.sh resolutions are clean unions whose counts add up.
  - I found no relaxed "missing X ⇒ refuse" check.
- **What is not sound.**
  - **F1 (MAJOR):** a first stop signal that arrives during A's teardown is swallowed, and B claims the lab. That is N1's consequence in a window no test reaches, because every run_lab test turns LabRound's own signal handlers off.
  - **F2:** N2's false COMPLETE has a fifth way in.
  - **F3:** N5 is untouched, and it now also hides a stop signal.
  - **F4:** N8 is only partly closed.
  - **F5:** one test asserts that two doc/audit `.md` files exist, so it goes red on the PR tree.
  - **F6:** the merge's resolved package path breaks B's controller marker when the run dir path contains a symlink.
  - **F7:** N5's and N6's text items have no r3 change at all.
- **Gate:** pending at 66f7f42d (55 caught, nothing survived, log ends in C5).

## 1. The r2 findings N1–N8

**N1: fixed for the windows r2 named; not fixed for a first signal during a teardown (F1).**
- **Code.**
  - SignalAbort is a BaseException (lab_round.py:50-57), so config.py:59, hosts.py:174 and round_b.py:146 no longer catch it.
  - A record that carries "aborted by signal" ends the run (lab.py:101-103, 128-132).
  - A run-level handler covers the gap between rounds (lab.py:106-112, 170-183).
- **Tests** (test_p4_health_collect.py):
  - :1202 test_an_http_call_lets_a_signal_through;
  - :1210 test_it_is_not_an_exception;
  - :2482 test_a_signal_in_an_observer_ends_the_run;
  - :2489 test_a_signal_while_a_sniffer_is_waited_for_ends_the_round_there (the FakeSniffer raises at :1751);
  - :2499 test_a_signal_between_the_rounds_ends_the_run.
- **Red on 4f50e23d:**
  - n1_n2.OLD_red.log:2-5 and :8-11 ("(2, 2) != (1, 1)": B was claimed and brought up after the signal);
  - n1_window.OLD_red.log:2-3 (only lab.py reverted).
- **Green:** n1_n2.NEW_green.log (125 tests).
- **Mutants:** C2R3-N1a/b/c caught at 27672d83/mutate_p4_health.log:1634-1650.
- **Class:** SUPPORTED for the windows r2 named. 6d9650ef's general claim "a stop signal ends the run" is CONTRADICTED for the teardown window (F1).

**N2: fixed for the four exits r2 named; a fifth exit exists (F2).**
- **Code:** round_b.py:66, 109, 118, 127 and 140 set `failed`; lab.py:150-153 adds it to the run's problems, and lab.py:191 then reads INCOMPLETE.
- **Tests:** test_p4_health_collect.py:2542 (fabric left at "ndtwin") and :2548 (controller never ready).
- **Red:** n1_n2.OLD_red.log:6-7 and :12-13 ("('COMPLETE', 0) != ('INCOMPLETE', 2)").
- **Mutant:** C2R3-N2 caught (:1652-1656).
- **Untested exits:** "could not be started" (round_b.py:116-119) and "wrote no result" (:138-140) have no run_lab test.
- **Class:** SUPPORTED for the two tested exits; UNTESTED for the other two. The general claim "a B that did nothing is incomplete" is CONTRADICTED by F2.

**N3: fixed.**
- **Code:**
  - `_git_run` returns rc None when git cannot run (probe.py:36-50);
  - the lab run is refused when rc is not 0 (:114-119);
  - it is also refused, before run_lab, when the system under test is missing or the fingerprint is "incomplete" (:153-158).
- **3ab969c6's guard** (:143-146) fails closed: `fabric_bmv2=None` makes the bmv2_fabric part UNREAD, and the digest then reads "incomplete" (identity.py:121-126, 133-135).
- **Tests:** test_p4_health_cells.py:1421 (rc 128, timeout, missing git) and :1434 (no system under test; incomplete fingerprint).
- **Red at 965106b1:** n3.OLD_red.log:2-11 ("S0 must not start", "the lab must not start").
- **Green:** n3.NEW_green.log.
- **Mutants:** C2R3-N3a/b/c caught (:1658-1674).
- **Note:** at 991c2b21 the N3b and N3c "kills" proved nothing, because their test was red under every mutant (see §2). At 27672d83 they are genuine.
- **Class:** SUPPORTED. The OSError branch itself is UNTESTED (F8).

**N4: fixed.**
- **Code:**
  - every exit of `fabric_view` now goes through `fail(why)`, and `diag` keeps the raw ip link text, every show_ports, each host's link and address, the unplaced ports, the listed CPU ports and which read failed (observe_a.py:607-674);
  - `observe_tp1` returns this as "diagnostics" (:677-681), so it lands in A/TP1.json;
  - port 510 is skipped (:604, :645-647);
  - S0 has a check `show_ports_ok` (s0.py:143-146) and runs a trial every run (s0.py:604-633, called at :689).
- `read()` is exactly parse(body(raw)), so the refactor drops no check.
- **Tests:** test_p4_health_collect.py:2139, :2153 and :2159; test_p4_health_cells.py:1346.
- **Red at aacab54d:** n4.OLD_red.log:2-7. Two of the three reds are KeyError 'diagnostics', i.e. the key did not exist yet. The CPU-port red ("'NOT RUN' != 'GREEN'") fails for its own reason.
- **Mutants:** C2R3-N4a–d caught (:1676-1698).
- **r1's test 10:** show_ports_cpu510.log:2-21 shows both binaries listing ports 1, 2, 3 and not 510. S0's check passed at 27672d83, b4194bed and 66f7f42d (s0-final/probe.log:54). Both runs used pcap-mode switches, not the fabric's veth mode (F10).
- **Class:** SUPPORTED.

**N5: not fixed; r3 changes nothing here.**
- verdict.py:364-371 still returns PROBE-BROKEN before it looks at INCOMPLETE.
- r3 has no documentation change, so §6 step 2 was not extended to the see-red run.
- No red, green or mutant exists.
- It is now worse (F3).

**N6: not fixed; r3 changes nothing here.** All four sub-items are SUMMARY text, and the patch has no document diff. No evidence exists.

**N7: fixed.**
- **Code:** table.py:134-138 makes an unobserved control NOT RUN with phase "unobserved"; a control that was observed but has no answer keeps phase "control" (:146-147).
- **Production path:** `judge_all` passes `observations.get(ctl.id)` (verdict.py:286-287), so an unobserved control really reaches `judge(None)`.
- **No check relaxed:** the verdict is NOT_RUN as before, so `control_problem` (verdict.py:150-151) and `run_verdict` behave the same.
- **Test:** test_p4_health_cells.py:1509.
- **Red at defc6017:** n7.OLD_red.log:2-3. **Green:** n7.NEW_green.log.
- **Mutant:** C2R3-N7 caught (:1700-1704).
- **Class:** SUPPORTED.

**N8: partly fixed.**
- **Code:**
  - hostside.py, frames.py and `__init__.py` are copied into the run dir and the copies are hashed (hosts.py:25-44);
  - lab.py:167-169 hands the copy to both rounds, and :203 records the hashes;
  - round_a.py:80-87 and :141-144; round_b.py:53, 61 and 99-102.
- **The copy is self-contained:** hostside.py puts its own parent on sys.path (hostside.py:34-37), frames.py imports only `struct`, and `__init__.py` imports nothing. So the `-I` flag does no harm.
- **Test:** test_p4_health_collect.py:2523-2540.
- **Red at 9d5bc6ae:** n8.OLD_red.log:2-3 (root's argv names the shared tree's hostside.py). **Green:** n8.NEW_green.log.
- **Mutants:** C2R3-N8a/b caught (:1706-1716).
- **Still open:** F4.
- **Class:** SUPPORTED for "root runs a frozen copy". UNDER-EVIDENCED for "the shared tree can change during a run without changing what root runs". That holds only after the freeze, and nothing compares the frozen files with HEAD.

## 2. The two survivors at 991c2b21
The log ends "266 mutations, 2 survived" (mutate_p4_health.991c2b21.2survivors.log:1618).

**Survivor 1: R2-m2b (:1472-1476). It was an equivalent mutant; it has been rewritten and is now killed.**
- **The old mutation** turned `except SignalAbort: raise` into `except ZeroDivisionError: raise`.
- **Why it was equivalent:** after 6d9650ef, SignalAbort is a BaseException. The `except Exception` that follows (round_a.py:160) never catches it, so the re-raise clause at :158-159 is dead code. Removing it changes nothing for any signal.
  - Strictly, the mutant would re-raise an observer's ZeroDivisionError. Nothing exercises that, and the mutant's name does not claim it.
- **3ab969c6** replaces both clauses with `except BaseException as exc:`. The guard then does swallow the signal, which is the real regression to guard against.
- **Killed at 27672d83** by test_a_signal_still_ends_the_round, with two N1 tests also red (27672d83/mutate_p4_health.log:1580-1584).
- **Class:** SUPPORTED.

**Survivor 2: not a mutant. The negative control (a comment-only edit) went red (:1610-1612).**
- **Cause:**
  - test_a_missing_identity_record_stops_the_run_before_the_lab calls the real `vs_trial.fabric_binary()` (vs_trial.py:35-42), which opens <REPO>/p4_proxy/mininet/bmv2_binary_override.
  - The harness's `fresh_copy` (mutate_p4_health.sh:2082-2088) copies only tools/p4_health and grpc_ports.py.
  - So in every mutant copy, `cmd_lab` crashed with FileNotFoundError. That test was "also red" under all 266 mutants (for example :1362 and :1530-1608) as well as under the comment.
- **The fix:** 3ab969c6 catches OSError (probe.py:143-146). The fingerprint then reads "incomplete" and the run is refused (identity.py:121-126, 133-135). In production this fails closed: the run is still refused, now with a record instead of a traceback.
- **Result at 27672d83:** the negative control is green (:1718-1720), and the test is gone from the "also red" lists.
- **Caveats:**
  - production code was changed to work around a test that depends on its environment;
  - the test still reads a real lab knob file when one exists;
  - the new branch has no test (F8).
- **Class:** SUPPORTED.

**27672d83 is a pure rename (R7- to C2R3-).** r3-diff.patch:1-119 changes only label strings and the section comment. It addresses neither survivor; it avoids a clash with the run-identity branch's R7- labels, which arrived with b1e933a8. No gate was run at 3ab969c6 alone. The evidence that both survivors are gone is therefore the 27672d83 gate, which also contains merge b1e933a8: 284 mutations, 0 survived (:1726-1727).

## 3. New problems, merge resolutions, test doubles
**Merge resolutions.**
- **b1e933a8, lab_round.py: correct.**
  - The package path is resolved once (:167).
  - `package_inside` has a single caller, and it passes the resolved path (:168).
  - Cut 2's StateInUse refusal still comes before any state is written (:171-175).
  - The resolved path is the one stored (:177).
- **All three mutate_p4_health.sh resolutions are unions,** and the counts add up:
  - 266 + 18 (R7-1a…R7-L3) = 284;
  - + 10 (R8) = 294;
  - + 4 (R9) = 298 expected at 66f7f42d (still pending).
- **Auto-merged hunks** do not show in `--cc`. The only run-identity change in a Python file that r3 also touched is lab_round.py:165-177, and it has one interaction with Cut 2: F6.

**Test doubles.**
- **One encodes an assumption** instead of copying real behaviour: the run_lab LabRound factory builds every round with `install_signals=False` (test_p4_health_collect.py:2392-2397). Under test, run_lab's raiser is therefore live during teardowns. Production never has that configuration (F1).
- **Faithful:**
  - FakeSniffer.wait raising SignalAbort (this is what the handler does inside Popen.wait);
  - the `kill` reply;
  - `force_mode` and `ctrl_never_ready`;
  - `git_answering`'s three failure shapes;
  - `cpu_port_listed` / `extra_ports` (labelled as hypothetical, test file :1597).

**Relaxed "missing X ⇒ refuse" checks: none found.** I checked:
- the 3ab969c6 guard (still refused);
- the skip of port 510 (no refusal involved; no false GREEN, since a 510 in NDTwin's graph would read RED);
- N7 (the verdict is unchanged);
- the `package_inside` signature change (its one caller resolves first);
- `_git`, which still returns "" but is now used only for labels.

## 4. Tests that assert a doc/audit/**/*.md or REPORT*.md file exists
- **test_p4_health_cells.py:1122-1124** (inside test_the_header_says_where_the_cited_records_live, :1110) runs `assertTrue(os.path.isfile(...))` on:
  - doc/audit/2026-09-04_p4-tutorial-exercise-prep/GAP-2b-ndtwin-p4-capabilities-2026-09-27.md
  - doc/audit/2026-10-03_p4-health-check/DESIGN.md

  This goes red on the PR tree. The test predates r3 (Cut 1, r6).
- **No other p4 health test does this.** The other doc/audit reads are all of types PR trees keep:
  - expected_today.tsv (test_p4_health_cells.py:35; test_p4_health_collect.py:1899 and 2352);
  - code_identity.py and venv_fingerprint.sh (probe.py:141).

  Also:
  - test_p4_health_recover.sh and mutate_p4_health.sh reference no `.md` file;
  - the RECORD_NAMES scan (test_p4_health_cells.py:1085-1103) only checks that certain names are absent.
- **Outside this branch's suites** (found while scanning, not reviewed): tests/shell/mutate_chaos_c07_control.sh:36, 42 and 56 hashes and copies doc/audit/2026-08-28_chaos-harness/05_first-live-run.md.

## 5. Verdict: MERGE AFTER FIXES

**F1 (MAJOR): a first stop signal during A's teardown is ignored, and B claims the lab.**
- **Where:**
  - lab_round.py:299-304: during the teardown, the handler only appends ("signal-during-teardown", n) to `self.events`;
  - lab_round.py:369-374: the teardown runs under that handler, then run_lab's raiser is put back;
  - nothing in tools/p4_health ever reads `events` (it is only appended to);
  - lab.py:128-138 decides only from `rec["problems"]` and the state file.
- **Scenario:**
  1. The probe runs under run.sh (setsid), so a stop arrives as `kill -TERM <pid>`.
  2. The stop arrives while A is in `ndt down` (lab_round.py:446, timeout 900 s) or in the release.
  3. The teardown finishes, and the record carries no "aborted by signal".
  4. `signalled()` is False and `ended_clean()` returns [].
  5. The probe runs `ndt claim` and `ndt up p4 --app packages/B`, and starts B's controller.

  The same signal during B's teardown leaves the run COMPLETE with rc 0 and no trace of the stop.
- **Why the gates are green:** the harness configuration described in §3, and no test signals during a teardown. The one test with real handlers signals inside the body (test_p4_health_collect.py:1147-1157).
- **Not introduced by r3:** the r2 code behaved the same way. But 6d9650ef's claim does not hold here.
- **Fix:**
  - the teardown handler keeps the first signal number, and `run()` adds "aborted by signal N (during the teardown)" to the record's problems;
  - **test:** run_lab with real LabRound handlers and a fake `ndt down` that sends SIGTERM to the probe. Expected: 1 claim, 1 up, INCOMPLETE, rc 2. Predicted on 66f7f42d: 2 claims, 2 ups, COMPLETE;
  - **mutant:** drop that one line.

**F2 (MINOR, fix before the first live run): N2's false COMPLETE has a fifth way in.**
- **Where:**
  - `stimulate()` runs only if every sniffer is ready (round_b.py:142, hosts.py:187-189);
  - `controller.go` is written only inside `stimulate()` (round_b.py:137);
  - without it, the controller waits up to 120 s (round_b.py:76; controller_ext.py:349-351), while the probe gives up after 30 s (round_b.py:143-147);
  - `finish(None)` records "no controller result" (:157-158) but never sets `failed`.
- **Scenario:**
  - In B, h4's P3 sniffer does not print READY within 10 s (hosts.py:57, 157-165), or h4 has no namespace pid, or the spawn fails.
  - The run reads COMPLETE, rc 0, with every bmv2 attribution unconfirmed. That is exactly r2's N2 consequence.
- **Fix:** set `failed` in `finish()` whenever the result is None, which covers all five exits. Test it with B's sniffer never ready.

**F3 (MINOR, fix before the first live run): N5 is untouched, and it now defeats N1's "rc is 2".**
- **Where:** verdict.py:364-371 and lab.py:191-192.
- **Scenario:**
  - A see-red run (`--mutant --only K1,TTL1 --bringups A`) is stopped after K1: K1 is PROBE-BROKEN through SC-count, and TTL1 was never observed.
  - The headline reads PROBE-BROKEN, rc 1, which is exactly what test_p4_health_collect.py:2591 pins as the see-red success.
- **Fix:** do one of these:
  - make a recorded stop override the headline;
  - require `bringups[0].complete` and empty `doc["problems"]` for a see-red pass (r2's N5 text).

**F4 (MINOR, fix before the first live run): N8 is only partly closed.**
- **(a) The freeze comes late.** It happens at lab.py:167, after S0, which took 111 s (s0.run.log:4), while the dirty check runs at probe.py:114.
  - An edit made in that window is frozen and run as root.
  - Nothing compares `root_code` (lab.py:203) with HEAD.
  - The fingerprint (probe.py:147) records the edited tree, and on the first authorized run that record becomes the baseline.
- **(b) B still runs shared-tree code.** B's controller and the adapter (round_b.py:38-39; controller_ext.py also uses frames, :326) run from the shared tree after S0 and all of A. They do not run as root, but they write P4Runtime state on the lab fabric.
- **(c) r2's second bullet is untouched.** Untracked files churn the fingerprint (identity.py:89-100), and §6 still says to run in the main checkout.
- **Fix:**
  - freeze right after the dirty check, and verify the frozen hashes against HEAD's blobs;
  - make §6 name a dedicated clean worktree.

**F5 (MINOR; blocks the PR to main, not trunk):** test_p4_health_cells.py:1122-1124 (see §4). Fix: skip that half, with a reason, when the files are absent.

**F6 (MINOR, only when the run dir path has a symlink): the merge breaks B's controller marker.**
- **Where:**
  - LabRound now hands out the resolved package path (lab_round.py:167, 177), and round_b.py:114 puts it in the controller's argv;
  - the controller is registered with the marker `self.cfg.run_dir` (round_b.py:122);
  - that marker is `abspath` (probe.py:124) of a path run.sh builds with logical `pwd` (run.sh:6-7, 12);
  - `register` refuses a pid whose command line lacks the marker (lab_round.py:271-272).
- **Scenario:**
  - Some component of the run dir path is a symlink.
  - The controller is logged as "controller not recorded" (round_b.py:123-124).
  - Neither the teardown nor recover.sh can stop it.
  - The run still reads COMPLETE.

  Before the merge, the argv carried the unresolved path and matched. The r7 test (test_p4_health_collect.py:884-897) covers LabRound only.
- **Fix:** register with `os.path.realpath(self.cfg.run_dir)`. Test it through a symlinked run dir.

**F7 (MINOR, document text):** N6, the §6 part of N5 and the "main checkout" part of N8 have no r3 change. The contradicted r2 statements in the SUMMARY still stand.

**F8 (NIT):** 3ab969c6's branch (probe.py:143-146) has no test and no mutant. The one test on that path still reads the real override file. Mock `fabric_binary` there, and add a test that the real fingerprint with `fabric_bmv2=None` reads "incomplete" and `cmd_lab` returns 2.

**F9 (NIT):**
- C2R3-N8b's name claims more than its mutation does. A mutant that hashed the source instead of the copy would survive, because the test compares with the source (test_p4_health_collect.py:2534-2539).
- B's spawn-None and no-result exits (round_b.py:118, 140) have no run_lab test.
- `show_ports_trial` (s0.py:604-633) has no unit test.

**F10 (NIT):** the docstring at observe_a.py:618-622 rests on a pcap-mode trial (show_ports_cpu510.log:1-3, `--use-files`, `-i 1@p1`), not on the fabric's veth mode. The first live run's `cpu_port_listed` will settle it.

**Conditions for merging:**
- F1 fixed, with a test seen red and a mutant.
- F2, F3, F4 and F6 fixed.
- F5 fixed before the PR to main.
- The N5, N6 and N8 text fixed, or explicitly deferred by Adam.
- The mutation gate finished at the final head (298 mutations expected if nothing else changes).
- A judge pass on the fix diff only.
- No live run before all of the above.

## Claims audit
| claim | class |
|---|---|
| 6d9650ef "a stop signal ends the run" | SUPPORTED for an observer, a sniffer wait, an HTTP call and the gap between rounds; CONTRADICTED for the teardown window (F1) |
| 6d9650ef "a B that did nothing is incomplete" | SUPPORTED for the mode and never-ready exits; UNTESTED for spawn None and no result; CONTRADICTED by the sniffer-not-ready path (F2) |
| aacab54d, 9d5bc6ae, defc6017 "keeps what it read" | SUPPORTED |
| defc6017 "a grpc switch started as the fabric starts one lists only its data ports" | UNDER-EVIDENCED: shown in pcap mode only |
| b78584a5 "root executes those copies; health.json records their sha256" | SUPPORTED |
| b78584a5 "the shared tree can then change during a run without changing what root runs" | UNDER-EVIDENCED: true only after lab.py:167; about 111 s after the check; no comparison with HEAD |
| 991c2b21 "the mutation itself is the same" | SUPPORTED |
| 3ab969c6 "an unreadable override yields an incomplete fingerprint, which stops the run" | SUPPORTED by reading identity.py:121-135 and probe.py:153-158; UNTESTED |
| 3ab969c6 "fix an equivalent mutant" | SUPPORTED |
| 965106b1 and 27672d83 "no mutation changes" | SUPPORTED |
| your brief: final gate pending (55 caught, 0 survived) | SUPPORTED: 55 caught, no survivor marker, the log ends in C5 |

## Tests I would have run
1. run_lab with real handlers and a SIGTERM inside the fake `ndt down` (F1).
2. run_lab with B's h4 sniffer never ready (F2).
3. The see-red run stopped after K1; read the verdict and rc (F3).
4. run_lab through a symlinked run dir; check the controller entry in LAB_STATE.B.json (F6).
5. `cmd_lab` with `fabric_binary` raising OSError and the real fingerprint (F8).
6. Run the frozen hostside.py with `-I` and confirm that `p4_health.frames` loads from the copy.
7. Edit hostside.py on disk during a fake S0 and confirm that root runs the edit (F4a).
8. B's spawn-None and no-result exits through run_lab.
9. test_p4_health_cells.py on a tree with doc/audit/**/*.md removed (F5).
10. The full gate at the final head.
11. A SIGTERM during `ndt claim` under the new run-level handler. `subprocess.run` then SIGKILLs `ndt claim`, which writes the claim file with a plain redirection (ndt:824-826). Check the claim file and what recover.sh prints for phase "claiming".
12. show_ports on a veth-mode simple_switch_grpc with `--cpu-port 510`.

## Internal consistency
- **"2 survived" at 991c2b21** is one equivalent mutant plus a failed negative control. The harness counts the control failure as a survivor (mutate_p4_health.sh:2179).
- **N3b and N3c at 991c2b21** were "caught" only because their test was red in every copy.
- **The counts add up:**
  - mutations: 266, 284, 294, then 298 expected;
  - test_collect: 118, 125, 128, 129, 130;
  - test_cells: 118, 119;
  - test_recover: 136, 155, 163.
- **The r3 reds ran on uncommitted test text.** Their failure lines match the committed assertions (for example, n8.OLD_red.log:3 shows the exact frozen path the committed test builds), but the text that actually ran is not archived.
- **The archived S0 logs were moved after their runs.** r3/27672d83/s0-final/probe.log:1 and r3/b4194bed/s0-final/probe.log:1 both name r3/s0-final as their output. The HEAD on each first line still tells them apart.
- **lab_round.py's docstring** (:15, "they take the finally") and 6d9650ef's subject both promise more than the teardown handler does (F1).