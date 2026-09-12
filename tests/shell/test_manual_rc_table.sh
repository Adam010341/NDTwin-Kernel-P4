#!/usr/bin/env bash
#
# Does doc/2026-08-17_testing-manual.md still read exit codes the way the tool answers them?
#
# [Co-developed with claude code -- Adam]
#
# FIX-NDT-8 (merged af5efa4f, 2026-09-12) made `ndt up`, `ndt down` and `ndt clean` share ONE
# rc vocabulary -- 1 measured and dirty, 3 nothing to measure, 5 a guard refused, 0 measured
# and clean, 2 usage -- and put the three tables into `ndt help`. The manual was written
# against the code BEFORE that, in three places, and one of them is the only paragraph in the
# document that tells a reader how to decide whether a lab was restored: it required `ndt clean`
# to answer rc 0, which is exactly the state that now answers 3. Following the manual would have
# scored a lab that WAS put back as one that was not (KNOWN-ISSUES G-53).
#
# 🔴 `ndt help` IS THE AUTHORITY AND THIS TEST TREATS IT AS ONE. Every code the manual glosses
# carries the sentence `ndt help` prints for it, and case 7 goes and finds that sentence in the
# live output of `tools/test_workflow/ndt help`. The manual cannot drift away from the tool
# without this going red, and it cannot drift by inventing a meaning the tool never stated.
#
# 🔴 THE OTHER DIRECTION IS WHY CASES 1-4 EXIST. A test that only asks "is every manual quote
# in the help text" passes brilliantly when the help text stops saying anything -- the empty
# authority agrees with everything. Cases 1-4 assert that `ndt help` still prints the three
# blocks and still announces 3 and 5 inside them, per verb. If the tool changes its contract,
# this file goes red on those cases and names the verb, instead of quietly certifying a manual
# that now describes nothing.
#
# 🔴 CASE 14 IS THE CONTROL and it is green before this ticket's fix as well as after. It reads
# a sentence the fix does not touch (a live fabric answers `ndt clean` with rc 1, §2.1). A suite
# where every case is red on the unfixed manual cannot tell "sensitive" from "stuck red"; this
# one can.
#
# The rc table is marked in the manual with NDT-RC-TABLE:BEGIN/END and the restore criterion
# with NDT-RESTORE-CRITERION:BEGIN/END, so this test reads the two regions the ticket is about
# rather than grepping the whole document and hoping. Exactly one rc table is allowed (case 5):
# the defect being fixed is a second copy of the codes going stale on its own.
#
# Nothing is built, no lab is touched, nothing is written: this reads one markdown file and
# runs `ndt help`, which prints text and exits 2.
#
# Overridable for the mutation gate, which must never write this worktree's copies:
#   MANUAL=<path>  NDT=<path>  bash tests/shell/test_manual_rc_table.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MANUAL="${MANUAL:-$REPO/doc/2026-08-17_testing-manual.md}"
NDT="${NDT:-$REPO/tools/test_workflow/ndt}"

