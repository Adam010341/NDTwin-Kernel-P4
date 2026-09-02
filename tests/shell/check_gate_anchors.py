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
gate states otherwise (`apply_exact <file> <old> <new> <count>`).

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

Counting is `str.count()` on the exact literal for literal anchors. Anchors that are
regexes in the gate (perl `s///`, `sed -i s///`) are counted by perl and sed themselves,
because reimplementing their regex dialects here would be a second place for the answer to
be wrong.

KNOWN LIMIT: a gate that only drives other gates (`mutate_lock_lease_all.sh`) has no
anchors of its own and is reported NO-ANCHORS. That is the honest answer -- this tool has
not checked it -- and the gates it delegates to must be listed separately.
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
    pending_heredocs = []

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
        if c == "'":
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
    return cmds


def scalar_assignments(text):
    """`NAME=value` at the start of a line, value a plain word (no $(...) or backticks)."""
    out = {}
    for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(\S*)\s*$", text, re.M):
        name, val = m.group(1), m.group(2)
        if "$(" in val or "`" in val or val.startswith("$"):
            continue
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
            val = val[1:-1]
        out[name] = val
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


def _py_anchors(block):
    """Every anchor a python mutation body searches for.

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
            found.append((m.group(1), val))
    for m in re.finditer(r"\.replace\(\s*(\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')", block):
        try:
            val = ast.literal_eval(m.group(1))
        except (ValueError, SyntaxError):
            continue
        if isinstance(val, str) and val:
            found.append(("replace", val))
    return found


def _looks_like_python(s):
    return ("sys.argv" in s or "pathlib" in s or "s.replace(" in s
            or re.search(r"^\s*(old|guard|store)\s*=", s, re.M) is not None)


def declared_paths(gate_text, env):
    """Every repo path the gate names: plain assignments, and `$DIR/$name` combinations."""
    out = []
    for v in env.values():
        if "/" in v and re.search(r"\.[A-Za-z0-9]+$", v):
            out.append(v)
    dirs = [v for v in env.values() if "/" in v and not re.search(r"\.[A-Za-z0-9]+$", v)]
    for m in re.finditer(r"(?<![\w/.-])([A-Za-z0-9_.-]+\.(?:sh|py|cpp|hpp|h|txt|md|env))"
                         r"(?![\w/.-])", gate_text):
        for d in dirs:
            out.append("%s/%s" % (d.rstrip("/"), m.group(1)))
    return sorted(set(out))


def extract(gate_text, gate_name):
    """-> (anchors, problems). anchor = (file, text, kind, where)."""
    env = scalar_assignments(gate_text)
    anchors, problems = [], []

    # `mutate()` with the file baked into its body (mutate_topk_recursive_lock.sh style):
    # find which target variable the function writes to.
    default_file = None
    fn = re.search(r"^mutate\(\)\s*\{(.*?)^\}", gate_text, re.S | re.M)
    if fn:
        for var in re.findall(r'"\$([A-Za-z_][A-Za-z0-9_]*)"', fn.group(1)):
            if var in env and "/" in env[var]:
                default_file = env[var]
                break

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
            for name, val in _py_anchors(head):
                anchors.append((pending_py_file, val, LITERAL, "%s (heredoc)" % name, 1))
            pending_py_file = None
            continue

        if (head == "mutate"
                and not any("/" in deref(w, q, env) and deref(w, q, env) is not w
                            for w, q in cmd[1:])
                and not any(_looks_like_python(w) for w, _ in cmd[1:])):
            # The file is baked into the mutate() body, so the first argument is the anchor.
            # A one-argument call carries neither file nor anchor: it is a runner for the
            # apply_* calls above it, and those are picked up by the generic rule below.
            args = cmd[1:]
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
                if val is not w and "/" in val:
                    files.append(val)
                elif q != "'" and "/" in val and not val.startswith("s/"):
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

        if head in NOT_APPLIERS or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", head):
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
                    if v is not x and "/" in v:
                        same_line.append(v)
                    elif re.fullmatch(r"[A-Za-z0-9_.-]+\.(sh|py|env|txt)", v):
                        # A bare basename: the gate joins it to one of its directory
                        # variables (`"$sb/$HARNESS_REL/$rel"`), so try each of those.
                        same_line += ["%s/%s" % (d.rstrip("/"), v) for d in env.values()
                                      if "/" in d and not re.search(r"\.[A-Za-z0-9]+$", d)]
                tgt = tuple(dict.fromkeys(same_line)) if len(same_line) > 1 else (
                    same_line[0] if same_line else None)
                for name, val in got:
                    anchors.append((tgt, val, LITERAL, "%s (%s)" % (name, head), 1))
        if took_python:
            continue

        # Generic shape: some argument resolves to a declared path, and the quoted argument
        # right after it is the text to be replaced. Every hand-rolled applier in this repo
        # (`mutate_must_die "name" "case" "$SRC" 'anchor' 'repl'`) is written this way.
        args = cmd[1:]
        for k in range(len(args) - 1):
            w, q = args[k]
            val = deref(w, q, env)
            if val is w or "/" not in val:
                continue
            nxt, nq = args[k + 1]
            if nq in ("'", '"') and len(nxt) >= 8 and not nxt.startswith("-"):
                # `apply_exact <file> <old> <new> <count>`: some anchors are deliberately
                # NOT unique and the gate says how many it expects. Honour that number --
                # calling a declared count of 3 a duplicate would be this tool inventing a
                # failure, which is the same sin as missing a real one.
                want = 1
                if k + 3 < len(args) and re.fullmatch(r"\d+", args[k + 3][0]):
                    want = int(args[k + 3][0])
                anchors.append((val, nxt, LITERAL, head, want))

    # An anchor whose file this tool could not pin down is checked against EVERY path the
    # gate declares, and counts as resolved when it appears exactly once across all of them.
    # That is weaker than naming the file, but it is the honest weakening: it still catches
    # the drift this tool exists for, and it never reports ok for an anchor it did not find.
    union = tuple(declared_paths(gate_text, env))
    fixed = []
    for f, text, kind, where, want in anchors:
        if f is None:
            if not union:
                problems.append("%s: anchor %r has no target file" % (gate_name, text[:40]))
                continue
            f = union                       # a tuple means "search all of these"
        fixed.append((f, text, kind, where, want))

    return fixed, problems


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
    for gate in names:
        for rv in revs:
            holder = src or rv
            text = holder.show(gate)
            if text is None:
                grid[(gate, rv.rev)] = "absent"
                continue
            anchors, problems = extract(text, os.path.basename(gate))
            unparsed += ["%s @%s: %s" % (os.path.basename(gate), rv.rev, p) for p in problems]
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

    w = max(len(os.path.basename(g)) for g in names) + 2
    cw = 11
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
    if unparsed:
        print("\n--- UNPARSED mutation constructs (NOT checked) ---")
        for u in unparsed:
            print("  " + u)
        return 2

    bad = [v for v in grid.values() if not v.startswith("ok")]
    print("\n%d/%d cells ok" % (len(grid) - len(bad), len(grid)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
