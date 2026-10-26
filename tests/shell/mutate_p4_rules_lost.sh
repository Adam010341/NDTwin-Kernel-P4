#!/usr/bin/env bash
#
# Mutation gate for the kernel half of KNOWN-ISSUES A-4c's Ryu-path loss notice: the
# P4RulesLost* cases in tests/test_P4Capabilities.cpp (section 4).
#
# [Co-developed with claude code -- Adam]
#
# Rules installed through the Ryu-compatible API are not replayed after a P4 pipeline push (the
# proxy's journal holds requests, not their reasons); the proxy reports them (`ryu_rules_lost` on
# GET /p4/switch_state) and the kernel must log an ERROR once per record and serve the record on
# /ndt/get_graph_data. Each
# mutation below makes the kernel quiet again, noisy in the wrong way, or wrong about which node
# the record belongs to, and must turn its named case red. The mechanics (one build-and-run cell
# per mutation, snapshot and restore, anchors that must resolve exactly once, a control that must
# stay green) are tests/shell/mutate_p4_capabilities.sh's, copied rather than shared for the
# reason that file gives for its helpers.
#
# NOT IN THIS GATE: the lock around the record, for the reason mutate_p4_capabilities.sh gives.
#
# Guard: on Adam's laptop every cell goes through tools/build_guard/guarded_build.sh (see
# mutate_p4_capabilities.sh's header for NO_GUARD). In an isolated VM with no guard, NO_GUARD=1.
#
# Usage:  bash tests/shell/mutate_p4_rules_lost.sh            (BUILD_DIR defaults to build)
#         bash tests/shell/mutate_p4_rules_lost.sh --dry-run  # anchors only; NOT a gate result
# Exit:   0 every mutation caught and the control green, 1 a mutation survived (or the control
#         went red), 2 refused.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='P4RulesLost.*:P4RulesLostPoll.*:P4RulesLostWire.*'
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

LOSS=src/ndt_core/power_management/P4RulesLost.cpp
DCPM=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
HTTP=src/ndt_core/http/HttpSession.cpp
FILES=("$LOSS" "$DCPM" "$HTTP")

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
    ANCHOR_CHECK=1
fi

for f in "${FILES[@]}" tests/test_P4Capabilities.cpp; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found." >&2; exit 2; }
done

MUTATIONS=0
SURVIVORS=0

# anchor_count <file> <literal> -- how many times the literal occurs. python rather than
# `grep -c -F`, which splits a multi-line pattern into several and counts matching LINES.
anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# --- the mutation table ------------------------------------------------------------------------
# Declared once so the anchor check and the gate cannot disagree about what is being tested.
# Fields: label, file, anchor, replacement, the test that must go red ("-" for a control).

MUT_LABEL=(); MUT_FILE=(); MUT_ANCHOR=(); MUT_REPL=(); MUT_EXPECT=()
add() {
    MUT_LABEL+=("$1"); MUT_FILE+=("$2"); MUT_ANCHOR+=("$3")
    MUT_REPL+=("$4");  MUT_EXPECT+=("$5")
}

add "K1: the poll never logs what it read (silent again)" \
    "$DCPM" \
    '        SPDLOG_LOGGER_ERROR(Logger::instance(), "{}", p4loss::describe(lost));' \
    '        (void)lost;' \
    'P4RulesLostPoll.ThePollLogsOneErrorPerRecordAndKeepsTheRecord'

add "K2: the loss is logged at WARN, not ERROR" \
    "$DCPM" \
    '        SPDLOG_LOGGER_ERROR(Logger::instance(), "{}", p4loss::describe(lost));' \
    '        SPDLOG_LOGGER_WARN(Logger::instance(), "{}", p4loss::describe(lost));' \
    'P4RulesLostPoll.ThePollLogsOneErrorPerRecordAndKeepsTheRecord'

