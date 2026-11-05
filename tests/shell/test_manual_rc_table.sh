#!/usr/bin/env bash
#
# Does doc/2026-11-05_user-guide.md still read exit codes the way the tool answers them?
#
# [Co-developed with claude code -- Adam]
#
# `ndt up`, `ndt down` and `ndt clean` share ONE rc vocabulary -- 1 measured and dirty, 3 nothing
# to measure, 5 a guard refused, 0 measured and clean, 2 usage -- and the three tables are in
# `ndt help`. The user guide glosses those codes, and one paragraph of it is the only place that
# tells a reader how to decide whether a lab was restored: written wrongly (as it once was, in the
# guide's predecessor) it requires `ndt clean` to answer rc 0, which is exactly the state that
# answers 3, and scores a lab that WAS put back as one that was not (KNOWN-ISSUES G-53).
#
# 🔴 `ndt help` IS THE AUTHORITY AND THIS TEST TREATS IT AS ONE. Every code the guide glosses
# carries the sentence `ndt help` prints for it, and case 7 goes and finds that sentence in the
# live output of `tools/test_workflow/ndt help`. The guide cannot drift away from the tool
# without this going red, and it cannot drift by inventing a meaning the tool never stated.
#
# 🔴 THE OTHER DIRECTION IS WHY CASES 1-4 EXIST. A test that only asks "is every guide quote
# in the help text" passes brilliantly when the help text stops saying anything -- the empty
# authority agrees with everything. Cases 1-4 assert that `ndt help` still prints the three
# blocks and still announces 3 and 5 inside them, per verb. If the tool changes its contract,
# this file goes red on those cases and names the verb, instead of quietly certifying a guide
# that now describes nothing.
#
# 🔴 CASE 14 IS THE CONTROL and it is green before the fix as well as after. It reads a sentence the
# fix does not touch (a live fabric answers `ndt clean` with rc 1, section 4.10). A suite where every case
# is red on the unfixed guide cannot tell "sensitive" from "stuck red"; this one can.
#
# The rc table is marked in the guide with NDT-RC-TABLE:BEGIN/END and the restore criterion
# with NDT-RESTORE-CRITERION:BEGIN/END, so this test reads the two regions this is about
# rather than grepping the whole document and hoping. Exactly one rc table is allowed (case 5):
# the defect being fixed is a second copy of the codes going stale on its own.
#
# Nothing is built, no lab is touched, nothing is written: this reads one markdown file and
# runs `ndt help`, which prints text and exits 2.
#
# Overridable for the mutation gate, which must never write this worktree's copies (MANUAL names
# the guide; the variable keeps its old name because the gate passes it):
#   MANUAL=<path>  NDT=<path>  bash tests/shell/test_manual_rc_table.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MANUAL="${MANUAL:-$REPO/doc/2026-11-05_user-guide.md}"
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

[[ -r "$MANUAL" ]] || { echo "FAILED   the guide is not readable: $MANUAL"; exit 2; }
[[ -r "$NDT"    ]] || { echo "FAILED   ndt is not readable: $NDT"; exit 2; }

# --- the authority ------------------------------------------------------------------------
# `ndt help` exits 2 by design (section 4.1 of the guide), so its status is not read here.
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
# Without this, every "the guide agrees with help" case below passes on an empty help text.
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

# --- the guide's two marked regions --------------------------------------------------------
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
check "case 5  the guide carries exactly one rc table (BEGIN/END)" "1/1" "$BEGINS/$ENDS"

# --- case 6: every code in the contract has a row ---------------------------------------------
# The row form is `| <code> | ...`. The contract is the five codes above.
row() { grep -E "^\| *$1 *\|" <<<"$TABLE"; }
for code in 0 1 2 3 5; do
    check "case 6  the rc table has a row for rc $code" 1 "$(row "$code" | grep -c . )"
done

# --- case 7: every sentence the table attributes to `ndt help` is really in `ndt help` --------
# Third column, backticked. A quote the tool does not print is the guide inventing a contract.
# 7a alone is green on a guide with no table at all (nothing to disagree with), which is why it
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

