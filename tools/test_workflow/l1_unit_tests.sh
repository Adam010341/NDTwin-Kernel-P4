#!/usr/bin/env bash
#
# L1: kernel unit tests.
#
# Runs the gtest binaries two ways, because either alone can lie:
#
#   ctest            -- gtest_discover_tests registers one ctest case per TEST_F, each
#                       running in its own process with --gtest_filter=Suite.Test. That
#                       isolation means any problem which only occurs when several suites
#                       share a process simply never happens, so ctest reports green.
#   direct execution -- the whole binary in one process, which is where cross-test
#                       interference shows up: static init, singletons, global registries,
#                       state a suite leaves behind.
#
# Measured with the Logger::init double-registration bug present:
#   --gtest_filter=P4RoutingStrategyTest.Install...  exit=0 ran=1  passed=1  skipped=0
#   whole binary                                     exit=1 ran=12 passed=10 skipped=2
#   ctest                                            100% tests passed, 0 failed out of 12
#
# Note the first line: under ctest those tests genuinely run and genuinely pass. ctest is
# not swallowing a failure -- it never creates the condition that fails.
#
# Additionally asserts that the number of tests that actually RAN matches the number
# discovered. A SKIPPED test is not a passing test.
#
# Also runs the P4 proxy's Python tests, since half the P4 path lives there: the sFlow emitter
# and the clone session are Python, and the C++ suite cannot reach them. A skipped Python test
# is treated the same way as a skipped gtest one -- reported, not counted as a pass -- except
# where the interpreter genuinely lacks the P4Runtime protobufs, which is a real environment
# limitation rather than a broken test.
#
# Usage:
#   ./l1_unit_tests.sh              # configure if needed, build, run both ways
#   ./l1_unit_tests.sh --no-build   # assume the build is current
#
# [Co-developed with claude code -- Adam]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=components.env
source "$HERE/components.env"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; D=''; N=''
fi

DO_BUILD=1
[[ "${1:-}" == "--no-build" ]] && DO_BUILD=0

BUILD_DIR="$KERNEL_DIR/build"
mkdir -p "$LOG_DIR"
FAILURES=0

step() { echo; echo "${D}--- $* ---${N}"; }

if [[ $DO_BUILD -eq 1 ]]; then
    step "building"
    if ! cmake -S "$KERNEL_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Debug \
            >"$LOG_DIR/l1_configure.log" 2>&1; then
        echo "${R}cmake configure failed${N} (see $LOG_DIR/l1_configure.log)"
        tail -20 "$LOG_DIR/l1_configure.log" | sed 's/^/  /'
        exit 1
    fi
    if ! cmake --build "$BUILD_DIR" -j"$(nproc)" >"$LOG_DIR/l1_build.log" 2>&1; then
        echo "${R}build failed${N} (see $LOG_DIR/l1_build.log)"
        tail -30 "$LOG_DIR/l1_build.log" | sed 's/^/  /'
        exit 1
    fi
    # -Werror means warnings are already errors, but surface any that slipped through
    # as informational (e.g. from a dependency built without our flags).
    if grep -qE "warning:" "$LOG_DIR/l1_build.log"; then
        echo "${Y}note: build log contains warnings${N} (see $LOG_DIR/l1_build.log)"
    fi
    echo "${G}build ok${N}"
fi

mapfile -t TEST_BINS < <(find "$BUILD_DIR/bin" -maxdepth 1 -type f -name 'test_*' \
                              -executable 2>/dev/null | sort)
