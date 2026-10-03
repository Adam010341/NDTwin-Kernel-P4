# JUDGE: suite TERM trap 85befc7d

**Verdict: MERGE.** The trap change is correct bash, and it covers every suite in tests/shell and tools/ that keeps a privileged fake on PATH inside a directory its handler deletes. The red-first really shows base running on past a deleted stub and HEAD stopping. Every trap4 gate number matches its log. Nothing in the branch needs to change.

One condition at merge time, not a fix to the branch: since fed37cff, trunk has changed `test_live_p1_common.sh` and the comments in `lib_probe_stub.sh`, and nobody has run the merged tree (finding 9). Findings 2, 3, 10 and 11 are follow-ups that do not block the merge.

**Method.** Read-only: Read/Grep/Glob, no git, nothing executed. Statements about bash behaviour come from reading, not running.
- **WT** is the working copy of `…/wt-suite-term-trap-0928`. I assume it equals 85befc7d: the gate driver refuses to run with tracked changes (`gates_trap.sh:18-19,40`), but I could not re-check that without git.
- **trunk** is the shared main checkout's working copy. This is an observation of an uncommitted working tree; the session-start git status showed no tracked changes under tests/.
- Short names: `apps_stop` = `tests/shell/test_apps_stop_kills_the_group.sh`, `app_orphans` = `test_ndt_app_orphans.sh`, `live_p1_common` = `test_live_p1_common.sh`, `lib` = `lib_probe_stub.sh`, `rf` = `scripts-trap4-85befc7d/redfirst_trap.sh`, `KEPT` = `redfirst_trap.trap4-85befc7d.kept/`.
- Line numbers are WT unless marked trunk.

## Findings

**1. Check 1: the bash semantics are correct.** The traps are at apps_stop:209-211, app_orphans:128-130 and live_p1_common:63-65.
- **Signal during a foreground child.** A trapped INT/TERM that arrives while bash waits on a foreground child runs after the child returns.
  - If the whole group is signalled, the child dies first.
  - If only the suite's pid is signalled, the child finishes first. That is seconds here, and at most 120 s for `timeout 120 bash step.sh` at live_p1_common:815, which runs in timeout's own process group.
- **`wait` builtins** (apps_stop:259, :322) return at once and the trap runs.
- **Exit path.** `exit N` runs the EXIT trap once: bash disarms the EXIT trap before running it. The status stays N because the cleanups `return` rather than `exit`; HEAD's 143/130 is observed.
- **Base ran cleanup twice.** It ran once as the TERM handler and again at EXIT: KEPT/base-TERM-test_apps_stop_kills_the_group.out:173-174 shows `groups: No such file`.
- **No path found where a signal lets the suite continue:**
  - None of the three suites uses `set -e`.
  - There is no `trap` command in ndt, ports.sh, sudo_surface.sh or components.env, so re-sourcing ndt at apps_stop:336 and :363 cannot re-arm anything.
  - ndt never runs sudo through `timeout`, `env`, `setsid` and the like, so function stubs cannot be bypassed that way.
  - apps_stop:132, :373 and live_p1_common:811 are heredoc fixture text.
  - `_common.sh` arms `trap finish EXIT INT TERM` (_common.sh:298), but it is only sourced in `bash -c` children (live_p1_common:208, :1019, :1070) or in a `( )` subshell (trunk :1171).
  - Subshells reset caught traps, so a group signal kills them and the parent then exits.

**2. Minor, optional: cleanup runs "at most once", not "exactly once".**
- A second INT/TERM during cleanup runs `exit` inside the EXIT trap and cuts it short. Nothing continues; at worst a temp dir or fixture leaks (fixtures self-reap after their TTL). Hardening: make `trap '' INT TERM` the first line of each cleanup.
- These cases are safe and unchanged by the branch:
  - A signal between `probe_stub_install` and the traps (apps_stop:82→209, app_orphans:86→128) kills the shell without cleanup.
  - If INT was ignored on entry, the INT trap is a no-op and the stubs stay in place.

**3. Minor, optional: `exit 130` defeats bash's wait-and-cooperative-exit.**
- A bash driver running the suite in the foreground sees a normal exit, not a death by SIGINT, so on Ctrl-C it moves on to the next suite. This is not a regression; the old code continued too.
- Re-raising fixes it: `trap 'trap - INT; kill -INT $$' INT`. TERM has no equivalent issue.

