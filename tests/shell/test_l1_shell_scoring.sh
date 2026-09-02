#!/usr/bin/env bash
#
# Tests for how l1_unit_tests.sh scores the kernel-side shell suites.
#
# [Co-developed with claude code -- Adam]
#
# The defect these encode was recorded on 2026-09-02 in
# doc/audit/2026-09-02_live-round/raw/B15_l1_six_problem_groups.log and B16_..._diagnosis.log.
# l1_unit_tests.sh counted every kernel-side test with unittest's line:
#
#     ran=$(grep -oE '^Ran [0-9]+' "$log" | tail -1 | grep -oE '[0-9]+')
#
# tests/shell does not use unittest and has three summary forms; only one of them begins with
# "Ran". Five suites -- test_cell_gate_suspect_wiring, test_ep4_gate_and_abort_evidence,
# test_gate_exit_code_not_tee, test_harness_instruments, test_log_suffix_idempotent -- exited 0
# with every check ok, were scored ran=0, and were each counted as a problem group. L1 was red
# on a green tree and local_ci.sh went red with it (raw/B18), so the project's own CI signal
# said "broken" about code that was fine.
#
# 🔴 The opposite error is worse and case group Z is what stops it. `Ran N` is how this repo
# catches a suite whose cases sit under a guard that stopped matching: it runs zero of them and
# still exits 0. A scorer that answered "passed" for a log it could not read, or for a summary
# whose numbers are zero, would turn every such suite green forever. Every fixture in group Z
# asserts ran=0 for a log that exits 0, and l1_lane_verdict turns ran=0 into NO-TESTS-RAN, which
# the driver counts as a failure.
#
# Group V drives l1_lane_verdict directly, so the branch order (rc, then skips, then zero, then
# failed checks) is asserted rather than assumed. Group C is the corpus check: every suite in
# tests/shell must actually print something this scorer recognises, which is the thing that was
# false before -- and it reads the suites' source rather than running them, because this file
# lives in that same directory and running the corpus would run itself.
#
# No fabric, no lab claim, no build: NDTWIN_L1_LIB_ONLY=1 stops l1_unit_tests.sh above its
# first side effect, and every fixture is a file in a mktemp sandbox.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/../../tools/test_workflow/l1_unit_tests.sh"
SHELL_TESTS_DIR="$HERE"

[[ -f "$DRIVER" ]] || { echo "  FAILED   no driver at $DRIVER"; echo "Ran 1 checks, 1 failed"; exit 1; }

# Source the scorer without running the lane, BEFORE this file defines anything of its own: the
# driver sets HERE, PASS-adjacent names and the colour variables, and a test whose counters were
# quietly overwritten by the thing it is measuring would report about nothing. If the seam is
# gone this file has nothing to test, which is a failure and not a skip -- a missing instrument
# must not read as a quiet pass.
# shellcheck source=/dev/null
if ! NDTWIN_L1_LIB_ONLY=1 source "$DRIVER" >/dev/null 2>&1 \
        || ! declare -F shell_summary >/dev/null || ! declare -F l1_lane_verdict >/dev/null; then
    echo "  FAILED   l1_unit_tests.sh does not expose shell_summary/l1_lane_verdict under" \
         "NDTWIN_L1_LIB_ONLY=1"
    echo "Ran 1 checks, 1 failed"
    exit 1
fi

PASS=0
FAIL=0

