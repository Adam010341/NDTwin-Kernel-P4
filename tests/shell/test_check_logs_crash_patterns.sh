#!/usr/bin/env bash
#
# What the crash detector can actually see.
#
# [Co-developed with claude code -- Adam]
#
# THE FINDING THIS EXISTS FOR (2026-09-02, alongside KNOWN-ISSUES B-5):
#
# check_logs.py's CRASH_PATTERNS listed "terminate called after throwing" and "terminate called
# recursively" -- and not "terminate called without an active exception", which is the one the
# kernel actually printed. The kernel aborted on every clean shutdown for as long as the defect
# existed, and had that abort landed in a log this gate examined, the gate would have said the
# log was clean. The gate existed, ran, and returned green, and it never had the ability to see
# the thing it is for.
#
# The shape of the mistake is not "one missing string". It is a hand-written list standing in for
# a whole class of phenomena -- every fatal message a C++ runtime, glibc, or the shell can print
# -- where a gap presents itself as exhaustiveness. So this file enumerates the class and asserts
# each member, and the negative controls at the end assert the patterns are not so wide that
# ordinary prose trips them. A detector that fires on everything is as useless as one that fires
# on nothing, and both look like "the gate is working".
#
# Run:  bash tests/shell/test_check_logs_crash_patterns.sh
#       CHECK_LOGS=/path/to/other/check_logs.py bash tests/shell/... # to score another version
#
# The CHECK_LOGS override is how the red-then-green was recorded: run against
# `git show HEAD:tools/contract_test/check_logs.py` and the cases below fail.

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CHECK_LOGS="${CHECK_LOGS:-$REPO/tools/contract_test/check_logs.py}"
ALLOWLIST="$REPO/tools/contract_test/warning_allowlist.txt"

PASS=0
FAIL=0
TMP="$(mktemp -d -t ndt_crashpat.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# A line that is unremarkable on its own, so every verdict below is about the injected line.
NORMAL='[2026-09-02 23:00:00.000] [info] [main.cpp:300 main] Logger Loads Successfully! level'

# must_fail <label> <injected line>
must_fail() {
    local label="$1" line="$2"
    printf '%s\n%s\n' "$NORMAL" "$line" >"$TMP/log"
    local out rc
    out="$("$CHECK_LOGS" "$TMP/log" --allowlist "$ALLOWLIST" 2>&1)"; rc=$?
    if [[ "$rc" == "1" ]] && grep -qi "crash" <<<"$out"; then
        echo "  ok       caught: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   NOT caught: $label"
        echo "             injected: $line"
        echo "             exit=$rc"
        FAIL=$((FAIL + 1))
    fi
}

# must_pass <label> <line that only LOOKS alarming>
must_pass() {
    local label="$1" line="$2"
    printf '%s\n%s\n' "$NORMAL" "$line" >"$TMP/log"
    local out rc
    out="$("$CHECK_LOGS" "$TMP/log" --allowlist "$ALLOWLIST" 2>&1)"; rc=$?
    if [[ "$rc" == "0" ]]; then
        echo "  ok       not a false positive: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   FALSE POSITIVE: $label"
        echo "             line: $line"
        echo "             exit=$rc"
        echo "$out" | grep -i crash | head -3 | sed 's/^/             /'
        FAIL=$((FAIL + 1))
    fi
}

echo "libstdc++ terminate paths"
must_fail "terminate, exception in flight" \
    "terminate called after throwing an instance of 'std::runtime_error'"
must_fail "terminate, NO exception in flight (B-5: a joinable std::thread destroyed)" \
    "terminate called without an active exception"
must_fail "terminate during terminate" "terminate called recursively"
must_fail "the exception's message" "  what():  bind: Address already in use"
must_fail "a pure virtual call" "pure virtual method called"
must_fail "allocation failure" \
    "terminate called after throwing an instance of 'std::bad_alloc'"

echo
echo "glibc aborts"
must_fail "assert()" \
    "ndtwin_kernel: src/x.cpp:42: void f(): Assertion \`p != nullptr' failed."
must_fail "double free, the tcache wording" "free(): double free detected in tcache 2"
must_fail "double free, the older wording" "double free or corruption (out)"
must_fail "invalid free" "free(): invalid pointer"
must_fail "malloc corruption" "malloc(): memory corruption"
must_fail "realloc corruption" "realloc(): invalid pointer"
must_fail "munmap corruption" "munmap_chunk(): invalid pointer"
must_fail "chunk header corruption" "corrupted size vs. prev_size"
must_fail "linked-list corruption" "corrupted double-linked list"
must_fail "stack protector" "*** stack smashing detected ***: terminated"
must_fail "FORTIFY_SOURCE" "*** buffer overflow detected ***: terminated"
must_fail "glibc's own fatal error" "Fatal glibc error: malloc assertion failure"

echo
echo "deaths reported by the shell, not by the process"
must_fail "SIGSEGV" "./stack.sh: line 364: 12345 Segmentation fault      (core dumped) ./bin/ndtwin_kernel"
must_fail "SIGABRT" "./stack.sh: line 364: 12345 Aborted                 (core dumped) ./bin/ndtwin_kernel"
must_fail "SIGKILL -- what systemd-oomd leaves behind, and the process prints nothing itself" \
    "./stack.sh: line 364: 12345 Killed                  ./bin/ndtwin_kernel"
must_fail "SIGBUS" "./stack.sh: line 364: 12345 Bus error               ./bin/ndtwin_kernel"
must_fail "SIGILL" "./stack.sh: line 364: 12345 Illegal instruction     ./bin/ndtwin_kernel"
must_fail "SIGFPE" "Floating point exception (core dumped)"
must_fail "a signal named in prose" "child exited on SIGABRT"

echo
echo "sanitizers"
must_fail "ASan" "==12345==ERROR: AddressSanitizer: heap-use-after-free on address 0x602"
must_fail "TSan" "WARNING: ThreadSanitizer: data race (pid=12345)"

echo
echo "negative controls -- ordinary lines that must NOT be called crashes"
must_pass "a normal info line" \
    "[2026-09-02 23:00:00.000] [info] [ControllerAndOtherEventHandler.cpp:189 stop] ControllerAndOtherEventHandler stopped."
must_pass "the word terminated in prose" \
    "[2026-09-02 23:00:00.000] [info] [SimulationRequestManager.cpp:296 run] the simulation request terminated normally"
must_pass "the word killed in prose" \
    "[2026-09-02 23:00:00.000] [info] [P4PowerStrategy.cpp:185 off] killed the switch process for dpid 5"
must_pass "a number next to the word aborted in prose" \
    "[2026-09-02 23:00:00.000] [info] [HttpSession.cpp:96 handleRequest] 12 aborted requests were retried"
must_pass "free() mentioned without an allocator message" \
    "[2026-09-02 23:00:00.000] [info] [x.cpp:1 f] buffers are free() of any owner here"

echo
if [[ $FAIL -gt 0 ]]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    echo "  (checker under test: $CHECK_LOGS)"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
echo "  (checker under test: $CHECK_LOGS)"
