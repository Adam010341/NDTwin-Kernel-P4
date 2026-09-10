#!/usr/bin/env bash
#
# Mutation gate for the KNOWN-ISSUES §E-2 fix: getTopKFlowInfoJson must not recursively acquire
# m_flowInfoTableMutex.
#
# [Co-developed with claude code -- Adam]
#
# The fix is a DELETION, which is the hardest kind to gate: nothing new runs, so a suite that
# was green before is green after, and "the tests pass" says nothing about whether the line is
# gone. Every mutation below therefore puts something back, or breaks one of the two halves the
# guard rests on, and names the case that must go red.
#
# Two harnesses, because the property is split on purpose (see the header of
# tests/shell/test_topk_no_recursive_shared_lock.sh): the recursion itself is a structural
# property -- it cannot deadlock on this libstdc++, so no runtime test can see it -- while the
# bounds and the field names are behavioural and live in the gtest binary.
#
# 🔴 The harness guards its own baseline. The original is snapshotted before the first mutation,
# an EXIT trap restores it on any exit including interrupt, and the run ends by asserting the file
# is byte-identical to the snapshot. This file lives in a worktree other sessions write to.
#
# A mutation is KILLED only when the case named beside it goes red. Everything else is a
# SURVIVOR, with the reason printed: `nothing went red`, `wrong test went red`, or
# `mutant does not compile` -- the named test never ran against that mutant, so it proves
# nothing about the test. Build failures are also reported as their own sub-count, because
# they usually mean the harness needs attention rather than the test, but a run that only
# failed to build is not a clean sweep. An anchor that has moved is refused outright by
# mutate() below, which is stricter still: the run stops rather than scoring anything.
#
# The run ends with "N mutations, M survived".
#
# EXIT CODES
#   0  every mutation was killed
#   1  at least one survivor -- a real verdict: the suite is weaker than it claims
#   2  harness fault -- the run measured nothing (a red or unbuildable baseline, a mutation
#      target that is no longer unique, a baseline that was not restored, or a tree that does
#      not build or is red after the final restore)
#
# Usage:  bash tests/shell/mutate_topk_recursive_lock.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC=src/ndt_core/collection/FlowLinkUsageCollector.cpp
GUARD=tests/shell/test_topk_no_recursive_shared_lock.sh
BIN=build/bin/test_routing_strategy
FILTER='TopKFlowInfoTest*'
BK=$(mktemp -d)

