**Re-review of fix/spawn-helper-traps-1001 at e0bb7d7f (c8635940, 055acd84, e0bb7d7f on top of 14c490c3)**

**Verdict: MERGE AFTER FIXES.** All five round-1 items (D1–D5) are met, and every log line the round-2 summary cites says what it claims. The remaining fixes are three small ones in tests/shell/test_fixture_suites_end_on_signal.sh, all introduced by e0bb7d7f. None of them touches the trap fix itself.

**A correction to my round-1 report.** I said fixtures started as `( exec … ) &` ignore INT. They don't: r3-d1a:34 and r3-d1b:32 show topo_pid's in-group fixtures dying of the group INT even with no EXIT trap. The likely cause is that bash's `exec` puts INT back to how the suite's shell inherited it. Two consequences:
- My D1 fix item, "red under TERM and INT", could not be met for an in-group suite under INT.
- My D3 reasoning overstated the in-group Ctrl-C case. The window that matters is for setsid fixtures (down, and ovs_claim's setsid variant).

## Per item

**D1: DONE. The INT/topo_pid gap is acceptable; no further mutant is needed.**
- **No EXIT trap** (r3-d1a): the temp-tree check is red in all four runs (:20/:35/:52/:69). The process check is red for topo_pid TERM (:17), down TERM (:49) and down INT (:66). rc stays 143/130.
- **Cleanup skips the reap** (r3-d1b): only the process check goes red (:17/:41/:56).
- **Cleanup skips the tree removal** (r3-d1c): only the tree check goes red (:18/:33/:48/:63).
- The 055acd84 runs show the same pattern.
- Why the gap is acceptable:
  - The process check is the same code on both signal paths, and it has been seen red on the INT path (down, :66).
  - For topo_pid under INT the group signal kills the in-group fixtures itself, so a missing reap leaves nothing behind. That mutant is equivalent under INT; the green row is the true answer, not a blind check.
  - The reap is what matters on the TERM-to-shell path, and that path went red for both suites.
  - The two suites cover both ways the test finds a temp tree (by register for topo_pid, by TMPDIR for down).
- Optional: one header line saying the INT process check can only fail for fixtures outside the suite's process group.

**D2: DONE.**
- Cost, from the log stamps:
  - green 15 s (round 1), then 24/24/23 s in the three r3 runs;
  - red 4 min 17 s, now 4 min 3 s (r3-red :7/:237).
- New defaults: FIRST_WAIT 60 s, HARD_LIMIT 30 s, TOTAL_LIMIT 300 s.
- The total limit is checked before each run (:187-190). A skipped run prints a FAILED line, so it can never turn a red result green.
- Both new bounds were seen working:
  - a hung suite is killed at HARD_LIMIT with rc 137; two hung runs took 66 s, about 33 s each (r3-d2-hung :15/:38, :7→:59);
  - `SIGNAL_TOTAL_LIMIT=1` skips three runs with FAILED lines, rc 1 (r3-d2-total-limit :19/:22/:25).
- The 393 s arithmetic is right: one run is at most FIRST_WAIT + HARD_LIMIT + 3 s = 93 s, and the last run can start just before 300 s. Add a few seconds of /proc scans (the leftover poll is 30 × (0.1 s + one scan)).
- Against ci.yml's 30 minutes:
  - 393 s (6.6 min) is a bound for this one file.
  - "A hung suite is a red line rather than a killed job" only holds if the rest of build-and-test leaves 6.6 min free, and the job's normal duration has never been measured.
  - That can be read from any recent CI run; no push is needed. Not blocking.

**D3: DONE.** All seven comments are narrowed: a signal to the suite's shell is covered, a group signal still has a window. Orphans carries the full wording. e0bb7d7f correctly adds that in-group fixtures usually die of the Ctrl-C, and setsid ones are left to their TTL. The window was not closed, as allowed.

**D4: DONE.**
- J13 and J14 pass on the HEAD gate (r2-green-gate-head :23-24; full gate 21/0, rc 0 at :118/:121; r3-gate-orphans).
- The rc ≠ 143 branch was also exercised by a real run: down with its old cleanup-and-return trap restored and the guard kept comes out SURVIVED "rc 1, not the 143" (d4-test2 :40, rc 1 :47).

**D5: DONE.**
- The shim is archived at scripts/shim124/timeout. Its content is identical to the scratchpad copy; I can't hash it, so I didn't check the sha.
- leftovers.sh gives raw counts of 0/0/0 at both r2 and r3 (:10/:13/:16).
- d452d111's gate was run in full: 14 mutations, 0 survivors (d5-old-gate :88), rc 0 (:91).

**Round-1 item 4: still open.** The bodies of 668930a5 and c8635940 need `git log --format=%B` before merge. I read e0bb7d7f's from COMMIT_EDITMSG: plain style, no trailers, no banned words. But its subject, "while one of its fixtures is alive", claims more than its own body ("a live process of the run"). I skipped 055acd84 as you asked.

## Your question about e0bb7d7f's premise

It cannot hide a broken signal path. The rc and time checks are unchanged, and a suite that ends or shows no process of its own still fails the premise. But it introduces two defects:

- **N1 (low-medium): the loop accepts any process of the run, not a fixture.** A poll's `sleep 0.1`, drive's `bash -c`, or ovs_claim's `command sleep 0.1` in kill_fixture all satisfy it (:133-135).
  - For the four suites that write under /tmp this is harmless. Their temp-tree check (:154-156) still requires a pid that is in the fixture register.
  - For window, ovs_claim and down there is no such tie. The signal can land in ovs_claim's gap between kill_fixture and the next spawn. Then a broken reap passes that run, which is exactly the case the new comment (:126-129) says the loop prevents. Before e0bb7d7f that moment gave a red flake; now it can give an uninformative green.
  - The check title at :140 ("reaches a live fixture") and the commit subject say "fixture".
- **N2 (low): the check at :148-149 can no longer fail.** "A process of this run … is alive when it is signalled" is guarded by the early return at :139, yet it still counts in "Ran 112 checks".

Also:
- **N3 (low): the header is stale.** :18-19 says the signal is sent as soon as the first fixture line appears. :33 says "about 15 s"; r2 and r3 measured 23-24 s.
- **N4 (info): r3-red attributes two red rows to the old suites.**
  - "Old suites now fail the leftover checks": topo_pid's leftover processes (:131/:148, rc 1) are a genuine detection.
  - down's temp-tree failures (:206/:227) are not. They come from the test's own SIGKILL at HARD_LIMIT (rc 137 at :201/:222), which stopped the old suite before its exit cleanup.
- **Untested:** the 60 s FIRST_WAIT bound was never hit by a run (only HARD_LIMIT and TOTAL_LIMIT were). Low.

## Fix list

1. **N1.** Either make the premise true or make the words match it:
   - Preferred: in the wait loop, require a live token pid that appears in the suite's own register, for all seven suites. Set SREG for the TMPDIR suites (window `fixtures`, ovs_claim `fixture.pids`, down `spawned.pids`) and find the tree inside the loop.
   - Minimum: retitle :140 to "a live process of its own", correct the comment at :126-129, and reword e0bb7d7f's subject at merge.
2. **N2.** Drop :148-149, or print it as a note instead of a check.
3. **N3.** Update header lines :18-19 and :33.
4. **Before merge.** Check the 668930a5 and c8635940 commit bodies; reword 055acd84 as you planned.

If you'd rather merge first, the preferred option in item 1 can be a follow-up, provided the minimum wording fix goes in now.

**Follow-ups, unchanged from round 1:** the spawn_app_fixture and spawn_two_layer races, shielding cleanup from a second signal, the INT re-raise idiom, and the group-INT register window for setsid fixtures. Also read CI headroom from an existing run.

Files:
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001/tests/shell/test_fixture_suites_end_on_signal.sh (:18-19, :33, :126-149, :187-190)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/r3-d1a-no-exit-trap.log, r3-d1b-cleanup-skips-reap.log, r3-d1c-cleanup-skips-tree.log, r3-d2-hung-suite.log, r3-d2-total-limit.log, r3-red-signal-test-d452d111.log, r2-green-signal-test-head.log, d4-test2-returning-trap.log, d5-old-gate-full-d452d111.log
- /home/adam/Desktop/NDTwin-Kernel/.git/worktrees/wt-spawn-traps-1001/COMMIT_EDITMSG
