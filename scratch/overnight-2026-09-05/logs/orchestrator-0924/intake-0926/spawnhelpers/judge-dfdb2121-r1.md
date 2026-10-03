# opus-judge round 1 on dfdb2121 (2026-10-01, prompt = 09-28 verbatim)

**Verdict: MERGE AFTER FIXES.** The fix itself is correct and well evidenced. The new gate, though, protects only the first call site in each suite, not all 35. Fix 1 below is the one that must be done before merge; fix 2 is a one-line correction for drift this commit caused.

How I worked: read-only, nothing executed, no git history, no intake or audit documents. I read the diff, the commit message, the six suites and the new gate at the worktree HEAD, the files they source (ndt, ndtwin-lab, faults.sh, lib_probe_stub.sh), l1_unit_tests.sh, ci.yml, check_process_by_name.py, and the evidence logs. Labels: SUPPORTED = the evidence establishes it. UNSUPPORTED = it may be right, but nothing ran it. WRONG = the code or the logs contradict it.

All suite paths are under `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-helpers-0928/tests/shell/`. All log paths are under `.../logs/gates-0910/spawn-helpers-0928/`.

## Per claim

**1. Every call site is a plain call — SUPPORTED.** There are 35 call sites, all of the form `helper ARGS; X="$FIXTURE_PID"`. None is inside `$( )`, backticks, `<( )` or a pipe, and no other function calls a spawn helper.
- orphans: 199, 200, 201, 324, 347, 416, 530
- liveness: 230, 231, 326, 345, 356, 375
- sweep: 173, 177, 259, 269
- window: 331, 368, 441, 700, 746, 789, 856 (856 is inside the conditional 12C block)
- topo_pid: 114, 119, 126
- ovs_claim: 523, 532, 542, 588, 596, 679, 701, 850

The run logs confirm it. The six `fix-dfdb2121-suite-*.log` files print exactly 7/6/4/7/3/8 = 35 lines of `ok       fixture took argv0=`. A helper running inside `$( )` would have its ok line captured into the variable instead of printed, so all 35 ran in the parent shell.

**2. Counted premise, the suite's own summary, registered before the poll, reaped by the EXIT trap — SUPPORTED.**
- **Registration before the poll:** orphans:168, liveness:134, sweep:121, window:145, topo_pid:80, ovs_claim:279.
- **Counted on success:** orphans:174, liveness:140, sweep:127, window:151, topo_pid:85, ovs_claim:285. This check can never fail, because it is reached only after the same comparison has already matched. It records the premise; it is not a test.
- **Counted on failure:** orphans:181, liveness:147, sweep:134, window:158, topo_pid:91, ovs_claim:292.
- **Summary format matches each suite's final line:**
  - orphans 184 vs 583
  - liveness 150 vs 511
  - sweep 137 vs 297
  - window 161 vs 901
  - ovs_claim 295 vs 877
  - topo_pid 94 vs 465, including the `(N skipped)` suffix
- **The parsers accept it:** `tools/test_workflow/l1_unit_tests.sh:98-103` reads this form, and the last summary in a log wins (:115). `fix-dfdb2121-l1-scoring.log:118-154` shows the summary check ok for all six suites.
- **EXIT traps:** orphans:128, liveness:106, sweep:91, window:117, topo_pid:60, ovs_claim:76. Each kills registered pids whose comm is `sleep`. A command-substitution subshell does not inherit the EXIT trap, so the inner `$( … & echo $! )` cannot reap anything early.
- **Evidence of actual reaping:** only the gate's fifth criterion. That branch never fires in any log or in any of J1–J5 (see claim 7).

**3. Poll bound and errexit safety — SUPPORTED, but the "pid already gone" path is UNTESTED.**
- **Bound:** every helper sets `deadline=$((SECONDS+FIXTURE_ARGV_WAIT))` and stops with `(( SECONDS < deadline )) || break` (e.g. sweep:122 and :131). The failing mutants took 30–33 s each.
- **errexit is really on in sweep:** `errexit-after-sourcing-ndtwin-lab.log:3-5` shows `$-` going from huBc to ehuBc, and rc 1 at `X="$(false)"`. ndtwin-lab:22 is `set -euo pipefail`; ndt:51 and faults.sh:83 set only `-uo`.
- **Sweep's helper is errexit-safe:** every line is. The sweep mutant reached `Ran 11 checks, 1 failed` (`fix-dfdb2121-gate.log:23`).
- **Untested:** the gate's mutation keeps the fixture alive, so mapfile never fails. No run has a fixture that is already gone while polled, so nothing shows that `|| true` (sweep:125) is reached or needed. Without it, sweep would die at that line with no summary.
- **Also changed:** the redirection order was swapped to `2>/dev/null <` in five suites. That is necessary, since a 30-s poll on a dead pid would otherwise print about 300 "No such file" lines.

