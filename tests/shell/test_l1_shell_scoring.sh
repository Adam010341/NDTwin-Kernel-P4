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
echo "=== group D: declared skips -- excused only on a hosted CI runner that lacks the need ==="

# [Co-developed with claude code -- Adam] (2026-09-28) A file in tests/python or tests/shell may
# declare `# NDTWIN_L1_NEEDS: <need>`; the lane probes the need itself and scores the skip
# DECLARED-SKIP -- not a pass, not a failure, listed apart -- only when this machine lacks it AND is
# a hosted CI runner (CI or GITHUB_ACTIONS true). The risk this group stands against is the excuse
# growing: the lab going quiet because it lost a need, a need the machine HAS still excusing, an
# unknown word excusing, an excuse outranking a non-zero exit or a failed count, a partial Python
# skip or a declaration that is not a real comment being taken at its word, or a shell suite
# carrying a red check out through its SKIP line.
declare -F l1_declared_needs >/dev/null && declare -F l1_skip_excuse >/dev/null \
    && declare -F l1_probe_py_plot >/dev/null && declare -F l1_hosted_runner >/dev/null \
    && have_d=yes || have_d=no
check "D0 the driver exposes l1_declared_needs, l1_skip_excuse, l1_probe_py_plot and l1_hosted_runner" \
      "yes" "$have_d"
