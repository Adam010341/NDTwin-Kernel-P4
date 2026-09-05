#!/usr/bin/env bash
# Mutation gate for the FlowRateDenominator suite in tests/test_RateDenominator.cpp.
#
# [Co-developed with claude code -- Adam]
#
# WHY A SECOND SCRIPT RATHER THAN FIVE MORE SLOTS IN mutate_rate_denominator.sh.
# That one is ticket Q's evidence for the LINK path and it is cited as such. This is the flow
# path, it mutates different files, and it must not be able to change the recorded verdict of the
# other. Keeping them apart also keeps each runnable on its own: a header this one mutates
# (common_types/SFlowType.hpp) rebuilds ~60 translation units, so a combined script would cost
# half an hour to answer either question.
#
# WHAT COUNTS AS A SURVIVOR -- identical to the link gate, and restated rather than referenced
# because a reader deciding whether to trust this run must not have to open another file:
#   nothing went red          the behaviour is untested
#   wrong test went red       the gate fires, but not for the reason the header claims
#   mutant does not compile   the test never ran against this mutant, so it proves nothing
#   anchor missing            the mutation was never applied, so it proves nothing
#
# EXIT CODES
#   0  every mutation was killed
#   1  at least one survivor (a real verdict: the suite is weaker than it claims)
#   2  harness fault -- the run measured nothing
#
# 🔴 BUILD DIRECTORY. Defaults to build-flowrate, NOT build. On 2026-09-02 a shared build/ was
# relinked while a measurement round was reading build/bin/ndtwin_kernel and the recorded binary
# was permanently lost. This gate rebuilds ~60 objects per mutation; it must never do that in a
# tree somebody else's kernel is linked from.
#
# 🔴 BUILD PARALLELISM. Every build goes through tools/build_guard/guarded_build.sh (JOBS=1,
# LOCK_WAIT=10800) -- the wide -j$(nproc) this laptop's systemd-oomd killed the user's own
# application over on 2026-09-02. 2026-09-04: this used to point BUILD_LOCK/BUILD_SHIM at a
# SPECIFIC AGENT SESSION's own scratchpad (a /tmp/claude-1000/.../<session-uuid>/scratchpad path)
# -- gone the moment that session ended, at which point flock and the PATH shim silently stopped
# doing anything (a missing lock file is not a locked one; a missing shim directory just is not on
# PATH) and this gate would have run an unguarded, unlimited-parallelism build without saying so.
# NO_GUARD=1 is for a machine where the guard is not installed; say so in the log if you use it.
#
# Usage: tests/shell/mutate_flow_rate_denominator.sh
#        BUILD_DIR=out tests/shell/mutate_flow_rate_denominator.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build-flowrate}"
GUARD="${GUARD:-tools/build_guard/guarded_build.sh}"

SFT=include/common_types/SFlowType.hpp                       # the arithmetic and its guard
FLUC=src/ndt_core/collection/FlowLinkUsageCollector.cpp      # the wiring
FHDR=include/ndt_core/collection/FlowLinkUsageCollector.hpp  # the divisor's sentinel

SUITE=FlowRateDenominator
MUTATIONS=0
SURVIVORS=0
SURVIVOR_LIST=()

harness_fault() {
    printf '\n🔴 HARNESS FAULT: %s\n' "$1" >&2
    printf '   This run measured nothing. It is not a pass and not a survivor count.\n' >&2
    printf '   Reached mutation slot %d of 5.\n' "$MUTATIONS" >&2
    exit 2
}

[[ -d "$BUILD_DIR" ]] || harness_fault "build directory '$BUILD_DIR' does not exist"

# One backup per file, taken before anything is touched, with its sha as the restore criterion.
declare -A BAK SHA
for f in "$SFT" "$FLUC" "$FHDR"; do
    SHA["$f"]=$(sha256sum "$f" | cut -d' ' -f1)
    BAK["$f"]=$(mktemp)
    cp -p "$f" "${BAK[$f]}"
done

