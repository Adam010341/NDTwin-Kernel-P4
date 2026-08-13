# Review prompt — NDTwin-Kernel test suite

Hand this whole file to one reviewing agent. It needs read access to `/home/adam/Desktop/NDTwin-Kernel`.

---

You are reviewing the **test suite** of `/home/adam/Desktop/NDTwin-Kernel`, on branch
`fix/flow-rate-divide-by-zero`. Not the production code — the tests.

## The question this review exists to answer

Not "are these tests well written". The question is:

> **How many of these tests would still pass if the code under them were wrong?**

A test that cannot fail is worse than no test, because it is counted as coverage and it buys false
confidence. This project has already caught **twelve** such tests by mutation, including one that
passed against an entirely empty graph. Assume more remain.

Everything else — naming, structure, duplication, style — is secondary and capped (see output rules).

## The suite

| Layer | Location | Size |
|---|---|---|
| C++ (gtest) | `tests/*.cpp`, 33 files | 426 tests, all linked into one binary |
| P4 proxy (Python unittest) | `p4_proxy/tests/`, 12 files | 331 pass + 1 skipped |
| Kernel-side Python + shell | `tests/python/`, `tests/shell/` | 107 |

Build and run: `tools/test_workflow/l1_unit_tests.sh` (runs ctest, then the binary directly, then
both Python suites, then cross-checks that ctest's case count matches gtest's discovered count).

⚠️ **The Python suites need the project venv, not the system interpreter.** Conda's `python3` lacks
`grpc` and `networkx`, and unittest then reports `OK (skipped=18)` — a broken suite that looks green.
This has happened here and went unnoticed for two commits. Use what `l1_unit_tests.sh` uses.

⚠️ `p4_proxy/tests/test_p4_client.py` skipping entirely is **expected** — it needs a live bmv2 on
`:50051` and is gated behind `NDTWIN_L1_OPT_IN`. Not a finding.

## What a false test looks like here

Concrete shapes, each seen in this repository or its siblings:

1. **Vacuously true assertions.** A loop over a container that is empty in the fixture, so the body
   never runs and the test passes by doing nothing. The famous one here passed on an empty graph.
2. **Asserting a mock's own configured behaviour.** The test sets a fake to return `X`, then asserts
   the result is `X`, exercising no production logic.
3. **Assertions on constants**, or on values the test itself computed with the same expression the
   production code uses — if the formula is wrong, both sides are wrong together.
4. **Expected values derived from running the code** rather than from the specification. A golden
   fixture regenerated from current output can only ever confirm that today equals today. Look hard
   at `tests/test_GoldenFixture.cpp` and `tests/fixtures/` — where did those expected values come
   from, and would a regression change them or change the fixture?
5. **A test that names a behaviour it does not reach.** Named for a failure path, but the setup never
   triggers that path.
6. **Over-mocked seams**, where every collaborator is faked and the only real code executed is a
   getter.

## Highest-value targets — start here

These modules are where a false test costs the most, because nothing else covers them:

- **`tests/test_SFlowParsing.cpp` (21) and `tests/test_EstimatedRates.cpp` (14).** The sFlow decoder
  is a hand-written fixed-offset binary parser, and its output feeds every rate, path and link-usage
  figure the twin reports. A wrong offset yields plausible numbers, never an error. Ask specifically:
  do these tests assert against *independently known* byte layouts and hand-computed expected rates,
  or against whatever the parser currently produces?
- **`tests/test_EstimatedRates.cpp`** specifically. `computeEstimatedRates`
  (`include/common_types/SFlowType.hpp:339`) divides accumulated bytes by `hopsCounter`. A live
  measurement this week found readings varying several-fold at low packet rates, and a suspected
  defect where `AutoRefreshQueue::size()` (which does **not** refresh, `SFlowType.hpp:134`)
  increments `hopsCounter` while `getSum()` (which **does** refresh, `:116`) then returns 0 for the
  same agent — inflating the denominator without the numerator. **Do the tests cover a stale-queue
  case at all?** If not, say so; that is a coverage hole with a live symptom behind it.
- **`tests/test_HttpSessionRouting.cpp` (18) and `tests/test_SwitchKindDispatch.cpp` (27).** The
  `/ndt/` endpoints are a cross-repo contract consumed by seven sibling applications that are not in
  this repository, so no test here fails when one breaks. Do these tests pin response *shapes* —
  field names, types, status codes — or only that a handler was reached?
- **`tests/test_FlowTableConcurrency.cpp`** has only **2** tests for a module whose comments describe
  several distinct races that were fixed. Are two tests enough to hold those fixes in place, and can
  a concurrency test here fail deterministically at all, or does it rely on winning a timing race?
- **`tests/test_LoggerEnvironment.cpp` reports 0 gtest cases.** Find out why. Either it uses a
  different macro, or it is a file that runs nothing.

## How to check, concretely

For any test you suspect, **name the mutation that would defeat it.** Be specific: "invert this
condition", "return an empty vector here", "off-by-one on this offset", "drop this `push_back`".
Then say whether the test would go red.

You may verify by actually applying a mutation, building, and running — but if you do:

- **`git status` first and do not touch anything uncommitted.** A previous session lost work by
  restoring files during mutation testing.
- Revert every mutation you make. Leave the tree exactly as you found it.
- Build is slow; batch your mutations rather than rebuilding per test.

Reasoning about the mutation without running it is acceptable and often enough — just say which mode
you used for each claim, so I know which findings are measured and which are argued.

## Do not report

- Missing tests for code that has none, unless the code is in the high-value list above. I know
  coverage is incomplete; I want to know which of the *existing* tests are lying.
- Style, naming, file organisation, duplication between tests — unless it causes a false pass.
- The `test_p4_client.py` skip (expected, see above).
- Anything the tooling already catches: GCC `-Werror` with a wide warning set, a clang build,
  ASan+UBSan and TSan over the whole unit suite, and CI running all of it.

## Output rules

- **No praise.** Do not tell me the suite is thorough or well-organised. I cannot act on it.
- **Every finding needs `file:line`** and the name of the mutation that defeats the test.
- **Severity:**
  - HIGH: a test that cannot fail, or that passes against a named plausible defect. Say which defect.
  - MEDIUM: a test that is much weaker than it appears, or a coverage hole in the high-value list.
  - NITPICK: everything else. **Cap at three, and only if you have no HIGH or MEDIUM.**
- **If you find nothing, say so in one sentence.** A clean review that names what it probed is worth
  more than a padded one.
- **Close with `Read: <paths and commands>`** — required even with zero findings. It is the only way
  to tell a review that read the test files from one that also read the code under them.

Start with one line I can grep:

```
VERDICT: <n> HIGH, <n> MEDIUM, <n> NITPICK
```
