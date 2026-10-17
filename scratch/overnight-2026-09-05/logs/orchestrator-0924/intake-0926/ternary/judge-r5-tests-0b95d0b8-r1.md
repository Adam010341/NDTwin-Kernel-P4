# Judge: r5 tests (feat/p4-journal-r5-tests 0b95d0b8) r1

(Opus judge, read-only, 2026-10-16 ~17:xx. Saved by the orchestrator: summary; full text in session c5aa4598's transcript.)

**Verdict: MERGE.** No BLOCKER/MAJOR (stop rule: closed). The six tests assert DESIGN.md:480-524/:804-819, SUMMARY-cut-c §13 rulings 6-7 and the api_routes stale-drop docstring; each reaches its branch; M-J140..144 each killed by its named new test at the intended line; anchors byte-identical to existing ones but mutant() asserts exactly-once (sh:168), so no silent misapply; m2r is a real bmv2 restart + readopt via main.readopt_switch on both binaries, red control fair.
- MINOR-1: handback's M-J90 explanation wrong (one def, three FAIL blocks from subTest); name-only killer matching is latent, not live (154 killer names = 154 defs, no duplicates).
- MINOR-2: 8 controls, not 9 (206 = 198 + 8).
- MINOR-3: item 5 trial scripts/logs only in scratch; binaries identified by path only -> archive on audit-raw (not trunk), add sha/--version; one-off observation, not a regression guard.
- MINOR-4: commit message not verified by the judge (no git) -- orchestrator checked it (one subject + plain body, no trailer, no banned words, no mutant IDs).
- NITs: assertion_of names product frames in 11/200 lines and prints "-> ?" for SwitchGone/SwitchBusy; test_readopt.py did run in p4lane; item 3 never asserts the fallback "lands"; STALE_REASON hard-coded copy of rule_journal._STALE_ENTRIES; quickmut logs print placeholders for the interpreter.
