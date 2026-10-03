DELIVERED 14c490c3b2e3dc0c39fe5c8147c8f97d5af40ed5

Branch `fix/spawn-helper-traps-1001`, worktree `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001`. Head is 14c490c3, porcelain 0. Nothing was pushed or merged.

Logs are in `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/` (called L below):
- `notes.log` is the findings log.
- `driver.log` is the overview.
- Each run has its own log, made by `scripts/run.sh`. Line 1 is the HEAD, line 2 is `porcelain-lines`, and the last line is `rc=`. Runs went through the build guard with JOBS=1, a separate lock of their own (nothing here builds), and the nolab sudo/curl tripwire first on PATH. The tripwire stayed at 0 lines throughout.
- Old-code runs used `git archive` trees in the scratchpad (`.../scratchpad/traps/`), built by `scripts/make_tree.sh` and `scripts/variant.py`. `trees.log` records what each tree holds.

## Commits (d452d111..14c490c3, 9 files, +380/-50)
- **668930a5** `tests/shell: let INT and TERM end the fixture-spawning suites`. Six suites get the trap fix. All seven helpers get the `$BASHPID` guard and in-substitution pid registration. Adds the new test `tests/shell/test_fixture_suites_end_on_signal.sh`.
- **14c490c3** `tests/shell: hold the spawn helpers to their own shell in the gate`. Changes `mutate_fixture_spawn_helpers.sh`.

## Item 1: INT/TERM end the run
**Change:**
- Each of the six suites now has `trap <cleanup> EXIT` + `trap 'exit 130' INT` + `trap 'exit 143' TERM`, the orphans pattern. Lines at HEAD: topo_pid:64-66, liveness:109-111, sweep:95-97, window:121-123, ovs_claim:80-82, down:164-166.
- I also closed a race this test could hit: each helper now writes the fixture pid to its register inside the `$( … & echo $! >> REG; echo $! )` that starts the fixture, not after the assignment.
- down's `SPAWNED` array became a register file, `SPAWNED_REG`, which its cleanup reads.

**The new test:**
- For each suite it sends TERM to the suite's pid, and INT to its process group. The suite is started under `setsid` + `env --default-signal=INT`.
- It waits for the first `ok fixture took argv0=` line before sending.
- It then checks:
  - rc 143 / 130;
  - the run ends ≤20 s after the signal;
  - no process carrying the run's environ token is left;
  - its temp tree is gone.
- Per suite it also checks four premises.

**Red, d452d111's suites** (`red-signal-test-d452d111.log`):
- orphans: TERM and INT all ok (:10-27).
- Each of the six fails "the run ends with 143/130", actual 1, under both signals: liveness :33/:50, sweep :67/:82, window :97/:112, topo_pid :127/:144, ovs_claim :161/:178, down :195/:212.
- liveness, topo_pid, ovs_claim and down also take more than 20 s (21-30 s).
- Totals: "Ran 112 checks, 20 failed" (:225), rc=1 (:228).
- The leftover-process and temp-tree checks passed even on old code, so on that code the exit status and the time are what turn it red.

**Green, HEAD** (`green-signal-test-head.log`): "Ran 112 checks, all passed" (:137), rc=0 (:140).

## Item 2: `[[ $BASHPID == "$$" ]]` in every helper
**Change:**
- All 7 helpers (topo_pid:82, orphans:162, sweep:121, liveness:134, ovs_claim:275, down:110, window:146) print a FAILED line to stderr, `kill -TERM "$$"`, and `exit 1`.
- The gate gains a SUBSHELL mutant per suite: one call wrapped in `( … )`. It counts only when the guard's line appears once, rc is 143, and no green summary follows. J11 and J12 are its synthetic controls.

**Red:**
- `red-gate-subshell-d452d111.log` (new gate on d452d111 suites): all 7 SUBSHELL mutants SURVIVED (:44, :55, :66, :79, :90, :101, :112). topo_pid's run was even rc 0 (:90). Totals: 21 mutations, 7 survivors (:116), rc=1 (:119).
- Review's test 1, a multi-line `( … )` around topo_pid's DECOY call, with the old gate (`red-review1-topo119-d452d111.log`): control "Ran 60 checks, all passed" (:23), premise count 3/3 (:24), rc=0 (:35). The gate stayed green, as the review predicted.

**Green:**
- `green-gate-head.log`: all 7 SUBSHELL mutants caught with rc 143 (:44-:112). That includes sweep, so errexit did not end the run first. Totals: 21 mutations, 0 survivors (:116), rc=0 (:119).
- The same multi-line wrap at HEAD (`green-review1-topo119-head.log`): "refused: topo_pid -- the unmutated copy is not green (rc 143): FAILED spawn called outside this suite's own shell" (:30), rc=2 (:33).

The gate header at :1-4 now describes this enforcement.

