#!/usr/bin/env bash
#
# Mutation gate for tests/test_StaleTableCarryForward.cpp (KNOWN-ISSUES F-6).
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. This applies each mutation, rebuilds,
# and records WHICH test went red -- not merely that something did. The identity matters: the
# F-6 suite has two halves that can be green for opposite reasons, and a mutation aimed at the
# merge rule that only reddens a wiring test (or the reverse) means the gate fires without
# establishing what it claims.
#
#   - StaleTableCarryForward.*        the rule: given a poll and a previous cache, what comes out
#   - StaleTableCarryForwardWiring.*  the wiring: what get_switch_openflow_table_entries serves
#   - PollPolicy.*                    which switches may enter the unread list at all
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. The baseline is the WORKING TREE, not HEAD, so
# this runs against an uncommitted fix. Restore is `cp -p` followed by `touch`: cp -p puts the
# ORIGINAL mtime back, which is older than the object built from the mutant, so ninja would decide
# there was nothing to do and the NEXT mutation would be scored against the previous mutant's
# binary. The run rebuilds once more after the final restore and refuses to finish green if the
# restored tree does not build or is not byte-identical.
#
# 🔴 Anything that stops the tests from RUNNING counts as SURVIVED, never as a warning: an anchor
# that no longer matches, a mutation that cannot be applied, and a mutant that does not compile.
# In all three the targeted behaviour is exactly as unproven as if the suite had stayed green, and
# scoring them softly lets the gate shrink silently as the code moves under it.
#
# Usage:  tests/shell/mutate_f6_stale_table_carry_forward.sh
#         BUILD_DIR=build-asan tests/shell/mutate_f6_stale_table_carry_forward.sh
# Assumes: cwd is the repo root, ${BUILD_DIR:-build} is already configured (ninja).
# Exit:    0 all mutations caught
#          1 a mutation survived -- including one that failed to build or whose anchor moved
#          2 refused (baseline red, tree unbuildable, or a source not restored byte-identically)
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='StaleTableCarryForward*:PollPolicy.*'

HDR=include/ndt_core/power_management/StaleTableCarryForward.hpp
SRC=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
FILES=("$HDR" "$SRC")

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -d "$BUILD_DIR" ]] || { echo "REFUSE: $BUILD_DIR is not configured. cmake -B $BUILD_DIR -G Ninja" >&2; exit 2; }

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done
restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "$(snap "$f")" "$f"
        # cp -p puts the ORIGINAL mtime back, which is older than the object built from the
        # mutant -- ninja would then see nothing to do and the next run would test the mutant
        # while the source on disk is pristine. touch is what actually restores the build.
        touch "$f"
    done
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
DECLARED=0

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal> -- prints how many times the literal occurs. Shown for every
# mutation: an anchor that matches twice silently mutates the wrong site, and one that matches
# zero times makes the mutation a no-op that then "passes".
#
# python, not `grep -c -F`: grep splits a multi-line -F pattern into several patterns and counts
# matching LINES, so a two-line anchor would report 2 and be rejected as "not unique". Two of the
# mutations below span lines.
anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

build() { cmake --build "$BUILD_DIR" --target "$TARGET" >/dev/null 2>&1; }

