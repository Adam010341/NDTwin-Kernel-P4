[Co-developed with claude code -- Adam]

<!-- Saved verbatim by the orchestrator from the opus-judge hand-back, 2026-10-09 ~22:0x. -->

# Review r6: P4 health check, Cut 2 offline. r6 diff only (`feat/p4-health-cut2`, 257fd0e0 → b518b9fb; code head b09cd060)

## Verdict: MERGE AFTER FIXES

- **Before trunk:** one docs-only SUMMARY commit covering findings 2–5. It needs no gate re-run.
- **Before the first live run:** finding 1. Either fix it in code (then a full gate at the new head and a review of that diff), or keep §6's check after a stop that B was not claimed. The standing items are at the end.
- **Can the code go to trunk now?** Yes, the code at b09cd060, as offline code. The gate holds, and nothing reaches the lab without Adam's authorization. Land the SUMMARY fixes first: §6 is the live procedure and §10 is the gate's record.

**What is sound**
- **The r5 items are fixed as asked.** r5 #2, #3, #5, #6, #7, #8, #10 and the pin-HEAD NIT each have a red on a test-only commit, a green, and caught mutants (table below). r5 #4 is fixed only if the probe process has one thread (finding 1).
- **No refusal is loosened.** The new refusals are: the exercise-copy check (frozen.py:99-147, called at s0.py:697, turned into rc 2 at probe.py:211-216); HEAD that cannot be named, or that moved (probe.py:158-161, :182-187); the aggregator's commit, tree and `--commit` checks (r6-diff.patch:2453-2474).
- **`as_set` changes nothing live** (table.py:292-298). It treats a list as equal only to the tuple it came from, so live observations compare as before.
- **The gate at b09cd060 holds.** I read all four shard logs in full: commit b09cd060 on line 1 and on the HEAD line; tree 4acc71ea with no `+UNCOMMITTED` mark; subject sha 00baee280a968776, gates sum 4851d9607830aed5 (shard{0..3}:1, :6-9); baseline, negative control, both byte-identical lines and the after-check are green, and rc=0 (shard0/1:14, :696-701, :706; shard2/3:14, :690-695, :700); 113/113/112/112 = 450 (shard0/1:703, shard2/3:697), with 450 "✅ caught" lines, 53 C2R6 headers (13/14/13/13) and every anchor count 1; no SURVIVED, WRONG TEST, HUNG, NO-SUITE, REFUSED, ENOSPC, Errno, "No space", Terminated or Killed line; the GATE line is the same in GATE.log:2 and GATE.at_doc_head_with_commit.log:2, and a run without `--commit` at b518b9fb is refused (GATE.at_doc_head_without_commit.log:2).
- **Neither the stops nor the low disk changed any result.** The control the hand-back did not use is the first r6 run at c82a9f49 (run1): it ran the same 450 mutants over the same tools tree and subject sha (run1 shard*:7-8) and the same suites; c82a9f49 → b09cd060 changes only C2R5-10b's expected test (r6-diff.patch:2695-2704); it was never stopped: the only STOP events are 06:29, 17:31 and 19:39 (wd5:21-25), and run1 ran 06:50–13:09 (wd6:424, :1187); final shards 0, 1 and 3 match run1 entry for entry (expected test and the full red list). The one exception is 10b: WRONG TEST in run1 (run1 shard0:559-560), caught in the final run by the test that was red there (shard0:559-560); shard 2 matches run1 on every "caught by" line.

## How I judged it

