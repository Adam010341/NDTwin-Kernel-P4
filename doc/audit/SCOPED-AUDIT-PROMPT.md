# Scoped code review: everything added since the last audit

[Co-developed with claude code -- Adam]

You are reviewing **only the changes in `be3c242..HEAD`** of the NDTwin-Kernel repository. A
full-repository audit already exists at `doc/audit-be3c242/` (10 stage summaries, base commit
`be3c242`). Do not repeat it. Every line you review must be a line that audit could not have seen.

```bash
git log --oneline be3c242..HEAD          # 24 commits
git diff --stat be3c242..HEAD            # 46 files, +4566 / -216
git diff be3c242..HEAD -- <path>         # the actual change for one file
```

Read the surrounding code for context freely — you need it to judge a change — but **report only
defects in, or caused by, this diff.** A pre-existing defect the diff merely touches is out of
scope unless the diff made it reachable, worse, or harder to see.

---

## Why this is scoped, and what that means for your standard of evidence

The first audit's findings were checked one by one. The result:

| | count |
|---|---|
| True, and now fixed | 6 |
| True, still open | 6 |
| **Judged wrong** | **4** |
| True but narrower than stated | 3 |

The four wrong ones were expensive to disprove, and that cost is why this brief is strict. The
clearest example: the audit reported that `inet_ntoa` in `utils::ipToString` caused "a global data
race, possibly a segfault", across 62 call sites. Disproving it took writing a C program to show
that glibc 2.39's `inet_ntoa` buffer is **thread-local** (the main thread's returned pointer differs
from a spawned thread's), plus an 8-thread / 160,000-iteration concurrency test that **passes
against unmodified `inet_ntoa`**. The change to `inet_ntop` was kept as a portability improvement,
but it fixed no bug, and the report's severity was wrong.

So:

- **Say how you verified each finding.** "Read the code and it looks wrong" is a hypothesis, not a
  finding — label it as one. If you ran something, give the command and the output.
- **Distinguish "this is reachable" from "this is theoretically possible."** Name the caller and the
  input. A race that requires two threads that never both exist is not a finding.
- **State the platform assumption when you rely on one.** Facts already established on this machine,
  so you neither re-derive nor contradict them:
  - glibc **2.39**; `inet_ntoa`'s buffer is thread-local here.
  - `std::hash<uint64_t>` on libstdc++ is the **identity function** (this caused a real bug: a
    hash-seeded power value produced 30001, 30002, ... mW).
  - `pclose()` and `std::system()` return a **wait status**, not an exit code (exit 1 → 256,
    exit 127 → 32512).
  - `/proc/PID/comm` is capped at 15 characters, so `pgrep -x simple_switch_grpc` never matches.
  - OpenFlow 1.3 `OFPFC_ADD` with an identical match and priority overwrites the existing entry.
- **A wrong finding is worse than no finding**, because someone has to spend an hour proving it
  wrong. If you are unsure, say you are unsure and say what would settle it.

---

## Out of scope — do not report these

1. **Shell injection through `popen("curl … -d '" + json.dump() + "'")`.** Known, catalogued
   (22 sites across 3 files, plus `SimulationRequestManager` and `SSHHelper`), and **deliberately
   deferred** by the repository owner pending a discussion. `nlohmann::json::dump()` does not escape
   single quotes; the JSON comes from unauthenticated REST bodies and LLM output. All of that is
   already written down in `doc/HANDOFF.md` §3. Reporting it again adds nothing.
   - **In scope**, however: any place in this diff that makes the exposure *worse*, or that could be
     mistaken for a fix. `SimulationRequestManager::validateRequestBody` was added in this diff and
     is explicitly shape-only; if you think its comments or its placement could lead a future reader
     to believe the body is sanitised, that is a finding.
2. **Anything already listed in `doc/HANDOFF.md` §2b** (the 12-item todo list) or §1h (the audit
   verdicts). Read both first. Examples of things already known and tracked: P4 switch liveness is a
   stub that reports every bmv2 switch up; `/ndt/disable_switch` does not exist while
   Energy-Saving-App calls it; `setSwitchPowerState` updates the graph regardless of the curl
   outcome; the LLDP beacon's hardcoded port range and colliding source MAC.
