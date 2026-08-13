# Codebase audit prompt — NDTwin-Kernel

Hand this whole file to the reviewing agent in a fresh session. It needs read access to
`/home/adam/Desktop/NDTwin-Kernel`. **Scope is that repository only** — not the sibling apps
(`Energy-Saving-App`, `Web-GUI`, etc.). The one exception is named under Theme C.

---

You are auditing the NDTwin-Kernel codebase for four specific classes of defect. This is not a
general code review — do not report style, naming, or architecture opinions. Four themes, and
nothing else:

- **A. AI hallucinations** — comments, docs, or code that assert something the code does not do.
- **B. Test-script completeness** — tests that cannot fail, and test harnesses that skip silently.
- **C. Hard-coded assumptions that break** — paths, ports, endpoints, credentials, magic values
  that are wrong outside one environment.
- **D. Silently swallowed errors** — failures reported as success, or an empty result standing in
  for a failed one.

## Ground rules — read these before your first tool call

- **Read-only.** No source edits, no `git add`, no commits, no `pip install`, no package
  installation of any kind. Everything you need is on disk. The only thing you create is the four
  report files named at the end.
- **Do not touch the running environment.** A live OVS stack is up (Ryu on `:8080`, the kernel on
  `:8000`) with a Mininet session attached to a terminal that is not yours. No `stack.sh up/down`,
  no `mn`, no `sudo`, no killing processes, no fault injection. You may read logs under
  `.test_run/logs/`.
- You **may** run `tools/test_workflow/l1_unit_tests.sh` and `cmake --build build -j$(nproc)` if a
  specific claim needs them. Both are self-contained and neither disturbs the running stack. Note
  the build is CMake+Ninja and is slow.
- Python tests need the project venv (`p4_proxy/venv/bin/python3`), never the system interpreter —
  conda's python lacks `grpc`/`networkx` and reports a broken suite as `OK (skipped=18)`.
- **Write findings incrementally**, as you go, not at the end. If the budget runs out mid-pass,
  nothing already found should be lost.
- **Fan out with subagents** across the passes listed below, and repeat the read-only constraint in
  every subagent prompt — they do not inherit it. Keep the *adjudication* for yourself: a
  subagent's finding is a hypothesis until you have opened the lines it cites.

## What is already known — do not spend the run rediscovering it

Re-reporting what has already been adjudicated is the main way this audit wastes its budget. Read
these first:

- **`doc/audit/codebase-review/ADJUDICATION_agy-reviews_0157-0201.md`**
  — 47 HIGH findings from the commit-review backlog, already triaged into Tier 1 (fixed), Tier 2
  (real, known, deliberately left), Tier 3 (deliberate trade-offs) and false positives. **Skip
  everything in it.** If you rediscover a Tier 2 item, you have spent budget for nothing.
- `git log --oneline --since=2026-08-11` — the worst items were fixed that day (`fbd8140`,
  `44fa86e`, `900d60b`, `7f738e6`, `42d86cd`). Check a finding is not already fixed before writing
  it down.
- **Three behaviours are deliberate, documented, test-locked trade-offs — do not flag them:**
  - `FlowLinkUsageCollector.cpp` `setAllPaths` ignoring an empty snapshot (30-line comment plus
    `tests/test_AllDestinationPaths.cpp` lock it)
  - `ryu_topology.py` `if installed:` treating an empty rule map as "unknown" rather than "nothing
    installed" (the docstring gives the counter-case: bmv2 keeps table entries across a proxy
    restart)
  - `Classifier.cpp` retaining the previous table for a switch whose fetch was skipped (the
    2026-08-07 Ryu wedge proved the opposite choice blanks every path)
- Tooling already covers `-Werror` with a wide warning set, a clang build, ASan/UBSan and TSan over
  the unit suite, and CI running all of it. **Do not report what a sanitizer would catch** — spend
  the run on semantics.
- `p4_proxy/tests/test_p4_client.py` skipping entirely is expected: it needs a live bmv2 on `:50051`
  and is gated behind `NDTWIN_L1_OPT_IN`. Not a finding.

## What this codebase is, so you read it correctly

A digital-twin kernel for an emulated software network. C++ (`src/`, `include/`, ~23k lines) is the
kernel; Python (`p4_proxy/`, ~9k lines) is a control-plane proxy that impersonates the Ryu
controller's northbound API so a P4/bmv2 fabric looks like an OVS one to the kernel above it. Tests
are `tests/` (C++ gtest, 33 files) and `p4_proxy/tests/` (Python unittest, 14 files). Docs are in
`doc/`. There is a second controller, `intelligent_router.py`, at the repo root (the OVS path).

The code is human+AI co-authored and carries **long explanatory comments that make specific factual
claims** — line numbers, counts, what a dependency does, what the old behaviour was. Those comments
are the richest hunting ground for Theme A, precisely because they are detailed enough to be wrong.

