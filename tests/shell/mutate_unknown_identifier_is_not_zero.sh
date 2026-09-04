#!/usr/bin/env bash
#
# Mutation gate for OV-2 / OV-3 in tests/test_HttpSessionStatusCodes.cpp:
# an identifier this kernel does not recognise is answered as such, and not as a fault, and not
# as a zero.
#
# [Co-developed with claude code -- Adam]
#
# Measured on this machine, 2026-09-04 (scratch/overnight-2026-09-04/FINDINGS-CANDIDATES.md):
#   OV-2  POST /ndt/set_switches_power_state?ip=203.0.113.9&action=off -> 500
#         {"error":"Failed to change switch power state"}, while GET of the SAME address
#         answered 404 and action=sideways answered 400. One address, two endpoints, two
#         verdicts on one question.
#   OV-3  POST /ndt/get_num_of_flows_passing_a_switch {"dpid":424242} -> 200 {"num_of_flows":0},
#         and the traffic-load twin the same, while install_flow_entry answered 404 for that
#         very dpid. A switch that does not exist and a switch with no traffic were the same
#         answer.
#
# 🔴 BOTH DIRECTIONS. Three of the six mutations below are the defects put back; three are the
# over-reaching fixes that look like rigour and are caught only by the controls:
#   * M2 answers 404 whenever the power manager returns false -- which relabels four genuine
#     server failures (the relay refusing, the vertex gone, an unrecognised action, an
#     exception) as "no such switch";
#   * M5 inverts the dpid test, so the switches that DO exist are the ones refused;
#   * M6 turns the missing-dpid 400 into a 404, i.e. lets the new status code swallow a
#     different error that was already correct.
# A gate with only the first kind would sign off on an endpoint that refuses everything.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit
# including Ctrl-C, byte-identity asserted at the end, and the tree is rebuilt from the restored
# source so the next ctest does not run the last mutant. Baseline is the WORKING TREE, not HEAD,
# so this runs against an uncommitted fix.
#
# ⚠️ COST. Only src/ndt_core/http/HttpSession.cpp is mutated, and it is a ~1.6 GB translation
#    unit: every mutant recompiles it and relinks a 230 MB test binary. That is why there are six
#    mutations and two controls and not twelve of each, and why every build here goes through
#    tools/build_guard/guarded_build.sh with JOBS=1 -- an unguarded build on this laptop is what
#    got the user's own application killed by systemd-oomd on 2026-09-02 and again on 09-03.
#    DO NOT wrap this script in guarded_build.sh: it takes the lock itself, per build, and an
#    outer guard would deadlock against its own inner one.
#
#    Neither the DeviceConfigurationAndPowerManager header nor TopologyAndFlowMonitor.hpp is
#    mutated, for the same reason mutate_delete_group_entry.sh gives: a header mutation rebuilds
#    every translation unit that includes it, and the new knowsSwitchIp is reachable through the
#    .cpp anyway.
#
# Usage:
#   bash tests/shell/mutate_unknown_identifier_is_not_zero.sh
#   BUILD_DIR=build-debug bash tests/shell/mutate_unknown_identifier_is_not_zero.sh
#
# Exit codes:
#   0  every mutation caught by the test named for it, both controls green
#   1  at least one mutation survived, or a control went red
#   2  the baseline is not green, or an anchor moved -- neither is a mutation result
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC=src/ndt_core/http/HttpSession.cpp
FILES=("$SRC")

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
BIN="${BIN:-$BUILD_DIR/bin/$TARGET}"
FILTER="${FILTER:-LockEndpointTest.*:PowerStateEndpointTest.*:KnownSwitchEndpointTest.*}"
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1").$(echo "$1" | md5sum | cut -c1-6)"; }
for f in "${FILES[@]}"; do cp "$f" "$(snap "$f")"; done
restore() { local f; for f in "${FILES[@]}"; do cp "$(snap "$f")" "$f"; touch "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
INVALID=0

# --- mechanics ---------------------------------------------------------------------------------

# Exact-string replacement. \Q..\E makes the pattern literal, so anchors carry braces, quotes,
# parentheses and > without escaping; the replacement is interpolated once and used verbatim.
apply() {   # $1 = file, $2 = exact anchor, $3 = replacement
    ANCHOR="$2" REPL="$3" perl -0777 -i -pe 's/\Q$ENV{ANCHOR}\E/$ENV{REPL}/' "$1"
}

# An anchor that matches twice would mutate two places at once and the result would not say which
# one the test caught. 🔴 That is not hypothetical here: the two OV-3 handlers are copy-paste
# twins, so `if (!m_topologyAndFlowMonitor->getSwitchKind(dpid).has_value())` occurs in both. Every
# anchor below that touches them is multi-line and carries that handler's OWN log line, and it is
# that line whose uniqueness is asserted.
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

echo "OV-2/OV-3 mutation gate -- unknown is not a fault, and not a zero"
echo "  build dir : $BUILD_DIR"
echo "  target    : $TARGET   (tests/test_HttpSessionStatusCodes.cpp compiles into this binary)"
echo "  filter    : $FILTER"
printf '  baseline  : %s  sha256 %s\n' "$SRC" "$(sha256sum "$SRC" | cut -c1-16)"
echo
echo "baseline (unmutated) must build and be green:"
build; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline build failed (rc=$rc) -- the fix or the new tests do not compile."
    tail -40 "$BK/build.log" | sed 's/^/    /'
    exit 2
fi
if [[ ! -x "$BIN" ]]; then
    echo "  REFUSE: $BIN is missing after a successful build. Check BUILD_DIR ('$BUILD_DIR')."
    exit 2
fi
run_suite; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline is not green (rc=$rc). Failing tests:"
    grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'
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

echo "mutations:"

# --- M1: OV-2 put back -- an unknown address is a server fault again ---------------------------
mutate_must_die \
    "M1 unknown-ip-is-a-500-again" \
    "PowerStateEndpointTest.SetSwitchesPowerStateWithAnUnknownIpIsA404NotA500" \
    "$SRC" \
    '    if (!m_deviceConfigurationAndPowerManager->knowsSwitchIp(ip))' \
    '    if (false)'

# --- M2: 🔴 the over-reaching fix -- every downstream failure becomes "no such switch" ----------
# This is the mutation that makes the discrimination test worth having. It passes every OV-2 case
# except ARealPowerFailureIsStillA500, and it would quietly turn four real faults into 404s.
mutate_must_die \
    "M2 every power failure becomes a 404" \
    "PowerStateEndpointTest.ARealPowerFailureIsStillA500" \
    "$SRC" \
    '        res.result(http::status::internal_server_error);
        res.body() = R"({"error":"Failed to change switch power state"})";' \
    '        res.result(http::status::not_found);
        res.body() = R"({"error":"Failed to change switch power state"})";' \
    '        res.body() = R"({"error":"Failed to change switch power state"})";'

# --- M3: OV-3 put back, num_of_flows ------------------------------------------------------------
# The anchor carries this handler's own log line: the two handlers are copy-paste twins and the
# `if` line alone occurs in both.
mutate_must_die \
    "M3 unknown-dpid-is-a-zero-again (num_of_flows)" \
    "LockEndpointTest.NumOfFlowsForAnUnknownDpidIsA404NotAZero" \
    "$SRC" \
    '        if (!m_topologyAndFlowMonitor->getSwitchKind(dpid).has_value())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "' \
    '        if (false)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "' \
    '                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "'

# --- M4: OV-3 put back, traffic load ------------------------------------------------------------
# 🔴 The twins get a mutation each. One mutation covering both would be satisfied by a suite that
# only tests one of them, which is how a copy-paste defect survives a "100% caught" gate.
mutate_must_die \
    "M4 unknown-dpid-is-a-zero-again (traffic load)" \
    "LockEndpointTest.TotalInputTrafficLoadForAnUnknownDpidIsA404NotAZero" \
    "$SRC" \
    '        if (!m_topologyAndFlowMonitor->getSwitchKind(dpid).has_value())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_total_input_traffic_load_passing_a_switch: dpid {} is not a "' \
    '        if (false)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_total_input_traffic_load_passing_a_switch: dpid {} is not a "' \
    '                               "get_total_input_traffic_load_passing_a_switch: dpid {} is not a "'

# --- M5: 🔴 the other over-reach -- the switches that exist are the ones refused ----------------
mutate_must_die \
    "M5 the test is inverted (known dpids get 404)" \
    "KnownSwitchEndpointTest.AKnownButIdleSwitchStillAnswersZero" \
    "$SRC" \
    '        if (!m_topologyAndFlowMonitor->getSwitchKind(dpid).has_value())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "' \
    '        if (m_topologyAndFlowMonitor->getSwitchKind(dpid).has_value())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "' \
    '                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "'

# --- M6: 🔴 the new status code swallows an error that was already right ------------------------
# The missing-dpid 400 was fixed months ago and is not part of this change. A gate that did not
# hold it would let "everything is a 404 now" pass.
mutate_must_die \
    "M6 the missing-dpid 400 becomes a 404" \
    "LockEndpointTest.NumOfFlowsWithoutADpidIsABadRequestNotA200" \
    "$SRC" \
    '        // See handleGetTotalInputTrafficLoadPassingASwitch: same missing res.result().
        // [Co-developed with claude code -- Adam]
        SPDLOG_LOGGER_WARN(Logger::instance(), "dpid missing");
        res.result(http::status::bad_request);' \
    '        // See handleGetTotalInputTrafficLoadPassingASwitch: same missing res.result().
        // [Co-developed with claude code -- Adam]
        SPDLOG_LOGGER_WARN(Logger::instance(), "dpid missing");
        res.result(http::status::not_found);' \
    '        // See handleGetTotalInputTrafficLoadPassingASwitch: same missing res.result().'

echo
echo "controls (behaviour-preserving; these must stay GREEN):"

# --- C1: the same body, built the other way -----------------------------------------------------
mutate_must_live \
    "C1 json::object(...) written as json{...}" \
    "$SRC" \
    '        res.body() = json::object({{"error", "Unknown switch IP"}}).dump();' \
    '        res.body() = json{{"error", "Unknown switch IP"}}.dump();'

# --- C2: the same predicate, spelled differently -------------------------------------------------
mutate_must_live \
    "C2 has_value() written as != std::nullopt" \
    "$SRC" \
    '        if (!m_topologyAndFlowMonitor->getSwitchKind(dpid).has_value())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "' \
    '        if (m_topologyAndFlowMonitor->getSwitchKind(dpid) == std::nullopt)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "' \
    '                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "'

# --- restore ------------------------------------------------------------------------------------

echo
ok=1
for f in "${FILES[@]}"; do
    cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }
done
if [[ "$ok" == 1 ]]; then
    echo "baseline restored: $SRC byte-identical to the pre-run snapshot"
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
