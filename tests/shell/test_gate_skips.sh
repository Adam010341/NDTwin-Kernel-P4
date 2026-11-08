#!/usr/bin/env bash
#
# Checks for tests/shell/lib_gate_skips.sh: a mutation gate must refuse, naming each test and its
# reason, when its baseline skipped a test, must refuse when it cannot tell what ran, and must not
# refuse for a skip it declared.
#
# [Co-developed with claude code -- Adam]
#
# The transcripts below are unittest -v output in the shapes Python 3.10 and 3.13 print (copied
# from real runs, trimmed); the last case runs python3 itself on a module made for it, so a change
# in what this machine's unittest prints shows up here and not as a gate that quietly stops
# seeing skips. Ids are checked as whole refusal lines, not as substrings.
#
# Usage: tests/shell/test_gate_skips.sh     (offline, no lab, a few seconds)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_gate_skips.sh
source "${GATE_SKIPS_LIB_UNDER_TEST:-$HERE/lib_gate_skips.sh}"
[[ -n "${GATE_SKIPS_LIB_UNDER_TEST:-}" ]] && echo "note: testing $GATE_SKIPS_LIB_UNDER_TEST" >&2

PASS=0
FAIL=0
check() {   # check <what> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        echo "  ok       $1"; PASS=$((PASS + 1))
    else
        printf '  FAILED   %s\n             expected: %s\n             actual:   %s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}
has() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; }   # has <text> <needle>
# named <text> <id> -- the id is listed as a line of its own, exactly (refused or count-refused).
named() { grep -qxF -- "    $2" <<<"$1" && echo yes || echo no; }
# expected <text> <id> -- the id is listed as a declared skip, exactly.
expected() { grep -qxF -- "  skipped in the baseline, expected by this gate: $2" <<<"$1" && echo yes || echo no; }
refusal() { sed -n '/^REFUSE/,$p' <<<"$1"; }

# --- Python 3.13 shape: class skip, setUpClass skip, a docstring line, a double-quoted reason,
# and a passing test whose NAME says "skipped" (it must not count).
PY313="test_one (t_a.A.test_one) ... skipped 'class reason'
setUpClass (t_a.B) ... skipped 'setupclass reason'
test_doc (t_a.C.test_doc)
A docstring line. ... skipped 'method reason (with parens)'
test_ok (t_a.C.test_ok) ... ok
test_a_switch_with_no_address_is_skipped (t_a.D.test_a_switch_with_no_address_is_skipped) ... ok
test_build (t_a.E.test_build) ... skipped \"NDTwin's compiled program is not built; run l0\"

----------------------------------------------------------------------
Ran 6 tests in 0.001s

OK (skipped=4)"

out=$(gate_baseline_skips <<<"$PY313"); rc=$?
check "1a. any undeclared skip refuses (rc 1)" 1 "$rc"
check "1b. it says REFUSE" yes "$(has "$out" "REFUSE: 4 test(s) in the baseline were SKIPPED")"
check "1c. a class-level skip is named by its id" yes "$(named "$out" "t_a.A.test_one")"
check "1d. a setUpClass skip is named" yes "$(named "$out" "t_a.B.setUpClass")"
check "1e. a skip after a docstring line is named by the test, not the docstring" yes \
    "$(named "$out" "t_a.C.test_doc")"
check "1f. the reason is printed" yes "$(has "$out" "'method reason (with parens)'")"
check "1g. a double-quoted reason is read too" yes "$(named "$out" "t_a.E.test_build")"
check "1h. a passing test named *_is_skipped is not a skip" no "$(has "$out" "t_a.D")"
check "1i. a 'not built' reason brings the build hint" yes "$(has "$out" "l0_build_check.sh p4")"
check "1j. and not the interpreter hint" no "$(has "$out" "PROXY_PY=")"
check "1k. it says what it checked" yes "$(has "$out" "  checked 1 run(s), 4 skip(s)")"

out=$(gate_baseline_skips 't_a\.A\..*' 't_a\.B\.setUpClass' 't_a\.C\.test_doc' 't_a\.E\..*' <<<"$PY313"); rc=$?
check "2a. every skip declared: no refusal (rc 0)" 0 "$rc"
check "2b. a declared skip is still listed, as expected" yes "$(expected "$out" "t_a.C.test_doc")"
check "2c. no REFUSE line" no "$(has "$out" "REFUSE")"
check "2d. and the checked line is the first line, before the declared ones" "  checked 1 run(s), 4 skip(s)" \
    "$(head -n 1 <<<"$out")"

