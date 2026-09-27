# JUDGE: fix/sudo-probe-unknown-0927 @ d57f90f1 (re-review, evidence audit)

**Verdict the evidence supports: MERGE AFTER FIXES (F1–F3 below).** The production change reads correctly against the orchestrator's three rulings. Red-first and the mutants S8–S12/T1 check out in the logs. As far as I can see without git, the merge lost nothing. Three things remain open:
- **F1:** the "anchored at `sudo: `" half of the ruling has never been seen red.
- **F2:** the report infers the `--check` exit-code effect but does not measure it, and nothing in the repo would notice if the problem line behind it disappeared.
- **F3:** the "no other suite flips" sweep is from before the merge.

## Scope and limits
- **What I read:**
  - the worker report (§7, plus the §1–§6 claims it still relies on);
  - every probe4 log and its kept outputs;
  - the frozen probe4 driver scripts;
  - the code at the branch head.
- **Which tree that code is:** the worktree HEAD points at the branch, and `.git/packed-refs:170` puts that branch at d57f90f1. The test and mutant names in the probe4 logs match the files I read. I cannot rule out uncommitted edits made since the gates ran.
- **What I compared against:** the main checkout (trunk; the session-start snapshot shows no uncommitted changes under `tests/` or `tools/`), plus raw gate logs from bbb9fd41.
- **Not done, because my role forbids reading audit documents, handoff notes or git history:**
  - I did not read `judge-SUDOPROBE-103f94f0.md`, so check 1 is not assessed against the contract.
  - I did not read the merge-resolution notes.
  - I did not use git log, diff or show, so byte-level identity for check 5 is not established and the commit messages are not checked.
- **No write tool:** this report is returned here, not written to `…/intake-0926/sudo2/`.
- **Nothing was executed.** "Would survive" below means read, not run.

## Verdicts in the worker report

| # | Claim | Class | Evidence |
|---|---|---|---|
| 1 | §7.1 merged 4ff4eee8; `NDT_SUDO_STDERR` comment now says could-not-tell | SUPPORTED | WT `sudo_surface.sh:132-134` |
| 2 | §7.1 merged file minus comments equals 103f94f0; trunk's file equals bbb9fd41's | UNDER-EVIDENCED | Read-only claims with no saved diff output; checking needs git |
| 3 | §7.2 line refs replaced by function names; "five" to "six"; R-pass row; G-41 | SUPPORTED | `lib_probe_stub.sh` WT 26-45, 81-83 vs trunk 26-41, 77-79 (function bodies identical); six patterns at WT `sudo_surface.sh:167-172`; KNOWN-ISSUES WT 4704-4706 vs trunk 4705-4706 |
| 4 | §7.3 two-row report check, killed by S8 | SUPPORTED | suite:311-321; test log:60; redfirst log:32-33; mutate log:29 |
| 5 | §7.4 S9 (three at once), S10, S11, T1 | SUPPORTED | mutate log:30-37; `report_all` at gate:51-64 needs every named case FAILED and rc≠0 |
| 6 | §7.5 warning match anchored; new fatal check; S12 | Code SUPPORTED (`sudo_surface.sh:203`). "Matched whole" SUPPORTED (mutate log:36). **"From `sudo: `" UNTESTED** | F1 |
| 7 | §7.6 stale refs fixed | SUPPORTED | `check_test_tmpdirs.py` WT:58 vs trunk:58; gate:276 |
| 8 | §7.7 SUMMARY corrections | SUPPORTED | probe4 log headers, line 5; `sweep_probe.probe3-103f94f0.log:14-17` |
| 9 | Commit messages follow the new rules from 0597fe86 | Not checked | Needs git log |
| 10 | probe4 gate table, 9 rows, all rc 0 with the stated counts | SUPPORTED | Each log's tail; details under check 3 |
| 11 | Driver ends `GATES-PROBE4 d57f90f1: ALL-AS-EXPECTED` | SUPPORTED, weakly stored | Only in `/tmp/.../scratchpad/queued/logs/gates_probe4.run.txt:10`, not beside the logs |
| 12 | `ndt status` table under the shim (rc 0/0; `--check` 3/3; grants block; problems) | SUPPORTED | status_probe log:11-35; kept `head-check.out:35-38, 50-53` |
| 13 | "0→1 on a machine with a baseline" | UNDER-EVIDENCED (the worker labels it inferred) | Code agrees (`ndt:6944-6946`, `7065-7072`); not measured. F2 |
| 14 | Historical harness will flip | SUPPORTED (read claim) | `scripts-pstub3-f9c59a44/redfirst_stubfix.sh:43` asserts `*granted*`; HEAD prints "could not be tested" |
| 15 | §1 rule and implementation | SUPPORTED | `sudo_surface.sh:165-175, 184, 194-210, 237-251, 257-280`; suite:260-321; test log:43-60 |
| 16 | Known limit documented | SUPPORTED in code only | `sudo_surface.sh:66-69, 76, 229-236, 248-249`; suite:279-280 plus S11; no README or KNOWN-ISSUES mention |
| 17 | §4 "no other suite flips; 0 lab calls" | **UNTESTED for d57f90f1** | Evidence is probe3 (103f94f0 vs 7746832e), before the merge. The probe4 driver copies `sweep_probe.sh` (`gates_probe.sh:24`) but never runs it (run list 47-62). No probe4 sweep log exists |

