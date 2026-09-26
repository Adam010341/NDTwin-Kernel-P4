#!/usr/bin/env python3
"""Every program embedded in a shell script, and whether anything ran it.

[Co-developed with claude code -- Adam] Segment W follow-up (the live H5 sampler that never
compiled). For each script given: find every embedded program -- Python heredocs fed to an
interpreter, Python `-c '...'` texts, single-quoted Python held in a variable, Python held in a
`$(cat <<'X' ...)` variable, awk programs, and the expressions handed to `jqp` -- then
  * COMPILE each one whose text is literal (single-quoted or a quoted heredoc): Python with the
    interpreters named on the command line, awk with `mawk -W dump` (parses, runs nothing);
  * mark it EXECUTED when the xtrace of the self-tests (given as trace files, lines of the form
    `+<file>:<line>: ...`) shows a command on any line from the program's opener to its end.
Prints one row per program and a per-file summary. Exit 0 always: this is a report.

usage: embedded_sweep.py --trace T1 [--trace T2 ...] --py /usr/bin/python3 [--py ...] FILE...
"""
import argparse
import os
import re
import subprocess
import sys

PY_CMD = r'(?:"?\$\{?(?:PY|VPY|PY_KERNEL|VENV_PY|PYTHON)\}?"?|python3?|/usr/bin/python3|"\$HB_TEST_PY"|\$HB_TEST_PY)'
HEREDOC = re.compile(PY_CMD + r"\b[^<\n]*<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
PY_C_SQ = re.compile(PY_CMD + r"\b[^'\n]*?\s-c\s+'")
PY_C_VAR = re.compile(PY_CMD + r"\b[^\n]*?\s-c\s+\"\$(\{)?([A-Za-z_][A-Za-z0-9_]*)")
VAR_SQ = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*_PY)='\s*$")
VAR_CAT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*_PY)=\"\$\(cat <<'([A-Za-z_][A-Za-z0-9_]*)'\s*$")
AWK = re.compile(r"(?:^|[\s|;(`$])(?:/usr/bin/)?awk\b((?:\s+-[Fv]\s*(?:'[^']*'|\"[^\"]*\"|\S+))*|(?:\s+-\S+)*)\s+'")
PY_C_DQ = re.compile(PY_CMD + r"\b\"?[^\"\n]*?\s-c\s+\"(?!\$)")
AWK_DQ = re.compile(r"(?:^|[\s|;(`$])(?:/usr/bin/)?awk\b((?:\s+-[Fv]\s*(?:'[^']*'|\"[^\"]*\"|\S+))*)\s+\"")
JQP = re.compile(r"\bjqp\s+\"[^\"]*\"\s+\"((?:[^\"\\]|\\.)*)\"")


def single_quoted_from(lines, li, col):
    """Text from lines[li][col] (just after an opening ') to the next ', and the closing line."""
    buf, i, c = [], li, col
    while i < len(lines):
        j = lines[i].find("'", c)
        if j >= 0:
            buf.append(lines[i][c:j])
            return "\n".join(buf), i
        buf.append(lines[i][c:])
        i, c = i + 1, 0
    return None, li


def double_quoted_from(lines, li, col):
    """Text from lines[li][col] (just after an opening \") to the next unescaped \" -- bash's view:
    backslash-escapes inside are kept as written."""
    buf, i, c = [], li, col
    while i < len(lines):
        line, j = lines[i], c
        while j < len(line):
            if line[j] == "\\":
                j += 2
                continue
            if line[j] == '"':
                buf.append(line[c:j])
                return "\n".join(buf), i
            j += 1
        buf.append(line[c:])
        i, c = i + 1, 0
    return None, li


def heredoc_body(lines, li, tag):
    buf, i = [], li + 1
    while i < len(lines):
        if lines[i].strip() == tag:
            return "\n".join(buf), i
        buf.append(lines[i])
        i += 1
    return None, li


