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

# mutate <name> <file-relative-to-sandbox-root> <python-mutation-expression>
#
# The mutation is a python snippet given the file text as `s` and expected to rebind `s`. It MUST
# change the text: a no-op mutation would report KILLED or SURVIVED about nothing, which is the
# failure mode this repo calls "the instrument looking like its own finding".
mutate() {
    local name="$1" rel="$2" expr="$3"
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
    if [[ "$rc" -ne 0 ]]; then
        echo "  KILLED   $name   (suite rc=$rc, $(grep -c '^  FAILED' "$sb/out.log") check(s) red)"
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

mutate "a suite stops printing any summary the lane understands" "$CORPUS_REL" '
s = s.replace("echo \"Ran $((PASS + FAIL)) checks, all passed\"",
              "echo \"everything is fine\"")
'

echo
echo "===== $((KILLED + SURVIVED)) mutation(s): $KILLED killed, $SURVIVED survived ====="
[[ "$SURVIVED" -eq 0 ]]
