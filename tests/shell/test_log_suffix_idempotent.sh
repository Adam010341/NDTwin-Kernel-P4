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
count_appends() {
    local f n total=0
    for f in "$@"; do
        n=$(sed 's/#.*//' "$f" | grep -c 'LOG="\${LOG%\.log}')
        total=$((total + n))
    done
    printf '%s\n' "$total"
}
check "case 7  no script appends a suffix to the inherited LOG" 0 \
      "$(count_appends "$E/lib_e.sh" "$E/run_e.sh" "$E/gates_e.sh" "$F/run_f5.sh")"
# and the stripper must not simply blank everything
check "case 7b the comment stripper still sees real code" 1 \
      "$(printf 'LOG="${LOG%%.log}.x.log"   # trailing comment\n# LOG="${LOG%%.log}.y.log"\n' \
         | sed 's/#.*//' | grep -c 'LOG="\${LOG%\.log}')"

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
