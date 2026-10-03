# JUDGE: N7 round.env 7b4a48b9

**Verdict: MERGE AFTER FIXES.** There are 3 blocking findings and 7 notes.

Path prefixes used below (all absolute):
- W = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-round-env-0927 (the head, 7b4a48b9)
- M = /home/adam/Desktop/NDTwin-Kernel (the base fed37cff, and also the tree the lab runs)
- L = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/n7-logs
- S = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/N7-ROUND-ENV-SUMMARY.md

I only read files; nothing was executed. Statements about shell behaviour come from reading the code.

**What holds up:**
- The edit is exactly the stated one-liner: E round.env:13 and F5 round.env:14. Comparing base and head, the three modified files differ only there and at W/tests/shell/test_gate_exit_code_not_tee.sh:39-44. Line counts are unchanged (100, 83 and 206), so E round.env:23 is still `PRIOR`.
- `../../..` is correct for both files.
- Every real consumer sources the file by absolute path (`$HERE/round.env`): gates_e.sh:37, run_e.sh:37, build_1khz_binary.sh:43 and run_f5.sh:25. Each skips it when ROUND is already set.
- Every gate number in S appears in a log.

## Blocking

**B1. Live E/F5 runs from any tree other than M now split between that tree and consumers that stay fixed to M. S §4 (lines 76-80) does not disclose this.**

Before the fix, every path pointed at M, which is the same tree the root lab helper uses. After the fix, a run from a worktree behaves as follows:

- **(a) Cells are written to M but read from W.**
  - `$PRIOR/measure.sh` is called at run_e.sh:137 and gates_e.sh:430. It still writes to a fixed `REPO=/home/adam/Desktop/NDTwin-Kernel` (W/doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh:24-26).
  - `archive_cell` reads `$PRIOR_RAW`, which is now in W, and skips missing files silently (lib_e.sh:1324-1326).
  - `cell_verdict.py` finds its raw directory relative to its own location (W/doc/audit/2026-08-25_sampling-rounds/cell_verdict.py:31-35, then W/doc/audit/2026-08-20_sampling-rate-and-cpu/plot_figures.py:45,49).
  - As a result, run_e.sh:159-173 writes NO-DATA rows and carries on. Only the load gate at gates_e.sh:453 would stop this, and run_e.sh does not require the gates to have run.
  - S:22-23 notes that live runs use measure.sh, but not this consequence.
- **(b) The P4 program the round compiles is not the one the switches load.**
  - `compile_at` edits and compiles W's `$P4SRC`/`$P4BUILD` (lib_e.sh:836-851).
  - `ndtwin-lab topo-start` starts the bridge from its own KERNEL_DIR, which defaults to M because /etc/ndtwin-lab.conf is absent (/usr/local/sbin/ndtwin-lab:98,103,312,1663-1669).
  - That bridge loads `<lab tree>/p4_proxy/p4_src/build/ndtwin_switch.json` (W/p4_proxy/mininet/p4_testbed_topo.py:327-338,355; W/p4_proxy/mininet/app_package.py:117).
  - `assert_truncate_128` and `compiled_rng` check W's JSON (lib_e.sh:825-834 and 940-958). Their premise, "that is what bmv2 loads" (lib_e.sh:825-827), no longer holds.
  - The emitter takes `sampling_rate` from the switch's packet-in metadata (W/p4_proxy/proxy_agent/sflow_emitter.py:585). The data therefore stay self-consistent, and every rung would silently measure whatever rate M has compiled.
- **(c) State that belongs to the whole machine is now per-tree.**
  - The LAB-NOT-RESTORED reader globs `$KERNEL_DIR/doc/audit/*/raw/` (lib_e.sh:365), and F5 writes the marker under `$ROUND/raw` (run_f5.sh:366,376). A marker left by a run in another tree is now invisible, so the check passes when it should refuse.
  - The claim file is `$KERNEL_DIR/.test_run/lab.claim` (lib_e.sh:280, run_f5.sh:383, build_1khz_binary.sh:64). `ndt` writes `$REPO/.test_run/lab.claim`, with REPO taken from its own resolved location (W/tools/test_workflow/ndt:53-54,341).
  - If the claim was made with M's `ndt`, the round refuses loudly (lib_e.sh:292-297). If it was made with W's `ndt`, the round now accepts a claim that M's registry does not show. Before the fix it refused that.
- **(d) F5's traffic child goes back to M.**
  - run_f5.sh:533-541 runs traffic_mesh.sh, which at line 35 sources a third round.env.
  - That file still does `export KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel` and runs `mkdir -p "$OUT"` inside M (W/doc/audit/2026-08-30_live-traffic-round/harness/round.env:18,31-32).
  - S does not mention this file.
