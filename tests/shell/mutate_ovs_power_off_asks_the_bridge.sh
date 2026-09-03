#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #82 -- OVS powerOff asks the machine whether the bridge is there,
# and records the commanded power-off on both answers.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_OvsPowerStrategy.cpp and the OVS cases in tests/test_PollDoesNotResurrect.cpp.
#
# WHAT THE DEFECT WAS
#   OVSPowerStrategy::powerOff opened with
#       if (!topoMonitor->getVertexIsUp(node)) { return OpResult::success(); }
#   -- the OVS twin of the early return FINDINGS #35 names on the P4 side, and the one that was
#   left in place when #35 was fixed there (FIX-POLL-RESURRECT.md (6).3), because `list-ports` on a
#   missing bridge exits 1 and an unguarded power-off would have refused with a 500.
#
#   It asked the graph. The graph reads false for a bridge that is present in at least four
#   states: freshly loaded topology (every vertex starts false), `list-br` refused or failed, a
#   liveness blip, and -- since FINDINGS #46 -- any switch already carrying a commanded power-off.
#   And the early return sits ABOVE setVertexPoweredOffByCommand, so on OVS the #46 fix held only
#   when isUp happened to be true at the moment the power-off arrived. A second `action=off`
#   returned 200 having recorded nothing at all.
#
# 🔴 TWO DIRECTIONS, AND THE SECOND ONE IS WHY THIS GATE IS NOT JUST #82's
#   1. RESTORING the defect must be caught             (M1, M2, M3, M4, M6, M7)
#      -- the early return itself; the measurement taken and then ignored; the command recorded
#         only on the teardown path; "could not ask" read as "not there"; the seam conflating
#         exit 2 with every other failure; power-on going back to a blind add-br.
#   2. RELAXING past the fix must ALSO be caught       (M5, M8, M9, M10)
#      -- a powerOff that ALWAYS takes the absent path deletes nothing ever, and satisfies every
#         assertion in direction 1: the command is still recorded, the graph still goes down, and
#         the fabric never stops. Same for a powerOn that never builds, a power-on that never
#         withdraws the command (a switch discovery can never report up again), and a teardown
#         whose failures stop propagating now that it lives in its own function -- which is the
#         specific risk of having extracted one.
#
# 🔴 THREE MUTATIONS MUST **NOT** BE CAUGHT (W1, W2, W3). A suite that reddens on these is pinning
# source text rather than behaviour:
#   W1  a comment                          -- the classic control
#   W2  the absent-path log line reworded  -- the INFO is a diagnostic, not the behaviour
#   W3  the branch written the other way round, identical semantics -- proves the cases assert
#       what happened to the machine and the graph, not the shape of the `if` that decided it
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. Every file it can touch is snapshotted with `cp -p` first, an EXIT
# trap restores them however this exits including Ctrl-C, and the run ends by asserting byte
# identity against the snapshot AND that the test binary's sha is the one the baseline built.
# `cp -p` restores the ORIGINAL mtime -- older than the object built from the mutant -- so ninja
# would see nothing to do and the next mutation would be measured against a binary still holding
# the previous one. A restored file is therefore also `touch`ed, but ONLY if it actually changed.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child. Nothing here
# starts Mininet, OVS, bmv2 or a listening socket, and 🔴 nothing in the test binary runs
# ovs-vsctl: every one of the five shell seams is overridden by every double. That is not a
# stylistic preference -- tests/test_OvsPowerStrategy.cpp's header records that `sudo ovs-vsctl
# add-br` once really ran against a developer's machine from inside this suite.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_ovs_power_off_asks_the_bridge.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_ovs_power_off_asks_the_bridge.sh
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

# The OVS power cases plus the two in the #46 suite that are about this plane. Named explicitly
# rather than taken as whole suites: PollDoesNotResurrectTest is another change's gate, and a
# widening here must not be judged against cases neither file's fix owns.
FILTER='OvsPowerStrategyTest.*:OvsPowerStrategyConcurrencyTest.*:PollDoesNotResurrectTest.AnOvsPowerOffAlsoSurvivesThePoll:PollDoesNotResurrectTest.ARedundantOvsPowerOffIsStillRecordedAsACommand'

