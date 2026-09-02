#!/usr/bin/env bash
# Mutation gate for tests/test_RateDenominator.cpp (ticket Q).
#
# A test that has never been seen to fail is a decoration. This applies each mutation named in
# that file's header, rebuilds, and records WHICH test went red -- not merely that something did.
# Two of this project's tests have previously turned red on a mutation aimed at a different
# behaviour, so "the gate works" is only established by the identity of the failure.
#
# WHAT COUNTS AS A SURVIVOR
# A mutation is KILLED only when the test the header names actually went red against it.
# Everything else is a SURVIVOR, because a survivor is defined by what we failed to learn, not
# by whether the harness had a bad day:
#   nothing went red          the behaviour is untested
#   wrong test went red       the gate fires, but not for the reason the header claims
#   mutant does not compile   the test never ran against this mutant, so it proves nothing
#   anchor missing            the mutation was never applied, so it proves nothing
# The last two used to print a warning and be skipped, which meant a run in which every single
# mutant failed to compile ended looking exactly like a clean pass. An unmeasured mutation is
# not a mutation that passed.
#
# EXIT CODES
#   0  every mutation was killed
#   1  at least one survivor (a real verdict: the suite is weaker than it claims)
#   2  harness fault -- the run measured nothing (red baseline, build directory missing,
#      a restore that was not byte-identical, or a suite still red after the final restore)
# A survivor is never reported as a 2, and a harness fault is never reported as a 1.
#
# The baseline is checksummed before anything is touched and re-checked after every restore: an
# interrupted mutation run once left a mutant on disk that was then archived as a baseline.
#
# Usage: tests/shell/mutate_rate_denominator.sh
#        BUILD_DIR=out tests/shell/mutate_rate_denominator.sh   # defaults to ./build
# [Co-developed with claude code -- Adam]
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
FLUC=src/ndt_core/collection/FlowLinkUsageCollector.cpp
HDR=include/ndt_core/collection/TopologyAndFlowMonitor.hpp

MUTATIONS=0
SURVIVORS=0
SURVIVOR_LIST=()

# A harness fault is not a verdict about the tests -- it says the run itself measured nothing.
# It must never be dressed up as a survivor count, so it exits before any summary is printed.
harness_fault() {
    printf '\n🔴 HARNESS FAULT: %s\n' "$1" >&2
    printf '   This run measured nothing. It is not a pass and not a survivor count.\n' >&2
    printf '   Reached mutation slot %d of 5.\n' "$MUTATIONS" >&2
    exit 2
}

if [[ ! -d "$BUILD_DIR" ]]; then
    harness_fault "build directory '$BUILD_DIR' does not exist -- there is nothing to mutate against"
fi

BASELINE_SHA=$(sha256sum "$TARGET" | cut -d' ' -f1)
BACKUP=$(mktemp) ; cp -p "$TARGET" "$BACKUP"
FBAK="" ; FSHA=""
HBAK="" ; HSHA=""
KERNEL_BIN="$BUILD_DIR/bin/ndtwin_kernel"
if [[ -f "$KERNEL_BIN" ]]; then
    KERNEL_SHA_BEFORE=$(sha256sum "$KERNEL_BIN" | cut -d' ' -f1)
else
    KERNEL_SHA_BEFORE="absent"
fi

# $1 = file, $2 = its backup, $3 = its baseline sha. Returns non-zero if the file did not come
# back byte-identical; the caller decides whether that is fatal (it always is).
restore_file() {
    cp -p "$2" "$1"
    # `cp -p` puts the ORIGINAL mtime back, which is older than the object built from the
    # mutant -- so ninja sees nothing to do and the next run tests the mutant while the source
    # on disk is pristine. The sha256 below passes either way: it checks the file, not the
    # artifact built from it. touch is what actually restores the build.
    touch "$1"
    local now; now=$(sha256sum "$1" | cut -d' ' -f1)
    if [[ "$now" != "$3" ]]; then
        echo "🔴 RESTORE FAILED -- $1 is not the baseline. Do NOT commit." >&2
        return 1
    fi
    return 0
}

restore() {
    restore_file "$TARGET" "$BACKUP" "$BASELINE_SHA" \
        || harness_fault "$TARGET did not come back byte-identical"
}

# Every path out of this script goes through here, including an interrupt part-way through a
# mutation: the sources must never be left mutated on disk for someone else to archive.
cleanup_on_exit() {
    local rc=$?
    trap - EXIT
    restore_file "$TARGET" "$BACKUP" "$BASELINE_SHA" || rc=2
    [[ -n "$FBAK" ]] && { restore_file "$FLUC" "$FBAK" "$FSHA" || rc=2; }
    [[ -n "$HBAK" ]] && { restore_file "$HDR" "$HBAK" "$HSHA" || rc=2; }
    rm -f "$BACKUP" ${FBAK:+"$FBAK"} ${HBAK:+"$HBAK"}
    exit "$rc"
}
trap cleanup_on_exit EXIT

record_killed() {
    MUTATIONS=$((MUTATIONS + 1))
    printf '  ✅ KILLED\n'
}

