#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #88 / W18: the EIGHTH `ip[0]` -- the attachment switch's address list
# in TopologyAndFlowMonitor::updateHosts, indexed to key the reverse edge.
#
# [Co-developed with claude code -- Adam]
#
# Structure and mechanics are lifted from mutate_index_zero_guards.sh (W14), which is itself lifted
# from mutate_first_address_of.sh (W2). Copied rather than shared for the reason those gates give: a
# common harness is a second place for the answer to be wrong, and check_gate_anchors.py reads each
# gate's own anchors.
#
# 🔴 ONE BUILD DIRECTORY. The suite this gate drives answers undefined behaviour with containment,
# not with a sanitizer: the one site has a death test whose child performs the poll and exits 0, so
# restoring the subscript makes the CHILD die and the parent prints
#
#     [  FAILED  ] AddresslessAttachmentSwitchTest.AnAddresslessAttachmentSwitchDoesNotKillTheProcess
#
# a named, ordinary red line on the ordinary build.
#
#   GROUP 1  M1, the site: the guard is removed and trunk's `ip[0]` put back, byte for byte. Run
#            under a death-test-only filter (see ROUND_FILTER below).
#   GROUP 2  M2-M6: the guard stays and something else is wrong. Two of them are the SAME guard
#            hoisted one and two steps too high -- this entry does three separate pieces of work and
#            only one of them is keyed by the missing address, so only that one may be lost. One
#            substitutes an address, one goes silent, one refuses for everybody. None crash, and no
#            sanitizer would ever see any of them.
#   C1-C3    controls: behaviour-preserving edits that must stay GREEN. Without them "N/N caught"
#            would also be produced by a harness that reports red for any edit at all. C3 is a
#            REWORDED warning, and it is the one that proves the log assertion pins the two
#            identifiers an operator needs rather than this gate author's prose.
#
# 🔴 WHY GROUP 1 RUNS A NARROWER FILTER
# Under M1 the death test is contained, but every in-process test in the suite calls pollHosts on a
# graph holding the address-less switch and would fault IN the test process. gtest writes to a
# redirected stdout, which is block-buffered, so a crash can discard a red line that was already
# printed -- and the scorer would then read a run with no verdict and score the mutation SURVIVED, a
# lie about the test rather than about the code. Restricting group 1 to the death test means nothing
# in the parent process ever touches an address-less switch. `stdbuf -oL` is belt to that braces.
#
# 🔴 Mutates one .cpp file and no header. include/utils/Utils.hpp holds firstAddressRaw and is
# included by ~70 translation units, so mutating it would rebuild the whole tree once per mutant.
# The helper's own behaviour is pinned by M2, which mutates the CALL SITE to do what a broken helper
# would do, and by C1, which spells the helper out inline and must stay green.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. Baseline is the WORKING TREE, not HEAD, so this runs
# against an uncommitted fix. These files are in a worktree other sessions write to.
#
# Assumptions (stated because they are the script's failure modes):
#   * cwd is the repo root, or this script is run by path from anywhere -- it cds to its own ../..
#   * ${BUILD_DIR:-build} is an already-configured ninja dir
#   * the suite is linked into the test_routing_strategy binary, per tests/CMakeLists.txt
#   * builds go through tools/build_guard/guarded_build.sh unless NO_GUARD=1 -- this laptop's
#     systemd-oomd kills the user's own application when an unguarded build takes the memory.
#
# Usage:
#   bash tests/shell/mutate_attachment_switch_index_zero.sh
#   BUILD_DIR=build bash tests/shell/mutate_attachment_switch_index_zero.sh
#
# Exit codes:
#   0  every mutation was caught and all three controls stayed green
#   1  a mutation survived, or one could not be applied/built
#   2  the baseline is not green -- the compile or the fix is the problem, not a mutation
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC_TAFM=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
FILES=("$SRC_TAFM")

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
FILTER="${FILTER:-AddresslessAttachmentSwitchTest.*}"
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

# The one death test in the suite ends in DoesNotKillTheProcess. Group 1 runs only this.
DEATH_FILTER="AddresslessAttachmentSwitchTest.*DoesNotKillTheProcess"

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
# mutate_first_address_of.sh §M7 records that trap, and records that check_gate_anchors.py says `ok`
# for anchors this function rejects -- the two tools ask different questions and this one is the
# stricter.
assert_unique() {   # $1 = file, $2 = single-line anchor
    local n
    n=$(grep -c -F -- "$2" "$1")
    if [[ "$n" -ne 1 ]]; then
        printf '  INVALID  anchor matches %s times in %s (want 1): %s\n' "$n" "$1" "$2"
        return 1
    fi
    return 0
}

