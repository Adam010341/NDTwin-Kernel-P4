#!/usr/bin/env bash
#
# Tests for tools/test_workflow/ports.sh -- the one table of ports that block a bring-up.
#
# [Co-developed with claude code -- Adam]
#
# The defect this replaces: `cmd_clean` and `deep_sweep` each looped over `8000 8080 8081`,
# which is the set of ports that are easy to name rather than the set that blocks the next
# bring-up. On 2026-09-02 a kernel nobody had started held UDP :6343, a legitimate bring-up
# died with `bind() to sFlow port 6343 failed`, and every one of `ndt down`'s assertions came
# back green. Two separate reasons, and a test has to close both:
#
#   1. :6343 was in none of the checks.
#   2. `port_open` speaks only TCP, so it could not have seen :6343 even if it had looked.
#
# 🔴 Discrimination is deliberately NOT demonstrated on :8000/:8080/:8081. Proving the tool
# still catches :8081 proves nothing here -- :8081 is one of the three the broken version
# already covered, and "we validated it by holding :8081" is precisely how this defect stayed
# hidden. Every mechanism case below holds a port outside those three, and the UDP case holds
# one a TCP-only probe cannot see at all.
#
# No lab contact: the mechanism cases bind ports in the 459xx range (the same range
# test_wait_for_port.sh already uses) and inject them through NDT_PORT_TABLE, and the cmd_clean
# wiring case stubs every lab predicate. Nothing here touches the fabric, a claim, or :6343
# itself -- another session may be measuring.
#
# Run:  bash tests/shell/test_ports_that_block_restart.sh
# Env:  PORTS_UNDER_TEST=<path>  NDT_UNDER_TEST=<path>   (the mutation gate uses both)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTS="${PORTS_UNDER_TEST:-$HERE/../../tools/test_workflow/ports.sh}"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n    %s\n' "$1" "$2"; }
check() { # <name> <expected> <actual>
    [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: $2 / actual: $3"
}

# shellcheck source=/dev/null
source "$PORTS" || { echo "  FAILED   could not source $PORTS"; echo "Ran 1 checks, 1 failed"; exit 1; }

HOLDERS=()
cleanup() { local p; for p in "${HOLDERS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

echo "the table itself"

# --- 1. the rows the four comments used to hold, now data ----------------------------------
# Each of these was written down somewhere and executed nowhere. A row missing here is that
# state restored, so each gets its own case rather than one "the table is big enough".
rows="$(ndt_port_rows all)"

grep -qE '^6343\|udp\|' <<<"$rows" \
    && t_ok "6343 is in the table AND declared udp (the 09-02 incident)" \
    || t_bad "6343 is in the table AND declared udp (the 09-02 incident)" "no 6343|udp| row"

grep -qE '^30051-30060\|' <<<"$rows" \
    && t_ok "the bmv2 gRPC block is a row (ndt:635 said :3005x in a comment)" \
    || t_bad "the bmv2 gRPC block is a row (ndt:635 said :3005x in a comment)" "no 30051-30060 row"

if grep -qE '^6653\|' <<<"$rows" && grep -qE '^6633\|' <<<"$rows"; then
    t_ok "BOTH 6653 and 6633 are rows (the probe order reaches both)"
else
    t_bad "BOTH 6653 and 6633 are rows (the probe order reaches both)" "$(grep -cE '^66[35]3\|' <<<"$rows") of 2"
fi

grep -qE '^9000\|' <<<"$rows" \
    && t_ok "sim's :9000 is a row" || t_bad "sim's :9000 is a row" "no 9000 row"

# Every row must carry an owner and a consequence -- the two columns the old checks lacked and
# the reason a residue line can say more than a count.
bad_rows=0
while IFS='|' read -r spec proto plane owner consequence; do
    [[ -z "$spec" ]] && continue
    [[ -n "$owner" && -n "$consequence" && "$proto" =~ ^(tcp|udp)$ ]] || bad_rows=$((bad_rows+1))
done <<<"$rows"
check "every row declares proto, owner and consequence" "0" "$bad_rows"

# --- 2. ranges are ports, not strings ------------------------------------------------------
exp="$(ndt_port_expand 30051-30060 | tr '\n' ' ')"
check "30051-30060 expands to all ten device ports" \
      "30051 30052 30053 30054 30055 30056 30057 30058 30059 30060 " "$exp"

echo "residue on a port that is NOT one of the original three"

# --- 3. TCP mechanism, on :45901 -----------------------------------------------------------
TCP_PORT=45901
python3 -c "
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $TCP_PORT)); s.listen(5); time.sleep(120)
" & HOLDERS+=($!)
for _ in $(seq 1 40); do ndt_port_open "$TCP_PORT" tcp && break; sleep 0.25; done

