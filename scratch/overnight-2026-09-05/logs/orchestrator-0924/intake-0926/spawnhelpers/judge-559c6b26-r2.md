# opus-judge round 2 on 559c6b26 (2026-10-01)

**Verdict on 559c6b26: MERGE AFTER FIXES.** The only required fix is a reword of the new commit message; the tree doesn't change, so nothing needs re-running. All six round-1 fix items are done and each has failing-before / passing-after evidence. No blocking code defect found.

Read-only, nothing executed. I treated the a5e8de70 logs as logs of 559c6b26's tree, as instructed (`r2-amend-message-only.txt` shows the same tree, 0481461a). I did not use `r2-superseded-*` or `r2-dev-*` as evidence.

Paths below: the gate is `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-spawn-helpers-0928/tests/shell/mutate_fixture_spawn_helpers.sh`. Logs are under `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/spawn-helpers-0928/`.

## Round-1 fix list
1. **Every call site covered — DONE.**
   - The gate now has three parts: a static check over every call line (gate :114-176, exits at :281), a count of premise lines in the unmutated run (:298-323), and the mutants.
   - On trunk the static check flags 38 lines across 7 suites (`r2-trunk-red-static.log:18-62`, rc 1).
   - The per-site sweep catches 38/38, each time naming the reverted file:line (`r2-site-sweep.log:10-49`). HEAD passes (`r2-gate.log:18-24`).
2. **check_process_by_name.py:24 — DONE.** It now names the topo_pid comment by its text ("B12 (2026-09-11)", which is at topo_pid:138), not a line range.
3. **J6 — DONE.** A real live `sleep` must be judged SURVIVED (gate :245-251). Removing condition 5 makes J6 refuse with rc 2 (`r2-red-j6.log:11-12, 19-20`).
4. **Fixture already gone when polled — DONE.**
   - A GONE mutant exists for all 7 suites; all are caught, each after the 30-s poll.
   - Sweep's GONE with `|| true` removed dies at once: rc 1, 0 s, last line "machine-wide scan" (`r2-gate.log:52-53`). That is a clean A/B showing the `|| true` is what keeps errexit from ending the run.
5. **test_ndt_down_stops_only_ours.sh — DONE.**
   - Every pid goes into `SPAWNED` before the poll (:111), the poll waits 30 s, the premise is counted, and summary plus `exit 1` are on one line (:130). Cleanup walks `SPAWNED` (:137-150).
   - Check count goes from 29 to 32 (`r2-before-suite-down.log:48`, `r2-suite-down.log:51`).
   - The old shape fails the gate: 0 of 3 premise lines counted, and the given-up fixture is left running (`r2-red-down-old-shape.log:26-44`).
6. **Nits — DONE.** Sweep comment :187-189, gate header :9-19, `.gitignore:105`, copies removed on INT/TERM (:78-80).
   - The corrected dfdb2121 message is only a file; dfdb2121 itself is unchanged. It lands only if that commit is reworded before the branch is merged or pushed.

## Your six questions

