#!/usr/bin/env bash
# Mutation gate for tests/test_RateDenominator.cpp (ticket Q).
#
# A test that has never been seen to fail is a decoration. This applies each mutation named in
# that file's header, rebuilds, and records WHICH test went red -- not merely that something did.
# Two of this project's tests have previously turned red on a mutation aimed at a different
# behaviour, so "the gate works" is only established by the identity of the failure.
#
# The baseline is checksummed before anything is touched and re-checked after every restore: an
# interrupted mutation run once left a mutant on disk that was then archived as a baseline.
#
# Usage: tests/shell/mutate_rate_denominator.sh
# [Co-developed with claude code -- Adam]
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

TARGET=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
BASELINE_SHA=$(sha256sum "$TARGET" | cut -d' ' -f1)
BACKUP=$(mktemp) ; cp -p "$TARGET" "$BACKUP"
KERNEL_SHA_BEFORE=$(sha256sum build/bin/ndtwin_kernel | cut -d' ' -f1)

restore() {
    cp -p "$BACKUP" "$TARGET"
    # `cp -p` puts the ORIGINAL mtime back, which is older than the object built from the
    # mutant -- so ninja sees nothing to do and the next run tests the mutant while the source
    # on disk is pristine. The sha256 below passes either way: it checks the file, not the
    # artifact built from it. touch is what actually restores the build.
    touch "$TARGET"
    local now; now=$(sha256sum "$TARGET" | cut -d' ' -f1)
    if [[ "$now" != "$BASELINE_SHA" ]]; then
        echo "🔴 RESTORE FAILED -- $TARGET is not the baseline. Do NOT commit." >&2
        exit 2
    fi
}
trap restore EXIT

# $1 = label, $2 = python expression replacing old->new, $3 = expected test name
run_mutation() {
    local label="$1" expected="$3"
    printf '\n=== %s ===\n  expect: %s\n' "$label" "$expected"
    if ! python3 - "$TARGET" <<<"$2"; then
        echo "  🔴 mutation could not be applied -- the anchor text has moved. NOT a pass." >&2
        restore; return
    fi
    if ! cmake --build build --target test_routing_strategy -j4 >/dev/null 2>&1; then
        echo "  ⚠️  mutant does not compile -- this mutation proves nothing about the tests."
        restore; return
    fi
    local out
    out=$(./build/bin/test_routing_strategy --gtest_filter='RateDenominator.*' 2>&1)
    local failed
    failed=$(sed -n 's/^\[  FAILED  \] \(RateDenominator\.[A-Za-z]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' ')
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
    elif grep -q "RateDenominator.$expected" <<<"$failed"; then
        echo "  ✅ red: $failed"
        grep -q " " <<<"${failed% }" && echo "     (more than one test caught it -- fine, but the named one did)"
    else
        echo "  🔴 WRONG TEST WENT RED: got [$failed], expected [$expected]"
        echo "     The gate fires, but not for the reason the header claims."
    fi
    restore
}

echo "baseline $TARGET sha256 ${BASELINE_SHA:0:16}"

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
printf '\n=== NEGATIVE CONTROL: host-bound site ignores its interval ===\n'
echo "  expect: LastHopAttributionTest.TheHostBoundSiteDividesByTheIntervalItWasGiven"
FLUC=src/ndt_core/collection/FlowLinkUsageCollector.cpp
FSHA=$(sha256sum "$FLUC" | cut -d' ' -f1); FBAK=$(mktemp); cp -p "$FLUC" "$FBAK"
python3 - "$FLUC" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "key, value.inputByteCountOnALinkMultiplySampingRate, elapsedSeconds);"
new = "key, value.inputByteCountOnALinkMultiplySampingRate, 1.0);"
assert old in s, "anchor missing"
p.write_text(s.replace(old, new, 1))
PYEOF
if cmake --build build --target test_routing_strategy -j4 >/dev/null 2>&1; then
    if ./build/bin/test_routing_strategy --gtest_filter='LastHopAttributionTest.TheHostBoundSite*' >/dev/null 2>&1; then
        echo "  🔴 THE PARTIAL FIX SURVIVED -- one site could ship unfixed and nothing would say so."
    else
        echo "  ✅ red: the unfixed site is detected"
    fi
else
    echo "  ⚠️  mutant does not compile"
fi
cp -p "$FBAK" "$FLUC"; touch "$FLUC"
[[ "$(sha256sum "$FLUC" | cut -d' ' -f1)" == "$FSHA" ]] || { echo "🔴 FLUC restore failed" >&2; exit 2; }

printf '\n=== 3. sentinel -1.0 becomes 0.0 (header file, run separately) ===\n'
echo "  expect: DivisorStartsAtASentinelNotZero"
HDR=include/ndt_core/collection/TopologyAndFlowMonitor.hpp
HSHA=$(sha256sum "$HDR" | cut -d' ' -f1); HBAK=$(mktemp); cp -p "$HDR" "$HBAK"
sed -i 's/m_lastRateDivisorSeconds{-1\.0}/m_lastRateDivisorSeconds{0.0}/' "$HDR"
if cmake --build build --target test_routing_strategy -j4 >/dev/null 2>&1; then
    out=$(./build/bin/test_routing_strategy --gtest_filter='RateDenominator.*' 2>&1)
    failed=$(sed -n 's/^\[  FAILED  \] \(RateDenominator\.[A-Za-z]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' ')
    if grep -q "DivisorStartsAtASentinelNotZero" <<<"$failed"; then
        echo "  ✅ red: $failed"
    elif [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the sentinel's value is untested."
    else
        echo "  🔴 WRONG TEST WENT RED: got [$failed]"
    fi
else
    echo "  ⚠️  mutant does not compile"
fi
cp -p "$HBAK" "$HDR"; touch "$HDR"
[[ "$(sha256sum "$HDR" | cut -d' ' -f1)" == "$HSHA" ]] || { echo "🔴 header restore failed" >&2; exit 2; }

cmake --build build --target test_routing_strategy -j4 >/dev/null 2>&1
printf '\n--- after restore: the suite must be green again ---\n'
if ./build/bin/test_routing_strategy --gtest_filter='RateDenominator.*' >/tmp/mrd.$$ 2>&1; then
    tail -2 /tmp/mrd.$$
else
    echo "🔴 THE SUITE IS RED AFTER RESTORE -- a mutant is still built in. Do NOT commit."
    sed -n 's/^\[  FAILED  \]/  still red:/p' /tmp/mrd.$$ | sort -u
    rm -f /tmp/mrd.$$; exit 2
fi
rm -f /tmp/mrd.$$
echo "kernel binary: $(sha256sum build/bin/ndtwin_kernel | cut -c1-16) (was ${KERNEL_SHA_BEFORE:0:16})"
