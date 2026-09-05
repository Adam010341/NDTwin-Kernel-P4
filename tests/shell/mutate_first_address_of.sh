#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #88: unguarded `ip.front()` on vectors that start empty.
#
# [Co-developed with claude code -- Adam]
#
# Structure, mechanics and wording are lifted from mutate_cpu_report_no_ip.sh, which gates the
# #85 suite in the same file. Copied rather than shared for the reason that gate gives: a common
# harness is a second place for the answer to be wrong, and check_gate_anchors.py reads each
# gate's own anchors.
#
# 🔴 THIS GATE RUNS TWO ROUNDS, AGAINST TWO BUILD DIRECTORIES, AND THE REASON IS NOT STYLE.
#
# The defect is undefined behaviour, and this project defines neither _GLIBCXX_ASSERTIONS nor
# _GLIBCXX_DEBUG -- the sanitizer is opt-in (-DSANITIZER=asan). `front()` on a default-constructed
# std::vector dereferences a null _M_start, so on the ordinary build the mutants that restore the
# defect do not produce a red line: they take the whole binary down with no verdict, or (with a
# different allocator state) read garbage and stay green. Neither outcome is evidence.
#
#   ROUND 1  ordinary build ($BUILD_DIR, default `build`)
#            M4, M5, M6, M7 -- the mutants that do NOT crash. Each one leaves the code perfectly
#            defined and makes the OUTPUT lie: an over-guard that empties the report, a
#            fabricated 0.0.0.0, a silent skip, a widened identifier comparison. These are
#            ordinary assertion reds and a sanitizer would never see them.
#            C1-C3 are controls: behaviour-preserving edits that must stay GREEN, without which
#            "N/N caught" would also be produced by a harness that reports red for any edit.
#
#   ROUND 2  asan build ($ASAN_BUILD_DIR, default `build-asan`)
#            M1, M2, M3 -- the mutants that restore trunk's expression byte for byte. "Caught"
#            here means the sanitizer named the fault AND the run exited non-zero. A plain red
#            line is NOT required and must not be, because the process dies before gtest can
#            print one; conversely a green run under asan is a real survivor.
#            Round 2 is skipped, loudly, if $ASAN_BUILD_DIR does not exist -- a skipped round is
#            reported as SKIPPED and exits 1, never as a pass.
#
# WHY M4/M5/M6 ARE THE POINT OF THIS GATE
# All three make the code "not crash", which is what a naive reading of #88 asks for, and all
# three make the report say something untrue: that there were fewer congested links than there
# are, that a link has an address it does not have, or that nothing was dropped. A guard that
# stops the crash and loses the disclosure has moved the defect, not fixed it.
#
# 🔴 Mutates only .cpp files. include/utils/Utils.hpp is where firstAddressOf lives and is
# included by ~70 translation units, so mutating it would rebuild the whole tree once per mutant
# -- the same reason mutate_delete_group_entry.sh gives for keeping GraphTypes.hpp out of its
# table. The helper's own behaviour is pinned by M5, which mutates the CALL SITE to do what a
# broken helper would do.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. Baseline is the WORKING TREE, not HEAD, so this
# runs against an uncommitted fix. These files are in a worktree other sessions write to.
#
# Assumptions (stated because they are the script's failure modes):
#   * cwd is the repo root, or this script is run by path from anywhere -- it cds to its own ../..
#   * ${BUILD_DIR:-build} and ${ASAN_BUILD_DIR:-build-asan} are already-configured ninja dirs
#   * the suite is linked into the test_routing_strategy binary, per tests/CMakeLists.txt
#   * builds go through tools/build_guard/guarded_build.sh unless NO_GUARD=1 -- this laptop's
#     systemd-oomd kills the user's own application when an unguarded build takes the memory.
#
# Usage:
#   bash tests/shell/mutate_first_address_of.sh
#   BUILD_DIR=build ASAN_BUILD_DIR=build-asan bash tests/shell/mutate_first_address_of.sh
#   ROUNDS=1 bash tests/shell/mutate_first_address_of.sh    # ordinary round only, says so
#
# Exit codes:
#   0  every mutation was caught, all three controls stayed green, and both rounds ran
#   1  a mutation survived, one could not be applied/built, or a round was skipped
#   2  a baseline is not green -- the compile or the fix is the problem, not a mutation
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC_TAFM=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
SRC_DCPM=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
FILES=("$SRC_TAFM" "$SRC_DCPM")

