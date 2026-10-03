DELIVERED e0bb7d7f4beb7719c50a61f52b502948a4cb3179

Branch `fix/spawn-helper-traps-1001`, worktree `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001`. Head is e0bb7d7f, porcelain 0. Nothing pushed or merged.

Logs are in `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/` (L below). This round's overviews are `driver2.log` and `driver3.log`; findings are in `notes.log`.

How to read the logs:
- Line 1 is the worktree HEAD and line 2 is its porcelain count. For runs on a scratch tree, the tree is named only on the `# dir:` line, with its `.tree-id`.
- The trees are listed in `trees2.log` and `trees3.log`. Variants are exact single replacements made by `scripts/variant.py`.
- Every run went through the build guard on its own lock, with the nolab tripwire. The tripwire stayed at 0 throughout.

## Commits since 14c490c3
- **c8635940** `tests/shell: bound the signal test and narrow the register comments` — D2 and D3.
- **055acd84** `tests/shell: cover the rest of the SUBSHELL verdict in the gate` — D4, J13/J14.
- **e0bb7d7f** `tests/shell: signal each suite only while one of its fixtures is alive` — a premise flake this round found, plus a comment correction. Both are described under "New this round".

The diff from d452d111 is 9 files, +412/-50 at 055acd84 (`trees2.log` :1-10). The diff at HEAD is at the top of `trees3.log`.

## D1: the leftover checks seen red
I mutated topo_pid (a suite that writes under /tmp) and down (a suite that honours TMPDIR) three ways, then ran `test_fixture_suites_end_on_signal.sh topo_pid down`. Final runs on e0bb7d7f are below; round-2 runs on 055acd84 (`d1a/d1b/d1c-*.log`) gave the same pattern.

**(a) `trap cleanup EXIT` removed** (`r3-d1a-no-exit-trap.log`):
- "temp tree gone" is red in all four runs: topo_pid TERM :20, topo_pid INT :35, down TERM :52, down INT :69.
- "no process left" is red for topo_pid TERM :17, down TERM :49 and down INT :66.
- rc stays 143/130, so only the cleanup checks catch this mutation.

**(b) cleanup skips the reap** (`r3-d1b-cleanup-skips-reap.log`): only "no process left" goes red — topo_pid TERM :17, down TERM :41, down INT :56.

**(c) cleanup skips the temp-tree removal** (`r3-d1c-cleanup-skips-tree.log`): only "temp tree gone" goes red — :18, :33, :48, :63.

**Not met as written: topo_pid INT's process check stays green under (a) and (b).** The group INT itself kills those fixtures, so nothing is left for the check to find.
- My inference for why: a `( exec -a … sleep ) &` fixture's subshell resets its signals to what the suite's bash started with. The suite starts with INT at default (`env --default-signal=INT`), so the fixture does not ignore INT.
- down's fixtures are setsid, in their own session, and they make the check red under INT.
- So the process check is seen red under INT only through a setsid suite.

## D2: CI cost and worst case
**Measured from the log stamps:**
- Green: `green-signal-test-head.log` :7 → :139 is 17:48:32 → 17:48:47, so 15 s. After e0bb7d7f it was 24, 24 and 23 s in three runs (`r3-green-signal-test-head-{1,2,3}.log` :7/:139, all rc 0 at :140).
- Red on d452d111: `red-signal-test-d452d111.log` :7 → :227 is 17:30:16 → 17:34:33, so 4 min 17 s. With the new limits it was 4 min 3 s (`r3-red-signal-test-d452d111.log` :7/:237).

**New defaults:** `SIGNAL_FIRST_FIXTURE_WAIT=60`, `SIGNAL_HARD_LIMIT=30`, and a new `SIGNAL_TOTAL_LIMIT=300`. No run starts after the total limit; each run it skips prints a FAILED line instead.