## The seven checks

**1. Fix list.** I did not check this against the contract. Of what §7 says was done, everything is supported except row 2 (under-evidenced) and the anchoring half of row 6 (untested). Items the worker explicitly leaves open:
- N4, the sudo-rs prefix;
- your "I would run" items 5–8;
- the requiretty case, where `guard_no_live_ovs` prints a NOPASSWD fix that cannot help (`ndt:6034-6038`).

The orchestrator needs to compare that list with `judge-SUDOPROBE-103f94f0.md`.

**2. Semantics.**
- **0/1/2 in the documented cases: SUPPORTED.** The order in `sudo_surface.sh:239-250`:
  - `NDT_SUDO_UNREAD` is cleared first.
  - Unknown key, no sudo, or program not installed gives 2.
  - A probe that succeeds gives 0.
  - A known refusal phrase gives 1.
  - The first `sudo:` line that does not start with `sudo: <entry>` gives 2, and that line is stored.
  - Otherwise 0.
  - This matches the documentation at 224-236.
- **Fatal lines that share words with a warning are not swallowed:**
  - `sudo: unable to execute …` gives 2 (suite:294-296, S12).
  - A warning plus a known refusal gives 1 (suite:290-291, S9).
  - A warning plus an unknown refusal gives 2 (suite:287-289, S6, R2 at redfirst log:54-58).
  - Gap: the anchoring itself is not pinned (F1).
- **The "no `sudo:` line means granted" residue** is honestly stated in the code; line 76's wording is exact. It also covers any refusal worded without a `sudo:` prefix, such as a `sudo-rs:` line (the carried N4), which only the SUMMARY mentions. `ndt status` prints a plain "granted" for these cases, and no README or KNOWN-ISSUES entry mentions it.
- **`--check` treats 2 correctly: correct in code, not pinned by any test.**
  - The `*)` arm adds a problem (`ndt:6944-6946`). With a baseline that gives rc 1 (`7070-7072`); without one, rc 3 with the problem still listed (`7056-7064`).
  - Observed only in the rc-3 case (`head-check.out:50-53`).
  - No test or mutant under `tests/` mentions either problem sentence.
  - The only check on this seam, "a refused grant is a --check problem" (suite:352, `has … "sudo grant"`), is already satisfied by the "sudo grants" header row that is always printed (`ndt:6940/6941/6944`). I found nothing that would go red if `ndt:6943` or `ndt:6946` were deleted.
