**Verdict: MERGE AFTER FIXES**

All five asks are met in code. Every log:line the summary cites matches what it says. Two things block a plain MERGE:

- **Two checks in the new CI test have never been seen red.** "No process of this run is left" and "its temp tree is gone" also passed on d452d111 (summary line 36 admits this). These are the only checks that tell "the run ends" apart from "the run ends and cleans up". The project rule says a test is not delivered until it has been seen red.
- **The CI-cost figure is wrong, according to the branch's own logs.** Both are cheap to fix.

Scope of my reading: I judged against the five asks as listed in your brief. I did not read judge-559c6b26-r2.md, and I read notes.log only through one grep line. I used no git; the one commit message I checked came from the worktree's COMMIT_EDITMSG.

## Per ask

**1. DONE.**
- The traps are at topo_pid:64-66, liveness:109-111, sweep:95-97, window:121-123, ovs_claim:80-82 and down:164-166. They are identical to orphans:128-130.
- There is no other `trap` in the seven files. None in ndt, faults.sh or ndtwin-lab either.
- Red run on d452d111 (red-signal-test-d452d111.log):
  - six suites end with rc 1 at all twelve cited lines;
  - four of them take more than 20 s (21/29/29/30 s);
  - totals 112 checks, 20 failed (:225), rc=1 (:228);
  - orphans passes all 16 of its checks (:10-27).
- Green run at HEAD: 112 checks, all passed (:137), rc=0 (:140).
- Caveat: see D1 below.

**2. DONE.**
- The guard is at topo_pid:82, orphans:162, sweep:121, liveness:134, ovs_claim:275, down:110 and window:146.
- New gate on d452d111 suites: all 7 SUBSHELL mutants SURVIVED (red-gate-subshell-d452d111.log:44…112), 21 mutations / 7 survivors (:116), rc=1.
- At HEAD: all 7 caught with rc 143 and exactly one guard line (green-gate-head.log:44-112), 21/0 (:116). Sweep is included (:66), so errexit does not end the run before the TERM trap does.
- The multi-line `( … )` wrap: the old gate stays green (red-review1:23-24, rc 0). At HEAD the control is refused (green-review1:30, rc 2).

**3. DONE.**
- MUST_SURVIVE is exact (gate:233, used at :419). J7 rejects rc 124 and J8 accepts rc 1 (green-gate-head:17-18).
- Forced rc 124: the old gate accepts it (red-forced124-old-gate:32-33, rc 0); the new gate refuses it (green-forced124-new-gate:42, rc 2). I read the shim: it rewrites only the gone-without-true copy's rc.
- "nothing readable": the old gate calls the variant caught (red-unreadable:28); the new gate says SURVIVED (green-unreadable:35, rc 1). J9/J10 cover both FAILED-block layouts.

**4. DONE as asked.**
- Test 4: a missing anchor gives rc 2 (anchor-missing-head:32/:35); a doubled anchor gives rc 2 (anchor-doubled-head:32/:35).
- Test 6 is described, not run. `l1_unit_tests.sh:584` does glob `tests/shell/test_*.sh`.
- The cost sentence attached to test 6 is wrong (D2).

**5. DONE.**
- anchors-head: ok(22) at :54, 128/128, rc 0.
- The base had ok(15) (anchors-base-d452d111:46), so 22 = 15 + 7.
- HEAD's gates at both revisions: 256/256.

## The specific checks you asked for

**Traps**
- **143/130:** shown for all seven suites, at one point each. Under the gate's `timeout`, `kill -TERM "$$"` reaches only the suite's shell, and timeout passes the 143 back.
- **Cleanup once, via EXIT:** true by reading the code; no log shows it.
  - A second INT or TERM during cleanup runs `exit 1xx` inside the EXIT trap and cuts cleanup short. That can happen on a double Ctrl-C, or with GNU timeout's TERM to the child followed by TERM to the group.
  - orphans has the same exposure. Low risk.
- **errexit (sweep):** the TERM trap runs before errexit exits (rc 143 at :66).
  - Inside `reap_fixtures` errexit is live, because it is the last command of an `&&` list.
  - Only the bare `kill -KILL` could trip it, if a fixture is reaped between its comm read and the kill. That would end the EXIT trap early with rc 1. Negligible.
