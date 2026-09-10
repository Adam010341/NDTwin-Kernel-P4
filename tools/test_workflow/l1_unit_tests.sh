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
# where this run can see for itself that a prerequisite is missing, which is a real environment
# limitation rather than a broken test. There are exactly two such prerequisites and the run
# computes both: an interpreter carrying the P4Runtime protobufs ($PY_P4), and the compiled P4
# artefacts that l0_build_check.sh writes to $P4_BUILD_DIR. Anything else that skips fails,
# whether the whole file skipped or one test in it.
#
# [Co-developed with claude code -- Adam]
# That last clause used to be false for a strict subset of skips. The all-skipped branch below
# did the work described here, but a file where *some* tests skipped printed
# "PASS N ran, M skipped" and exited 0 -- so the same condition that is a hard FAIL on the
# gtest side was a pass on this side, and a test that quietly started skipping itself (an
# ImportError guard that begins triggering is the easy way) cost the run nothing. The subset
# case is the more dangerous one, too: an all-skipped file is at least conspicuous.
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

# --- scoring the kernel-side lane ------------------------------------------------
# [Co-developed with claude code -- Adam]
# Defined up here, above the build, so tests/shell/test_l1_shell_scoring.sh can source this
# file with NDTWIN_L1_LIB_ONLY=1 and drive the scorer on fixtures without configuring cmake or
# touching the lab. A scorer reachable only by running the whole lane is a scorer nobody ever
# watches go red -- which is how the defect below survived: it was wrong for five suites for as
# long as those suites have existed, and the lane it broke is the thing that would have said so.

# shell_summary <log> -- echo "<ran> <failed>" for a tests/shell harness log.
#
# tests/shell does not use unittest, and only some of it ever printed unittest's vocabulary. The
# suites there end in one of three summary lines (counts as of 2026-09-02, 17 suites):
#
#   A   Ran 60 checks, all passed   /   Ran 6 checks, 0 failed        (12 suites)
#   B   12 passed, 0 failed             (optionally indented)         (4 suites)
#   C   ===== 34 check(s): 34 ok, 0 FAILED =====                      (1 suite)
#
# Scoring form A alone is what made L1 red on a green tree on 2026-09-02
# (doc/audit/2026-09-02_live-round/raw/B15,B16): five suites exited 0 with every check ok and
# were each counted as a problem group, so local_ci.sh reported the project broken.
#
# 🔴 What this must never do is answer "passed" for a log it does not understand. No recognised
# summary echoes "0 0", and 0 is a FAILURE in l1_lane_verdict below -- the same verdict as an
# explicit "Ran 0 checks" or "0 passed, 0 failed". "The suite asserted nothing" and "the suite
# asserted N things and they held" stay different facts and only the second is a pass. That is
# the distinction the whole count exists for: a harness whose cases sit under a guard that
# quietly stops matching runs zero of them and still exits 0, and the count is what catches it.
shell_summary() {
    awk '
        # The k-th run of digits on the line, or -1 if there are fewer than k.
        function numat(s, k,   n, t, i, j) {
            n = split(s, t, /[^0-9]+/)
            i = 0
            for (j = 1; j <= n; j++)
                if (t[j] != "") { i++; if (i == k) return t[j] + 0 }
            return -1
        }
        # A. The failed count is the SECOND number; "all passed" carries no second number.
        /^[[:space:]]*Ran [0-9]+ check/ {
            ran = numat($0, 1)
            failed = ($0 ~ /all passed/) ? 0 : numat($0, 2)
            if (failed < 0) failed = 0
            next
        }
        # B. Anchored at both ends: a check whose NAME quotes this shape is output, not a
        #    summary, and counting it would invent tests that never ran.
        /^[[:space:]]*[0-9]+ passed, [0-9]+ failed[[:space:]]*$/ {
            failed = numat($0, 2); ran = numat($0, 1) + failed
            next
        }
        # C. "===== N check(s): P ok, F FAILED =====".
        /^[[:space:]]*=+ [0-9]+ check\(s\): [0-9]+ ok, [0-9]+ FAILED =+[[:space:]]*$/ {
            ran = numat($0, 1); failed = numat($0, 3)
            next
        }
        # Last summary on the log wins, as `tail -1` did. Absent one, ran stays 0.
        END { printf "%d %d\n", ran + 0, failed + 0 }
    ' "$1"
}

