#!/usr/bin/env bash
#
# Mutation gate for tests/test_GroupMeterExistence.cpp (doc/KNOWN-ISSUES.md F-13).
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. This applies five mutations, rebuilds,
# and records WHICH tests went red -- and, just as importantly, which ones STAYED GREEN. Four of
# the tests in that file are reverse guards: they assert that an existence check the kernel could
# not answer does NOT become a 404. A mutation that turns those red has broken the thing they
# protect, so this script fails on that too.
#
# The five mutations, and the one control:
#
#   A   the guard stops asking          -- reproduces the F-13 defect exactly, one line
#   A'  Unknown collapses into Absent   -- the reverse: the instrument reports its own failure
#                                          as a finding ("Ryu is down" reads as "no such group")
#   A"  a controller failure gets relabelled with the guard's own outcome
#   B   respondToOpResult stops emitting `outcome`
#   B'  respondToOpResult emits `outcome` unconditionally, including empty
#   C   comment-only control edit       -- must rebuild and stay green. Without it, "the suite
#                                          went red" could just mean "a rebuild happened".
#
# A and A' are a pair on purpose, and so are B and B'. A" was added afterwards because without it
# exactly one of the 30 tests was killed by no mutation at all -- checked mechanically, not by
# eye. Every test in the file is now named in at least one RED_LIST.
#
# ⚠️ The design note for F-13 lists only A/A'/B/B'. It also mis-stated A' as killing four tests
# without saying that A' needs a SECOND edit (the ternary fallback in guardedMod) to reach the
# non-addressable case. Both are corrected here; this script, not the note, is the executable
# statement of the gate.
#
# 🔴 GUARDS ITS OWN BASELINE. sha256 before anything is touched, EXIT trap restores on any exit
# (including Ctrl-C), and the last thing it does is assert byte-identity against the pre-run
# snapshot. An interrupted mutation run has previously left a mutant on disk in this repo.
#
# ⚠️ `cp -p` alone does NOT restore the build. It puts the ORIGINAL mtime back, which is older
# than the object built from the mutant, so ninja sees nothing to do and the NEXT run tests the
# mutant while the source on disk is pristine. `touch` after every restore is what actually
# restores the build. (Same trap as tests/shell/mutate_rate_denominator.sh; do not remove.)
#
# ⚠️ TARGET NAME. There is no build target called `test_GroupMeterExistence`.
#    tests/test_GroupMeterExistence.cpp is a SOURCE FILE compiled into the single test binary
#    `test_routing_strategy` (tests/CMakeLists.txt:2-56), which is where every test in this repo
#    lives. This script builds that target and selects the two suites with --gtest_filter.
#    Override with TARGET=... if that ever changes.
#
# Usage:
#   tests/shell/mutate_f13_group_meter_existence.sh
#   BUILD_DIR=build-asan tests/shell/mutate_f13_group_meter_existence.sh
#
# Exit codes:
#   0  every mutation caught, control green, baseline restored byte-identically
#   1  at least one mutation SURVIVED (that behaviour is untested)
#   2  harness fault: baseline red, anchor moved, control went red, or restore failed
#
# Never uses pkill/pgrep. Every rc is read unpiped.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
BIN="$BUILD_DIR/bin/$TARGET"
FILTER="${FILTER:-GroupMeterFixture.*:GroupMeterEndpointTest.*}"
JOBS="${JOBS:-4}"

STRAT=src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp
SESSION=src/ndt_core/http/HttpSession.cpp
FILES=("$STRAT" "$SESSION")

BUILD_LOG=$(mktemp)
BK=$(mktemp -d)

SURVIVORS=0
MUTATIONS=0
HARNESS_FAULT=0

# --- snapshot / restore -------------------------------------------------------------------------

declare -A BASE_SHA
for f in "${FILES[@]}"; do
    cp -p "$f" "$BK/$(basename "$f")"
    BASE_SHA["$f"]=$(sha256sum "$f" | cut -d' ' -f1)
done

