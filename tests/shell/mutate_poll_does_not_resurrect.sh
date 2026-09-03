#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #46 (with #35 and #36) -- a commanded power-off must survive the
# topology poll, and the poll must go on marking every other switch up.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_PollDoesNotResurrect.cpp.
#
# WHAT THE DEFECT WAS
#   TopologyAndFlowMonitor::updateSwitches applied the control plane's list with
#       (*m_graph)[*vertexSwitchOpt].isUp = true;
#   and no else branch anywhere in the function, so the only thing a poll could ever say about a
#   switch's power was "up". The proxy lists a killed switch for D = 3.06 s after it dies, so a
#   power-off landing shortly before a poll was overwritten by it -- and re-overwritten every 30 s
#   after that, for ever. Live, on the 10-switch bmv2 fabric: lost 8 of 14 at the losing phase,
#   0 of 4 at the winning one, every loss at t_off + 2.31 s.
#
# 🔴 TWO DIRECTIONS, AND THE SECOND ONE IS WHY THIS GATE EXISTS AT ALL
#   1. RESTORING the defect must be caught          (M1, M2, M3, M4, M9, M10)
#      -- discovery lifts isUp over a standing command, by any of the routes it could take:
#         the original unconditional write, the veto inverted, the power path going back to the
#         observation writer, the observation writer clearing the command, and the OVS plane.
#   2. RELAXING past the fix must ALSO be caught    (M5, M6)
#      -- a poll that NEVER writes up satisfies every assertion in direction 1 and is a worse
#         outage than the defect: for everything the liveness worker answers Unknown about,
#         discovery is the only writer that brings a switch back. A gate without M5/M6 would give
#         a green light to `// (*m_graph)[v].isUp = true;`.
#   plus #35's two early returns (M7, M8), which are what turned the resurrection into a brick.
#
# 🔴 THREE MUTATIONS MUST **NOT** BE CAUGHT (W1, W2, W3). A suite that reddens on these is pinning
# source text rather than behaviour, and every catch above would be worth nothing:
#   W1  a comment                        -- the classic control
#   W2  the WARN's wording               -- the log line is not the behaviour; a test that reads it
#                                           would be pinning a string this gate cannot defend
#   W3  the veto rewritten as an early `continue` with identical semantics -- proves the tests
#       assert what the graph ends up holding, not the shape of the branch that put it there
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. Every file it can touch is snapshotted with `cp -p` first, an EXIT
# trap restores them however this exits including Ctrl-C, and the run ends by asserting byte
# identity against the snapshot AND that the test binary's sha is the one the baseline built.
# `cp -p` restores the ORIGINAL mtime -- older than the object built from the mutant -- so ninja
# would see nothing to do and the next mutation would be measured against a binary still holding
# the previous one. A restored file is therefore also `touch`ed, but ONLY if it actually changed:
# touching GraphTypes.hpp on every iteration rebuilds every TU that includes it.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child. Nothing here
# starts Mininet, bmv2, OVS or a listening socket. The tests do start the kernel's own poll and
# liveness threads in-process; both fail to reach a control plane and write nothing.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_poll_does_not_resurrect.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_poll_does_not_resurrect.sh
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
FILTER='PollDoesNotResurrectTest.*'

TFM=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
P4=src/ndt_core/power_management/P4PowerStrategy.cpp
OVS=src/ndt_core/power_management/OVSPowerStrategy.cpp
FILES=("$TFM" "$P4" "$OVS")

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

add_anchor "poll-veto"        "$TFM" '                    if (vprop.adminPoweredOff)'
add_anchor "poll-lifts"       "$TFM" '                    else
                    {
                        vprop.isUp = true;
                    }'
add_anchor "poll-enables"     "$TFM" '                    vprop.isEnabled = true;'
add_anchor "commanded-off"    "$TFM" '    vprop.isUp = false;
    vprop.adminPoweredOff = true;'