# l1_lane_verdict <rc> <ran> <failed> <skipped> -- one token for what the lane should print.
#
# The order is the one this lane has always used, and each step is load-bearing:
#   FAIL-RC        the harness itself said no.
#   FAIL-SKIP      before NO-TESTS-RAN, because a shell suite that skips exits before printing
#                  a summary; scored the other way round the real reason is lost.
#   NO-TESTS-RAN   nothing was collected, or nothing this lane can read. Never a pass.
#   FAIL-CHECKS    exit 0 over a summary line that says checks failed. Cannot turn a red run
#                  green; it only refuses to believe a green exit code over its own numbers.
#   PASS
l1_lane_verdict() {
    local rc="$1" ran="$2" failed="$3" skipped="$4"
    if   [[ "$rc"      -ne 0 ]]; then echo FAIL-RC
    elif [[ "$skipped" -gt 0 ]]; then echo FAIL-SKIP
    elif [[ "$ran"     -eq 0 ]]; then echo NO-TESTS-RAN
    elif [[ "$failed"  -gt 0 ]]; then echo FAIL-CHECKS
    else                              echo PASS
    fi
}

# l1_check_test_tmpdirs <repo> <log> -- run that repo's temp-path scanner and report it.
# Echoes the lane's line(s); returns 0 when the tree is clean, 1 otherwise.
#
# [Co-developed with claude code -- Adam]
# 2026-09-08, decision E-17. tests/shell/check_test_tmpdirs.py asks whether any test CREATES a
# temp path whose name is the same string in every process. ctest gives every test its own
# process, so a constant path -- or a counter that restarts at 0 in each of them -- is a race
# that is green at -j1, red at -j2 only sometimes, and red in a DIFFERENT test each time, which
# is how it gets filed as "just re-run it". Measured 2026-09-06 (W11's round); c3d99d00 fixed six
# fixtures by hand and this is what stops the seventh. It reads files and builds nothing, so it
# belongs beside the anchor check rather than behind the build.
#
# 🔴 THREE outcomes, not two, and that is the whole reason this is a function rather than three
# lines inline. rc 2 means the scanner could not READ some file -- a string that never closed, a
# heredoc with no terminator -- and a file nobody could read is not a file with nothing in it.
# Three parser bugs while that tool was being written each made whole REAL files scan green and
# print exactly what a clean tree prints. So rc 2 is red, like rc 1, but it must not say the same
# thing: one means "a test names a path it shares", the other means "this gate went blind".
# KNOWN-ISSUES L-3 is the same lesson from check_gate_anchors.py's side.
#
# Takes the repo as an argument so the scanner and the tree it scans move together: that is what
# lets this function be driven over a sandbox tree, which is the only way anyone sees its two red
# branches without breaking the real one.
l1_check_test_tmpdirs() {
    local repo="$1" log="$2" rc
    python3 "$repo/tests/shell/check_test_tmpdirs.py" --repo "$repo" >"$log" 2>&1
    rc=$?
    case "$rc" in
    0)  echo "${G}test temp paths ok${N}  ${D}($(tail -1 "$log"))${N}"
        return 0
        ;;
    1)  echo "${R}test temp paths FAILED${N} — a test creates a temp path that is the same in" \
             "every process (see $log)"
        grep -E '^[^ ].*:[0-9]+: ' "$log" | head -10 | sed 's/^/  /'
        return 1
        ;;
    *)  echo "${R}test temp paths NOT CHECKED${N} — the scanner could not READ some of the" \
             "tests (exit $rc). This is the gate going blind, ${R}not${N} a clean tree" \
             "(see $log)"
        grep -E 'NOT CHECKED|COULD NOT BE READ' "$log" | head -5 | sed 's/^/  /'
        return 1
        ;;
    esac
}

# Everything below this line runs the lane. The suite that tests the scoring functions above
# stops here; nothing before it builds, writes or connects to anything.
[[ -n "${NDTWIN_L1_LIB_ONLY:-}" ]] && return 0

DO_BUILD=1
[[ "${1:-}" == "--no-build" ]] && DO_BUILD=0

BUILD_DIR="$KERNEL_DIR/build"
mkdir -p "$LOG_DIR"
FAILURES=0

step() { echo; echo "${D}--- $* ---${N}"; }

