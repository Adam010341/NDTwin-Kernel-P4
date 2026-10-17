# Judge: port-guard r2 (feat/p4-port-guard-offline 383be526), scoped

(Opus judge, read-only, 2026-10-16 ~17:xx. Saved by the orchestrator: summary; full text in session c5aa4598's transcript.)

**Verdict: MERGE** (stop rule: no BLOCKER/MAJOR). MAJOR-1 and MAJOR-2 FIXED with fair reds/greens; MINOR-3, 5, 6 and NITs FIXED; MINOR-4 PARTLY.
- A (MINOR): L1 counts skips with `grep -cE "^test_.* \.\.\. skipped"` (tools/test_workflow/l1_unit_tests.sh:472); a test WITH a docstring prints its skip on the docstring line, so on CI (no p4_src/build) test_port_guard reports PASS 10 ran, not PROVED LESS -- the dial test (docstring T:341-347) and the already-existing port-taken test (T:288) are invisible skips. "(PROVED LESS)" in the skip reason is the test's own text. Fix: docstrings -> comments, drop the verdict word, run p4lane without p4_src/build expecting PROVED LESS; separately fix :472 (count `... skipped` anywhere + `(skipped=N)`), with its own red.
- B (MINOR evidence): p4lane run started with 0.0.0.0:8081 held (p4lane.ss.txt:14) and, because of A, cannot show the dial test executed; established greens: green_new, knob_new_version (+3 reds that reached startup within 6.5 s).
- C (MINOR): a race between setUp's probe and the child's bind gives a misleading message on the startup test; append out[-2000:] to failure messages (also the kernel assertion).
- D/E/F/G/H (NITs): telemetry_override and host_count_override still read from the checkout; nothing asserts "[Proxy Agent] app package: baseline"; the kernel assertEqual never red on its own; "posts" -> "calls"; stale mutant files in later runs, a mislabeled count in gated3.sh.
- Guard covers every channel the proxy opens today (p4_client.py:371); a future `from grpc import insecure_channel` or aio channel would bypass it.
