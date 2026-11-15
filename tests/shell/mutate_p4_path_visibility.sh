#!/usr/bin/env bash
#
# Mutation gate for `flow_stats` and `path_unconfirmed_at`: the P4FlowStats* and P4PathVisibility*
# cases in tests/test_P4PathVisibility.cpp and tests/test_P4Capabilities.cpp (section 5).
#
# [Co-developed with claude code -- Adam]
#
# The P4 proxy renders only the bound route table of a package's pipeline for the path walk and
# counts every other row it left out (`flow_stats.unrendered_entries` on GET /p4/switch_state).
# The kernel must copy that record onto the switch's /ndt/get_graph_data node and mark each flow
# row of /ndt/get_detected_flow_data and /ndt/get_detected_top_k_flow_data whose path crosses a
# switch whose count is not 0. Each mutation below makes a path through such a switch read as
# confirmed again, marks one that is, or loses the record, and must turn its named case red. The
# mechanics (one build-and-run cell per mutation, snapshot and restore, anchors that must resolve
# exactly once, a control that must stay green) are tests/shell/mutate_p4_capabilities.sh's,
# copied rather than shared for the reason that file gives for its helpers.
#
# NOT IN THIS GATE: the lock around the record, for the reason mutate_p4_capabilities.sh gives.
#
# Guard: on a shared workstation every cell goes through tools/build_guard/guarded_build.sh (see
# mutate_p4_capabilities.sh's header for NO_GUARD). In an isolated VM with no guard, NO_GUARD=1.
#
# Usage:  bash tests/shell/mutate_p4_path_visibility.sh            (BUILD_DIR defaults to build)
#         bash tests/shell/mutate_p4_path_visibility.sh --dry-run  # anchors only; NOT a gate result
# Exit:   0 every mutation caught and the control green, 1 a mutation survived (or the control
#         went red), 2 refused.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='P4FlowStats.*:P4PathVisibility.*:P4FlowStatsPoll.*:P4FlowStatsWire.*'
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

PATHS=src/ndt_core/power_management/P4PathVisibility.cpp
DCPM=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
HTTP=src/ndt_core/http/HttpSession.cpp
FILES=("$PATHS" "$DCPM" "$HTTP")

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
    ANCHOR_CHECK=1
fi

for f in "${FILES[@]}" tests/test_P4Capabilities.cpp tests/test_P4PathVisibility.cpp; do
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

add "V1: a null count is read as 'nothing left out'" \
    "$PATHS" \
    '            if (count.is_number_integer() && count.get<std::int64_t>() == 0)' \
    '            if (!count.is_number_integer() || count.get<std::int64_t>() == 0)' \
    'P4PathVisibility.ANullCountIsListed'

add "V2: the two hosts at the ends of the path are looked up as dpids" \
    "$PATHS" \
    '        for (std::size_t i = 1; i + 1 < path.size(); ++i)' \
    '        for (std::size_t i = 0; i < path.size(); ++i)' \
    'P4PathVisibility.TheEndpointsAreHostsAndAreNeverLookedUp'

add "V3: a switch that hides nothing is listed too" \
    "$PATHS" \
    '            if (count.is_number_integer() && count.get<std::int64_t>() == 0)
            {
                continue;
            }' \
    '            if (false)
            {
                continue;
            }' \
    'P4PathVisibility.APathWhoseSwitchesHideNothingIsAnEmptyList'

add "V4: the key is written when nobody on the path said anything" \
    "$PATHS" \
    '        if (anyRecord)' \
    '        if (anyRecord || true)' \
    'P4PathVisibility.NoRecordForAnySwitchOnThePathMeansNoKey'

add "V5: the record is read from the wrong key" \
    "$PATHS" \
    '    return p4caps::objectsUnder(payload, "flow_stats");' \
    '    return p4caps::objectsUnder(payload, "flowstats");' \
    'P4FlowStats.AReportIsCopiedVerbatimAndNullIsKept'

add "V6: hosts get the record too" \
    "$PATHS" \
    '    if (vertex.vertexType != VertexType::SWITCH)
    {
        return;
    }
    const auto it = stats.find(vertex.dpid);' \
    '    const auto it = stats.find(vertex.dpid);' \
    'P4FlowStats.AttachPutsTheRecordOnItsSwitchOnly'

add "V7: the poll never records what it read" \
    "$DCPM" \
    '        m_p4FlowStats = std::move(flowStats);' \
    '        (void)flowStats;' \
    'P4FlowStatsPoll.AnAllBmv2FabricRecordsWhatTheProxySaid'

add "V8: an unreadable proxy leaves the last record standing" \
    "$DCPM" \
    '        m_p4FlowStats = std::move(flowStats);' \
    '        if (payload.has_value())
        {
            m_p4FlowStats = std::move(flowStats);
        }' \
    'P4FlowStatsPoll.AnUnreadableProxyWithdrawsTheRecord'

add "V9: get_graph_data never puts the record on the node" \
    "$HTTP" \
    '        p4paths::attachToNode(node, graph[vd], p4FlowStats);' \
    '        // MUTANT: flow_stats never attached' \
    'P4FlowStatsWire.EachSwitchNodeCarriesItsFlowStats'

add "V10: get_detected_flow_data never marks its rows" \
    "$HTTP" \
    '    p4paths::annotateFlowRows(rows, p4FlowStatsOf(m_deviceConfigurationAndPowerManager));' \
    '    // MUTANT: rows never marked' \
    'P4FlowStatsWire.TheDetectedFlowRowsMarkAPathThroughASwitchHidingRows'

add "V11: get_detected_top_k_flow_data never marks its rows" \
    "$HTTP" \
    '    p4paths::annotateFlowRows(j, p4FlowStatsOf(m_deviceConfigurationAndPowerManager));' \
    '    // MUTANT: top-k rows never marked' \
    'P4FlowStatsWire.TheTopKRowsMarkAPathThroughASwitchHidingRows'

add "C1: control -- a comment beside the count check (must stay green)" \
    "$PATHS" \
    '            if (count.is_number_integer() && count.get<std::int64_t>() == 0)' \
    '            // control: nothing changes here
            if (count.is_number_integer() && count.get<std::int64_t>() == 0)' \
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
        # Only a file that differs is put back: touching all three after every cell would make
        # every build recompile HttpSession.cpp for mutants that never went near it.
        cmp -s "$(snap "$f")" "$f" && continue
        cp -p "$(snap "$f")" "$f"
        # cp -p restores the ORIGINAL mtime, older than the object built from the mutant, so
        # ninja would see nothing to do. touch is what actually restores the build.
        touch "$f"
    done
}
trap 'restore; rm -rf "$SNAP" "$BK"' EXIT

# cell -- ONE guard call that builds the target and, only if that succeeded, runs the suite.
# Writes $BK/build.log and $BK/run.log and sets CELL_BUILT (0/1) and CELL_RC (the suite's exit
# status, taken from the binary directly, never through a pipe). See the header for NO_GUARD.
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
    # 97 is the build failing. The guard's own refusals come back as other codes with an empty
    # run log; they are reported as "did not build" too, never as a verdict.
    if [[ $rc -eq 97 || ! -s "$BK/run.log" ]]; then
        CELL_BUILT=0
    else
        CELL_BUILT=1
    fi
    CELL_RC=$rc
}

# red_tests -- the names of the tests the last cell saw fail, space-separated; empty when all
# passed. The name pattern admits digits: every suite here is spelled P4...
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
# A filter that matches nothing runs zero tests and exits 0; every mutant would then "survive"
# loudly, but a count is cheaper to read than that.
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
