#!/usr/bin/env bash
#
# Tests for the two E-round defects closed on 2026-09-01: E-P4's fail-open clause, and abort()
# tearing down the evidence for the abort.
#
# [Co-developed with claude code -- Adam]
#
# (a) run_e.sh read `if [[ -n "$pv" && "$pv" != *SATURATED* && "$v" == *SATURATED* ]]`. When the
#     batching-off partner row was ABSENT, `-n "$pv"` made the whole guard evaluate false, so the
#     round said nothing and carried on -- silent in exactly the state where its input is gone.
#     The clause added to make the comparison safe to evaluate is the clause that emptied it.
#     🔑 Case 1 is the load-bearing one: the gate must go red for the MISSING-PARTNER case
#     SPECIFICALLY. A fix whose force-red only fires on some other case is a second hollow guard,
#     which is what 8/31 mainDev warned whoever picked this up about.
#
# (b) abort() ran restore_production -> teardown -> the topology's tmux session was gone, taking
#     with it the only account of why leg 1 died at 02:10:58. Both actions were correct; the ORDER
#     was wrong. Case 5 tests the order, because that is the entire defect.
#
# No fabric and no lab claim: ep4_verdict is pure, and the capture is driven by a stub $LAB.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND_DIR="$HERE/../../doc/audit/2026-08-31_sampling-ceiling-after-merge"

PASS=0
FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"; PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export ROUND="$ROUND_DIR" DRY_RUN=0
LOG="$T/test.log"; OUT="$T/out"; mkdir -p "$OUT"
# shellcheck source=/dev/null
. "$ROUND_DIR/lib_e.sh"
LOG="$T/test.log"; OUT="$T/out"          # lib_e.sh may rewrite LOG; ours is the one under test

declare -F ep4_verdict >/dev/null || { echo "FAILED   lib_e.sh does not define ep4_verdict"; exit 1; }

HEALTHY=$'e_bl_0008_1\tbl\t8\t1\t1khz\t1\t-\tsha\tcell=e_bl_0008_1  mark=OK  ratio=0.99'
SAT=$'e_bl_0008_1\tbl\t8\t1\t1khz\t1\t-\tsha\tcell=e_bl_0008_1  mark=SATURATED  ratio=0.80'

# --- (a) the decision -------------------------------------------------------------------------
check "case 1  partner row MISSING -> MISSING-PARTNER (the defect)" \
      MISSING-PARTNER "$(ep4_verdict "" "$SAT")"
check "case 2  partner healthy, cell saturated -> RATIO-MOVED (behaviour kept)" \
      RATIO-MOVED "$(ep4_verdict "$HEALTHY" "$SAT")"
check "case 3  partner saturated too -> OK (not a merge effect)" \
      OK "$(ep4_verdict "$SAT" "$SAT")"
check "case 4  both healthy -> OK" \
      OK "$(ep4_verdict "$HEALTHY" "$HEALTHY")"

# --- (a) the decision is actually WIRED IN.  A fixed function with no caller is not a fix. -----
wired=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' "$ROUND_DIR/run_e.sh" | grep -c 'ep4_verdict "\$pv" "\$v"')
check "case 4b run_e.sh calls ep4_verdict on the real cell values" 1 "$wired"
check "case 4c run_e.sh aborts on MISSING-PARTNER" 1 \
      "$(grep -c '^        MISSING-PARTNER)' "$ROUND_DIR/run_e.sh")"

# --- (b) ORDER: evidence is preserved BEFORE the restore that destroys it ----------------------
( : >"$T/order"
  preserve_abort_evidence() { printf 'PRESERVE\n' >>"$T/order"; }
  restore_production()      { printf 'RESTORE\n'  >>"$T/order"; }
  abort "§test" "ordering probe" ) >/dev/null 2>&1
check "case 5  abort preserves evidence BEFORE restore_production" \
      "PRESERVE RESTORE" "$(tr '\n' ' ' <"$T/order" | sed 's/ $//')"

# --- (b) the FORCED branch captures too.  F-24: the preserving branch was wired to the case
#         that did not need it, so the one that did was never covered. -------------------------
( : >"$T/order2"
  preserve_abort_evidence() { printf 'PRESERVE\n' >>"$T/order2"; }
  restore_production()      { printf 'RESTORE\n'  >>"$T/order2"; }
  FORCED_ABORT=1 abort "§test" "forced probe" ) >/dev/null 2>&1
check "case 6  a FORCED abort captures evidence and skips only the restore" \
      "PRESERVE" "$(tr '\n' ' ' <"$T/order2" | sed 's/ $//')"

# --- (b) the size report describes the PANE, not the file the function just wrote --------------
# 🔑 The empty-pane stub still answers `status`, at realistic length, because that is the real
# failure: the lab is alive and it is the PANE that is gone.
#
# The length is load-bearing and the mutation gate is what proved it. A first version answered
# `status` in 38 characters -- under the 64-byte floor -- so mutating the size report to measure
# `status` instead of the pane still produced "NOT captured" and case 7 stayed green. The case
# claimed to test "the report describes the pane, not some other capture" while being unable to
# tell the two apart. A fixture too small to discriminate reads exactly like a passing test.
printf '#!/bin/sh\n[ "$1" = status ] && { echo "ndtwin-lab: bmv2: 10  ovs: 0  proxy: up  kernel: up"; echo "claim: none   measuring: no   topo session: absent"; }\nexit 0\n' \
    >"$T/lab_empty"; chmod +x "$T/lab_empty"
printf '#!/bin/sh\n[ "$1" = topo-out ] && { i=0; while [ $i -lt 20 ]; do echo "topology line $i"; i=$((i+1)); done; }\nexit 0\n' \
    >"$T/lab_full"; chmod +x "$T/lab_full"

( LAB="$T/lab_empty"; LOG="$T/empty.log"; OUT="$T/out"; preserve_abort_evidence "§empty" ) >/dev/null 2>&1
check "case 7  an empty pane is reported as NOT captured, not as nothing to report" 1 \
      "$(grep -c 'NOT captured' "$T/empty.log" 2>/dev/null || echo 0)"

( LAB="$T/lab_full"; LOG="$T/full.log"; OUT="$T/out"; preserve_abort_evidence "§full" ) >/dev/null 2>&1
check "case 8  a real pane is reported as preserved" 1 \
      "$(grep -c 'abort evidence preserved BEFORE restore' "$T/full.log" 2>/dev/null || echo 0)"
# 🔑 Locate the file, do not predict its name. The first draft globbed for a tag with three
# underscores because it assumed one substitution per character; "§" is two bytes in UTF-8 and
# ${tag//[^A-Za-z0-9]/_} substitutes per byte, so the name has two. Both of the checks below
# reported 0 -- looking exactly like "the capture wrote nothing" while the capture was fine.
full_file=$(find "$OUT" -name 'abort-evidence*full*.log' -print -quit 2>/dev/null)
empty_file=$(find "$OUT" -name 'abort-evidence*empty*.log' -print -quit 2>/dev/null)
check "case 8b the captured file actually contains the pane" 1 \
      "$(grep -c 'topology line 19' "$full_file" 2>/dev/null || echo 0)"

# --- (b) and the check cannot be passed by the header alone -----------------------------------
# The header is ~150 bytes. If the size test measured the FILE, the empty-pane case would pass.
hdr=$(wc -c <"$empty_file" 2>/dev/null || echo 0)
check "case 9  the empty-pane file is still non-trivial, so a file-size test would have passed it" \
      yes "$( [[ "$hdr" -gt 64 ]] && echo yes || echo no )"

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