if [[ "$have_d" == yes ]]; then
    DF="$T/declared"; mkdir -p "$DF"
    printf '"""x"""\n# NDTWIN_L1_NEEDS: ryu\nimport unittest\n' > "$DF/one.py"
    printf '#!/usr/bin/env bash\n#   NDTWIN_L1_NEEDS: py-plot, ryu ryu\necho hi\n' > "$DF/two.sh"
    printf 'x = "NDTWIN_L1_NEEDS: ryu"\n' > "$DF/quoted.py"
    printf '"""A docstring that quotes the form:\n# NDTWIN_L1_NEEDS: ryu\n"""\nimport unittest\n' \
        > "$DF/docstring.py"
    printf 'import unittest  # NDTWIN_L1_NEEDS: ryu\n' > "$DF/aftercode.py"
    printf "cat > \"\$T/f\" <<'EOF'\n# NDTWIN_L1_NEEDS: ryu\nEOF\nread -r x <<<\"\$y\"\n# NDTWIN_L1_NEEDS: py-plot\n" \
        > "$DF/heredoc.sh"
    printf '# nothing declared here\n' > "$DF/none.py"
    printf '# NDTWIN_L1_NEEDS: ryu no-such-need\n' > "$DF/unknown.py"
    printf 'test_a ... skipped "no ryu"\n' > "$DF/py.log"
    printf '  ok       case 6\nSKIP: PY_PLOT is not present\n' > "$DF/sh_clean.log"
    printf '  FAILED   case 6\nSKIP: PY_PLOT is not present\n' > "$DF/sh_red.log"

    check "D1 a declaration on a comment line of its own is read" "ryu" "$(l1_declared_needs "$DF/one.py")"
    check "D2 several needs, comma or space separated, sorted and once each" "py-plot ryu" \
          "$(l1_declared_needs "$DF/two.sh" | tr '\n' ' ' | sed 's/ $//')"
    check "D3 the words inside a string are not a declaration" "" "$(l1_declared_needs "$DF/quoted.py")"
    check "D3b 🔴 a declaration quoted inside a Python docstring is not one" "" \
          "$(l1_declared_needs "$DF/docstring.py")"
    check "D3c a comment after code on the same line is not one" "" "$(l1_declared_needs "$DF/aftercode.py")"
    check "D3d 🔴 a line inside a shell heredoc is not one; the declaration after it is" "py-plot" \
          "$(l1_declared_needs "$DF/heredoc.sh" | tr '\n' ' ' | sed 's/ $//')"

    check "D4 a hosted runner's skip with an excuse is DECLARED-SKIP" "DECLARED-SKIP" \
          "$(l1_lane_verdict 0 5 0 5 ryu 1)"
    check "D4b 🔴 the same skip anywhere else is FAIL-SKIP (a lab that lost the need is red)" "FAIL-SKIP" \
          "$(l1_lane_verdict 0 5 0 5 ryu 0)"
    check "D4c ... and with no hosted flag at all it is FAIL-SKIP too" "FAIL-SKIP" \
          "$(l1_lane_verdict 0 5 0 5 ryu)"
    check "D5 the same skip with no excuse is still FAIL-SKIP" "FAIL-SKIP" "$(l1_lane_verdict 0 5 0 5 '' 1)"
    # rc 1 over a clean count -- a harness that crashed -- so that only the rc can say no here
    check "D6 an excuse never outranks a harness that exited non-zero" "FAIL-RC" \
          "$(l1_lane_verdict 1 5 0 5 ryu 1)"
    check "D6b 🔴 a summary that counts failed checks vetoes the excuse, whatever its lines say" "FAIL-SKIP" \
          "$(l1_lane_verdict 0 12 3 1 ryu 1)"
    check "D7 an excuse with nothing skipped changes nothing" "PASS" "$(l1_lane_verdict 0 5 0 0 ryu 1)"

    L1_NEED_MET=([ryu]=1 [py-plot]=1)
    check "D8 🔴 a machine that HAS the need excuses nothing" "" \
          "$(l1_skip_excuse "$DF/one.py" "$DF/py.log" py 5 5)"
    L1_NEED_MET=([ryu]=0 [py-plot]=1)
    check "D9 a machine that lacks it names what the file declared" "ryu" \
          "$(l1_skip_excuse "$DF/one.py" "$DF/py.log" py 5 5)"
    check "D9b 🔴 a Python file that ran some of its tests is not excused (only a whole-file skip is)" "" \
          "$(l1_skip_excuse "$DF/one.py" "$DF/py.log" py 5 2)"
    check "D10 ... and names only what is missing" "ryu" \
          "$(l1_skip_excuse "$DF/two.sh" "$DF/sh_clean.log" sh 0 1)"
    check "D11 a file that declared nothing has no excuse" "" \
          "$(l1_skip_excuse "$DF/none.py" "$DF/py.log" py 5 5)"
    check "D12 🔴 a need the lane has no probe for excuses nothing, even beside a missing one" "" \
          "$(l1_skip_excuse "$DF/unknown.py" "$DF/py.log" py 5 5)"
    check "D13 🔴 a shell suite that printed a FAILED check before its SKIP is not excused" "" \
          "$(l1_skip_excuse "$DF/two.sh" "$DF/sh_red.log" sh 0 1)"

    # The two machines, end to end through the functions the dispatch calls: the same file, the same
    # log, the same missing need -- and only the hosted runner excuses it.
    check "D23 🔴 lab env (CI, GITHUB_ACTIONS unset) + a missing declared need -> FAIL-SKIP" "FAIL-SKIP" \
          "$(unset CI GITHUB_ACTIONS; l1_lane_verdict 0 5 0 5 \
               "$(l1_skip_excuse "$DF/one.py" "$DF/py.log" py 5 5)" "$(l1_hosted_runner)")"
    check "D24 CI env (CI=true) + a missing declared need -> DECLARED-SKIP" "DECLARED-SKIP" \
          "$(unset GITHUB_ACTIONS; export CI=true; l1_lane_verdict 0 5 0 5 \
               "$(l1_skip_excuse "$DF/one.py" "$DF/py.log" py 5 5)" "$(l1_hosted_runner)")"
    check "D25 l1_hosted_runner: GITHUB_ACTIONS=true yes, CI=false no, neither no" "1 0 0" \
          "$(unset CI; GITHUB_ACTIONS=true l1_hosted_runner) $(unset GITHUB_ACTIONS; CI=false l1_hosted_runner) $(unset CI GITHUB_ACTIONS; l1_hosted_runner)"
    L1_NEED_MET=()
    check "D14 with no probes at all nothing is excused" "" \
          "$(l1_skip_excuse "$DF/one.py" "$DF/py.log" py 5 5)"

    # l1_probe_py_plot asks round.env what the suite asks it, and must not let it mkdir.
    PR="$T/probe-repo"; RD="$PR/doc/audit/2026-08-31_sampling-ceiling-after-merge"; mkdir -p "$RD"
    : > "$T/fake-py-plot"
    printf 'export PY_PLOT="${PY_PLOT:-%s}"\nmkdir -p "%s"\n' "$T/fake-py-plot" "$T/made-by-round-env" \
        > "$RD/round.env"
    check "D15 py-plot is met when round.env's PY_PLOT is on disk" "1" \
          "$(unset PY_PLOT; l1_probe_py_plot "$PR")"
    check "D16 ... and round.env's mkdir did not run" "absent" \
          "$([[ -e "$T/made-by-round-env" ]] && echo present || echo absent)"
    printf 'export PY_PLOT="${PY_PLOT:-%s}"\n' "$T/no-such-python" > "$RD/round.env"
    check "D17 py-plot is missing when it is not" "0" "$(unset PY_PLOT; l1_probe_py_plot "$PR")"
