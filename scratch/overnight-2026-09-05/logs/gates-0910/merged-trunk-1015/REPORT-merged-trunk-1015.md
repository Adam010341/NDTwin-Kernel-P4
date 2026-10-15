# merged-trunk-1015: the gate at the merge head

(Written by the orchestrator from the gate worker's hand-back; the worker could not write this file itself. Every number below was re-checked by the orchestrator against the logs in this directory on 2026-10-16.)

E = this directory. S = /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/mg

## Result
- M1 = d83a78d9d71035c1fbb9fb71de11cbea403d9dc8 = Merge branch 'feat/p4-ternary-replay-c' into trunk (parents acb3c4b7, 392a5746).
- M2 = d92bf1a258cec2d1524652fcff17526926fbcefa = Merge branch 'feat/p4-health-locale' into trunk (parents M1, 4a4eb94e). Branch `merge/trunk-1015`.
- Stage A clean apart from the one expected conflict (expected_today.tsv row T8). Stages B, C, D all green. No red step, no watchdog stop, no push, no commit besides the two merges.
- GATE.log: `GATE: 517 mutations, 0 survived, shards 4/4 ok, commit d92bf1a258cec2d1524652fcff17526926fbcefa, tree fd872b3ddb9d6eaa87d264675c8aaabcbabf2c26, subject sha e69a74d976c1a022`, rc=0.

## Stage A: the merge head
- M1: `git merge --no-ff` of 392a5746 onto acb3c4b7, clean.
- M2: `git merge --no-ff --no-commit 4a4eb94e`; the only conflict, expected_today.tsv row T8, resolved as the locale side's text with `rule_journal.py:1141` → `rule_journal.py:1249` (verified by `grep -n`: the merged file's line 1249 is `return self.record_complete(dpid) and TABLE_JOURNAL_REPLAYS`); `rule_journal.py:331` kept. No trailers on either merge.
- merge-verify.txt: parents as above; for every path in `git diff --name-only acb3c4b7 M2` except the tsv, M2's blob equals 392a5746's or 4a4eb94e's (0 MISMATCH); the tsv differs from each side only in row T8; SUMMARY-cut-a.md equals acb3c4b7's (blob 3cd024e4…); relative to their merge base c24a7d19 the two branches share only the tsv (392a5746: 14 files, 4a4eb94e: 13).
- Gate clone S/gate: `git clone --no-hardlinks`, detached at M2, `p4_proxy/venv` and `build` symlinked to the shared repo, P4 build per p4-ternary-replay-c/r2/p4build.log line 2 (E/p4build.log, rc=0). Tracked-clean at M2 before Stage B and after Stage D.

## Preconditions before every step
guard.sh (no other mutate_/probe.py/simple_switch/driver.sh process; df ≥ 1800 MB; MemAvailable ≥ 1800 MB) logged per step as `<step>.guard.log`, never waited or refused. Signal mask read inside the exec'ing process (mexec.sh, /proc/self/status, not a command substitution): `SigBlk & 0x4203 == 0` required and logged; all passed. Verdicts from each log's own final `rc=` line.

## Stage B: locale pre-gate checks (20:28:16–20:39:52, 11 min 36 s)
| # | Step | Log | Result | rc |
|---|---|---|---|---|
| 1 | ANCHOR_CHECK=1 mutate_p4_health.sh | B_1_anchor_check.log | 518 count lines (517 mutants + negative control), all 1; rc 2 by design; Cut C added no health mutant | 2 |
| 2 | check_gate_anchors.py HEAD | B_2_check_gate_anchors.log | 137/137 cells ok; mutate_p4_health.sh ok(476) (:111) | 0 |
| 3 | bare-sort lint | B_3_bare_sort_grep.log | `bare (not LC_ALL=C) sorts in a pipe: 0` (final grep finds nothing → rc 1, as in r3) | 1 |
| 4a-d | cells / collect, py3.13 and py3.8 | B_4_p4h.{cells,cells.py38,collect,collect.py38}.log | Ran 203 / 203 / 192 / 192, OK | 0 ×4 |
| 4e-h | the same four under a SIGHUP-blocked parent | B_4_*.sighup_blocked_parent.log | Ran 203 / 203 / 192 / 192, OK | 0 ×4 |
| 5a | test_p4_health_recover.sh | B_5_p4h.recover.log | Ran 163 checks, 0 failed | 0 |
| 5b | test_p4_health_gate_scripts.sh | B_5_p4h.gate_scripts.log | Ran 79 checks, 0 failed | 0 |
| 6 | ONLY_LABEL_PREFIX=C2R8-5g | B_6_mutate_partial_C2R8-5g.log | baseline green; mutant caught; negative control green; both byte-identical lines + `suites green against the real files`; `1 mutations, 0 survived` | 0 |
| 7a | ValueSet delivery test with SIGHUP pending before exec (pending_hup.py) | B_7_valueset_delivery_pending_hup.log | Ran 1 OK | 0 |
| 7b | the same, nothing pending (control) | B_7_valueset_delivery_control_no_pending.log | Ran 1 OK | 0 |
| 8 | S0 with a Frozen, bytecode writing ON | B_8_s0_with_frozen.log | see below | 0 |

