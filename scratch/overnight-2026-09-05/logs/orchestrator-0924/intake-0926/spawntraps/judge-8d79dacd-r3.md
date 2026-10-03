**Re-review of fix/spawn-helper-traps-1001 at 8d79dacd**

**Verdict: MERGE.** Every item on my round-2 list and your CI-headroom addition is met, and every log line the round-3 summary cites matches. What's left below is recommended or a follow-up, not blocking.

## Per item

- **N1: DONE.**
  - SREG is now set for all seven suites. The premise loop (test :140-154) waits for a live pid of the run that is listed in the suite's own register, and the tree it is listed in becomes the suite's temp tree.
  - The green runs show it working: each of the 14 note lines names live fixture pids and the register path, including window, ovs_claim and down (r4-green-signal-test-head-1.log:13…117). 3/3 green: 84 checks, rc 0, 23/22/23 s.
  - **Wrong or stale tree: no.**
    - For window, ovs_claim and down, the only place searched is `$WORK/tmp-<label>-<sig>`, created fresh by each run.
    - For the four /tmp suites, trees that existed before the run are excluded (:147). A tree that another concurrent run creates can't match, because its register lists pids without this run's token.
    - Only pid reuse could make a foreign tree match. With pids around 2-3.5 million in these logs, that is negligible.
  - **The red/green pair is valid.** The variant makes ovs_claim kill its first fixture, then run 60 s of `command sleep 0.5` (FIRST_WAIT=25).
    - The previous test accepts that moment: all 16 checks ok, the "process alive" premise ok at :13/:22, rc 0.
    - The delivered test refuses it: premise FAILED at :11/:15, "1 other process(es) of the run alive" at :13/:17, rc 1.
    - The r4 pair was correctly marked superseded: FIRST_WAIT=5 was shorter than ovs_claim's time to its first fixture.
- **N2: DONE.**
  - The count went from 8 checks per run to 6, so 112 → 84 = 14 × 2.
  - Only two checks were removed: "a process … is alive" (it could not fail since e0bb7d7f) and "its temp tree is found" (it cannot fail now that the tree is found inside the loop and an empty tree returns early). Both were replaced by a `note` line.
  - The remaining premises (the pid is the suite's shell, it leads its own group) can still fail. The premise-failure check itself was seen red (r5-gap-head, r5-down).
- **N3 and the optional header line: DONE** (:18-31, :38). One nuance in the optional line:
  - It says the INT process check "can only fail for a fixture outside the suite's process group". A process inside the group that ignores INT also survives.
  - r4-d2-hung :44-46 shows this: the leftover is the hung variant's `sleep 1000`, which inherited SIG_IGN.
  - The line could say "only for a process that outlives the INT: a setsid one, or one that ignores INT".
- **Commit messages: DONE, as far as I can read them.**
  - COMMIT_EDITMSG holds 6e3cae59's pre-reword text: plain, no trailers, no listed words.
  - The rewritten bodies are only readable with git, which you have already used. Per the summary, their subjects now match their code.
  - The worker's "0 hits" is a whole-word scan; your substring hit on `judge_subshell` is the only difference, and you have accepted it.
  - Process note: `refs/heads/backup/spawn-traps-1001-pre-reword` still carries the old messages. Don't push it; delete it after merge.
- **CI headroom: DONE.** Defaults are now FIRST_WAIT 30, HARD_LIMIT 30, TOTAL_LIMIT 150.
  - The bound arithmetic holds. The first two waits are wall-clock deadlines that already include their /proc scans. Only the leftover poll (≤ 30 × (0.1 s + one scan)) and the final reap fall outside them.
  - That gives ≤ ~65 s per run and ≤ ~215 s in total, within your 4 min. 22:11 + 3:35 ≈ 25:46, inside the 30-minute timeout.
  - Observed: the worst run was r4-red at 171 s. Two hung runs took 66 s together, with "killed (SIGNAL_HARD_LIMIT)" at :14/:36. TOTAL_LIMIT=1 produced three FAILED skip lines (:18/:21/:24).
  - Not measured: the green duration on a CI runner. ovs_claim takes about 4-6 s to reach its first fixture locally, so FIRST_WAIT 30 leaves roughly a 5-7× margin. Read this test's time on the first CI run.

## Is the down skip on d452d111 acceptable?

Yes for a CI gate, with caveats.
- The run is red (rc 1), and down's two rows are explicit FAILED skip lines ("171s used"). A skipped suite can never read as passed.
- On d452d111 itself, liveness, sweep, window, topo_pid and ovs_claim are red by rc. Orphans is green, which is correct because d452d111's orphans already had the exit-pattern traps.
- A realistic regression of one suite takes about 70-90 s and stays inside the budget. Only a regression in two or three suites at once gets truncated; that run is still red, but a rerun by label is needed to name every broken suite.
- **Caveat:** with the current version of the test, down's rc check has never been seen red.
  - d452d111's down keeps its pids in an array, not a file, so run alone it can only fail the premise (r5-…-down :11/:15).
  - Its rc red exists only from older versions of the test: round 1 :195/:212, and r3 rc 137 from the HARD_LIMIT kill.
  - **Recommended (about 1 min):** run the current test on HEAD with only down's traps reverted to `trap cleanup EXIT INT TERM` (round 2's th-test2 variant). Expect down TERM/INT ≠ 143/130.

## Minor, new this round (all low, non-blocking)

- **Snapshot-to-signal gap.** The register snapshot is taken about two checks (tens of ms) before the signal. ovs_claim can kill LIVE_VIZ in that gap, so the note's "alive" is as of the snapshot. Optionally re-check `/proc/<pid>` just before `kill`.
- **Premise-failure leak.** When the test SIGKILLs a still-running /tmp suite on the premise-failure path, that suite's tree is unknown and left behind. This predates the branch; the TMPDIR suites are covered by the WORK cleanup.

## Still follow-ups

- spawn_app_fixture and spawn_two_layer races.
- Shielding cleanup from a second signal.
- The INT re-raise idiom.
- The group-INT register window for setsid fixtures.

## Files

- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-traps-1001/tests/shell/test_fixture_suites_end_on_signal.sh (:18-45, :140-165, :191-199)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/r5-n1-gap-prev-test.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/r5-n1-gap-head-test.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/r5-red-signal-test-d452d111-down.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/r4-red-signal-test-d452d111.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/r4-d2-hung-suite.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-traps-1001/r4-green-signal-test-head-1.log
