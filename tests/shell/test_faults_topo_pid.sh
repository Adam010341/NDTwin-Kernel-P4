#!/usr/bin/env bash
#
# Tests for faults.sh's topo_pid -- the replacement for the `pgrep -f` snippet that faults.sh
# used to PRINT AT THE OPERATOR when the tc grant was the wrong shape.  KNOWN-ISSUES G-9.
#
# [Co-developed with claude code -- Adam]
#
# Why an advice string got its own test: the value this produces is handed to `mnexec -a`, which
# runs tc as uid 0 inside whatever namespace that pid is in.  A wrong pid here is not a wrong
# answer, it is root in a stranger's namespace.  `pgrep -f '[t]estbed_topo.py' | head -1` could
# return one three ways -- the bracket trick does not stop the calling SHELL from matching (ndt
# header trap note 2), -f matches a log path or an open editor, and `| head -1` under pipefail is
# the SIGPIPE trap from 2026-08-20.
#
# Safe on a shared machine: read-only, signals nothing, and its fixtures wear
# /nonexistent/NDT-TEST-FIXTURE/... argv0s.  It does need the real ps, so the assertions are
# one-directional -- "the fixture I started is found", "the decoy I started is not" -- which stay
# true however busy the machine is.  The one check that needs an EMPTY machine is skipped when a
# real topology is running, and says so rather than failing.
#
# Run:  bash tests/shell/test_faults_topo_pid.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAULTS="$HERE/../../tools/test_workflow/faults.sh"

PASS=0; FAIL=0; SKIP=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
skip() { echo "  skipped  $1"; SKIP=$((SKIP+1)); }

# shellcheck source=/dev/null
source "$FAULTS" || { echo "  FAILED   could not source $FAULTS"; echo "Ran 1 checks, 1 failed"; exit 1; }

TMPROOT="$(mktemp -d /tmp/faults-topo-pid-XXXXXX)"
FIXTURE_REG="$TMPROOT/fixtures"; : > "$FIXTURE_REG"
FIXTURE_TTL=90
reap() {
    local pid left=0
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || continue
        kill -KILL "$pid" 2>/dev/null
    done < "$FIXTURE_REG"
    sleep 0.3
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] && left=$((left+1))
    done < "$FIXTURE_REG"
    echo "$left"
}
cleanup() {
    [[ -f "$FIXTURE_REG" ]] && reap >/dev/null
    [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/faults-topo-pid-* ]] && rm -rf "$TMPROOT"
    return 0
}
trap cleanup EXIT INT TERM

spawn() {
    local want="$1" pid i; local -a argv=()
    ( exec -a "$want" sleep "$FIXTURE_TTL" ) >/dev/null 2>&1 </dev/null &
    pid=$!; echo "$pid" >> "$FIXTURE_REG"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        argv=(); mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null
        [[ "${argv[0]:-}" == "$want" ]] && { echo "$pid"; return 0; }
        sleep 0.1
    done
    echo "  FAILED   fixture never took argv0=$want" >&2; exit 1
}

SCRIPT=NDT-TEST-FIXTURE-topo.py
FIXP="/nonexistent/NDT-TEST-FIXTURE/$SCRIPT"
DECOYP="/nonexistent/NDT-TEST-FIXTURE/tail-of-$SCRIPT.log"

echo "topo_pid (the value that gets handed to 'mnexec -a')"

# Nothing running under that name: must print nothing AND fail, so `$(topo_pid)` cannot expand to
# an empty string that then makes `mnexec -a  tc` run against pid 0 / argument-shift garbage.
out="$(topo_pid "$SCRIPT" 2>/dev/null)"; rc=$?
if [[ -z "$out" ]]; then
    check "nothing running -> rc 1"              1 "$rc"
    check "  and it prints nothing"              "" "$out"
else
    skip "nothing running (something already matches $SCRIPT on this machine)"
fi

FIX="$(spawn "$FIXP")"
out="$(topo_pid "$SCRIPT" 2>/dev/null)"; rc=$?
check "one topology -> rc 0"                     0 "$rc"
check "  and it is the right pid"                "$FIX" "$out"

DECOY="$(spawn "$DECOYP")"
out="$(topo_pid "$SCRIPT" 2>/dev/null)"; rc=$?
check "a log file named after it is not it"      "$FIX" "$out"
check "  still rc 0"                             0 "$rc"

# Two of them is the case where guessing is worst: `| head -1` silently picked one, and mnexec
# would have run tc as root in whichever namespace won the race.
FIX2="$(spawn "$FIXP")"
out="$(topo_pid "$SCRIPT" 2>/dev/null)"; rc=$?
check "two topologies -> refuses, rc 1"          1 "$rc"
check "  and prints no pid at all"               "" "$out"
err_out="$(topo_pid "$SCRIPT" 2>&1 >/dev/null)"
check "  and says why"                           yes "$(case "$err_out" in *"more than one"*) echo yes ;; *) echo no ;; esac)"

# The red line is about what this file DOES and what it TELLS PEOPLE TO DO. Quoting the bad
# form inside an explanation is how the rule gets taught -- CLAUDE.md itself contains the string
# -- so the assertion is about executable lines and about output, not about the characters
# appearing anywhere in the file.
echo "the advice strings no longer teach pgrep -f"
check "no pgrep -f on an executable line"        0 \
    "$(grep -n 'pgrep -f' "$FAULTS" | grep -vc '^[0-9]*:[[:space:]]*#' || true)"
check "no pgrep -f inside anything it prints"    0 \
    "$(grep -E '^[[:space:]]*(err|say|echo|printf)' "$FAULTS" | grep -c 'pgrep' || true)"

echo "the suite reaps its own fixtures"
check "no fixture survives this run"             0 "$(reap)"

echo
if (( FAIL > 0 )); then echo "Ran $((PASS+FAIL)) checks, $FAIL failed${SKIP:+ ($SKIP skipped)}"; exit 1; fi
echo "Ran $((PASS+FAIL)) checks, all passed${SKIP:+ ($SKIP skipped)}"