fi

# The driver's own wiring, read from its source (the lane itself builds the kernel).
probed="$(grep -oE '^L1_NEED_MET\[[a-z0-9-]+\]=' "$DRIVER" | sed -E 's/^L1_NEED_MET\[([^]]*)\]=$/\1/' | sort -u)"
check "D18 the lane probes the needs it can excuse (ryu, py-plot)" "py-plot ryu" \
      "$(tr '\n' ' ' <<<"$probed" | sed 's/ $//')"
check "D19 the dispatch hands the lane's own excuse and the hosted flag to the verdict" "yes" \
      "$(grep -qF 'l1_lane_verdict "$rc" "${ran:-0}" "${failed:-0}" "${skipped:-0}" "$excuse" "$L1_HOSTED"' "$DRIVER" \
         && grep -qF 'excuse="$(l1_skip_excuse "$testfile" "$log" "${testfile##*.}" "${ran:-0}" "${skipped:-0}")"' "$DRIVER" \
         && grep -qF 'L1_HOSTED="$(l1_hosted_runner)"' "$DRIVER" \
         && echo yes || echo no)"
check "D20 🔴 the DECLARED-SKIP arm records the file and does NOT count a failure" "records, no failure" \
      "$(awk '$0 ~ /^ *DECLARED-SKIP\)/ { on = 1; next }
             on && /^ *;;/ { exit }
             on && index($0, "FAILURES=$((FAILURES + 1))") { f = 1 }
             on && index($0, "DECLARED_SKIPS+=(") { r = 1 }
             END { printf "%s, %s", (r ? "records" : "records nothing"), (f ? "counts a failure" : "no failure") }' "$DRIVER")"
check "D21 the end of the lane lists every declared skip" "yes" \
      "$(grep -qF 'printf '"'"'  %s\n'"'"' "${DECLARED_SKIPS[@]}"' "$DRIVER" && echo yes || echo no)"
check "D26 🔴 the FAIL-SKIP arm names a declared need that is missing (the lab is told what it lost)" "yes" \
      "$(awk '$0 ~ /^ *FAIL-SKIP\)/ { on = 1; next }
             on && /^ *;;/ { exit }
             on && index($0, "needs ${excuse}") { n = 1 }
             END { print (n ? "yes" : "no") }' "$DRIVER")"
# Every declaration in the corpus names a need the lane probes: an unknown word there would make
# that file FAIL-SKIP on a machine without the need, which is loud, but the typo is cheaper here.
unknown=""
for f in "$SHELL_TESTS_DIR"/test_*.sh "$SHELL_TESTS_DIR"/../python/test_*.py; do
    [[ -f "$f" ]] || continue
    while IFS= read -r need; do
        grep -qxF -- "$need" <<<"$probed" || unknown+="$(basename "$f"):$need "
    done < <(l1_declared_needs "$f" 2>/dev/null)
done
check "D22 every NDTWIN_L1_NEEDS in tests/shell and tests/python is one the lane probes" "" "$unknown"

echo
echo "=== group C: the corpus -- every suite in tests/shell prints a form this scorer reads ==="

