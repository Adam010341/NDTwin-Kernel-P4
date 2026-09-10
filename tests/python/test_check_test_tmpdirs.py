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

# =================================================================================================
# B12 (2026-09-11): the spellings the gate USED TO let through.
#
# hunt-0911/F-B0-B12-REPORT.md §3.1 rows (2)d..(2)h put five synthetic inputs through this scanner
# and got `0 fixed temp paths`, rc 0, out of every one of them. None of the five differs from a
# case above in the property the rule names -- each differs only in HOW the same fixed temp path is
# SPELLED. The cases below are those five inputs, verbatim in shape, plus a sixth of the same
# family found while reproducing them, and the negative controls that keep each widening from
# becoming a nuisance.
# =================================================================================================

# (2)d The escape that motivated the whole ticket: PER_PROCESS_MARKERS was a SUBSTRING test, so a
#      variable whose NAME contains "mkdtemp" made every statement it appears in look safe. The
#      path here is a constant and nothing per-process ever runs.
PY_MKDTEMP_ONLY_IN_A_VARIABLE_NAME = '''import os

mkdtemp_root = "/tmp/ndt-kiref-fixture"


def test_it():
    os.makedirs(mkdtemp_root, exist_ok=True)
'''

# 🔴 The control that pairs with it: a REAL mkdtemp call, whose leaf the kernel picks. If the
#     boundary rule is written as "mkdtemp must be followed by (" this still passes; if it is
#     written as "there must be no mkdtemp anywhere", this goes red.
PY_MKDTEMP_CALLED_THROUGH_A_NAME = '''import tempfile
import os

mkdtemp_root = tempfile.mkdtemp(prefix="ndtwin_case_")


def test_it():
    os.makedirs(mkdtemp_root + "/inner", exist_ok=True)
'''

# (2)e std::tmpnam names a temp file WITHOUT creating it. The name is never reserved, so the
#      create that follows is the classic TOCTOU race -- and the scanner did not know the spelling
#      at all: no /tmp/ literal, no temp_directory_path(), nothing to match.
CPP_TMPNAM_THEN_FOPEN = r"""#include <cstdio>

void writeIt()
{
    char* p = std::tmpnam(nullptr);
    std::FILE* fh = std::fopen(p, "w");
    std::fclose(fh);
}
"""

# 🔴 The control for it: tmpfile() is the SAFE sibling -- it creates and unlinks in one step, so
#     there is no window and no name to collide on.
CPP_TMPFILE_IS_FINE = r"""#include <cstdio>

void writeIt()
{
    std::FILE* fh = std::tmpfile();
    std::fclose(fh);
}
"""

# (2)f $TMPDIR is one string for the whole ctest run, so `$TMPDIR/name` is as fixed as
#      `/tmp/name`. The scanner knew that for shell (scan_shell's TMPDIR branch) and for
#      tempfile.gettempdir(), but not for the Python spelling of the same environment variable.
PY_TMPDIR_FROM_THE_ENVIRONMENT = '''import os


def test_it():
    root = os.environ["TMPDIR"] + "/ndt-fixture"
    os.makedirs(root, exist_ok=True)
'''

# The same shape through os.getenv, which is what half this tree writes.
PY_TMPDIR_THROUGH_GETENV = '''import os


def test_it():
    root = os.getenv("TMPDIR", "/tmp") + "/ndt-fixture"
    os.makedirs(root, exist_ok=True)
'''

# 🔴 The control: another environment variable that is not a temp root. Widening "TMPDIR" into
#     "any os.environ read" would report this, and reporting it is a nuisance.
PY_A_DIFFERENT_ENVIRONMENT_VARIABLE = '''import os


def test_it():
    root = os.environ["NDT_STATE_DIR"] + "/ndt-fixture"
    os.makedirs(root, exist_ok=True)
'''

# Found while reproducing (2)g: a BARE "/tmp" with a name joined onto it in the same statement.
# LITERAL_TEMP_ROOT requires something after `/tmp/`, so the join argument was never part of the
# match and the statement had no root at all. Nothing is assembled here -- the literal is written
# out in full -- so this is not the limit the module docstring documents; it is a hole.
PY_JOIN_ONTO_A_BARE_TMP = '''import os


def test_it():
    root = os.path.join("/tmp", "ndt-fixture")
    os.makedirs(root, exist_ok=True)
'''