# --- 0. gate anchors (read-only, no build, runs even under --no-build) ----------
# [Co-developed with claude code -- Adam]
# 2026-09-04. tests/shell/check_gate_anchors.py: can every mutation gate still find the text it
# mutates? It never builds and never runs a gate, so it belongs ahead of the build below, not
# behind it -- a mutation gate whose anchor has silently drifted keeps exiting 0 (the gtest suite
# it protects is still green; the gate itself is what stopped mutating anything), and nothing
# else in this lane would ever say so. Checked against HEAD: this tool reads git revisions, not
# the working tree, so an uncommitted gate edit is not caught here -- known, and stated so
# nothing mistakes silence for having checked it.
step "gate anchors (read-only, no build)"
GATE_ANCHORS_LOG="$LOG_DIR/l1_gate_anchors.log"
mkdir -p "$LOG_DIR"
if python3 "$KERNEL_DIR/tests/shell/check_gate_anchors.py" HEAD >"$GATE_ANCHORS_LOG" 2>&1; then
    echo "${G}gate anchors ok${N}  ${D}($(grep -oE '^[0-9]+/[0-9]+ cells ok' "$GATE_ANCHORS_LOG" | head -1))${N}"
else
    echo "${R}gate anchors FAILED${N} (see $GATE_ANCHORS_LOG)"
    grep -E "^[0-9]+/[0-9]+ cells ok|NOT CHECKED AT ALL" "$GATE_ANCHORS_LOG" | head -5 | sed 's/^/  /'
    FAILURES=$((FAILURES + 1))
fi

# --- 0b. test temp paths (read-only, no build, runs even under --no-build) ------
# [Co-developed with claude code -- Adam]
# Decision E-17. Reasoning, and why exit 2 is its own kind of red, in l1_check_test_tmpdirs above.
# Same placement argument as the anchor check: nothing here builds, so a defect that makes the
# whole suite untrustworthy at -j2 is reported before the lane spends twenty minutes compiling.
step "test temp paths (read-only, no build)"
TMPDIRS_LOG="$LOG_DIR/l1_test_tmpdirs.log"
l1_check_test_tmpdirs "$KERNEL_DIR" "$TMPDIRS_LOG" || FAILURES=$((FAILURES + 1))

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

    # [Co-developed with claude code -- Adam]
    # The second prerequisite a skip is allowed to blame. l0_build_check.sh p4 writes this file;
    # without it the tests that compare the proxy's metadata-id constants against the generated
    # p4info have nothing to compare with and skip. Checked here rather than trusted from a list
    # of reasons: this is the same path l0 writes to, declared once in components.env, so it
    # cannot drift the way a hand-kept catalogue of acceptable skip messages would.
    P4INFO_FILE="$P4_BUILD_DIR/ndtwin_switch.p4info.txt"
    HAVE_P4INFO=0
    [[ -f "$P4INFO_FILE" ]] && HAVE_P4INFO=1
    [[ $HAVE_P4INFO -eq 0 ]] && echo "  ${Y}note: no compiled p4info at $P4INFO_FILE;" \
        "run l0_build_check.sh p4 -- tests that pin the metadata ids will skip themselves${N}"

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
            # Nothing was collected at all.
            echo "${Y}NO TESTS RAN${N} ${D}(missing dependency? see $log)${N}"
            grep -E "SkipTest|ModuleNotFound" "$log" | head -3 | sed 's/^/      /'
        elif [[ $skipped -gt 0 && $skipped -eq $ran ]]; then
            # [Co-developed with claude code -- Adam]
            # Every test in the file skipped, so the file asserted nothing. The `ran -eq 0` branch
            # above cannot catch this: unittest counts skipped tests *inside* "Ran N", unlike
            # gtest, so such a file prints "Ran 55 tests / OK" and used to be reported green.
            #
            # Three different situations reach here and they do not deserve the same verdict:
            #
            #  1. the file is an opt-in live test that says so. test_p4_client.py needs a real bmv2
            #     on :30051 and skips deliberately -- that is the design, not a defect, so it must
            #     not fail the run. It has to *declare* itself, though, because "everything
            #     skipped" is indistinguishable from a broken file otherwise.
            #  2. no interpreter on this machine has the P4Runtime protobufs, so the skip is the
            #     environment's fault rather than the file's. Reported, not failed.
            #  3. neither of those: the file could have run and chose not to. That is the bug this
            #     branch exists for.
            if grep -q 'NDTWIN_L1_OPT_IN' "$testfile"; then
                echo "${Y}SKIPPED${N} ${D}all ${ran} skipped; file declares it needs a live" \
                     "switch (NDTWIN_L1_OPT_IN)${N}"
            elif [[ -z "$PY_P4" ]]; then
                echo "${Y}PROVED NOTHING${N} ${D}all ${ran} skipped (no interpreter with the" \
                     "P4Runtime protobufs)${N}"
            else
                echo "${R}FAIL${N} all ${ran} test(s) skipped, and the file does not declare" \
                     "itself opt-in — it asserted nothing"
                grep -E "\.\.\. skipped" "$log" | head -3 | sed 's/^/      /'
                FAILURES=$((FAILURES + 1))
            fi
        elif [[ $skipped -gt 0 ]]; then
            # [Co-developed with claude code -- Adam]
            # A strict subset skipped. This printed "PASS N ran, M skipped" and exited 0, which
            # is what made the header's parity claim false: the same condition on the gtest side
            # is a hard FAIL, and a test that starts skipping itself is exactly the erosion both
            # checks exist to catch. It also cannot rely on the opt-in escape hatch above --
            # NDTWIN_L1_OPT_IN says "this whole file needs a live switch", which a file that ran
            # most of its tests plainly did not.
            #
            # The two environment excuses are the ones this run computed for itself, so the
            # verdict never depends on parsing a skip message. On a machine with both
            # prerequisites there is no excuse left, and today the reference checkout has zero
            # partially-skipped files -- so this costs nothing until something regresses.
            if [[ -z "$PY_P4" ]]; then
                echo "${Y}PROVED LESS${N} ${D}${ran} ran, ${skipped} skipped (no interpreter" \
                     "with the P4Runtime protobufs)${N}"
            elif [[ $HAVE_P4INFO -eq 0 ]]; then
                echo "${Y}PROVED LESS${N} ${D}${ran} ran, ${skipped} skipped (no compiled" \
                     "p4info; run l0_build_check.sh p4)${N}"
            else
                echo "${R}FAIL${N} ${skipped} of ${ran} test(s) skipped with both prerequisites" \
                     "present — a skipped test is not a passing test"
                grep -E "^test_.* \.\.\. skipped" "$log" | head -6 | sed 's/^/      /'
                FAILURES=$((FAILURES + 1))
            fi
        else
            echo "${G}PASS${N}  ${D}${ran} ran and passed${N}"
        fi
    done
    shopt -u nullglob
