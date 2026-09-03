#!/usr/bin/env bash
#
# Mutation gate for tests/test_SimulatedDeviceMetrics.cpp (F-1: the CPU/memory/temperature
# figures MININET mode used to invent).
#
# [Co-developed with claude code -- Adam]
#
# 🔴 The suite this gates has NEVER BEEN SEEN RED. It was written in a window where building was
# forbidden -- a CPU-sensitive measurement was running -- so it has not been compiled, let alone
# run. Until this script exits 0, tests/test_SimulatedDeviceMetrics.cpp is not delivered.
#
# The mutation that matters most is M5. M1-M4 put the four original fabrications back, which any
# equality assertion would catch; M5 installs a *different, better-looking* fake -- wider spread,
# no two switches colliding. That is the tempting "fix" for a number that never changes, and it
# is strictly worse than the old one because it survives the two questions that catch the old one
# ("why is it always the same?" and "why do these two switches match?"). If M5 survives, the
# suite is pinning the old formula rather than the property, and it is the wrong suite.
#
# C1 is the control: a comment-only edit that must stay GREEN. Without it, a harness that reports
# red for any edit at all -- a stale binary, a build that silently failed, a filter that matches
# nothing -- would look like a perfect mutation score.
#
# M8 is declared an EXPECTED SURVIVOR and is reported separately from the score. Its defect is
# undefined behaviour (a null dereference), and this build has no _GLIBCXX_ASSERTIONS, no
# _GLIBCXX_DEBUG and no sanitizer, so whether the suite notices is a property of the compiler
# rather than of the test. Counting it would make the gate lie about the test either way. Its
# comment block says how to make it observable.
#
# [Co-developed with claude code -- Adam] 2026-09-04, FINDINGS #85: M8's anchor was re-pointed,
# because the line it moved -- `std::string ip_str = utils::ipToString(vp.ip.front());` -- no
# longer exists in fetchTemperatureReportInternal. That read is now managementIpForReport(vp),
# which answers nullopt instead of faulting. M8 still moves the address read above the type
# filter, and is still an expected survivor, but no longer for the old reason: the mutant is not
# undefined behaviour any more, it is an unasserted side effect (a host with no address now takes
# a WARN and an entry in the missing-address set that no assertion in THIS suite looks at). The
# harm F-1b named is gone; what M8 measures now is that this suite does not cover the ordering
# for its own sake. Left in place, with its verdict unchanged, rather than deleted: removing a
# mutation because it stopped being dangerous is how a gate quietly gets easier.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. Baseline is the WORKING TREE, not HEAD, so this
# runs against an uncommitted fix. These files are in a worktree other sessions write to.
#
# Assumptions (stated because they are the script's failure modes):
#   * cwd is the repo root, or this script is run by path from anywhere -- it cds to its own ../..
#   * ${BUILD_DIR:-build} is an already-configured build directory (ninja)
#   * the suite is linked into the test_routing_strategy binary, per tests/CMakeLists.txt
#
# Usage:
#   bash tests/shell/mutate_f1_mininet_health_metrics.sh
#   BUILD_DIR=build-debug bash tests/shell/mutate_f1_mininet_health_metrics.sh
#
# Exit codes:
#   0  every mutation was caught and the control stayed green
#   1  at least one mutation survived, or one could not be applied/built
#   2  the baseline itself is not green -- the compile or the fix is the problem, not a mutation
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
HDR=include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp
FILES=("$SRC" "$HDR")

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
BIN="${BIN:-$BUILD_DIR/bin/$TARGET}"
FILTER="${FILTER:-SimulatedDeviceMetricsTest.*}"

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1").$(echo "$1" | md5sum | cut -c1-6)"; }
for f in "${FILES[@]}"; do cp "$f" "$(snap "$f")"; done
restore() { local f; for f in "${FILES[@]}"; do cp "$(snap "$f")" "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
EXPECTED_SURVIVORS=0
INVALID=0

# --- mechanics ---------------------------------------------------------------------------------

# Exact-string replacement. \Q..\E makes the pattern literal, so anchors carry braces, %, < and >
# without escaping; the replacement is interpolated once and used verbatim.
apply() {   # $1 = file, $2 = exact anchor, $3 = replacement
    ANCHOR="$2" REPL="$3" perl -0777 -i -pe 's/\Q$ENV{ANCHOR}\E/$ENV{REPL}/' "$1"
}

# An anchor that matches twice would mutate two places at once and the result would not say which
# one the test caught. Checked on a SINGLE line, which is why every anchor below is one line or is
# introduced by a line unique on its own.
assert_unique() {   # $1 = file, $2 = single-line anchor
    local n
    n=$(grep -c -F -- "$2" "$1")
    if [[ "$n" -ne 1 ]]; then
        printf '  INVALID  anchor matches %s times in %s (want 1): %s\n' "$n" "$1" "$2"
        return 1
    fi
    return 0
}

build() {
    cmake --build "$BUILD_DIR" --target "$TARGET" >"$BK/build.log" 2>&1
}

# rc captured directly, never through a pipe: `cmd | tail` reports tail's status.
run_suite() {
    "$BIN" --gtest_filter="$FILTER" >"$BK/run.log" 2>&1
}

# --- baseline ----------------------------------------------------------------------------------

echo "baseline (unmutated) must build and be green:"
build; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline build failed (rc=$rc) -- the fix or the new test does not compile."
    echo "          This is a compile problem, not a mutation result. Last 40 lines:"
    tail -40 "$BK/build.log" | sed 's/^/    /'
    exit 2
fi
if [[ ! -x "$BIN" ]]; then
    echo "  REFUSE: $BIN is missing or not executable after a successful build."
    echo "          Check BUILD_DIR (currently '$BUILD_DIR') and CMAKE_RUNTIME_OUTPUT_DIRECTORY."
    exit 2
fi
run_suite; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline is not green (rc=$rc). Failing tests:"
    grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'
    echo "          The compile or the base is the problem, not a mutation."
    exit 2
fi
if ! grep -qE '^\[  PASSED  \] [1-9]' "$BK/run.log"; then
    echo "  REFUSE: the filter '$FILTER' ran no tests. A gate over zero tests proves nothing."
    tail -20 "$BK/run.log" | sed 's/^/    /'
    exit 2
fi
printf '  ok       baseline green (%s)\n' "$(grep -E '^\[  PASSED  \]' "$BK/run.log" | tail -1)"
echo

# --- reporting ---------------------------------------------------------------------------------

# $1 = mutation name, $2 = the test that MUST go red, $3 = file, $4 = anchor, $5 = replacement
# ($4 may be multi-line; $6, when given, is the single line whose uniqueness is asserted.)
mutate_must_die() {
    local name="$1" must_fail="$2" file="$3" anchor="$4" repl="$5" uniq="${6:-$4}"
    local rc

    MUTATIONS=$((MUTATIONS + 1))

    if ! assert_unique "$file" "$uniq"; then
        INVALID=$((INVALID + 1)); restore; return
    fi

    apply "$file" "$anchor" "$repl"
    # A no-op "mutation" leaves the suite green and would be reported as SURVIVED, which would be
    # a lie about the test rather than about the code. Multi-line anchors are where this happens.
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-46s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi

    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-46s (mutant does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi

    run_suite; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $must_fail" "$BK/run.log"; then
        printf '  caught   %-46s (%s went red)\n' "$name" "$must_fail"
    else
        printf '  SURVIVED %-46s (%s stayed green -- that test proves nothing)\n' "$name" "$must_fail"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             also red: /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# The control. Same machinery, opposite expectation.
mutate_must_live() {
    local name="$1" file="$2" anchor="$3" repl="$4"
    local rc

    MUTATIONS=$((MUTATIONS + 1))

    if ! assert_unique "$file" "$anchor"; then
        INVALID=$((INVALID + 1)); restore; return
    fi

    apply "$file" "$anchor" "$repl"
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-46s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi

    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-46s (control does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi

    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ok       %-46s (control stayed green, as it must)\n' "$name"
    else
        printf '  SURVIVED %-46s (control went RED -- the harness reports red for any edit,\n' "$name"
        printf '           %-46s  so every "caught" above is worthless)\n' ""
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# A mutation whose effect is UNDEFINED BEHAVIOUR rather than a wrong value. Reported, never
# counted as a survivor: this build has no _GLIBCXX_ASSERTIONS, no _GLIBCXX_DEBUG and no
# sanitizer (see M8's comment), so whether the suite notices is a property of the compiler, not
# of the test. Failing the gate on it would make the gate lie about the test.
#
# $1 name, $2 test that would go red if observable, $3 file, $4 anchor, $5 repl, $6 uniq line
mutate_may_survive() {
    local name="$1" would_fail="$2" file="$3" anchor="$4" repl="$5" uniq="${6:-$4}"
    local rc last

    MUTATIONS=$((MUTATIONS + 1))

    if ! assert_unique "$file" "$uniq"; then
        INVALID=$((INVALID + 1)); restore; return
    fi
    apply "$file" "$anchor" "$repl"
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-46s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi
    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-46s (mutant does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi

    run_suite; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $would_fail" "$BK/run.log"; then
        printf '  caught   %-46s (%s went red)\n' "$name" "$would_fail"
    elif [[ "$rc" -ne 0 ]] && ! grep -qF '[  FAILED  ]' "$BK/run.log"; then
        # No verdict line at all: the process died mid-test. That is what a null dereference looks
        # like without library assertions -- a real catch, but a crash rather than an assertion,
        # and it takes the rest of the binary down with it.
        last=$(grep -F '[ RUN      ]' "$BK/run.log" | tail -1)
        printf '  caught   %-46s (process DIED during%s -- crash, not an assertion;\n' \
            "$name" "${last#*\]}"
        printf '           %-46s  later tests in the binary never ran)\n' ""
    elif [[ "$rc" -ne 0 ]]; then
        printf '  caught   %-46s (red, but not in %s):\n' "$name" "$would_fail"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             /'
    else
        printf '  EXPECTED-SURVIVOR %-35s (stayed green; see the note in M8 -- this build\n' "$name"
        printf '           %-46s  cannot observe the UB, so this is not a test defect)\n' ""
        EXPECTED_SURVIVORS=$((EXPECTED_SURVIVORS + 1))
    fi
    restore
}

echo "mutations:"

# --- M1: the CPU map endpoint invents a figure again -------------------------------------------
# The original defect, verbatim from 4cbec52d:1548.
mutate_must_die \
    "M1 cpu-map-refabricates" \
    "SimulatedDeviceMetricsTest.CpuReportsUnavailableForEverySwitch" \
    "$SRC" \
    '            cpu = kHealthMetricUnavailable;' \
    '            cpu = 10 + (std::hash<std::string>{}(ip_str) % 50);'

# --- M2: the memory endpoint invents a figure again --------------------------------------------
# Byte-identical to M1's expression on the same seed -- which is the half of F-1 the KNOWN-ISSUES
# entry names, and the reason the two endpoints answered the same body.
mutate_must_die \
    "M2 memory-map-refabricates" \
    "SimulatedDeviceMetricsTest.MemoryReportsUnavailableForEverySwitch" \
    "$SRC" \
    '            memory = kHealthMetricUnavailable;' \
    '            memory = 10 + (std::hash<std::string>{}(ip_str) % 50);'

# --- M3: temperature invents a figure again ----------------------------------------------------
mutate_must_die \
    "M3 temperature-refabricates" \
    "SimulatedDeviceMetricsTest.TemperatureReportsUnavailableForEverySwitch" \
    "$SRC" \
    '            temp = kHealthMetricUnavailable;' \
    '            temp = 25 + (std::hash<std::string>{}(ip_str) % 25);'

# --- M4: the fourth copy, on the Intent Translator's per-device path ---------------------------
# The one doc/KNOWN-ISSUES.md's F-1 entry does not name. It must red a DIFFERENT test from M1: if
# it reds CpuReportsUnavailableForEverySwitch instead, the per-device path is not separately
# covered and a future edit could fix the map endpoints while leaving this one fabricating.
# Two-line anchor; uniqueness is asserted on the comment line, which is unique on its own (the
# `        cpu = ...` line is not -- as a substring it also matches the 12-space one in M1).
mutate_must_die \
    "M4 intent-translator-copy-refabricates" \
    "SimulatedDeviceMetricsTest.TheIntentTranslatorsPerDeviceQueryAgreesWithTheMap" \
    "$SRC" \
    '        // agreed with each other; they were both wrong. See kHealthMetricUnavailable.
        cpu = kHealthMetricUnavailable;' \
    '        // agreed with each other; they were both wrong. See kHealthMetricUnavailable.
        cpu = 10 + (std::hash<std::string>{}(deviceIdentifier) % 50);' \
    '        // agreed with each other; they were both wrong. See kHealthMetricUnavailable.'

# --- M5: a BETTER fake -- the one that matters -------------------------------------------------
# Wider band, 97 buckets instead of 50, so over ten switches a collision is unlikely and the
# numbers look spread out and credible. Everything F-1's *symptom* complained about is fixed and
# the defect is untouched. A suite that only pins the old formula goes green here.
mutate_must_die \
    "M5 better-fake-varies-plausibly" \
    "SimulatedDeviceMetricsTest.NoTwoSwitchesShareAFabricatedNumber" \
    "$SRC" \
    '            cpu = kHealthMetricUnavailable;' \
    '            cpu = 3 + (std::hash<std::string>{}(ip_str) % 97);'

# --- M6: the sentinel becomes 0 ----------------------------------------------------------------
# 0 is the specific wrong answer this endpoint has produced before: when the key was dropped, the
# Web-GUI's `data[ip] || 0` rendered a dead switch as 0%, which reads as idle rather than absent.
# A sentinel inside the plausible range is not a sentinel.
mutate_must_die \
    "M6 sentinel-becomes-zero" \
    "SimulatedDeviceMetricsTest.CpuReportsUnavailableForEverySwitch" \
    "$HDR" \
    '    static constexpr int kHealthMetricUnavailable = -1;' \
    '    static constexpr int kHealthMetricUnavailable = 0;'

# --- M7: the down-switch key is dropped again --------------------------------------------------
# The 2026-08-18 defect restored in the memory report only: `continue` without writing the
# sentinel, so a powered-off switch vanishes from the response. Must red the down-switch test and
# nothing else -- no other test in the suite puts a down switch in the graph.
mutate_must_die \
    "M7 down-switch-key-dropped-again" \
    "SimulatedDeviceMetricsTest.ADownSwitchStillReportsTheSameSentinel" \
    "$SRC" \
    '            result_json[ip_str] = -1;' \
    '            // mutated: key dropped, restoring the 2026-08-18 defect'

# --- M8: the IP read moves back above the type filter ------------------------------------------
# F-1b. fetchTemperatureReportInternal used to take vp.ip.front() as the loop's first statement,
# before the vertexType filter, while the CPU and memory loops filtered first. A vertex with an
# empty `ip` -- a host the topology file gave no address -- made that a null dereference.
#
# 🔴 DECLARED EXPECTED-SURVIVOR, because this build cannot reliably observe it. Checked, not
# assumed:
#   _GLIBCXX_ASSERTIONS   not defined -- zero hits in CMakeLists.txt, tests/CMakeLists.txt, cmake/
#   _GLIBCXX_DEBUG        not defined -- likewise zero hits
#   sanitizers            opt-in only: cmake/sanitizer-flags.cmake:22-24 returns unless
#                         -DSANITIZER= is passed, and tests/CMakeLists.txt:113 puts -fsanitize
#                         only on fuzz_sflow, behind FUZZING=ON (clang-only, OFF by default)
#   the only global define is SPDLOG_ACTIVE_LEVEL (CMakeLists.txt:66)
#
# So the likely outcome here is a SEGFAULT that kills the binary before any verdict is printed --
# which mutate_may_survive reports as a catch-by-crash -- or, if the compiler is feeling
# creative, nothing at all. Neither counts against the gate.
#
# To watch it fail properly:
#   cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=asan
#   BUILD_DIR=build-asan bash tests/shell/mutate_f1_mininet_health_metrics.sh
# UBSan's null-dereference check with -fno-sanitize-recover=all makes it a named red line.
mutate_may_survive \
    "M8 ip-read-moves-above-the-filter" \
    "SimulatedDeviceMetricsTest.AVertexWithNoIpIsSkippedRatherThanDereferenced" \
    "$SRC" \
    '        // [Co-developed with claude code -- Adam] F-1b: read the IP AFTER the type filter, the
        // shape fetchCpuReportInternal and fetchMemoryReportInternal already have. It used to be
        // the first statement in the loop body, so vp.ip.front() was taken from a vertex of ANY
        // type -- and VertexProperties::ip is a std::vector that starts empty.
        //
        // The hazard was already written down for the power path: the note on
        // syntheticPowerMilliwattsFor in the header says a vertex ip vector can be empty and the
        // MININET path must not call ip.front(), which is why that report is keyed by dpid. This
        // loop never got the same treatment, and it was the only one of the three that read
        // before it filtered.
        //
        // A switch carrying no IP would still fault one branch later, in all three functions.
        // That is a separate question -- what a switch with no management IP should report -- and
        // is deliberately not answered here.
        if (vp.vertexType != VertexType::SWITCH)
        {
            continue;
        }

        // [Co-developed with claude code -- Adam]
        // FINDINGS #85, the third of the three the comment above predicted would "still fault one
        // branch later". See managementIpForReport in the header.
        const auto ipOpt = managementIpForReport(vp);' \
    '        const auto ipOpt = managementIpForReport(vp);
        if (vp.vertexType != VertexType::SWITCH)
        {
            continue;
        }
' \
    '        // shape fetchCpuReportInternal and fetchMemoryReportInternal already have. It used to be'

# --- C1: the control ---------------------------------------------------------------------------
# Comment text only. If this goes red, the harness is measuring "did anything change" rather than
# "did behaviour change", and every "caught" line above is meaningless.
mutate_must_live \
    "C1 control-comment-only" \
    "$SRC" \
    '            // See kHealthMetricUnavailable in the header for why this is -1 and not a better' \
    '            // CONTROL EDIT: comment text only, no behaviour change. See the header for why'

# --- restoration and verdict -------------------------------------------------------------------

restore
echo
ok=1
for f in "${FILES[@]}"; do
    cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }
done
if [[ "$ok" == 1 ]]; then
    echo "baseline restored: both source files byte-identical to the pre-run snapshot"
else
    echo "🔴 the working tree was left mutated -- do not commit until this is sorted out"
fi

# Rebuild from the restored source so the build directory agrees with the tree: otherwise the next
# ctest run would execute the last mutant's binary and read as a spurious failure.
echo "rebuilding from the restored source:"
build; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  🔴 rebuild after restore failed (rc=$rc) -- the tree may not be what it was"
    tail -20 "$BK/build.log" | sed 's/^/    /'
    ok=0
else
    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        echo "  ok       green again from the restored source"
    else
        echo "  🔴 NOT green after restore (rc=$rc):"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'
        ok=0
    fi
fi

echo
printf '%d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
if [[ "$EXPECTED_SURVIVORS" -gt 0 ]]; then
    printf '%d expected survivor(s) not counted above: undefined-behaviour mutations this build\n' \
        "$EXPECTED_SURVIVORS"
    printf '  cannot observe (no _GLIBCXX_ASSERTIONS, no _GLIBCXX_DEBUG, no sanitizer).\n'
    printf '  Re-run with BUILD_DIR pointing at a -DSANITIZER=asan build to score them.\n'
fi
if [[ "$INVALID" -gt 0 ]]; then
    printf '%d could not be applied or built -- neither caught nor survived; a human must look\n' \
        "$INVALID"
fi

[[ "$SURVIVORS" -eq 0 && "$INVALID" -eq 0 && "$ok" == 1 ]]
