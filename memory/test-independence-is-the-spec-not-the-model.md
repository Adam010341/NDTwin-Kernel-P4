---
name: test-independence-is-the-spec-not-the-model
description: Adam worried that one model writing both code and tests is player-and-referee. The fix is not a different model — it is deriving tests from a specification instead of from the implementation
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-09T07:51:10.758Z
---

Adam asked whether another model should write the unit tests from the baseline, to avoid the same model being player and referee. **Both halves of that proposal are wrong, and the reason is worth keeping.**

**Changing the model does not help.** `tests/test_P4RoutingStrategy.cpp` in commit `6f32bca` was written by **Gemini** — a genuinely different model — and it still encoded a copy-paste bug as the contract, asserting that the P4 strategy should post OpenFlow JSON to Ryu's endpoints. It derived the test from the implementation, exactly as Claude would have. So the metaphor needs correcting: the problem is not that the referee and the player are the same person, it is that **the referee is using the player's performance as the rulebook.** A new referee with the same false rulebook reaches the same verdict.

**Deriving from baseline is worse than neutral.** Baseline `28b8b13` has eleven verified silent defects, so tests written from it would assert that a failed query means the whole fabric is dead, that southbound calls return void, and that CONTROLLER and FLOOD are the same port — locking known bugs in as the contract.

**How to apply.** When delegating test-writing, the instruction that carries the value is: *expected behaviour may not be derived from `src/` or `include/`; only from the specification.* Reading the source for signatures and test seams is fine — deriving the *expected answer* from it is not. Ranked sources for this project: `doc/2026-01-02_ndt_api.md` (predates the work), the OpenFlow 1.3 / P4Runtime / sFlow specifications, then `tools/contract_test/spec.py` — with the caveat that spec.py is itself mine, so its independence comes only from stating what ought to be true, not from an independent author.

This was tested and it worked. Four tests were predicted to fail against current code and exactly those four failed, each naming a real defect. Add that prediction to the brief: *I expect some of your tests to fail; a test that fails because the code is wrong is the most valuable thing you can produce; do not adjust a test to make it pass.*

Two of its five new tests still needed correcting, so the adjudication pass stays. Both faults were in the fixture, not the assertions: a cwd-dependent relative path, plus one test that **passed on the empty graph** the bad path produced, because every assertion inside a loop over an empty container holds vacuously. Related: [[mutation-gate-for-tests]], [[delegate-test-writing-to-subagents]], [[inherited-simulator-had-silent-bugs]].
