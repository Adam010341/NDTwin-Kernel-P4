#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_e_restore_asserts_compiled_artifact.sh (G-5).
#
# [Co-developed with claude code -- Adam]
#
# The disease this gate exists for is "the check passes either way", so it is not enough to show
# the cases go red when the fix is removed: M3 removes the fix in the OTHER direction (assert
# unconditionally) and case 1 must go red for that too.  A restore assertion that is always red
# is as worthless as one that is always green, and both would have looked like a fix.
#
#   M1  the original defect: the rng assertion never fires        -> case 2 (an arm left at 1/8)
#   M2  read only the upper bound, as `ndt status` used to        -> case 3 (lo=1, samples nothing)
#   M3  assert unconditionally (always red)                       -> case 1 (production accepted)
#   M4  compiled_rng lies: always reports production bounds       -> case 2
#   M5  the old order: copy the kernel binary before teardown     -> case 4
#   M6  drop the rc read on the copy                              -> case 5b
#
# 🔴 Guards its own baseline: mutations are applied to a COPY of lib_e.sh in a temp dir and the
# test is pointed at the copy with LIB_E_UNDER_TEST.  The round's own lib_e.sh is never written --
# the E round's scripts source it and another session may be reading it right now.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LIB="$REPO/doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh"
TEST="$HERE/test_e_restore_asserts_compiled_artifact.sh"
BK="$(mktemp -d /tmp/e-restore-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$LIB" | cut -d' ' -f1)"

SURVIVORS=0
run_against() { LIB_E_UNDER_TEST="$1" bash "$TEST" 2>&1; }
report() {   # $1 = mutation name, $2 = mutated copy, $3 = case that must go red
    local out rc
    out="$(run_against "$2")"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $3" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}
mutant() {   # $1 = name, $2.. = alternating old/new text; prints the path to the mutated copy
    local out="$BK/lib_e.$1.sh"; cp "$LIB" "$out"; shift
    python3 - "$out" "$@" <<'PY'
import sys
p, pairs = sys.argv[1], sys.argv[2:]
s = open(p).read()
for a, b in zip(pairs[0::2], pairs[1::2]):
    assert s.count(a) == 1, "anchor is not unique (%d hits): %r" % (s.count(a), a[:70])
    s = s.replace(a, b)
open(p, "w").write(s)
PY
    echo "$out"
}

echo "baseline (must be green before any mutation):"
run_against "$LIB" | tail -1
run_against "$LIB" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

m1=$(mutant m1 'if [[ "$rng" != "0 255" ]]; then' 'if [[ "$rng" == "NEVER-MATCHES" ]]; then')
report "M1: the rng assertion never fires (the original defect)" "$m1" \
       "case 2  compiled artefact still at 1/8 while the source reads 256 is REJECTED"

m2=$(mutant m2 'if [[ "$rng" != "0 255" ]]; then' 'if [[ "${rng#* }" != "255" ]]; then')
report "M2: only the upper bound is read" "$m2" \
       "case 3  compiled artefact that samples nothing (rng 1..255) is REJECTED"

m3=$(mutant m3 'if [[ "$rng" != "0 255" ]]; then' 'if true; then')
report "M3: assert unconditionally -- always red" "$m3" \
       "case 1  production compiled artefact (rng 0..255) is accepted"

m4=$(mutant m4 'print("%d %d" % (int(b[0], 16), int(b[1], 16)) if b and len(b) == 2 else "UNREADABLE")' \
                'print("0 255")')
report "M4: compiled_rng always reports production bounds" "$m4" \
       "case 2  compiled artefact still at 1/8 while the source reads 256 is REJECTED"

m5=$(mutant m5 '    teardown
    if [[ -f "$KBIN_BACKUP" ]]; then' '    if [[ -f "$KBIN_BACKUP" ]]; then' \
               '    fi
    compile_at 256' '    fi
    teardown
    compile_at 256')
report "M5: the old order -- copy the binary while the stack is up" "$m5" \
       "case 4  restore_production tears the stack down BEFORE copying the kernel binary"

m6=$(mutant m6 'if RUN cp -f "$KBIN_BACKUP" "$KBIN"; then' \
                'RUN cp -f "$KBIN_BACKUP" "$KBIN"; if true; then')
report "M6: the exit code of the copy is not read" "$m6" \
       "case 5b a kernel copy that FAILS is reported and makes restore_production non-zero"

echo
[[ "$(sha256sum "$LIB" | cut -d' ' -f1)" == "$BASE_SHA" ]] \
    && echo "baseline byte-identical: yes" \
    || { echo "🔴 baseline CHANGED -- lib_e.sh was written during the gate"; exit 3; }
if [[ "$SURVIVORS" -eq 0 ]]; then echo "mutation gate: 6 mutations, 0 survived"; exit 0
else echo "mutation gate: $SURVIVORS survived"; exit 1; fi