OVS=src/ndt_core/power_management/OVSPowerStrategy.cpp
HPP=include/ndt_core/power_management/OVSPowerStrategy.hpp
FILES=("$OVS" "$HPP")

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
# mutate a site the mutation is not named for; one matching zero times means the source moved under
# the gate, and "could not be applied" must never be reported as "was caught".
count_exact() {
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME
add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

add_anchor "off-asks"        "$OVS" '    const std::optional<bool> bridgeExists = executeBridgeExists(swName);'
add_anchor "off-decides"     "$OVS" '    const bool nothingToTearDown = bridgeExists.has_value() && !*bridgeExists;'
add_anchor "off-branch"      "$OVS" '    if (nothingToTearDown)'
add_anchor "off-records"     "$OVS" '    topoMonitor->setVertexPoweredOffByCommand(node);'
add_anchor "off-teardown"    "$OVS" '        const OpResult teardown = tearDownBridge(node, swName, topoMonitor);'
add_anchor "teardown-fails"  "$OVS" '        if (!teardown.ok)'
add_anchor "on-asks"         "$OVS" '    const std::optional<bool> bridgeAlreadyThere = executeBridgeExists(swName);'
add_anchor "on-clears"       "$OVS" '        topoMonitor->clearVertexAdminPowerOff(node);
        return finishTelemetryRestore(node, swName, saved, topoMonitor);'
add_anchor "seam-exit2"      "$OVS" '    if (WIFEXITED(waitStatus) && WEXITSTATUS(waitStatus) == 2)'
add_anchor "absent-log"      "$OVS" '                       "{} has no bridge on this machine, so there was nothing to tear down. "'
add_anchor "off-comment"     "$OVS" '    // FINDINGS #82. The question this used to ask was `getVertexIsUp`, and the graph is a'

echo "=== anchor uniqueness (exact substring count must be 1) ==="
anchor_ok=1
for i in "${!ANCHOR_NAME[@]}"; do
    n=$(count_exact "${ANCHOR_FILE[$i]}" "${ANCHOR_TEXT[$i]}")
    printf '  %-6s %-16s %-52s x%s\n' \
        "$([[ "$n" == 1 ]] && echo ok || echo REFUSE)" "${ANCHOR_NAME[$i]}" "${ANCHOR_FILE[$i]}" "$n"
    [[ "$n" == 1 ]] || anchor_ok=0
done
[[ "$anchor_ok" == 1 ]] || { echo "🔴 anchors have drifted; this gate cannot render a verdict" >&2; exit 2; }

# 🔴 THE TEST BINARY MUST NOT BE ABLE TO RUN ovs-vsctl.
#
# tests/test_OvsPowerStrategy.cpp's header records that `sudo ovs-vsctl add-br` once really ran
# against a developer's machine from inside this suite, because a double covered the string seam
# and add-br went out through a different one. #82 adds a FIFTH seam, which is a fifth chance to
# reopen exactly that hole -- and a double that forgets it does not fail: it silently asks the
# machine the suite is running on, so the cases pass or fail depending on whether a fabric happens
# to be up.
#
# The invariant, checked rather than trusted: any double that overrides executeListPorts is one
# that drives powerOn/powerOff, and every such double must override executeBridgeExists too. A
# sixth double added next month is caught by the counts disagreeing.
echo
echo "=== no double reaches a real ovs-vsctl (executeListPorts overrides == executeBridgeExists overrides) ==="
seam_ok=1
for tf in tests/test_OvsPowerStrategy.cpp tests/test_PollDoesNotResurrect.cpp; do
    doubles=$(grep -c ': public OVSPowerStrategy' "$tf")
    ports=$(grep -c 'executeListPorts(const std::string' "$tf")
    exists=$(grep -c 'executeBridgeExists(const std::string' "$tf")
    printf '  %-38s doubles=%s  listPorts=%s  brExists=%s' "$tf" "$doubles" "$ports" "$exists"
    if [[ "$ports" == "$exists" && "$ports" != 0 ]]; then
        printf '  ok\n'
    else
        printf '  🔴 REFUSE\n'
        seam_ok=0
    fi
done
if [[ "$seam_ok" != 1 ]]; then
    echo "🔴 a power double does not cover every shell seam; it would run ovs-vsctl for real" >&2
    exit 2
fi

# --- 3. build + run helpers ---------------------------------------------------------------------
build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >/dev/null 2>&1; }

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN. rc comes from the binary itself and
# is never taken through a pipe, because a pipeline's status belongs to its last stage.
#
# 🔴 A TEST CAN GO RED WITHOUT PRINTING `[  FAILED  ]`. The #46 cases start real threads; a mutation
# that deadlocks one against the graph mutex kills the process with no FAILED line, and reading "no
# FAILED line" as "nothing went red" would score real damage as a survivor. DIED_IN is the last
# case gtest announced, empty when it announced none -- which stays a survivor, loudly.
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

