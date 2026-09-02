#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_iperf3_guard.sh (KNOWN-ISSUES G-inst-2, the guard half).
#
# [Co-developed with claude code -- Adam]
#
# M1 restores the original defect verbatim -- the awk whose own argv carries `iperf3`, which
# `pkill -f iperf3` then kills, leaving $pids empty and the guard returning "clean". M2 removes
# the empty-process-list refusal, the same fail-open with a different cause. M3 makes the comm
# comparison a prefix match, the FABRIC_PREFIXES shape, so `iperf3d` would trip it. M4 pins the
# pid list empty after a correct read, so a real foreign iperf3 is passed over. M5 lets a blank
# line count as a process, which turns "could not look" back into "looked and found nothing".
# M6 rewrites the enumeration as `pgrep -f iperf3`, to show that case 1 measures the property
# (nothing the guard spawns carries the pattern) and not the spelling of the line it replaced.
#
# Each mutation must turn its NAMED case red. A compile-or-load failure, a moved anchor, or the
# wrong case going red is a SURVIVOR, not a kill: in each of those the case it targets was never
# put to the test.
#
# 🔴 Guards its own baseline: every mutation is applied to a COPY of lib_e.sh in a temp dir and
# the test is pointed at the copy with LIB_E_UNDER_TEST. The E round's own lib_e.sh is never
# written -- it belongs to a pre-registered round, in a worktree several sessions share, and
# another session may be sourcing it right now. Byte-identity is asserted at the end anyway.
#
# No process is ever killed: the hazard is reproduced by RECORDING argv, never by pkill.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LIB="$REPO/doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh"
TEST="$HERE/test_iperf3_guard.sh"
BK=$(mktemp -d /tmp/iperf3-guard-mutate-XXXXXX)
trap 'rm -rf "$BK"' EXIT
BASE_SHA=$(sha256sum "$LIB" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0
run_against() { LIB_E_UNDER_TEST="$1" bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutated copy, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $3" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}

mutant() {   # $1 = name, $2 = anchor \x1f replacement; prints the path to the mutated copy
    local out="$BK/lib_e.$1.sh"; cp "$LIB" "$out"
    python3 - "$out" "$2" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
old, new = spec.split("\x1f")
s = open(p).read()
assert s.count(old) == 1, "anchor is not unique (%d matches): %s" % (s.count(old), old[:70])
open(p, "w").write(s.replace(old, new))
PY
    echo "$out"
}

echo "baseline (must be green before any mutation):"
run_against "$LIB" | tail -1
if ! run_against "$LIB" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi

OLD_LOOP='    local _pid _comm _seen=0
    pids=""
    while read -r _pid _comm; do
        [[ -n "$_pid" ]] || continue     # a blank line is not a process, and must not count as one
        _seen=$((_seen + 1))
        [[ "$_comm" == iperf3 ]] && pids+="$_pid "
    done < <(ps -eo pid=,comm=)'

m1=$(mutant m1 "$OLD_LOOP"$'\x1f''    local _seen=1
    pids=$(ps -eo pid=,comm= | awk '"'"'$2=="iperf3"{printf "%s ", $1}'"'"')')
report "M1: the original awk, whose argv carries the pattern" "$m1" \
       "case 1  no process the guard spawns carries 'iperf3' in its own argv"

m2=$(mutant m2 '    if [[ "$_seen" -eq 0 ]]; then'$'\x1f''    if false; then')
report "M2: an unreadable process list is read as 'clean'" "$m2" \
       "case 4  an empty process list is REFUSED, not read as 'clean'"

m3=$(mutant m3 '[[ "$_comm" == iperf3 ]] && pids'$'\x1f''[[ "$_comm" == iperf3* ]] && pids')
report "M3: prefix match instead of exact comm (the FABRIC_PREFIXES shape)" "$m3" \
       "case 3  look-alike comms (iperf, iperf3d, xiperf3, iperf3.sh) do NOT trip the guard"

m4=$(mutant m4 '    if [[ -n "${pids// /}" ]]; then'$'\x1f''    pids=""
    if [[ -n "${pids// /}" ]]; then')
report "M4: a real foreign iperf3 is passed over" "$m4" \
       "case 2  a foreign iperf3 in the process list is REFUSED"

m5=$(mutant m5 '        [[ -n "$_pid" ]] || continue     # a blank line is not a process, and must not count as one
'$'\x1f''')
report "M5: a blank line counts as a process" "$m5" \
       "case 4c a process table of one blank line is REFUSED (a blank line is not a process)"

m6=$(mutant m6 "$OLD_LOOP"$'\x1f''    local _seen=1
    pids=$(pgrep -f iperf3 | tr '"'"'\n'"'"' '"'"' '"'"')')
report "M6: the same hazard respelled as pgrep -f" "$m6" \
       "case 1  no process the guard spawns carries 'iperf3' in its own argv"

echo
if [[ "$(sha256sum "$LIB" | cut -d' ' -f1)" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes (lib_e.sh was never written)"
else
    echo "🔴 baseline CHANGED -- lib_e.sh was written during the gate"
    exit 3
fi
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
