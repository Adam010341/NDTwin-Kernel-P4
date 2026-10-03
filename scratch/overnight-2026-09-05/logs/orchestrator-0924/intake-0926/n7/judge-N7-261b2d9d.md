# JUDGE: N7 round.env 261b2d9d

**Verdict: MERGE AFTER FIXES.**
- **The core defect is fixed.** A live round can no longer run from a tree the lab isn't running: `lab_tree_check` refuses first in both preflights, before any lab action or cross-tree write.
- **The evidence holds.** Every number in the summary's gate table matches its log. The red-first runs really happened in a tree without the venv.
- **Two things before merge:**
  - **F-1 (should-fix, or the orchestrator explicitly accepts it):** refusals at the entry points still write into the refused tree, and F-5 prints a false "do not release the lab".
  - **F-2 (must be explained in SUMMARY):** the PF and G2 timestamps can't both be true if the guard lock serialized them.
- Everything else below is a note.

**How I checked.** Read-only (Read/Grep/Glob). Nothing executed, no git. I did not read the previous judge report or any audit/handoff documents. A repo-wide grep surfaced a few lines from doc/audit files; I did not use them as evidence.

Path shorthands:
- W = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-round-env-0927` (the head). Its `mutate_live_round_lab_tree.sh:156` has the corrected M7 label.
- NV = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-round-env-novenv-0928`. It still has the old `"  E: …"` label at :156, so it is b114d8fb. `NV/p4_proxy/venv/pyvenv.cfg` does not exist; `W/p4_proxy/venv/pyvenv.cfg` does.
- L = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/n7-logs`
- E = `W/doc/audit/2026-08-31_sampling-ceiling-after-merge`
- F = `W/doc/audit/2026-08-31_f5-fine-grid-round`

## 1. Ruling items

| Item | Status | Where |
|---|---|---|
| B1 | **FIXED** in both preflights. **PARTLY** at the entry points (see F-1) | E/lib_e.sh:258 and :1348-1369; F/run_f5.sh:383 and :811-832. Round.env headers E:19-22 and F:20-23. SUMMARY §4.1 covers (a)–(d) plus the counterweight. The third round.env is listed and unchanged |
| B2 | FIXED | E/round.env:77, F/round.env:68, W/tests/shell/test_cell_gate_suspect_wiring.sh:79-88. Red-first: L/RF.3.out (SKIP, rc 0) → L/PF.3.out (FAILED, rc 1). Mutant M21 |
| B3 | FIXED | E/round.env:23-27 and F/round.env:24-28; suite :158-186. Red before the fix: RF.1.out:36-63 (dash gave `Bad substitution`, then `KERNEL_DIR=/` with rc 0; `bash -c` also gave `/`). Green after: PF.1, PF.7, PF.8. Mutants M13/M14/M15/M17 |
| N1 | FIXED | test_gate_exit_code_not_tee.sh:49 and :86; test_cell_gate_suspect_wiring.sh:26 and :71. Red: RF.4:8-9 and RF.5:10-11 show mkdirs into the main checkout. Green: PF.5 and PF.6 show "none". Mutants M19/M20 |
| N2 | FIXED | E:25 and F:26. Red: RF.1:12-14 (KERNEL_DIR came out as tree-b twice, on two lines). Green: PF.1:12. Mutant M18 |
| N3 | FIXED, documentation only (as ruled) | E:14-18, F:15-19. Nothing tests the convention: control C2 (`cd -P`) stays green |
| N4 | FIXED on the suite side | suite :83-114 (`env -i`, `compgen -e` before/after diff, 10 write shims). See N-7 |
| N5 | FIXED | M9–M12 (F-5 versions of M2/M4/M5/M6), M16, C2, C3 |
| N6 | FIXED as an inventory; the prose classification is incomplete | L/literal-inventory.txt has exactly 117 files (91 under doc/audit, 26 live). See N-8 |
| N7 | FIXED | L/.steps.frozen.sh:13-21 and L/.cell2.frozen.sh:14-17. G2's rc 1 is reported honestly |
| SUMMARY fixes | FIXED where I could check | §7.1: B2-observe-prefix.log:12,40 are empty. §7.2: .cell.run.sh has no floor STOP; B log shows 2323 MB with WARN. §7.5: 18 execve. §7.6: git-show-stat files exist |

## 2. `lab_tree_check` (Q2)

**The two copies are identical.** Logic, line by line:
- **Dry-run exemption.** `[[ "${DRY_RUN:-0}" == 1 ]] && return 0` (lib_e.sh:1349, run_f5.sh:812). Only the exact string `1` is exempt, the same test every other `== 1` in these files uses.
- **Asking the lab.** `if ! cfg="$($lab_cmd config 2>&1)"` returns rc 2 with "could not ask".
- **Parsing.** `sed -n 's/^KERNEL_DIR:[[:space:]]*//p' | head -1` matches the installed helper's `printf 'KERNEL_DIR: %s\n'` (/usr/local/sbin/ndtwin-lab:1814). If /etc/ndtwin-lab.conf is refused, the warning lines go to stderr and are indented (:282-289), so they can never match.
- **Symlinks.** Both sides are resolved with `cd -P … && pwd -P`. A match needs both values non-empty and equal.
- **rc 2 on every failure path:** sudo or config fails; no KERNEL_DIR line; the lab's directory is missing; KERNEL_DIR unset or missing; the trees differ. preflight maps any non-zero to 2.

**Placement.**
- E: first statement of preflight (:258), before the `say` at :259.
- F-5: after a pure `local` (:383), before `df` and `say` (:384-385).
- So both run before any preflight write.

**Is `LAB` always the real helper?** round.env exports it unconditionally (E:51, F:40). But run_e.sh:37, gates_e.sh:37, build_1khz_binary.sh:43 and run_f5.sh:25 skip round.env when ROUND is already set. Then LAB and KERNEL_DIR come from the caller's environment, and an unset LAB falls back to the default. An override can only pass the check by printing a matching `KERNEL_DIR:` line, so this fails closed.

**Entry points:**
- **run_e.sh `ladder` (:225) and `bltrue` (:273):** preflight comes first and there is no trap, so they are clean (apart from round.env's mkdir, which §4.2 discloses). The per-cell `preflight cell` at :105 re-asks every cell, which catches a lab re-pointed mid-run.
- **run_e.sh `plan` (:303):** runs `preflight plan >/dev/null || true`. A live plan from a worktree now makes a sudo call, prints the REFUSE block on stderr, and then prints the plan anyway (N-4).
- **gates_e.sh `main` (:313-314) and `baseline` (:277-278):** each does a `say` before calling preflight. That appends to `$ROUND/gates_e.log`, which is a tracked file. `main` adds a second `say` after the refusal. The EXIT trap at :258 is inert here.
- **run_f5.sh `arm`, `q3`, `restore` (:851-853):** the EXIT trap is armed before preflight. After a tree refusal, `f5_exit_restore_check` (:363-379) runs `assert_kernel_restored` for real (:193-218: `ps`, `sudo -n readlink`, `sudo -n nm`). It then either:
  - writes `$ROUND/run_f5.log` (a new untracked file), `raw/RESTORE-FAILED` and `raw/LAB-NOT-RESTORED` into the refused tree, and prints "THE PRODUCTION KERNEL IS NOT RESTORED … do not release the lab"; or
  - `rm -f`s those files.
- **run_f5.sh `q3`:** also writes and can abort before preflight (:629-634).
- **build_1khz_binary.sh:** no preflight, but no lab action either (no abort/teardown; it builds and runs `git checkout --` in its own tree at :182). This matches §4.1.
- **Result:** no path reaches `$LAB topo-*` or teardown without the tree check.

## 3. round.env guards (Q3)

- **bash:** correct.
- **dash `. file`:** guard 1 fires and `return 1` is valid inside a dot script. PF.7 shows `rc=1 [UNSET]` and no MKDIR.
- **`bash -c "$(cat round.env)"`:** guard 2 fires; `return` is invalid there, so it `exit 1`s (PF.8).
- **Relative sourcing, `./round.env`, another checkout's cwd, CDPATH:** suite :143-148, green in PF.1:10-12.
- **A loose copy outside any checkout:** derives `/`, and guard 3 refuses (PF.1:18-21).
- **Exiting a user's shell:** normal `. round.env` never exits. However, if the file's text is `eval`'d or pasted into an interactive bash, BASH_SOURCE is empty, `return` fails, and `exit 1` closes the user's terminal (N-3).
- **`-d "$_kd/doc/audit"`:** always true when `_kd` is derived, because the file sits at `<_kd>/doc/audit/<round>/`. For an exported KERNEL_DIR, every checkout of this repo has doc/audit (the main PR still carries the non-.md files there). A relative export such as `KERNEL_DIR=.` is accepted as-is (N-9).

## 4. Interaction with fix/ci-l1-0927 (Q4)

- **`l1_probe_py_plot`** (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ci-l1-0927/tools/test_workflow/l1_unit_tests.sh:254-259`):
  - It sources the real E round.env in bash, by its path, with KERNEL_DIR already set by components.env:16 (a shell variable the subshell inherits).
  - All three guards pass and `_kd` is that tree. PY_PLOT (E:76) doesn't depend on the tree, so **the answer does not change**.
  - Both output streams go to /dev/null, so **there is no noise**. The `mkdir(){ :; }` function still shadows round.env's mkdir at :87.
