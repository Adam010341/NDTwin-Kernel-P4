#!/usr/bin/env bash
#
# Mutation gate for Q12 (Adam's ruling (a), 2026-09-03) with FINDINGS #80 and #81 -- `is_up`
# answered two questions with one bit, and the two answers now have their own names.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_IsUpSplit.cpp, the three InformSwitchEnteredTest cases in
# tests/test_HttpSessionRouting.cpp, and PollDoesNotResurrectTest's wire-shape case.
#
# WHAT THE DEFECT WAS
#   One boolean meant both "nobody commanded this off" and "the twin can reach it". Different
#   writers, different lifetimes, and they can legitimately disagree. Measured consequences:
#     - /ndt/get_switches_power_state derived ON/OFF from that boolean, so a switch the twin had
#       killed and a switch that had crashed answered differently for no reason a caller could
#       see -- and only until liveness caught up, at which point they answered the same;
#     - the contract suite's A-8 check read the same bit on both sides of its own comparison, so
#       `unexplained_down` was structurally empty on any real kernel;
#     - #80: `kPostPowerOffDistrustWindow` bounded distrust by TIME (15 s) over an interval whose
#       measured length is 8-13 s of stale cache. A timer cannot know whether anything looked.
#
# 🔴 TWO DIRECTIONS, AND THE SECOND IS WHY THIS GATE IS MORE THAN A SHAPE CHECK
#   1. PUTTING THE CONFLATION BACK must be caught     (M1-M8, M12, M13, M15)
#      -- the wire losing a field, the alias tracking the wrong one, admin_state derived from the
#         observation again, the endpoint back to one scalar, distrust back on a clock.
#   2. OVER-CORRECTING must ALSO be caught            (M9, M11, M14, M16)
#      -- "never believe liveness again" satisfies every assertion in direction 1 and is a bigger
#         outage than the defect: the 1 Hz worker is the only writer that brings a bmv2 switch
#         back. A gate without these would green-light `return false;` at the top of
#         acceptLivenessUp, and a twin that reports a live fabric dead.
#
# 🔴 THREE MUTATIONS MUST **NOT** BE CAUGHT (W1, W2, W3). A suite that reddens on these is
# pinning source text rather than behaviour:
#   W1  a comment                     -- the classic control
#   W2  a log line's wording          -- diagnostics are not behaviour; a test that read the
#                                        string would stop the next person improving it
#   W3  the admin_state ternary written the other way round -- identical semantics, different
#       shape, so the catches above are about what the JSON holds and not how it was built
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. Every file it can touch is snapshotted with `cp -p` first, an EXIT
# trap restores them however this exits including Ctrl-C, and the run ends by asserting byte
# identity against the snapshot AND that the test binary's sha is the one the baseline built.
# `cp -p` restores the ORIGINAL mtime -- older than the object built from the mutant -- so ninja
# would see nothing to do and the next mutation would be measured against a stale binary. A
# restored file is therefore also `touch`ed, but ONLY if it actually changed: touching
# GraphTypes.hpp on every iteration rebuilds every TU that includes it, which is most of them.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child. Nothing here
# starts Mininet, bmv2, OVS or a listening socket.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_is_up_split.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_is_up_split.sh
#   BUILD_DIR=build     configured build directory (ninja)
#   JOBS=2              build parallelism
#   TEST_TIMEOUT=300    seconds allowed per test-binary run
#
# Exit: 0 every mutation caught by the test it names, all three widenings survived, tree restored
#       1 at least one mutation survived, or a widening was caught
#       2 no verdict is possible: baseline red or not building, anchor drift, hang, failed restore
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
JOBS="${JOBS:-2}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='IsUpSplitTest.*:InformSwitchEnteredTest.*:PollDoesNotResurrectTest.TheEmittedVertexShapeCarriesAdminStateAndReachable'

GT=include/common_types/GraphTypes.hpp
PM=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
P4=src/ndt_core/power_management/P4PowerStrategy.cpp
HS=src/ndt_core/http/HttpSession.cpp
FILES=("$GT" "$PM" "$P4" "$HS")

MUTATIONS=0
SURVIVORS=0
WIDENINGS=0
WIDENINGS_CAUGHT=0

# --- 0. self-check ------------------------------------------------------------------------------
if ! bash -n "${BASH_SOURCE[0]}"; then
    echo "🔴 this script does not parse" >&2; exit 2
fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
command -v python3 >/dev/null || { echo "🔴 python3 is required" >&2; exit 2; }
[[ -f "$BUILD_DIR/CMakeCache.txt" ]] || {
    echo "🔴 '$BUILD_DIR' is not a configured build dir. Configure it first, or pass BUILD_DIR=." >&2
    exit 2
}

# --- 1. snapshot --------------------------------------------------------------------------------
BK=$(mktemp -d)
declare -A SNAP SHA
for f in "${FILES[@]}"; do
    s="$BK/$(echo "$f" | md5sum | cut -c1-12).snap"
    cp -p "$f" "$s"; SNAP["$f"]="$s"; SHA["$f"]=$(sha256sum "$f" | cut -d' ' -f1)
done

restore() {
    local f
    for f in "${FILES[@]}"; do
        cmp -s "${SNAP[$f]}" "$f" && continue
        cp -p "${SNAP[$f]}" "$f"
        touch "$f"          # cp -p brings the old mtime back and ninja believes it
    done
}
trap 'restore; rm -rf "$BK"' EXIT

# --- 2. anchors ---------------------------------------------------------------------------------
# Declared before anything is touched, every one exactly once. An anchor matching twice would
# mutate a site the mutation is not named for; one matching zero times means the source moved
# under the gate, and "could not be applied" must never be reported as "was caught".
count_exact() {
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME
add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

add_anchor "wire-admin"    "$GT" '                       {"admin_state", v.adminPoweredOff ? "off" : "on"},'
add_anchor "wire-reach"    "$GT" '                       {"reachable", v.isUp},'
add_anchor "wire-alias"    "$GT" '                       {"is_up", v.isUp},'
add_anchor "read-reach"    "$GT" '    v.isUp = j.contains("reachable") ? j.at("reachable").get<bool>() : j.at("is_up").get<bool>();'
add_anchor "read-admin"    "$GT" '    v.adminPoweredOff = j.value("admin_state", std::string("on")) == "off";'
add_anchor "endpoint"      "$PM" '        result[sip] = json{
            {"admin_state",
             m_topologyAndFlowMonitor->getVertexAdminPoweredOff(nodeOpt.value()) ? "off" : "on"},
            {"reachable", m_topologyAndFlowMonitor->getVertexIsUp(nodeOpt.value())}};'
add_anchor "worker-join"   "$PM" '                            if (!acceptP4LivenessUp(swName, graph[v].dpid, p4SwitchState))'
add_anchor "probe-age"     "$PM" '    return ageIt->get<double>();'
add_anchor "decline-warn"  "$PM" '                           "declining a liveness Up for {}: the twin powered it off and the "'
add_anchor "window"        "$P4" '    const std::lock_guard<std::mutex> guard(m_lastPowerOffMutex);
    return m_lastPowerOffAt.find(swName) != m_lastPowerOffAt.end();'
add_anchor "accept-none"   "$P4" '    if (it == m_lastPowerOffAt.end())
    {
        // Nothing has been commanded off, so nothing is being distrusted and every observation'
add_anchor "accept-untimed" "$P4" '    if (!observedAt.has_value())
    {
        return false;
    }'
add_anchor "accept-order"  "$P4" '    if (*observedAt <= it->second)'
add_anchor "inform-up"     "$HS" '    m_topologyAndFlowMonitor->setVertexUp(*switchVertexOpt);
    m_topologyAndFlowMonitor->setVertexEnable(*switchVertexOpt);'
add_anchor "inform-warn"   "$HS" '                           "inform_switch_entered: dpid {} completed a control-plane session "'
add_anchor "wire-comment"  "$GT" '                       // different writers (the power strategies vs liveness probing), different'

echo "=== anchor uniqueness (exact substring count must be 1) ==="
anchor_ok=1
for i in "${!ANCHOR_NAME[@]}"; do
    n=$(count_exact "${ANCHOR_FILE[$i]}" "${ANCHOR_TEXT[$i]}")
    printf '  %-6s %-16s %-56s x%s\n' \
        "$([[ "$n" == 1 ]] && echo ok || echo REFUSE)" "${ANCHOR_NAME[$i]}" "${ANCHOR_FILE[$i]}" "$n"
    [[ "$n" == 1 ]] || anchor_ok=0
done
[[ "$anchor_ok" == 1 ]] || { echo "🔴 anchors have drifted; this gate cannot render a verdict" >&2; exit 2; }

# --- 3. build + run helpers ---------------------------------------------------------------------
build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >/dev/null 2>&1; }

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN. rc comes from the binary itself and
# is never taken through a pipe, because a pipeline's status belongs to its last stage.
#
# 🔴 A TEST CAN GO RED WITHOUT PRINTING `[  FAILED  ]`. These cases construct json by key, and a
# mutation that removes a key can turn an assertion into an uncaught throw -- which kills the
# process with no FAILED line. Reading "no FAILED line" as "nothing went red" would score real
# damage as a survivor. DIED_IN is the last case gtest announced, empty when it announced none.
run_tests() {
    OUT=$(timeout "$TEST_TIMEOUT" "$BIN" --gtest_filter="$1" 2>&1); RC=$?
    FAILED=$(sed -n 's/^\[  FAILED  \] \([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' <<<"$OUT" \
             | sort -u | tr '\n' ' ')
    DIED_IN=""
    if   (( RC == 124 )); then STATUS=hang
    elif (( RC > 128 ));  then STATUS=crash
    elif (( RC != 0 ));   then STATUS=fail
    else                       STATUS=pass
    fi
    if [[ "$STATUS" != pass && "$STATUS" != hang && -z "$FAILED" ]]; then
        DIED_IN=$(sed -n 's/^\[ RUN      \] \(.*\)$/\1/p' <<<"$OUT" | tail -1)
    fi
}