cp "$SRC" "$BK/src"
# Checked on EVERY restore, not just at the end: a restore that quietly failed would leave the
# next mutation stacking on top of the previous mutant, and every verdict after it would be
# measured against a tree nobody described.
restore() {
    cp "$BK/src" "$SRC"
    cmp -s "$BK/src" "$SRC" ||
        harness_fault "$SRC did not come back byte-identical -- the next mutation would stack on this one"
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
BROKEN=0

# A harness fault means the run measured nothing: it is never a survivor count and never a 1.
harness_fault() {
    printf '\n🔴 HARNESS FAULT: %s\n' "$1" >&2
    printf '   This run measured nothing: it is not a pass and not a survivor count.\n' >&2
    exit 2
}

mutate() {   # $1 = literal to find, $2 = literal replacement
    local from="$1" to="$2" n
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$SRC")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 REFUSE: the mutation target appears $n times in $SRC, expected exactly 1"
        echo "     target: $from"
        exit 2
    fi
    FROM="$from" TO="$to" perl -0777 -pi -e 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' "$SRC"
}

# $1 = mutation name, $2 = harness (guard|gtest), $3 = case that must go red
#
# A mutation is KILLED only when the case named here goes red. Everything else is a SURVIVOR
# with a reason, INCLUDING a mutant that does not compile: the named test never ran against it,
# so it says nothing about the test. Build failures stay broken out as a sub-count because they
# are usually a harness problem rather than a weak test, but they are survivors either way, and
# a run that only failed to build must never be reported as a clean sweep.
report() {
    local name="$1" harness="$2" want="$3" out rc others
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$harness" == "gtest" ]]; then
        if ! cmake --build build --target test_routing_strategy -j"$(nproc)" >"$BK/build.log" 2>&1
        then
            printf '  SURVIVED %-46s (mutant does not compile -- it tested nothing)\n' "$name"
            tail -5 "$BK/build.log" | sed 's/^/             /'
            BROKEN=$((BROKEN + 1)); SURVIVORS=$((SURVIVORS + 1)); restore; return
        fi
        out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
        others=$(grep -E '^\[  FAILED  \]' <<<"$out")
        if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $want" <<<"$out"; then
            printf '  caught   %-46s (%s went red)\n' "$name" "$want"
        elif [[ -n "$others" ]]; then
            printf '  SURVIVED %-46s (wrong test went red -- %s did not)\n' "$name" "$want"
            sed 's/^/             /' <<<"$others"
            SURVIVORS=$((SURVIVORS + 1))
        else
            # An aborted binary and a green one look the same to a grep for "[  FAILED  ]",
            # which is why a non-zero rc with no failure line is scored as no evidence at all
            # rather than as the named case going red. See the note on mutation 4 below.
            printf '  SURVIVED %-46s (nothing went red -- %s proves nothing)\n' "$name" "$want"
            [[ "$rc" -ne 0 ]] && printf '             (the binary exited %s without naming a test)\n' "$rc"
            SURVIVORS=$((SURVIVORS + 1))
        fi
    else
        # The structural guard reads the source; no build needed, which is also why it is the
        # half that can gate a deletion cheaply.
        out=$(bash "$GUARD" 2>&1); rc=$?
        others=$(grep -E '^  FAILED' <<<"$out")
        if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $want" <<<"$out"; then
            printf '  caught   %-46s (%s went red)\n' "$name" "$want"
        elif [[ -n "$others" ]]; then
            printf '  SURVIVED %-46s (wrong test went red -- %s did not)\n' "$name" "$want"
            sed 's/^/             /' <<<"$others"
            SURVIVORS=$((SURVIVORS + 1))
        else
            printf '  SURVIVED %-46s (nothing went red -- %s proves nothing)\n' "$name" "$want"
            [[ "$rc" -ne 0 ]] && printf '             (the guard exited %s without naming a case)\n' "$rc"
            grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
            SURVIVORS=$((SURVIVORS + 1))
        fi
    fi
    restore
}

echo "baseline (unmutated) must be green:"
if ! cmake --build build --target test_routing_strategy -j"$(nproc)" >"$BK/build.log" 2>&1; then
    echo "  REFUSE: the baseline does not build"; tail -20 "$BK/build.log" | sed 's/^/    /'
    harness_fault "the unmutated tree does not build -- no mutation was applied"
fi
if ! bash "$GUARD" | tail -1 | grep -q 'all passed'; then
    echo "  REFUSE: the structural guard is not green"; bash "$GUARD" | sed 's/^/    /'
    harness_fault "the structural guard is already red -- no mutation was applied"
fi
if ! "$BIN" --gtest_filter="$FILTER" | grep -q '^\[  PASSED  \]'; then
    echo "  REFUSE: the gtest cases are not green"
    harness_fault "the gtest cases are already red -- no mutation was applied"
fi
echo "  ok       structural guard green, $FILTER green"
echo
echo "mutations:"

# 1. The defect, verbatim: the outer shared_lock goes back above the delegating call.
mutate '    nlohmann::json flowInfo = getFlowInfoJson(filter);' \
       '    shared_lock lock(m_flowInfoTableMutex);
    nlohmann::json flowInfo = getFlowInfoJson(filter);'
report "the recursive shared_lock is put back" guard \
       "case 1  getTopKFlowInfoJson does not lock m_flowInfoTableMutex"

# 2. The opposite direction, and the one a lock-removal fix invites: the INNER lock is deleted
#    too. There is then no recursion and no protection, and cases 1 and 2 of the guard are both
#    satisfied. Only the control case can see it.
mutate 'FlowLinkUsageCollector::getFlowInfoJson(sflow::FlowLivenessFilter filter)
{
    shared_lock lock(m_flowInfoTableMutex);
' \
       'FlowLinkUsageCollector::getFlowInfoJson(sflow::FlowLivenessFilter filter)
{
'
report "the inner lock is deleted as well" guard \
       "case 3  getFlowInfoJson does take m_flowInfoTableMutex"

# 3. The delegation is dropped. Case 1 would still pass -- there is no lock -- but the function
#    no longer reads the table at all, and an inlined copy of the loop would need its own lock
#    that this guard would then never see.
mutate 'nlohmann::json flowInfo = getFlowInfoJson(filter);' \
       'nlohmann::json flowInfo = nlohmann::json::array();'
report "getTopKFlowInfoJson stops calling getFlowInfoJson" guard \
       "case 2  getTopKFlowInfoJson still calls getFlowInfoJson()"

# 4. The two field names drift apart. The comparator's `a` is a CONST json&, so this reaches
#    nlohmann's const operator[], which neither inserts nor throws -- it is JSON_ASSERT(found),
#    i.e. abort(), and under -DNDEBUG (this repo's Release flags) an out-of-range dereference.
#
#    🔴 That is why TheSortKeyIsAFieldTheRowsActuallyCarry is declared first in its file and does
#    its check before calling. On the first run of this gate the mutation came out as SURVIVED --
#    not because anything passed, but because the process aborted in an earlier case and gtest
#    printed no failure line for the case named here. An aborted binary and a green one look the
#    same to a grep for "[  FAILED  ]".
mutate 'j["estimated_packet_rate_in_the_proceeding_1sec_timeslot"] =' \
       'j["estimated_packet_rate_renamed_by_someone"] ='
report "the sort key is renamed on the emitter side" gtest \
       "TopKFlowInfoTest.TheSortKeyIsAFieldTheRowsActuallyCarry"

# 5. The k bound stops applying. Not written as "remove std::min", which would index past the end
#    of the array -- that is undefined behaviour and a crash proves nothing about a test.
mutate 'for (int i = 0; i < std::min(k, static_cast<int>(flowInfo.size())); ++i)' \
       'for (int i = 0; i < static_cast<int>(flowInfo.size()); ++i)'
report "top-k ignores k and returns the whole table" gtest \
       "TopKFlowInfoTest.AKOfZeroOrLessIsAnEmptyArrayRatherThanTheWholeTable"

restore
echo
if cmp -s "$BK/src" "$SRC"; then
    echo "baseline restored: $SRC byte-identical to the pre-run snapshot"
else
    echo "🔴 BASELINE NOT RESTORED -- a mutant is still on disk:"
    diff -u "$BK/src" "$SRC" | head -20
    harness_fault "the baseline was not restored -- a mutant is still on disk"
fi
# The source being back is not the same as the BINARY being back: without this rebuild the
# tree still tests the last mutant, and without checking it we would not know.
if ! cmake --build build --target test_routing_strategy -j"$(nproc)" >"$BK/build.log" 2>&1; then
    tail -20 "$BK/build.log" | sed 's/^/    /'
    harness_fault "the tree does not build after the final restore"
fi
if ! "$BIN" --gtest_filter="$FILTER" >"$BK/after.log" 2>&1; then
    echo "🔴 THE SUITE IS RED AFTER RESTORE -- a mutant is still built in. Do NOT commit."
    grep -E '^\[  FAILED  \]' "$BK/after.log" | sed 's/^/    /'
    harness_fault "the suite is red after the final restore"
fi
echo "after restore: $FILTER green again"

echo
if ((BROKEN > 0)); then
    printf '  of which %d did not compile\n' "$BROKEN"
fi
printf '%d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
((SURVIVORS == 0)) || exit 1
exit 0