# [Co-developed with claude code -- Adam] 🔴 REWRITTEN 2026-09-27. The first version took the LAST
# `echo "..."` in each suite's source as its summary. That is not what the lane reads: shell_summary
# reads the whole LOG, and the last summary in it wins -- so an echo placed after the summary in the
# source (a trailer, a heredoc line, a message in a function defined below), or a summary written
# with printf, made that heuristic red on suites the lane scores correctly. 12 suites, red since
# they changed shape; every one of the 12 was run for real (inside the guard, 09-27) and the lane's
# own shell_summary + l1_lane_verdict read each run exactly: this side was the wrong one.
#
# What the lane needs of a suite is that its GREEN run prints a summary shell_summary reads. So:
#   (1) every `echo` and `printf` in the source is rendered -- EVERY one on a line, not only the
#       first (a line is cut into its commands at unquoted ; ;; && || | &, outside quotes, $( ) and
#       $(( )); a print is a command whose first word, after a function head (`f() {`, `f(){`,
#       `function f {`), if/then/else/do/{/(, `case X in` and a case pattern (`0)`, `*)`), is echo
#       or printf) -- a printf's %d/%s filled from its own arguments, a counter whose name says
#       fail/bad as 0 and every other as 9 ($((PASS + FAIL)) is 9 + 0) -- and scored by the lane's
#       own shell_summary; at least one must score a non-zero count. Where it sits no longer
#       matters: a printf summary, or an echo that comes after it in the source, is fine. A print
#       whose stdout goes to a FILE (`> f`, `>> f`, `&> f`) is not rendered: the lane runs
#       `bash suite >log 2>&1`, so it never reaches the log (`>&2` does, and is rendered).
#   (2) the LAST one that scores (in source order; a print inside a function counts at the last
#       call of that function that is not itself on a failure path) must be on the path that runs
#       to the end:
#       (2a) no `exit <non-zero>` CERTAIN to run after it on ITS OWN LINE -- the one-line failure
#            branch, `if (( FAIL > 0 )); then echo "Ran ..."; exit 1; fi`, or
#            `|| { echo "Ran 1 checks, 1 failed"; exit 1; }`. Certain means reached through ; or &,
#            through && after a command that cannot fail (a print, tee), through a pipe into
#            tee/sed/..., or past the end of the block the print is in (} fi done esac )). NOT
#            certain: an exit behind && after a test (`; (( FAIL )) && exit 1` -- that summary is
#            the green one), behind ||, inside an if/while/for/case opened after the print, or in
#            another branch (else, elif, the next ;; pattern). A conditional exit that does not
#            fail (`[[ $FAIL -eq 0 ]] && exit 0`) is a way to the end: not a failure path.
#            For a print inside a function, (2a) is also read on the line of every CALL
#            (`summary; exit 1` -- the opus judge's NOTE A on 1d5180ce) and in the function's own
#            body (a later line of it that starts with `exit <non-zero>`): a function whose every
#            call, or whose body, ends in a failure prints only on a failure path.
#            Such a print is on a failure path and is never "the last one"; if every scoring print
#            is one, the suite is red for it.
#       (2b) no bare `exit <non-zero>` at the start of any LATER line.
#       Together they keep what the old last-echo check caught -- a suite that still prints its
#       failure-path summary but lost its green one would read NO-TESTS-RAN at run time -- in both
#       the multi-line and the one-line shape, without the old check's false alarms. (2a) came
#       with the opus judge's B1 on d2a9d641 (09-27); its call-line, pipe, block-end, conditional
#       and case readings with the same judge's NOTEs A, B, F, G and H on 1d5180ce (09-27). Group R
#       holds each reading on a fixture of its own; mutate_l1_shell_scoring.sh breaks each one.
# 🔴 KNOWN LIMITATIONS, not fixed -- each a shape the corpus does not have today (M0 is green):
#   - a summary followed by a bare `exit` or `exit $FAIL` -- the SELFTEST_INNER branch of
#     test_mutate_gate_dead_mutant.sh (`echo "Ran ..."`, then `(( FAIL == 0 )); exit`) -- is a
#     GREEN-path form this static rule cannot tell from a failure branch: whether it runs to the end
#     depends on a value, not on the text. If the suite's final summary is lost, group C still reads
#     that branch's summary as the green one.
#   - (2b) reads ANY later line that starts with `exit <non-zero>`, including one inside an
#     `if (( FAIL ))` after the green summary: a false red, never a false green. So does a function
#     body's later `exit <non-zero>`.
#   - heredoc bodies are read as code (NOTE J): a `echo "Ran ..."` line inside a heredoc renders as a
#     print of the suite. No heredoc in the corpus holds one. A regex that skipped heredocs is worse:
#     test_redirection_order.sh has a `<<` inside a quoted check name, and skipping from there
#     swallows the suite's real summary (09-27, read).
#   - a function's extent is found by counting { and } per line (N4): braces inside strings and
#     heredoc bodies count too. In the corpus this moves the extent of functions in
#     test_live_p1_common.sh and test_ndtwin_lab_heartbeat.sh; both read green.
#   - an `exit` inside a subshell, `( echo "Ran ..."; exit 1 )`, is read as the script's exit.
#   - a call of the function that is not at the start of a line (`|| summary`, `trap summary EXIT`,
#     a call from another function) is not seen: its prints count at the function's own line.
# 🔴 FAIL CLOSED (the judge's N4): a $(( )) the renderer cannot evaluate (09, an empty $(( )), **)
# stops render_prints with a message and a non-zero status, and so does a renderer that runs past
# 30 s; group C then reports "instrument failed" for that suite, never a zero or half its prints.
# A `/` is not in the renderer's alphabet at all: a $(( )) holding one renders as 9, silently, and is
# never evaluated -- so a division by zero is NOT an instrument failure (the judge's NOTE E).
# (A print whose quotes do not close on its own line -- a multi-line string -- is not a one-line
# print and is skipped, as before.)
# Reading source, not running it: this file is in the corpus.
render_prints() {   # render_prints <suite> -> "<effective line><TAB><0, or the failure rule><TAB><text>" per rendered line
    timeout 30 python3 - "$1" <<'PYR'
import re, shlex, sys

class InstrumentError(Exception):
    pass

lines = open(sys.argv[1], errors="replace").read().split("\n")
# A print inside a function body happens where the function is CALLED, not where it is written:
# `done_() { echo "Ran ..."; ...; exit $?; }` near the top, `done_` as the file's last line
# (test_run_layers_*). Its calls are the lines that start with its name, outside any function.
owner, depth, func_of = None, 0, {}
for n, line in enumerate(lines, 1):
    m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", line)
    if owner is None and m:
        owner, depth = m.group(1), 0
    if owner is not None:
        func_of[n] = owner
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            owner = None
_calls, _call_fails = {}, {}
def call_lines(f):
    if f not in _calls:
        _calls[f] = [i for i, l in enumerate(lines, 1)
                     if i not in func_of and re.match(r"^\s*" + re.escape(f) + r"(\s|;|$)", l)]
    return _calls[f]
def call_fails(c):   # (2a) read on a call's own line: the call is its first command
    if c not in _call_fails:
        _call_fails[c] = failure_after(commands(lines[c - 1]), 0)
    return _call_fails[c]
def body_exits_after(n):   # a later line of the same function body that starts with exit <non-zero>
    f, m = func_of.get(n), n + 1
    while func_of.get(m) == f:
        if re.match(r"^\s*exit\s+[1-9]", lines[m - 1]):
            return True
        m += 1
    return False
def val(expr):
    return "0" if re.search(r"fail|bad", expr, re.I) else "9"
def arith(expr):   # $(( PASS + FAIL )) -> each counter by its name, then the sum: 9 + 0 = 9
    if "**" in expr:
        raise InstrumentError("'**' in $((%s))" % expr)
    e = re.sub(r"\$?\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda m: val(m.group(1)), expr)
    if not re.fullmatch(r"[0-9+\-* ()]+", e):
        return "9"
    try:
        return str(eval(e, {"__builtins__": {}}))
    except Exception as x:
        raise InstrumentError("cannot evaluate $((%s)) as %r: %s" % (expr, e, x))
def expand(text):
    text = re.sub(r"\$\(\(([^)]*)\)\)", lambda m: arith(m.group(1)), text)
    text = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}", lambda m: val(m.group(1)), text)
    return re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)", lambda m: val(m.group(1)), text)
