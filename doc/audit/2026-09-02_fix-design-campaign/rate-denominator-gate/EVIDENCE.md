# Mutation gate of the mutation gate — `tests/shell/mutate_rate_denominator.sh`

Every scenario below was run against BOTH versions of the script through identical stubs:

- `original_gate.sh` = `git show 4cbec52d:tests/shell/mutate_rate_denominator.sh`
- the new script     = `tests/shell/mutate_rate_denominator.sh` on branch
                       `fix/mutate-rate-denominator-survivor-accounting`

## No compiler was ever invoked

A CPU-sensitive measurement was running on this machine, so nothing was built. The harness
stubs `git` so that `git rev-parse --show-toplevel` answers with `sandbox/`, a throwaway tree
holding copies of the three mutated sources. The gate therefore `cd`s into the sandbox and the
REAL worktree is never touched by any scenario — `cmake`/`ninja`/`c++` are never executed, and
the worktree still has no `build/` directory.

- `bin/git`     — answers `rev-parse --show-toplevel` with the sandbox; refuses anything else
- `bin/cmake`   — never builds; can fail for a chosen mutant (c) or sabotage the restore (f)
- `faketest.sh` — stub gtest binary, installed as `$BUILD_DIR/bin/test_routing_strategy`
- `detect.sh`   — reports WHICH mutation is on disk, by presence of the mutated text

`detect.sh` is what makes this a real test rather than a puppet show: the stubs read the actual
mutated file off disk, so the gate's own patching logic is genuinely exercised. `stub.log` for
scenario (a) shows the five mutations arriving one at a time — `m1, m2, m4, neg, m3` — with
`none` at the baseline and again after the final restore.

## Scenario table

| # | scenario | original rc | new rc | new summary line | new reason |
|---|----------|------------|--------|------------------|------------|
| a | all mutants killed | **0** ✅ | **0** ✅ | `5 mutations, 0 survived` | — |
| b | one mutant, nothing goes red | **0** 🔴 wrong | **1** ✅ | `5 mutations, 1 survived` | `nothing went red` |
| c | one mutant does not compile | **0** 🔴 wrong | **1** ✅ | `5 mutations, 1 survived` | `mutant does not compile` |
| d | anchor missing (header, `sed -i`) | **0** 🔴 wrong | **1** ✅ | `5 mutations, 1 survived` | `anchor missing` |
| d2 | anchor missing (cpp, python assert) | **0** 🔴 wrong | **1** ✅ | `5 mutations, 1 survived` | `anchor missing` |
| e | baseline already red | 2 (only at the very end) | **2** ✅ | none (harness fault) | no mutation applied |
| f | restore not byte-identical | 2 | **2** ✅ | none (harness fault) | stops at slot 1 |
| g | wrong test goes red | **0** 🔴 wrong | **1** ✅ | `5 mutations, 1 survived` | `wrong test went red` |
| h | build directory missing | 2 (wrong reason, after a FALSE KILL) | **2** ✅ | none (harness fault) | refuses up front |
| i | `BUILD_DIR=out` override | 2 (ignores BUILD_DIR) | **0** ✅ | `5 mutations, 0 survived` | — |
| j | binary exits non-zero naming no test | **0** 🔴 FALSE KILL | **1** ✅ | `5 mutations, 1 survived` | `nothing went red` |

Rows b, c, d, d2, g, j are the red this change fixes: the original ends green on every one.

Rows a and i are the green: the fix does not turn correct runs into failures, and the default
`BUILD_DIR` behaviour is unchanged (row a runs with `BUILD_DIR` unset).

## Two bugs found that were not in the brief

**h/j — a non-zero exit status was read as "the test went red".** The original's NEGATIVE
CONTROL block tested `if ./build/bin/test_routing_strategy ...; then SURVIVED else "✅ red"`.
Anything that makes the binary exit non-zero without running the test — a missing binary, a
crash, a gtest init failure — was therefore reported as proof that the gate works. Scenario h
shows the original printing `✅ red: the unfixed site is detected` when `build/` does not exist
at all. The new script parses the `[  FAILED  ]` test names instead, so an unexplained non-zero
exit yields no names and is scored `nothing went red`.

**d — `sed -i` exits 0 when it matches nothing.** Mutation 3 mutated the header with `sed -i`
and never checked that anything changed, so a moved anchor was invisible: no warning, no
verdict, exit 0. The new script compares the file's sha256 before and after the `sed`, which is
the only honest evidence the mutation was applied.

## Raw matrix output (not transcribed — this is the driver's own output)

Columns: scenario, exit code, the summary line grepped out of the run, whether the sandbox
sources came back byte-identical, and whether the real worktree sources were touched.

### original (`git show 4cbec52d:...`)

