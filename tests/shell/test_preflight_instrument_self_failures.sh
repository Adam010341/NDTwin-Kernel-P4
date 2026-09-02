#!/usr/bin/env bash
#
# Tests for L-10: two of 00_preflight.sh's nine live FAILs were the instrument failing itself.
#
# [Co-developed with claude code -- Adam]
#
# (a) The harness ran `ndt` with NDT_OWNER unset. `ndt status` renders the claim line RELATIVE to
#     that name (ndt:1145), so with it unset EVERY claim -- including the round's own -- prints as
#     a stranger's, and the §4.1/§4.2 gate reported "the lab is claimed by someone else: auditor"
#     about a lab auditor had correctly claimed for this round. Measured in one second, both ways:
#     raw/C29_preflight_triage.log (a): unset -> "claim auditor", NDT_OWNER=auditor -> "claim yours".
#     Two directions matter here and case 3 is the second one: OWNER-UNSET must not become a
#     blanket amnesty that also stops reporting a genuinely foreign claim.
#
# (b) `port_holder` took `head -1` of ss's users list. ss lists every process holding an fd for
#     the socket, not the one that called listen(), and the kernel forks helpers while its
#     listening fd is inheritable. Live, raw/C29 (d):
#       users:(("curl",pid=896662,fd=8),("curl",pid=896661,fd=8),("curl",pid=896660,fd=8),
#              ("ndtwin_kernel",pid=845333,fd=8))
#     The preflight reported ":8000 is held by pid 896662 (curl ...)". Case 5 uses that exact
#     captured line; case 6 proves the rule is "oldest holder", not "the one called ndtwin_kernel"
#     -- a check that recognises the answer by name would pass this fixture and nothing else.
#
# NOTHING HERE TOUCHES THE LAB: no ndt, no ndtwin-lab, no sudo, no fabric, no real `ss` except in
# case 8, which binds an ephemeral loopback port with python and kills its two pids by exact pid.
#
# Run:  bash tests/shell/test_preflight_instrument_self_failures.sh
# Env:  LIB_UNDER_TEST=<path>  test another copy of lib.sh (the mutation gate uses it)
#       PREFLIGHT_UNDER_TEST=<path>  ditto for 00_preflight.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND="$HERE/../../doc/audit/2026-08-30_live-full-stack-round"
LIB="${LIB_UNDER_TEST:-$ROUND/harness/lib.sh}"
PREFLIGHT="${PREFLIGHT_UNDER_TEST:-$ROUND/harness/00_preflight.sh}"

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_bad "$1" "expected: [$2]  actual: [$3]"; fi; }

T="$(mktemp -d /tmp/preflight-instr-XXXXXX)"
KILL_PIDS=()
cleanup() {
    local p
    for p in "${KILL_PIDS[@]+"${KILL_PIDS[@]}"}"; do kill "$p" 2>/dev/null || true; done
    [[ -n "${T:-}" && "$T" == /tmp/preflight-instr-* ]] && rm -rf "$T"
}
trap cleanup EXIT

export OUT="$T/out" RUN_TAG=test KERNEL_DIR="$HERE/../.."
unset NDT_OWNER
# shellcheck source=/dev/null
. "$LIB" || { echo "  FAILED   could not source $LIB"; echo "Ran 1 checks, 1 failed"; exit 1; }
set +e   # lib.sh turns on -Eeuo; the cases below deliberately evaluate failing conditions

declare -F claim_verdict    >/dev/null || { echo "  FAILED   $LIB does not define claim_verdict";    echo "Ran 1 checks, 1 failed"; exit 1; }
declare -F listen_owner_pid >/dev/null || { echo "  FAILED   $LIB does not define listen_owner_pid"; echo "Ran 1 checks, 1 failed"; exit 1; }

# =================================================================================================
echo "=== (a) NDT_OWNER: the harness must not read its own claim as a stranger's ==="

