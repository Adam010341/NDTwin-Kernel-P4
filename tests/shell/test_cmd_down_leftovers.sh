#!/usr/bin/env bash
#
# stack.sh cmd_down, leftovers branch: a port that is still listening after teardown.
#
# [Co-developed with claude code -- Adam]
#
# Why this exists: cmd_down walks ports.sh's table with the real ndt_port_open, and a port that is
# still open makes it print who holds it and return 1 -- "held by a process this script started"
# when the pidfile registry says so, "did not start it" otherwise. No other suite runs that branch
# against the real functions: test_supervise_exit_status.sh stubs the probe (so that a listener on
# the machine cannot redden its ending checks), test_ports_that_block_restart.sh covers ports.sh
# only, and test_ndt_down_stops_only_ours.sh replaces stack.sh with a fake. Without this file the
# branch could stop returning 1, or swap its ours/stray verdict, with every suite green.
#
# Isolation: PID_DIR/LOG_DIR/RUN_DIR are a temp dir, NDT_PORT_TABLE is overridden to ONE 459xx
# port (set after sourcing, because ports.sh assigns the table unconditionally), so cmd_down never
# sees a real pidfile or a real table port. The listener is a throwaway python3 this test starts and
# records the pid of FROM THE CHILD ITSELF (not `$!`); it is killed only after `ps` confirms the
# recorded pid still runs this test's own listener. No pkill/pgrep, no lab contact.
#
# The "ours" variant has a wrinkle: stop_one would normally stop a process named by a pidfile.
# The pidfile is backdated so that stop_one refuses ("pid started AFTER the pidfile was written"),
# which leaves the process running and the pidfile in place -- the state the verdict reads.
#
# Run:  bash tests/shell/test_cmd_down_leftovers.sh
# Env:  STACK_UNDER_TEST=<path to a stack.sh COPY>   (the mutation gate uses it; the copy needs
#       components.env, ports.sh and supervise.sh beside it)

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="${STACK_UNDER_TEST:-$REPO/tools/test_workflow/stack.sh}"

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

TMP="$(mktemp -d -t ndt_down_leftovers.XXXXXX)"
LISTENER_PID=""
LISTENER_MARK="$TMP/listener.pid"   # also in the listener's argv, which is how ps identifies it

# Kill the recorded listener pid, and only that one, and only while ps still shows this test's
# own python3 under it.
stop_listener() {
    local pid="$LISTENER_PID" args
    [[ -n "$pid" ]] || return 0
    args="$(ps -o args= -p "$pid" 2>/dev/null)"
    if [[ "$args" == *python3*"$LISTENER_MARK"* ]]; then
        kill -TERM "$pid" 2>/dev/null
        for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    fi
    LISTENER_PID=""
}
trap 'stop_listener; rm -rf "$TMP"' EXIT

export PID_DIR="$TMP/pids" LOG_DIR="$TMP/logs" RUN_DIR="$TMP"
mkdir -p "$PID_DIR" "$LOG_DIR"

# stack.sh returns early when sourced: functions only, no command runs.
# shellcheck source=/dev/null
source "$STACK"

# A 459xx port nothing holds. Refuse (exit 2, nothing run) if every candidate is held: a test that
# claims "this port is ours" must not run on a port somebody else is using.
PORT=""
for cand in 45937 45938 45939 45940; do
    if ! ndt_port_open "$cand" tcp && [[ -z "$(ss -ltnH "( sport = :$cand )" 2>/dev/null)" ]]; then
        PORT="$cand"; break
    fi
done
if [[ -z "$PORT" ]]; then
    echo "  REFUSED  every candidate port (45937-45940) is held by something else; nothing was run"
    echo "Ran 0 checks, 0 failed (refused)"
    exit 2
fi
# After sourcing: ports.sh assigns the table unconditionally when it is sourced.
NDT_PORT_TABLE="$PORT|tcp|both|the test's own listener|FIXTURE-CONSEQUENCE"