restore() {
    local f now
    for f in "${FILES[@]}"; do
        cp -p "$BK/$(basename "$f")" "$f"
        # See the header: cp -p restores the mtime too, which is what makes ninja skip the
        # rebuild and silently test the mutant on the next round.
        touch "$f"
        now=$(sha256sum "$f" | cut -d' ' -f1)
        if [[ "$now" != "${BASE_SHA[$f]}" ]]; then
            echo "🔴 RESTORE FAILED -- $f is not the baseline. Do NOT commit." >&2
            HARNESS_FAULT=1
        fi
    done
}

cleanup() {
    restore
    rm -rf "$BK"
    rm -f "$BUILD_LOG"
}
trap cleanup EXIT

# --- primitives ---------------------------------------------------------------------------------

# apply_exact FILE OLD NEW EXPECTED_COUNT
# Exact-string replacement with an asserted occurrence count. No regex: the anchors contain
# braces, brackets, quotes and '?' and a regex would silently match the wrong thing.
apply_exact() {
    MUT_FILE="$1" MUT_OLD="$2" MUT_NEW="$3" MUT_COUNT="$4" python3 - <<'PY'
import os, pathlib, sys

path = pathlib.Path(os.environ["MUT_FILE"])
old  = os.environ["MUT_OLD"]
new  = os.environ["MUT_NEW"]
want = int(os.environ["MUT_COUNT"])

text = path.read_text()
got = text.count(old)
if got != want:
    sys.stderr.write(
        "     anchor count mismatch in %s: found %d, expected %d\n" % (path, got, want))
    sys.stderr.write("     anchor was:\n")
    for line in old.splitlines():
        sys.stderr.write("       | %s\n" % line)
    sys.exit(3)
path.write_text(text.replace(old, new))
PY
}

build_target() {
    cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >"$BUILD_LOG" 2>&1
}

LAST_OUT=""
LAST_RC=0
run_suite() {
    # Assignment then $? on the next line: a pipe here would report the filter's rc, not the
    # binary's. (memory: `cmd | filter` followed by && / || is always wrong.)
    LAST_OUT=$("$BIN" --gtest_filter="$FILTER" 2>&1)
    LAST_RC=$?
}

failed_names() {
    sed -n 's/^\[  FAILED  \] \([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' <<<"$LAST_OUT" \
        | sort -u
}

# verdict LABEL -- reads the RED_LIST and GREEN_LIST arrays set by the caller.
verdict() {
    local label="$1"
    local failed name
    failed=$(failed_names)

    local missing=0 broken=0
    for name in "${RED_LIST[@]}"; do
        if ! grep -qxF "$name" <<<"$failed"; then
            printf '     🔴 stayed GREEN but must go red: %s\n' "$name"
            missing=$((missing + 1))
        fi
    done
    for name in "${GREEN_LIST[@]}"; do
        if grep -qxF "$name" <<<"$failed"; then
            printf '     🔴 went RED but is a reverse guard: %s\n' "$name"
            broken=$((broken + 1))
        fi
    done

    if [[ "$missing" -eq 0 && "$broken" -eq 0 ]]; then
        printf '  ✅ caught   %s  (%d red, %d reverse guards held)\n' \
            "$label" "${#RED_LIST[@]}" "${#GREEN_LIST[@]}"
    else
        printf '  🔴 SURVIVED %s  (%d of %d expected reds missing, %d reverse guards broken)\n' \
            "$label" "$missing" "${#RED_LIST[@]}" "$broken"
        SURVIVORS=$((SURVIVORS + 1))
    fi
}

# mutate LABEL -- the caller has already applied the edits. Builds, runs, judges, restores.
mutate() {
    local label="$1"
    MUTATIONS=$((MUTATIONS + 1))
    printf '\n=== %s ===\n' "$label"

    build_target
    if [[ $? -ne 0 ]]; then
        # A mutant that does not compile proves NOTHING about the tests. Counting it as a pass
        # is how a mutation gate turns into a decoration, so it is a survivor.
        printf '  🔴 SURVIVED %s  (mutant does not compile -- proves nothing)\n' "$label"
        tail -20 "$BUILD_LOG" | sed 's/^/       /'
        SURVIVORS=$((SURVIVORS + 1))
        restore
        return
    fi

    run_suite
    verdict "$label"
    restore
}

# --- preflight ----------------------------------------------------------------------------------

