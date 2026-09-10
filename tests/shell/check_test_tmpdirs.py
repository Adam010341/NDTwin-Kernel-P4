#!/usr/bin/env python3
"""Every temp path a test creates must carry something that differs per process.

[Co-developed with claude code -- Adam]

Decision E-17 (2026-09-07 grill 4E). `ctest` gives every test its own process. Six fixtures in
this suite named their temp path from a constant, or from a counter that restarts at 0 in every
process, so two processes running two different tests named the same directory -- and one
fixture's `remove_all` ran while the other process was chdir'ed inside it. `c3d99d00` fixed the
six by hand. This gate is what stops the seventh: put the constant root back and

    IntentTaskOutcomesTest.AFailedDeleteReportsTheFailureRatherThanOk
    C++ exception with description "filesystem error: cannot remove all: No such file or
    directory [/tmp/ndtwin_test_intent_task_outcomes] ..." thrown in the test fixture's
    constructor.

comes back -- but only under `-j2`, and only sometimes, which is how "just re-run it" gets
learned. A static rule does not depend on which test lost the race.

    python3 tests/shell/check_test_tmpdirs.py            # the whole suite; rc 1 if anything is fixed
    python3 tests/shell/check_test_tmpdirs.py FILE...    # just these files
    python3 tests/shell/check_test_tmpdirs.py --repo DIR # scan another checkout / a synthetic tree

=================================================================================================
THE RULE, and why it is narrower than "no /tmp literals in tests"
=================================================================================================
A fixed path is only a hazard if the test MATERIALISES it -- creates, writes, or removes
something there. A path that is only handed to a parser or compared against cannot race, and
this tree is full of those; a gate that flagged them would be turned off in a week. So a finding
needs all three of:

  (1) a TEMP ROOT      -- `temp_directory_path()`, a `/tmp/...` or `/var/tmp/...` literal, a bare
                          `/tmp` with a name joined onto it, `tmpnam`/`tempnam`, or the
                          environment's temp directory under any of its names -- shell
                          `$TMPDIR` `$TMP` `$TEMP` `$TEMPDIR`, Python `os.environ["TMPDIR"]` /
                          `os.getenv("TMPDIR")` / `tempfile.gettempdir()`;
  (2) MATERIALISATION  -- in the same statement (C++/Python) or the same command (shell), an
                          operation that makes or destroys a filesystem entry;
  (3) NO PER-PROCESS MARKER anywhere in that statement/command -- see PER_PROCESS_MARKERS.

🔴 Each of (1) and (3) is about a PROPERTY, and each of them was once a test on a SPELLING. B12
(2026-09-11, hunt-0911/F-B0-B12-REPORT.md §3.1) put five re-spellings of the same fixed temp path
through this scanner and got `0 fixed temp paths`, rc 0, out of every one: a variable merely NAMED
`mkdtemp_root`, `std::tmpnam`, `os.environ["TMPDIR"]`, `os.path.join("/tmp", name)`, and `$TMP`.
None of them differs from a reported case in the property; they differ in how it is written. Every
widening that closed one is paired here with the control that keeps it from becoming a nuisance,
because a gate people switch off reports nothing at all.

Worked examples of (2), all real lines in this tree that this gate deliberately does NOT report:

  tests/test_ExecArgv.cpp:44        R"(x'; touch /tmp/ndtwin-pwned; echo ')"
                                    a shell-injection payload the test asserts never runs. It
                                    contains the word "touch"; it is not a C++ filesystem call.
  tests/test_LoggerCliArgs.cpp:298  Argv a{..., "--logfile", "/tmp/chosen-by-the-operator.log"};
                                    argv for a parser test. Nothing is ever opened.
  tests/test_SwitchKindDispatch.cpp:379  ScopedTopoEnv env("/tmp/ndt_override_mininet.json");
                                    sets an environment variable and reads it back.
  tests/shell/test_ndt_sudo_surface.sh:241  topo_for_hosts() { echo /tmp/x.json; }
                                    a stub's return value, inside a single-quoted blob.
  tests/shell/test_apps_stop_kills_the_group.sh:190  [[ "$TMPROOT" == /tmp/ndt-appsgroup-* ]]
                                    a guard on a glob before an rm -rf. An operand of `==`, not
                                    an argument of a command that writes.
  tests/shell/test_log_suffix_idempotent.sh:37  B=/tmp/round/run_f5.log
                                    a string the suite only derives other strings from; `$B` is
                                    never passed to anything that touches the disk.

For (1) in C++ the gate is stricter than for the other two, on purpose: `temp_directory_path()`
is not a string you pass to a parser -- the standard defines it as the directory to create
temporary files in -- so a name joined onto it is in scope whether or not the same statement
names the call that creates the file. That is exactly the six-fixture shape c3d99d00 fixed, and
five of those six do their creating in a LATER statement than the one that names the path.

=================================================================================================
KNOWN LIMITS (documented rather than papered over -- a lint, not a proof)
=================================================================================================
 * Embedded foreign source is data, not code: a Python triple-quoted blob and a shell heredoc
   body are skipped. tests/python/test_check_gate_anchors.py carries fifteen synthetic shell
   gates in triple-quoted strings, several with a `MUT_DIR=/tmp/...` line; those gates are
   parsed by a static checker and never run. Same reason C++ comments are stripped:
   tests/test_IntentTaskOutcomes.cpp:470 quotes the defective line inside a doc comment, as the
   record of what must not come back.
 * Command substitution in shell: `"$( ... )"` restarts quoting (so the nesting parses), but the
   commands inside a quoted substitution stay inside one word -- enough to see a `mktemp` in it,
   not enough to attribute a write nested in it. An UNQUOTED `$( ... )` is analysed normally.
 * A file this scanner cannot read is reported as NOT CHECKED and the run exits 2 -- never as a
   clean file. Two of the three parser bugs found while writing this gate (a `<<<` herestring read
   as a heredoc; `"$( [[ "$x" ]] )"` read as an unterminated string) had made whole files scan
   green, which is the failure mode this exit code exists for.
 * Variables are followed one hop, within one file, in all three languages: `NAME=<fixed temp
   path>` is reported when `$NAME` later reaches something that writes. An indirection through a
   function's argument, or across files, is not followed. (Until 2026-09-11 this said "all three"
   and meant two: scan_cpp did not do it, which is F-OFFLINE-1-REPORT.md §1.17 D2.)
 * A path assembled from pieces that are individually not temp roots (`os.path.join("/" + "tmp",
   name)`) is not recognised, and stays a limit on purpose. Recognising it means constant-folding
   arbitrary expressions, and the spelling after `"/" + "tmp"` is `"/tm" + "p"`, then `os.sep +
   "tmp"`, then `chr(47) + "tmp"` -- one pattern per spelling and none of them the property, which
   is the trap B12 is about. A lint does not stop an author taking the path apart to get past it.
   Nothing in this tree does it; test_check_test_tmpdirs.py pins the decision.
 * SCOPE is every test in the tree: `tests/` and `p4_proxy/tests/` recursively, plus the `test_*`
   files under tools/. Harness and driver code is NOT scanned even when it lives in a directory
   with "test" in the name -- tools/test_workflow/build_bmv2_fast.sh's `BUILD=/tmp/bmv2-fast-src`
   is a build cache that exists to be found again by the next run, and the rule here is about
   files ctest gives a process of their own. A path named on the command line is always scanned,
   whatever directory it is in.
"""
import os
import re
import sys