# Every build goes through the guard, JOBS=1: an unguarded build on this laptop is what got the
# user's application killed by systemd-oomd on 2026-09-02, and one round rebuilds
# TopologyAndFlowMonitor.cpp plus a link, which parallelism would not help anyway.
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
    # A death test that never forks is a test that cannot go red the way this gate needs.
    local deaths
    deaths=$(stdbuf -oL "$CUR_DIR/bin/$TARGET" --gtest_list_tests --gtest_filter="$DEATH_FILTER" \
             2>/dev/null | grep -c 'DoesNotKillTheProcess')
    if [[ "$deaths" -ne 1 ]]; then
        echo "  REFUSE: expected 1 death test matching $DEATH_FILTER, found $deaths."
        echo "          The site would then have no contained red line and this gate would not say so."
        exit 2
    fi
    printf '  ok       baseline green (%s), %s death test present\n' \
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
    # A no-op "mutation" leaves the suite green and would be reported as SURVIVED, which would be a
    # lie about the test rather than about the code. Multi-line anchors are where this happens.
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
        printf '  caught   %-52s (%s went red)\n' "$name" "${must_fail#AddresslessAttachmentSwitchTest.}"
    elif [[ "$rc" -ne 0 ]] && ! grep -qF '[  FAILED  ]' "$BK/run.log"; then
        # No verdict line at all: the parent process died mid-run. Never a clean catch -- a death
        # test's whole job is to contain the fault, so this says the containment failed.
        printf '  SURVIVED %-52s (the RUN died with no verdict line -- containment failed;\n' "$name"
        printf '           %-52s  %s never reported)\n' "" "$must_fail"
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

# ================================================================================================
# GROUP 1 -- the site: trunk's subscript put back.
# ================================================================================================

echo "=== GROUP 1: the defect restored (filter: $DEATH_FILTER) ==="
ROUND_FILTER="$FILTER"
baseline_must_be_green
ROUND_FILTER="$DEATH_FILTER"
echo "mutations:"

# --- M1: the attachment switch's address list, indexed --------------------------------------------
# 🔴 RE-ANCHORED for the merged form (integrate-0910, 2026-09-10; TopologyAndFlowMonitor.cpp:2352-2368).
# fix/e29-update-hosts-race-evidence and fix/w18-eighth-index-zero changed the same line and Adam kept
# both (FIX-E29.md section 6), so the site is no longer trunk's one-liner: the address is copied out of
# the graph under a shared_lock, and W18's guard sits outside that scope. The old anchor was trunk's
# `const auto attachIpOpt = utils::firstAddressRaw(...)` on one unlocked line and matched 0 times here.
#
# The mutant therefore restores the SUBSCRIPT AND KEEPS THE LOCK -- it is E-29's own shape at 483a03dd,
# before W18 was merged onto it. Dropping the lock as well would put two defects in one mutant and this
# gate would no longer be able to say which of them the death test caught; W18's `ip[0]` is the only one
# this gate is for. The E-29 race has its own evidence and is not a mutation here.
mutate_must_die \
    "M1 attachment-switch-subscript-restored" \
    "AddresslessAttachmentSwitchTest.AnAddresslessAttachmentSwitchDoesNotKillTheProcess" \
    "$SRC_TAFM" \
    '                std::optional<uint32_t> attachIpOpt;
                {
                    std::shared_lock lock(*m_graphMutex);
                    attachIpOpt = utils::firstAddressRaw((*m_graph)[*vertexOpt2].ip);
                }
                if (!attachIpOpt.has_value())
                {
                    SPDLOG_LOGGER_WARN(Logger::instance(),
                                       "host {} attaches to switch dpid {}, which carries no IP "
                                       "address in this topology; the reverse edge is keyed by "
                                       "that address, so it cannot be looked up and is left as it "
                                       "was",
                                       macStr,
                                       *attachDpidOpt);
                    continue;
                }
                auto edgeRevOpt = findEdgeBySrcAndDstIp(*attachIpOpt, ip);' \
    '                uint32_t attachIp = 0;
                {
                    std::shared_lock lock(*m_graphMutex);
                    attachIp = (*m_graph)[*vertexOpt2].ip[0];
                }
                auto edgeRevOpt = findEdgeBySrcAndDstIp(attachIp, ip);' \
    '                auto edgeRevOpt = findEdgeBySrcAndDstIp(*attachIpOpt, ip);'