echo "F-13 mutation gate"
echo "  build dir : $BUILD_DIR"
echo "  target    : $TARGET   (tests/test_GroupMeterExistence.cpp compiles into this binary)"
echo "  filter    : $FILTER"
for f in "${FILES[@]}"; do
    printf '  baseline  : %s  sha256 %s\n' "$f" "${BASE_SHA[$f]:0:16}"
done

if [[ ! -d "$BUILD_DIR" ]]; then
    echo "🔴 REFUSE: '$BUILD_DIR' does not exist. Configure it first, or set BUILD_DIR=..." >&2
    exit 2
fi

# --- baseline -----------------------------------------------------------------------------------

printf '\n=== BASELINE (unmutated) ===\n'
build_target
if [[ $? -ne 0 ]]; then
    echo "🔴 REFUSE: the baseline does not build. Nothing below would mean anything." >&2
    tail -40 "$BUILD_LOG" | sed 's/^/    /' >&2
    exit 2
fi
if [[ ! -x "$BIN" ]]; then
    echo "🔴 REFUSE: $BIN was not produced. Is '$TARGET' the right target name?" >&2
    exit 2
fi

run_suite
if [[ "$LAST_RC" -ne 0 ]]; then
    echo "🔴 REFUSE: the baseline is RED. A mutation gate over a red suite measures nothing." >&2
    failed_names | sed 's/^/    still red: /' >&2
    exit 2
fi
BASELINE_COUNT=$(grep -c '^\[       OK \]' <<<"$LAST_OUT")
printf '  ✅ green  (%s tests)\n' "$BASELINE_COUNT"

# =================================================================================================
# A -- the guard stops asking.
#
# Reproduces the pre-fix behaviour exactly: `before` is always Unknown, so no existence check is
# ever issued, nothing is ever refused, and every success is labelled "unverified". This is the
# F-13 defect, put back in one line.
# =================================================================================================

apply_exact "$STRAT" \
'    const Existence before = addressable ? entryExists(kind, dpid, id) : Existence::Unknown;' \
'    (void)addressable;
    const Existence before = Existence::Unknown;' \
    1
if [[ $? -ne 0 ]]; then echo "  🔴 anchor moved -- A not applied"; HARNESS_FAULT=1; restore; else

RED_LIST=(
    GroupMeterFixture.DeletingAGroupThatIsNotThereIsRefusedRatherThanReportedDeleted
    GroupMeterFixture.ModifyingAGroupThatIsNotThereIsRefusedRatherThanReportedModified
    GroupMeterFixture.AddingAGroupThatAlreadyExistsIsAConflictNotAnInstall
    GroupMeterFixture.DeletingAMeterThatIsNotThereIsRefused
    GroupMeterFixture.ModifyingAMeterThatIsNotThereIsRefused
    GroupMeterFixture.AddingAMeterThatAlreadyExistsIsAConflict
    GroupMeterFixture.DeletingAGroupThatIsThereGoesThroughAndSaysItWasDeleted
    GroupMeterFixture.ModifyingAGroupThatIsThereGoesThrough
    GroupMeterFixture.AddingAGroupThatIsNotThereGoesThrough
    GroupMeterFixture.TheMeterAcceptPathsGoThrough
    GroupMeterFixture.TheGroupCheckAsksForTheWholeListBecauseRyuIgnoresTheIdOnOf13
    GroupMeterFixture.TheMeterCheckNamesTheMeterItIsAskingAbout
    GroupMeterFixture.TheCheckHappensBeforeTheModNotAfterIt
    GroupMeterFixture.TheExistenceCheckAsksForTheStatusCodeAndBoundsItsTime
)
# Under A the guard never runs, so everything it could have got wrong is unreachable -- these
# assert the Unknown path, which A makes universal. They must NOT move.
GREEN_LIST=(
    GroupMeterFixture.AnUnreachableControllerDoesNotTurnEveryGroupIntoA404
    GroupMeterFixture.AStatsReplyInAnUnexpectedShapeIsUnknownNotAbsent
    GroupMeterFixture.AnUnparseableStatsReplyIsUnknownNotAbsent
    GroupMeterFixture.ANonNumericGroupIdIsUnknownRatherThanRefused
    GroupMeterFixture.AControllerRefusalOfTheModIsStillReported
    GroupMeterEndpointTest.AResultWithNoOutcomeStillAnswersTheOriginalThreeFieldFailureBody
)
mutate "A   the guard stops asking (F-13 put back)"
fi

