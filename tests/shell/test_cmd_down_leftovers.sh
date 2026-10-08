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
# with every suite green.
#
# Variants:
#   stray        a listener nobody registered
#   reused       kernel.pid names the holder but is backdated, so stop_one refuses it as "a
#                different process that reuses the number" -- and the verdict must agree: NOT ours
#   symlink      kernel.pid is a symlink to a file naming the holder; stop_one refuses to read it,
#                and the verdict must not follow it either
#   ours         kernel.pid names the holder and passes stop_one's tests (see below)
#   not-holder   kernel.pid names a live process that is not the holder (the identity test)
#   pgid         ryu.pid names a process-group leader whose CHILD holds the port (the pgid test,
#                and a component other than kernel)
#   cannot tell  a udp row whose probe answers 2: named as not checked, never reported clear, and
#                not a failure -- once through a stubbed probe, once with no ss on PATH for real
#   ss form      every `( sport = ... )` filter stack.sh and ports.sh build uses ss(8)'s `:PORT`
#
# 🔴 How "ours" is reached. port_owner_verdict applies stop_one's own tests (pidfile_vouches), and
# stop_one removes every pidfile it accepts, so after a real stop_one the only pidfile left is one
# it refused -- which the verdict now refuses too. "ours" is therefore reachable only when a pidfile
# that passes those tests appears AFTER stop_one ran: an `up` racing this `down` (or a pidfile
# stop_one could not delete). The ours and pgid variants build exactly that: stop_one runs for real,
# and a wrapper then writes a fresh pidfile naming the holder, as a concurrent start_bg would. A
# holder that stop_one accepts and yet fails to stop is not buildable -- it sends KILL and removes
# the pidfile either way.
#
# Isolation: PID_DIR/LOG_DIR/RUN_DIR are a temp dir, NDT_PORT_TABLE is overridden to 459xx ports
# (set after sourcing, because ports.sh assigns the table unconditionally), so cmd_down never sees a
# real pidfile or a real table port. The listeners are throwaway python3s this test starts and
# records the pid of FROM THE CHILD ITSELF (not `$!`); the registered non-holder is a `sleep` that
# execs from a bash which wrote its own pid; the group leader is a bash that wrote its own pid. Each
# is killed only after `ps` confirms the recorded pid still runs this test's own process. No
# pkill/pgrep, no lab contact. Needs ss, ps and python3; refuses (exit 2, nothing run) without them,
# without a temp dir, or without a free port.
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
# has / hasnt <what> <needle> <haystack>
has()   { case "$3" in *"$2"*) check "$1" "yes" "yes" ;; *) check "$1" "yes" "no: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) check "$1" "yes" "no: $3" ;; *) check "$1" "yes" "yes" ;; esac; }

TMP="$(mktemp -d -t ndt_down_leftovers.XXXXXX 2>/dev/null)"
[[ -n "$TMP" && -d "$TMP" ]] || refuse "mktemp -d failed (TMPDIR unwritable?)"
LISTENER_PID=""
LEADER_PID=""
SLEEPER_PID=""
LISTENER_MARK="$TMP/listener.pid"   # also in the listener's argv, which is how ps identifies it
LEADER_MARK="$TMP/listener.pid.lead"
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
stop_listener() {
    kill_ours "$LISTENER_PID" "$LISTENER_MARK"; LISTENER_PID=""
    # The group leader's argv carries the listener mark too (it is its $1).
    kill_ours "$LEADER_PID" "$LISTENER_MARK"; LEADER_PID=""
}
stop_sleeper()  { kill_ours "$SLEEPER_PID" "$SLEEPER_MARK"; SLEEPER_PID=""; }
# alive <pid> -- "alive" or "gone". Not `kill -0`: a child this shell has not reaped yet is a zombie,
# and kill -0 succeeds on a zombie, so "the listener was left running" would pass for a dead one.
alive() {
    local st
    st="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)"
    [[ -n "$st" && "$st" != Z ]] && echo alive || echo gone
}
trap 'stop_listener; stop_sleeper; rm -rf "$TMP"' EXIT

