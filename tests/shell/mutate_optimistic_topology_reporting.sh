#!/usr/bin/env bash
#
# Mutation gate for tests/test_OptimisticTopologyReporting.cpp
# (doc/KNOWN-ISSUES.md §C rows F-4, F-14 and F-16 -- the "twin always reports optimistically"
# family; by code, not by line: the numbers this header carried had all drifted by 2026-09-11).
#
# [Co-developed with claude code -- Adam]
#
# Usage:  bash tests/shell/mutate_optimistic_topology_reporting.sh
#         BUILD_DIR=build-asan bash tests/shell/mutate_optimistic_topology_reporting.sh
#
# Repo root is the cwd; ${BUILD_DIR:-build} must already be configured (this script never runs
# cmake configure -- a gate that reconfigures someone's build directory is a gate that can lose
# their flags).
#
# 🔴 Guards its own baseline. The two sources are snapshotted before the first mutation, an EXIT
# trap restores them on ANY exit including interrupt, and the run ends by asserting both files are
# byte-identical to the snapshot. These files live in a worktree other sessions write to, so a
# mutant left on disk is not a tidiness problem -- it is a defect someone else would inherit.
#
# ---------------------------------------------------------------------------------------------
# WHAT "SURVIVED" MEANS HERE, AND THE ONE PLACE IT IS EXPECTED
#
# Most mutations below name the tests that must go red. Three do not, and saying why is the whole
# reason this header is long.
#
# The F-4 repair is three guards on one function: an up-front rejection of a hosts entry whose
# address belongs to a switch, plus a direction check on each of the two edge lookups. They are
# three routes to one edge, not one check written three times -- but they are NOT independently
# observable, and a gate that pretended otherwise would be lying. Any input that reaches a
# direction check is, by construction, an input the up-front rejection has already dropped: an
# address that matches a switch-to-switch edge IS a switch's management address. So removing any
# ONE of the three changes no observable state.
#
# This gate therefore asserts the property that is actually true, and it is a stronger statement
# than "each guard is load-bearing":
#
#   * each guard ALONE  -> the suite must stay GREEN   (expected; a red here is an anomaly and is
#                                                       counted in BROKEN, not waved through)
#   * each PAIR with the up-front rejection -> named tests must go RED
#
# The redundancy is deliberate defence in depth: the guard that is dead today is what holds when a
# fourth route into these lookups appears. What must never happen is a reader believing a
# single-guard mutation was tested and killed.
#
# A MUTANT THAT NEVER RAN IS A SURVIVOR. There are two ways for that to happen and both are
# counted as survivors, not as warnings:
#
#   * it did not compile -- this project builds with -Werror (CMakeLists.txt:51-53), so any mutant
#     that trips a warning stops the build;
#   * its anchor no longer matches -- the source moved and the literal in this file did not.
#
# In both cases the named test stayed green because the code it was pointed at was never changed.
# Counting that as anything softer than a survivor would let the gate report a clean run over
# behaviour nothing had checked. A drifted anchor is recorded and the run continues rather than
# aborting, so one stale string cannot take the remaining mutations with it.
# ---------------------------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

BUILD_DIR="${BUILD_DIR:-build}"
BIN="$BUILD_DIR/bin/test_routing_strategy"
SRC=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
HDR=include/ndt_core/collection/TopologyAndFlowMonitor.hpp
SUITE='OptimisticTopologyReportingTest'
FILTER="$SUITE.*"

# The nine cases in the suite, so a mutation can be checked against all of them rather than only
# against the ones it was expected to touch.
ALL_TESTS=(
    ASwitchLearnedAsAHostDoesNotResurrectASwitchLink
    ARealHostEntryStillRaisesItsOwnTwoEdges
    HostFacingEdgesOfAnUnreachableSwitchGoDownWithAReason
    AHostBehindAnUnreachableSwitchIsMarkedDownWithAReason
    AHostWhoseSwitchIsHealthyStaysUp
    OneMissedPollDoesNotIsolateAnything
    RecoveryClearsTheReasonWithoutRaisingAnything
    TheDerivationRunsAsPartOfAPollNotOnlyWhenCalledDirectly
    AHostsEntryWithAnUnknownMacIsStillAppliedByItsAddress
)