# start_listener -- python3 binds 127.0.0.1:$PORT and writes ITS OWN pid to $LISTENER_MARK once it
# is listening. Sets LISTENER_PID from that file; empty if the bind failed.
start_listener() {
    rm -f "$LISTENER_MARK" "$LISTENER_MARK.tmp"
    python3 -c '
import os, socket, sys, time
mark, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(5)
with open(mark + ".tmp", "w") as f:
    f.write(str(os.getpid()))
os.rename(mark + ".tmp", mark)
time.sleep(120)
' "$LISTENER_MARK" "$PORT" >/dev/null 2>&1 &
    for _ in $(seq 1 50); do [[ -s "$LISTENER_MARK" ]] && break; sleep 0.1; done
    LISTENER_PID="$(cat "$LISTENER_MARK" 2>/dev/null)"
    if [[ ! "$LISTENER_PID" =~ ^[0-9]+$ ]]; then LISTENER_PID=""; return 1; fi
    for _ in $(seq 1 30); do ndt_port_open "$PORT" tcp && return 0; sleep 0.1; done
    return 1
}

echo "cmd_down with a port still listening: the real probe, the real branch"

# --- control: nothing listens -> the teardown is clean ----------------------------------------
# Without this the cases below would pass against a cmd_down that fails unconditionally.
rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
out="$(cmd_down 2>&1)"; rc=$?
check "control: nothing on :$PORT -> down returns 0" "0" "$rc"
case "$out" in *"still listening"*|*"this script started"*)
    check "control: and it reports no leftover" "none" "$out" ;;
    *) check "control: and it reports no leftover" "none" "none" ;; esac

# --- stray: a listener nobody registered ------------------------------------------------------
if ! start_listener; then
    check "injection took effect: the stray listener is up on :$PORT" "up" "not up"
else
    check "injection took effect: the stray listener is up on :$PORT" "up" "up"
    COMM="$(cat "/proc/$LISTENER_PID/comm" 2>/dev/null)"
    check "  and it is the python3 this test started" "python3" "$COMM"
    rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
    out="$(cmd_down 2>&1)"; rc=$?
    check "stray: a still-listening port fails down" "1" "$rc"
    case "$out" in *":$PORT is still listening, held by $COMM pid $LISTENER_PID"*)
        check "stray: it names the port and the holder's pid" "yes" "yes" ;;
        *) check "stray: it names the port and the holder's pid" "yes" "no: $out" ;; esac
    case "$out" in *"This script did not start it"*)
        check "stray: it says this script did not start it" "yes" "yes" ;;
        *) check "stray: it says this script did not start it" "yes" "no: $out" ;; esac
    case "$out" in *"FIXTURE-CONSEQUENCE"*)
        check "stray: it prints the row's consequence" "yes" "yes" ;;
        *) check "stray: it prints the row's consequence" "yes" "no: $out" ;; esac
    case "$out" in *"is still held by a process this script started"*)
        check "stray: it does not claim the holder is ours" "yes" "no: $out" ;;
        *) check "stray: it does not claim the holder is ours" "yes" "yes" ;; esac
    check "stray: down did not kill the listener it does not own" "alive" \
        "$(kill -0 "$LISTENER_PID" 2>/dev/null && echo alive || echo gone)"

    # --- ours: the same listener, now registered in PID_DIR ------------------------------------
    # Backdated, so stop_one refuses to signal it (see the header) and the pidfile stays.
    echo "$LISTENER_PID" >"$PID_DIR/kernel.pid"
    touch -d '2 hours ago' "$PID_DIR/kernel.pid"
    out="$(cmd_down 2>&1)"; rc=$?
    check "ours: a still-listening registered port fails down" "1" "$rc"
    case "$out" in *":$PORT is still held by a process this script started ($COMM pid $LISTENER_PID)"*)
        check "ours: it says a process this script started holds it, by pid" "yes" "yes" ;;
        *) check "ours: it says a process this script started holds it, by pid" "yes" "no: $out" ;; esac
    case "$out" in *"This script did not start it"*)
        check "ours: it does not say this script did not start it" "yes" "no: $out" ;;
        *) check "ours: it does not say this script did not start it" "yes" "yes" ;; esac
    case "$out" in *"FIXTURE-CONSEQUENCE"*)
        check "ours: it prints the row's consequence" "yes" "yes" ;;
        *) check "ours: it prints the row's consequence" "yes" "no: $out" ;; esac
    check "ours: the injection held (stop_one left the listener running)" "alive" \
        "$(kill -0 "$LISTENER_PID" 2>/dev/null && echo alive || echo gone)"

    # --- and once the holder is gone, the same pidfile no longer fails down --------------------
    stop_listener
    for _ in $(seq 1 30); do ndt_port_open "$PORT" tcp || break; sleep 0.1; done
    out="$(cmd_down 2>&1)"; rc=$?
    check "after: the listener is gone and down returns 0 again" "0" "$rc"
fi

echo
if [[ $FAIL -gt 0 ]]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