```
orig-a-all-killed            rc=0   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
orig-b-nothing-red           rc=0   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
orig-c-no-compile            rc=0   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
orig-d-anchor-hdr            rc=0   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
orig-d2-anchor-cpp           rc=0   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
orig-e-baseline-red          rc=2   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
orig-f-restore-broken        rc=2   | (no summary line printed)    | 🔴 SANDBOX SOURCES CHANGED | porcelain empty
orig-g-wrong-test            rc=0   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
orig-h-nobuilddir            rc=2   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
orig-i-builddir-override     rc=2   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
orig-j-silent-fail           rc=0   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
```

### new

```
new-a-all-killed             rc=0   | 5 mutations, 0 survived      | sandbox sources byte-identical | porcelain empty
new-b-nothing-red            rc=1   | 5 mutations, 1 survived      | sandbox sources byte-identical | porcelain empty
new-c-no-compile             rc=1   | 5 mutations, 1 survived      | sandbox sources byte-identical | porcelain empty
new-d-anchor-hdr             rc=1   | 5 mutations, 1 survived      | sandbox sources byte-identical | porcelain empty
new-d2-anchor-cpp            rc=1   | 5 mutations, 1 survived      | sandbox sources byte-identical | porcelain empty
new-e-baseline-red           rc=2   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
new-f-restore-broken         rc=2   | (no summary line printed)    | 🔴 SANDBOX SOURCES CHANGED | porcelain empty
new-g-wrong-test             rc=1   | 5 mutations, 1 survived      | sandbox sources byte-identical | porcelain empty
new-h-nobuilddir             rc=2   | (no summary line printed)    | sandbox sources byte-identical | porcelain empty
new-i-builddir-override      rc=0   | 5 mutations, 0 survived      | sandbox sources byte-identical | porcelain empty
new-j-silent-fail            rc=1   | 5 mutations, 1 survived      | sandbox sources byte-identical | porcelain empty
```

Row f reports `SANDBOX SOURCES CHANGED` on purpose: the scenario makes the target
unwritable, so the restore genuinely cannot put the baseline back. That is exactly why it
must exit 2 and print `Do NOT commit` — the tree really is left mutated.

## Per-scenario output

### (a-all-killed)

```
$ bash run_scenario.sh <script> a-all-killed   # see run_all.sh for the exact env
--- original: last 6 lines ---
  ✅ red: RateDenominator.DivisorStartsAtASentinelNotZero 

--- after restore: the suite must be green again ---
[----------] Global test environment tear-down
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)
--- new: last 6 lines ---
[----------] Global test environment tear-down
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)

--- verdict ---
5 mutations, 0 survived
```

### (b-nothing-red)

```
$ bash run_scenario.sh <script> b-nothing-red   # see run_all.sh for the exact env
--- original: last 6 lines ---
  ✅ red: RateDenominator.DivisorStartsAtASentinelNotZero 

--- after restore: the suite must be green again ---
[----------] Global test environment tear-down
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)
--- new: last 6 lines ---
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)

--- verdict ---
  survived: 2. accept a zero interval (> becomes >=) -- nothing went red
5 mutations, 1 survived
```

### (c-no-compile)

```
$ bash run_scenario.sh <script> c-no-compile   # see run_all.sh for the exact env
--- original: last 6 lines ---
  ✅ red: RateDenominator.DivisorStartsAtASentinelNotZero 

--- after restore: the suite must be green again ---
[----------] Global test environment tear-down
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)
--- new: last 6 lines ---
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)

--- verdict ---
  survived: 2. accept a zero interval (> becomes >=) -- mutant does not compile
5 mutations, 1 survived
```

### (d-anchor-hdr)

```
$ bash run_scenario.sh <script> d-anchor-hdr   # see run_all.sh for the exact env
--- original: last 6 lines ---
  🔴 NOTHING WENT RED -- the sentinel's value is untested.

--- after restore: the suite must be green again ---
[----------] Global test environment tear-down
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)
--- new: last 6 lines ---
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)

--- verdict ---
  survived: 3. sentinel -1.0 becomes 0.0 (header file, run separately) -- anchor missing
5 mutations, 1 survived
```

### (d2-anchor-cpp)

```
$ bash run_scenario.sh <script> d2-anchor-cpp   # see run_all.sh for the exact env
--- original: last 6 lines ---
  ✅ red: RateDenominator.DivisorStartsAtASentinelNotZero 

--- after restore: the suite must be green again ---
[----------] Global test environment tear-down
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)
--- new: last 6 lines ---
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)

--- verdict ---
  survived: 1. drop the division by elapsedSeconds -- anchor missing
5 mutations, 1 survived
```

### (e-baseline-red)

