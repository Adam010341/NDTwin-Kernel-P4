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
# branch could stop returning 1, swap its ours/stray verdict, or call any registered pid "ours"
# with every suite green. Three variants pin those: a stray holder (no pidfile), an owned holder
# (pidfile names the holder), and a registered pid that is NOT the holder (the identity test in
# port_owner_verdict, stack.sh:779). Not covered: the pgid branch (:783-784) and the p4_proxy and
# ryu verdicts -- every variant registers kernel.pid only.
#
# Isolation: PID_DIR/LOG_DIR/RUN_DIR are a temp dir, NDT_PORT_TABLE is overridden to ONE 459xx
# port (set after sourcing, because ports.sh assigns the table unconditionally), so cmd_down never
# sees a real pidfile or a real table port. The listener is a throwaway python3 this test starts and
# records the pid of FROM THE CHILD ITSELF (not `$!`); the registered non-holder is a `sleep` that
# execs from a bash which wrote its own pid. Each is killed only after `ps` confirms the recorded
# pid still runs this test's own process. No pkill/pgrep, no lab contact. Needs ss, ps and python3;
# refuses (exit 2, nothing run) without them, without a temp dir, or without a free port.
#
# 🔴 What the "ours" variants really pin. They need a pidfile that survives cmd_down's stop_one,
# which signals whatever the file names. The only way to keep it is to backdate the file so stop_one
# REFUSES: it has just declared the pid "a different process that reuses the number" (stack.sh:
# 694-701) and kept the file. cmd_down then calls the same pid "a process this script started --
# stop_one did not manage to stop it". That contradiction is a known production issue (the verdict
# does not apply stop_one's start-time test); the "ours" variant pins TODAY'S ROUTING, not that
# "ours" is the right answer. If port_owner_verdict is fixed to apply that test, expect this
# variant to go red and update it rather than restore the old behaviour.
#
# Run:  bash tests/shell/test_cmd_down_leftovers.sh
# Env:  STACK_UNDER_TEST=<path to a stack.sh COPY>   (used by the one-off red runs in the evidence
#       dir; the mutation gate does not use it -- it runs this file from a tree copy instead). The
#       copy needs components.env, ports.sh and supervise.sh beside it.

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="${STACK_UNDER_TEST:-$REPO/tools/test_workflow/stack.sh}"

refuse() { echo "  REFUSED  $1; nothing was run"; echo "Ran 0 checks, 0 failed (refused)"; exit 2; }
for tool in ss ps python3 mktemp; do
    command -v "$tool" >/dev/null 2>&1 || refuse "needs $tool and it is not on PATH"
done

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

TMP="$(mktemp -d -t ndt_down_leftovers.XXXXXX 2>/dev/null)"
[[ -n "$TMP" && -d "$TMP" ]] || refuse "mktemp -d failed (TMPDIR unwritable?)"
LISTENER_PID=""
SLEEPER_PID=""
LISTENER_MARK="$TMP/listener.pid"   # also in the listener's argv, which is how ps identifies it
SLEEPER_MARK="$TMP/sleeper"         # argv[0] of the sleeper, likewise

# Kill the recorded pid, and only that one, and only while ps still shows this test's own
# process (argv containing the marker path) under it.
kill_ours() {   # $1 = pid, $2 = marker
    local pid="$1" mark="$2" args
    [[ -n "$pid" ]] || return 0
    args="$(ps -o args= -p "$pid" 2>/dev/null)"
    if [[ "$args" == *"$mark"* ]]; then
        kill -TERM "$pid" 2>/dev/null
        for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    fi
}
stop_listener() { kill_ours "$LISTENER_PID" "$LISTENER_MARK"; LISTENER_PID=""; }
stop_sleeper()  { kill_ours "$SLEEPER_PID" "$SLEEPER_MARK"; SLEEPER_PID=""; }
trap 'stop_listener; stop_sleeper; rm -rf "$TMP"' EXIT

export PID_DIR="$TMP/pids" LOG_DIR="$TMP/logs" RUN_DIR="$TMP"
mkdir -p "$PID_DIR" "$LOG_DIR"

# stack.sh returns early when sourced: functions only, no command runs.
# shellcheck source=/dev/null
source "$STACK"

CANDIDATES=(45937 45938 45939 45940)
PORT=""

# port_free <port> -- nothing listens on it, by the real probe and by ss.
port_free() {
    ! ndt_port_open "$1" tcp && [[ -z "$(ss -ltnH "( sport = :$1 )" 2>/dev/null)" ]]
}
# use_port <port> -- the table ports.sh assigns on source is overridden AFTER sourcing.
use_port() {
    PORT="$1"
    NDT_PORT_TABLE="$PORT|tcp|both|the test's own listener|FIXTURE-CONSEQUENCE"
}

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
    for _ in $(seq 1 50); do [[ -s "$LISTENER_MARK" ]] && break; kill -0 $! 2>/dev/null || break; sleep 0.1; done
    LISTENER_PID="$(cat "$LISTENER_MARK" 2>/dev/null)"
    if [[ ! "$LISTENER_PID" =~ ^[0-9]+$ ]]; then LISTENER_PID=""; return 1; fi
    for _ in $(seq 1 30); do ndt_port_open "$PORT" tcp && return 0; sleep 0.1; done
    return 1
}