**4. Check 3: the red-first is valid but narrower than it reads.**
- **Injection points** (rf:80-82; the anchor must occur exactly once, rf:43). In each case the stub and both traps are already in place, in both trees:
  - apps_stop: before `# start_app` (HEAD :213, base :206).
  - app_orphans: before `# spawn_fixture` (HEAD :132, base :125).
  - live_p1_common: after `export PATH="$NOLAB/bin:$PATH"` (HEAD :135, base :128).
  - The signal goes to the suite's own process group, and INT/TERM are reset to their defaults first (rf:56-59).
- **Base ran on:**
  - apps_stop: `Ran 72 checks, 37 failed` (KEPT/base-TERM-…apps_stop….out:172).
  - app_orphans: `Ran 104 checks, 45 failed` (…app_orphans.out:237).
  - live_p1_common: `Ran 169 checks, 83 failed` (…live_p1_common.out:381).
  - The recorders hold 8, 16 and 0 lines of `sudo -n /usr/local/sbin/ndtwin-lab status`, for both TERM and INT.
- **HEAD:** all six `.out` files are empty, all recorders are empty, rc is 143/130 (trap4 log :13-37).
- **Weakness 1: the HEAD rule cannot tell a trapped exit from a signal death.** The rule (rf:74, `rc==want && n==0`) also passes a suite that simply died of the signal: trap1 marked HEAD rows ok where no trap was installed yet (trap1 log :14-15, :18-19, :24-25, :28-29).
  - Two things actually show HEAD left through `exit 143`:
    - base, at the same anchor, visibly had its handler installed;
    - trap4 prints no bash `Terminated` notice, whereas trap1 prints one for every signal death (:10, :13, :20, :23).
  - The report does not cite that second point, and INT has no such discriminator.
- **Weakness 2: never exercised.**
  - A signal sent from outside while the suite is blocked in a child.
  - A signal sent to the pid only.
  - Any evidence that HEAD's cleanup actually ran: nobody checked that `/tmp/ndt-appsgroup-*`, `/tmp/ndt-app-orphans-*` or `$TMPDIR/live-p1-common-*` are gone.
- **Weakness 3: live_p1_common's criterion was relaxed after trap1 without saying so.**
  - In trap1 its injection point was already the one used later (trap1 script :73), and both base rows were BAD for "0 calls" (trap1 log :30-31, :34-35).
  - trap2/trap4 added `need_calls=no` for that row (rf:67-71, :82).
  - The summary attributes trap1's BAD only to the injection point, which is true for apps_stop and app_orphans. For live_p1_common, the red is "ran on" only.

**5. Report error: "109 checks" for app_orphans.** The suite itself says 104 (…app_orphans.out:237). The harness's `grep -cE '^ *(ok|FAILED) '` (rf:63) also counts five `FAILED fixture never took argv0` lines (out :3, :5, :7, :85, :106), which gives 109.

**6. Report error: half of §4's 【讀】 (read) note is contradicted.**
- The note says live_p1_common's lab calls are "in the section before the stub was deleted". The stub is deleted right after :135, before section 1, so no such section exists.
- The real reason is the other half of the note: `drive()`'s shell-function stubs (live_p1_common:201-204).

**7. Check 4: P12 and P8.**
- **P12** (mutate_probe_stubs.sh:233-236) is killed on its named text: `(4 escaped; … actual: 1 NO STUB: the stub was installed and is gone (…)` (mutate_probe_stubs.trap4 log :33). `mutant_rule` matches against the untruncated `why` (:114-117).
- **P12 genuinely guards the new branch.**
  - With the base lib, the same mutation prints `NO STUB: probe_stub_install never ran` (trap4 log :40, KEPT/base-gone.out:15), so P12 would survive.
  - With lib:130-132 deleted, the check falls through to `the sudo on PATH is …` plus a read error, so P12 would also survive.
- **P8 is unchanged.** With `PROBE_STUB_LOG` unset, lib:125-127 prints `NO STUB: probe_stub_install never ran`, and P8 is caught on "NO STUB" (log :31).
- The only consumers of either string are mutate_probe_stubs.sh:217 and :236.

