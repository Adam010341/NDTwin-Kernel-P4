# Resume after Adam's reboot (planned 15:0x-15:1x, 2026-09-28)

State at the reboot:
- Public: both mains be01cc7a (ndtwin-lab fast-forwarded 14:3x, rule change); both trunks fc25112e (KJL merged). Local trunk 08f67b7a = fc25112e + CLAUDE.md sync rule (not pushed).
- PR #15 (KJL, head 47b8fb9c) open on Adam010341; CI runs remotely. Prediction ci-prediction-pr15.txt. After green: compare, squash, then
  `git push lab <new main>:refs/heads/main` (use https + gh credential if ssh:22 times out), verify unauthenticated. Then tell the slides worker KJL landed;
  then commit the withheld intake-0926/kjl/ records (fix now public).
- Q-N1 85befc7d: rerun2 on 6893a9ba (onto 85bec430) all green. Trunk moved by KJL (no C++, file-disjoint) and CLAUDE.md -> merge Q-N1 onto trunk,
  run test_l1_shell_scoring on the merged tree, push, PR (with CLAUDE.md in the same PR or its own), compare, squash, sync lab main.
- B 480e9f2e: round 3 PARTIAL (19/23 gates). Resume worker abac0003a05190784: copy logs/gates-0910/worker-extb-0928/ back, run gates_b3r.sh,
  then round 4 (Adam: fix both). Send my two rulings from extb/INTAKE.md (14:5x section).
- Slides worker a033cea3ef106e934: refresh + GAP-2b cells + ndtwin-lab no longer frozen. Resume from its PROGRESS-0928.md.
- ssh to github.com:22 timed out twice at 14:4x-14:5x; https push via `git -c credential.helper='!gh auth git-credential'` worked.
- Rulings: RULINGS-0928-afternoon.md.
- Slides worker stopped 06:59Z, PARTIAL: 14 PNGs regenerated (Q4, Q5, F1 37/0/2, N1, t1b, T1); left: figure .md files, README/template,
  byte-identical sweep, report. Resume plan: scratch/overnight-2026-09-05/logs/slides930/PROGRESS-0928.md. GAP-2b diff to read myself
  (four cells, six markers, summary line 7/3/3 -> 6/4/3) before committing it. Tell it: trunk fc25112e is now public (after 06:45Z).
- Two findings to check:
  (1) the first all-green CI was the trunk push of 8d622ea4 at 01:26Z, ~12 min before PR #12's runs -> correct "PR #12 = first fully green CI"
      to "first all-green PR" in memory (phase5-post-roles-state) and in what I told Adam;
  (2) Adam010341 trunk f253ed08 GCC failed while ndtwin-lab passed on the same commit -> fetch both job logs by gh api (check line counts).
