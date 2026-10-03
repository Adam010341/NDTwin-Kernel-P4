# spawn-helper round 2 worker report (delivered 559c6b26, 2026-10-01)

DELIVERED 559c6b266781ad3ae8bca07169950999ff90efd4

**SUMMARY.md was not written.** The harness refused the Write call ("Subagents should return findings as text, not write report files"). I did not work around the refusal. The full SUMMARY content is below. If you want it on disk, the orchestrator can paste it into `/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/spawnhelpers-r2/SUMMARY.md`.

## 10-line summary

**OBSERVED**
1. There is one new commit, 559c6b26, on top of dfdb2121, which is unchanged. Nothing was merged or pushed. Every final log records a5e8de70 with porcelain 0. a5e8de70 is the same commit with an earlier wording of its message: I amended only the message, twice. The tree is 0481461a in both (`$E/r2-amend-message-only.txt`).
2. On trunk 3368412d the new static check fails on exactly 38 lines: the 35 sites plus the seventh suite's 3, all in `$(...)` (`r2-trunk-red-static.log`, rc=1).
3. Per-site revert sweep: the full gate catches 38 of 38, and the premise-count part alone also catches 38 of 38 (`r2-site-sweep.log`). At 6 sites the suite stays green and only the count catches the revert: orphans:200 and :347, topo_pid:119 and :126, ovs_claim:523 and :588.
4. The new gate passes, rc=0. J1–J6 are ok, all 7 controls are green with premise count equal to site count (7/6/4/7/3/8/3), and all 14 NEVER/GONE mutants are caught. Sweep's GONE mutant with `|| true` removed survives with no summary, as it must (`r2-gate.log`, ~8 min).
5. J6 goes red when condition 5 is removed (`r2-red-j6.log`, rc=2). The old down suite has 0 of 3 premises counted and its NEVER mutant survives with the fixture still running (`r2-red-down-old-shape.log`). The down suite went from 29 to 32 checks.
6. All other runs pass, rc=0: the seven suites, the ten gates you listed (probe-stubs with PY_PROXY), l1-scoring, redirection-order, tmpdirs and the by-name checker. check_gate_anchors gives the new gate ok(15) at HEAD, 379/381 overall. The 2 misses are this gate at 3368412d and dfdb2121, which don't have the round-2 anchors. The tripwire has 0 lines throughout.

**INFERRED**
7. The 6 sites in item 3 also left the round-1 gate green: that gate's mutant stops at the first call site, and ovs_claim:523 is a first site whose swallowed failure is followed by a counted one. The judge named 4 of these sites; the commit message says six.
8. Keeping mutant copies beside the suites, plus a cleanup on EXIT/INT/TERM and a `.gitignore` rule, is the only safe placement. A symlink mirror would give `ndt` (which resolves its own path with `readlink -f`, ndt:53-54) a different tree from the suite's.
9. Writing the down helper's summary and `exit 1` on one line keeps `mutate_l1_shell_scoring.sh`'s corpus role intact. I watched it go 52/53 with them on separate lines and 53/53 after.
10. Out of scope and untouched: `test_ndt_down_stops_only_ours.sh:151` still has `trap cleanup EXIT INT TERM` with a cleanup that returns, so INT/TERM do not end that suite (the shape 3368412d fixed elsewhere). The judge's tests 4 and 6 were not run.

---

## SUMMARY content

E = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-helpers-0928`

Worktree: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-helpers-0928`

Commit 559c6b26 changes `.gitignore` and four files in `tests/shell`: `mutate_fixture_spawn_helpers.sh`, `test_ndt_down_stops_only_ours.sh`, `test_ndtwin_lab_sweep.sh`, `check_process_by_name.py`. Totals: +368/-77, and 0 added lines matching a secret pattern.

**How things were run:**
- **Command:** every run used `PATH=$E/nolab:$PATH JOBS=1 LOCK_WAIT=10800 /home/adam/Desktop/NDTwin-Kernel/tools/build_guard/guarded_build.sh`, through the wrapper `$E/scripts/r2_run.sh`.
- **Log format:** each log has HEAD on line 1 and `porcelain-lines: N` on line 2, and ends with `rc=`.
- **Driver:** `$E/scripts/r2_driver.sh`, whose overview is `$E/r2-driver.log`.
- **Trees:** `git archive` copies in the scratchpad, made by `$E/scripts/r2_make_tree.sh` and recorded in `$E/r2-tree-head.txt` and `$E/r2-tree-trunk.txt`.

Line numbers below are at HEAD.

### Fix 1 (REQUIRED): cover every call site

**What changed in `tests/shell/mutate_fixture_spawn_helpers.sh`:**
- **Part 1, the static check.**
  - The reader is `STATIC_PY` (:114-176), called by `static_suite` (:256), with exit 1 at :281.
  - Every non-comment line that mentions the suite's helper (`spawn_fixture`, or `spawn` in topo_pid/ovs_claim/down) is a call site. It must be either the single definition, or `helper ARGS; VAR="$FIXTURE_PID"` with ARGS double-quoted with plain `$VAR` or bare words.
  - The check refuses `$(`, backticks, `<(`/`>(`, `|`/`||` and any other shape, and names the reason.
  - It also refuses an indented call outside the one declared conditional block.