export PID_DIR="$TMP/pids" LOG_DIR="$TMP/logs" RUN_DIR="$TMP" NO_COLOR=1
mkdir -p "$PID_DIR" "$LOG_DIR"

# Every ss call this test and the code under it make is logged, then run for real, so the filter
# form can be checked at the end (ss(8) documents `sport = :PORT`; a bare number is version luck).
REAL_SS="$(command -v ss)"
mkdir -p "$TMP/ssbin"
export SS_LOG="$TMP/ss.calls" REAL_SS
: >"$SS_LOG"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$SS_LOG"\nexec "$REAL_SS" "$@"\n' >"$TMP/ssbin/ss"
chmod +x "$TMP/ssbin/ss"
PATH="$TMP/ssbin:$PATH"

# stack.sh returns early when sourced: functions only, no command runs.
# shellcheck source=/dev/null
source "$STACK"

# The real probe and the real stop_one, kept under other names so a case can wrap them.
eval "real_ndt_port_open() $(declare -f ndt_port_open | tail -n +2)"
eval "real_stop_one() $(declare -f stop_one | tail -n +2)"

CANDIDATES=(45937 45938 45939 45940)
UPORT=45943   # the udp row of the cannot-tell cases; never bound, its probe is what is varied
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
with_udp_row() {
    NDT_PORT_TABLE="$PORT|tcp|both|the test's own listener|FIXTURE-CONSEQUENCE
$UPORT|udp|both|the test's udp row|FIXTURE-UDP-CONSEQUENCE"
}

# It ACCEPTS and closes every connection: each /dev/tcp probe is a real connect, and a listener that
# never accepts fills its backlog after a handful of them -- the next probe's SYN is then dropped and
# the connect hangs for minutes (measured: one cmd_down took 134 s, outliving the listener).
PY_LISTENER='
import os, socket, sys, time
mark, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(64)
s.settimeout(0.5)
with open(mark + ".tmp", "w") as f:
    f.write(str(os.getpid()))
os.rename(mark + ".tmp", mark)
end = time.time() + 120
while time.time() < end:
    try:
        c, _ = s.accept()
        c.close()
    except socket.timeout:
        pass
'

# wait_listener -- LISTENER_PID from the file the listener wrote, then the port must answer.
wait_listener() {
    for _ in $(seq 1 50); do [[ -s "$LISTENER_MARK" ]] && break; sleep 0.1; done
    LISTENER_PID="$(cat "$LISTENER_MARK" 2>/dev/null)"
    if [[ ! "$LISTENER_PID" =~ ^[0-9]+$ ]]; then LISTENER_PID=""; return 1; fi
    for _ in $(seq 1 30); do ndt_port_open "$PORT" tcp && return 0; sleep 0.1; done
    return 1
}

# start_listener -- python3 binds 127.0.0.1:$PORT and writes ITS OWN pid to $LISTENER_MARK once it
# is listening. Sets LISTENER_PID from that file; empty if the bind failed.
start_listener() {
    rm -f "$LISTENER_MARK" "$LISTENER_MARK.tmp"
    python3 -c "$PY_LISTENER" "$LISTENER_MARK" "$PORT" >/dev/null 2>&1 &
    wait_listener
}