# --- what makes a path safe ---------------------------------------------------------------------
# A marker that makes the name differ between two processes running at the same time. Substring
# match, all three languages in one list, because the same word means the same thing in each:
# ::getpid() / os.getpid(), mkdtemp(3) / tempfile.mkdtemp, mktemp(1) and its XXXXXX template.
#
# 🔴 This list is what separates a lint from a nuisance. Deleting an entry widens the gate --
# `mkdtemp` names a directory that CANNOT collide, and reporting it would be a false alarm
# against the very API the fix is supposed to steer people towards. mutate_check_test_tmpdirs.sh
# M4 removes one entry and requires the negative control to go red.
PER_PROCESS_MARKERS = (
    "getpid",             # C++ ::getpid(), Python os.getpid()
    "mkdtemp",            # mkdtemp(3), tempfile.mkdtemp -- the kernel picks the name
    "mkstemp",            # mkstemp(3), tempfile.mkstemp
    "mkostemp",
    "NamedTemporaryFile",
    "TemporaryDirectory",
    "TemporaryFile",
    "mktemp",             # mktemp(1) / mktemp -d
    "XXXXXX",             # a mktemp template, even when the caller spells it out
    "$$",                 # shell: this shell's pid
    "$BASHPID",           # shell: this subshell's pid, which $$ is not
)

# 🔴 Which of the markers above are IDENTIFIERS, i.e. must appear as a name of their own rather
# than as a run of letters inside a longer one. B12 (2026-09-11): the marker test was a plain
# substring test, so a variable CALLED `mkdtemp_root` disarmed the rule for every statement it
# appeared in -- `mkdtemp_root = "/tmp/ndt-kiref-fixture"` plus `os.makedirs(mkdtemp_root)` scanned
# clean, and nothing per-process ran anywhere in that file. A name is not a call.
#
# `XXXXXX`, `$$` and `$BASHPID` are deliberately NOT in here: they are not identifiers, and a
# seven-X template `XXXXXXX` would fail an identifier-boundary test on both sides.
_MARKER_IS_AN_IDENTIFIER = frozenset((
    "getpid", "mkdtemp", "mkstemp", "mkostemp", "NamedTemporaryFile", "TemporaryDirectory",
    "TemporaryFile", "mktemp",
))

_IDENTIFIER_BYTE = re.compile(r"[A-Za-z0-9_]")


# 🔴 A file this scanner could not read is NOT a file with no findings. check_gate_anchors.py
# learned this the expensive way (KNOWN-ISSUES L-3): four gates it could not parse were reported
# as "no anchors" for weeks. Anything carrying this prefix makes the run exit 2, which is neither
# "clean" nor "there is a fixed path here" but "go and look".
NOT_CHECKED = "NOT CHECKED: "


def has_per_process_marker(text):
    """Does anything in `text` make the name differ per process?

    An identifier marker has to be a name of its own: `tempfile.mkdtemp(...)` disarms the rule and
    `mkdtemp_root = "/tmp/fixed"` does not. See _MARKER_IS_AN_IDENTIFIER.
    """
    for marker in PER_PROCESS_MARKERS:
        if marker not in text:
            continue
        if marker not in _MARKER_IS_AN_IDENTIFIER:
            return True
        at = text.find(marker)
        while at != -1:
            before = text[at - 1:at]
            after = text[at + len(marker):at + len(marker) + 1]
            if not _IDENTIFIER_BYTE.match(before or " ") \
                    and not _IDENTIFIER_BYTE.match(after or " "):
                return True
            at = text.find(marker, at + 1)
    return False


# --- what counts as a temp root ------------------------------------------------------------------
# A literal path under the system temp directory. `/tmp` or `/var/tmp` with something after it:
# the bare directory is shared by design and names nothing.
LITERAL_TEMP_ROOT = re.compile(r"/(?:var/)?tmp/[^\s\"'`)\];,]+")

