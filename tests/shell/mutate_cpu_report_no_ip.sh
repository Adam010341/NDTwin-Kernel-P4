#!/usr/bin/env bash
#
# Mutation gate for tests/test_CpuReportNoIpSwitch.cpp (FINDINGS #85: a SWITCH vertex with no
# management address made the status worker's four reports call front() on an empty vector).
#
# [Co-developed with claude code -- Adam]
#
# Structure, mechanics and wording are lifted from mutate_f1_mininet_health_metrics.sh, which
# gates the neighbouring suite over the same two files. Copied rather than shared for the reason
# that gate gives: a common harness is a second place for the answer to be wrong, and
# check_gate_anchors.py reads each gate's own anchors.
#
# M1 and M2 put the defect itself back -- trunk's exact expression, byte for byte -- at the CPU
# site the gdb backtrace named and at the power site that would have faulted first in TESTBED
# mode. Unlike F-1's M8, these are NOT declared expected survivors: the fault happens inside a
# forked death-test child, so the suite reports a named red line whether or not the compiler
# chooses to crash, and the parent survives to print it. That is the whole reason the death test
# exists rather than a plain call.
#
# M9 is the one that matters most, and it is the only mutation here that makes the code *safer*
# in the naive sense: it hoists the address guard above the deployment-mode branch in the power
# report, so a switch with no address stops getting its MININET synthetic figure too. Nothing
# crashes, nothing is undefined, and the fix looks tidier. It is wrong, because the MININET power
# figure is a function of the dpid alone and never needed an address -- over-guarding is how a
# crash fix turns into a silent loss of data. If M9 survives, the suite is pinning "does not
# crash" and not "reports what it can".
#
# C1-C3 are the controls: three behaviour-preserving widenings that must stay GREEN. Without
# them, a harness that reports red for any edit at all -- a stale binary, a build that silently
# failed, a filter that matches nothing -- would look like a perfect mutation score.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. Baseline is the WORKING TREE, not HEAD, so this
# runs against an uncommitted fix. These files are in a worktree other sessions write to.
#
# Assumptions (stated because they are the script's failure modes):
#   * cwd is the repo root, or this script is run by path from anywhere -- it cds to its own ../..
#   * ${BUILD_DIR:-build} is an already-configured build directory (ninja)
#   * the suite is linked into the test_routing_strategy binary, per tests/CMakeLists.txt
#   * builds go through tools/build_guard/guarded_build.sh unless NO_GUARD=1 -- this laptop's
#     systemd-oomd kills the user's own application when an unguarded build takes the memory.
#
# Usage:
#   bash tests/shell/mutate_cpu_report_no_ip.sh
#   BUILD_DIR=build-debug bash tests/shell/mutate_cpu_report_no_ip.sh
#
# Exit codes:
#   0  every mutation was caught and all three controls stayed green
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
FILTER="${FILTER:-NoIpSwitchTest.*}"
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1").$(echo "$1" | md5sum | cut -c1-6)"; }
for f in "${FILES[@]}"; do cp "$f" "$(snap "$f")"; done
restore() { local f; for f in "${FILES[@]}"; do cp "$(snap "$f")" "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
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

# Every build in this gate goes through the guard: JOBS=1 because HttpSession.cpp and LLMAgent.cpp
# take ~1.6 GB each and two at once exceed the guard's MemoryHigh, and because an unguarded build
# on this laptop is what got the user's application killed by systemd-oomd on 2026-09-02.
# NO_GUARD=1 is for a machine where the guard is not installed; say so in the log if you use it.
build() {
    if [[ "${NO_GUARD:-0}" == "1" || ! -x "$GUARD" ]]; then
        cmake --build "$BUILD_DIR" --target "$TARGET" >"$BK/build.log" 2>&1
    else
        LOCK_WAIT="${LOCK_WAIT:-10800}" JOBS=1 "$GUARD" \
            cmake --build "$BUILD_DIR" --target "$TARGET" -j1 >"$BK/build.log" 2>&1
    fi
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
    elif [[ "$rc" -ne 0 ]] && ! grep -qF '[  FAILED  ]' "$BK/run.log"; then
        # No verdict line at all: the process died mid-test, taking the rest of the binary with
        # it. That is a catch, but a crash rather than an assertion -- and for THIS gate it means
        # the death test did not contain the fault the way it is supposed to. Named separately so
        # it cannot be read as a clean red.
        printf '  SURVIVED %-46s (process DIED with no verdict line -- the death test was\n' "$name"
        printf '           %-46s  meant to contain this; %s never reported)\n' "" "$must_fail"
        tail -6 "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    else
        printf '  SURVIVED %-46s (%s stayed green -- that test proves nothing)\n' "$name" "$must_fail"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             also red: /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# A control. Same machinery, opposite expectation: a behaviour-preserving edit must stay green.
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

echo "mutations:"

# --- M1: the crash, put back, at the site the gdb backtrace named ------------------------------
# trunk's expression byte for byte. The death test forks, so this is a named red line rather than
# a binary that dies with no verdict.
mutate_must_die \
    "M1 cpu-dereferences-empty-ip-again" \
    "NoIpSwitchTest.AStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess" \
    "$SRC" \
    '        const auto ipOpt = managementIpForReport(vp);
        if (!ipOpt)
        {
            result[reportKeyForSwitchWithoutIp(vp.dpid)] = kHealthMetricUnavailable;
            continue;
        }
        const std::string ip_str = *ipOpt;

        // [Co-developed with claude code -- Adam]
        // A switch that is down gets the documented sentinel, not a missing key.' \
    '        std::string ip_str = utils::ipToString(vp.ip.front());

        // [Co-developed with claude code -- Adam]
        // A switch that is down gets the documented sentinel, not a missing key.' \
    '        // FINDINGS #85, and the site the gdb backtrace named. Was'

# --- M2: the same defect on the power path -----------------------------------------------------
# statusUpdateWorker calls the power report FIRST, so in TESTBED mode this is the site that would
# actually have faulted before the CPU one ever ran.
#
# 🔴 This mutation SURVIVED on 2026-09-04 11:54, and the survivor was real. It used to name the
# MININET death test, which cannot reach this site at all: in MININET the power figure is
# syntheticPowerMilliwattsFor(dpid) and no address is read. The fault landed in
# TestbedPowerReportsTheSentinelForAnAddresslessSwitch instead -- an ordinary in-process call --
# so the binary died with no verdict line and this gate scored it SURVIVED rather than letting a
# crash read as a clean red. It now names a second death test that runs the round in TESTBED
# mode, declared above every in-process TESTBED test so the fork happens first.
mutate_must_die \
    "M2 testbed-power-dereferences-empty-ip" \
    "NoIpSwitchTest.ATestbedStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess" \
    "$SRC" \
    '            const auto ipOpt = managementIpForReport(props);
            if (!ipOpt)
            {
                result.push_back(entryFor(props, kHealthMetricUnavailable));
                continue;
            }
            const std::string ip_str = *ipOpt;' \
    '            std::string ip_str = utils::ipToString(props.ip.front());' \
    '            const auto ipOpt = managementIpForReport(props);'

# --- M3: the WARN fires every round ------------------------------------------------------------
# The status worker ticks every 10 s and re-reads the whole graph, so an un-edge-triggered WARN is
# a line every 10 s for as long as the topology is wrong. That is the shape that put 3596 sudo
# errors into a single run and buried everything else in it.
mutate_must_die \
    "M3 warn-every-round-not-once" \
    "NoIpSwitchTest.TheMissingAddressWarnsOncePerEpisodeAndNamesTheDpid" \
    "$SRC" \
    '    if (noteSwitchMissingManagementIp(vp.dpid))' \
    '    if (noteSwitchMissingManagementIp(vp.dpid), true)'

# --- M4: the switch is skipped in silence ------------------------------------------------------
# No WARN at all. The report still answers, so nothing looks broken -- and a topology file with a
# switch that has no address stays wrong for ever because nothing ever says which switch.
mutate_must_die \
    "M4 skipped-silently-no-warn" \
    "NoIpSwitchTest.TheMissingAddressWarnsOncePerEpisodeAndNamesTheDpid" \
    "$SRC" \
    '    if (noteSwitchMissingManagementIp(vp.dpid))
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),' \
    '    if (false)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),' \
    '    if (noteSwitchMissingManagementIp(vp.dpid))'

