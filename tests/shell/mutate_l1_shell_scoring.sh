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
CORPUS_CALL_REL="tests/shell/test_ndt_ovs_topo_script.sh"   # `summary() { printf ...; }`, `summary; exit 1`, `summary`
CORPUS_NEEDS_REL="tests/shell/test_gate_exit_code_not_tee.sh"   # carries a NDTWIN_L1_NEEDS declaration
HBDROP_REL="tests/shell/test_heartbeat_drop_check.py"   # [Co-developed with claude code -- Adam] declares bmv2-stock

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
    # [Co-developed with claude code -- Adam] and the Python suites (S-8): D22 and D29 read their
    # NDTWIN_L1_NEEDS declarations
    cp "$REPO_ROOT"/tests/shell/test_*.py "$sb/tests/shell/"
    # group R's fixtures (09-27): without them every R check reads "instrument failed"
    mkdir -p "$sb/tests/shell/fixtures"
    cp -r "$REPO_ROOT/tests/shell/fixtures/l1_shell_scoring" "$sb/tests/shell/fixtures/"
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
echo "=== mutations: declared skips (group D) -- the excuse must not grow ==="

# [Co-developed with claude code -- Adam] (2026-09-28) each one widens or deletes the declared-skip
# excuse in the driver, and the group D check that pins that edge must go red by name.
mutate "the DECLARED-SKIP verdict is gone, so an excused skip is a failure again" "$DRIVER_REL" '
s = s.replace("    elif [[ \"$skipped\" -gt 0 && -n \"$excuse\" && \"$hosted\" == 1 && \"$failed\" -eq 0 ]]; then echo DECLARED-SKIP\n", "")
' "D4 a hosted runner's skip with an excuse is DECLARED-SKIP"
mutate "an excuse outranks a harness that exited non-zero" "$DRIVER_REL" '
s = s.replace("    elif [[ \"$skipped\" -gt 0 && -n \"$excuse\" && \"$hosted\" == 1 && \"$failed\" -eq 0 ]]; then echo DECLARED-SKIP\n", "")
s = s.replace("    if   [[ \"$rc\"      -ne 0 ]]; then echo FAIL-RC\n",
              "    if   [[ \"$skipped\" -gt 0 && -n \"$excuse\" && \"$hosted\" == 1 && \"$failed\" -eq 0 ]]; then echo DECLARED-SKIP\n    elif [[ \"$rc\"      -ne 0 ]]; then echo FAIL-RC\n")
' "D6 an excuse never outranks a harness that exited non-zero"
mutate "a need the machine HAS still excuses (the lab would go quiet)" "$DRIVER_REL" '
s = s.replace("            0)        missing+=(\"$need\") ;;", "            0|1)      missing+=(\"$need\") ;;")
' "D8 🔴 a machine that HAS the need excuses nothing"
mutate "a need with no probe is read as missing" "$DRIVER_REL" '
s = s.replace("            unprobed) return 0 ;;", "            unprobed) missing+=(\"$need\") ;;")
' "D12 🔴 a need the lane has no probe for excuses nothing, even beside a missing one"
mutate "a shell suite with a red check before its SKIP is excused" "$DRIVER_REL" '
s = s.replace("    if [[ \"$kind\" == sh ]] && grep -qE \x27^[[:space:]]*(FAILED|FAIL )\x27 \"$log\"; then return 0; fi\n", "")
' "D13 🔴 a shell suite that printed a FAILED check before its SKIP is not excused"
mutate "the py-plot probe lets round.env mkdir" "$DRIVER_REL" '
s = s.replace("    ( mkdir() { :; }\n", "    (\n")
' "D16 ... and round.env's mkdir did not run"
mutate "the DECLARED-SKIP arm counts a failure after all" "$DRIVER_REL" '
s = s.replace("            DECLARED_SKIPS+=(\"$name (needs $excuse)\")\n",
              "            DECLARED_SKIPS+=(\"$name (needs $excuse)\")\n            FAILURES=$((FAILURES + 1))\n")
