#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_l1_shell_scoring.sh.
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen red is not a test. Mutation 1 is the point of the whole file:
# it puts back the pre-fix scorer VERBATIM -- the `grep -oE '^Ran [0-9]+'` that
# doc/audit/2026-09-02_live-round/raw/B16 diagnosed at l1_unit_tests.sh:319 -- and asserts the
# suite goes red for it. If that one ever SURVIVES, the suite is not testing the defect it was
# written for.
#
# The second half is the more important half. The cheap way to "fix" this scorer is to stop
# counting and believe the exit code, and that would be a worse bug than the one being fixed:
# `Ran N` is how this repo catches a suite whose cases sit under a guard that stopped matching,
# which runs zero of them and still exits 0. Mutations 7-10 are exactly those cheap fixes --
# ran==0 scored as a pass, the zero check deleted, its arm no longer counted -- and each must
# be killed.
#
# Mutations are applied to a COPY in a mktemp sandbox laid out with the same relative shape,
# because the suite resolves the driver as $HERE/../../tools/test_workflow/l1_unit_tests.sh.
# The files in the worktree are never written to. No build, no fabric, no lab claim.
#
# Run:  bash tests/shell/mutate_l1_shell_scoring.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DRIVER_REL="tools/test_workflow/l1_unit_tests.sh"
SUITE_REL="tests/shell/test_l1_shell_scoring.sh"
# Named as a variable so check_gate_anchors.py can resolve the last mutation's anchor: the
# tool checks an unpinned anchor against every path the gate declares.
CORPUS_REL="tests/shell/test_faults.sh"
CORPUS_PRINTF_REL="tests/shell/test_stack_log_rotation.sh"   # a suite whose summary is a printf
CORPUS_ONELINE_REL="tests/shell/test_faults_topo_pid.sh"      # its failure branch is one line
CORPUS_GROUPED_REL="tests/shell/test_ndt_down_stops_only_ours.sh"   # `|| { echo "Ran ..."; exit 1; }`

KILLED=0
SURVIVED=0

# build_sandbox -- a fresh copy of exactly the files the suite reads. Echoes the sandbox root.
# The whole tests/shell corpus comes along because the suite's group C reads all of it.
build_sandbox() {
    local sb; sb="$(mktemp -d)"
    mkdir -p "$sb/tools/test_workflow" "$sb/tests/shell"
    cp "$REPO_ROOT/$DRIVER_REL" "$REPO_ROOT/tools/test_workflow/components.env" \
       "$sb/tools/test_workflow/"
    cp "$REPO_ROOT"/tests/shell/test_*.sh "$sb/tests/shell/"
    printf '%s' "$sb"
}

# [Co-developed with claude code -- Adam] 🔴 THE BASELINE MUST BE GREEN (2026-09-27). This gate had
# no baseline, and a mutation counted as KILLED whenever the suite went red at all -- so from the
# day group C went red (12 of the corpus's suites changed shape) every mutation here was "killed"
# by the red that was already there, and the gate passed while proving nothing.
echo "baseline (must be green before any mutation):"
sb0="$(build_sandbox)"
if ! bash "$sb0/$SUITE_REL" > "$sb0/out.log" 2>&1; then
    echo "  refused: the suite is RED with no mutation ($(grep -c '^  FAILED' "$sb0/out.log") check(s)) -- mutations prove nothing"
    grep '^  FAILED' "$sb0/out.log" | head -5 | sed 's/^/    /'
    rm -rf "$sb0"; exit 2
fi
echo "  $(tail -1 "$sb0/out.log")"
rm -rf "$sb0"