check() {
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

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# summary_of <fixture-text> -- run the scorer over a log holding exactly that text.
summary_of() {
    printf '%s\n' "$1" > "$T/fixture.log"
    shell_summary "$T/fixture.log"
}

echo
echo "=== group A: the 'Ran N checks' form, which is the only one the old scorer knew ==="

check "A1 'Ran 60 checks, all passed' -> 60 ran, 0 failed" "60 0" \
      "$(summary_of 'Ran 60 checks, all passed')"
check "A2 'Ran 6 checks, 0 failed' -> the second number is the failed count, not the total" \
      "6 0" "$(summary_of 'Ran 6 checks, 0 failed')"
check "A3 'Ran 12 checks, 3 failed' -> 12 ran, 3 failed" "12 3" \
      "$(summary_of 'Ran 12 checks, 3 failed')"

echo
echo "=== group B: the two forms the old scorer scored as zero (the 09-02 defect) ==="

# Verbatim from the five suites: two print the line flush left, three indent it by two spaces,
# and test_harness_instruments prints a banner. These strings are the defect.
check "B1 '12 passed, 0 failed' (test_cell_gate_suspect_wiring) -> 12 ran, 0 failed" "12 0" \
      "$(summary_of '12 passed, 0 failed')"
check "B2 '  12 passed, 0 failed' indented (test_ep4_gate_and_abort_evidence) -> 12 ran" "12 0" \
      "$(summary_of '  12 passed, 0 failed')"
check "B3 '  7 passed, 0 failed' (test_gate_exit_code_not_tee) -> 7 ran" "7 0" \
      "$(summary_of '  7 passed, 0 failed')"
check "B4 '  15 passed, 0 failed' (test_log_suffix_idempotent) -> 15 ran" "15 0" \
      "$(summary_of '  15 passed, 0 failed')"
check "B5 the banner form (test_harness_instruments) -> 34 ran, 0 failed" "34 0" \
      "$(summary_of '===== 34 check(s): 34 ok, 0 FAILED =====')"
check "B6 'N passed, M failed' with M>0 carries the failed count through" "12 4" \
      "$(summary_of '8 passed, 4 failed')"
check "B7 the banner's third number is the failed count" "34 4" \
      "$(summary_of '===== 34 check(s): 30 ok, 4 FAILED =====')"
check "B8 a real transcript, ok lines then the summary last" "12 0" \
      "$(summary_of '  ok       case 1c suspect=true -> the cell is listed
  ok       case 2a suspect=false -> returns 0

12 passed, 0 failed')"

echo
echo "=== group Z: zero stays zero -- 'nothing ran' must not become 'passed' ==="

check "Z1 a log with no summary at all is 0 ran, never a pass" "0 0" \
      "$(summary_of '  ok       something happened
  ok       something else happened')"
check "Z2 an empty log is 0 ran" "0 0" "$(summary_of '')"
check "Z3 'Ran 0 checks, all passed' -> 0 ran (the __main__-guard shape, shell edition)" "0 0" \
      "$(summary_of 'Ran 0 checks, all passed')"
check "Z4 '0 passed, 0 failed' -> 0 ran, so a suite that collected nothing cannot pass" "0 0" \
      "$(summary_of '0 passed, 0 failed')"
check "Z5 '===== 0 check(s): 0 ok, 0 FAILED =====' -> 0 ran" "0 0" \
      "$(summary_of '===== 0 check(s): 0 ok, 0 FAILED =====')"
check "Z6 a check whose NAME quotes a summary is output, not a summary" "0 0" \
      "$(summary_of '  ok       case 4  prints 12 passed, 0 failed when green
  ok       case 5  and ===== 3 check(s): 3 ok, 0 FAILED ===== otherwise')"
check "Z7 the LAST summary wins, as tail -1 did (5 passed + 1 failed = 6 ran)" "6 1" \
      "$(summary_of '9 passed, 0 failed
Ran 6 checks, 1 failed
5 passed, 1 failed')"

echo
echo "=== group V: the verdict branch order, so ran=0 keeps its own answer ==="

check "V1 rc!=0 is FAIL-RC even with a green summary" "FAIL-RC" \
      "$(l1_lane_verdict 1 12 0 0)"
check "V2 a skip outranks the zero count, so a skipping suite is not 'no tests ran'" "FAIL-SKIP" \
      "$(l1_lane_verdict 0 0 0 1)"
check "V3 rc=0 and nothing collected is NO-TESTS-RAN, NOT a pass" "NO-TESTS-RAN" \
      "$(l1_lane_verdict 0 0 0 0)"
check "V4 rc=0 over a summary that names failures is FAIL-CHECKS" "FAIL-CHECKS" \
      "$(l1_lane_verdict 0 12 4 0)"
check "V5 rc=0, checks ran, none failed, none skipped is the only PASS" "PASS" \
      "$(l1_lane_verdict 0 12 0 0)"
check "V6 NO-TESTS-RAN and PASS are different tokens (the distinction is the point)" "different" \
      "$( [[ "$(l1_lane_verdict 0 0 0 0)" != "$(l1_lane_verdict 0 1 0 0)" ]] \
             && echo different || echo same )"

echo
echo "=== group W: the driver still counts every non-PASS verdict as a failure ==="

# Read from the driver's source rather than re-running the lane: the lane builds the kernel.
# Each arm must be followed by a FAILURES increment; a verdict that prints red and counts
# nothing is the same defect wearing a different colour.
for verdict in FAIL-RC FAIL-SKIP NO-TESTS-RAN FAIL-CHECKS; do
    check "W  the $verdict arm increments FAILURES" "yes" \
          "$(awk -v v="$verdict" '
                $0 ~ "^ *"v"\\)" { inarm = 1; next }
                inarm && index($0, "FAILURES=$((FAILURES + 1))") { hit = 1 }
                inarm && /^ *;;/ { inarm = 0 }
                END { exit !hit }' "$DRIVER" && echo yes || echo no)"
done

echo
echo "=== group X: the scorer is WIRED IN, and the Python side keeps unittest's line ==="

# A correct scorer nobody calls is the 09-02 defect with extra steps, so read the driver's own
# dispatch. The .py arm must keep `^Ran [0-9]+` -- that is how a Python file whose cases sit
# under a __main__ guard is caught, and it is not this fix's business to touch it -- and the
# shell arm must not be scored with unittest's vocabulary at all.
# The region between the two counters and the verdict call that consumes them. Anchored there
# and not on `== *.py`, which the lane also uses further up to pick an interpreter -- matching
# that one would read the wrong block and every check below would pass on an empty string.
dispatch="$(awk '/^[[:space:]]*ran=0; failed=0[[:space:]]*$/ { on = 1 }
                 on && /l1_lane_verdict/ { exit } on { print }' "$DRIVER")"
py_arm="$(awk '/== \*\.py \]\]; then/ { on = 1; next } on && /^ *else$/ { exit } on { print }' \
          <<<"$dispatch")"
sh_arm="$(awk '/^ *else$/ { on = 1; next } on && /^ *fi$/ { exit } on { print }' <<<"$dispatch")"

# X0 first, because every check below asks "does this block NOT contain X" of a block that may
# not have been found at all, and an empty string satisfies all of them.
check "X0 the scoring dispatch was located, so X1-X4 are not asking about an empty string" \
      "both found" \
      "$( [[ -n "$py_arm" && -n "$sh_arm" ]] && echo "both found" || echo "py=[$py_arm] sh=[$sh_arm]" )"
check "X1 the shell arm scores with shell_summary" "yes" \
      "$( grep -q 'shell_summary "\$log"' <<<"$sh_arm" && echo yes || echo no )"
check "X2 the shell arm does NOT count with unittest's '^Ran N'" "yes" \
      "$( grep -q "\^Ran \[0-9\]" <<<"$sh_arm" && echo no || echo yes )"
check "X3 the Python arm still counts with unittest's '^Ran N' (the __main__-guard catch)" "yes" \
      "$( grep -q "grep -oE '\^Ran \[0-9\]+'" <<<"$py_arm" && echo yes || echo no )"
check "X4 the shell arm binds both numbers the verdict needs" "yes" \
      "$( grep -q 'read -r ran failed' <<<"$sh_arm" && echo yes || echo no )"

echo
echo "=== group C: the corpus -- every suite in tests/shell prints a form this scorer reads ==="

# The check that would have caught the defect on the day it landed. Every suite in this
# directory ends the same way -- print the summary, then let `[[ $FAIL -eq 0 ]]` be the exit
# status -- so the LAST echo in the file is the green-path summary. Render it with plausible
# numbers and require a non-zero recognised count. Reading source, not running it: this file is
# in the corpus and running the corpus would run itself.
for suite in "$SHELL_TESTS_DIR"/test_*.sh; do
    name="$(basename "$suite")"
    line="$(grep -hoE '^ *echo "[^"]*"' "$suite" | tail -1 \
            | sed -e 's/^ *echo "//' -e 's/"$//' \
                  -e 's/\$((PASS *+ *FAIL))/9/g' -e 's/\$((PASS+FAIL))/9/g' \
                  -e 's/\$PASS/9/g' -e 's/\$FAIL/0/g')"
    if [[ -z "$line" ]]; then
        check "C  $name ends in an echo this test can read" "found" "not found"
        continue
    fi
    check "C  $name's last line scores non-zero (it is '$line')" "nonzero" \
          "$( [[ "$(summary_of "$line" | cut -d' ' -f1)" -gt 0 ]] && echo nonzero || echo zero )"
done

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
