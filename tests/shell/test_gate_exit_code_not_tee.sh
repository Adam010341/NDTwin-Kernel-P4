#!/usr/bin/env bash
#
# Tests for run_gate(), the helper the E round's gates use to read a gate's exit code.
#
# [Co-developed with claude code -- Adam]
#
# The defect these encode was found on 2026-09-01 while verifying the previous session's handoff.
# gates_e.sh ran its three ratio gates as
#
#     elif <gate> 2>&1 | tee -a "$LOG"; then record ... PASS; else record ... FAIL; abort ...
#
# and nothing in the round sets `pipefail`, so the condition read tee's exit status. tee succeeds
# whenever the write succeeds. All three gates therefore recorded PASS no matter what the gate
# decided, and had done so since 22:03 on 2026-08-31.
#
# The sharpest instance is G6b. It was added that same morning for the sole purpose of making a
# just-fixed code path stop being unread -- a caller shipped to prove a fix works, which would
# have said "works" either way. It had also never actually run: the commit that added it landed
# at 07:50 on 09-01, hours after the last live gate pass.
#
# Case 2 is the load-bearing one and case 3 is its witness: case 3 reproduces the ORIGINAL
# construct against the same failing command and asserts it still reports success, so the fix is
# pinned to a mechanism rather than to a story that fits. Case 5 is the one that stops the defect
# coming back at a call site nobody is looking at.
#
# No fabric, no lab claim: the gate is pointed at t008_poll, an archived 08-20 cell that is in
# version control, which is the same cell the live G7 uses.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND_DIR="$HERE/../../doc/audit/2026-08-31_sampling-ceiling-after-merge"
GOODCELL="${RATIO_GOOD_CELL:-t008_poll}"

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

# --- source the SHIPPED helper, never a copy of it -------------------------------------------
# A test that re-implements the branch under test is testing its own copy; this round's own notes
# record that shape three times in two days. run_gate comes from the file gates_e.sh loads.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export ROUND="$ROUND_DIR"
export LOG="$T/test.log"
export DRY_RUN=0
# shellcheck source=/dev/null
. "$ROUND_DIR/round.env" >/dev/null 2>&1 || true
LOG="$T/test.log"          # round.env sets its own LOG; ours is the one under test
# shellcheck source=/dev/null
. "$ROUND_DIR/lib_e.sh"
LOG="$T/test.log"

if ! declare -F run_gate >/dev/null; then
    echo "FAILED   lib_e.sh does not define run_gate -- the helper under test is gone"
    exit 1
fi
if [[ ! -x "${PY_PLOT:-}" && ! -f "${PY_PLOT:-}" ]]; then
    echo "SKIP: PY_PLOT (${PY_PLOT:-unset}) is not present; the gate cannot be invoked"
    exit 0
fi

GATE=(env PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" "$ROUND_DIR/ratio_gate.py")

# --- case 1: the accept path.  A green cell asked to be green passes. --------------------------
run_gate "${GATE[@]}" --check "$GOODCELL" --expect green >/dev/null 2>&1
check "case 1  --expect green on a green cell -> caller sees success" 0 "$?"

# --- case 2: THE DEFECT.  A green cell asked to be RED must reach the caller as a failure. -----
# Before the fix this returned 0, and gates_e.sh recorded PASS.
run_gate "${GATE[@]}" --check "$GOODCELL" --expect red >/dev/null 2>&1
check "case 2  --expect red on a green cell -> caller sees failure" 2 "$?"

# --- case 3: the witness.  The original construct, same command, still reports success. --------
# This is not a hypothetical: it is what shipped, and it is why case 2 could not have caught it.
#
# 🔴 `set +o pipefail` is load-bearing, and the first draft of this test got it wrong.  This file
# opens with `set -uo pipefail`, house style for tests here -- under which the old construct
# behaves CORRECTLY and case 3 reports failure, i.e. the harness would have testified that the
# shipped code was fine.  gates_e.sh sets only `set -u` (line 35).  The defect lives entirely in
# that difference, so the reproduction has to run under the shell options the round actually used.
# A harness whose options differ from production's is the same family as a harness that cd's
# somewhere production never goes: both hide a whole class of defect while looking green.
set +o pipefail
if "${GATE[@]}" --check "$GOODCELL" --expect red 2>&1 | tee -a "$LOG" >/dev/null; then
    old_verdict=reported-success
else
    old_verdict=reported-failure
fi
set -o pipefail
check "case 3  the pre-fix pipeline hid that same failure (no pipefail, as gates_e.sh runs)" \
      reported-success "$old_verdict"

# --- case 3b: and gates_e.sh really does still lack pipefail, which is what makes 3 relevant ----
check "case 3b gates_e.sh sets no pipefail, so run_gate is the only thing standing there" 0 \
      "$(grep -cE '^\s*set .*pipefail' "$ROUND_DIR/gates_e.sh")"

# --- case 4: the tee's actual job still happens.  A silent gate is its own defect. -------------
: >"$LOG"
run_gate "${GATE[@]}" --check "$GOODCELL" --expect green >/dev/null 2>&1
check "case 4  gate output still reaches the log" 1 \
      "$(grep -c 'GATE ratio force-test OK' "$LOG")"

# --- case 5: no call site anywhere still pipes a gate straight into an if/elif condition -------
# Case 2 only protects the three sites that exist today. This protects the next one.
#
# 🔴 Line continuations must be joined first, and the first draft of this check did not join them.
# The mutation gate caught it: reverting the G6b call site left the test green, because two of the
# three sites that shipped the defect were written as
#
#     elif <gate> \
#             --args 2>&1 | tee -a "$LOG"; then
#
# and a line-based grep sees `elif` on one line and `| tee ...; then` on the next, matching
# neither. A guard that cannot see the exact shape the defect actually took is decorative --
# and this one would have reported all clear against the code as it shipped.
count_leaks() {
    local f n total=0
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        n=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' "$f" |
            grep -cE '^[[:space:]]*(el)?if .*\|[[:space:]]*tee .*; then')
        total=$((total + n))
    done
    printf '%s\n' "$total"
}
check "case 5  no gate is wired straight into a condition through tee" 0 \
      "$(count_leaks "$ROUND_DIR/gates_e.sh" "$ROUND_DIR/run_e.sh")"

# --- case 5b: the joiner itself works, checked against a fixture, not against the file ---------
# Case 5 passing could mean "no leaks" or "the joiner is broken". A guard that cannot tell those
# apart reads as all-clear in both.
cat >"$T/fixture.sh" <<'FIXTURE'
    elif some_gate \
            --arg 2>&1 | tee -a "$LOG"; then
FIXTURE
check "case 5b the continuation joiner sees a leak written across two lines" 1 \
      "$(count_leaks "$T/fixture.sh")"

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