- **timeout's own process group:** timeout's group is not the terminal's foreground group, so a Ctrl-C on the gate never reaches the suite. The suite dies of SIGPIPE at its next write, and its EXIT trap still runs. This predates the branch.
  - On a real timeout the new traps are an improvement: the old cleanup-and-return trap kept the suite running after timeout's TERM.
- **Follow-up, from the pattern the ask prescribed:** `exit 130` is a normal exit. So the calling bash (l1_unit_tests.sh:599) treats the Ctrl-C as handled and goes on to the next file. The re-raise idiom (`trap - INT; kill -INT $$`) keeps the 130 status and lets the caller stop as well (worth verifying).

**BASHPID guard**
- No false red found. Every call site is a plain call, nothing sources these suites, and all controls and after-runs are green with unchanged counts (111/57/33/157/61/174/32).
- `kill -TERM "$$"` ends the run in all seven suites. Only the `( … )` form was run; the pipeline, `$( )` and `&` forms are reasoned, not tested.

**Moving the pid registration inside the substitution**
- The code is correct in all seven helpers, including both ovs_claim branches and down's SPAWNED_REG.
- The race is real for TERM sent to the suite's own pid. Bash runs pending traps when each command finishes. With the old order, the trap fired between `pid=$(…)` and `echo >> REG`, and the new fixture was never registered. The new order closes that.
- It is **not** closed for Ctrl-C (INT to the whole group), which is the signal the new test actually sends.
  - The substitution subshell is in the group and its traps are reset to default, so it can die between its fork and its `echo >> REG`.
  - The fixture ignores INT and then lives for up to FIXTURE_TTL. The window is under a millisecond.
  - The comments in all seven helpers claim the race is closed without this limit.
- Neither case was reproduced.

**Can the new test pass vacuously?**
- A suite that never reaches a fixture, or ends early, fails the premise check: red.
- A signal that is not delivered, or is ignored, leaves rc 0 or 1: red.
- A suite with no handlers at all dies by the signal. `wait` then reports 143/130, so the rc check passes. Only the two never-red checks would catch the missing cleanup.
- The token: for the four suites that write under /tmp, a token-carrying pid is tied to the fixture register. For window, ovs_claim and down, nothing ties a token process to a fixture; the premise could be met by the poll's own `sleep 0.1`. Their fixtures do carry the token today, by construction.

**The ≤20 s bound:** sound. At HEAD each suite ends in about a second (14 runs in 15 s). The sample point, just after the first fixture, only has short foreground commands. It is one fixed point per suite, though.

**CI cost:**
- The green log's stamps show 15 s (17:48:32 → 17:48:47).
- The "about 4 minutes" is the red run (17:30:16 → 17:34:33). That is what a regression costs, not the steady state.
- What matters is the worst case: 14 runs × (FIRST_WAIT 180 + HARD_LIMIT 600) s exceeds the CI job's `timeout-minutes: 30` (ci.yml:47-48). A hung suite would kill the job instead of printing a red line.

**The spawners left alone (from the code):**
- **liveness `spawn_app_fixture`: same race, much wider.** `app_spawn` forks a setsid'd app, writes the pidfile, then runs `sleep 1` (ndt:8794-8800). All of that happens before `SPAWNED+=` (liveness:468-469).
  - So for at least 1 s per call, a signal leaves bash plus a 120 s sleep running in their own session. Nothing reaches them.
  - The new test signals in section 1, so it never samples this window.
- **window `spawn_two_layer`: same shape, under a millisecond.** A trap can fire between `&` and `TWO_PARENT=$!` (window:548-549).
  - Also, before the child has exec'd, `reap_two_layer`'s cmdline check (:103) declines to kill it.

**Commit messages:**
- 14c490c3 is clean: one subject line, six plain lines, no trailers, none of the banned words.
- 668930a5's body could not be read without git.

## New defects, ranked

- **D1 (medium):** the new test's leftover-process and temp-tree checks have never been seen red.
- **D2 (medium-low):** the cost claim is contradicted by the logs, and the worst case exceeds the CI job's budget.
- **D3 (low):** the registration fix and its comments overstate the closure for Ctrl-C.
- **D4 (low):** `judge_subshell`'s "rc ≠ 143" and "green summary after the guard" branches have no control and no run.
- **D5 (low):** evidence hygiene.
  - The shim exists only in the scratchpad.
  - "No token process, no .spawn-gate-* left" has no archived output; notes.log:16 is prose and mentions only the token.
  - "14 mutations at d452d111" was never run.