- **D15–D17** (test_l1_shell_scoring.sh:287-297) write their own synthetic round.env without the guards, so they are **unaffected**.
- **Both branches edit test_gate_exit_code_not_tee.sh.**
  - N7 changes trunk lines :39-49 and adds a line after :81; ci-l1 inserts :101-105 just before the PY_PLOT SKIP. The hunks are about 20 lines apart, so I expect a clean textual merge. Run both suites after merging.
  - The new tree check prints `ok` before the SKIP line, so `l1_skip_excuse` (:238) still excuses the declared py-plot skip on hosted runners.
- **One positive effect:** with ci-l1's CI venv (ci.yml:122-126), PY_PROXY now resolves to the CI checkout. Before this branch it pointed at /home/adam/…, so the cell-gate suite would have SKIPped, which that lane counts as FAIL-SKIP.

## 5. The summary's claims, classified (Q5, Q7)

**SUPPORTED:**
- **RF** (L/RF-prefix-novenv.log:1,4-16):
  - NV at 7b4a48b9 with 2 dirty files.
  - Round.env suite: 60 checks, 36 failed (RF.1:152).
  - Lab-tree suite: 30 checks, 28 failed (RF.2:108). The 2 greens are the two "does not call sudo" checks.
  - Cell-gate suite: SKIP with rc 0.
  - inherited.sh: red (stray mkdirs in main).
