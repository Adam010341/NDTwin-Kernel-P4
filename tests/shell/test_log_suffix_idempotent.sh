#!/usr/bin/env bash
#
# Tests for the round scripts' log-name derivation (KNOWN-ISSUES: the suffix stacked).
#
# [Co-developed with claude code -- Adam]
#
# The defect: round.env did `export LOG=`, and both round drivers appended their suffix to whatever
# LOG they were handed. A parent running selftest under DRY_RUN produced run_f5.dryrun.selftest.log
# and exported it; the `arm` child it spawned inherited that finished name and suffixed it again ->
# run_f5.dryrun.selftest.dryrun.log. The number of layers equalled the process nesting depth.
# The suffix logic assumed it was given the original name; export gave it the previous level's
# product. The missing property has a name: f(f(x)) != f(x).
#
# Case 3 is the load-bearing one: it drives the ACTUAL nesting that produced the reported filename.
# Case 6 is the one that keeps it fixed -- the two rounds carry separate copies of derive_log
# (F5 has no lib file), and copies drift.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
E="$HERE/../../doc/audit/2026-08-31_sampling-ceiling-after-merge"
F="$HERE/../../doc/audit/2026-08-31_f5-fine-grid-round"

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS + 1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"
         FAIL=$((FAIL + 1)); fi
}
extract() { sed -n '/^derive_log()/,/^}/p' "$1"; }     # the SHIPPED body, not a copy of it

# --- load the shipped function out of lib_e.sh. run_f5.sh cannot be sourced (it dispatches on $1),
#     so its copy is extracted the same way and compared in case 6.
eval "$(extract "$E/lib_e.sh")"
declare -F derive_log >/dev/null || { echo "FAILED   lib_e.sh has no derive_log"; exit 1; }

B=/tmp/round/run_f5.log

# 🔑 An inherited, ALREADY-SUFFIXED LOG is in scope for every call below, and it has to be: the
# whole contract is that derive_log ignores the ambient LOG and uses only the base it is handed.
# Without this the mutation "build from $LOG instead of $1" is inert in the test shell -- LOG is
# unset there, so the fallback lands back on $1 and the wrong code passes. The mutation gate is
# what surfaced that; the fixture was reproducing an environment the defect cannot exist in.
export LOG="/tmp/round/run_f5.dryrun.selftest.log"

# --- the property, directly ---------------------------------------------------------------------
check "case 1  one suffix" "/tmp/round/run_f5.dryrun.log" "$(derive_log "$B" dryrun)"
check "case 2  suffixes compose in order" "/tmp/round/run_f5.dryrun.selftest.log" \
      "$(derive_log "$B" dryrun selftest)"

# 🔑 The reported filename, reproduced both ways. This is the whole ticket.
parent=$(derive_log "$B" dryrun selftest)          # parent: dry + selftest
child_new=$(derive_log "$B" dryrun)                # child re-derives from the base
child_old="${parent%.log}.dryrun.log"              # child appends to the inherited name
check "case 3  a child deriving from the base does not stack" "/tmp/round/run_f5.dryrun.log" "$child_new"
check "case 3b and appending to the inherited name is what stacked" \
      "/tmp/round/run_f5.dryrun.selftest.dryrun.log" "$child_old"

check "case 4  f(f(x)) == f(x): deriving twice from the base is stable" \
      "$(derive_log "$B" dryrun plan)" "$(derive_log "$B" dryrun plan)"
check "case 5  no suffixes returns the base untouched" "$B" "$(derive_log "$B")"

# --- the two copies must not drift ---------------------------------------------------------------
check "case 6  lib_e.sh and run_f5.sh carry the same derive_log" identical \
      "$( [[ "$(extract "$E/lib_e.sh")" == "$(extract "$F/run_f5.sh")" ]] && echo identical || echo drifted )"