# 🔴 Assert the INJECTION took effect before asserting the tool's response to it. A tool that
# reports nothing against a port nobody is holding is not evidence of anything.
if ndt_port_open "$TCP_PORT" tcp; then
    t_ok "injection took effect: something really is holding :$TCP_PORT"

    NDT_PORT_TABLE="$TCP_PORT|tcp|both|the fixture holder|THE-CONSEQUENCE-STRING"
    out="$(ndt_port_residue all)"; rc=$?
    check "a held port outside 8000/8080/8081 makes residue return 1" "1" "$rc"
    grep -q "holding :$TCP_PORT" <<<"$out" \
        && t_ok "the residue line names the port" || t_bad "the residue line names the port" "$out"
    grep -qE 'pid [0-9]+' <<<"$out" \
        && t_ok "the residue line names the HOLDER by pid, not a count" \
        || t_bad "the residue line names the HOLDER by pid, not a count" "$out"
    grep -q 'THE-CONSEQUENCE-STRING' <<<"$out" \
        && t_ok "the residue line states the consequence from the row" \
        || t_bad "the residue line states the consequence from the row" "$out"

    # Zero-discrimination guard: the same table with nothing held must stay silent, or the
    # three checks above would pass against a function that prints unconditionally.
    NDT_PORT_TABLE="45999|tcp|both|nobody|NOT-EXPECTED"
    out="$(ndt_port_residue all)"; rc=$?
    check "a free port produces no residue and returns 0" "0" "$rc"
    check "and prints nothing" "" "$out"
else
    t_bad "injection took effect: something really is holding :$TCP_PORT" "could not bind the fixture"
fi

echo "the proto column: a UDP holder a TCP probe cannot see"

# --- 4. UDP mechanism, on :45902 -----------------------------------------------------------
# This is the shape of the 09-02 failure without touching :6343: the holder is real, and the
# probe every caller had before this change would have called the port closed.
UDP_PORT=45902
python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $UDP_PORT)); time.sleep(120)
" & HOLDERS+=($!)
for _ in $(seq 1 40); do ndt_port_open "$UDP_PORT" udp && break; sleep 0.25; done

if ndt_port_open "$UDP_PORT" udp; then
    t_ok "injection took effect: something really is holding udp :$UDP_PORT"

    # The discrimination that matters: the old TCP-only probe says closed for the same port.
    if ndt_port_open "$UDP_PORT" tcp; then
        t_bad "the same port probed as tcp reads closed (a TCP-only check would miss it)" "tcp said open"
    else
        t_ok "the same port probed as tcp reads closed (a TCP-only check would miss it)"
    fi

    NDT_PORT_TABLE="$UDP_PORT|udp|both|the udp fixture holder|UDP-CONSEQUENCE-STRING"
    out="$(ndt_port_residue all)"; rc=$?
    check "a held UDP port makes residue return 1" "1" "$rc"
    grep -q 'UDP-CONSEQUENCE-STRING' <<<"$out" \
        && t_ok "the UDP residue line states its consequence" \
        || t_bad "the UDP residue line states its consequence" "$out"
else
    t_bad "injection took effect: something really is holding udp :$UDP_PORT" "could not bind the fixture"
fi

echo "cmd_clean reads the table"

# --- 5. wiring ------------------------------------------------------------------------------
# Hermetic: every lab predicate is stubbed, so this asserts only that cmd_clean's port section
# comes from ndt_port_residue. Without it, cmd_clean could keep its own copy of the list and
# every case above would still pass.
wiring="$(
    # shellcheck source=/dev/null
    source "$NDT" >/dev/null 2>&1
    bmv2_count() { echo 0; }
    mn_count()   { echo 0; }
    topo_session() { return 1; }
    MANIFEST="/nonexistent/ndt-test-manifest-$$"
    ndt_port_residue() { echo "SENTINEL-FROM-THE-TABLE"; return 1; }
    ndt_port_label()   { echo "SENTINEL-LABEL"; }
    cmd_clean 2>&1
)"
grep -q 'SENTINEL-FROM-THE-TABLE' <<<"$wiring" \
    && t_ok "cmd_clean's port residue comes from the shared table function" \
    || t_bad "cmd_clean's port residue comes from the shared table function" "$wiring"

echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