# apply <file> <anchor> <new> -- python does the replace, so the anchor matches LITERALLY, newlines
# and all, and the count is re-asserted at the moment of writing. `sed -i` would read the anchor as
# a regex and would not see a multi-line one at all.
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
  pass) echo "  ok       baseline green ($(grep -c '^\[       OK \]' <<<"$OUT") cases in the #82 filter)" ;;
  hang) echo "🔴 BASELINE HUNG (>${TEST_TIMEOUT}s). Not a red; the gate cannot proceed." >&2; exit 2 ;;
  *)    echo "🔴 THE BASELINE IS ALREADY RED: $FAILED $DIED_IN" >&2
        echo "   Every 'expect red' below would be meaningless. Stopping." >&2; exit 2 ;;
esac
echo "  ok       $TARGET sha256 $BIN_SHA_BEFORE"

# ================================================================================================
# 5. the mutations -- direction 1: putting the defect back
# ================================================================================================

# M1. THE DEFECT EXACTLY AS IT SHIPPED. The early return #35 names, restored verbatim at the top of
#     powerOff, above everything including the line that records the command.
mutate "early return restored: powerOff believes the graph's cached isUp" \
    "$OVS" \
    '    const std::optional<bool> bridgeExists = executeBridgeExists(swName);' \
    '    if (!topoMonitor->getVertexIsUp(node))
    {
        return OpResult::success();
    }

    const std::optional<bool> bridgeExists = executeBridgeExists(swName);' \
    OvsPowerStrategyTest.PowerOffTearsDownABridgeThatExistsThoughTheGraphSaysDown \
    OvsPowerStrategyTest.PowerOffOnAnAbsentBridgeSucceedsWithoutDeletingAnythingAndStillRecordsTheCommand \
    OvsPowerStrategyTest.ASecondPowerOffOnAStillRunningSwitchIsNotSwallowedByTheFirst \
    PollDoesNotResurrectTest.ARedundantOvsPowerOffIsStillRecordedAsACommand

# M2. The measurement is taken and then thrown away: powerOff always tears down, whatever
#     br-exists said. The seam is still called -- a reviewer sees a machine being asked -- and the
#     answer reaches nothing. This is the shape a merge resolution produces.
mutate "br-exists result ignored: the teardown runs whatever the machine answered" \
    "$OVS" \
    '    const bool nothingToTearDown = bridgeExists.has_value() && !*bridgeExists;' \
    '    const bool nothingToTearDown = false;
    (void)bridgeExists;' \
    OvsPowerStrategyTest.PowerOffOnAnAbsentBridgeSucceedsWithoutDeletingAnythingAndStillRecordsTheCommand \
    PollDoesNotResurrectTest.ARedundantOvsPowerOffIsStillRecordedAsACommand

