#!/usr/bin/env bash
#
# Tests for local_ci.sh's driver: which jobs run, and whether a failure reaches the exit code.
#
# [Co-developed with claude code -- Adam]
#
# The driver's whole value is that a red job cannot be mistaken for a green run -- this repo's
# recurring disease is the false PASS (a runner reporting OK over a file where nothing ran, a
# suite exiting 0 after a UBSan report). A wrapper that swallowed one job's failure would be the
# same bug one level up, and it would be invisible precisely when it matters: the day something
# actually breaks. So the failure-propagation case is the load-bearing test here.
#
# The real jobs are never run: sourcing local_ci.sh defines the functions without executing
# anything, and each case replaces them with stubs that record their name.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../tools/test_workflow/local_ci.sh"

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
RAN="$TMP/ran"

# Runs main in a subshell with stubbed jobs. $1 = job to fail ("" for none), rest = main's args.
# Echoes the exit code; the jobs that ran land in $RAN.
run_with_stubs() {
    local failing="$1"; shift
    : > "$RAN"
    (
        # shellcheck source=/dev/null
        source "$SCRIPT"
        for j in gcc python asan tsan clang p4cov; do
            eval "job_$j() { echo $j >> '$RAN'; [[ '$failing' != '$j' ]]; }"
        done
        main "$@" >/dev/null 2>&1
    )
    echo $?
}

ran_jobs() { tr '\n' ' ' < "$RAN" | sed 's/ $//'; }

echo "no arguments -> every job, in order, exit 0"
rc="$(run_with_stubs "")"
check "exit 0" 0 "$rc"
check "all six ran in order" "gcc python asan tsan clang p4cov" "$(ran_jobs)"

echo "one job fails -> exit 1, and the others still run (not fail-fast)"
rc="$(run_with_stubs asan)"
check "exit 1" 1 "$rc"
check "later jobs still ran" "gcc python asan tsan clang p4cov" "$(ran_jobs)"

echo "the last job failing still reaches the exit code"
rc="$(run_with_stubs p4cov)"
check "exit 1" 1 "$rc"

echo "named jobs -> only those run"
rc="$(run_with_stubs "" asan tsan)"
check "exit 0" 0 "$rc"
check "only the two named ran" "asan tsan" "$(ran_jobs)"

echo "an unknown job name is a usage error, and nothing runs"
rc="$(run_with_stubs "" gcc typo)"
check "exit 2" 2 "$rc"
check "no job ran" "" "$(ran_jobs)"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
