---
name: delegate-test-writing-to-subagents
description: "Adam's standing preference (2026-08-07): default to having subagents write tests. Delegate the test-writing; keep production-seam design and the verification pass for myself"
metadata:
  node_type: memory
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-09T07:52:45.589Z
---

Adam asked (2026-08-07) that from now on I consider routing **test writing** to subagents by default, rather than writing it all myself.

**Why:** it worked. Two parallel agents produced 219 tests in one afternoon (145 Python, 74 C++) against a budget where writing them inline would have consumed the session. My verification pass — sampling their mutation tables and re-running the mutations myself — cost a small fraction of what writing them would have.

**How to apply:**

- **The single most important clause is about the source of truth, not the mutation gate:** forbid deriving expected behaviour from `src/`, and name the specification to use instead. Without it, a delegated test encodes whatever the code already does — which is how a Gemini-written test file shipped a copy-paste bug as the contract. See [[test-independence-is-the-spec-not-the-model]], which also gives the falsifiable acceptance check: predict which tests will fail, and be right.
- Put the mutation gate **in the delegation prompt**, not in a later review step: every test ships with the exact mutation that breaks it, applied and observed, and any test with no mutation gets deleted. An agent required to produce that table cannot hand back tests it never ran. See [[mutation-gate-for-tests]].
- Tell them to **append the mutation table to a file as they go**. Both agents were killed mid-run by a session limit; the first pair lost all their evidence, the second pair kept it because they were writing incrementally.
- Give each agent a **distinct scratchpad prefix** — two agents collided on a shared driver file on the first attempt.
- **Verify, don't accept.** Sample rows from their table and re-run the mutations independently. On the C++ side the table turned out to record mutations as prose rather than literal patches, so nothing could be replayed mechanically; the Python side was literal and 18/18 sampled rows held.
- **Keep for myself:** anything needing a *production* seam or a design decision — the `HttpSession::buildResponse` split, the flow-table lock hoist, `counterDelta`. Those change shipped code, and the judgement about where the seam goes is the work. Delegating the tests around an existing seam is cheap; delegating the seam is not.
- Agents that flag their own unproven tests (`NO-FAILURE`) are doing the right thing — that honesty is more valuable than a fuller-looking table, and those rows are where the genuinely hard structural findings turned out to be.
