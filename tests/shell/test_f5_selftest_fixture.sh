#!/usr/bin/env bash
#
# The F5 round's selftest fixture must list exactly the force rows run_f5.sh defines.
#
# [Co-developed with claude code -- Adam]
#
# `run_f5.sh selftest` builds its force fixtures from a registration-shaped file. Without a
# PREREG_FILE from the caller, it uses selftest_registration.txt beside the script. One of the
# forces checks that the transcript in that file has one [ok] row per FORCE_MATRIX row. If a row
# is added to FORCE_MATRIX and not to the fixture, the selftest stops passing, but only when
# someone runs it. This suite reads both sides the same way the script's own check does (the
# FORCE_MATRIX array literal, and the fenced block after "force matrix:") and compares them, so
# the drift shows up in L1. It also checks the other structures the forces rely on: the anchored
# EVIDENCE-BASIS sentinel, and an [ok] outside the block that comes before it.
#
# Pure: reads two files, runs nothing. RUN_F5_UNDER_TEST / FIXTURE_UNDER_TEST point it at copies.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND="$HERE/../../doc/audit/2026-08-31_f5-fine-grid-round"
RUN_F5="${RUN_F5_UNDER_TEST:-$ROUND/run_f5.sh}"
FIXTURE="${FIXTURE_UNDER_TEST:-$ROUND/selftest_registration.txt}"

PASS=0
FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"; PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"; echo "           expected: [$expected]"; echo "           actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

check "run_f5.sh and the fixture are readable" "yes" \
      "$( [[ -r "$RUN_F5" && -r "$FIXTURE" ]] && echo yes || echo no)"

# Side A and side B, parsed with the same commands as run_f5.sh's preflight.
a_labels=$(sed -n '/local FORCE_MATRIX=(/,/^    )/p' "$RUN_F5" | grep -oE '^      "[^|]*' | sed 's/.*"//' | sort)
b_labels=$(awk '/force matrix:/{f=1} f&&/```/{exit} f' "$FIXTURE" 2>/dev/null \
           | grep -oE '\[ok\]   [^ ]*' | sed 's/\[ok\]   //' | sort)
na=$(printf '%s\n' "$a_labels" | grep -c .)
nb=$(printf '%s\n' "$b_labels" | grep -c .)
check "FORCE_MATRIX in run_f5.sh parses to some rows" "yes" "$( (( na > 0 )) && echo yes || echo "no ($na)")"
check "the fixture's force-matrix block lists the same rows as FORCE_MATRIX ($na)" "$a_labels" "$b_labels"
check "  and the same number of them" "$na" "$nb"

# The sentinel the readers take: the first line matching the anchored pattern, and it says COMPLETE.
check "the first anchored EVIDENCE-BASIS line says COMPLETE" "COMPLETE" \
      "$(grep -m1 -oE '^[[:space:]]*EVIDENCE-BASIS: [A-Z]*' "$FIXTURE" | awk '{print $2}')"
# The transcript force deletes the first [ok] INSIDE the block; an [ok] before the block is what makes
# that force able to tell the block from the file.
first_ok=$(grep -n '\[ok\]' "$FIXTURE" | head -1 | cut -d: -f1)
block=$(grep -n 'force matrix:' "$FIXTURE" | head -1 | cut -d: -f1)
check "an [ok] comes before the force-matrix block" "yes" \
      "$( [[ -n "$first_ok" && -n "$block" && "$first_ok" -lt "$block" ]] && echo yes || echo "no (first [ok] ${first_ok:-none}, block ${block:-none})")"

echo
if [ "$FAIL" -gt 0 ]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