# 🔴 The C++ half of rule (1). mutate_check_test_tmpdirs.sh M2 drops the temp_directory_path
# alternative, leaving a gate that only knows the spelling C++ fixtures do not use.
CPP_TEMP_ROOT = re.compile(r"(?:\btemp_directory_path\s*\(\s*\))|(?:/(?:var/)?tmp/)")

# 🔴 The calls that hand back a temp NAME without creating anything at it. B12 (2026-09-11) row
# (2)e: `char* p = std::tmpnam(nullptr); std::fopen(p, "w");` had no /tmp literal and no
# temp_directory_path(), so the scanner saw no temp root at all and the file read clean. tmpnam(3)
# and tempnam(3) never reserve the name they return, so between the name and the create any other
# process may take it -- which is the same hazard by a different mechanism, and why both man pages
# say never to use them. There is no per-process marker that rescues these: the answer is
# mkstemp/mkdtemp, or tmpfile() (which creates and unlinks in one step and is NOT listed here).
CPP_NAME_WITHOUT_RESERVING = re.compile(r"\b(?:std::)?(?:tmpnam|tempnam)\s*\(")

# A C++ name bound to a fixed temp path, so that a create through it one statement later is still
# attributable to the line that chose it. F-OFFLINE-1-REPORT.md §1.17 D2: the module docstring has
# promised "variables are followed one hop, within one file" since the gate was written, and
# scan_python and scan_shell did it -- scan_cpp did not, so
# `const std::string root = "/tmp/x"; std::filesystem::create_directories(root);` scanned clean
# next to a positive control on the same-statement spelling that was caught.
#
# The binding is recognised by the ASSIGNMENT, not by the declared type: `const std::string root =`
# and `auto root =` and `m_root =` are one shape, and a gate that listed the types would be back to
# guarding spellings. `(?!=)` keeps `path == "/tmp/x"` out, and a comparison operator immediately
# before the `=` (`!=`, `<=`, `+=`) fails the `\s*` on its own.
CPP_NAME_BOUND_TO_A_PATH = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)")

# C++ operations that make or destroy a filesystem entry. Deliberately only the C++ API: the word
# "touch" appears in this tree only inside shell payloads a test asserts are never executed.
CPP_MATERIALISERS = (
    "ofstream", "fstream", "create_director", "remove_all", "remove(", "copy_file", "copy(",
    "rename(", "fopen", "::open(", "mkdir", "mkdtemp", "mkstemp", "resize_file",
)

# Python operations that make or destroy a filesystem entry.
PY_MATERIALISERS = (
    "open(", "os.makedirs", "os.mkdir", "os.rmdir", "os.remove", "os.unlink", "os.rename",
    "shutil.", ".write_text(", ".write_bytes(", ".mkdir(", ".touch(", ".unlink(",
    "mkdtemp", "mkstemp", "NamedTemporaryFile", "TemporaryDirectory",
)

# Shell commands whose (non-flag) arguments are paths they write or delete. `>` and `>>` are
# handled separately, as operators.
SH_MATERIALISERS = frozenset((
    "mkdir", "touch", "rm", "rmdir", "cp", "mv", "ln", "tee", "install", "truncate", "dd",
    "mkfifo", "unlink", "shred",
))


# =================================================================================================
# C++
# =================================================================================================
def strip_cpp_comments(text):
    """(code, unreadable) -- // and /* */ blanked out, every other byte and newline in place.

    String literals survive -- in C++ the path IS a string literal. Raw strings (R"(...)") are
    stepped over whole, because tests/test_ExecArgv.cpp holds one containing an apostrophe and a
    naive character-literal scanner would swallow the rest of the file from there.

    `unreadable` is a reason string when a comment or a literal ran to end of file, i.e. when this
    scanner lost track and everything after that point was read as the wrong kind of text.
    """
    unreadable = None
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif c == "/" and nxt == "*":
            j = text.find("*/", i + 2)
            if j == -1:
                unreadable = "a /* block comment runs to end of file"
            j = n if j == -1 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
            i = j
        elif c == "R" and nxt == '"' and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            k = text.find("(", i + 2)
            if k == -1:
                out.append(c)
                i += 1
                continue
            close = ")" + text[i + 2:k] + '"'
            end = text.find(close, k)
            if end == -1:
                unreadable = "a raw string literal runs to end of file"
            j = n if end == -1 else end + len(close)
            out.append(text[i:j])
            i = j
        elif c == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            else:
                unreadable = "a string literal runs to end of file"
            out.append(text[i:j])
            i = j
        elif c == "'":
            # A character literal, or a digit separator (1'000), or an apostrophe left over from a
            # construct this scanner does not model. Only consume it as a literal when it closes
            # within a few characters; otherwise it is one ordinary byte.
            j = text.find("'", i + 1)
            if j != -1 and j - i <= 5 and "\n" not in text[i:j]:
                out.append(text[i:j + 1])
                i = j + 1
            else:
                out.append(c)
                i += 1
        else:
            out.append(c)
            i += 1
    code = "".join(out)
    if len(code) != len(text):                  # the stripper must be byte-for-byte positional
        unreadable = "the comment stripper lost its place (%d bytes in, %d out)" % (len(text),
                                                                                    len(code))
    return code, unreadable


def _cpp_statement(text, pos):
    """The statement around offset `pos`: from the previous ; { } to the next one."""
    start = max(text.rfind(";", 0, pos), text.rfind("{", 0, pos), text.rfind("}", 0, pos)) + 1
    ends = [p for p in (text.find(";", pos), text.find("{", pos), text.find("}", pos)) if p != -1]
    end = min(ends) if ends else len(text)
    return text[start:end + 1]


