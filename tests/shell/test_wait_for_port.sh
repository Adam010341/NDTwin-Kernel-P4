#!/usr/bin/env bash
#
# Tests for stack.sh's wait_for_port ownership check.
#
# [Co-developed with claude code -- Adam]
#
# This guard shipped broken and nothing noticed. Its "is the port ours?" branch re-tested
# `! is_running "$component"` -- textually the same condition as the liveness check a few lines
# above, in the same loop iteration -- so it was unreachable, and the case it was written for sailed
# through: a leftover kernel holding :8000 was reported "up" while the kernel stack.sh had just
# started was already dead of `bind: Address already in use`. That run measured the stray process and
# reported 288 edges and 128 hosts, the OVS topology's numbers, during a P4 session. Nothing said so.
#
# A false PASS here is worse than a bug in the kernel, because every measurement downstream is then
# about the wrong network. So the guard gets tests, driving the real function out of stack.sh rather
# than a copy of it.
#
# [Co-developed with claude code -- Adam]
# Cases 7-10 pin how the bring-up treats each pidfile state port_owner_verdict shares with
# stop_one (pidfile_vouches):
#   reused (pidfile older than the process it names)  decided by who holds the port, as before
#       the test was shared, and WARNED about -- the start time is fooled by a wall-clock step, so
#       it is not allowed to refuse a bring-up (7: the holder -> up; 8: not the holder -> refused)
#   symlink   refused, "not ours", as stop_one refuses it (9)
#   no usable pid   "cannot tell" -- in practice the liveness check refuses it first (10)
#
# Isolation: PID_DIR/LOG_DIR/RUN_DIR are a temp dir exported BEFORE stack.sh is sourced, so not even
# its source-time mkdir touches the checkout's .test_run. The holder and the sleepers carry a marker
# path from that dir in their argv and are killed only when ps still shows it.
#
# Env:  STACK_UNDER_TEST=<path to a stack.sh COPY>   (one-off red runs; needs components.env,
#       ports.sh and supervise.sh beside it)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="${STACK_UNDER_TEST:-$HERE/../../tools/test_workflow/stack.sh}"

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
has() { case "$3" in *"$2"*) check "$1" "yes" "yes" ;; *) check "$1" "yes" "no: $3" ;; esac; }

# Own scratch dirs, so a real run's tracking is never touched.
TMP="$(mktemp -d -t ndt_wait_for_port.XXXXXX 2>/dev/null)"
[[ -n "$TMP" && -d "$TMP" ]] || { echo "  REFUSED  mktemp -d failed"; echo "Ran 0 checks, 0 failed (refused)"; exit 2; }
export PID_DIR="$TMP/pids" LOG_DIR="$TMP/logs" RUN_DIR="$TMP" NO_COLOR=1
mkdir -p "$PID_DIR" "$LOG_DIR"
MARK="$TMP/marker"
OURS=()   # pids this test started; each is killed only while ps still shows $MARK in its argv
kill_ours() {
    local p
    for p in "${OURS[@]:-}"; do
        [[ -n "$p" ]] || continue
        [[ "$(ps -o args= -p "$p" 2>/dev/null)" == *"$MARK"* ]] && kill "$p" 2>/dev/null
    done
    return 0
}
trap 'kill_ours; rm -rf "$TMP"' EXIT

# stack.sh returns early when sourced, so this defines its functions without running a command.
# shellcheck source=/dev/null
source "$STACK"

# A listener we did not start, standing in for the leftover kernel. It accepts and closes, so the
# repeated connect probes below never fill its backlog (a full backlog makes the next connect hang).
PORT=45871
python3 -c "
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $PORT)); s.listen(64); s.settimeout(0.5)
end = time.time() + 120
while time.time() < end:
    try:
        c, _ = s.accept(); c.close()
    except socket.timeout:
        pass
" "$MARK.holder" &
HOLDER_PID=$!
OURS+=("$HOLDER_PID")
for _ in $(seq 1 40); do
    port_open "$PORT" && break
    sleep 0.25
done
if ! port_open "$PORT"; then
    echo "  SKIP: could not bind :$PORT for the fixture"
    exit 0
fi

# sleeper <seconds> -- a live process that is NOT on the port; prints its pid.
sleeper() {
    bash -c 'echo $$ >"$1.pid"; exec -a "$1" sleep "$2"' _ "$MARK.sleep$RANDOM" "$1" >/dev/null 2>&1 &
    local f="" _
    for _ in $(seq 1 50); do f="$(ls "$MARK".sleep*.pid 2>/dev/null | head -1)"; [[ -s "$f" ]] && break; sleep 0.1; done
    cat "$f"; rm -f "$f"
}

