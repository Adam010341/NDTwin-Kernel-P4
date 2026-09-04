#!/usr/bin/env bash
#
# Mutation gate for the finding #1 half of tests/test_GroupMeterExistence.cpp:
# a delete is claimed only after the switch is asked.
#
# [Co-developed with claude code -- Adam]
#
# The defect this guards against was measured on ovs4 2026-09-03
# (doc/audit/2026-09-03_night-rounds/round1-ovs/21_delete_group_meter_says_deleted_but_persists.log):
# /ndt/delete_group_entry answered 200 {"outcome":"deleted"} five times while all five groups
# stayed on the switch, re-installing the id correctly answered 409 -- so the id was gone for the
# life of the switch -- and the kernel log held not one line about any of it.
#
# The F-13 gate next door already mutates the PRE-check. It cannot reach any of this: a pre-check
# establishes that the entry was there before, which is the precondition for deleting it, not
# evidence that it left. These five mutations are all on the far side of the POST.
#
#   M1  a switch that still has the entry is reported as deleted  -- finding #1, put back
#   M2  an unanswerable read-back becomes a failed delete         -- the mirror defect: the
#                                                                    kernel publishing its own
#                                                                    reach as a finding
#   M3  the delete forwards the caller's body verbatim            -- the request-side half
#   M4  the read-back happens once                                -- a delete still in flight
#                                                                    is reported as a failure
#   M5  the retry loop spins on success instead of on Present     -- every delete pays the delay
#
# and four WIDENINGS, which must all stay GREEN. A mutation gate scored only on what it kills
# says nothing about what it has over-fitted to: if changing 502 to 503, or a loop bound to an
# equivalent one, or the wording of a message, turns the suite red, then the tests are pinned to
# incidentals rather than to behaviour and the "5/5 caught" above is worth less than it looks.
#
#   W1  `<` becomes `!=` over the same bound          -- an equivalent loop
#   W2  502 becomes 503                               -- still a non-2xx naming the far end
#   W3  the failure sentence is reworded              -- the phrase under test is kept
#   W4  `attempt > 0` becomes `attempt >= 1`          -- the same predicate
#
# Every mutation names the ONE test that must go red for it -- NAMED_BY below -- and that test is
# asserted to be in the red list. A mutation whose named test stays green is a survivor even if
# other tests went red, because then it was caught by something other than the guard it targets.
#
# 🔴 GUARDS ITS OWN BASELINE, on the pattern of mutate_f13_group_meter_existence.sh: sha256
# before anything is touched, EXIT trap restores on any exit including Ctrl-C, byte-identity
# asserted at the end. `touch` after every restore, because cp -p puts the ORIGINAL mtime back
# and ninja then skips the rebuild, so the NEXT round silently tests the previous mutant while
# the source on disk is pristine.
#
# ⚠️ TARGET NAME. There is no target called `test_GroupMeterExistence`; that file compiles into
#    the single binary `test_routing_strategy` (tests/CMakeLists.txt). Override with TARGET=...
#
# ⚠️ Only src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp is mutated. The header
#    carries VERIFY_ATTEMPTS and mutating it would rebuild every translation unit that includes
#    it -- including the ~1.6 GB HttpSession.cpp -- which on this laptop is what systemd-oomd
#    kills Adam's app over. The loop bound is reached through the .cpp instead (W1).
#
# A mutation is only ever CAUGHT by evidence. A mutant that does not compile, and an anchor that
# no longer matches, are both counted as SURVIVORS: in each the test never ran and therefore
# demonstrated nothing. A moved anchor additionally raises a harness fault, because it means this
# script needs editing rather than the code under test.
#
# Usage:
#   tests/shell/mutate_delete_group_entry.sh
#   BUILD_DIR=build-asan tests/shell/mutate_delete_group_entry.sh
#
# Exit codes:
#   0  every mutation caught, every widening green, control green, baseline restored
#   1  at least one mutation SURVIVED, or a widening went red (that behaviour is untested, or
#      the tests are pinned to an incidental)
#   2  harness fault: baseline red, an anchor moved, the control went red, or restore failed
#
# Never uses pkill/pgrep. Every rc is read unpiped.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
BIN="$BUILD_DIR/bin/$TARGET"
FILTER="${FILTER:-GroupMeterFixture.*:GroupMeterEndpointTest.*}"
JOBS="${JOBS:-1}"