fi

# --- 3b. kernel-side Python and shell tests --------------------------------------
# [Co-developed with claude code -- Adam]
# Separate from p4_proxy/tests because these cover the OVS/Ryu side and the test tooling itself.
# Most run under a plain python3, but the walk suites (test_walk_instrumentation,
# test_find_host_by_ip) build real networkx graphs -- under a bare python3 they read as
# FAIL ran=0, which is how test_walk_instrumentation was red in this lane from the day it was
# added. So the lane picks an interpreter that carries networkx when one exists, same move as
# the P4 section above; plain python3 remains the fallback and runs everything else.
#
# [Co-developed with claude code -- Adam]
# 2026-08-25: the ryu env goes FIRST, and the probe now asks for ryu as well as networkx. Two
# reasons, one old and one new. The old one: on this machine neither $P4_PROXY_PY nor plain
# python3 carries networkx, so the walk suites had been skipping -- and this lane calls a skip a
# failure -- meaning the fix above never actually took effect here. The new one: the ring round's
# suites (test_topology_worker_coalescing, test_topology_read_timeouts) drive the real Ryu
# greenlet primitives, so networkx alone is not enough to run them.
#
# Ordered probe, not "first that exists": a candidate carrying both wins over one carrying
# neither, and the bare python3 fallback still runs everything that needs no imports.
step "kernel-side Python and shell tests"
PY_KERNEL="$(command -v python3)"
for candidate in "$RYU_PY" "$HOME/miniconda3/envs/ryu-env/bin/python" "$P4_PROXY_PY" python3; do
    if [[ -n "$candidate" ]] && command -v "$candidate" >/dev/null 2>&1 \
            && "$candidate" -c "import networkx, ryu" >/dev/null 2>&1; then
        PY_KERNEL="$candidate"; break
    fi
done
if ! "$PY_KERNEL" -c "import networkx, ryu" >/dev/null 2>&1; then
    # Say which one, because "N skip(s)" below names the symptom and not the cause.
    echo "  ${Y}note${N} ${D}no interpreter with networkx+ryu found; suites needing them will" \
         "skip, and this lane counts a skip as a failure. Set RYU_PY to override.${N}"
