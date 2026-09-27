# JUDGE: fix/rulings-aeg-0927 @ ebe17f7c0b17a6e360a256b312b12bbb888dfa5b (Adam's rulings A, E, G, 09-27)

**Verdict: MERGE AFTER FIXES.** Two small fixes are needed (F1, F2), plus one verification that takes a single command (F3).

- All three rulings are in the production code and scripts.
- The red-first and mutation evidence is in the logs, and it says what the worker's report says.
- None of the four reused gate results could have been affected by the uncommitted edit.
- Nothing new in the diff is unfit for a public repo.
- No finding is a DO-NOT-MERGE blocker.

I could not write the file: my toolset is read-only and has no Write tool. Please save this text to `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/aeg/judge-AEG-ebe17f7c.md`.

## 0. Method and limits

- **Nothing was run.** I have no shell, and my instructions forbid git history. So I did **not** run `git diff 7746832e ebe17f7c` or `git diff --name-only 5dcf704b ebe17f7c`. Every judgement below is "read, not run". The gate numbers I quote are the worker's runs, read from the logs.
- **Which code I read.** I read the worker's worktree. I identified its commit by reading two ref files only:
  - `/home/adam/Desktop/NDTwin-Kernel/.git/worktrees/wt-rulings-aeg-0927/HEAD` points to `refs/heads/fix/rulings-aeg-0927`.
  - `/home/adam/Desktop/NDTwin-Kernel/.git/refs/heads/fix/rulings-aeg-0927` holds `ebe17f7c…`.
- **Uncommitted edits in that worktree:** I cannot see them. The aeg4 driver refused to start any gate if tracked files had changed (`gates_aeg4.sh:21-22` and `:40`). Its last gate started at 15:14:37Z.
- **Telling new lines from old ones.** I compared against the main checkout, which is on trunk. It still has `: "${NDT_OWNER:=live-p1}"` at `.../live-p1/_common.sh:35` and `06_thirteen.sh:40`, so it does not contain this branch. I did not check that checkout's own uncommitted state.
- **Not read:** audit, handoff and investigation documents. I only grepped README.md and TICKET-P4-heartbeat.md for the wording the report says it changed.