def _cpp_statements(text):
    """[(statement text, first line number)] -- the same split _cpp_statement makes, walked."""
    out = []
    start, line = 0, 1

    def add(stmt, at):
        body = stmt.lstrip()
        if body:
            out.append((stmt, at + stmt[:len(stmt) - len(body)].count("\n")))

    for i, ch in enumerate(text):
        if ch in ";{}":
            stmt = text[start:i + 1]
            add(stmt, line)
            line += stmt.count("\n")
            start = i + 1
    add(text[start:], line)
    return out


def scan_cpp(text, path):
    """Findings in one C++ test translation unit."""
    findings = []
    code, unreadable = strip_cpp_comments(text)
    if unreadable:
        return [(path, 1, NOT_CHECKED + unreadable, "")]

    # tmpnam(3) / tempnam(3): a name nothing holds. No marker rescues these, so this loop asks
    # nothing about the rest of the statement.
    for m in CPP_NAME_WITHOUT_RESERVING.finditer(code):
        stmt = _cpp_statement(code, m.start())
        findings.append((path, code.count("\n", 0, m.start()) + 1,
                         "%s hands back a temp path without creating anything at it, so the name "
                         "is never reserved and the create that follows is the race; use mkstemp "
                         "/ mkdtemp, or tmpfile() if the file need not have a name"
                         % m.group(0).rstrip("( "),
                         _one_line(stmt)))

    # D2 (F-OFFLINE-1-REPORT.md §1.17): a name bound to a fixed temp path here, materialised
    # through that name in a LATER statement. `fixed_names[name] = (line, shown)`.
    fixed_names = {}
    for m in CPP_TEMP_ROOT.finditer(code):
        if not m.group(0).startswith("/"):
            continue        # temp_directory_path() is reported by the loop below either way
        stmt = _cpp_statement(code, m.start())
        if has_per_process_marker(stmt):
            continue
        if any(tok in stmt for tok in CPP_MATERIALISERS):
            continue                     # reported by the same-statement rule below
        bound = CPP_NAME_BOUND_TO_A_PATH.search(stmt)
        if not bound:
            continue
        hit = LITERAL_TEMP_ROOT.search(code, m.start())
        fixed_names.setdefault(bound.group(1),
                               (code.count("\n", 0, m.start()) + 1,
                                hit.group(0) if hit else m.group(0)))
    if fixed_names:
        for stmt, stmt_line in _cpp_statements(code):
            if not any(tok in stmt for tok in CPP_MATERIALISERS):
                continue
            if has_per_process_marker(stmt):
                continue
            for name in set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", stmt)):
                if name not in fixed_names:
                    continue
                where, shown = fixed_names.pop(name)
                if where == stmt_line:
                    continue
                findings.append((path, where,
                                 "%s is a fixed %s path, and line %d creates or deletes it; no "
                                 "::getpid() / mkstemp / mkdtemp anywhere in between"
                                 % (name, shown, stmt_line),
                                 _one_line(stmt)))

    for m in CPP_TEMP_ROOT.finditer(code):
        stmt = _cpp_statement(code, m.start())
        if has_per_process_marker(stmt):
            continue
        line = code.count("\n", 0, m.start()) + 1
        if m.group(0).startswith("/"):
            # A /tmp literal. Only a hazard when this statement also does the creating -- see the
            # worked examples in the module docstring for the ones this skips.
            if not any(tok in stmt for tok in CPP_MATERIALISERS):
                continue
            hit = LITERAL_TEMP_ROOT.search(code, m.start())
            shown = hit.group(0) if hit else m.group(0)
            why = ("a fixed %s path that this statement creates or deletes, with no getpid() / "
                   "mkstemp / mkdtemp in it" % shown)
        else:
            # temp_directory_path(). In scope whether or not this statement does the creating: it
            # exists only to name a file the test is about to make.
            if "/" not in stmt[stmt.find("temp_directory_path"):]:
                continue        # the temp directory itself, with no name joined onto it
            why = ("temp_directory_path() joined with a name that is the same in every process "
                   "(no getpid() / mkstemp / mkdtemp in this statement)")
        findings.append((path, line, why, _one_line(stmt)))
    return sorted(findings, key=lambda f: f[1])


# =================================================================================================
# Python
# =================================================================================================
# The temp directory named some way other than by a `/tmp/...` literal. `tempfile.gettempdir()`
# was here from the start; B12 (2026-09-11) added the two spellings rows (2)f and the bare-root
# half of (2)g escaped through.
#
#   (2)f  os.environ["TMPDIR"] / os.environ.get("TMPDIR") / os.getenv("TMPDIR") -- ONE string for
#         the whole ctest run, so `$TMPDIR/name` is as fixed as `/tmp/name`. scan_shell had known
#         this since the gate was written; scan_python did not. Only the four conventional names
#         count: widening this to "any environment variable" would report every fixture that reads
#         a directory out of the environment, which is most of them.
#   bare  a `/tmp` or `/var/tmp` literal with a NAME JOINED ONTO IT in the same statement --
#         `os.path.join("/tmp", "ndt-fixture")`, `Path("/tmp") / "ndt-fixture"`.
#         LITERAL_TEMP_ROOT deliberately requires something after `/tmp/` (the bare directory
#         names nothing), so the join argument was never part of the match and the statement had
#         no root at all. The join is what turns the bare directory into a name, which is the same
#         reasoning the C++ half already applied to temp_directory_path().
PY_TEMP_ENV = re.compile(r"(?:os\s*\.\s*environ\s*(?:\[|\.\s*get\s*\()|os\s*\.\s*getenv\s*\()\s*"
                         r"[\"'](TMPDIR|TEMPDIR|TEMP|TMP)[\"']")