# $1 = mutation label, $2 = reason (one of the four named in the header)
record_survivor() {
    MUTATIONS=$((MUTATIONS + 1))
    SURVIVORS=$((SURVIVORS + 1))
    SURVIVOR_LIST+=("$1 -- $2")
    printf '  🔴 SURVIVED (%s)\n' "$2"
}

# $1 = gtest suite name; reads gtest output on stdin, prints the distinct tests that failed.
failed_tests() {
    sed -n "s/^\[  FAILED  \] \($1\.[A-Za-z0-9_]*\).*/\1/p" | sort -u | tr '\n' ' '
}

build_it() { cmake --build "$BUILD_DIR" --target test_routing_strategy -j4 >/dev/null 2>&1; }

# $1 = label, $2 = python expression replacing old->new, $3 = expected test name
run_mutation() {
    local label="$1" expected="$3"
    printf '\n=== %s ===\n  expect: %s\n' "$label" "$expected"
    if ! python3 - "$TARGET" <<<"$2"; then
        echo "  ⚠️  mutation could not be applied -- the anchor text has moved. NOT a pass." >&2
        record_survivor "$label" "anchor missing"
        restore; return
    fi
    if ! build_it; then
        echo "  ⚠️  mutant does not compile -- this mutation proves nothing about the tests."
        record_survivor "$label" "mutant does not compile"
        restore; return
    fi
    local out
    out=$("$BUILD_DIR/bin/test_routing_strategy" --gtest_filter='RateDenominator.*' 2>&1)
    local failed
    failed=$(failed_tests RateDenominator <<<"$out")
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        record_survivor "$label" "nothing went red"
    elif grep -q "RateDenominator.$expected" <<<"$failed"; then
        echo "  ✅ red: $failed"
        grep -q " " <<<"${failed% }" && echo "     (more than one test caught it -- fine, but the named one did)"
        record_killed
    else
        echo "  🔴 WRONG TEST WENT RED: got [$failed], expected [$expected]"
        echo "     The gate fires, but not for the reason the header claims."
        record_survivor "$label" "wrong test went red"
    fi
    restore
}

echo "baseline $TARGET sha256 ${BASELINE_SHA:0:16}"

# --- BASELINE ------------------------------------------------------------------------------
# A mutation run against a red baseline measures nothing: every "red" it then sees could be the
# pre-existing failure rather than the mutant.
printf '\n=== baseline: the unmutated tree must be green ===\n'
if ! build_it; then
    harness_fault "the unmutated tree does not build -- no mutation was applied"
fi
base_out=$("$BUILD_DIR/bin/test_routing_strategy" --gtest_filter='RateDenominator.*' 2>&1)
base_out+=$'\n'
base_out+=$("$BUILD_DIR/bin/test_routing_strategy" --gtest_filter='LastHopAttributionTest.TheHostBoundSite*' 2>&1)
base_failed="$(failed_tests RateDenominator <<<"$base_out")$(failed_tests LastHopAttributionTest <<<"$base_out")"
if [[ -n "${base_failed// /}" ]]; then
    echo "  red at baseline: $base_failed" >&2
    harness_fault "the suite is already red before any mutation -- no mutation was applied"
fi
echo "  ✅ green"

run_mutation "1. drop the division by elapsedSeconds" '
import sys,pathlib
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old="static_cast<double>(accumulatedBytes) * 8.0 / elapsedSeconds"
new="static_cast<double>(accumulatedBytes) * 8.0"
assert old in s, "anchor missing"
p.write_text(s.replace(old,new,1))
' SameBytesOverTwoSecondsIsHalfTheRate

run_mutation "2. accept a zero interval (> becomes >=)" '
import sys,pathlib
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old="if (!(elapsedSeconds > 0.0))"
new="if (!(elapsedSeconds >= 0.0))"
assert old in s, "anchor missing"
p.write_text(s.replace(old,new,1))
' ZeroIntervalPublishesNothing

run_mutation "4. record the divisor before the guard rejects it" '
import sys,pathlib
p=pathlib.Path(sys.argv[1]); s=p.read_text()
guard="    if (!(elapsedSeconds > 0.0))"
store="    m_lastRateDivisorSeconds.store(elapsedSeconds);\n"
assert guard in s and store in s, "anchor missing"
s=s.replace(store,"",1)
p.write_text(s.replace(guard, store+guard, 1))
' ZeroIntervalDoesNotRecordADivisor

