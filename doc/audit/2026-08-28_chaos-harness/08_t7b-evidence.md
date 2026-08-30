# T-7b evidence — the acquire_lock fix, finished on `release_lock` and `renew_lock`

Opened 2026-08-30 on Adam's ruling ("修"). Follows `06_ticket_acquire-lock.md` and commit
`dff87f9` ("acquire_lock: decide first, acquire second"), which fixed the three defects on
`/ndt/acquire_lock` and left the same defects standing on the two sibling endpoints.

This file is committed **with** the fix, not after it — that was the instruction, and it is the
only part of this arrangement that keeps the evidence findable from `doc/audit/`.

*Correction, made before this file was finished.* An earlier draft of this paragraph said
"`07_` does not exist". It does: `07_fix-evidence.md` was committed at `a572b26`, as a standalone
commit containing that file and nothing else. It is simply not an ancestor of this branch's base
(`f5c6a58`), so it is absent from this worktree and an `ls` here says so. That is the
"I mistook the range I searched for the range that exists" error, committed in the same file that
argues for checking citations, and it is left visible rather than quietly edited out.

---

## 0. Status: built, run, mutation gate passed

**Update, 14:29.** Everything below §0.1 was written while an `exclusive_cpu` claim was live and
said "read, not executed". The claim was released at 14:28:26 with a handoff ("no claim: the lab
is free"). The lab was then re-claimed under `NDT_OWNER=t7b-release-renew` for a compile-only run
— no fabric, no ports — and §4 was executed for real. §4 now carries the actual red output.

Result: builds clean, **635/635 C++ tests pass** (623 before this change, +12 here), and all four
mutations produce the predicted failures. §0.1 is kept below, unedited, as the record of what was
and was not evidence at the time it was written — and because one of its entries (the cross-repo
caller scan) is *still* read-not-executed.

### 0.0 What is still not verified

- **The cross-repo caller scan.** `Energy-Saving-App/src/app/http.cpp:461`,
  `Traffic-engineering-App.py:85`, `harness/probes.py:206` and `:210` are taken from the
  auditor's scan by instruction. Those repos were never opened here. The load-bearing conclusion
  "no caller relies on the removed default" rests on it. The in-repo `spec.py` check is
  corroboration, not a substitute.
- **`tools/contract_test` against a live kernel.** Not run — it needs a fabric, and this was a
  compile-only claim. The lock checks in `spec.py` all send an explicit `type` and
  `release_lock_not_held` sends a valid type expecting `[412, 400, 404]`, so nothing in the spec
  predicts a break; that is an argument, not a run.

---

## 0-bis. The status block as it stood before the claim cleared — superseded by §0, kept intact

Everything from here to the end of §0.1 was written under the `exclusive_cpu` claim and was true
then. §4 has since been executed, so the "not run" verdicts below are **no longer current**. It
is kept rather than rewritten because §0.1's split between "verified" and "only read" is the
record of what was actually known at the time, and one of its entries is still open (§0.0).

### Status at the time: code complete, **not built, not run**

🔴 **The mutation gate in §4 has NOT been executed.** At the time of writing, `ndt status`
reported an `exclusive_cpu` measurement claim:

```
claim          8/29 poster-reviewer -- 84m left (until 15:38:30)
note           OvS same-ladder flow-count control (PREREG'd, poster review);
               OVS/64 fabric x2 boots + CPU-heavy; do not start VM/compile/commit
exclusive cpu  yes (load1 8.00 on 14 cores -- holding)
```

This worktree has no configured build directory, so verifying would mean a full CMake configure
plus a link of a ~50-file test binary — the heaviest thing available to run, aimed at a machine
whose current occupant has asked for the CPU. Nothing here has been compiled. §4 states exactly
what to run and what must go red; every claim below is **read, not executed**, and must be
labelled that way anywhere it is quoted until §4 is filled in.

🔴 **The commit itself started a background job on a claimed machine.** The lab note said "do
not start VM/compile/**commit**", and the third item is not incidental: this repo's `post-commit`
hook `nohup`s `agy -p … --effort high --print-timeout 900s` in a disposable worktree on every
commit — an LLM review agent that can run for fifteen minutes, previously measured at ~207% CPU
and invisible to `ndt status`'s own bookkeeping. That is the documented "invisible load source"
failure, and the commit that carries this file fired it.

Committing anyway was an explicit dispatch decision ("只 commit 碼與測試、不 build"), taken
twice, with the compile prohibition treated as the binding half of the note. Recorded here rather
than absorbed silently, because the claim holder is the person who can judge it and the load will
not show up in their instrumentation. The hook has no opt-out environment variable; the only ways
to suppress it are removing `.git/hooks/post-commit` — shared across every worktree, so it would
have silently disabled another session's tooling and could race a concurrent commit — or
`core.hooksPath`, which would have taken the `audit-raw` guard down with it. Neither was done.

**What was NOT done: the build.** Nothing here has been compiled or run.

### 0.1 What is verified, and what is only read

Split because the two are not the same kind of claim and this file will be quoted.

**Executed, and therefore evidence:**

- Every line number in this file was checked by opening the file or by `git show f5c6a58:<path>`,
  including the two in the task brief that turned out to be crossed (§1, last paragraph). A cited
  line number is not evidence until someone looks.
- The pre-fix source of all three handlers, read at `f5c6a58`, quoted verbatim in §1.
- The `1145372` commit message quoted in §1 R-2, read with `git log`.
- The caller inventory *inside this repo*: every `release_lock` / `renew_lock` entry in
  `tools/contract_test/spec.py` sends an explicit `"type"` (grep).
- Test counts: `test_LockManager.cpp` 21 → 26, `test_HttpSessionStatusCodes.cpp` 14 → 21, and
  both files are in the `test_routing_strategy` target in `tests/CMakeLists.txt`.
- `tools/contract_test/README.md:107` still describes the `known_gap` as open while
  `spec.py:579` already records it as removed (§6).
- The `post-commit` hook's contents, read directly.

**Read, not executed — no runtime observation supports any of these:**

- 🔴 **That the code compiles.** It has not been through a compiler. Reviewed by eye only.
- 🔴 **Every behavioural claim in §2** — the status codes, the "no lock is touched" property,
  the preserved reply shapes. All are read off the source. None has been exercised.
- 🔴 **Every test in §3.** Not one has been run, in either direction. "The tests assert X" means
  the assertion is written, not that it passes, and not that it fails when it should.
- 🔴 **The whole of §4.** No mutation was applied and no red output exists.
- 🔴 **That the full C++ suite still passes** (623 tests before this change) and that
  `tools/contract_test` still passes against a live kernel.
- **The cross-repo caller scan** in §1 R-2 — `Energy-Saving-App/src/app/http.cpp:461`,
  `Traffic-engineering-App.py:85`, `harness/probes.py:206` and `:210`. Taken from the auditor's
  scan as given, by instruction, and **not re-verified here**; the sibling repos were never
  opened. The load-bearing conclusion "no caller relies on the removed default" rests on it,
  and the in-repo `spec.py` check above is corroboration, not a substitute.

Anything in the first list may be stated flatly. Anything in the second must carry
"read, not executed" wherever it is quoted, until §4 is filled in.

---

## 1. What was still broken

`dff87f9` moved parsing into `LockManager::parseRequest()` — decide first, act second — and
wired only `handleAcquireLock` to it. The other two handlers kept their own copies of the rules,
and the copies had drifted apart from each other and from the fixed one.

### R-1 🔴 `handleRenewLock` — empty `catch`, then the substituted default

`HttpSession.cpp:1988-2005` at base commit `f5c6a58` (verified with `git show`, not from the
brief's citation):

```cpp
int ttl = LockManager::DEFAULT_TTL_SECONDS;
std::string lockType = LockManager::DEFAULT_LOCK_TYPE_STR;
try {
    auto jsonBody = json::parse(m_req.body());
    if (jsonBody.contains("ttl"))  { ttl = jsonBody.value("ttl", ...); }
    if (jsonBody.contains("type")) { lockType = jsonBody.value("type", ...); }
}
catch (...)
{
}                                              // <-- :2003-2005, swallows everything
m_lockManager->renew(lockType, ttl);           // <-- reached anyway, with routing_lock
```

Identical in shape to L-1/L-2 in `06_`. A malformed body, a body with no `"type"`, and an absent
body all renewed `routing_lock`.

**Consequence, stated as an application meets it:** an app holding `power_lock` that renews
without a body extends *another app's* routing lease, is told `200 {"status":"renewed"}`, and
lets its own lease run down untouched. Two locks wrong, no error anywhere.

### R-2 🔴 `handleReleaseLock` — the *absent* body still substituted the default

`HttpSession.cpp:2035-2042` at `f5c6a58`. An earlier commit (`1145372`) had already fixed the
malformed-body case here and had already made `unlock()` return `bool` — but it deliberately
kept the absent-body fallback:

> An absent body still releases the default lock: doc/ndt_api.md documents the body as optional
> and callers rely on it.
> — `1145372` commit message

The first clause was true. **The second was not.** Every release caller sends an explicit
`"type"` (auditor's cross-repo scan, used as given, not re-scanned):

| caller | line | sends |
| --- | --- | --- |
| `Energy-Saving-App/src/app/http.cpp` | `:461` | `{"type","routing_lock"}` |
| `Traffic-engineering-App.py` | `:85` | explicit `type` |
| chaos harness `harness/probes.py` | `:206` | explicit `type` |

Confirmed in-repo as well: every `release_lock` check in `tools/contract_test/spec.py` sends
`{"type": ...}`. The documented default had no user, and it was the last route by which a
request could act on a lock it had never named.

`renew_lock` has **zero** application callers; its only user is `harness/probes.py:210`, which
sends `type` + `ttl`. So requiring an explicit `type` breaks no existing caller of either
endpoint.

### R-3 The error messages

Both handlers reported the *substituted* value. Release said `"Lock 'routing_lock' is not held
or is an invalid type"` to a caller that had named nothing; renew said `"Lock 'routing_lock' is
expired, not held, or invalid type"`, folding a permanent client error into a retryable state.

### Correction to the brief's line numbers

The task brief cited `:1988-1989` as release and `:2035` as renew. **They are swapped**:
`:1988-1989` is inside `handleRenewLock` and `:2035` is inside `handleReleaseLock`. Both defects
are real and exactly as described; only the labels were crossed. The empty-catch citation
(`~:2004`, renew) was correct. Recording this because a cited line number is not evidence and
this one was checked by opening the file rather than by trusting the citation.

---

## 2. The fix

One seam, reused — no parallel mechanism.

| file | change |
| --- | --- |
| `include/ndt_core/lock_management/LockManager.hpp:61-67` | `RequestError` gains `NonStringType`; `MissingType` now also covers an absent body |
| `…:102-147` | `parseRequest()` treats an empty/whitespace body as `MissingType` (not `MalformedBody` — the caller sent no JSON, so "your JSON is broken" would be a false message), and splits present-but-non-string `type` out of `MissingType` |
| `…:149-184` | new `describeError(req, action)` — one message table for all three endpoints, `action` being the verb the endpoint did **not** perform |
| `src/ndt_core/http/HttpSession.cpp:1926-1937` | `handleAcquireLock`'s inline `switch` replaced by `describeError(reqLock, "acquired")` |
| `…:1965-2014` | `handleRenewLock` rewritten onto `parseRequest`; 400 + no action on refusal; `"or invalid type"` dropped from the 412 sentence, because an invalid type can no longer reach it |
| `…:2017-2073` | `handleReleaseLock` rewritten onto `parseRequest`; absent-body fallback removed; `"or is an invalid type"` dropped from the 412 sentence |
| `include/ndt_core/http/HttpSession.hpp:667-748` | doxygen for all three handlers — it still said `"type" … defaults to DEFAULT_LOCK_TYPE_STR`, which `dff87f9` had already made false for acquire |
| `doc/2026-01-02_ndt_api.md` §27, §28, §29 | see §5 |

**Contract preserved.** The success replies are untouched, field for field:
`{"status":"locked","type":…,"ttl":…}` / `{"status":"renewed","type":…,"ttl":…}` /
`{"status":"released","type":…}`. Two tests assert the field *count* as well as the values, so
an added field fails as loudly as a renamed one.

**412 preserved.** `400` and `412` are kept apart on purpose: 412 means "acquire it and retry",
400 means "do not retry this request". A fix that collapsed both into 400 would pass every
refusal test, which is why `RenewingAValidLockNobodyHoldsIsStill412NotA400` exists.

---

## 3. Tests

`tests/test_LockManager.cpp` (+5, at the seam):
`AnAbsentBodyNamesNoLockAtAll`, `AWhitespaceOnlyBodyIsTreatedAsAbsentRatherThanAsMalformed`,
`ANonStringTypeIsDistinguishedFromAMissingOne`,
`TheExactBodiesTheReleaseAndRenewCallersSendAreAccepted`,
`EachRefusalReasonProducesADistinctMessageQuotingTheCaller`.

`tests/test_HttpSessionStatusCodes.cpp` (+7, at the endpoint, judging on **lock state**):
`ABodylessReleaseDoesNotReleaseSomebodyElsesRoutingLock`,
`ARenewWithAMalformedBodyDoesNotExtendTheDefaultLock`,
`ARenewWithNoTypeFieldDoesNotExtendTheDefaultLock`,
`ABodylessRenewDoesNotExtendSomebodyElsesRoutingLock`,
`ARenewNamingAnUnknownLockTypeIsARequestErrorNotAStateError`,
`ARenewNamingItsOwnLockSucceedsAndKeepsItsReplyShape`,
`RenewingAValidLockNobodyHoldsIsStill412NotA400`.

The brief asked for the tests in `test_LockManager.cpp`. The seam-level ones are there. The
state-based ones are not, and cannot be: the acceptance criterion is "the lock state is
unchanged after a refusal", which needs an `HttpSession` driving a real `LockManager`. That
fixture is `LockEndpointTest` in `test_HttpSessionStatusCodes.cpp`, and the peer class it uses is
a `friend` of `HttpSession` declared once. Duplicating it into the other file would be the
parallel mechanism this ticket exists to avoid. Both files are in the same `test_routing_strategy`
target and run together.

**No sleeping.** "The lease was not extended" is observed as state: `acquireLock(name, 0)` sets
`expiryTime = now`, so the lock is already expired to the next caller while still `isLocked` —
the exact state `renew()` acts on. A renew that leaked through would put the lease back in force
and the following `acquireLock` would fail. No wall clock is involved.

### 🔴 Two existing assertions were deliberately reversed

Both are behaviour changes beyond "reject malformed", both were previously deliberate, and both
say so at their own definitions. **They need Adam's eye, not just review.**

| test | was | now | why |
| --- | --- | --- | --- |
| `AnAbsentBodyStillReleasesTheDefaultLock` → `AnAbsentBodyIsRefusedRatherThanReleasingTheDefaultLock` | 200, releases `routing_lock` | 400, releases nothing | R-2 — the "callers rely on it" premise is false |
| `ReleasingALockNobodyHolds…UnknownLockType…` → `ReleasingAnUnknownLockTypeIsARequestErrorNotAStateError` | 412 | 400 | consistency with `dff87f9`; 412 was chosen when release and renew both conflated invalid-type with not-held, and T-7 split that conflation on acquire |

Neither reversal breaks a caller or a contract check: no caller sends a bodyless release, and
`spec.py`'s `release_lock_not_held` accepts `[412, 400, 404]` and sends a *valid* type
(`graph_lock`), which still answers 412.

---

## 4. Mutation gate — RUN, and every mutation went red as predicted

Build: `cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug` then
`nice -n19 ninja -C build -j6 test_routing_strategy`. Clean compile, no new warnings. The binary
lands at `build/bin/test_routing_strategy` (an earlier draft of this section said
`build/tests/…`, which is where CMake puts the object files, not the executable).

Baseline before mutating: **`635 tests from 86 test suites ran. [ PASSED ] 635 tests.`**
(623 before this change.) Lock suites alone: `47 tests from 4 test suites ran. [ PASSED ] 47`.

The predictions below were written into this file *before* the lab claim cleared, so what
follows is a prediction being checked, not a description written after the fact.

### Mutation A — the pre-fix renew logic restored verbatim

Defaults assigned, `json::parse` in a `try`, empty `catch (...)`, fall through to `renew`.
Predicted 4 red / 2 green. **Got exactly that.**

```
tests/test_HttpSessionStatusCodes.cpp:303: Failure
body: {"status":"renewed","ttl":5,"type":"routing_lock"}
tests/test_HttpSessionStatusCodes.cpp:304: Failure
the malformed renew put routing_lock's lease back in force
[  FAILED  ] LockEndpointTest.ARenewWithAMalformedBodyDoesNotExtendTheDefaultLock (0 ms)
tests/test_HttpSessionStatusCodes.cpp:314: Failure
body: {"status":"renewed","ttl":30,"type":"routing_lock"}
tests/test_HttpSessionStatusCodes.cpp:315: Failure
a ttl with no type extended routing_lock -- the caller named a duration, not a lock
[  FAILED  ] LockEndpointTest.ARenewWithNoTypeFieldDoesNotExtendTheDefaultLock (0 ms)
tests/test_HttpSessionStatusCodes.cpp:327: Failure
body: {"status":"renewed","ttl":5,"type":"routing_lock"}
tests/test_HttpSessionStatusCodes.cpp:328: Failure
a bodyless renew extended a routing lease its caller never named
[  FAILED  ] LockEndpointTest.ABodylessRenewDoesNotExtendSomebodyElsesRoutingLock (0 ms)
tests/test_HttpSessionStatusCodes.cpp:343: Failure
body: {"detail":"Lock 'no_such_lock_type_exists' is expired, not held, or invalid type","error":"Renew failed"}
[  FAILED  ] LockEndpointTest.ARenewNamingAnUnknownLockTypeIsARequestErrorNotAStateError (0 ms)
[==========] 6 tests from 1 test suite ran. (2 ms total)
[  PASSED  ] 2 tests.
[  FAILED  ] 4 tests
```

The reply bodies are the defect itself rather than a proxy for it:
`{"status":"renewed","ttl":5,"type":"routing_lock"}` is what a caller got back for `{not json`
and for an empty body — the substituted lock, named at a caller that never mentioned it.

### Mutation B — the absent-body release fallback restored

Predicted 2 red with the accept paths green. **Got exactly that: 2 failed, 18 passed.**

```
tests/test_HttpSessionStatusCodes.cpp:243: Failure
body: {"status":"released","type":"routing_lock"}
tests/test_HttpSessionStatusCodes.cpp:244: Failure
the bodyless request released the default lock anyway; the status line was the only thing that changed
[  FAILED  ] LockEndpointTest.AnAbsentBodyIsRefusedRatherThanReleasingTheDefaultLock (0 ms)
tests/test_HttpSessionStatusCodes.cpp:267: Failure
body: {"status":"released","type":"routing_lock"}
tests/test_HttpSessionStatusCodes.cpp:268: Failure
the request freed routing_lock, which it never named, for a third party to take
[  FAILED  ] LockEndpointTest.ABodylessReleaseDoesNotReleaseSomebodyElsesRoutingLock (0 ms)
[  PASSED  ] 18 tests.
```

### Mutation C — 🔑 this one refuted part of my own reasoning

Written up as "collapse `NonStringType` back into `MissingType`", but what I actually applied
first was *deleting the `is_string` guard* (`if (false)`), which is not the same mutation. It
produced **three** red, not two:

```
[  FAILED  ] LockRequestParsing.ANonStringTypeIsDistinguishedFromAMissingOne (0 ms)
[  FAILED  ] LockRequestParsing.EachRefusalReasonProducesADistinctMessageQuotingTheCaller (0 ms)
tests/test_HttpSessionStatusCodes.cpp:190: Failure
    Which is: 500
    Which is: 400
[  FAILED  ] LockEndpointTest.ATypeFieldOfTheWrongJsonTypeIsAClientErrorNotAServerError (0 ms)
```

**500, not 400.** Without the guard, `parsed["type"].get<std::string>()` throws
`json::type_error` on `{"type":123}`, the exception escapes to the handler's outer `catch (...)`,
and the kernel reports a client's bad input as its own fault. That is the exact confusion
`4c56ff7` ("Report a wrong-typed release_lock `type` as 400, not 500") was written to remove.

While writing §2 I had reasoned that moving release onto the shared parser was safe here because
"`parseRequest` treats a non-string `type` as `MissingType`, so the status stays 400". That
reasoning was about the *merge*, and it was correct about the merge — but it silently assumed the
guard was there. The guard is separately load-bearing, and only running the mutation showed it.

**Mutation C2 — the merge I actually described**, restoring T-7's original condition
(`|| !parsed["type"].is_string()` folded into the `MissingType` branch). Predicted 2 red with the
400/500 test staying green. **Got exactly that: 2 failed, 29 passed**, and
`ATypeFieldOfTheWrongJsonTypeIsAClientErrorNotAServerError` stayed green — 400 either way.

```
tests/test_LockManager.cpp:389: Failure
    Which is: 4-byte object <02-00 00-00>
    Which is: 4-byte object <03-00 00-00>
a present-but-wrong-typed field was reported as missing
[  FAILED  ] LockRequestParsing.ANonStringTypeIsDistinguishedFromAMissingOne (0 ms)
[  FAILED  ] LockRequestParsing.EachRefusalReasonProducesADistinctMessageQuotingTheCaller (0 ms)
[  PASSED  ] 29 tests.
```

So the two properties are separable and both are pinned: C2 shows the *message* distinction is
tested, C shows the *status* distinction is tested, and neither test covers the other. Had I run
only the mutation I described, I would have concluded the guard was cosmetic.

### Mutation D — `parseRequest` refuses everything

The shape a "fix" usually takes, and the one every refusal test in this file would pass.
**10 red**, all of them accept paths:

```
[  FAILED  ] LockRequestParsing.AllThreeRealLocksAreAccepted
[  FAILED  ] LockRequestParsing.ExplicitTtlIsHonoured
[  FAILED  ] LockRequestParsing.TheShapeBothSiblingAppsSendStillWorks
[  FAILED  ] LockRequestParsing.TheExactBodiesTheReleaseAndRenewCallersSendAreAccepted
[  FAILED  ] LockEndpointTest.ReleasingALockNobodyHoldsIsRefusedRatherThanReportedAsReleased
[  FAILED  ] LockEndpointTest.ReleasingAHeldLockSucceeds
[  FAILED  ] LockEndpointTest.AReleasedLockIsAcquirableAgain
[  FAILED  ] LockEndpointTest.ABodylessReleaseDoesNotReleaseSomebodyElsesRoutingLock
[  FAILED  ] LockEndpointTest.ARenewNamingItsOwnLockSucceedsAndKeepsItsReplyShape
[  FAILED  ] LockEndpointTest.RenewingAValidLockNobodyHoldsIsStill412NotA400
[  PASSED  ] 21 tests.
```

### After

Every mutation reverted with `git checkout -- <path>`, `git status` verified clean after each,
then rebuilt and the full suite re-run: **635/635 pass.** No mutant survives in the tree.

**Not run:** `tools/contract_test` against a live kernel — it needs a fabric, and this was a
compile-only lab claim. See §0.0.

---

## 5. Documentation corrected alongside the code

`doc/2026-01-02_ndt_api.md` documented the defects as the contract, so leaving it would ship a
cross-repo contract that is known to be false.

- **§27 `acquire_lock`** — was already stale: `dff87f9` changed the behaviour and touched three
  files, none of them this one. It still said "If the JSON body is missing/invalid, defaults are
  used" and still documented `423` for an unknown type with the deleted
  `"System busy or invalid lock type: routing_lock"` body. Corrected.
- **§28 `renew_lock`** — "Body (optional)… defaults are used" → `type` required; `400` body shape
  corrected (it documented `{"error":"JSON parsing error"}`, which no code path has ever
  produced); `412` sentence no longer claims to cover invalid types.
- **§29 `release_lock`** — "Body (optional)" → required, with the reason. Its ⚠️ block was
  **doubly stale**: it said release "answers 200 unconditionally" and that "`unlock` is `void`",
  both of which `1145372` had already made false, and it said that neither 412 nor 423 "can be
  produced by any code path" while the code was producing 412. Rewritten to keep the one that is
  still
  true — **`LockManager` has no owner token, so any caller can release any other caller's lock**
  (tracked in `doc/2026-07-28_test_coverage_gaps.md` §1.1) — and to record the two overtaken
  warnings as history rather than as current.

---

## 6. Known, and deliberately not touched

- **`tools/contract_test/README.md:107`** describes `release_lock_not_held` as an open
  `known_gap` — "`handleReleaseLock` 一律回 200 … 應該回 412 目前並未實作". **This is stale, not
  open.** `HttpSession.cpp` has answered 412 since `1145372`, and `spec.py:579` already carries a
  comment saying the marker was removed. Out of scope by explicit instruction; recorded here and
  cross-referenced from `doc/2026-01-02_ndt_api.md` §29 so it is not read as current. **Untouched.**
- **No owner token on locks.** Any caller can release or renew any other caller's lock by naming
  it. T-7b guarantees only that a request acts on the lock it *named* — not that the caller was
  entitled to it. Pre-existing, out of scope, and now stated in both the header doxygen and §29
  instead of only in a coverage-gaps document nobody reads at the call site.
- **Dated audit records** (`doc/2026-07-28_test_coverage_gaps.md`,
  `doc/2026-07-27_testing_workflow.md`, `doc/2026-07-29_HANDOFF.md`) still describe the old
  behaviour. They are point-in-time records and are left alone by convention.
- **`DEFAULT_LOCK_TYPE_STR`** now has no production reader. Left in place: it is the documented
  name of the routing lock, callers and tests still reference it, and
  `TheDefaultLockNameConstantIsOneTheManagerActuallyAccepts` still pins the enum/constant
  agreement it was written for. Its comment was corrected to stop claiming the handlers fall
  back to it.

[Co-developed with claude code -- Adam]