- **Part 2, the control's premise count.**
  - In `gate_control` (:298), the unmutated copy must be green and print one `ok … fixture took argv0=` line per call site.
  - Call sites include non-plain ones, so this part can catch a revert on its own.
- **window:856 is handled explicitly.**
  - `suite_info` (:93) declares the 12C block by its exact `if` line and the suite's text `12C did NOT run`. Each must occur exactly once.
  - The site is removed from the count only when the control prints that text, and the gate says so. In every run here 12C ran, so 7 of 7 window sites counted.
- **Part 3, mutants**, at :360-397.

**Red evidence:**
- `$E/r2-trunk-red-static.log`, rc=1: trunk 3368412d with the HEAD gate (sha256 32c00a13…) gives 38 `FAILED static` lines, and all 7 suites report a non-plain call.
- `$E/r2-site-sweep.log`, rc=0 (the script is `$E/scripts/r2_site_sweep.sh`; outputs are in `$E/r2-site-sweep-out/`).
  - **Method:** in a HEAD archive, one site at a time is reverted to `VAR="$(helper ARGS)"`, then the suite is restored.
  - **Column A**, the unchanged gate: caught means rc≠0 and the static output names that file:line. Result: 38 of 38.
  - **Column B**, the gate with :281 and the mutants removed, run on that suite only: 38 of 38. At 32 sites the control goes red (rc 2). At 6 sites only the premise count catches it (rc 1).

| suite | line | caught | rc | premise count alone |
|---|---|---|---|---|
| orphans | 199 | yes | 1 | rc2 |
| orphans | 200 | yes | 1 | rc1 (6 vs 7) |
| orphans | 201 | yes | 1 | rc2 |
| orphans | 324 | yes | 1 | rc2 |
| orphans | 347 | yes | 1 | rc1 (6 vs 7) |
| orphans | 416 | yes | 1 | rc2 |
| orphans | 530 | yes | 1 | rc2 |
| liveness | 230 | yes | 1 | rc2 |
| liveness | 231 | yes | 1 | rc2 |
| liveness | 326 | yes | 1 | rc2 |
| liveness | 345 | yes | 1 | rc2 |
| liveness | 356 | yes | 1 | rc2 |
| liveness | 375 | yes | 1 | rc2 |
| sweep | 173 | yes | 1 | rc2 |
| sweep | 177 | yes | 1 | rc2 |
| sweep | 260 | yes | 1 | rc2 |
| sweep | 270 | yes | 1 | rc2 |
| window | 331 | yes | 1 | rc2 |
| window | 368 | yes | 1 | rc2 |
| window | 441 | yes | 1 | rc2 |
| window | 700 | yes | 1 | rc2 |
| window | 746 | yes | 1 | rc2 |
| window | 789 | yes | 1 | rc2 |
| window | 856 | yes | 1 | rc2 |
| topo_pid | 114 | yes | 1 | rc2 |
| topo_pid | 119 | yes | 1 | rc1 (2 vs 3) |
| topo_pid | 126 | yes | 1 | rc1 (2 vs 3) |
| ovs_claim | 523 | yes | 1 | rc1 (7 vs 8) |
| ovs_claim | 532 | yes | 1 | rc2 |
| ovs_claim | 542 | yes | 1 | rc2 |
| ovs_claim | 588 | yes | 1 | rc1 (7 vs 8) |
| ovs_claim | 596 | yes | 1 | rc2 |
| ovs_claim | 679 | yes | 1 | rc2 |
| ovs_claim | 701 | yes | 1 | rc2 |
| ovs_claim | 850 | yes | 1 | rc2 |
| down | 153 | yes | 1 | rc2 |
| down | 154 | yes | 1 | rc2 |
| down | 258 | yes | 1 | rc2 |

**Green evidence:** `$E/r2-gate.log`, rc=0.

### Fix 2: re-anchor check_process_by_name.py:24

`check_process_by_name.py:24-25` now names the comment instead of a line range. It says the two checks in test_faults_topo_pid.sh "used to be (its "B12 (2026-09-11)" comment, above the checks that replaced them, quotes them)". That comment is at topo_pid:138.

Green: `$E/r2-g-by-name.log` and `$E/r2-by-name-checker.log`, both rc=0. This is a docstring, so there is no red test for it.

### Fix 3: judge self-test J6

- **Test (gate :243-251):** J6 starts a real `sleep 120` that is the gate's own child, names its pid after the FAILED line, and requires `SURVIVED (… still running: pid N)`. It then kills the sleep and waits for it. The EXIT trap at :78 kills it as well.
- **Red:** `$E/r2-red-j6.log`, rc=2, made with `$E/scripts/r2_red_variants.sh <tree> j6red`, which removes condition 5 at :220. J1–J5 stay ok, then the gate prints `refused: control "J6…" answered "caught (…)", not "SURVIVED (… pid 2009623)"`.
- **Green:** the J6 line in `r2-gate.log`.