is_red() {
    [[ " $FAILED " == *" $1 "* ]] && return 0
    [[ -n "$DIED_IN" && "$DIED_IN" == "$1" ]] && return 0
    return 1
}

# apply <file> <anchor> <new> -- python does the replace, so the anchor matches LITERALLY,
# newlines and all, and the count is re-asserted at the moment of writing. `sed -i` would read the
# anchor as a regex and would not see a multi-line one at all.
apply() {
    local file="$1" anchor="$2" new="$3"
    python3 - "$file" "$anchor" "$new" <<'PY'
import sys, pathlib
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path); s = p.read_text()
if s.count(old) != 1:
    sys.stderr.write("anchor count %d, expected 1\n" % s.count(old)); sys.exit(1)
p.write_text(s.replace(old, new, 1))
PY
}

# mutate <label> <file> <anchor> <new> <expect-red...>
# Every named test must be red. "Something went red" is not the check -- WHICH light went red is.
mutate() {
    local label="$1" file="$2" anchor="$3" new="$4"; shift 4
    local expected=("$@")
    MUTATIONS=$((MUTATIONS + 1))
    printf '\n=== M%d. %s ===\n' "$MUTATIONS" "$label"
    printf '  expect red: %s\n' "${expected[*]}"

    if ! apply "$file" "$anchor" "$new"; then
        echo "  🔴 SURVIVED (anchor could not be applied) -- this proves nothing about the tests"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! build; then
        echo "  🔴 SURVIVED (mutant does not compile) -- the suite never ran"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local missed=() got=() t filter=""
    for t in "${expected[@]}"; do filter+="$t:"; done
    run_tests "${filter%:}"
    for t in "${expected[@]}"; do
        if is_red "$t"; then got+=("$t"); else missed+=("$t"); fi
    done

    if [[ "$STATUS" == hang ]]; then
        echo "  🔴 HUNG (>${TEST_TIMEOUT}s) -- not a red, and not a catch"
        SURVIVORS=$((SURVIVORS + 1))
    elif [[ ${#missed[@]} -eq 0 ]]; then
        if [[ "$STATUS" == crash ]]; then
            printf '  ✅ caught  reason=signal %d, died in %s\n' "$((RC-128))" "$DIED_IN"
        elif [[ -n "$DIED_IN" ]]; then
            printf '  ✅ caught  reason=the process exited %d inside %s\n' "$RC" "$DIED_IN"
        else
            printf '  ✅ caught  red: %s\n' "${got[*]}"
        fi
    else
        printf '  🔴 SURVIVED -- these stayed green: %s\n' "${missed[*]}"
        [[ -n "$FAILED" ]] && printf '     (something else went red: %s -- the gate fires, but not\n     for the reason this mutation claims)\n' "$FAILED"
        [[ "$STATUS" != pass && -z "$FAILED" && -z "$DIED_IN" ]] && printf '     (the binary exited %d before announcing a single case -- the mutation broke the\n     test process itself, which is damage, not evidence)\n' "$RC"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# widen <label> <file> <anchor> <new> -- a change that must leave EVERY case green. These are what
# give the catches above their meaning.
widen() {
    local label="$1" file="$2" anchor="$3" new="$4"
    WIDENINGS=$((WIDENINGS + 1))
    printf '\n=== W%d. %s (MUST stay green) ===\n' "$WIDENINGS" "$label"

    if ! apply "$file" "$anchor" "$new"; then
        echo "  🔴 the widening's anchor could not be applied -- this control checked nothing"
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1)); restore; return
    fi
    if ! build; then
        echo "  🔴 CAUGHT: the widening does not compile"
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1)); restore; return
    fi
    run_tests "$FILTER"
    if [[ "$STATUS" == pass ]]; then
        echo "  ✅ survived -- behaviour unchanged, so the catches above are about behaviour"
    else
        echo "  🔴 CAUGHT: tests went red on a behaviour-preserving change: $FAILED $DIED_IN"
        echo "     This gate cannot tell an edit from a behaviour change."
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1))
    fi
    restore
}