add "K3: the poll never records what it read" \
    "$DCPM" \
    '        m_p4RulesLost = std::move(rulesLost);' \
    '        (void)rulesLost;' \
    'P4RulesLostPoll.ThePollLogsOneErrorPerRecordAndKeepsTheRecord'

add "K4: an unreadable proxy leaves the last record standing" \
    "$DCPM" \
    '        m_p4RulesLost = std::move(rulesLost);' \
    '        if (payload.has_value())
        {
            m_p4RulesLost = std::move(rulesLost);
        }' \
    'P4RulesLostPoll.AnUnreadableProxyWithdrawsTheRecord'

add "K5: the announcer forgets what it said (an ERROR every second)" \
    "$LOSS" \
    '        if (!m_seen.insert(id).second)' \
    '        if (false)' \
    'P4RulesLost.EachRecordIsAnnouncedOnceAndANewOneAgain'

add "K6: a push that took nothing is announced too" \
    "$LOSS" \
    '        if (a.count.has_value() && *a.count == 0 && a.unreadable == 0 && a.writeFailures == 0)' \
    '        if (false)' \
    'P4RulesLost.APushThatTookNothingIsNotAnnounced'

add "K7: unreadable journal lines are ignored" \
    "$LOSS" \
    '        if (a.count.has_value() && *a.count == 0 && a.unreadable == 0 && a.writeFailures == 0)' \
    '        if (a.count.has_value() && *a.count == 0 && a.writeFailures == 0)' \
    'P4RulesLost.UnreadableJournalLinesAreAnnouncedEvenWithACountOfZero'

add "K8: a count the kernel cannot read is taken as zero" \
    "$LOSS" \
    '        a.count = nonNegative(record, "count");' \
    '        a.count = nonNegative(record, "count").value_or(0);' \
    'P4RulesLost.ACountTheKernelCannotReadIsAnnouncedAsUnknown'

add "K9: the line no longer says nothing was replayed" \
    "$LOSS" \
    '    line += ". They were NOT replayed: ' \
    '    line += ". They were replayed: ' \
    'P4RulesLost.TheLineNamesTheSwitchTheCountAndThatNothingWasReplayed'

add "K10: the record is read from the wrong key" \
    "$LOSS" \
    '    return p4caps::objectsUnder(payload, "ryu_rules_lost");' \
    '    return p4caps::objectsUnder(payload, "rules_lost");' \
    'P4RulesLost.ARecordIsCopiedVerbatimAndNullIsNoEntry'

add "K11: hosts get the record too" \
    "$LOSS" \
    '    if (vertex.vertexType != VertexType::SWITCH)
    {
        return;
    }
    const auto it = records.find(vertex.dpid);' \
    '    const auto it = records.find(vertex.dpid);' \
    'P4RulesLost.AttachPutsTheRecordOnItsSwitchOnly'

add "K13: journal write failures are ignored" \
    "$LOSS" \
    '        if (a.count.has_value() && *a.count == 0 && a.unreadable == 0 && a.writeFailures == 0)' \
    '        if (a.count.has_value() && *a.count == 0 && a.unreadable == 0)' \
    'P4RulesLost.JournalWriteFailuresAreAnnouncedEvenWithACountOfZero'

add "K14: the proxy's reason for an unknown count is dropped" \
    "$LOSS" \
    '        line += " (count unknown: " + a.countUnknown + ")";' \
    '        line += "";' \
    'P4RulesLost.ANullCountIsAnnouncedWithTheProxysReason'

add "K12: get_graph_data never puts the record on the node" \
    "$HTTP" \
    '        p4loss::attachToNode(node, graph[vd], p4RulesLost);' \
    '        // MUTANT: ryu_rules_lost never attached' \
    'P4RulesLostWire.TheSwitchNodeCarriesTheRecordVerbatim'

add "C1: control -- a comment beside the log line (must stay green)" \
    "$DCPM" \
    '        SPDLOG_LOGGER_ERROR(Logger::instance(), "{}", p4loss::describe(lost));' \
    '        // control: nothing changes here
        SPDLOG_LOGGER_ERROR(Logger::instance(), "{}", p4loss::describe(lost));' \
    '-'