# start_group_listener -- the same python3, as the CHILD of a bash that setsid made a process-group
# leader. The bash writes its own pid (LEADER_PID) and waits, so the listener's pgid is the leader's
# pid while the listener's own pid is not -- the shape start_bg gives every component.
start_group_listener() {
    rm -f "$LISTENER_MARK" "$LISTENER_MARK.tmp" "$LEADER_MARK"
    setsid bash -c 'echo $$ >"$1.lead"; python3 -c "$3" "$1" "$2" & wait' \
        _ "$LISTENER_MARK" "$PORT" "$PY_LISTENER" >/dev/null 2>&1 &
    wait_listener || return 1
    LEADER_PID="$(cat "$LEADER_MARK" 2>/dev/null)"
    [[ "$LEADER_PID" =~ ^[0-9]+$ ]] || { LEADER_PID=""; return 1; }
    [[ "$(ps -o args= -p "$LEADER_PID" 2>/dev/null)" == *"$LISTENER_MARK"* ]]
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

# down_reregistering <component> <pid> -- cmd_down, where the real stop_one runs for every
# component and then, for <component> only, a FRESH pidfile naming <pid> is written: what a
# concurrent start_bg leaves behind. The pidfile passes stop_one's tests, because <pid> started
# before the file was written. Prints cmd_down's output; its rc is cmd_down's.
# Always called inside $(...), so the wrapper and the two globals die with that subshell. Globals,
# not locals: the wrapper runs under cmd_down, and a local named `pid` anywhere on that call stack
# would be the one it read.
down_reregistering() {
    RR_COMP="$1" RR_PID="$2"
    stop_one() {
        real_stop_one "$@"; local r=$?
        [[ "$1" == "$RR_COMP" ]] && echo "$RR_PID" >"$PID_DIR/$1.pid"
        return $r
    }
    cmd_down 2>&1
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
has   "stray: it names the port and the holder's pid" ":$PORT is still listening, held by $COMM pid $LISTENER_PID" "$out"
has   "stray: it says this script did not start it" "This script did not start it" "$out"
has   "stray: it prints the row's consequence" "FIXTURE-CONSEQUENCE" "$out"
hasnt "stray: it does not claim the holder is ours" "is still held by a process this script started" "$out"
check "stray: down did not kill the listener it does not own" "alive" \
    "$(alive "$LISTENER_PID")"

# --- reused: kernel.pid names the holder, but stop_one calls it a reused number ----------------
# Backdated by two hours, so the holder "started AFTER the pidfile was written". stop_one refuses
# and keeps the file; the verdict reads the same file and must reach the same answer. Until the
# verdict shared stop_one's tests, this case printed "a process this script started" for the pid
# stop_one had just called "a different process that reuses the number".
rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
echo "$LISTENER_PID" >"$PID_DIR/kernel.pid"
touch -d '2 hours ago' "$PID_DIR/kernel.pid"
out="$(cmd_down 2>&1)"; rc=$?
check "reused: a still-listening port fails down" "1" "$rc"
has   "reused: stop_one refused the pid as a reused number" "refusing to stop kernel: pid $LISTENER_PID started" "$out"
hasnt "reused: it does not call the holder ours (stop_one just said it is not)" \
      "is still held by a process this script started" "$out"
has   "reused: it names the holder and says this script did not start it" \
      ":$PORT is still listening, held by $COMM pid $LISTENER_PID" "$out"
has   "reused: it prints the row's consequence" "FIXTURE-CONSEQUENCE" "$out"
check "reused: the listener was left running" "alive" \
    "$(alive "$LISTENER_PID")"

# --- symlink: kernel.pid is a symlink to a fresh file naming the holder ------------------------
# The target is current, so the start-time test alone would pass it: only the symlink refusal
# separates this from "ours". stop_one refuses to read it; the verdict must not follow it.
rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
echo "$LISTENER_PID" >"$TMP/elsewhere.pid"
ln -s "$TMP/elsewhere.pid" "$PID_DIR/kernel.pid"
out="$(cmd_down 2>&1)"; rc=$?
check "symlink: a still-listening port fails down" "1" "$rc"
has   "symlink: stop_one refused to read it" "kernel.pid is a symlink; refusing to read it" "$out"
hasnt "symlink: it does not call the holder ours through the symlink" \
      "is still held by a process this script started" "$out"
check "symlink: the listener was left running" "alive" \
    "$(alive "$LISTENER_PID")"
rm -f "$TMP/elsewhere.pid"

# --- ours: a current kernel.pid naming the holder, written after stop_one ran -----------------
# See the header: the only state in which a pidfile stop_one would accept is still there.
rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
out="$(down_reregistering kernel "$LISTENER_PID")"; rc=$?
rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"   # before anything else can signal what it names
check "ours: a still-listening registered port fails down" "1" "$rc"
has   "ours: it says a process this script started holds it, by pid" \
      ":$PORT is still held by a process this script started ($COMM pid $LISTENER_PID)" "$out"
has   "ours: and that its pidfile is current, not that stop_one failed on it" \
      "registered while this 'down' ran" "$out"
hasnt "ours: stop_one refused nothing" "refusing" "$out"
hasnt "ours: it does not say this script did not start it" "This script did not start it" "$out"
has   "ours: it prints the row's consequence" "FIXTURE-CONSEQUENCE" "$out"
check "ours: the injection held (the listener is still running)" "alive" \
    "$(alive "$LISTENER_PID")"

# --- registered, but not the holder: the identity test must say no ----------------------------
# kernel.pid names a live process this test owns that is NOT on the port, and is current, so the
# verdict gets past pidfile_vouches and has to compare the registered pid with the holder's: a
# version that calls any registered pid "ours" goes red here.
if start_sleeper; then
    check "injection took effect: a live registered process that is not the holder" "alive" \
        "$(alive "$SLEEPER_PID")"
    rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
    out="$(down_reregistering kernel "$SLEEPER_PID")"; rc=$?
    rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
    check "not-holder: a still-listening port fails down" "1" "$rc"
    case "$out" in *":$PORT is still listening, held by $COMM pid $LISTENER_PID"*"This script did not start it"*)
        check "not-holder: it names the real holder and says this script did not start it" "yes" "yes" ;;
        *) check "not-holder: it names the real holder and says this script did not start it" "yes" "no: $out" ;; esac
    hasnt "not-holder: it does not call the registered pid the holder's owner" "this script started" "$out"
    check "not-holder: the registered process was left running" "alive" \
        "$(alive "$SLEEPER_PID")"
