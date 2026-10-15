# P4 health check Cut 2, offline half (feat/p4-health-cut2)

[Co-developed with claude code -- Adam]

- 10-04 00:4x dispatched to opus-worker in wt-p4-health-cut2 from 0cd01656 (Cut 1 + follow-ups). Told at 01:0x about the coming
  per-run identity change (own package per round under run_dir; claim expires in LAB_STATE).
- ~02:4x DELIVERED 50c3379d, 4 commits, 19 files (tools/p4_health + its three test files only), +3856/-11
  (REPORT-50c3379d.handback.txt). recover.sh, lab_round.py, DESIGN.md, expected_today.tsv untouched.
  - Gates: cells 110 / collect 97 sealed / recover 72 on 3.8, 3.12, 3.13; H1-H6 red; mutation gate 201/0; S0 COMPLETE 54 ok
    (adds A-MUT and a ctrl_trial of the B controller on both grpc builds); anchors 133/133; tmpdirs 414; scoring 163.
  - Not done: AP1/AS1/IT1/VS1 observers (§13 puts them in Cut 2; my brief's list missed them) -> NOT RUN; Cut 3-5; the live half
    (procedure in SUMMARY §6).
  - Observed on throwaway grpc bmv2: RegisterEntry write is UNIMPLEMENTED ("Register writes are not supported yet") on both builds,
    so R3 will read UNATTRIBUTED, not the predicted RED. Prediction left unchanged on purpose (pre-registered from code).
  - Old-code red is coarse for most (ImportError on 0cd01656); per-path evidence is the 43 new mutants.
- Checked by me: messages clean, scope as stated, scan 0/3, no /home, no private names. SUMMARY committed from the markers.
- Review r1 sent to a new opus judge (lab safety and false greens first).
- Review r1 (new opus judge): **MERGE AFTER FIXES** (judge-cut2-d70370c0-r1.md). MAJOR-1 TP1 oracle parses only veth peers printed as @ifK, but switch-to-switch peers in the root netns print as @name -> false RED, cascading to SC-fwd/K1/TTL1 and the see-red run (the fake fabric shared the wrong assumption). MAJOR-2 sniffer counts ICMP port-unreachable copies as markers -> pingall sniffers stop early, SC-fwd fails on a healthy fabric. MAJOR-3 B is brought up whatever A's teardown left, and both bring-ups overwrite one LAB_STATE.json (A's recovery record lost). m1 delta 'flipped' for unobserved cells; m2 no per-step guard; m3 hostside.py (root) untested; m4 live-procedure gaps; m5 adapter path never run; m6 SUMMARY corrections; m7 R3 / AP1-AS1-IT1-VS1.
- My decisions: R3 prediction -> UNATTRIBUTED citing ctrl_trial, before any live run (VS1 precedent); VS1 observer now (cheap); AP1/AS1/IT1 move to cut 3 in a reviewed commit. MAJOR-3 approach: merge fix/p4-health-run-identity in first, then refuse to overwrite a non-terminal LAB_STATE and gate B on A's clean end. Fixes sent back to the same Cut 2 worker.
- Fixes DELIVERED fa7fcb83 (REPORT-r2-fa7fcb83.handback.txt): merged run-identity f721be78 first (no conflicts, green); MAJOR-1 both veth forms (format settled under unshare -rn: same-netns peer by name, other-netns by @ifK), fake fabric fixed, unplaced port -> oracle unreadable; MAJOR-2 sniffer only UDP to the cell's dport and receiver ip, fake emits ICMP quotes; MAJOR-3 B only after A ended clean, LabRound refuses a non-terminal LAB_STATE, per-bring-up LAB_STATE.<X>.json kept, external check before the controller; m1-m7, w1 done (dirty-tree refusal, gate fingerprint + system_under_test, adapter dry run in S0, R3/VS1/AP1-IT1 per my decisions). Gates: cells 116, collect 118 sealed, recover 108/0, H1-H6 red, mutation 252/0, S0 55 ok, anchors ok(242) (197 vs 201 explained: shared anchors).
- Checked by me: messages clean, scan 0. SUMMARY updated (4f50e23d). Judge pass on the fix diff only (new opus judge). Still to come: run-identity r7, then one more merge and final gates.
- Review r2 (fix diff only, new opus judge): **MERGE AFTER FIXES** (judge-cut2-4f50e23d-r2.md). All r1 items fixed with faithful mutants. New: N1 a stop signal during A does not stop the run (LabRound returns after SignalAbort and the gate lets B claim; SignalAbort is an Exception and three 'except Exception' blocks swallow it, e.g. during the 150 s sniffer wait); N2 a B whose controller never runs (refused by the external check, no spawn, no ready, no result) leaves the run COMPLETE rc 0 and the rollups show false 'can's. MINOR: N3 dirty check fails open when git fails, identity not checked before the lab; N4 TP1 NOT RUN keeps nothing to diagnose; N5 see-red rc 1 hides an unclean teardown; N6 §6 delta count 27 not 26, pre-check needs plain ndt status; N7 unobserved controls read flipped; N8 run from a dedicated clean worktree (fingerprint and root-run files).
- Sent back to the same Cut 2 worker.
- 10-15/16 locale rounds 2-3 (partials, reviews, fixes) and the merged-head gate: see gates-0910/p4-health-locale/r2, r3 and gates-0910/merged-trunk-1015/; summary in doc/audit/2026-10-03_p4-health-check/SUMMARY-cut2-offline.md §11.10.