def commands(line):   # -> [(operator before it, its text)], cut at unquoted ; ;; && || | &
    out, cur, op, stack, i = [], [], "", [], 0
    while i < len(line):
        c, top = line[i], (stack[-1] if stack else "")
        if top == "sq":
            cur.append(c); i += 1
            if c == "'":
                stack.pop()
            continue
        if c == "\\" and i + 1 < len(line):
            cur.append(line[i:i + 2]); i += 2; continue
        if c == "'" and top != "dq":
            stack.append("sq"); cur.append(c); i += 1; continue
        if c == '"':
            if top == "dq":
                stack.pop()
            else:
                stack.append("dq")
            cur.append(c); i += 1; continue
        if line.startswith("$((", i):
            stack.append("ar"); cur.append("$(("); i += 3; continue
        if top == "ar" and line.startswith("))", i):
            stack.pop(); cur.append("))"); i += 2; continue
        if line.startswith("$(", i):
            stack.append("cs"); cur.append("$("); i += 2; continue
        if c == "(" and top in ("cs", "pa"):
            stack.append("pa"); cur.append(c); i += 1; continue
        if c == ")" and top in ("cs", "pa"):
            stack.pop(); cur.append(c); i += 1; continue
        if c == "`":
            if top == "bt":
                stack.pop()
            else:
                stack.append("bt")
            cur.append(c); i += 1; continue
        if stack:
            cur.append(c); i += 1; continue
        if c == "#" and (not cur or cur[-1][-1:].isspace()):
            break
        two = line[i:i + 2]
        if two in ("&&", "||", ";;"):
            out.append((op, "".join(cur))); cur, op = [], two; i += 2; continue
        if c == ";" or c == "|" and two != "|&" or \
           c == "&" and line[i - 1:i] not in ("<", ">") and line[i + 1:i + 2] != ">":
            out.append((op, "".join(cur))); cur, op = [], c; i += 1; continue
        cur.append(c); i += 1
    out.append((op, "".join(cur)))
    return out
