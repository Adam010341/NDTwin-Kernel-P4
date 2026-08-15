#!/usr/bin/env bash
#
# Tests for start_bg's one-generation log rotation.
#
# [Co-developed with claude code -- Adam]
#
# start_bg used a bare '>' redirect, so every restart erased the previous era's log. That is
# how the entire P4-era kernel.log vanished on 2026-08-15: the OVS restart truncated it, and
# the era had to be reconstructed from the proxy's log during the overnight audit. The fix
# rotates a non-empty log to <log>.prev before starting -- each file stays single-era, disk
# use stays bounded at two generations, and the era you just tore down remains readable.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$HERE/../../tools/test_workflow/stack.sh"

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

# --- a previous era's log is rotated, not erased -------------------------------------------

LOG="$TMP/kernel.log"
printf 'previous era line\n' >"$LOG"
start_bg rot_test1 "$LOG" true >/dev/null 2>&1
wait 2>/dev/null || true

check "previous log rotated to .prev" "yes" "$([[ -f "$LOG.prev" ]] && echo yes || echo no)"
check ".prev holds the previous era's content" "previous era line" "$(cat "$LOG.prev" 2>/dev/null)"
check "current log is a fresh file for the new era" "yes" "$([[ -f "$LOG" ]] && echo yes || echo no)"

# --- a first start has nothing to rotate ----------------------------------------------------

LOG2="$TMP/first.log"
start_bg rot_test2 "$LOG2" true >/dev/null 2>&1
wait 2>/dev/null || true

check "no .prev appears on a first start" "no" "$([[ -f "$LOG2.prev" ]] && echo yes || echo no)"

# --- an empty leftover log is not worth a generation ----------------------------------------

LOG3="$TMP/empty.log"
: >"$LOG3"
start_bg rot_test3 "$LOG3" true >/dev/null 2>&1
wait 2>/dev/null || true

check "an empty previous log is not rotated" "no" "$([[ -f "$LOG3.prev" ]] && echo yes || echo no)"

# --- two eras end up in exactly two files ---------------------------------------------------

LOG4="$TMP/two_eras.log"
start_bg era1 "$LOG4" echo era-one >/dev/null 2>&1
sleep 0.2   # let the echo land before the next start rotates it
start_bg era2 "$LOG4" echo era-two >/dev/null 2>&1
sleep 0.2

check "the older era survives in .prev" "era-one" "$(cat "$LOG4.prev" 2>/dev/null)"
check "the newer era is in the main log" "era-two" "$(cat "$LOG4" 2>/dev/null)"

echo
if [[ $FAIL -gt 0 ]]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