PY_BARE_TEMP_ROOT = re.compile(r"[\"']/(?:var/)?tmp/?[\"']")
PY_JOINS_A_NAME_ON = re.compile(r"os\s*\.\s*path\s*\.\s*join|\bPath\s*\(|os\s*\.\s*sep|\s\+\s|\s/\s")


def _py_other_roots(code, line):
    """[(line, shown)] for the temp roots that are not a `/tmp/...` string literal."""
    if "gettempdir" in code:
        return [(line, "tempfile.gettempdir()")]
    env = PY_TEMP_ENV.search(code)
    if env:
        return [(line, "$" + env.group(1))]
    if PY_BARE_TEMP_ROOT.search(code) and PY_JOINS_A_NAME_ON.search(code):
        return [(line, PY_BARE_TEMP_ROOT.search(code).group(0).strip("\"'"))]
    return []


def scan_python(text, path):
    """Findings in one Python test.

    Uses the tokeniser rather than a regex so that a `#` inside a string is a `#` inside a string,
    and so that triple-quoted blobs -- docstrings, and the synthetic shell gates that
    test_check_gate_anchors.py carries -- can be skipped as the data they are.
    """
    import io
    import tokenize

    findings = []
    try:
        tokens = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, IndentationError, SyntaxError) as exc:
        return [(path, 1, NOT_CHECKED + "this file could not be tokenised (%s)" % exc, "")]

    # One entry per logical line: (first line number, code text, {name: line} of NAME tokens,
    # [(line, text)] of the string tokens that carry a temp root).
    statements = []
    cur, cur_names, cur_roots, cur_line = [], {}, [], None
    for tok in tokens:
        kind, tok_text, (row, _), _, _ = tok
        if kind == tokenize.COMMENT:
            continue
        if kind in (tokenize.NEWLINE, tokenize.NL):
            if cur:
                statements.append((cur_line, " ".join(cur), cur_names, cur_roots))
            cur, cur_names, cur_roots, cur_line = [], {}, [], None
            continue
        if kind in (tokenize.INDENT, tokenize.DEDENT, tokenize.ENDMARKER, tokenize.ENCODING):
            continue
        if cur_line is None:
            cur_line = row
        if kind == tokenize.STRING:
            if tok_text.lstrip("rbufRBUF")[:3] in ('"""', "'''"):
                cur.append('"<triple-quoted block: data, not a path this file names>"')
                continue
            if LITERAL_TEMP_ROOT.search(tok_text):
                cur_roots.append((row, LITERAL_TEMP_ROOT.search(tok_text).group(0)))
        elif kind == tokenize.NAME:
            cur_names.setdefault(tok_text, row)
        cur.append(tok_text)
    if cur:
        statements.append((cur_line, " ".join(cur), cur_names, cur_roots))

    # Pass 1: `NAME = "<fixed temp path>"`, so that a write through $NAME one statement later is
    # still attributable to the line that chose the name.
    fixed_vars = {}
    for line, code, names, roots in statements:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*) = (.*)$", code)
        if m and (roots or _py_other_roots(code, line)) and not has_per_process_marker(code):
            fixed_vars[m.group(1)] = (line, (roots or _py_other_roots(code, line))[0][1])

    for line, code, names, roots in statements:
        materialises = any(tok in code.replace(" ", "") for tok in PY_MATERIALISERS)
        roots = roots or _py_other_roots(code, line)
        if roots and materialises and not has_per_process_marker(code):
            findings.append((path, roots[0][0],
                             "a fixed %s path that this statement creates or deletes, with no "
                             "os.getpid() / tempfile.mkdtemp / mkstemp in it" % roots[0][1],
                             _one_line(code)))
            continue
        if materialises:
            for name in names:
                if name in fixed_vars and not has_per_process_marker(code):
                    where, shown = fixed_vars[name]
                    findings.append((path, where,
                                     "%s is a fixed %s path, and line %d creates or deletes it; "
                                     "no os.getpid() / tempfile.mkdtemp / mkstemp anywhere in "
                                     "between" % (name, shown, line),
                                     _one_line(code)))
                    del fixed_vars[name]
    return sorted(findings, key=lambda f: f[1])


