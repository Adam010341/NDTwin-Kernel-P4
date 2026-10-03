# Forms for Adam at 10:00 (3 forms × 4 questions; recommendation first; "Other" is automatic)

## Form A
1. Manual §E (6 questions after pb5): take all recommendations? E1 keep -public; E2 sync after the venv migration and live 01/06 pass, with §C in the same deploy; E3 a child commit; E4 publish the branch with today's text; E5 run pip on 3.8 first; E6 no image rebuild.
   - Take all recommendations (Recommended) / Decide each one (Other)
2. GAP-2b's 4 judgement cells: registers=partial, queue_metadata=can, multicast twin=green, flowcache twin="IPv4 only" (orange, changed from green).
   - As recommended, then commit GAP-2b (Recommended) / flowcache twin stays green / all four stay pending
3. Third cut, Web-GUI: push draft/p4-capabilities-0924 @65eecf6 and open a PR on ndtwin-lab/Web-GUI?
   - Push after the kernel side is in main (Recommended) / push now / not yet
4. Restore bound: should restore also be "about 20 s"? (today: strict 20 s; detection is "about", with a 35 s ceiling)
   - Keep restore strict at 20 s (Recommended) / also "about 20 s" / other

## Form B
1. Tools-out §9: after the move, should main exclude all of doc/audit, should the PR delete the 3 moved READMEs, and who rewords doc/README.md:123?
   - Exclude all of doc/audit from main + delete the 3 + the worker rewords (Recommended) / keep the .md rule / other
2. ndt serve v2 after a measuring pause: manual refresh only, or a 60 s probe?
   - Manual refresh only, with a banner (Recommended) / 60 s probe
3. Third cut, Appendix A's 5 silent points (the judge finds all reasonable): accept?
   - Accept all 5 (Recommended) / change some (Other)
4. B's scope: the heartbeat starts under every external package on its own pipeline.
   - Package opt-out, default on, `heartbeat: false` (Recommended) / on for all, disclosed / opt-in only

## Form C
1. 930 deck: show the unmerged detect-only (B) on N1/N3?
   - Not until it is merged (Recommended) / show it marked "in review"
2. Lab L1 lane runs all of tests/python under ryu-env 3.8 (8 files red even on trunk):
   - Use ryu-env only for files that need ryu (Recommended) / port those files to 3.8 / leave it
3. Conda env webgui-node + GUI node_modules/dist (~0.5 GB): remove?
   - Keep until the Web-GUI PR is built, then remove (Recommended) / remove now
4. sudoers: the NOPASSWD rule bound to doc/audit/.../drive_exercise.py must change before tools-out tier 1 moves the driver.
   - I'll write the exact new line for you to install (Recommended) / hold tools-out tier 1

## Form D (security, first to ask)
1. KJL release: the frozen ndtwin-lab main f186ce98 keeps the pre-fix reap once trunk publishes the fix.
   - One-time fast-forward of ndtwin-lab main to the fixed main after the PR (Recommended) / keep frozen + security note in README / hold the KJL merge
2. B live comparison procedure (form D):
   - Controls on trunk, then a local unpushed merge of B for the treatment; push only on pass (Recommended) / you point /etc/ndtwin-lab.conf at B's worktree