else
    check "injection took effect: a live registered process that is not the holder" "alive" "not started"
fi
stop_sleeper

# --- cannot tell, next to a real leftover: both are said, and the leftover still fails ----------
rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
with_udp_row
STUB_CALLS="$TMP/stub.calls"; : >"$STUB_CALLS"
out="$(ndt_port_open() { echo "$1 ${2:-tcp}" >>"$STUB_CALLS"; [[ "$1" == "$UPORT" ]] && return 2; real_ndt_port_open "$@"; }
       cmd_down 2>&1)"; rc=$?
check "cannot tell + leftover: injection took effect (the udp row was probed through the stub)" \
      "yes" "$(grep -qx "$UPORT udp" "$STUB_CALLS" && echo yes || echo "no: $(tr '\n' ';' <"$STUB_CALLS")")"
check "cannot tell + leftover: the still-listening tcp port still fails down" "1" "$rc"
has   "cannot tell + leftover: the tcp leftover is named" ":$PORT is still listening, held by" "$out"
has   "cannot tell + leftover: the udp port is named as not checked" ":$UPORT (udp) could NOT be checked" "$out"
hasnt "cannot tell + leftover: the udp port is not called a leftover" ":$UPORT is still listening" "$out"
use_port "$PORT"

# --- pgid: ryu.pid names a group leader whose child holds the port ----------------------------
stop_listener
for _ in $(seq 1 30); do ndt_port_open "$PORT" tcp || break; sleep 0.1; done
if start_group_listener; then
    check "injection took effect: the listener is a child in the leader's process group" \
        "$LEADER_PID" "$(ps -o pgid= -p "$LISTENER_PID" 2>/dev/null | tr -d ' ')"
    check "  and its own pid is not the leader's" "different" \
        "$([[ "$LISTENER_PID" != "$LEADER_PID" ]] && echo different || echo same)"
    rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
    out="$(down_reregistering ryu "$LEADER_PID")"; rc=$?
    rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
    check "pgid: a port held in ryu's process group fails down" "1" "$rc"
    has   "pgid: it says a process this script started holds it, naming the child" \
          ":$PORT is still held by a process this script started (python3 pid $LISTENER_PID)" "$out"
    hasnt "pgid: it does not say this script did not start it" "This script did not start it" "$out"
    check "pgid: the listener was left running" "alive" \
        "$(alive "$LISTENER_PID")"
else
    check "injection took effect: the listener is a child in the leader's process group" "up" "not started"