# --- 4. baseline --------------------------------------------------------------------------------
echo
echo "=== baseline (unmutated working tree) must build and be green ==="
if ! build; then
    echo "🔴 THE BASELINE DOES NOT COMPILE. Nothing below would mean anything." >&2
    cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" 2>&1 | tail -40 >&2
    exit 2
fi
[[ -x "$BIN" ]] || { echo "🔴 $BIN is missing after a successful build" >&2; exit 2; }
BIN_SHA_BEFORE=$(sha256sum "$BIN" | cut -c1-16)

run_tests "$FILTER"
case "$STATUS" in
  pass) echo "  ok       baseline green ($(grep -c '^\[       OK \]' <<<"$OUT") cases in the filter)" ;;
  hang) echo "🔴 BASELINE HUNG (>${TEST_TIMEOUT}s). Not a red; the gate cannot proceed." >&2; exit 2 ;;
  *)    echo "🔴 THE BASELINE IS ALREADY RED: $FAILED $DIED_IN" >&2
        echo "   Every 'expect red' below would be meaningless. Stopping." >&2; exit 2 ;;
esac
echo "  ok       $TARGET sha256 $BIN_SHA_BEFORE"

# ================================================================================================
# 5. direction 1 -- putting the conflation back
# ================================================================================================

# M1. THE DEFECT VERBATIM, in the one line that carries it: admin_state derived from the
#     OBSERVATION again. The wire keeps all three keys and every shape assertion still passes;
#     what comes back is the old lie -- a crashed switch reported as one somebody powered down.
mutate "admin_state is derived from isUp again (the conflation, verbatim)" \
    "$GT" \
    '                       {"admin_state", v.adminPoweredOff ? "off" : "on"},' \
    '                       {"admin_state", v.isUp ? "on" : "off"},' \
    IsUpSplitTest.ACommandedOffSwitchAndACrashedSwitchAreDistinguishableOnTheWire \
    IsUpSplitTest.ACommandedOffSwitchThatIsReachableAgainReportsBothHonestly \
    InformSwitchEnteredTest.TheResultingVertexReportsTheDisagreementRatherThanPickingOne

# M2. The observed half loses its name and only the deprecated alias is left. A consumer written
#     against the ruling reads a key that is not there.
mutate "the wire drops reachable and keeps only the alias" \
    "$GT" \
    '                       {"reachable", v.isUp},' \
    '' \
    IsUpSplitTest.AVertexCarriesAdminStateReachableAndTheIsUpAlias \
    IsUpSplitTest.TheIsUpAliasEqualsReachableInBothDirections \
    IsUpSplitTest.ACommandedOffSwitchAndACrashedSwitchAreDistinguishableOnTheWire

# M3. The alias is wired to the OTHER field. This is the single most likely wrong reconnection:
#     four consumers read `is_up`, and pointing it at the command instead of the observation
#     silently changes what every one of them is told, while every key is still present.
mutate "the is_up alias tracks admin_state instead of reachable" \
    "$GT" \
    '                       {"is_up", v.isUp},' \
    '                       {"is_up", !v.adminPoweredOff},' \
    IsUpSplitTest.TheIsUpAliasEqualsReachableInBothDirections \
    IsUpSplitTest.ACommandedOffSwitchThatIsReachableAgainReportsBothHonestly

