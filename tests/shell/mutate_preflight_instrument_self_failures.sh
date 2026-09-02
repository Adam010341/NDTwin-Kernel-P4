#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_preflight_instrument_self_failures.sh (L-10).
#
# [Co-developed with claude code -- Adam]
#
# Both defects here were instruments answering a question they could not reach, so both
# directions are gated: M1 restores the original wrong answer and M2 restores it as a blanket
# amnesty, which is the shape a careless fix takes -- stop reporting the FAIL and call it fixed.
#
#   M1  claim_verdict: a name with no NDT_OWNER is FOREIGN again    -> case 2
#   M2  claim_verdict: everything is OWNER-UNSET (the amnesty)      -> case 3
#   M3  lib.sh does not export NDT_OWNER                            -> case 4d
#   M4  00_preflight.sh loses its OWNER-UNSET branch                -> case 4c
#   M5  listen_owner_pid takes head -1 (the original defect)        -> case 5
#   M6  listen_owner_pid takes the NEWEST holder                    -> case 6
#   M7  all holders gone -> name the first one instead of HIDDEN    -> case 7a
#
# 🔴 Guards its own baseline: every mutation is applied to COPIES of lib.sh and 00_preflight.sh
# in a temp dir; the harness's own files are never written. Other sessions read them.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HARNESS="$REPO/doc/audit/2026-08-30_live-full-stack-round/harness"
LIB="$HARNESS/lib.sh"
PRE="$HARNESS/00_preflight.sh"
TEST="$HERE/test_preflight_instrument_self_failures.sh"
BK="$(mktemp -d /tmp/preflight-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$LIB" "$PRE" | cut -d' ' -f1 | tr '\n' ' ')"

SURVIVORS=0
run_against() { LIB_UNDER_TEST="$1" PREFLIGHT_UNDER_TEST="$2" bash "$TEST" 2>&1; }
report() {   # $1 = name, $2 = lib copy, $3 = preflight copy, $4 = case that must go red
    local out rc
    out="$(run_against "$2" "$3")"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $4" <<<"$out"; then
        printf '  caught   %-52s (%s went red)\n' "$1" "$4"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-52s (%s stayed green -- that case proves nothing)\n' "$1" "$4"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}
# mutate <name> <which: lib|pre> <old> <new>; prints "<lib copy> <preflight copy>"
mutate() {
    local name="$1" which="$2" old="$3" new="$4"
    local l="$BK/lib.$name.sh" p="$BK/pre.$name.sh"
    cp "$LIB" "$l"; cp "$PRE" "$p"
    local target="$l"; [[ "$which" == pre ]] && target="$p"
    python3 - "$target" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor is not unique (%d hits): %r" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    printf '%s %s' "$l" "$p"
}

echo "baseline (must be green before any mutation):"
run_against "$LIB" "$PRE" | tail -1
run_against "$LIB" "$PRE" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# shellcheck disable=SC2046  # the helper prints two paths and both are wanted as separate args
report "M1: a name with no NDT_OWNER is FOREIGN again" \
  $(mutate m1 lib '*)        if [[ -n "$owner" ]]; then printf '"'"'FOREIGN'"'"'; else printf '"'"'OWNER-UNSET'"'"'; fi ;;' \
                  '*)        printf '"'"'FOREIGN'"'"' ;;') \
  "case 2  a NAME with NDT_OWNER UNSET is OWNER-UNSET, not FOREIGN (the L-10 defect)"

# shellcheck disable=SC2046
report "M2: everything is OWNER-UNSET (the amnesty)" \
  $(mutate m2 lib '*)        if [[ -n "$owner" ]]; then printf '"'"'FOREIGN'"'"'; else printf '"'"'OWNER-UNSET'"'"'; fi ;;' \
                  '*)        printf '"'"'OWNER-UNSET'"'"' ;;') \
  "case 3  a NAME with a DIFFERENT NDT_OWNER set is still FOREIGN (the check is not silenced)"

# shellcheck disable=SC2046
report "M3: lib.sh does not export NDT_OWNER" \
  $(mutate m3 lib 'if [[ -n "${NDT_OWNER:-}" ]]; then export NDT_OWNER; fi' ':  # not exported') \
  "case 4d sourcing lib.sh EXPORTS a set-but-unexported NDT_OWNER so ndt can see it"

# shellcheck disable=SC2046
report "M4: 00_preflight.sh loses its OWNER-UNSET branch" \
  $(mutate m4 pre '    OWNER-UNSET) bad "THIS HARNESS' '    NEVER-MATCHES) bad "THIS HARNESS') \
  "case 4c 00_preflight.sh calls claim_verdict, has an OWNER-UNSET branch, and dropped the old catch-all"

# shellcheck disable=SC2046
report "M5: listen_owner_pid takes head -1 (the original defect)" \
  $(mutate m5 lib '    (( ${#pids[@]} == 1 )) && { printf '"'"'%s'"'"' "${pids[0]}"; return 0; }' \
                  '    printf '"'"'%s'"'"' "${pids[0]}"; return 0') \
  "case 5  the LISTEN owner is the kernel, not the curl ss printed first"

# shellcheck disable=SC2046
report "M6: listen_owner_pid takes the NEWEST holder" \
  $(mutate m6 lib '(( t < best_t ))' '(( t > best_t ))') \
  "case 6  with the ages reversed the answer follows the age, not the process name"

# shellcheck disable=SC2046
report "M7: all holders gone -> name the first one instead of HIDDEN" \
  $(mutate m7 lib '[[ -n "$best" ]] || { printf '"'"'%s'"'"' "$PORT_HOLDER_HIDDEN"; return 0; }' \
                  '[[ -n "$best" ]] || { printf '"'"'%s'"'"' "${pids[0]}"; return 0; }') \
  "case 7a several holders, all gone -> LISTENER-OWNER-HIDDEN (not a guess)"

echo
[[ "$(sha256sum "$LIB" "$PRE" | cut -d' ' -f1 | tr '\n' ' ')" == "$BASE_SHA" ]] \
    && echo "baseline byte-identical: yes" \
    || { echo "🔴 baseline CHANGED -- a harness file was written during the gate"; exit 3; }
if [[ "$SURVIVORS" -eq 0 ]]; then echo "mutation gate: 7 mutations, 0 survived"; exit 0
else echo "mutation gate: $SURVIVORS survived"; exit 1; fi