- **Counterweight, also not disclosed.** Before the fix, a live run from a worktree edited M's tracked files. After the fix these land in W:
  - `sed -i` on the P4 source (lib_e.sh:838-839)
  - `cp -f` over the kernel binary (lib_e.sh:887)
  - `git checkout --` of M's FlowLinkUsageCollector.hpp (build_1khz_binary.sh:182)

**Required fix, one of:**
- In live mode (DRY_RUN≠1), have lib_e.sh preflight and run_f5.sh preflight refuse when `$KERNEL_DIR` is not the tree reported by `sudo -n ndtwin-lab config`.
- Or get an explicit ruling that live E/F5 runs happen only from M, and write it into both round.env headers.

In either case, S §4 must list (a)-(d).

**B2. test_cell_gate_suspect_wiring now passes silently (SKIP, exit code 0) in any worktree or clone that lacks a hand-made venv.**
- `PY_PROXY="$KERNEL_DIR/p4_proxy/venv/bin/python"` (E round.env:63) cannot be overridden, and it now resolves inside the tree.
- The venv is ignored by git (M/.git/info/exclude:30), so `git worktree add` or a fresh clone has none.
- The suite sources round.env (test_cell_gate_suspect_wiring.sh:62) and then prints `SKIP … exit 0` when PY_PROXY is missing (:74-77).
- Before the fix it ran all 13 checks from any worktree on this machine, using M's venv (L/prefix2.test_cell_gate_suspect_wiring.main-paths:1-14).
- P1's 13/13 (L/P1-observe-postfix.log:17,34) exists only because W has a hand-made `p4_proxy/venv` symlink to M (L/observe.sh:30-31; S:56; W/p4_proxy/venv/pyvenv.cfg:5 points at M's venv).
- Its gate would refuse (tests/shell/mutate_cell_gate_suspect_wiring.sh:65-70), but the suite on its own reads green. This is one of the two suites the fix exists for.
- **Fix:** make a missing interpreter a failure (or a non-green skip), or honour `${PY_PROXY:-…}`. Then show a run from a worktree without the symlink.

**B3. The `:?` guard does nothing useful, and S:19's claim about it is contradicted.**
- `${BASH_SOURCE[0]:?…}` sits inside two nested command substitutions (E round.env:13, F5 round.env:14).
- When it fails, only the innermost subshell exits. Cases that trigger it:
  - bash with an empty BASH_SOURCE, e.g. `bash -c "$(cat round.env)"`
  - shells without BASH_SOURCE
  - dash, which raises "Bad substitution" for `[0]` at expansion time
- The outer `cd "/../../.." && pwd` then succeeds, so:
  - KERNEL_DIR becomes `/`
  - ROUND becomes `/doc/audit/…`
  - `mkdir -p /doc/… /.test_run/…` runs (EACCES as a normal user; it would create those directories at `/` as root)
  - sourcing continues.
- So it prints one line to stderr, but it does not fail, and it does derive a wrong tree.
- The suite only ever uses `bash -c` (test_round_env_kernel_dir.sh:57-65). No mutation touches the guard, so removing it would survive.
- **Fix:** add a guard at top level, before the line (for example `[ -n "${BASH_VERSION:-}" ] || { echo … >&2; return 1; }`), add a suite case that sources with `sh`, and add a mutation. Or drop the claim.

## Notes (non-blocking)

**N1. An inherited KERNEL_DIR silently points the two consumer suites back at M.**
- round.env exports KERNEL_DIR, and its documented use is to source it into a shell (E round.env:5; F5 round.env:5-6). harness/round.env:18 exports M.
- Neither suite unsets KERNEL_DIR before sourcing (test_gate_exit_code_not_tee.sh:71-77; test_cell_gate_suspect_wiring.sh:58-62). From such a shell, N7 comes back.
- The new suite removes the variable itself (`env -u KERNEL_DIR`, :57), so it cannot see this.
- The new comment at test_gate_exit_code_not_tee.sh:42-43 ("the tree under test is the tree this suite runs in") holds only when nothing is inherited.
- Fix: `unset KERNEL_DIR` in both suites, plus a case that covers it.

**N2. CDPATH.** The documented form, `. doc/audit/<round>/round.env`, is a relative path without `./`, so `cd` consults CDPATH. When a non-empty CDPATH entry matches, bash prints the directory, and that output lands inside `$(…)`. Fix: `CDPATH= cd -- … >/dev/null`. This form is untested; components.env:16 has the same pattern.

**N3. Symlinks.** If round.env is sourced through a symlink located elsewhere, KERNEL_DIR is three levels above the link, not the target. Untested. `ndt` uses `readlink -f` (ndt:53), so the repo now has two conventions.

