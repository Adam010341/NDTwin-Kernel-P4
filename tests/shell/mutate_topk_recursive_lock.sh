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
restore() { cp "$BK/src" "$SRC"; }
trap 'restore; rm -rf "$BK"' EXIT

SURVIVORS=0
BROKEN=0

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
report() {
    local name="$1" harness="$2" want="$3" out rc
    if [[ "$harness" == "gtest" ]]; then
        if ! cmake --build build --target test_routing_strategy -j"$(nproc)" >"$BK/build.log" 2>&1
        then
            printf '  BUILD-FAIL %-42s (the mutation did not compile -- it tested nothing)\n' "$name"
            tail -5 "$BK/build.log" | sed 's/^/             /'
            BROKEN=$((BROKEN + 1)); restore; return
        fi
        out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
        if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $want" <<<"$out"; then
            printf '  caught   %-46s (%s went red)\n' "$name" "$want"
        else
            printf '  SURVIVED %-46s (%s stayed green)\n' "$name" "$want"
            grep -E '^\[  FAILED  \]' <<<"$out" | sed 's/^/             /'
            SURVIVORS=$((SURVIVORS + 1))
        fi
    else
        # The structural guard reads the source; no build needed, which is also why it is the
        # half that can gate a deletion cheaply.
        out=$(bash "$GUARD" 2>&1); rc=$?
        if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $want" <<<"$out"; then
            printf '  caught   %-46s (%s went red)\n' "$name" "$want"
        else
            printf '  SURVIVED %-46s (%s stayed green)\n' "$name" "$want"
            grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
            SURVIVORS=$((SURVIVORS + 1))
        fi
    fi
    restore
}

echo "baseline (unmutated) must be green:"
if ! cmake --build build --target test_routing_strategy -j"$(nproc)" >"$BK/build.log" 2>&1; then
    echo "  REFUSE: the baseline does not build"; tail -20 "$BK/build.log" | sed 's/^/    /'; exit 2
fi
if ! bash "$GUARD" | tail -1 | grep -q 'all passed'; then
    echo "  REFUSE: the structural guard is not green"; bash "$GUARD" | sed 's/^/    /'; exit 2
fi
if ! "$BIN" --gtest_filter="$FILTER" | grep -q '^\[  PASSED  \]'; then
    echo "  REFUSE: the gtest cases are not green"; exit 2
fi
echo "  ok       structural guard green, $FILTER green"
echo
echo "mutations:"

# 1. The defect, verbatim: the outer shared_lock goes back above the delegating call.
mutate '    nlohmann::json flowInfo = getFlowInfoJson();' \
       '    shared_lock lock(m_flowInfoTableMutex);
    nlohmann::json flowInfo = getFlowInfoJson();'
report "the recursive shared_lock is put back" guard \
       "case 1  getTopKFlowInfoJson does not lock m_flowInfoTableMutex"

# 2. The opposite direction, and the one a lock-removal fix invites: the INNER lock is deleted
#    too. There is then no recursion and no protection, and cases 1 and 2 of the guard are both
#    satisfied. Only the control case can see it.
mutate 'FlowLinkUsageCollector::getFlowInfoJson()
{
    shared_lock lock(m_flowInfoTableMutex);
' \
       'FlowLinkUsageCollector::getFlowInfoJson()
{
'
report "the inner lock is deleted as well" guard \
       "case 3  getFlowInfoJson does take m_flowInfoTableMutex"

# 3. The delegation is dropped. Case 1 would still pass -- there is no lock -- but the function
#    no longer reads the table at all, and an inlined copy of the loop would need its own lock
#    that this guard would then never see.
mutate 'nlohmann::json flowInfo = getFlowInfoJson();' \
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
cmake --build build --target test_routing_strategy -j"$(nproc)" >/dev/null 2>&1
echo
if cmp -s "$BK/src" "$SRC"; then
    echo "baseline restored: $SRC byte-identical to the pre-run snapshot"
else
    echo "🔴 BASELINE NOT RESTORED -- a mutant is still on disk:"
    diff -u "$BK/src" "$SRC" | head -20
    exit 1
fi
echo "survivors=$SURVIVORS build-failures=$BROKEN"
[[ "$SURVIVORS" -eq 0 && "$BROKEN" -eq 0 ]]