# The two negative controls named in the fix design. Unless a mutation explicitly expects one of
# them red, both must stay green: a mutant that takes the whole graph down would otherwise make
# every other assertion in the suite pass while the twin became useless.
CONTROLS=(AHostWhoseSwitchIsHealthyStaysUp OneMissedPollDoesNotIsolateAnything)

if [[ ! -d "$BUILD_DIR" ]]; then
    echo "🔴 REFUSE: \$BUILD_DIR=$BUILD_DIR does not exist. Configure it first:"
    echo "     cmake -S . -B $BUILD_DIR -G Ninja -DCMAKE_BUILD_TYPE=Debug"
    exit 2
fi

BK=$(mktemp -d)
cp "$SRC" "$BK/src"
cp "$HDR" "$BK/hdr"

# 🔴 Plain `cp` and then an explicit `touch`, and NEITHER is incidental.
#
# ninja decides what to rebuild by comparing mtimes against the object it already has. `cp -p`,
# `cp -a` and `cp --preserve=timestamps` restore the ORIGINAL mtime, which is older than the .o
# built from the mutant -- so ninja concludes there is nothing to do, the next mutation runs
# against the PREVIOUS mutant's binary, and the results shift by one. Every reading is then wrong
# and nothing in the output looks unusual.
#
# The `touch` makes that guarantee explicit rather than a property of which cp flags someone
# happens to use. Anyone tidying these two lines: the timestamp must go forward.
restore() {
    cp "$BK/src" "$SRC"
    cp "$BK/hdr" "$HDR"
    touch "$SRC" "$HDR"
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
BROKEN=0
ANCHOR_FAIL=""

# ---------------------------------------------------------------------------------------------
# mutate FILE FROM TO -- literal, and refuses unless the anchor appears EXACTLY once.
#
# The count is printed for every anchor, because "the mutation ran" and "the mutation ran where I
# meant" are different claims and only the second one is worth anything. An anchor that has
# drifted to zero occurrences would otherwise mutate nothing and be reported as a survivor, which
# reads as "the test is weak" when the truth is "the gate missed".
# ---------------------------------------------------------------------------------------------
mutate() {
    local file="$1" from="$2" to="$3" n
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    printf '           anchor x%-3s %s\n' "$n" "$(basename "$file")"
    if [[ "$n" != "1" ]]; then
        # Recorded, not fatal. An anchor that has drifted means THIS mutation never ran, which is
        # a survivor -- but aborting here would also skip every mutation after it, and a batch run
        # would lose the rest of the gate to one stale string. The flag is consumed by the next
        # report/expect_green, which counts it and moves on.
        ANCHOR_FAIL="$ANCHOR_FAIL anchor x$n in $(basename "$file"): $(head -1 <<<"$from")"
        return 1
    fi
    FROM="$from" TO="$to" perl -0777 -pi -e 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' "$file"
}

build() { cmake --build "$BUILD_DIR" --target test_routing_strategy -j"$(nproc)" >"$BK/build.log" 2>&1; }

# Runs the suite once and leaves the raw output in $BK/run.log. rc is captured directly from the
# binary with no pipe in between: a pipeline's exit status is the LAST command's, so `$BIN | tee`
# would report tee's success and every mutation would look caught.
run_suite() {
    "$BIN" --gtest_filter="$FILTER" >"$BK/run.log" 2>&1
    echo $?
}

# gtest prints the fully-qualified name, so the suite prefix is not optional: grepping for the
# bare case name matches nothing and every mutation would read as SURVIVED.
red()   { grep -qF "[  FAILED  ] $SUITE.$1" "$BK/run.log"; }
green() { grep -qF "[       OK ] $SUITE.$1" "$BK/run.log"; }

# report NAME "<space separated tests that must go red>"
report() {
    local name="$1" want="$2" rc t ok=1 missing=""
    MUTATIONS=$((MUTATIONS + 1))

    # A mutant that never ran is a SURVIVOR, not a warning. Both of the ways it can fail to run --
    # a drifted anchor and a compile error -- leave the named test green, and a gate that let
    # either of them pass as "broken but not survived" would report a clean run while that
    # behaviour had gone completely unchecked. -Werror (CMakeLists.txt:51-53) makes the compile
    # case realistic: any mutant that trips a warning stops the build.
    if [[ -n "$ANCHOR_FAIL" ]]; then
        printf '  SURVIVED %-46s (never applied:%s)\n' "$name" "$ANCHOR_FAIL"
        ANCHOR_FAIL=""; SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! build; then
        printf '  SURVIVED %-46s (build-fail: the mutant never ran, so nothing was tested)\n' "$name"
        tail -6 "$BK/build.log" | sed 's/^/               /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    rc=$(run_suite)

    # gtest exits 0 only when every selected case passed, so a mutation that changes nothing is
    # visible here before any per-test grep.
    if [[ "$rc" -eq 0 ]]; then ok=0; missing="suite exited 0"; fi

    for t in $want; do
        if ! red "$t"; then ok=0; missing="$missing $t(not red)"; fi
    done

    # Controls: green unless this mutation named them as expected-red.
    for t in "${CONTROLS[@]}"; do
        case " $want " in *" $t "*) continue ;; esac
        if ! green "$t"; then ok=0; missing="$missing CONTROL:$t(not green)"; fi
    done

    if [[ "$ok" == 1 ]]; then
        printf '  caught   %-46s (%s)\n' "$name" "$(tr ' ' ',' <<<"$want" | sed 's/,$//')"
    else
        printf '  SURVIVED %-46s (%s)\n' "$name" "$missing"
        grep -E '^\[  (FAILED|PASSED) ' "$BK/run.log" | sed 's/^/               /' | head -12
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# expect_green NAME WHY -- a mutation whose CORRECT outcome is that nothing goes red.
#
# Not a free pass. "The suite stays green" is a prediction this checks, and a red here is an
# anomaly counted in BROKEN: for the F-4 singles it would mean the guards are not redundant the
# way the header claims, and for the comment-only control it would mean the harness is measuring
# something other than the mutation -- a stale binary, a build directory that is not being
# rebuilt, or a case that is not deterministic.
expect_green() {
    local name="$1" why="$2" rc
    MUTATIONS=$((MUTATIONS + 1))
    # Same rule as report(): a mutant that never ran proves nothing, including the negative claim
    # this function makes. "The suite stayed green" is worthless if the binary is the baseline's.
    if [[ -n "$ANCHOR_FAIL" ]]; then
        printf '  SURVIVED %-46s (never applied:%s)\n' "$name" "$ANCHOR_FAIL"
        ANCHOR_FAIL=""; SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! build; then
        printf '  SURVIVED %-46s (build-fail: the mutant never ran)\n' "$name"
        tail -6 "$BK/build.log" | sed 's/^/               /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    rc=$(run_suite)
    if [[ "$rc" -eq 0 ]]; then
        printf '  green-ok %-46s (%s)\n' "$name" "$why"
    else
        printf '  🔴 ANOMALY %-44s (went red, and it was predicted not to)\n' "$name"
        grep -E '^\[  FAILED  \]' "$BK/run.log" | sed 's/^/               /'
        BROKEN=$((BROKEN + 1))
    fi
    restore
}

# ---------------------------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------------------------
echo "gate: tests/test_OptimisticTopologyReporting.cpp   (BUILD_DIR=$BUILD_DIR)"
echo
echo "baseline (unmutated) must be green:"
if ! build; then
    echo "  🔴 REFUSE: the baseline does not build"; tail -25 "$BK/build.log" | sed 's/^/    /'; exit 2
fi
BASE_RC=$(run_suite)
if [[ "$BASE_RC" -ne 0 ]]; then
    echo "  🔴 REFUSE: the baseline is red. Nothing below would mean anything -- a mutation cannot"
    echo "     be said to have killed a test that was already failing. Failing cases:"
    grep -E '^\[  FAILED  \]' "$BK/run.log" | sed 's/^/       /'
    exit 2
fi
for t in "${ALL_TESTS[@]}"; do
    green "$t" || { echo "  🔴 REFUSE: $t did not run (renamed, or not registered in tests/CMakeLists.txt)"; exit 2; }
done
printf '  ok       all %d cases of %s green, rc=0\n' "${#ALL_TESTS[@]}" "$FILTER"
echo
echo "mutations:"

# --- 1. The derivation is never called -------------------------------------------------------
# The wiring, not the logic. Every other case drives reconcileDerivedLiveness() through the test
# seam, so before TheDerivationRunsAsPartOfAPoll... existed this mutation survived outright.
mutate "$SRC" \
    '    reconcileDerivedLiveness();' \
    '    // reconcileDerivedLiveness();  [mutant 1]'
report "reconcileDerivedLiveness() is never called from a poll" \
    "TheDerivationRunsAsPartOfAPollNotOnlyWhenCalledDirectly"

# --- 2. Hysteresis dropped: isolate on a single missed poll -----------------------------------
# The flap mutant. One poll of "unusable" is a power cycle between del-br and add-br, so this is
# the change that turns every switch restart into 32 hosts and 66 edges flipping twice.
mutate "$HDR" \
    'static constexpr unsigned kMissesBeforeIsolating = 2;' \
    'static constexpr unsigned kMissesBeforeIsolating = 1;  // [mutant 2]'
report "kMissesBeforeIsolating = 1 (flaps on one missed poll)" \
    "OneMissedPollDoesNotIsolateAnything"

# --- 3. Hysteresis raised out of reach: never isolates ----------------------------------------
# The mutant that a symbolically-written test cannot see: loops bounded by the constant itself
# would simply iterate 1000 times and pass. The suite counts polls with a literal for this reason.
mutate "$HDR" \
    'static constexpr unsigned kMissesBeforeIsolating = 2;' \
    'static constexpr unsigned kMissesBeforeIsolating = 1000;  // [mutant 3]'
report "kMissesBeforeIsolating = 1000 (never isolates anything)" \
    "HostFacingEdgesOfAnUnreachableSwitchGoDownWithAReason AHostBehindAnUnreachableSwitchIsMarkedDownWithAReason RecoveryClearsTheReasonWithoutRaisingAnything TheDerivationRunsAsPartOfAPollNotOnlyWhenCalledDirectly OneMissedPollDoesNotIsolateAnything"

# --- 4a. The edge goes down but says nothing about why ----------------------------------------
# is_up still moves, so a suite that only checked is_up would be green. The reason is the whole
# difference between "we probed it" and "we inferred it", which is the claim a consumer needs.
mutate "$SRC" \
    'ep.downReason = DownReason::SwitchUnreachable;' \
    'ep.downReason = DownReason::None;  // [mutant 4a]'
report "an isolated edge carries no down_reason" \
    "HostFacingEdgesOfAnUnreachableSwitchGoDownWithAReason RecoveryClearsTheReasonWithoutRaisingAnything"

# --- 4b. The host goes down but says nothing about why ----------------------------------------
mutate "$SRC" \
    'vp.downReason = DownReason::SwitchUnreachable;' \
    'vp.downReason = DownReason::None;  // [mutant 4b]'
report "an isolated host carries no down_reason" \
    "AHostBehindAnUnreachableSwitchIsMarkedDownWithAReason TheDerivationRunsAsPartOfAPollNotOnlyWhenCalledDirectly"

# --- 5. Recovery raises instead of only releasing ---------------------------------------------
# The derivation has evidence for down (a switch positively observed absent) and none whatever for
# up. This mutant makes it the seventh site in that file asserting liveness it never observed --
# which is the exact branch deleted from DeviceConfigurationAndPowerManager.cpp:781-802.
mutate "$SRC" \
    '            ep.downReason = DownReason::None;
            ++edgesReleased;' \
    '            ep.downReason = DownReason::None;
            ep.isUp = true;  // [mutant 5]
            ++edgesReleased;'
report "recovery marks edges up instead of only clearing the reason" \
    "RecoveryClearsTheReasonWithoutRaisingAnything"

# --- 5b. Over-isolation: every edge is cut, regardless of which switch is unusable -------------
# The mutant both negative controls exist for, and the reason this gate has any negative controls
# at all. A twin that reports everything down is exactly as useless as one that reports everything
# up, and every "went red as expected" assertion in this file would still hold under it -- the
# suite would look like it was catching things while the fix had become the opposite defect.
#
# Named as expected-red for BOTH controls, which is the point: it is the only mutation here that
# demonstrates they can fail at all. A control no mutant can turn red is a control nobody has
# checked.
mutate "$SRC" \
    '        const bool cut = isolating.count(boost::source(e, *m_graph)) != 0 ||
                         isolating.count(boost::target(e, *m_graph)) != 0;' \
    '        const bool cut = true;  // [mutant 5b] every edge, not just the isolated ones'
report "every edge is cut regardless of which switch is unusable" \
    "AHostWhoseSwitchIsHealthyStaysUp OneMissedPollDoesNotIsolateAnything"

# --- 6. F-4 guards, one at a time. Expected to survive; see the header. -----------------------
mutate "$SRC" \
    'if (findSwitchByIp(ip).has_value())' \
    'if (false)  // [mutant 6a] up-front rejection removed'
expect_green "F-4 guard 1 alone: findSwitchByIp rejection removed" \
    "redundant alone -- killed by mutants 7a/7b/7c"

mutate "$SRC" \
    'if ((*m_graph)[*edgeOpt].srcDpid == 0)' \
    'if (true)  // [mutant 6b] srcDpid==0 check removed'
expect_green "F-4 guard 2 alone: srcDpid==0 check removed" \
    "redundant alone -- killed by mutant 7a"

mutate "$SRC" \
    'if ((*m_graph)[edgeRevOpt.value()].dstDpid == 0)' \
    'if (true)  // [mutant 6c] dstDpid==0 check removed'
expect_green "F-4 guard 3 alone: dstDpid==0 check removed" \
    "redundant alone -- killed by mutant 7b"

# --- 7. F-4 guards in the combinations that ARE load-bearing ----------------------------------
mutate "$SRC" \
    'if (findSwitchByIp(ip).has_value())' \
    'if (false)  // [mutant 7a]'
mutate "$SRC" \
    'if ((*m_graph)[*edgeOpt].srcDpid == 0)' \
    'if (true)  // [mutant 7a]'
report "F-4 guards 1+2 removed (route via findEdgeByHostIp opens)" \
    "ASwitchLearnedAsAHostDoesNotResurrectASwitchLink"

mutate "$SRC" \
    'if (findSwitchByIp(ip).has_value())' \
    'if (false)  // [mutant 7b]'
mutate "$SRC" \
    'if ((*m_graph)[edgeRevOpt.value()].dstDpid == 0)' \
    'if (true)  // [mutant 7b]'
report "F-4 guards 1+3 removed (route via findEdgeBySrcAndDstIp opens)" \
    "ASwitchLearnedAsAHostDoesNotResurrectASwitchLink"

mutate "$SRC" \
    'if (findSwitchByIp(ip).has_value())' \
    'if (false)  // [mutant 7c]'
mutate "$SRC" \
    'if ((*m_graph)[*edgeOpt].srcDpid == 0)' \
    'if (true)  // [mutant 7c]'
mutate "$SRC" \
    'if ((*m_graph)[edgeRevOpt.value()].dstDpid == 0)' \
    'if (true)  // [mutant 7c]'
report "F-4 all three guards removed (the defect, verbatim)" \
    "ASwitchLearnedAsAHostDoesNotResurrectASwitchLink"

# --- 8. The MAC-not-found fallthrough gains a continue ----------------------------------------
# updateHosts today only WARNs when findVertexByMac misses and then carries on to the IP lookups.
# Add a continue and the F-4 test's bogus entry is dropped before it reaches a single guard: the
# inter-switch links stay down, the F-4 case passes, and it has exercised nothing. This mutation
# must be caught by the case that exists to say which mechanism produced that green.
mutate "$SRC" \
    '"Host ({}) not found in static network topology file",
                                   macStr);
            }' \
    '"Host ({}) not found in static network topology file",
                                   macStr);
                continue;  // [mutant 8]
            }'