STRAT=src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp
FILES=("$STRAT")

BUILD_LOG=$(mktemp)
BK=$(mktemp -d)

SURVIVORS=0
MUTATIONS=0
WIDENINGS=0
WIDENINGS_RED=0
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
        # rebuild and silently test the previous mutant on the next round.
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

# verdict LABEL -- reads RED_LIST, GREEN_LIST and NAMED_BY set by the caller.
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

    # The mutation must be caught by the guard it targets, not merely by something.
    local named_ok=1
    if ! grep -qxF "$NAMED_BY" <<<"$failed"; then
        printf '     🔴 the NAMED guard did not catch it: %s\n' "$NAMED_BY"
        named_ok=0
    fi

    if [[ "$missing" -eq 0 && "$broken" -eq 0 && "$named_ok" -eq 1 ]]; then
        printf '  ✅ caught   %s\n' "$label"
        printf '     by       %s\n' "$NAMED_BY"
        printf '     (%d red, %d reverse guards held)\n' "${#RED_LIST[@]}" "${#GREEN_LIST[@]}"
    else
        printf '  🔴 SURVIVED %s  (%d of %d expected reds missing, %d reverse guards broken)\n' \
            "$label" "$missing" "${#RED_LIST[@]}" "$broken"
        SURVIVORS=$((SURVIVORS + 1))
    fi
}

