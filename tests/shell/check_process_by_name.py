#!/usr/bin/env python3
"""No shell script in this tree may find or signal a process BY NAME, or teach anyone to.

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

    python3 tests/shell/check_process_by_name.py            # every shell script in scope
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
 * Shell only, and only files git tracks. `p4_proxy/mininet/ntg_bmv2_topo.py:98` and
   `p4_proxy/mininet/p4_testbed_topo.py:658` both run `os.system('sudo pkill -f
   simple_switch_grpc ...')` and are NOT in scope here; so is `tools/test_workflow/ndt`, which
   has no .sh extension and looks up simple_switch_grpc with `ps -eo args= | grep -o` twice.
   Those are recorded in the ticket's SUMMARY for a decision, not silently covered.
 * A double-quoted string that is data rather than advice reads as TEACHES. There is no static
   way to tell "printed to a human" from "assigned to a variable that is never printed", and
   guessing from the command word is what let `warn` through in the first place.
 * A file this scanner cannot read is reported as NOT CHECKED and the run exits 2, never as a
   clean file. check_gate_anchors.py learned that one (KNOWN-ISSUES L-3).
"""
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

# 🔴 The files whose SUBJECT is this rule, and which therefore quote it in their own labels,
# section headers and fixtures. An instrument that reported these would be reporting itself.
ABOUT_THE_RULE = frozenset((
    "tests/shell/test_faults_topo_pid.sh",       # the suite this checker was extracted from
    "tests/shell/mutate_g9_faults_topo_pid.sh",  # its mutation gate: the pre-fix advice string
    "tests/shell/test_iperf3_guard.sh",          # G-inst-2's suite: PATH shims named pgrep/pkill
    "tests/shell/mutate_iperf3_guard.sh",        # and its gate, whose M6 IS `pgrep -f iperf3`
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


def scan_tree(repo):
    """Every shell script in scope, minus the files whose subject is this rule."""
    import glob
    found, scanned = [], 0
    for pattern in SUITE_GLOBS:
        for path in sorted(glob.glob(os.path.join(repo, pattern))):
            rel = os.path.relpath(path, repo)
            if rel in ABOUT_THE_RULE:
                continue
            scanned += 1
            found += scan_file(path, rel=rel)
    return found, scanned


def scan_file(path, rel=None):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return sites(fh.read(), rel if rel is not None else path)


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