## Item 3: gone-without-true needs rc 1; GONE needs "nothing readable"
**Change:**
- `MUST_SURVIVE` (gate :233) is exact: `SURVIVED (rc 1, and no "Ran N checks" line at all)`, used at :419.
- `gone_block_says_unreadable` (:237) is applied to GONE at :402.
- Synthetic controls J7-J10.

**Red:**
- A forced timeout uses a PATH shim (`scratchpad/traps/shim124/timeout`) that reports rc 124 for the gone-without-true copy. With the old gate (`red-forced124-old-gate.log`): "ok sweep gone-without-true survives as it must: SURVIVED (rc 124 …)" (:32-33), rc=0 (:38).
- With sweep's "nothing readable" text changed and the old gate (`red-unreadable-old-gate.log`): GONE "caught" (:28), rc=0 (:37).

**Green:**
- `green-forced124-new-gate.log`: "refused: sweep gone-without-true -- this mutant must end with rc 1 …: SURVIVED (rc 124 …)" (:42), rc=2 (:46).
- J7 rejects rc 124 and J8 accepts rc 1 (`green-gate-head.log:17-18`).
- `green-unreadable-new-gate.log`: "SURVIVED sweep gone (caught, but its FAILED block does not say "nothing readable" …)" (:35), rc=1 (:47).

## Item 4: review tests 4 and 6
**Test 4, run:**
- A missing anchor gives "refused: never topo_pid -- an anchor occurs 0 time(s)" (`anchor-missing-head.log:32`), rc=2 (:35).
- A doubled anchor gives "… occurs 2 time(s)" (`anchor-doubled-head.log:32`), rc=2 (:35).

**Test 6, not run (needs CI):** it would take three things.
1. Push a throwaway branch that carries one red suite. For example, revert one suite's trap line; the new test then goes red inside the L1 lane, since `l1_unit_tests.sh:584` globs `tests/shell/test_*.sh`.
2. Let `ci.yml`'s build-and-test job run.
3. Read the step timing of "Python unit tests" against a green run of the same tree, then delete the branch.

The new test adds one suite run per signal up to its first fixture. Locally that took about 4 minutes in total; that is inferred from the start and end stamps in the two signal logs, not timed separately.

## Item 5: anchors
- At e7e548fa (since amended), check_gate_anchors gave NO-ANCHORS for this gate, rc 2 (`anchors-superseded-e7e548fa.log`). I bisected it with `extract()`. Inferred cause: an apostrophe inside `"$( … )"` in a printf argument. I replaced it with a plain variable.
- `anchors-head.log`: 128/128 ok, `mutate_fixture_spawn_helpers.sh ok(22)` (:54), rc 0. That is 15 old anchors plus 7 SUBSHELL anchors.
- `anchors-base-and-head.log` (HEAD's gates at d452d111 and HEAD): 256/256 ok.

## Counts before and after (all ran, rc 0)
- **Suites** at d452d111 vs HEAD, from the `suite-before-*`/`suite-after-*` logs: 111/57/33/157/61/174/32 checks in both. They are unchanged, because the guard and the register write add no checks.
- **Gate:** 14 mutations at d452d111 → 21 at HEAD, 0 survivors.
- **Other gates and checks at HEAD, all rc 0 in `driver.log`:**
  - mutate_redirection_order, g6_apps_liveness, te_launcher_stdin, ndt_ovs_claim, ndt_helper_apps_window, g9_cleanup_no_pkill_f, g9_faults_topo_pid, check_process_by_name.
  - l1_shell_scoring "53 killed, 0 survived".
  - probe_stubs with PY_PROXY "15 mutation(s), 0 survivor(s)".
  - test_l1_shell_scoring "Ran 151 checks, 0 failed".
  - test_redirection_order "Ran 48 checks, 0 failed".
  - check_process_by_name.py, check_test_tmpdirs.py "0 fixed temp paths".
- After the run, no process carried the test token and no `.spawn-gate-*` files were left.

## Inferred, not separately tested
- That writing the pid inside the substitution closes the race depends on bash running a pending trap only after the command substitution returns. I did not reproduce the race on old code; the green runs only show that nothing leaks.
- INT is sent to the process group, like a Ctrl-C. Bash's handling of an INT sent to the suite's pid alone, while it waits for a child that did not die of INT, was not exercised.

## Left alone
- window's `spawn_two_layer` and liveness's `spawn_app_fixture` are other spawners. They were not changed or examined for the same race.

## Process notes
- **Coordinator's "skip READY FOR GO" update:** the auto-mode classifier refused three commands right after it arrived, all marked [Auto-Mode Bypass]:
  1. appending that update to `notes.log` together with a grep of `test_l1_shell_scoring.sh`;
  2. the same grep alone;
  3. reading the endings of two suites.
- **What I did about it:** I did not retry or work around those reads. The note is not in `notes.log`, and I did not read `test_l1_shell_scoring.sh`'s rules. The new test's summary follows the sweep suite's existing form, and test_l1_shell_scoring then passed (151/0).
- **Phase gate:** on the coordinator's update I went straight into phase 2 without a separate GO.
