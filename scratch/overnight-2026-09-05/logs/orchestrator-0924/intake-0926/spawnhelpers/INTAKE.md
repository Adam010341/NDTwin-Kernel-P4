# spawn helpers that exit only their $(...) subshell — intake (2026-09-28)
- Found by the residue worker (round3/spawn-helpers-measure.log). Dispatched 17:2x; delivered dfdb2121 on fix/spawn-helper-subshell-0928
  (one commit on trunk 3368412d; 7 files, +386/-96, tests/shell only). merge-tree onto trunk == branch tree d0e25b62.
- Secret scan of added lines: 0 hits. Gate red on trunk 6/6 survivors, green on the fix 6/6 caught; suites +1 check per spawn call.
- errexit in test_ndtwin_lab_sweep.sh measured: sourcing ndtwin-lab sets -e.
- Judge (opus) launched 17:5x. Merge order: after the residue fix (both touch only tests/shell; no shared file, check again at merge time).
- 2026-10-01: judge relaunched with the 09-28 prompt verbatim (opus-judge, max). Verdict MERGE AFTER FIXES, full text in
  judge-dfdb2121-r1.md. Required: the new gate exercises only the first of 35 call sites (6/35); four sites can revert to
  $(...) with suite and gate green (topo_pid:119/126, orphans:200, ovs_claim:523). Plus: re-anchor check_process_by_name.py:24;
  J6 live-pid self-test; already-gone-fixture mutation for sweep's `|| true`; seventh suite test_ndt_down_stops_only_ours.sh
  (same shape, fixture never reaped, 2 s poll) -> I rule FIX it (Adam: fix over disclose); nits. Round 2 dispatched to a fresh opus-worker.
- 2026-10-01 round 2 delivered 559c6b26 (message-only amends of a5e8de70; trees equal 0481461a, verified). Report SUMMARY-r2-559c6b26.md.
  Static check red on trunk (38 lines = 35 sites + 3 in the seventh suite); per-site revert sweep 38/38 caught, premise count alone 38/38;
  J6 red without condition 5; GONE + gone-without-true controls; down suite 29 -> 32 checks; all listed gates rc 0; anchors ok(15) at HEAD.
  Secret scan of added lines 0. Merge onto trunk 584905d8: .gitignore conflict only (both append at the end) -> keep both blocks.
  Left by the worker: down suite's INT/TERM trap still returns (out of scope); judge tests 4 (bad anchor exit 2) and 6 (CI timing) not run.
  Scoped re-judge sent to the round-1 judge (same agent).
- 2026-10-01 round-2 re-judge (same judge): MERGE AFTER FIXES, fix 1 = reword "a judge self-test" in the new commit message
  (judge-559c6b26-r2.md). Done as message-only rewrites: 1b6c99ae (dfdb2121's tree, corrected message) + 8df555e6 (559c6b26's tree,
  "a self-test of its verdict"); trees verified equal; old tip kept as backup/spawn-helper-r2-559c6b26.
  Merged to trunk as d452d111 (built off-worktree: merge-tree + .gitignore resolved by keeping both appended blocks, then ff-only;
  9 branch files identical to the branch tip); secret scan 0; pushed to both repos (push-spawnhelpers-d452d111.log).
  PR #22 from pr/spawn-helper-call-sites eea1173d on main c1f59394; prediction ci-prediction-pr22.txt written first.
  Follow-ups (not blocking): INT/TERM traps that return in topo_pid:60, liveness:106, sweep:91, window:117, ovs_claim:76, down:151
  -> orphans' pattern + a TERM-mid-run test; optional BASHPID check in each helper; gone-without-true should require rc 1; judge tests
  4 (bad anchor exit 2) and 6 (CI timing of a forced-red lane) not run.