# --- cases 8-9: the two rows the old guide did not have --------------------------------------
# Case-SENSITIVE on purpose: the third column quotes `ndt help` in capitals (`A GUARD REFUSED ...`), so a
# case-insensitive match would be satisfied by the quote and say nothing about the guide's own gloss.
check "case 8  the rc 3 row says nothing was measured, not that it was clean" \
      1 "$(row 3 | grep -c 'nothing to measure')"
check "case 9  the rc 5 row says a guard refused and nothing was done" \
      1 "$(row 5 | grep -c 'a guard refused')"

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
# The restore criterion is the only paragraph in the guide that tells a reader how to decide a lab was restored.
check "case 11 the restore criterion exists and is marked" \
      "yes" "$( [[ -n "$RESTORE" ]] && echo yes || echo no )"
# Presence, not an exact count: `ndt down` and `ndt clean` are both read with this vocabulary,
# so a phrase legitimately appears more than once here.
says() { grep -q "$1" <<<"$RESTORE" && echo yes || echo no; }
check "case 12a the restore criterion accepts rc 3 from 'ndt clean' as restored" \
      "yes" "$(says '`ndt clean` returns 0 or 3')"
check "case 12d the restore criterion accepts rc 3 from 'ndt down' too" \
      "yes" "$(says '`ndt down`.*0 or 3')"
check "case 12b the restore criterion still calls rc 1 not-restored" \
      "yes" "$(says '1.*not restored')"
check "case 12c the restore criterion says rc 5 measured nothing" \
      "yes" "$(says '5.*checked nothing')"
check "case 13 the restore criterion reads orphans_verdict.sh's VERDICT, not a rc" \
      "yes/yes" "$(says 'orphans_verdict.sh')/$(says 'VERDICT: CLEAN')"

# --- case 15: the guide does not type what `ndt help` computes --------------------------------
# The size of ports.sh's table ("N rule(s), M port(s)") and its port list are printed by `ndt help`
# from the file itself, so that they cannot go stale. A copy typed into the guide is the same
# artefact one edit later (the help says so, under `down --deep`), and nothing guards it. The guide
# therefore points at the help; this case fails if a typed count or the typed list comes back.
check "case 15 the guide does not type the port table's size or its port list" \
      0 "$(grep -cE '[0-9]+ rules?,? [0-9]+ ports?|[0-9]+ rule\(s\)|8000/8080/8081' "$MANUAL")"

# --- case 16: the guide's sudoers lines never grant a root-equivalent program unrestricted -------------
# `sed` (its `e` command, or -i on any file), `exportfs` (any directory, no_root_squash), a bare `tc`
# and a bare `ifconfig` are each root on the machine, and the code needs only scoped forms of tc and
# ifconfig and never needs sed or exportfs from a kernel that `ndt` started. Every entry after a
# `NOPASSWD:` in the guide (entries are comma separated) is read; an entry that is one of those four
# programs with no arguments after it is a violation. 16b is the instrument's own check: the scan must
# actually see the guide's lines, or "no violation" would be said about nothing.
GRANT_ENTRIES="$(sed -n 's/.*NOPASSWD:[[:space:]]*//p' "$MANUAL" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
check "case 16 no sudoers entry in the guide grants sed, exportfs, a bare tc or a bare ifconfig" \
      0 "$(grep -cE '^/usr/(bin/sed|sbin/(exportfs|tc|ifconfig))$' <<<"$GRANT_ENTRIES")"
check "case 16b the grant scan sees the guide's sudoers entries (>= 8)" \
      "yes" "$( [[ "$(grep -c . <<<"$GRANT_ENTRIES")" -ge 8 ]] && echo yes || echo "no ($(grep -c . <<<"$GRANT_ENTRIES"))" )"

# --- case 14 (CONTROL): a sentence the fix does not touch is still there --------------------
# Green on the unfixed guide and on the fixed one. If this file ever goes all-red, this case is
# how you tell a real regression from a test that stopped reading the document.
check "case 14 CONTROL: the guide still says a live fabric answers 'ndt clean' with rc 1" \
      1 "$(grep -c 'Over a live fabric a plain `ndt clean` returns rc 1' "$MANUAL")"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