- **Nothing parses the new wording.**
  - `ndt` prints the report as-is and branches only on its rc (`ndt:6938-6947`).
  - `ndt serve` maps rc codes only (`verbs.py:205-217`, "…a refused sudo grant, and more") and shows the output as-is. `test_ndt_serve.py:1132-1136` only checks words in that description.
  - The only other copies of the wording are recorded fixtures (`tests/fixtures/live_cells/stale_app_pidfile_does_not_frame_the_fabric/{old,new}/check.log:35`).

**3. Red-first: SUPPORTED from the logs.**
- Base is 4ff4eee8 (redfirst log:9): `base: rc 1 -- Ran 51 checks, 8 failed` and head 51/0 (log:12-13).
- The 8 red checks are listed at 15-33; "exactly those 8 and nothing else" at 50 comes from a count match plus a match on each of the 8 names.
- Each mutant is killed by name: S8 at mutate log:29, S9 at 30-33 (three named reds), S10 at 34, S11 at 35, S12 at 36, T1 at 37.
- 27 mutations, 0 survived (log:44); baseline files byte-identical (log:43).
- Across the 18 probe-group checks, every one has now been seen red by name, through R1, R2 or a mutant.

**4. Measuring `--check` 0→1: yes, cheaply and offline, and I would require it (F2).**
- The `run_check` seam in `tests/shell/test_ndt_status_check_baseline.sh:126-183` already returns RC=0 for a recorded, healthy 4-host OVS fixture (section 1, :200-206), with `ndt_sudo_report() { return 0; }` stubbed at :154. Add the same fixture with the report returning 2, and with it returning 1; both must give RC=1 plus the problem sentence.
- For the measured version of the worker's inference, remove the report stub in that seam and:
  1. set `NDT_SUDO_TABLE` to the ovs-vsctl row;
  2. put a fake `sudo` on PATH that prints the nolab line and exits 1;
  3. run once with 4ff4eee8's `sudo_surface.sh` and once with HEAD's. The expected result is RC 0 at base and 1 at HEAD.
- The same case can live in the suite's own ST_STUBS block (stub `check_up_target` to return 0), which stays inside the ticket's files.
- Adding an `up.target` to status_probe's archive trees would not work: the kernel is down there (`head-check.out:33`), so the baseline comparison would likely raise its own problems in both trees.

**5. Merge resolution: nothing lost — SUPPORTED as far as I can check without git.**
- `tests/shell`: 206 files in both trees. The branch has 213 more lines, which is exactly `mutate_ndt_sudo_surface.sh` (+122), `test_ndt_sudo_surface.sh` (+87) and `lib_probe_stub.sh` (+4).
- `tools/test_workflow`: 43 files in both; the only difference is `sudo_surface.sh` (+57). `ndt` is 11042 lines in both.
- `ndt_serve` and its tests are identical in line count except `tests/python/test_ndt_serve.py` (1204 vs 1213). That is the file trunk's later TMPDIR fix touched according to the session's starting commit list; I did not verify that with git.
- `lib_probe_stub.sh`: read in full in both trees; the function bodies are identical.
- Gate behaviour matches the bbb9fd41 runs:
  - `mutate_probe_stubs`: same six baseline counts, C1–C3, P1–P11, T1–T3, 14/0 (probe4 log:10-42 vs queued3 log:11-43).
  - L1 scorer: 113/0 with identical R1–R17 (probe4 log:57-74 vs 58-75).
  - Anchor count for `mutate_probe_stubs.sh`: 11 in both.
- What this does not prove is byte identity of files whose length did not change.

**6. Line references.**
- Every reference the branch set out to replace is gone. No `sudo_surface.sh:N` or `test_ndt_sudo_surface.sh:N` remains outside `doc/audit`. The spike's `sudo_surface.sh:37-49` still points at the right block.
- Stale references remain in files the branch edits, carried over from trunk:
  - `sudo_surface.sh:12-13` cites `ndt:1177` and `ndt:1206`. `ndt:1177` is now a comment in `claim_note_unwritten`; the real calls are at `ndt:6003` and `ndt:6094`.
  - Two check names at suite:110-114 embed the same numbers.
