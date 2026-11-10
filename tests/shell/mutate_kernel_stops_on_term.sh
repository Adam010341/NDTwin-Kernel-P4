#!/usr/bin/env bash
#
# Mutation gate: the kernel stops in order on SIGTERM, and stack.sh reports one that does not.
# FIXED-ISSUES A-13.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/shell/test_kernel_stops_on_term.sh (the built kernel, started and stopped through
# stack.sh's start_bg/stop_one) and the KILL-window case of tests/shell/test_supervise_exit_status.sh.
#
# Kernel mutants (src/main.cpp; each rebuilds ndtwin_kernel):
#   K1  SIGTERM is not registered                 -- the defect as it shipped
#   K2  the handler is one-shot (SA_RESETHAND)    -- the second TERM, the one supervise.sh
#                                                    forwards, kills the kernel mid-shutdown
#   K3  SIGINT is not registered                  -- the control must be able to fail too
#   K4  the shutdown blocks past stop_one's window
#   K5  the handler ends the process with status 0 and skips the orderly path, so the status
#       alone cannot be what the test reads
#   K6  the collector's stop() joins its worker pool before its receive thread again, so two
#       threads join the same workers (an abort or a hang at shutdown). A race, so the suite runs
#       K6_TERM_ROUNDS TERM rounds for this mutant (see K6_TERM_ROUNDS below for the measured rate),
#       and only a TERM round whose recorded ending is not a clean exit counts as the catch.
# stack.sh mutants (no rebuild):
#   S1  a KILL after the window is not recorded as a fatal ending
#   S2  no KILL after the window at all
#   S3  the KILL is reported without the phrase `ndt` reads as a fatal ending
#   S4  the KILL is not appended to <name>.exit.log
#   S5  a STOP_WAIT_TICKS that is not a positive whole number is not refused by the command
#   S6  cmd_down calls the KILL a crash again
# Widenings (must NOT be caught):
#   W1  a comment in the handler
#   W2  the two signals registered in the other order
#   W3  the hint under the KILL line reworded
#
# The kernel suite needs TCP :8000 and UDP :6343 free, as in a lab that is down; with either held
# it says SKIP, and this gate refuses at the baseline rather than count a skip as anything.
#
# Run from the repo root:  BUILD_DIR=build bash tests/shell/mutate_kernel_stops_on_term.sh
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
JOBS="${JOBS:-2}"
TARGET=ndtwin_kernel
# [Co-developed with claude code -- Adam]
# TERM rounds the kernel suite runs. Its own default for every mutant but K6, which is a race and
# gets more rounds; the per-round rate it is sized from is recorded where K6 runs.
SUITE_TERM_ROUNDS=""
K6_TERM_ROUNDS="${K6_TERM_ROUNDS:-12}"

MAIN=src/main.cpp
COLLECTOR=src/ndt_core/collection/FlowLinkUsageCollector.cpp
STACK=tools/test_workflow/stack.sh
FILES=("$MAIN" "$COLLECTOR" "$STACK")
KERNEL_SUITE=tests/shell/test_kernel_stops_on_term.sh
STACK_SUITE=tests/shell/test_supervise_exit_status.sh

for f in "${FILES[@]}" "$KERNEL_SUITE" "$STACK_SUITE"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -d "$BUILD_DIR" ]] || { echo "REFUSE: $BUILD_DIR is not configured. cmake -B $BUILD_DIR -G Ninja" >&2; exit 2; }

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done
restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "$(snap "$f")" "$f"
        # cp -p puts the original mtime back, older than the object built from the mutant; ninja
        # would then rebuild nothing. touch makes the restored source the newest.
        touch "$f"
    done
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
WIDENINGS=0
WRONGLY_CAUGHT=0

anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

edit() {
    local file="$1" anchor="$2" repl="$3" n
    n=$(anchor_count "$file" "$anchor")
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    [[ "$n" -eq 1 ]] || { echo "  🔴 ANCHOR IS NOT UNIQUE ($n) -- this mutation proves nothing."; return 1; }
    ANCHOR="$anchor" REPL="$repl" python3 - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
}

build() { cmake --build "$BUILD_DIR" --target "$TARGET" --parallel "$JOBS" >/dev/null 2>&1; }

# red_checks <suite> -- the names of the checks that went red, one per line; nothing when the
# suite passed. A suite that skipped or printed no summary is reported as such, never as green.
red_checks() {
    local out rc
    out=$(BUILD_DIR="$BUILD_DIR" TERM_ROUNDS="${SUITE_TERM_ROUNDS:-3}" bash "$1" 2>&1); rc=$?
    if grep -qE '^SKIP:' <<<"$out"; then echo "SKIPPED: $(grep -E '^SKIP:' <<<"$out" | head -1)"; return; fi
    if [[ $rc -eq 0 ]] && grep -qE '^Ran [0-9]+ checks, all passed' <<<"$out"; then return; fi
    sed -n 's/^  FAILED   //p' <<<"$out"
    grep -qE '^Ran [0-9]+ checks' <<<"$out" || echo "NO-SUMMARY (rc $rc)"
}