# The claim line exactly as `ndt status` printed it on 2026-09-02 at 21:45 (raw/C29 (a)).
FOREIGN_NAME_LINE='auditor -- 246m left (until 01:51:28)'
YOURS_LINE='yours -- 246m left (until 01:51:28)'

check "case 1  claim 'yours ...' with NDT_OWNER set    -> YOURS" \
      "YOURS" "$(claim_verdict "$YOURS_LINE" auditor)"
check "case 2  a NAME with NDT_OWNER UNSET is OWNER-UNSET, not FOREIGN (the L-10 defect)" \
      "OWNER-UNSET" "$(claim_verdict "$FOREIGN_NAME_LINE" "")"
check "case 3  a NAME with a DIFFERENT NDT_OWNER set is still FOREIGN (the check is not silenced)" \
      "FOREIGN" "$(claim_verdict "$FOREIGN_NAME_LINE" e-round-sampling-ceiling)"
check "case 4a 'none' -> UNCLAIMED"  "UNCLAIMED" "$(claim_verdict none "")"
check "case 4b 'EXPIRED 3m ago (was auditor) -- treated as free' -> EXPIRED" \
      "EXPIRED" "$(claim_verdict 'EXPIRED 3m ago (was auditor) -- treated as free' "")"

# The verdict must be WIRED IN. A five-valued function that 00_preflight.sh does not call, or
# calls while keeping its old catch-all, changes nothing about the FAIL that was observed.
wired="$(grep -c 'claim_verdict "\$CLAIM_LINE"' "$PREFLIGHT")"
branch="$(grep -c '^    OWNER-UNSET)' "$PREFLIGHT")"
old="$(grep -c 'the lab is claimed by someone else: \$CLAIM_LINE\. PREREG' "$PREFLIGHT")"
check "case 4c 00_preflight.sh calls claim_verdict, has an OWNER-UNSET branch, and dropped the old catch-all" \
      "1 1 0" "$wired $branch $old"

# NDT_OWNER has to REACH ndt, which means exported, not merely set. lib.sh is sourced in a fresh
# shell with it set-but-not-exported; `env` in that shell is the observation.
seen="$(env -u NDT_OWNER bash -c 'NDT_OWNER=probe-owner; . "$1" >/dev/null 2>&1; env | grep -c "^NDT_OWNER=probe-owner$"' _ "$LIB" 2>/dev/null)"
check "case 4d sourcing lib.sh EXPORTS a set-but-unexported NDT_OWNER so ndt can see it" "1" "$seen"

# =================================================================================================
echo "=== (b) :8000 -- the LISTEN owner, not whichever fd-holder ss happens to print first ==="

# The line exactly as captured on 2026-09-02 (raw/C29_preflight_triage.log (d)).
C29_LINE='LISTEN 0      4096   0.0.0.0:8000 0.0.0.0:* users:(("curl",pid=896662,fd=8),("curl",pid=896661,fd=8),("curl",pid=896660,fd=8),("ndtwin_kernel",pid=845333,fd=8))'

# 🔴 INJECTION CHECK FIRST. If the fixture does not actually contain several holders with the
# listener printed last, every assertion below would pass on the old code too and prove nothing.
n_holders="$(grep -oE 'pid=[0-9]+' <<<"$C29_LINE" | wc -l | tr -d ' ')"
first_holder="$(grep -oE 'pid=[0-9]+' <<<"$C29_LINE" | head -1 | cut -d= -f2)"
check "injection check: the captured line lists 4 holders and the FIRST one is the curl, not the kernel" \
      "4 896662" "$n_holders $first_holder"

