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

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$HERE/../../tools/test_workflow/stack.sh"

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

# stack.sh returns early when sourced, so this defines its functions without running a command.
# shellcheck source=/dev/null
source "$STACK"

# Own scratch pid dir, so a real run's tracking is never touched.
PID_DIR="$(mktemp -d)"
trap 'rm -rf "$PID_DIR"; [[ -n "${HOLDER_PID:-}" ]] && kill "$HOLDER_PID" 2>/dev/null' EXIT

# A listener we did not start, standing in for the leftover kernel.
PORT=45871
python3 -c "
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $PORT)); s.listen(5)
time.sleep(120)
" &
HOLDER_PID=$!
for _ in $(seq 1 40); do
    port_open "$PORT" && break
    sleep 0.25
done
if ! port_open "$PORT"; then
    echo "  SKIP: could not bind :$PORT for the fixture"
    exit 0
fi

echo "wait_for_port ownership"

# 1. The finding. A component that is alive but does NOT own the port must not be reported up.
#    `sleep` is alive for the whole test, so the liveness check passes -- which is precisely why the
#    old guard let this through.
sleep 60 &
INNOCENT=$!
echo "$INNOCENT" >"$PID_DIR/faker.pid"
out="$(wait_for_port "$PORT" "test API" 2 faker 2>&1)"; rc=$?
check "a stray listener is refused even though our component is alive" "1" "$rc"
case "$out" in
    *"not ours"*) check "and it says why" "yes" "yes" ;;
    *)            check "and it says why" "yes" "no: $out" ;;
esac
kill "$INNOCENT" 2>/dev/null

# 2. The port's real owner is accepted.
echo "$HOLDER_PID" >"$PID_DIR/holder.pid"
out="$(wait_for_port "$PORT" "test API" 2 holder 2>&1)"
check "the process that actually holds the port is accepted" "0" "$?"

# NOTE: the descendant case (start_bg uses setsid, so the listener can be a child of the recorded
# pid) is handled by port_owner_verdict's pgid comparison but is not covered here -- constructing it
# reliably in a test needs a helper that forks and holds a socket, and a version of this that only
# *appeared* to cover it would be worse than the gap. Recorded rather than faked.

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

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