report "updateHosts abandons an entry whose MAC it cannot resolve" \
    "AHostsEntryWithAnUnknownMacIsStillAppliedByItsAddress"

# --- 9. The rejected version of the F-4 fix: updateHosts stops raising host edges -------------
# "Just stop updateHosts writing edges" is the repair someone reaches for first, and it breaks
# discovery outright: the loader starts every edge down and this is the only thing that ever
# raises a host's. Added because the first version of this gate left
# ARealHostEntryStillRaisesItsOwnTwoEdges with no mutation pointed at it -- a test nothing can
# kill is a test nothing has checked, whatever the suite's exit code says.
mutate "$SRC" \
    'if ((*m_graph)[*edgeOpt].srcDpid == 0)' \
    'if (false)  // [mutant 9] updateHosts never raises a host edge'
report "updateHosts stops raising host edges (the rejected fix)" \
    "ARealHostEntryStillRaisesItsOwnTwoEdges AHostsEntryWithAnUnknownMacIsStillAppliedByItsAddress"

# --- 10. Comment-only control -----------------------------------------------------------------
# The gate's own negative control. This changes no behaviour, so the suite must stay green; a red
# here means the harness is measuring something other than the mutation -- a stale binary, a
# non-deterministic case, a build directory that is not being rebuilt between runs.
mutate "$SRC" \
    '/** @brief See the header for what this does not do and why. [Co-developed with claude code -- Adam]
 */' \
    '/** @brief See the header for what this does not do and why. [Co-developed with claude code -- Adam]
 *  [mutant 10] comment-only control: no behaviour changes, the suite must stay green.
 */'