# The start-time oracle. lib.sh reads /proc; these pids are long gone, so the seam is replaced by
# a fixture table. Every candidate must be looked up, so the calls are counted.
# 🔴 Keep the real one: redefining a function REPLACES it, and `unset -f` afterwards would leave
# case 8 running against no oracle at all -- which it does notice, but as a false red.
_REAL_STARTTIME="$(declare -f _proc_starttime)"
: > "$T/starttime_calls"
_proc_starttime() {
    printf '%s\n' "$1" >> "$T/starttime_calls"
    case "$1" in
        845333) printf '100' ;;    # the kernel: started first, so it is the listener
        896660) printf '900' ;;
        896661) printf '901' ;;
        896662) printf '902' ;;
        *)      printf '' ;;       # gone
    esac
}
got="$(listen_owner_pid "$C29_LINE")"
calls="$(sort -u "$T/starttime_calls" | wc -l | tr -d ' ')"
check "injection check: the start-time oracle was consulted for all four holders" "4" "$calls"
check "case 5  the LISTEN owner is the kernel, not the curl ss printed first" "845333" "$got"

# The rule is "oldest holder", not "the one whose comm looks like a server". Flip the ages and the
# answer must flip with them, or the previous case was passed by a name match.
_proc_starttime() {
    case "$1" in
        845333) printf '999' ;;
        896660) printf '100' ;;
        896661) printf '901' ;;
        896662) printf '902' ;;
        *)      printf '' ;;
    esac
}
check "case 6  with the ages reversed the answer follows the age, not the process name" \
      "896660" "$(listen_owner_pid "$C29_LINE")"

# Several holders, none of which still exists: the owner is genuinely unestablished, and the
# harness's third state says so rather than naming a dead pid.
_proc_starttime() { printf ''; }
check "case 7a several holders, all gone -> LISTENER-OWNER-HIDDEN (not a guess)" \
      "LISTENER-OWNER-HIDDEN" "$(listen_owner_pid "$C29_LINE")"
# A single holder keeps the pre-existing contract even when /proc cannot answer -- the case
# tests/shell/test_harness_instruments.sh group 1 pins with a synthetic pid.
check "case 7b one holder is unambiguous and is returned without consulting /proc" \
      "284117" "$(listen_owner_pid 'LISTEN 0 4096 0.0.0.0:9000 0.0.0.0:* users:(("kernel",pid=284117,fd=7))')"
eval "$_REAL_STARTTIME"          # back to reading /proc, for the live case below

# =================================================================================================
echo "=== (b') the same question against a REAL socket and a REAL inherited fd ==="
# A python process binds an ephemeral loopback port and forks; the child never listens, it only
# inherits the fd -- exactly the shape ss reported on :8000. Real ss, real /proc, no fabric.
cat > "$T/listener.py" <<'PY'
import os, socket, sys, time
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(8)
port = s.getsockname()[1]
child = os.fork()
if child == 0:
    time.sleep(25); os._exit(0)          # holds the INHERITED listening fd, listens to nothing
sys.stdout.write("%d %d %d\n" % (port, os.getpid(), child)); sys.stdout.flush()
time.sleep(25)
PY
python3 "$T/listener.py" > "$T/listener.out" 2>"$T/listener.err" &
for _ in $(seq 1 40); do [[ -s "$T/listener.out" ]] && break; sleep 0.25; done
read -r LPORT LPARENT LCHILD < "$T/listener.out" 2>/dev/null || true
KILL_PIDS=("${LPARENT:-}" "${LCHILD:-}")
if [[ -n "${LPORT:-}" && -n "${LPARENT:-}" && -n "${LCHILD:-}" ]]; then
    holders="$(ss -lptnH "sport = :$LPORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | wc -l | tr -d ' ')"
    check "injection check: the real socket really has TWO fd-holders (parent + forked child)" \
          "2" "$holders"
    check "case 8  port_holder names the process that called listen(), not the child that inherited it" \
          "$LPARENT" "$(port_holder "$LPORT")"
else
    t_bad "case 8  port_holder names the process that called listen()" \
          "the fixture listener never reported a port ($(head -c 200 "$T/listener.err" 2>/dev/null))"
fi

echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
