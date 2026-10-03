# spawn-helper follow-up: INT/TERM traps, BASHPID guard, stricter gate — intake (2026-10-01)
- Asked from the 559c6b26 r2 review's follow-up list (spawnhelpers/judge-559c6b26-r2.md). opus-worker, worktree wt-spawn-traps-1001,
  branch fix/spawn-helper-traps-1001 from trunk d452d111. Two phases (a machine-wide fork measurement was running first).
- Delivered 14c490c3 (668930a5 + 14c490c3; 9 files +380/-50, tests/shell only). Report SUMMARY-14c490c3.md; logs gates-0910/spawn-traps-1001/.
  Secret scan 0 hits (control 3). merge-tree onto trunk d452d111 clean. Commit messages checked: no trailers, no banned words.
- Review r1 (opus-judge): MERGE AFTER FIXES, judge-14c490c3-r1.md. Asks 1–5 DONE. Required: D1 the new test's leftover/temp-tree checks
  never seen red; D2 cost claim (4 min is the red run; green is 15 s) and worst case 14×(180+600) s exceeds CI's 30 min; D5 evidence
  hygiene; D4 judge_subshell's untested branches (J13/J14); D3 comments overstate the race closure for group INT.
  Sent back to the same worker as round 2.
- Follow-ups for a separate branch (not scheduled yet): liveness spawn_app_fixture registers its pid only after app_spawn's `sleep 1`
  (≥1 s window, signal leaves bash + 120 s sleep in their own session); window spawn_two_layer `&`→`TWO_PARENT=$!` window and the
  pre-exec cmdline check; `trap '' INT TERM` first in each cleanup (a second signal cuts cleanup short); INT re-raise idiom so a
  calling script stops on Ctrl-C (l1_unit_tests.sh:599 carries on after `exit 130`).
- Round 2 delivered e0bb7d7f (c8635940, 055acd84, e0bb7d7f). Report SUMMARY-r2-e0bb7d7f.md. Scan 0. Re-review (same judge):
  MERGE AFTER FIXES, judge-e0bb7d7f-r2.md — D1–D5 DONE (topo_pid INT gap accepted as an equivalent mutant); N1 the premise accepts
  any run process, not a fixture (green can be uninformative for window/ovs_claim/down); N2 a check that can no longer fail; N3 stale
  header. Commit messages: 668930a5, c8635940 clean (read by me); 055acd84 uses "judged"; e0bb7d7f subject overclaims -> message-only
  rewrites. Round 3 sent to the same worker (preferred N1 fix).
  Extra follow-up: read build-and-test's normal duration from a recent CI run to confirm the 6.6 min worst case fits the 30 min job.
- Round 3 delivered 8d79dacd (055acd84 -> 4fd73e72, e0bb7d7f -> 664500d3 message-only, trees verified equal; + 8d79dacd). Scan 0,
  privacy grep 0. Re-review r3 (same judge): **MERGE**, judge-8d79dacd-r3.md. Recommended evidence run (down's rc red with the current
  test) sent to the worker, no code change. Nits left: the INT header line could say "or one that ignores INT"; re-check /proc just
  before kill; premise-failure leak of a /tmp suite's tree (predates). Delete refs/heads/backup/spawn-traps-1001-pre-reword after merge;
  never push it.
- Merged --no-ff into trunk as 1e350bf2 (tree == 8d79dacd's), pushed to both repos (push-spawntraps-1e350bf2.log, unauthenticated
  ls-remote 1e350bf2 on both). PR #23 from pr/spawn-helper-signals 23dee9c4 on main 546fd33b (invariant diff 0); prediction
  ci-prediction-pr23.txt written first.
- r6 evidence: down's rc checks red with the current test (returning trap restored, SIGKILL at the hard limit → 137 ≠ 143/130; 12 checks, 6 failed, rc 1; r6-down-rc-red.log :16-21, :36-41, :51, :54). Spot-checked.
- PR #23 CI all MATCH (ci-compare-pr23.txt; spot-checked). Squashed as a1f1bc3d; ndtwin-lab main synced; both mains a1f1bc3d (push-pr23-1002.log).