# =================================================================================================
# A' -- Unknown collapses into Absent.
#
# The reverse of A, and the more dangerous direction: a controller that has gone away, a reply
# the reader does not recognise, or an id it cannot parse would all be reported as "the group is
# not there" -- a 404 asserting something about the switch on the strength of the kernel's own
# failure to look. Four tests exist for exactly this and nothing else kills them.
#
# Two edits, because Unknown is produced in two places: the three early returns inside
# entryExists (asserted count 3 -- this anchor is deliberately NOT unique) and the ternary
# fallback in guardedMod for a payload that cannot be addressed at all.
# =================================================================================================

apply_exact "$STRAT" \
'        return Existence::Unknown;' \
'        return Existence::Absent;' \
    3
rc_a1=$?
apply_exact "$STRAT" \
'    const Existence before = addressable ? entryExists(kind, dpid, id) : Existence::Unknown;' \
'    const Existence before = addressable ? entryExists(kind, dpid, id) : Existence::Absent;' \
    1
rc_a2=$?
if [[ "$rc_a1" -ne 0 || "$rc_a2" -ne 0 ]]; then
    echo "  🔴 anchor moved -- A' not applied"; HARNESS_FAULT=1; restore
else

RED_LIST=(
    GroupMeterFixture.AnUnreachableControllerDoesNotTurnEveryGroupIntoA404
    GroupMeterFixture.AStatsReplyInAnUnexpectedShapeIsUnknownNotAbsent
    GroupMeterFixture.AnUnparseableStatsReplyIsUnknownNotAbsent
    GroupMeterFixture.ANonNumericGroupIdIsUnknownRatherThanRefused
)
# A' only changes what an UNANSWERABLE check reports. A check that got a well-formed answer still
# returns Present or Absent as before, so every accept/refuse pair must hold.
GREEN_LIST=(
    GroupMeterFixture.DeletingAGroupThatIsNotThereIsRefusedRatherThanReportedDeleted
    GroupMeterFixture.ModifyingAGroupThatIsNotThereIsRefusedRatherThanReportedModified
    GroupMeterFixture.AddingAGroupThatAlreadyExistsIsAConflictNotAnInstall
    GroupMeterFixture.DeletingAMeterThatIsNotThereIsRefused
    GroupMeterFixture.ModifyingAMeterThatIsNotThereIsRefused
    GroupMeterFixture.AddingAMeterThatAlreadyExistsIsAConflict
    GroupMeterFixture.DeletingAGroupThatIsThereGoesThroughAndSaysItWasDeleted
    GroupMeterFixture.ModifyingAGroupThatIsThereGoesThrough
    GroupMeterFixture.AddingAGroupThatIsNotThereGoesThrough
    GroupMeterFixture.TheMeterAcceptPathsGoThrough
    GroupMeterFixture.AControllerRefusalOfTheModIsStillReported
)
mutate "A'  Unknown collapses into Absent (instrument reports its own failure)"
fi

# =================================================================================================
# A" -- the guard relabels a controller failure as its own outcome.
#
# Added after the first four: without it exactly one test in the file
# (AControllerRefusalOfTheModIsStillReported) is killed by no mutation at all, and a test that
# has never been seen red is a decoration. It pins that a real 400 from Ryu is relayed intact
# rather than being stamped "deleted" by the layer that only checked the precondition.
# =================================================================================================

apply_exact "$STRAT" \
'    OpResult result = post(path, j, operation);
    if (!result.ok)
    {
        return result;
    }' \
'    OpResult result = post(path, j, operation);' \
    1
if [[ $? -ne 0 ]]; then echo "  🔴 anchor moved -- A\" not applied"; HARNESS_FAULT=1; restore; else

