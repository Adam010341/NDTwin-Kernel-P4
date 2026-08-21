#!/usr/bin/env bash
#
# Tests for slim_client_json.sh, the branch measure.sh uses to reduce iperf3 --json output.
#
# [Co-developed with claude code -- Adam]
#
# The scenario these encode is the one that motivated the split (2026-08-20 matrix round):
# iperf3 failed on the mzero_nopoll cell and emitted {"error": ...} instead of a result. The
# filter in use selected .end.sum and .start.test_start only, so both yielded null and it wrote
# a well-formed 76-byte file of nulls with the error text gone. A dead run and a missing run
# became indistinguishable and neither looked broken; the run was only salvageable because
# /proc/net/dev had counted the traffic independently of iperf3.
#
# Case 3 is the load-bearing one: it asserts the OLD filter still reproduces the committed
# artefact byte for byte, so the regression is pinned to a mechanism rather than to a story
# that merely fits.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../../doc/audit/2026-08-20_sampling-rate-and-cpu/slim_client_json.sh"
COMMITTED="$HERE/../../doc/audit/2026-08-20_sampling-rate-and-cpu/raw/mzero_nopoll_client.json"

PASS=0
FAIL=0

check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed; slim_client_json.sh degrades to copy and has nothing to test"
    exit 0
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

echo "slim_client_json.sh"

# --- 1. a successful run is slimmed, keeps end.sum, and loses the intervals array
cat > "$T/ok.json" <<'EOF'
{"start":{"test_start":{"protocol":"UDP","duration":300}},
 "intervals":[{"junk":1},{"junk":2}],
 "end":{"sum":{"packets":5357127,"bytes":7499977800,"seconds":300.0,
               "bits_per_second":200000000,"lost_percent":0.35}}}
EOF
"$TOOL" "$T/ok.json" "$T/ok.out" ok >/dev/null 2>&1
check "good run exits 0"                    "0"       "$?"
check "good run keeps the packet count"     "5357127" "$(jq -r '.end.sum.packets' "$T/ok.out")"
check "good run drops intervals[]"          "false"   "$(jq -r 'has("intervals")' "$T/ok.out")"

# --- 2. the failure that produced the committed stub
cat > "$T/err.json" <<'EOF'
{"error":"unable to connect to server - server may have stopped running or use a different port"}
EOF
"$TOOL" "$T/err.json" "$T/err.out" err >/dev/null 2>&1
check "errored run exits 3"                 "3"     "$?"
check "errored run keeps the error text"    "true"  "$(jq -r 'has("error")' "$T/err.out")"
check "errored run is not a nulled result"  "false" "$(jq -r 'has("end")' "$T/err.out")"

# --- 3. the regression witness: the OLD filter on that same input reproduces the committed
#        76-byte artefact exactly. If this ever stops matching, the story behind the fix is
#        wrong and the fix should be re-derived rather than trusted.
if [ -f "$COMMITTED" ]; then
    jq '{end: {sum: .end.sum}, start: {test_start: .start.test_start}}' "$T/err.json" \
        > "$T/old.out" 2>/dev/null
    if diff -q "$T/old.out" "$COMMITTED" >/dev/null 2>&1; then
        check "old filter reproduces mzero_nopoll_client.json" "same" "same"
    else
        check "old filter reproduces mzero_nopoll_client.json" "same" "differs"
    fi
else
    echo "  skip     committed artefact not present"
fi

# --- 4. a truncated file must take the failure branch, not parse as a result
printf '{"end":{"sum":{"packets":53571' > "$T/trunc.json"
"$TOOL" "$T/trunc.json" "$T/trunc.out" trunc >/dev/null 2>&1
check "truncated run exits 3"               "3"    "$?"
check "truncated run is kept verbatim"      "same" \
    "$(diff -q "$T/trunc.json" "$T/trunc.out" >/dev/null 2>&1 && echo same || echo differs)"

# --- 5. a result whose sum is explicitly null is a failure, not a result
echo '{"end":{"sum":null},"start":{"test_start":null}}' > "$T/nulls.json"
"$TOOL" "$T/nulls.json" "$T/nulls.out" nulls >/dev/null 2>&1
check "null end.sum exits 3"                "3"    "$?"

# --- 6. usage errors are loud
"$TOOL" >/dev/null 2>&1
check "no arguments exits 2"                "2"    "$?"
"$TOOL" "$T/nope.json" "$T/nope.out" x >/dev/null 2>&1
check "missing input exits 2"               "2"    "$?"

# "Ran N checks" is the phrase the L1 lane's parser greps for; the previous "passed N,
# failed M" summary read as NO TESTS RAN and this file was a problem group from the day it
# was born, with all 12 checks passing inside the log. Same emitter as test_faults.sh.
echo
if [ "$FAIL" -gt 0 ]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
