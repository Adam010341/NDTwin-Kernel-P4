#!/usr/bin/env bash
#
# Mutation gate for tests/test_TopologyPollRound.cpp (KNOWN-ISSUES A-2, third uncovered item).
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. This applies each mutation, rebuilds,
# and records WHICH test went red -- not merely that something did. The identity matters here more
# than usual, because the A-2 round suite has two halves that can be green for opposite reasons:
#
#   - TopologyPollRound.*         the rules: how a round is classified, and when it earns a line
#   - TopologyPollRoundWiring.*   what a real monitor records and writes to the log
#
# A mutation aimed at the classification that only reddens a wiring test (or the reverse) means the
# gate fires without establishing what it claims.
#
# 🔴 The mutation that matters most is #5. "" (the request did not come back) and "[]" (the fabric
# genuinely has no links) are different answers, and every OVS boot produces the second one until
# LLDP finishes. #5 tightens the silence test so "[]" reads as no answer, which turns a healthy
# boot into a reported wedge. If nothing goes red for it, the fix has installed a false-alarm
# generator and the suite cannot see it.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. The baseline is the WORKING TREE, not HEAD, so this
# runs against an uncommitted fix.
#
# One deliberate difference from tests/shell/mutate_f6_stale_table_carry_forward.sh, which is
# otherwise this script's model: there, a mutant that fails to compile is discounted from the
# mutation count with a warning. Here it is a SURVIVOR. A mutation that never reached the compiler
# established nothing about the tests, and discounting it lets a mutation table rot into one that
# silently tests less every month -- the same failure the anchor-uniqueness check exists to catch.
# The same rule covers an anchor that has moved and the wrong test going red. None of the three
# aborts the remaining mutations.
#
# Usage:  tests/shell/mutate_a2_poll_round.sh
#         BUILD_DIR=build-asan tests/shell/mutate_a2_poll_round.sh
#         ANCHOR_CHECK=1 tests/shell/mutate_a2_poll_round.sh   # anchors only; NOT a gate result
# Assumes: cwd is the repo root, ${BUILD_DIR:-build} is already configured (ninja).
# Exit:    0 all mutations caught, 1 a mutation survived, 2 refused (baseline red / not restored /
#          anchor-check mode, which never produces a verdict).
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='TopologyPollRound.*:TopologyPollRoundWiring.*'

HDR=include/ndt_core/collection/TopologyAndFlowMonitor.hpp
SRC=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
FILES=("$HDR" "$SRC")

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
    ANCHOR_CHECK=1
fi

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal> -- prints how many times the literal occurs. Shown for every
# mutation: an anchor that matches twice silently mutates the wrong site, and one that matches
# zero times makes the mutation a no-op that then "passes".
#
# python, not `grep -c -F`: grep splits a multi-line -F pattern into several patterns and counts
# matching LINES, so a two-line anchor would report 2 and be rejected as "not unique".
anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# --- the mutation table -------------------------------------------------------------------------
# Declared once so the anchor check and the gate cannot disagree about what is being tested.
# Fields are NUL-free and tab-separated: label, file, anchor, replacement, expected test,
# declared-uncovered reason ("" when the mutation must be caught).

MUT_LABEL=(); MUT_FILE=(); MUT_ANCHOR=(); MUT_REPL=(); MUT_EXPECT=(); MUT_DECLARED=()
add() {
    MUT_LABEL+=("$1"); MUT_FILE+=("$2"); MUT_ANCHOR+=("$3")
    MUT_REPL+=("$4");  MUT_EXPECT+=("$5"); MUT_DECLARED+=("${6:-}")
}

# 1. A round missing one endpoint reports itself Complete: the mixed-age graph is applied and the
#    log says nothing, which is the state this whole ticket is about.
add "1. two answers out of three count as a complete round" \
    "$SRC" \
    '    if (answered == 3)' \
    '    if (answered >= 2)' \
    'TopologyPollRound.OneSilentEndpointIsPartial'

