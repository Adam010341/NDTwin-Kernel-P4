#!/usr/bin/env bash
#
# Tests for G-5's two sub-defects in the E round's restore path
# (doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh).
#
# [Co-developed with claude code -- Adam]
#
# (a) assert_restore_landed() asserted SAMPLE_RATE only in the .p4 SOURCE.  Its one check on the
#     COMPILED artefact was `"op":"truncate"` exists -- and the truncate op is present in every
#     build p4c has ever produced here: at 1/8, at 1/256, and with sampling switched off.  So the
#     line "source and compiled JSON agree" was printed by a check that could not disagree.  bmv2
#     loads the JSON at exec and never reloads, so the artefact is the only thing that describes
#     the fabric the NEXT round measures on.  The axis is the rng primitive's two bounds:
#         0 255 = production 1/256      0 7 = an arm left at 1/8      1 255 = samples NOTHING
#     Cases 1-3 are the load-bearing ones and they are stated in BOTH directions on purpose: a
#     restore assertion that is merely "now red" is as useless as one that is always green.
#
# (b) restore_production() ran `cp -f` over the kernel binary BEFORE `teardown`, with the copy's
#     exit code unread.  Both halves are the same shape -- an action reported as done without
#     evidence that it landed.  `cp -f` onto a running binary hits ETXTBSY and papers over it by
#     unlinking the destination, so the FILE becomes correct while the PROCESS goes on executing
#     the arm from the unlinked inode; the old order came out right only because `teardown` on
#     the next line happened to kill it.  Case 4 pins the order, case 5 pins the rc read.
#
# 🔴 Case 5 is deliberately built so that the rc read is the ONLY thing that can catch the
#    failure: the fixture's $KBIN already equals $KBIN_BACKUP, so the sha comparison inside
#    assert_restore_landed is green whether the copy ran or not.  A test whose subject is also
#    caught by a second check downstream does not prove the subject works.
#
# No fabric, no lab claim, no p4c, no kernel: every path exercised here reads fixture files and
# stubbed functions.  The .p4/.json fixtures are checked against an INDEPENDENT decoder (python3
# in this file) before use, so a fixture that failed to encode the case cannot produce a green.
#
# Run:  bash tests/shell/test_e_restore_asserts_compiled_artifact.sh
# Env:  LIB_E_UNDER_TEST=<path>   test another copy of lib_e.sh (the mutation gate uses it)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND_DIR="$HERE/../../doc/audit/2026-08-31_sampling-ceiling-after-merge"
LIB="${LIB_E_UNDER_TEST:-$ROUND_DIR/lib_e.sh}"

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_bad "$1" "expected: [$2]  actual: [$3]"; fi; }

T="$(mktemp -d /tmp/e-restore-XXXXXX)"
cleanup() { [[ -n "${T:-}" && "$T" == /tmp/e-restore-* ]] && rm -rf "$T"; }
trap cleanup EXIT

# --- fixtures ---------------------------------------------------------------------------------
mkdir -p "$T/p4build" "$T/out" "$T/bin"
export ROUND="$ROUND_DIR" DRY_RUN=0 DRY_FAIL=
export P4SRC="$T/ndtwin_switch.p4" P4BUILD="$T/p4build" OUT="$T/out"
export KBIN="$T/bin/ndtwin_kernel" KBIN_BACKUP="$T/bin/ndtwin_kernel.production-backup"
export PY_PROXY="${PY_PROXY:-python3}"
LOG_BASE="$T/test.log"
# shellcheck source=/dev/null
. "$LIB" || { echo "  FAILED   could not source $LIB"; echo "Ran 1 checks, 1 failed"; exit 1; }
LOG="$T/test.log"; OUT="$T/out"          # lib_e.sh rewrites LOG at load; ours is the one under test

declare -F assert_restore_landed >/dev/null || { echo "  FAILED   $LIB does not define assert_restore_landed"; echo "Ran 1 checks, 1 failed"; exit 1; }
declare -F restore_production   >/dev/null || { echo "  FAILED   $LIB does not define restore_production";   echo "Ran 1 checks, 1 failed"; exit 1; }

printf 'const bit<16> SAMPLE_RATE = 256;\nconst bit<32> SAMPLE_TRUNC_BYTES = 128;\n' > "$P4SRC"
printf 'production-kernel-bytes\n' > "$KBIN_BACKUP"
cp "$KBIN_BACKUP" "$KBIN"

# The primitive exactly as p4c emits it, copied from the real build
# (p4_proxy/p4_src/build/ndtwin_switch.json, actions[15].primitives[0]), plus the truncate op the
# old check looked at -- present in EVERY fixture below, which is the point.
write_json() {   # $1 = lo hexstr, $2 = hi hexstr
    cat > "$P4BUILD/ndtwin_switch.json" <<JSON
{"actions":[{"name":"sample","primitives":[
 {"op" : "truncate", "parameters":[{"type":"hexstr","value":"0x00000080"}]},
 {"op":"modify_field_rng_uniform","parameters":[{"type":"field","value":["scalars","metadata.sample_rand"]},{"type":"hexstr","value":"$1"},{"type":"hexstr","value":"$2"}]}
]}]}
JSON
}