3. **Missing tests for code this diff did not touch.** The first audit made a factual error here —
   it reported `ryu_topology`, `kernel_notifier` and `topology_manager` as having no tests when they
   had 24, 13 and 9 respectively. Check before you claim absence: `grep` for a class name finds
   mentions in *other* files' comments.
4. **Style, naming, formatting, comment length.** The comments in this diff are deliberately long and
   explain why a change exists; that is intentional. Only report a comment if it is **wrong**.

---

## What to look at, in priority order

### Priority 1 — the new tests (~1900 of the 4566 added lines)

This is the highest-value target and the reason this review is worth doing, because it is the part
the author cannot reliably check alone. Two test files in this very diff were **written, run green,
and only then found to assert nothing that mattered**:

- `tests/test_Controller.cpp` — the first version passed with the bug it existed to catch
  reintroduced. Fixed by adding a `spdlog` capturing sink.
- `tests/test_SimulationRequestValidation.cpp` — a test named `RejectsNullAsAbsent...` never
  verified the "as absent" part; removing the `is_null()` check changed nothing observable, because
  null fell through to the type-error branch and was still rejected. A second test could not detect
  the required-field list shrinking, because it derived its expectations from that same list.

Both were caught by mutation testing, not by review, and both were written by someone who knew the
bug intimately. Assume more of the same survived.

Files: `tests/test_Controller.cpp`, `test_FlowDispatcher.cpp`, `test_IpToString.cpp`,
`test_KeyedFailureLog.cpp`, `test_OvsPowerStrategy.cpp`, `test_ParamParsing.cpp`,
`test_SimulationRequestValidation.cpp`, `p4_proxy/tests/test_unsupported_match.py`.

For each test, the question is not "is it correct?" but:

- **Would it fail if the bug it names came back?** Name the exact edit that should break it. If you
  can find an edit that reintroduces the defect and leaves the test green, that is a finding — the
  most valuable kind in this review.
- **Is it a tautology?** Does it derive its expected value from the same code it is testing (the
  same function, the same constant, the same list)?
- **Does the name or comment claim more than the assertions check?** An overclaiming test is worse
  than a missing one, because it tells the next reader the case is covered.
- **Would it pass against an empty/no-op implementation?** Several assert only that something was
  rejected, when the interesting part is *how*.
- Does it assert on a real object where it could, or does it mock so much that the assertion is
  about the mock? (`test_OvsPowerStrategy.cpp` deliberately drives a real
  `TopologyAndFlowMonitor`; check that the real object is actually exercised.)

### Priority 2 — new concurrency and lifecycle code

- `src/ndt_core/collection/FlowLinkUsageCollector.cpp` — `setAllPaths` now takes **two** mutexes via
  `std::scoped_lock(m_allPathMapMutex, m_switchCountMapMutex)`. `scoped_lock` avoids deadlock among
  its own users, but **check every other site that takes both**, in either order, separately. Also
  check the new `refreshDestinationPathsPeriodically` loop: it changed a once-at-startup fetch into
  a repeating one, which is what made the previously-harmless unlocked access matter.
- `src/ndt_core/routing_management/FlowDispatcher.cpp` — `stop()` now sets `running_` under `mtx_`
  and swaps `workers_` out before joining; `enqueue()` returns early when `!running_`. Look for
  remaining lost-wakeup and use-after-move windows, and for whether the destructor's second `stop()`
  is genuinely safe.
- `intelligent_router.py` — **entirely new**: `_schedule_route_reinstall`, `_route_reinstall_worker`,
  a 3-second debounce, and `on_link_delete`/`on_link_add` mutating a shared `net`. This runs on Ryu
  `hub` greenthreads, not OS threads. Check the debounce for lost or coalesced-away events, whether
  `install_all_pair_paths` can run concurrently with itself, and what happens if it raises.
- `src/ndt_core/routing_management/Controller.cpp` and `HttpSession.cpp` — the `OpResult` chain. Look
  for a path where a failure is still reported as success, and for the reverse: a success reported as
  a failure.