PY_PATHLIB_ONTO_A_BARE_TMP = '''import pathlib


def test_it():
    root = pathlib.Path("/tmp") / "ndt-fixture"
    root.mkdir(parents=True, exist_ok=True)
'''

# 🔴 The control: "/tmp" as DATA in a statement that writes somewhere else entirely. This is
#     test_ndt_sudo_surface's and test_ndtwin_lab_config's shape -- the fixture writes a config
#     file whose CONTENTS mention /tmp -- and reporting it would be a false alarm.
PY_A_BARE_TMP_THAT_IS_ONLY_DATA = '''import os


def test_it(cfg):
    with open(cfg, "w") as fh:
        fh.write("KERNEL_DIRS=/tmp\\n")
'''

# (2)h $TMP is the same environment variable by another of its conventional names. The shell half
#      of the scanner matched the string "$TMPDIR", so `$TMP/...` -- and `$TEMP/...` -- walked past.
SH_TMP_ENV_VAR = """#!/usr/bin/env bash
set -uo pipefail
TMPROOT="$TMP/ndt-fixture"
mkdir -p "$TMPROOT"
"""

SH_TEMP_ENV_VAR = """#!/usr/bin/env bash
set -uo pipefail
mkdir -p "${TEMP}/ndt-fixture"
"""

# 🔴 The control that stops the widening from being a substring test again: $TMPROOT and $TMPFILE
#     START with TMP and are ordinary local names, not the environment's temp directory. The value
#     bound here comes from mktemp, so a scanner that reads `$TMPROOT/` as `$TMP` + `ROOT/` reports
#     a path the kernel chose.
#     🔴 And the case that pays for the whole widening: tests/shell/test_build_guard.sh:22-23,
#     verbatim in shape. `TMP` is a LOCAL name here, holding a directory mktemp chose. A local
#     assignment shadows the environment, so `$TMP` is that binding -- not the environment's temp
#     directory -- and reporting `$TMP/fake` would be a false alarm against mktemp itself.
SH_LOCAL_TMP_SHADOWS_THE_ENVIRONMENT = """#!/usr/bin/env bash
set -uo pipefail
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/fake"; mkdir -p "$FAKE"
for t in cmake ninja make; do
    printf '#!/usr/bin/env bash\\n' > "$FAKE/$t"
done
"""

