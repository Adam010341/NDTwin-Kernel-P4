#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #88 / W14: the `ip[0]` sites in the intent and flow subsystems --
# `operator[]` on a std::vector that starts empty.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 SIX SITES, NOT THE SEVEN THIS GATE SHIPPED WITH. On 2026-09-11 the fifth site,
# LLMAgent::getCurrentTopology, was deleted as dead code -- its only caller has been commented out
# since d6f7c014 (2025-12-15) -- and mutations M3, M10 and C3, which were the three that mutated
# LLMAgent.cpp, were removed with it. The surviving mutations keep their original labels so that
# "M4 caught" still means the same edit it meant in the 2026-09-06 and 2026-09-10 runs; the totals
# moved from `16 mutations` to `13 mutations`. See
# doc/audit/2026-09-06_fix-index-zero-guards/FIX-INDEX-ZERO-GUARDS.md section 7.
#
# Structure, mechanics and wording are lifted from mutate_first_address_of.sh, which gates the
# other sixteen sites of the same finding. Copied rather than shared for the reason that gate
# gives: a common harness is a second place for the answer to be wrong, and check_gate_anchors.py
# reads each gate's own anchors.
#
# 🔴 ONE BUILD DIRECTORY, NOT TWO, AND THAT IS A DIFFERENCE FROM ITS PARENT GATE.
#
# mutate_first_address_of.sh needs an asan round because its M1-M3 mutants restore undefined
# behaviour inside ordinary in-process tests: on the plain build the fault kills the binary with no
# verdict for anything, which is not a red line. Its own §4.2 records M2 being scored SURVIVED for
# exactly that.
#
# The suite this gate drives answers that with containment instead of with a sanitizer. Each of
# the six sites has a death test -- the child performs the operation and exits 0, so restoring
# the subscript makes the CHILD die and the parent prints
#
#     [  FAILED  ] AddresslessNodeTest.<name>
#
# a named, ordinary red line on the ordinary build. That is strictly better evidence than "the
# sanitizer said something and the run exited non-zero", and it costs no second build tree.
#
#   GROUP 1  M1, M2, M4-M7, one per site: the guard is removed and trunk's `ip[0]` put back, byte
#            for byte. Run under a death-test-only filter (see ROUND_FILTER below).
#   GROUP 2  M8, M9, M11-M13: the guard stays and the OUTPUT lies -- a fabricated 0.0.0.0, a node
#            dropped from a listing whose question is "which nodes are there", a refusal that does
#            not say which host it is about, and two over-guards that refuse everything. None of
#            these crash, and no sanitizer would ever see them. They are the point of this gate: a
#            guard that stops the fault and loses the disclosure has moved the defect, not fixed it.
#   C1-C2    controls: behaviour-preserving edits that must stay GREEN. Without them "N/N caught"
#            would also be produced by a harness that reports red for any edit at all.
#
# 🔴 WHY GROUP 1 RUNS A NARROWER FILTER
# Under M4 ("the source-end subscript is back"), the death test is contained, but the in-process
# test APathQueryToAnAddresslessHostIsRefusedAndSaysWhich would fault IN the test process. gtest
# writes to a redirected stdout, which is block-buffered, so a crash can discard the red line that
# was already printed -- and the scorer would then read a run with no verdict and score the
# mutation SURVIVED, a lie about the test rather than about the code. Restricting group 1 to the
# death tests means nothing in the parent process ever touches an address-less node. `stdbuf -oL`
# is belt to that braces.
#
# 🔴 Mutates only .cpp files. include/utils/Utils.hpp holds firstAddressOf/firstAddressRaw and is
# included by ~70 translation units, so mutating it would rebuild the whole tree once per mutant.
# The helpers' own behaviour is pinned by M8, which mutates the CALL SITE to do what a broken
# helper would do. M10 was the second such mutant and went with the 2026-09-11 deletion.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. Baseline is the WORKING TREE, not HEAD, so this
# runs against an uncommitted fix. These files are in a worktree other sessions write to.
#
# Assumptions (stated because they are the script's failure modes):
#   * cwd is the repo root, or this script is run by path from anywhere -- it cds to its own ../..
#   * ${BUILD_DIR:-build} is an already-configured ninja dir
#   * the suite is linked into the test_routing_strategy binary, per tests/CMakeLists.txt
#   * builds go through tools/build_guard/guarded_build.sh unless NO_GUARD=1 -- this laptop's
#     systemd-oomd kills the user's own application when an unguarded build takes the memory.
#
# Usage:
#   bash tests/shell/mutate_index_zero_guards.sh
#   BUILD_DIR=build bash tests/shell/mutate_index_zero_guards.sh
#
# Exit codes:
#   0  every mutation was caught and both controls stayed green
#   1  a mutation survived, or one could not be applied/built
#   2  the baseline is not green -- the compile or the fix is the problem, not a mutation
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC_IT=src/ndt_core/intent_translator/IntentTranslator.cpp
SRC_FLUC=src/ndt_core/collection/FlowLinkUsageCollector.cpp
# src/ndt_core/intent_translator/LLMAgent.cpp was the third file here, for M3/M10/C3. It is not
# snapshotted any more because nothing mutates it: see the note at the top of this file.
FILES=("$SRC_IT" "$SRC_FLUC")

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
FILTER="${FILTER:-AddresslessNodeTest.*}"
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