# red_tests -- prints the space-separated names of the tests that failed. rc is captured from the
# binary directly, never through a pipe.
red_tests() {
    local out rc
    out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\[  FAILED  \] \([A-Za-z]*\.[A-Za-z]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <file> <anchor> <replacement> <expected-test> [declared-uncovered-reason]
mutate() {
    local label="$1" file="$2" anchor="$3" repl="$4" expected="$5" declared="${6:-}"
    local n; n=$(anchor_count "$file" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1)); restore; return
    fi
    MUTATIONS=$((MUTATIONS + 1))

    ANCHOR="$anchor" REPL="$repl" python3 - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
    if [[ $? -ne 0 ]]; then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    if ! build; then
        # A SURVIVOR, not a warning. The test never ran, so the behaviour this mutation targets
        # is exactly as unproven as if the suite had stayed green -- and scoring it as a warning
        # lets the gate shrink silently: a later edit that stops a mutation compiling would
        # quietly remove it from the run while the script still reported "0 survived".
        # Declared-uncovered does not exempt this either: "cannot be observed by a gtest" is a
        # statement about a mutation that BUILT and RAN.
        echo "  🔴 MUTANT DOES NOT COMPILE -- the test never ran, so this counts as SURVIVED."
        echo "     Fix the mutation (or the anchor); a mutation that cannot build proves nothing."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | grep -E 'error|Error' | head -5 |
            sed 's/^/       /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        if [[ -n "$declared" ]]; then
            printf '  ⚪ SURVIVED AS DECLARED -- %s\n' "$declared"
            DECLARED=$((DECLARED + 1)); MUTATIONS=$((MUTATIONS - 1))
        else
            echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
            SURVIVORS=$((SURVIVORS + 1))
        fi
    elif grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# --- baseline --------------------------------------------------------------------------------

echo "F-6 mutation gate"
echo "  build dir : $BUILD_DIR"
echo "  target    : $TARGET"
echo "  filter    : $FILTER"
for f in "${FILES[@]}"; do printf '  baseline  : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"; done
echo
echo "baseline (unmutated) must build and be green:"
if ! build; then
    echo "  REFUSE: the unmutated tree does not build. Nothing below would mean anything."
    cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -20 | sed 's/^/    /'
    exit 2
fi
BASE_RED=$(red_tests)
if [[ -n "$BASE_RED" ]]; then
    echo "  REFUSE: baseline is RED before any mutation."
    printf '    red: %s\n' "$BASE_RED"
    exit 2
fi
"$BIN" --gtest_filter="$FILTER" 2>&1 | tail -3 | sed 's/^/    /'
echo "  ok       baseline green"

# --- mutations -------------------------------------------------------------------------------

# 1. THE ORIGINAL DEFECT, at the wiring: the worker stops carrying anything forward, so the
#    replacement below erases every switch this poll could not read. This is what the tree did
#    before the fix. It must redden the WIRING tests -- the rule-level tests call the helper
#    directly and cannot see a call-site change, which is exactly why the wiring tests exist.
mutate "1. carry-forward disabled at the call site (back to erase)" \
    "$SRC" \
    '                                                         fetched.unread,' \
    '                                                         {},' \
    'StaleTableCarryForwardWiring.TheServedCacheKeepsASwitchWhoseReadFailed'

# 2. The table is carried but never marked: a stale answer served as though it were current.
#    The other half of the dishonesty, and invisible to any test that only checks presence.
mutate "2. stale_since is never set" \
    "$HDR" \
    '        entry[kStaleSinceField] = staleSince;' \
    '        // MUTANT: stale_since not set' \
    'StaleTableCarryForward.TheCarriedTableSaysItIsStaleAndWhy'

# 3. THE ONE THAT TURNS THIS FIX INTO F-4/F-16. isPollableForFlowTable stops excluding a switch
#    that is down, so a dead switch is polled, fails, enters unread, and has its flow table kept
#    alive for as long as it stays dead -- with a stale_since that reads like a transport fault.
#    Must be caught by the test that distinguishes "never asked" from "asked and unanswered".
mutate "3. a down switch is polled, so it can enter the unread list" \
    "$SRC" \
    '    return props.vertexType == VertexType::SWITCH && props.isUp;' \
    '    return props.vertexType == VertexType::SWITCH;' \
    'PollPolicy.ADownSwitchIsNeverPolledSoItCanNeverEnterTheUnreadList'

# 4. stale_polls stops accumulating: a switch unreadable for an hour reports one poll of
#    staleness, and any consumer thresholding on it never fires.
mutate "4. stale_polls never accumulates" \
    "$HDR" \
    '        entry[kStalePollsField] = priorPolls + 1;' \
    '        entry[kStalePollsField] = 1;' \
    'StaleTableCarryForward.StaleSinceNamesTheFirstFailedPollNotTheLatest'

# 5. A switch that has never been read is omitted instead of listed -- F-6 half-fixed, which is
#    the tempting version: the common case looks right and the boot-time case stays silent.
#    Both lines go, so the mutant has no unreachable statement after the `continue` -- an
#    -Werror build would reject that, and a mutant that does not compile is scored SURVIVED.
mutate "5. a never-read switch is omitted instead of listed" \
    "$HDR" \
    '            entry = nlohmann::json{{"dpid", u.dpid}, {"flows", nlohmann::json::object()}};
            entry[kNeverReadField] = true;' \
    '            continue; // MUTANT: nothing to carry, so say nothing' \
    'StaleTableCarryForward.ASwitchNeverReadIsStillListedAndSaysSo'

# 6. A stale copy overwrites a switch that was read successfully this poll: memory beating
#    measurement, the worst direction available to this code.
mutate "6. a stale copy no longer yields to a fresh read" \
    "$HDR" \
    '        if (ndt_detail::findSwitchIndex(fresh, u.dpid) != fresh.size())' \
    '        if (false)' \
    'StaleTableCarryForward.AFreshReadIsNeverOverwrittenByAStaleCopy'

# 7. The markers are written but the T-11 filter eats them on the way out, so the endpoint serves
#    a stale table with nothing saying so -- the fix reverted at the last possible moment.
mutate "7. the T-11 filter rebuilds the switch object and drops the markers" \
    "$SRC" \
    '    stripUnprogrammedEntries(out, m_isProgrammed);' \
    '    stripUnprogrammedEntries(out, m_isProgrammed); for (auto& s : out) { if (s.is_object()) { s.erase(kStaleSinceField); s.erase(kLastErrorField); } }' \
    'StaleTableCarryForwardWiring.TheServedCacheKeepsASwitchWhoseReadFailed'

# --- declared-uncovered ----------------------------------------------------------------------
# Run, reported, and NOT counted as a survivor -- with the reason stated, because an exemption
# that is not written down is indistinguishable from a gap nobody noticed.

# 8. The merge reads the cache before taking the write lock. Semantically identical in a
#    single-threaded test and detectable only by a concurrent writer, so no gtest here can catch
#    it. Closing it needs ThreadSanitizer (-fsanitize=thread) with test_FlowTableConcurrency.cpp
#    driving updateOpenFlowTables against applyFetchedTables, which is a separate ticket.
#    The copy is actually USED as the merge's `previous`, so the mutant has no unused variable to
#    trip -Werror on, and the change is the real semantic one: a concurrent updateOpenFlowTables
#    write landing in the gap is read from the pre-lock copy and then overwritten.
mutate "8. the merge reads the cache outside the write lock" \
    "$SRC" \
    '    std::lock_guard<std::shared_mutex> lock(m_openflowTablesMutex);

    const std::size_t carried = carryForwardUnreadTables(fetched.tables,
                                                         m_cachedOpenFlowTables,' \
    '    const json previousUnlocked = m_cachedOpenFlowTables;
    std::lock_guard<std::shared_mutex> lock(m_openflowTablesMutex);

    const std::size_t carried = carryForwardUnreadTables(fetched.tables,
                                                         previousUnlocked,' \
    'StaleTableCarryForwardWiring.TheServedCacheKeepsASwitchWhoseReadFailed' \
    'single-threaded tests cannot see a lock-ordering change; needs TSan + a concurrent writer'

# --- negative control ------------------------------------------------------------------------
# A gate that reddens on anything is not a gate. A comment-only edit must leave the suite green;
# if this goes red the suite is a change detector, not a specification.

printf '\n=== NEGATIVE CONTROL: comment-only edit must stay GREEN ===\n'
CTRL_ANCHOR='    std::size_t carried = 0;'
n=$(anchor_count "$HDR" "$CTRL_ANCHOR")
printf '  anchor occurrences: %s in %s\n' "$n" "$HDR"
if [[ "$n" -ne 1 ]]; then
    echo "  🔴 control anchor is not unique ($n matches) -- the control proves nothing."
    SURVIVORS=$((SURVIVORS + 1))
else
    ANCHOR="$CTRL_ANCHOR" REPL="    // MUTANT: a comment, and nothing else.
    std::size_t carried = 0;" python3 - "$HDR" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace(os.environ["ANCHOR"], os.environ["REPL"], 1))
PY
    if ! build; then
        echo "  🔴 a comment broke the build -- the anchor landed somewhere it should not have."
        SURVIVORS=$((SURVIVORS + 1))
    else
        ctrl_red=$(red_tests)
        if [[ -z "$ctrl_red" ]]; then
            echo "  ✅ green: the suite does not react to a comment"
        else
            printf '  🔴 A COMMENT TURNED THE SUITE RED: %s\n' "$ctrl_red"
            echo "     These tests are change detectors, not a specification."
            SURVIVORS=$((SURVIVORS + 1))
        fi
    fi
    restore
fi

# --- byte-identity and verdict ---------------------------------------------------------------

restore
printf '\n--- baseline restored? ---\n'
ok=1
for f in "${FILES[@]}"; do
    if cmp -s "$(snap "$f")" "$f"; then
        printf '  byte-identical  %s\n' "$f"
    else
        printf '  🔴 NOT RESTORED: %s -- do NOT commit\n' "$f"; ok=0
    fi
done
[[ "$ok" == 1 ]] || exit 2

if ! build; then
    echo "🔴 THE TREE DOES NOT BUILD AFTER RESTORE -- do NOT commit."; exit 2
fi
after_red=$(red_tests)
if [[ -n "$after_red" ]]; then
    printf '🔴 THE SUITE IS RED AFTER RESTORE: %s\n' "$after_red"
    echo "   A mutant is still built in. Do NOT commit."; exit 2
fi
echo "  suite green again after restore"

printf '\n%s mutations, %s survived' "$MUTATIONS" "$SURVIVORS"
[[ "$DECLARED" -gt 0 ]] && printf ' (+%s declared-uncovered, listed above)' "$DECLARED"
printf '\n'
[[ "$SURVIVORS" -eq 0 ]]