**N4. The suite covers less than its header claims (:17-20).**
- "Every path it exports" is really the fixed lists E_VARS/F_VARS (:79-81). LOG and PY_PLOT are not in them, and any new export would go unchecked.
- An inherited CPU_BASELINE_FILE (honoured at E round.env:91, not removed at :57) produces a false red.
- For the current files, the mkdir shim does stop every write: besides `mkdir`, round.env only runs `cd`, `dirname`, `pwd`, `unset`, `export` and `case` (no cp, no python). But a `command mkdir` or `install -d` would write for real without being seen.

**N5. Mutation gate.**
- The 8 mutations are realistic wrong fixes: revert to the fixed path, derive from cwd, one level short or long, ignore the override, one fixed export, one fixed mkdir.
- Gaps:
  - no F5 versions of M2/M4/M5/M6 (F5 sensitivity is shown only by the red-first run)
  - no `$0` or `BASH_SOURCE[1]` variant
  - nothing touches `:?`
- The control C1 (:174-180) only shows the suite is not comparing bytes, which nothing in it could be. A rewrite that keeps the behaviour (e.g. `cd -P`) would be a meaningful control.

**N6. The "about 40 one-off round scripts" claim (S:25) has no list in L, and "no live code runs them" is inaccurate.**
- Within reach of the E-round suites there is no other fixed path. recompute_rate.py:138 is overridden at lib_e.sh:1283, and nothing runs overlap_bands.py:61.
- But live test and gate code outside round scripts carries the same literal:
  - W/tools/test_workflow/test_topo_model_guards.py:16-20
  - W/tests/shell/mutate_a7_dispatch_status.sh:56
  - W/tests/shell/mutate_p4_priority_refusal.sh:42
  - W/tests/shell/mutate_ovs4_has_sflow.sh:50
  - W/tests/shell/test_ndtwin_lab_heartbeat.sh:48
- Plus the third round.env (B1d).

**N7. The cell wrappers never exit non-zero.** L/post.sh:7-13, observe.sh and lint.sh ignore suite failures: for example, B2 reports `exit 0` (line 48) even though its line 47 shows rc=1. S reads the per-line return codes correctly, but a cell's `rc=0` is not a verdict.

## Claims vs evidence

