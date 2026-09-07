#!/usr/bin/env bash
#
# Mutation gate for tests/test_ExemptSwitchIsNotDialled.cpp
# (E-23 / E-25 / E-30, Adam's rulings of 2026-09-07: a switch admitted only by its `switch_kind`
# must not be dialled, and the mark that says so must be visible from outside the process).
#
# [Co-developed with claude code -- Adam]
#
# Structure, mechanics and wording are lifted from mutate_cpu_report_no_ip.sh, which gates the
# neighbouring suite over the same source file. Copied rather than shared for the reason that gate
# gives: a common harness is a second place for the answer to be wrong, and check_gate_anchors.py
# reads each gate's own anchors.
#
# WHAT IS BEING GATED, IN ONE SENTENCE PER GROUP
#
#   M1-M6   The six brand-branching sites, one mutation each: the short-circuit is deleted and the
#           exempted switch falls back into the branch written for Brocade hardware. These are the
#           defect itself, restored one site at a time -- six sites, six reds, because a fix
#           applied at five of them is a fix that still SSHes a Cisco every ten seconds.
#   M7, M8  The two keys are dropped from to_json, i.e. /ndt/get_graph_data goes back to the shape
#           round-2's lw17c measured: the mark exists, and nobody outside can see it.
#   M9, M13 The startup line: not printed at all, and printed when there is nothing to print.
#           Both directions, because "warn about everything" is how a warning stops being read.
#   M10-M12 THE WIDENINGS THAT MUST BE CAUGHT. Not controls -- these are mutations that make the
#           guard SAFER in the naive sense and wrong in fact: every switch treated as exempt, the
#           MININET synthetic figure suppressed, the marks published on hosts. Over-guarding is
#           the failure mode a "does not dial" fix invites, and if these survive then the suite is
#           pinning "dials nobody" rather than "dials everybody it has a branch for".
#   W1-W3   The controls: three behaviour-preserving rewrites that must stay GREEN. Without them a
#           harness that reports red for any edit at all -- a stale binary, a build that silently
#           failed, a filter that matches nothing -- would look like a perfect mutation score.
#
# 🔴 GraphTypes.hpp IS INCLUDED BY 43 TRANSLATION UNITS. M7, M8 and W1 each trigger a whole-tree
# rebuild, so this gate is slow by construction. Kept anyway: the alternative is to gate the wire
# format somewhere cheaper than the place it is actually decided, which is how a gate ends up
# flattering its own subject.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. Baseline is the WORKING TREE, not HEAD, so this
# runs against an uncommitted fix. These files are in a worktree other sessions write to.
#
# Assumptions (stated because they are the script's failure modes):
#   * cwd is the repo root, or this script is run by path from anywhere -- it cds to its own ../..
#   * ${BUILD_DIR:-build} is an already-configured build directory (ninja)
#   * the suite is linked into the test_routing_strategy binary, per tests/CMakeLists.txt
#   * two of the cases load setting/StaticNetworkTopologyP4_10Switches_4Hosts.json, so the binary
#     has to be run from somewhere that can see `setting/` -- the suite says so rather than
#     asserting vacuously, and this gate's baseline check would refuse on it
#   * builds go through tools/build_guard/guarded_build.sh unless NO_GUARD=1 -- this laptop's
#     systemd-oomd kills the user's own application when an unguarded build takes the memory.
#
# Usage:
#   bash tests/shell/mutate_exempt_switch_is_not_dialled.sh
#   BUILD_DIR=build-debug bash tests/shell/mutate_exempt_switch_is_not_dialled.sh
#
#   # ...or, when another session is competing for the build lock, the form guarded_build.sh's
#   # own USAGE documents -- ONE lock acquisition for the whole run instead of one per mutation,
#   # with every inner build still inside the guard's cgroup and behind its PATH shim:
#   JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh \
#       env NO_GUARD=1 bash tests/shell/mutate_exempt_switch_is_not_dialled.sh
#   # NO_GUARD=1 there does NOT mean "unguarded": it stops this script calling the guard a second
#   # time from inside it, which would block on the lock the outer guard is already holding. Never
#   # set it without an outer guard.
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
TFM=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
GT=include/common_types/GraphTypes.hpp
FILES=("$SRC" "$TFM" "$GT")

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
BIN="${BIN:-$BUILD_DIR/bin/$TARGET}"
FILTER="${FILTER:-ExemptSwitchTest.*}"
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
# introduced by a line unique on its own -- here, the "E-23, site N of 6" banners.
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
#
# NO_GUARD=1 has exactly two legitimate uses and neither of them is "the guard is in the way":
# a machine where the guard is not installed (say so in the log), and the wrapped invocation in
# the Usage block above, where an OUTER guard is already holding the lock and running this whole
# script inside its cgroup -- calling the guard again from here would block on that lock forever.
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
        printf '  INVALID  %-52s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi

    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-52s (mutant does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi

    run_suite; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $must_fail" "$BK/run.log"; then
        printf '  caught   %-52s (%s went red)\n' "$name" "$must_fail"
        grep -A6 -F "[ RUN      ] $must_fail" "$BK/run.log" | grep -E 'Failure|Which is|Expected|Actual|error:' \
            | head -6 | sed 's/^/             | /'
    elif [[ "$rc" -ne 0 ]] && ! grep -qF '[  FAILED  ]' "$BK/run.log"; then
        printf '  SURVIVED %-52s (process DIED with no verdict line; %s never reported)\n' \
            "$name" "$must_fail"
        tail -6 "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    else
        printf '  SURVIVED %-52s (%s stayed green -- that test proves nothing)\n' "$name" "$must_fail"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             also red: /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# A control. Same machinery, opposite expectation: a behaviour-preserving edit must stay green.
mutate_must_live() {
    local name="$1" file="$2" anchor="$3" repl="$4" uniq="${5:-$3}"
    local rc

    MUTATIONS=$((MUTATIONS + 1))

    if ! assert_unique "$file" "$uniq"; then
        INVALID=$((INVALID + 1)); restore; return
    fi

    apply "$file" "$anchor" "$repl"
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-52s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi

    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-52s (control does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi

    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ok       %-52s (control stayed green, as it must)\n' "$name"
    else
        printf '  SURVIVED %-52s (control went RED -- the harness reports red for any edit,\n' "$name"
        printf '           %-52s  so every "caught" above is worthless)\n' ""
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

echo "mutations:"

# --- M1: the memory report dials the exempted switch again -------------------------------------
# The defect, restored at site 1. The `else if` is removed, so the exempted switch falls through
# to the Brocade memory OID -- 1.3.6.1.4.1.1991.1.1.2.1.53.0, a Foundry/Brocade enterprise OID
# that a Cisco does not implement.
mutate_must_die \
    "M1 E-23 site 1: the memory report dials it again" \
    "ExemptSwitchTest.TheMemoryReportDoesNotSnmpTheExemptSwitch" \
    "$SRC" \
    '        if (m_mode != utils::DeploymentMode::MININET && exemptFromBrandPathsForReport(vp))
        {
            result_json[ip_str] = kHealthMetricUnavailable;
            continue;
        }
' \
    '        // MUTANT M1: the exemption is not consulted here any more.
' \
    '            result_json[ip_str] = kHealthMetricUnavailable;'

# --- M2: the power report SSHes the exempted switch again --------------------------------------
# The site Adam's ruling names. `getPowerReportViaSsh` opens an ssh session with a ten-second
# connect timeout to a machine that has no account for it, once per switch per round.
mutate_must_die \
    "M2 E-23 site 2: the power report SSHes it again" \
    "ExemptSwitchTest.TheTestbedPowerReportDoesNotSshTheExemptSwitch" \
    "$SRC" \
    '            // E-23, site 2 of 6, and the one the ruling names: the `else` below is the
            // "Brocade / Others (Currently via SSH)" branch, so an exempted switch was SSHed into
            // with `show power` every ten seconds. The sentinel, and the same entry shape the
            // address-less case above emits -- this body is keyed by dpid, so the entry is
            // well-formed and only the value is unavailable.
            //
            // Ahead of the "Getting power report" line on purpose: announcing a read that is not
            // going to happen is how a log stops being evidence.
            if (exemptFromBrandPathsForReport(props))
            {
                result.push_back({{"dpid", dpid}, {"power_consumed", kHealthMetricUnavailable}});
                continue;
            }
' \
    '            // MUTANT M2: the exemption is not consulted here any more.
' \
    '            // E-23, site 2 of 6, and the one the ruling names: the `else` below is the'

# --- M3: the CPU report dials the exempted switch again ----------------------------------------
mutate_must_die \
    "M3 E-23 site 3: the CPU report dials it again" \
    "ExemptSwitchTest.TheCpuReportDoesNotSnmpTheExemptSwitch" \
    "$SRC" \
    '        // E-23, site 3 of 6. See fetchMemoryReportInternal for the placement rule and for why
        // this is an early exit rather than one more branch of the chain below.
        if (m_mode != utils::DeploymentMode::MININET && exemptFromBrandPathsForReport(vp))
        {
            result[ip_str] = kHealthMetricUnavailable;
            continue;
        }
' \
    '        // MUTANT M3: the exemption is not consulted here any more.
' \
    '        // E-23, site 3 of 6. See fetchMemoryReportInternal for the placement rule and for why'

# --- M4: the temperature report goes back to the HPE sentence ----------------------------------
# The only one of the six where the fix changes what is SAID and not what is done: this site
# already returned before its snmpget. Removing it puts back "The temperature function only
# supports the HPE 5520.", which reads as "we have a path, just not for this model" about a
# machine this build has no path for at all.
mutate_must_die \
    "M4 E-23 site 4: temperature says only-HPE again" \
    "ExemptSwitchTest.TheTemperatureReportAnswersTheSentinelRatherThanTheHpeSentence" \
    "$SRC" \
    '        else if (m_mode != utils::DeploymentMode::MININET && exemptFromBrandPathsForReport(vp))
        {
            result[ip_str] = kHealthMetricUnavailable;
            continue;
        }
' \
    '        // MUTANT M4: the exemption is not consulted here any more.
' \
    '        else if (m_mode != utils::DeploymentMode::MININET && exemptFromBrandPathsForReport(vp))'

# --- M5: the single-switch power report dials again --------------------------------------------
mutate_must_die \
    "M5 E-23 site 5: single power dials it again" \
    "ExemptSwitchTest.TheSingleSwitchPowerReportSaysExemptRatherThanFailing" \
    "$SRC" \
    '        if (m_mode == utils::DeploymentMode::TESTBED && isExemptFromBrandPaths(props))
        {
            const std::string note = exemptionNoteFor(props);
            SPDLOG_LOGGER_INFO(Logger::instance(), "{}", note);
            return {{"dpid", props.dpid},
                    {"power_consumed", kHealthMetricUnavailable},
                    {"exempt", note}};
        }
' \
    '        // MUTANT M5: the exemption is not consulted here any more.
' \
    '        if (m_mode == utils::DeploymentMode::TESTBED && isExemptFromBrandPaths(props))'

# --- M6: the single-switch CPU report dials again ----------------------------------------------
mutate_must_die \
    "M6 E-23 site 6: single CPU dials it again" \
    "ExemptSwitchTest.TheSingleSwitchCpuReportSaysExemptRatherThanFailing" \
    "$SRC" \
    '    else if (isExemptFromBrandPaths(*targetSwitch))
    {
        const std::string note = exemptionNoteFor(*targetSwitch);
        SPDLOG_LOGGER_INFO(Logger::instance(), "{}", note);
        return {{"dpid", targetSwitch->dpid},
                {"cpu_usage", kHealthMetricUnavailable},
                {"exempt", note}};
    }
' \
    '    // MUTANT M6: the exemption is not consulted here any more.
' \
    '    else if (isExemptFromBrandPaths(*targetSwitch))'

# --- M7: get_graph_data stops publishing power_path --------------------------------------------
# This is round-2 lw17c's measurement, restored: the mark is written onto the vertex and no
# consumer can see it. Whole-tree rebuild.
mutate_must_die \
    "M7 E-25: get_graph_data drops power_path" \
    "ExemptSwitchTest.GetGraphDataCarriesBothMarksOnASwitchAndNeitherOnAHost" \
    "$GT" \
    '        j["power_path"] = v.powerPath;
' \
    '' \
    '        j["power_path"] = v.powerPath;'

# --- M8: ... and telemetry_path ----------------------------------------------------------------
# Separate from M7 on purpose. A test that only looked at power_path would score both as caught
# and would say nothing about the second key, which is the one that tells an exempted switch from
# an OVS bridge (both "none") once you have power_path in hand.
mutate_must_die \
    "M8 E-25: get_graph_data drops telemetry_path" \
    "ExemptSwitchTest.GetGraphDataCarriesBothMarksOnASwitchAndNeitherOnAHost" \
    "$GT" \
    '        j["telemetry_path"] = v.telemetryPath;
' \
    '' \
    '        j["telemetry_path"] = v.telemetryPath;'

# --- W1: control, the predicate rewritten (header; declared HERE, next to M7/M8) ---------------
# Ordered immediately after M7/M8 on purpose and not with the other controls at the end: every
# edit to GraphTypes.hpp rebuilds 43 translation units, and so does the build after its restore,
# so putting the three header mutations back to back costs four whole-tree builds instead of six.
# Same predicate, De Morgan'd and with the two operands swapped. A suite that reds here is pinning
# the spelling of the mark rather than the mark. Also the control for M7/M8: it proves those two
# reds are about the keys and not about "any edit to GraphTypes.hpp reddens this suite".
mutate_must_live \
    "W1 control: the exemption predicate rewritten" \
    "$GT" \
    '    return v.vertexType == VertexType::SWITCH && v.powerPath == kPathNone;' \
    '    const bool hasSomePath = v.powerPath != kPathNone;
    return !hasSomePath && v.vertexType == VertexType::SWITCH;'

# --- M9: the startup line is not printed -------------------------------------------------------
mutate_must_die \
    "M9 E-30: the startup WARN is never printed" \
    "ExemptSwitchTest.TheLoadedExemptSwitchIsMarkedAndAnnounced" \
    "$TFM" \
    '    warnAboutSwitchesWithNoBrandPathNoLock();' \
    '    // MUTANT M9: nothing announces the exemption at load.'

# --- M13: ... and the other direction ----------------------------------------------------------
# A line on every start is a line nobody reads. Both directions are gated because a warning that
# fires for a fleet this build can drive end to end trains the reader to skip it, and then M9 and
# M13 have the same practical effect.
mutate_must_die \
    "M13 E-30: the startup WARN fires with nothing to say" \
    "ExemptSwitchTest.AFleetWithNoExemptSwitchSaysNothingAtAll" \
    "$TFM" \
    '    if (exempt == 0)
    {
        return;
    }
' \
    '' \
    '    if (exempt == 0)'

# --- M10: the widening that matters most -------------------------------------------------------
# 🔴 EVERY SWITCH IS TREATED AS EXEMPT. Nothing crashes, nothing is undefined, no exempted switch
# is ever dialled again, and every "does not dial" assertion in the suite still passes. It is
# wrong because the twin then reports -1 for the ten HPE and Brocade switches it has perfectly
# good OIDs for. If this survives, the suite is pinning "dials nobody".
mutate_must_die \
    "M10 widening: every switch is treated as exempt" \
    "ExemptSwitchTest.TheTestbedPowerReportDoesNotSshTheExemptSwitch" \
    "$SRC" \
    '    if (!isExemptFromBrandPaths(vp))
    {
        noteSwitchHasBrandPath(vp.dpid);
        return false;
    }' \
    '    if (false)
    {
        noteSwitchHasBrandPath(vp.dpid);
        return false;
    }' \
    '    if (!isExemptFromBrandPaths(vp))'

# --- M11: the second widening, and the one that looks tidiest ----------------------------------
# The TESTBED test is dropped from the single-switch power report's guard, so an exempted switch
# in MININET stops getting its synthetic figure. The guard reads better without the mode test and
# the code is shorter; it silently loses a number that never depended on the machine at all --
# exactly the shape mutate_cpu_report_no_ip.sh's M9 pins for the address guard.
mutate_must_die \
    "M11 widening: MININET loses the synthetic figure" \
    "ExemptSwitchTest.MininetStillGivesTheExemptSwitchTheSameSyntheticFigureThroughBothPaths" \
    "$SRC" \
    '        if (m_mode == utils::DeploymentMode::TESTBED && isExemptFromBrandPaths(props))' \
    '        if (isExemptFromBrandPaths(props))'

# --- M12: the exemption line is not edge-triggered ----------------------------------------------
# Four reports, every ten seconds, for a brand that will never change. The shape that put 3596
# sudo errors into one run and buried everything else in it.
mutate_must_die \
    "M12 the exemption line is logged every round" \
    "ExemptSwitchTest.TheExemptionIsLoggedOncePerEpisodeAndNotOncePerRound" \
    "$SRC" \
    '    if (noteSwitchExemptFromBrandPaths(vp.dpid))' \
    '    if (noteSwitchExemptFromBrandPaths(vp.dpid), true)'

# --- W2: control, the exemption sentence reworded ----------------------------------------------
# The suite asserts that the note contains "power_path none" and names the brand, and asserts
# nothing about the rest of the sentence. Rewording a diagnostic must stay free -- this is the
# widening that proves it.
mutate_must_live \
    "W2 control: the exemption note is reworded" \
    "$SRC" \
    '           " over SNMP or SSH. It was admitted by its explicit \"switch_kind\"; the generic "
           "branch it would otherwise fall into is written for Brocade hardware and would not "
           "answer for it. Reporting the unavailable sentinel "' \
    '           " over SNMP or SSH. CONTROL EDIT: this half of the sentence is rewritten and "
           "nothing may go red for it. Reporting the unavailable sentinel "' \
    '           " over SNMP or SSH. It was admitted by its explicit \"switch_kind\"; the generic "'

# --- W3: control, the sentinel written as its literal value ------------------------------------
# kHealthMetricUnavailable is -1, and doc/2026-01-02_ndt_api.md §12/§13 have said so since they
# were written. The same value spelled the other way must not change a verdict.
mutate_must_live \
    "W3 control: the memory sentinel written as -1" \
    "$SRC" \
    '            result_json[ip_str] = kHealthMetricUnavailable;
            continue;' \
    '            result_json[ip_str] = -1;
            continue;' \
    '            result_json[ip_str] = kHealthMetricUnavailable;'

# --- restoration and verdict -------------------------------------------------------------------

restore
echo
ok=1
for f in "${FILES[@]}"; do
    cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }
done
if [[ "$ok" == 1 ]]; then
    echo "baseline restored: all ${#FILES[@]} files byte-identical to the pre-run snapshot"
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
        echo "  test binary sha $(sha256sum "$BIN" | cut -c1-16)"
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
