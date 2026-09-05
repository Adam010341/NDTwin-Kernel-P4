#!/usr/bin/env python3
"""Can every mutation gate still find the text it mutates?

[Co-developed with claude code -- Adam]

A mutation gate edits a source file by exact text. When another change rewords that text,
the gate stops being able to apply its mutation -- and nothing says so, because the gtest
suite the gate protects is still green. `mutate_lock_renew_expiry.sh` lost all six of its
anchors that way during this campaign while its tests stayed green.

This tool is READ-ONLY. It never writes a file, never builds, never runs a gate. For a
given git rev it reads each gate script, works out which files that gate mutates and which
anchor strings it looks for, and counts each anchor in that rev's copy of the file. An
anchor that occurs zero times cannot be applied; one that occurs more often than the gate
declares would mutate the wrong site; both are reported. The expected count is 1 unless the
gate states otherwise (`apply_exact <file> <old> <new> <count>`), or is applying the anchor
with a bare python `s.replace(old, new)` -- no count argument, Python's own default -- which
touches every occurrence uniformly and so has no wrong site for a second match to be; such an
anchor is expected at least once, with no upper bound (`_replace_call_want`).

    check_gate_anchors.py 4cbec52d                        # every gate in one rev
    check_gate_anchors.py 4cbec52d fix/a-9-lock-lease      # matrix over revs
    check_gate_anchors.py --revs-file revs.txt            # ... or read them from a file
    check_gate_anchors.py BR --gates mutate_lock_renew_expiry.sh

    # Will the batch break a gate? Take BR_A's gates, and count their anchors in each
    # column rev 3-way merged with BR_A over the common base:
    check_gate_anchors.py --gates-from BR_A --merge-with-base 4cbec52d --revs-file revs.txt

Without --merge-with-base a gate is checked against a column rev's file as it stands, which
for a gate whose fix that rev does not carry is a guaranteed miss and says nothing. With it,
the file each anchor is counted in is what git would actually produce for that pair, so a
result means "after these two merge".

Exit status: 0 every anchor resolves the number of times its gate expects; 1 some anchor is
missing, over-matched, its file is absent, or the merge conflicts; 2 the tool could not
parse a mutation construct, or read a gate and found no anchors at all -- neither is a pass,
because an applier this tool cannot read is an applier it is not checking.

🔴 "COULD NOT CHECK" IS NOT "CHECKED AND FINE", and every part of the output is built so the
two cannot be confused. A cell that was counted and is fine reads `ok(n)` or `ok-via(n)`, and
nothing else starts with `ok`. UNPARSED, NO-ANCHORS, VIA-UNCHECKED and PENDING-VIA are each
named in the grid, counted on the summary line ("... of which N were NOT CHECKED AT ALL"),
listed one per line under a header that says NOT checked, repeated on stderr so a teed or
truncated stdout cannot swallow them, and they exit 2. The four gates L-3 found -- four cells
this tool skipped while the run still looked orderly -- are the reason each of those exists.

Counting is `str.count()` on the exact literal for literal anchors. Anchors that are
regexes in the gate (perl `s///`, `sed -i s///`) are counted by perl and sed themselves,
because reimplementing their regex dialects here would be a second place for the answer to
be wrong. `ok(n)` counts DISTINCT anchors: a gate that reaches the same text twice -- once
through its table, once at the builder's own call site -- is checked once, because counting
it twice would say nothing the first count did not.

A gate that only drives other gates (`mutate_lock_lease_all.sh`, the whole kernel-side
evidence for A-9) has no anchors of its own. It is not NO-ANCHORS any more and it is not
`ok` either: the gates it runs are read out of the array it walks, and its cell becomes
`ok-via(n)` only when every one of them was checked in this run and is ok. A delegate that
is broken makes the driver VIA-BROKEN; a delegate this run did not check makes it
VIA-UNCHECKED and exits 2, because a verdict nobody produced cannot be inherited.

The shapes it reads are covered by tests/python/test_check_gate_anchors.py, whose own gate is
tests/shell/mutate_check_gate_anchors.sh -- an instrument nobody has seen fail is a decoration.
"""
import argparse
import os
import re
import subprocess
import sys

# Commands that never carry an anchor, so the generic "<file> <anchor>" rule below skips them.
# Everything else is treated as a possible mutation helper -- gates in this repo each define
# their own (`mutate`, `mutate_must_die`, `run_mutation`, ...), so recognising them by name
# would mean this tool silently checked nothing the next time someone invented a fifth spelling.
NOT_APPLIERS = {
    "echo", "printf", "cat", "cd", "cp", "mv", "rm", "mkdir", "grep", "sed", "awk", "cut",
    "sort", "head", "tail", "wc", "diff", "cmp", "test", "[", "[[", "local", "return",
    "exit", "export", "read", "if", "then", "else", "elif", "fi", "for", "while", "do",
    "done", "case", "esac", "function", "trap", "set", "shift", "eval", "source", ".",
    "true", "false", "touch", "chmod", "mktemp", "basename", "dirname", "md5sum",
    "sha256sum", "tee", "bash", "sh", "cmake", "ctest", "ninja", "make", "git", "find",
}

LITERAL, PERL_RE, SED_RE = "literal", "perl-re", "sed-re"