# M4. The alias is dropped outright -- the "deprecated means removable" mistake. The
#     Energy-Saving-App parses it with j.at(), which throws.
mutate "the deprecated is_up alias is removed" \
    "$GT" \
    '                       {"is_up", v.isUp},' \
    '' \
    IsUpSplitTest.AVertexCarriesAdminStateReachableAndTheIsUpAlias \
    IsUpSplitTest.TheIsUpAliasEqualsReachableInBothDirections \
    PollDoesNotResurrectTest.TheEmittedVertexShapeCarriesAdminStateAndReachable

# M5. Reading back: the field is ignored and the alias wins. Harmless while they agree, which is
#     always -- until something emits them separately, which is the entire reason for the split.
mutate "from_json reads the alias and ignores reachable" \
    "$GT" \
    '    v.isUp = j.contains("reachable") ? j.at("reachable").get<bool>() : j.at("is_up").get<bool>();' \
    '    v.isUp = j.at("is_up").get<bool>();' \
    IsUpSplitTest.FromJsonReadsReachableAndAdminStateWhenBothArePresent

# M6. The back-compatibility promise withdrawn: `reachable` becomes required, so every payload
#     written before the ruling throws on load.
mutate "from_json requires reachable and rejects old payloads" \
    "$GT" \
    '    v.isUp = j.contains("reachable") ? j.at("reachable").get<bool>() : j.at("is_up").get<bool>();' \
    '    v.isUp = j.at("reachable").get<bool>();' \
    IsUpSplitTest.FromJsonAcceptsAnOldPayloadThatCarriesOnlyIsUp

# M7. The default points the wrong way, so silence reads as "somebody powered this down" and
#     every archived graph loads as a deliberately darkened fabric.
mutate "a missing admin_state defaults to off" \
    "$GT" \
    '    v.adminPoweredOff = j.value("admin_state", std::string("on")) == "off";' \
    '    v.adminPoweredOff = j.value("admin_state", std::string("off")) == "off";' \
    IsUpSplitTest.FromJsonAcceptsAnOldPayloadThatCarriesOnlyIsUp

# M8. THE ENDPOINT, back to one scalar derived from the observation. This is what
#     /ndt/get_switches_power_state did, and it is the shape the finding is named for.
mutate "get_switches_power_state answers one scalar off isUp again" \
    "$PM" \
    '        result[sip] = json{
            {"admin_state",
             m_topologyAndFlowMonitor->getVertexAdminPoweredOff(nodeOpt.value()) ? "off" : "on"},
            {"reachable", m_topologyAndFlowMonitor->getVertexIsUp(nodeOpt.value())}};' \
    '        result[sip] = m_topologyAndFlowMonitor->getVertexIsUp(nodeOpt.value()) ? "ON" : "OFF";' \
    IsUpSplitTest.PowerStateEndpointReportsAdminStateAndReachableForEverySwitch \
    IsUpSplitTest.PowerStateEndpointForOneIpCarriesBothFieldsToo

# M9. The endpoint keeps the new shape and fills it from the old source: two keys, one fact.
#     This is the mutation a reviewer would pass, because the JSON looks right.
mutate "the endpoint's admin_state is filled from the observation" \
    "$PM" \
    '            {"admin_state",
             m_topologyAndFlowMonitor->getVertexAdminPoweredOff(nodeOpt.value()) ? "off" : "on"},' \
    '            {"admin_state",
             m_topologyAndFlowMonitor->getVertexIsUp(nodeOpt.value()) ? "on" : "off"},' \
    IsUpSplitTest.PowerStateEndpointReportsAdminStateAndReachableForEverySwitch

# ================================================================================================
#    FINDINGS #80 -- distrust bounded by evidence
# ================================================================================================

# M10. THE #80 DEFECT PUT BACK: the window closes on a clock. Written with the literal rather than
#      the old constant, because the constant is gone -- which is the point.
mutate "the distrust window goes back to a fifteen-second timer" \
    "$P4" \
    '    const std::lock_guard<std::mutex> guard(m_lastPowerOffMutex);
    return m_lastPowerOffAt.find(swName) != m_lastPowerOffAt.end();' \
    '    const std::chrono::steady_clock::time_point at = now();
    const std::lock_guard<std::mutex> guard(m_lastPowerOffMutex);
    const auto it = m_lastPowerOffAt.find(swName);
    if (it == m_lastPowerOffAt.end())
    {
        return false;
    }
    return at - it->second < std::chrono::seconds(15);' \
    IsUpSplitTest.TheDistrustWindowDoesNotCloseOnTimeAlone