- **PF:** NV at b114d8fb, clean; 8 of 8 steps OK.
- **G1:** W at b114d8fb; 11 of 11 steps. Suites: 30, 60, 10, 14, 30, 12, 11, 12 checks. Anchors 124/124 (G1.9:67 ok(10), :113 ok(21), :131). Process-name lint: 342 files, 0 sites. Temp-dir lint: 392 files, 0.
- **G2:** the lab-tree gate is 8 mutations with 1 survivor. G2.1:10-11 shows the label mismatch as described.
- **G2, the other gates:** round.env 21/0 with 3 controls; cell-gate 0 survivors, 0 harness errors; not_tee 6/0; log_suffix 7/0; iperf3 6/0; e_restore 7/0; ep4 6/0. The worktree was clean afterwards (G2.9 is empty).
- **G3:** W at 261b2d9d; 8/0 with 2 controls. M7 is now caught on 2 checks (G3.1:10).
- **Regressions:** the six existing offline suites were rerun green (G1 steps 3–8) and their gates show 0 survivors (G2 steps 3–8). None of them calls preflight, so none can trigger a real sudo.
- **§4.1 citations:** each points at the stated code (lib_e.sh:365, :836-851, :887, :1324-1326; run_f5.sh:366, :376; build_1khz_binary.sh:182).
- **Line numbers:** lib_e.sh's existing line numbers are unchanged (e202e463 has 2 deletions in total). The checklist citation `round.env:37` does point at `PRIOR`.
- **§6 counts:** 117, 91 and 26 are exact.

**UNDER-EVIDENCED:**
- **§4.1 "config reports the main checkout".** Nothing in L captures that manual run. It is corroborated by: no `/etc/ndtwin-lab.conf` exists, and the helper defaults to /home/adam/Desktop/NDTwin-Kernel (ndtwin-lab:98, :110). Whether `config` is NOPASSWD can't be checked (/etc/sudoers.d/ndtwin-lab is EACCES to me).
- **Symlink resolution on the lab side.** It is claimed but never exercised (N-1).
- **§6 "the other live files mostly use it as data".** Not established (N-8).
- **§3 "one guard call per cell" as serialization.** See F-2.
- **§3 "261b2d9d was committed while G2 was at steps 4–5".** No timestamps back it (F-2).

**CONTRADICTED** (by code, in the broad reading): "refused before anything is written", read as "a refused live run leaves nothing behind" (F-1). It holds only for `preflight()`.