PASS=0
FAIL=0
check() {   # check <what> <expected> <actual>
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

[[ -r "$MANUAL" ]] || { echo "FAILED   the manual is not readable: $MANUAL"; exit 2; }
[[ -r "$NDT"    ]] || { echo "FAILED   ndt is not readable: $NDT"; exit 2; }

# --- the authority ------------------------------------------------------------------------
# `ndt help` exits 2 by design (§2.0 of the manual), so its status is not read here.
HELP="$(bash "$NDT" help 2>&1)"
flat() { tr '\n' ' ' | tr -s ' '; }
# One command's block: the line that starts it, through to the next command at the same indent.
verb_block() {   # verb_block <verb>
    awk -v v="$1" 'BEGIN{on=0} /^  [a-z]/{ on = ($0 ~ "^  " v "([ ]|$)") } on' <<<"$HELP"
}
HELP_FLAT="$(flat <<<"$HELP")"
UP_FLAT="$(verb_block up    | flat)"
DOWN_FLAT="$(verb_block down  | flat)"
CLEAN_FLAT="$(verb_block clean | flat)"

# --- case 1: the authority is actually there ------------------------------------------------
# Without this, every "the manual agrees with help" case below passes on an empty help text.
for v in up down clean; do
    n=$(verb_block "$v" | wc -l)
    check "case 1  'ndt help' still prints a block for '$v' (>= 5 lines)" \
          "yes" "$( [[ "$n" -ge 5 ]] && echo yes || echo "no ($n line(s))" )"
done

# --- cases 2-4: help still announces the contract, per verb ---------------------------------
check "case 2  help's 'clean' block still announces 3 as nothing to judge" \
      1 "$(grep -c 'THERE WAS NOTHING TO JUDGE' <<<"$CLEAN_FLAT")"
check "case 3  help's 'down' block still announces 3 as nothing to tear down" \
      1 "$(grep -c 'THERE WAS NOTHING TO TEAR DOWN' <<<"$DOWN_FLAT")"
check "case 4a help's 'down' block still announces 5 as a guard refusal" \
      1 "$(grep -c 'A GUARD REFUSED' <<<"$DOWN_FLAT")"
check "case 4b help's 'up' block still announces 5 as a guard refusal" \
      1 "$(grep -ci 'a GUARD REFUSED' <<<"$UP_FLAT")"
check "case 4c help's 'clean' block still says its refusal is rc 5" \
      1 "$(grep -c 'refusal is rc 5' <<<"$CLEAN_FLAT")"

# --- the manual's two marked regions --------------------------------------------------------
BEGINS=$(grep -c 'NDT-RC-TABLE:BEGIN' "$MANUAL")
ENDS=$(grep -c 'NDT-RC-TABLE:END' "$MANUAL")
region() {   # region <name> -- the lines strictly between BEGIN and END
    awk -v b="$1:BEGIN" -v e="$1:END" '
        index($0, e) { on=0 }
        on           { print }
        index($0, b) { on=1 }' "$MANUAL"
}
TABLE="$(region NDT-RC-TABLE)"
RESTORE="$(region NDT-RESTORE-CRITERION)"

# --- case 5: exactly one rc table ------------------------------------------------------------
# The defect this fixes is a second copy of the codes drifting on its own, so a second table is
# a failure even when both copies happen to be right today.
check "case 5  the manual carries exactly one rc table (BEGIN/END)" "1/1" "$BEGINS/$ENDS"

# --- case 6: every code in the contract has a row ---------------------------------------------
# The row form is `| <code> | ...`. The contract is FIX-NDT-8's five codes.
row() { grep -E "^\| *$1 *\|" <<<"$TABLE"; }
for code in 0 1 2 3 5; do
    check "case 6  the rc table has a row for rc $code" 1 "$(row "$code" | grep -c . )"
done

# --- case 7: every sentence the table attributes to `ndt help` is really in `ndt help` --------
# Third column, backticked. A quote the tool does not print is the manual inventing a contract.
# 7a alone is green on a manual with no table at all (nothing to disagree with), which is why it
# is not allowed to stand on its own: 7b asserts the table quotes the tool in the first place.
QUOTES=$(sed -n 's/^|[^|]*|[^|]*| *`\([^`]*\)` *|.*$/\1/p' <<<"$TABLE")
missing=0
nquotes=0
while IFS= read -r q; do
    [[ -z "$q" ]] && continue
    nquotes=$((nquotes + 1))
    if ! grep -Fq -- "$q" <<<"$HELP_FLAT"; then
        missing=$((missing + 1))
        echo "             not printed by 'ndt help': $q"
    fi
done <<<"$QUOTES"
check "case 7a every quote in the rc table is verbatim from 'ndt help'" 0 "$missing"
check "case 7b the rc table quotes 'ndt help' at all (>= 5 quotes)" \
      "yes" "$( [[ "$nquotes" -ge 5 ]] && echo yes || echo "no ($nquotes)" )"

# --- cases 8-9: the two rows the old manual did not have --------------------------------------
check "case 8  the rc 3 row says nothing was measured, not that it was clean" \
      1 "$(row 3 | grep -c '沒有東西可量')"
check "case 9  the rc 5 row says a guard refused and nothing was done" \
      1 "$(row 5 | grep -c '守衛拒絕')"

# --- case 10: no shorthand in a code block glosses an rc on its own ---------------------------
# `ndt clean  # ... exit 1 = ...` is how both stale sites were written. A comment may point at
# the table; it may not carry a code of its own, because that copy is what goes stale.
GLOSSED=$(grep -nE '^ndt (up|down|clean)\b[^#]*#.*(exit|rc) *[0-9]' "$MANUAL")
NGLOSSED=0
if [[ -n "$GLOSSED" ]]; then
    NGLOSSED=$(wc -l <<<"$GLOSSED")
    sed 's/^/             /' <<<"$GLOSSED"
fi
check "case 10 no 'ndt up/down/clean' command comment carries its own rc gloss" \
      0 "$NGLOSSED"

# --- cases 11-13: the restore criterion --------------------------------------------------------
# §2.8 is the only paragraph in the manual that tells a reader how to decide a lab was restored.
check "case 11 the restore criterion exists and is marked" \
      "yes" "$( [[ -n "$RESTORE" ]] && echo yes || echo no )"
# Presence, not an exact count: `ndt down` and `ndt clean` are both read with this vocabulary,
# so a phrase legitimately appears more than once here.
says() { grep -q "$1" <<<"$RESTORE" && echo yes || echo no; }
check "case 12a the restore criterion accepts rc 3 from 'ndt clean' as restored" \
      "yes" "$(says '`ndt clean` 回 0 或 3')"
check "case 12d the restore criterion accepts rc 3 from 'ndt down' too" \
      "yes" "$(says '`ndt down`.*0 或 3')"
check "case 12b the restore criterion still calls rc 1 not-restored" \
      "yes" "$(says '1.*還沒還原')"
check "case 12c the restore criterion says rc 5 measured nothing" \
      "yes" "$(says '5.*什麼都沒驗')"
check "case 13 the restore criterion reads orphans_verdict.sh's VERDICT, not a rc" \
      "yes/yes" "$(says 'orphans_verdict.sh')/$(says 'VERDICT: CLEAN')"

# --- case 14 (CONTROL): a sentence this ticket does not touch is still there --------------------
# Green on the unfixed manual and on the fixed one. If this file ever goes all-red, this case is
# how you tell a real regression from a test that stopped reading the document.
check "case 14 CONTROL: §2.1 still says a live fabric answers 'ndt clean' with rc 1" \
      1 "$(grep -c 'fabric 活著時 `ndt clean` 回 rc 1 是正常的' "$MANUAL")"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