RED_LIST=(
    GroupMeterFixture.AControllerRefusalOfTheModIsStillReported
)
# The mutation only touches the failed-POST path; every success path is byte-for-byte the same,
# which is why this one test is the whole guard.
GREEN_LIST=(
    GroupMeterFixture.DeletingAGroupThatIsThereGoesThroughAndSaysItWasDeleted
    GroupMeterFixture.AddingAGroupThatIsNotThereGoesThrough
    GroupMeterFixture.TheMeterAcceptPathsGoThrough
    GroupMeterFixture.AnUnreachableControllerDoesNotTurnEveryGroupIntoA404
    GroupMeterFixture.DeletingAGroupThatIsNotThereIsRefusedRatherThanReportedDeleted
)
mutate "A\" a controller failure gets relabelled with an outcome"
fi

# =================================================================================================
# B -- respondToOpResult stops emitting `outcome`.
#
# The pre-fix reply shape: one key on success, three on failure, fixed. This is what made the six
# endpoints indistinguishable from each other and made both kinds of 404 look identical.
# =================================================================================================

apply_exact "$SESSION" \
'        json body{{"status", successMessage}};
        if (!result.outcome.empty())
        {
            body["outcome"] = result.outcome;
        }
        res.body() = body.dump();' \
'        json body{{"status", successMessage}};
        res.body() = body.dump();' \
    1
rc_b1=$?
apply_exact "$SESSION" \
'    if (!result.outcome.empty())
    {
        failureBody["outcome"] = result.outcome;
    }
    res.body() = failureBody.dump();' \
'    res.body() = failureBody.dump();' \
    1
rc_b2=$?
if [[ "$rc_b1" -ne 0 || "$rc_b2" -ne 0 ]]; then
    echo "  🔴 anchor moved -- B not applied"; HARNESS_FAULT=1; restore
else

RED_LIST=(
    GroupMeterEndpointTest.DeleteGroupRelaysA404WithAnOutcomeNamingWhatWasNotFound
    GroupMeterEndpointTest.ModifyGroupRelaysA404WithItsOutcome
    GroupMeterEndpointTest.InstallGroupRelaysA409WithItsOutcome
    GroupMeterEndpointTest.DeleteMeterRelaysA404WithItsOutcome
    GroupMeterEndpointTest.ModifyMeterRelaysA404WithItsOutcome
    GroupMeterEndpointTest.InstallMeterRelaysA409WithItsOutcome
    GroupMeterEndpointTest.EachEndpointKeepsItsOwnSuccessSentenceAndCarriesTheOutcome
    GroupMeterEndpointTest.AnUnverifiedSuccessSaysSoRatherThanClaimingItWasDeleted
    GroupMeterEndpointTest.AP4RefusalIsStill501AndNamesItself
    GroupMeterEndpointTest.TheTwoDifferentNotFoundsAreDistinguishableInTheBody
)
# B touches HttpSession only, so the whole strategy layer must be untouched -- and the one
# endpoint test that asserts the ABSENCE of the key still holds, which is why B alone is not
# enough and B' exists.
GREEN_LIST=(
    GroupMeterEndpointTest.AResultWithNoOutcomeStillAnswersTheOriginalThreeFieldFailureBody
    GroupMeterFixture.DeletingAGroupThatIsNotThereIsRefusedRatherThanReportedDeleted
    GroupMeterFixture.AddingAGroupThatAlreadyExistsIsAConflictNotAnInstall
    GroupMeterFixture.AnUnreachableControllerDoesNotTurnEveryGroupIntoA404
)
mutate "B   respondToOpResult stops emitting outcome"
fi

# =================================================================================================
# B' -- respondToOpResult emits `outcome` unconditionally.
#
# The opposite failure: a key that appears even when the layer below had nothing to say. /ndt/ is
# a cross-repo contract and an added field is as much a break as a renamed one for a client that
# counts them. Exactly one test asserts this, and nothing else can kill it.
# =================================================================================================

apply_exact "$SESSION" \
'        if (!result.outcome.empty())
        {
            body["outcome"] = result.outcome;
        }' \
'        body["outcome"] = result.outcome;' \
    1
rc_c1=$?
apply_exact "$SESSION" \
'    if (!result.outcome.empty())
    {
        failureBody["outcome"] = result.outcome;
    }' \
'    failureBody["outcome"] = result.outcome;' \
    1