# Every death test in the suite ends in DoesNotKillTheProcess. Group 1 runs only these.
DEATH_FILTER="AddresslessNodeTest.*DoesNotKillTheProcess"

CUR_DIR="$BUILD_DIR"
ROUND_FILTER="$FILTER"

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
# one the test caught. Checked on a SINGLE line, because assert_unique counts with `grep -c -F`,
# which is LINE oriented: a two-line anchor is two patterns and would be reported as two matches.
# mutate_first_address_of.sh §M7 records that trap, and records that check_gate_anchors.py says
# `ok` for anchors this function rejects -- the two tools ask different questions and this one is
# the stricter.
assert_unique() {   # $1 = file, $2 = single-line anchor
    local n
    n=$(grep -c -F -- "$2" "$1")
    if [[ "$n" -ne 1 ]]; then
        printf '  INVALID  anchor matches %s times in %s (want 1): %s\n' "$n" "$1" "$2"
        return 1
    fi
    return 0
}

# Every build goes through the guard: JOBS=1 because HttpSession.cpp and LLMAgent.cpp take ~1.6 GB
# each and two at once exceed the guard's MemoryHigh, and because an unguarded build on this
# laptop is what got the user's application killed by systemd-oomd on 2026-09-02.
build() {
    if [[ "${NO_GUARD:-0}" == "1" || ! -x "$GUARD" ]]; then
        cmake --build "$CUR_DIR" --target "$TARGET" >"$BK/build.log" 2>&1
    else
        LOCK_WAIT="${LOCK_WAIT:-10800}" JOBS=1 "$GUARD" \
            cmake --build "$CUR_DIR" --target "$TARGET" -j1 >"$BK/build.log" 2>&1
    fi
}

# rc captured directly, never through a pipe: `cmd | tail` reports tail's status. stdbuf -oL so a
# verdict line already printed survives a process that dies later in the same run.
run_suite() {
    stdbuf -oL -eL "$CUR_DIR/bin/$TARGET" --gtest_filter="$ROUND_FILTER" >"$BK/run.log" 2>&1
}

