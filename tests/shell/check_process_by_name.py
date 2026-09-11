#!/usr/bin/env python3
"""No script in this tree may find or signal a process BY NAME, or teach anyone to.

[Co-developed with claude code -- Adam]

CLAUDE.md, engineering discipline: "永不 `pkill -f`／`pgrep -f` 殺程序". KNOWN-ISSUES G-9 and
G-inst-2 are the two times it was learned the expensive way:

  * faults.sh printed `pgrep -f '[t]estbed_topo.py' | head -1` AT THE OPERATOR as the value to
    hand `mnexec -a`, which runs tc as uid 0 inside whatever namespace that pid is in. A wrong
    pid there is not a wrong answer, it is root in a stranger's namespace.
  * lib_e.sh's foreign-iperf3 guard built its process list with `ps -eo pid=,comm= | awk
    '$2=="iperf3"{...}'`, whose OWN argv carries the string it searches for -- so the sibling
    session's `pkill -f iperf3` killed the guard, and a guard that cannot look returned "no
    foreign load".

    python3 tests/shell/check_process_by_name.py            # every script in scope
    python3 tests/shell/check_process_by_name.py FILE...    # just these files
    python3 tests/shell/check_process_by_name.py --repo DIR # another checkout / a synthetic tree

=================================================================================================
THE RULE, and why it is not `grep -n 'pgrep -f'`
=================================================================================================
tests/shell/test_faults_topo_pid.sh:114-117 used to be

    grep -n 'pgrep -f' "$FAULTS" | grep -vc '^[0-9]*:[[:space:]]*#'
    grep -E '^[[:space:]]*(err|say|echo|printf)' "$FAULTS" | grep -c 'pgrep'

and hunt-0911/F-B0-B12-REPORT.md §3.1 rows (3)b..(3)e put four inputs through those two pipelines
and got 0 out of every one: `pgrep --full`, `pgrep  -f` with two spaces, `pkill -f`, and the same
advice string printed by `warn` instead of `err`. One space and one letter -- and the file scanned
was `$FAULTS`, one path, hard-coded, while `tools/test_workflow/run_layers.sh` has been looking a
process up by name the whole time.

So the rule is about the PROPERTY: a name-based process lookup or signal, whatever flags it
carries and whoever prints it. A site is either

  RUNS     -- the script executes it. `pgrep`, `pkill`, `killall`, `pidof`, or a `ps` whose
              output is piped into grep/awk/sed, in a position where the shell would run it.
  TEACHES  -- the script puts it in a DOUBLE-quoted string, i.e. interpolates it into something a
              human is going to read and copy. This is the G-9 half: the advice spreads further
              than the code does.

=================================================================================================
AND PYTHON, because the two live violations in this tree are python (2026-09-11, FIX-PROXY-1)
=================================================================================================
`p4_proxy/mininet/ntg_bmv2_topo.py` and `p4_proxy/mininet/p4_testbed_topo.py` each ran

    os.system('sudo pkill -f simple_switch_grpc > /dev/null 2>&1')

at startup -- the frontal violation of CLAUDE.md's red line, in the one language this checker
could not read. It was recorded as a KNOWN LIMIT here the day this file was written, which is
exactly how a limit becomes a hole: the shell half went green every night while the thing the
rule exists to prevent ran as root on every topology bring-up.

A shell parser cannot be pointed at python, and not because of syntax. The two languages put the
hazard in OPPOSITE constructs:

  * in shell, a single-quoted string is DATA -- a mutation gate's literal anchor;
  * in python, a single-quoted string is the only place the hazard can BE, because spawning a
    process means handing its name to os.system / subprocess / Node.cmd as a string.

So python is read with `ast`, and the two kinds are decided by WHERE the literal sits:

  RUNS     -- the string literal is an argument to a call that spawns a process (os.system,
              os.popen, os.exec*/spawn*, anything on `subprocess`, Popen/check_output/..., and
              Mininet's `.cmd`/`.sendCmd`, which is how every topology in this tree runs things).
              Reached through list/tuple literals, f-strings and `+` concatenation, so
              `subprocess.run(["pkill", "-f", name])` -- which contains no shell at all and no
              space before `-f` -- is the same site as the os.system one-liner.
  TEACHES  -- any other string literal. Same meaning and the same known limit as the shell half.

DATA in python is a comment (ast never sees one) and a string that stands alone as a STATEMENT:
module, class and function docstrings, and the triple-quoted blocks this tree uses as block
comments. That is the whole carve-out, and it is a property -- "this string is prose, not an
argument and not a message" -- rather than a list of files.

=================================================================================================
WHAT IS DATA, NOT CODE -- and why this file needs a registry
=================================================================================================
This tree teaches the rule by quoting the thing it forbids, so a scanner that reported every
occurrence would report its own instrument first. Three constructs are therefore read as data:

  * a comment;
  * a SINGLE-quoted string -- mutation gates carry the defective line as a literal anchor
    (`mutate_iperf3_guard.sh:104` is `pids=$(pgrep -f iperf3 ...)` inside one);
  * a heredoc body -- `write_case ... <<'PAIR'` in mutate_g9_faults_topo_pid.sh carries the exact
    pre-fix advice string as the mutation to apply.

That is not enough on its own: the suites whose whole subject IS this rule name it in their own
check labels and section headers, which are double-quoted and would read as TEACHES. Those files
are listed in ABOUT_THE_RULE, by name, with the reason -- an instrument must not be able to
report itself (memory: "儀器不能長得像自己的發現").

And the widened scan finds sites in code that is NOT about the rule. They are in REGISTERED
below rather than fixed: this checker was written under a ticket that forbids touching product
code, and a scan that silently dropped them would be the third way this rule gets lost. The
verdict compares the set FOUND against the set REGISTERED in both directions, so a new site is
red and a registered site that has been fixed is also red -- the registry cannot rot into an
excuse.

KNOWN LIMITS (documented rather than papered over -- a lint, not a proof)
 * Shell and python, by file extension, within the globs below. `tools/test_workflow/ndt` has
   no extension and looks simple_switch_grpc up with `ps -eo args= | grep -o` twice; it is
   REGISTERED rather than scanned, because reading it means deciding what language an
   extensionless file is, and guessing that is its own defect.
 * Neither half follows a variable. `cmd = "pkill -f x"` then `os.system(cmd)` is seen as
   TEACHES, not RUNS -- reported either way, which is the property that matters, but the kind
   is wrong. Same for `" ".join(argv)` where argv was built elsewhere.
 * A double-quoted (python: any non-statement) string that is data rather than advice reads as
   TEACHES. There is no static way to tell "printed to a human" from "assigned to a variable
   that is never printed", and guessing from the command word is what let `warn` through in the
   first place.
 * A file this scanner cannot read -- an unterminated shell quote, a python SyntaxError -- is
   reported as NOT CHECKED and the run exits 2, never as a clean file. check_gate_anchors.py
   learned that one (KNOWN-ISSUES L-3).
"""
import ast
import os
import re
import sys

