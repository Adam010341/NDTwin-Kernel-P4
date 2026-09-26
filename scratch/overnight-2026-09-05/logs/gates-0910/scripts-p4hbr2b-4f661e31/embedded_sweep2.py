#!/usr/bin/env python3
"""Every program embedded in a shell script -- found on LOGICAL lines -- and does it compile.

[Co-developed with claude code -- Adam] Round 2b of the 08 H5-sampler follow-up. The first sweep
(embedded_sweep.py) matched each PHYSICAL line on its own, so a program whose opener is spread over
a backslash continuation was missed: 08's consts (`"$PY" -c \\` / `'from proxy_agent ...'`) and
_common.sh's link_usage_window (`"$PY" - "$pkg" ... \\` / `... <<'PYW'`) -- the opus judge's N2-2.
Here a shell line ending in a backslash is joined with the next ("\\\\\\n" becomes two spaces, so
every offset in the joined text is the same as in the file), the patterns run on the joined text,
and a program's text and its insertion point are mapped back to physical lines. The bodies of the
programs found (heredocs, quoted texts) are skipped, never rescanned as shell.
An awk -v value may be a quoted command substitution with quotes inside it (`-v c="$(cat "$X/clock")"`):
the first sweep read the inner "$X/clock" as a double-quoted awk program and missed the real one
(S_heartbeat_spike.sh:1175); a -v value is now name=, then "$( ... )", '...', "..." or a word, and a
double-quoted text that starts with $ is not taken for an awk program.

Each program: kind, start (the physical line of its opener), end, text, literal (no bash expansion
in it), name, and where a coverage marker would go: `ins` = (line index, column) for an inline text,
`body` = the line index its first line sits on for a heredoc / variable.

Round 2b, second pass (found while re-counting): the interpreter list lacked the spike's
$PY_SELFTEST (five programs: 916, 924, 1078, 1081, 1096), and a program written to a file first
(`cat > "$d/x.py" <<'TAG'`: 1128, 1663) or a shell driver / fake command in a quoted heredoc
(`cat <<'DRIVER'`, FAKETC, FAKEQDISC, FAKENDT) was not looked for at all. Both are now found; the
shell texts are counted apart and checked with `bash -n`.

usage: embedded_sweep2.py [--strict] --py PYTHON [--py ...] FILE...   (compile report)
"""
import argparse
import os
import re
import subprocess
import sys