add_anchor "observed-up"      "$TFM" '    (*m_graph)[v].isUp = true;
    /// @see setEdgeUp for why the reason is cleared here.
    (*m_graph)[v].downReason = DownReason::None;'
add_anchor "warn-text"        "$TFM" '                                "the control plane still lists switch {} (dpid {}), but a "'
add_anchor "p4-off-writes"    "$P4"  '    topoMonitor->setVertexPoweredOffByCommand(node);'
add_anchor "p4-on-guard"      "$P4"  '    if (topoMonitor->getVertexIsUp(node) && !topoMonitor->getVertexAdminPoweredOff(node) &&
        !poweredOffWithinDistrustWindow(swName))'
add_anchor "p4-on-clears"     "$P4"  '    topoMonitor->clearVertexAdminPowerOff(node);'
add_anchor "ovs-off-writes"   "$OVS" '    topoMonitor->setVertexPoweredOffByCommand(node);'
add_anchor "ovs-comment"      "$TFM" '                    // The narrowest rule that closes it: discovery is still allowed to lift'

echo "=== anchor uniqueness (exact substring count must be 1) ==="
anchor_ok=1
for i in "${!ANCHOR_NAME[@]}"; do
    n=$(count_exact "${ANCHOR_FILE[$i]}" "${ANCHOR_TEXT[$i]}")
    printf '  %-6s %-16s %-52s x%s\n' \
        "$([[ "$n" == 1 ]] && echo ok || echo REFUSE)" "${ANCHOR_NAME[$i]}" "${ANCHOR_FILE[$i]}" "$n"
    [[ "$n" == 1 ]] || anchor_ok=0
done
[[ "$anchor_ok" == 1 ]] || { echo "🔴 anchors have drifted; this gate cannot render a verdict" >&2; exit 2; }

# --- 3. build + run helpers ---------------------------------------------------------------------
build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >/dev/null 2>&1; }

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN. rc comes from the binary itself and
# is never taken through a pipe, because a pipeline's status belongs to its last stage.
#
# 🔴 A TEST CAN GO RED WITHOUT PRINTING `[  FAILED  ]`. These cases start real threads; a mutation
# that deadlocks the poll thread against the graph mutex kills the process with no FAILED line, and
# reading "no FAILED line" as "nothing went red" would score real damage as a survivor. DIED_IN is
# the last case gtest announced, empty when it announced none -- which stays a survivor, loudly.
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
  pass) echo "  ok       baseline green ($(grep -c '^\[       OK \]' <<<"$OUT") cases in $FILTER)" ;;
  hang) echo "🔴 BASELINE HUNG (>${TEST_TIMEOUT}s). Not a red; the gate cannot proceed." >&2; exit 2 ;;
  *)    echo "🔴 THE BASELINE IS ALREADY RED: $FAILED $DIED_IN" >&2
        echo "   Every 'expect red' below would be meaningless. Stopping." >&2; exit 2 ;;
esac
echo "  ok       $TARGET sha256 $BIN_SHA_BEFORE"

# ================================================================================================
# 5. the mutations -- direction 1: putting the defect back
# ================================================================================================