# The tools. Flags and spacing are deliberately absent: `-f`, `--full`, `-x`, `-ax` and two
# spaces are four spellings of one hazard, and the old check guarded exactly one of them.
BY_NAME = re.compile(r"\b(pgrep|pkill|killall5|killall|pidof)\b")

# `ps` read for a NAME rather than for a pid: the G-inst-2 shape, where the searcher's own argv
# is a match for the search. `ps -o ... -p "$pid"` is not this, and is not reported.
PS_BY_NAME = re.compile(r"\bps\b(?=[^|]*\|[^|]*\b(?:grep|awk|sed)\b)")

NOT_CHECKED = "NOT CHECKED: "

# 🔴 The scan surface, derived rather than hard-coded -- the old check read one path.
SUITE_GLOBS = ("tools/test_workflow/*.sh", "tests/shell/*.sh")

# 🔴 The python surface. Live code and the suites that test it -- the same line the shell half
# draws. `doc/audit/**` is a dated record of what was measured on a day, and rewriting one to
# please a lint would be falsifying evidence; the one exception is the chaos harness, which
# lives under doc/audit for historical reasons but is LIVE TOOLING -- tests/python/test_chaos_*
# and tests/shell/mutate_chaos_* are its suites and its mutation gates, and this tree runs them.
# `p4_proxy/reference/` is vendored third-party source, not ours to hold to our rules.
PY_GLOBS = (
    "p4_proxy/mininet/*.py",
    "p4_proxy/proxy_agent/*.py",
    "p4_proxy/tests/*.py",
    "tools/*.py",
    "tools/contract_test/*.py",
    "tools/ryu_apps/*.py",
    "tools/test_workflow/*.py",
    "tools/twin_audit/*.py",
    "tests/python/*.py",
    "tests/shell/*.py",
    "doc/audit/2026-08-28_chaos-harness/harness/*.py",
)