# start_sleeper -- a live process this test owns that is NOT on the port. A bash writes its own pid
# and execs sleep under an argv[0] containing the marker, so the recorded pid is the sleeper's.
start_sleeper() {
    rm -f "$SLEEPER_MARK.pid"
    bash -c 'echo $$ >"$1.pid"; exec -a "$1" sleep 120' _ "$SLEEPER_MARK" >/dev/null 2>&1 &
    for _ in $(seq 1 50); do [[ -s "$SLEEPER_MARK.pid" ]] && break; sleep 0.1; done
    SLEEPER_PID="$(cat "$SLEEPER_MARK.pid" 2>/dev/null)"
    [[ "$SLEEPER_PID" =~ ^[0-9]+$ ]] || { SLEEPER_PID=""; return 1; }
    [[ "$(ps -o args= -p "$SLEEPER_PID" 2>/dev/null)" == *"$SLEEPER_MARK"* ]]
}

echo "cmd_down with a port still listening: the real probe, the real branch"

# The control runs on the first free candidate. All four held -> refuse: a test that claims "this
# port is ours" must not run on a port somebody else is using.
for cand in "${CANDIDATES[@]}"; do
    port_free "$cand" && { use_port "$cand"; break; }
done
[[ -n "$PORT" ]] || refuse "every candidate port (${CANDIDATES[*]}) is held by something else"

# --- control: nothing listens -> the teardown is clean ----------------------------------------
# Without this the cases below would pass against a cmd_down that fails unconditionally.
rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
out="$(cmd_down 2>&1)"; rc=$?
check "control: nothing on :$PORT -> down returns 0" "0" "$rc"
case "$out" in *"still listening"*|*"this script started"*)
    check "control: and it reports no leftover" "none" "$out" ;;
    *) check "control: and it reports no leftover" "none" "none" ;; esac

# --- the listener: first candidate that is free AND binds -------------------------------------
# A candidate can be free by the probe and still refuse the bind (a loopback client socket holds the
# number, or a bound-but-not-listening socket): try the next one rather than call it a failure.
STARTED=0
for cand in "${CANDIDATES[@]}"; do
    port_free "$cand" || continue
    use_port "$cand"
    if start_listener; then STARTED=1; break; fi
    stop_listener
done
[[ "$STARTED" == 1 ]] || refuse "no candidate port (${CANDIDATES[*]}) was both free and bindable"
echo "  port     using :$PORT"
check "injection took effect: the stray listener is up on :$PORT" "up" \
    "$(ndt_port_open "$PORT" tcp && echo up || echo "not up")"
COMM="$(cat "/proc/$LISTENER_PID/comm" 2>/dev/null)"
check "  and it is the python3 this test started" "python3" "$COMM"

# --- stray: a listener nobody registered ------------------------------------------------------
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

# --- ours: the same listener, now registered in PID_DIR ---------------------------------------
# Backdated, so stop_one refuses to signal it (see the header) and the pidfile stays.
echo "$LISTENER_PID" >"$PID_DIR/kernel.pid"
touch -d '2 hours ago' "$PID_DIR/kernel.pid"
out="$(cmd_down 2>&1)"; rc=$?
check "ours: a still-listening registered port fails down" "1" "$rc"
case "$out" in *"refusing to stop kernel: pid $LISTENER_PID started"*)
    check "ours: stop_one refused, which is what kept the pidfile" "yes" "yes" ;;
    *) check "ours: stop_one refused, which is what kept the pidfile" "yes" "no: $out" ;; esac
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

# --- registered, but not the holder: the identity test must say no ----------------------------
# kernel.pid names a live process this test owns that is NOT on the port, backdated so stop_one
# refuses and the file stays. port_owner_verdict must compare the registered pid with the holder's
# (stack.sh:779): a version that calls any registered pid "ours" goes red here.
if start_sleeper; then
    check "injection took effect: a live registered process that is not the holder" "alive" \
        "$(kill -0 "$SLEEPER_PID" 2>/dev/null && echo alive || echo gone)"
    echo "$SLEEPER_PID" >"$PID_DIR/kernel.pid"
    touch -d '2 hours ago' "$PID_DIR/kernel.pid"
    out="$(cmd_down 2>&1)"; rc=$?
    check "not-holder: a still-listening port fails down" "1" "$rc"
    case "$out" in *"refusing to stop kernel: pid $SLEEPER_PID started"*)
        check "not-holder: stop_one refused, which is what kept the pidfile" "yes" "yes" ;;
        *) check "not-holder: stop_one refused, which is what kept the pidfile" "yes" "no: $out" ;; esac
    case "$out" in *":$PORT is still listening, held by $COMM pid $LISTENER_PID"*"This script did not start it"*)
        check "not-holder: it names the real holder and says this script did not start it" "yes" "yes" ;;
        *) check "not-holder: it names the real holder and says this script did not start it" "yes" "no: $out" ;; esac
    case "$out" in *"this script started"*)
        check "not-holder: it does not call the registered pid the holder's owner" "yes" "no: $out" ;;
        *) check "not-holder: it does not call the registered pid the holder's owner" "yes" "yes" ;; esac
    check "not-holder: the registered process was left running" "alive" \
        "$(kill -0 "$SLEEPER_PID" 2>/dev/null && echo alive || echo gone)"
else
    check "injection took effect: a live registered process that is not the holder" "alive" "not started"
fi

# --- and once the holder is gone, the same pidfile no longer fails down -----------------------
stop_listener
stop_sleeper
for _ in $(seq 1 30); do ndt_port_open "$PORT" tcp || break; sleep 0.1; done
out="$(cmd_down 2>&1)"; rc=$?
check "after: the holder is gone and down returns 0 again" "0" "$rc"

echo
if [[ $FAIL -gt 0 ]]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