BUILD_DIR="${BUILD_DIR:-build}"
ASAN_BUILD_DIR="${ASAN_BUILD_DIR:-build-asan}"
ROUNDS="${ROUNDS:-2}"
TARGET="${TARGET:-test_routing_strategy}"
FILTER="${FILTER:-NoIpSwitchTest.*}"
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

# Which directory the current round builds and runs in. Set by each round.
CUR_DIR="$BUILD_DIR"

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1").$(echo "$1" | md5sum | cut -c1-6)"; }
for f in "${FILES[@]}"; do cp "$f" "$(snap "$f")"; done
restore() { local f; for f in "${FILES[@]}"; do cp "$(snap "$f")" "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
INVALID=0
SKIPPED=0

# --- mechanics ---------------------------------------------------------------------------------

# Exact-string replacement. \Q..\E makes the pattern literal, so anchors carry braces, %, < and >
# without escaping; the replacement is interpolated once and used verbatim.
apply() {   # $1 = file, $2 = exact anchor, $3 = replacement
    ANCHOR="$2" REPL="$3" perl -0777 -i -pe 's/\Q$ENV{ANCHOR}\E/$ENV{REPL}/' "$1"
}

# An anchor that matches twice would mutate two places at once and the result would not say which
# one the test caught. Checked on a SINGLE line, which is why every anchor below is one line or is
# introduced by a line unique on its own. Five of the D-group sites are byte-identical to each
# other, so those pass an explicit uniq line.
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
build() {
    if [[ "${NO_GUARD:-0}" == "1" || ! -x "$GUARD" ]]; then
        cmake --build "$CUR_DIR" --target "$TARGET" >"$BK/build.log" 2>&1
    else
        LOCK_WAIT="${LOCK_WAIT:-10800}" JOBS=1 "$GUARD" \
            cmake --build "$CUR_DIR" --target "$TARGET" -j1 >"$BK/build.log" 2>&1
    fi
}

# rc captured directly, never through a pipe: `cmd | tail` reports tail's status.
run_suite() {
    "$CUR_DIR/bin/$TARGET" --gtest_filter="$FILTER" >"$BK/run.log" 2>&1
}

# Did the sanitizer say anything? This is round 2's definition of a red line.
saw_sanitizer_report() {
    grep -qE 'AddressSanitizer|UndefinedBehaviorSanitizer|runtime error:|SEGV on unknown address' \
        "$BK/run.log"
}

baseline_must_be_green() {   # $1 = human name of the round
    echo "baseline (unmutated) must build and be green in $CUR_DIR:"
    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "  REFUSE: baseline build failed (rc=$rc) -- the fix or the new test does not compile."
        echo "          This is a compile problem, not a mutation result. Last 40 lines:"
        tail -40 "$BK/build.log" | sed 's/^/    /'
        exit 2
    fi
    if [[ ! -x "$CUR_DIR/bin/$TARGET" ]]; then
        echo "  REFUSE: $CUR_DIR/bin/$TARGET is missing or not executable after a successful build."
        exit 2
    fi
    run_suite; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "  REFUSE: baseline is not green (rc=$rc) in the $1 round. Failing tests:"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'
        saw_sanitizer_report && echo "    (and the sanitizer reported on the UNMUTATED build)"
        exit 2
    fi
    if saw_sanitizer_report; then
        echo "  REFUSE: the sanitizer reported against the UNMUTATED build. The fix is incomplete;"
        echo "          round 2 cannot tell a mutant's report from this one."
        exit 2
    fi
    if ! grep -qE '^\[  PASSED  \] [1-9]' "$BK/run.log"; then
        echo "  REFUSE: the filter '$FILTER' ran no tests. A gate over zero tests proves nothing."
        tail -20 "$BK/run.log" | sed 's/^/    /'
        exit 2
    fi
    printf '  ok       baseline green (%s)\n' "$(grep -E '^\[  PASSED  \]' "$BK/run.log" | tail -1)"
    echo
}

# --- reporting ---------------------------------------------------------------------------------

# ROUND 1 scorer. $1 = name, $2 = the test that MUST go red, $3 = file, $4 = anchor, $5 = repl,
# $6 = optional single line whose uniqueness is asserted instead of $4.
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
        # No verdict line at all: the process died mid-test. For a round-1 mutant that is NOT a
        # clean catch -- these mutants are supposed to be perfectly defined code that lies, so a
        # crash means the mutation did something other than what its comment claims.
        printf '  SURVIVED %-46s (process DIED with no verdict line -- a round-1 mutant must\n' "$name"
        printf '           %-46s  not crash; %s never reported)\n' "" "$must_fail"
        tail -6 "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    else
        printf '  SURVIVED %-46s (%s stayed green -- that test proves nothing)\n' "$name" "$must_fail"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             also red: /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# ROUND 2 scorer. Same machinery, different definition of red: the sanitizer must report and the
# run must exit non-zero. $2 names the test the fault is expected to land in, for the log only --
# gtest may never print a verdict for it, and requiring one is what would make this scorer wrong.
mutate_must_trip_sanitizer() {
    local name="$1" lands_in="$2" file="$3" anchor="$4" repl="$5" uniq="${6:-$4}"
    local rc

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
    if [[ "$rc" -ne 0 ]] && saw_sanitizer_report; then
        printf '  caught   %-46s (sanitizer reported; fault expected in %s)\n' "$name" "$lands_in"
        grep -m1 -E 'ERROR: AddressSanitizer|runtime error:' "$BK/run.log" | sed 's/^/             /'
    elif [[ "$rc" -ne 0 ]]; then
        printf '  SURVIVED %-46s (run failed but the sanitizer said NOTHING -- an ordinary red\n' "$name"
        printf '           %-46s  here is not evidence of the undefined behaviour)\n' ""
        tail -6 "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    else
        printf '  SURVIVED %-46s (asan build stayed GREEN with the defect restored)\n' "$name"
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

# ================================================================================================
# ROUND 1 -- the ordinary build. Mutants that do not crash, and lie.
# ================================================================================================

CUR_DIR="$BUILD_DIR"
echo "=== ROUND 1: ordinary build ($CUR_DIR) -- mutants that stay defined and lie ==="
baseline_must_be_green "ordinary"
echo "mutations:"

# --- M4: over-guard. Nothing crashes; the endpoint quietly stops answering. --------------------
# The tidiest-looking wrong fix: one address-less vertex anywhere empties the whole ranking.
mutate_must_die \
    "M4 over-guard-empties-the-whole-topk" \
    "NoIpSwitchTest.ALinkWithAddressesOnBothEndsStillRanks" \
    "$SRC_TAFM" \
    '        if (!ip1Opt || !ip2Opt)
        {
            ++links_skipped_no_address;
            continue;
        }' \
    '        if (!ip1Opt || !ip2Opt)
        {
            result["top_k_links"] = json::array();
            result["links_skipped_no_address"] = links_skipped_no_address;
            return result;
        }' \
    '            ++links_skipped_no_address;'

# --- M5: the fabricated address -----------------------------------------------------------------
# 0.0.0.0 instead of a skip. Nothing crashes, the ranking is full, and one of its rows names a
# link that does not exist. This is the failure mode FIX-CPU-REPORT-NO-IP.md §5 records twice.
mutate_must_die \
    "M5 substitutes-0.0.0.0-for-a-missing-address" \
    "NoIpSwitchTest.AnAddresslessHostDoesNotEndTheTopKReport" \
    "$SRC_TAFM" \
    '        const std::string& ip1_str = *ip1Opt;
        const std::string& ip2_str = *ip2Opt;' \
    '        const std::string ip1_str = ip1Opt ? *ip1Opt : std::string("0.0.0.0");
        const std::string ip2_str = ip2Opt ? *ip2Opt : std::string("0.0.0.0");' \
    '        const std::string& ip1_str = *ip1Opt;'

# --- M6: the silent skip ------------------------------------------------------------------------
# Drops the link and says nothing. Indistinguishable from "there were only this many links".
mutate_must_die \
    "M6 skips-the-link-without-reporting-it" \
    "NoIpSwitchTest.AnAddresslessHostDoesNotEndTheTopKReport" \
    "$SRC_TAFM" \
    '    result["links_skipped_no_address"] = links_skipped_no_address;' \
    '    // links_skipped_no_address deliberately not reported (mutation)'

# --- M7: the injection defence, widened ---------------------------------------------------------
# `==` relaxed to a substring match while adding the empty guard. deviceIdentifier flows into
# execArgv at the snmpget call site; equality is what keeps it to an address the topology holds.
mutate_must_die \
    "M7 identifier-comparison-widened-to-substring" \
    "NoIpSwitchTest.TheSingleSwitchCpuReportStillMatchesOnTheAddressItHas" \
    "$SRC_DCPM" \
    '        if (vp.vertexType == VertexType::SWITCH && !vp.ip.empty() &&
            utils::ipToString(vp.ip.front()) == deviceIdentifier)' \
    '        if (vp.vertexType == VertexType::SWITCH && !vp.ip.empty() &&
            utils::ipToString(vp.ip.front()).find(deviceIdentifier) != std::string::npos)'

# --- C1-C3: controls. Behaviour-preserving; must stay GREEN. ------------------------------------

# C1 spells the helper out at the call site. Same answer by construction -- an empty list yields a
# disengaged optional either way -- so it must stay green. A comment-only edit was rejected here:
# it produces identical object code, so it would only prove the harness rebuilds, not that it can
# tell a behaviour change from a behaviour-preserving one.
mutate_must_live \
    "C1 helper-inlined-at-the-call-site" \
    "$SRC_TAFM" \
    '        const auto ip1Opt = utils::firstAddressOf((*m_graph)[v1].ip);' \
    '        const auto ip1Opt = (*m_graph)[v1].ip.empty()
                                ? std::optional<std::string>{}
                                : utils::firstAddressOf((*m_graph)[v1].ip);'

mutate_must_live \
    "C2 topk-skip-condition-written-the-other-way" \
    "$SRC_TAFM" \
    '        if (!ip1Opt || !ip2Opt)' \
    '        if (!(ip1Opt.has_value() && ip2Opt.has_value()))'

mutate_must_live \
    "C3 cpu-report-guard-written-with-size" \
    "$SRC_DCPM" \
    '        if (vp.vertexType == VertexType::SWITCH && !vp.ip.empty() &&' \
    '        if (vp.vertexType == VertexType::SWITCH && vp.ip.size() != 0 &&'

echo

# ================================================================================================
# ROUND 2 -- the asan build. Mutants that restore the undefined behaviour itself.
# ================================================================================================

if [[ "$ROUNDS" != "2" ]]; then
    echo "=== ROUND 2: SKIPPED (ROUNDS=$ROUNDS) ==="
    echo "  🔴 The undefined behaviour itself was NOT exercised. Round 1 pins the disclosure only."
    SKIPPED=$((SKIPPED + 1))
elif [[ ! -d "$ASAN_BUILD_DIR" ]]; then
    echo "=== ROUND 2: SKIPPED -- $ASAN_BUILD_DIR does not exist ==="
    echo "  Configure it with:  cmake -S . -B $ASAN_BUILD_DIR -G Ninja -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=asan"
    echo "  🔴 A skipped round is not a pass. This gate exits 1."
    SKIPPED=$((SKIPPED + 1))
else
    CUR_DIR="$ASAN_BUILD_DIR"
    echo "=== ROUND 2: asan build ($CUR_DIR) -- the undefined behaviour itself ==="
    baseline_must_be_green "asan"
    echo "mutations:"

    # --- M1: group C put back, byte for byte from trunk -----------------------------------------
    # utils::ipToString(vector) returns a vector<string> BY VALUE. For a host with no address that
    # vector is empty, so .front() is taken on a temporary that was just built empty -- not even on
    # VertexProperties::ip. getTopKCongestedLinksJson walks boost::edges with no vertexType filter,
    # so a HOST endpoint reaches here, and the load-time gate covers SWITCH vertices only.
    mutate_must_trip_sanitizer \
        "M1 topk-dereferences-empty-address-vector" \
        "NoIpSwitchTest.AnAddresslessHostDoesNotEndTheTopKReport" \
        "$SRC_TAFM" \
        '        const auto ip1Opt = utils::firstAddressOf((*m_graph)[v1].ip);
        const auto ip2Opt = utils::firstAddressOf((*m_graph)[v2].ip);
        if (!ip1Opt || !ip2Opt)
        {
            ++links_skipped_no_address;
            continue;
        }
        const std::string& ip1_str = *ip1Opt;
        const std::string& ip2_str = *ip2Opt;' \
        '        std::string ip1_str = utils::ipToString((*m_graph)[v1].ip).front();
        std::string ip2_str = utils::ipToString((*m_graph)[v2].ip).front();' \
        '        const auto ip1Opt = utils::firstAddressOf((*m_graph)[v1].ip);'

    # --- M2: one group-D scan put back ----------------------------------------------------------
    # findEdgeByAgentIpAndPort dereferences srcIp BEFORE any filtering, so one malformed edge costs
    # the whole scan rather than that edge. Nothing on the load path checks an edge's srcIp/dstIp.
    mutate_must_trip_sanitizer \
        "M2 edge-scan-dereferences-empty-srcip" \
        "NoIpSwitchTest.AnEdgeWithNoSourceAddressDoesNotBreakTheWholeScan" \
        "$SRC_TAFM" \
        '        if (!props.srcIp.empty() and props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            return edge;
        }
    }
    return nullopt;
}