def words_of(text):   # its words, up to the first redirection; None when its quotes do not close
    try:
        lx = shlex.shlex(text, posix=True, punctuation_chars="<>")
        lx.whitespace_split = True
        words = []
        for w in lx:
            if w and set(w) <= set("<>"):
                break
            words.append(w)
        return words
    except ValueError:
        return None
LEAD = ("if", "then", "else", "elif", "do", "while", "until", "!", "{", "time")
def strip_head(w):   # the command's own words: a function head, keywords, `(`, a case pattern off the front
    w = list(w or [])
    if w and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\(\)\{?", w[0]):        # f() {   f(){
        w = (["{"] if w[0].endswith("{") else []) + w[1:]
    elif len(w) > 1 and w[1] in ("()", "(){"):                             # f () {
        w = (["{"] if w[1].endswith("{") else []) + w[2:]
    elif len(w) > 1 and w[0] == "function":                                # function f {
        w = w[2:]
    if len(w) > 3 and w[0] == "case" and w[2] == "in":                     # case X in 0) ...
        w = w[3:]
    while w:
        h = w[0]
        if h in LEAD or h == "(":
            w.pop(0)
        elif h.startswith("("):
            w[0] = h.lstrip("(")
        elif re.fullmatch(r"[^$`(){}\"']*\)", h):                          # 0)  *)  --help)
            w.pop(0)
        else:
            break
    return w
def print_words(text):   # the words of a print command (echo/printf first), or None
    w = strip_head(words_of(text))
    return w if w and w[0] in ("echo", "printf") else None
def stdout_away(text):   # its stdout goes to a file -- never to the lane's log (`bash suite >log 2>&1`)
    t = re.sub(r"'[^']*'|\"(?:\\.|[^\"\\])*\"", "Q", text)
    for m in re.finditer(r"(\d*)(&?)>>?\s*(\S+)", t):
        fd, _amp, target = m.groups()
        if fd not in ("", "1"):
            continue                                  # 2> ...: not its stdout
        if target.startswith("&") or target in ("/dev/stdout", "/dev/stderr"):
            continue                                  # >&2: still the lane's log
        return True
    return False
def exit_kind(text):   # "fail" exit <literal non-zero>; "other" exit 0, bare exit, exit $X; None
    w = strip_head(words_of(text))
    if not w or w[0] != "exit":
        return None
    return "fail" if len(w) > 1 and re.fullmatch(r"[1-9][0-9]*", w[1]) else "other"
OPENERS = ("if", "while", "until", "for", "case", "select")
CLOSERS = ("fi", "done", "esac")
SURE = ("echo", "printf", "tee", "true", ":")
def failure_after(cmds, k):   # (2a): an exit <non-zero> CERTAIN to run after command k of this line
    ok, cond, nest = True, False, 0      # ok: the last command cannot have failed (k is a print or a call)
    for op, text in cmds[k + 1:]:
        raw = words_of(text) or []
        head = raw[0] if raw else ""
        if nest == 0 and (op == ";;" or head in ("else", "elif")):
            return False                     # another branch: not on this print's path
        if op in (";", "&", ";;"):
            cond = False
        elif op == "&&":
            cond = cond or not ok
        elif op == "||":
            if ok and not cond:
                continue                     # never runs, and the list still succeeded
            cond = True
        elif op == "|":                      # the same pipeline: an exit here ends a subshell
            w = strip_head(raw)
            ok = bool(w) and w[0] in SURE + ("cat", "sed")
            nest += head in OPENERS              # `| while read ...; do`: its body is not this path
            continue
        if head in OPENERS:
            nest, ok = nest + 1, False
            continue
        if head in CLOSERS or head in ("}", ")") or head.startswith(")"):
            if head in CLOSERS and nest > 0:
                nest, ok = nest - 1, False
            continue                         # the print's own block ends: what follows still runs
        kind = exit_kind(text)
        if kind is not None:
            if nest == 0 and not cond:
                return kind == "fail"        # it runs: the script ends here
            if kind == "other":
                return False                 # it may run: a way to the end that does not fail
            continue                         # a conditional failure exit: go on
        w = strip_head(raw)
        ok = bool(w) and w[0] in SURE
    return False
def where(n, cmds, k):   # -> (effective line, "0" or the rule that puts it on a failure path)
    here = failure_after(cmds, k)
    f = func_of.get(n)
    if f is None:
        return n, ("2a" if here else "0")
    body = not here and body_exits_after(n)
    calls = call_lines(f)
    if here or body:
        return (calls[-1] if calls else n), ("2a" if here else "body")
    ok = [c for c in calls if not call_fails(c)]
    if ok or not calls:
        return (ok[-1] if ok else n), "0"
    return calls[-1], "call"
rendered = []
for n, line in enumerate(lines, 1):
    cmds = commands(line)
    for k, (op, text) in enumerate(cmds):
        w = print_words(text)
        if w is None or stdout_away(text):
            continue
        args = [x for x in w[1:] if not (w[0] == "echo" and x in ("-e", "-n"))]
        if not args:
            continue
        try:
            if w[0] == "echo":
                outs = [expand(" ".join(args))]
            else:
                it = iter([expand(a) for a in args[1:]])
                fmt = args[0].replace("%%", "%")
                outs = re.sub(r"%[-0-9.]*[dsi]", lambda _m: next(it, "9"), fmt).replace("\\n", "\n").split("\n")
        except InstrumentError as x:
            sys.stderr.write("render_prints: line %d: %s\n" % (n, x))
            sys.exit(3)
        eff, rule = where(n, cmds, k)
        for o in outs:
            if o.strip():
                rendered.append("%d\t%s\t%s" % (eff, rule, o))
sys.stdout.write("".join(r + "\n" for r in rendered))
PYR
}
# corpus_verdict <suite> -> "nonzero" when its green path prints a summary the lane reads; else why not
corpus_verdict() {
    local rout rrc last=0 fpline=0 fprule="" n rule line bare
    rout="$(render_prints "$1" 2>"$T/render.err")"; rrc=$?
    if (( rrc != 0 )); then
        echo "instrument failed: render_prints rc $rrc -- $(head -1 "$T/render.err")"; return
    fi
    while IFS=$'\t' read -r n rule line; do
        [[ -n "$line" && "$(summary_of "$line" | cut -d' ' -f1)" -gt 0 ]] || continue
        # the LAST failure-path summary is the one with the greatest effective line, as for `last`
        # below -- not the last one read: a function's print is read at its definition and counts
        # at its call (queued2, 09-27: test_ndt_ovs_topo_script.sh was named for its line-51
        # `|| { ...; exit 1; }` while its `summary; exit 1` call at line 70 is the later one)
        if [[ "$rule" != 0 ]]; then
            (( n >= fpline )) && { fpline="$n"; fprule="$rule"; }
            continue
        fi
        (( n >= last )) && last="$n"
    done <<<"$rout"
    if (( last == 0 && fpline > 0 )); then
        case "$fprule" in
            2a)   echo "only on a failure path: every summary it prints has an exit <non-zero> after it on the same line (the last at line $fpline)" ;;
            call) echo "only on a failure path: its last summary (line $fpline) is printed by a function every call of which has an exit <non-zero> after the call on the same line" ;;
            body) echo "only on a failure path: its last summary (line $fpline) is printed by a function that exits <non-zero> later in its body" ;;
            *)    echo "instrument failed: render_prints named no rule we know ($fprule)" ;;
        esac
    elif (( last == 0 )); then
        echo "zero: no echo or printf in it renders to a summary"
    else
        bare="$(awk -v n="$last" 'NR > n && /^[[:space:]]*exit[[:space:]]+[1-9]/ {print NR; exit}' "$1")"
        if [[ -z "$bare" ]]; then echo nonzero
        else echo "only on a failure path: its last summary (line $last) is followed by a bare exit at line $bare"; fi
    fi
}

