# SUMMARY: HB spike round 5, the five R4 notes from the judge's round-4 verdict on `e1245b40`

(Worker's final reply, saved by the orchestrator 2026-09-26; content as delivered.)

**Result:** all five notes (R4-1 to R4-5) are fixed, and (d)(i) is done as well. The full `--self-test` passes at head, and the in-repo discrimination tool passes for every revert.

- **Head:** `796703653ad2dd9d9b96e4c74acc1bc928afc419`
- **Branch:** `fix/hb-spike-r4-0926` in worktree `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hb-spike-r4-0926`, based on trunk `dd7e2fcf`.
- Nothing was pushed or merged. The root helper `tools/test_workflow/ndtwin-lab` is untouched (`git diff dd7e2fcf..HEAD` covers only the 3 spike files below).
- 🔴 **Nothing here is a live run.** No lab, no sudo, no claim, no tc/mininet, no C++. `SELFTEST_PROBE_SUDO` and `FAULTS_TC` were unset for every run, and every log shows `the real sudo probe was NOT run`.

## Commits (dd7e2fcf..HEAD)
| sha | what |
|---|---|
| `869598c7` | Tests only: red-first checks for R4-1, R4-2, R4-3, R4-5 and (d)(i). The code under test is dd7e2fcf's. |
| `08c74a20` | R4-5: the detect driver defines `QDISC_TOOL`. |
| `67d47067` | Fixes R4-1, R4-2, R4-3 and (d)(i). |
| `d486f1c7` | Self-test drives one census arm with stubs (R4-1 at the census's own call site). |
| `d6e649a4` | R4-4: `spike/oldcode_selftest.sh`. |
| `79670365` | Header comment only. |

## Files changed (numstat dd7e2fcf..HEAD)
- `doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`: +263 −34 (now 974 lines)
- `doc/audit/2026-09-25_p4-heartbeat/spike/hb_watch.py`: +77 −4 (now 380 lines)
- `doc/audit/2026-09-25_p4-heartbeat/spike/oldcode_selftest.sh`: +230, new file

## Logs
All logs are in `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/`. In each one, line 1 is the full sha tested and the last line is `# rc=N`. That rc is the command's real exit code, captured by a plain wrapper: no setsid, no guarded_build. Nothing here was heavy: the self-test takes about 15 s and the tool about 2 min.

- **RED1:** `spike_selftest.red.hbr4-869598c7.log`, rc 1
- **RED2:** `spike_selftest.red.hbr4-08c74a20.log`, rc 1
- **GREEN-fix:** `spike_selftest.hbr4-67d47067.log`, rc 0
- **GREEN-head:** `spike_selftest.hbr4-79670365.log`, rc 0, 0 red lines, `SPIKE SELF-TEST PASS` at :76
- `hb_watch_selftest.hbr4-79670365.log` and `hb_sniff_selftest.hbr4-79670365.log`: both rc 0, PASS. They were also run inside the spike self-test.
- `spike_selftest.oldcode.hbr4-79670365.log`: rc 0
- `check_gate_anchors.hbr4-79670365.log`, `check_test_tmpdirs.hbr4-79670365.log`, `check_test_tmpdirs.files.hbr4-79670365.log`
- Earlier copies at `d6e649a4` also exist; ignore them, the head logs replace them.

## Per note

**R4-1: `wait_session` accepted any report**
- **Change:**
  - `hb_watch.py` gains the pure function `session_of(doc, pid)`. It returns the session only when `status == "running"` and `pid` equals the pid given; otherwise `""`.
  - `session <report> <pid>` now uses it.
  - New `started-pid <file>` / `started_pid()` reads the pid from the helper's own `heartbeat started (pid N; ...)` answer.
  - `wait_session <report> <tries> <pid>` passes the pid through.
  - `census` takes the pid from `11_hb_start.txt`. If `start` named no pid (for example "already running"), or no running report of that pid appears within 5 s, the arm gets a FAIL row and no sniffer is started.
- **Red-first checks** (session driver in a fresh `bash -euo pipefail` process):
  - "the previous arm's final report ('stopped', its own pid) is not taken…"
  - "nor a 'stopped' report of the very pid start named…"
  - "nor a 'running' report of another pid…"
  - RED1 :67-69 and RED2 :67-69 show `rc 0: a1a1…/b2b2…/c3c3…`.
  - GREEN-fix :67-69 and GREEN-head :67-69 are ok.
  - The hb_watch unit lines at RED1 :29-33 are only "missing" reds (the function did not exist yet).
- **Added after the fix, never red on a commit:**
  - Three census-arm checks (GREEN-head :71-73). Their red is shown only by the oldcode tool (oldcode log :80-81).
  - The check that the pid parse matches the template read out of the helper. Its only red, at RED1 :70, was the trivial "no such verb" red.

**R4-2: `cut_link || break` left a half-done cut to the EXIT trap**
- **Change:** `cut_link || { restore_link || fail "cycle $i: could not remove the netem a half-done cut left on $CUT_A"; break; }`. I used `fail`, not the judge's `|| true`, because `revert_link_loss` empties `INJECTED_IFACES` even when it fails, so `|| true` would hide netem that was really left on the link.
- **Red-first check:** "a half-done cut (the second end refused)…". It runs detect with the real cut/restore functions and faults.sh's netem functions against a fake tc that keeps per-veth state; `nd_down` removes the veths, and `spike_finish` is the EXIT trap.
  - RED1 :64 is **not a valid red**: it died of the missing `QDISC_TOOL` (R4-5's reason).
  - RED2 :64 is the valid red, the judge's exact symptom: no `tc qdisc del dev s1-eth3` before `ndt down`, and the teardown says "cannot locate the netem".
  - GREEN-fix :64 and GREEN-head :64 are ok.

**R4-3: `column … | sed` under pipefail**
- **Change:** new `show_census` uses `column` when it is installed; without it, `sed` prints the rows as they are. Both paths end `|| true`, and the run block calls it.
- **Red-first check:** "the census table on a machine without 'column'…". It takes the run block's own display step out of the script source and runs it with a PATH that has no `column`, in a fresh `bash -euo pipefail` process.
  - RED1 :71 and RED2 :71: `rc 127 … column: command not found`.
  - GREEN-fix :71 and GREEN-head :74 are ok.
  - A second check confirms that `column` is still used when present.

**(d)(i): done**
- `hb_watch all-heard` and `others-up` now catch `(OSError, ValueError, KeyError)` and print `BAD the report could not be read: …` with rc 0.
- Red: RED1 :34-35 (`raised FileNotFoundError`). Green: GREEN-fix and GREEN-head :34-35.

**R4-4: the discrimination tool is now in the repo**
- `spike/oldcode_selftest.sh`, runnable from anywhere.
- For each revert it writes a copy of the spike and of `hb_watch.py` beside the real ones (named with the pid and cleaned up on exit), and points the spike copy's `WATCH` at the hb_watch copy.
- Each edit's count is asserted and the diff is printed. Then it runs the copy's `--self-test` with `SELFTEST_PROBE_SUDO` and `FAULTS_TC` removed.
- A revert passes only if rc ≠ 0 and the red lines are exactly the expected set, each carrying its expected reason. A no-revert control must be clean.
- The round-3 reverts (the two `set -e` fixes) are kept from the scratchpad tool.

**R4-5: the detect driver had no `QDISC_TOOL`**
- **Change:** the driver now defines `QDISC_TOOL` (a stub).
- **Red-first check:** "a detection cycle that goes as designed…" (fake tc, both ends cut and restored, the row written to the TSV).
  - RED1 :63: `QDISC_TOOL: unbound variable`.
  - RED2 :63 and GREEN-head :63 are ok.

## Oldcode tool, per revert (`spike_selftest.oldcode.hbr4-79670365.log`, table at :207-218, rc 0)
| revert | copy's self-test rc | red lines | expected | verdict | log |
|---|---|---|---|---|---|
| control | 0 | 0 | 0 | clean | :18 |
| r3 (two round-3 `set -e` reverts) | 1 | 3 | 3 | ok | :36-38 |
| R4-1 (whole) | 1 | 5 | 5 | ok | :77-81 |
| R4-1 status clause only | 1 | 2 | 2 | ok | :100-101 |
| R4-1 pid clause only | 1 | 2 | 2 | ok | :120-121 |
| R4-2 | 1 | 1 | 1 | ok | :138 (reason: "cannot locate") |
| R4-3 | 1 | 1 | 1 | ok | :155 (rc 127, `column: command not found`) |
| (d)(i) | 1 | 2 | 2 | ok | :183-184 |
| R4-5 | 1 | 2 | 2 | ok | :200-201 (both `QDISC_TOOL: unbound variable`) |

Two rows are not "exactly one check", and both are by construction:
- **r3** now reds 3 lines, not 2. The two original checks are still red, and the new census-arm check also catches the same bare `watch_hit`.
- **R4-5** reds 2 lines. Every detect scenario that gets past the first check reads `QDISC_TOOL`, and the tool asserts that both lines carry that reason.

## Other gates
- `check_gate_anchors.py HEAD`: 118/118 cells ok, rc 0. No `mutate_*` gate points at the spike.
- `check_test_tmpdirs.py --repo .`: 356 files, 0 fixed temp paths, rc 0. Its default scan covers only `tests/`, so it did not look at these files. Run explicitly on the 3 changed files: 3 scanned, 0 findings, rc 0. I did not check whether it would have caught a planted fixed temp path in them.

## Observed vs inferred, and what I could not verify
- **Observed (logs above):** every rc, red line and green line cited; the tool's table; the diffs it printed; copies removed afterwards (spike dir listing after the runs); no working-tree residue.
- **Inferred, not run live:**
  - That the real bmv2 veths' `tc qdisc show` output parses like the fake tc's `noqueue root` tree.
  - That the helper really prints `heartbeat started (pid N; …)` at run time. This was read from its source template, not from a running helper.
  - That the "stopped report" race exists live (the judge's reasoning; not reproduced).
  - That hiding `column` from PATH behaves like a machine without bsdextrautils.
- **Not verified:** any live behaviour of detect or census. The census arm is fully stubbed, and so are `sudo`, `mnexec`, `ndt` and the helper.

## Decisions for you
1. "already running" answered by `start` in a census arm is now a FAIL row; before, that daemon's session was sniffed. I read the ticket's "tie it to the just-started daemon" as ruling that out, and it matches the run's own pre-check that refuses an already-running heartbeat. It is a behaviour change.
2. R4-2 uses `restore_link || fail`, not `|| true` (reason given under R4-2 above).

## Seen but not fixed (out of scope; inferred from reading, not run)
`spike_finish` fails with `could NOT remove the netem on ${INJECTED_IFACES[*]}`, but `revert_link_loss` empties that array before it returns (`faults.sh:357`), so the message names no interface. It is cosmetic, and after the R4-2 fix it is less likely to be reached.

DELIVERED 796703653ad2dd9d9b96e4c74acc1bc928afc419
