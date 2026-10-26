#!/usr/bin/env bash
#
# Tests for how l1_unit_tests.sh scores a tools/p4_exercise/tests file (l1_exercise_verdict).
#
# [Co-developed with claude code -- Adam]
#
# Those files skip some tests when a local P4 tutorial tool is missing, and the lane excuses a skip
# only when its reason names the variable that points at the tool (NDTWIN_TUTORIALS_DIR, NDTWIN_P4C or
# NDTWIN_P4DEV_VENV). The reason is read out of unittest's own `-v` output, so every fixture here is a
# small real unittest file run with `python3 -m unittest -v`: the log is whatever unittest prints, not
# a transcription of it. That matters for the shapes that are easy to get wrong by hand -- a test with
# a docstring (the "... skipped" lands on the line after the docstring), a reason with an apostrophe
# (the reason is then printed in double quotes), a skip inside subTest (one line per subtest, no "ok"
# for the test), and a setUpClass or setUpModule SkipTest (unittest prints "Ran 0 tests / OK
# (skipped=1)", which the lane must not read as a file that merely had no tests).
#
# No fabric, no lab claim, no build: NDTWIN_L1_LIB_ONLY=1 stops l1_unit_tests.sh above its first side
# effect, and every fixture lives in a mktemp sandbox. Needs python3 (any, standard library only).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="${L1_DRIVER:-$HERE/../../tools/test_workflow/l1_unit_tests.sh}"