**(1) Does the static check refuse every non-plain form?**
- **What it refuses:** for each line, it flags anything not exactly `helper ARGS; VAR="$FIXTURE_PID"`. That covers:
  - command substitution, backticks, `<(`/`>(`
  - `|`, `||`, `&&`, a trailing `&`
  - `;` chains, line continuations
  - `command`/`\` prefixes, alias or `eval` lines that name the helper
  - an indented call outside 12C, so a helper call inside an indented function body is refused.
- **What it misses:** an exactly-plain line at column 0 inside a multi-line construct that forks, or a helper name built at run time (eval or indirection).
  - Multi-line `X="$(` / call / `)"`: part 1 misses it, part 2 catches it, because the premise line is captured.
  - Multi-line `( … )`, `{ …; } | cmd`, `{ …; } &`, or a column-0 function body run that way: both parts miss it, because the premise line still reaches the suite's stdout.
  - None exists today and none is a natural revert. The gate header's "every call … runs in the suite's own shell" (:3-4) claims more than is enforced; a `[[ $BASHPID == "$$" ]]` check in each helper would make it true.
- **Column B does not prove the premise count works on its own.** It proves part 2 as a whole (green unmutated run plus count) catches all 38 one-line reverts.
  - At 32 sites, the unmutated run went red first ("refused", rc 2), so the count was never compared.
  - At 6 sites the count alone decides: orphans:200 and :347, topo_pid:119 and :126, ovs_claim:523 and :588.
  - Only the one-line form was tested. SUMMARY item 3 says "premise-count part alone 38/38"; that overstates it, though its own detail section is accurate.

**(2) Can the window:856 (12C) exclusion hide a real revert?** No.
- Part 1 reads line 856 whether or not 12C runs, so a one-line revert is always caught.
- The site is dropped from the expected count only when the unmutated run prints "12C did NOT run". That text is printed only in the block's `else` branch, and the gate requires it, and the `if` line, to occur exactly once.
- The count compares for equality, so a stray note while 12C ran would also go red.
- In every logged run 12C ran (7/7).

**(3) Do J6, GONE and gone-without-true show what they claim?** Yes, with two loose ends.
- The gone-without-true check matches any nonzero exit with no summary line, `'SURVIVED (rc '[1-9]*…` at :347. So a timeout (rc 124) would also count as "survives as it must". The evidence shows rc 1 in 0 s, but the gate doesn't require it.
- GONE never checks for "nothing readable". That the read really failed is proven only in sweep, via the A/B above.
- Minor: J6 only exercises the live-process branch, not the zombie one.

**(4) Down suite — correct, reaped, counted, summary and exit on one line.**
- Call sites :153, :154 and :258 are plain. The fixture is still started from a command substitution, so "OURS IS GONE" keeps reading /proc correctly. Each fixture still leads its own process group (`r2-suite-down.log:19-20`).
- mutate_l1_shell_scoring is 53/53, and the down mutation is caught for the required reason (`r2-g-l1-scoring.log:56, 77`).
- **INT/TERM trap that returns: follow-up, not a blocker.**
  - It was already there on trunk. The same returning-trap shape is in topo_pid:60, liveness:106, sweep:91, window:117 and ovs_claim:76; only orphans (:128-130) was converted.
  - In down, `sudo` is a function inside every `drive` (:172), so a run that continues after cleanup cannot reach root. Its checks fail, and a spawn at :258 into the deleted directory waits up to 30 s (2 s before this change) and then exits 1.
  - Fix all six suites in one follow-up, with a test that sends TERM mid-run.

**(5) Mutant copies beside the suites + cleanup + .gitignore — acceptable.**
- The reason holds: ndt:53 resolves its own path with `readlink -f`.
- Each copy is removed after its run and by the EXIT trap. INT/TERM go through exit 130/143 and then EXIT, but only after the running suite finishes: `timeout` puts the suite in its own process group, so Ctrl-C doesn't reach it.
- A SIGKILL leaves a copy behind, which `.gitignore` covers. Copies left by dead runs (named by their pid) accumulate; harmless.

**(6) Anything else new.**
- The new commit message (`r2-commit-message-new.txt`) says "a judge self-test against a live process". "judge" is on the list of words that can't go public. Everything else in both messages is fine: short, engineer style, no trailers, no ticket words.
- The new message also states as fact that the six sites left the round-1 gate green. That was inferred, not run, but the mechanism makes it certain.

## Numbers (consistent)
- Static call-site counts 7/6/4/7/3/8/3 = 38 (35 plus down's 3).
- Unmutated runs 111/57/33/157/61/174/32.
- Each mutant's check count equals the checks before that suite's first call site.
- 14 mutants = 7 NEVER + 7 GONE.
- Gate anchors ok(15) at HEAD; 379/381 = 127 gates × 3 revisions − 2 (this gate at 3368412d and dfdb2121, expected).

## Tests I would have run
1. Wrap topo_pid:119 in a multi-line `( … )`: expect the gate to stay green.
2. A multi-line `$( … )` at a later call site: expect part 1 to pass and part 2's count to fail.
3. Force a timeout on gone-without-true: expect it to be wrongly accepted.
4. Force 12C to be skipped: expect window's count to come out 6/6 with the note.
5. Send TERM to the down suite mid-run.
6. A missing or doubled anchor: expect rc 2 (still not run).

## Fix list
1. **(Required)** Reword "a judge self-test against a live process", e.g. "a self-test of its verdict against a live process". Message-only amend.
2. **(Follow-up)** Make INT/TERM end the run in all six suites with a returning trap (topo_pid:60, liveness:106, sweep:91, window:117, ovs_claim:76, down:151), using orphans' pattern, plus a TERM-mid-run test.
3. **(Optional)** Add `[[ $BASHPID == "$$" ]]` to each helper, or soften gate :3-4, to close the multi-line forking evasions.
4. **(Optional)** Require rc 1 in the gone-without-true check (:347), and "nothing readable" in GONE's FAILED block.
5. **(Housekeeping)** Reword dfdb2121 with the corrected message before the branch is merged or pushed, if that correction is wanted.