# mutate <name> <file-relative-to-sandbox-root> <python-mutation-expression> [<check that must go red>
#        [<text its "actual:" line must hold -- WHICH rule caught it>]]
#
# The mutation is a python snippet given the file text as `s` and expected to rebind `s`. It MUST
# change the text: a no-op mutation would report KILLED or SURVIVED about nothing, which is the
# failure mode this repo calls "the instrument looking like its own finding".
mutate() {
    local name="$1" rel="$2" expr="$3" want="${4:-}" because="${5:-}"
    local sb; sb="$(build_sandbox)"
    local target="$sb/$rel"

    if ! python3 - "$target" "$expr" <<'PY'
import sys
path, expr = sys.argv[1], sys.argv[2]
s = open(path).read()
before = s
ns = {"s": s}
exec(expr, ns)
s = ns["s"]
if s == before:
    sys.stderr.write("MUTATION DID NOT CHANGE THE FILE\n")
    sys.exit(2)
open(path, "w").write(s)
PY
    then
        echo "  ERROR    $name -- the mutation did not apply; the construct it targets has moved"
        SURVIVED=$((SURVIVED + 1))
        rm -rf "$sb"
        return
    fi

    local rc=0
    bash "$sb/$SUITE_REL" > "$sb/out.log" 2>&1 || rc=$?
    local why=""
    [[ -n "$because" ]] && why="$(awk -v w="  FAILED   $want" 'index($0, w) == 1 {f = 1; next}
                                     f && /^ +actual:/ {print; exit}' "$sb/out.log")"
    if [[ "$rc" -ne 0 && -n "$want" ]] && ! grep -qF "  FAILED   $want" "$sb/out.log"; then
        echo "  SURVIVED $name   -- red, but not on '$want'"
        grep '^  FAILED' "$sb/out.log" | head -3 | sed 's/^/             /'
        SURVIVED=$((SURVIVED + 1))
    elif [[ "$rc" -ne 0 && -n "$because" && "$why" != *"$because"* ]]; then
        echo "  SURVIVED $name   -- '$want' red, but not because '$because' (${why:-no actual: line})"
        SURVIVED=$((SURVIVED + 1))
    elif [[ "$rc" -ne 0 ]]; then
        echo "  KILLED   $name   (suite rc=$rc, $(grep -c '^  FAILED' "$sb/out.log") check(s) red${want:+, '$want' among them}${because:+, because '$because'})"
        KILLED=$((KILLED + 1))
    else
        echo "  SURVIVED $name   -- the suite stayed GREEN with this defect present"
        SURVIVED=$((SURVIVED + 1))
    fi
    rm -rf "$sb"
}

echo
echo "=== mutations: the 09-02 defect itself -- shell logs scored with unittest's vocabulary ==="

mutate "the pre-fix scorer at l1_unit_tests.sh:319, verbatim" "$DRIVER_REL" '
s = s.replace("            read -r ran failed <<<\"$(shell_summary \"$log\")\"",
              "            ran=$(grep -oE \x27^Ran [0-9]+\x27 \"$log\" | tail -1 | grep -oE \x27[0-9]+\x27)\n            ran=${ran:-0}")
'

mutate "form B dropped, so '12 passed, 0 failed' counts as nothing" "$DRIVER_REL" '
s = s.replace("        /^[[:space:]]*[0-9]+ passed, [0-9]+ failed[[:space:]]*$/ {",
              "        /^NEVER MATCHES passed, failed$/ {")
'

mutate "form C dropped, so the check(s) banner counts as nothing" "$DRIVER_REL" '
s = s.replace("        /^[[:space:]]*=+ [0-9]+ check\\(s\\): [0-9]+ ok, [0-9]+ FAILED =+[[:space:]]*$/ {",
              "        /^NEVER MATCHES check banner$/ {")
'

mutate "form B loses its anchors, so a check NAME that quotes a summary invents tests" "$DRIVER_REL" '
s = s.replace("/^[[:space:]]*[0-9]+ passed, [0-9]+ failed[[:space:]]*$/",
              "/[0-9]+ passed, [0-9]+ failed/")
'

mutate "form A reads the total as the failed count" "$DRIVER_REL" '
s = s.replace("failed = ($0 ~ /all passed/) ? 0 : numat($0, 2)",
              "failed = ($0 ~ /all passed/) ? 0 : numat($0, 1)")
'

mutate "form B counts only the passes, so a red suite under-reports what it ran" "$DRIVER_REL" '
s = s.replace("failed = numat($0, 2); ran = numat($0, 1) + failed",
              "failed = numat($0, 2); ran = numat($0, 1)")
'

echo
echo "=== mutations: the WORSE bug -- 'no tests ran' quietly becoming 'passed' ==="

mutate "shell_summary answers 1 for a log it cannot read (absence scored as a pass)" "$DRIVER_REL" '
s = s.replace("        END { printf \"%d %d\\n\", ran + 0, failed + 0 }",
              "        END { if (ran + 0 == 0) ran = 1; printf \"%d %d\\n\", ran + 0, failed + 0 }")
'

mutate "ran==0 verdict flipped to PASS" "$DRIVER_REL" '
s = s.replace("elif [[ \"$ran\"     -eq 0 ]]; then echo NO-TESTS-RAN",
              "elif [[ \"$ran\"     -eq 0 ]]; then echo PASS")
'

mutate "the zero check deleted from the verdict entirely" "$DRIVER_REL" '
s = s.replace("    elif [[ \"$ran\"     -eq 0 ]]; then echo NO-TESTS-RAN\n", "")
'

mutate "the NO-TESTS-RAN arm stops counting, so the lane prints red and exits 0" "$DRIVER_REL" '
s = s.replace("echo \"${Y}NO TESTS RAN${N} ${D}(see $log)${N}\"\n            FAILURES=$((FAILURES + 1))",
              "echo \"${Y}NO TESTS RAN${N} ${D}(see $log)${N}\"")
'

echo
echo "=== mutations: the rest of the verdict order ==="