' "D20 🔴 the DECLARED-SKIP arm records the file and does NOT count a failure"
mutate "the DECLARED-SKIP arm records nothing, so the end of the lane never lists it" "$DRIVER_REL" '
s = s.replace("            DECLARED_SKIPS+=(\"$name (needs $excuse)\")\n", "")
' "D20 🔴 the DECLARED-SKIP arm records the file and does NOT count a failure"
# [Co-developed with claude code -- Adam] (2026-09-28, second round) the excuse is a KIND of machine,
# the failed count vetoes it, a partial Python skip is not excused, and only a real comment declares.
mutate "the hosted-runner condition is dropped, so a lab that lost a need reads as excused" "$DRIVER_REL" '
s = s.replace(" && \"$hosted\" == 1 && \"$failed\" -eq 0 ]]; then echo DECLARED-SKIP", " && \"$failed\" -eq 0 ]]; then echo DECLARED-SKIP")
' "D4b 🔴 the same skip anywhere else is FAIL-SKIP (a lab that lost the need is red)"
mutate "every machine is taken for a hosted runner" "$DRIVER_REL" '
s = s.replace("    [[ \"${CI:-}\" == true || \"${GITHUB_ACTIONS:-}\" == true ]] && echo 1 || echo 0\n", "    echo 1\n")
' "D23 🔴 lab env (CI, GITHUB_ACTIONS unset) + a missing declared need -> FAIL-SKIP"
mutate "a failed count no longer vetoes the excuse" "$DRIVER_REL" '
s = s.replace(" && \"$hosted\" == 1 && \"$failed\" -eq 0 ]]; then echo DECLARED-SKIP", " && \"$hosted\" == 1 ]]; then echo DECLARED-SKIP")
' "D6b 🔴 a summary that counts failed checks vetoes the excuse, whatever its lines say"
mutate "a Python file that ran some of its tests is excused" "$DRIVER_REL" '
s = s.replace("    if [[ \"$kind\" == py && \"$skipped\" -ne \"$ran\" ]]; then return 0; fi\n", "")
' "D9b 🔴 a Python file that ran some of its tests is not excused (only a whole-file skip is)"
mutate "a .py file is read line by line, so a docstring declares" "$DRIVER_REL" '
s = s.replace("    *.py)\n        python3 - \"$1\" 2>/dev/null <<\x27PY\x27", "    *.never-py)\n        python3 - \"$1\" 2>/dev/null <<\x27PY\x27")
' "D3b 🔴 a declaration quoted inside a Python docstring is not one"
mutate "a heredoc body is read as the script" "$DRIVER_REL" '
s = s.replace("            hd != \"\" { t = $0; if (strip) sub(/^\\t+/, \"\", t); if (t == hd) hd = \"\"; next }\n", "")
' "D3d 🔴 a line inside a shell heredoc is not one; the declaration after it is"
mutate "the FAIL-SKIP line stops naming the missing need" "$DRIVER_REL" '
s = s.replace("skip(s) — needs ${excuse}, which this machine", "skip(s) — a declared need, which this machine")
' "D26 🔴 the FAIL-SKIP arm names a declared need that is missing (the lab is told what it lost)"
mutate "a declaration in the corpus names a need the lane has no probe for" "$CORPUS_NEEDS_REL" '
s = s.replace("# NDTWIN_L1_NEEDS: py-plot\n", "# NDTWIN_L1_NEEDS: py-plot no-such-need\n")
' "D22 every NDTWIN_L1_NEEDS in tests/shell and tests/python is one the lane probes"
mutate "the ryu probe is lost" "$DRIVER_REL" '
s = s.replace("L1_NEED_MET[ryu]=0\n\"$PY_KERNEL\" -c \"import networkx, ryu\" >/dev/null 2>&1 && L1_NEED_MET[ryu]=1\n", "")
' "D18 the lane probes the needs it can excuse (ryu, py-plot, bmv2-stock)"

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