# M11. The comparison inverted: a probe from BEFORE the kill closes the window and one from after
#      does not. Both directions in one edit, and both are named.
mutate "the evidence comparison is inverted" \
    "$P4" \
    '    if (*observedAt <= it->second)' \
    '    if (*observedAt > it->second)' \
    IsUpSplitTest.AProbeTakenAfterTheKillClosesTheWindow \
    IsUpSplitTest.AProbeTakenBeforeTheKillIsNotEvidenceAndDoesNotCloseTheWindow \
    IsUpSplitTest.TheWorkerDeclinesAnUpWhoseProbePredatesTheKill \
    IsUpSplitTest.TheWorkerAcceptsAFreshUpAndItClosesTheWindow

# M12. An Up with no timestamp is treated as fresh. The optimistic branch, and the one a schema
#      change on the proxy side would silently hand us.
mutate "an untimed Up counts as evidence" \
    "$P4" \
    '    if (!observedAt.has_value())
    {
        return false;
    }' \
    '    if (!observedAt.has_value())
    {
        m_lastPowerOffAt.erase(it);
        return true;
    }' \
    IsUpSplitTest.AnUpWithNoProbeTimestampIsNotEvidence

# M13. The worker stops asking: the join is bypassed and every Up is written, which is trunk's
#      behaviour and the 8-13 s of `is_up=true` after every kill that #80 measured.
mutate "the 1 Hz worker writes every Up without dating it" \
    "$PM" \
    '                            if (!acceptP4LivenessUp(swName, graph[v].dpid, p4SwitchState))' \
    '                            if (false)' \
    IsUpSplitTest.TheWorkerDeclinesAnUpWhoseProbePredatesTheKill

# M14. The probe's age is discarded, so every reading is dated to the moment it was COLLECTED --
#      which is how a cache launders itself into current evidence. The join still runs.
mutate "the probe age is thrown away and every reading is dated now" \
    "$PM" \
    '    return ageIt->get<double>();' \
    '    return 0.0;' \
    IsUpSplitTest.TheProbeAgeIsReadFromThePayloadAndIsNulloptWhenItCannotBe \
    IsUpSplitTest.TheWorkerDeclinesAnUpWhoseProbePredatesTheKill

# ================================================================================================
#    direction 2 -- over-correcting. 🔴 These are why this gate is not just a shape check.
# ================================================================================================