SH_A_NAME_THAT_MERELY_STARTS_WITH_TMP = """#!/usr/bin/env bash
set -uo pipefail
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/ndtwin-case-XXXXXX")"
mkdir -p "$TMPROOT/inner"
touch "$TMPROOT/marker"
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


class TheRuleIsAboutTheProperty(TreeCase):
    """B12: the same fixed temp path, spelled the ways F-B0-B12-REPORT.md §3.1 got a clean run out of.

    🔴 Every case here was `0 fixed temp paths`, rc 0, on trunk c81dabbb. Not one of them differs
    from a case in TheDefectIsCaught in the property the rule names -- "a temp root, materialised,
    with nothing per-process in it". They differ only in spelling, which is not a property of the
    hazard. A gate whose findings depend on spelling reads clean for whoever writes it the other
    way, and that is indistinguishable from a tree with no defect in it.
    """

    def test_a_variable_merely_NAMED_mkdtemp_does_not_make_a_path_safe(self):
        """(2)d. PER_PROCESS_MARKERS was a substring test, so `mkdtemp_root` disarmed the rule."""
        hits = self.assertFlags({"tests/python/test_x.py": PY_MKDTEMP_ONLY_IN_A_VARIABLE_NAME},
                                "tests/python/test_x.py", "/tmp/ndt-kiref-fixture")
        self.assertEqual(3, hits[0][1], "the report belongs on the line that chose the name")

    def test_cpp_tmpnam_names_a_file_it_does_not_reserve(self):
        """(2)e. No /tmp literal and no temp_directory_path(), so the scanner saw no root at all."""
        self.assertFlags({"tests/test_T.cpp": CPP_TMPNAM_THEN_FOPEN}, "tests/test_T.cpp", "tmpnam")

    def test_python_reads_TMPDIR_out_of_the_environment(self):
        """(2)f. The shell half already knew $TMPDIR/name is fixed; the Python half did not."""
        self.assertFlags({"tests/python/test_x.py": PY_TMPDIR_FROM_THE_ENVIRONMENT},
                         "tests/python/test_x.py", "TMPDIR")

    def test_python_reads_TMPDIR_through_getenv(self):
        self.assertFlags({"tests/python/test_x.py": PY_TMPDIR_THROUGH_GETENV},
                         "tests/python/test_x.py", "TMPDIR")

    def test_a_name_joined_onto_a_bare_tmp(self):
        """Same family as (2)g but with nothing assembled: `os.path.join("/tmp", "name")`. The
        literal is written out in full, so the module docstring's "assembled from pieces" limit
        does not cover it."""
        self.assertFlags({"tests/python/test_x.py": PY_JOIN_ONTO_A_BARE_TMP},
                         "tests/python/test_x.py", "/tmp")

    def test_a_name_joined_onto_a_bare_tmp_with_pathlib(self):
        self.assertFlags({"tests/python/test_x.py": PY_PATHLIB_ONTO_A_BARE_TMP},
                         "tests/python/test_x.py", "/tmp")

    def test_shell_TMP_is_the_same_variable_as_TMPDIR(self):
        """(2)h. $TMP and $TEMP name the same directory $TMPDIR does."""
        self.assertFlags({"tests/shell/test_x.sh": SH_TMP_ENV_VAR}, "tests/shell/test_x.sh", "TMP")

    def test_shell_TEMP_is_the_same_variable_as_TMPDIR(self):
        self.assertFlags({"tests/shell/test_x.sh": SH_TEMP_ENV_VAR}, "tests/shell/test_x.sh",
                         "TEMP")


class TheWideningDidNotBecomeANuisance(TreeCase):
    """🔴 The other half of B12. Each case pairs with one above and differs in exactly the property.

    A widened gate is worth nothing if it is switched off in a week, so every spelling admitted
    above gets a control that must stay clean: a real mkdtemp reached through a variable, tmpfile()
    (which creates and unlinks in one step), an environment variable that is not a temp root, a
    bare /tmp that is only data, and a local name that merely begins with the letters TMP.
    """

    def test_a_real_mkdtemp_call_still_makes_a_path_safe(self):
        self.assertClean({"tests/python/test_x.py": PY_MKDTEMP_CALLED_THROUGH_A_NAME})

    def test_cpp_tmpfile_creates_and_unlinks_in_one_step(self):
        self.assertClean({"tests/test_T.cpp": CPP_TMPFILE_IS_FINE})

    def test_an_environment_variable_that_is_not_a_temp_root(self):
        self.assertClean({"tests/python/test_x.py": PY_A_DIFFERENT_ENVIRONMENT_VARIABLE})

    def test_a_bare_tmp_that_is_only_written_into_a_file_as_text(self):
        self.assertClean({"tests/python/test_x.py": PY_A_BARE_TMP_THAT_IS_ONLY_DATA})

    def test_a_shell_name_that_merely_starts_with_TMP(self):
        self.assertClean({"tests/shell/test_x.sh": SH_A_NAME_THAT_MERELY_STARTS_WITH_TMP})

    def test_a_local_TMP_shadows_the_environments_TMP(self):
        """🔴 tests/shell/test_build_guard.sh's shape, and the one real-tree file the widened rule
        reported before the shadow check went in. `$TMP` here is a mktemp directory."""
        self.assertClean({"tests/shell/test_x.sh": SH_LOCAL_TMP_SHADOWS_THE_ENVIRONMENT})


class TheScopeIsEveryTestNotThreeGlobs(TreeCase):
    """D1 (F-OFFLINE-1-REPORT.md §1.17): the tree walk's three globs were NOT recursive.

    `python3 tests/shell/check_test_tmpdirs.py` scanned 261 files -- exactly
    `tests/*.cpp` + `tests/python/*.py` + `tests/shell/*.sh` -- so tests/fuzz/, tests/manual/,
    p4_proxy/tests/, the two .py checkers in tests/shell/ and every .cc/.h/.hpp under tests/ were
    never opened. The report's own evidence that this is scope and not capability: naming
    `p4_proxy/tests/test_rule_install_times.py` on the command line scanned it fine.

    🔴 A clean verdict over a scope that excludes most of the tree is the L-3 shape again: the
    number printed is the number of files it looked at, and nobody reads it against the number of
    test files that exist.
    """

    def test_a_subdirectory_of_tests_is_walked(self):
        self.assertFlags({"tests/fuzz/fuzz_x.cpp": CPP_TMP_LITERAL_OPENED},
                         "tests/fuzz/fuzz_x.cpp", "/tmp/ndtwin_case_written.json")

    def test_the_python_suite_outside_tests_is_walked(self):
        self.assertFlags({"p4_proxy/tests/test_x.py": PY_CONSTANT_OPENED},
                         "p4_proxy/tests/test_x.py", "/tmp/ndtwin_case_py.json")

    def test_a_py_file_in_tests_shell_is_dispatched_by_extension(self):
        """tests/shell/ was globbed as *.sh, so check_gate_anchors.py and this gate's own
        scanner -- both of which live there -- were outside the scope of the gate they implement."""
        self.assertFlags({"tests/shell/check_x.py": PY_CONSTANT_OPENED},
                         "tests/shell/check_x.py", "/tmp/ndtwin_case_py.json")

    def test_a_header_under_tests_is_read_as_cpp(self):
        self.assertFlags({"tests/support/Rig.hpp": CPP_CONSTANT_ROOT}, "tests/support/Rig.hpp",
                         "temp_directory_path")

    def test_a_test_under_tools_is_in_scope(self):
        self.assertFlags({"tools/test_workflow/test_x.sh": SH_MKDIR_CONSTANT},
                         "tools/test_workflow/test_x.sh", "/tmp/ndtwin-case-dir")

    def test_a_driver_under_tools_is_not_a_test_and_stays_out_of_scope(self):
        """🔴 The control that keeps D1 from becoming "lint every .sh under tools/".
        tools/test_workflow/build_bmv2_fast.sh:42 binds `BUILD=/tmp/bmv2-fast-src` and rm -rf's it:
        a build CACHE, deliberately the same path every run so the next run finds it. It is not a
        test, ctest never runs it, and reporting it would be a false alarm on day one. This is the
        real file's shape, and the scan must not open it."""
        cache = ("#!/usr/bin/env bash\n"
                 "set -uo pipefail\n"
                 "BUILD=/tmp/bmv2-fast-src\n"
                 'rm -rf "$BUILD"\n')
        # The clean test file is here so that `scanned` is non-zero: "nothing was opened at all"
        # and "the driver was not opened" have to be told apart, or this case proves nothing.
        self.assertClean({"tools/test_workflow/build_something_fast.sh": cache,
                          "tools/test_workflow/test_real_one.sh": SH_MKTEMP})
        # ...and it is still reportable when a caller asks about it by name: scope, not blindness.
        write_tree(self.root, {"tools/test_workflow/build_something_fast.sh": cache})
        named = subprocess.run(
            [sys.executable, CHECKER,
             os.path.join(self.root, "tools", "test_workflow", "build_something_fast.sh")],
            capture_output=True, text=True)
        self.assertEqual(1, named.returncode, named.stdout + named.stderr)

    def test_the_count_it_prints_is_the_count_it_walked(self):
        proc = self.run_cli({"tests/test_A.cpp": CPP_PID_ROOT,
                             "tests/fuzz/fuzz_x.cpp": CPP_PID_ROOT,
                             "tests/python/test_x.py": PY_TEMPFILE_IS_FINE,
                             "tests/shell/test_x.sh": SH_MKTEMP,
                             "p4_proxy/tests/test_y.py": PY_TEMPFILE_IS_FINE})
        self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
        self.assertIn("5 file(s) scanned", proc.stdout)

    def test_the_cpp_suite_being_removed_still_takes_every_cpp_file_out(self):
        """🔴 M1's case, held against the widening. SUITES is still the one place that says which
        languages are in scope: if the C++ row goes, no recursive sweep may quietly put
        tests/**/*.cpp back, or M1 survives and nobody notices the gate stopped reading C++."""
        module = load_checker()
        cpp_rows = [row for row in module.SUITES if row[2] is module.scan_cpp]
        self.assertTrue(cpp_rows, "SUITES has no C++ row -- M1 would have nothing to remove")
        original = module.SUITES
        try:
            module.SUITES = tuple(row for row in original if row[2] is not module.scan_cpp)
            write_tree(self.root, {"tests/test_Rig.cpp": CPP_CONSTANT_ROOT,
                                   "tests/fuzz/fuzz_x.cpp": CPP_CONSTANT_ROOT,
                                   "tests/support/Rig.hpp": CPP_CONSTANT_ROOT})
            findings, scanned = module.scan_tree(self.root)
            self.assertEqual(0, scanned, "a C++ file was scanned with the C++ suite removed")
            self.assertEqual([], findings)
        finally:
            module.SUITES = original