**Path roots used below (all absolute):**
- `WT` = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-rulings-aeg-0927`
- `LIVE` = `WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1`
- `LOGS` = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910`
- `SUMMARY` = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/RULINGS-AEG-SUMMARY.md`
- `SP` = `/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/aeg`

## 1. Are the rulings in production code, and contradicted nowhere?

### A: detection "at most about 20 s"; a cycle over 20 s is disclosed, not failed

**Implemented:**
- `LIVE/08_heartbeat.sh:440-452`: `v_strict` returns `OVER …`. A row it cannot read is still BAD (`:444-445`).
- `:1099-1105`: `cut_cycle` writes a note for an OVER cycle and appends that cycle's own line, verbatim, to `STRICT_OVER_LIST`. Only non-OVER results go to `judge`.
- `:1126-1136`: `strict_conclude` no longer sets `VERDICT_RC`; it hands the count and the lines to `disclose` (`LIVE/_common.sh:83`).
- `_common.sh:297-305`: `finish` prints each disclosure as `NOTE <step> -- …` directly above the PASS or FAIL line.
- H3 is concluded the same way (`:2161`). The `strict_20s` column is still written (`:2094`, `:2118`).
- The pre-ruling behaviour is confirmed on trunk's 08: `strict_conclude` set `VERDICT_RC=1` (trunk `08:1108-1121`), and trunk has no `strict_conclude H3`.

**Paths where an over-20 s cycle is still dropped from the last lines, or still fails:**
- **a. New, this is F1: early exits in the H1 loop skip `strict_conclude H1`.**
  - The exits are `:2099-2100` (`cut_cycle … || exit 1`), `:2114-2115` (`restore_cycle … || { fail …; exit 1; }`), and INT/TERM.
  - `w_finish` (`:667-683`) does not flush the pending tally, and `finish` prints only what is already in `DISCLOSED`.
  - Result: over-cycles measured before the exit never reach the NOTE lines. Only their inline note (`:1101`) stays in the body.
  - The run is FAIL for another reason on these paths, so the ruling's letter still holds.
  - But two claims say more than the code does: `LIVE/README.md:295` says every over-cycle appears right above the last line, and the self-test label at `08:1867` says "an OVER cycle anywhere reaches the last lines".
- **b. Pre-existing (trunk `08:1098`): the no-phase-record fallback.** At `:1111-1114`, elapsed time is judged against the strict 20 s through `v_elapsed` (`:362-369`), which calls `fail`. This is only reached after the phase record has already failed at `:1091`, so no verdict changes. That over-cycle is neither counted nor disclosed.
- **c. Pre-existing (trunk `08:1076`): a 35 s ceiling.** `graph_until`'s limit is `DETECT_BOUND_S + 15` (`:1084`, loop exit at `:843`). A detection slower than 35 s is a FAIL. In practice "about 20 s" means "≤ 35 s"; README and SUMMARY do not say so.
- **d. Restore is still a strict 20 s FAIL** (`:1151`, `:1168`). Ruling A only names detection, so this matches its letter. Adam should confirm.
- **e. Two stale sentences contradict ruling A:**
  - `:2089` prints "Each cycle is judged on the STRICT 20 s" in the live output.
  - The comment at `:2120` says "the strict bound decides H1, and its count leads the run's last line".

### E: `link_watchdog` comes out of `control_plane.skipped`

**Implemented:**
- `WT/p4_proxy/proxy_agent/main.py:2224-2229` removes `SKIP_WATCHDOG` only when `_start_heartbeat_watchdog` reports that it started.
- The proxy reports `heartbeat.watchdog` as `running` or `not_started` (`:1352`), served at the top level of switch_state (`WT/p4_proxy/proxy_agent/api_routes.py:822-823`). So `running` is the real value 02 compares with (`LIVE/02_app_basic.sh:162`, `:185`).

**Conditional removal matches the intent.**
- The list exists to name what the proxy did not do (`main.py:321-327`, "SKIPPING IS NOT SILENCE").
- Removing `link_watchdog` unconditionally would claim a watchdog is running when the heartbeat watchdog failed to start.
- This goes beyond the ruling's wording. `SUMMARY:53` states the interpretation; Adam should see it.

**Every reader and asserter, checked:**
- **07:** updated (`07_roles_basic.sh:88-89`, fixture `:480-484`, new BAD cell `:553-554`). Its expectation is unconditional, but 07 already requires the heartbeat to be running (`CAPS_*` `link_discovery: heartbeat`, `:82-83`), so this is consistent.
- **02:** updated, conditional (`:61-68`, `:161-187`). See N1.
- **03/04 (external):** still expect `link_watchdog` (`03:120`, `04:108`). That is correct: an external fabric never enters the heartbeat branch (`main.py:2199-2201`, `:2224`; `EXTERNAL_SKIPS` at `:345-346`).
- **ndt** (`WT/tools/test_workflow/ndt:4044-4061`) and **stack.sh** (`:274-277`) only look for `lldp_discovery`. `drive_exercise.py:2476-2479` only prints the list. Nothing under `WT/src` reads `control_plane`.
- **GUI:** a grep of `/home/adam/Web-GUI` for `control_plane|link_watchdog|switch_state|lldp_discovery` found no files. I also checked trunk's `ndt serve` page (`/home/adam/Desktop/NDTwin-Kernel/tools/ndt_serve/static/{index.html,app.js}`), which is not in this branch and which the worker did not mention: no matches either.
- **Tests that still expect `link_watchdog` in the list:** `p4_proxy/tests/test_declared_links.py:307,317`, `test_foreign_pipeline.py:441`, `test_startup.py:532,1016`.
  - They pass at ebe17f7c (`LOGS/proxy_unit.aeg4-ebe17f7c.log:14,22,48`), and their `assertEqual` includes `SKIP_WATCHDOG`.
  - So on their topology doubles the heartbeat watchdog never starts: they test the "not started" half, which is consistent.
- **Shell fixtures:** `tests/shell/test_ndt_app_package.sh:1008,1063` and `test_stack_await_convergence.sh:93,96,147,214` still carry the pre-E list. They only test that ndt and stack.sh quote it back (N5).
- **The proxy's own startup log disagrees with the list (F2).** `main.py:2183-2188` prints `Skipped: …, link_watchdog, …` *before* the heartbeat decision. On every heartbeat-driven fabric the log therefore says the watchdog is skipped, and the next line (`:1409-1411`) says it runs.

### G: no default owner; refuse with rc 2, nothing started

**Implemented:**
- `_common.sh:35-41` sets no default. `:314-318` refuses (prints `REFUSED`, exits 2) before the run directory (`:319`), `mkdir` (`:320`) and the trap (`:321`).
- Every script that calls `start_step` has only variable assignments before it: 01:26-28, 02:47-70, 02b:38-44, 03:44-50, 04:32-38, 05:41-48, and 07:61-89 then 716-723 (its self-test returns before `start_step`).
- **06:** refuses at `:43-47`, before its run directory (`:53-54`) and before its EUID and driver checks.
- **08:** its own refusal at `:90-95` comes before `faults.sh` and `_common.sh` are sourced (`:107-109`).

**Sourcing `_common.sh` without an owner still works (by reading):**
- The only top-level reference to `NDT_OWNER` is guarded (`:41`).
- `:132` (inside `require_free_lab`) and `:322` are inside functions that only run after the check.
- `link_usage_cell` always passes an owner (`drive_exercise.py:461-465`, `:2652`).
- The test for this (`tests/shell/test_live_p1_common.sh:1140-1141`) only proves the variable stays unset, not that a function runs.

**Remaining default owners:**
- `drive_exercise.py:106`: `os.environ.get("NDT_OWNER") or "drive-exercise"`. A standalone run still claims the lab as nobody. The ruling names `_common.sh`, so this is outside its letter, and the worker disclosed it (`SUMMARY:74,121`).
- Others are outside the ruling's scope (e.g. `tools/test_workflow/live_cells/run_cells.sh:50`).

## 2. Red-first claims (check 3)

- **A: SUPPORTED.**
  - `LOGS/redfirst_aeg.aeg3-5dcf704b.log:15-25`: exactly 4 cells red (cut_cycle; OVER last line; earlier failure; STOP), and the within-20 s control is green.
  - `:26` shows the base's last line is the pre-ruling FAIL. aeg4 is identical (`:15-25`).
- **E: SUPPORTED.**
  - aeg3 `:28-36`: exactly 2 proxy tests red. The "did not start" test is green at base. HEAD's `main.py` runs 28 tests OK.
  - 07 with the base's lists is red on the three named cells plus the roles cell (`:37-43`).
- **G: SUPPORTED, with one caveat.**
  - aeg3 `:45-62`: 184 checks, 11 red, all in §15 and §16.
  - `:63-67`: the base `start_step` with no owner ran as `live-p1`, PASS, rc 0.
  - Base 06: 4 red at aeg3 (`:68-73`), 6 red at aeg4 (`LOGS/redfirst_aeg.aeg4-ebe17f7c.log:68-75`).
  - Caveat: at aeg3, one of the new no-owner cells ("no round ran as a default owner") was **not** red on the base. `SUMMARY:79` quotes that aeg3 count without saying so. aeg4 closes it.

**Do the tests assert the ruling or an implementation detail?** Mostly the ruling:
- These assert observable behaviour: the H1 last-line cells (`08:1806-1839`), §15 (`test_live_p1_common.sh:1099-1110`), §16 (`:1134-1144`), the proxy tests (`test_heartbeat_fabric.py:149-181`), the 07 cells, and the 06 cells (`test_live_p1_thirteen.sh:197-208`).
- The cut_cycle glue cell pins internal variables (`08:1649-1655`).
- The L62 cell (`08:1855-1870`) is a check on the script's source text, and it overclaims (F1).
- The 06 cell "no round ran as a default owner" pins the literal text `owner: live-p1`. A different default name would pass it, but the rc-2, REFUSED, no-verdict and no-run-directory cells beside it would go red.

## 3. The M11 fix and the proxy_unit runner (check 4)

**M11: SUPPORTED.**
- aeg3: SURVIVED, "still green: no round ran as a default owner" (`LOGS/mutate_live_p1_thirteen.aeg3-5dcf704b.log:100-101`).
- The fix (`SP/fix_m11.patch`) replaces `hasnt ">>> "` with `hasnt "owner: live-p1"` and adds `hasnt "PASS 06_thirteen"`.
- The new cells can go red: at aeg4, M11 was caught on all 5 named cells (aeg4 log `:100-111`), and both new cells are red against the base 06 (redfirst aeg4 `:72-73`).

**proxy_unit:**
- It is **not in ebe17f7c**. It is a gate-driver script, `LOGS/scripts-aeg4-ebe17f7c/proxy_unit.sh`.
- It covers every test file: the 46 `tests/test_*.py` in `WT/p4_proxy/tests` are exactly the 46 in `LOGS/proxy_unit.aeg4-ebe17f7c.log:9-54`. The per-file counts sum to 1660 (`:55`).
- Caveat 1: the runner treats `OK (skipped=N)` as OK (`proxy_unit.sh:13-14`).
  - `test_p4_client.py` shows "ran 1, OK (skipped=1)" (`log:35`), so the real result is 1659 passed and 1 skipped.
  - A file whose every test skips would also read ok (for example `test_heartbeat_fabric.py:129`, `skipUnless(HAVE_PROXY)`).
- Caveat 2: the runner itself was never shown going red.

## 4. The four reused gate results (check 5)

The worker's argument has two halves:

- **"5dcf704b..ebe17f7c changes only three files": UNDER-EVIDENCED.** No git output is in the evidence, and I could not run git. What I found is consistent with it but does not prove it:
  - `fix_m11.patch` covers 2 of the 3 files, with 6 and 2 changed lines, matching `SUMMARY:117`.
  - `06_thirteen.sh` has the same sha256 (87e1944f…) at aeg3 and aeg4 (mutate_live_p1_thirteen logs `:104` and `:114`).
  - The red-first G and E outputs are identical at aeg3 and aeg4 (184 checks / 11 red; 28 tests / 2 failures).
- **"None of the four gates reads those files": SUPPORTED.**
  - selftest_07 reads 07, `_common.sh` and the snapshot.
  - test_live_p1_common reads `_common.sh`, `LIVE/*.sh` (its hazard scan at `test_live_p1_common.sh:694`) and ndt.
  - mutate_live_p1_common reads the same plus itself.
  - mutate_roles_binding reads the proxy code and tests (a `test_*.py` glob at `mutate_roles_binding.sh:294`) and 07.
  - A grep of the whole worktree finds the three changed file names only in those files themselves and in comments.

## 5. The ~2-minute uncommitted edit (check 6): SUPPORTED

- aeg3 gate start times (line 2 of each log):

  | gate | start (UTC) |
  |---|---|
  | selftest_07 | 08:20:17 |
  | test_live_p1_common | 08:42:25 |
  | mutate_live_p1_common | 10:45:20 |
  | test_live_p1_thirteen | 10:53:03 |
  | mutate_live_p1_thirteen | 10:53:35 |
  | proxy_unit | 10:55:29 |
  | mutate_p4_heartbeat_w | 11:10:22 |
  | mutate_roles_binding | 11:47:08 |
  | check_gate_anchors | 12:31:22 |
  | nolab_tripwire | 12:31:36 |

- The edit could only come after M11's survival was known, i.e. by 10:55:29. Three of the reused gates had finished by 10:53:03.
- The driver exits if tracked files are modified when any gate starts (`gates_aeg3.sh:17,36`). The tree was clean at 11:10:22, 11:47:08, 12:31:22 and 12:31:36.
- The only gate that ran during the edit was aeg3's proxy_unit, which was discarded and reads no shell tests. mutate_roles_binding does not read the two edited files anyway.

## 6. Public repo (check 7): nothing new

- I grepped `main.py`, `test_heartbeat_fabric.py`, `LIVE/*.sh` and the six changed `tests/shell` files for home paths, hostnames, VPN addresses, e-mail, keys and tokens.
- The only hits are `/home/adam` paths at `LIVE/03:143,146`, `04:117,120,190,191`, `06:39` and `test_live_p1_common.sh:167`. All are identical on trunk, so they predate this branch.
- Code comments that cite "Adam's ruling", "fable judge" or "orchestrator" follow the existing convention in `main.py`. The CLAUDE.md restriction applies to PR titles, descriptions and squash messages, not code comments.

## Findings

- **F1 (fix; small). 08's early exits drop over-cycle disclosures from the last lines.**
  - Where: `08:2099-2100`, `:2114-2115`, `:667-683`.
  - Claims it breaks: `README:295` and the label at `08:1867`.
  - Fix: flush any pending tally in `w_finish` before `finish`, and add a self-test cell (an OVER cycle followed by a failing restore, expecting the NOTE line above the FAIL). The alternative is to narrow the two claims.
  - Also fix the stale sentences at `08:2089` and `08:2120`.
- **F2 (fix; small). The proxy's startup log line disagrees with the list.** `main.py:2183-2188` prints the skipped list before the decision at `:2224-2229`. Print it after the decision.
- **F3 (verify).** Run `git diff --name-only 5dcf704b ebe17f7c`; it should list exactly the three tests/shell files. Run `git diff --stat 7746832e ebe17f7c`; it should show 20 files. Any other result means the four reused gates must be re-run.
- **After F1 and F2 land, re-run:** the 08 self-test and mutate_p4_heartbeat_w; proxy_unit and mutate_roles_binding (both read `main.py`).
- **N1. 02's expectation is chosen by the proxy's own report.**
  - 02 picks which list to expect from the proxy's own `heartbeat.watchdog` (`02:185`). The script's own header warns against exactly this (`02:59-60`).
  - It proves the list agrees with that field, not that the heartbeat is running.
  - It has never been executed (disclosed at `SUMMARY:122,124`).
  - Accept it, or assert `running` explicitly.
- **N2.** "About 20 s" is implemented as "≤ 35 s", and restore stays a strict 20 s. Document both and confirm with Adam.
- **N3.** `drive_exercise.py:106` still defaults the owner (a disclosed open item).
- **N4.** The runner counts skipped tests as OK. Mutants E1 and E1b are the same change (`mutate_p4_heartbeat_w.sh:689-700`), so "200 mutations" counts one mutation twice.
- **N5.** The pre-E shell fixtures are harmless.

## Claim-by-claim classification

**CONTRADICTED**
- `SUMMARY:5` "4 commits": §5 (`:114-116`) lists 3, and so does the delivery description.
- `:18` "both fixed in ebe17f7c": the proxy_unit fix is in the gate driver, not the commit (§5, `:117`).
- `:92` "1660 tests, all OK": one of them was skipped (`log:35`).
- `README:295` and the cell label `08:1867`: false on the early-exit paths (F1).

**UNDER-EVIDENCED**
- `:5` a clean merge-tree against trunk 3d740be0: no output is quoted.
- `:16` the "only conflict" part. The NOTEs-first order itself is supported by `mutate_roles_binding.aeg3 log:609-613`.
- `:97` the premise that only three files changed (F3).
- `:89` "green at HEAD" for A and G: the red-first script checks HEAD only for E's proxy tests (`redfirst_aeg.sh:60-63`); A and G being green at HEAD comes from other gates.
- `:69` "sourcing still works" as a tested claim (supported by reading only).
- `:6` no push, no sudo, main checkout untouched: cannot be checked read-only. The "no lab" part is supported by the tripwire: `nolab_tripwire.aeg4 log:20-21`, and the shim log's 185 lines are all `curl … file://`.

**UNTESTED (disclosed by the worker)**
- 02's new branch has never been executed.

**SUPPORTED** (citations in sections 1-5)
- Every other claim in §1-§4:
  - the A, E and G code changes;
  - the 07 changes and the Web-GUI claim;
  - `ndt:4044-4061`;
  - the red-first results;
  - the aeg4 gate table (`gates_aeg4_run.txt:1-8` and each log);
  - the reused gates' own results;
  - the edit disclosure.

## Tests I would have run

1. F3's two git commands.
2. An 08 self-test cell for an early exit after an OVER cycle.
3. An offline check of 02's list selection against synthetic switch_state files where `heartbeat.watchdog` is `running`, `not_started` and absent, plus `bash -n`.
4. The proxy_unit runner against a tree with the base `main.py`, to show it can go red; and an all-skipped case.
5. `WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/tests/test_drive_exercise.py`. It parses and sources `_common.sh` and was in neither aeg3 nor aeg4.
6. Each real step (01, 02, 02b, 03, 04, 05, 07) run with `env -u NDT_OWNER` and a stub ndt, checking for `REFUSED <step>`, rc 2 and no new run directory.
7. The repo's own L1 lane instead of a one-off runner.

## Internal inconsistencies in the report

- It says 4 commits but lists 3.
- It says both defects were fixed in ebe17f7c, but its own §5 lists only three test files.
- It reports 1660 tests "all OK" when one was skipped.
- §3's aeg3 count of "4 red, all the new no-owner cells" was taken while one of those cells was still vacuous.
- "200 mutations" includes the duplicated E1/E1b change.
- The red-first gate is labelled "green at HEAD" although it only checks E at HEAD.

---
# orchestrator: F3 run 2026-09-27 23:5x -- `git diff --name-only 5dcf704b ebe17f7c` = the three tests/shell files named; `git diff --stat 7746832e ebe17f7c` = 20 files, +443/-103. F3 holds.