# 🔴 An INDEPENDENT decoder.  The fixture must be proved to encode the case before the case is
# used, or a typo in write_json produces a green that means nothing -- and it must not be proved
# by the same function the test is about, or a broken decoder proves itself.
fixture_bounds() {
    python3 - "$P4BUILD/ndtwin_switch.json" <<'PY' 2>/dev/null || echo FIXTURE-UNREADABLE
import json, sys
d = json.load(open(sys.argv[1]))
p = [x for a in d["actions"] for x in a["primitives"] if x["op"] == "modify_field_rng_uniform"]
h = [q["value"] for q in p[0]["parameters"] if q["type"] == "hexstr"]
assert any(x["op"] == "truncate" for a in d["actions"] for x in a["primitives"]), "no truncate op"
print("%d %d" % (int(h[0], 16), int(h[1], 16)))
PY
}

# Green means: returns 0, and no RESTORE-FAILED marker left behind.
restore_verdict() {
    rm -f "$OUT/RESTORE-FAILED"
    local out rc
    out="$(assert_restore_landed 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then echo "GREEN"; else
        [[ -f "$OUT/RESTORE-FAILED" ]] && echo "RED+MARKER" || echo "RED-NO-MARKER"
    fi
}

# --- 1. production artefact (0..255) is ACCEPTED -----------------------------------------------
# The other direction.  Without it, a mutation that reddens everything would look like a fix.
write_json 0x0000 0x00ff
check "fixture check: production JSON encodes rng 0..255 and a truncate op" "0 255" "$(fixture_bounds)"
check "case 1  production compiled artefact (rng 0..255) is accepted" "GREEN" "$(restore_verdict)"

# --- 2. an arm left compiled at 1/8 is REJECTED ------------------------------------------------
# The .p4 source is left at 256 on purpose: this is the exact state a restore that edited the
# source and never recompiled leaves behind, and the old assertion called it verified.
write_json 0x0000 0x0007
check "fixture check: 1/8 JSON encodes rng 0..7 with the source still saying 256" "0 7" "$(fixture_bounds)"
check "case 2  compiled artefact still at 1/8 while the source reads 256 is REJECTED" \
      "RED+MARKER" "$(restore_verdict)"

# --- 3. a pipeline that samples NOTHING (lo=1) is REJECTED -------------------------------------
# hi is still 255, so every reading that looks only at the upper bound -- including `ndt status`
# before it was fixed -- calls this "1/256".
write_json 0x0001 0x00ff
check "fixture check: zero-sampling JSON encodes rng 1..255 (hi still 255)" "1 255" "$(fixture_bounds)"
check "case 3  compiled artefact that samples nothing (rng 1..255) is REJECTED" \
      "RED+MARKER" "$(restore_verdict)"

# --- 4. ORDER: the stack goes down BEFORE the kernel binary is touched --------------------------
write_json 0x0000 0x00ff
order="$(
  : >"$T/order"
  teardown()              { printf 'TEARDOWN\n' >>"$T/order"; }
  compile_at()            { printf 'COMPILE %s\n' "$1" >>"$T/order"; return 0; }
  assert_restore_landed() { printf 'ASSERT\n' >>"$T/order"; return 0; }
  RUN() { [[ "${1:-}" == cp ]] && printf 'CP\n' >>"$T/order"; command "$@"; }
  restore_production >/dev/null 2>&1
  tr '\n' ' ' <"$T/order" | sed 's/ $//'
)"
# Assert the injection took effect before asserting the response: if the stubs never ran, the
# trace is empty and "does not start with CP" would be trivially, uselessly true.
if [[ "$order" == *TEARDOWN* && "$order" == *CP* ]]; then
    t_ok "injection check: the ordering probe reached both teardown and the kernel copy"
else
    t_bad "injection check: the ordering probe reached both teardown and the kernel copy" \
          "trace was [$order] -- the stubs did not run, so case 4 proves nothing"
fi
check "case 4  restore_production tears the stack down BEFORE copying the kernel binary" \
      "TEARDOWN CP COMPILE 256 ASSERT" "$order"

# --- 5. the copy's EXIT CODE is read ------------------------------------------------------------
# $KBIN already equals $KBIN_BACKUP, so assert_restore_landed's sha comparison is green either
# way: reading the rc is the only thing that can notice the copy never happened.
cp "$KBIN_BACKUP" "$KBIN"
run_with_cp_rc() {   # $1 = rc the stubbed cp returns; prints "<rc-of-restore_production> <cp-calls>"
    (
      : >"$T/cpcalls"
      teardown()   { :; }
      compile_at() { return 0; }
      # $1 belongs to run_with_cp_rc, not to RUN, so bind the wanted rc into the definition.
      eval "RUN() { if [[ \"\${1:-}\" == cp ]]; then printf 'called\\n' >>\"$T/cpcalls\"; return $1; fi; command \"\$@\"; }"
      out="$(restore_production 2>&1)"; rc=$?
      printf '%s %s %s\n' "$rc" "$(wc -l <"$T/cpcalls" | tr -d ' ')" \
             "$(grep -c 'cp of the production kernel FAILED' <<<"$out")"
    )
}
ok_line="$(run_with_cp_rc 0)"
bad_line="$(run_with_cp_rc 1)"
# Injection first: a stub that was never called cannot have had its rc read.
if [[ "${bad_line#* }" == "1 "* ]]; then
    t_ok "injection check: the failing-cp probe actually invoked the stubbed cp exactly once"
else
    t_bad "injection check: the failing-cp probe actually invoked the stubbed cp exactly once" \
          "probe result was [$bad_line] -- field 2 is the call count"
fi
check "case 5a a kernel copy that SUCCEEDS leaves restore_production green" "0 1 0" "$ok_line"
check "case 5b a kernel copy that FAILS is reported and makes restore_production non-zero" \
      "1 1 1" "$bad_line"

echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