- Read-only: no git, nothing executed, no files written.
- Read in full: r6-diff.patch (26 commits) and the hand-back (as claims); the four final shard logs, run1 shards 0, 1 and 3 (shard 2 on its "caught" lines); every n*.RED/GREEN log, GATE*.log, the final check logs, both disk_watchdog logs, and the result lines of the partial and aborted logs; SUMMARY §6 and §9.2–§10.
- Spot-checked code: probe.py, lab.py, lab_round.py, frozen.py, report.py, run.sh, the run section of mutate_p4_health.sh, and parts of s0.py, vs_trial.py and the new tests.
- Read only for the finding definitions: the r5 review.
- Two reads outside the inputs: scratchpad/watchdog.sh (now the r6 sampler, 9 lines, no STOP logic; the r5 stopper's code is gone, nothing below depends on it); a file listing of the main checkout's tools/p4_health/exercise/ (an uncommitted observation: the committed files plus `__pycache__`).
- Paths: W = …/scratch/overnight-2026-09-05/wt-p4-health-cut2/; L6 = …/logs/gates-0910/p4-health-cut2/r6/; wd6 = L6/disk_watchdog.log; wd5 = r5/disk_watchdog.log; shardN = L6/mutate_p4_health.shardNof4.log; run1 shardN = L6/mutate_p4_health.run1_c82a9f49.shardNof4.log; SUMMARY = W/doc/audit/2026-10-03_p4-health-check/SUMMARY-cut2-offline.md

## Findings

### 1. MINOR (live path; code): finding 4's fix works only in a one-thread process, and nothing shows the probe is one when run_lab runs

What the fix rests on: `_masked` blocks the three stop signals in the calling thread only (lab_round.py:330-334). Its reason is "The probe has no threads (nothing under tools/p4_health imports threading), so masking the main thread masks the process" (lab_round.py:324-326). SUMMARY:488 repeats it. That is true of the package's own code. It is not shown for the running process.

S0 starts threads inside the probe process. S0 runs the ValueSet trial in-process (s0.py:569-575, called at :705): `import grpc` (vs_trial.py:64); `grpc.insecure_channel` (:84); a `StreamChannel` fed by a generator that sleeps 8 s (:88-94). gRPC's Python layer reads a request iterator on a thread of its own, and its C core runs worker threads. Nothing shows how many are still alive after `chan.close()` (:132), when run_lab starts.

What happens if one is left (a thread that does not block SIGTERM): the kernel hands a SIGTERM sent to the process to that thread while the main thread is masked; Python then runs the handler in the main thread at its next check, which is inside the masked region; that handler is still the round's `_noter` (lab_round.py:300-305), and `_finish` has already read `teardown_signal` (:431); so the stop is lost and B is claimed, exactly r5 #4. The swap under mask from r5 NIT 10 (lab_round.py:307-316, lab.py:126-135) rests on the same premise. Finding 3's fix stays safe either way, because main() catches SignalAbort (probe.py:299-306).

Found by reading; nothing was run. The window is as small as in r5, but §6 dropped the check after a stop on the strength of this fix (SUMMARY:233).

Fix (any one, then a full gate and a review): block SIGTERM, SIGINT and SIGHUP around `vs_trial()`, so that any thread gRPC starts inherits the block; run the trial as a subprocess, as the controller already is (ctrl_trial.py:84); in run_lab, when `/proc/self/task` has more than one entry, refuse, or re-read `teardown_signal` after the restore. Add a test: the finish-hook test (test_p4_health_collect.py:3218) with one extra running thread started first.

### 2. MINOR (text): SUMMARY §10.3–§10.4 describe the stops wrongly and leave out the evidence that clears them

- The shard 3 stop: SUMMARY:518 (and handback:66) says 19:43 to 20:00, 17 minutes, cause unknown. The stop began at 19:39:23 (wd5:25). The free-disk samples go flat from 19:41:17 and start moving again at 19:58:19 (wd6:1987-2021). The cause is the leftover r5 watchdog.
- The second stop is missing: shard 1 was also stopped, 17:31:53 to 17:32:53 (wd5:23-24; flat samples at wd6:1725-1726).
- §10.4 rests on a check that cannot see test errors: SUMMARY:530 relies on "no ENOSPC, Errno 28 … line". The shard log keeps only the names of red tests (mutate_p4_health.sh:3197, :3202, :3207), never their messages. What does settle the stops and the disk question is the run1 comparison above. Cite it.
- The log-format sentence is wrong: SUMMARY:475 says every log has `tracked-dirty` on line 2. In shard, partial and GATE logs, line 2 is `gate :` or the GATE line. Several logs carry a note added to line 1 (partial_*, GATE.at_doc_head_*), not only GATE.run1 as handback:5 says.

### 3. MINOR (test evidence): the pin re-check is caught only by its message, and §10.1 misreports its red

- The re-check's only test commits frames.py right after the pin (test_p4_health_cells.py:2829-2838). frames.py is one of the frozen files (frozen.py:40), so without the re-check the freeze refuses the change anyway. So C2R6-pin-b, which removes the re-check, is caught only by `assertIn("HEAD moved", err)` (shard2:658-662).
- The case the re-check exists for is not tested: a commit, between the pin and the re-check, to a module that is loaded but not frozen (lab.py, cells/table.py). Without the re-check, that run reaches S0 with `frozen_head` naming a commit its modules were not read from. c1d29a7a moved the other pin test's commit to after the re-check, onto unrelated.txt (r6-diff.patch:1831-1841).
- SUMMARY:494 misdescribes npin.cells.RED.log: "a commit after the pin was not refused": the old code did refuse it, with the freeze's message (npin:32). "frozen.head is the later HEAD": the hook never fired on the old code; the assertion that failed is the test's own precondition, "HEAD did move" (npin:40-42). "the pin is not the first git call" is a real behavioural red (npin:52). "an unnamed HEAD was not refused" is not what the red shows; it shows only that the freeze was reached after the clean check (npin:22).
- Fix: move the first test's commit to lab.py. With pin-b, S0 is then reached, which is a behavioural catch. This changes a test, so it goes with the next gate. Otherwise, record the gap in §10.2.
- Same class, smaller: C2R6-5b replaces `os.replace` with `os.rename` (r6-diff.patch:1318-1322), which does the same thing on Linux. It is caught only because the test patches the name `os.replace` (test_p4_health_collect.py:3306-3315). n5's `0 != 2` red (n5.collect.RED.log:60) is the same artefact; SUMMARY:489 says so.

### 4. MINOR (text): §6 still cites line numbers that r6 moved, and two sentences are out of date

Stale citations (cited → now): `probe.py:155` → :172 (SUMMARY:182); `frozen.py:36-38` → :40-42 (SUMMARY:182); `probe.py:49-57` → :59-67 (SUMMARY:182); `s0.py:663` → :673 (SUMMARY:185); `s0.py:233`, `:275` → :243, :285 (SUMMARY:186); `s0.py:297` → :307 (SUMMARY:187); `probe.py:197-206` → :231-240 (SUMMARY:189); `lab_round.py:374-377`, `:394-397` → :393-396, :413-416 (SUMMARY:179). Lines 374-377 are now the claim-refused branch.

Out-of-date sentences:
- SUMMARY:198, "HEAD is the one the freeze pinned". HEAD is now pinned first (probe.py:158), and the freeze is handed that sha (:189-193, :201).
- SUMMARY:196 and probe.py:47-50 say the copy is what S0, the controller trial and lab.load_model then run. But the copy is checked once, right after compile_all (s0.py:697); it is then passed to the shared tree's unchecked convert.py as input (s0.py:243); lab.load_model runs it later (lab.py:224). So the guarantee holds only while convert.py, which nothing checks, does not write into its input. Say so, or check the copy again right before load_model.

### 5. NIT: gaps §10.2 does not list (all fail safe)

- A stop between `ndt claim` and the round's `try:` (lab_round.py:372-391, including a stop delivered when `_handlers(True)` lifts its mask, :346, :316). Such a stop raises out of `run()` with the claim held and no teardown. It predates r6 and fails safe: take_unrecorded marks the record as cut off (lab.py:108-113), and recover.sh handles a null `claim_expires` (test_recover.log:134, :161).
- `set_verdict_aside` renames whatever health.json is in the run dir (probe.py:255-267). If a run dir is reused and the catch-all fires before the freeze would refuse it (say, an import error in load_lab_path), an earlier run's verdict gets renamed. Needs `P4_HEALTH_RUN_DIR` to be reused; §6 makes a fresh dir (SUMMARY:211).
- The new `ERROR:` prefix confuses the gate's parser: probe.py:314 prints lines starting `ERROR:`, which the gate's `FAIL|ERROR: <name>` parser reads as test names (mutate_p4_health.sh:3197). It adds a fake test named "the" to red lists (shard1:500, :506). No expected test is called "the", so no verdict changes.
- The gate script itself: the shard log has no per-mutation time stamp, so the stop analysis below is an estimate. `check_gate_anchors` reports ok(420) for a 450-row table (check_gate_anchors.HEAD.log:109; r5 had 373 for 397), and nothing explains the gap. Housekeeping: the worker's SIGCONT watcher's scope and whether it is still running are unrecorded. Check that it is gone.

## The stops (question 3)

The shard logs carry no time stamps and no per-mutation wall time, and keep no suite output, so the mutation in flight and exit codes 124/137 cannot be read from them. Estimated from wd6 START/END lines at ~48 s per suite cycle (shard 1: 5569 s over 116 cycles; partial_C2R5-10b.log:34: 3m11.6s for 4 cycles).

Why a timer cannot produce a "caught": any rc 124 from a `timeout 300` prints HUNG and counts as a survivor (mutate_p4_health.sh:3195, :3200, :3205, :3253-3254); no shard has a HUNG line. GNU `timeout` without `--foreground` runs in its own process group, so stopping the `timeout 21600 …` group does not freeze the inner timers. The outer 6-hour timer never ran out: shard 3 took 1h51m.

| window | where | in flight (estimate) | baseline and controls | verdict |
|---|---|---|---|---|
| 17:31:53–17:32:53 (wd5:23-24) | shard 1, 4271 s after 16:20:42 (wd6:1582) | about cycle 89 of 116: #88 C2R5-9a, #89 C2R5-5b (shard1:538-548); with 5 % drift, #84 C2R5-2f to #93 C2R5-11f | baseline first cycle; control and after-check the last two (~17:53–17:54:31, wd6:1770); outside | sound: all 113 entries equal run1 shard 1 (08:28–10:04, unstopped) |
| 19:39:23 to SIGCONT ~20:00 (wd5:25; wd6:2025) | shard 3, 775 s after 19:26:28 (wd6:1957) | about #14–#16: C5, B4, B8 (shard3:94-110) | baseline ~19:26–19:27; control and after-check ~21:16–21:17:40 (wd6:2181); outside | sound: no HUNG line although a frozen `timeout 300` would have fired after 19+ min; all 112 entries equal run1 shard 3 (11:37–13:09, unstopped) |
| 06:29:38–06:30:39 (wd5:21-22) | after the abort (wd6:320), before run1 (wd6:424) | no shard of either gate | — | touches neither gate |

No re-run is needed. Smallest optional re-run at b09cd060: seven partial runs (~3 min each) with `ONLY_LABEL_PREFIX` C2R5-9a, C2R5-5b, C2R5-5f, `C1.`, `C5.`, `B4.`, `B8.`. Not recorded anywhere: the final shard 0 took 2h22m (wd6:1197, :1482) against 1h37m for the same 113 mutants in run1 (wd6:424, :619); no stop recorded; its entries still match run1.

## Disk (question 4)

Minimum 1042 MB at 20:10:50 (wd6:2047). The gate swings free space by ~100–150 MB per cycle (wd6:1003-1186). No "caught" came from a write failure: after 19:39 shard 3 ran with 1042–1506 MB free and is entry-for-entry identical to run1 shard 3 (2142–2291 MB free).

## Each r5 finding

| r5 | fixed? | red on the old code | green | mutants |
|---|---|---|---|---|
| #2 (code) | yes; see finding 4 for the convert.py caveat | n2.cells.RED.log at e85aab7a: 4 behavioural (:57 `[510] != [4242]`; :77, :96, :115 `(None, True) != (2, False)`), 5 interface | n2.cells.GREEN, n2.*.full.GREEN (164/162) | 2a–2k (11) caught (shard0/1/2/3:610-626) |
| #2 (text) | probe.py comment fixed (:45-57); §6 citations stale (finding 4) | — | — | — |
| #3 | yes | n3.collect.RED.log:79, :14; n3.cells.RED.log:21 | n3.*.GREEN (164/165) | 3a–3e caught |
| #4 | yes, if the process has one thread (finding 1) | n4.collect.RED.log:12, :22 | n4.*.GREEN (166) | 4a–4e caught |
| #5 | yes | n5.collect.RED.log: 4 behavioural (:25, :40, :70, :99), 1 test artefact (:60) | n5.*.GREEN (171) | 5a–5f caught; 5b changes nothing on Linux |
| #6 | yes | n67.gatescripts.RED.log: 22 of 68, mostly interface; behaviour shown by caught 6a–6d | n67 GREEN, 68/0 | 6a–6m caught |
| #7 | yes | n67 RED:36-39 interface only; behaviour shown by caught 7a (shard2:682-686) | n67 GREEN | 7a–7d caught; guard removed, no mutant |
| #8 | yes, labels only (r6-diff.patch:2584-2636) | none, by design | final suites | none |
| #9 | not in this diff (fixed in 257fd0e0); new cases of the same kind in §10 (findings 2, 3) | — | — | — |
| #10 | yes | n10.collect.RED.log:30, 3 TypeErrors | n10.*.GREEN (174) | 10a–10e caught |
| pin NIT | yes in code (probe.py:158-193) | npin.cells.RED.log: 2 behavioural (:52, :22), 1 message-only (:32), 1 precondition (:42) | npin.*.GREEN (169/174) | pin-a, pin-c, pin-d by behaviour; pin-b only by its message (finding 3) |

## Claims audit (the hand-back)

| claim | class |
|---|---|
| b518b9fb docs-only; code head b09cd060; tree 4acc71ea | SUPPORTED (r6-diff.patch:2713; shard*:7) |
| nothing pushed; no live run, ndt, sudo, pkill -f | UNTESTED |
| every log line 1 `commit`, last `rc=`; exceptions only disk_watchdog and GATE.run1 | SUPPORTED in substance, other line 1s annotated too; SUMMARY:475 CONTRADICTED |
| commit-message check over 26 commits, zero hits | UNDER-EVIDENCED (no log); subjects consistent |
| commit table; findings 2, 3, 5, 6, 7, 8, 10 | SUPPORTED |
| finding 4's red, green, mutants, choice | SUPPORTED; premise "no threads" UNDER-EVIDENCED (finding 1) |
| pin NIT fix and "Red: npin (4)" | fix and count SUPPORTED; 2 of 4 reds not behavioural (finding 3) |
| 53 new mutants, 450 = 397 + 53; partials 0 except 5b, fixed | SUPPORTED |
| GATE line, shards, 113/113/112/112, rc 0, refusal without --commit | SUPPORTED |
| two failed earlier runs | SUPPORTED (aborted log:451, :552; run1 shard0:559; GATE.run1:2-5) |
| final checks | SUPPORTED (174, 170, 163, 68, 133/133, 416) |
| disk: 2152 samples, min 1042, max 2624, nine waits | SUPPORTED (wd6:2047, :1746, :1483-1571) |
| no ENOSPC / Errno 28 line | SUPPORTED as stated; cannot detect a test's own ENOSPC (finding 2) |
| shard 3 stopped "about 19:43 to 20:00" | CONTRADICTED (wd5:25: 19:39:23); shard 1 stop not mentioned |
| "C5 was in flight, then caught" | in flight UNDER-EVIDENCED (fits estimate); caught SUPPORTED (shard3:97, same as run1) |
| watcher "never fired again" | UNDER-EVIDENCED (log not kept) |
| §10.2 list | SUPPORTED but incomplete (findings 1, 3, 5) |

## Tests I would have run

1. The finish-hook test (collect:3218) with one extra running thread that does not block SIGTERM. Expected red at b09cd060.
2. A real offline S0 with throwaway switches, then a count of `/proc/self/task` when run_lab would start.
3. The pin test with the commit on lab.py instead of frames.py, with and without pin-b.
4. A SIGTERM right after the fake `ndt claim` returns (lab_round.py:373): rc, the "cut off" problem, the LAB_STATE phase, then recover.sh.
5. A reused run dir holding a health.json, plus an exception before the freeze: is the old file renamed?
6. A fake convert.py that appends to `<input>/gen_runtime.py`: does lab.load_model run the change?
7. An uncommitted edit to test_p4_health_cells.py, made after a shard's header and undone before it ends (only mutate_p4_health.sh:83 and :3296-3300 look for edits).

## Numbers that don't agree

- The stop's length: SUMMARY:518 says 17 min (19:43–20:00); wd5:25 has 19:39:23 (≈19 min by samples, 21 to the 20:00:13 note).
- Line 2 of the logs: SUMMARY:475 `tracked-dirty`; shard*:2 is `gate :`.
- SUMMARY:494 vs npin.cells.RED.log:32 and :40-42.
- Anchor count ok(420) vs a 450-row table.
- Shard 0's time 2h22m final vs 1h37m run1, no stop recorded.
- Counts that add up: 113+113+112+112 = 450 = 397+53 with 450 "caught"; `===` headers N+2 per shard; collect 162+2+2+5+3 = 174; cells 153+11+1+4+1 = 170; gate scripts 43+25 = 68; 2153 `free_mb=` lines = 2152 samples + end record.

## Before trunk

1. One docs-only SUMMARY commit: finding 2 (§10.3/§10.4 stops and disk, citing the run1 comparison; §10's log-format sentence); finding 3 (the §10.1 pin row); finding 4 (the §6 citations and the two out-of-date sentences); findings 1, 3 and 5 (additions to §10.2). No gate re-run.
2. Confirm the worker's SIGCONT watcher is no longer running.

## Before the first live run

1. Finding 1: fix it in code with the extra-thread test, or keep §6's check after a stop (`LAB_STATE.B.json` absent, no "bring-up B (external)" line, no second claim; SUMMARY:233). A code change means all four shards re-run at the new head, the GATE line shown with the four logs, and a review of that diff. If so, fold in finding 3's test and the re-check before load_model (finding 4).
2. Disk: free space above §6's floor of 2500 MB (SUMMARY:210). On 10-09 it was 1042–2624 MB, 1375 MB at the end (wd6:2183).
3. Unchanged from r5: §6's announcement to every session and the helper-tree check (r5 #1; ndt side open); Adam's per-run authorization; the `repo_untracked` decision before the first record becomes a standing authorization.

Nothing else found blocks the first run.
