#!/usr/bin/env python3
"""Does the temp-path gate see the defect it exists for -- and stay quiet about everything else?

[Co-developed with claude code -- Adam]

Decision E-17 (2026-09-07 grill 4E). `c3d99d00` fixed six fixtures whose temp path was the same
string in every process; `ctest -j2` was red on that and `-j1` was green, which is how a race gets
filed as "flaky". `tests/shell/check_test_tmpdirs.py` is the rule that stops the seventh.

🔴 The load-bearing half of this file is the NEGATIVE direction. A checker that reported every
`/tmp` it saw would pass every positive case here and be switched off inside a week, because this
tree is full of `/tmp` paths that are argv for a parser, a stub's return value, an injection
payload asserted never to run, or the left operand of a glob comparison. Every positive case is
therefore paired with a negative one that differs in exactly the property the rule names.

Cases run against SYNTHETIC files in a temp directory: the real tests change under other sessions'
hands all night, and the shapes are the thing under test. TheRealTreeIsClean is the exception, and
it asserts what the whole gate is for.

🔴 Every synthetic file below lives in a TRIPLE-QUOTED string, which the scanner treats as data --
so this file scans clean while being full of the paths it is about. That is a rule of the scanner,
not an accident, and NoFalsePositives.test_a_triple_quoted_blob_is_data is the case that holds it.

    python3 tests/python/test_check_test_tmpdirs.py
    CHECK_TMPDIRS_UNDER_TEST=/tmp/x/check.py python3 tests/python/test_check_test_tmpdirs.py
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CHECKER = os.environ.get("CHECK_TMPDIRS_UNDER_TEST",
                         os.path.join(REPO, "tests", "shell", "check_test_tmpdirs.py"))


def load_checker():
    """The module under test -- the real one, or the mutated copy the gate points us at."""
    spec = importlib.util.spec_from_file_location("check_test_tmpdirs_under_test", CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# =================================================================================================
# Synthetic files. One shape per case, written the way this repo really writes that shape.
# =================================================================================================

# (a) The defect itself, as LaunchLayoutRig had it before c3d99d00: a constant joined onto
#     temp_directory_path(). Note the creating call is a LATER statement -- which is why the C++
#     rule does not require materialisation in the same statement.
CPP_CONSTANT_ROOT = r"""#include <filesystem>
#include <fstream>

class Rig
{
  public:
    Rig()
    {
        m_root = std::filesystem::temp_directory_path() / "ndtwin_case_fixed";
        std::filesystem::remove_all(m_root);
        std::filesystem::create_directories(m_root);
    }

  private:
    std::filesystem::path m_root;
};
"""

# (b) The same fixture after c3d99d00. One std::to_string is the whole difference.
CPP_PID_ROOT = r"""#include <filesystem>
#include <fstream>
#include <unistd.h>

class Rig
{
  public:
    Rig()
    {
        m_root = std::filesystem::temp_directory_path() /
                 ("ndtwin_case_fixed." + std::to_string(::getpid()));
        std::filesystem::remove_all(m_root);
        std::filesystem::create_directories(m_root);
    }

  private:
    std::filesystem::path m_root;
};
"""

# (c) A per-process COUNTER and nothing else -- test_SwitchKindDispatch's and
#     test_LeftBandwidthCapacity's shape. The counter restarts at 0 in every process, so two
#     processes both write ndt_topo_test_1.json. This is the case a gate that only looked for
#     "a constant string" would miss: there is no constant here.
CPP_COUNTER_ONLY = r"""#include <filesystem>
#include <fstream>

class TempTopology
{
  public:
    explicit TempTopology(const std::string& body)
    {
        m_path = std::filesystem::temp_directory_path() /
                 ("ndt_topo_test_" + std::to_string(++s_counter) + ".json");
        std::ofstream ofs(m_path);
        ofs << body;
    }

  private:
    std::filesystem::path m_path;
    static int s_counter;
};
"""

# (d) The comment that RECORDS the defect. tests/test_IntentTaskOutcomes.cpp:470 carries exactly
#     this, quoting the line that must not come back; a gate that reported it would be telling
#     people to delete the explanation.
CPP_DEFECT_IN_A_COMMENT = r"""#include <filesystem>
#include <unistd.h>