echo "wait_for_port ownership"

# 1. The finding. A component that is alive but does NOT own the port must not be reported up.
#    The sleeper is alive for the whole test, so the liveness check passes -- which is precisely why
#    the old guard let this through.
INNOCENT="$(sleeper 60)"; OURS+=("$INNOCENT")
echo "$INNOCENT" >"$PID_DIR/faker.pid"
out="$(wait_for_port "$PORT" "test API" 2 faker 2>&1)"; rc=$?
check "a stray listener is refused even though our component is alive" "1" "$rc"
case "$out" in
    *"not ours"*) check "and it says why" "yes" "yes" ;;
    *)            check "and it says why" "yes" "no: $out" ;;
esac

# 2. The port's real owner is accepted.
echo "$HOLDER_PID" >"$PID_DIR/holder.pid"
out="$(wait_for_port "$PORT" "test API" 2 holder 2>&1)"
check "the process that actually holds the port is accepted" "0" "$?"

# NOTE: the descendant case (start_bg uses setsid, so the listener can be a child of the recorded
# pid) is handled by port_owner_verdict's pgid comparison and covered by
# test_cmd_down_leftovers.sh's pgid variant; not repeated here.

# 4. No component name: the old, weaker behaviour is preserved for callers that pass none.
out="$(wait_for_port "$PORT" "test API" 2 2>&1)"
check "with no component name, an open port is still success" "0" "$?"

# 5. A dead component is refused before the port is even examined.
echo "999999" >"$PID_DIR/ghost.pid"
out="$(wait_for_port "$PORT" "test API" 2 ghost 2>&1)"
check "a component that is not running is refused" "1" "$?"

# 6. A port nobody holds times out rather than succeeding.
out="$(wait_for_port "$((PORT + 7))" "nothing" 1 2>&1)"
check "an unheld port times out" "1" "$?"

# 7. Reused, and it IS the holder: what a forward clock step does to a legitimate component. The
#    bring-up must not refuse it (stop_one already will not stop it, so a refusal here leaves no way
#    down and no way up), and must say which two readings are in play.
echo "$HOLDER_PID" >"$PID_DIR/aged.pid"
touch -d '2 hours ago' "$PID_DIR/aged.pid"
out="$(wait_for_port "$PORT" "test API" 2 aged 2>&1)"; rc=$?
check "reused, holder: a pidfile older than the holder it names is not a refusal" "0" "$rc"
has   "  but it is warned about, naming the pidfile" "aged.pid is older than the process it names" "$out"
has   "  and both readings: a recycled pid or a clock step" "a recycled pid, or the clock" "$out"

# 8. Reused, and it is NOT the holder: a recycled number now running something unrelated. Still
#    decided by who holds the port -- refused, as before the start-time test was shared.
AGED_OTHER="$(sleeper 60)"; OURS+=("$AGED_OTHER")
echo "$AGED_OTHER" >"$PID_DIR/agedother.pid"
touch -d '2 hours ago' "$PID_DIR/agedother.pid"
out="$(wait_for_port "$PORT" "test API" 2 agedother 2>&1)"; rc=$?
check "reused, not the holder: refused although the recycled pid is alive" "1" "$rc"
has   "  as not ours" "not ours" "$out"

# 9. A symlinked pidfile naming the holder. stop_one refuses to read it; so does the bring-up --
#    is_running would follow it, so falling back to liveness would accept anything it points at.
echo "$HOLDER_PID" >"$TMP/elsewhere.pid"
ln -s "$TMP/elsewhere.pid" "$PID_DIR/linked.pid"
out="$(wait_for_port "$PORT" "test API" 2 linked 2>&1)"; rc=$?
check "symlink: a symlinked pidfile is refused even when it names the holder" "1" "$rc"
has   "  as not ours, saying it is a symlink" "linked.pid is a symlink" "$out"

# 10. No usable pid ("abc"): the verdict would say "cannot tell", but the liveness check at the top
#     of the loop gets there first -- is_running cannot kill -0 "abc" -- so it is refused as dead.
echo "abc" >"$PID_DIR/junk.pid"
out="$(wait_for_port "$PORT" "test API" 2 junk 2>&1)"; rc=$?
check "junk pidfile: not up" "1" "$rc"
has   "  refused by the liveness check" "junk exited while starting" "$out"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