echo

# ================================================================================================
# GROUP 2 -- guarded, defined, and wrong. Full suite; nothing here crashes.
# ================================================================================================

echo "=== GROUP 2: guarded, defined, and wrong (filter: $FILTER) ==="
ROUND_FILTER="$FILTER"
echo "mutations:"

# --- M2: the substituted address ------------------------------------------------------------------
# The failure mode FIX-CPU-REPORT-NO-IP.md §5 records twice, with a twist specific to this site: the
# fabricated key resolves to nothing, so the caller is handed "Rev Edge ... not found in static
# network topology file" -- an instruction to go and edit a file that could never have carried an
# edge keyed by an address the switch does not have.
mutate_must_die \
    "M2 fabricates-an-address-for-the-attachment-switch" \
    "AddresslessAttachmentSwitchTest.TheWarningNamesTheHostAndTheSwitchAndNotTheTopologyFile" \
    "$SRC_TAFM" \
    '                if (!attachIpOpt.has_value())
                {
                    SPDLOG_LOGGER_WARN(Logger::instance(),
                                       "host {} attaches to switch dpid {}, which carries no IP "
                                       "address in this topology; the reverse edge is keyed by "
                                       "that address, so it cannot be looked up and is left as it "
                                       "was",
                                       macStr,
                                       *attachDpidOpt);
                    continue;
                }
                auto edgeRevOpt = findEdgeBySrcAndDstIp(*attachIpOpt, ip);' \
    '                auto edgeRevOpt = findEdgeBySrcAndDstIp(attachIpOpt.value_or(0), ip);' \
    '                auto edgeRevOpt = findEdgeBySrcAndDstIp(*attachIpOpt, ip);'

# --- M3: the silent skip --------------------------------------------------------------------------
# The guard is right and says nothing. This function returns void and writes only the graph, so an
# operator sees a host-side edge come up and its reverse stay down with nothing connecting the two.
mutate_must_die \
    "M3 the-guard-says-nothing" \
    "AddresslessAttachmentSwitchTest.TheWarningNamesTheHostAndTheSwitchAndNotTheTopologyFile" \
    "$SRC_TAFM" \
    '                    SPDLOG_LOGGER_WARN(Logger::instance(),
                                       "host {} attaches to switch dpid {}, which carries no IP "
                                       "address in this topology; the reverse edge is keyed by "
                                       "that address, so it cannot be looked up and is left as it "
                                       "was",
                                       macStr,
                                       *attachDpidOpt);
                    continue;' \
    '                    // [mutant] the guard is right and says nothing
                    continue;' \
    '                                       *attachDpidOpt);'

# --- M4: the guard hoisted one step too high ------------------------------------------------------
# "Skip the entry when its attachment switch has no address", placed before the host-side edge. The
# host-side edge is keyed by the HOST's address, which this entry has; losing it is a link reported
# down that is not down.
mutate_must_die \
    "M4 guard-hoisted-above-the-host-side-edge" \
    "AddresslessAttachmentSwitchTest.TheHostSideEdgeIsStillRaisedWhenTheAttachmentSwitchHasNoAddress" \
    "$SRC_TAFM" \
    '            auto edgeOpt = findEdgeByHostIp(ip);' \
    '            // [mutant] the whole entry abandoned, one step too high
            if (host.contains("port") && host["port"].contains("dpid"))
            {
                const auto mutantDpidOpt = utils::tryParseHexUint64(host["port"].value("dpid", ""));
                if (mutantDpidOpt.has_value())
                {
                    const auto mutantVertexOpt = findSwitchByDpid(*mutantDpidOpt);
                    if (mutantVertexOpt.has_value() && (*m_graph)[*mutantVertexOpt].ip.empty())
                    {
                        continue;
                    }
                }
            }
            auto edgeOpt = findEdgeByHostIp(ip);'