/**
 * WHICH LINE MAKES THIS RED: restore the constant root in the constructor
 * (`m_root = std::filesystem::temp_directory_path() / "ndtwin_test_intent_task_outcomes";`).
 */
class Rig
{
  public:
    Rig()
    {
        // m_root = std::filesystem::temp_directory_path() / "ndtwin_case_fixed";
        m_root = std::filesystem::temp_directory_path() / std::to_string(::getpid());
    }

  private:
    std::filesystem::path m_root;
};
"""

# (e) /tmp literals that are DATA. Every one of these is a real line in this tree (test_ExecArgv,
#     test_LoggerCliArgs, test_SwitchKindDispatch, test_GoldenFixture). The raw string holds an
#     apostrophe, which is also the construct that made a naive comment stripper swallow the file.
CPP_TMP_LITERALS_THAT_ARE_DATA = r"""#include <string>
#include <vector>

const char* const kHostileValue = R"(x'; touch /tmp/ndtwin-pwned; echo ')";

TEST(LoggerCliArgs, ALogfilePathIsCarriedThrough)
{
    Argv a{"ndtwin_kernel", "--logfile", "/tmp/chosen-by-the-operator.log"};
    EXPECT_EQ(cfg.filePath, "/tmp/chosen-by-the-operator.log");
}

TEST(SwitchKindDispatch, TheOverrideIsRead)
{
    ScopedTopoEnv env("/tmp/ndt_override_mininet.json");
    EXPECT_EQ(monitor->activeTopologyPath(), "/tmp/ndt_override_mininet.json");
}
"""

# (f) A /tmp literal in C++ that IS opened. Different from (e) by the presence of the ofstream,
#     which is the whole rule.
CPP_TMP_LITERAL_OPENED = r"""#include <fstream>

void writeIt()
{
    std::ofstream out("/tmp/ndtwin_case_written.json");
    out << "{}";
}
"""

# --- Python ------------------------------------------------------------------------------------
PY_CONSTANT_OPENED = '''import os


def test_it():
    with open("/tmp/ndtwin_case_py.json", "w") as fh:
        fh.write("{}")
'''

PY_PID_OPENED = '''import os


def test_it():
    with open("/tmp/ndtwin_case_py.%d.json" % os.getpid(), "w") as fh:
        fh.write("{}")
'''

# 🔴 The M4 negative control, and the only case where `mkdtemp` is the ONLY thing that saves it:
# the parent directory is a constant, and mkdtemp still cannot collide because the kernel picks
# the leaf. A gate widened to report mkdtemp reports this one.
PY_MKDTEMP_UNDER_A_FIXED_PARENT = '''import tempfile


def test_it():
    d = tempfile.mkdtemp(dir="/tmp/ndtwin_case_pool")
    return d
'''

PY_TEMPFILE_IS_FINE = '''import tempfile


class T:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = tempfile.mkdtemp(prefix="ndtwin_case_")
'''

# A constant that is never opened: test_cpu_gate_lifetime.py:456's shape, a fabricated path that
# is asserted to be RECORDED, not read.
PY_CONSTANT_NOT_OPENED = '''def test_it(cg):
    cg.PROCFS = "/tmp/fabricated"
    assert record()["procfs"] == "/tmp/fabricated"
'''

# One hop through a name -- the case same-statement matching alone would miss.
PY_CONSTANT_THROUGH_A_NAME = '''import os

ROOT = "/tmp/ndtwin_case_named"


def test_it():
    os.makedirs(ROOT)
'''

# --- shell ---------------------------------------------------------------------------------------
SH_MKDIR_CONSTANT = """#!/usr/bin/env bash
set -uo pipefail
mkdir -p /tmp/ndtwin-case-dir
echo hi > /tmp/ndtwin-case-dir/marker
"""

SH_MKTEMP = """#!/usr/bin/env bash
set -uo pipefail
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndtwin-case-XXXXXX")
trap 'rm -rf "$BK"' EXIT
mkdir -p "$BK/inner"
"""

SH_PID = """#!/usr/bin/env bash
set -uo pipefail
OUT=/tmp/ndtwin-case.$$.log
rm -f "$OUT"
echo hi > "$OUT"
"""

# mutate_logger_cli.sh's shape before this gate found it: a constant name bound once, deleted
# somewhere else. The report has to land on the line that CHOSE the name, not on the rm.
SH_CONSTANT_THROUGH_A_NAME = """#!/usr/bin/env bash
set -uo pipefail
NOFILE=/tmp/ndtwin-case-should-not-exist.log
run_case() {
    rm -f "$NOFILE"
    "$KBIN" --help --logfile "$NOFILE"
    [[ -e "$NOFILE" ]] && { echo "the --help path opened $NOFILE"; return; }
}
"""

# Everything here is a /tmp path that is never created: a stub's return value inside a
# single-quoted blob, a glob guard, a string the suite only derives other strings from, and a
# path handed to a program as an argument. All four are real lines in tests/shell.
SH_TMP_WORDS_THAT_ARE_DATA = """#!/usr/bin/env bash
set -uo pipefail
STUBS='
host_count() { echo 4; }; topo_for_hosts() { echo /tmp/x.json; };'
B=/tmp/round/run_f5.log
export LOG="/tmp/round/run_f5.dryrun.selftest.log"
check "case 1  one suffix" "/tmp/round/run_f5.dryrun.log" "$(derive_log "$B" dryrun)"
[[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-case-* ]] && rm -rf "$TMPROOT"
"$KBIN" --help --topology /tmp/ndtwin-gate-topo.json
printf 'KERNEL_DIRS=/tmp\\n' > "$f"
"""

# A heredoc body: content written into some other file, and in this directory usually a whole
# Python program. Also the construct a `<<<` herestring was misread as.
SH_HEREDOC_BODY_AND_HERESTRING = """#!/usr/bin/env bash
set -uo pipefail
T="$(mktemp -d "${TMPDIR:-/tmp}/ndtwin-case-XXXXXX")"
cat > "$T/prog.py" <<'PY'
import os
os.makedirs("/tmp/written-by-the-program-not-by-this-gate")
PY
FAILED=$(sed -n 's/^\\[  FAILED  \\] \\(.*\\)/\\1/p' <<<"$OUT" \\
         | sort -u)