# 🔴 The files whose SUBJECT is this rule, and which therefore quote it in their own labels,
# section headers and fixtures. An instrument that reported these would be reporting itself.
ABOUT_THE_RULE = frozenset((
    "tests/shell/test_faults_topo_pid.sh",       # the suite this checker was extracted from
    "tests/shell/mutate_g9_faults_topo_pid.sh",  # its mutation gate: the pre-fix advice string
    "tests/shell/test_iperf3_guard.sh",          # G-inst-2's suite: PATH shims named pgrep/pkill
    "tests/shell/mutate_iperf3_guard.sh",        # and its gate, whose M6 IS `pgrep -f iperf3`
    "tests/shell/check_process_by_name.py",      # this file: BY_NAME below IS the list of names
    "tests/shell/mutate_check_process_by_name.sh",  # its gate, whose mutants are this file
))

# 🔴 Every site the widened scan finds in code that is not about the rule, as
# (path, kind, tool). Line numbers are printed but deliberately NOT part of the verdict: other
# sessions edit these files all night and a line-pinned registry would go red for the wrong
# reason. Each entry is a decision someone has to make, not an exemption.
#
# 🔴 IT IS EMPTY, and that is a result rather than a default. The three entries this set was
# created with were FIXED on 2026-09-11 (FIX-NDT-4 #16, Adam's ruling), and the verdict below
# compares found against registered in BOTH directions, so the empty set is now itself an
# assertion: the next site to appear anywhere in the scan surface is red on the day it appears.
# What the three were, and what replaced them, because the registry is where the next reader
# looks first:
#
#   run_layers.sh   `pids="$(pgrep -x ndtwin_kernel 2>/dev/null)"` -- recon-B item 13. `-x`
#                   matches comm rather than the whole command line, the narrow end of the
#                   family, and it was still "find the process by its name". Now
#                   kernel_pidfile_pids: <name>.pid and <name>.child.pid from $PID_DIR. The
#                   third state moved with it -- no pidfile is "cannot tell", not "stale",
#                   because a kernel started by hand (which the manual teaches) records none.
#   stack.sh (RUNS) `ps -eo args | awk '$NF ~ /^mininet:/{c++}'` -- counted mininet host shells
#                   by the shape of their argv, with the pattern travelling in the awk's own
#                   argv, which is G-inst-2. Now mininet_procs_in, the same last-field reading
#                   done in the shell; there is no pidfile for Mininet, which is started by
#                   hand, so the process table is the only channel and what went away is the
#                   instrument's own footprint in it.
#   stack.sh (TEACHES) `err "    pgrep -ax ndtwin_kernel"` -- printed at the operator as the way
#                   to look, which is G-9's half of the same defect in a different file. Now
#                   `cat $PID_DIR/*.pid`, beside the `ss -ltnp` line that names the port holder.
#                   (FIX-NDT-4, 2026-09-11: run_layers.sh:398, stack.sh:55, stack.sh:1075 are FIXED
#                   and therefore NOT in the list below.)
#
# 🔴 2026-09-11, FIX-PROXY-1. Widening the surface to python found five more, and the first two
# are the frontal violation CLAUDE.md names -- `os.system('sudo pkill -f simple_switch_grpc')`,
# as root, on every topology bring-up, in the two files that own the bmv2 fabric:
#
#   p4_proxy/mininet/{p4_testbed_topo,ntg_bmv2_topo}.py -- FIXED, and therefore NOT in the list
#                   below. They were registered for exactly one commit so that the widening and
#                   the fix stayed separable; the fix replaced both with
#                   clear_switches_from_a_previous_run, which reaps the manifest's pids and
#                   reports a port it cannot address instead of matching a name. The registry's
#                   other direction is what made removing them here mandatory rather than
#                   optional: `2 stale`, rc 1, until they came out.
#
#   probes.py (RUNS)      `run(["pgrep", "-cf", "simple_switch_g[r]pc"])` -- the chaos harness
#                   counts live bmv2 processes by name. It only ever READS, and the bracket trick
#                   keeps its own argv off its own list, but "how many switches are up" is the
#                   question the manifest (p4_testbed_topo.MANIFEST_PATH) answers by pid.
#   probes.py (TEACHES) / antioracle.py / test_probes.py -- the same names in messages and in a
#                   shim, i.e. the advice half, in live tooling that happens to live under
#                   doc/audit for historical reasons.
#   tests/python/test_chaos_opt_in_all_actions.py -- `if words[0] == "pgrep":` in FakeShell. It
#                   is a stub, not a call; it is here because a stub that answers `pgrep` is
#                   evidence that something real still asks, and taking it out of the registry
#                   should require someone to look at probes.py first.
#
# 🔴 2026-09-12, FIX-PROXY-2 A11 (Adam's ruling on FIX-PROXY-1 §7-2, option (i)): all five are
# FIXED and therefore NOT in the set below, which is empty again. The chaos harness asks the
# manifest (p4_testbed_topo.MANIFEST_PATH -> pid -> /proc/<pid>/cmdline) for both "how many
# switches are up" and "which binary are they running", so the count and the provenance probe
# no longer shell out at all; test_probes.py fakes the manifest instead of faking pgrep's
# output; the FakeShell in test_chaos_opt_in_all_actions.py no longer answers a command nothing
# runs; and AO-13 names the trap by what it does rather than by the literal, with the
# KNOWN-ISSUES id that carries the exact command. The harness did NOT move out of doc/audit --
# that was option (iii) and Adam did not pick it.
REGISTERED = frozenset()


