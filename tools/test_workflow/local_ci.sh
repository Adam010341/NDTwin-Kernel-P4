#!/usr/bin/env bash
#
# local_ci.sh -- run everything .github/workflows/ci.yml runs, here, in one command.
#
# [Co-developed with claude code -- Adam]
#
# GitHub Actions has been out of quota since b0a7bdc (all eight checks "Failing after 2s") and
# the repo is staying private for now, so CI is whatever actually gets run on this machine.
# The four workflow jobs are easy to name and easy to get wrong: TSan dies before main without
# `setarch -R`, ASan's UBSan half prints and still exits 0 without abort_on_error, clang needs
# one -Wno-error, and the GCC job deliberately runs the binary *and* ctest because each catches
# what the other misses. Running them by hand works exactly as long as someone remembers all of
# that -- the setarch line had to be rediscovered on 2026-08-13, three days after it was written
# down.
#
# Usage:
#   tools/test_workflow/local_ci.sh              # every job
#   tools/test_workflow/local_ci.sh gcc asan     # named jobs only
#
# Not fail-fast: every job runs even after one fails, because the point of a local run is to
# learn everything that is broken in one pass. Exit 1 if any job failed, 2 for a usage error.
#
# Mirrors .github/workflows/ci.yml -- when that file changes, change this one.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JOBS_ALL=(gcc python asan tsan clang p4cov)

if [[ -t 1 ]]; then
    G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; R=""; D=""; B=""; N=""
fi

step() { echo; echo "${B}=== $* ===${N}"; }

# --- jobs -------------------------------------------------------------------------
# One function per workflow job, same flags as the YAML. Each returns nonzero on failure.

job_gcc() {
    cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Debug >/dev/null || return 1
    cmake --build "$ROOT/build" -j"$(nproc)" || return 1
    # Direct execution *and* ctest: ctest runs one process per case, so a SetUpTestSuite failure
    # reads as "100% tests passed" while nothing ran. The workflow calls this its most important
    # line.
    "$ROOT/build/bin/test_routing_strategy" || return 1
    ctest --test-dir "$ROOT/build" --output-on-failure || return 1
}

job_python() {
    # The runner probes for an interpreter that can import the P4Runtime protobufs; locally that
    # is p4_proxy/venv. A fully-skipped file is a failure there unless it declares
    # NDTWIN_L1_OPT_IN -- unittest counts skips inside "Ran N", so all-skipped otherwise reads OK.
    bash "$ROOT/tools/test_workflow/l1_unit_tests.sh" || return 1
}

job_asan() {
    cmake -S "$ROOT" -B "$ROOT/build-asan" -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=asan \
          -DCMAKE_GTEST_DISCOVER_TESTS_DISCOVERY_MODE=PRE_TEST >/dev/null || return 1
    cmake --build "$ROOT/build-asan" -j"$(nproc)" || return 1
    # Without abort_on_error a UBSan report prints and the suite still exits 0.
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1:detect_stack_use_after_return=1 \
    UBSAN_OPTIONS=print_stacktrace=1 \
        "$ROOT/build-asan/bin/test_routing_strategy" || return 1
}

job_tsan() {
    cmake -S "$ROOT" -B "$ROOT/build-tsan" -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=tsan \
          -DCMAKE_GTEST_DISCOVER_TESTS_DISCOVERY_MODE=PRE_TEST >/dev/null || return 1
    cmake --build "$ROOT/build-tsan" -j"$(nproc)" || return 1
    # setarch -R disables ASLR. Without it: "FATAL: ThreadSanitizer: unexpected memory mapping"
    # before main -- current kernels use more mmap entropy than TSan's fixed shadow layout allows.
    TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1:history_size=4 \
        setarch "$(uname -m)" -R "$ROOT/build-tsan/bin/test_routing_strategy" || return 1
}

job_p4cov() {
    # Not in the GitHub workflow -- p4c is not on the hosted runners. Cheap to keep here: it
    # returns in milliseconds unless ndtwin_switch.p4 actually changed since the baseline.
    bash "$ROOT/tools/test_workflow/p4_coverage_gate.sh" || return 1
}

job_clang() {
    # A build, not a test run: a rot guard. clang once could not compile this at all (unique_ptr
    # to an incomplete type that GCC accepts), which blocked the whole fuzzing plan.
    cmake -S "$ROOT" -B "$ROOT/build-clang" -DCMAKE_BUILD_TYPE=Debug \
          -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_C_COMPILER=clang \
          -DCMAKE_CXX_FLAGS=-Wno-error=deprecated-declarations \
          -DCMAKE_GTEST_DISCOVER_TESTS_DISCOVERY_MODE=PRE_TEST >/dev/null || return 1
    cmake --build "$ROOT/build-clang" -j"$(nproc)" || return 1
}

# --- driver -----------------------------------------------------------------------

main() {
    local jobs=("$@")
    if [[ ${#jobs[@]} -eq 0 ]]; then
        jobs=("${JOBS_ALL[@]}")
    fi

    local job
    for job in "${jobs[@]}"; do
        local known=no known_job
        for known_job in "${JOBS_ALL[@]}"; do
            [[ "$job" == "$known_job" ]] && known=yes
        done
        if [[ "$known" == "no" ]]; then
            echo "${R}unknown job: $job${N}" >&2
            echo "usage: $0 [${JOBS_ALL[*]}]" >&2
            return 2
        fi
    done

    local -a results=()
    local failed=0 started
    started="$(date +%s)"

    for job in "${jobs[@]}"; do
        step "$job"
        if "job_$job"; then
            results+=("${G}PASS${N}  $job")
        else
            results+=("${R}FAIL${N}  $job")
            failed=1
        fi
    done

    echo
    echo "${B}=== local CI summary ===${N}"
    printf '%s\n' "${results[@]}"
    echo "${D}$(( $(date +%s) - started ))s, head $(git -C "$ROOT" log --oneline -1)${N}"

    if [[ "$failed" -ne 0 ]]; then
        echo "${R}local CI FAILED${N}" >&2
        return 1
    fi
    echo "${G}local CI passed${N}"
}

# Sourcing defines the functions without running anything -- that is the tests' seam.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

main "$@"