Step 7's test: `TestS0Cut2Checks.test_a_stop_that_arrives_during_the_trial_waits_and_is_delivered_when_the_mask_is_put_back` (cells :2026).

S0 with a Frozen: run outside runlog.sh (which sets PYTHONDONTWRITEBYTECODE=1) via s0_frozen_run.sh with `env -u PYTHONDONTWRITEBYTECODE`; the log records no PYTHON* variable and `sys.dont_write_bytecode` False. probe.py cmd_lab's `ID.system_under_test` and `ID.fingerprint` (cmd_lab ~:239-251, same arguments) were added before the final check_exercise. Result: `S0 verdict: COMPLETE rc 0 refused: None`; `S0 checks: 57, failed: 0`; three check_exercise ok; `final check of the copy after s0.run(): ok`; `__pycache__ entries in the copy: []` (the exercise copy holds 23 files, 6 dirs; full find listing in the log).
- Observation, not a failure: `ID.fingerprint` returned "gate fingerprint incomplete", `cmd_lab would REFUSE here`, the only unrecorded part being `repo_untracked`: in this clone `build` and `p4_proxy/venv` are symlinks to the shared repo, which `.gitignore`'s `build/` and `p4_proxy/venv/` do not match, and `file_sha()` returns None for them. In a real checkout they are ignored directories [inferred, not verified on a real checkout].
- With bytecode on, the imports wrote six `__pycache__` dirs in the gate clone (listed in B_8_clone_pycache_removed.txt: p4_proxy/mininet, p4_proxy/proxy_agent, tools/p4_exercise, tools/p4_health, tools/p4_health/cells, tools/p4_health/collect) — none in the S0 exercise copy. Those six were removed afterwards; the clone stayed tracked-clean at M2; no new .pyc in the shared venv. The run dir was under S (deleted).

## Stage C: Cut C's gate set (20:39:52–22:50:49, 2 h 10 min 57 s, 0 red)
Step order as p4-ternary-replay-c/r2/driver.sh; TMPDIR under S; p4lane and klane through the patched ci-r2.sh; S0 via s0_run.sh (run dir E/s0-run); trial via p4-ternary-replay-c/r5's trial_run.sh / trial.py / trial_boot.py.

| Step | Log | Result | rc | Wall |
|---|---|---|---|---|
| mutate_table_journal | mutate_table_journal.log | 193 mutations, 0 survived | 0 | 2095 s |
| mutate_table_entry | mutate_table_entry.log | 79, 0 survived | 0 | 401 s |
| mutate_table_entry_owner | mutate_table_entry_owner.log | 27, 0 survived | 0 | 82 s |
| mutate_p4_rule_install_time | mutate_p4_rule_install_time.log | 27, 0 survived | 0 | 17 s |
| mutate_roles_binding | mutate_roles_binding.log | 194, 0 survived | 0 | 2760 s |
| mutate_p4_exercise_tools | mutate_p4_exercise_tools.log | 37, 0 survived | 0 | 82 s |
| mutate_rule_journal_is_wired | mutate_rule_journal_is_wired.log | 14, 0 survived | 0 | 12 s |
| mutate_app_package | mutate_app_package.log | 48, 0 survived | 0 | 240 s |
| mutate_telemetry_by_name | mutate_telemetry_by_name.log | 23, 0 survived | 0 | 275 s |
| mutate_p4_priority_refusal | mutate_p4_priority_refusal.log | 9, 0 survived | 0 | 5 s |
| mutate_p4_probe | mutate_p4_probe.log | 6, 0 survived | 0 | 4 s |
| mutate_l1_shell_scoring | mutate_l1_shell_scoring.log | 62 killed, 0 survived | 0 | 575 s |
| test_l1_shell_scoring | test_l1_shell_scoring.log | Ran 165 checks, 0 failed | 0 | 10 s |
| check_test_tmpdirs | check_test_tmpdirs.log | (no output) | 0 | 1 s |
| check_gate_anchors | check_gate_anchors.log | 137/137 cells ok | 0 | 3 s |
| p4lane | p4lane.log | FAILURES=0 | 0 | 122 s |
| klane | klane.log | FAILURES=0 | 0 | 804 s |
| no_stray_table_journal | no_stray_table_journal.log | one process (2086 tests) and 50 files one by one; the checkout's journal is as it was | 0 | 77 s |
| dot_run_after | dot_run_after.log | p4_proxy/.run does not exist | 0 | 0 s |
| p4h.cells.py312 / .py38 | p4h.cells.py312.log, p4h.cells.py38.log | Ran 203 OK | 0 | 4 s |
| p4h.collect.py312 / .py38 | p4h.collect.py312.log, p4h.collect.py38.log | Ran 192 OK | 0 | 3-4 s |
| p4h.recover | p4h.recover.log | Ran 163 checks, 0 failed | 0 | 40 s |
| p4h.gate_scripts | p4h.gate_scripts.log | Ran 79 checks, 0 failed | 0 | 5 s |
| extra: `python -m unittest tests.python.test_p4_health_cells` from the repo root | p4h.cells.unittest_root.log | Ran 203 OK | 0 | 4 s |
| s0 | s0.log | S0 verdict (s0-run/s0.json): COMPLETE; post-scan no leftovers | 0 | 114 s |
| trial-final | trial-final.log | ALL CHECKS PASS; post-scan no leftovers | 0 | 111 s |
| journal_tests_seen_red | journal_tests_seen_red.log | tests: 218, seen red: 218, never seen red: 0 | 0 | 1 s |