## The rule that governs the entire audit

**Open every line before you assert anything about it, and open it as it exists now.** This project
has been burned repeatedly by a cited line number that was already stale — one misread line
propagated into four documents as fact. A comment saying "`foo.cpp:123` does X" is a claim to
verify, not evidence. If you cite `foo.cpp:123`, you must have just read `foo.cpp:123` in the
current tree.

**Every finding is graded CONFIRMED or SUSPECTED, and you must not blur them.**

- CONFIRMED — you read the code and the defect is definitely present. Quote it.
- SUSPECTED — it looks wrong but you could not fully verify (needs a running system, a build, an
  input you cannot construct). Say exactly what would settle it.

Writing a SUSPECTED finding as though it were CONFIRMED is itself the Theme-A failure you are hunting
for — do not commit it in your own report. When in doubt, grade down.

## The four themes, concretely

### A. AI hallucinations / false assertions

The shape: text that confidently states something untrue. Check especially —

- Comments citing line numbers, function names, counts ("four callers", "the only writer"): pick a
  sample and verify each against the current code and against `git log`/`git show`.
- Comments describing what a *different* function or dependency does: read that other thing.
- Doc claims in `doc/*.md` about endpoint behaviour, status codes, field names, and measured values.
  The API reference `doc/ndt_api.md` is large and has been wrong before.
- A comment that says "this used to do X, now does Y": check `git show` that X was ever true.

**Calibration — all three of these really happened in this repository, and all three survived into
committed text:**

- `doc/p4_manual_test_runbook.md` cited `TopologyAndFlowMonitor.cpp:2429` for a function that lives
  at `:2441`. The citation was wrong **the day it was written** — not drift.
- `tools/git-hooks/post-commit` asserted "git serializes hook invocations per commit". Measured
  false: two hooks overlap freely. Worse, a later comment claimed that assertion had been removed —
  it had not, so the correction was itself a second false claim.
- A runbook explained a measured rate spread as "divided by the sampling window length". The real
  divisor is a hop counter and the window is never a denominator. **The arithmetic fit the measured
  data and was still the wrong mechanism** — which is why matching numbers is not evidence.

For every hallucination, put **what the text claims** next to **what the code actually does**, so
the gap is checkable in one glance.

### B. Test completeness

The question is not "are tests well written" but **"how many would still pass if the code under them
were wrong?"** Twelve false tests have already been caught here by mutation. Look for —

- **Tests that never run.** A test class defined *after* `unittest.main()` in a file the harness
  executes as a script is never collected — one such class hid three dead tests here. Check every
  `p4_proxy/tests/*.py`: is `unittest.main()` the last thing in the file? A C++ test file that
  compiles zero `TEST(`/`TEST_F(` macros runs nothing — `tests/test_LoggerEnvironment.cpp` is worth
  a look.
- **Vacuous assertions.** A loop over a container the fixture leaves empty; an assertion on a mock's
  own configured return value; an assertion on a constant.
- **Golden fixtures regenerated from current output** — they can only confirm today equals today.
  Look at `tests/test_GoldenFixture.cpp` and `tests/fixtures/`: where did the expected values come
  from?
- **The harness itself.** `tools/test_workflow/l1_unit_tests.sh` runs everything. Does it detect a
  suite that ran zero tests, or would `OK (skipped=N)` sail through? (A real hazard here: the Python
  suites need the project venv; the system interpreter lacks `grpc`/`networkx` and silently skips.)

For any test you flag, **name the mutation that defeats it** — "invert this condition", "return
`{}` here", "drop this `push_back`" — and say whether the test goes red. Reasoning it through is
acceptable; if you actually apply a mutation, `git status` first, revert it after, and leave the
tree exactly as found.

### C. Hard-coded assumptions that break

Mostly this is research code and the risk is brittle constants, not sabotage — report a hard-coded
value when it is **wrong outside one setup**, and say when it bites. But supply-chain tampering is
**not theoretical here**: on 2026-08-11, on this machine, `pip install "mcp[cli]"` pulled PyPI's
`mcp 2.0.0`, which had swapped its `httpx` dependency for a typosquat named `httpx2` whose metadata
impersonates httpx's real author (Tom Christie) and misattributes it to the pydantic org. So check
dependency *names*, not just versions.

Hunt both halves —

- Relative paths that depend on the process's working directory (`../doc/...`, prompt-file paths
  resolved from cwd). One handler here opens `../doc/OpenflowCapacity.json` and fails on any other
  cwd.
- Absolute paths under `/home/adam/...` baked into shipped code (as opposed to test fixtures or
  tooling, where they are fine).
- Hosts, ports, URLs assumed rather than configured: `localhost`, `:8080`, `:8000`, `:6343`,
  `50051-50060`, `192.168.123.1`. Flag one only if changing the deployment would silently break it.
