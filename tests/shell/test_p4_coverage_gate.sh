#!/usr/bin/env bash
#
# Tests for p4_coverage_gate.sh, driven through a fake p4testgen (the P4TESTGEN seam).
#
# [Co-developed with claude code -- Adam]
#
# The gate's job is to notice when a .p4 edit adds code that generated tests can never reach.
# Its two failure modes are both silent: skipping when it should measure (the .p4 changed but
# the sha check said otherwise) and passing when the uncovered set grew. Both are exercised
# here against a stub, so no real 7-minute symbolic execution runs.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../../tools/test_workflow/p4_coverage_gate.sh"

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

P4="$TMP/fake_switch.p4"
echo "// fake p4 program" > "$P4"
SHA="$(git hash-object "$P4")"

# A stub p4testgen: prints the coverage block described by FAKE_COVERAGE / FAKE_UNCOVERED and
# exits with FAKE_RC. Records that it was called.
cat > "$TMP/fake_p4testgen" <<'FAKE'
#!/usr/bin/env bash
echo called >> "$FAKE_CALLS"
echo "============ Test 53: Nodes covered: $FAKE_COVERAGE (46/54) ============"
echo "Not covered program nodes:"
for line in $FAKE_UNCOVERED; do
    printf '\tfake_switch.p4\\%s: hdr.packet_in.setValid();\n' "$line"
done
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$TMP/fake_p4testgen"

export P4TESTGEN="$TMP/fake_p4testgen"
export P4_FILE="$P4"
export BASELINE="$TMP/baseline.txt"
export FAKE_CALLS="$TMP/calls"

write_baseline() {
    { echo "sha $1"; echo "coverage 0.851852"; echo "uncovered 414 415 416"; } > "$BASELINE"
}

run_gate() {
    : > "$FAKE_CALLS"
    out="$(bash "$GATE" "$@" 2>&1)"; rc=$?
    echo "$out" > "$TMP/last_out"
    echo "$rc"
}

called() { [[ -s "$FAKE_CALLS" ]] && echo yes || echo no; }

echo "unchanged .p4 -> skips without running p4testgen at all"
write_baseline "$SHA"
export FAKE_COVERAGE=0.851852 FAKE_UNCOVERED="414 415 416" FAKE_RC=0
rc="$(run_gate)"
check "exit 0" 0 "$rc"
check "p4testgen not called" no "$(called)"

echo "changed .p4, same uncovered set -> PASS"
write_baseline "0000000000000000000000000000000000000000"
rc="$(run_gate)"
check "exit 0" 0 "$rc"
check "p4testgen called" yes "$(called)"
check "says PASS" yes "$(grep -q PASS "$TMP/last_out" && echo yes || echo no)"

echo "changed .p4, a NEW unreachable line -> FAIL naming it"
write_baseline "0000000000000000000000000000000000000000"
FAKE_UNCOVERED="414 415 416 999"
rc="$(run_gate)"
check "exit 1" 1 "$rc"
check "names the new line" yes "$(grep -q 999 "$TMP/last_out" && echo yes || echo no)"
check "points at --update-baseline" yes "$(grep -q -- "--update-baseline" "$TMP/last_out" && echo yes || echo no)"

echo "changed .p4, one line now covered -> PASS with a note"
write_baseline "0000000000000000000000000000000000000000"
FAKE_UNCOVERED="414 415"
rc="$(run_gate)"
check "exit 0" 0 "$rc"
check "notes the newly covered line" yes "$(grep -q "now covered" "$TMP/last_out" && echo yes || echo no)"

echo "p4testgen itself failing the coverage floor -> FAIL"
write_baseline "0000000000000000000000000000000000000000"
FAKE_UNCOVERED="414 415 416" FAKE_RC=1
rc="$(run_gate)"
check "exit 1" 1 "$rc"
check "blames the floor" yes "$(grep -q "below" "$TMP/last_out" && echo yes || echo no)"

echo "--update-baseline records the current measurement"
write_baseline "0000000000000000000000000000000000000000"
FAKE_UNCOVERED="414 999" FAKE_RC=0
rc="$(run_gate --update-baseline)"
check "exit 0" 0 "$rc"
check "sha rewritten" "sha $SHA" "$(grep '^sha ' "$BASELINE")"
check "uncovered rewritten" "uncovered 414 999" "$(grep '^uncovered ' "$BASELINE")"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