# =================================================================================================
# Shell
# =================================================================================================
def _sh_tokens(text):
    """((line, word, is_operator)..., unreadable) for one script, quotes tracked across newlines.

    Heredoc bodies are dropped: `cat > "$f" <<'EOF' ... EOF` writes its body somewhere else
    entirely, and the mutation gates in this directory carry whole Python programs in them.

    🔴 The heredoc is recognised INSIDE the scan, where the quote state is known. A pre-pass over
    raw lines cannot tell a heredoc from a C++ stream insertion, and mutate_logger_cli.sh:137
    has `<< known_option_names(also_known) <<` inside a single-quoted anchor -- which such a
    pre-pass read as `<<known_option_names`, and then swallowed the remaining 482 lines of the
    gate looking for a terminator that does not exist. The whole file scanned clean.
    """
    lines = text.split("\n")
    out = []
    word, word_line = "", None
    quote = None          # None, "'" or '"'
    pending_heredocs = []
    substitutions = []    # double-quote contexts suspended by a "$( ... )"
    unreadable = None
    i = 0
    while i < len(lines):
        lineno, line = i + 1, lines[i]
        j = 0
        while j < len(line):
            c = line[j]
            if quote:
                if quote == '"' and line[j:j + 2] == "$(":
                    # Quoting RESTARTS inside a command substitution, so `"$( [[ "$x" ]] )"` is
                    # balanced even though it looks like three quotes in a row. Without this,
                    # test_l1_shell_scoring.sh:219 and test_ndtwin_lab_config.sh:269 left the
                    # scanner inside a string for the rest of the file.
                    substitutions.append(quote)
                    quote = None
                    word += "$("
                    j += 2
                    continue
                word += c
                if c == quote:
                    quote = None
                elif c == "\\" and quote == '"' and j + 1 < len(line):
                    word += line[j + 1]
                    j += 1
                j += 1
                continue
            if c == ")" and substitutions:
                quote = substitutions.pop()
                word += c
                j += 1
                continue
            if c in "'\"":
                quote = c
                if word_line is None:
                    word_line = lineno
                word += c
                j += 1
                continue
            if c == "\\" and j + 1 < len(line):
                if word_line is None:
                    word_line = lineno
                word += line[j:j + 2]
                j += 2
                continue
            if c == "#" and not word:
                break                                   # a comment: the rest of the line
            if c in " \t":
                if word:
                    out.append((word_line, word, False))
                word, word_line = "", None
                j += 1
                continue
            two = line[j:j + 2]
            if two == "<<":
                # A heredoc, seen here rather than in a pre-pass so that quotes count.
                #
                # 🔴 No `and line[j:j + 3] != "<<<"` guard, and that is deliberate. With it, a
                # herestring was skipped at its FIRST `<` and reconsidered at its second, where
                # `<<"` reads as a heredoc whose delimiter is quoted -- so `<<<"$OUT"` had its
                # opening quote eaten and the remaining 482 lines of mutate_logger_cli.sh were
                # read as string content. The whole gate scanned clean. Without the guard the
                # branch fires once, at the first `<`, finds no delimiter word after `<<<`, and
                # hands the third `<` back to the operator rule below.
                # mutate_check_test_tmpdirs.sh M5 puts the guard back.
                if word:
                    out.append((word_line, word, False))
                word, word_line = "", None
                k = j + 2
                if k < len(line) and line[k] == "-":
                    k += 1
                while k < len(line) and line[k] in " \t":
                    k += 1
                delim_quote = line[k] if k < len(line) and line[k] in "'\"" else ""
                k += 1 if delim_quote else 0
                term = ""
                while k < len(line) and (line[k].isalnum() or line[k] in "_-."):
                    term += line[k]
                    k += 1
                if delim_quote and k < len(line) and line[k] == delim_quote:
                    k += 1
                if term:
                    pending_heredocs.append(term)
                out.append((lineno, "<<", True))
                j = k
                continue
            if two in (">>", "&&", "||", "&>"):
                if word:
                    out.append((word_line, word, False))
                word, word_line = "", None
                out.append((lineno, two, True))
                j += 2
                continue
            if c in "<>;|&()":
                if word:
                    out.append((word_line, word, False))
                word, word_line = "", None
                out.append((lineno, c, True))
                j += 1
                continue
            if word_line is None:
                word_line = lineno
            word += c
            j += 1
        # End of line. A word that is still inside a quote, or that ends in a backslash, does not
        # end here -- test_ndt_sudo_surface.sh's stub tables are one single-quoted word eight
        # lines long, and treating each line as its own command loses which command they belong
        # to.
        if quote:
            word += "\n"
            i += 1
            continue
        if word.endswith("\\"):
            word = word[:-1]
            i += 1
            continue
        if word:
            out.append((word_line, word, False))
            word, word_line = "", None
        out.append((lineno, "\n", True))
        while pending_heredocs:                 # skip each body, terminator included
            term = pending_heredocs.pop(0)
            i += 1
            start = i
            while i < len(lines) and lines[i].strip() != term:
                i += 1
            if i >= len(lines):
                unreadable = ("a heredoc opened near line %d (<<%s) has no terminator; "
                              "everything from there was skipped" % (start, term))
        i += 1
    if word:
        out.append((word_line or 1, word, False))
    if substitutions and unreadable is None:
        unreadable = ("a \"$( command substitution never closed; everything after it was read "
                      "as the wrong kind of text")
    if quote and unreadable is None:
        unreadable = ("a %s-quoted string opened near line %s and never closed; everything "
                      "after it was read as string content" % (quote, word_line))
    return out, unreadable


_SH_CMD_SEPARATORS = frozenset((";", "\n", "|", "&", "&&", "||", "(", ")"))


def _sh_commands(tokens):
    """Group the token stream into commands: [(line, [words], [(op, line, word)])]."""
    commands = []
    words, redirects, line = [], [], None
    for lineno, tok, is_op in tokens:
        if is_op and tok in _SH_CMD_SEPARATORS:
            if words:
                commands.append((line, words, redirects))
            words, redirects, line = [], [], None
            continue
        if is_op and tok in (">", ">>", "&>"):
            redirects.append([tok, lineno, None])
            continue
        if redirects and redirects[-1][2] is None and not is_op:
            redirects[-1][2] = tok
            continue
        if is_op:
            continue
        if line is None:
            line = lineno
        words.append((lineno, tok))
    if words:
        commands.append((line, words, redirects))
    return commands


def _sh_unquote(word):
    return word.replace('"', "").replace("'", "")


_SH_ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
_SH_VAR_USE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")

# The environment's temp directory, under any of the four names the same directory goes by. B12
# (2026-09-11) row (2)h: the test was the substring `"$TMPDIR" in value`, so `$TMP/ndt-fixture` and
# `${TEMP}/ndt-fixture` -- the same directory, the same fixed path -- walked past.
#
# 🔴 The name has to END where the reference ends. `$TMPROOT` and `$TMPFILE` begin with the letters
# TMP and are ordinary local names, usually holding something mktemp chose; reading `$TMPROOT/` as
# `$TMP` + `ROOT/` would report a path the kernel picked. Hence the `}` and the negative lookahead,
# and hence TMPDIR before TMP in the alternation.
_SH_TEMP_ENV_NAMES = r"TMPDIR|TEMPDIR|TEMP|TMP"
SH_TEMP_ENV_REF = re.compile(r"\$(?:\{(" + _SH_TEMP_ENV_NAMES + r")(?::[-=+?][^}]*)?\}"
                             r"|(" + _SH_TEMP_ENV_NAMES + r")(?![A-Za-z0-9_]))")