**8. Check 2: coverage.**
- My grep reproduces the summary's set exactly, and trunk has the same set; only test_ndt_ovs_topo_script moved, :84 → trunk :100.
- In tools/, only two scripts trap INT/TERM:
  - `tools/remote-lab/host_witness.sh:327` already has the right shape (`…; exit 143`).
  - `tools/test_workflow/supervise.sh:62-64` forwards signals; it is not a suite.
  - Nothing outside doc/ and scratch/ has the shape.
- **None of the 22 suites has a privileged fake on PATH inside the directory its handler deletes, so none can reach real sudo through this defect.** All 22 still run on after INT/TERM and report wrong results.
- **sudo is a shell function**, which `rm -rf` cannot remove:
  - test_ndt_app_package:56 and :1645 (`sudo()` at :221 and :780)
  - test_ndt_apps_liveness:106 (:165)
  - test_ndt_down_claim_guard:54 (:89)
  - test_ndt_down_stops_only_ours:118 (:139)
  - test_ndt_heartbeat:58 (:153)
  - test_ndt_helper_apps_window:117 (:167)
  - test_ndt_ovs_claim:76 (:155). Its fake ndtwin-lab is `LAB=` at :144, not on PATH.
- **Never calls sudo:**
  - test_faults_topo_pid:60 (sudo appears only inside checker fixture strings, :229-290)
  - test_ndtwin_lab_config:64
  - test_ndtwin_lab_heartbeat:87
  - test_ndtwin_lab_sweep:91
  - test_stack_await_convergence:66
  - test_mutate_gate_dead_mutant:65
- **Sets PATH, but not to a privileged fake:**
  - test_ndt_ovs_topo_script:84: `PATH="$NOBIN"` (:283, :293) is an empty seatbelt directory and stays empty if deleted.
  - test_live_p1_thirteen:53: `env -i PATH=/usr/bin:/bin` (:89, :189) puts the real sudo on PATH by design. But 06_thirteen.sh never calls sudo, and `DRIVER_UNDER_TEST` is set, so there is no fallback (06_thirteen.sh:38).
- **Mutation gates:**
  - mutate_check_process_by_name:71 and mutate_startup_clears_by_pid:82 work on copies in `$BK`; after a signal the run is just wasted.
  - mutate_g6:47, g7:47, g9_cleanup:47, g9_faults:47 and ndtwin_lab_heartbeat:65 mutate a tracked file in place.
    - Their handler restores the file, deletes SNAP and MUT_DIR, and returns.
    - The next mutation is read from the deleted MUT_DIR (g6:143, :176), so I found no path that mutates the file again.
    - The run then ends in a false "restore FAILED" (g6:224).
    - The PATH shim in mutate_ndtwin_lab_heartbeat is a python3 wrapper (:508-512), not a privileged command.
  - So §3's "they only restore files" is under-evidenced as a safety argument.
- **Safe under bash's EXIT-trap-on-fatal-signal behaviour, but never exercised by the report:**
  - the other four lib users: cell_gate:44, lab_handoff:51, honesty:61, sample_rate:33;
  - test_ndt_sudo_surface:43/85, test_ovs4_sflow_verify:48/110, test_harness_instruments:58/81.