# M1. THE DEFECT EXACTLY AS IT SHIPPED. The veto is gone and the write is unconditional again --
#     one line, no else branch, which is what TopologyAndFlowMonitor.cpp:768-772 was.
mutate "the defect verbatim: the poll writes isUp = true unconditionally" \
    "$TFM" \
    '                    if (vprop.adminPoweredOff)
                    {' \
    '                    if (false)
                    {' \
    PollDoesNotResurrectTest.ACommandedPowerOffSurvivesTheNextPollThatStillListsTheSwitch \
    PollDoesNotResurrectTest.EveryLaterPollDeclinesToo \
    PollDoesNotResurrectTest.AnOvsPowerOffAlsoSurvivesThePoll \
    PollDoesNotResurrectTest.TheEmittedVertexShapeCarriesAdminStateAndReachable

# M2. Same outcome by a different route: the power path goes back to the OBSERVATION writer, so the
#     graph can no longer tell "the twin killed this" from "a probe missed a beat". This is the
#     single line the fix turns on, and it is the one a later refactor is most likely to undo.
mutate "P4 power-off records an observation instead of a command" \
    "$P4" \
    '    topoMonitor->setVertexPoweredOffByCommand(node);' \
    '    topoMonitor->setVertexDown(node);' \
    PollDoesNotResurrectTest.ACommandedPowerOffSurvivesTheNextPollThatStillListsTheSwitch \
    PollDoesNotResurrectTest.EveryLaterPollDeclinesToo \
    PollDoesNotResurrectTest.TheLivenessWorkersUpDoesNotWithdrawTheCommand \
    PollDoesNotResurrectTest.PowerOnActuatesWhenACommandedOffIsStillStanding

# M3. The second door: the 1 Hz liveness worker's setVertexUp clears the command. Within a second
#     of every kill the proxy's cached probe_ok is still true, so this would hand the resurrection
#     a one-tick window and the poll would then take it exactly as before.
mutate "a liveness observation withdraws the power-off command" \
    "$TFM" \
    '    (*m_graph)[v].isUp = true;
    /// @see setEdgeUp for why the reason is cleared here.
    (*m_graph)[v].downReason = DownReason::None;' \
    '    (*m_graph)[v].isUp = true;
    /// @see setEdgeUp for why the reason is cleared here.
    (*m_graph)[v].downReason = DownReason::None;
    (*m_graph)[v].adminPoweredOff = false;' \
    PollDoesNotResurrectTest.TheLivenessWorkersUpDoesNotWithdrawTheCommand \
    PollDoesNotResurrectTest.PowerOnActuatesWhenACommandedOffIsStillStanding

# M4. The command is never recorded in the first place: power-off takes the switch down but leaves
#     the flag clear. Everything looks right for one instant and the next poll undoes it.
mutate "power-off marks down but records no command" \
    "$TFM" \
    '    vprop.isUp = false;
    vprop.adminPoweredOff = true;' \
    '    vprop.isUp = false;
    vprop.adminPoweredOff = false;' \
    PollDoesNotResurrectTest.ACommandedPowerOffSurvivesTheNextPollThatStillListsTheSwitch \
    PollDoesNotResurrectTest.EveryLaterPollDeclinesToo \
    PollDoesNotResurrectTest.TheLivenessWorkersUpDoesNotWithdrawTheCommand

# ================================================================================================
#    direction 2: relaxing past the fix. 🔴 These are the reason this gate is not just #46's.
# ================================================================================================

# M5. THE OVER-CORRECTION. The poll stops writing isUp at all -- the shape someone reaches for on
#     reading "the poll must not mark switches up". Every assertion in direction 1 stays green;
#     the fabric never comes back, because for anything liveness answers Unknown about, discovery
#     is the only writer that lifts a switch.
mutate "the poll never marks any switch up" \
    "$TFM" \
    '                    else
                    {
                        vprop.isUp = true;
                    }' \
    '                    else
                    {
                        // nothing
                    }' \
    PollDoesNotResurrectTest.DiscoveryStillMarksAnUncommandedSwitchUp \
    PollDoesNotResurrectTest.APowerOnLetsDiscoveryLiftTheSwitchAgain

# M6. The narrower over-correction, and the more plausible one: the veto is never lifted, so a
#     switch that has been powered back on is suppressed for the rest of the process. Direction 1
#     cannot see this at all -- the command being permanent makes every one of those cases greener.
mutate "power-on never withdraws the command" \
    "$P4" \
    '    topoMonitor->clearVertexAdminPowerOff(node);' \
    '    (void)node;' \
    PollDoesNotResurrectTest.APowerOnLetsDiscoveryLiftTheSwitchAgain

# ================================================================================================
#    FINDINGS #35: the early returns that turned the resurrection into a brick
# ================================================================================================

# M7. The power-off guard as it was: ask the graph, believe it, run nothing. The graph reads down
#     for a running switch whenever the proxy's probe is failing, so this returned 200 having sent
#     no signal to anything.
mutate "power-off returns success on the graph's cached isUp" \
    "$P4" \
    '    // The helper SIGTERMs the one PID the manifest names for this switch -- after' \
    '    if (!topoMonitor->getVertexIsUp(node))
    {
        return OpResult::success();
    }

    // The helper SIGTERMs the one PID the manifest names for this switch -- after' \
    PollDoesNotResurrectTest.PowerOffActuatesEvenWhenTheGraphAlreadySaysDown

# M8. The power-on guard as it was: two questions instead of three. Past the 15 s distrust window a
#     resurrected switch reads up, so this is #36 -- 200 Success in ~1 ms, no command, and the only
#     recovery left is out of band.
mutate "power-on returns success on a cached isUp with a command standing" \
    "$P4" \
    '    if (topoMonitor->getVertexIsUp(node) && !topoMonitor->getVertexAdminPoweredOff(node) &&
        !poweredOffWithinDistrustWindow(swName))' \
    '    if (topoMonitor->getVertexIsUp(node) &&
        !poweredOffWithinDistrustWindow(swName))' \
    PollDoesNotResurrectTest.PowerOnActuatesWhenACommandedOffIsStillStanding

# ================================================================================================
#    the OVS plane, which is what `ndt up` gives you by default
# ================================================================================================

# M9. OVS power-off goes back to the observation writer. updateSwitches is plane-agnostic, so a fix
#     wired only into P4PowerStrategy holds on the plane the evidence came from and nowhere else.
mutate "OVS power-off records an observation instead of a command" \
    "$OVS" \
    '    topoMonitor->setVertexPoweredOffByCommand(node);' \
    '    topoMonitor->setVertexDown(node);' \
    PollDoesNotResurrectTest.AnOvsPowerOffAlsoSurvivesThePoll

# M10. The veto reads the wrong flag. adminDisabled is the operator's out-of-service intent and is
#      false for every switch that was merely powered off, so the poll resurrects again -- while
#      the code still visibly consults "an admin flag", which is how this one would survive review.
mutate "the veto consults adminDisabled instead of the power command" \
    "$TFM" \
    '                    if (vprop.adminPoweredOff)' \
    '                    if (vprop.adminDisabled)' \
    PollDoesNotResurrectTest.ACommandedPowerOffSurvivesTheNextPollThatStillListsTheSwitch \
    PollDoesNotResurrectTest.EveryLaterPollDeclinesToo \
    PollDoesNotResurrectTest.AnOvsPowerOffAlsoSurvivesThePoll

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the behaviour changed".
widen "a comment, nothing else" \
    "$TFM" \
    '                    // The narrowest rule that closes it: discovery is still allowed to lift' \
    '                    // The narrowest rule that shuts it: discovery may still lift'

# W2. The WARN's wording. The log line is a diagnostic, not the behaviour: a suite that reddens
#     here is pinning a string, and the next person to improve the message would have to change a
#     test to do it.
widen "the declined-resurrection warning is reworded" \
    "$TFM" \
    '                                "the control plane still lists switch {} (dpid {}), but a "' \
    '                                "switch {} (dpid {}) is still listed by the control plane, but a "'

# W3. The veto rewritten with the branches the other way round -- identical semantics, different
#     shape. This is the control for tests that pin the structure of the fix rather than what the
#     graph ends up holding.
widen "the veto is written as the negated branch instead" \
    "$TFM" \
    '                    if (vprop.adminPoweredOff)' \
    '                    if (bool(vprop.adminPoweredOff) == true)'

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
echo "  FINDINGS #46 gate: the defect cannot be put back by any of six routes, a poll that"
echo "  stops marking switches up is caught too, and three behaviour-preserving edits were"
echo "  left alone."
exit 0