out=$(gate_baseline_skips 't_a\.A\..*' 't_a\.B\..*' 't_a\.C\..*' <<<"$PY313"); rc=$?
check "3a. one undeclared skip among declared ones refuses" 1 "$rc"
check "3b. it counts only the undeclared one" yes "$(has "$out" "REFUSE: 1 test(s)")"
check "3c. the declared ones are not in the refusal" no "$(named "$(refusal "$out")" "t_a.C.test_doc")"

out=$(gate_baseline_skips 't_a\.A' 't_a\.B\.setUpClass' 't_a\.C\.test_doc' 'E\.test_build' <<<"$PY313"); rc=$?
check "3d. an allowed ERE must match the WHOLE id (a prefix or a tail declares nothing)" 1 "$rc"
check "3e. so the prefix-only and tail-only ones are refused" yesyes \
    "$(named "$out" "t_a.A.test_one")$(named "$out" "t_a.E.test_build")"

# --- Python 3.10 shape: "name (module.Class)", and a setUpClass skip printed with no name.
PY310="test_one (t_a.A) ... skipped 'class reason'
skipped 'setupclass reason'
test_doc (t_a.C)
A docstring line. ... skipped 'method reason'
test_ok (t_a.C) ... ok

----------------------------------------------------------------------
Ran 3 tests in 0.000s

OK (skipped=3)"
out=$(gate_baseline_skips <<<"$PY310"); rc=$?
check "4a. 3.10: refuses" 1 "$rc"
check "4b. 3.10: the id is module.Class.method" yes "$(named "$out" "t_a.A.test_one")"
check "4c. 3.10: a nameless setUpClass skip is listed, not dropped" yes "$(named "$out" "(unnamed)")"
check "4d. 3.10: docstring case" yes "$(named "$out" "t_a.C.test_doc")"
check "4e. no 'not built' reason: no build hint" no "$(has "$out" "l0_build_check")"

# --- Output a test printed between " ... " and its result.
NOISY="test_x (m.C.test_x) ... some output the test printed
skipped 'late reason'
Ran 1 test in 0.001s

OK (skipped=1)"
out=$(gate_baseline_skips <<<"$NOISY")
check "5a. a result line broken by printed output is still the test's" yes "$(named "$out" "m.C.test_x")"
GLUED="test_glued (t_d.S.test_glued) ... noise-no-newlineskipped 'glued reason'
Ran 1 test in 0.001s

OK (skipped=1)"
out=$(gate_baseline_skips <<<"$GLUED")
check "5b. a status glued to printed output is the test's, with its reason" yesyes \
    "$(named "$out" "t_d.S.test_glued")$(has "$out" "        'glued reason'")"
# The declared test resolved, then the NEXT start line is glued to output: its skip is that next
# test's, never the declared one's (that would declare it silently).
GLUED_START="t1 (a.B.t1) ... skipped 'declared'
noise)t2 (a.B.t2) ... skipped 'not declared'
Ran 2 tests in 0.001s

OK (skipped=2)"
out=$(gate_baseline_skips 'a\.B\.t1' <<<"$GLUED_START"); rc=$?
check "5c. a glued start line after a declared test is not taken as the declared one" 1 "$rc"
check "5d. it is named by its own line" yes "$(named "$out" "a.B.t2")"
# A passing test with a docstring, then a bare skip (3.10's setUpClass): nobody's, not the docstring's.
DOC_THEN_BARE="test_doc_ok (t_d.S)
Passing doc. ... ok
skipped 'module setup reason'
Ran 1 test in 0.000s

OK (skipped=1)"
out=$(gate_baseline_skips 't_d\.S\.test_doc_ok' <<<"$DOC_THEN_BARE"); rc=$?
check "5e. a bare skip after a passing docstring test is not that test's" 1 "$rc"
check "5f. it is listed as (unnamed)" yes "$(named "$out" "(unnamed)")"
# subTest (3.13 prints it indented under its test), setUpModule (3.13 and 3.10), expected failure.
# 3.11+ ends a subTest's parent line with "... " (a trailing space), which makes it a start line.
SHAPES="$(printf '%s\n' "setUpModule (t_c) ... skipped 'module setup reason'" "test_sub (t_d.S.test_sub) ... " \
    "  test_sub (t_d.S.test_sub) (i=1) ... skipped 'sub reason'" "test_xf (t_d.S.test_xf) ... expected failure" \
    "Ran 3 tests in 0.001s" "" "OK (skipped=2, expected failures=1)")"
out=$(gate_baseline_skips <<<"$SHAPES"); rc=$?
check "5g. 3.13 setUpModule skip is named" yes "$(named "$out" "t_c.setUpModule")"
check "5h. 3.13 subTest skip is named by its test" yes "$(named "$out" "t_d.S.test_sub")"
check "5i. an expected failure is not a skip (2 counted, nothing unaccounted)" yes \
    "$(has "$out" "REFUSE: 2 test(s)")"