### Fix 4: fixture already gone when polled

- **Mutation:** a GONE mutant for all seven suites, replacing `exec … sleep` with `exit 0`.
- **Sweep positive control:** sweep also gets `gate_must_survive gone-without-true` (:374): GONE plus `|| true` removed from the mapfile line. It must be judged SURVIVED with no summary line, otherwise the gate stops with exit 2.
- **Evidence (`r2-gate.log`):**
  - With `|| true` in place, it is caught: `caught sweep gone (rc 1; Ran 11 checks, 1 failed; …)`.
  - With it removed: `ok sweep gone-without-true survives as it must: SURVIVED (rc 1, and no "Ran N checks" line at all)`. The last line it printed is `machine-wide scan (real ps, read-only)`, which means errexit killed it at the mapfile.
  - GONE is caught in all seven suites.

### Fix 5: test_ndt_down_stops_only_ours.sh

- **Helper (:83-131):**
  - It is called as a plain command.
  - It still starts the fixture from a command substitution, so the fixture is never this shell's child. `alive()` reads /proc, so a stopped child that had not been reaped would still look alive.
  - The pid goes into `SPAWNED` before the poll (:111), with `FIXTURE_ARGV_WAIT=30` (:99) and a counted premise.
  - On failure it prints the summary and `exit 1` on one line (:130). The comment at :127-129 explains why: mutate_l1_shell_scoring.sh uses this suite as its corpus. With them on separate lines, that gate went 52/53 (`$E/r2-superseded-f3057c09/r2-g-l1-scoring.log`); now it is 53/53.
- **Cleanup (:137):** it kills and reports every pid in `SPAWNED`.
- **Call sites:** :153, :154, :258.
- **Under the gate:** the static check covers it, and its NEVER and GONE mutants are at :394-396.
- **Check count:** 29 before (`$E/r2-before-suite-down.log`, at dfdb2121) and 32 after (`$E/r2-suite-down.log`).
- **Red:** `$E/r2-red-down-old-shape.log`, rc=1, the old suite under the gate with part 1's exit removed. The control prints "0 ok lines but 3 call sites should have run", and NEVER gives `SURVIVED (… still running: pid 2010944)`. The script then killed that fixture.

### Fix 6: nits

- **Sweep comment, :187-189:** the fixture was reparented, so it is not this shell's child, but it is still in this shell's process group.
- **Gate header, :8-19:**
  - `spawn` is named for topo_pid and ovs_claim.
  - X held the helper's "Ran N checks" line in four suites, and nothing in window and topo_pid, whose helpers sent only their FAILED line to stderr.
  - I checked the six old helpers on `git show 3368412d`: all of them send FAILED to stderr.
- **Corrected dfdb2121 message:** `$E/r2-commit-message-dfdb2121-corrected.txt`, not amended. The new commit's message is in `$E/r2-commit-message-new.txt`.
- **Mutant copies:**
  - **Where they go:** they stay beside the suites, which find `../../tools`, `../../doc` and their siblings through `BASH_SOURCE`.
  - **Cleanup:** they are removed on EXIT, INT and TERM (:78-80).
  - **Ignore rule:** `.gitignore:105` has `tests/shell/.spawn-gate-*`.
  - **Leftovers:** the worktree held 0 `.spawn-gate-*` files after every run. Stopping one driver mid-sweep by process group left nothing behind either.

### Gate anchors and superseded runs

- **Anchor reader (observed):** check_gate_anchors.py reads a heredoc inside `$( )` as shell code. The static reader's python therefore made the first committed gate (f3057c09) come out NO-ANCHORS, exit 2. I moved both python programs to top-level `IFS= read -r -d '' VAR <<'PY'` heredocs (:109-192), run with `python3 -c`. The gate now reads ok(15).
- **`$E/r2-superseded-534dfbb1/`:** in the first commit, part 2 counted only plain calls, so the old down suite read as 0 of 0. The down-old-shape run found it.
- **`$E/r2-superseded-f3057c09/`:** the anchor reader problem and the l1-scoring result described above.
- **`$E/r2-dev-*.log`:** runs on an uncommitted tree. They are not evidence for the final commit.

### Not done

- **Down suite signals (out of scope, untouched):** its INT/TERM trap still returns and lets the suite continue.
- **Judge test 4:** a missing or doubled anchor should give exit 2. Not run.
- **Judge test 6:** the CI timing of a forced-red L1 lane. Not run.
- **The SUMMARY.md file itself:** the harness refused the Write.

## Files
- Gate: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-helpers-0928/tests/shell/mutate_fixture_spawn_helpers.sh`
- Seventh suite: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-helpers-0928/tests/shell/test_ndt_down_stops_only_ours.sh`
- Evidence scripts: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-helpers-0928/scripts/` (`r2_run.sh`, `r2_driver.sh`, `r2_site_sweep.sh`, `r2_red_variants.sh`, `r2_make_tree.sh`)
- Corrected dfdb2121 message: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-helpers-0928/r2-commit-message-dfdb2121-corrected.txt`