- **Out of scope, not checked:** live drivers under doc/audit with `EXIT INT TERM` handlers that may return. Examples: ring_fix_verify.sh:50, ring-edge-fix/phase*.sh, host_curve.sh:70, zero_cell.sh:64, esa-power-off-injection/run.sh:79, boot-ring-summon/*.sh, p4-heartbeat/spike/*.sh.
  - These use real sudo on purpose; a returning handler there keeps driving a lab that has already been torn down. They belong in the separate ticket.
  - live-p1's `finish()` does exit (_common.sh:279, :290).

**9. Check 6 and the merge-time condition.**
- **`lib_probe_stub.sh` merges cleanly and keeps both sides' changes.**
  - The branch changes the header (base :3-4 → WT :3-8) and the closing check (base :121-123 → WT :125-132).
  - Trunk changes the WORDING block (base :26-41 → trunk :26-45) and one install comment (base :78 → trunk :82).
  - The regions are disjoint, with at least 20 unchanged lines between each.
  - Trunk's edit is comments only, so the merged file's only behaviour change is the branch's.
- **Unchanged on trunk:** mutate_probe_stubs, apps_stop (trap still at :204) and app_orphans (trap at :123).
- **Changed on trunk: `test_live_p1_common.sh`.** It gained sections 15, 16 and 18 (trunk :1076-1182). The branch's hunk at :58 is untouched there, so the merge is clean, and the new sections source `_common.sh` only in children or subshells.
  - But the merged suite has never run, and its check count is no longer 169.
  - The merged lib has never run under trunk's ndt_sudo_unread either.
- **Run on the merge commit:**
  - the 7 stub/trap suites;
  - mutate_probe_stubs, mutate_apps_stop_kills_the_group, mutate_live_p1_common, mutate_redirection_order, check_gate_anchors;
  - rf, with BASE set to the merge's first parent (it is hard-coded to fed37cff at rf:19). Its anchors still occur exactly once on trunk: :206, :125, :128.

**10. Follow-up: nothing in the repo guards the trap property.**
- The red-first lives only in scratch, and P12 guards only the diagnostic message.
- The lib's new rule (lib:6-7, "must exit on INT and TERM") is not enforced. Reverting any of the three traps, or copying the old pattern into a new stub suite, turns nothing red.
- Two ways to close this:
  - a static check that flags `trap <handler> … INT|TERM` without an `exit`, in files that source the lib or put a temp dir first on PATH;
  - or move rf into tests/shell as a gate.

**11. Pre-existing, not caused by the branch.**
- FIX10 (:782; trunk :775) and trunk's FIX15, FIX16 and FIX18 sit outside the EXIT trap and leak on a signal.
- Two checks go vacuous once their directory is gone:
  - apps_stop's "this suite leaked no fixtures" (KEPT base out :167-168);
  - live_p1_common's "NOTHING reached for sudo…" (:378).

**12. Cosmetic.**
- live_p1_common's new comment says its "next sudo went to whatever sudo came next on PATH". No such call was observed, because its normal paths go through the function stubs.
- Some new comment lines exceed the ~100-column style: apps_stop:205, app_orphans:124, live_p1_common:59.

**13. Under-evidenced or not verifiable read-only.**
- **"This machine has NOPASSWD, so it reaches root":** no sudoers or `sudo -l` output is quoted. The calls that actually escaped were read-only verbs (`status`, `topo-out 400`).
- **1 commit, commit-message style, and "no push/merge/sudo/lab":** these need git. Tripwire 0 covers only PATH-level lab calls during the gates.

## Check 5: gate numbers (all SUPPORTED)

In every trap4 log, line 1 is `85befc7db18b0a215703f6f41f8d33689c24ea70` and the last line is `# rc=0`.

| gate | result | log line |
|---|---|---|
| redfirst | ALL AS EXPECTED | :46 |
| check_gate_anchors | 122/122 | :137 |
| check_test_tmpdirs | 388 files / 0 fixed temp paths | :9 |
| test_l1_shell_scoring | 113/0 | :141 |
| apps_stop | 72/0 | :91 |
| app_orphans | 104, all passed | :124 |
| live_p1_common | 169/0 | :201 |
| cell_gate | 13/0 | :23 |
| lab_handoff | 19 | :30 |
| honesty | 346/0 | :460 |
| sample_rate | 7/0 | :16 |
| mutate_probe_stubs | 15/0 | :43 |
| mutate_apps_stop | 13/0 | :27 |
| mutate_live_p1_common | 45/0; 4 controls, 0 red | :301 |
| mutate_redirection_order | 22/0 | :36 |
| mutate_cell_gate | survivors=0, harness-errors=0 | :21 |
| mutate_ndt_honesty | 67/0 | :81 |
| mutate_live_cells | 35/0; 3 controls, 0 wrongly caught; 16 fixture checks, 0 failed | :130 |
| mutate_sample_rate | 3/0 | :16 |
| nolab_tripwire | 0 | :20-21 |
| gates.trap4-85befc7d.result | ALL-AS-EXPECTED, rc 0 | — |

## The summary's verdicts, classified

**§1**
- Handlers delete the stub dir and return: **SUPPORTED** (trunk apps_stop:187-204, app_orphans:118-123, lib:76, :108).
- "NOPASSWD, so root": **UNDER-EVIDENCED**.
- The queued2 OBSERVED claim: **SUPPORTED**.
  - `tripwire.log:2-9` alone cannot establish the cause, because a stub that was never installed produces the same 8 lines.
  - What establishes it is `test_apps_stop_kills_the_group.queued2-01da86bc.log:50-155`: the suite runs on after section 5, prints `NO STUB` and `Ran 72 checks, 27 failed`, runs cleanup a second time (:152-153), and is marked ABORTED by a group SIGTERM (:154).

**§2**
- All four changes, and P8's criterion being unchanged: **SUPPORTED**.

**§3**
- The list is complete for tests/shell: **SUPPORTED**. tools/ was **UNTESTED** by the report, though it is clean on my grep.
- "Don't fix" for the test suites: **SUPPORTED**, as a static read (which is how the report labels it).
- "Mutation gates only restore files": **UNDER-EVIDENCED** (finding 8).

**§4**
- Base runs on, HEAD stops; 8/16/0 calls: **SUPPORTED**.
- "109": **CONTRADICTED** (finding 5).
- live_p1_common: "calls are in the section before the stub was deleted" is **CONTRADICTED**; "or via the `sudo()` shell function" is **SUPPORTED**.
- HEAD "exit 143/130, printed nothing": **SUPPORTED**, but the harness rule alone does not tell a trapped exit from a signal death (finding 4).
- cell_gate "gone" attribution, 4 calls each: **SUPPORTED**.
- "trap1 BAD = harness error": **SUPPORTED** for the apps_stop and app_orphans rows; **UNDER-EVIDENCED** for live_p1_common, because the criterion was changed afterwards (finding 4).
- venv correction (83 failed, 9 venv lines): **SUPPORTED**.

**§5**
- Every gate number: **SUPPORTED**.
- "Matches the orchestrator's 'CI sees the same 78'": **UNDER-EVIDENCED**.
- "ps showed flock waits of at least 43 and 28 min": **UNDER-EVIDENCED**. No ps output is quoted; the cell start times 01:34:01Z → 02:20:02Z are consistent with it.

**Implicit**
- "Cleanup runs once, on the way out": **UNTESTED**. It rests on bash semantics only.

## Tests I would have run
1. **External signal while blocked.** Send TERM/INT from outside, to the pid only and to the group, while the suite sits in a foreground child (for example a hooked `sleep 5` placed after the traps). Assert rc 143/130 after the child returns, zero recorder lines, and TMPROOT/FIX removed.
2. **Proof of cleanup on every HEAD row.** Snapshot `/tmp/ndt-appsgroup-*`, `/tmp/ndt-app-orphans-*` and `$TMPDIR/live-p1-common-*` before and after. Have the EXIT trap drop a marker so a signal death cannot pass.
3. **Double signal during cleanup.**
4. **The other four lib users**, which have EXIT-only traps, under the same harness.
5. **Parent-loop behaviour.** Run a bash driver loop and send SIGINT to the group.
6. **Merge commit.** Everything in finding 9, on the merge commit.
7. **`shellcheck -x`** on the five changed files.

## Places where the report's own numbers disagree
- §4 says app_orphans ran 109 checks; §5 and the suite itself say 104.
- §4's 【讀】 note contradicts the harness's own injection point.
- §4 cites the trap2 log, while §5 names trap4 as the record. The 12 rows are identical in both logs (checked), so no numbers conflict.
- §3's line numbers are fed37cff's. On trunk, ovs_topo_script is at :100, and live_p1_common has an extra fixture-heredoc trap at :1092.
- "These 8 are exactly queued2's 8" is the same count and call site, but different events.
- The trap1 account leaves out the live_p1_common criterion change.

## Files
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-suite-term-trap-0928/tests/shell/{test_apps_stop_kills_the_group.sh, test_ndt_app_orphans.sh, test_live_p1_common.sh, lib_probe_stub.sh, mutate_probe_stubs.sh}
- /home/adam/Desktop/NDTwin-Kernel/tests/shell/{lib_probe_stub.sh, test_live_p1_common.sh} (trunk)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/redfirst_trap.trap4-85befc7d.log, redfirst_trap.trap1-85befc7d.log, redfirst_trap.trap4-85befc7d.kept/, scripts-trap4-85befc7d/{redfirst_trap.sh, gates_trap.sh}, scripts-trap1-85befc7d/redfirst_trap.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/test_apps_stop_kills_the_group.queued2-01da86bc.log, scripts-queued2-01da86bc/tripwire.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/*.trap4-85befc7d.log, gates.trap4-85befc7d.result
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/SUITE-TERM-TRAP-SUMMARY.md