fi

# --- and once the holder is gone, down returns 0 again -----------------------------------------
stop_listener
for _ in $(seq 1 30); do ndt_port_open "$PORT" tcp || break; sleep 0.1; done
rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"
out="$(cmd_down 2>&1)"; rc=$?
check "after: the holder is gone and down returns 0 again" "0" "$rc"
check "after: and it says done" "yes" "$(grep -qx 'done' <<<"$out" && echo yes || echo "no: $out")"

# --- cannot tell, alone: a stubbed probe answers 2 for the udp row ----------------------------
# 2 is "cannot tell" (ports.sh). It must not be read as closed: the port is named as not checked,
# the closing line is not a plain "done", and -- the routine case -- it does not fail down.
with_udp_row
: >"$STUB_CALLS"
out="$(ndt_port_open() { echo "$1 ${2:-tcp}" >>"$STUB_CALLS"; [[ "$1" == "$UPORT" ]] && return 2; real_ndt_port_open "$@"; }
       cmd_down 2>&1)"; rc=$?
check "cannot tell: injection took effect (the udp row was probed through the stub)" \
      "yes" "$(grep -qx "$UPORT udp" "$STUB_CALLS" && echo yes || echo "no: $(tr '\n' ';' <"$STUB_CALLS")")"
check "cannot tell: it does not fail a down that found nothing listening" "0" "$rc"
has   "cannot tell: it names the port as not checked, and why" \
      ":$UPORT (udp) could NOT be checked: the probe could not tell -- not reported clear" "$out"
has   "cannot tell: the closing line says the check was incomplete, naming the port" \
      "the port check is INCOMPLETE -- not checked: :$UPORT/udp" "$out"
check "cannot tell: the closing line is not a plain 'done'" "no" \
      "$(grep -qx 'done' <<<"$out" && echo "yes: $out" || echo no)"
hasnt "cannot tell: the udp port is not called a leftover" ":$UPORT is still listening" "$out"

# --- cannot tell, for real: no ss on PATH ----------------------------------------------------
# The real ndt_port_open, on a PATH with every tool cmd_down needs here except ss. UDP has no
# handshake to borrow, so this is the machine ports.sh's rc 2 was written for.
NOSS="$TMP/noss"; mkdir -p "$NOSS"
for t in rm cat stat ps awk sed grep sort cut tr seq sleep getconf date ls mv; do
    p="$(command -v "$t")" && ln -s "$p" "$NOSS/$t"
done
check "no ss: injection took effect (ss is not on the PATH cmd_down runs with)" "absent" \
      "$( PATH="$NOSS"; command -v ss >/dev/null 2>&1 && echo present || echo absent )"
out="$( PATH="$NOSS"; cmd_down 2>&1 )"; rc=$?
hasnt "no ss: every other tool was found" "command not found" "$out"
check "no ss: it does not fail a down that found nothing listening" "0" "$rc"
has   "no ss: it names the udp port as not checked, and that ss is missing" \
      ":$UPORT (udp) could NOT be checked: no ss on PATH" "$out"
check "no ss: the closing line is not a plain 'done'" "no" \
      "$(grep -qx 'done' <<<"$out" && echo "yes: $out" || echo no)"
use_port "$PORT"

# --- ss form: every port filter built under this test uses ss(8)'s `:PORT` -------------------
# Counted over the whole run; port_listener_pids (stack.sh) and ndt_port_listener_pids (ports.sh)
# both ran above. The `-ltnp` count guards against a vacuous pass.
n_lp="$(grep -c -- '^-ltnpH ( sport = ' "$SS_LOG")"
check "ss form: stack.sh's listener lookup ran (at least one -ltnpH filter)" "yes" \
      "$([[ "$n_lp" -gt 0 ]] && echo yes || echo "no: $n_lp")"
check "ss form: no sport filter uses a bare port number" "" \
      "$(grep -- 'sport = ' "$SS_LOG" | grep -v -- 'sport = :' | sort -u | tr '\n' ';')"

echo
if [[ $FAIL -gt 0 ]]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
