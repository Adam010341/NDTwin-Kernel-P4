#!/usr/bin/env bash
#
# Tests for start_bg's side of log rotation: WHEN it rotates, and that what it rotates survives.
#
# [Co-developed with claude code -- Adam]
#
# start_bg used a bare '>' redirect, so every restart erased the previous era's log. That is
# how the entire P4-era kernel.log vanished on 2026-08-15: the OVS restart truncated it, and
# the era had to be reconstructed from the proxy's log during the overnight audit. The fix
# rotates a non-empty log aside before starting -- each file stays single-era, disk use stays
# bounded, and the era you just tore down remains readable.
#
# 🔴 THE ROTATION CONTRACT ITSELF LIVES IN test_stack_log_rotation.sh (2026-09-27). O-4
# (74c811df, 2026-09-06) replaced this file's two-generation `.prev`/`.prev2` scheme with five
# time-stamped generations `<log>.<YYYYmmdd-HHMMSS>` and NDT_LOG_KEEP, and that suite tests them
# (its lines 84-122). This file kept asserting `.prev`/`.prev2` and was red from then on; those
# six expectations -- and the three that stayed green only because no `.prev` file is ever made
# any more -- are gone and NOT replaced here, so the contract is stated once. What only this file
# covers stays, retargeted to the stamped names: start_bg's own decision (stack.sh:559-560) --
# a non-empty log is rotated, a first start and an empty log are not.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="${STACK_UNDER_TEST:-$HERE/../../tools/test_workflow/stack.sh}"   # mutate_stack_log_rotation.sh points this at a copy

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

# stack.sh returns early when sourced, so this defines its functions without running a command.
# shellcheck source=/dev/null
source "$STACK"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PID_DIR="$TMP/pids"   # start_bg writes the pid file here; is_running reads it
mkdir -p "$PID_DIR"

# gens <log> -- the time-stamped generations rotate_log left beside <log>, one per line.
gens() { ls -1 "$1".[0-9]* 2>/dev/null | /usr/bin/grep -E "^$1\.[0-9]{8}-[0-9]{6}(-[0-9]+)?$"; }

# --- a previous era's log is rotated, not erased -------------------------------------------

LOG="$TMP/kernel.log"
printf 'previous era line\n' >"$LOG"
start_bg rot_test1 "$LOG" echo the-new-era >/dev/null 2>&1
wait 2>/dev/null || true
sleep 0.2   # let the new era's echo land before reading the live log

check "a non-empty previous log is rotated: exactly one stamped generation" "1" "$(gens "$LOG" | wc -l)"
check "  and it holds the previous era's content" "previous era line" "$(cat "$(gens "$LOG" | head -1)" 2>/dev/null)"
check "the live log is the new era's alone" "the-new-era" "$(cat "$LOG" 2>/dev/null)"

# --- a first start has nothing to rotate ----------------------------------------------------

LOG2="$TMP/first.log"
start_bg rot_test2 "$LOG2" true >/dev/null 2>&1
wait 2>/dev/null || true

check "no generation appears on a first start" "0" "$(gens "$LOG2" | wc -l)"

# --- an empty previous log is not rotated: an empty generation would be one of the five kept,
#     pushing out an era that had something in it ---------------------------------------------

LOG3="$TMP/empty.log"
: >"$LOG3"
start_bg rot_test3 "$LOG3" true >/dev/null 2>&1
wait 2>/dev/null || true

check "an empty previous log is not rotated" "0" "$(gens "$LOG3" | wc -l)"

echo
if [[ $FAIL -gt 0 ]]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