# M3. The command is recorded only where a bridge was actually deleted -- "a redundant power-off is
#     not really a power-off". This is #82's own half of #46 and the reason a single call site at
#     the tail is not merely tidier: two call sites are two chances to disagree.
mutate "command not recorded on the absent path" \
    "$OVS" \
    '    topoMonitor->setVertexPoweredOffByCommand(node);' \
    '    if (!nothingToTearDown)
    {
        topoMonitor->setVertexPoweredOffByCommand(node);
    }' \
    OvsPowerStrategyTest.PowerOffOnAnAbsentBridgeSucceedsWithoutDeletingAnythingAndStillRecordsTheCommand \
    PollDoesNotResurrectTest.ARedundantOvsPowerOffIsStillRecordedAsACommand

# M4. "I could not find out" is read as "there is nothing there". br-exists is a NEW sudo argv
#     shape and a NOPASSWD allowlist is argv-pattern scoped, so on a machine where it is refused
#     this makes every power-off skip the teardown and report success -- the defect, louder.
mutate "unknown conflated with absent at the decision site" \
    "$OVS" \
    '    const bool nothingToTearDown = bridgeExists.has_value() && !*bridgeExists;' \
    '    const bool nothingToTearDown = !bridgeExists.value_or(false);' \
    OvsPowerStrategyTest.PowerOffAttemptsTheTeardownWhenItCannotAskWhetherTheBridgeExists

# M5. The same conflation one level down, in the seam's own rule: any non-zero status becomes
#     "no such bridge". Every double overrides the seam, so this is invisible to all of them --
#     it is caught only because the decision was split into a function that needs no process.
mutate "the seam reads every failure as 'no such bridge'" \
    "$OVS" \
    '    if (WIFEXITED(waitStatus) && WEXITSTATUS(waitStatus) == 2)' \
    '    if (waitStatus != 0)' \
    OvsPowerStrategyTest.BrExistsTreatsExitTwoAsAnAnswerAndEveryOtherFailureAsUnknown

# M6. power-on goes back to a blind add-br: the existence question is asked and the answer
#     discarded. On an existing bridge add-br exits 1 and the whole power-on 500s at step one.
mutate "power-on blind-adds the bridge again" \
    "$OVS" \
    '    const std::optional<bool> bridgeAlreadyThere = executeBridgeExists(swName);' \
    '    const std::optional<bool> bridgeAlreadyThere = false;' \
    OvsPowerStrategyTest.PowerOnDoesNotBlindAddBrWhenTheBridgeIsAlreadyThere \
    OvsPowerStrategyTest.PowerOnOnAnExistingBridgeWithdrawsAStandingPowerOffCommand

# M7. The extracted teardown's failure stops propagating: powerOff carries on to record the
#     command and return 200 after a list-ports that failed. This is the specific hazard of having
#     moved that body into its own function -- the return value is now something a caller has to
#     remember to read, and the old code could not forget.
mutate "the teardown's failure is dropped by its new caller" \
    "$OVS" \
    '        if (!teardown.ok)' \
    '        if (teardown.ok && !teardown.ok)' \
    OvsPowerStrategyTest.PowerOffStillRefusesWhenTheBridgeIsThereButItsPortsCannotBeRead \
    OvsPowerStrategyTest.PowerOffRefusesWhenItCannotReadThePorts \
    OvsPowerStrategyTest.PowerOffLeavesTheVertexUpWhenACommandFails

# ================================================================================================
#    direction 2: relaxing past the fix. 🔴 These are the reason this gate is not just #82's.
# ================================================================================================

# M8. THE OVER-CORRECTION. powerOff ALWAYS takes the absent path, so no bridge is ever deleted --
#     and every assertion in direction 1 gets greener, because the command is still recorded and
#     the vertex still goes down. A twin that reports switches off while the fabric forwards
#     everything is a worse outage than the one this fix removes, and it is exactly what
#     "just trust br-exists" degenerates into if the answer is inverted.
mutate "power-off never tears anything down" \
    "$OVS" \
    '    const bool nothingToTearDown = bridgeExists.has_value() && !*bridgeExists;' \
    '    const bool nothingToTearDown = true;
    (void)bridgeExists;' \
    OvsPowerStrategyTest.PowerOffSavesThePortsThenDeletesTheBridge \
    OvsPowerStrategyTest.PowerOffTearsDownABridgeThatExistsThoughTheGraphSaysDown \
    PollDoesNotResurrectTest.AnOvsPowerOffAlsoSurvivesThePoll