# --- anchor check (never a verdict) -------------------------------------------------------------

if [[ "$ANCHOR_CHECK" != "0" ]]; then
    echo "================================================================"
    echo " ANCHOR CHECK ONLY -- THIS IS NOT A GATE RESULT."
    echo " Nothing was built, no mutation was applied, no test was run."
    echo " The exit code is 2 on purpose so this can never be mistaken for"
    echo " a passing gate."
    echo "================================================================"
    broken=0
    for i in "${!MUT_LABEL[@]}"; do
        n=$(anchor_count "${MUT_FILE[$i]}" "${MUT_ANCHOR[$i]}")
        if [[ "$n" -eq 1 ]]; then
            printf '  ok    %s  (%s)\n' "$n" "${MUT_LABEL[$i]}"
        else
            printf '  🔴 %s matches in %s  (%s)\n' "$n" "${MUT_FILE[$i]}" "${MUT_LABEL[$i]}"
            broken=$((broken + 1))
        fi
    done
    if [[ "$broken" -eq 0 ]]; then
        echo "ANCHORS: ok -- all ${#MUT_LABEL[@]} resolve to one site each."
    else
        echo "ANCHORS: BROKEN -- $broken anchor(s) have moved. Fix them before running the gate."
    fi
    echo "(still exiting 2: an anchor check is not a gate result)"
    exit 2
fi

# --- the gate: mutations in place, snapshot and restore ------------------------------------------

[[ -f "$BUILD_DIR/build.ninja" ]] || { echo "REFUSE: $BUILD_DIR is not configured (cmake -B $BUILD_DIR -G Ninja)." >&2; exit 2; }

