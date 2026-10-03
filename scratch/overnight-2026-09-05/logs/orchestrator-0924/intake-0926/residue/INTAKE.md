# ndt one-clock residue fix — intake (2026-09-28)

- Origin: PR #15's GCC red 3 of 4 on test_apps_residue.sh 5K; f253ed08 once. Worker measured a second-boundary race between residue_report's
  `now` and app_started_at's own `date +%s`; KJL off that path (85bec430 vs fc25112e, 150 runs each, no significant difference).
- Delivered 600f0ca0 on fix/residue-live-pid-wait-0928 (c2c9293d test-only first attempt; ca16700a merge of trunk 3368412d; 74d1383f product fix;
  600f0ca0 moved ndt line citations). merge-tree onto trunk 3368412d == branch tree 5130637f.
- I read the ndt hunks myself: `now` moved after the flow-table fetch and passed to app_started_at; secret scan: 1 hit = existing prose about
  the serve token (not a secret).
- Judge (opus) launched on 600f0ca0; my frozen rerun launched (rerun-residue.frozen.sh, pid in rerun-residue.pid): 5K suite twice, the one-clock
  gate, mutate_apps_stop_lists_rules, test_ndt_serve.py (main venv), l1 scoring, anchors (3368412d), tmpdirs.
- Not fixed here, my ruling for a follow-up after this merges: S1/S2/S3 (whole-second rounding at recorded window edges) -> option (a),
  sub-second comparison (duration_nsec + fractional mtime / /proc starttime); not (b) tolerance (changes E-7) nor (c).
- Separate ticket dispatched: spawn helpers that exit only their $(...) subshell (six suites) -> fix/spawn-helper-subshell-0928.
- 17:4x judge (opus, read-only) on 600f0ca0 -> MERGE AFTER FIXES: product change and root cause SUPPORTED; WRONG comment (duration_sec is from the
  kernel's ~10 s cached table, not "the switch's answer at the fetch"); public comments carry a wrong CI ratio; 5N never run under load; old case
  never asserts its rule age; early-opening window undocumented; 600f0ca0 fixes a red intermediate (fold it). S1/S2/S3 characterisation corrected
  (cache age dominates). Fix list 1-8 sent. My rerun of 600f0ca0 stopped by pgid (stale head), summary marked ABORTED.
- 18:1x stopped for Adam's budget: head 571fa6fd (one folded commit on 3368412d; backup/residue-live-pid-wait-0928-pre-fold = 600f0ca0).
  Fix items 1-7 done (cache wording, no CI ratio, 5N try counts + 30 s bound, idle 0/50 & loaded 0/50, age asserts, apps dated right after `now`
  + case + M9, fold, KNOWN-ISSUES G-62). Item 8 partial: L1 no-build sections at 571fa6fd FAILURES=42 incl. the eight G-61 files — NOT yet
  classified against a trunk control (aborted). Gates green at 9ec12523 (= 571fa6fd minus a 3-line comment). Resume: PROGRESS-0928.md there.
- 2026-10-01 item 8 closed (Sonnet 5.5 trial #1, general-purpose+model sonnet): L1 no-build control 3368412d vs head 571fa6fd,
  both under the nolab tripwire: FAILURES=42 on both, 42 BOTH / 0 HEAD-ONLY / 0 CONTROL-ONLY, head set identical to 09-28's.
  Report gates-0910/residue-0928/round4/CLASSIFY-l1-r2.md; logs round4/l1-nobuild-{control-3368412d,head-571fa6fd}-r2.log.
  Found on the way: gawk installed 2026-09-29 17:23 took over /etc/alternatives/awk (priority 10 > mawk 5); under gawk
  scripts/l1_nobuild.sh's `awk -v` regex end marker never matched -> 407 lines evaluated -> cmake started (-j1, guarded,
  ~100 s, killed by pgid; attempt1 logs kept, not results). r2 runs used an awk->mawk shim. I then changed the slice to
  fixed-string prefixes via ENVIRON; output identical to the old mawk slice under both gawk and mawk (diff empty).
  Control worktree has ignored debris from attempt 1 (build/ 272 MB, setting/AppConfig.hpp).
- 2026-10-01 my frozen rerun at 571fa6fd (rerun-residue-571fa6fd.frozen.sh, tripwire 0 lines, tracked tree clean): test_apps_residue
  145/0 twice; mutate_apps_residue_one_clock 9 mutations 0 survived; mutate_apps_stop_lists_rules 35/0; test_ndt_serve 74 OK;
  test_l1_shell_scoring 150/0; check_test_tmpdirs rc 0; check_gate_anchors 3368412d vs 571fa6fd 253/254, the one not-ok cell =
  mutate_apps_residue_one_clock.sh absent at trunk (expected by construction; head column all ok). Short re-judge running.
- 2026-10-01 round-2 re-judge (opus-judge max, scoped to the 8 items): MERGE AFTER FIXES, no new defect; items 1,2,4-8 DONE, item 3 PARTLY
  (CI at the head never run). Required: PR GCC CI green at 571fa6fd + record its 5N try lines; carry-over 9ec12523->571fa6fd shown
  (done: comment-only, round4/carryover-9ec12523-vs-571fa6fd.log); PROGRESS 15->14 corrected (done). Follow-ups (do not move the head):
  test:380-381 wording "no new try after 30 s"; dirty-tree guard in evidence4b.sh; G-62 bound = 10 s + poll duration and two more cache
  effects (rules newer than the last poll absent; rules up to one cache age before app start dated inside its window); optional LC_ALL=C.
  These go with the S1-S3 follow-up ticket. Full verdict: judge-571fa6fd-r2.md.
- 2026-10-01 12:5x merged to trunk c9c84ea4 ("Merge fix/residue-live-pid-wait-0928: ndt dates apps and rules against one clock read";
  tree == merge-tree 0fd99d20); secret scan 1 hit = serve-token prose (not a secret); ndt + G-62 hunks read; trunk pushed to both repos
  (push-residue-c9c84ea4.log, unauthenticated ls-remote both c9c84ea4). PR #19 from pr/residue-one-clock c22ca67b (main a7ff42ab + the 11
  files; tree == trunk outside doc/audit md / REPORT md). Prediction written first: ci-prediction-pr19.txt. CI compare = Sonnet trial #2.
- 2026-10-01 PR #19 squashed 6722c298 (no trailers); ndtwin-lab main ff to 6722c298; both repos main 6722c298 / trunk c9c84ea4 (push-pr19-1001.log). CI compare: ci-compare-pr19.txt. Residue fix CLOSED; follow-up = S1-S3 sub-second ticket + judge r2 follow-ups.