# Colour codes (a forced-colour unittest) do not hide a skip or a summary.
ESC=$'\033'
COLOUR="test_c (m.C.test_c) ... ${ESC}[33mskipped 'colour reason'${ESC}[0m
Ran 1 test in 0.001s

${ESC}[32mOK${ESC}[0m (${ESC}[33mskipped=1${ESC}[0m)"
out=$(gate_baseline_skips <<<"$COLOUR"); rc=$?
check "5j. a coloured transcript: refuses" 1 "$rc"
check "5k. a coloured transcript: named correctly" yes "$(named "$out" "m.C.test_c")"

# --- A skip goes to a pending test only when the parser is sure it is that test's.
# Trace 1 (3.11+): t1 printed, its "ok" came on a line of its own, then t2's start line is glued to
# output. t1 is declared; t2's skip must not become t1's.
TRACE1="t1 (a.B.t1) ... printed
ok
noise)t2 (a.B.t2) ... skipped 'not declared'
Ran 2 tests in 0.001s

OK (skipped=1)"
out=$(gate_baseline_skips 'a\.B\.t1' <<<"$TRACE1"); rc=$?
check "10a. trace 1: a glued start line after a bare ok is not the declared test's" 1 "$rc"
check "10b. trace 1: it is named by its own line" yes "$(named "$out" "a.B.t2")"
# Trace 2 (3.10): the same, then another class's setUpClass skip, which 3.10 prints bare.
TRACE2="t1 (a.B) ... printed
ok
skipped 'class setup reason'
Ran 1 test in 0.001s

OK (skipped=1)"
out=$(gate_baseline_skips 'a\.B\.t1' <<<"$TRACE2"); rc=$?
check "10c. trace 2: a bare setUpClass skip after a bare ok is not the declared test's" 1 "$rc"
check "10d. trace 2: it is (unnamed)" yes "$(named "$out" "(unnamed)")"
# The result glued to the end of the output ("printedok"), then the next class's bare skip.
GLUED_OK="t1 (a.B) ... printedok
skipped 'class setup reason'
Ran 1 test in 0.001s

OK (skipped=1)"
out=$(gate_baseline_skips 'a\.B\.t1' <<<"$GLUED_OK"); rc=$?
check "10e. a result glued to printed output ends the test: the next skip is not its" 1 "$rc"
# Two lines of output, then a bare skip: too far from the start line to be sure -- refused,
# even though it may be t1's own (the rule's over-refusal).
FAR="t1 (a.B.t1) ... line one
line two
skipped 'far reason'
Ran 1 test in 0.001s

OK (skipped=1)"
out=$(gate_baseline_skips 'a\.B\.t1' <<<"$FAR"); rc=$?
check "10f. a skip two lines after the start line is not given to the pending test" 1 "$rc"
check "10g. it is (unnamed)" yes "$(named "$out" "(unnamed)")"
# The suffix rule: output glued in front of a 3.11+ start line still gives the test's own id.
SUFFIX="t1 (a.B.t1) ... ok
noisetest_b (m.C.test_b) ... skipped 'r'
Ran 2 tests in 0.001s

OK (skipped=1)"
out=$(gate_baseline_skips <<<"$SUFFIX")
check "10h. a start line with output glued in front is named by the path" yes "$(named "$out" "m.C.test_b")"
# A skip line that names no test, with no test pending.
ORPHAN="free text ... skipped 'orphan reason'
Ran 1 test in 0.001s

OK (skipped=1)"
out=$(gate_baseline_skips <<<"$ORPHAN")
check "10i. a skip that names no test and follows none is (unnamed), with its reason" yesyes \
    "$(named "$out" "(unnamed)")$(has "$out" "        'orphan reason'")"

# --- Fails closed when the skips do not add up.
SHORT="test_one (t_a.A.test_one) ... skipped 'r'
Ran 2 tests in 0.001s

OK (skipped=2)"
out=$(gate_baseline_skips '.*' <<<"$SHORT"); rc=$?
check "6a. summary says 2, one named: refuses even with everything declared" 1 "$rc"
check "6b. and says it cannot account for them" yes "$(has "$out" "count 2 skipped test(s) and 1 could be")"
check "6c. and still lists the one it could name" yes "$(named "$out" "t_a.A.test_one")"

# --- Fails closed when it saw no run.
out=$(gate_baseline_skips < /dev/null); rc=$?
check "6d. an empty transcript refuses" 1 "$rc"
check "6e. and says no run was recognised" yes "$(has "$out" "no unittest run was recognised")"
out=$(gate_baseline_skips <<<"some output that is not unittest's"); rc=$?
check "6f. output with no unittest run in it refuses" 1 "$rc"
NOSUMMARY="t1 (a.B.t1) ... ok
Ran 1 test in 0.001s"
out=$(gate_baseline_skips <<<"$NOSUMMARY"); rc=$?
check "6g. a run with no summary line refuses" 1 "$rc"
check "6h. and says the runs and summaries do not pair, NO TESTS RAN among the causes" yesyes \
    "$(has "$out" "1 run(s) but 0 summary line(s)")$(has "$out" "NO TESTS RAN")"
out=$(gate_baseline_skips <<<"Ran 0 tests in 0.000s

OK"); rc=$?
check "6i. a run of 0 tests (3.10/3.11: OK) refuses" 1 "$rc"
check "6j. and says it ran nothing" yes "$(has "$out" "1 of the baseline's runs ran 0 tests")"
out=$(gate_baseline_skips <<<"Ran 0 tests in 0.000s

NO TESTS RAN"); rc=$?
check "6k. a run of 0 tests (3.12+: NO TESTS RAN) refuses" 1 "$rc"

# --- Two runs in one transcript; and a clean one.
TWO="t1 (a.B.t1) ... ok
Ran 1 test in 0.001s

OK
t2 (c.D.t2) ... skipped 'x'
t3 (c.D.t3) ... skipped 'y'
Ran 2 tests in 0.001s

OK (skipped=2)"
out=$(gate_baseline_skips 'c\.D\.t2' 'c\.D\.t3' <<<"$TWO"); rc=$?
check "7. two runs: the totals add up and both are declared" 0 "$rc"
out=$(gate_baseline_skips <<<"t1 (a.B.t1) ... ok
Ran 1 test in 0.001s

OK"); rc=$?
check "8a. nothing skipped: rc 0" 0 "$rc"
check "8b. nothing skipped: prints only what it checked" "  checked 1 run(s), 0 skip(s)" "$out"
out=$(gate_baseline_skips <<<"t1 (a.B.t1) ... FAIL
Ran 1 test in 0.001s

FAILED (failures=1, skipped=1)"); rc=$?
check "8c. a FAILED summary's skipped= counts too (one counted, none named)" 1 "$rc"
check "8e. and the refusal is the count one" yes "$(has "$out" "count 1 skipped test(s) and 0 could be")"
out=$(gate_baseline_skips <<<"t (a.B.t) ... skipped 'needs the P4Runtime protobufs and the compiled p4info'
Ran 1 test in 0.001s

OK (skipped=1)")
check "8d. a reason naming both causes gets both hints" yesyes \
    "$(has "$out" "l0_build_check.sh p4")$(has "$out" "PROXY_PY=")"

# --- This machine's own unittest.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/live_mod.py" <<'PY'
import unittest

@unittest.skipUnless(False, "class reason")
class A(unittest.TestCase):
    def test_one(self): pass

class B(unittest.TestCase):
    @classmethod
    def setUpClass(cls): raise unittest.SkipTest("setupclass reason")
    def test_two(self): pass

class C(unittest.TestCase):
    def test_doc(self):
        """A docstring line."""
        print("printed by the test")
        self.skipTest("it's not built")
    def test_ok(self): pass
PY
echo "  (case 9 runs $(command -v python3): $(python3 -V 2>&1))"
live=$(cd "$T" && python3 -m unittest live_mod -v 2>&1)
out=$(gate_baseline_skips <<<"$live"); rc=$?
check "9a. live: refuses" 1 "$rc"
check "9b. live: counts all three skips (no 'could be named' line)" no "$(has "$out" "could be")"
check "9c. live: names the class skip" yes "$(named "$out" "live_mod.A.test_one")"
check "9d. live: names the docstring test" yes "$(named "$out" "live_mod.C.test_doc")"
check "9e. live: the double-quoted reason" yes "$(has "$out" "\"it's not built\"")"
# A warning printed between a test's " ... " and its "ok", then another class's setUpClass skip
# (bare on 3.10): declaring the warning test must not declare that skip.
cat > "$T/live_w.py" <<'PY'
import unittest, warnings

class AWarns(unittest.TestCase):
    def test_warns(self):
        warnings.warn("a warning the test raises")

class BSkipsItsClass(unittest.TestCase):
    @classmethod
    def setUpClass(cls): raise unittest.SkipTest("another class never ran")
    def test_x(self): pass
PY
live=$(cd "$T" && python3 -m unittest live_w -v 2>&1)
out=$(gate_baseline_skips 'live_w\.AWarns\.test_warns' <<<"$live"); rc=$?
check "9f. live: a warning before ok does not hand the next class's skip to the warning test" 1 "$rc"
printf '\n' > "$T/live_empty.py"
live=$(cd "$T" && python3 -m unittest live_empty -v 2>&1)
out=$(gate_baseline_skips <<<"$live"); rc=$?
check "9g. live: a run of 0 tests refuses" 1 "$rc"

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