mkdir -p "$T/inner"
"""


def write_tree(root, files):
    """files: {relative path: contents}. Creates tests/, tests/python/, tests/shell/ as needed."""
    for rel, body in files.items():
        target = os.path.join(root, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(body)


class TreeCase(unittest.TestCase):
    """A synthetic repo per test, scanned exactly the way the real one is."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="check_tmpdirs_case_%d_" % os.getpid())
        self.addCleanup(shutil.rmtree, self.root, True)

    def scan(self, files):
        write_tree(self.root, files)
        return load_checker().scan_tree(self.root)

    def run_cli(self, files, extra=()):
        write_tree(self.root, files)
        return subprocess.run([sys.executable, CHECKER, "--repo", self.root] + list(extra),
                              capture_output=True, text=True)

    def assertFlags(self, files, rel, needle=""):
        findings, scanned = self.scan(files)
        self.assertTrue(scanned, "nothing was scanned at all")
        hits = [f for f in findings if f[0] == rel]
        self.assertTrue(hits, "%s was not reported. findings=%r" % (rel, findings))
        if needle:
            self.assertIn(needle, " ".join(f[2] for f in hits))
        for _path, _line, why, _ctx in hits:
            self.assertFalse(why.startswith(load_checker().NOT_CHECKED),
                             "reported as unreadable, not as a finding: %s" % why)
        return hits

    def assertClean(self, files):
        findings, scanned = self.scan(files)
        self.assertTrue(scanned, "nothing was scanned at all")
        self.assertEqual([], findings, "expected no findings, got %r" % (findings,))