rc_c2=$?
if [[ "$rc_c1" -ne 0 || "$rc_c2" -ne 0 ]]; then
    echo "  🔴 anchor moved -- B' not applied"; HARNESS_FAULT=1; restore
else

RED_LIST=(
    GroupMeterEndpointTest.AResultWithNoOutcomeStillAnswersTheOriginalThreeFieldFailureBody
)
# Every other endpoint test supplies a non-empty outcome, so an unconditional write is invisible
# to them. That is the point: without the test above, B' ships unnoticed.
GREEN_LIST=(
    GroupMeterEndpointTest.DeleteGroupRelaysA404WithAnOutcomeNamingWhatWasNotFound
    GroupMeterEndpointTest.EachEndpointKeepsItsOwnSuccessSentenceAndCarriesTheOutcome
    GroupMeterEndpointTest.AnUnverifiedSuccessSaysSoRatherThanClaimingItWasDeleted
    GroupMeterEndpointTest.AP4RefusalIsStill501AndNamesItself
    GroupMeterEndpointTest.TheTwoDifferentNotFoundsAreDistinguishableInTheBody
)
mutate "B'  respondToOpResult emits outcome unconditionally"
fi

# =================================================================================================
# C -- CONTROL. A comment-only edit.
#
# Not a mutation and not counted as one. It changes a byte in a file the mutations touch, forces
# the same rebuild, and must leave the suite green. Without it, every "went red" above could
# equally be explained by the rebuild itself, and a harness that reported red unconditionally
# would score a perfect run.
# =================================================================================================

printf '\n=== C   CONTROL: comment-only edit, must stay green ===\n'
apply_exact "$STRAT" \
'// What the switch does afterwards, per OpenFlow 1.3 (the error codes are in' \
'// CONTROL EDIT (mutation gate; restored below). What the switch does afterwards, per OF1.3 (in' \
    1
if [[ $? -ne 0 ]]; then
    echo "  🔴 control anchor moved -- the control did not run"
    HARNESS_FAULT=1
    restore
else
    build_target
    if [[ $? -ne 0 ]]; then
        echo "  🔴 the CONTROL edit broke the build -- a comment cannot do that. Harness fault."
        tail -20 "$BUILD_LOG" | sed 's/^/       /'
        HARNESS_FAULT=1
    else
        run_suite
        if [[ "$LAST_RC" -eq 0 ]]; then
            echo "  ✅ green after a comment-only rebuild (the reds above are the mutations)"
        else
            echo "  🔴 CONTROL WENT RED -- the suite is not stable across a rebuild, so every"
            echo "     'caught' verdict above is unreliable. Harness fault, not a pass."
            failed_names | sed 's/^/       red: /'
            HARNESS_FAULT=1
        fi
    fi
    restore
fi

# --- byte identity, and the score ---------------------------------------------------------------

restore
printf '\n--- restore ---\n'
IDENTICAL=1
for f in "${FILES[@]}"; do
    cmp -s "$BK/$(basename "$f")" "$f"
    if [[ $? -ne 0 ]]; then
        echo "  🔴 NOT RESTORED: $f differs from the pre-run snapshot. Do NOT commit."
        IDENTICAL=0
    else
        printf '  ok  %s byte-identical to the pre-run snapshot\n' "$f"
    fi
done

# Leave the tree with a binary built from the restored sources, not from the last mutant.
build_target
if [[ $? -ne 0 ]]; then
    echo "  🔴 the restored tree does not build. Do NOT commit." >&2
    IDENTICAL=0
fi
run_suite
if [[ "$LAST_RC" -ne 0 ]]; then
    echo "  🔴 THE SUITE IS RED AFTER RESTORE -- a mutant is still built in. Do NOT commit." >&2
    failed_names | sed 's/^/       still red: /' >&2
    IDENTICAL=0
fi

printf '\n%d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"

if [[ "$IDENTICAL" -ne 1 || "$HARNESS_FAULT" -ne 0 ]]; then
    echo "harness fault or restore failure -- the score above does not stand" >&2
    exit 2
fi
if [[ "$SURVIVORS" -gt 0 ]]; then
    echo "a surviving mutation means that behaviour is untested" >&2
    exit 1
fi
echo "every mutation caught, every reverse guard held, baseline restored"
exit 0