**UNTESTED:**
- Refusal at the real entry points (`gates_e.sh`, `run_f5.sh arm`).
- §4.1's statement that live E/F-5 from any worktree gets rc 2 at preflight's first step. True by code for ladder/gates/arm/restore, but never run as an entry point.
- Commit-message bodies. The stat files show only subject lines.

## 6. Mutation gates (Q6)

**Lab-tree gate:**
- **Realistic mutants present:** M1/M2 remove the call; M3/M8 leave `mine` unresolved; M7 inverts the comparison.
- **M5 is not a fail-open.** With `if false`, the function still refuses (via `lab=""`). It is caught only because the message check differs.
- **The realistic fail-open is missing.** A mutant putting `return 0` in the config-failure branch isn't in the gate. The suite would catch it (:115-116), but that isn't demonstrated.
- **`theirs="$lab"` (lab side unresolved) would SURVIVE.** No case feeds a symlinked lab path: case 1 differs anyway, case 2 passes `$MINE` literally, and case 4c differs anyway.
- **"Check placed after a write"** isn't a mutant, but the suite's check at :96-97 would catch it.
- **Controls:** C1 (order of locals) and C2 (comment wording) are cosmetic.

**Round.env gate:**
- Good coverage: the defect itself, near misses, every guard, the consumer suites, and M21.
- C2 (`cd -P`) is a meaningful behaviour-preserving control. It also shows nothing pins the N3 symlink convention.
- `ok(21)` in the anchor check counts unique (file, anchor) pairs, not mutants (M1/M4, M7/M10 and M18/C2 share anchors). That is consistent.

## 7. Discipline (Q8)

- Co-developed tags are present in all 6 test files and in the new code blocks.
- No `pkill`/`pgrep`.
- `mktemp` is used throughout, with one exception: mutate_round_env_kernel_dir.sh:250-285 writes fixed-name `.mutant-{m19,m20,m21,c3}-*.sh` into the checkout's tests/shell. Its exit trap at :41 deletes them with a glob, so two concurrent runs would collide (N-10).
- git-show-stat: 7b4a48b9 touches 5 files, e202e463 4, b114d8fb 7, 261b2d9d 1. All are within the listed set.

## 8. Findings

**F-1 (should-fix; merge-gating unless the orchestrator explicitly accepts it and §4.2 discloses it).** The refusal is clean inside `preflight()`, but the real live entry points still write in the refused tree:
- `gates_e.sh:313` and `:277` append to the tracked `gates_e.log` before calling preflight.
- `run_f5.sh:851-853` arms its EXIT trap before preflight. After the refusal, the trap runs the restore check against the refused tree (run_f5.sh:363-379, :193-218). It creates `run_f5.log`, `raw/RESTORE-FAILED` and `raw/LAB-NOT-RESTORED` there (or deletes them), and prints "THE PRODUCTION KERNEL IS NOT RESTORED … do not release the lab". Its advice ("Clear it with ./run_f5.sh restore") can't be followed from that tree, because `restore` is refused too.

This is the per-tree marker problem from B1(c), in reverse. The lab-tree suite extracts `preflight` with sed (test_live_round_lab_tree.sh:70-82), so it structurally can't see any of this.

Fix:
- F-5: in the dispatch, run `lab_tree_check || exit 2` before arming the trap, or have `f5_exit_restore_check` skip when the tree check refused. The trap's behaviour for other refusals (claim, disk) is intended and can stay.
- E: move gates_e.sh's first `say` below preflight.
- Test: add an entry-level case. Copy both round directories into a checkout-shaped temp tree, stub `sudo`, run the real scripts with DRY_RUN=0, and assert rc 2 plus no created or changed files.

**F-2 (evidence; SUMMARY must explain).**
- PF's cell was queued at 04:59:53 and ended 06:51:33 (PF-postfix-novenv.log:1,22). G2 was queued at 05:05:33 and ended 06:52:30 (G2-postfix-gates.log:1,24).
- Both took the exclusive flock on `/tmp/ndtwin-build.lock`: neither log has an "already held above us" line, and guarded_build.sh:127-131 holds the lock until the process exits.
- If the lock serialized them, G2's nine steps (roughly 80+ suite runs) must fit into 06:51:33–06:52:30, i.e. 57 seconds.
- But §3 says 261b2d9d was committed while G2 was at steps 4–5, and G3 needed 18 minutes (06:52:59–07:11:10) for a subset of G2's work.
- The summary's own phrase ("PF queued behind the guard lock 04:59:53–06:51:33") doesn't resolve this. Either G2 ran in under a minute, or PF and G2 overlapped, meaning the lock didn't serialize them.
- The pass/fail numbers are not affected: separate worktrees, mktemp directories, and G2's in-place mutations stayed inside W.
- What is affected is the "one guard at a time" memory-safety claim. Please explain, or add per-step timestamps.