def _regions(text):
    """[(line, code, printed)] -- one entry per line, with the data parts blanked out.

    `code` is what the shell would execute; `printed` is what a double-quoted string interpolates.
    Single quotes, heredoc bodies and comments end up in neither.

    🔴 Quoting RESTARTS inside `"$( ... )"`, so a command substitution nested in a double-quoted
    string is code and not advice -- `pids="$(pgrep -x ndtwin_kernel)"` is a lookup, not a
    sentence. check_test_tmpdirs.py learned the same thing three parser bugs ago.
    """
    lines = text.split("\n")
    out = []
    quote = None
    substitutions = []          # double-quote contexts suspended by a "$("
    pending = []                # heredoc terminators still to be consumed
    unreadable = None
    i = 0
    while i < len(lines):
        line = lines[i]
        code, printed = [], []
        j = 0
        while j < len(line):
            c = line[j]
            if quote == "'":
                if c == "'":
                    quote = None
                j += 1
                continue
            if quote == '"':
                if line[j:j + 2] == "$(":
                    substitutions.append(quote)
                    quote = None
                    code.append("$(")
                    j += 2
                    continue
                if c == '"':
                    quote = None
                    j += 1
                    continue
                if c == "\\" and j + 1 < len(line):
                    printed.append(line[j:j + 2])
                    j += 2
                    continue
                printed.append(c)
                j += 1
                continue
            if c == ")" and substitutions:
                quote = substitutions.pop()
                code.append(c)
                j += 1
                continue
            if c in "'\"":
                quote = c
                j += 1
                continue
            if c == "\\" and j + 1 < len(line):
                code.append(line[j:j + 2])
                j += 2
                continue
            if c == "#" and (j == 0 or line[j - 1] in " \t;&|("):
                break                                   # a comment: the rest of the line
            if line[j:j + 2] == "<<":
                k = j + 2
                if k < len(line) and line[k] == "-":
                    k += 1
                while k < len(line) and line[k] in " \t":
                    k += 1
                delim = line[k] if k < len(line) and line[k] in "'\"" else ""
                k += 1 if delim else 0
                term = ""
                while k < len(line) and (line[k].isalnum() or line[k] in "_-."):
                    term += line[k]
                    k += 1
                if term and line[j:j + 3] != "<<<":
                    pending.append(term)
                code.append("<<")
                j = k + (1 if delim and k < len(line) and line[k] == delim else 0)
                continue
            code.append(c)
            j += 1
        out.append((i + 1, "".join(code), "".join(printed)))
        while pending:
            term = pending.pop(0)
            start, i = i, i + 1
            while i < len(lines) and lines[i].strip() != term:
                out.append((i + 1, "", ""))
                i += 1
            if i >= len(lines):
                unreadable = ("a heredoc opened near line %d (<<%s) has no terminator; everything "
                              "from there was skipped" % (start + 1, term))
            else:
                out.append((i + 1, "", ""))
        i += 1
    if substitutions and unreadable is None:
        unreadable = ('a "$( command substitution never closed; everything after it was read as '
                      "the wrong kind of text")
    if quote and unreadable is None:
        unreadable = ("a %s-quoted string was never closed; everything after it was read as string "
                      "content" % quote)
    return out, unreadable