if [[ ${#TEST_BINS[@]} -eq 0 ]]; then
    echo "${R}no test binaries found in $BUILD_DIR/bin${N}"
    exit 1
fi

# --- 1. ctest -------------------------------------------------------------------
step "ctest"
CTEST_LOG="$LOG_DIR/l1_ctest.log"
if ctest --test-dir "$BUILD_DIR" --output-on-failure >"$CTEST_LOG" 2>&1; then
    echo "${G}ctest passed${N}  ${D}($(grep -oE '[0-9]+% tests passed[^.]*' "$CTEST_LOG" | head -1))${N}"
else
    echo "${R}ctest FAILED${N} (see $CTEST_LOG)"
    grep -E "Failed|\*\*\*" "$CTEST_LOG" | head -20 | sed 's/^/  /'
    FAILURES=$((FAILURES + 1))
fi

# --- 2. direct execution, per binary --------------------------------------------
step "direct execution (catches suite-level failures ctest hides)"
for bin in "${TEST_BINS[@]}"; do
    name="$(basename "$bin")"
    log="$LOG_DIR/l1_direct_${name}.log"
    printf '  %-30s ' "$name"

    "$bin" >"$log" 2>&1
    rc=$?

    # gtest prints "[==========] N tests from M test suites ran." and, when anything was
    # skipped, "[  SKIPPED ] N tests".
    ran=$(grep -oE '\[==========\] [0-9]+ test' "$log" | tail -1 | grep -oE '[0-9]+' | head -1)
    passed=$(grep -oE '\[  PASSED  \] [0-9]+ test' "$log" | tail -1 | grep -oE '[0-9]+' | head -1)
    skipped=$(grep -oE '\[  SKIPPED \] [0-9]+ test' "$log" | tail -1 | grep -oE '[0-9]+' | head -1)
    ran=${ran:-0}; passed=${passed:-0}; skipped=${skipped:-0}

    if [[ $rc -ne 0 ]]; then
        echo "${R}FAIL${N} (exit $rc, ran=$ran passed=$passed skipped=$skipped)"
        grep -E "FAILED|Failure|error:|C\+\+ exception" "$log" | head -12 | sed 's/^/      /'
        FAILURES=$((FAILURES + 1))
    elif [[ $skipped -gt 0 ]]; then
        # The trap this script exists for: exit 0 with tests that never executed.
        echo "${R}FAIL${N} ${skipped} test(s) SKIPPED — a skipped test is not a passing test"
        grep -E "SKIPPED|C\+\+ exception|SetUpTestSuite" "$log" | head -12 | sed 's/^/      /'
        FAILURES=$((FAILURES + 1))
    elif [[ $ran -eq 0 ]]; then
        echo "${R}FAIL${N} no tests ran"
        FAILURES=$((FAILURES + 1))
    else
        echo "${G}PASS${N}  ${D}${passed}/${ran} ran and passed${N}"
    fi
done

# --- 3. P4 proxy Python tests ----------------------------------------------------
# The emitter's tests need no gRPC, so they run under any python3. The clone-session tests
# need the P4Runtime protobufs, so they prefer an interpreter that has them.
step "P4 proxy Python tests"
PROXY_DIR="$KERNEL_DIR/p4_proxy"
if [[ ! -d "$PROXY_DIR/tests" ]]; then
    echo "  ${D}no p4_proxy/tests directory; skipping${N}"
else
    # Pick an interpreter with the P4Runtime protobufs, falling back to plain python3. Tests
    # that need them skip themselves, so the fallback still runs the emitter suite.
    PY_P4=""
    for candidate in "$P4_PROXY_PY" /home/adam/p4dev-python-venv/bin/python3 python3; do
        if [[ -n "$candidate" ]] && command -v "$candidate" >/dev/null 2>&1 \
                && "$candidate" -c "import p4.v1.p4runtime_pb2" >/dev/null 2>&1; then
            PY_P4="$candidate"; break
        fi
    done
    PY_PLAIN="$(command -v python3)"
    [[ -z "$PY_P4" ]] && echo "  ${Y}note: no interpreter with P4Runtime protobufs; " \
        "gRPC-dependent tests will skip themselves${N}"

    shopt -s nullglob
    for testfile in "$PROXY_DIR"/tests/test_*.py; do
        name="$(basename "$testfile")"
        log="$LOG_DIR/l1_python_${name%.py}.log"
        printf '  %-30s ' "$name"

        # Use the P4-capable interpreter when there is one; it is a superset.
        interp="${PY_P4:-$PY_PLAIN}"
        (cd "$PROXY_DIR" && PYTHONPATH=. "$interp" "$testfile" -v) >"$log" 2>&1
        rc=$?

        ran=$(grep -oE '^Ran [0-9]+ test' "$log" | tail -1 | grep -oE '[0-9]+')
        ran=${ran:-0}
        skipped=$(grep -cE "^test_.* \.\.\. skipped" "$log")

        if [[ $rc -ne 0 ]]; then
            echo "${R}FAIL${N} (exit $rc, ran=$ran)"
            grep -E "^(FAIL|ERROR):|AssertionError|SkipTest" "$log" | head -12 | sed 's/^/      /'
            FAILURES=$((FAILURES + 1))
        elif [[ $ran -eq 0 ]]; then
            # Either everything skipped or nothing was collected. Both mean this file proved
            # nothing, which is exactly the failure mode this script exists to catch.
            echo "${Y}NO TESTS RAN${N} ${D}(missing dependency? see $log)${N}"
            grep -E "SkipTest|ModuleNotFound" "$log" | head -3 | sed 's/^/      /'
        elif [[ $skipped -gt 0 ]]; then
            echo "${G}PASS${N}  ${D}${ran} ran, ${skipped} skipped${N}"
        else
            echo "${G}PASS${N}  ${D}${ran} ran and passed${N}"
        fi
    done
    shopt -u nullglob
fi

# --- 4. cross-check: ctest case count vs discovered tests ------------------------
step "cross-check ctest coverage"
ctest_cases=$(ctest --test-dir "$BUILD_DIR" -N 2>/dev/null | grep -cE '^\s+Test\s+#')
direct_total=0
for bin in "${TEST_BINS[@]}"; do
    n=$("$bin" --gtest_list_tests 2>/dev/null | grep -cE '^\s+\S')
    direct_total=$((direct_total + n))
done
printf '  ctest cases=%s   gtest tests=%s  ' "$ctest_cases" "$direct_total"
if [[ "$ctest_cases" -eq "$direct_total" ]]; then
    echo "${G}consistent${N}"
else
    echo "${Y}mismatch — a test may not be registered with ctest${N}"
fi

echo
echo "======================================================================"
if [[ $FAILURES -gt 0 ]]; then
    echo "${R}L1 FAILED ($FAILURES problem group(s))${N}   logs: $LOG_DIR"
    exit 1
fi
echo "${G}L1 passed: ${#TEST_BINS[@]} test binary/binaries, clean under ctest and direct execution.${N}"
