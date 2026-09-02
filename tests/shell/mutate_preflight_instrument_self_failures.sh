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
# 🔴 Guards its own baseline: every mutation is applied to a COPY of lib.sh or 00_preflight.sh in
# a temp dir; the harness's own files are never written. Other sessions read them.
#
# 🔑 The two appliers name their parameters `anchor`/`replacement` in a `local` line, and each
# bakes ONE file into its own body. That is the shape tests/shell/check_gate_anchors.py can read
# (ROLE_ANCHOR / the function's default file); a gate that tool cannot parse is a gate nobody is
# checking, which is the defect L-3 is about -- so a new gate must not add a sixth. Neither is
# named `mutate`, because that name is special-cased there to mean "argument 1 is the anchor",
# and these take the mutant's name first.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LIB="$REPO/doc/audit/2026-08-30_live-full-stack-round/harness/lib.sh"
PRE="$REPO/doc/audit/2026-08-30_live-full-stack-round/harness/00_preflight.sh"
TEST="$HERE/test_preflight_instrument_self_failures.sh"
BK="$(mktemp -d /tmp/preflight-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$LIB" "$PRE" | cut -d' ' -f1 | tr '\n' ' ')"

SURVIVORS=0
# An empty argument means "use the shipped file": only one of the two is mutated at a time, and
# passing "$LIB"/"$PRE" at the report call sites would make check_gate_anchors.py read `report`
# itself as a mutation applier (file = the path argument, anchor = the case string).
run_against() { LIB_UNDER_TEST="${1:-$LIB}" PREFLIGHT_UNDER_TEST="${2:-$PRE}" bash "$TEST" 2>&1; }
report() {   # $1 = label, $2 = mutated lib or "", $3 = mutated preflight or "", $4 = case that must go red
    local label="$1" libcopy="$2" precopy="$3" wanted="$4"
    local out rc
    out="$(run_against "$libcopy" "$precopy")"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $wanted" <<<"$out"; then
        printf '  caught   %-52s (%s went red)\n' "$label" "$wanted"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-52s (%s stayed green -- that case proves nothing)\n' "$label" "$wanted"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}
_apply() {       # $1 = the copy to edit, $2 = exact old text, $3 = new text
    python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor is not unique (%d hits): %r" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PYEOF
}
mutate_lib() {   # $1 = mutant name, $2 = anchor (exact text), $3 = replacement -- inside lib.sh
    local name="$1" anchor="$2" replacement="$3"
    local out="$BK/lib.$name.sh"
    cp "$LIB" "$out"
    _apply "$out" "$anchor" "$replacement"
    echo "$out"
}
mutate_pre() {   # $1 = mutant name, $2 = anchor (exact text), $3 = replacement -- in 00_preflight.sh
    local name="$1" anchor="$2" replacement="$3"
    local out="$BK/pre.$name.sh"
    cp "$PRE" "$out"
    _apply "$out" "$anchor" "$replacement"
    echo "$out"
}

echo "baseline (must be green before any mutation):"
run_against "" "" | tail -1
run_against "" "" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

m1=$(mutate_lib m1 '*)        if [[ -n "$owner" ]]; then printf '"'"'FOREIGN'"'"'; else printf '"'"'OWNER-UNSET'"'"'; fi ;;' \
                   '*)        printf '"'"'FOREIGN'"'"' ;;')
report "M1: a name with no NDT_OWNER is FOREIGN again" "$m1" "" \
  "case 2  a NAME with NDT_OWNER UNSET is OWNER-UNSET, not FOREIGN (the L-10 defect)"

m2=$(mutate_lib m2 '*)        if [[ -n "$owner" ]]; then printf '"'"'FOREIGN'"'"'; else printf '"'"'OWNER-UNSET'"'"'; fi ;;' \
                   '*)        printf '"'"'OWNER-UNSET'"'"' ;;')
report "M2: everything is OWNER-UNSET (the amnesty)" "$m2" "" \
  "case 3  a NAME with a DIFFERENT NDT_OWNER set is still FOREIGN (the check is not silenced)"

m3=$(mutate_lib m3 'if [[ -n "${NDT_OWNER:-}" ]]; then export NDT_OWNER; fi' \
                   ':  # deliberately not exported')
report "M3: lib.sh does not export NDT_OWNER" "$m3" "" \
  "case 4d sourcing lib.sh EXPORTS a set-but-unexported NDT_OWNER so ndt can see it"

m4=$(mutate_pre m4 '    OWNER-UNSET) bad "THIS HARNESS' \
                   '    NEVER-MATCHES) bad "THIS HARNESS')
report "M4: 00_preflight.sh loses its OWNER-UNSET branch" "" "$m4" \
  "case 4c 00_preflight.sh calls claim_verdict, has an OWNER-UNSET branch, and dropped the old catch-all"

m5=$(mutate_lib m5 '    (( ${#pids[@]} == 1 )) && { printf '"'"'%s'"'"' "${pids[0]}"; return 0; }' \
                   '    printf '"'"'%s'"'"' "${pids[0]}"; return 0')
report "M5: listen_owner_pid takes head -1 (the original defect)" "$m5" "" \
  "case 5  the LISTEN owner is the kernel, not the curl ss printed first"

m6=$(mutate_lib m6 '(( t < best_t ))' '(( t > best_t ))')
report "M6: listen_owner_pid takes the NEWEST holder" "$m6" "" \
  "case 6  with the ages reversed the answer follows the age, not the process name"

m7=$(mutate_lib m7 '[[ -n "$best" ]] || { printf '"'"'%s'"'"' "$PORT_HOLDER_HIDDEN"; return 0; }' \
                   '[[ -n "$best" ]] || { printf '"'"'%s'"'"' "${pids[0]}"; return 0; }')
report "M7: all holders gone -> name the first one instead of HIDDEN" "$m7" "" \
  "case 7a several holders, all gone -> LISTENER-OWNER-HIDDEN (not a guess)"

echo
[[ "$(sha256sum "$LIB" "$PRE" | cut -d' ' -f1 | tr '\n' ' ')" == "$BASE_SHA" ]] \
    && echo "baseline byte-identical: yes" \
    || { echo "🔴 baseline CHANGED -- a harness file was written during the gate"; exit 3; }
if [[ "$SURVIVORS" -eq 0 ]]; then echo "mutation gate: 7 mutations, 0 survived"; exit 0
else echo "mutation gate: $SURVIVORS survived"; exit 1; fi
