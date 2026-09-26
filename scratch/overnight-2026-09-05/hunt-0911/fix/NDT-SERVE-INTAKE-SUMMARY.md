# SUMMARY: ndt serve intake fixes (items 1–5)

(Worker's final reply, saved by the orchestrator 2026-09-26; content as delivered, condensed only in layout.)

**Head:** `f643b884753bae4013f68831d73fc6497287a9cc` on branch `intake/ndt-serve-0926`, worktree `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-intake-ndt-serve-0926`. The worktree is clean. Nothing pushed; no lab; the peer's worktree and the real `~/.config/ndt-serve` / `~/.local/state/ndt-serve` untouched.

## Commits (on top of `48209682`)
| sha | what | files |
|---|---|---|
| `6053f75f` | Items 1, 2, 3: exact own-claim check, a named message for each unread-claim case, and each rc anchor now names its enclosing function | serve.py, verbs.py, README.md, test_ndt_serve.py, test_ndt_serve_cells.py, mutate_ndt_serve.sh |
| `ea18b6ca` | Item 4: comments the merge made false, plus the REPORT version note and heading time | serve.py, verbs.py, README.md, test_ndt_serve.py, test_ndt_serve_cells.py, doc/audit/2026-09-24_ndt-serve/REPORT.md |
| `f643b884` | Item 5: the serve paragraph in `ndt help` | tools/test_workflow/ndt |

Diff against `48209682`: 8 files, +216/−39. Final line counts: serve.py 952, verbs.py 294, README.md 154, test_ndt_serve.py 1164, test_ndt_serve_cells.py 675, mutate_ndt_serve.sh 735, REPORT.md 305, ndt 10915 (sha256 now `6954755b…`, was `7ecd2f12…`).

Logs: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/*.ndtserve-intake-f643b884.log`; first line full HEAD sha (red/survivor logs also name the service sha `48209682…`); last line `rc=<real rc>`.

## Item 1: prefix match on the claim line (Finding 2)
- `_require_own_claim` uses `OWN_CLAIM.fullmatch(line)`, `OWN_CLAIM = re.compile(r"yours -- [0-9]+m left \(until [0-9]{2}:[0-9]{2}:[0-9]{2}\)")` — ndt's own-claim printf (`claim_line`, ndt:5677). Full match rather than `startswith("yours -- ")`: an owner named `yours -- 5m left (until 12:00:00)` would pass the prefix version. Every other `claim_line` value checked: another owner (`yours-x`, `yoursx`), `EXPIRED … (was yours)`, `malformed …`, `none`, a missing row, `yours -- 12m left` without time — none passes.
- Residual: a foreign owner named exactly `yours` prints the same line as your own claim (docstring and README:96 say so); ndt's own `--check` has the same prefix issue at ndt:6575 (`yours*`) — trunk code, left alone.
- Test `CellsRun.test_only_ndts_own_claim_form_is_yours` (six refused values + positive control). Red log `red-item1-claim-prefix…`: on the `48209682` service, `yours-x -- 12m left (until 23:40:00)` returned 202 (observed).
- Mutations C25 (`startswith("yours")`) and C26 (`startswith("yours -- ")`) caught; C18's anchor moved, still caught.

## Item 2: unread claim (Finding 5)
- Each unread case its own 409 `claim`: `r is None` → "no read slot came free within N s (two read-only ndt calls held both), so ndt status never ran"; timeout → "ndt status did not answer within N s and was stopped…", with `read=<id>`. Stub ndt gained `sleep_after`.
- Tests `CellsRun.test_no_read_slot_is_not_a_claim_and_says_so`, `CellsRun.test_a_status_past_its_timeout_is_not_a_claim`. Red log `red-item2-unread-claim…`: both red on old code — the slot case because the note was wrong (a real defect); the timeout case only on message detail (old code already refused it); the real discrimination for that branch is C28.
- Mutations C27 (remove the `r is None` guard → 500 TypeError) and C28 (trust a timed-out read → partial `yours` starts the run, 202) caught; `why-c27-c28…` shows why.

## Item 3: anchor trap (Finding 3)
- `RC_SOURCE[...]["code"]` tuples are `(line, rc, needle, function)`; functions cmd_status, cmd_claim, claim_take, cmd_release, app_start, cmd_apps — all 19 match the judge's table. `RcProvenance.test_code_sourced_tables_are_in_ndt` finds each anchor's enclosing function (nearest column-0 `name() {` above, no column-0 `}` between, not a one-line definition) and collects every broken anchor. New `test_the_function_finder_reads_ndt`. M61 anchor updated.
- Survivor log `red-item3-8315-survives-merged…`: merged tree's own test with verbs.py 8775→8315 stays green (rc=0). Caught log `caught-item3-8315-at-head…`: red with `apps.start rc 1: ndt:8315 is 'return 1' in proc_checkout, cited as 'return 1' in app_start`. Mutation M63 (8775→8315) caught.

## Item 4: comments that now lie (Finding 4)
- README:60 → `ndt:9292-9307` (at `fd7382a3`, blob `3273df8b`, 8832 was the same lock_probe comment).
- `_spawn_cell_run` and `test_lab_cell_run_needs_your_claim` docstrings: OVS `up` refuses a foreign claim since 68ace017 (ndt:4248 `guard_up_lab_free`); the check stays because cells do netem, `kill -TERM` and knob writes directly (verified in the live_cells scripts), and the restore's `down` is refused under a foreign claim.
- serve.py red line 6 and `NoPatternKill` docstring name two signal sites: `run_read` and `cells.Grid._run`.
- verbs.py: 6662 is `in_flight`'s process scan; the `declared` row (6638-6640) is not a problem.
- REPORT.md: one note at the top (line numbers are 09-24's ndt, blob `3273df8b` = base `fd7382a3`, before 68ace017; "OVS up does not refuse a foreign claim" in §1-7, §2, §4.3 row 4, §4.4, §4.5-4 no longer holds; text below untouched); :283 heading now 22:49:18. REPORT-cells.md has no stale citations (grep).

## Item 5: `ndt help` (Finding 7, first point)
- "Every write carries the token" → "Every request but /health carries the token"; same five lines, no `$` or backtick added. test_ndt_honesty 345/0, test_manual_rc_table 26/0, test_ndt_up_target 23/0.

## Gate numbers at HEAD `f643b884` (all rc=0)
- test_ndt_serve.py 73 OK (was 72); test_ndt_serve_cells.py 35 OK (was 32); honesty 345/0; rc table 26/0; up_target 23/0.
- check_gate_anchors 119/119; mutate_ndt_serve.sh `ok(84)` (was 81; new distinct anchors C27, C28, M63; C25/C26 reuse C18's text). check_test_tmpdirs 359/0; check_process_by_name 326 files, 0 sites.
- Mutation gate through the guard: **91 mutations, 0 survivors** (was 86).

## CI shape (Finding 10)
- Observed: both suites green under `/usr/bin/python3` 3.12.3 with `env -i`, `PATH=/usr/bin:/bin`, an empty temp HOME; nothing written to HOME; no skips. Logs `ci-shape-test_ndt_serve…`, `ci-shape-test_ndt_serve_cells…`.
- Inferred, not verified on a runner: `Bounded.test_listen_backlog_holds_a_burst` needs `ss` (iproute2) — ERRORs if missing, does not skip; LoopbackOnly reads `/proc/net/tcp6`; wall-clock bounds a slow runner could hit (POST < 1.5 s at test_ndt_serve.py:776, refused connection < 3 s at :507, timeout cases < 8/12/10 s; the new slot case ~4 s margin; the new timeout case a 2 s `--list` timeout, C23 already uses 1 s); in CI l1 may run the server under PY_KERNEL rather than PATH `python3` — both 3.12 there.

## Observed vs inferred
- Observed: every red, survivor and caught result; C27/C28 reasons; every green gate; the CI-shape runs; that 3273df8b is ndt's `git hash-object` at fd7382a3; every ndt line number cited.
- Inferred: the runner-specific CI points; that a foreign owner literally named `yours` is the only claim line that still passes wrongly.

## Not done / notes for the next cut
- A plain `ndt status` that exits non-zero without a timeout is still read for its claim line (plain status is documented to always return 0).
- Cosmetic: a guided walk's blocked `why` for an unread claim reads `(claim line: None)`.
- ndt:6575's `yours*` glob not fixed (out of scope). All other judge notes remain notes.

DELIVERED f643b884753bae4013f68831d73fc6497287a9cc