anchor_moved() {
    local label="$1"
    MUTATIONS=$((MUTATIONS + 1))
    SURVIVORS=$((SURVIVORS + 1))
    HARNESS_FAULT=1
    printf '\n=== %s ===\n' "$label"
    printf '  🔴 SURVIVED %s  (anchor moved -- the mutation never ran, so the test never ran)\n' \
        "$label"
    restore
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

# widen LABEL -- a behaviour-preserving edit. Must stay green; red means the tests are pinned to
# an incidental rather than to the behaviour, which devalues every "caught" above.
widen() {
    local label="$1"
    WIDENINGS=$((WIDENINGS + 1))
    printf '\n=== %s ===\n' "$label"

    build_target
    if [[ $? -ne 0 ]]; then
        printf '  🔴 the widening does not compile -- harness fault, not a result\n'
        tail -20 "$BUILD_LOG" | sed 's/^/       /'
        HARNESS_FAULT=1
        restore
        return
    fi

    run_suite
    if [[ "$LAST_RC" -eq 0 ]]; then
        printf '  ✅ green    %s  (the tests are not pinned to this)\n' "$label"
    else
        printf '  🔴 WENT RED %s  (the tests are over-fitted to an incidental)\n' "$label"
        failed_names | sed 's/^/       red: /'
        WIDENINGS_RED=$((WIDENINGS_RED + 1))
    fi
    restore
}

# --- preflight ----------------------------------------------------------------------------------

echo "finding #1 mutation gate -- a delete is claimed only after the switch is asked"
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
# M1 -- a switch that still has the entry is reported as deleted.
#
# Finding #1 itself, in one line: the read-back still happens, and its answer is thrown away.
# This is the exact behaviour measured on ovs4 -- 200 {"outcome":"deleted"} over a group that is
# still there -- so if the suite does not go red here it does not test the finding at all.
# =================================================================================================

# [Co-developed with claude code -- Adam] 2026-09-04, FINDINGS #87: the read-back block was
# lifted out of `if (op == EntryOp::Delete)` and made to serve all three verbs, so it lost four
# spaces of indentation and its Present/Absent tests became `expected`. Same mutation, same
# verdict, new coordinates. `after != expected` IS "the entry is still there" for a delete,
# because expected is Absent for Delete.
apply_exact "$STRAT" \
'    if (after != expected)
    {' \
'    if (false)
    {' \
    1
if [[ $? -ne 0 ]]; then anchor_moved "M1  a group the switch still has is reported as deleted"; else

NAMED_BY=GroupMeterFixture.AGroupTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
RED_LIST=(
    GroupMeterFixture.AGroupTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
    GroupMeterFixture.AMeterTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
    GroupMeterFixture.TheDeleteReCheckIsRetriedAndBounded
)
# M1 only changes what a STILL-PRESENT entry is reported as. A delete that landed, one that
# could not be read back, and the refusal paths are all untouched -- and the accept twin is the
# one that matters here: without it, "refuse every delete" would score as catching M1.
GREEN_LIST=(
    GroupMeterFixture.DeletingAGroupThatIsThereGoesThroughAndSaysItWasDeleted
    GroupMeterFixture.TheMeterAcceptPathsGoThrough
    GroupMeterFixture.AGroupIdCanBeInstalledAgainAfterAVerifiedDelete
    GroupMeterFixture.ADeleteThatCannotBeReadBackIsUnverifiedRatherThanFailed
    GroupMeterFixture.ADeleteNamesTheEntryAndDoesNotCarryADefinitionOfIt
    GroupMeterFixture.AControllerRefusalOfTheModIsStillReported
    GroupMeterFixture.DeletingAGroupThatIsNotThereIsRefusedRatherThanReportedDeleted
)
mutate "M1  a group the switch still has is reported as deleted"
fi

# =================================================================================================
# M2 -- an unanswerable read-back becomes a failed delete.
#
# The mirror of M1 and the more insidious direction, because it looks like rigour: a controller
# that has gone away would make every delete answer 502 "still on the switch" -- an assertion
# about the fabric manufactured out of the kernel's own failure to look. Same rule the pre-check
# follows; this is the test that keeps the new guard honest about not knowing.
# =================================================================================================

# Re-pointed with M1 (#87). Same defect from the other side: after #87 the Unknown arm is what
# keeps an unanswerable read-back out of the failure branch, so removing IT is what turns a
# read-back the kernel could not perform into a 502 about the switch.
apply_exact "$STRAT" \
'    if (after == Existence::Unknown)
    {' \
'    if (false)
    {' \
    1
if [[ $? -ne 0 ]]; then anchor_moved "M2  an unanswerable read-back becomes a failed delete"; else

NAMED_BY=GroupMeterFixture.ADeleteThatCannotBeReadBackIsUnverifiedRatherThanFailed
RED_LIST=(
    GroupMeterFixture.ADeleteThatCannotBeReadBackIsUnverifiedRatherThanFailed
)
# Present is still Present and Absent is still Absent, so every other delete path is unchanged.
GREEN_LIST=(
    GroupMeterFixture.AGroupTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
    GroupMeterFixture.AMeterTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
    GroupMeterFixture.DeletingAGroupThatIsThereGoesThroughAndSaysItWasDeleted
    GroupMeterFixture.TheMeterAcceptPathsGoThrough
    GroupMeterFixture.AGroupIdCanBeInstalledAgainAfterAVerifiedDelete
    GroupMeterFixture.AnUnreachableControllerDoesNotTurnEveryGroupIntoA404
)
mutate "M2  an unanswerable read-back becomes a failed delete"
fi

# =================================================================================================
# M3 -- the delete forwards the caller's body verbatim.
#
# The request-side half of the finding, and the half that is invisible in the response: OpenFlow
# 1.3 gives ofp_group_mod's bucket list no meaning for OFPGC_DELETE, Ryu packs whatever the body
# carries into the message it builds, and a switch that rejects that shape rejects it after Ryu
# has already answered 200. Nothing in the reply distinguishes the two, so only an assertion on
# what went onto the wire can hold this.
# =================================================================================================

apply_exact "$STRAT" \
'        outbound = json{{"dpid", dpid}, {idField, id}};' \
'        outbound = j;' \
    1
if [[ $? -ne 0 ]]; then anchor_moved "M3  the delete forwards the caller's body verbatim"; else

NAMED_BY=GroupMeterFixture.ADeleteNamesTheEntryAndDoesNotCarryADefinitionOfIt
RED_LIST=(
    GroupMeterFixture.ADeleteNamesTheEntryAndDoesNotCarryADefinitionOfIt
)
# The read-back does not care what was sent, so every outcome assertion is unmoved. That is
# precisely why M3 needs its own test: the defect it restores cannot be seen from the reply.
GREEN_LIST=(
    GroupMeterFixture.AGroupTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
    GroupMeterFixture.DeletingAGroupThatIsThereGoesThroughAndSaysItWasDeleted
    GroupMeterFixture.TheMeterAcceptPathsGoThrough
    GroupMeterFixture.AGroupIdCanBeInstalledAgainAfterAVerifiedDelete
    GroupMeterFixture.ADeleteThatCannotBeReadBackIsUnverifiedRatherThanFailed
    GroupMeterFixture.ANonNumericGroupIdIsUnknownRatherThanRefused
)
mutate "M3  the delete forwards the caller's body verbatim"
fi

# =================================================================================================
# M4 -- the read-back happens once.
#
# Ryu answers 200 the moment it has enqueued the message, before the switch has seen it, so a
# single immediate read can legitimately still find the entry. One attempt turns that race into
# a fabricated 502 on deletes that were perfectly fine -- the defect inverted rather than fixed.
# =================================================================================================

apply_exact "$STRAT" \
'    for (int attempt = 0; attempt < VERIFY_ATTEMPTS; ++attempt)' \
'    for (int attempt = 0; attempt < 1; ++attempt)' \
    1
if [[ $? -ne 0 ]]; then anchor_moved "M4  the read-back happens once"; else

NAMED_BY=GroupMeterFixture.TheDeleteReCheckIsRetriedAndBounded
RED_LIST=(
    GroupMeterFixture.TheDeleteReCheckIsRetriedAndBounded
)
# A switch that never removes the entry still reports still_present, and one that removed it
# before the first read still reports deleted -- which is why the retry needs its own assertion.
GREEN_LIST=(
    GroupMeterFixture.AGroupTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
    GroupMeterFixture.AMeterTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
    GroupMeterFixture.DeletingAGroupThatIsThereGoesThroughAndSaysItWasDeleted
    GroupMeterFixture.AGroupIdCanBeInstalledAgainAfterAVerifiedDelete
    GroupMeterFixture.ADeleteThatCannotBeReadBackIsUnverifiedRatherThanFailed
)
mutate "M4  the read-back happens once"
fi

# =================================================================================================
# M5 -- the retry loop spins on success instead of on Present.
#
# Inverting the break makes a delete that DID land keep asking, so the common path pays the
# whole delay budget while the failing path answers immediately: the cost lands on exactly the
# wrong case. Invisible in every outcome assertion, which is why the accept twin's "no delay was
# paid" half exists.
# =================================================================================================

apply_exact "$STRAT" \
'        if (after == expected || after == Existence::Unknown)
        {
            break;
        }' \
'        if (after != expected)
        {
            break;
        }' \
    1
if [[ $? -ne 0 ]]; then anchor_moved "M5  the retry loop spins on success instead of on Present"; else

NAMED_BY=GroupMeterFixture.TheDeleteReCheckIsRetriedAndBounded
RED_LIST=(
    GroupMeterFixture.TheDeleteReCheckIsRetriedAndBounded
)
# Every final verdict is the same -- the loop still ends with `after` holding the last answer --
# so nothing that reads only the OpResult can see this.
GREEN_LIST=(
    GroupMeterFixture.AGroupTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
    GroupMeterFixture.AMeterTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted
    GroupMeterFixture.DeletingAGroupThatIsThereGoesThroughAndSaysItWasDeleted
    GroupMeterFixture.AGroupIdCanBeInstalledAgainAfterAVerifiedDelete
)
mutate "M5  the retry loop spins on success instead of on Present"
fi

# =================================================================================================
# WIDENINGS -- behaviour-preserving edits that must all stay GREEN.
# =================================================================================================

apply_exact "$STRAT" \
'    for (int attempt = 0; attempt < VERIFY_ATTEMPTS; ++attempt)' \
'    for (int attempt = 0; attempt != VERIFY_ATTEMPTS; ++attempt)' \
    1
if [[ $? -ne 0 ]]; then
    echo "  🔴 W1 anchor moved"; HARNESS_FAULT=1; restore
else
    widen "W1  '<' becomes '!=' over the same bound (an equivalent loop)"
fi

# Re-pointed (#87): both verbs now share one construction, `OpResult::failure(502, what)`.
# 🔴 That is also why the new #87 tests assert the status code at the ENDPOINT layer and not at
# the strategy -- a strategy-level EXPECT_EQ(httpStatus, 502) would turn this widening red and
# cost this gate its control.
apply_exact "$STRAT" \
'        auto failed = OpResult::failure(502, what).withOutcome(outcome);' \
'        auto failed = OpResult::failure(503, what).withOutcome(outcome);' \
    1
if [[ $? -ne 0 ]]; then
    echo "  🔴 W2 anchor moved"; HARNESS_FAULT=1; restore
else
    widen "W2  502 becomes 503 (still a non-2xx naming the far end)"
fi

apply_exact "$STRAT" \
'                ? named + " is still on the switch after the delete was forwarded and "
                          "acknowledged; it was NOT deleted"' \
'                ? named + " is still on the switch -- the delete was acknowledged by the "
                          "controller and not carried out by the switch"' \
    1
if [[ $? -ne 0 ]]; then
    echo "  🔴 W3 anchor moved"; HARNESS_FAULT=1; restore
else
    widen "W3  the failure sentence is reworded (the phrase under test is kept)"
fi

apply_exact "$STRAT" \
'        if (attempt > 0)' \
'        if (attempt >= 1)' \
    1
if [[ $? -ne 0 ]]; then
    echo "  🔴 W4 anchor moved"; HARNESS_FAULT=1; restore
else
    widen "W4  'attempt > 0' becomes 'attempt >= 1' (the same predicate)"
fi

# =================================================================================================
# C -- CONTROL. A comment-only edit.
#
# Not a mutation and not counted as one. It changes a byte in the file the mutations touch,
# forces the same rebuild, and must leave the suite green. Without it, every "went red" above
# could equally be explained by the rebuild itself.
# =================================================================================================

printf '\n=== C   CONTROL: comment-only edit, must stay green ===\n'
apply_exact "$STRAT" \
'    // [Co-developed with claude code -- Adam] Finding #1, part 2 of 2: what is claimed.' \
'    // CONTROL EDIT (mutation gate; restored below). Finding #1, part 2 of 2: what is claimed.' \
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

printf '\n%d mutations, %d survived; %d widenings, %d went red\n' \
    "$MUTATIONS" "$SURVIVORS" "$WIDENINGS" "$WIDENINGS_RED"

if [[ "$IDENTICAL" -ne 1 || "$HARNESS_FAULT" -ne 0 ]]; then
    echo "harness fault or restore failure -- the score above does not stand" >&2
    exit 2
fi
if [[ "$SURVIVORS" -gt 0 ]]; then
    echo "a surviving mutation means that behaviour is untested" >&2
    exit 1
fi
if [[ "$WIDENINGS_RED" -gt 0 ]]; then
    echo "a widening went red -- the tests are pinned to an incidental, not to the behaviour" >&2
    exit 1
fi
echo "every mutation caught by its named guard, every widening green, baseline restored"
exit 0