**4. Spawn form, pid identity, process groups, cleanup — SUPPORTED.**
- **Pid identity:** every variant execs inside the backgrounded subshell, so `$!` is the process whose argv0 is polled. ovs_claim:273 execs `setsid bash -c 'exec -a …'`. setsid(1) forks only when its caller leads a process group, and with no job control the subshell does not, so the pid carries through.
- **Parentage and process group are the same as on trunk.** On trunk the fixture was also forked inside a command substitution (the caller's `$(…)`) and reparented when that exited.
- **Evidence:**
  - sweep's "even though it shares our group" is ok (suite-sweep.log:28);
  - the ovs_claim setsid cells are ok (suite-ovs_claim.log:107-109, 129-130, 152-159), including "recycled into a group leader", which needs pid == process group id.
- **Cleanup:** the traps kill by pid.
- **Stale comment:** sweep:187-188 still calls the fixture "a child of this shell". It is not, and was not on trunk either; the new comment at :116-117 has it right.

**5. FIXTURE_PID does not collide — SUPPORTED.** liveness uses `SPAWNED` (446, 460, 471, 476). `FIXTURE_PID` and `FIXTURE_ARGV_WAIT` appear only in these six files anywhere in the worktree. None of the sourced files defines them, or functions named `spawn`, `spawn_fixture`, `check` or `sleep`.

**6. Check counts grew by exactly the number of call sites — SUPPORTED.** The unmutated runs went from 104/51/29/150/58/166 (`redfirst2-gate-trunk-3368412d.log:14-34`) to 111/57/33/157/61/174 (`fix-dfdb2121-gate.log:14-34`). That is +7/+6/+4/+7/+3/+8, the call-site counts. The diff touches only helper bodies, call sites and comments. Window's +7 depends on 12C running; where it doesn't, it is +6.

**7. The new gate (`tests/shell/mutate_fixture_spawn_helpers.sh`) — partly SUPPORTED, two parts WRONG, one part UNSUPPORTED.**
- **SUPPORTED:**
  - the unmutated control runs first (:129, then :137);
  - the mutation can never match (:148-153);
  - the judge implements the five conditions (:73-83);
  - J1–J5 pass;
  - the identical gate file (sha256 9d4d3973…) shows 6 survivors on trunk and 6 caught on dfdb2121;
  - each trunk survivor is the defect itself: uncounted FAILED lines are 59−52, 23−17, 28−21, 5−2 and 26−18, exactly the call-site counts, and sweep prints no summary;
  - `redfirst2-sweep-errexit-demo-trunk.log:6-9` isolates errexit as sweep's cause.
- **WRONG — "the gate would fail on a regression to `$(...)`":**
  - The mutation is inside the shared helper, so each mutant stops at its first call site. The mutants' summaries are `Ran 1/1/11/28/3/84`, the check count at that first site. The gate exercises 6 of the 35 sites.
  - A later site that reverts is never reached.
  - If the first site reverts, its failure is swallowed, the next plain call fails properly, and the judge still says "caught". The only exception is sweep:173, where errexit ends the run.
  - The unmutated control catches a revert only when the variable feeds a check that needs a real pid. Even then it shows up as "refused" (exit 2), not as a survivor.
  - At four sites a revert leaves both the suite and the gate green:
    - **topo_pid:119 (DECOY) and :126 (FIX2):** never read again.
    - **orphans:200 (DECOY):** read only by the negative checks at 205 and 218.
    - **ovs_claim:523 (LIVE_VIZ):** the variable would hold text, not a pid, and the pidfile check at :526 still passes because ndt treats a non-numeric pidfile as "unusable" and prints nothing for it (ndt:4890, 5726-5733).
  - At topo_pid:119, orphans:200 and ovs_claim:523, a real fixture failure after such a revert would pass for the wrong reason, which is exactly the defect being fixed.
- **WRONG as stated — "a mutation that fails to apply counts as SURVIVED":** an anchor found other than exactly once makes the gate print "refused" and exit 2 (:125-128). That fails closed, which is fine, but it is not SURVIVED, and no run exercised it. A mutation that applies but changes nothing does exit 0 and counts as SURVIVED (:73), which is correct.
- **UNSUPPORTED — the fifth condition ("the given-up pid is no longer running"):** none of J1–J5 has a live pid, so nothing shows this condition can ever fail.

**8. Existing gates still green — SUPPORTED.** Every log starts with dfdb2121, has nothing uncommitted, and ends rc=0:
- redirection-order 22/0
- g6 liveness
- te-stdin 9/0
- ovs-claim 39/0
- window 38/0
- both g9 gates
- by-name 16/0
- l1-scoring 53/53
- probe-stubs 15/0, only with PY_PROXY (`followup2-dfdb2121-g-probe-stubs-pyproxy.log`)

Without PY_PROXY, probe-stubs refused because test_cell_gate_suspect_wiring.sh has no proxy Python in the worktree (`followup-dfdb2121-cell-gate-suite.log:7`). That is unrelated to this change. These ten are every gate that references the six suites.

Gate anchors: 253/254, with the only failure the new gate absent at trunk (`fix-dfdb2121-anchors.log:50, 141`). Reading gates from HEAD gives 254/254 (`followup-dfdb2121-anchors-gates-from-head.log:140`).

**9. `tests/shell/check_process_by_name.py:24` — not fine (low severity).**
- On trunk, lines 114-117 of test_faults_topo_pid.sh were the comment that quotes exactly those two pipelines. Those lines are now :138-141, so the citation was correct until this commit.
- This commit's +24-line shift makes :114-117 point at the spawn call and the topo_pid checks.
- Since this commit caused the drift, it should re-anchor the citation.

**CI (ci.yml:48) — no threat.**
- A helper failure ends its suite, so a failing run waits 30 s once per suite, not once per call site. Worst case is about 6 × 30 s ≈ 3 min, and each suite skips its remaining checks.
- The failing mutants show 30–33 s each.
- CI runs only tests/shell/test_*.sh (l1_unit_tests.sh:584), with no per-suite timeout (:599), and the ~4-minute gate is not run.
- 21.5 + 3 ≈ 24.5 min, under 30. The 21.5-minute figure was not in the evidence I was given.

**Commit message — fit to go public.** Short, engineer style, no trailers, no judge, intake or ticket IDs; the subject is 72 characters. Two small inaccuracies, the second of which the gate header (:16-17) repeats:
- two of the six suites call `spawn`, not `spawn_fixture`;
- "the helper's text in place of a pid" was not true for window and topo_pid, where the variable was empty.

## Not covered by any claim
- **A seventh suite has the same shape:** `test_ndt_down_stops_only_ours.sh:120-121` and `:225` use `X="$(spawn …)" || {…; exit 1;}`. The `||` means the failure is counted. But the given-up fixture is never reaped (cleanup at :104-117 only knows OURS/THEIRS, which are empty after a failure), and the poll is still 2 s. By the new gate's own fifth condition it would be a survivor.
- **The gate writes its copies into tests/shell/** (:111-112). If the gate is SIGKILLed (oomd, for example), they stay behind in a shared tree.

## Tests I would have run
1. A revert to `$(…)` at each of the 35 sites, running the control and the mutant. I expect the four sites above to come out green.
2. A sixth judge self-test: synthetic output naming a live `sleep` pid, which must be SURVIVED.
3. A sweep mutant whose fixture exits at once: caught with `|| true` in place, SURVIVED with it removed.
4. An anchor that is missing or doubled, to confirm exit 2.
5. A repo-wide grep for `$(spawn`, backtick and pipe forms (this finds the seventh suite).
6. l1_unit_tests.sh with all six suites forced to fail, timed, to confirm the roughly +3 min.

## Internal consistency
The numbers agree throughout:
- the trunk uncounted-FAILED counts equal the call sites;
- the mutant check counts equal the checks before each suite's first site plus one (window's 28 needs the installed-helper check, which ran at suite-window.log:12);
- the ok-line counts equal the call sites.

The only inconsistencies are the wording points noted above.

## Fix list
1. **(Required before merge)** Make the gate cover every call site. Add a static check per suite: every non-comment call must match `^\s*(spawn_fixture|spawn) …; VAR="$FIXTURE_PID"$`, and `$(`, backticks, `<(` and `|` are refused. It fails on trunk by construction. As a second check, require the control's `ok fixture took argv0=` count to equal the number of call sites, allowing for window:856 being conditional.
2. **(Same commit, one line)** Re-anchor check_process_by_name.py:24 to test_faults_topo_pid.sh:140-141, preferably by naming the quoting comment rather than a line range.
3. Add a sixth judge self-test that uses a live pid, as a positive control for the fifth condition.
4. Add a mutation where the fixture's pid is already gone, at least for sweep, so `|| true` under errexit has evidence of failing without it.
5. Either fix test_ndt_down_stops_only_ours.sh (register and reap the given-up fixture, 30-s bound) or state in the gate header and commit body why it is out of scope.
6. Nits:
   - the sweep comment at :187-188;
   - the gate header :16-17 and commit wording (empty variable in window and topo_pid; two suites call `spawn`);
   - an optional ignore rule for `tests/shell/.spawn-gate-*`.