restore_file() {
    local f="$1"
    cp -p "${BAK[$f]}" "$f"
    # cp -p restores the ORIGINAL mtime, which is older than the object built from the mutant,
    # so ninja would see nothing to do and the next slot would silently test the mutant while
    # the source on disk looked pristine. touch is what actually restores the build.
    touch "$f"
    local now; now=$(sha256sum "$f" | cut -d' ' -f1)
    [[ "$now" == "${SHA[$f]}" ]] || { echo "🔴 RESTORE FAILED -- $f. Do NOT commit." >&2; return 1; }
    return 0
}

restore_all() {
    local rc=0
    for f in "$SFT" "$FLUC" "$FHDR"; do restore_file "$f" || rc=1; done
    return $rc
}

# Every path out, including an interrupt part-way through a mutation: the sources must never be
# left mutated on disk for someone else to read or archive.
cleanup_on_exit() {
    local rc=$?
    trap - EXIT
    restore_all || rc=2
    for f in "$SFT" "$FLUC" "$FHDR"; do rm -f "${BAK[$f]}"; done
    exit "$rc"
}
trap cleanup_on_exit EXIT

build_it() {
    if [[ "${NO_GUARD:-0}" == "1" || ! -x "$GUARD" ]]; then
        cmake --build "$BUILD_DIR" --target test_routing_strategy >/dev/null 2>&1
    else
        LOCK_WAIT="${LOCK_WAIT:-10800}" JOBS=1 "$GUARD" \
            cmake --build "$BUILD_DIR" --target test_routing_strategy -j1 >/dev/null 2>&1
    fi
}

failed_tests() { sed -n "s/^\[  FAILED  \] \($SUITE\.[A-Za-z0-9_]*\).*/\1/p" | sort -u | tr '\n' ' '; }

record_killed()  { MUTATIONS=$((MUTATIONS + 1)); printf '  ✅ KILLED\n'; }
record_survivor() {
    MUTATIONS=$((MUTATIONS + 1)); SURVIVORS=$((SURVIVORS + 1))
    SURVIVOR_LIST+=("$1 -- $2"); printf '  🔴 SURVIVED (%s)\n' "$2"
}

# $1 = label, $2 = file to mutate, $3 = python program (old->new), $4 = expected test name
run_mutation() {
    local label="$1" file="$2" prog="$3" expected="$4"
    printf '\n=== %s ===\n  file:   %s\n  expect: %s.%s\n' "$label" "$file" "$SUITE" "$expected"
    if ! python3 - "$file" <<<"$prog"; then
        echo "  ⚠️  mutation could not be applied -- the anchor text has moved. NOT a pass." >&2
        record_survivor "$label" "anchor missing"; restore_file "$file"; return
    fi
    if ! build_it; then
        echo "  ⚠️  mutant does not compile -- this mutation proves nothing about the tests."
        record_survivor "$label" "mutant does not compile"
        restore_file "$file" || harness_fault "$file did not come back byte-identical"; return
    fi
    local out failed
    out=$("$BUILD_DIR/bin/test_routing_strategy" --gtest_filter="$SUITE.*" 2>&1)
    failed=$(failed_tests <<<"$out")
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        record_survivor "$label" "nothing went red"
    elif grep -q "$SUITE\.$expected" <<<"$failed"; then
        echo "  ✅ red: $failed"
        record_killed
    else
        echo "  🔴 WRONG TEST WENT RED: got [$failed], expected [$expected]"
        record_survivor "$label" "wrong test went red"
    fi
    restore_file "$file" || harness_fault "$file did not come back byte-identical"
}

# --- BASELINE ------------------------------------------------------------------------------
# A mutation run against a red baseline measures nothing: every "red" it then sees could be the
# pre-existing failure rather than the mutant.
printf '=== baseline: the unmutated tree must be green ===\n'
build_it || harness_fault "the unmutated tree does not build -- no mutation was applied"
base_out=$("$BUILD_DIR/bin/test_routing_strategy" --gtest_filter="$SUITE.*:RateDenominator.*" 2>&1)
base_failed="$(failed_tests <<<"$base_out")"
if [[ -n "${base_failed// /}" ]] || ! grep -q "\[  PASSED  \]" <<<"$base_out"; then
    echo "  red at baseline: $base_failed" >&2
    harness_fault "the suite is already red before any mutation"