expect_green "CONTROL: comment-only edit" \
    "no behaviour changed, so nothing may go red"

# ---------------------------------------------------------------------------------------------
# Restore and report
# ---------------------------------------------------------------------------------------------
restore
# Rebuild once on the restored sources, so the tree this run leaves behind holds a binary built
# from the baseline and not from mutant 10. Without it the next thing anyone runs -- local_ci, a
# sibling gate, a bare ./bin/test_routing_strategy -- silently tests the last mutant.
build >/dev/null 2>&1
echo
ok=1
cmp -s "$BK/src" "$SRC" || { echo "🔴 BASELINE NOT RESTORED: $SRC"; diff -u "$BK/src" "$SRC" | head -20; ok=0; }
cmp -s "$BK/hdr" "$HDR" || { echo "🔴 BASELINE NOT RESTORED: $HDR"; diff -u "$BK/hdr" "$HDR" | head -20; ok=0; }
[[ "$ok" == 1 ]] && echo "baseline restored: both sources byte-identical to the pre-run snapshot"
echo
echo "$MUTATIONS mutations, $SURVIVORS survived"
[[ "$BROKEN" -gt 0 ]] && echo "$BROKEN anomaly/anomalies: a mutation predicted green went red -- see above"
if [[ "$SURVIVORS" -gt 0 ]]; then
    echo "🔴 a survivor means the named test cannot tell that code from the mutant -- it is not a"
    echo "   test of that behaviour, whatever its name says. A survivor recorded as 'never applied'"
    echo "   or 'build-fail' means worse: the behaviour was not tested at all this run."
fi
[[ "$ok" == 1 && "$SURVIVORS" -eq 0 && "$BROKEN" -eq 0 ]]
exit $?
