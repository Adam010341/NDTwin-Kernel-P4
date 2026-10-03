# JUDGE: CI clang+TSan a956fd78

**Verdict: MERGE.** Nothing blocks the merge. The three code changes are correct, small, and each one was seen red before it went green. Three of the summary's CI predictions are still unobserved: clang against libstdc++ 14, the ASan job, and the GCC job. Only the branch's own CI run can settle those, so do not report "clang green" as fact until that run exists. The summary also needs the corrections listed below before it is archived.

**Path roots used below**
- `WT` = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ci-cxx-0927`. This is the head. The worktree's HEAD is `refs/heads/fix/ci-clang-tsan-0927`, which points at `a956fd78c0b7…`. Its four files match the diff in the brief.
- `TR` = `/home/adam/Desktop/NDTwin-Kernel`. This is trunk, used as the base.
- `L` = `TR/scratch/overnight-2026-09-05/logs/ci-cxx-0927`.
- The scratchpad snapshots (`base-src`, `head-src*`, `mut`) have been deleted. Only `cells/` and `nosudo/` remain, so M1's frozen inputs cannot be re-checked.

## Classification of the report's verdicts

| Report claim | Class |
|---|---|
| §0: CI saw 2 of 15 errors and stopped at ~51% (`L/job-108620581946.nocolor.log:7031, :10965, :10980, :11686`) | SUPPORTED |
| §0: "compiled every TU that names the class" | CONTRADICTED. C0 compiled only main.cpp plus `tests/*.cpp` (`L/cells/c0_clang_base_tus.sh:16-17`). It skipped the 7 `src/` TUs, but those built clean on the base CI run (`job-…946:314-5963`), so the error is harmless. |
| §0/§2.1: "not a libc false positive"; the halt hid a second race | SUPPORTED, with the nuance in N4 |
| §1: root cause; `final` and a protected destructor ruled out; "no UB fired" | SUPPORTED (see Q1) |
| §1 C0: 15 FAILED = 10 on the class itself + 2 CacheDriver + MetricProbe, ReportProbe, DialCountingManager; 27 objects; rc 1 | SUPPORTED (`c0…nocolor.log:5, 35-9224, 9964`) |
| §1 C1: full Makefiles build of 4dc78c66 with `-k`, rc 0, 656 warnings, all `aligned_storage` / `-Wdeprecated-declarations` | SUPPORTED (`c1…nocolor.log:3, 29211`; I counted all three greps at 656) |
| §1 C2: 1368/1368 | SUPPORTED. Note it ran on 4dc78c66 (`c2:3-4, 3314-3316`). |
| §1: 4dc78c66 → a956fd78 changes only comments | UNDER-EVIDENCED. The diff/grep output is not in L/. The risk is reduced because T3/T4 built the final sha and C3 compiled two TUs that include the final Utils.hpp. |
| §2.1: CI stacks, `mutexes: read M0`, threads created at :299 | SUPPORTED (`job-…797:2461-2550`) |
| §2.1: M2 table | SUPPORTED (`m2:5-44, 45-84, 85-90, 92`). The ptr address `0x7ffff620b320` is the same as the `_tmbuf` address at `m2:70`. |
| §2.1: production could mis-print timestamps | SUPPORTED as an inference (see Q2) |
| §2.1 M1: base red, tm_year 70→123, tm_yday 0→318 | SUPPORTED (`m1:41-67, 74-100`) |
| §2.1 M1: "head 13/13 under both TZ values" | CONTRADICTED. The Asia/Taipei runs used `--gtest_filter='FormatTimeTest.*'` (`m1…sh:19`) and ran 2/2 (`m1:146-158`). 13/13 holds only for TZ unset (`m1:141-143`). |
| §2.1: the test behaves the same across zones | UNTESTED (N3) |
| §2.2 T2: the race; "in base too" | SUPPORTED. The line numbers :140/:152/:194 match trunk's fixture exactly. |
| §2.2 T4a/T4b: 0 reports, 1368/1368, rc 0 | SUPPORTED (`t4:3-11`; t4a/t4b `:3325-3326`) |
| §2.2: T2 and T4 binaries differ only by the fixture | UNDER-EVIDENCED. No diff is logged, though it is consistent with the brief. |
| §3: clang green | UNDER-EVIDENCED for the CI configuration (N1) |
| §3: TSan green | SUPPORTED (Q5) |
| §3: ASan green | The row is labelled INFERRED, which is correct. Its premise "green on base" is UNDER-EVIDENCED: there is no ASan job log in L/. |
| §3: GCC C++ steps green; job red on Python L1 | UNDER-EVIDENCED, and presented as run although it was not (N2) |
| §4: every cell went through the guard | SUPPORTED. Every cell log starts with `guarded_build: jobs=1`. |
| §4: "each cell prints its .snapshot-sha" | CONTRADICTED for C0, M1 and M2 (N11) |
| §5: C3; `logCurrentTimeSystemClock` has no live caller; HistoricalDataManager runs on one thread | SUPPORTED |
| §5: "-Wtsan … per the CI yml's own comment" | CONTRADICTED as to where it comes from (N9). The count of 19 is SUPPORTED. |

## Findings

**Blocking:** none.

**Notes:**

1. **N1: the clang job is observed only against libstdc++ 13.**
   - CI's clang build uses GCC 14's headers (`job-…946:7031`, path `…/gcc/x86_64-linux-gnu/14/…`). Local C0 used GCC 13's (`c0…nocolor.log:387`).
   - On CI's base run the build stopped after all the `src` libs plus about 21 of the 82 `test_routing_strategy` TUs.
   - That leaves about 61 test TUs and `main.cpp` that clang 18 has never compiled against libstdc++ 14. The suite has also never run against libstdc++ 14 headers, because the GCC jobs use 13's.
   - §3 should read: "observed with libstdc++ 13; the CI configuration is not observed."

2. **N2: the GCC row in §3 is unlabelled, but it was not run.**
   - No cell did a plain `-O0` GCC build.
   - No cell ran `ctest`, which in that job runs one process per case with POST_BUILD discovery (`TR/.github/workflows/ci.yml:60-61, 73-74`).
   - There is no GCC job log for the "red on Python L1" claim.
   - The house rule says run and read-not-executed results must never share a table without labels.

3. **N3: the TZ variants in M1 are one zone twice.**
   - The TZ-unset run already prints `formatTime(2023-11-15 06:13:20)` (`m1:48`), which is 1.7e9 s at UTC+8. That is the same zone as the explicit Asia/Taipei run.
   - Two zones were never exercised:
     - UTC, which is what the runner uses.
     - A negative-offset zone, where epoch 0 is 1969 and tm_yday is 364.
   - The test is written to be zone-robust: it reads the before-values instead of hard-coding them (`WT/tests/test_IpToString.cpp:240-241`). That robustness is argued from the code, not observed.

4. **N4: the free/strdup pair that CI reported is not the race itself.**
   - That pair (`tzset.c:401`) is glibc-internal state that glibc serialises with its own `tzset_lock`, which TSan cannot see. This comes from my knowledge of glibc's source; it cannot be checked in this repo.
   - The real race is on `_tmbuf`, shown by M2's `TZ=UTC` run (`m2:48-70`).
   - §2.1 already says this correctly. §0's wording overstates it. The conclusion still stands: it is a real race, it is fixed at the source, and it must not be suppressed.

5. **N5: `localtime_r` on glibc does not re-run tzset after the first call.** Also from glibc knowledge. As a result, formatTime no longer notices a runtime change to TZ or `/etc/localtime`; the base `localtime()` re-checked on every call. This is harmless here and worth one line in `WT/include/utils/Utils.hpp:979-994`.

6. **N6: the new `nullptr` branch has no test.** At `WT/include/utils/Utils.hpp:1000-1003` the behaviour changes from UB to returning `""`. A `formatTime(INT64_MAX)` case would crash on base and pass on head. Production timestamps cannot reach this branch.

7. **N7: FormatTimeTest checks a proxy, not the whole property.**
   - `WT/tests/test_IpToString.cpp:235-250` pins that formatTime does not write libc's shared struct. That is an effect other callers can observe, not a restatement of the implementation.
   - A regression to a function-local `static struct tm` plus `localtime_r` would still pass it.
   - Thread-safety itself is covered only by the TopK test in the TSan job. The proxy is acceptable.

8. **N8: C0's scope wording.** See the §0 row above.

9. **N9: `-Wno-error=tsan` is set in the CMake file, not the workflow.** It is at `TR/cmake/sanitizer-flags.cmake:45-57`. `ci.yml` never mentions it.

10. **N10: several checks are presented as done but have no raw output in L/.**
    - "A grep of the diff finds no non-comment lines."
    - "`git diff --stat 5a47f0a2 a956fd78`."
    - "sha256 checked after the cut": no log has a hash from before the cut; `t4_tsan_runs.log:4` is the only one.

11. **N11: C0, M1 and M2 do not print their snapshot identity.** C0 echoes a hard-coded "(git archive f186ce98)" (`c0…sh:8`), and M1 and M2 print nothing. There is indirect support: M2's base report points at `Utils.hpp:986`, which is the `localtime` line in trunk's `TR/include/utils/Utils.hpp:986`.

12. **N12: the tree after merging onto current trunk was never built.** The session's git status shows trunk at fed37cff, four commits past f186ce98, including one "tests only" merge.

13. **N13: minor number mismatches.**
    - "T3 started at 4.3 GB free": `t3_tsan_build.log:5` says 4.4G. The 4.3G figure is T1's (`t1…log:5`).
    - CI's "58 times" comes from a run that halted at TopK (`job-…797:2552`). The local 63 covers the full suite, so the two counts cover different spans.
    - The stub does not print "the same message": it appends "(local stub)" (`L/cells/nosudo-stub-sudo.sh:4`).
    - "make -j4" is inferred. The log only shows `-j"$(nproc)"` (`job-…946:303-304`).

14. **N14: `acceptLoop` can still spin in one case.** If `accept` fails for a reason other than shutdown while `m_accepting` is still true (for example EMFILE), the loop retries without end (`WT/tests/test_KernelStopIsBounded.cpp:204-210`). This was already true before the change, and it is not on the destructor's path.

15. **N15: two small edits carry no Co-developed tag.** `WT/include/utils/Utils.hpp:24` (`#include <ctime>`) and `:46-47` (the `@warning` edit) are untagged. All the substantive blocks are tagged:
    - `WT/include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp:153`
    - `WT/include/utils/Utils.hpp:982`
    - `WT/tests/test_IpToString.cpp:226`
    - `WT/tests/test_KernelStopIsBounded.cpp:157`

## Answers to the six checks

**Q1. Root causes**
- The one-line fix clears everything. After it, C1 builds every TU with 0 errors under the same flags as CI.
- `final` is ruled out: 14 subclasses in 13 test files derive from the class, for example `TR/tests/test_SimulatedDeviceMetrics.cpp:55` and `TR/tests/test_StaleTableCarryForward.cpp:65, 388`.
- A protected destructor is ruled out: the class is created and destroyed as itself at `TR/src/main.cpp:400-401` and in 9 test files, for example `TR/tests/test_PowerManagerShutdown.cpp:73` and `TR/tests/test_KernelStopIsBounded.cpp:352, 532`.
- There is no `unique_ptr<DeviceConfigurationAndPowerManager>` and no `delete` anywhere in `src/`, `include/` or `tests/`.

**Q2. The formatTime race is real**
- Where it happens:
  - `getFlowInfoJson` takes `shared_lock` at `TR/src/ndt_core/collection/FlowLinkUsageCollector.cpp:2678` and calls formatTime at `:2742-2743`.
  - TopK calls `getFlowInfoJson` without its own lock at `:2805`.
- Who calls it concurrently:
  - In the test: the readers at `TR/tests/test_TopKFlowInfoLocking.cpp:295-302`.
  - In production: `TR/src/ndt_core/http/HttpSession.cpp:1553, 1595`, on an io_context run by `hardware_concurrency()` threads (`TR/src/ndt_core/event_handling/ControllerAndOtherEventHandler.cpp:272-277`), plus `IntentTranslator.cpp:463, 566`.
- Other `localtime`-family callers:
  - `TR/src/ndt_core/data_management/HistoricalDataManager.cpp:107`. Its only caller is `:204`, inside the recorder thread started at `:79`, and it copies the struct immediately.
  - `logCurrentTimeSystemClock`: its only call sites are commented out, at `FlowLinkUsageCollector.cpp:1350, 1715`.
- There is no gmtime, ctime, asctime, strtok or inet_ntoa call in `src/` or `include/`.
- Adjacent calls that need no fix:
  - `strerror` on collector threads (`FlowLinkUsageCollector.cpp:281, 425, 679, 723, 828, 847`) is MT-safe in practice on glibc 2.32 and later.
  - `getenv` is read concurrently only after `setenv` has run at startup (`main.cpp:247, 265`, before `:481-515`).
  - `readdir` is used on private streams (`src/utils/FdHygiene.cpp:151, 266`).
  - spdlog uses `localtime_r` (`TR/libs/spdlog/details/os-inl.h:102`).

**Q3. Mutation gate**
- The test is red on base and green on head.
- It cannot pass on base by luck on glibc: base always rewrites the shared struct to year 123.
- On head it could fail for an unrelated reason only if another thread called `localtime` or `gmtime` in between, and nothing in the suite does. The zone question is N3.

**Q4. test_KernelStopIsBounded**
- `shutdown` wakes a blocked `accept` on Linux: the listener leaves the LISTEN state and `accept` returns EINVAL. That is kernel behaviour I know; the direct evidence is T4a/T4b, where all 7 cases ran with no hang (`t4b:2864-2880`).
- Base's own comment, "Closing the listening fd is what wakes the accept()" (`TR/tests/test_KernelStopIsBounded.cpp:148`), was wrong on Linux: `close` does not wake it. So base already depended on `shutdown`, and the new order adds no new dependency.
- `acceptLoop` exits after shutdown:
  - `m_accepting` is cleared at `WT…:145`, before the `shutdown` at `:151`.
  - When `accept` then fails, the loop returns at `:206-209`.
- T2 shows the race (`t2:2872-2919`, rc 66).

**Q5. CI prediction**
- TSan is supported:
  - Same g++ 13.3.0 (`job-…797:225`).
  - Same BuildIds in the CI and local reports for libc (a4a7992a), libtsan (2a13a771) and libstdc++ (753c6c86).
  - Same `TSAN_OPTIONS` and `setarch` (`L/cells/t4_tsan_runs.sh:17` against `ci.yml:181-182`).
  - A clean `halt_on_error=0` sweep over the whole suite.
- Differences between CI and the worker's cells:
  - libstdc++ 14 headers for clang (N1).
  - `-k` in C1, T1 and T3, which only makes the local builds stricter.
  - `-j`, which does not matter.
  - A local copy of googletest at the commit pinned in `TR/CMakeLists.txt:128`.
  - The sudo stub instead of real sudo. All 63 local calls were to `ovs-vsctl`, so the effect is the same.
  - No test filter in CI, C2 or T4. Only M1's Asia/Taipei run used one.
  - The runner's zone is UTC; locally it is +08:00.
  - The runner has a different CPU count, so thread scheduling differs.

**Q6. Scope and discipline**
- Only four files changed, all under `include/` and `tests/`.
- The tags are present (N15).
- Every build went through the guard.
- Claimed as run but not run: N2 and N10.
- "Main checkout untouched, no sudo, no lab" cannot be checked read-only without git.

## Tests I would have run
1. The branch's own CI run. It is the only way to observe clang with libstdc++ 14 and the ASan job.
2. A plain GCC Debug build followed by `ctest --test-dir build --output-on-failure`.
3. An ASan+UBSan build run with `--gtest_filter='FormatTimeTest.*:KernelStopIsBoundedTest.*:TopKFlowInfoTest.*'`.
4. M1's binaries under `TZ=UTC` and `TZ=America/Los_Angeles`, on both base and head.
5. `--gtest_repeat` of KernelStopIsBounded and TopK under TSan, pinned to 4 CPUs to match the runner.
6. A formatTime mutant using `static struct tm` + `localtime_r`. It should stay green, which would document the test's blind spot.
7. A build of the branch merged onto the current trunk.

Key files:
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/CI-CXX-SUMMARY.md`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/ci-cxx-0927/`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ci-cxx-0927/`
- `/home/adam/Desktop/NDTwin-Kernel/.github/workflows/ci.yml`
- `/home/adam/Desktop/NDTwin-Kernel/cmake/sanitizer-flags.cmake`