**Arithmetic:**
- One run is at most 60 + 30 + 3 s (the leftover poll) = 93 s.
- The whole test is at most 300 + 93 = 393 s, about 6.6 min, against build-and-test's `timeout-minutes: 30`.
- Without the total limit it would be 14 × 93 = 1302 s, about 21.7 min. Under the old defaults it was 14 × (180 + 600) = 10920 s.

**Both bounds seen working:**
- A topo_pid that ignores INT/TERM and sleeps after its first fixture prints "still running 30s after the signal: killed (SIGNAL_HARD_LIMIT)" (`r3-d2-hung-suite.log` :15, :38). It ends with rc 137 (:17, :40) and both runs together took 66 s (:7 → :59).
- `SIGNAL_TOTAL_LIMIT=1` runs the first test, then prints 3 FAILED "run, before SIGNAL_TOTAL_LIMIT (1s) was used up" lines (`r3-d2-total-limit.log` :19, :22, :25), rc 1.

## D3: register comments narrowed, window left open
- All seven helpers now say the in-substitution register covers a signal sent to the suite's own shell, not one sent to its whole process group. Orphans' helper carries the full wording; the other six point to it.
- I did not close the window.
- e0bb7d7f also corrects my earlier "the fixture (it ignores INT)" wording to what D1 showed: a fixture in the suite's own process group usually dies of the Ctrl-C with it; a setsid one is left to its TTL.

## D4: judge_subshell's untested branches
- J13 and J14 run green on HEAD's gate: `r2-green-gate-head.log` :23-24, where the full gate gives 21 mutations, 0 survivors and rc 0; and `r3-gate-orphans.log` at e0bb7d7f.
- Review test 2: down with the old cleanup-and-return trap put back and the guard kept. Its SUBSHELL mutant comes out "SURVIVED down subshell (rc 1, not the 143 of the TERM the guard sends)" (`d4-test2-returning-trap.log` :40), rc 1 (:47).

## D5: evidence hygiene
- **Timeout shim archived** at `L/scripts/shim124/timeout`. Its sha256 096f7f6d… matches the scratchpad copy.
- **"Nothing left" is now raw output:** `scripts/leftovers.sh` lists every process carrying the test token, every `.spawn-gate-*` copy in the worktree and the trees, and every temp tree for the eight prefixes. `r2-leftovers.log` and `r3-leftovers.log` give 0/0/0 (:10, :13, :16).
- **d452d111's gate run in full** (`d5-old-gate-full-d452d111.log`): 14 mutations, 0 survivors (:88), rc 0 (:91). The 14 is now a run count, not derived from the diff.

## New this round
**Premise flake, fixed in e0bb7d7f:**
- `r2-green-signal-test-head.log` :112: ovs_claim's INT premise "a process of this run besides the suite is alive" read "no (0)".
- Cause: ovs_claim stops its first fixture after one `drive` (`kill_fixture "$LIVE_VIZ"`). The test sometimes polled after that.
- The fix: the test now waits until a fixture line has been printed and a live process of the run exists, both at once. Since then the green runs are 3/3.
- I reran all of the signal test's red runs on the new version. In `r3-red-signal-test-d452d111.log` (112 checks, 22 failed), the old suites now sometimes fail the leftover checks too: topo_pid processes :131/:148, down temp tree :206/:227.

**Sanity at e0bb7d7f, from the `driver2.log`/`driver3.log` rows** (the r2 rows ran at 055acd84):
- The seven suites are unchanged: 111/57/33/157/61/174/32 (r2-suite-*), orphans 111 again (r3).
- mutate_l1_shell_scoring: 53/53 killed.
- test_l1_shell_scoring: 151/0.
- check_test_tmpdirs: 0 fixed temp paths.
- check_gate_anchors HEAD: 128/128 ok, the gate at ok(22).

## Not done (your follow-up list)
- spawn_app_fixture and spawn_two_layer races.
- `trap '' INT TERM` first in each cleanup.
- The INT re-raise idiom.
- The register window for a group INT (D3).