[[ -f "$DRIVER" ]] || { echo "  FAILED   no driver at $DRIVER"; echo "Ran 1 checks, 1 failed"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  FAILED   no python3"; echo "Ran 1 checks, 1 failed"; exit 1; }

# shellcheck source=/dev/null
if ! NDTWIN_L1_LIB_ONLY=1 source "$DRIVER" >/dev/null 2>&1 || ! declare -F l1_exercise_verdict >/dev/null; then
    echo "  FAILED   l1_unit_tests.sh does not expose l1_exercise_verdict under NDTWIN_L1_LIB_ONLY=1"
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

# verdict_of <name> -- run fixture $T/<name>.py (already written) under unittest -v and echo the verdict token.
verdict_of() {
    local name="$1" rc
    (cd "$T" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v "$name") >"$T/$name.log" 2>&1
    rc=$?
    l1_exercise_verdict "$T/$name.log" "$rc" | awk '{print $1}'
}
# full_of <name> -- the whole "<VERDICT> <ran> <skipped> <tool_skipped>" line, for the counts.
full_of() {
    local name="$1" rc
    (cd "$T" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v "$name") >"$T/$name.log" 2>&1
    rc=$?
    l1_exercise_verdict "$T/$name.log" "$rc"
}

# --- plain skips ------------------------------------------------------------------
cat >"$T/fx_tool.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_needs_tool(self):
        self.skipTest("no p4c-bm2-ss (not on PATH, $NDTWIN_P4C unset)")
PY
check "a skip naming NDTWIN_P4C, the other test passing, is PROVED LESS" "PROVED-LESS" "$(verdict_of fx_tool)"
check "  and the counts are 2 ran, 1 skipped, 1 naming a tool" "PROVED-LESS 2 1 1" "$(full_of fx_tool)"

cat >"$T/fx_unrelated.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_regressed(self):
        self.skipTest("unrelated")
PY
check "a skip naming no tool is FAIL-UNRELATED" "FAIL-UNRELATED" "$(verdict_of fx_unrelated)"

cat >"$T/fx_each_var.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_a(self): self.skipTest("set NDTWIN_TUTORIALS_DIR")
    def test_b(self): self.skipTest("set NDTWIN_P4C")
    def test_c(self): self.skipTest("set NDTWIN_P4DEV_VENV")
PY
check "each of the three variables excuses a skip" "PROVED-LESS 4 3 3" "$(full_of fx_each_var)"

cat >"$T/fx_mixed.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_t1(self): self.skipTest("set NDTWIN_P4C")
    def test_t2(self): self.skipTest("set NDTWIN_P4C")
    def test_bad(self): self.skipTest("unrelated")
PY
check "tool skips do not hide an unrelated one beside them" "FAIL-UNRELATED 4 3 2" "$(full_of fx_mixed)"

# --- docstring form ----------------------------------------------------------------
cat >"$T/fx_doc_tool.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_documented(self):
        """A docstring first line."""
        self.skipTest("no tutorials checkout (set NDTWIN_TUTORIALS_DIR)")
PY
check "a docstring test skipping with a tool reason is PROVED LESS" "PROVED-LESS 2 1 1" "$(full_of fx_doc_tool)"

cat >"$T/fx_doc_unrelated.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_documented(self):
        """A docstring first line."""
        self.skipTest("unrelated")
PY
check "a docstring test skipping for no tool reason is FAIL-UNRELATED" "FAIL-UNRELATED 2 1 0" "$(full_of fx_doc_unrelated)"

# --- apostrophe: unittest prints the reason with double quotes -------------------------
cat >"$T/fx_apos_tool.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_apostrophe(self):
        self.skipTest("the tool isn't there; set NDTWIN_P4C")
PY
check "a tool reason with an apostrophe (double-quoted by unittest) is PROVED LESS" "PROVED-LESS 2 1 1" "$(full_of fx_apos_tool)"

cat >"$T/fx_apos_unrelated.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_apostrophe(self):
        self.skipTest("it isn't wired up")
PY
check "an unrelated reason with an apostrophe is FAIL-UNRELATED" "FAIL-UNRELATED 2 1 0" "$(full_of fx_apos_unrelated)"

# --- subTest -------------------------------------------------------------------------
cat >"$T/fx_sub_tool.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_sub(self):
        for i in range(3):
            with self.subTest(i=i):
                if i < 2:
                    self.skipTest("set NDTWIN_P4C (%d)" % i)
PY
check "subTest skips with a tool reason are PROVED LESS (one per subtest)" "PROVED-LESS 2 2 2" "$(full_of fx_sub_tool)"

cat >"$T/fx_sub_unrelated.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
    def test_sub(self):
        for i in range(3):
            with self.subTest(i=i):
                if i < 2:
                    self.skipTest("unrelated (%d)" % i)
PY
check "subTest skips with no tool reason are FAIL-UNRELATED" "FAIL-UNRELATED 2 2 0" "$(full_of fx_sub_unrelated)"

cat >"$T/fx_sub_only.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_sub(self):
        for i in range(2):
            with self.subTest(i=i):
                self.skipTest("set NDTWIN_P4C")
PY
check "a file whose only test skips in every subTest is FAIL-ALL-SKIPPED" "FAIL-ALL-SKIPPED" "$(verdict_of fx_sub_only)"

# --- whole-file skips ------------------------------------------------------------------
cat >"$T/fx_setupclass.py" <<'PY'
import unittest
class A(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raise unittest.SkipTest("whole file: set NDTWIN_P4C")
    def test_never(self): pass
PY
check "a setUpClass SkipTest that skips the whole file is FAIL-ALL-SKIPPED, not a note" "FAIL-ALL-SKIPPED 0 1 1" "$(full_of fx_setupclass)"

cat >"$T/fx_setupmodule.py" <<'PY'
import unittest
def setUpModule():
    raise unittest.SkipTest("whole file: set NDTWIN_P4C")
class A(unittest.TestCase):
    def test_never(self): pass
PY
check "a setUpModule SkipTest is FAIL-ALL-SKIPPED" "FAIL-ALL-SKIPPED" "$(verdict_of fx_setupmodule)"

cat >"$T/fx_allskipped.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_a(self): self.skipTest("set NDTWIN_P4C")
    def test_b(self): self.skipTest("set NDTWIN_P4C")
PY
check "a file in which every test skips, tool reason or not, is FAIL-ALL-SKIPPED" "FAIL-ALL-SKIPPED 2 2 2" "$(full_of fx_allskipped)"

cat >"$T/fx_setupclass_other.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_runs(self): pass
class B(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raise unittest.SkipTest("class B: unrelated")
    def test_never(self): pass
PY
check "a setUpClass skip in one class, others passing, is judged by its reason (unrelated: FAIL)" "FAIL-UNRELATED" "$(verdict_of fx_setupclass_other)"

# --- the ordinary shapes the lane must still get right -------------------------------------
cat >"$T/fx_pass.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_a(self): pass
    def test_b(self): pass
PY
check "no skips, all passing: PASS" "PASS 2 0 0" "$(full_of fx_pass)"

cat >"$T/fx_red.py" <<'PY'
import unittest
class A(unittest.TestCase):
    def test_a(self): self.assertEqual(1, 2)
    def test_b(self): self.skipTest("set NDTWIN_P4C")
PY
check "a failing test is FAIL-RC whatever else skipped" "FAIL-RC" "$(verdict_of fx_red)"

# Python 3.12+ exits 5 for a file that collects nothing (FAIL-RC); older ones exit 0 over "Ran 0 tests", which is
# the shape this check is about. That one log is therefore written by hand, not produced by unittest.
printf '%s\n' "----------------------------------------------------------------------" "Ran 0 tests in 0.000s" "" "OK" >"$T/fx_empty.log"
check "a file that collects nothing and exits 0 is FAIL-NO-TESTS" "FAIL-NO-TESTS 0 0 0" "$(l1_exercise_verdict "$T/fx_empty.log" 0)"

cat >"$T/fx_noisy.py" <<'PY'
import sys, unittest
class A(unittest.TestCase):
    def test_noisy(self):
        sys.stderr.write("a log line from inside the test\n")
    def test_needs_tool(self): self.skipTest("set NDTWIN_P4DEV_VENV")
PY
check "a passing test that logged to stderr still counts as a pass (PROVED LESS, not all-skipped)" "PROVED-LESS" "$(verdict_of fx_noisy)"

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