- `verbs.py`'s pins `6930`, `6943` and `7070-7072` are still correct, since `ndt` is unchanged.

**7. Public-repo fitness.**
- No secrets, emails, private IPs, hostnames or home paths in the six changed files. The only address is Mininet's `10.0.0.2`, and the only hostname is the fake `lab-7`.
- Internal-process wording is newly added at `sudo_surface.sh:180` ("the orchestrator's ruling, 09-27"). Similar wording already exists in trunk (`lib_probe_stub.sh:8, 15, 21-22, 29, 36`; `sudo_surface.sh:45` "Adam's account…").
- CLAUDE.md bans these words only in PR and commit text, so this does not block.
- `sudo_surface.sh:81` cites a `doc/audit/*.md` file that the PR rule excludes, so the reference will dangle on main. This predates the branch.

## Required fixes
- **F1.** Pin the anchoring half of the ruling.
  - Why: replacing `"sudo: $w"*` with `*"$w"*` would pass all 51 checks (read, not run). Every warning fixture starts with `sudo: <entry>` (suite:252-253), and the fatal fixture contains neither entry anywhere (294-296). The check's name claims a property its input cannot show.
  - Fix: add a fatal `sudo:` line that contains an entry after other text (expected rc 2), plus an un-anchoring mutant that must kill it.
- **F2.** The `--check` case from check 4, plus mutants that delete `ndt:6943` and `ndt:6946`.
- **F3.** Run `sweep_probe` at d57f90f1 against base 4ff4eee8 (a frozen copy already sits in `scripts-probe4-d57f90f1/`) and keep the log. Alternatively, relabel §4 as evidence about 103f94f0 only.

## Tests I would have run that the report did not
- F1–F3.
- `mutate_ndt_serve.sh` and `tests/python/test_ndt_serve*.py` at d57f90f1. The merge brought in the ndt-serve GUI, and probe4 only counted its anchors.
- A named control for a refusal worded without a `sudo:` prefix (for example `sudo-rs: …`) that is expected to read 0. This would record N4 in the suite, not only in the SUMMARY.
- Your items 5–8: guard, dataplane and sflow messages under requiretty, PAM and secure_path, at base and at head.

## Internal consistency
- No numeric contradictions: 49+2=51; 6+2=8; 21+6=27 = 10+12+1+4; 96+17=113 L1 checks; 4+8+16=28 sudo calls; 14 = P1–P11 + T1–T3.
- The anchor count ok(24) against 27 mutations reconciles: S4, S5 and S12 share one anchor, and N1 reuses M1's. That leaves 23, plus T1, is 24; probe3's 19 plus 5 also gives 24.
- Wording, not numbers: §7.4 says "six checks, each with a mutant", but it is four mutants (S9 covers three checks).
- The driver's own header (`gates_probe.sh:3-4`) still lists `sweep_probe` in its run set, which it does not run.

## Files
- Worktree (WT): `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-sudo-probe-unknown-0927/`
  - `tools/test_workflow/sudo_surface.sh`
  - `tools/test_workflow/ndt`
  - `tests/shell/test_ndt_sudo_surface.sh`
  - `tests/shell/mutate_ndt_sudo_surface.sh`
  - `tests/shell/lib_probe_stub.sh`
  - `tests/shell/test_ndt_status_check_baseline.sh`
  - `tools/ndt_serve/verbs.py`
- Logs: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/`
  - `*.probe4-d57f90f1.log` and their `.kept/` directories
  - `scripts-probe4-d57f90f1/gates_probe.sh`
  - `*.queued3-bbb9fd41.log`
- Worker report: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/SUDO-PROBE-UNKNOWN-SUMMARY.md`