# --- M5: the CPU entry is dropped instead of reported ------------------------------------------
# The 2026-08-18 defect in its new clothes: a switch that vanishes from the body renders as 0%
# through the Web-GUI's `data[ip] || 0` -- as an idle switch rather than an unreadable one.
mutate_must_die \
    "M5 cpu-entry-dropped-not-reported" \
    "NoIpSwitchTest.TheAddresslessSwitchKeepsAKeyAtTheDocumentedSentinel" \
    "$SRC" \
    '            result[reportKeyForSwitchWithoutIp(vp.dpid)] = kHealthMetricUnavailable;
            continue;
        }
        const std::string ip_str = *ipOpt;

        // [Co-developed with claude code -- Adam]
        // A switch that is down gets the documented sentinel, not a missing key.' \
    '            continue;
        }
        const std::string ip_str = *ipOpt;

        // [Co-developed with claude code -- Adam]
        // A switch that is down gets the documented sentinel, not a missing key.' \
    '        // FINDINGS #85, and the site the gdb backtrace named. Was'

# --- M6: the CPU sentinel becomes 0 ------------------------------------------------------------
# 0 is the specific wrong answer this endpoint has produced before. A sentinel inside the
# plausible range is not a sentinel: it is a reading.
mutate_must_die \
    "M6 cpu-sentinel-becomes-zero" \
    "NoIpSwitchTest.TheSentinelIsNotSomethingAReaderWouldTakeForAMeasurement" \
    "$HDR" \
    '    static constexpr int kHealthMetricUnavailable = -1;' \
    '    static constexpr int kHealthMetricUnavailable = 0;'