# run_mutation <label> <suite> <expected red check> <apply> [rebuild]
run_mutation() {
    local label="$1" suite="$2" expected="$3" apply="$4" rebuild="${5:-}"
    printf '\n=== %s ===\n' "$label"
    MUTATIONS=$((MUTATIONS + 1))
    if ! "$apply"; then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if [[ -n "$rebuild" ]] && ! build; then
        echo "  🔴 MUTANT DOES NOT COMPILE -- the test never ran, so this counts as SURVIVED."
        SURVIVORS=$((SURVIVORS + 1)); restore; build; return
    fi
    local red; red=$(red_checks "$suite")
    if [[ -z "$red" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived."
        SURVIVORS=$((SURVIVORS + 1))
    elif grep -qF -- "$expected" <<<"$red"; then
        echo "  ✅ caught by: $expected"
        sed 's/^/     red: /' <<<"$red"
    else
        echo "  🔴 WRONG CHECK WENT RED: expected [$expected]"
        sed 's/^/     red: /' <<<"$red"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
    [[ -n "$rebuild" ]] && build
}

# run_widening <label> <suite> <apply> [rebuild] -- must stay green.
run_widening() {
    local label="$1" suite="$2" apply="$3" rebuild="${4:-}"
    printf '\n=== %s (widening: must NOT be caught) ===\n' "$label"
    WIDENINGS=$((WIDENINGS + 1))
    if ! "$apply" || { [[ -n "$rebuild" ]] && ! build; }; then
        echo "  🔴 widening could not be applied or built. NOT a pass."
        WRONGLY_CAUGHT=$((WRONGLY_CAUGHT + 1)); restore; [[ -n "$rebuild" ]] && build; return
    fi
    local red; red=$(red_checks "$suite")
    if [[ -z "$red" ]]; then
        echo "  ✅ stayed green"
    else
        echo "  🔴 WRONGLY CAUGHT -- the suite pins text, not behaviour:"
        sed 's/^/     red: /' <<<"$red"
        WRONGLY_CAUGHT=$((WRONGLY_CAUGHT + 1))
    fi
    restore
    [[ -n "$rebuild" ]] && build
}

# --- kernel mutants ------------------------------------------------------------------------------
k1() {
    edit "$MAIN" \
'    for (const int signo : {SIGINT, SIGTERM})' \
'    for (const int signo : {SIGINT}) // MUTANT: SIGTERM keeps its default action'
}
k2() {
    edit "$MAIN" \
'    action.sa_flags = SA_RESTART;' \
'    action.sa_flags = SA_RESTART | SA_RESETHAND; // MUTANT: one-shot'
}
k3() {
    edit "$MAIN" \
'    for (const int signo : {SIGINT, SIGTERM})' \
'    for (const int signo : {SIGTERM}) // MUTANT: SIGINT keeps its disposition'
}
k4() {
    edit "$MAIN" \
'    SPDLOG_LOGGER_INFO(Logger::instance(), "Shutdown requested. Cleaning up…");' \
'    SPDLOG_LOGGER_INFO(Logger::instance(), "Shutdown requested. Cleaning up…");
    std::this_thread::sleep_for(std::chrono::seconds(15)); // MUTANT: a stop that outlives the window'
}
k5() {
    edit "$MAIN" \
'handleShutdownSignal(int)
{
    gShutdownRequested.store(true);
}' \
'handleShutdownSignal(int)
{
    _exit(0); // MUTANT: status 0, no orderly path
}'
}
k6() {
    edit "$COLLECTOR" \
'    if (m_pktRcvThread.joinable())
    {
        m_pktRcvThread.join();
    }

    // With run() gone' \
'    stopAndJoinWorkers(); // MUTANT: the pool is joined while run() joins it too
    if (m_pktRcvThread.joinable())
    {
        m_pktRcvThread.join();
    }

    // With run() gone'
}
w1() {
    edit "$MAIN" \
'handleShutdownSignal(int)
{
    gShutdownRequested.store(true);
}' \
'handleShutdownSignal(int)
{
    // WIDENING: a comment
    gShutdownRequested.store(true);
}'
}
w2() {
    edit "$MAIN" \
'    for (const int signo : {SIGINT, SIGTERM})' \
'    for (const int signo : {SIGTERM, SIGINT}) // WIDENING: the other order'
}

# --- stack.sh mutants ----------------------------------------------------------------------------
s1() {
    edit "$STACK" \
'            STACK_FATAL_ENDINGS="${STACK_FATAL_ENDINGS:+$STACK_FATAL_ENDINGS }$name(KILL)"' \
'            : # MUTANT: a KILL after the window is not a fatal ending'
}
s2() {
    edit "$STACK" \
'            kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
            printf' \
'            : # MUTANT: no KILL after the window
            printf'
}
s3() {
    edit "$STACK" \
'            err "  🔴 $name did not stop cleanly: still running $(stop_wait_seconds) s after TERM; sending KILL"' \
'            warn "  $name did not exit on TERM; sending KILL" # MUTANT: the old warning'
}
s4() {
    edit "$STACK" \
'                >>"$PID_DIR/$name.exit.log"' \
'                >/dev/null # MUTANT: the KILL is not written to the exit history'
}
s5() {
    edit "$STACK" \
'if ! stop_wait_ticks_valid; then
    stop_wait_ticks_refusal
    exit 2
fi' \
': # MUTANT: a bad STOP_WAIT_TICKS is not refused'
}
s6() {
    edit "$STACK" \
'        err "  teardown itself worked, but something crashed or had to be killed rather than stopping:"' \
'        err "  teardown itself worked, but something crashed rather than stopped:" # MUTANT: the old wording'
}
w3() {
    edit "$STACK" \
'            err "     its own shutdown did not finish; see the tail of $LOG_DIR/$name.log"' \
'            err "     read the tail of $LOG_DIR/$name.log for where its shutdown stopped" # WIDENING'
}

echo "A-13 mutation gate (the kernel stops in order on SIGTERM)"
echo "  build dir : $BUILD_DIR   jobs: $JOBS"
for f in "${FILES[@]}" "$KERNEL_SUITE" "$STACK_SUITE"; do
    printf '  baseline  : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"
done
echo
echo "baseline (unmutated) must build and both suites must be green:"
if ! build; then
    echo "  REFUSE: the unmutated tree does not build."
    cmake --build "$BUILD_DIR" --target "$TARGET" --parallel "$JOBS" 2>&1 | tail -20 | sed 's/^/    /'
    exit 2
fi
for suite in "$KERNEL_SUITE" "$STACK_SUITE"; do
    red=$(red_checks "$suite")
    if [[ -n "$red" ]]; then
        echo "  REFUSE: $suite is not green before any mutation:"
        sed 's/^/    /' <<<"$red"
        exit 2
    fi
    echo "  ok       $suite green"
done

run_mutation "K1. SIGTERM is not registered (the defect)" "$KERNEL_SUITE" \
    "TERM: the recorded ending is a clean exit" k1 rebuild
run_mutation "K2. a one-shot handler: supervise.sh's forwarded TERM kills it" "$KERNEL_SUITE" \
    "TERM: the recorded ending is a clean exit" k2 rebuild
run_mutation "K3. SIGINT is not registered (the control can fail)" "$KERNEL_SUITE" \
    "INT: the recorded ending is a clean exit" k3 rebuild
run_mutation "K4. the shutdown outlives stop_one's window" "$KERNEL_SUITE" \
    "TERM: stop_one did not have to send KILL" k4 rebuild
run_mutation "K5. status 0 without the orderly path" "$KERNEL_SUITE" \
    "TERM: the kernel logged that it was asked to stop" k5 rebuild
# K6 is a race. Measured 2026-11-09 on a Debug build in a VM: 15 of 20 and 9 of 20 TERM rounds
# caught it in two runs, so one round misses it 25-55% of the time. 12 rounds keep a whole-gate
# miss below 0.1% at the worse of the two rates (0.55^12 = 0.08%; 8 rounds would be 0.8%).
SUITE_TERM_ROUNDS="$K6_TERM_ROUNDS"
run_mutation "K6. the collector joins its pool before its receive thread (the race)" "$KERNEL_SUITE" \
    "TERM: the recorded ending is a clean exit" k6 rebuild
SUITE_TERM_ROUNDS=""
run_widening "W1. a comment in the handler" "$KERNEL_SUITE" w1 rebuild
run_widening "W2. the signals registered in the other order" "$KERNEL_SUITE" w2 rebuild

run_mutation "S1. a KILL after the window is not a fatal ending" "$STACK_SUITE" \
    "and records it as a fatal ending" s1
run_mutation "S2. no KILL after the window" "$STACK_SUITE" \
    "it is killed when the window ends" s2
run_mutation "S3. the KILL is only a warning again" "$STACK_SUITE" \
    "stop_one says it did not stop cleanly" s3
run_mutation "S4. the KILL is not written to the exit history" "$STACK_SUITE" \
    "the KILL is in the component's exit history" s4
run_mutation "S5. a bad STOP_WAIT_TICKS is not refused by the command" "$STACK_SUITE" \
    "is refused before 'down' does anything" s5
run_mutation "S6. cmd_down calls the KILL a crash again" "$STACK_SUITE" \
    "and cmd_down does not call the KILL a crash" s6
run_widening "W3. the hint under the KILL line reworded" "$STACK_SUITE" w3

echo
echo "restoring and re-checking the baseline:"
restore
if ! build; then
    echo "  REFUSE: the RESTORED tree does not build. The working tree may be damaged."
    exit 2
fi
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$(snap "$f")"; then
        echo "  REFUSE: $f was not restored byte-identically."
        exit 2
    fi
done
echo "  ok       sources restored byte-identically and the tree builds"

echo
echo "mutations: $MUTATIONS   survivors: $SURVIVORS   widenings: $WIDENINGS   wrongly caught: $WRONGLY_CAUGHT"
if (( SURVIVORS > 0 || WRONGLY_CAUGHT > 0 )); then
    echo "🔴 GATE FAILED"
    exit 1
fi
echo "✅ every mutation was caught and no widening was."