- **D6 (low, follow-up):** spawn_app_fixture and spawn_two_layer, as above.
- **D7 (low, follow-up):** cleanup is not shielded from a second signal, and `exit 130` breaks caller propagation.

## Claims classified

**SUPPORTED:**
- every trap, guard and register line;
- every red/green log citation in items 1-5;
- suite counts before and after;
- the ten dependent gates and checks at rc 0;
- tripwire empty.
- Also l1-scoring.log:123 shows the lane's scorer reads the new test's summary, which is stronger evidence than the summary cites.

**UNDER-EVIDENCED:**
- "14 mutations at d452d111", under a header that says "all ran";
- "no token process / no .spawn-gate-* left";
- "closed a race";
- the apostrophe cause of the NO-ANCHORS failure (the fix's effect is supported);
- the +380/-50 line count (not recounted).

**CONTRADICTED:** "about 4 minutes" as the cost the test adds to L1.

**UNTESTED:**
- the new test as a detector of a missing cleanup;
- "nothing was pushed";
- INT sent to the suite's pid alone (labelled as such);
- the other spawners (labelled as such).

## Internal inconsistencies

- 4 minutes versus the green log's 15 s.
- "All ran, rc 0" covers a gate run that is not among the logs.
- "Line 1 is the HEAD, line 2 is porcelain":
  - anchors-superseded-e7e548fa.log and anchors-base-d452d111.log have no porcelain line;
  - line 1 is the worktree HEAD even for the runs on d452d111 trees, which are identified only on the `# dir:` line.
- The gate header is at :3-6, not :1-4.

## Tests I would have run

1. Remove `trap cleanup EXIT` from one suite (and separately make cleanup skip the reap), then run `test_fixture_suites_end_on_signal.sh <label>`. Both checks must go red under TERM and INT.
2. Keep the guard but restore the old cleanup-and-return TERM trap in one suite. The SUBSHELL mutant must be called SURVIVED through the rc ≠ 143 branch. Also add synthetic controls J13 (one guard line, rc 1) and J14 (one guard line, rc 143, then a green summary).
3. Insert a `sleep 1` between the fork and the register write, then send TERM to the pid and INT to the group, on the old and the new order. Expected: the old order leaks under TERM, and the new order still leaks under group INT.
4. Send signals at other points of each suite, including liveness section 6.
5. Send a double TERM 50 ms apart, and run `timeout -s TERM 2 bash <suite>`. Cleanup must still complete.
6. Press Ctrl-C through a calling bash script while one of these suites is running.
7. Time the green test directly instead of inferring, and run d452d111's gate in full.

## Fix list

**Required before merge:**
1. Run item 1 above and archive the log.
2. Restate the cost: 15 s when green, 4 min 17 s when red.
3. Copy `shim124/timeout` into the logs' `scripts/` directory. Archive raw output for the "nothing left" claim, or withdraw it. Label the 14 as derived from the diff.
4. Run `git log -1 --format=%B 668930a5` and check it against the commit-message rules.

**Recommended on this branch:**
5. Default `SIGNAL_HARD_LIMIT` to about 60 s and `FIRST_WAIT` to about 60-90 s.
6. Add J13/J14.
7. Limit the register comments to "a signal sent to this shell", or close the Ctrl-C window.

**Follow-ups on a separate branch:**
- Register `spawn_app_fixture`'s pid as soon as `app_spawn` writes its pidfile.
- Close `spawn_two_layer`'s windows.
- Make `trap '' INT TERM` the first line of each cleanup.
- Use the INT re-raise idiom.

## Files

- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001/tests/shell/test_fixture_suites_end_on_signal.sh (defaults at :36-38, signal and checks at :150-161)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001/tests/shell/mutate_fixture_spawn_helpers.sh (:233, :248-258, :312-315)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001/tests/shell/test_ndt_apps_liveness.sh (:457-474)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001/tests/shell/test_ndt_helper_apps_window.sh (:100-110, :545-561)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001/tools/test_workflow/ndt (:8794-8800)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001/.github/workflows/ci.yml (:47-48)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/red-signal-test-d452d111.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/green-signal-test-head.log
- /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/traps/shim124/timeout (not archived)
- /home/adam/Desktop/NDTwin-Kernel/.git/worktrees/wt-spawn-traps-1001/COMMIT_EDITMSG