class TheCppHalfFollowsANameToo(TreeCase):
    """D2 (F-OFFLINE-1-REPORT.md §1.17): scan_cpp did not do what the module docstring promised.

    "Variables are followed one hop, within one file" has been in KNOWN LIMITS since the gate was
    written, and scan_python and scan_shell both did it. scan_cpp did not, so the report's
    synthetic tree caught the same-statement spelling (the positive control) and missed

        const std::string root = "/tmp/ndtwin_x";
        std::filesystem::create_directories(root);

    which is the SAME defect one line apart -- and the shape five of the six fixtures c3d99d00
    fixed actually had.
    """

    SAME_STATEMENT = r"""#include <filesystem>

void go()
{
    std::filesystem::create_directories("/tmp/ndtwin_y");
}
"""

    THROUGH_A_NAME = r"""#include <filesystem>
#include <string>

void go()
{
    const std::string root = "/tmp/ndtwin_x";
    std::filesystem::create_directories(root);
}
"""

    def test_the_positive_control_the_same_statement_spelling(self):
        """Already caught before D2 was fixed. Here so that a green run below means something."""
        self.assertFlags({"tests/test_S.cpp": self.SAME_STATEMENT}, "tests/test_S.cpp",
                         "/tmp/ndtwin_y")

    def test_a_cpp_name_bound_to_a_fixed_path_and_created_one_line_later(self):
        hits = self.assertFlags({"tests/test_N.cpp": self.THROUGH_A_NAME}, "tests/test_N.cpp",
                                "/tmp/ndtwin_x")
        self.assertEqual(6, hits[0][1], "the report belongs on the line that chose the name")
        self.assertIn("root", hits[0][2])

    def test_a_cpp_name_bound_to_a_fixed_path_that_nothing_ever_creates(self):
        """🔴 The control. test_LoggerCliArgs and test_SwitchKindDispatch bind /tmp paths that are
        argv for a parser and a value read back out of the environment. One hop must not turn
        those into findings, or the C++ half becomes "no /tmp literals in tests"."""
        parser_only = r"""#include <string>

TEST(LoggerCliArgs, ALogfilePathIsCarriedThrough)
{
    const std::string chosen = "/tmp/chosen-by-the-operator.log";
    Argv a{"ndtwin_kernel", "--logfile", chosen};
    EXPECT_EQ(cfg.filePath, chosen);
}
"""
        self.assertClean({"tests/test_P.cpp": parser_only})

    def test_a_cpp_name_compared_against_is_not_a_binding(self):
        """`==` is not `=`. A guard that compares a path before writing somewhere else is the
        shape tests/shell/test_apps_stop_kills_the_group.sh:190 has in shell."""
        compared = r"""#include <filesystem>
#include <string>

void go(const std::string& path)
{
    if (path == "/tmp/ndtwin_guarded")
    {
        std::filesystem::remove_all(path);
    }
}
"""
        self.assertClean({"tests/test_C.cpp": compared})


class TheDocumentedLimitIsStillTheLimit(TreeCase):
    """(2)g, the one row of §3.1 that is NOT widened, pinned so the decision is visible.

    `os.path.join("/" + "tmp", "name")` assembles a temp root out of pieces that are individually
    not temp roots. The module docstring has said so since the gate was written, and it stays a
    limit on purpose: recognising it means constant-folding arbitrary expressions, and the next
    spelling after `"/" + "tmp"` is `"/tm" + "p"`, then `os.sep + "tmp"`, then `chr(47) + "tmp"`.
    Each pattern added closes one spelling and none of them closes the property, which is the
    failure this whole class of fix exists to stop repeating. A lint does not stop an author who
    is taking the path apart to get past it.

    🔴 If you ever widen this, delete this case and the docstring limit in the SAME commit. A
    limit that is documented in one place and enforced in another is how L-3 happened.
    """

    def test_a_temp_root_assembled_from_pieces_is_a_known_limit(self):
        assembled = ('import os\n'
                     '\n'
                     '\n'
                     'def test_it():\n'
                     '    root = os.path.join("/" + "tmp", "ndt-fixture")\n'
                     '    os.makedirs(root, exist_ok=True)\n')
        self.assertClean({"tests/python/test_x.py": assembled})


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