class TheDefectIsCaught(TreeCase):
    """The six shapes c3d99d00 fixed, and the two other languages."""

    def test_a_constant_joined_onto_temp_directory_path(self):
        hits = self.assertFlags({"tests/test_Rig.cpp": CPP_CONSTANT_ROOT}, "tests/test_Rig.cpp",
                                "temp_directory_path")
        self.assertIn("ndtwin_case_fixed", hits[0][3])

    def test_a_per_process_counter_is_not_per_process(self):
        """The counter restarts at 0 in every process. Two of the six looked like this, and a
        rule that only knew about constant strings would have called both of them fine."""
        self.assertFlags({"tests/test_Topo.cpp": CPP_COUNTER_ONLY}, "tests/test_Topo.cpp")

    def test_a_tmp_literal_that_is_actually_opened(self):
        self.assertFlags({"tests/test_W.cpp": CPP_TMP_LITERAL_OPENED}, "tests/test_W.cpp",
                         "/tmp/ndtwin_case_written.json")

    def test_python_open_of_a_constant(self):
        self.assertFlags({"tests/python/test_x.py": PY_CONSTANT_OPENED}, "tests/python/test_x.py",
                         "/tmp/ndtwin_case_py.json")

    def test_python_constant_reached_through_a_name(self):
        hits = self.assertFlags({"tests/python/test_x.py": PY_CONSTANT_THROUGH_A_NAME},
                                "tests/python/test_x.py", "ROOT")
        self.assertEqual(3, hits[0][1], "the report belongs on the line that chose the name")

    def test_shell_mkdir_of_a_constant(self):
        self.assertFlags({"tests/shell/test_x.sh": SH_MKDIR_CONSTANT}, "tests/shell/test_x.sh",
                         "/tmp/ndtwin-case-dir")

    def test_shell_constant_reached_through_a_name(self):
        """mutate_logger_cli.sh's shape: bound on one line, deleted on another."""
        hits = self.assertFlags({"tests/shell/test_x.sh": SH_CONSTANT_THROUGH_A_NAME},
                                "tests/shell/test_x.sh", "NOFILE")
        self.assertEqual(3, hits[0][1], "the report belongs on the line that chose the name")

    def test_a_redirect_target_counts_as_creating_the_file(self):
        hits = self.assertFlags({"tests/shell/test_x.sh": SH_MKDIR_CONSTANT},
                                "tests/shell/test_x.sh")
        self.assertTrue(any("marker" in f[2] for f in hits),
                        "the `> /tmp/.../marker` redirect was not seen: %r" % (hits,))


class NoFalsePositives(TreeCase):
    """Each of these differs from a case above in exactly the property the rule names."""

    def test_the_same_fixture_with_getpid(self):
        self.assertClean({"tests/test_Rig.cpp": CPP_PID_ROOT})

    def test_a_triple_quoted_blob_is_data(self):
        """This very file is the reason: it carries fifteen synthetic sources full of /tmp paths,
        and so does tests/python/test_check_gate_anchors.py, whose blobs are shell gates that are
        parsed and never run.

        🔴 The blob has to carry an embedded `open(... "w")`, not just a shell `mkdir`. Without a
        PYTHON write in it there is nothing for the same-statement rule to trip over, and the case
        stays green even when the skip is removed -- which is how the first version of this test
        let M11 survive. This is GATE_CASE_FILES's shape from test_check_gate_anchors.py:256,
        verbatim in structure.
        """
        blob = ('GATE_CASE_FILES = r"""#!/usr/bin/env bash\n'
                'A=/tmp/mutate-shape-casefiles\n'
                'mkdir -p "$A"\n'
                'python3 - "$SRC" "$A/m1.old" <<\'PY\'\n'
                'import sys, io\n'
                'io.open(sys.argv[1], "w").write(io.open(sys.argv[2]).read())\n'
                'PY\n'
                '"""\n')
        self.assertClean({"tests/python/test_x.py": blob})

    def test_a_defect_quoted_in_a_c_comment(self):
        self.assertClean({"tests/test_Rig.cpp": CPP_DEFECT_IN_A_COMMENT})

    def test_tmp_literals_that_are_argv_payloads_and_assertions(self):
        self.assertClean({"tests/test_Data.cpp": CPP_TMP_LITERALS_THAT_ARE_DATA})

    def test_python_tempfile(self):
        self.assertClean({"tests/python/test_x.py": PY_TEMPFILE_IS_FINE})

    def test_mkdtemp_under_a_fixed_parent_cannot_collide(self):
        """🔴 The widening control. `/tmp/ndtwin_case_pool` is a constant and mkdtemp is the only
        thing that makes the result unique -- exactly the API a gate on this subject is supposed
        to steer people towards. Reporting it would be a false alarm, and mutate M4 checks that
        the gate has not been widened into making one."""
        self.assertClean({"tests/python/test_x.py": PY_MKDTEMP_UNDER_A_FIXED_PARENT})

    def test_python_pid(self):
        self.assertClean({"tests/python/test_x.py": PY_PID_OPENED})

    def test_a_python_constant_that_is_never_opened(self):
        self.assertClean({"tests/python/test_x.py": PY_CONSTANT_NOT_OPENED})

    def test_shell_mktemp(self):
        self.assertClean({"tests/shell/test_x.sh": SH_MKTEMP})

    def test_shell_dollar_dollar(self):
        self.assertClean({"tests/shell/test_x.sh": SH_PID})

    def test_shell_words_that_are_data(self):
        self.assertClean({"tests/shell/test_x.sh": SH_TMP_WORDS_THAT_ARE_DATA})

    def test_a_heredoc_body_belongs_to_the_file_it_is_written_into(self):
        self.assertClean({"tests/shell/test_x.sh": SH_HEREDOC_BODY_AND_HERESTRING})


