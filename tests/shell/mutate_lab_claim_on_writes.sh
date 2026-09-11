#!/usr/bin/env bash
#
# Mutation gate for the lab claim on a write reply -- doc/KNOWN-ISSUES.md G-32, option C.
#
# [Co-developed with claude code -- Adam]
#
# Structure, mechanics and wording are lifted from mutate_cpu_report_no_ip.sh, which gates a
# neighbouring change over the same kind of seam. Copied rather than shared for the reason that
# gate gives: a common harness is a second place for the answer to be wrong, and
# check_gate_anchors.py reads each gate's own anchors.
#
# WHAT IT GATES. Measured 2026-09-11 02:01:16-02:02:45 (ROLE-4 T4, written up in
# scratch/overnight-2026-09-05/fix/FIX-NDT-3-SUMMARY.md section 7-1): a loop firing
# install_flow_entry and delete_flow_entry every two seconds got 200 through the second its own
# claim expired, and kept getting 200 after a different owner took the claim, until that owner
# tore the kernel down. Adam's ruling of 2026-09-11 was option C: the kernel REPORTS the claim on
# every write reply and logs one line when it changes, and refuses nothing.
#
# 🔴 M8 IS THE ONE THAT MATTERS MOST, and it is the only mutation here that makes the kernel say
# MORE rather than less: it marks every POST instead of the twelve that program the fabric. If it
# survives, this suite is pinning "the key exists" and not "the key means something" -- a claim on
# Ryu's own notification would be noise, and B-6 keeps that a separate route on purpose.
#
# M6 is its mirror on the log side: one line per REQUEST rather than per change. It leaves every
# key correct and every state correct, and would have put 1800 identical WARNs an hour into the
# log the 02:01 round was read out of.
#
# C1 is the control: a behaviour-preserving comment edit that must stay GREEN. Without it, a
# harness that reports red for any edit at all -- a stale binary, a build that silently failed, a
# filter that matches nothing -- would look like a perfect mutation score.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. Baseline is the WORKING TREE, not HEAD, so this
# runs against an uncommitted fix. These files are in a worktree other sessions write to.
#
# Assumptions (stated because they are the script's failure modes):
#   * cwd is the repo root, or this script is run by path from anywhere -- it cds to its own ../..
#   * ${BUILD_DIR:-build} is an already-configured build directory (ninja)
#   * the suite is linked into the test_routing_strategy binary, per tests/CMakeLists.txt
#   * builds go through tools/build_guard/guarded_build.sh unless NO_GUARD=1 -- this laptop's
#     systemd-oomd kills the user's own application when an unguarded build takes the memory
#   * the contract lane runs tests/python/test_contract_spec.py with ${PYTHON:-/usr/bin/python3};
#     it imports only the standard library plus tools/contract_test
#
# Usage:
#   bash tests/shell/mutate_lab_claim_on_writes.sh
#   BUILD_DIR=build-debug bash tests/shell/mutate_lab_claim_on_writes.sh
#
# Exit codes:
#   0  every mutation was caught and the control stayed green
#   1  at least one mutation survived, or one could not be applied/built
#   2  a baseline is not green -- the compile or the fix is the problem, not a mutation
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC=src/ndt_core/http/HttpSession.cpp
SPEC=tools/contract_test/spec.py
FILES=("$SRC" "$SPEC")

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
BIN="${BIN:-$BUILD_DIR/bin/$TARGET}"
FILTER="${FILTER:-LabClaimOnWriteRepliesTest.*:GroupMeterEndpointTest.*}"
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"
PYTHON="${PYTHON:-/usr/bin/python3}"
PYTEST_FILE=tests/python/test_contract_spec.py
PYTEST_CLASS=LabClaimOnWriteRepliesTest

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1").$(echo "$1" | md5sum | cut -c1-6)"; }
for f in "${FILES[@]}"; do cp "$f" "$(snap "$f")"; done
restore() { local f; for f in "${FILES[@]}"; do cp "$(snap "$f")" "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
INVALID=0

# --- mechanics ---------------------------------------------------------------------------------

# Exact-string replacement. \Q..\E makes the pattern literal, so anchors carry braces, %, < and >
# without escaping; the replacement is interpolated once and used verbatim.
apply() {   # $1 = file, $2 = exact anchor, $3 = replacement
    ANCHOR="$2" REPL="$3" perl -0777 -i -pe 's/\Q$ENV{ANCHOR}\E/$ENV{REPL}/' "$1"
}

# 🔴 `grep -c -F` is the WRONG TOOL for a multi-line anchor and this gate never uses it for the
# verdict: grep splits an -F pattern on newlines, treats the pieces as alternatives, and counts
# LINES matching any of them. Measured on trunk 6c4000eb (hunt-0911/F-B0-B12-REPORT.md §2.2) a
# five-line anchor in a sibling gate counted 549 that way and its control was never applied. The
# exact substring count comes from python, the way mutate_bx_flow_liveness.sh has done it since
# 2026-09-08.
count_exact() {   # $1 = file, $2 = anchor, one line or many
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

# An anchor that matches twice would mutate two places at once and the result would not say which
# one the test caught.
assert_unique() {   # $1 = file, $2 = anchor
    local n first g
    n=$(count_exact "$1" "$2")
    if [[ "$n" -ne 1 ]]; then
        first=${2%%$'\n'*}
        g=$(grep -c -F -- "$first" "$1" || true)
        printf '  INVALID  anchor matches %s times in %s (want 1; grep on its first line: %s): %s\n' \
            "$n" "$1" "$g" "$first"
        return 1
    fi
    return 0
}

# Every build in this gate goes through the guard: JOBS=1 because HttpSession.cpp and LLMAgent.cpp
# take ~1.6 GB each and two at once exceed the guard's MemoryHigh, and because an unguarded build
# on this laptop is what got the user's application killed by systemd-oomd on 2026-09-02.
# NO_GUARD=1 is for a machine where the guard is not installed; say so in the log if you use it.
build() {
    if [[ "${NO_GUARD:-0}" == "1" || ! -x "$GUARD" ]]; then
        cmake --build "$BUILD_DIR" --target "$TARGET" >"$BK/build.log" 2>&1
    else
        LOCK_WAIT="${LOCK_WAIT:-10800}" JOBS=1 "$GUARD" \
            cmake --build "$BUILD_DIR" --target "$TARGET" -j1 >"$BK/build.log" 2>&1
    fi
}

# rc captured directly, never through a pipe: `cmd | tail` reports tail's status.
run_suite() {
    "$BIN" --gtest_filter="$FILTER" >"$BK/run.log" 2>&1
}

run_contract() {
    "$PYTHON" "$PYTEST_FILE" "$PYTEST_CLASS" >"$BK/py.log" 2>&1
}

# --- baselines ---------------------------------------------------------------------------------

echo "build dir: $BUILD_DIR   target: $TARGET   filter: $FILTER"
echo "contract:  $PYTHON $PYTEST_FILE $PYTEST_CLASS"
echo
echo "baseline (unmutated) must build and be green:"
build; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline build failed (rc=$rc) -- the fix or the new test does not compile."
    tail -40 "$BK/build.log" | sed 's/^/    /'
    exit 2
fi
if [[ ! -x "$BIN" ]]; then
    echo "  REFUSE: $BIN is missing or not executable after a successful build."
    exit 2
fi
run_suite; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline is not green (rc=$rc). Failing tests:"
    grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'
    exit 2
fi
if ! grep -qE '^\[  PASSED  \] [1-9]' "$BK/run.log"; then
    echo "  REFUSE: the filter '$FILTER' ran no tests. A gate over zero tests proves nothing."
    tail -20 "$BK/run.log" | sed 's/^/    /'
    exit 2
fi
printf '  ok       cpp baseline green (%s)\n' "$(grep -E '^\[  PASSED  \]' "$BK/run.log" | tail -1)"
run_contract; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: the contract baseline is not green (rc=$rc):"
    tail -20 "$BK/py.log" | sed 's/^/    /'
    exit 2
fi
printf '  ok       contract baseline green (%s)\n' "$(grep -E '^Ran [0-9]+ test' "$BK/py.log" | tail -1)"
echo

# --- reporting ---------------------------------------------------------------------------------

# $1 = name, $2 = the test that MUST go red, $3 = file, $4 = anchor, $5 = replacement,
# $6 = the lane: "cpp" (default) or "contract". ($7, when given, is the line whose uniqueness is
# asserted, for an anchor whose own first line is not unique.)
mutate_must_die() {
    local name="$1" must_fail="$2" file="$3" anchor="$4" repl="$5" lane="${6:-cpp}"
    local uniq="${7:-$4}"
    local rc

    MUTATIONS=$((MUTATIONS + 1))

    if ! assert_unique "$file" "$uniq"; then
        INVALID=$((INVALID + 1)); restore; return
    fi

    apply "$file" "$anchor" "$repl"
    # A no-op "mutation" leaves the suite green and would be reported as SURVIVED, which would be
    # a lie about the test rather than about the code.
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-50s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi

    if [[ "$lane" == "cpp" ]]; then
        build; rc=$?
        if [[ "$rc" -ne 0 ]]; then
            printf '  INVALID  %-50s (mutant does not compile, rc=%s)\n' "$name" "$rc"
            tail -12 "$BK/build.log" | sed 's/^/             /'
            INVALID=$((INVALID + 1)); restore; return
        fi
        run_suite; rc=$?
        if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $must_fail" "$BK/run.log"; then
            printf '  caught   %-50s (%s went red)\n' "$name" "$must_fail"
        elif [[ "$rc" -ne 0 ]]; then
            printf '  SURVIVED %-50s (something else went red, not %s)\n' "$name" "$must_fail"
            grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             also red: /'
            SURVIVORS=$((SURVIVORS + 1))
        else
            printf '  SURVIVED %-50s (%s stayed green -- that test proves nothing)\n' \
                "$name" "$must_fail"
            SURVIVORS=$((SURVIVORS + 1))
        fi
    else
        run_contract; rc=$?
        if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $must_fail" "$BK/py.log"; then
            printf '  caught   %-50s (%s went red)\n' "$name" "$must_fail"
        elif [[ "$rc" -ne 0 ]]; then
            printf '  SURVIVED %-50s (something else went red, not %s)\n' "$name" "$must_fail"
            grep -E '^(FAIL|ERROR):' "$BK/py.log" | sed 's/^/             also red: /'
            SURVIVORS=$((SURVIVORS + 1))
        else
            printf '  SURVIVED %-50s (%s stayed green -- that test proves nothing)\n' \
                "$name" "$must_fail"
            SURVIVORS=$((SURVIVORS + 1))
        fi
    fi
    restore
}

# A control. Same machinery, opposite expectation: a behaviour-preserving edit must stay green.
mutate_must_live() {
    local name="$1" file="$2" anchor="$3" repl="$4"
    local rc

    MUTATIONS=$((MUTATIONS + 1))

    if ! assert_unique "$file" "$anchor"; then
        INVALID=$((INVALID + 1)); restore; return
    fi

    apply "$file" "$anchor" "$repl"
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-50s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi

    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-50s (control does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi

    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ok       %-50s (control stayed green, as it must)\n' "$name"
    else
        printf '  SURVIVED %-50s (control went RED -- the harness reports red for any edit,\n' "$name"
        printf '           %-50s  so every "caught" above is worthless)\n' ""
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

echo "mutations:"

# --- M1: what the claim file says is thrown away -----------------------------------------------
# The state before option C, and the state a `--mode physical` kernel is legitimately in: the
# reply carries the key and it always says "none". A suite that only checked for the key's
# presence would stay green through this.
#
# 🔴 THE CALL STAYS AND ONLY ITS RESULT GOES, and that is not a softer mutation -- it is the same
# one. Dropping the call as well does not compile: readLabClaimFile lives in an anonymous
# namespace with no other caller, and this build is -Werror -Wunused-function, so the mutant was
# reported INVALID ("mutant does not compile") on the first run of this gate rather than caught.
# An INVALID is not a pass and not a failure; it is a cell nobody measured, so the mutation is
# written to measure. What reaches the reply is byte-for-byte what it would be with no read at
# all: a default-constructed LabClaimFields, fileRead = false, state "none".
mutate_must_die \
    "M1 what the claim file says is thrown away" \
    "LabClaimOnWriteRepliesTest.EveryWriteEndpointCarriesTheClaimAndTheNotificationDoesNot" \
    "$SRC" \
    '        const LabClaimFields fields = readLabClaimFile(path);' \
    '        static_cast<void>(readLabClaimFile(path));
        const LabClaimFields fields{};'

# --- M2: an expired claim is reported as active ------------------------------------------------
# The first half of what was measured: the writer's own claim ran out and nothing said so. `&&`
# to `||` -- the smallest edit that makes a lapsed claim read live while leaving an unreadable
# expiry alone, so M3 below stays a separate question.
mutate_must_die \
    "M2 an expired claim reads as active" \
    "LabClaimOnWriteRepliesTest.AClaimThatHasRunOutIsExpiredAndStillNamesItsOwner" \
    "$SRC" \
    '            state = (fields.expiresParsed && fields.expiresAt > now) ? kLabClaimStateActive' \
    '            state = (fields.expiresParsed || fields.expiresAt > now) ? kLabClaimStateActive'

# --- M3: an unreadable expiry is taken for a live claim ----------------------------------------
# ndt's own header says any script may write this file, so `expires=soon` is reachable rather
# than hypothetical. A claim that cannot say when it ends is not a live claim, and foreign_claim
# agrees. This mutant only changes the unreadable case, which is what makes it distinct from M2.
mutate_must_die \
    "M3 an unreadable expiry reads as active" \
    "LabClaimOnWriteRepliesTest.AClaimWithNoReadableExpiryIsNotReportedAsActive" \
    "$SRC" \
    '            state = (fields.expiresParsed && fields.expiresAt > now) ? kLabClaimStateActive' \
    '            state = (!fields.expiresParsed || fields.expiresAt > now) ? kLabClaimStateActive'

# --- M4: the line is split on its last `=` rather than its first -------------------------------
# `ndt down` writes `...; cleared measuring=iperf3 -c 10.0.0.33 -t 200`. Splitting anywhere but
# the first `=` truncates exactly the note that says what was running.
mutate_must_die \
    "M4 the line is split on its last equals sign" \
    "LabClaimOnWriteRepliesTest.ANoteContainingAnEqualsSignSurvivesTheParse" \
    "$SRC" \
    '        const auto eq = line.find('"'"'='"'"');' \
    '        const auto eq = line.rfind('"'"'='"'"');'

# --- M5: the change is never logged ------------------------------------------------------------
# Option C with its one deliverable removed. Every key is still correct and every state is still
# correct; the handover simply leaves no trace, which is the 02:01 round all over again.
mutate_must_die \
    "M5 a change of hands is not logged" \
    "LabClaimOnWriteRepliesTest.TheClaimChangingHandsIsLoggedOncePerChangeAndRefusesNothing" \
    "$SRC" \
    '    noteLabClaimChange(state, owner, expiresAt);' \
    '    // noteLabClaimChange(state, owner, expiresAt);'

# --- M6: one line per request instead of one per change ----------------------------------------
# 🔴 The mirror of M8, on the log side. Nothing is wrong with any value; the kernel just says it
# 1800 times an hour, which is how a real signal gets lost in a log somebody has to read.
mutate_must_die \
    "M6 the line is logged once per request" \
    "LabClaimOnWriteRepliesTest.TheClaimChangingHandsIsLoggedOncePerChangeAndRefusesNothing" \
    "$SRC" \
    '        if (ledger.seen && ledger.state == state && ledger.owner == owner &&
            ledger.expiresAt == expiresAt)
        {
            return;
        }' \
    '        if (false)
        {
            return;
        }' \
    cpp \
    '        if (ledger.seen && ledger.state == state && ledger.owner == owner &&'

# --- M7: one endpoint falls off the list -------------------------------------------------------
# The failure the list-shaped case exists for: the key on eleven of the twelve, and a consumer
# that reads reply["lab_claim"]["state"] throwing on the one nobody remembered.
mutate_must_die \
    "M7 modify_meter_entry loses the mark" \
    "LabClaimOnWriteRepliesTest.EveryWriteEndpointCarriesTheClaimAndTheNotificationDoesNot" \
    "$SRC" \
    '        "/ndt/modify_meter_entry",
        "/ndt/inject_link_failure",' \
    '        "/ndt/inject_link_failure",' \
    cpp \
    '        "/ndt/modify_meter_entry",'

# --- M8: the mark goes on every POST -----------------------------------------------------------
# 🔴 THE ONE THAT MATTERS MOST, and the only mutation here that makes the kernel say more rather
# than less. Every assertion about the twelve still holds; what goes is the selectivity, and with
# it the meaning -- the claim answers "should I be programming this fabric", and B-6 keeps Ryu's
# own notification a separate route precisely because it is a different act.
mutate_must_die \
    "M8 widening: every POST carries the claim" \
    "LabClaimOnWriteRepliesTest.EveryWriteEndpointCarriesTheClaimAndTheNotificationDoesNot" \
    "$SRC" \
    '    for (const std::string_view write : kWrites)
    {
        if (target == write)
        {
            return true;
        }
    }
    return false;' \
    '    (void)kWrites;
    (void)target;
    return true;' \
    cpp \
    '    for (const std::string_view write : kWrites)'

# --- M9 [contract]: the state vocabulary is opened up ------------------------------------------
# Cheap lane, no rebuild. The schema is the only side of this change an external consumer is
# checked against, so a state the kernel never emits passing it is a defect nothing else here
# can see.
mutate_must_die \
    "M9 [contract] the state vocabulary is opened up" \
    "test_the_schema_pins_the_state_vocabulary" \
    "$SPEC" \
    '    "state": Str(allowed=("none", "active", "expired")),' \
    '    "state": Str(),' \
    contract

# --- M10 [contract]: the three flow writes forget the key --------------------------------------
# One edit takes it from all three, which is the point of their sharing one dict: three copies of
# the same optional set is three places for it to drift.
mutate_must_die \
    "M10 [contract] the flow writes forget the key" \
    "test_every_write_endpoint_declares_the_key_optional" \
    "$SPEC" \
    'FLOW_WRITE_OPTIONAL = {"detail": Str(), "lab_claim": LAB_CLAIM}' \
    'FLOW_WRITE_OPTIONAL = {"detail": Str()}' \
    contract

# --- C1: control, comment text only ------------------------------------------------------------
# If this goes red, the harness is measuring "did anything change" rather than "did behaviour
# change", and every "caught" line above is meaningless.
mutate_must_live \
    "C1 control-comment-only" \
    "$SRC" \
    '// says "here is the claim for this lab"; its absence says "this deployment has no claim file",' \
    '// CONTROL EDIT: comment text only, no behaviour change -- see G-32 for the reasoning,'

# --- restoration and verdict -------------------------------------------------------------------

restore
echo
ok=1
for f in "${FILES[@]}"; do
    cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }
done
if [[ "$ok" == 1 ]]; then
    echo "baseline restored: both files byte-identical to the pre-run snapshot"
else
    echo "🔴 the working tree was left mutated -- do not commit until this is sorted out"
fi

# Rebuild from the restored source so the build directory agrees with the tree: otherwise the next
# ctest run would execute the last mutant's binary and read as a spurious failure.
echo "rebuilding from the restored source:"
build; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  🔴 rebuild after restore failed (rc=$rc) -- the tree may not be what it was"
    tail -20 "$BK/build.log" | sed 's/^/    /'
    ok=0
else
    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        echo "  ok       green again from the restored source"
    else
        echo "  🔴 NOT green after restore (rc=$rc):"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'
        ok=0
    fi
fi

echo
printf '%d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
if [[ "$INVALID" -gt 0 ]]; then
    printf '%d could not be applied or built -- neither caught nor survived; a human must look\n' \
        "$INVALID"
fi

[[ "$SURVIVORS" -eq 0 && "$INVALID" -eq 0 && "$ok" == 1 ]]