# --- NEGATIVE CONTROL: leave one of the two rate-publishing sites unfixed ------------------
# The auditor's requirement: without having seen this red, "every site is asserted" is a claim
# with no evidence. This reverts creditHostBoundEgressEdges to ignore the interval it is handed,
# which is exactly the partial fix Q-ter warned produces a wrong verdict rather than a visible
# failure.
NEG_LABEL="NEGATIVE CONTROL: host-bound site ignores its interval"
NEG_EXPECT=LastHopAttributionTest.TheHostBoundSiteDividesByTheIntervalItWasGiven
printf '\n=== %s ===\n' "$NEG_LABEL"
echo "  expect: $NEG_EXPECT"
FSHA=$(sha256sum "$FLUC" | cut -d' ' -f1); FBAK=$(mktemp); cp -p "$FLUC" "$FBAK"
if ! python3 - "$FLUC" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "key, value.inputByteCountOnALinkMultiplySampingRate, elapsedSeconds);"
new = "key, value.inputByteCountOnALinkMultiplySampingRate, 1.0);"
assert old in s, "anchor missing"
p.write_text(s.replace(old, new, 1))
PYEOF
then
    echo "  ⚠️  mutation could not be applied -- the anchor text has moved. NOT a pass." >&2
    record_survivor "$NEG_LABEL" "anchor missing"
elif ! build_it; then
    echo "  ⚠️  mutant does not compile -- this mutation proves nothing about the tests."
    record_survivor "$NEG_LABEL" "mutant does not compile"
else
    neg_out=$("$BUILD_DIR/bin/test_routing_strategy" \
        --gtest_filter='LastHopAttributionTest.TheHostBoundSite*' 2>&1)
    neg_failed=$(failed_tests LastHopAttributionTest <<<"$neg_out")
    if [[ -z "$neg_failed" ]]; then
        echo "  🔴 THE PARTIAL FIX SURVIVED -- one site could ship unfixed and nothing would say so."
        record_survivor "$NEG_LABEL" "nothing went red"
    elif grep -q "${NEG_EXPECT#*.}" <<<"$neg_failed"; then
        echo "  ✅ red: the unfixed site is detected ($neg_failed)"
        record_killed
    else
        echo "  🔴 WRONG TEST WENT RED: got [$neg_failed], expected [$NEG_EXPECT]"
        echo "     The gate fires, but not for the reason the header claims."
        record_survivor "$NEG_LABEL" "wrong test went red"
    fi
fi
restore_file "$FLUC" "$FBAK" "$FSHA" || harness_fault "$FLUC did not come back byte-identical"

M3_LABEL="3. sentinel -1.0 becomes 0.0 (header file, run separately)"
printf '\n=== %s ===\n' "$M3_LABEL"
echo "  expect: DivisorStartsAtASentinelNotZero"
HSHA=$(sha256sum "$HDR" | cut -d' ' -f1); HBAK=$(mktemp); cp -p "$HDR" "$HBAK"
sed -i 's/m_lastRateDivisorSeconds{-1\.0}/m_lastRateDivisorSeconds{0.0}/' "$HDR"
if [[ "$(sha256sum "$HDR" | cut -d' ' -f1)" == "$HSHA" ]]; then
    # `sed -i` exits 0 when it matches nothing, so the file's own sha is the only honest
    # evidence that the mutation was applied at all.
    echo "  ⚠️  mutation could not be applied -- the anchor text has moved. NOT a pass." >&2
    record_survivor "$M3_LABEL" "anchor missing"
elif ! build_it; then
    echo "  ⚠️  mutant does not compile -- this mutation proves nothing about the tests."
    record_survivor "$M3_LABEL" "mutant does not compile"
else
    out=$("$BUILD_DIR/bin/test_routing_strategy" --gtest_filter='RateDenominator.*' 2>&1)
    failed=$(failed_tests RateDenominator <<<"$out")
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the sentinel's value is untested."
        record_survivor "$M3_LABEL" "nothing went red"
    elif grep -q "DivisorStartsAtASentinelNotZero" <<<"$failed"; then
        echo "  ✅ red: $failed"
        record_killed
    else
        echo "  🔴 WRONG TEST WENT RED: got [$failed]"
        echo "     The gate fires, but not for the reason the header claims."
        record_survivor "$M3_LABEL" "wrong test went red"
    fi
fi
restore_file "$HDR" "$HBAK" "$HSHA" || harness_fault "$HDR did not come back byte-identical"

if ! build_it; then
    harness_fault "the tree does not build after the final restore -- the verdicts above were \
measured, but the tree you are left with is not the one they were measured on"
fi
printf '\n--- after restore: the suite must be green again ---\n'
if "$BUILD_DIR/bin/test_routing_strategy" --gtest_filter='RateDenominator.*' >/tmp/mrd.$$ 2>&1; then
    tail -2 /tmp/mrd.$$
else
    echo "🔴 THE SUITE IS RED AFTER RESTORE -- a mutant is still built in. Do NOT commit."
    sed -n 's/^\[  FAILED  \]/  still red:/p' /tmp/mrd.$$ | sort -u
    rm -f /tmp/mrd.$$
    harness_fault "the suite is red after the final restore"
fi
rm -f /tmp/mrd.$$
echo "kernel binary: $(sha256sum "$KERNEL_BIN" 2>/dev/null | cut -c1-16) (was ${KERNEL_SHA_BEFORE:0:16})"

printf '\n--- verdict ---\n'
if ((SURVIVORS > 0)); then
    for s in "${SURVIVOR_LIST[@]}"; do
        printf '  survived: %s\n' "$s"
    done
fi
printf '%d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
((SURVIVORS == 0)) || exit 1
exit 0
