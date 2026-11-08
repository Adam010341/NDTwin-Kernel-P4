#!/usr/bin/env bash
#
# The built kernel runs its orderly shutdown when `ndt down` stops it. FIXED-ISSUES A-13.
#
# [Co-developed with claude code -- Adam]
#
# `ndt down` stops the kernel through stack.sh: start_bg launched it under supervise.sh in a
# process group of its own, and stop_one sends SIGTERM to that group, waits, and sends SIGKILL if
# it is still there. While the kernel handled SIGINT only, SIGTERM's default action ended it at
# once: status 143, no "All subsystems stopped", no destructor run.
#
# This drives the real binary through the real start_bg and stop_one, so what is asserted is the
# path an operator runs, not a signal sent by hand:
#
#   1. TERM through stop_one, three rounds: the ending supervise.sh records is 0, both shutdown
#      lines are in the log, the application manager's destructor logged its cleanup, stop_one did
#      not have to send KILL, and nothing is left on :8000.
#   2. INT to the kernel's own pid (Ctrl-C), as the control: the same ending. It proves that a
#      kernel which reaches its loop at all can stop cleanly here, so case 1 failing is about
#      SIGTERM and not about this machine.
#
# The kernel is started the way stack.sh starts it (from the build directory, --mode mininet,
# --topology, --no-ai) on the shipped 4-host OVS model, with no controller and no fabric behind
# it: the smallest setup that reaches main's loop. It needs TCP :8000 and UDP :6343, which a
# running lab holds; with either held this suite says SKIP and runs nothing rather than measure
# another process. It declares that need, so the L1 lane excuses the skip on a hosted CI runner
# (DECLARED-SKIP) and names it on any other machine (FAIL-SKIP, "needs kernel-ports"):
# NDTWIN_L1_NEEDS: kernel-ports
#
# Isolation: PID_DIR/LOG_DIR/RUN_DIR point at a temp directory, so no registry or log of a real
# stack is read or written; every process this starts is stopped by its recorded pid.
#
# Run:  bash tests/shell/test_kernel_stops_on_term.sh      (BUILD_DIR defaults to ./build)
# Mutation gate: tests/shell/mutate_kernel_stops_on_term.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="${STACK_UNDER_TEST:-$REPO/tools/test_workflow/stack.sh}"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
[[ "$BUILD_DIR" == /* ]] || BUILD_DIR="$PWD/$BUILD_DIR"
KERNEL_BIN="$BUILD_DIR/bin/ndtwin_kernel"
TOPO="$REPO/setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json"
# How long the kernel may take to reach its loop. A Debug build on a slow runner is the case.
READY_WITHIN_S="${READY_WITHIN_S:-60}"

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

[[ -x "$KERNEL_BIN" ]] || { echo "SKIP: no kernel binary at $KERNEL_BIN -- build it first"; exit 0; }
[[ -f "$TOPO" ]] || { echo "SKIP: the topology $TOPO is missing"; exit 0; }

# held <t|u> <port> -- something is listening there. Unknown (no ss) counts as free: the kernel
# then fails to bind, and the readiness check below says so in its own words.
held() { command -v ss >/dev/null 2>&1 && [[ -n "$(ss -l"$1"nH "sport = :$2" 2>/dev/null)" ]]; }
for spec in t:8000 u:6343; do
    if held "${spec%%:*}" "${spec#*:}"; then
        echo "SKIP: port ${spec#*:} is held (a lab is running here?); this suite would measure that process"
        exit 0
    fi
done

TMP="$(mktemp -d -t ndt_kernel_term.XXXXXX)"
export PID_DIR="$TMP/pids" LOG_DIR="$TMP/logs" RUN_DIR="$TMP"
mkdir -p "$PID_DIR" "$LOG_DIR"

# stack.sh returns early when sourced: this defines start_bg/stop_one without running a command.
# shellcheck source=/dev/null
source "$STACK"

# Whatever is left of a case that failed half-way: its process group, by the recorded pid.
cleanup() {
    local pid
    pid="$(cat "$PID_DIR/kernel.pid" 2>/dev/null)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

field() { sed -n "s/^$2=//p" "$1" 2>/dev/null; }
has_line() { grep -qF -- "$2" "$1" 2>/dev/null && echo present || echo absent; }

# The ending of the run that started after history_lines was read, from supervise.sh's appended
# history. Not from kernel.exit: report_exit removes a FATAL record once it has reported it, and
# a group KILL leaves no record at all -- both would read as an empty status.
history_lines() { if [[ -f "$PID_DIR/kernel.exit.log" ]]; then wc -l <"$PID_DIR/kernel.exit.log"; else echo 0; fi; }
ending_since() {
    local n; n="$(history_lines)"
    if (( n > $1 )); then
        tail -1 "$PID_DIR/kernel.exit.log" | sed -n 's/.*\tstatus=\([0-9]*\)\t.*/\1/p'
    else
        echo "no record (killed together with its supervisor?)"
    fi
}

# start_kernel -- start_bg it as stack.sh does, then wait for its API to listen. rc 1 when it
# never got there, with the reason on stdout. Called in this shell, not in $(...), because it
# sets KERNEL_CHILD.
start_kernel() {
    start_bg kernel "$LOG_DIR/kernel.log" \
        bash -c "cd '$BUILD_DIR' && exec ./bin/ndtwin_kernel --mode mininet --topology '$TOPO' --no-ai" \
        >/dev/null 2>&1
    local i child
    for (( i = 0; i < READY_WITHIN_S * 5; i++ )); do
        grep -qF "Server Listening on port" "$LOG_DIR/kernel.log" 2>/dev/null && break
        [[ -s "$PID_DIR/kernel.exit" ]] && break
        sleep 0.2
    done
    child="$(cat "$PID_DIR/kernel.child.pid" 2>/dev/null)"
    if ! grep -qF "Server Listening on port" "$LOG_DIR/kernel.log" 2>/dev/null \
        || ! [[ "$child" =~ ^[0-9]+$ ]] || ! kill -0 "$child" 2>/dev/null; then
        echo "the kernel did not reach its loop within ${READY_WITHIN_S}s"
        [[ -s "$PID_DIR/kernel.exit" ]] && echo "  it ended: $(field "$PID_DIR/kernel.exit" reason)"
        tail -5 "$LOG_DIR/kernel.log" 2>/dev/null | sed 's/^/  log: /'
        return 1
    fi
    KERNEL_CHILD="$child"
    return 0
}

echo "binary: $KERNEL_BIN ($(sha256sum "$KERNEL_BIN" | cut -c1-16))"
echo

# --- 1. TERM, through stop_one ------------------------------------------------------------------
# More than one round, because the shutdown has had a race of its own: the collector's stop()
# joined its worker pool while its receive thread was joining the same threads, which aborted or
# hung some shutdowns and not others (2 of 3 aborted in one measured run).
TERM_ROUNDS="${TERM_ROUNDS:-3}"
for (( round = 1; round <= TERM_ROUNDS; round++ )); do
    echo "SIGTERM through stop_one (the 'ndt down' path), round $round of $TERM_ROUNDS"
    if start_kernel >"$TMP/why" 2>&1; then
        check "TERM: the kernel reached its loop" "yes" "yes"
        before="$(history_lines)"
        t0=$EPOCHREALTIME
        STACK_FATAL_ENDINGS=""
        stop_one kernel >"$TMP/stop_term.out" 2>&1
        t1=$EPOCHREALTIME
        echo "    stop_one took $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }') s"
        check "TERM: the recorded ending is a clean exit" "0" "$(ending_since "$before")"
        check "TERM: the kernel logged that it was asked to stop" "present" \
            "$(has_line "$LOG_DIR/kernel.log" "Shutdown requested. Cleaning up")"
        check "TERM: the kernel logged that every subsystem stopped" "present" \
            "$(has_line "$LOG_DIR/kernel.log" "All subsystems stopped. Exiting.")"
        # The destructors ran too: the application manager's is what removes the per-app folders.
        check "TERM: the application manager's destructor ran" "present" \
            "$(has_line "$LOG_DIR/kernel.log" "Cleaning up registered NFS folders in")"
        check "TERM: stop_one did not have to send KILL" "absent" "$(has_line "$TMP/stop_term.out" "sending KILL")"
        check "TERM: stop_one reported no fatal ending" "" "$STACK_FATAL_ENDINGS"
        check "TERM: the kernel's pid is gone" "gone" "$(kill -0 "$KERNEL_CHILD" 2>/dev/null && echo alive || echo gone)"
        check "TERM: nothing is left listening on :8000" "free" "$(held t 8000 && echo held || echo free)"
        sed 's/^/    stop_one: /' "$TMP/stop_term.out"
        grep -E "terminate called|what\(\)" "$LOG_DIR/kernel.log" 2>/dev/null | sed 's/^/    kernel.log: /'
    else
        check "TERM: the kernel reached its loop" "yes" "no: $(cat "$TMP/why")"
    fi
    echo
done

# --- 2. INT to the kernel itself: the control ---------------------------------------------------
echo "SIGINT to the kernel's pid (Ctrl-C), the control"
if start_kernel >"$TMP/why" 2>&1; then
    check "INT: the kernel reached its loop" "yes" "yes"
    before="$(history_lines)"
    t0=$EPOCHREALTIME
    # supervise.sh runs the kernel as a background job of a non-interactive shell, so it starts
    # with SIGINT ignored; only the kernel's own handler makes this signal do anything.
    kill -INT "$KERNEL_CHILD"
    # supervise.sh writes .exit after the kernel has ended; the window stop_one allows (stack.sh
    # before that window had a name used 20 ticks too).
    for (( i = 0; i < ${STOP_WAIT_TICKS:-20}; i++ )); do
        [[ -s "$PID_DIR/kernel.exit" ]] && break
        sleep 0.5
    done
    t1=$EPOCHREALTIME
    echo "    the kernel ended after $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }') s"
    check "INT: the recorded ending is a clean exit" "0" "$(ending_since "$before")"
    check "INT: the kernel logged that it was asked to stop" "present" \
        "$(has_line "$LOG_DIR/kernel.log" "Shutdown requested. Cleaning up")"
    check "INT: the kernel logged that every subsystem stopped" "present" \
        "$(has_line "$LOG_DIR/kernel.log" "All subsystems stopped. Exiting.")"
    # The destructors ran too: the application manager's is what removes the per-app folders.
    check "INT: the application manager's destructor ran" "present" \
        "$(has_line "$LOG_DIR/kernel.log" "Cleaning up registered NFS folders in")"
    stop_one kernel >/dev/null 2>&1
else
    check "INT: the kernel reached its loop" "yes" "no: $(cat "$TMP/why")"
fi

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $PASS checks, all passed"