def find_programs(path):
    lines = open(path).read().split("\n")
    progs = []
    for li, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        m = HEREDOC.search(line)
        if m:
            text, end = heredoc_body(lines, li, m.group(2))
            progs.append(dict(kind="py-heredoc", start=li + 1, end=end + 1, text=text,
                              literal=bool(m.group(1)), name=m.group(2)))
            continue
        m = VAR_CAT.match(line)
        if m:
            text, end = heredoc_body(lines, li, m.group(2))
            progs.append(dict(kind="py-var", start=li + 1, end=end + 1, text=text, literal=True, name=m.group(1)))
            continue
        m = VAR_SQ.match(line)
        if m:
            text, end = single_quoted_from(lines, li, line.index("'") + 1)
            progs.append(dict(kind="py-var", start=li + 1, end=end + 1, text=text, literal=True, name=m.group(1)))
            continue
        m = PY_C_SQ.search(line)
        if m:
            text, end = single_quoted_from(lines, li, m.end())
            progs.append(dict(kind="py-c", start=li + 1, end=end + 1, text=text, literal=True, name=""))
            continue
        m = PY_C_VAR.search(line)
        if m:
            progs.append(dict(kind="py-c-var", start=li + 1, end=li + 1, text=None, literal=False, name=m.group(2)))
        m = PY_C_DQ.search(line)
        if m and not PY_C_VAR.search(line):
            text, end = double_quoted_from(lines, li, m.end())
            lit = text is not None and "$" not in text and "`" not in text
            progs.append(dict(kind="py-c-dq", start=li + 1, end=end + 1,
                              text=(text.replace('\\"', '"') if lit else text), literal=lit, name=""))
            continue
        for m in AWK_DQ.finditer(line):
            text, end = double_quoted_from(lines, li, m.end())
            progs.append(dict(kind="awk-dq", start=li + 1, end=end + 1, text=text, literal=False, name=""))
        for m in AWK.finditer(line):
            text, end = single_quoted_from(lines, li, m.end())
            progs.append(dict(kind="awk", start=li + 1, end=end + 1, text=text, literal=True, name=""))
        for m in JQP.finditer(line):
            expr = m.group(1)
            progs.append(dict(kind="py-jqp", start=li + 1, end=li + 1, text=expr,
                              literal="$" not in expr, name=""))
    return progs


def compile_py(text, pys, mode="exec"):
    bad = []
    for py in pys:
        r = subprocess.run([py, "-I", "-c", "import sys; compile(sys.stdin.read(), '<embedded>', sys.argv[1])", mode],
                           input=text, capture_output=True, text=True)
        if r.returncode != 0:
            bad.append(f"{os.path.basename(py)}: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'rc ' + str(r.returncode)}")
    return bad


def compile_awk(text):
    r = subprocess.run(["mawk", "-W", "dump", text], stdin=subprocess.DEVNULL, capture_output=True, text=True)
    return [] if r.returncode == 0 else [r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "rc %d" % r.returncode]


def executed_lines(traces, root):
    seen = {}
    pat = re.compile(r"^\++([^:\s]+):(\d+):")
    for t in traces:
        with open(t, errors="replace") as fh:
            for line in fh:
                m = pat.match(line)
                if m:
                    f = m.group(1)
                    f = f if os.path.isabs(f) else os.path.join(root, f)
                    seen.setdefault(os.path.realpath(f), set()).add(int(m.group(2)))
    return seen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", action="append", default=[])
    ap.add_argument("--py", action="append", default=[])
    ap.add_argument("--strict", action="store_true", help="exit 1 when any literal program does not compile")
    ap.add_argument("--root", default=os.getcwd(), help="what a relative path in a trace is relative to")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    seen = executed_lines(a.trace, a.root)
    total = {}
    for f in a.files:
        rf = os.path.realpath(f)
        lines_run = seen.get(rf, set())
        progs = find_programs(f)
        n_exec = n_bad = 0
        print(f"== {f}: {len(progs)} embedded program(s)")
        for p in progs:
            if not p["literal"] or p["text"] is None:
                comp = "dynamic"
            elif p["kind"] == "awk":
                comp = "; ".join(compile_awk(p["text"])) or "ok"
            elif p["kind"] == "py-jqp":
                comp = "; ".join(compile_py(p["text"], a.py[:1], "eval")) or "ok"
            else:
                comp = "; ".join(compile_py(p["text"], a.py)) or "ok"
            lo = p["start"] - 3 if p["kind"] != "py-var" else p["start"]
            ran = any(l in lines_run for l in range(lo, p["end"] + 2))
            n_exec += ran
            n_bad += comp not in ("ok", "dynamic")
            first = (p["text"] or "").strip().splitlines()[0][:60] if p["text"] else p["name"]
            print(f"  {p['start']:5d}-{p['end']:<5d} {p['kind']:10s} {'RAN ' if ran else 'NOT '} compile={comp:8.60s} | {first}")
        print(f"   -> {n_exec}/{len(progs)} executed by the traced self-tests; {n_bad} do not compile")
        total[f] = (len(progs), n_exec, n_bad)
    print("SUMMARY")
    for f, (n, e, b) in total.items():
        print(f"  {os.path.basename(f)}: {n} programs, {b} do not compile" + (f", {e} executed" if a.trace else ""))
    nbad = sum(b for _n, _e, b in total.values())
    print(f"EMBEDDED-COMPILE: {sum(n for n, _e, _b in total.values())} programs, {nbad} do not compile")
    if a.strict and nbad:
        sys.exit(1)


if __name__ == "__main__":
    main()