def sites(text, path):
    """[(path, line, kind, tool, context)] for one shell script."""
    regions, unreadable = _regions(text)
    if unreadable:
        return [(path, 1, NOT_CHECKED, "-", unreadable)]
    found = []
    for line, code, printed in regions:
        for kind, part in (("RUNS", code), ("TEACHES", printed)):
            hit = BY_NAME.search(part)
            tool = hit.group(1) if hit else None
            if tool is None and kind == "RUNS" and PS_BY_NAME.search(part):
                tool = "ps"
            if tool:
                found.append((path, line, kind, tool, " ".join(part.split())[:110]))
    return found


# =================================================================================================
# python
# =================================================================================================
# 🔴 The calls that hand a string to the operating system to run. Matched on the LAST name only
# (`os.system`, `subprocess.run`, `self.cmd`), because the module it came in through is a
# spelling: `from subprocess import run` and `import subprocess` are the same site.
#
# `cmd`/`sendCmd`/`cmdPrint` are Mininet's Node methods. They are how every topology in this tree
# runs anything inside a namespace, and leaving them out would mean the checker could read
# p4_testbed_topo.py and still not see what it does.
PY_SPAWNER_METHODS = frozenset((
    "system", "popen", "Popen", "run", "call", "check_call", "check_output",
    "getoutput", "getstatusoutput", "cmd", "sendCmd", "cmdPrint", "pexec",
    "execv", "execve", "execvp", "execvpe", "execl", "execle", "execlp", "execlpe",
    "spawnv", "spawnve", "spawnvp", "spawnl", "spawnle", "spawnlp",
))

# A bare name is read the same way, `run` and `call` included. The tempting caution -- "too many
# things are called run, leave it out" -- picks the QUIETER error, and this checker's whole
# subject is what quiet costs: `doc/audit/2026-08-28_chaos-harness/harness/probes.py:461` is
# `run(["pgrep", "-cf", ...])` through that module's own subprocess wrapper, and leaving `run`
# off this list filed a live pgrep call under TEACHES. Both kinds are reported either way, so an
# over-broad name makes the verdict louder, never emptier.
PY_SPAWNER_NAMES = PY_SPAWNER_METHODS - frozenset(("cmd", "sendCmd", "cmdPrint"))


def _spawns(func):
    """Whether this call node's callee runs a process."""
    if isinstance(func, ast.Attribute):
        return func.attr in PY_SPAWNER_METHODS
    if isinstance(func, ast.Name):
        return func.id in PY_SPAWNER_NAMES
    return False


def _string_pieces(node):
    """Every string literal reachable from an argument WITHOUT leaving literal syntax.

    A list, a tuple, an f-string and `a + b` are all still the argument the author wrote, so
    `subprocess.run(["pkill", "-f", name])` reaches the same place `os.system("pkill -f " + name)`
    does. A bare Name does not: this checker does not follow variables, and says so in KNOWN
    LIMITS rather than pretending the one-hop case is the whole of it.
    """
    if isinstance(node, ast.Constant):
        if isinstance(node.value, str):
            yield node
    elif isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        for element in node.elts:
            yield from _string_pieces(element)
    elif isinstance(node, ast.Starred):
        yield from _string_pieces(node.value)
    elif isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        yield from _string_pieces(node.left)
        yield from _string_pieces(node.right)
    elif isinstance(node, ast.JoinedStr):
        for part in node.values:
            yield from _string_pieces(part)


def _context(text, match):
    """The matched part of a literal, collapsed onto one line and trimmed around the hit."""
    flat = " ".join(text.split())
    needle = " ".join(match.group(0).split())
    at = flat.find(needle)
    start = max(0, at - 45) if at >= 0 else 0
    out = flat[start:start + 110]
    return ("..." + out) if start else out


