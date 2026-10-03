# Where the 09-28 orchestrator stopped (~18:1x +08; Adam out of usage budget)

Public (unauthenticated, both repos): main eef173a9 (PRs #6-#17 all squash-merged, none open), trunk 3368412d. main == trunk outside doc/audit/**/*.md, REPORT*.md.
ndtwin-lab main now FOLLOWS main (rule changed 14:2x; CLAUDE.md via #17). Push over https with `git -c credential.helper='!gh auth git-credential'` when ssh:22 times out.

Open work, in merge order:
1. ndt one-clock residue fix — fix/residue-live-pid-wait-0928, worktree wt-residue-flake-0928, worker ad27fbd4333602a76.
   Judge MERGE AFTER FIXES; fixes 1-7 done at 571fa6fd (folded). Left: classify the 42 L1 no-build failures vs a trunk control; rerun at 571fa6fd;
   a short re-judge of the fixes. See logs/gates-0910/residue-0928/PROGRESS-0928.md.
   Then: my frozen rerun on the new head (residue/rerun-residue.frozen.sh, update sha), merge to trunk, push, PR (prediction first), compare, squash, sync lab main.
   Follow-up after it: S1/S2/S3 window edges (KNOWN-ISSUES entry from the worker) -> option (a) sub-second comparison.
2. spawn-helper subshell fix — fix/spawn-helper-subshell-0928 @ dfdb2121, worktree wt-spawn-helpers-0928. Judge was STOPPED unfinished for budget:
   relaunch it (prompt in this session; claims in spawnhelpers/INTAKE.md). Then rerun, merge, PR.
3. B / detect-only — feat/external-detect-only-0927: round 3 DELIVERED 480e9f2e; round 4 committed @ faf6eb41, 21 gates rc 0, 5 left via gates_b4r.sh (SUMMARY §R4.6); then judge round 4. (old line:) @ 480e9f2e, worker abac0003a05190784. Round 3: 19/23 gates rc 0 before the reboot, remaining
   run via gates_b3r.sh; told to checkpoint (SUMMARY §R3). Round 4 = Adam's "fix both" (external: no guessed paths; heartbeat only after an offline
   bmv2 drop check), my two rulings in extb/INTAKE.md. Then live comparison per procedure (a): controls on trunk, local unpushed merge for treatment.
4. After B: GUI live check on real P4 switches (Web-GUI 65eecf6, not pushed), screenshots to Adam; then remove webgui-node env.
5. Deferred by Adam: manual §E (one pass when stable); tools-out (main excludes all doc/audit; sudoers line for Adam first); ndt serve v2 60 s probe;
   Lab L1 lane ryu-env only where needed.
Private: intake-0926/kjl/ stays private (describes open T2/N4/N5). Slide deck: pinned to main eef173a9 / trunk 3368412d; refresh again if main moves before 09-30.
