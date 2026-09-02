#!/usr/bin/env bash
#
# Tests for lib_e.sh's foreign_iperf3_guard -- KNOWN-ISSUES G-inst-2, the guard half.
#
# [Co-developed with claude code -- Adam]
#
# THE DEFECT.  The guard existed to stop the round handing control to measure.sh while a
# sibling session's iperf3 was alive, because measure.sh clears stale servers with
# `pkill -f iperf3` in the ROOT pid namespace.  It built its process list with
#
#     pids=$(ps -eo pid=,comm= | awk '$2=="iperf3"{printf "%s ", $1}')
#
# and that awk's OWN argv contains the string `iperf3`, so `pkill -f iperf3` matches the guard
# itself.  lib_e.sh has `set -u` but no `set -e` and no `pipefail`, so a killed awk leaves $pids
# empty, the `-n` test is false, and the function RETURNS 0 -- it reports "no foreign load" at
# the exact moment it was destroyed.  A round then records the absence of foreign load as a
# measured fact.  A guard whose failure direction is "proceed" is worse than no guard, because
# no guard at least leaves the question open.
#
# WHAT IS ACTUALLY TESTED, and why it is not a grep of the source.  Case 1 runs the guard with a
# PATH shim in front of it that records the argv of every process the guard spawns, and then
# asserts that no child's command line carries the pattern.  That is the property -- "nothing
# this guard runs is a legal target for `pkill -f iperf3`" -- rather than the spelling of one
# line, so it also catches a future rewrite to `pgrep -f iperf3` or `ps ... | grep iperf3`.
# 🔴 Nothing here kills anything: the hazard is reproduced by RECORDING argv, never by running
# pkill.  The shims for pkill/pgrep refuse instead of forwarding, so a regression that reaches
# for them fails the test rather than the machine.
#
# Cases 4 and 5 are the other half of the same principle: a guard that could not look must say
# so.  An empty process table means `ps` did not run -- every live machine has processes -- and
# "could not look" must never be returned as "looked and found nothing".
#
# No fabric, no lab claim, no build: the guard is pure and every process table below is a stub.
#
#   bash tests/shell/test_iperf3_guard.sh
#   LIB_E_UNDER_TEST=/tmp/x/lib_e.sh bash tests/shell/test_iperf3_guard.sh   # mutation gate

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND_DIR="$HERE/../../doc/audit/2026-08-31_sampling-ceiling-after-merge"
LIB="${LIB_E_UNDER_TEST:-$ROUND_DIR/lib_e.sh}"

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

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

[[ -f "$LIB" ]] || { echo "FAILED   no lib_e.sh at $LIB"; exit 1; }

export ROUND="$ROUND_DIR" DRY_RUN=0
LOG_BASE="$T/test.log"                   # lib_e.sh:67 refuses to load without it
# shellcheck source=/dev/null
. "$LIB"
LOG="$T/test.log"; OUT="$T/out"; mkdir -p "$OUT"

declare -F foreign_iperf3_guard >/dev/null \
    || { echo "FAILED   $LIB does not define foreign_iperf3_guard"; exit 1; }

# --- shim builders ------------------------------------------------------------------------------
# A recording shim: writes its own argv to $T/argv.log, then becomes the real command.  The real
# path is resolved BEFORE the shim directory goes on PATH, so the shim cannot recurse into itself.
mk_recorder() {                          # $1 = dir, $2.. = command names
    local dir="$1"; shift
    mkdir -p "$dir"
    local c real
    for c in "$@"; do
        real=$(command -v "$c" 2>/dev/null) || real=""
        if [[ "$c" == pkill || "$c" == pgrep || -z "$real" ]]; then
            # 🔴 Never forward these.  A regression that reaches for a -f matcher must fail this
            # test, not sweep the machine -- a sibling session's fabric is running right now.
            printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >>"%s"\nexit 127\n' \
                "$c" "$T/argv.log" >"$dir/$c"
        else
            printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >>"%s"\nexec %s "$@"\n' \
                "$c" "$T/argv.log" "$real" >"$dir/$c"
        fi
        chmod +x "$dir/$c"
    done
}

# A fake `ps` that prints a fixed table, so detection can be tested without any real iperf3.
mk_fake_ps() {                           # $1 = dir, $2 = table text ("" = a table of no rows)
    mkdir -p "$1"
    { printf '#!/bin/sh\ncat <<%s\n' "TABLE_EOF"
      [[ -n "$2" ]] && printf '%s\n' "$2"
      printf 'TABLE_EOF\n'; } >"$1/ps"
    chmod +x "$1/ps"
}

cnt() {                                  # occurrences of $1 in file $2, 0 when absent
    local n
    n=$(grep -c -- "$1" "$2" 2>/dev/null) || true
    printf '%s' "${n:-0}"
}