class ItSaysSoWhenItCannotRead(TreeCase):
    """L-3's lesson: "no findings" and "could not look" must not print the same way.

    Two of the three parser bugs found while writing this gate made whole real files scan green.
    """

    def test_an_unterminated_quote_is_not_a_clean_file(self):
        bad = '#!/usr/bin/env bash\necho "this quote never closes\nmkdir -p /tmp/ndtwin-case-x\n'
        findings, _ = self.scan({"tests/shell/test_x.sh": bad})
        self.assertTrue(findings, "an unreadable file was reported as having nothing in it")
        self.assertTrue(findings[0][2].startswith(load_checker().NOT_CHECKED), findings)

    def test_an_unreadable_file_exits_2_not_0_and_not_1(self):
        bad = '#!/usr/bin/env bash\necho "this quote never closes\n'
        proc = self.run_cli({"tests/shell/test_x.sh": bad})
        self.assertEqual(2, proc.returncode, proc.stdout + proc.stderr)
        self.assertIn("COULD NOT BE READ", proc.stderr)

    def test_a_herestring_is_not_a_heredoc(self):
        """`<<<"$OUT"` read as `<<"` swallowed the remaining 482 lines of mutate_logger_cli.sh and
        the whole gate scanned clean. The synthetic file has a real finding AFTER the herestring:
        if the herestring is misread, the finding disappears."""
        text = ('#!/usr/bin/env bash\n'
                'FAILED=$(sed -n "s/x/y/p" <<<"$OUT")\n'
                'mkdir -p /tmp/ndtwin-case-after-the-herestring\n')
        self.assertFlags({"tests/shell/test_x.sh": text}, "tests/shell/test_x.sh",
                         "/tmp/ndtwin-case-after-the-herestring")

    def test_quoting_restarts_inside_a_command_substitution(self):
        """`"$( ... )"` is a fresh quoting context, so the commands inside it are commands.

        Reading it as plain string content is what left the scanner mid-string for the rest of
        test_l1_shell_scoring.sh and test_ndtwin_lab_config.sh -- but 🔴 asserting on THAT is a
        trap: whether a mis-paired quote ends the file open depends on how many quotes come after
        it, so an excerpt of those files balances by accident and the case stays green while the
        real files are unreadable. This asserts the capability instead, which does not depend on
        parity: a write nested inside a quoted substitution is a write, and the scanner has to see
        it. The second half is the same shape as l1's line 219, held to being readable.
        """
        nested = ('#!/usr/bin/env bash\n'
                  'out="$( mkdir -p /tmp/ndtwin-case-inside-a-subst && echo done )"\n')
        self.assertFlags({"tests/shell/test_x.sh": nested}, "tests/shell/test_x.sh",
                         "/tmp/ndtwin-case-inside-a-subst")

        module = load_checker()
        l1_shape = ('#!/usr/bin/env bash\n'
                    'check "C  $name\'s last line scores non-zero (it is \'$line\')" "nonzero" \\\n'
                    '      "$( [[ "$(summary_of "$line" | cut -d\' \' -f1)" -gt 0 ]]'
                    ' && echo nonzero || echo zero )"\n')
        self.assertIsNone(module._sh_tokens(l1_shape)[1],
                          "l1's line 219 was read as an unterminated string")


