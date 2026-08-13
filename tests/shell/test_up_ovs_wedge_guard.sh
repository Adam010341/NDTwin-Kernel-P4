#!/usr/bin/env bash
#
# Tests for cmd_up's ovs wedge guard.
#
# [Co-developed with claude code -- Adam]
#
# Starting Ryu while a Mininet is already alive is the /stats/flow wedge trigger (empty replies
# forever, ~1.011 s each -- ofctl's DEFAULT_TIMEOUT; root cause unproven, no recovery short of
# recreating the network). doc/2026-08-10_ovs_manual_test_runbook.md's rule is "never restart Ryu alone",
# and the 2026-08-13 overnight round showed how easily it happens anyway: the OVS teardown left
# Mininet running for the morning, and the documented way to bring the stack back was exactly
# `stack.sh up ovs`. The guard refuses that combination unless --force.
#
# These tests drive the real cmd_up out of stack.sh with the process-count seam overridden.
# Nothing is ever started: every path that survives the guard is cut short at a
# missing-binary check before the first start_bg.

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

# Nothing may actually start: cut every surviving path at its first binary check.
RYU_MANAGER=/nonexistent/ryu-manager-for-this-test
P4_PROXY_PY=/nonexistent/p4-proxy-interpreter-for-this-test

echo "live Mininet + 'up ovs' -> refused before touching Ryu"
count_mininet_procs() { echo 139; }
out="$(cmd_up ovs </dev/null 2>&1)"; rc=$?
check "returns 1" 1 "$rc"
check "says why" yes "$(grep -q "refusing 'up ovs'" <<<"$out" && echo yes || echo no)"
check "names the wedge" yes "$(grep -q "wedge" <<<"$out" && echo yes || echo no)"
check "never reaches the Ryu step" no "$(grep -q "control plane (Ryu)" <<<"$out" && echo yes || echo no)"

echo "no Mininet + 'up ovs' -> guard passes (dies later at the missing ryu-manager, by design)"
count_mininet_procs() { echo 0; }
out="$(cmd_up ovs </dev/null 2>&1)"; rc=$?
check "guard silent" no "$(grep -q "refusing" <<<"$out" && echo yes || echo no)"
check "reached the Ryu step" yes "$(grep -q "ryu-manager not found" <<<"$out" && echo yes || echo no)"

echo "live Mininet + 'up ovs --force' -> guard bypassed on explicit request"
count_mininet_procs() { echo 139; }
out="$(cmd_up ovs --force </dev/null 2>&1)"; rc=$?
check "guard silent" no "$(grep -q "refusing" <<<"$out" && echo yes || echo no)"
check "reached the Ryu step" yes "$(grep -q "ryu-manager not found" <<<"$out" && echo yes || echo no)"

echo "live Mininet + 'up p4' -> the guard is ovs-only (P4 restarts under live Mininet are routine)"
count_mininet_procs() { echo 139; }
out="$(cmd_up p4 </dev/null 2>&1)"; rc=$?
check "guard silent" no "$(grep -q "refusing" <<<"$out" && echo yes || echo no)"
check "reached the proxy step" yes "$(grep -q "P4 proxy interpreter not found" <<<"$out" && echo yes || echo no)"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