SH_TEMP_ENV_ROOT = re.compile(SH_TEMP_ENV_REF.pattern + r"/\S")


def _sh_env_temp_root(text, locally_bound, with_a_name_on_it):
    """The environment's temp directory referenced in `text`, or None.

    🔴 A LOCAL ASSIGNMENT SHADOWS THE ENVIRONMENT, and this rule is why the widening above is not
    a nuisance. tests/shell/test_build_guard.sh:22-23 is

        TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        FAKE="$TMP/fake"; mkdir -p "$FAKE"

    -- where `$TMP` is a directory the kernel chose, named after the shell's own convention, and
    reporting it would be a false alarm on the very API this gate steers people towards. If the
    file binds the name itself, `$TMP` is that binding and not the environment; whatever it was
    bound to is judged on its own by the assignment rules.
    """
    for m in (SH_TEMP_ENV_ROOT if with_a_name_on_it else SH_TEMP_ENV_REF).finditer(text):
        name = m.group(1) or m.group(2)
        if name not in locally_bound:
            return m.group(0)
    return None


def scan_shell(text, path):
    """Findings in one shell test or mutation gate."""
    findings = []
    tokens, unreadable = _sh_tokens(text)
    if unreadable:
        return [(path, 1, NOT_CHECKED + unreadable, "")]
    commands = _sh_commands(tokens)

    # Pass 1: bare assignments only. `KERNEL_DIR=/tmp/attacker bash -c ...` is an environment
    # prefix for one child command, not a name this file goes on to use, so a command that has a
    # command word is not a definition here.
    # Pass 0: every name this file binds anywhere, however it binds it. Only used to tell the
    # environment's $TMP from a local one -- see _sh_env_temp_root.
    locally_bound = {m.group(1) for _, words, _ in commands for _, w in words
                     if (m := _SH_ASSIGN.match(w))}

    fixed_vars, safe_vars = {}, set()
    for line, words, _ in commands:
        lead = [w for _, w in words]
        while lead and lead[0] in ("export", "local", "declare", "readonly", "typeset"):
            lead = lead[1:]
        if not lead or not all(_SH_ASSIGN.match(w) for w in lead):
            continue
        for wline, w in words:
            m = _SH_ASSIGN.match(w)
            if not m:
                continue
            name, value = m.group(1), m.group(2)
            if has_per_process_marker(value):
                safe_vars.add(name)
            elif LITERAL_TEMP_ROOT.search(_sh_unquote(value)) \
                    or _sh_env_temp_root(value, locally_bound, False):
                fixed_vars[name] = (wline, _sh_unquote(value))

    # Pass 2: the places a command writes -- its arguments if it is one of SH_MATERIALISERS, and
    # whatever a > or >> points at.
    reported = set()

    def report(where, shown, why, context):
        if (where, shown) in reported:
            return
        reported.add((where, shown))
        findings.append((path, where, why, context))

    for line, words, redirects in commands:
        plain = [w for _, w in words]
        idx = 0
        while idx < len(plain) and (_SH_ASSIGN.match(plain[idx])
                                    or plain[idx] in ("export", "local", "declare", "readonly",
                                                      "typeset", "sudo", "command", "time",
                                                      "if", "then", "else", "elif", "while",
                                                      "until", "do", "!")):
            idx += 1
        head = os.path.basename(_sh_unquote(plain[idx])) if idx < len(plain) else ""
        targets = []
        if head in SH_MATERIALISERS:
            targets += [(wl, w) for wl, w in words[idx + 1:] if not w.startswith("-")]
        for _op, opline, target in redirects:
            if target:
                targets.append((opline, target))

        whole = " ".join(plain)
        for tline, target in targets:
            bare = _sh_unquote(target)
            if has_per_process_marker(bare) or has_per_process_marker(whole):
                continue
            hit = LITERAL_TEMP_ROOT.search(bare)
            if hit and "*" not in hit.group(0):
                report(tline, hit.group(0),
                       "%s is a fixed path and this command creates or deletes it; no $$ / "
                       "mktemp / getpid anywhere in the command" % hit.group(0),
                       _one_line(whole))
                continue
            if _sh_env_temp_root(bare, locally_bound, True):
                report(tline, bare,
                       "%s is the same path in every process and this command creates or deletes "
                       "it; no $$ / mktemp / getpid anywhere in the command" % bare,
                       _one_line(whole))
                continue
            for name in _SH_VAR_USE.findall(bare):
                if name in fixed_vars and name not in safe_vars:
                    where, value = fixed_vars[name]
                    report(where, value,
                           "$%s is a fixed %s path, and line %d creates or deletes it; no $$ / "
                           "mktemp / getpid in either place" % (name, value, tline),
                           _one_line(whole))
    return sorted(findings, key=lambda f: f[1])


# =================================================================================================
# Driving the whole tree
# =================================================================================================
# 🔴 The suites, and the only place the file types are named. mutate_check_test_tmpdirs.sh M1
# deletes the C++ row: a gate that no longer looks at the files the defect was measured in.
SUITES = (
    ("tests", "*.cpp", scan_cpp),
    ("tests/python", "*.py", scan_python),
    ("tests/shell", "*.sh", scan_shell),
)

_BY_EXTENSION = {".c": scan_cpp, ".cpp": scan_cpp, ".cc": scan_cpp, ".h": scan_cpp,
                 ".hpp": scan_cpp,
                 ".py": scan_python, ".sh": scan_shell, ".bash": scan_shell}