fi
shopt -s nullglob
KERNEL_TESTS=("$KERNEL_DIR"/tests/python/test_*.py "$KERNEL_DIR"/tests/shell/test_*.sh)
shopt -u nullglob
if [[ ${#KERNEL_TESTS[@]} -eq 0 ]]; then
    echo "  ${D}none found${N}"
else
    for testfile in "${KERNEL_TESTS[@]}"; do
        name="$(basename "$testfile")"
        log="$LOG_DIR/l1_kernel_${name%.*}.log"
        printf '  %-30s ' "$name"
        if [[ "$testfile" == *.py ]]; then
            # -v so a skip prints "test_x ... skipped 'reason'". Without it unittest prints a bare
            # "s" and the skip count only appears in the summary, which is how the skip check below
            # was dead for these files from the day it was written. Found by agy-review 0117.
            (cd "$KERNEL_DIR" && "$PY_KERNEL" "$testfile" -v) >"$log" 2>&1
        else
            (cd "$KERNEL_DIR" && bash "$testfile") >"$log" 2>&1
        fi
        rc=$?
        # How many checks ran, and how many of them were red. Zero ran means nothing was
        # collected, which proves nothing and must not read as a pass.
        # [Co-developed with claude code -- Adam]
        # Per file type, because the two harnesses report differently and applying unittest's
        # vocabulary to a shell script silently measures nothing. All three problems here were
        # found by agy-review 0117; the previous version had one code path for both.
        #
        # 2026-09-02: the count itself was still unittest's for both types -- a bare
        # `grep '^Ran [0-9]+'` -- and tests/shell has three summary forms of which only one
        # starts with "Ran". The five suites that print the other two were scored ran=0 and
        # counted as failures while every check in them was ok (raw/B15, raw/B16), so this lane
        # and local_ci.sh were red on a green tree. Shell logs now go through shell_summary,
        # which knows all three forms and still answers 0 for a log it cannot read.
        ran=0; failed=0
        if [[ "$testfile" == *.py ]]; then
            # unittest's own line, which is correct here and stays. It counts skipped tests
            # inside "Ran N", so N > 0 does not mean anything was asserted -- hence the skip
            # check below -- and a file whose cases sit under a __main__ guard collects nothing
            # and prints "Ran 0 tests", the shape this lane must keep calling a failure.
            ran=$(grep -oE '^Ran [0-9]+' "$log" | tail -1 | grep -oE '[0-9]+')
            ran=${ran:-0}
            # Both spellings: the "... skipped" lines that -v produces, and the summary count, which
            # appears either way. Belt and braces, because relying on -v alone is what broke before.
            skipped=$(grep -cE "\.\.\. skipped" "$log")
            summary_skipped=$(grep -oE '\(skipped=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+')
            [[ -n "$summary_skipped" && "${summary_skipped:-0}" -gt "${skipped:-0}" ]] \
                && skipped="$summary_skipped"
            skip_evidence='\.\.\. skipped|\(skipped='
        else
            # Shell tests do not use unittest. This repo's convention is a "SKIP:" line, and such a
            # script exits 0 *before* printing its "Ran N checks" summary -- which used to surface as
            # a confusing "NO TESTS RAN" rather than as a skip.
            read -r ran failed <<<"$(shell_summary "$log")"
            skipped=$(grep -cE "^[[:space:]]*SKIP:" "$log")
            skip_evidence='^[[:space:]]*SKIP:'
        fi
        case "$(l1_lane_verdict "$rc" "${ran:-0}" "${failed:-0}" "${skipped:-0}")" in
        FAIL-RC)
            echo "${R}FAIL${N} (exit $rc, ran=$ran)"
            grep -E "^(FAIL|ERROR):|AssertionError|FAILED " "$log" | head -8 | sed 's/^/      /'
            FAILURES=$((FAILURES + 1))
            ;;
        FAIL-SKIP)
            # Checked before the ran-eq-0 branch: a shell test that skips exits before printing a
            # summary, so it would otherwise be reported as "no tests ran" and the real reason lost.
            echo "${R}FAIL${N} ${skipped} skip(s) — nothing in tests/python or tests/shell has a" \
                 "reason to skip"
            grep -E "$skip_evidence" "$log" | head -5 | sed 's/^/      /'
            FAILURES=$((FAILURES + 1))
            ;;
        NO-TESTS-RAN)
            echo "${Y}NO TESTS RAN${N} ${D}(see $log)${N}"
            FAILURES=$((FAILURES + 1))
            ;;
        FAIL-CHECKS)
            # Exit 0 with a summary line that names failures. The harness contradicted itself;
            # believe the numbers, not the status.
            echo "${R}FAIL${N} ${failed} of ${ran} check(s) failed, but the suite exited 0"
            grep -E "^[[:space:]]*(FAILED|FAIL )" "$log" | head -8 | sed 's/^/      /'
            FAILURES=$((FAILURES + 1))
            ;;
        *)
            echo "${G}PASS${N} ${D}${ran} ran and passed${N}"
            ;;
        esac
    done
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
