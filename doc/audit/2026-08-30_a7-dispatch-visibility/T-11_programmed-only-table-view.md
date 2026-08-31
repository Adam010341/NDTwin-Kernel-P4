# T-11-A — the table listing reports only entries that were actually programmed

[Co-developed with claude code -- Adam]

Written by 8/29 mainDev. Adam ruled **option A** (2026-08-30 21:58), relayed by the auditor with
the spec. Built on top of A-7 (`2016d4c`, `636f9ab`, `30eb6d7`) — the confirmation signal is the
seam A-7 left open, and filling it needed no change to any call site, which was the point.

## The defect, at the line

`processFlowBatch` enqueues the jobs and then calls `updateOpenFlowTables(...)` — the line marked
`// TODO: Immediately update the table` — **synchronously, on the HTTP thread**. That writes the
*requested* rule into the table cache before the dispatcher has sent anything. Until the periodic
poll overwrites the cache, `GET /ndt/get_switch_openflow_table_entries` serves it as a table entry.

That is FINDING-03's phantom, and per the FINDING-06 correction the window is the **cache refresh**
cycle (a fixed 10 s sleep plus one southbound poll ≈ 10.7 s), not a dispatch cycle. The rule is
very likely programmed within milliseconds; what lasted ~10.7 s was the *view* being wrong.

## What was built

**Provenance by token, never by fingerprint.**

| | |
|---|---|
| `FlowJob::token` | opaque, process-wide monotonic, minted once per install |
| `kPendingTokenField` | the stamp on the cached row, declared beside the token so writer/stamper/filter cannot drift on a spelling |
| `DispatchOutcomeLog::isProgrammed(token)` | the confirmation index — the A-7 seam, now filled |
| `stripUnprogrammedEntries()` | the rule, extracted so it is testable without the power manager |
| `DeviceConfigurationAndPowerManager::setProgrammedPredicate` | injection point; wired once in `main.cpp` |

**Why not compare contents.** Neither candidate identity survives the trip. FINDING-07 established
every rule is programmed at priority 0 whatever was requested; and the cached copy carries the
caller's vocabulary (`ipv4_dst`) while a polled one carries the switch's (`nw_dst`). Matching a
pending row against a confirmation by comparing fields would be comparing two spellings of two
different values. A token cannot be wrong about where a row came from.

**Why not the FINDING-03 signature.** Four fields, no counters, caller vocabulary — that signature
is real and it is what *detected* the phantom. Keying the *fix* on it would make the instrument the
same shape as the thing it measures: a polled row that arrived without counters would vanish, a
pending row that looked complete would survive. `TheFilterIsKeyedOnProvenanceNotOnLookingLikeARequest`
is the test that pins this, using two rows that each look like the other.

**Why the filter is in `getOpenFlowTables()` and not in the endpoint.** Three callers read that
cache — the endpoint, `LLMAgent.cpp:275`, `IntentTranslator.cpp:1069`. A filter in the handler
would have left the other two reading the phantom, which is how "we fixed the view" becomes true of
one view. The kernel table view is the common source, so the fix is at the source.

**Both defaults are conservative, deliberately.** An unset predicate withholds every tokened row;
an aged-out token (the index is bounded at 8192) reads as unconfirmed. Both fail toward *a real
entry briefly hidden*, never toward *a phantom shown*. The symptom of a dropped wire in `main.cpp`
is entries missing for up to one poll interval — visible and safe — rather than the phantom
silently returning. The window is self-limiting anyway: the poll replaces the whole cache.

## Results

**Full suite 655/655** (was 647; +8). `ndtwin_kernel` builds.

| # | Mutation | Verdict |
|---|---|---|
| **T1** | filter never withholds — the phantom mutation | 🔴 RED (3 tests) |
| **T2** | untokened rows withheld too | 🔴 RED (3) — this is the "empties the entire view" direction |
| **T3** | internal stamp not stripped | 🔴 RED |
| **T4** | `isProgrammed` always true | 🔴 RED (2) |
| **T5** | a refused rule confirms its own token | 🔴 RED |
| **C1** | green control (default capacity 256→512) | ✅ GREEN, all 28 |

🔴 **T5 first came back `SKIP — pattern matched 0 times`**: the anchor was written with 12 spaces
of indentation and the code has 8. A skipped mutation is not a passed one, and the harness printed
it plainly rather than folding it into the pass count — which is the only reason it was noticed and
re-run. Second time: RED. Counting a SKIP as coverage is how a mutation table comes to overstate
what it checked.

## 🔴 The acceptance for this ticket was run inside someone else's measurement window

The build, the T1–T5 mutation battery, the two full-suite runs and the commit `91e7743`
(22:33:17) all fell inside the `tr5-energy` claim, which began at **22:24** and ran to 00:24. The
window's note said `NO git commit repo-wide` and `do not start a compile`.

I had read `ndt status` at ~22:1x, seen `claim none` and a handoff saying *"no claim: the lab is
free"*, and then treated that reading as durable for the following twenty minutes. It was correct
when taken and stale by 22:24. **A status read is a point sample, not a lease.** A-7's own build
and commits (22:18) were in the legitimate gap; T-11's were not.

So the numbers in this ticket — T1–T5, C1, 655/655 — were produced by a process that was itself
contaminating a concurrent energy measurement. **They are still valid as a functional result**:
mutation verdicts and test outcomes do not depend on the machine being quiet. What is affected is
somebody else's data, not this ticket's. Full evidence and timeline:
[`WINDOW-VIOLATION_evidence.md`](WINDOW-VIOLATION_evidence.md).

## Not covered — stated so it is not read as done

- 🔴 **The live acceptance the auditor specified has NOT been run.** Both halves need a fabric
  (force-red: re-expose the queue and confirm FINDING-03's t=0 recipe catches the phantom again;
  force-green: install a real rule, absent at t=0, present after the southbound confirms). The
  fabric was torn down at 21:53. **The unit tests assert both directions, but on the filter, not on
  the running kernel.** Until that runs, this ticket is verified in the small only.
- **Only installs are tokened.** A refused *modify* leaves the cache showing a mutation that never
  reached the switch; a refused *delete* removes a row that is still programmed. Those are the
  mirror of this defect — under-reporting rather than over-reporting — and this change does not
  address them. Registered here rather than folded in silently.
- **A confirmed row still carries the request's shape until the next poll**: requested priority
  (which FINDING-07 proved is not what was programmed) and the caller's field vocabulary. So the
  view now reports only rules that exist, but for up to one poll interval it may report one of them
  with a priority the switch does not have. That is FINDING-07's ticket, not this one; conflating
  them would be scope creep, but it means "the listing is correct" is not yet true unqualified.
  **Measured 2026-08-31 (live acceptance batch, auditor)**: a legitimate rule displayed in
  request shape from t=0.272 s to t=7.630 s — **a 7.4 s window** — before the poll replaced it
  with the switch's own shape. The force-red run alone would support a stronger claim than the
  evidence does; this ticket removes never-programmed phantoms, not the request-shape display
  window of rules that will be programmed. State both halves wherever this ticket is cited.
- **OVS untested.** Everything reasoned here is from source common to both arms, but the phantom
  was characterised on P4/BMv2.