# M15. THE OVER-CORRECTION: nothing is ever believed again. Every catch in direction 1 gets
#      GREENER, and the twin reports a live fabric dead -- the 1 Hz worker is the only writer
#      that brings a bmv2 switch back for anything discovery answers Unknown about.
mutate "no liveness Up is ever accepted again" \
    "$P4" \
    '    if (it == m_lastPowerOffAt.end())
    {
        // Nothing has been commanded off, so nothing is being distrusted and every observation' \
    '    if (false)
    {
        // Nothing has been commanded off, so nothing is being distrusted and every observation' \
    IsUpSplitTest.AnUncommandedSwitchAcceptsEveryLivenessUp \
    IsUpSplitTest.TheWorkerAcceptsEveryUpForASwitchItNeverStopped \
    IsUpSplitTest.AProbeTakenAfterTheKillClosesTheWindow

# M16. The narrower over-correction: the window never closes on evidence, only on a power-on. A
#      switch restarted out of band is then distrusted for the life of the process.
mutate "the window never closes on a probe, only on a power-on" \
    "$P4" \
    '    m_lastPowerOffAt.erase(it);
    return true;' \
    '    return true;' \
    IsUpSplitTest.AProbeTakenAfterTheKillClosesTheWindow \
    IsUpSplitTest.TheWorkerAcceptsAFreshUpAndItClosesTheWindow

# ================================================================================================
#    FINDINGS #81 -- the control-plane push
# ================================================================================================

# M17. The push clears the command. This is the second door #46 spent a whole branch closing: one
#      "switch entered" and discovery is free to mark a commanded-off switch up for ever after.
mutate "inform_switch_entered withdraws the commanded power-off" \
    "$HS" \
    '    m_topologyAndFlowMonitor->setVertexUp(*switchVertexOpt);
    m_topologyAndFlowMonitor->setVertexEnable(*switchVertexOpt);' \
    '    m_topologyAndFlowMonitor->clearVertexAdminPowerOff(*switchVertexOpt);
    m_topologyAndFlowMonitor->setVertexUp(*switchVertexOpt);
    m_topologyAndFlowMonitor->setVertexEnable(*switchVertexOpt);' \
    InformSwitchEnteredTest.ASwitchEnteredPushDoesNotClearAStandingCommandedPowerOff \
    InformSwitchEnteredTest.TheResultingVertexReportsTheDisagreementRatherThanPickingOne

# M18. The other direction, and the decision this fix actually took: the push declines to record
#      a completed session. A switch that is demonstrably answering is reported unreachable.
mutate "inform_switch_entered declines to record reachability" \
    "$HS" \
    '    m_topologyAndFlowMonitor->setVertexUp(*switchVertexOpt);
    m_topologyAndFlowMonitor->setVertexEnable(*switchVertexOpt);' \
    '    m_topologyAndFlowMonitor->setVertexEnable(*switchVertexOpt);' \
    InformSwitchEnteredTest.ASwitchEnteredPushMayStillLiftReachable \
    InformSwitchEnteredTest.TheResultingVertexReportsTheDisagreementRatherThanPickingOne

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the behaviour changed" -- and GraphTypes.hpp is the worst file in the
#     repository for that, because most of the tree includes it.
widen "a comment in the serialiser, nothing else" \
    "$GT" \
    '                       // different writers (the power strategies vs liveness probing), different' \
    '                       // separate writers (the power strategies vs liveness probing), different'

# W2. The declined-Up warning's wording. The log line is a diagnostic, not the behaviour: a suite
#     that reddens here is pinning a string, and the next person to improve the message would
#     have to change a test to do it.
widen "the declined-Up warning is reworded" \
    "$PM" \
    '                           "declining a liveness Up for {}: the twin powered it off and the "' \
    '                           "ignoring a liveness Up for {}: the twin powered it off and the "'

# W3. The admin_state ternary written the other way round -- identical semantics, different shape.
#     The control for tests that pin how the JSON was built rather than what it holds.
widen "the admin_state ternary is written as the negated test" \
    "$GT" \
    '                       {"admin_state", v.adminPoweredOff ? "off" : "on"},' \
    '                       {"admin_state", !v.adminPoweredOff ? "on" : "off"},'

# ================================================================================================
# 7. restore and verdict
# ================================================================================================
restore
REBUILD_OK=1
build || REBUILD_OK=0

printf '\n=== restore ===\n'
ok=1
for f in "${FILES[@]}"; do
    now=$(sha256sum "$f" | cut -d' ' -f1)
    if [[ "$now" != "${SHA[$f]}" ]]; then
        echo "  🔴 NOT RESTORED: $f  (${now:0:16} != ${SHA[$f]:0:16})  DO NOT COMMIT"; ok=0
    elif ! cmp -s "${SNAP[$f]}" "$f"; then
        echo "  🔴 NOT BYTE-IDENTICAL: $f  DO NOT COMMIT"; ok=0
    fi
done
[[ "$ok" == 1 ]] && echo "  all ${#FILES[@]} files byte-identical to the pre-run snapshot"
if [[ "$REBUILD_OK" == 1 ]]; then
    echo "  rebuilt from the restored tree"
    run_tests "$FILTER"
    if [[ "$STATUS" == pass ]]; then
        echo "  suite green again after restore"
    else
        echo "  🔴 SUITE RED AFTER RESTORE: $FAILED $DIED_IN"; ok=0
    fi
    BIN_SHA_AFTER=$(sha256sum "$BIN" | cut -c1-16)
    if [[ "$BIN_SHA_AFTER" == "$BIN_SHA_BEFORE" ]]; then
        echo "  test binary sha unchanged: $BIN_SHA_AFTER"
    else
        echo "  🔴 BINARY SHA MOVED: $BIN_SHA_BEFORE -> $BIN_SHA_AFTER"; ok=0
    fi
else
    echo "  🔴 THE RESTORED TREE DOES NOT BUILD -- the binary on disk is whatever the last"
    echo "     mutation left. Do not trust it."; ok=0
fi

printf '\n=== verdict ===\n'
printf '  %d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
printf '  %d widenings, %d wrongly caught\n' "$WIDENINGS" "$WIDENINGS_CAUGHT"
if [[ "$ok" != 1 ]]; then exit 2; fi
if (( SURVIVORS > 0 || WIDENINGS_CAUGHT > 0 )); then exit 1; fi
exit 0
