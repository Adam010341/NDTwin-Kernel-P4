# Adam's rulings, 2026-09-28 14:1x-14:3x (forms; answers verbatim where he typed)

- Q14 KJL release -> RULE CHANGE: "ndtwin-lab的那個repo不用凍結，可以同步". ndtwin-lab/NDTwin-Kernel-P4 main is no longer frozen at f186ce98;
  it follows the PR-merged main (fast-forward push of Adam010341 main). PRs still open only on Adam010341. CLAUDE.md to be updated by PR.
- Q15 B live comparison -> (a) controls on trunk from the main checkout, then a local unpushed merge of B for the treatment; push only if compare passes.
  Adam asked whether to give root; answer given: not needed, not advised.
- Q13 B scope -> "兩個都修再併": (1) external fabrics report no guessed destination paths; (2) the heartbeat starts on an external program only
  after an offline check proves it drops 0x88B5. Supersedes the opt-out question. Sent to the B worker as round 4.
- Q10 930 deck -> detect-only stays off N1/N3 until merged.
- Q1 Manual §E -> Adam: "要不要等我們全部穩定下來之後再一次改？" -> deferred; one pass after KJL, Q-N1, B and tools-out land.
- Q2 GAP-2b -> as recommended (registers=partial, queue_metadata=can, multicast twin=green, flowcache twin="IPv4 only"); commit; regenerate 930 t1b.
- Q3 Web-GUI -> not pushed. Adam asked whether it is usable yet: kernel half is on main; the GUI half builds and was judged sound, but was
  never rebuilt at 65eecf6 nor seen in a browser on real P4 switches. Plan: a live GUI check after B's live comparison, screenshots, no push.
- Q4 Restore bound -> stays strict 20 s.
- Q5 Tools-out §9 -> main excludes all of doc/audit; the PR deletes the 3 moved READMEs; the worker rewords doc/README.md:123.
- Q6 ndt serve v2 -> 60 s automatic probe after a measuring pause (NOT my recommendation; keep the probe read-only and light).
- Q8 Third cut Appendix A 5 silent points -> all accepted.
- Q11 Lab L1 lane -> ryu-env only for files that need ryu.
- Q9 webgui-node env -> keep until the GUI live check, then remove.
- Q12 sudoers -> I write the exact new line for Adam before tools-out tier 1 moves the driver.
- 14:3x Adam: "等等找個時間讓我重開機" -> I pick a window with no local run in flight and tell him.