# [Co-developed with claude code -- Adam] rule (2a) read on a CALL's line -- the opus judge's NOTE A on
# 1d5180ce (09-27). test_ndt_ovs_topo_script.sh prints its summary from `summary() { printf ...; }`,
# calls it as `summary; exit 1` when a section cannot run, and as a bare `summary` last. With the bare
# call gone, 1d5180ce's group C read the function's print at its definition line, saw no exit there,
# took the failure call as "the last call" -- and stayed GREEN on a suite whose green run prints no
# summary at all. It must now be red, for the call-line reason.
mutate "a suite whose summary is a function loses its last, bare call (only \`summary; exit 1\` is left)" "$CORPUS_CALL_REL" '
s = s.replace("\nsummary\n[[ $FAIL -eq 0 ]]\n", "\n[[ $FAIL -eq 0 ]]\n")
' "C  test_ndt_ovs_topo_script.sh prints" "every call of which has an exit <non-zero> after the call"

echo
echo "=== mutations: group C's readings, each broken in the suite's own reader (group R must see it) ==="

# [Co-developed with claude code -- Adam] (09-27, the opus judge's NOTE I on 1d5180ce) each reading of
# render_prints is broken once, in the suite's OWN copy of it, and the group R fixture that pins that
# reading must go red for it -- by name, and with the verdict the broken reading gives.
mutate "(2a) && after a print is no longer certain" "$SUITE_REL" '
s = s.replace("        elif op == \"&&\":\n            cond = cond or not ok\n",
              "        elif op == \"&&\":\n            cond = True\n")
' 'R7   `echo ... && exit 1` in a failure branch' "nonzero"
mutate "(2a) the command after || is read as reached" "$SUITE_REL" '
s = s.replace("            if ok and not cond:\n                continue                     # never runs, and the list still succeeded\n            cond = True\n",
              "            cond = False\n")
' 'R6   `echo ... || exit 1`' "exit <non-zero> after it on the same line"
mutate "(2a) an exit behind && after a test is read as certain (B)" "$SUITE_REL" '
s = s.replace("            if nest == 0 and not cond:\n                return kind == \"fail\"",
              "            if nest == 0:\n                return kind == \"fail\"")
' 'R4 * `echo ...; (( FAIL )) && exit 1`' "exit <non-zero> after it on the same line"
mutate "(2a) a conditional exit 0 is no longer a way to the end (B)" "$SUITE_REL" '
s = s.replace("            if kind == \"other\":\n                return False                 # it may run: a way to the end that does not fail\n",
              "            if kind == \"other\":\n                continue\n")
' 'R5 * `echo ...; [[ $FAIL -eq 0 ]] && exit 0; exit 1`' "exit <non-zero> after it on the same line"
mutate "(2a) an exit inside an if opened after the print is read as certain" "$SUITE_REL" '
s = s.replace("        if head in OPENERS:\n            nest, ok = nest + 1, False\n",
              "        if head in OPENERS:\n            ok = False\n")
' 'R16   `echo ...; if (( FAIL )); then exit 1; fi`' "exit <non-zero> after it on the same line"
mutate "(2a) a function's calls are not read, only its definition line (A)" "$SUITE_REL" '
s = s.replace("    ok = [c for c in calls if not call_fails(c)]\n", "    ok = calls\n")
' 'R1 * a function summary whose every call is `summary; exit 1`' "nonzero"
mutate "(2a) a function's own body is not read (A)" "$SUITE_REL" '
s = s.replace("    body = not here and body_exits_after(n)\n", "    body = False\n")
' 'R3 * a function that exits 1 later in its body' "nonzero"
mutate "(2a) the end of the block the print is in stops the reading (H)" "$SUITE_REL" '
s = s.replace("            continue                         # the print\x27s own block ends: what follows still runs\n",
              "            return False\n")