**Notes:**
- **N-1.** Add a case with `STUB_LAB_TREE="$T/link-to-mine"` and `KERNEL_DIR="$MINE"`, plus a `theirs="$lab"` mutant to the gate.
- **N-2.** Add the fail-open mutant (`return 0` when `config` fails), and at least one semantic control for the lab-tree gate (for example `readlink -f` in place of `cd -P && pwd -P`).
- **N-3.** Guard 2's `exit 1` also fires in an interactive bash when the text is eval'd or pasted. Consider `[[ $- == *i* ]] || exit 1`.
- **N-4.** Add to §4.2: a live `run_e.sh plan` now calls sudo, and prints the REFUSE block when run from a worktree.
- **N-5.** Save the one manual `sudo -n … config` output into L. If `config` were not NOPASSWD, every live run would fail closed at "could not ask".
- **N-6.** The suite assumes `sh` is not bash (test_round_env_kernel_dir.sh:170-177). It goes red on systems where /bin/sh is bash.
- **N-7.** `env -i` makes the suite blind to inheritance. Two tree-derived overridable values still cross trees from a shell that once sourced another tree's round.env: `CPU_BASELINE_FILE` (E:105) and, since B2, `PY_PROXY` (E:77, F:68). Live runs are mostly covered by `lab_tree_check` plus the ROUND skip. If the earlier judge's N4 "remove inherited CPU_BASELINE_FILE" meant round.env itself rather than the suite, that part is not done.
- **N-8.** `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-round-env-0927/tools/test_workflow/greenlet_dump_smoke.py:7,20` uses the literal as a real path (`sys.path` and `open(…/intelligent_router.py)`). It appears in neither §6 list. `test_orphans_verdict.sh` (4 hits) and `test_ndt_lab_session.sh` aren't classified either.
- **N-9.** An exported relative KERNEL_DIR is accepted and produces relative exports. Separately, if ROUND is exported but KERNEL_DIR is not, `run_f5.sh:383` dies under `set -u` with rc 1 before the tree check, whereas E returns 2.
- **N-10.** The fixed-name `.mutant-*` files in tests/shell (see §7).
- **N-11.** No `DRY_FAIL` force exists for the tree refusal, so the rounds' own force matrices never exercise it. That is acceptable (an F-5 row would force a PREREG transcript change), but say so.
- **N-12.** G2's header says b114d8fb, but steps 5–9 ran after HEAD moved to 261b2d9d. This is disclosed, it doesn't affect those steps, and G3 reran the anchors at 261b2d9d.
- **N-13.** RF steps 4–5 were bound to go red before the fix, because the old consumer suites have no tree-check line. The discriminating evidence is the stray-mkdir lists (RF.4:8-9, RF.5:10-11), and the summary does cite those.

## 9. Internal inconsistencies

- F-2: PF and G2 end times versus an exclusive lock, versus the claim that 261b2d9d was committed mid-G2.
- The G1 row's "(the two new tests/shell/*.sh)" isn't visible in G1.10.out, which shows totals only.
- `ok(21)` looks like "21 mutations" but counts unique anchors. It is correct, just easy to misread.

## 10. Tests I would have run

1. The entry-level refusal test described in F-1, asserting no created or changed files.
2. The lab-side symlink case (N-1).
3. The fail-open mutant (N-2).
4. `lab_tree_check` fed the real `config` output shape, including the refused-conf stderr preamble.
5. `eval "$(cat round.env)"` in an interactive bash, to document N-3.
6. The suite with `sh` pointing at bash.
7. Sourcing with CPU_BASELINE_FILE and PY_PROXY inherited from another tree (no `env -i`).
8. After merging with ci-l1: test_l1_shell_scoring.sh, the not_tee suite, and the l1 lane.
9. Saving the one-shot `config` capture.
10. Timestamps per step in steps.sh.
11. run_f5.sh with ROUND exported and KERNEL_DIR unset.