// [Co-developed with claude code -- Adam]
optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeToHostByAgentIpAndPort(' \
        '        if (props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            return edge;
        }
    }
    return nullopt;
}

// [Co-developed with claude code -- Adam]
optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeToHostByAgentIpAndPort(' \
        'TopologyAndFlowMonitor::findEdgeToHostByAgentIpAndPort('

    # --- M3: group A put back -------------------------------------------------------------------
    # An address-less SWITCH is reached before the switch that holds the address being searched
    # for. Listed here rather than in round 1 because it is undefined behaviour, not a lie: the
    # ordinary build either crashes with no verdict or reads garbage and stays green, and neither
    # of those is a red line.
    mutate_must_trip_sanitizer \
        "M3 findSwitchByIp-guard-removed" \
        "NoIpSwitchTest.AnAddresslessSwitchDoesNotMatchEveryIpLookup" \
        "$SRC_TAFM" \
        '    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        const auto& vprop = (*m_graph)[*vi];
        if (vprop.vertexType == VertexType::SWITCH && !vprop.ip.empty() &&
            vprop.ip.front() == ip)' \
        '    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        const auto& vprop = (*m_graph)[*vi];
        if (vprop.vertexType == VertexType::SWITCH && vprop.ip.front() == ip)' \
        'TopologyAndFlowMonitor::findSwitchByIp(uint32_t ip) const'
fi

# --- summary ------------------------------------------------------------------------------------

restore
echo
for f in "${FILES[@]}"; do
    if ! cmp -s "$(snap "$f")" "$f"; then
        echo "🔴 $f was NOT restored to its pre-run state. Check it before committing."
        exit 1
    fi
done
echo "all mutated files restored byte-identical to the working tree they started from."

printf '\n%s mutations, %s survived, %s invalid, %s rounds skipped\n' \
    "$MUTATIONS" "$SURVIVORS" "$INVALID" "$SKIPPED"

if [[ "$SURVIVORS" -eq 0 && "$INVALID" -eq 0 && "$SKIPPED" -eq 0 ]]; then
    echo "PASS"
    exit 0
fi
echo "FAIL -- a survivor, an inapplicable mutation, or a skipped round. None of these is a pass."
exit 1