# 2. The other end of the same boundary: a single answer is written off as total silence, so the
#    one reply that DID land is applied without the round admitting it was partial.
add "2. one answer out of three counts as silence" \
    "$SRC" \
    '    if (answered == 0)' \
    '    if (answered <= 1)' \
    'TopologyPollRound.OnlyOneAnsweredIsStillPartial'

# 3. A healthy round is reported partial: a warning on every poll of a control plane that is
#    working, which is how an operator learns to ignore the warning.
add "3. a complete round is classified partial" \
    "$SRC" \
    '        return PollRoundKind::Complete;' \
    '        return PollRoundKind::Partial;' \
    'TopologyPollRound.AllThreeAnsweredIsComplete'

# 4. A fully wedged control plane is reported partial, so both this line and the warning beside
#    m_topologyFetchFailures fire for one fault and the two faults stop being distinguishable.
add "4. a fully silent round is classified partial" \
    "$SRC" \
    '        return PollRoundKind::Silent;' \
    '        return PollRoundKind::Partial;' \
    'TopologyPollRound.NoneAnsweredIsSilent'

# 5. 🔴 THE ONE THAT INVENTS A FAULT. "[]" is two bytes and a complete answer; size() > 2 makes a
#    zero-link fabric read as an unanswered endpoint. Every OVS boot reports "[]" from /links
#    until LLDP has discovered anything, so this turns normal startup into a logged wedge -- an
#    unexpected case dressed up as a deliberate one, which is the error mode this repo has
#    already recorded once.
add "5. an empty JSON list is treated as no answer" \
    "$SRC" \
    '    const bool linksAnswered = !linksBody.empty();' \
    '    const bool linksAnswered = linksBody.size() > 2;' \
    'TopologyPollRoundWiring.AnEmptyJsonListIsAnAnswerNotSilence'

# 6. The edge-trigger is aimed at the wrong predecessor: a control plane that stays partial writes
#    a line every poll forever, and the FIRST partial round writes none. Both halves of the
#    property break, in opposite directions, from one changed enumerator.
add "6. the edge-trigger fires on the wrong previous state" \
    "$SRC" \
    '    return current == PollRoundKind::Partial && previous != PollRoundKind::Partial;' \
    '    return current == PollRoundKind::Partial && previous != PollRoundKind::NotYetPolled;' \
    'TopologyPollRoundWiring.APartialRoundWritesTheStableTokenOncePerEpisode'

# 7. The line is attached to the silent round instead of the partial one, so the fault that
#    already has a warning gets a second one and the fault that had none still has none.
add "7. the line is announced for silent rounds instead of partial ones" \
    "$SRC" \
    '    return current == PollRoundKind::Partial && previous != PollRoundKind::Partial;' \
    '    return current == PollRoundKind::Silent && previous != PollRoundKind::Silent;' \
    'TopologyPollRoundWiring.ASilentRoundDoesNotWriteThePartialToken'

# 8. The log line survives but the readable state does not, so anything holding the monitor -- a
#    test, or a freshness field on /ndt/get_graph_data later -- is back to guessing from the log.
#    The assignment is the only write; the read above it keeps m_lastPollRoundKind used, so the
#    mutant still compiles under -Werror.
add "8. the round kind is never recorded" \
    "$SRC" \
    '    m_lastPollRoundKind = kind;' \
    '    // MUTANT: the round kind is never recorded' \
    'TopologyPollRoundWiring.TheRoundKindIsRecordedForReading'

# 9. The token is renamed. Every deployed scraper and runbook grep breaks silently -- and this is
#    the mutation the obvious version of the test cannot catch, because a test that compares the
#    log against kPartialRoundToken follows the rename and stays green. The suite asserts the
#    literal spelling separately for exactly this.
add "9. the stable grep token is renamed" \
    "$HDR" \
    '    static constexpr const char* kPartialRoundToken = "topology-round-partial";' \
    '    static constexpr const char* kPartialRoundToken = "topology-round-changed";' \
    'TopologyPollRound.TheStableTokenIsTheOneTheRunbookGreps'