SNAP=$(mktemp -d)
BK=$(mktemp -d)
snap() { echo "$SNAP/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done
restore() {
    local f
    for f in "${FILES[@]}"; do
        # Only a file that differs is put back. Touching all three after every cell would make
        # every build recompile HttpSession.cpp (~1.6 GB, minutes at -j1) for mutants that never
        # went near it -- and each build waits on the shared lock.
        cmp -s "$(snap "$f")" "$f" && continue
        cp -p "$(snap "$f")" "$f"
        # cp -p restores the ORIGINAL mtime, which is older than the object built from the
        # mutant -- ninja would then see nothing to do and the next run would test the mutant
        # while the source on disk is pristine. touch is what actually restores the build.
        touch "$f"
    done
}
trap 'restore; rm -rf "$SNAP" "$BK"' EXIT

# cell -- ONE guard call that builds the target and, only if that succeeded, runs the suite:
# one cell, one lock acquisition, never a batch. Writes $BK/build.log and $BK/run.log and sets
# CELL_BUILT (0/1) and CELL_RC (the suite's exit status, taken from the binary directly, never
# through a pipe). See the header for NO_GUARD.
CELL_BUILT=0
CELL_RC=0
cell() {
    local runner=(bash -c '
        cmake --build "$1" --target "$2" -j1 >"$3" 2>&1 || exit 97
        "$4" --gtest_filter="$5" >"$6" 2>&1' _
        "$BUILD_DIR" "$TARGET" "$BK/build.log" "$BIN" "$FILTER" "$BK/run.log")
    : >"$BK/build.log"; : >"$BK/run.log"
    local rc
    if [[ "${NO_GUARD:-0}" == "1" ]]; then
        "${runner[@]}"; rc=$?
    else
        LOCK_WAIT="${LOCK_WAIT:-10800}" JOBS=1 "$GUARD" "${runner[@]}" >>"$BK/guard.log" 2>&1; rc=$?
    fi
    # 97 is the build failing. The guard's own refusals (lock timeout, bad env) come back as other
    # codes with an empty run log; they are reported as "did not build" too, never as a verdict.
    if [[ $rc -eq 97 || ! -s "$BK/run.log" ]]; then
        CELL_BUILT=0
    else
        CELL_BUILT=1
    fi
    CELL_RC=$rc
}

# red_tests -- the names of the tests the last cell saw fail, space-separated; empty when all
# passed. The name pattern admits digits: every suite here is spelled P4..., and a letters-only
# pattern would read each red as "none" and score every mutant a survivor.
red_tests() {
    if [[ $CELL_RC -eq 0 ]]; then echo ""; return; fi
    local names
    names=$(sed -n 's/^\[  FAILED  \] \([A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' "$BK/run.log" | sort -u | tr '\n' ' ')
    # A non-zero exit with no FAILED line is a crash or an abort, which is red but names nothing.
    [[ -n "$names" ]] && echo "$names" || echo "UNNAMED(rc=$CELL_RC)"
}

echo "baseline (must be green before any mutation):"
cell
if [[ $CELL_BUILT -ne 1 ]]; then
    echo "  the tree does not build (cell rc $CELL_RC) -- nothing below would mean anything"
    tail -8 "$BK/build.log" "$BK/guard.log" 2>/dev/null | sed 's/^/    /'
    exit 2
fi
base_red=$(red_tests)
if [[ -n "$base_red" ]]; then
    echo "  baseline is RED: $base_red"
    exit 2
fi
echo "  green  ($(grep -c '^\[       OK \]' "$BK/run.log") cases passed in $FILTER)"

CONTROL_RED=0

# mutate <label> <file> <anchor> <replacement> <expected-test>
mutate() {
    local label="$1" file="$2" anchor="$3" repl="$4" expected="$5"
    local n; n=$(anchor_count "$file" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1)); restore; return
    fi
    [[ "$expected" == "-" ]] || MUTATIONS=$((MUTATIONS + 1))

    if ! ANCHOR="$anchor" REPL="$repl" python3 - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
    then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    cell
    if [[ $CELL_BUILT -ne 1 ]]; then
        # A mutant that never reached the compiler established nothing about the tests.
        echo "  🔴 MUTANT DOES NOT COMPILE (cell rc $CELL_RC) -- the behaviour it was aimed at is still untested."
        tail -8 "$BK/build.log" | sed 's/^/    /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_tests)
    restore

    if [[ "$expected" == "-" ]]; then
        if [[ -n "$failed" ]]; then
            echo "  🔴 CONTROL WENT RED: $failed -- the gate reports red for a change that changes nothing"
            CONTROL_RED=$((CONTROL_RED + 1))
        else
            echo "  control green, as it must be"
        fi
        return
    fi
    if [[ -z "$failed" ]]; then
        echo "  🔴 SURVIVED -- every test stayed green"
        SURVIVORS=$((SURVIVORS + 1))
        return
    fi
    if ! grep -qw -- "$expected" <<<"$failed"; then
        echo "  🔴 WRONG TEST WENT RED. expected $expected, got: $failed"
        echo "     A gate that fires without establishing what it claims is not a gate."
        SURVIVORS=$((SURVIVORS + 1))
        return
    fi
    echo "  caught by: $failed"
}

for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_FILE[$i]}" "${MUT_ANCHOR[$i]}" \
           "${MUT_REPL[$i]}" "${MUT_EXPECT[$i]}"
done

echo
echo "restoring and rebuilding the baseline..."
restore
cell
if [[ $CELL_BUILT -ne 1 ]]; then
    echo "🔴 the tree does not build after restore -- the baseline was NOT restored"
    exit 2
fi
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$(snap "$f")"; then
        echo "🔴 $f was NOT restored byte-for-byte"
        exit 2
    fi
done
after_red=$(red_tests)
if [[ -n "$after_red" ]]; then
    echo "🔴 the restored tree is RED: $after_red"
    exit 2
fi
echo "baseline restored, byte-identical, green."

echo
if [[ "$SURVIVORS" -eq 0 && "$CONTROL_RED" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived; control green"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROL_RED control(s) red"
exit 1