baseline_must_be_green() {
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
        echo "  REFUSE: baseline is not green (rc=$rc). Failing tests:"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'
        exit 2
    fi
    if ! grep -qE '^\[  PASSED  \] [1-9]' "$BK/run.log"; then
        echo "  REFUSE: the filter '$ROUND_FILTER' ran no tests. A gate over zero tests proves nothing."
        tail -20 "$BK/run.log" | sed 's/^/    /'
        exit 2
    fi
    # A death test that never forks is a test that cannot go red the way this gate needs. Assert
    # the suite really has all six before trusting any "caught" below. Was seven until the
    # 2026-09-11 deletion of the getCurrentTopology site.
    local deaths
    deaths=$(stdbuf -oL "$CUR_DIR/bin/$TARGET" --gtest_list_tests --gtest_filter="$DEATH_FILTER" \
             2>/dev/null | grep -c 'DoesNotKillTheProcess')
    if [[ "$deaths" -ne 6 ]]; then
        echo "  REFUSE: expected 6 death tests matching $DEATH_FILTER, found $deaths."
        echo "          One site would then have no contained red line and this gate would not say so."
        exit 2
    fi
    printf '  ok       baseline green (%s), %s death tests present\n' \
        "$(grep -E '^\[  PASSED  \]' "$BK/run.log" | tail -1)" "$deaths"
    echo
}

# --- reporting ---------------------------------------------------------------------------------