## Stage D: the four-shard health gate (22:50:49–06:33:01, 7 h 42 min 12 s)
chain_mut.sh copy; each shard through shardwrap.sh, which logs `grep -E '^Sig(Blk|Ign)' /proc/self/status`, requires `SigBlk & 0x4203 == 0`, then execs `env MUT_SHARD=k/4 bash tests/shell/mutate_p4_health.sh`. PYTHON unset; shards sequential; 21600 s timeout kept; guard + procscan before each shard. All four interpreter lines identical: `interpreter: /home/adam/miniconda3/envs/ryu-env/bin/python3.8 (3.8.20, prefix /home/adam/miniconda3/envs/ryu-env)`.

| Shard | Summary | rc | Time |
|---|---|---|---|
| 0 | 130 mutations, 0 survived (SHARD 0/4 of 517) | 0 | 22:50:49–00:50:22 |
| 1 | 129 mutations, 0 survived | 0 | 00:50:22–02:44:42 |
| 2 | 129 mutations, 0 survived | 0 | 02:44:42–04:38:43 |
| 3 | 129 mutations, 0 survived | 0 | 04:38:43–06:33:01 |

Signal lines, identical in all four shard logs (lines 3-9): child SigBlk 0000000000000000, child SigIgn 0000000000000000; the exec'ing process SigBlk 0000000000010000 (SIGCHLD only), SigIgn 0000000000000004 (SIGQUIT ignored); `env PYTHON*: PYTHONDONTWRITEBYTECODE=1` (inherited from the session environment, as in earlier gates).
GATE.log as quoted at the top. The tree fd872b3d is tools/p4_health at M2. Still to do when the squash exists: record that the squash commit's tools/p4_health tree equals fd872b3d.

## Deviations (as reported by the worker)
1. While checking `python3 -m venv --without-pip`, a venv was created by mistake at wt-p4-health-locale/tools/nonexist/ (relative path from the session cwd); it was read, confirmed fresh, and removed; that worktree's `git status` was clean before and after (orchestrator re-checked: clean, no `nonexist`).
2. p4build.log written by mkclone.sh in C2's format, not via runlog (runlog hashes build outputs that did not exist yet).
3. ci-r2.sh copy: HOME and RUNNER_TEMP under S/fakehome; TMPDIR added to its `env -i` list.
4. The second merge was made with `--no-commit`, resolved, then committed with the given message.
5. Stage B used L3's runlog.sh, Stage C C2's (both unchanged copies).
6. PYTHONDONTWRITEBYTECODE=1 was in the session environment: every step except B8 ran with bytecode writing off (runlog sets it; shards inherited it). No shard evidence with bytecode writing on.
7. A per-step watchdog (2x expected time, stop by session) was added; never fired. It cannot reach the inner sessions s0_run.sh / trial_run.sh create (known limit).
8. Stage B log names carry a `B_<n>_` prefix.
9. A guard before each shard was added inside the chain_mut.sh copy.
10. The exec'ing process's SigBlk shows 0x10000 (SIGCHLD); the child sees 0; both & 0x4203 = 0.
11. Script copies vs sources: copied-script-diffs.txt. New scripts: mgrun.sh, mexec.sh, stopsess.sh, shardwrap.sh, s0_frozen_run.sh; rewritten: guard.sh, mkclone.sh; reference copies only (not run): c2_driver.sh, l3_driver.sh, unit.sh.
12. This file was written by the orchestrator.

## State after the run
S/gate kept (HEAD M2, tracked-clean); S/tmp emptied; merge worktree removed; no other clones. `merge/trunk-1015` = d92bf1a2; `trunk` untouched (a7e6288f). Nothing pushed. Free space on / after the run: about 3939 MB.