def python_sites(text, path):
    """[(path, line, kind, tool, context)] for one python file.

    [Co-developed with claude code -- Adam]
    Same verdict shape as `sites`, different notion of what is data. See the module docstring:
    in python the hazard lives INSIDE a string literal, so "single-quoted means data" -- the
    shell half's central carve-out -- would make this blind to every real site.
    """
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError) as err:
        return [(path, 1, NOT_CHECKED, "-", "this file is not parseable python: %s" % err)]

    # Prose: a string that is a statement all by itself. Docstrings are the common case; this
    # tree also uses triple-quoted blocks mid-function as block comments, and those are prose by
    # the same argument -- nobody runs them and nobody is told to copy them.
    prose = {id(node.value) for node in ast.walk(tree)
             if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant)
             and isinstance(node.value.value, str)}

    executed = set()
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and _spawns(node.func)):
            continue
        for arg in list(node.args) + [kw.value for kw in node.keywords]:
            for literal in _string_pieces(arg):
                executed.add(id(literal))

    found = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Constant) and isinstance(node.value, str)):
            continue
        if id(node) in prose:
            continue
        kind = "RUNS" if id(node) in executed else "TEACHES"
        hit = BY_NAME.search(node.value)
        if hit is None and kind == "RUNS":
            hit = PS_BY_NAME.search(node.value)
            tool = "ps" if hit else None
        else:
            tool = hit.group(1) if hit else None
        if tool:
            found.append((path, node.lineno, kind, tool, _context(node.value, hit)))
    return sorted(found, key=lambda f: (f[1], f[2]))


# By extension, because that is what says which grammar a file is in. Anything else -- including
# `tools/test_workflow/ndt`, which has no extension -- is read as shell, the way this checker
# always did, and is out of the derived surface either way.
_ANALYSER_BY_EXTENSION = {".py": python_sites}


def scan_tree(repo):
    """Every script in scope, minus the files whose subject is this rule."""
    import glob
    found, scanned = [], 0
    for pattern in SUITE_GLOBS + PY_GLOBS:
        for path in sorted(glob.glob(os.path.join(repo, pattern))):
            rel = os.path.relpath(path, repo)
            if rel in ABOUT_THE_RULE:
                continue
            scanned += 1
            found += scan_file(path, rel=rel)
    return found, scanned


def scan_file(path, rel=None):
    analyse = _ANALYSER_BY_EXTENSION.get(os.path.splitext(path)[1], sites)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return analyse(fh.read(), rel if rel is not None else path)


def main(argv):
    args = list(argv[1:])
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    files = []
    while args:
        arg = args.pop(0)
        if arg == "--repo":
            if not args:
                print("check_process_by_name: --repo needs a directory", file=sys.stderr)
                return 2
            repo = args.pop(0)
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        elif arg.startswith("-"):
            print("check_process_by_name: unknown option %s" % arg, file=sys.stderr)
            return 2
        else:
            files.append(arg)

    if files:
        found, scanned = [], 0
        for path in files:
            if not os.path.exists(path):
                print("check_process_by_name: no such file: %s" % path, file=sys.stderr)
                return 2
            scanned += 1
            found += scan_file(path)
        registered = frozenset()          # a named file is being asked about, not audited
    else:
        found, scanned = scan_tree(repo)
        registered = REGISTERED

    for path, line, kind, tool, context in found:
        if kind == NOT_CHECKED:
            print("%s:%d: %s%s" % (path, line, NOT_CHECKED, context))
        else:
            print("%s:%d: %-7s %-8s %s" % (path, line, kind, tool, context))

    unreadable = [f for f in found if f[2] == NOT_CHECKED]
    if unreadable:
        print("check_process_by_name: %d file(s) COULD NOT BE READ and were not checked at all "
              "(exit 2)." % len(unreadable), file=sys.stderr)
        return 2

    here = {(f[0], f[2], f[3]) for f in found}
    new = sorted(here - registered)
    gone = sorted(registered - here)
    for path, kind, tool in new:
        print("🔴 NEW: %s %s %s -- finds or signals a process by name, and is not registered"
              % (path, kind, tool))
    for path, kind, tool in gone:
        print("🔴 REGISTERED BUT GONE: %s %s %s -- fixed? then take it out of REGISTERED, so the "
              "next one cannot hide behind it" % (path, kind, tool))
    if not files:
        print("check_process_by_name: %d file(s) scanned, %d site(s), %d registered, %d new, "
              "%d stale" % (scanned, len(found), len(registered), len(new), len(gone)))
    return 1 if (new or gone) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