### Priority 3 — new logic that can silently do nothing

- `include/utils/KeyedFailureLog.hpp` — **entirely new**, 160 lines, edge-triggered failure reporting
  with a persistence hold-off. Its whole purpose is suppression, so a bug here **hides** other bugs.
  Specifically: can a failure be permanently suppressed? Can `m_open` grow without bound (keys are
  built from dpid/port pairs)? What happens if `endPass()` is called twice in one pass, or never?
- `include/utils/Utils.hpp` — `+169` lines including `tryIpStringToUint32`, `tryParseUint64` and
  `describeCommandStatus`. This is a header included nearly everywhere; check the new `<sys/wait.h>`
  and `<cstring>` includes do not break anything, and that `describeCommandStatus`'s `errno` read is
  valid at that point.
- `src/ndt_core/power_management/OVSPowerStrategy.cpp` — `executeListPorts` now returns
  `std::optional`, and `powerOff` refuses to delete a bridge whose ports it could not read. Check
  the refusal cannot strand a switch permanently, and that `powerOn`'s empty-saved-ports case (which
  builds a bridge with no ports and reports success) is the only remaining hole.
- `p4_proxy/proxy_agent/topology_manager.py` and `api_routes.py` — `UnsupportedMatchError` and the
  `HONOURED_MATCH_FIELDS` set. Check the set is complete with respect to what the kernel and the
  Intent Translator actually emit, and that the 400 reaches the caller rather than being swallowed.

### Priority 4 — the test tooling itself

`tools/test_workflow/stack.sh`, `run_layers.sh`, `tools/contract_test/spec.py` and the two allowlist
files. This tooling **decides whether the system is working**, so a false PASS here is worse than a
bug in the kernel. It has already produced two false passes that were found and fixed in this diff
(a convergence gate that counted the keys of a response envelope instead of the paths inside it; a
port-wait that reported success when a *different* process held the port). Assume more.

Pay particular attention to `baseline_diff_allowlist.txt` and `warning_allowlist.txt`: an entry that
is too broad silently hides a real regression. One entry in this diff was already removed for
exactly that reason after the suppressed warning turned out to fire 75,853 times.

---

## Output

Write one Markdown file per priority group into `doc/audit/scoped/`, named
`P1-tests.md`, `P2-concurrency.md`, `P3-logic.md`, `P4-tooling.md`, plus a `00-summary.md`.

For every finding:

```
### <short title>

- **File:line** — `path/to/file.cpp:123` (and the commit that introduced it)
- **Severity** — critical / high / medium / low, and say what the *consequence* is, not how it feels
- **Confidence** — verified / probable / hypothesis
- **How I checked** — the command you ran and its output, or the reasoning chain if you could not run it
- **Failure scenario** — concrete inputs or interleaving → wrong output, crash, hang, or silent no-op
- **Suggested fix** — one paragraph, or "unclear, needs a decision about X"
```

In `00-summary.md`, additionally answer these three questions directly:

1. **Which of the new tests would not fail if the defect it names returned?** Give the test name and
   the exact edit that leaves it green. This is the answer most wanted.
2. **What in this diff is a silent failure** — reports success, or logs nothing, when something did
   not happen?
3. **What did you check and find sound?** A short list. It matters: it tells the reader which parts
   were examined and cleared, so absence from your findings means "checked" rather than "not looked
   at".

Do not modify any file outside `doc/audit/scoped/`. Do not fix anything you find.

## Build and test commands

```bash
cmake --build build -j4                       # -j4, not -j$(nproc): -j14 exhausts 15 GB of RAM
./build/bin/test_routing_strategy             # run DIRECTLY, 207 tests -- see below
ctest --test-dir build --output-on-failure
PYTHONPATH=. pytest p4_proxy/tests/
```

Always run the gtest binary **directly** as well as through `ctest`. `ctest` runs one process per
test, which masks a suite-level failure — that is exactly how a previous bug hid, where two fixtures
both called `Logger::init` and the second threw `logger with name 'netdt' already exists`, so the
whole suite was silently SKIPPED while its assertions happened to codify the bug as intended
behaviour.