# M9. The mirror on the power-on side: the bridge is always assumed present, so nothing is ever
#     built. Direction 1 cannot see it -- "does not blind-add-br" is more true than ever.
mutate "power-on never builds the bridge" \
    "$OVS" \
    '    const std::optional<bool> bridgeAlreadyThere = executeBridgeExists(swName);' \
    '    const std::optional<bool> bridgeAlreadyThere = true;' \
    OvsPowerStrategyTest.PowerOnRecreatesTheBridgeWithTheSavedPorts \
    OvsPowerStrategyTest.PowerOnBuildsTheBridgeWhenTheMachineSaysItIsNotThere

# M10. The new power-on path settles the telemetry but never withdraws the standing command, so a
#      switch recovered this way is suppressed by FINDINGS #46's veto for the rest of the process.
#      This is #46's own M6 arriving through the door #82 opened.
mutate "the existing-bridge power-on never withdraws the command" \
    "$OVS" \
    '        topoMonitor->clearVertexAdminPowerOff(node);
        return finishTelemetryRestore(node, swName, saved, topoMonitor);' \
    '        return finishTelemetryRestore(node, swName, saved, topoMonitor);' \
    OvsPowerStrategyTest.PowerOnOnAnExistingBridgeWithdrawsAStandingPowerOffCommand

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the behaviour changed".
widen "a comment, nothing else" \
    "$OVS" \
    '    // FINDINGS #82. The question this used to ask was `getVertexIsUp`, and the graph is a' \
    '    // FINDINGS #82. This used to ask `getVertexIsUp`, and that graph field is a'

# W2. The absent-path log line reworded. The INFO is a diagnostic: a suite that reddens here is
#     pinning a string, and the next person to improve the message would have to change a test.
widen "the already-stopped log line is reworded" \
    "$OVS" \
    '                       "{} has no bridge on this machine, so there was nothing to tear down. "' \
    '                       "there is no bridge for {} here, so nothing had to be torn down. "'

# W3. The branch written the other way round -- identical semantics, opposite shape. The control
#     for tests that pin the structure of the fix rather than what the machine and the graph end
#     up holding.
widen "the absent/present branch is inverted" \
    "$OVS" \
    '    if (nothingToTearDown)' \
    '    if (!(!nothingToTearDown))'

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
else
    echo "  🔴 THE RESTORED TREE DOES NOT BUILD -- the binary on disk is whatever the last"
    echo "     mutation left. Do not run another gate against it."
    ok=0
fi
run_tests "$FILTER"
if [[ "$STATUS" != pass ]]; then
    echo "  🔴 the suite is red after restore -- a mutant object is still linked in: $FAILED"; ok=0
else
    echo "  suite green again after restore"
fi
BIN_SHA_AFTER=$(sha256sum "$BIN" 2>/dev/null | cut -c1-16)
if [[ "$BIN_SHA_AFTER" != "$BIN_SHA_BEFORE" ]]; then
    echo "  🔴 test binary sha changed: $BIN_SHA_AFTER (was $BIN_SHA_BEFORE). The tree restored"
    echo "     byte-identically, so a binary that did not is a build that is not reproducible"
    echo "     from it -- and every 'caught' above was measured against binaries built the same way."
    ok=0
else
    echo "  test binary sha unchanged: $BIN_SHA_AFTER"
fi

printf '\n=== verdict ===\n'
printf '  %d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
printf '  %d widenings, %d wrongly caught\n' "$WIDENINGS" "$WIDENINGS_CAUGHT"

if [[ "$ok" != 1 ]]; then exit 2; fi
if (( SURVIVORS > 0 || WIDENINGS_CAUGHT > 0 )); then exit 1; fi
echo "  FINDINGS #82 gate: the early return cannot be put back by any of seven routes, a"
echo "  power-off that stops deleting bridges and a power-on that stops building them are"
echo "  caught too, and three behaviour-preserving edits were left alone."
exit 0
