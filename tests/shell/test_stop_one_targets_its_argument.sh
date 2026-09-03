#!/usr/bin/env bash
#
# stop_one must stop the component it was ASKED for.
#
# [Co-developed with claude code -- Adam]
#
# THE DEFECT (found 2026-09-02 while making the kernel's exit status observable, KNOWN-ISSUES
# B-5). stop_one began:
#
#     local name="$1" pidfile="$PID_DIR/$name.pid"
#
# bash expands every word of a command before the command runs, and `local` is a command. So
# `$name` on that line is not the `name` being assigned two words earlier -- it is whatever
# `name` held in the CALLER. The line had been right for as long as it existed, by coincidence:
# both call sites happen to have a variable called `name` holding the same value (cmd_down's
# `for name in kernel p4_proxy ryu`, and start_bg's own local). The bug and the correct answer
# agreed, so nothing could tell them apart.
#
# What it costs when they disagree is not a crash. `err`/`info` inside stop_one print $name --
# which by then IS the argument -- so the function reports the component it was asked for while
# reading the pidfile of, and sending SIGTERM to the process GROUP of, a different one. "stopped
# kernel" while Ryu dies.
#
# Both cases are asserted here, because they fail differently:
#   A. the caller has some other `name` in scope  -> the wrong component is stopped, silently
#   B. the caller has no `name` at all            -> `set -u` kills the shell mid-teardown
#
# Run:  bash tests/shell/test_stop_one_targets_its_argument.sh
#       STACK=/path/to/other/stack.sh bash tests/shell/...   # to score another version
#
# The STACK override is how the red-then-green was recorded: against
# `git show HEAD:tools/test_workflow/stack.sh` both cases below fail.

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="${STACK:-$REPO/tools/test_workflow/stack.sh}"

PASS=0
FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"; PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

TMP="$(mktemp -d -t ndt_stop_one.XXXXXX)"
export PID_DIR="$TMP/pids" LOG_DIR="$TMP/logs" RUN_DIR="$TMP"
mkdir -p "$PID_DIR" "$LOG_DIR"

alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }

cleanup() {
    local p
    for p in "$PID_DIR"/*.pid; do
        [[ -f "$p" ]] || continue
        local pid; pid="$(cat "$p" 2>/dev/null)"
        [[ "$pid" =~ ^[0-9]{2,}$ ]] && kill -KILL "-$pid" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

# stack.sh returns early when sourced: this defines its functions without running a command.
# shellcheck source=/dev/null
source "$STACK"

# Two components, both real processes, so "which one died" is a fact and not a log line.
start_two() {
    rm -f "$PID_DIR"/*
    start_bg kernel "$LOG_DIR/kernel.log" bash -c 'exec sleep 300' >/dev/null 2>&1
    start_bg ryu    "$LOG_DIR/ryu.log"    bash -c 'exec sleep 300' >/dev/null 2>&1
    sleep 0.4
}

echo "A. a caller whose own \$name names a DIFFERENT component"
start_two
K="$(cat "$PID_DIR/kernel.pid")"
R="$(cat "$PID_DIR/ryu.pid")"
# The hostile-but-entirely-ordinary caller: it has a `name` of its own, holding something else.
( name=ryu; stop_one kernel ) >/dev/null 2>&1
sleep 0.3
check "the component that was ASKED for is stopped" "gone"  "$(alive "$K")"
check "the component that was NOT asked for survives" "alive" "$(alive "$R")"
kill -KILL "-$R" 2>/dev/null

echo
echo "B. a caller with no \$name in scope at all"
start_two
K="$(cat "$PID_DIR/kernel.pid")"
R="$(cat "$PID_DIR/ryu.pid")"
( unset name 2>/dev/null; stop_one kernel ) >/dev/null 2>&1
rc=$?
sleep 0.3
check "teardown does not die on an unbound variable" "0" "$rc"
check "and it still stops the right one" "gone" "$(alive "$K")"
check "leaving the other alone" "alive" "$(alive "$R")"
kill -KILL "-$R" 2>/dev/null

echo
if [[ $FAIL -gt 0 ]]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    echo "  (stack.sh under test: $STACK)"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
echo "  (stack.sh under test: $STACK)"