mutate "the rc check dropped, so a harness that exited nonzero can still pass" "$DRIVER_REL" '
s = s.replace("    if   [[ \"$rc\"      -ne 0 ]]; then echo FAIL-RC\n", "    if false; then echo FAIL-RC\n")
'

mutate "the skip check dropped, so a skipping suite reads as no-tests-ran" "$DRIVER_REL" '
s = s.replace("elif [[ \"$skipped\" -gt 0 ]]; then echo FAIL-SKIP",
              "elif false;                  then echo FAIL-SKIP")
'

mutate "the failed-checks arm dropped, so exit 0 over a red summary passes" "$DRIVER_REL" '
s = s.replace("elif [[ \"$failed\"  -gt 0 ]]; then echo FAIL-CHECKS",
              "elif false;                  then echo FAIL-CHECKS")
'

echo
echo "=== mutations: the corpus check (group C) actually reads the corpus ==="

# [Co-developed with claude code -- Adam] (09-27) each corpus mutant names the check that must go
# red AND the rule that must be the reason: "zero" is rule (1), no summary at all; "followed by a
# bare exit" is rule (2), a summary left only on the failure path. The first is the defect the
# old last-echo check was written for; with rule (2) gone it survives (its failure-path summary
# still scores).
mutate "a suite stops printing its GREEN-path summary (its failure one, followed by a bare exit, is left)" "$CORPUS_REL" '
s = s.replace("echo \"Ran $((PASS + FAIL)) checks, all passed\"",
              "echo \"everything is fine\"")
' "C  test_faults.sh prints" "followed by a bare exit at line"
mutate "a suite stops printing any summary the lane understands" "$CORPUS_REL" '
s = s.replace("echo \"Ran $((PASS + FAIL)) checks, all passed\"",
              "echo \"everything is fine\"")
s = s.replace("echo \"Ran $((PASS + FAIL)) checks, $FAIL failed\"",
              "echo \"something failed\"")
' "C  test_faults.sh prints" "zero:"
# the same two for a suite that prints its summary with printf -- the form the old last-echo
# heuristic could not read at all (it was red on this suite before any mutation)
mutate "a printf-summary suite stops printing a summary the lane understands" "$CORPUS_PRINTF_REL" '
s = s.replace("printf \x27\\nRan %d checks, %d failed\\n\x27", "printf \x27\\nDone: %d, %d\\n\x27")
' "C  test_stack_log_rotation.sh prints" "zero:"
mutate "a printf-summary suite prints it only on the failure path, followed by a bare exit" "$CORPUS_PRINTF_REL" '
s = s.replace("printf \x27\\nRan %d checks, %d failed\\n\x27 \"$((PASS+FAIL))\" \"$FAIL\"\n[[ \"$FAIL\" -eq 0 ]] || exit 1\n",
              "if [[ \"$FAIL\" -ne 0 ]]; then\n    printf \x27\\nRan %d checks, %d failed\\n\x27 \"$((PASS+FAIL))\" \"$FAIL\"\n    exit 1\nfi\n")
' "C  test_stack_log_rotation.sh prints" "followed by a bare exit at line"
# [Co-developed with claude code -- Adam] rule (2a), the opus judge's B1 on d2a9d641 (09-27): the
# one-line failure branch and the `|| { ...; exit 1; }` summary. At d2a9d641 both SURVIVED (group C
# saw a bare exit only at the start of a later line); each must now be caught by (2a) by name.
mutate "a one-line-failure-branch suite stops printing its green summary" "$CORPUS_ONELINE_REL" '
s = s.replace("echo \"Ran $((PASS+FAIL)) checks, all passed${SKIP:+ ($SKIP skipped)}\"",
              "echo \"everything is fine\"")
' "C  test_faults_topo_pid.sh prints" "exit <non-zero> after it on the same line"
mutate "a suite whose other summaries are all \"|| { ...; exit 1; }\" loses its final one" "$CORPUS_GROUPED_REL" '
s = s.replace("printf \x27\\n\x27\necho \"Ran $((PASS+FAIL)) checks, $FAIL failed\"\n", "printf \x27\\n\x27\n")
' "C  test_ndt_down_stops_only_ours.sh prints" "exit <non-zero> after it on the same line"
# ... and the judge's N4: a $(( )) the renderer cannot evaluate is an instrument failure, red as
# such -- never read as "zero", or as the prints before it
mutate "a summary whose \$(( )) the renderer cannot evaluate (09)" "$CORPUS_REL" '
s = s.replace("echo \"Ran $((PASS + FAIL)) checks, all passed\"",
              "echo \"Ran $((PASS + 09)) checks, all passed\"")
' "C  test_faults.sh prints" "instrument failed"

echo
echo "===== $((KILLED + SURVIVED)) mutation(s): $KILLED killed, $SURVIVED survived ====="
[[ "$SURVIVED" -eq 0 ]]
