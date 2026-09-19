#!/usr/bin/env bash
#
# Does the mutation gate refuse correctly when it CANNOT test?
#
# [Co-developed with claude code -- Adam]
#
# 🔴 A GATE'S REFUSAL PATHS ARE INSTRUMENTS TOO, and an instrument nobody has seen fail is a
# decoration. Two of this gate's paths decide whether its numbers mean anything:
#
#   (a) ANCHOR DRIFT -- a mutation whose anchor no longer matches is never applied, the suite
#       then passes, and the gate used to print that as SURVIVED: evidence about a test, when
#       in fact no mutation was made and there is no verdict to give. This is not hypothetical.
#       On 2026-09-19 M-E21's anchor drifted when round 3 rewrote the release block, and the
#       gate reported a survivor that never existed (ruling 24(5) candidate, then 25(3)).
#   (b) PARTIAL RED -- report_shell requires EVERY named cell to go red. If only some do, the
#       mutation is not caught, and calling it caught would credit a cell that stayed green.
#
# This file runs the gate's own `--self-test`, which drives mutant() and report()/report_shell()
# over one deliberately-unmatchable anchor and one really-applied mutation reported against a
# cell that cannot exist, and then asserts on what the gate SAID.
#
# It is a sibling of test_drive_e_offline.sh rather than a cell inside it, on purpose: the gate
# runs that file for every shell mutation, so a cell there that invoked the gate would recurse.
#
# Run:  doc/audit/2026-09-19_telemetry-three-groups/tests/test_mutate_gate.sh
# Exit: 0 all cells passed; 1 a cell failed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/mutate_analyse.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; PASS=$((PASS + 1))
          else printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has()   { if [[ "$3" == *"$2"* ]]; then printf '  ok    %s\n' "$1"; PASS=$((PASS + 1))
          else printf '  FAIL  %s\n        expected to contain: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi; }
hasnt() { if [[ "$3" != *"$2"* ]]; then printf '  ok    %s\n' "$1"; PASS=$((PASS + 1))
          else printf '  FAIL  %s\n        must NOT contain: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi; }

printf '=== the gate refuses a verdict when it could not mutate\n'
OUT="$(timeout 1800 "$GATE" --self-test 2>&1)"; RC=$?

check "🔴 rc is 2 -- refused, not 0 (pass) and not 1 (a survivor)" "2" "$RC"
has   "🔴 and it says so in words"        "REFUSING A VERDICT" "$OUT"
has   "  the drifted mutation is named as DRIFT, not as a survivor" \
      "DRIFT  ST-1" "$OUT"
has   "  and the reason is on the line"   "NO mutation was made" "$OUT"
has   "  the counters carry it"           "drifted: 1" "$OUT"

printf '\n=== and exactly one verdict marker, which is the refusal\n'
has   "🔴 the log ends in ### rc=2"        "### rc=2" "$OUT"
hasnt "🔴 and there is no ### rc=0 anywhere in it" "### rc=0" "$OUT"
hasnt "  nor a ### rc=1"                   "### rc=1" "$OUT"
check "  exactly one rc marker in the whole run" "1" \
      "$(/usr/bin/grep -c '^### rc=' <<<"$OUT")"

printf '\n=== a mutation whose cells are only PARTLY red is not caught\n'
has   "🔴 report_shell says SURVIVED when one required cell stayed green" \
      "SURVIVED ST-2" "$OUT"
has   "  and it names the cell that stayed green" \
      "still green:   a cell name that does not exist in the suite" "$OUT"
hasnt "  it is never reported as caught" "caught   ST-2" "$OUT"

printf '\n=== the gate checked itself and said which paths fired\n'
has   "  (a) the drift path"   "ok    (a) an unmatchable anchor was reported as DRIFT" "$OUT"
has   "  (b) the partial-red path" "ok    (b) a partially-red mutation was reported SURVIVED" "$OUT"

printf '\n%s\n' "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) || exit 1
exit 0