| Claim | Class | Evidence |
|---|---|---|
| 18/24 red on fed37cff | SUPPORTED | L/A1b-new-suite-prefix.log:1 (head fed37cff), :93. The 6 green are the self-checks (:32,33,52,71,72,91). Independently shown at L/B-observe-prefix.log:47, L/B2-observe-prefix.log:47 and L/prefix2.plain.test_round_env_kernel_dir.out:90 |
| 24/24 on head | SUPPORTED | L/P1-observe-postfix.log:1,39; L/postfix.plain.test_round_env_kernel_dir.out:28; L/post.mutate_round_env_kernel_dir.out:2 |
| First pre-fix run discarded (shim output swallowed) | SUPPORTED | L/A1-new-suite-prefix.log:28-31: the directory check passes vacuously and the self-check shows actual `[0]` |
| The `are: command not found` line in the A1 log | UNDER-EVIDENCED | No file in L contains it. The A1 log instead holds two full runs (:3-93 and :94-185), which fits the explanation |
| mutate_round_env: 8 mutations, 0 survived, control green | SUPPORTED | L/P2-gates-postfix.log:4; post.mutate_round_env_kernel_dir.out:4-15 |
| mutate_gate_exit_code: 6 mutations, 0 survived | SUPPORTED | P2:5; post.mutate_gate_exit_code.out:15 |
| mutate_cell_gate_suspect_wiring: 0 survivors | SUPPORTED (only with W's venv symlink, see B2) | P2:6; post.mutate_cell_gate_suspect_wiring.out:5-13 (6 caught) |
| mutate_log_suffix_idempotent: 7 mutations, 0 survived | SUPPORTED | P2:7; post.mutate_log_suffix_idempotent.out:16 |
| Anchors 245/246 | SUPPORTED | P2:8; post.check_gate_anchors.out:114 (`absent` at base, `ok(9)` at head) and :132. That is 123 gates × 2 revisions |
| 6 existing suites green before and after | SUPPORTED as numbers, weak as evidence | B2:41-46 vs P1:33-38. Only 2 of the 6 source round.env (:77, :62). The other 4 export ROUND and skip it (test_iperf3_guard.sh:62, test_e_restore_asserts_compiled_artifact.sh:53, test_ep4_gate_and_abort_evidence.sh:42) or only grep it (test_log_suffix_idempotent.sh:189-190). The post-fix 13/13 depends on the symlink (B2) |
| Lint return codes 0 | SUPPORTED | L/L1-lints.log:4-6 |
| Lint file count went 338→340 | UNDER-EVIDENCED | No pre-fix lint log |
| strace: mkdir moved from M to W | SUPPORTED | L/prefix2.test_gate_exit_code_not_tee.mkdir:1 and prefix2.test_cell_gate_suspect_wiring.mkdir:2, vs postfix.*.mkdir:1 and :2 |
| "Only effect from round.env was the mkdir"; "venv paths not from round.env" (S:52,56) | CONTRADICTED (true for writes only) | Before the fix, PY_PROXY (round.env:63) made the suite execute M's venv python: prefix2.test_cell_gate_suspect_wiring.main-paths:1-14; B2:32-39 (18 execve calls) |
| wt-audit-raw had only chdir/stat | UNDER-EVIDENCED | P1:9-12 also counts 2 openat and 15 readlink, and that tally (.observe.run2.sh:37) does not exclude the venv paths that the path list excludes |
| measure.sh:24 left unchanged; no suite runs it | SUPPORTED | Reason given at round.env:16-22; no suite executes measure.sh. The consequence was not analysed (B1a) |
| recompute_rate `--klog` default is safe | SUPPORTED | lib_e.sh:1282-1283 passes it explicitly |
| About 40 one-off scripts, no live code runs them | UNDER-EVIDENCED | No list in L; counterexamples in N6 |
| `:?` makes non-bash shells fail loudly | CONTRADICTED and UNTESTED | See B3 |
| Commit touches only the 5 files | UNDER-EVIDENCED | No `git show --stat` in L. L/apply_fix.py:9-27 contains only the 3 edits. I cannot list the commit's files without git |
| Worktree clean after the gates | SUPPORTED | P2 has no "after gates" lines (post.sh:13) |

## Tests I would have run
1. `sh -c '. <planted copy>/round.env; echo "[$KERNEL_DIR]"'` with mkdir shimmed. By my reading it prints `[/]`.
2. Both consumer suites from a `git worktree add` without the venv symlink. I expect SKIP with exit code 0.
3. Both consumer suites with `KERNEL_DIR` exported to M, or run after sourcing M's round.env in the same shell. I expect the mkdir arguments to land in M again.
4. The documented relative source with CDPATH set; a symlinked round.env.
5. Dry-run transcripts (`run_e.sh plan`, the gates_e.sh dry run, `run_f5.sh selftest`) from W and from M, comparing the paths each names: PRIOR_RAW, P4BUILD, the claim file and the marker glob.
6. Live `preflight plan` from W, to confirm the claim refusal is the first thing that stops it.
7. A control that rewrites the line in a behaviour-preserving way.
8. `git show --stat 7b4a48b9` saved into L.

## Internal inconsistencies
- S:42-45 cites B2 for the "before" mkdir values, but B2's own log shows empty mkdir sections (L/B2-observe-prefix.log:12 and :40). The cause is .observe.run.sh:36 `grep -vE '^-'`, which drops every shim line because each one starts with `-p`. The raw .mkdir files do carry the claim; the empty sections are not disclosed.
- S:61 says every cell had a 1.5 GB floor for non-build cells. The frozen copy .cell.run.sh:13-16 has no such floor, and cell B ran at 2323 MB with the unfrozen observe.sh (B-observe-prefix.log:1-4).
- Cells A1 (00:21:48–00:38:33) and B (00:35:48–00:37:30) overlap in time. This does not affect any number.

## Discipline
- **Co-developed tags:** present in both new files (test_round_env_kernel_dir.sh:4, mutate_round_env_kernel_dir.sh:6). The edited lines rely on the file-header tags only (E round.env:11, F5 round.env:12, test_gate_exit_code_not_tee.sh:5). Other dated edits in those files carry an inline tag (E round.env:26; test_gate_exit_code_not_tee.sh:27,35), so this is a cosmetic inconsistency.
- **pkill / pgrep:** neither appears in the new files.
- **Temp directories:**
  - Both new files use `mktemp -d` with an EXIT trap (:38-39 and :33-34).
  - The mutation gate never writes the real round.env: `apply_exact` only writes its destination copy, and the sha guard sits at :35 and :183-186.
  - check_test_tmpdirs reports 0 fixed temp paths (L1-lints.log:5-6).
  - The observe PATH shim runs the real mkdir (L/observe.sh:15). So P1 really created W/doc/audit/2026-08-31_sampling-ceiling-after-merge/raw and W/.test_run/binaries/e-round (both gitignored), and B2 ran the same mkdir in M, where both directories exist now.
- **Only 5 files touched:** not verifiable read-only (see the table).

**Re-review ask:** after B1–B3, re-run the new suite and both consumer suites from a worktree without the venv symlink and with an inherited KERNEL_DIR, and include the `sh` case.