echo
echo "=== group R: group C's readings, one fixture each (tests/shell/fixtures/l1_shell_scoring/) ==="

# [Co-developed with claude code -- Adam] (09-27) every reading group C makes, held on a file of its
# own, so the rule is pinned and not only the corpus it happens to meet today: each fixture is a
# minimal suite text (read, never run; README.md there). The ones marked * were read the other way
# by b005bf50's group C -- a false red (B, F) or a vacuous green (A, G, H) -- the rest pin a reading
# that did not change, so that mutate_l1_shell_scoring.sh can break it by name (the judge's NOTE I).
RFIX="$SHELL_TESTS_DIR/fixtures/l1_shell_scoring"   # not $HERE: sourcing the driver replaced it
FP="only on a failure path:"
SAME="every summary it prints has an exit <non-zero> after it on the same line"
rcheck() { check "R$1" "$3" "$(corpus_verdict "$RFIX/$2")"; }
rcheck "1 * a function summary whose every call is \`summary; exit 1\` is on a failure path (A)" \
       r01_call_line_exit.sh \
       "$FP its last summary (line 5) is printed by a function every call of which has an exit <non-zero> after the call on the same line"
rcheck "2   ... and a bare \`summary\` call after it is its green path" r02_call_line_green.sh nonzero
rcheck "3 * a function that exits 1 later in its body prints on a failure path (A)" \
       r03_function_body_exit.sh \
       "$FP its last summary (line 7) is printed by a function that exits <non-zero> later in its body"