fi
printf '  ✅ green -- %s\n' "$(grep -o '\[  PASSED  \].*' <<<"$base_out" | head -1)"

# --- F1: the defect itself ------------------------------------------------------------------
# This restores the expression the kernel actually shipped: delta * 8 * samplingRate, with no
# division. Seeing the named test red against it IS the "seen failing against the unfixed code"
# observation for this ticket, and unlike a one-off manual check it is reproducible.
run_mutation "F1. drop the division on the BIT rate (restores the shipped defect)" "$SFT" '
import sys,pathlib
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old="static_cast<double>(byteDelta) * 8.0 * samplingScale / elapsedSeconds)"
new="static_cast<double>(byteDelta) * 8.0 * samplingScale)"
assert old in s, "anchor missing"
p.write_text(s.replace(old,new,1))
' FlowSameBytesOverTwoSecondsIsHalfTheRate

run_mutation "F2. drop the division on the PACKET rate" "$SFT" '
import sys,pathlib
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old="static_cast<double>(packetDelta) * samplingScale / elapsedSeconds)"
new="static_cast<double>(packetDelta) * samplingScale)"
assert old in s, "anchor missing"
p.write_text(s.replace(old,new,1))
' FlowPacketRateIsPerSecondToo

run_mutation "F3. accept a zero interval (> becomes >=)" "$SFT" '
import sys,pathlib
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old="    if (!(elapsedSeconds > 0.0))\n    {\n        return false;"
new="    if (!(elapsedSeconds >= 0.0))\n    {\n        return false;"
assert old in s, "anchor missing"
p.write_text(s.replace(old,new,1))
' ZeroIntervalLeavesTheFlowAlone

# --- F4: THE WIRING -------------------------------------------------------------------------
# The mutation an arithmetic-only suite cannot kill, and the exact shape of what this ticket is
# repairing: a correct divider handed an assumed one-second interval. Every other test in the
# suite stays green against it.
run_mutation "F4. the loop assumes a 1 s period instead of measuring it (WIRING)" "$FLUC" '
import sys,pathlib
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old="        std::chrono::duration<double>(nowFlowDrain - m_lastFlowDrainAt).count();"
new="        1.0;   // MUTANT: assume the loop period is exactly one second"
assert old in s, "anchor missing"
p.write_text(s.replace(old,new,1))
' TheFlowDivisorIsMeasuredNotAssumed

run_mutation "F5. the flow divisor sentinel -1.0 becomes 0.0" "$FHDR" '
import sys,pathlib
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old="m_lastFlowRateDivisorSeconds{-1.0}"
new="m_lastFlowRateDivisorSeconds{0.0}"
assert old in s, "anchor missing"
p.write_text(s.replace(old,new,1))
' TheFlowDivisorStartsAtASentinelNotZero

# --- after restore --------------------------------------------------------------------------
restore_all || harness_fault "a source did not come back byte-identical after the last mutation"
build_it || harness_fault "the tree does not build after the final restore -- the verdicts above \
were measured, but the tree you are left with is not the one they were measured on"
printf '\n--- after restore: the suite must be green again ---\n'
final=$("$BUILD_DIR/bin/test_routing_strategy" --gtest_filter="$SUITE.*:RateDenominator.*" 2>&1)
if grep -q "^\[  FAILED  \]" <<<"$final"; then
    echo "🔴 THE SUITE IS RED AFTER RESTORE -- a mutant is still built in. Do NOT commit."
    grep "^\[  FAILED  \]" <<<"$final" | sort -u
    harness_fault "the suite is red after the final restore"
fi
grep -o '\[  PASSED  \].*' <<<"$final" | head -1

printf '\n--- verdict ---\n'
for s in "${SURVIVOR_LIST[@]:-}"; do [[ -n "$s" ]] && printf '  survived: %s\n' "$s"; done
printf '%d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
((SURVIVORS == 0)) || exit 1
exit 0
