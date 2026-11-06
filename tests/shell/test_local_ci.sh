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
# The real jobs are not run: sourcing local_ci.sh defines the functions without executing
# anything, and each case replaces them with stubs that record their name. The one exception is
# job_py310, which is cheap: it runs below with fake interpreters in place of a real 3.10.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../tools/test_workflow/local_ci.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

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
        for j in gcc release python asan tsan clang py310 p4cov; do
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
check "all eight ran in order" "gcc release python asan tsan clang py310 p4cov" "$(ran_jobs)"

echo "one job fails -> exit 1, and the others still run (not fail-fast)"
rc="$(run_with_stubs asan)"
check "exit 1" 1 "$rc"
check "later jobs still ran" "gcc release python asan tsan clang py310 p4cov" "$(ran_jobs)"

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

# job_py310 itself, with fake interpreters (the real 3.10 may not be installed where this runs).
# Its whole value is that it cannot pass without a 3.10 interpreter having read the file list.
BIN="$TMP/bin"; mkdir -p "$BIN"
ln -s "$(command -v git)" "$BIN/git"; ln -s "$(command -v cat)" "$BIN/cat"
# The fakes answer the job's version probe by really running its code, with sys.version_info set to
# the version they pretend to be, so a probe that stops looking at the version is caught.
PYREAL="$(command -v python3)"
fake_interpreter() { # $1 = path, $2 = pretended sys.version_info tuple
    cat > "$1" <<FAKE
#!/bin/sh
if [ "\$1" = "-c" ]; then
    exec "$PYREAL" -c "import sys; sys.version_info = $2
\$2"
fi
cat > "\$FAKE_STDIN"
echo "\$1" > "\$FAKE_ARG"
pwd > "\$FAKE_PWD"
exit "\${FAKE_RC:-0}"
FAKE
    chmod +x "$1"
}
fake_interpreter "$BIN/fake310" "(3, 10, 12, 'final', 0)"
fake_interpreter "$BIN/fake312" "(3, 12, 3, 'final', 0)"

run_py310_job() { # $1 = PY310 value ("" = unset), $2 = FAKE_RC, $3 = PATH dir (default $BIN), $4 = start dir
    (
        # shellcheck source=/dev/null
        source "$SCRIPT"
        unset PY310
        [[ -n "$1" ]] && export PY310="$1"
        export FAKE_RC="$2" FAKE_STDIN="$TMP/fake_stdin" FAKE_ARG="$TMP/fake_arg" FAKE_PWD="$TMP/fake_pwd"
        : > "$FAKE_STDIN"; : > "$FAKE_ARG"; : > "$FAKE_PWD"
        cd "${4:-.}" || exit 99
        PATH="${3:-$BIN}" job_py310 >/dev/null 2>&1
    )
    echo $?
}

echo "job_py310: no PY310 and no python3.10 on PATH -> fails"
check "exit 1" 1 "$(run_py310_job "" 0)"
echo "job_py310: PY310 is not a 3.10 interpreter -> fails"
check "exit 1" 1 "$(run_py310_job "$BIN/fake312" 0)"
echo "job_py310: a 3.10 interpreter that reports a failure -> fails"
check "exit 1" 1 "$(run_py310_job "$BIN/fake310" 1)"
echo "job_py310: a 3.10 interpreter -> passes, and the program got the tracked .py list on stdin"
check "exit 0" 0 "$(run_py310_job "$BIN/fake310" 0)"
check "stdin lists the program itself" "yes" \
    "$(tr '\0' '\n' < "$TMP/fake_stdin" | grep -x 'tools/test_workflow/check_py310_compile.py' > /dev/null && echo yes || echo no)"
check "argument is the program" "$REPO_ROOT/tools/test_workflow/check_py310_compile.py" "$(cat "$TMP/fake_arg")"

echo "job_py310: PY310 unset, python3.10 on PATH -> passes, and the program is called"
BIN2="$TMP/bin2"; mkdir -p "$BIN2"
ln -s "$(command -v git)" "$BIN2/git"; ln -s "$(command -v cat)" "$BIN2/cat"
ln -s "$BIN/fake310" "$BIN2/python3.10"
check "exit 0" 0 "$(run_py310_job "" 0 "$BIN2")"
check "argument is the program" "$REPO_ROOT/tools/test_workflow/check_py310_compile.py" "$(cat "$TMP/fake_arg")"

echo "job_py310: called from another directory -> the program still runs in the repo root, on the whole tracked list"
check "exit 0" 0 "$(run_py310_job "$BIN/fake310" 0 "$BIN2" "$TMP")"
check "working directory is the repo root" "$REPO_ROOT" "$(cat "$TMP/fake_pwd")"
check "stdin lists the program itself" "yes" \
    "$(tr '\0' '\n' < "$TMP/fake_stdin" | grep -x 'tools/test_workflow/check_py310_compile.py' > /dev/null && echo yes || echo no)"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
