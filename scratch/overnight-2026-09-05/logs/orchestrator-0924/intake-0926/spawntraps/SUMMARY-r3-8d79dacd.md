DELIVERED 8d79dacd0e40e9ddd20d7c8e9af6185b4ef8e482

Branch `fix/spawn-helper-traps-1001`, worktree `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001`. Head is 8d79dacd, porcelain 0. Nothing pushed or merged. The old tip is kept as `refs/heads/backup/spawn-traps-1001-pre-reword`.

Logs are in `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/` (L below). This round's runs are in `driver4.log` and `driver5.log`, with trees in `trees4.log` and `trees5.log`. Every r4/r5 log has the delivered head 8d79dacd on line 1 and `porcelain-lines: 0` (28 logs). The tripwire stayed at 0.

## Commits (d452d111..8d79dacd)
- 668930a5 `tests/shell: let INT and TERM end the fixture-spawning suites`
- 14c490c3 `tests/shell: hold the spawn helpers to their own shell in the gate`
- c8635940 `tests/shell: bound the signal test and narrow the register comments`
- 4fd73e72 `tests/shell: cover the rest of the SUBSHELL verdict in the gate` (was 055acd84)
- 664500d3 `tests/shell: signal each suite only while a process of its run is alive` (was e0bb7d7f)
- 8d79dacd `tests/shell: signal each suite only while a registered fixture is alive` (new this round, committed as 6e3cae59, then message rewritten)

## Item 5: commit messages
The last three commits were rewritten message-only with `git commit-tree`, keeping the original trees and author:
- 055acd84 → 4fd73e72, tree c61b4c4b on both.
- e0bb7d7f → 664500d3, tree 2d990a7f on both. Its subject now matches what its code checks: a live process of the run.
- 6e3cae59 → 8d79dacd, tree a6d4831c on both. Its body now says the two checks were dropped and a note added.

I scanned all six bodies for the listed words, plus co-authored: 0 hits. The rewrite and the scan are recorded in `notes.log`.

## N1: the premise requires a live pid in the suite's own register
**Change:**
- `SREG` is now set for all seven suites: window `fixtures`, ovs_claim `fixture.pids`, down `spawned.pids`; the other four `fixtures`.
- The wait loop finds the temp tree inside the loop: the candidate whose register lists a live token pid. For /tmp suites, only trees created during this run are candidates.
- The failing check now reads "within Ns, a pid in its own fixture register is alive, the suite still running".

**Red, then green, on the same variant.** The variant is ovs_claim killing its first fixture at once and then running 60 s of `command sleep 0.5`. Those sleeps are processes of the run that are not in its register. `driver5.sh`; `SIGNAL_FIRST_FIXTURE_WAIT=25` (the default is 30).
- **The previous test** (664500d3's tree, `r5-n1-gap-prev-test.log`) accepts the moment: "a process of this run besides the suite is alive" ok at :13 and :22, all 16 checks ok, rc 0. This is the uninformative green.
- **The delivered test** (`r5-n1-gap-head-test.log`) refuses it: the premise FAILED for TERM (:11) and INT (:15), with "1 other process(es) of the run alive" (:13, :17), rc 1.

**First attempt superseded:** `r4-n1-gap-*` used FIRST_WAIT=5, which is shorter than ovs_claim's time to its first fixture (`r4-n1-gap-prev-test.log:13`). That pair shows nothing either way; it is noted as superseded in `notes.log`.

## N2: checks that could no longer fail
- Dropped "a process of this run … is alive when it is signalled" (old :148-149).
- Also dropped "its temp tree is found while it runs", which became just as unfailable once the tree is found inside the loop.
- Both are replaced by one `note` line that names the fixture pids and the register.
- Check count is now 6 per run, 84 for the 14 runs, down from 112.

## N3 and the optional line
- Header :18-28 now describes the register premise.
- One line says that under INT the "no process left" check can only fail for a fixture outside the suite's process group.
- The timing line now gives 23-24 s.

## Your CI headroom addition
- **New defaults:** FIRST_WAIT 30 s, HARD_LIMIT 30 s, TOTAL_LIMIT 150 s. ci.yml is unchanged.
- **Header bound** (:37-45), with your two job durations and their job ids:
  - One run is at most 30 + 30 + about 5 s of /proc scans = 65 s.
  - The whole test is at most 150 + 65 = 215 s, about 3.6 min.
  - 22 min 11 s + 3.6 min = 25.8 min, inside the job's 30.
- **Both bounds seen working:**
  - HARD_LIMIT: `r4-d2-hung-suite.log` shows "killed (SIGNAL_HARD_LIMIT)" at :14 and :36. The two runs took 21:21:55 → 21:23:01.
  - TOTAL_LIMIT: `r4-d2-total-limit.log` shows three skipped runs as FAILED (:18, :21, :24).
- **Effect on the d452d111 red run** (`r4-red-signal-test-d452d111.log`):
  - 74 checks, 18 failed.
  - liveness, sweep, window, topo_pid and ovs_claim are red by rc 1 (:30-:171).
  - down was not reached: the 150 s limit was used up (:180, :183). The run took 21:18:36 → 21:21:27.
  - Run alone (`r5-red-signal-test-d452d111-down.log`), d452d111's down fails the new premise (:11, :15). That code keeps no register file, so it is red by the premise, not by rc. Its rc red is in the earlier logs `red-signal-test-d452d111.log:195/:212` and `r3-red-…:199/:220`.

## Reruns at 8d79dacd (all ran)
**Signal test, green 3/3:**
- "Ran 84 checks, all passed", rc 0, in `r4-green-signal-test-head-{1,2,3}.log`.
- Wall times: 21:23:02-21:23:25, 21:23:26-21:23:48, 21:23:48-21:24:11. That is 23, 22 and 23 s.

**The D1 mutants still go red for the same reasons:**
- No EXIT trap (`r4-d1a`): process check :16/:46/:62, tree check :19/:33/:49/:65.
- Cleanup skips the reap (`r4-d1b`): process check :16/:38/:52.
- Cleanup skips the tree removal (`r4-d1c`): tree check :17/:31/:45/:59.
- topo_pid's INT process check stays ok, as accepted.

**Everything else:**
- Full gate (`r4-green-gate-head.log`): J13/J14 ok (:23-24), 7 SUBSHELL caught with rc 143 (:46-:114), 21 mutations, 0 survivors (:118), rc 0 (:121).
- Seven suites: 111/57/33/157/61/174/32, all rc 0 (r4-suite-*).
- test_l1_shell_scoring: 151/0. mutate_l1_shell_scoring: 53 killed, 0 survived (:78).
- check_test_tmpdirs: 0 fixed temp paths.
- check_gate_anchors HEAD: 128/128, the gate at ok(22) (:54).
- leftovers.sh: 0 processes, 0 copies, 0 temp trees, in `r4-leftovers.log` and `r5-leftovers.log` (:10/:13/:16).

## Inferred, or not done
- The 215 s bound is arithmetic. The FIRST_WAIT limit itself was hit only in the deliberate N1 runs, not by a slow suite.
- The CI job durations are yours; I did not read CI myself.
- Not done, as instructed: the follow-ups (the spawn_app_fixture and spawn_two_layer races, shielding cleanup from a second signal, the INT re-raise idiom, the group-INT register window).