rcheck "4 * \`echo ...; (( FAIL )) && exit 1\` is the green summary: the exit is conditional (B)" \
       r04_conditional_exit_after.sh nonzero
rcheck "5 * \`echo ...; [[ \$FAIL -eq 0 ]] && exit 0; exit 1\` is the green summary: a way out that does not fail (B)" \
       r05_conditional_exit_zero.sh nonzero
rcheck "6   \`echo ... || exit 1\`: the exit after || never runs (I)" r06_or_exit.sh nonzero
rcheck "7   \`echo ... && exit 1\` in a failure branch: && after a print is certain (I)" \
       r07_and_exit.sh "$FP $SAME (the last at line 3)"
rcheck "8 * \`summary(){ echo ...; }\` -- no space before { -- is a print (F)" r08_function_no_space.sh nonzero
rcheck "9 * a print behind a case pattern, \`0) echo ... ;;\`, is a print (F)" r09_case_branches.sh nonzero
rcheck "10 * a summary written to a FILE never reaches the lane's log (G)" \
       r10_redirected_to_file.sh "zero: no echo or printf in it renders to a summary"
rcheck "11   ... and one written to stderr (>&2) does (G)" r11_redirected_to_stderr.sh nonzero
rcheck "12 * \`echo ... | tee -a \$LOG; exit 1\`: the exit after a pipeline is certain (G)" \
       r12_piped_then_exit.sh "$FP $SAME (the last at line 4)"
rcheck "13 * \`{ echo ...; }; exit 1\`: the end of a block does not stop the reading (H)" \
       r13_group_then_exit.sh "$FP $SAME (the last at line 3)"
rcheck "14   \`then echo ...; else exit 1; fi\`: the else branch is not the print's path (H)" \
       r14_else_branch.sh nonzero
rcheck "15 * \`case ... in 0) echo ... ;; *) exit 1 ;; esac\`: the next pattern is not the print's path (F)" \
       r15_case_other_branch.sh nonzero
rcheck "16   \`echo ...; if (( FAIL )); then exit 1; fi\`: an exit inside a later if is conditional (B)" \
       r16_exit_in_later_if.sh nonzero
rcheck "17 * the reason named is the LAST failure path in line order: a call at line 6 after a 2a at line 4 (A)" \
       r17_last_failure_is_the_call.sh \
       "$FP its last summary (line 6) is printed by a function every call of which has an exit <non-zero> after the call on the same line"

echo
echo "=== group C: the corpus ==="
for suite in "$SHELL_TESTS_DIR"/test_*.sh; do
    check "C  $(basename "$suite") prints a summary this scorer reads on its green path" "nonzero" \
          "$(corpus_verdict "$suite")"
done

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