# --------------------------------------------------------------------------- shell parsing
def _unescape_dq(s):
    """Bash double-quote semantics: a backslash is literal unless it precedes $ ` " \\ or \\n."""
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] in '$`"\\\n':
            if s[i + 1] != "\n":       # backslash-newline inside "" is a line continuation
                out.append(s[i + 1])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def split_commands(text):
    """Split a shell script into logical commands, each a list of (value, quote) words.

    quote is "'" for a single-quoted word, '"' for double-quoted, '' for bare. Only the
    subset the gate scripts actually use is handled: quotes, backslash escapes, line
    continuations, comments, and ; & | && || newline as separators. Heredocs are returned
    whole as a single word tagged 'H' so the python-heredoc extractor can read them.
    """
    cmds, cur, word, quote, i, n = [], [], [], "", 0, len(text)
    pending_heredocs, substitutions = [], []

    def flush_word():
        nonlocal word, quote
        if word or quote:
            cur.append(("".join(word), quote))
        word, quote = [], ""

    def flush_cmd():
        nonlocal cur
        flush_word()
        if cur:
            cmds.append(cur)
        cur = []

    while i < n:
        c = text[i]
        if c == "$" and text[i:i + 2] == "$'":
            # ANSI-C quoting. `mutate_ndt_sample_rate_reads_both_bounds.sh` packs an anchor and
            # its replacement into one argument separated by $'\x1f'; without this the escape is
            # read as three literal characters and the whole call is unreadable.
            j = i + 2
            while j < n:
                if text[j] == "\\" and j + 1 < n:
                    j += 2
                elif text[j] == "'":
                    break
                else:
                    j += 1
            word.append(_unescape_ansi_c(text[i + 2:j]))
            quote = quote or "'"
            i = j + 1
        elif c == "$" and text[i:i + 2] == "$(":
            # Command substitution. `m1=$(mutant m1 '<anchor>')` is a mutation call like any
            # other; before this it was one unreadable word beginning `m1=$(mutant`. The inside
            # is parsed as its own command list -- the outer word keeps nothing, because what
            # the substitution EVALUATES to is not something this tool can know.
            j = _match_close(text, i + 1, "(", ")")
            substitutions.append(text[i + 2:j - 1] if j > i + 2 else "")
            i = j
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                j = n
            word.append(text[i + 1:j])
            quote = quote or "'"
            i = j + 1
        elif c == '"':
            j, buf = i + 1, []
            while j < n:
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j:j + 2])
                    j += 2
                elif text[j] == '"':
                    break
                else:
                    buf.append(text[j])
                    j += 1
            word.append(_unescape_dq("".join(buf)))
            quote = quote or '"'
            i = j + 1
        elif c == "\\" and i + 1 < n:
            if text[i + 1] == "\n":
                i += 2                              # line continuation
            else:
                word.append(text[i + 1])
                i += 2
        elif c == "#" and not word and not quote and (i == 0 or text[i - 1] in " \t\n;|&("):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c == "<" and text[i:i + 2] == "<<":
            m = re.match(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", text[i:])
            if m:
                pending_heredocs.append(m.group(2))
                i += m.end()
            else:
                word.append(c)
                i += 1
        elif c == "\n":
            flush_cmd()
            i += 1
            for tag in pending_heredocs:
                end = re.search(r"^\s*%s\s*$" % re.escape(tag), text[i:], re.M)
                stop = i + (end.start() if end else 0)
                cmds.append([(text[i:stop], "H")])
                i = i + end.end() + 1 if end else n
            pending_heredocs = []
        elif c in " \t":
            flush_word()
            i += 1
        elif c in ";&|":
            flush_cmd()
            i += 1
        else:
            word.append(c)
            i += 1
    flush_cmd()
    for sub in substitutions:
        cmds.extend(split_commands(sub))
    return cmds


def _match_close(text, i, opener, closer):
    """Index just past the `closer` matching the `opener` at text[i], quotes respected."""
    depth, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c in "'\"":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if (text[j] == "\\" and c == '"') else 1
            i = j + 1
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


_ANSI_C = {"a": "\a", "b": "\b", "e": "\x1b", "f": "\f", "n": "\n", "r": "\r",
           "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}


def _unescape_ansi_c(s):
    """Bash $'...' semantics, enough of them: \\xHH, \\NNN, \\uHHHH and the named escapes."""
    out, i, n = [], 0, len(s)
    while i < n:
        if s[i] != "\\" or i + 1 >= n:
            out.append(s[i])
            i += 1
            continue
        c = s[i + 1]
        if c == "x":
            m = re.match(r"[0-9a-fA-F]{1,2}", s[i + 2:])
            if m:
                out.append(chr(int(m.group(0), 16)))
                i += 2 + m.end()
                continue
        if c in "uU":
            m = re.match(r"[0-9a-fA-F]{1,8}", s[i + 2:])
            if m:
                out.append(chr(int(m.group(0), 16)))
                i += 2 + m.end()
                continue
        if c in "01234567":
            m = re.match(r"[0-7]{1,3}", s[i + 1:])
            out.append(chr(int(m.group(0), 8)))
            i += 1 + m.end()
            continue
        out.append(_ANSI_C.get(c, "\\" + c))
        i += 2
    return "".join(out)


def scalar_assignments(text, gate_dir=None):
    """`NAME=value` at the start of a line, value a plain word (no $(...) or backticks).

    A gate names its targets relative to itself -- `NDT="$REPO/tools/test_workflow/ndt"`,
    `GATES=("$HERE/mutate_lock_lease_expiry.sh")` -- and every path this tool hands to `git show`
    has to be repo-relative. $REPO and $HERE are the two spellings every gate in this directory
    uses and both are knowable without running anything: $HERE is the directory the gate is IN
    (which the caller passes in) and $REPO is the root above it. Nothing else is guessed.
    """
    # 2026-09-04: `SFT=include/common_types/SFlowType.hpp   # the arithmetic and its guard` (from
    # tests/shell/mutate_flow_rate_denominator.sh) matched nothing -- `\s*$` requires the rest of
    # the line to be BLANK, and a trailing inline comment is not blank, so the whole assignment
    # was invisible and every anchor attributed through it fell through to "no target file". A
    # comment is only ever preceded by WHITESPACE here (bash's own rule for where `#` starts one;
    # `X=a#b` has no comment at all, `#` is just part of the word), so the added group requires
    # that whitespace rather than allowing a bare trailing `#`.
    out = {}
    for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(\S*)(?:[ \t]+#.*)?\s*$", text, re.M):
        name, val = m.group(1), m.group(2)
        if "$(" in val or "`" in val:
            continue
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
            val = val[1:-1]
        out[name] = _repo_relative(val, gate_dir)
    return out


def _repo_relative(val, gate_dir):
    """$REPO/x -> x, $HERE/x -> <the gate's own directory>/x. Anything else is left alone."""
    for pat in (r"^\$\{?REPO\}?/", r"^\$\{?ROOT\}?/"):
        if re.match(pat, val):
            return re.sub(pat, "", val)
    if gate_dir is not None and re.match(r"^\$\{?HERE\}?/", val):
        return os.path.normpath(os.path.join(gate_dir, re.sub(r"^\$\{?HERE\}?/", "", val)))
    return val


def quoted_assignments(text, gate_dir=None):
    """`NAME='...'` / `NAME="..."` where the value has spaces or newlines in it.

    scalar_assignments deliberately reads only single-token values, so a gate's negative-control
    anchor (`CTRL_ANCHOR='    def _unavailable():'`) was invisible and the control was the one
    mutation this tool never checked. Values are NOT chained into path guessing -- an anchor that
    happens to contain a slash is not a file -- they exist so `"$CTRL_ANCHOR"` can be resolved.
    """
    out, i, n = {}, 0, len(text)
    for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(['\"])", text, re.M):
        name, q = m.group(1), m.group(2)
        j = m.end()
        buf = []
        while j < n:
            if text[j] == "\\" and q == '"' and j + 1 < n:
                buf.append(text[j:j + 2])
                j += 2
            elif text[j] == q:
                break
            else:
                buf.append(text[j])
                j += 1
        if j >= n:
            continue
        rest = text[j + 1:].split("\n", 1)[0]
        if rest.strip() and not rest.lstrip().startswith("#"):
            continue                            # not a whole-value assignment; leave it alone
        val = "".join(buf)
        out[name] = _unescape_dq(val) if q == '"' else val
    return out


def _prune(env):
    """Drop values that still carry an unexpanded parameter AND look like a path.

    `BIN="$BUILD_DIR/bin/$TARGET"` would otherwise resolve to a plausible-looking path that is
    in no git rev, and every anchor attributed to it would be reported NOFILE -- a broken
    instrument reporting broken anchors. An anchor that merely contains a `$` is kept.
    """
    return {k: v for k, v in env.items()
            if not (re.search(r"\$\{?[A-Za-z_]", v) and "/" in v)}


# A repo-root target has no directory part to give it away. `testbed_topo.py`, `Makefile.am`,
# `CMakeLists.txt` -- shaped like a filename, and that is all the shape can say.
_BARE_FILENAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.+-]*\.[A-Za-z0-9]{1,8}")


def is_repo_path(v, exists=None):
    """Is this string a FILE the gate mutates, rather than the TEXT it searches for?

    🔴 `"/" in v` used to be the whole of it, everywhere this question is asked (`path_at`,
    `default_file_of`, the generic `<file> <anchor>` rule, ...). A gate whose target sits at the
    repo ROOT declares `TOPO="$REPO/testbed_topo.py"`, which `_repo_relative` reduces to
    `testbed_topo.py` -- no slash, therefore not a file, therefore every one of its anchors fell
    through to the only slash-bearing string the gate declared and was counted in the wrong file.
    Measured 2026-09-03 on tests/shell/mutate_testbed_banner.sh: `MISSING:23` against a gate whose
    23 anchors are all present and all unique. That is the failure mode this tool is built to make
    impossible -- not `NO-ANCHORS`, not `UNPARSED`, but a confident wrong answer.

    The slash rule is kept exactly as it was: a value with a directory part is a path, as before.
    What is added is the only other way to know, and it is git's answer rather than a guess --
    a bare word shaped like a filename is a file when, and only when, this rev's tree actually
    holds one by that name. `exists` is the caller's `git show <rev>:<path>` probe; without it
    (extract() called directly, no rev to ask) nothing is added and the answer is the old one.

    A string that neither carries a slash nor names a file git can produce is NOT quietly promoted
    to a path: it stays unidentified, and an anchor whose file this tool could not pin down is
    reported unresolved. Widening this to "any argument is a file" is the relaxing direction and
    is what tests/shell/mutate_gate_anchors_root_files.sh's control mutation does.

    [Co-developed with claude code -- Adam]
    """
    if not isinstance(v, str) or not v:
        return False
    if "/" in v:
        return True                             # unchanged: a directory part is a path
    if exists is None:
        return False                            # no rev to ask -- do not guess
    return _BARE_FILENAME.fullmatch(v) is not None and bool(exists(v))


def resolve_env(env, rounds=4):
    """Expand "$VAR" / "${VAR}" that appear inside other values, so `CTRL_FILE="$SRC"` is a path.

    Bounded rather than fixpointed: a self-referential value must stop, not hang, and after a few
    rounds anything still unresolved is reported as unresolved rather than guessed at.
    """
    out = dict(env)
    for _ in range(rounds):
        changed = False
        for k, v in list(out.items()):
            if "$" not in v:
                continue
            def sub(m):
                return out.get(m.group(1) or m.group(2), m.group(0))
            nv = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", sub, v)
            if nv != v and "$" + k not in nv:
                out[k], changed = nv, True
        if not changed:
            break
    return out


def deref(word, quote, env):
    """Resolve "$VAR" / $VAR / ${VAR} to its assigned value; leave anything else alone."""
    if quote == "'":
        return word
    m = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", word.strip())
    if m:
        return env.get(m.group(1), word)
    return word


# ------------------------------------------------------------------------ anchor extraction
def _scan_delimited(prog, i, d, close):
    """Read one delimited half starting at i; return (text, index just past the delimiter)."""
    depth, buf = 1, []
    while i < len(prog):
        ch = prog[i]
        if ch == "\\" and i + 1 < len(prog):
            buf.append(prog[i:i + 2])
            i += 2
            continue
        if close:
            if ch == d:
                depth += 1
            elif ch == close:
                depth -= 1
                if depth == 0:
                    return "".join(buf), i + 1
        elif ch == d:
            return "".join(buf), i + 1
        buf.append(ch)
        i += 1
    return None, i


def _perl_subst_pattern(prog):
    """The search half of a perl/sed s/// (or s{}{}) expression, with its regex modifiers
    folded in as an inline (?msix) group -- a pattern anchored with ^...$ under /m counts
    zero without it, which would read as a broken anchor when the gate is fine."""
    m = re.match(r"\s*s(.)", prog)
    if not m:
        return None
    d = m.group(1)
    close = {"{": "}", "(": ")", "[": "]", "<": ">"}.get(d)
    pat, i = _scan_delimited(prog, m.end(), d, close)
    if pat is None:
        return None
    if close:                                   # s{...}{...}: the replacement reopens
        m2 = re.match(r"\s*(.)", prog[i:])
        if not m2:
            return pat
        d2 = m2.group(1)
        _, i = _scan_delimited(prog, i + m2.end(), d2,
                               {"{": "}", "(": ")", "[": "]", "<": ">"}.get(d2))
    else:
        _, i = _scan_delimited(prog, i, d, None)
    flags = "".join(c for c in re.match(r"[a-zA-Z]*", prog[i:]).group(0) if c in "msix")
    return ("(?%s)" % flags) + pat if flags else pat



# 2026-09-04: `mutate_harness_instruments.sh` reported DUP:1 against a target where the anchor is
# fine -- it occurs twice on purpose (FINDING-02 Defect B's "hidden owner" sentinel collapses to
# empty at two call sites since L-10 split the pid search out of port_holder). The gate's own
# `s.replace(old, new)` -- Python's own default, no count argument -- replaces BOTH, uniformly,
# which is the correct and intended mutation; this tool was inventing a failure by assuming every
# anchor wants exactly one match. `_replace_call_want` reads the call the way `apply_exact`'s
# trailing count already is read: a bare two-argument call implies "at least one, no upper bound"
# (Python's replace() cannot ever hit the wrong site the way a hand-rolled single-replace can, so
# there is nothing for a second match to get wrong); an explicit third argument is an exact count;
# anything this cannot confidently parse (a non-literal second argument, an unusual call shape)
# falls back to 1, the old and only behaviour, rather than guess.
_REPL_TAIL = re.compile(
    r'^\s*,\s*(?:"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')\s*(?:,\s*(\d+)\s*)?\)')


def _replace_call_want(block, end):
    """want implied by a `.replace(anchor, repl[, count])` call, reading from just past the
    anchor argument. None means "at least one, no upper bound"; see the note above."""
    m = _REPL_TAIL.match(block[end:])
    if not m:
        return 1
    return int(m.group(1)) if m.group(1) else None


def _py_anchors(block):
    """Every anchor a python mutation body searches for, as (label, text, want).

    Two spellings are in use across this repo's gates: a named `old=`/`guard=`/`store=`
    literal that is then asserted and replaced, and an inline `s.replace("anchor", ...)`.
    Both are the text that has to still be there, so both are collected.
    """
    import ast
    found = []
    for m in re.finditer(r"^\s*(old|guard|store)\s*=\s*(.+)$", block, re.M):
        try:
            val = ast.literal_eval(m.group(2).strip())
        except (ValueError, SyntaxError):
            continue
        if isinstance(val, str):
            found.append((m.group(1), val, 1))
    for m in re.finditer(r"\.replace\(\s*(\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')", block):
        try:
            val = ast.literal_eval(m.group(1))
        except (ValueError, SyntaxError):
            continue
        if isinstance(val, str) and val:
            found.append(("replace", val, _replace_call_want(block, m.end())))
    return found


def _looks_like_python(s):
    return ("sys.argv" in s or "pathlib" in s or "s.replace(" in s
            or re.search(r"^\s*(old|guard|store)\s*=", s, re.M) is not None)


# ------------------------------------------------------- the shapes a gate holds its table in
# Four gates in this directory were reported UNPARSED or NO-ANCHORS -- among them
# mutate_lock_lease_all.sh, which is the whole evidence for A-9 on the kernel side. None of them
# is exotic; each holds its mutation table one indirection further out than the rules above can
# follow, and the tool said so rather than pretending. The helpers below follow those four
# indirections, and every one of them is a POSITIVE identification: a role this tool cannot name
# stays unnamed and the gate stays UNPARSED.

ROLE_ANCHOR = {"anchor", "old", "needle", "pattern", "search", "from", "before"}
ROLE_FILE = {"file", "src", "path", "target", "source", "rel"}


def function_bodies(text):
    """-> {name: body} for every `name() { ... }`, brace-per-line and one-liner alike.

    🔴 The one-liner is decided FIRST, per definition. Reading `add() { ... }` with a
    dot-all "up to the next line that starts with }" swallows every function after it up to the
    first multi-line one, and the roles of THAT function are then read as this one's -- which is
    how a table builder came to look like it declared an `anchor` parameter. It happened to give
    the right answer on the gate it was written against, and that is the worst way for it to be
    wrong. Found by mutation M3 of tests/shell/mutate_check_gate_anchors.sh.
    """
    out = {}
    for m in re.finditer(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", text, re.M):
        name, start = m.group(1), m.end()
        eol = text.find("\n", start)
        line = text[start:eol if eol >= 0 else len(text)]
        depth, closed = 1, None
        for k, ch in enumerate(line):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    closed = k
                    break
        if closed is not None:
            out.setdefault(name, line[:closed])
            continue
        end = re.search(r"^\}", text[start:], re.M)
        out.setdefault(name, text[start:start + (end.start() if end else 0)])
    return out


_POSITIONAL = r'\$\{?([0-9]+)(?::-[^}]*)?\}?'


def param_roles(body):
    """{position: role} from a function's own `local label="$1" file="$2" anchor="$3"` line.

    This is the gate telling us what its parameters ARE, in its own words, rather than this tool
    guessing from argument order. A function that names no role yields nothing and its call sites
    fall through to the generic rules.
    """
    roles = {}
    for m in re.finditer(r'\b([A-Za-z_][A-Za-z0-9_]*)="?' + _POSITIONAL + r'"?', body):
        roles.setdefault(int(m.group(2)), m.group(1).lower())
    return roles


def role_position(roles, wanted):
    for pos, name in sorted(roles.items()):
        if name in wanted:
            return pos
    return None


def builder_arrays(body):
    """{position: array} from a table builder's `MUT_ANCHOR+=("$3")` statements."""
    out = {}
    for m in re.finditer(r'\b([A-Za-z_][A-Za-z0-9_]*)\+=\(\s*"?' + _POSITIONAL + r'"?\s*\)', body):
        out[int(m.group(2))] = m.group(1)
    return out


def array_assignments(text, gate_dir=None):
    """{name: [element, ...]} for `NAME=( ... )`, comments and quotes respected."""
    out = {}
    for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=\(", text, re.M):
        end = _match_close(text, m.end() - 1, "(", ")")
        body = text[m.end():end - 1]
        body = re.sub(r"#[^\n]*", "", body)
        out[m.group(1)] = [_repo_relative(w, gate_dir)
                           for w, _ in (c for cmd in split_commands(body) for c in cmd)]
    return out


def default_file_of(body, env, exists=None):
    """The repo path a function bakes into its own body: `"$VAR"` where VAR is a declared path.

    `exists` is git's answer, not a guess: without it a build artefact like "$BIN" would look
    exactly like a source file and every anchor would be counted in a file that is not there.
    """
    for var in re.findall(r'"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"', body):
        v = env.get(var)
        if v and "$" not in v and is_repo_path(v, exists) and (exists is None or exists(v)):
            return v
    return None


def is_param_ref(word, quote):
    """True when the word is an unexpanded parameter -- $1, "$anchor", "${MUT_ANCHOR[$i]}".

    🔴 Load-bearing. `mutate "${MUT_LABEL[$i]}" ...` used to be recorded as a LITERAL anchor
    spelled `${MUT_LABEL[$i]}`, which is why mutate_ryu_rest_topology_bounded.sh reported
    MISSING:1 against a file whose anchors are all fine. A word that still contains a parameter
    is never the text a gate searches for; it is one more indirection to follow or to report.
    """
    if quote == "'":
        return False                            # inside '' a $ is just a dollar sign
    return re.search(r"\$\{?[A-Za-z_0-9]", word) is not None


def is_whole_param_ref(word, quote):
    """The word is NOTHING BUT a parameter -- $anchor, "${MUT_ANCHOR[$i]}", "$1".

    Distinguished from a word that merely contains a `$`: a mixed word like "value=$x" is a
    literal with a substitution in it and has always been counted as one, whereas a word that is
    only a parameter carries no text at all and is one more indirection to follow or to report.

    🔴 2026-09-04: the docstring's own third example, "$1", used to be a lie -- the name part of
    the pattern required a letter or underscore FIRST, so a bare numbered positional parameter
    ($1..$9, or ${10}+) never matched and fell through as if it were two characters of literal
    anchor text. tests/shell/mutate_logger_cli.sh's `widen() { ... apply "$1" "$2" "$3" ...; }`
    calls `apply` (whose own signature names its 2nd argument `anchor`) with widen's OWN
    positional parameters, not a named local -- exactly the indirection this function exists to
    recognise -- and was reported MISSING against the literal string "$2", which occurs nowhere
    because it is not text. The generic rule further down already had a dead `name.isdigit()`
    branch for precisely this case that the bug made unreachable, which is the tell that
    recognising digits here was always the intent.
    """
    if quote == "'":
        return False
    return re.fullmatch(r"\$\{?(?:[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?|[0-9]+)\}?",
                        word.strip()) is not None


def expand_word(word, quote, env):
    """Substitute the variables the gate declared, inside a word.

    `"$OLD_LOOP"$'\x1f''<replacement>'` is ONE word whose first field is a variable holding the
    anchor. Only names the gate assigns are substituted; anything else is left visible so that
    it is reported rather than silently dropped.
    """
    if quote == "'" or "$" not in word:
        return word

    def sub(m):
        return env.get(m.group(1) or m.group(2), m.group(0))
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", sub, word)


def array_ref(word, quote):
    """`${NAME[$i]}` / `${NAME[i]}` -> NAME."""
    if quote == "'":
        return None
    m = re.fullmatch(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\[[^\]]*\]\}", word.strip())
    return m.group(1) if m else None


PACKED_SEP = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def declared_paths(gate_text, env, exists=None):
    """Every repo path the gate names: plain assignments, and `$DIR/$name` combinations.

    A repo-root target (`testbed_topo.py`) belongs here too, or the union an unpinned anchor
    falls back to would be every file the gate declares EXCEPT the one it mutates.
    """
    out = []
    for v in env.values():
        if is_repo_path(v, exists) and re.search(r"\.[A-Za-z0-9]+$", v):
            out.append(v)
    dirs = [v for v in env.values() if "/" in v and not re.search(r"\.[A-Za-z0-9]+$", v)]
    for m in re.finditer(r"(?<![\w/.-])([A-Za-z0-9_.-]+\.(?:sh|py|cpp|hpp|h|txt|md|env))"
                         r"(?![\w/.-])", gate_text):
        for d in dirs:
            out.append("%s/%s" % (d.rstrip("/"), m.group(1)))
    return sorted(set(out))


def extract(gate_text, gate_name, gate_path=None, exists=None):
    """-> (anchors, problems, delegates). anchor = (file, text, kind, where, want)."""
    gate_dir = os.path.dirname(gate_path) if gate_path else None
    paths_env = _prune(resolve_env(scalar_assignments(gate_text, gate_dir)))
    env = dict(paths_env)
    env.update(_prune(resolve_env(dict(scalar_assignments(gate_text, gate_dir),
                                       **quoted_assignments(gate_text, gate_dir)))))
    anchors, problems = [], []

    funcs = function_bodies(gate_text)
    sigs = {n: param_roles(b) for n, b in funcs.items()}
    builders = {n: m for n, m in ((n, builder_arrays(b)) for n, b in funcs.items()) if m}
    fdefault = {n: default_file_of(b, paths_env, exists) for n, b in funcs.items()}
    # Every name that is a function's own parameter or local. A word spelled "$anchor" INSIDE
    # mutate() is that parameter, not a literal -- the value is at the call sites, and those are
    # read separately. Without this the applier's own body would be reported as a broken anchor.
    locals_ = set()
    for b in funcs.values():
        for m in re.finditer(r"\blocal\s+([^\n]*)", b):
            locals_.update(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)=", m.group(1)))
            locals_.update(re.findall(r"(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)(?=\s|$)", m.group(1)))
        locals_.update(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)=\"?\$\{?[0-9]", b))

    # `mutate()` with the file baked into its body (mutate_topk_recursive_lock.sh style):
    # find which target variable the function writes to.
    default_file = fdefault.get("mutate")

    # Function BODIES are removed before the scan below. They hold the applier itself --
    # `perl ... "$1"`, `grep -F -- "$2" "$1"` -- whose "anchor" is a positional parameter, not
    # a string in any file. Counting those would invent broken anchors that do not exist.
    body = re.sub(r"^[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{.*?^\}", "",
                  gate_text, flags=re.S | re.M)
    body = re.sub(r"^\s*[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{[^\n]*\}\s*$", "",
                  body, flags=re.M)

    pending_py_file = None
    for cmd in split_commands(body):
        if not cmd:
            continue
        head, hq = cmd[0]

        if hq == "H":                                    # heredoc body
            for name, val, want in _py_anchors(head):
                anchors.append((pending_py_file, val, LITERAL, "%s (heredoc)" % name, want))
            pending_py_file = None
            continue

        if (head == "mutate"
                and not any(deref(w, q, env) is not w
                            and is_repo_path(deref(w, q, env), exists)
                            for w, q in cmd[1:])
                and not any(_looks_like_python(w) for w, _ in cmd[1:])):
            # The file is baked into the mutate() body, so the first argument is the anchor.
            # A one-argument call carries neither file nor anchor: it is a runner for the
            # apply_* calls above it, and those are picked up by the generic rule below.
            args = cmd[1:]
            if len(args) >= 2 and is_whole_param_ref(*args[0]):
                continue          # a table dispatch -- read at its call sites in pass 2 below
            if len(args) >= 2 and default_file:
                anchors.append((default_file, args[0][0], LITERAL, "mutate", 1))
            elif len(args) >= 2:
                problems.append("%s: mutate names no file and none is implied" % gate_name)
            continue


        if head in ("perl", "sed", "python3", "python"):
            raw = cmd[1:]
            # Operand words only: never an option, never the script/program argument itself
            # (a perl s/// program is full of slashes and would otherwise look like a path).
            skip = set()
            for k, (w, _) in enumerate(raw):
                if w in ("-e", "-E", "-f") and k + 1 < len(raw):
                    skip.add(k + 1)
                if re.match(r"^s.", w) and k not in skip and head == "sed":
                    skip.add(k)
            files = []
            for k, (w, q) in enumerate(raw):
                if k in skip or w.startswith("-"):
                    continue
                val = deref(w, q, env)
                # Either it resolved from a declared path variable, or it is a literal path.
                if val is not w and is_repo_path(val, exists):
                    files.append(val)
                elif q != "'" and is_repo_path(val, exists) and not val.startswith("s/"):
                    files.append(val)

            if head == "perl":
                progs = [raw[k + 1][0] for k, (w, _) in enumerate(raw)
                         if w in ("-e", "-E") and k + 1 < len(raw)]
                inline = [w for w, _ in raw if re.match(r"^-[0-9a-zA-Z]*e", w) and len(w) > 2]
                if not progs and inline:
                    progs = [inline[0]]
                if not progs:
                    continue                             # perl used to COUNT, not to mutate
                for prog in progs:
                    pat = _perl_subst_pattern(prog)
                    if pat is None:
                        problems.append("%s: unparsed perl program %r" % (gate_name, prog[:60]))
                        continue
                    anchors.append((files[-1] if files else None, pat, PERL_RE, "perl s///", 1))
                continue

            if head == "sed":
                if not any(w == "-i" or w.startswith("-i") for w, _ in raw):
                    continue                             # read-only sed
                for w, q in raw:
                    if q in ("'", '"') and re.match(r"^s(.)", w):
                        pat = _perl_subst_pattern(w)
                        if pat is None:
                            problems.append("%s: unparsed sed script %r" % (gate_name, w[:60]))
                        else:
                            anchors.append((files[-1] if files else None, pat, SED_RE, "sed -i", 1))
                continue

            # python3 - "$FILE" <<EOF : the heredoc that follows edits that file.
            if files:
                pending_py_file = files[-1]
            continue

    full = split_commands(gate_text)

    # -------------------------------------------------------------- pass 1.5: "case" heredocs
    # 2026-09-04. `write_case <name> <expect> <<'PAIR'\n<FROM>\n@@@TO@@@\n<TO>\nPAIR` -- all four
    # of tests/shell/mutate_g6_apps_liveness.sh, mutate_g7_ndtwin_lab_config.sh,
    # mutate_g9_cleanup_no_pkill_f.sh and mutate_g9_faults_topo_pid.sh store their mutation table
    # this way: one heredoc per case, split on the literal marker line by a small python applier
    # read back at RUNTIME (`frm, to = pair.split("@@@TO@@@\n")`). Every one of them was
    # NO-ANCHORS: pass 1's heredoc handling only looks for python inside a heredoc, via
    # `_py_anchors`, and there is no python in a write_case heredoc to find -- it is FROM/TO text,
    # not code.
    #
    # The target file is not named at write_case's own call site; it is resolved the same way
    # default_file_of resolves any other applier's baked-in file, applied to whichever function's
    # body contains the split marker AS PYTHON SOURCE (whichever function actually consumes
    # "@@@TO@@@", as opposed to some unrelated function -- run_suite() in these same gates also
    # bakes in a file of its own, the test SUITE it runs, and guessing "the gate's only baked-in
    # file" would have pinned every case to the wrong one).
    CASE_MARKER = "@@@TO@@@"
    applier = next((n for n, b in funcs.items()
                    if ('"%s' % CASE_MARKER) in b or ("'%s" % CASE_MARKER) in b), None)
    case_file = fdefault.get(applier) if applier else None
    for cmd in full:
        if not cmd:
            continue
        head, hq = cmd[0]
        # The marker on a line of its OWN, i.e. followed by a real newline byte -- not merely
        # present, or the applier's own heredoc (`pair.split("@@@TO@@@\n")` is genuine python
        # source, the marker followed by a literal backslash-n inside a quoted string, matched
        # here too if this required only substring presence) would be misread as a case of its
        # own with no FROM text worth anything.
        if hq != "H" or (CASE_MARKER + "\n") not in head:
            continue
        frm = head.split(CASE_MARKER + "\n", 1)[0]
        if frm:
            anchors.append((case_file, frm, LITERAL, "write_case heredoc", 1))

    # -------------------------------------------------------------- pass 1.6: "<name>.old/.new"
    # 2026-09-04. `cat > "$DIR/<name>.old" <<'EOF' ... EOF` / same for `.new` -- tests/shell/
    # mutate_build_guard.sh and mutate_ndt_up_target.sh (whose own header says its shape is
    # copied from build_guard's) store their mutation table as a PAIR of files per case, written
    # by `cat >` and read back at runtime by a small python applier. build_guard's own header
    # explains why this shape exists at all: an earlier version packed old/new as shell WORDS and
    # silently lost six mutations to backslash-escaping and a `grep -F` that read a trailing
    # newline as a second, empty pattern matching every line -- "files have no quoting" is the
    # point, and also why this text is never a shell argument for pass 2 below to find.
    CASE_FILE_RE = re.compile(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/([A-Za-z0-9_.+-]+)\.(old|new)$")
    case_pairs = {}
    pending_case = None
    for cmd in full:
        if not cmd:
            continue
        head, hq = cmd[0]
        if hq == "H":
            if pending_case:
                name, suffix = pending_case
                case_pairs.setdefault(name, {})[suffix] = head
            pending_case = None
            continue
        pending_case = None
        if head != "cat" or len(cmd) != 3 or cmd[1] != (">", ""):
            continue
        m = CASE_FILE_RE.match(cmd[2][0])
        if m:
            pending_case = (m.group(1), m.group(2))

    # Whichever function's body reads BOTH suffixes back (the applier, e.g. mutant()) -- found
    # the same positive way write_case's applier is, rather than assumed from its name or from
    # being the gate's only function with a baked-in file (run_suite()-shaped functions exist
    # here too).
    case_applier = next((n for n, b in funcs.items() if ".old" in b and ".new" in b), None)
    case_file = fdefault.get(case_applier) if case_applier else None

    # mutate_build_guard.sh's applier is not this simple: `mutant <name> <rel>` takes its target
    # FILE per-case too (cmake/ninja/make/_resolve.sh all share one gate), so a single case_file
    # for the whole gate is wrong for it specifically. Its own baked-in value is a DIRECTORY, not
    # a file ($GUARD, no extension, so default_file_of above correctly declined it) -- combined
    # here with whatever relative path sits beside a bare word naming one of these cases, at the
    # call site of any locally-defined function whose OWN signature names a ROLE_FILE argument
    # (check() in build_guard: `local label=$1 name=$2 rel=$3 want=$4`, two levels above mutant()
    # itself, which is why this is not simply another ROLE_FILE pin further down).
    if case_pairs and case_applier:
        case_dir = next((paths_env[v] for v in re.findall(r'"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"',
                                                           funcs[case_applier])
                         if paths_env.get(v) and "/" in paths_env[v]
                         and not re.search(r"\.[A-Za-z0-9]+$", paths_env[v])), None)
        if case_dir:
            for cmd in full:
                if len(cmd) < 2:
                    continue
                head, hq = cmd[0]
                fpos = role_position(sigs.get(head) or {}, ROLE_FILE)
                if fpos is None or fpos >= len(cmd):
                    continue
                names_here = {w for w, q in cmd[1:] if q == "" and w in case_pairs}
                relw, relq = cmd[fpos]
                if not names_here or relq != "" or "$" in relw:
                    continue
                for nm in names_here:
                    case_pairs[nm]["_file"] = case_dir.rstrip("/") + "/" + relw

    for name, pair in case_pairs.items():
        old = pair.get("old")
        if old:
            anchors.append((pair.get("_file", case_file), old, LITERAL,
                            "cat > *.old heredoc", 1))

    # ------------------------------------------------------------------- pass 2: the call sites
    # This pass reads the FULL text, function bodies included, because that is where three of the
    # four unreadable gates keep their mutation tables. It runs only rules that need a positively
    # identified file AND a literal anchor; the appliers themselves (perl/sed/python over "$1")
    # stay in pass 1 above, where a positional parameter cannot be mistaken for a string in a file.
    seen = {(f, t, k, n) for f, t, k, _w, n in anchors}
    unread_params = []

    def add(f, text_, where, want=1):
        # Deduplicated: the same anchor reached twice -- once through the table, once at the
        # builder's own call site -- is one anchor, and counting it twice would say nothing new.
        if not text_ or (f, text_, LITERAL, want) in seen:
            return
        seen.add((f, text_, LITERAL, want))
        anchors.append((f, text_, LITERAL, where, want))

    def path_at(cmd, pos):
        if pos is None or pos >= len(cmd):
            return None
        w, q = cmd[pos]
        v = deref(w, q, env)
        return v if (v is not w and is_repo_path(v, exists)) else None

    def var_head_targets(head, hq):
        """`"$m" ... ` -- a callback. The value is at the enclosing function's own call sites:
        each_mutation() takes `local m="$1"` and is called as `each_mutation mutate`."""
        if hq == "'":
            return []
        m = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", head.strip())
        if not m:
            return []
        var, out = m.group(1), []
        for fname, roles in sigs.items():
            for pos, role in roles.items():
                if role != var:
                    continue
                for c in full:
                    if c[0][0] == fname and pos < len(c) and c[pos][0] in funcs:
                        out.append(c[pos][0])
        return list(dict.fromkeys(out))

    # (i) + (ii) a call whose own signature names which argument is the anchor -- either spelled
    #     out on the line, or reached through the parallel arrays a table builder filled.
    builders_used = set()
    for cmd in full:
        if len(cmd) < 2:
            continue
        head, hq = cmd[0]
        for fn in ([head] if head in sigs else var_head_targets(head, hq)):
            roles = sigs.get(fn) or {}
            apos = role_position(roles, ROLE_ANCHOR)
            if apos is None or apos >= len(cmd):
                continue
            fpos = role_position(roles, ROLE_FILE)
            aw, aq = cmd[apos]
            arr = array_ref(aw, aq)
            if arr is None:
                aw = expand_word(aw, aq, env)
                if not is_whole_param_ref(aw, aq):
                    add(path_at(cmd, fpos) or fdefault.get(fn), aw, fn)
                continue
            farr = array_ref(*cmd[fpos]) if (fpos is not None and fpos < len(cmd)) else None
            b = next((bn for bn, mp in builders.items() if arr in mp.values()), None)
            if b is None:
                problems.append("%s: %s is dispatched from %s, which no table builder in this "
                                "gate fills -- its anchors are NOT checked"
                                % (gate_name, fn, arr))
                continue
            builders_used.add(b)
            ba = next(p for p, a in builders[b].items() if a == arr)
            bf = next((p for p, a in builders[b].items() if a == farr), None)
            for c2 in full:
                if c2[0][0] != b or ba >= len(c2):
                    continue
                w2, q2 = c2[ba]
                w2 = expand_word(w2, q2, env)
                if is_whole_param_ref(w2, q2):
                    unread_params.append("%s() argument %d" % (b, ba))
                    continue
                add(path_at(c2, bf) or fdefault.get(fn), w2, "%s -> %s" % (b, arr))

    # A gate that builds a mutation table this tool never managed to read is NOT checked, and
    # says so. Silence here is the exact failure L-3 is about.
    def _builder_uncovered(bn):
        """Call sites of a table builder whose anchor is nowhere in what this tool extracted.

        A gate may declare the same anchor twice -- once in a table used for a uniqueness
        pre-check, once at the mutation call itself (mutate_bx_flow_liveness.sh does exactly
        that) -- so "this tool did not read the dispatch" is not the same as "these anchors are
        unchecked". What matters is whether the TEXT was checked, by whichever route.
        """
        covered = {t for _f, t, _k, _w, _n in anchors}
        sites, blind = 0, 0
        for c in full:
            if not c or c[0][0] != bn:
                continue
            sites += 1
            lits = [expand_word(w, q, env) for w, q in c[1:] if q in ("'", '"')]
            if not any(l in covered for l in lits if len(l) >= 8):
                blind += 1
        return sites, blind

    # (iii) an anchor and its replacement packed into ONE argument, separated by a control
    #       character written as $'\x1f'. Nothing else in these scripts puts a control character
    #       in an argument, so the marker identifies the shape on its own.
    for cmd in full:
        if len(cmd) < 2:
            continue
        head, hq = cmd[0]
        if head in NOT_APPLIERS or hq == "H":
            continue
        for w, q in cmd[1:]:
            if q not in ("'", '"') or not PACKED_SEP.search(w):
                continue
            first = expand_word(PACKED_SEP.split(w)[0], q, env)
            if is_whole_param_ref(first, q):
                unread_params.append("%s packed argument %s" % (head, first[:40]))
            elif len(first) >= 8:
                add(fdefault.get(head), first, "%s (packed)" % head)

    for cmd in full:
        if not cmd:
            continue
        head, hq = cmd[0]
        if hq == "H" or head in NOT_APPLIERS or head in ("perl", "sed", "python3", "python"):
            continue                 # those four are pass 1's, over the stripped body
        if not (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", head)
                or re.fullmatch(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?", head)):
            continue

        # A `mutate "label" [args] '<python>'` style call: the body is a quoted argument.
        took_python = False
        for w, q in cmd[1:]:
            if q in ("'", '"') and len(w) > 20 and _looks_like_python(w):
                got = _py_anchors(w)
                if not got:
                    continue
                took_python = True
                # A file named on this same line wins; otherwise the anchor is looked for
                # across every path the gate declares (see resolve_union below).
                same_line = []
                for x, xq in cmd[1:]:
                    v = deref(x, xq, env)
                    if v is not x and is_repo_path(v, exists):
                        same_line.append(v)
                    elif re.fullmatch(r"[A-Za-z0-9_.-]+\.(sh|py|env|txt)", v):
                        # A bare basename: the gate joins it to one of its directory
                        # variables (`"$sb/$HARNESS_REL/$rel"`), so try each of those.
                        same_line += ["%s/%s" % (d.rstrip("/"), v) for d in env.values()
                                      if "/" in d and not re.search(r"\.[A-Za-z0-9]+$", d)]
                tgt = tuple(dict.fromkeys(same_line)) if len(same_line) > 1 else (
                    same_line[0] if same_line else None)
                for name, val, want in got:
                    add(tgt, val, "%s (%s)" % (name, head), want)
        if took_python:
            continue

        # Generic shape: some argument resolves to a declared path, and the quoted argument
        # right after it is the text to be replaced. Every hand-rolled applier in this repo
        # (`mutate_must_die "name" "case" "$SRC" 'anchor' 'repl'`) is written this way.
        args = cmd[1:]
        for k in range(len(args) - 1):
            w, q = args[k]
            val = deref(w, q, env)
            if val is w or not is_repo_path(val, exists):
                continue
            nxt, nq = args[k + 1]
            if nq not in ("'", '"') or len(nxt) < 8 or nxt.startswith("-"):
                continue
            nxt = expand_word(nxt, nq, env)
            if is_whole_param_ref(nxt, nq):
                # 🔴 NOT an anchor: it is one more indirection. `${MUT_ANCHOR[$i]}` is what made
                # mutate_ryu_rest_topology_bounded.sh report MISSING:1 against a file whose
                # anchors were all fine. A parameter of the enclosing function is the applier
                # reading its own argument and is silent; an array the table dispatch already
                # read is silent; anything else is unread, and is said so out loud.
                name = re.sub(r"^\$\{?|\}?$", "", re.sub(r"\[.*\]", "", nxt))
                if not (name in locals_ or name.isdigit() or array_ref(nxt, nq)):
                    unread_params.append("%s %s" % (head, nxt[:40]))
                continue
            if len(nxt) < 8:
                continue
            # `apply_exact <file> <old> <new> <count>`: some anchors are deliberately
            # NOT unique and the gate says how many it expects. Honour that number --
            # calling a declared count of 3 a duplicate would be this tool inventing a
            # failure, which is the same sin as missing a real one.
            want = 1
            if k + 3 < len(args) and re.fullmatch(r"\d+", args[k + 3][0]):
                want = int(args[k + 3][0])
            add(val, nxt, head, want)

    # An anchor whose file this tool could not pin down is checked against EVERY path the
    # gate declares, and counts as resolved when it appears exactly once across all of them.
    # That is weaker than naming the file, but it is the honest weakening: it still catches
    # the drift this tool exists for, and it never reports ok for an anchor it did not find.
    # A gate that builds a mutation table this tool never read is NOT checked, and says so.
    # Silence here is the exact failure L-3 is about: an anchor checker that skips a gate and
    # scores the run as if it had not.
    for bn in builders:
        if bn in builders_used:
            continue
        sites, blind = _builder_uncovered(bn)
        if blind or not sites:
            problems.append("%s: %s() fills a mutation table and %s -- those anchors are "
                            "NOT checked"
                            % (gate_name, bn,
                               "%d of its %d call sites carry an anchor this tool never read"
                               % (blind, sites) if sites else "this tool found no call site"))

    # When one rule pinned an anchor's file and another only reached the union of every path the
    # gate declares, keep the pinned one: the union is the weaker answer, and it is the one that
    # can invent a DUP by finding the same text in a second declared file.
    pinned = {(t, k, n) for f, t, k, _w, n in anchors if isinstance(f, str)}
    anchors = [a for a in anchors
               if a[0] is not None or (a[1], a[2], a[4]) not in pinned]

    union = tuple(declared_paths(gate_text, paths_env, exists))
    fixed = []
    for f, text, kind, where, want in anchors:
        if f is None:
            if not union:
                problems.append("%s: anchor %r has no target file" % (gate_name, text[:40]))
                continue
            f = union                       # a tuple means "search all of these"
        fixed.append((f, text, kind, where, want))

    for u in dict.fromkeys(unread_params):
        problems.append("%s: %s is an anchor this tool could not resolve to a literal -- it is "
                        "NOT checked" % (gate_name, u))

    # A driver gate has no anchors of its own; it runs other gates. `mutate_lock_lease_all.sh` is
    # the whole kernel-side evidence for A-9 and this tool used to report it NO-ANCHORS, which is
    # honest but useless. Naming its delegates lets the caller give it their verdict instead, so
    # a broken anchor three levels down cannot leave the driver looking unexamined-but-fine.
    delegates = []
    for name, vals in array_assignments(gate_text, gate_dir).items():
        if not re.search(r'\bin\s+"\$\{%s\[@\]\}"' % re.escape(name), gate_text):
            continue                        # declared but never walked: not a delegation
        for v in vals:
            if re.search(r"(^|/)mutate_[A-Za-z0-9_]+\.sh$", v) and v != gate_path:
                delegates.append(v)

    return fixed, problems, sorted(dict.fromkeys(delegates))


# ------------------------------------------------------------------------------- git access
class Rev:
    def __init__(self, repo, rev):
        self.repo, self.rev, self._cache = repo, rev, {}

    def _git(self, *args):
        return subprocess.run(("git", "-C", self.repo) + args,
                              capture_output=True, text=True)

    def show(self, path):
        if path not in self._cache:
            p = self._git("show", "%s:%s" % (self.rev, path))
            self._cache[path] = p.stdout if p.returncode == 0 else None
        return self._cache[path]

    def gates(self):
        p = self._git("ls-tree", "--name-only", self.rev, "tests/shell/")
        return sorted(l for l in p.stdout.splitlines()
                      if os.path.basename(l).startswith("mutate_") and l.endswith(".sh"))


def merged_body(repo, path, ours, base, theirs, tmpdir):
    """The 3-way merge of one file, as git itself would produce it.

    This is what makes a cross-branch answer mean anything: a gate from branch X checked
    against branch Y's tree alone finds nothing, because Y does not carry X's fix. What the
    batch actually produces is X's file merged with Y's, and that is what the anchors have
    to survive. Returns (text, conflicted) or (None, False) when the file is absent.
    """
    def show(rev):
        p = subprocess.run(("git", "-C", repo, "show", "%s:%s" % (rev, path)),
                           capture_output=True, text=True)
        return p.stdout if p.returncode == 0 else None

    o, b, t = show(ours), show(base), show(theirs)
    if o is None:
        return None, False
    if t is None or b is None or o == t:
        return o, False
    names = {}
    for tag, body in (("ours", o), ("base", b), ("theirs", t)):
        fn = os.path.join(tmpdir, "%s.%s" % (tag, os.path.basename(path)))
        with open(fn, "w") as fh:
            fh.write(body)
        names[tag] = fn
    p = subprocess.run(("git", "-C", repo, "merge-file", "-p", "--diff3",
                        names["ours"], names["base"], names["theirs"]),
                       capture_output=True, text=True)
    # returncode > 0 is the number of conflicts; < 0 is an error.
    return p.stdout, p.returncode > 0


def count(anchor, kind, body):
    """Occurrences of one anchor in one file body, counted by whoever owns the dialect."""
    if kind == LITERAL:
        return body.count(anchor)
    if kind == PERL_RE:
        p = subprocess.run(["perl", "-0777", "-ne",
                            'my $r = $ENV{ANCHOR}; my $c = () = /$r/g; print $c'],
                           input=body, capture_output=True, text=True,
                           env=dict(os.environ, ANCHOR=anchor))
        try:
            return int(p.stdout.strip() or -1)
        except ValueError:
            return -1
    if kind == SED_RE:
        p = subprocess.run(["sed", "-n", "/%s/p" % anchor.replace("/", r"\/")],
                           input=body, capture_output=True, text=True)
        if p.returncode != 0:
            return -1
        return len([l for l in p.stdout.splitlines() if l])
    return -1


# ------------------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="Check mutation-gate anchors against a git rev.")
    ap.add_argument("revs", nargs="*", help="revs whose FILES the anchors are counted in")
    ap.add_argument("--revs-file", metavar="PATH",
                    help="read revs from this file, one per line (blank lines and # ignored)")
    ap.add_argument("--gates-from", metavar="REV",
                    help="take the gate scripts from this rev instead of from each rev itself")
    ap.add_argument("--gates", nargs="+", metavar="NAME",
                    help="only these gates (basename or path)")
    ap.add_argument("--merge-with-base", metavar="REV",
                    help="simulate the batch: 3-way merge each anchor's file between the "
                         "--gates-from rev and each column rev over this common base, and "
                         "count the anchors in the MERGED text. Without it, a gate is checked "
                         "against a column rev's file as it stands, which for a gate whose "
                         "fix that rev does not carry is a guaranteed miss and says nothing.")
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print every anchor, not only the broken ones")
    a = ap.parse_args()

    rev_names = list(a.revs)
    if a.revs_file:
        with open(a.revs_file) as fh:
            rev_names += [l.strip() for l in fh
                          if l.strip() and not l.lstrip().startswith("#")]
    if not rev_names:
        ap.error("give at least one rev, or --revs-file")

    src = Rev(a.repo, a.gates_from) if a.gates_from else None
    revs = [Rev(a.repo, r) for r in rev_names]

    if src:
        names = src.gates()
    else:
        # Union across the revs, not just the first: a gate a branch ADDS is exactly the one
        # nobody else has checked, and taking the list from one rev would hide it.
        seen = set()
        for rv in revs:
            seen.update(rv.gates())
        names = sorted(seen)
    if a.gates:
        want = {os.path.basename(g) for g in a.gates}
        names = [n for n in names if os.path.basename(n) in want]
    if not names:
        print("no gate scripts found", file=sys.stderr)
        return 2

    if a.merge_with_base and not a.gates_from:
        ap.error("--merge-with-base only means something together with --gates-from")
    import tempfile
    tmpdir = tempfile.mkdtemp(prefix="gate_anchors_")

    grid, unparsed, details = {}, [], []
    delegation = {}
    for gate in names:
        for rv in revs:
            holder = src or rv
            text = holder.show(gate)
            if text is None:
                grid[(gate, rv.rev)] = "absent"
                continue
            anchors, problems, delegates = extract(
                text, os.path.basename(gate), gate, lambda p, _r=rv: _r.show(p) is not None)
            unparsed += ["%s @%s: %s" % (os.path.basename(gate), rv.rev, p) for p in problems]
            if delegates and not anchors and not problems:
                # A driver with no anchors of its own. Its verdict is its delegates' verdict,
                # resolved after every cell exists -- never "ok", which would report a pass for
                # a gate this tool did not read.
                delegation[(gate, rv.rev)] = delegates
                grid[(gate, rv.rev)] = "PENDING-VIA"
                continue
            if not anchors and not problems:
                # A gate with no anchors is an EXTRACTION failure, never a pass: this tool
                # would otherwise report a perfect score for a gate it never read.
                grid[(gate, rv.rev)] = "NO-ANCHORS"
                unparsed.append("%s @%s: no anchors extracted from this gate"
                                % (os.path.basename(gate), rv.rev))
                continue
            missing, dup, nofile, conflicts = [], [], [], []
            for f, anchor, kind, where, want in anchors:
                paths = f if isinstance(f, tuple) else (f,)
                c, seen_any = 0, False
                for path in paths:
                    if a.merge_with_base and src and src.rev != rv.rev:
                        body, clash = merged_body(a.repo, path, src.rev, a.merge_with_base,
                                                  rv.rev, tmpdir)
                        if clash:
                            conflicts.append(path)
                    else:
                        body = rv.show(path)
                    if body is None:
                        continue
                    seen_any = True
                    c += count(anchor, kind, body)
                if not seen_any:
                    nofile.append(paths[0] if len(paths) == 1 else "|".join(paths))
                    continue
                f = paths[0] if len(paths) == 1 else "(%d declared paths)" % len(paths)
                if a.verbose:
                    print("    %-34s %-28s %s x%d  %s" % (os.path.basename(gate), rv.rev,
                                                          kind, c, f))
                if want is None:
                    # "at least one, no upper bound" -- see _replace_call_want. A bare
                    # `s.replace(old, new)` cannot mutate the wrong site the way a single-target
                    # applier can, so more than one match is not a DUP; zero still is MISSING.
                    if c >= 1:
                        continue
                    missing.append((f, anchor, kind, where, c, 1))
                    continue
                if c == want:
                    continue
                (dup if c > want else missing).append((f, anchor, kind, where, c, want))
            if problems:
                grid[(gate, rv.rev)] = "UNPARSED"
            elif nofile:
                grid[(gate, rv.rev)] = "NOFILE:%d" % len(set(nofile))
            elif missing:
                grid[(gate, rv.rev)] = "MISSING:%d" % len(missing)
            elif dup:
                grid[(gate, rv.rev)] = "DUP:%d" % len(dup)
            elif conflicts:
                grid[(gate, rv.rev)] = "CONFLICT"
            else:
                grid[(gate, rv.rev)] = "ok(%d)" % len(anchors)
            for f, anchor, kind, where, c, want in missing + dup:
                details.append((os.path.basename(gate), rv.rev, f, where, kind,
                                c, anchor, want))
            for f in sorted(set(nofile)):
                details.append((os.path.basename(gate), rv.rev, f, "-", "no such file",
                                -1, "(the anchor's target file is not in this rev)", 1))

    # ------------------------------------------------------- a driver gate inherits its verdict
    # Resolved only now, because a delegate's own cell has to exist first. Three ways this can
    # go, and only one of them is a pass: every delegate checked and ok; a delegate this run did
    # not check at all (report it and fail, never inherit a silence); or a delegate whose anchors
    # are broken, which makes the driver broken too -- it is the driver that gets quoted as the
    # evidence, so it must not read clean while the gate under it cannot apply its mutation.
    for (gate, rev), delegates in delegation.items():
        states, absent = [], []
        for d in delegates:
            if (d, rev) in grid:
                states.append(grid[(d, rev)])
            else:
                absent.append(d)
        if absent or not states:
            grid[(gate, rev)] = "VIA-UNCHECKED"
            for d in absent or ["(none resolved)"]:
                unparsed.append("%s @%s: delegates to %s, which this run did not check -- the "
                                "driver's verdict is NOT its delegates' verdict"
                                % (os.path.basename(gate), rev, d))
        elif all(s.startswith("ok") for s in states):
            grid[(gate, rev)] = "ok-via(%d)" % len(states)
        else:
            grid[(gate, rev)] = "VIA-BROKEN"
            for d, s in zip(delegates, states):
                if not s.startswith("ok"):
                    details.append((os.path.basename(gate), rev, d, "delegated gate", s,
                                    -1, "(this driver's verdict is this delegate's verdict)", 1))

    w = max(len(os.path.basename(g)) for g in names) + 2
    cw = 14
    print("anchors of each gate, counted in each rev's own files"
          + ("; gates read from %s" % a.gates_from if a.gates_from else ""))
    print("columns:")
    for k, r in enumerate(revs):
        print("  c%-3d %s" % (k, r.rev))
    print()
    print("".ljust(w) + "".join(("c%d" % k).ljust(cw) for k in range(len(revs))))
    for gate in names:
        print(os.path.basename(gate).ljust(w)
              + "".join(grid[(gate, r.rev)].ljust(cw) for r in revs))

    if details:
        print("\n--- broken anchors ---")
        for gate, rev, f, where, kind, c, anchor, want in details:
            head = anchor.split("\n")[0]
            print("%s @ %s\n  file  : %s\n  from  : %s (%s)\n  count : %d (want %d)"
                  "\n  anchor: %s%s"
                  % (gate, rev, f, where, kind, c, want, head[:110],
                     " ..." if "\n" in anchor or len(head) > 110 else ""))
    # 🔴 THE ONE THING THIS TOOL MUST NEVER DO is let "could not check" read like "checked and
    # passed". Every counted-and-fine cell is `ok(n)` or `ok-via(n)`; everything else is named,
    # counted here, and repeated on stderr so a truncated or teed stdout cannot swallow it.
    bad = [v for v in grid.values() if not v.startswith("ok")]
    blind = [k for k, v in grid.items()
             if v in ("UNPARSED", "NO-ANCHORS", "VIA-UNCHECKED", "PENDING-VIA")]
    print("\n%d/%d cells ok  (%d not ok, of which %d were NOT CHECKED AT ALL)"
          % (len(grid) - len(bad), len(grid), len(bad), len(blind)))
    if unparsed:
        print("\n--- UNPARSED mutation constructs (NOT checked -- this is not a pass) ---")
        for u in unparsed:
            print("  " + u)
        print("\nA gate this tool cannot read is a gate it is not checking. Exit 2 says so; it is"
              "\nnot exit 0 with a caveat, and it must not be read as one.")
        print("check_gate_anchors: %d gate-cell(s) COULD NOT BE CHECKED (exit 2); "
              "%d other cell(s) not ok" % (len(blind), len(bad) - len(blind)), file=sys.stderr)
        return 2
    if bad:
        print("check_gate_anchors: %d cell(s) not ok (exit 1)" % len(bad), file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