- **Secrets, in the tree *and* in reachable git history**: API keys, tokens, passwords, private
  keys. `grep` the working tree for `api_key`, `Bearer`, `token`, `password`, `sk-`, `LLM_`, and
  base64-looking runs of 32+ chars; then check history with `git log -p -S'<pattern>'`, because a
  key deleted in a later commit is still in the repo. Report **file and line only** — do not paste
  the secret value into your report.
- **Dependency names**, not just versions: `p4_proxy/requirements.txt`, `FetchContent` blocks in
  `CMakeLists.txt`, and any `pip install` line inside scripts or docs. A name one character off a
  well-known package is the attack; a pinned version of the *wrong package* is still compromised.
- Magic numbers that encode an environment assumption (a fixed switch count, a hardcoded host range,
  an interface-speed constant) used where live data should be.

The **cross-repo contract exception**: the `/ndt/` HTTP endpoints are consumed by sibling apps not
in this repo. If you suspect a hard-coded field name, type, or wire format on a `/ndt/` response is
wrong, you MAY read those consumers to check — they are at `/home/adam/Energy-Saving-App`,
`/home/adam/Web-GUI`, `/home/adam/Traffic-Engineering-App`, `/home/adam/Network-State-Recorder`,
`/home/adam/Network-Traffic-Visualizer`, `/home/adam/Network-Traffic-Generator`. This is the only
reason to leave the repo. (Precedent: flow IPs are little-endian integers on the wire, and every
consumer already decodes them that way — changing it to strings would be the break. Verify before
you flag.)

### D. Silently swallowed errors

The commonest real defect in this repo. Shapes —

- `return true` / `200 OK` / a bare `return` on a path where the work could have failed. Grep for
  `return True`/`return true` right after a call whose result is discarded.
- `except Exception:` / `catch (...)` that logs and continues, or does not even log, turning a
  failure into a normal-looking empty result.
- An empty container (`[]`, `{}`, `sflow::Path{}`, `std::nullopt` folded to a default) that means
  both "genuinely empty" and "the query failed", where the caller cannot tell them apart. This one
  has real consequences here — an empty flow-stats reply is consumed as an authoritative snapshot.
- `operator[]` on a `std::map`/`dict` that inserts-on-read, so a lookup miss becomes a silent 0 or
  default instead of an error.

## Suggested batching — the codebase does not fit in one pass

Roughly 32k lines plus tests and docs. Work in passes and write findings incrementally so a
truncated run still leaves partial results on disk:

1. **Python proxy** — `p4_proxy/proxy_agent/*.py` (the control-plane logic) and `intelligent_router.py`.
2. **C++ collection + http** — `src/ndt_core/collection/`, `src/ndt_core/http/` (telemetry, the
   sFlow parser, the `/ndt/` handlers — highest density of Themes A and D).
3. **C++ rest** — `src/ndt_core/power_management/`, `routing_management/`, `intent_translator/`,
   `event_*`, `src/main.cpp`.
4. **Tests + harness** — all of `tests/`, `p4_proxy/tests/`, `tools/test_workflow/`.
5. **Docs** — `doc/*.md`, spot-checking their claims against the code (Theme A).

You do not need to build or run the suite; reading the code and git history is the job. If you do
choose to build to confirm a Theme-B mutation, note that it is CMake+Ninja
(`cmake --build build -j$(nproc)`), it is slow, and you must restore the tree afterward.

## Output — four reports, one per theme

Write four files under `doc/audit/codebase-review/`:

```
AUDIT_A_hallucinations.md
AUDIT_B_test_completeness.md
AUDIT_C_hardcoded.md
AUDIT_D_swallowed_errors.md
```

A finding that spans two themes goes in the **one** report it fits best, with a one-line
cross-reference from the other — do not paste the same finding into two files.

Each report starts with a grep-able verdict line:

```
VERDICT: <n> CONFIRMED, <n> SUSPECTED
```

Then each finding:

```
### <short title>
GRADE: CONFIRMED | SUSPECTED
WHERE: <file:line in the current tree>
WHAT: <the defect, with the offending code quoted>
BITES: <when it goes wrong and who notices — for a test, the mutation that defeats it>
[SETTLE: <only for SUSPECTED — exactly what would confirm or refute it>]
```

Rules that matter as much as the findings:

- **No praise, no summaries of what is good.** Only defects.
- **No style/naming/architecture opinions.** Four themes only.
- **CONFIRMED must be quoted from the current tree.** SUSPECTED must say what is missing.
- **A clean theme is a fine result** — say "no CONFIRMED findings; here is what I checked" in a
  sentence, and list the files you actually read. That last part is required: a zero-finding report
  that read the code is worth everything, and one that skimmed is worth nothing, and the file list
  is the only way to tell them apart.
- Close each report with `Read: <paths and commands>`.

Be terse. These four reports get read end to end by someone who will act on them.