' 'R13 * `{ echo ...; }; exit 1`' "nonzero"
mutate "(2a) a pipe stops the reading (G)" "$SUITE_REL" '
s = s.replace("        elif op == \"|\":                      # the same pipeline: an exit here ends a subshell\n",
              "        elif op == \"|\":\n            return False\n")
' 'R12 * `echo ... | tee -a $LOG; exit 1`' "nonzero"
mutate "(1) a print written to a file is rendered as if it reached the log (G)" "$SUITE_REL" '
s = s.replace("        if w is None or stdout_away(text):\n", "        if w is None:\n")
' 'R10 * a summary written to a FILE' "nonzero"
mutate "(1) a print written to stderr is dropped with the ones written to files (G)" "$SUITE_REL" '
s = s.replace("        if target.startswith(\"&\") or target in", "        if target.startswith(\"&1\") or target in")
' 'R11   ... and one written to stderr' "zero:"
mutate "(1) \`name(){\` -- no space -- is not a function head (F)" "$SUITE_REL" '
s = s.replace("r\"[A-Za-z_][A-Za-z0-9_]*\\(\\)\\{?\", w[0]", "r\"[A-Za-z_][A-Za-z0-9_]*\\(\\)\", w[0]")
' 'R8 * `summary(){ echo ...; }`' "zero:"
mutate "(1) a case pattern is not taken off the front of a print (F)" "$SUITE_REL" '
s = s.replace("        elif re.fullmatch(r\"[^$`(){}\\\"\x27]*\\)\", h):", "        elif False:")
' 'R9 * a print behind a case pattern' "zero:"
mutate "(2a) the next ;; pattern is read as the print's path" "$SUITE_REL" '
s = s.replace("        if nest == 0 and (op == \";;\" or head in (\"else\", \"elif\")):",
              "        if nest == 0 and head in (\"else\", \"elif\"):")
' 'R15 * `case ... in 0) echo ... ;; *) exit 1 ;; esac`' "exit <non-zero> after it on the same line"
mutate "(2a) the else branch is read as the print's path" "$SUITE_REL" '
s = s.replace("        if nest == 0 and (op == \";;\" or head in (\"else\", \"elif\")):",
              "        if nest == 0 and op == \";;\":")
' 'R14   `then echo ...; else exit 1; fi`' "exit <non-zero> after it on the same line"

echo
echo "=== mutations: tests/shell's Python suites are collected, scored as shell suites, and declare their need (S-8) ==="
# [Co-developed with claude code -- Adam] round 5 (the round-4 review's S-8)
mutate "tests/shell/test_*.py is not collected" "$DRIVER_REL" '
s = s.replace(" \"$KERNEL_DIR\"/tests/shell/test_*.py)", ")")
' "D27 🔴 the lane collects tests/shell/test_*.py"
mutate "a tests/shell/*.py is scored with unittest's vocabulary" "$DRIVER_REL" '
s = s.replace("[[ \"$testfile\" == *.py && \"$testfile\" != */tests/shell/* ]] && kind=py", "[[ \"$testfile\" == *.py ]] && kind=py")
' "D28 🔴 and scores them as shell suites (their summary and SKIP: lines), run by python3"
mutate "the drop check suite does not declare the stock bmv2" "$HBDROP_REL" '
s = s.replace("# NDTWIN_L1_NEEDS: bmv2-stock\n", "\n")
' "D29 🔴 the drop check's suite declares the stock bmv2 it needs"
mutate "the lane never probes bmv2-stock" "$DRIVER_REL" '
s = s.replace("L1_NEED_MET[bmv2-stock]=0\n", "").replace("&& L1_NEED_MET[bmv2-stock]=1", "&& :")
' "D18 the lane probes the needs it can excuse (ryu, py-plot, bmv2-stock)"

echo
echo "===== $((KILLED + SURVIVED)) mutation(s): $KILLED killed, $SURVIVED survived ====="
[[ "$SURVIVED" -eq 0 ]]