```
$ bash run_scenario.sh <script> e-baseline-red   # see run_all.sh for the exact env
--- original: last 6 lines ---

--- after restore: the suite must be green again ---
🔴 THE SUITE IS RED AFTER RESTORE -- a mutant is still built in. Do NOT commit.
  still red: 1 test, listed below:
  still red: RateDenominator.SameBytesOverTwoSecondsIsHalfTheRate
  still red: RateDenominator.SameBytesOverTwoSecondsIsHalfTheRate (1 ms)
--- new: last 6 lines ---
=== baseline: the unmutated tree must be green ===
  red at baseline: RateDenominator.SameBytesOverTwoSecondsIsHalfTheRate 

🔴 HARNESS FAULT: the suite is already red before any mutation -- no mutation was applied
   This run measured nothing. It is not a pass and not a survivor count.
   Reached mutation slot 0 of 5.
```

### (f-restore-broken)

```
$ bash run_scenario.sh <script> f-restore-broken   # see run_all.sh for the exact env
--- original: last 6 lines ---
  expect: SameBytesOverTwoSecondsIsHalfTheRate
  ✅ red: RateDenominator.SameBytesOverTwoSecondsIsHalfTheRate 
cp: cannot create regular file 'src/ndt_core/collection/TopologyAndFlowMonitor.cpp': Permission denied
🔴 RESTORE FAILED -- src/ndt_core/collection/TopologyAndFlowMonitor.cpp is not the baseline. Do NOT commit.
cp: cannot create regular file 'src/ndt_core/collection/TopologyAndFlowMonitor.cpp': Permission denied
🔴 RESTORE FAILED -- src/ndt_core/collection/TopologyAndFlowMonitor.cpp is not the baseline. Do NOT commit.
--- new: last 6 lines ---

🔴 HARNESS FAULT: src/ndt_core/collection/TopologyAndFlowMonitor.cpp did not come back byte-identical
   This run measured nothing. It is not a pass and not a survivor count.
   Reached mutation slot 1 of 5.
cp: cannot create regular file 'src/ndt_core/collection/TopologyAndFlowMonitor.cpp': Permission denied
🔴 RESTORE FAILED -- src/ndt_core/collection/TopologyAndFlowMonitor.cpp is not the baseline. Do NOT commit.
```

### (g-wrong-test)

```
$ bash run_scenario.sh <script> g-wrong-test   # see run_all.sh for the exact env
--- original: last 6 lines ---
  ✅ red: RateDenominator.DivisorStartsAtASentinelNotZero 

--- after restore: the suite must be green again ---
[----------] Global test environment tear-down
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)
--- new: last 6 lines ---
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)

--- verdict ---
  survived: 2. accept a zero interval (> becomes >=) -- wrong test went red
5 mutations, 1 survived
```

### (h-nobuilddir)

```
$ bash run_scenario.sh <script> h-nobuilddir   # see run_all.sh for the exact env
--- original: last 6 lines ---
=== 3. sentinel -1.0 becomes 0.0 (header file, run separately) ===
  expect: DivisorStartsAtASentinelNotZero
  🔴 NOTHING WENT RED -- the sentinel's value is untested.

--- after restore: the suite must be green again ---
🔴 THE SUITE IS RED AFTER RESTORE -- a mutant is still built in. Do NOT commit.
--- new: last 6 lines ---

🔴 HARNESS FAULT: build directory 'build' does not exist -- there is nothing to mutate against
   This run measured nothing. It is not a pass and not a survivor count.
   Reached mutation slot 0 of 5.
```

### (i-builddir-override)

```
$ bash run_scenario.sh <script> i-builddir-override   # see run_all.sh for the exact env
--- original: last 6 lines ---
=== 3. sentinel -1.0 becomes 0.0 (header file, run separately) ===
  expect: DivisorStartsAtASentinelNotZero
  🔴 NOTHING WENT RED -- the sentinel's value is untested.

--- after restore: the suite must be green again ---
🔴 THE SUITE IS RED AFTER RESTORE -- a mutant is still built in. Do NOT commit.
--- new: last 6 lines ---
[----------] Global test environment tear-down
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)

--- verdict ---
5 mutations, 0 survived
```

### (j-silent-fail)

```
$ bash run_scenario.sh <script> j-silent-fail   # see run_all.sh for the exact env
--- original: last 6 lines ---
  ✅ red: RateDenominator.DivisorStartsAtASentinelNotZero 

--- after restore: the suite must be green again ---
[----------] Global test environment tear-down
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)
--- new: last 6 lines ---
[  PASSED  ] 4 tests.
kernel binary: db871e6e70161b15 (was db871e6e70161b15)

--- verdict ---
  survived: NEGATIVE CONTROL: host-bound site ignores its interval -- nothing went red
5 mutations, 1 survived
```