# --- M7: the power sentinel becomes 0 ----------------------------------------------------------
# Worse here than anywhere else: 0 mW is already this endpoint's answer for a switch that is
# powered OFF, and a switch reported at 0 mW is exactly what the Energy-Saving application is
# looking for. "Cannot read it" and "it is off" must not be the same number.
#
# 🔴 RE-ANCHORED 2026-09-10 (R5). The four exits of fetchPowerReportInternal now build their entry
# through one `entryFor` lambda, so that they all carry `power_path` -- which means the sentinel
# line this mutation used to name verbatim is now the same text at the exempt exit two branches
# below it. The anchor therefore carries the `if (!ipOpt)` block around it, and the uniqueness
# assertion names the `managementIpForReport` line that introduces it; a single-line anchor here
# would silently mutate whichever of the two perl reached first.
mutate_must_die \
    "M7 power-sentinel-becomes-zero" \
    "NoIpSwitchTest.TestbedPowerReportsTheSentinelForAnAddresslessSwitch" \
    "$SRC" \
    '            if (!ipOpt)
            {
                result.push_back(entryFor(props, kHealthMetricUnavailable));
                continue;
            }' \
    '            if (!ipOpt)
            {
                result.push_back(entryFor(props, 0));
                continue;
            }' \
    '            const auto ipOpt = managementIpForReport(props);'

# --- M8: the episode never ends ----------------------------------------------------------------
# Drop the recovery half of the edge trigger. The first episode still warns exactly once, so
# every assertion about "not once per round" stays green -- and a switch that loses its address a
# second time is never reported again for the life of the process.
mutate_must_die \
    "M8 episode-never-ends" \
    "NoIpSwitchTest.ANewEpisodeWarnsAgain" \
    "$SRC" \
    '        noteSwitchHasManagementIp(vp.dpid);
        return ip;' \
    '        return ip;' \
    '        noteSwitchHasManagementIp(vp.dpid);'

# --- M9: the guard is hoisted above the mode branch -- the "tidier" fix ------------------------
# The only mutation here that looks like an improvement. Nothing crashes and nothing is
# undefined; the address check simply moves up so it covers both deployment modes. It is wrong:
# the MININET power figure is syntheticPowerMilliwattsFor(dpid), a function of the dpid alone --
# the header's own comment says this path must not call ip.front() precisely because it does not
# need one. A switch with no address has a perfectly real answer here and would stop getting it.
#
# If M9 survives, this suite pins "does not crash" rather than "reports what it can", and the
# next author to tidy the function will delete a real reading and see nothing go red.
mutate_must_die \
    "M9 over-guards-the-mininet-power-path" \
    "NoIpSwitchTest.MininetPowerStillReportsARealFigureForAnAddresslessSwitch" \
    "$SRC" \
    '        if (m_mode == utils::DeploymentMode::MININET)
        {
            power_mW = syntheticPowerMilliwattsFor(dpid);
        }' \
    '        if (!managementIpForReport(props))
        {
            result.push_back(entryFor(props, kHealthMetricUnavailable));
            continue;
        }
        if (m_mode == utils::DeploymentMode::MININET)
        {
            power_mW = syntheticPowerMilliwattsFor(dpid);
        }' \
    '            power_mW = syntheticPowerMilliwattsFor(dpid);'

# --- C1: control, comment text only ------------------------------------------------------------
# If this goes red, the harness is measuring "did anything change" rather than "did behaviour
# change", and every "caught" line above is meaningless.
mutate_must_live \
    "C1 control-comment-only" \
    "$SRC" \
    '// FINDINGS #85. See the four declarations in the header for why these exist and what they refuse' \
    '// CONTROL EDIT: comment text only, no behaviour change. See the header for the reasoning'

# --- C2: control, the empty check rewritten --------------------------------------------------
# Same predicate, ternary instead of an early return, `ip[0]` instead of `front()` -- which is the
# same element by the same rules, still guarded. A suite that reds here is pinning the spelling.
mutate_must_live \
    "C2 control-empty-check-rewritten" \
    "$SRC" \
    '    if (vp.ip.empty())
    {
        return std::nullopt;
    }
    return utils::ipToString(vp.ip.front());' \
    '    return vp.ip.empty() ? std::optional<std::string>{}
                         : std::optional<std::string>{utils::ipToString(vp.ip[0])};'

# --- C3: control, the key built a different way ------------------------------------------------
# Byte-identical output, different construction. The tests assert the prefix and the round trip,
# not the concatenation order.
mutate_must_live \
    "C3 control-key-built-differently" \
    "$SRC" \
    '    return "dpid:" + std::to_string(dpid);' \
    '    std::string key("dpid:");
    key += std::to_string(dpid);
    return key;'

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
if [[ "$INVALID" -gt 0 ]]; then
    printf '%d could not be applied or built -- neither caught nor survived; a human must look\n' \
        "$INVALID"
fi

[[ "$SURVIVORS" -eq 0 && "$INVALID" -eq 0 && "$ok" == 1 ]]