# --- M5: the guard hoisted two steps too high -----------------------------------------------------
# The same edit above the MAC-keyed vertex update. A host can never be marked down again by anything
# else (F-14), so a host skipped here stays down for the life of the process.
mutate_must_die \
    "M5 guard-hoisted-above-the-host-vertex-update" \
    "AddresslessAttachmentSwitchTest.TheHostOnAnAddresslessAttachmentSwitchIsStillMarkedUp" \
    "$SRC_TAFM" \
    '            auto vecIpStr = host["ipv4"];' \
    '            // [mutant] the whole entry abandoned, two steps too high
            if (host.contains("port") && host["port"].contains("dpid"))
            {
                const auto mutantDpidOpt = utils::tryParseHexUint64(host["port"].value("dpid", ""));
                if (mutantDpidOpt.has_value())
                {
                    const auto mutantVertexOpt = findSwitchByDpid(*mutantDpidOpt);
                    if (mutantVertexOpt.has_value() && (*m_graph)[*mutantVertexOpt].ip.empty())
                    {
                        continue;
                    }
                }
            }
            auto vecIpStr = host["ipv4"];'

# --- M6: the over-guard ---------------------------------------------------------------------------
# "Leave the reverse edge alone when in doubt" taken one step too far: the lookup never finds
# anything, for anybody, and every assertion about the address-less switch still passes.
mutate_must_die \
    "M6 no-reverse-edge-is-ever-found" \
    "AddresslessAttachmentSwitchTest.TheReverseEdgeOfAnAddressedAttachmentSwitchIsStillRaised" \
    "$SRC_TAFM" \
    '                auto edgeRevOpt = findEdgeBySrcAndDstIp(*attachIpOpt, ip);' \
    '                auto edgeRevOpt = std::optional<Graph::edge_descriptor>{};'

# --- C1-C3: controls. Behaviour-preserving; must stay GREEN. --------------------------------------

# C1 spells the helper out at the call site. Same answer by construction. A comment-only edit was
# rejected here for the reason W14's C1 gives: it produces identical object code, so it would only
# prove the harness rebuilds, not that it can tell a behaviour change from a behaviour-preserving
# one.
#
# 🔴 RE-ANCHORED for the merged form (see M1): the call is now an ASSIGNMENT to an optional declared
# outside the locked scope, indented 20, not a `const auto` declaration indented 16. Both controls edit
# only the line inside the scope, so the lock and W18's guard are left exactly as the merged fix has
# them -- a control that moved either would not be behaviour-preserving.
mutate_must_live \
    "C1 helper-spelled-out-at-the-call-site" \
    "$SRC_TAFM" \
    '                    attachIpOpt = utils::firstAddressRaw((*m_graph)[*vertexOpt2].ip);' \
    '                    attachIpOpt =
                        (*m_graph)[*vertexOpt2].ip.empty()
                            ? std::optional<uint32_t>{}
                            : std::optional<uint32_t>{(*m_graph)[*vertexOpt2].ip.front()};'

# C2 reads the vertex once into a named reference instead of twice through the property map.
mutate_must_live \
    "C2 attachment-properties-hoisted-to-a-reference" \
    "$SRC_TAFM" \
    '                    attachIpOpt = utils::firstAddressRaw((*m_graph)[*vertexOpt2].ip);' \
    '                    const auto& attachSwitchProps = (*m_graph)[*vertexOpt2];
                    attachIpOpt = utils::firstAddressRaw(attachSwitchProps.ip);'

# 🔴 C3 rewords the warning and keeps its two arguments. This is the control for
# TheWarningNamesTheHostAndTheSwitchAndNotTheTopologyFile: that test must pin the identifiers an
# operator needs -- which host, which switch -- and must NOT pin the sentence they are wrapped in.
# A gate whose only log assertion is an exact phrase fails the next person who improves the wording,
# and teaches them to delete the assertion.
mutate_must_live \
    "C3 warning-reworded-same-two-identifiers" \
    "$SRC_TAFM" \
    '                                       "host {} attaches to switch dpid {}, which carries no IP "
                                       "address in this topology; the reverse edge is keyed by "
                                       "that address, so it cannot be looked up and is left as it "
                                       "was",' \
    '                                       "no reverse edge lookup for host {}: its attachment "
                                       "switch (dpid {}) has no address to key one with",' \
    '                                       "host {} attaches to switch dpid {}, which carries no IP "'

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