# --- nobody appends to an inherited LOG any more --------------------------------------------------
# Case 1-5 only prove the helper is right. This proves it is the thing being used.
#
# 🔑 Comment lines are stripped first, and the first draft did not strip them: both fixes describe
# the old line verbatim in the comment explaining why it changed, so the check counted its own
# documentation and reported 2. A guard that cannot tell "the defect is present" from "the defect
# is explained" would go red on every file that documents its own history -- and would go green if
# someone re-introduced the append inside a heredoc. Code lines only.
# 🔴 B12 (2026-09-11). This used to be
#
#     grep -c 'LOG="\${LOG%\.log}'
#
# over FOUR hard-coded paths. hunt-0911/F-B0-B12-REPORT.md §3.1 rows (6)b and (6)c put the same
# append through that pipeline spelled `${LOG%%.log}` (bash's other strip operator, same result
# here) and `${LOG%".log"}` (the suffix quoted, which bash allows) and got 0 out of both. What
# was guarded was one string; what has to be guarded is "this line builds the new log name out of
# the inherited LOG". Two more spellings do the same damage and were never in the report:
# `LOG="$LOG.dryrun.log"` appends with no strip at all, and `LOG=${LOG%.log}.x` drops the quotes.
#
# The rule, in two alternatives:
#   ${LOG%...} / ${LOG#...}   the extension stripped off the INHERITED name -- any number of
#                             % or #, suffix quoted or not;
#   $LOG. / ${LOG}. / $LOG/   the inherited name with something appended straight onto it.
# `LOG="$LOG_BASE"` and `LOG="$(derive_log "$LOG_BASE" ...)"` are what the fix looks like, and
# neither is matched: the name must END at LOG (`$LOG_BASE` continues), and `${LOG:-$d}` has no
# strip and nothing appended. The value stops at the first `;`, `&` or `|`, because
# `LOG=$HOME/x.log; W=$(launch "$LOG")` is one assignment followed by a different command.
#
# 🔴 The assignment is anchored to a COMMAND POSITION, not to the start of a line, and that is
# not a detail: mutation 5 of tests/shell/mutate_log_suffix_idempotent.sh puts the defect back as
#     plan|selftest|restore) LOG="${LOG%.log}.$1.log" ;;
# -- an assignment after a `case` pattern. An `^[[:space:]]*LOG=` rule let that mutation SURVIVE
# while every synthetic case above stayed green, which is exactly the shape this file's own
# header warns about. The same character class is what keeps `MYLOG=` and `child_old=` out: the
# name has to BEGIN where the match begins.
INHERITED_LOG_RE='(^|[;&|(){}[:space:]])(export[[:space:]]+|local[[:space:]]+|readonly[[:space:]]+|declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)?)?LOG=[^;&|]*(\$\{LOG[%#]|\$\{?LOG\}?[./])'

count_appends() {
    local f n total=0
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        n=$(sed 's/#.*//' "$f" | grep -cE "$INHERITED_LOG_RE")
        total=$((total + n))
    done
    printf '%s\n' "$total"
}

# counts_one <line> -- what the rule says about a single line. The (6)b/(6)c cases and their
# controls go through this, so a spelling that walks past is visible as a 0 next to a 1.
counts_one() { printf '%s\n' "$1" | sed 's/#.*//' | grep -cE "$INHERITED_LOG_RE" || true; }

# 🔴 The case lines are ASSEMBLED, never written out. This file is inside the surface case 7
# scans (every tracked shell script, this one included), so a literal assignment to LOG in
# command position here would be a finding this file produces about itself -- and the first run
# after the surface was widened was exactly that: two of the cases below, reported. Same
# discipline as cite() in tests/python/test_known_issues_references.py, and the same reason: an
# instrument that has to be excluded from its own scan has a scope nobody can check.
NAME="LO""G"
assign() { printf '%s=%s' "$NAME" "$1"; }

echo "case 7 the rule is 'built from the inherited LOG', not one spelling of it"
check "case 7a  \${LOG%.log} (the one it caught)" 1 "$(counts_one "$(assign '"${LOG%.log}.x.log"')")"
check "case 7b  (6)b the other strip operator"   1 "$(counts_one "$(assign '"${LOG%%.log}.x.log"')")"
check "case 7c  (6)c the suffix quoted"          1 "$(counts_one "$(assign '"${LOG%".log"}.x.log"')")"
check "case 7d  no quotes on the assignment"     1 "$(counts_one "$(assign '${LOG%.log}.x.log')")"
check "case 7e  appended with no strip at all"   1 "$(counts_one "export $(assign '"$LOG.dryrun.log"')")"
check "case 7f  braced and appended"             1 "$(counts_one "$(assign '"${LOG}.dryrun.log"')")"
check "case 7o  after a case pattern is still an assignment" 1 \
      "$(counts_one "    plan|selftest|restore) $(assign '"${LOG%.log}.$1.log"') ;;")"

# 🔴 The other side. Each of these is what the FIX looks like, and a guard that reported them
# would have to be switched off before the round scripts could be written at all.
check "case 7g  the base, not the inherited name" 0 "$(counts_one "$(assign '"$LOG_BASE"')")"
check "case 7h  deriving from the base is the fix" 0 \
      "$(counts_one "$(assign '"$(derive_log "$LOG_BASE" $LOG_SUFFIX_DRY)"')")"
check "case 7i  a default is not an append"      0 "$(counts_one "$(assign '"${LOG:-$fallback}"')")"
check "case 7j  another variable is not it"      0 "$(counts_one 'child_old="${parent%.log}.dryrun.log"')"
check "case 7p  a name that merely ends in it"   0 "$(counts_one "MY$(assign '"${LOG%.log}.x.log"')")"
check "case 7k  a comment is not code"           0 \
      "$(counts_one "# $(assign '"${LOG%.log}.x.log"') -- what it used to do")"