run_guard() {                            # $1 = PATH prefix dir ("" for none); prints rc
    local pre="$1" rc
    if [[ -n "$pre" ]]; then
        ( PATH="$pre:$PATH"; foreign_iperf3_guard ) >"$T/guard.out" 2>"$T/guard.err"; rc=$?
    else
        ( foreign_iperf3_guard ) >"$T/guard.out" 2>"$T/guard.err"; rc=$?
    fi
    printf '%s' "$rc"
}

# --- case 1: THE DEFECT.  Nothing the guard spawns may carry the pattern in its own argv --------
# With the old `awk '$2=="iperf3"{...}'` the awk process is a legal target for the `pkill -f
# iperf3` this guard exists to survive, and killing it makes the guard answer "clean".
: >"$T/argv.log"
REC="$T/rec"
mk_recorder "$REC" ps awk gawk mawk grep sed pgrep pkill perl python3 bash sh
rc1=$(run_guard "$REC")
carriers=$(cnt 'iperf3' "$T/argv.log")
check "case 1  no process the guard spawns carries 'iperf3' in its own argv" 0 "$carriers"
if [[ "$carriers" != 0 ]]; then
    echo "             offending argv:"; sed 's/^/               /' "$T/argv.log"
fi
# It must still have looked -- a guard that spawns nothing at all would also score 0 above.
looked=$(cnt '^ps ' "$T/argv.log")
check "case 1b it did look: the process list was read (ps ran)" yes \
      "$( [[ "$looked" -ge 1 ]] && echo yes || echo no )"

# --- case 2: an exact `comm` of iperf3 is still detected -----------------------------------------
mk_fake_ps "$T/ps_hit" "  4242 iperf3
  4243 bash"
check "case 2  a foreign iperf3 in the process list is REFUSED" 1 "$(run_guard "$T/ps_hit")"
check "case 2b the refusal names the pid" 1 \
      "$(cnt '4242' "$T/guard.err")"

# --- case 3: the comparison is exact, not a prefix or a substring -------------------------------
# `comm.startswith("iperf3")` is the OTHER half of G-inst-2 (cpu_gate.py's FABRIC_PREFIXES) and
# is deliberately NOT changed here; this pins that the guard itself never acquired that shape.
mk_fake_ps "$T/ps_near" "  5001 iperf
  5002 iperf3d
  5003 xiperf3
  5004 iperf3.sh"
check "case 3  look-alike comms (iperf, iperf3d, xiperf3, iperf3.sh) do NOT trip the guard" 0 \
      "$(run_guard "$T/ps_near")"

# --- case 4: an empty process table is "could not look", not "nothing there" ---------------------
# Every live machine has processes.  Zero lines means ps did not run, was killed, or was shimmed
# away.  The old code returned 0 here -- the same fail-open the awk kill produced.
mk_fake_ps "$T/ps_empty" ""
check "case 4  an empty process list is REFUSED, not read as 'clean'" 1 "$(run_guard "$T/ps_empty")"
check "case 4b the refusal says the guard did not look" 1 \
      "$(cnt 'did not look' "$T/guard.err")"

# A table of one blank line is the same "did not look" in a shape that a naive line count reads
# as a real answer.  `read` succeeds on it, so counting iterations rather than parsed rows would
# score this as a machine with one process on it and nothing named iperf3.
mkdir -p "$T/ps_blank"
printf '#!/bin/sh\necho ""\n' >"$T/ps_blank/ps"; chmod +x "$T/ps_blank/ps"
check "case 4c a process table of one blank line is REFUSED (a blank line is not a process)" 1 \
      "$(run_guard "$T/ps_blank")"

# --- case 5: ps missing outright is the same answer ----------------------------------------------
# The destroyed-instrument case with a different cause: the enumerator is simply not there.
mkdir -p "$T/noexec"
rc5=$( PATH="$T/noexec"; ( foreign_iperf3_guard ) >/dev/null 2>&1; echo $? )
check "case 5  ps absent from PATH is REFUSED, not read as 'clean'" 1 "$rc5"

# --- case 6: the dry-run contract is unchanged ---------------------------------------------------
# The E round's transcripts are produced through these two branches; changing what they answer
# would change what a pre-registered analysis measures, so they are pinned rather than touched.
check "case 6  DRY_RUN=1 synthesises a clean machine" 0 \
      "$( ( DRY_RUN=1 DRY_FAIL= foreign_iperf3_guard ) >/dev/null 2>&1; echo $? )"
check "case 6b DRY_RUN=1 DRY_FAIL=iperf3 forces the refusal branch" 1 \
      "$( ( DRY_RUN=1 DRY_FAIL=iperf3 foreign_iperf3_guard ) >/dev/null 2>&1; echo $? )"

# --- case 7: the callers still consult it --------------------------------------------------------
# A fixed function with no caller is not a fix (the round's own §2.3 lesson).
check "case 7  run_e.sh and gates_e.sh still call the guard and act on its answer" 2 \
      "$(grep -hc 'foreign_iperf3_guard ||' "$ROUND_DIR/run_e.sh" "$ROUND_DIR/gates_e.sh" \
         2>/dev/null | paste -sd+ | bc)"

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