# 10. DECLARED-UNCOVERED. Run, reported, and NOT counted as a survivor -- with the reason stated,
#     because an exemption that is not written down is indistinguishable from a gap nobody
#     noticed. The call sits between three live curls in pollControlPlaneTopology; reaching it
#     needs a control plane, which is the same reason buildTopologyFetchCommand was extracted
#     rather than tested in place. Closing it is a live step, not a unit test: see §6 of the A-2
#     findings (stall a listener on :8080, watch for the token in kernel.log).
add "10. the poll never calls the round bookkeeping at all" \
    "$SRC" \
    '    noteAndAnnouncePollRound(switchesStr, hostsStr, linksStr);' \
    '    // MUTANT: the poll no longer records or announces its round' \
    'TopologyPollRoundWiring.TheRoundKindIsRecordedForReading' \
    'the call site needs three live curls and a control plane; no gtest can reach it'

CTRL_FILE="$SRC"
CTRL_ANCHOR='    const PollRoundKind kind = classifyPollRound(switchesAnswered, hostsAnswered, linksAnswered);'
CTRL_REPL='    // MUTANT: a comment, and nothing else.
    const PollRoundKind kind = classifyPollRound(switchesAnswered, hostsAnswered, linksAnswered);'

# --- anchor check (never a verdict) -------------------------------------------------------------

if [[ "$ANCHOR_CHECK" != "0" ]]; then
    echo "================================================================"
    echo " ANCHOR CHECK ONLY -- THIS IS NOT A GATE RESULT."
    echo " Nothing was built, no mutation was applied, no test was run."
    echo " The exit code is 2 on purpose so this can never be mistaken for"
    echo " a passing gate. Run without ANCHOR_CHECK/--dry-run for a verdict."
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
    n=$(anchor_count "$CTRL_FILE" "$CTRL_ANCHOR")
    if [[ "$n" -eq 1 ]]; then
        printf '  ok    %s  (negative control)\n' "$n"
    else
        printf '  🔴 %s matches in %s  (negative control)\n' "$n" "$CTRL_FILE"
        broken=$((broken + 1))
    fi
    if [[ "$broken" -eq 0 ]]; then
        echo "ANCHORS: ok -- all ${#MUT_LABEL[@]} mutations plus the control resolve to one site each."
    else
        echo "ANCHORS: BROKEN -- $broken anchor(s) have moved. Fix them before running the gate."
    fi
    echo "(still exiting 2: an anchor check is not a gate result)"
    exit 2
fi

# --- baseline snapshot --------------------------------------------------------------------------

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

    if ! build; then
        # A mutant that does not compile establishes nothing about the tests, so it is not counted
        # as caught -- but it is not a free pass either: the mutation it was meant to make never
        # happened, and that is a survivor, not a warning.
        echo "  🔴 MUTANT DOES NOT COMPILE -- the behaviour it was aimed at is still untested."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -8 | sed 's/^/    /'
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
        if [[ -n "$declared" ]]; then
            printf '  ⚠️  declared uncovered, yet something went red. The exemption is stale: %s\n' \
                "$declared"
        fi
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# --- baseline -----------------------------------------------------------------------------------

echo "A-2 poll-round mutation gate"
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

# --- mutations ----------------------------------------------------------------------------------

for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_FILE[$i]}" "${MUT_ANCHOR[$i]}" \
           "${MUT_REPL[$i]}" "${MUT_EXPECT[$i]}" "${MUT_DECLARED[$i]}"
done

# --- negative control ---------------------------------------------------------------------------
# A gate that reddens on anything is not a gate. A comment-only edit must leave the suite green;
# if this goes red the suite is a change detector, not a specification.

printf '\n=== NEGATIVE CONTROL: comment-only edit must stay GREEN ===\n'
n=$(anchor_count "$CTRL_FILE" "$CTRL_ANCHOR")
printf '  anchor occurrences: %s in %s\n' "$n" "$CTRL_FILE"
if [[ "$n" -ne 1 ]]; then
    echo "  🔴 control anchor is not unique ($n matches) -- the control proves nothing."
    SURVIVORS=$((SURVIVORS + 1))
else
    ANCHOR="$CTRL_ANCHOR" REPL="$CTRL_REPL" python3 - "$CTRL_FILE" <<'PY'
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

# --- byte-identity and verdict ------------------------------------------------------------------

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