# 🔴 D1 (F-OFFLINE-1-REPORT.md §1.17). Every SUITES row was one NON-RECURSIVE glob, so the tree
# walk saw 261 files and the following were never opened at all -- while the scanner handled each
# of them perfectly well when a path was named on the command line:
#
#   tests/fuzz/  tests/manual/  tests/shell/*.py (both checkers)  p4_proxy/tests/  and every
#   .cc / .h / .hpp / .c under tests/
#
# The three rows stay (M1 still removes the C++ one), but each is now walked recursively, and the
# test suites that live outside tests/ are walked too.
#
# 🔴 What is NOT in scope, and why the line is here rather than at "every .sh under tools/":
# the rule is about A TEST, because the reason it exists is that ctest gives every test its own
# process. tools/test_workflow/ and tools/contract_test/ are mostly harness and driver code, whose
# fixed /tmp paths are deliberate shared state -- tools/test_workflow/build_bmv2_fast.sh:42's
# `BUILD=/tmp/bmv2-fast-src` is a build CACHE that exists to be found again by the next run, and a
# gate that called it a hazard would be a nuisance on its first day. So under tools/ only the
# files that are themselves tests are scanned, recognised by this tree's own naming convention.
EXTRA_TEST_TREES = (
    ("p4_proxy/tests", None),
    ("tools/test_workflow", "test_"),
    ("tools/contract_test", "test_"),
)


def _one_line(text):
    return " ".join(text.split())[:150]


def scan_file(path, scanner=None, rel=None):
    scanner = scanner or _BY_EXTENSION.get(os.path.splitext(path)[1])
    if scanner is None:
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return scanner(fh.read(), rel if rel is not None else path)


def _walk(root, keep):
    """Every file under `root`, recursively, that `keep(basename)` says yes to."""
    out = []
    for here, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in ("__pycache__", ".git", "venv"))
        out += [os.path.join(here, name) for name in filenames if keep(name)]
    return sorted(out)


def scan_tree(repo):
    """Every file in every suite, in a stable order."""
    import fnmatch
    findings, scanned, seen = [], 0, set()

    def take(path, scanner):
        nonlocal scanned
        if path in seen:
            return
        seen.add(path)
        scanned += 1
        findings.extend(scan_file(path, scanner, rel=os.path.relpath(path, repo)))

    for directory, pattern, scanner in SUITES:
        for path in _walk(os.path.join(repo, directory),
                          lambda name, pattern=pattern: fnmatch.fnmatch(name, pattern)):
            take(path, scanner)
    # 🔴 SUITES stays the ONE place that decides which languages' tests are in scope, so M1 --
    # "tests/*.cpp is no longer one of the suites" -- still takes every C++ file in the tree out of
    # scope rather than being routed around by the sweeps below.
    in_scope = {scanner for _, _, scanner in SUITES}

    def readable(name, prefix=None):
        return (_BY_EXTENSION.get(os.path.splitext(name)[1]) in in_scope
                and (prefix is None or name.startswith(prefix)))

    for directory, prefix in EXTRA_TEST_TREES:
        for path in _walk(os.path.join(repo, directory),
                          lambda name, prefix=prefix: readable(name, prefix)):
            take(path, None)
    # Everything else under tests/ this scanner can read: .cc / .h / .hpp / .c, and the .py
    # checkers that live in tests/shell. Dispatched by extension, like a named argument is.
    for path in _walk(os.path.join(repo, "tests"), readable):
        take(path, None)
    return findings, scanned


def main(argv):
    args = list(argv[1:])
    # .../<repo>/tests/shell/check_test_tmpdirs.py -> <repo>
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    files = []
    while args:
        arg = args.pop(0)
        if arg == "--repo":
            if not args:
                print("check_test_tmpdirs: --repo needs a directory", file=sys.stderr)
                return 2
            repo = args.pop(0)
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        elif arg.startswith("-"):
            print("check_test_tmpdirs: unknown option %s" % arg, file=sys.stderr)
            return 2
        else:
            files.append(arg)

    if files:
        findings, scanned = [], 0
        for path in files:
            if not os.path.exists(path):
                print("check_test_tmpdirs: no such file: %s" % path, file=sys.stderr)
                return 2
            scanned += 1
            findings += scan_file(path)
    else:
        findings, scanned = scan_tree(repo)

    for path, line, why, context in findings:
        print("%s:%d: %s" % (path, line, why))
        if context:
            print("      %s" % context)

    unreadable = [f for f in findings if f[2].startswith(NOT_CHECKED)]
    if unreadable:
        print("check_test_tmpdirs: %d file(s) COULD NOT BE READ and were not checked at all "
              "(exit 2); %d other finding(s)." % (len(unreadable), len(findings) - len(unreadable)),
              file=sys.stderr)
        return 2
    if findings:
        print("check_test_tmpdirs: %d fixed temp path(s) in %d file(s), out of %d file(s) scanned."
              % (len(findings), len({f[0] for f in findings}), scanned))
        print("      ctest gives every test its own process. A temp path that is the same string "
              "in two of them")
        print("      is a race the suite can only be trusted at -j1: put getpid() / os.getpid() / "
              "$$ in the name,")
        print("      or let mkdtemp / mkstemp / mktemp -d choose it. See "
              "doc/2026-08-17_testing-manual.md.")
    else:
        print("check_test_tmpdirs: %d file(s) scanned, 0 fixed temp paths" % scanned)
    # 🔴 The verdict. mutate_check_test_tmpdirs.sh M3 pins this to 0: a gate that finds everything
    # and reports success is worse than no gate, because the report reads clean.
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