check "case 7l  and the stripper still sees code" 1 \
      "$(counts_one "$(assign '"${LOG%.log}.x.log"')   # trailing comment")"

# 🔴 And the SURFACE, which was four paths written out by hand. THE CLASS, written down: every
# path `git ls-files` reports whose name ends `.sh` or `.bash`, plus every tracked extensionless
# file whose first line is an sh/bash shebang (tools/test_workflow/ndt and ndtwin-lab are the
# two). That is "every shell script this repo tracks" -- the convention is a repo-wide one, and a
# fifth round script added next month is exactly the file a four-name list cannot see.
#
# The floor is asserted for the reason every scan in this tree asserts one: a derivation that
# returns nothing scans nothing and reports 0 appends, which is indistinguishable from clean.
shell_scripts() {
    local f
    while IFS= read -r -d '' f; do
        case "$f" in
            *.sh|*.bash) printf '%s\n' "$REPO_ROOT/$f"; continue ;;
            *.*)         continue ;;
        esac
        [[ -f "$REPO_ROOT/$f" ]] || continue
        case "$(head -1 "$REPO_ROOT/$f" 2>/dev/null)" in
            '#!'*sh|'#!'*sh[[:space:]]*) printf '%s\n' "$REPO_ROOT/$f" ;;
        esac
    done < <(git -C "$REPO_ROOT" ls-files -z)
}
mapfile -t SCRIPTS < <(shell_scripts)
check "case 7m  the scan found the shell scripts" yes \
      "$( (( ${#SCRIPTS[@]} >= 150 )) && echo yes || echo "no (${#SCRIPTS[@]} found)" )"
# 🔴 Seven, not four. Widening the surface found THREE MORE COPIES of the round scripts --
# doc/audit/2026-09-02_fix-design-campaign/findings/IPERF3-CONFLICT.patches/committed/{lib_e,
# run_e,gates_e}.sh -- which the four-name list never read. Case 6 above exists because "the two
# rounds carry separate copies of derive_log and copies drift"; there were five copies, and two
# of them were outside every check in this file. The assertion is a FLOOR and the count is
# printed, so a new copy appearing is visible rather than silently unscanned.
found_copies="$(printf '%s\n' "${SCRIPTS[@]}" | grep -cE '/(lib_e|run_e|gates_e|run_f5)\.sh$')"
check "case 7n  the four the ticket named are in it (of $found_copies copies found)" yes \
      "$( (( found_copies >= 4 )) && echo yes || echo "no ($found_copies)" )"
check "case 7  no script appends a suffix to the inherited LOG" 0 \
      "$(count_appends "${SCRIPTS[@]}")"

# --- round.env exports the immutable anchor in both rounds ---------------------------------------
for r in "$E" "$F"; do
    check "case 8  $(basename "$r")/round.env exports LOG_BASE" 1 \
          "$(grep -c '^export LOG_BASE=' "$r/round.env")"
done

# --- and the convention is enforced, not just documented ------------------------------------------
# A script that forgets to derive used to share a transcript with a real run. Now it stops.
# 🔑 Both the message AND the exit status. Checking only the message let the mutation that
# replaces `exit 2` with `:` pass: it still prints, it just no longer stops -- and "warns and
# carries on" is precisely what lib_e.sh's own preamble forbids. The mutation gate caught this.
out=$( set +e
       export ROUND="$E" DRY_RUN=1 LOG_BASE="$E/run_e.log"
       # shellcheck source=/dev/null
       . "$E/lib_e.sh" 2>/dev/null
       LOG="$E/run_e.log"          # simulate a caller that skipped the derivation
       assert_log_is_derived 2>&1 ); rc9=$?
check "case 9  a dry run whose LOG lacks .dryrun. says so" 1 \
      "$(grep -c 'carries no .dryrun. segment' <<<"$out")"
check "case 9b and STOPS rather than carrying on" 2 "$rc9"

out2=$( set +e
        export ROUND="$E" DRY_RUN=0 LOG_BASE="$E/run_e.log"
        # shellcheck source=/dev/null
        . "$E/lib_e.sh" 2>/dev/null
        LOG="$E/run_e.dryrun.log"   # simulate a real run that inherited a dry parent's LOG
        assert_log_is_derived 2>&1 ); rc10=$?
check "case 10 a real run holding a dry-run transcript says so" 1 \
      "$(grep -c 'is a dry-run transcript' <<<"$out2")"
check "case 10b and STOPS too" 2 "$rc10"

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