# $1 = name, $2 = the test that MUST go red, $3 = file, $4 = anchor, $5 = repl,
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
        printf '  INVALID  %-48s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi

    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-48s (mutant does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi

    run_suite; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $must_fail" "$BK/run.log"; then
        printf '  caught   %-48s (%s went red)\n' "$name" "${must_fail#AddresslessNodeTest.}"
    elif [[ "$rc" -ne 0 ]] && ! grep -qF '[  FAILED  ]' "$BK/run.log"; then
        # No verdict line at all: the parent process died mid-run. Never a clean catch -- a
        # death test's whole job is to contain the fault, so this says the containment failed.
        printf '  SURVIVED %-48s (the RUN died with no verdict line -- containment failed;\n' "$name"
        printf '           %-48s  %s never reported)\n' "" "$must_fail"
        tail -6 "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    else
        printf '  SURVIVED %-48s (%s stayed green -- that test proves nothing)\n' "$name" "$must_fail"
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
        printf '  INVALID  %-48s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi

    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-48s (control does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi

    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ok       %-48s (control stayed green, as it must)\n' "$name"
    else
        printf '  SURVIVED %-48s (control went RED -- the harness reports red for any edit,\n' "$name"
        printf '           %-48s  so every "caught" above is worthless)\n' ""
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# ================================================================================================
# GROUP 1 -- the six sites, one mutant each: trunk's subscript put back.
# ================================================================================================

echo "=== GROUP 1: the defect restored, one site at a time (filter: $DEATH_FILTER) ==="
ROUND_FILTER="$FILTER"
baseline_must_be_green
ROUND_FILTER="$DEATH_FILTER"
echo "mutations:"

# --- M1: GET_NETWORK_TOPOLOGY, hosts[] ----------------------------------------------------------
# The reachable one. The loop filters on vertexType and nothing else, and the load-time gate that
# keeps `ip` non-empty covers SWITCH vertices only.
mutate_must_die \
    "M1 topology-reply-hosts-subscript-restored" \
    "AddresslessNodeTest.TheTopologyReplyOverAnAddresslessHostDoesNotKillTheProcess" \
    "$SRC_IT" \
    '                    topoJson["hosts"].push_back({
                        {"name", vprop.deviceName},
                        {"ip", ipJson},' \
    '                    topoJson["hosts"].push_back({
                        {"name", vprop.deviceName},
                        {"ip", utils::ipToString(vprop.ip[0])},' \
    '                    topoJson["hosts"].push_back({'

# --- M2: GET_ALL_HOSTS --------------------------------------------------------------------------
# The `const auto ipOpt` line goes with it: leaving it behind is an unused variable, and this tree
# builds with -Werror, so the mutant would be scored INVALID for a reason that has nothing to do
# with the test.
mutate_must_die \
    "M2 host-listing-subscript-restored" \
    "AddresslessNodeTest.TheHostListingOverAnAddresslessHostDoesNotKillTheProcess" \
    "$SRC_IT" \
    '                    const auto ipOpt = utils::firstAddressOf(vprop.ip);
                    hostsJson.push_back({
                        {"name", vprop.deviceName},
                        {"ip", ipOpt.has_value() ? json(*ipOpt) : json(nullptr)},' \
    '                    hostsJson.push_back({
                        {"name", vprop.deviceName},
                        {"ip", utils::ipToString(vprop.ip[0])},' \
    '                    hostsJson.push_back({'

# --- M3: REMOVED 2026-09-11 ---------------------------------------------------------------------
# M3 restored the subscript in LLMAgent::getCurrentTopology and required
# TheAgentPromptOverAnAddresslessHostDoesNotKillTheProcess to go red. The member had no caller and
# was deleted; there is no expression left to mutate. The label is retired rather than reused, so
# an "M3 caught" line in an older log still means the edit it meant then.

# --- M4: getPathBetweenHostsJson, SOURCE end only -----------------------------------------------
# The destination guard is left standing on purpose. The two subscripts are separate expressions
# and a fix to one would leave the other; this mutant is the evidence that the two death tests
# discriminate rather than both answering "something in this function crashed".
mutate_must_die \
    "M4 path-source-subscript-restored" \
    "AddresslessNodeTest.APathQueryFromAnAddresslessHostDoesNotKillTheProcess" \
    "$SRC_FLUC" \
    '    const auto srcIpOpt = utils::firstAddressRaw(graph[*srcHostOpt].ip);
    const auto dstIpOpt = utils::firstAddressRaw(graph[*dstHostOpt].ip);
    if (!srcIpOpt.has_value() || !dstIpOpt.has_value())
    {
        json errorJson;
        errorJson["error"] = "One or both hosts carry no IP address in the topology.";
        if (!srcIpOpt.has_value())
        {
            errorJson["hosts_without_address"].push_back(srcHostName);
        }
        if (!dstIpOpt.has_value())
        {
            errorJson["hosts_without_address"].push_back(dstHostName);
        }
        return errorJson;
    }
    uint32_t srcIp = *srcIpOpt;
    uint32_t dstIp = *dstIpOpt;' \
    '    const auto dstIpOpt = utils::firstAddressRaw(graph[*dstHostOpt].ip);
    if (!dstIpOpt.has_value())
    {
        json errorJson;
        errorJson["error"] = "One or both hosts carry no IP address in the topology.";
        errorJson["hosts_without_address"].push_back(dstHostName);
        return errorJson;
    }
    uint32_t srcIp = graph[*srcHostOpt].ip[0];
    uint32_t dstIp = *dstIpOpt;' \
    '    const auto srcIpOpt = utils::firstAddressRaw(graph[*srcHostOpt].ip);'

# --- M5: getPathBetweenHostsJson, DESTINATION end only ------------------------------------------
mutate_must_die \
    "M5 path-destination-subscript-restored" \
    "AddresslessNodeTest.APathQueryToAnAddresslessHostDoesNotKillTheProcess" \
    "$SRC_FLUC" \
    '    const auto srcIpOpt = utils::firstAddressRaw(graph[*srcHostOpt].ip);
    const auto dstIpOpt = utils::firstAddressRaw(graph[*dstHostOpt].ip);
    if (!srcIpOpt.has_value() || !dstIpOpt.has_value())
    {
        json errorJson;
        errorJson["error"] = "One or both hosts carry no IP address in the topology.";
        if (!srcIpOpt.has_value())
        {
            errorJson["hosts_without_address"].push_back(srcHostName);
        }
        if (!dstIpOpt.has_value())
        {
            errorJson["hosts_without_address"].push_back(dstHostName);
        }
        return errorJson;
    }
    uint32_t srcIp = *srcIpOpt;
    uint32_t dstIp = *dstIpOpt;' \
    '    const auto srcIpOpt = utils::firstAddressRaw(graph[*srcHostOpt].ip);
    if (!srcIpOpt.has_value())
    {
        json errorJson;
        errorJson["error"] = "One or both hosts carry no IP address in the topology.";
        errorJson["hosts_without_address"].push_back(srcHostName);
        return errorJson;
    }
    uint32_t srcIp = *srcIpOpt;
    uint32_t dstIp = graph[*dstHostOpt].ip[0];' \
    '    const auto dstIpOpt = utils::firstAddressRaw(graph[*dstHostOpt].ip);'

# --- M6: getSwitchIpByName ----------------------------------------------------------------------
# A SWITCH site: no production route to it was found, and it is fixed and pinned anyway, because
# the gate that closes it is one `if` in another subsystem that did not exist five weeks ago.
mutate_must_die \
    "M6 switch-ip-by-name-subscript-restored" \
    "AddresslessNodeTest.ResolvingAnAddresslessSwitchByNameDoesNotKillTheProcess" \
    "$SRC_IT" \
    '    auto ipOpt = utils::firstAddressOf(vertex.ip);
    if (!ipOpt.has_value())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Switch {} carries no IP address in the topology",
                           switchName);
        return std::nullopt;
    }
    return ipOpt;' \
    '    return utils::ipToString(vertex.ip[0]);' \
    '    auto ipOpt = utils::firstAddressOf(vertex.ip);'

# --- M7: GET_NETWORK_TOPOLOGY, switches[] -------------------------------------------------------
# The other SWITCH site. Separate from M1 because the two branches share one guard now, and the
# thing worth proving is that the shared guard covers both -- not that it covers one of them.
mutate_must_die \
    "M7 topology-reply-switches-subscript-restored" \
    "AddresslessNodeTest.TheTopologyReplyOverAnAddresslessSwitchDoesNotKillTheProcess" \
    "$SRC_IT" \
    '                    topoJson["switches"].push_back({
                        {"name", vprop.deviceName},
                        {"dpid", vprop.dpid},
                        {"ip", ipJson},' \
    '                    topoJson["switches"].push_back({
                        {"name", vprop.deviceName},
                        {"dpid", vprop.dpid},
                        {"ip", utils::ipToString(vprop.ip[0])},' \
    '                    topoJson["switches"].push_back({'

echo

# ================================================================================================
# GROUP 2 -- the guard stays and the answer lies. Full suite; nothing here crashes.
# ================================================================================================

echo "=== GROUP 2: guarded, defined, and wrong (filter: $FILTER) ==="
ROUND_FILTER="$FILTER"
echo "mutations:"

# --- M8: the fabricated address -----------------------------------------------------------------
# The failure mode FIX-CPU-REPORT-NO-IP.md §5 records twice: a plausible-looking substitute no
# caller can tell apart from a measurement. Nothing crashes and the reply is full.
mutate_must_die \
    "M8 fabricates-0.0.0.0-in-the-topology-reply" \
    "AddresslessNodeTest.TheTopologyReplyGivesTheAddresslessNodesNullAndNotAnAddress" \
    "$SRC_IT" \
    '                const json ipJson = ipOpt.has_value() ? json(*ipOpt) : json(nullptr);' \
    '                const json ipJson = ipOpt.has_value() ? json(*ipOpt) : json("0.0.0.0");'

# --- M9: the silent drop ------------------------------------------------------------------------
# The other tidy-looking wrong fix. GET_ALL_HOSTS answers "which hosts are there", so a host
# removed from the answer because of a missing field is a different question answered.
mutate_must_die \
    "M9 drops-the-addressless-host-from-the-listing" \
    "AddresslessNodeTest.TheHostListingKeepsTheAddresslessHostWithANullAddress" \
    "$SRC_IT" \
    '                    const auto ipOpt = utils::firstAddressOf(vprop.ip);
                    hostsJson.push_back({' \
    '                    const auto ipOpt = utils::firstAddressOf(vprop.ip);
                    if (!ipOpt.has_value()) { continue; }
                    hostsJson.push_back({' \
    '                    hostsJson.push_back({'

# --- M10: REMOVED 2026-09-11 --------------------------------------------------------------------
# M10 put "0.0.0.0" into the agent prompt in place of the prose substitute, and required
# ThePromptDescribesTheAddresslessHostWithoutGivingItAnAddress to go red. Deleted with the member.
# M8 keeps the same failure mode under test at the JSON sites.

# --- M11: the refusal that does not say which ---------------------------------------------------
# Indistinguishable, to the caller, from "these two hosts have no route between them".
mutate_must_die \
    "M11 path-refusal-does-not-name-the-host" \
    "AddresslessNodeTest.APathQueryFromAnAddresslessHostIsRefusedAndSaysWhich" \
    "$SRC_FLUC" \
    '        if (!srcIpOpt.has_value())
        {
            errorJson["hosts_without_address"].push_back(srcHostName);
        }
        if (!dstIpOpt.has_value())
        {
            errorJson["hosts_without_address"].push_back(dstHostName);
        }' \
    '        // the refusal deliberately does not say which host (mutation)' \
    '            errorJson["hosts_without_address"].push_back(srcHostName);'

# --- M12: the over-guard, switch lookup ---------------------------------------------------------
# "Return nullopt when in doubt" taken one step too far: the endpoint stops answering at all.
mutate_must_die \
    "M12 switch-lookup-answers-nullopt-for-everything" \
    "AddresslessNodeTest.ASwitchWithAnAddressStillResolves" \
    "$SRC_IT" \
    '    return ipOpt;' \
    '    return std::nullopt;'

# --- M13: the over-guard, path query ------------------------------------------------------------
# Every assertion about the refusal still passes on a function that refuses everything. This is
# what APathBetweenTwoAddressedHostsStillAnswers is for, and this mutant is its evidence.
mutate_must_die \
    "M13 every-path-query-refused" \
    "AddresslessNodeTest.APathBetweenTwoAddressedHostsStillAnswers" \
    "$SRC_FLUC" \
    '    if (!srcIpOpt.has_value() || !dstIpOpt.has_value())' \
    '    if (!srcIpOpt.has_value() || !dstIpOpt.has_value() || srcIpOpt.has_value())'

# --- C1-C2: controls. Behaviour-preserving; must stay GREEN. ------------------------------------

# C1 spells the helper out at the call site. Same answer by construction -- an empty list yields a
# disengaged optional either way. A comment-only edit was rejected here: it produces identical
# object code, so it would only prove the harness rebuilds, not that it can tell a behaviour
# change from a behaviour-preserving one.
mutate_must_live \
    "C1 helper-inlined-at-the-host-listing" \
    "$SRC_IT" \
    '                    const auto ipOpt = utils::firstAddressOf(vprop.ip);' \
    '                    const auto ipOpt = vprop.ip.empty()
                                       ? std::optional<std::string>{}
                                       : utils::firstAddressOf(vprop.ip);'

mutate_must_live \
    "C2 path-guard-written-the-other-way" \
    "$SRC_FLUC" \
    '    if (!srcIpOpt.has_value() || !dstIpOpt.has_value())' \
    '    if (!(srcIpOpt.has_value() && dstIpOpt.has_value()))'

# C3 REMOVED 2026-09-11: it rewrote the prompt substitute in two steps, in the function that was
# deleted. C1 and C2 still cover both remaining files, which is what the control is for.

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

printf '\n%s mutations, %s survived, %s invalid\n' "$MUTATIONS" "$SURVIVORS" "$INVALID"
if [[ "$SURVIVORS" -eq 0 && "$INVALID" -eq 0 ]]; then
    echo "PASS"
    exit 0
fi
echo "FAIL"
exit 1