PY_CMD = r'(?:"?\$\{?(?:PY|VPY|PY_KERNEL|VENV_PY|PYTHON|PY_SELFTEST)\}?"?|python3?|/usr/bin/python3|"\$HB_TEST_PY"|\$HB_TEST_PY)'
HEREDOC = re.compile(PY_CMD + r"\b[^<]*?<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
PY_C_SQ = re.compile(PY_CMD + r"\b[^'\n]*?\s-c\s+'")
PY_C_DQ = re.compile(PY_CMD + r"\b\"?[^\"\n]*?\s-c\s+\"(?!\$)")
PY_C_VAR = re.compile(PY_CMD + r"\b[^\n]*?\s-c\s+\"\$(\{)?([A-Za-z_][A-Za-z0-9_]*)")
VAR_SQ = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*_PY)='\s*$")
VAR_CAT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*_PY)=\"\$\(cat <<'([A-Za-z_][A-Za-z0-9_]*)'\s*$")
AWK = re.compile(r"(?:^|[\s|;(`$])(?:/usr/bin/)?awk\b((?:\s+-[Fv]\s*(?:[A-Za-z_]\w*=)?(?:\"\$\([^)]*\)\"|'[^']*'|\"[^\"]*\"|\S+))*|(?:\s+-\S+)*)\s+'")
AWK_DQ = re.compile(r"(?:^|[\s|;(`$])(?:/usr/bin/)?awk\b((?:\s+-[Fv]\s*(?:[A-Za-z_]\w*=)?(?:\"\$\([^)]*\)\"|'[^']*'|\"[^\"]*\"|\S+))*)\s+\"(?!\$)")
# a program written to a file and run from there: `cat > "$d/x.py" <<'TAG'` (Python) and
# `cat <<'TAG'` / `cat > "$d/x" <<'TAG'` (a shell driver or a fake command -- checked with bash -n)
PY_FILE = re.compile(r"\bcat\s*>\s*\"?[^\"\s<]+\.py\"?\s*<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
SH_HEREDOC = re.compile(r"\bcat\s*(?:>\s*\"?[^\"\s<]+\"?\s*)?<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
JQP = re.compile(r"\bjqp\s+\"[^\"]*\"\s+\"((?:[^\"\\]|\\.)*)\"")


def single_quoted_from(lines, li, col):
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


def logical(lines, li):
    """(joined text, [(physical line index, offset of that line in the joined text)], last index).
    A line ending in an unquoted backslash continues on the next; comment lines never do."""
    parts, marks, i, off = [], [], li, 0
    while i < len(lines):
        line = lines[i]
        marks.append((i, off))
        cont = line.endswith("\\") and not line.lstrip().startswith("#")
        parts.append(line[:-1] + " " if cont else line)
        off += len(line) + 1
        if not cont:
            break
        parts.append(" ")
        i += 1
    return "".join(parts), marks, i


def at(marks, pos):
    """The physical (line index, column) of offset pos in a joined logical line."""
    li, base = marks[0]
    for m_li, m_off in marks:
        if m_off <= pos:
            li, base = m_li, m_off
    return li, pos - base


def find_programs(path):
    lines = open(path).read().split("\n")
    progs, li = [], 0
    while li < len(lines):
        if lines[li].lstrip().startswith("#"):
            li += 1
            continue
        text_l, marks, last = logical(lines, li)
        nxt = last + 1
        m = VAR_CAT.match(text_l)
        if m:
            text, end = heredoc_body(lines, last, m.group(2))
            progs.append(dict(kind="py-var", start=li + 1, end=end + 1, text=text, literal=True,
                              name=m.group(1), body=last + 1))
            li = max(nxt, end + 1)
            continue
        m = VAR_SQ.match(text_l)
        if m:
            text, end = single_quoted_from(lines, li, lines[li].index("'") + 1)
            progs.append(dict(kind="py-var", start=li + 1, end=end + 1, text=text, literal=True,
                              name=m.group(1), body=li + 1))
            li = max(nxt, end + 1)
            continue
        found_end = last
        m = PY_FILE.search(text_l)
        if m:
            text, end = heredoc_body(lines, last, m.group(2))
            progs.append(dict(kind="py-file", start=li + 1, end=end + 1, text=text,
                              literal=bool(m.group(1)), name=m.group(2), body=last + 1))
            li = max(nxt, end + 1)
            continue
        m = SH_HEREDOC.search(text_l)
        if m and not HEREDOC.search(text_l):
            text, end = heredoc_body(lines, last, m.group(2))
            progs.append(dict(kind="sh-heredoc", start=li + 1, end=end + 1, text=text,
                              literal=bool(m.group(1)), name=m.group(2), body=last + 1))
            li = nxt   # its body IS shell: the programs inside it (FAKETC's awk, 1175) are looked for too
            continue
        m = HEREDOC.search(text_l)
        if m:
            text, end = heredoc_body(lines, last, m.group(2))
            progs.append(dict(kind="py-heredoc", start=li + 1, end=end + 1, text=text,
                              literal=bool(m.group(1)), name=m.group(2), body=last + 1))
            li = max(nxt, end + 1)
            continue
        m = PY_C_SQ.search(text_l)
        if m:
            pli, col = at(marks, m.end())
            text, end = single_quoted_from(lines, pli, col)
            progs.append(dict(kind="py-c", start=li + 1, end=end + 1, text=text, literal=True, name="",
                              ins=(pli, col)))
            found_end = max(found_end, end)
        elif PY_C_VAR.search(text_l):
            m = PY_C_VAR.search(text_l)
            progs.append(dict(kind="py-c-var", start=li + 1, end=last + 1, text=None, literal=False,
                              name=m.group(2)))
        else:
            m = PY_C_DQ.search(text_l)
            if m:
                pli, col = at(marks, m.end())
                text, end = double_quoted_from(lines, pli, col)
                lit = text is not None and "$" not in text and "`" not in text
                progs.append(dict(kind="py-c-dq", start=li + 1, end=end + 1,
                                  text=(text.replace('\\"', '"') if lit else text), literal=lit, name="",
                                  ins=(pli, col)))
                found_end = max(found_end, end)
        for m in AWK.finditer(text_l):
            pli, col = at(marks, m.end())
            text, end = single_quoted_from(lines, pli, col)
            progs.append(dict(kind="awk", start=pli + 1, end=end + 1, text=text, literal=True, name="",
                              ins=(pli, col)))
            found_end = max(found_end, end)
        for m in AWK_DQ.finditer(text_l):
            pli, col = at(marks, m.end())
            text, end = double_quoted_from(lines, pli, col)
            progs.append(dict(kind="awk-dq", start=pli + 1, end=end + 1, text=text, literal=False, name="",
                              ins=(pli, col)))
        for m in JQP.finditer(text_l):
            pli, col = at(marks, m.start(1))
            expr = m.group(1)
            progs.append(dict(kind="py-jqp", start=pli + 1, end=pli + 1, text=expr, literal="$" not in expr,
                              name="", ins=(pli, col), span=len(expr)))
        li = max(nxt, found_end + 1)
    return progs


def compile_py(text, pys, mode="exec"):
    bad = []
    for py in pys:
        r = subprocess.run([py, "-I", "-c", "import sys; compile(sys.stdin.read(), '<embedded>', sys.argv[1])", mode],
                           input=text, capture_output=True, text=True)
        if r.returncode != 0:
            err = r.stderr.strip().splitlines()
            bad.append(f"{os.path.basename(py)}: {err[-1] if err else 'rc %d' % r.returncode}")
    return bad


def compile_sh(text):
    r = subprocess.run(["bash", "-n"], input=text, capture_output=True, text=True)
    err = r.stderr.strip().splitlines()
    return [] if r.returncode == 0 else [err[-1] if err else "rc %d" % r.returncode]


def compile_awk(text):
    r = subprocess.run(["mawk", "-W", "dump", text], stdin=subprocess.DEVNULL, capture_output=True, text=True)
    err = r.stderr.strip().splitlines()
    return [] if r.returncode == 0 else [err[-1] if err else "rc %d" % r.returncode]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--py", action="append", default=[])
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    total = {}
    for f in a.files:
        progs = find_programs(f)
        nbad = ndyn = 0
        print(f"== {f}: {len(progs)} embedded program(s)")
        for p in progs:
            if not p["literal"] or p["text"] is None:
                comp = "dynamic"
                ndyn += 1
            elif p["kind"] == "awk":
                comp = "; ".join(compile_awk(p["text"])) or "ok"
            elif p["kind"] == "py-jqp":
                comp = "; ".join(compile_py(p["text"], a.py[:1], "eval")) or "ok"
            elif p["kind"] == "sh-heredoc":
                comp = "; ".join(compile_sh(p["text"])) or "ok"
            else:
                comp = "; ".join(compile_py(p["text"], a.py)) or "ok"
            nbad += comp not in ("ok", "dynamic")
            first = (p["text"] or "").strip().splitlines()[0][:60] if p["text"] else p["name"]
            print(f"  {p['start']:5d}-{p['end']:<5d} {p['kind']:10s} compile={comp:.70s} | {first}")
        total[f] = (len(progs), ndyn, nbad, sum(p["kind"] == "sh-heredoc" for p in progs))
    print("SUMMARY")
    for f, (n, d, b, nsh) in total.items():
        print(f"  {os.path.basename(f)}: {n} programs ({n - d} literal, {d} with bash expansion; "
              f"{n - nsh} Python/awk, {nsh} shell), {b} do not compile")
    n_all = sum(t[0] for t in total.values())
    b_all = sum(t[2] for t in total.values())
    sh_all = sum(t[3] for t in total.values())
    print(f"EMBEDDED-COMPILE: {n_all} programs ({n_all - sh_all} Python/awk, {sh_all} shell), {b_all} do not compile")
    if a.strict and b_all:
        sys.exit(1)


if __name__ == "__main__":
    main()
