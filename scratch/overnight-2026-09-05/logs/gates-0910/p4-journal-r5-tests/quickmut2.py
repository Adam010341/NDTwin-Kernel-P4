"""Quick check (NOT the gate): apply mutants to a copy of <repo>'s p4_proxy and run the test modules once per mutant.

Based on p4-ternary-replay-c/r5/quickmut.py. Two changes: (1) for each FAIL/ERROR it prints the failing assertion -- the
deepest frame in a tests/ file (file:line and its source line) and the exception's first line -- so a RED line says
WHICH assertion went red; (2) besides the gate's own mutants (by label), it takes ad-hoc variants from a JSON file
[{"name", "file", "old", "new", "test"}], for a mutation that is not (yet) in the gate.

usage: quickmut2.py <repo> <python> [--modules m1,m2,...] [--build <p4_src/build dir>] [--adhoc <json>] [names...]
       a name "base" runs the unmutated copy.
[Co-developed with claude code -- Adam]
"""
import json, os, re, shlex, shutil, subprocess, sys, tempfile

args = sys.argv[1:]
repo, py = args[0], args[1]
rest = args[2:]
modules = ["tests.test_table_entry_replay", "tests.test_table_entry_journal"]
build = os.path.join(repo, "p4_proxy", "p4_src", "build")
adhoc = []
names = []
i = 0
while i < len(rest):
    a = rest[i]
    if a == "--modules":
        modules = rest[i + 1].split(","); i += 2
    elif a == "--build":
        build = rest[i + 1]; i += 2
    elif a == "--adhoc":
        adhoc = json.load(open(rest[i + 1])); i += 2
    else:
        names.append(a); i += 1

files = {"JOURNAL": "proxy_agent/rule_journal.py", "MAIN": "proxy_agent/main.py", "ROUTES": "proxy_agent/api_routes.py"}
text = open(os.path.join(repo, "tests/shell/mutate_table_journal.sh")).read()
pat = re.compile(r'm=\$\(mutant2? (\w+) "\$(\w+)" \\\n(.*?)\)\nreport \'((?:[^\']|\'\\\'\')*)\' "\$m" \\\n\s+\'(\w+)\'', re.S)
jobs = []
if "base" in names:
    jobs.append(("base", None, [], "the unmutated copy", None))
for m in pat.finditer(text):
    name, fvar, body, label, test = m.groups()
    if name not in names:
        continue
    parts = shlex.split(body.replace("\\\n", " "))
    assert len(parts) in (2, 4), (name, len(parts))
    jobs.append((name, files[fvar], list(zip(parts[0::2], parts[1::2])), label.replace("'\\''", "'"), test))
for a in adhoc:
    jobs.append((a["name"], a["file"], [(a["old"], a["new"])], a.get("label", "ad hoc"), a.get("test")))
missing = set(names) - {j[0] for j in jobs}
assert not missing, "no such mutant: %s" % sorted(missing)

FRAME = re.compile(r'^  File "(?:[^"]*/)?(tests/[^"]+\.py)", line (\d+), in (\w+)')
EXC = re.compile(r'^[A-Za-z_][A-Za-z0-9_.]*(?:Error|Exception|Failure|Exit|Interrupt)(?::|$)')


def assertions(out):
    """{test name: "tests/x.py:N <source> -> <exception line>"} for every FAIL/ERROR block of a unittest -v output."""
    found, cur, where, src, exc, tb = {}, None, None, None, None, False
    lines = out.splitlines()
    for n, line in enumerate(lines):
        m = re.match(r'^(FAIL|ERROR): (\w+) ', line)
        if m:
            if cur:
                found[cur] = (where, src, exc)
            cur, where, src, exc, tb = m.group(2), None, None, None, False
            continue
        if cur is None:
            continue
        if line.startswith("Traceback"):
            tb = True
            continue
        if tb and re.fullmatch(r'(=+|-+)', line):
            found[cur] = (where, src, exc); cur = None
            continue
        f = FRAME.match(line)
        if f:
            where = "%s:%s" % (f.group(1), f.group(2))
            src = lines[n + 1].strip() if n + 1 < len(lines) else ""
            continue
        if tb and EXC.match(line):
            exc = line
    if cur:
        found[cur] = (where, src, exc)
    return {k: "%s %s -> %s" % (w or "?", (s or "")[:110], (e or "?")[:160]) for k, (w, s, e) in found.items()}


for name, rel, edits, label, test in jobs:
    bk = tempfile.mkdtemp(prefix="quickmut2-")
    for n in ("setting", "tools", "p4_proxy"):
        os.symlink(os.path.join(repo, n), os.path.join(bk, n))
    d = os.path.join(bk, name); os.makedirs(d)
    for sub in ("proxy_agent", "tests", "mininet"):
        shutil.copytree(os.path.join(repo, "p4_proxy", sub), os.path.join(d, sub), ignore=shutil.ignore_patterns("__pycache__"))
    if os.path.isdir(build):
        os.makedirs(os.path.join(d, "p4_src"))
        shutil.copytree(build, os.path.join(d, "p4_src", "build"))
    if rel:
        p = os.path.join(d, rel); s = open(p).read()
        for a, b in edits:
            assert s.count(a) == 1, (name, s.count(a), a[:60])
            s = s.replace(a, b)
        open(p, "w").write(s)
    r = subprocess.run([py, "-m", "unittest", "-v"] + modules, cwd=d,
                       env=dict(os.environ, PYTHONPATH=d, PYTHONDONTWRITEBYTECODE="1"), capture_output=True, text=True)
    out = r.stderr
    red = [l for l in out.splitlines() if l.startswith(("FAIL:", "ERROR:"))]
    tail = [l for l in out.splitlines() if l.startswith(("Ran", "OK", "FAILED"))]
    why = assertions(out)
    print("%s: %s" % (name, label[:110]))
    if test:
        hit = any(re.match(r'^(FAIL|ERROR): %s ' % re.escape(test), l) for l in red)
        print("   named test: %s  -> %s" % (test, "RED" if hit else "GREEN (survived)"))
        if hit:
            print("   assertion: %s" % why.get(test, "?"))
    print("   rc=%d %s" % (r.returncode, tail))
    for l in red:
        t = re.match(r'^(?:FAIL|ERROR): (\w+) ', l).group(1)
        print("   " + l)
        print("        at " + why.get(t, "?"))
    sys.stdout.flush()
    shutil.rmtree(bk)
