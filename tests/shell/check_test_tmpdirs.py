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

  (1) a TEMP ROOT      -- `temp_directory_path()`, a `/tmp/...` or `/var/tmp/...` literal, or
                          `$TMPDIR` / `tempfile.gettempdir()`;
  (2) MATERIALISATION  -- in the same statement (C++/Python) or the same command (shell), an
                          operation that makes or destroys a filesystem entry;
  (3) NO PER-PROCESS MARKER anywhere in that statement/command -- see PER_PROCESS_MARKERS.

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
 * Variables are followed one hop, within one file: `NAME=<fixed temp path>` is reported when
   `$NAME` later reaches something that writes. An indirection through a function's argument, or
   across files, is not followed.
 * A path assembled from pieces that are individually not temp roots (`root = "/" + "tmp"`) is
   not recognised. Nothing in this tree does that.
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


# 🔴 A file this scanner could not read is NOT a file with no findings. check_gate_anchors.py
# learned this the expensive way (KNOWN-ISSUES L-3): four gates it could not parse were reported
# as "no anchors" for weeks. Anything carrying this prefix makes the run exit 2, which is neither
# "clean" nor "there is a fixed path here" but "go and look".
NOT_CHECKED = "NOT CHECKED: "


def has_per_process_marker(text):
    """Does anything in `text` make the name differ per process?"""
    return any(marker in text for marker in PER_PROCESS_MARKERS)


# --- what counts as a temp root ------------------------------------------------------------------
# A literal path under the system temp directory. `/tmp` or `/var/tmp` with something after it:
# the bare directory is shared by design and names nothing.
LITERAL_TEMP_ROOT = re.compile(r"/(?:var/)?tmp/[^\s\"'`)\];,]+")

# 🔴 The C++ half of rule (1). mutate_check_test_tmpdirs.sh M2 drops the temp_directory_path
# alternative, leaving a gate that only knows the spelling C++ fixtures do not use.
CPP_TEMP_ROOT = re.compile(r"(?:\btemp_directory_path\s*\(\s*\))|(?:/(?:var/)?tmp/)")

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


def scan_cpp(text, path):
    """Findings in one C++ test translation unit."""
    findings = []
    code, unreadable = strip_cpp_comments(text)
    if unreadable:
        return [(path, 1, NOT_CHECKED + unreadable, "")]
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
    return findings


# =================================================================================================
# Python
# =================================================================================================
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
        if m and roots and not has_per_process_marker(code):
            fixed_vars[m.group(1)] = (line, roots[0][1])

    for line, code, names, roots in statements:
        materialises = any(tok in code.replace(" ", "") for tok in PY_MATERIALISERS)
        if "gettempdir" in code and not roots:
            roots = [(line, "tempfile.gettempdir()")]
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
            elif LITERAL_TEMP_ROOT.search(_sh_unquote(value)) or "$TMPDIR" in value \
                    or "{TMPDIR" in value:
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
            if "TMPDIR" in bare and re.search(r"\$\{?TMPDIR[^}]*\}?/\S", bare):
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

_BY_EXTENSION = {".cpp": scan_cpp, ".cc": scan_cpp, ".h": scan_cpp, ".hpp": scan_cpp,
                 ".py": scan_python, ".sh": scan_shell, ".bash": scan_shell}


def _one_line(text):
    return " ".join(text.split())[:150]


def scan_file(path, scanner=None, rel=None):
    scanner = scanner or _BY_EXTENSION.get(os.path.splitext(path)[1])
    if scanner is None:
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return scanner(fh.read(), rel if rel is not None else path)


def scan_tree(repo):
    """Every file in every suite, in a stable order."""
    import glob
    findings, scanned = [], 0
    for directory, pattern, scanner in SUITES:
        for path in sorted(glob.glob(os.path.join(repo, directory, pattern))):
            scanned += 1
            findings += scan_file(path, scanner, rel=os.path.relpath(path, repo))
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