class TheExitCodeAndTheSuites(TreeCase):
    """What a caller sees, and which files are looked at."""

    def test_a_clean_tree_exits_0(self):
        proc = self.run_cli({"tests/test_Rig.cpp": CPP_PID_ROOT,
                             "tests/shell/test_x.sh": SH_MKTEMP})
        self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
        self.assertIn("0 fixed temp paths", proc.stdout)

    def test_a_tree_with_a_fixed_path_exits_1_and_names_it(self):
        """🔴 M3's case. A gate that finds everything and exits 0 is worse than no gate: the run
        goes green and the report reads clean."""
        proc = self.run_cli({"tests/test_Rig.cpp": CPP_CONSTANT_ROOT})
        self.assertEqual(1, proc.returncode, proc.stdout + proc.stderr)
        self.assertIn("tests/test_Rig.cpp:", proc.stdout)
        self.assertIn("temp_directory_path", proc.stdout)

    def test_the_cpp_suite_is_scanned_by_the_tree_walk(self):
        """🔴 M1's case. The defect was measured in tests/*.cpp; a gate that stopped globbing them
        would still be green on every other case in this file."""
        findings, scanned = self.scan({"tests/test_Rig.cpp": CPP_CONSTANT_ROOT,
                                       "tests/python/test_x.py": PY_TEMPFILE_IS_FINE,
                                       "tests/shell/test_x.sh": SH_MKTEMP})
        self.assertEqual(3, scanned, "the walk did not visit all three suites")
        self.assertEqual(["tests/test_Rig.cpp"], [f[0] for f in findings])

    def test_a_single_file_argument_is_dispatched_by_extension(self):
        write_tree(self.root, {"tests/test_Rig.cpp": CPP_CONSTANT_ROOT})
        proc = subprocess.run([sys.executable, CHECKER,
                               os.path.join(self.root, "tests", "test_Rig.cpp")],
                              capture_output=True, text=True)
        self.assertEqual(1, proc.returncode, proc.stdout + proc.stderr)

    def test_the_reason_says_why_rather_than_just_naming_the_line(self):
        findings, _ = self.scan({"tests/test_Rig.cpp": CPP_CONSTANT_ROOT})
        why = findings[0][2]
        self.assertIn("every process", why)
        self.assertIn("getpid", why)


class TheRealTreeIsClean(unittest.TestCase):
    """The whole point: this repo, at this rev, has no fixed temp path any test creates.

    Not a synthetic tree and not a shape -- the tree the gate is being adopted for. If another
    session adds a fixture with a constant path tonight, this goes red, and that is the gate
    working rather than the test being wrong.
    """

    def setUp(self):
        if not os.path.isdir(os.path.join(REPO, "tests")):
            self.fail("no tests/ directory at %s -- nothing was checked" % REPO)

    def test_the_repo_scans_clean(self):
        proc = subprocess.run([sys.executable, CHECKER, "--repo", REPO],
                              capture_output=True, text=True)
        self.assertEqual(0, proc.returncode,
                         "check_test_tmpdirs is not clean on this tree:\n%s%s"
                         % (proc.stdout, proc.stderr))

    def test_it_actually_looked_at_the_six_fixtures_c3d99d00_fixed(self):
        """A clean run means nothing if the six files were not opened. Each of them still names
        temp_directory_path(), and the scanner has to reach every one of those call sites."""
        module = load_checker()
        six = ["test_IntentTaskOutcomes.cpp", "test_ApiKeyNotLogged.cpp",
               "test_HistoricalLogging.cpp", "test_SwitchKindDispatch.cpp",
               "test_LeftBandwidthCapacity.cpp", "test_SFlowEmitterRoundtrip.cpp"]
        for name in six:
            path = os.path.join(REPO, "tests", name)
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            code, unreadable = module.strip_cpp_comments(text)
            self.assertIsNone(unreadable, "%s: %s" % (name, unreadable))
            sites = [m for m in module.CPP_TEMP_ROOT.finditer(code)
                     if not m.group(0).startswith("/")]
            self.assertTrue(sites, "%s: the scanner found no temp_directory_path() call at all "
                                   "-- a clean verdict on it proves nothing" % name)
            for site in sites:
                stmt = module._cpp_statement(code, site.start())
                self.assertTrue(module.has_per_process_marker(stmt),
                                "%s: %s" % (name, module._one_line(stmt)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
