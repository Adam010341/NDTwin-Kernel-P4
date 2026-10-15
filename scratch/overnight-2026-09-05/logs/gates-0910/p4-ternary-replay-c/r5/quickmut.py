"""Quick check (NOT the gate): apply selected mutants of mutate_table_journal.sh to a copy of <repo>'s p4_proxy and run the one named test.
usage: quickmut.py <repo> <python> <names...>  ; prints the unittest verdict and the FAIL/ERROR lines.
[Co-developed with claude code -- Adam]"""
import re, shlex, shutil, subprocess, sys, os, tempfile
repo, py, names = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(os.path.join(repo, "tests/shell/mutate_table_journal.sh")).read()
files = {"JOURNAL": "proxy_agent/rule_journal.py", "MAIN": "proxy_agent/main.py", "ROUTES": "proxy_agent/api_routes.py"}
pat = re.compile(r'm=\$\(mutant2? (\w+) "\$(\w+)" \\\n(.*?)\)\nreport \'((?:[^\']|\'\\\'\')*)\' "\$m" \\\n\s+\'(\w+)\'', re.S)
for m in pat.finditer(text):
    name, fvar, args, label, test = m.groups()
    if name not in names:
        continue
    parts = shlex.split(args.replace("\\\n", " "))
    assert len(parts) in (2, 4), (name, len(parts))
    bk = tempfile.mkdtemp(prefix="quickmut-")
    for n in ("setting", "tools", "p4_proxy"):
        os.symlink(os.path.join(repo, n), os.path.join(bk, n))
    d = os.path.join(bk, name); os.makedirs(d)
    for sub in ("proxy_agent", "tests", "mininet"):
        shutil.copytree(os.path.join(repo, "p4_proxy", sub), os.path.join(d, sub), ignore=shutil.ignore_patterns("__pycache__"))
    p = os.path.join(d, files[fvar]); s = open(p).read()
    for a, b in zip(parts[0::2], parts[1::2]):
        assert s.count(a) == 1, (name, s.count(a), a[:60])
        s = s.replace(a, b)
    open(p, "w").write(s)
    r = subprocess.run([py, "-m", "unittest", "-v", "tests.test_table_entry_replay", "tests.test_table_entry_journal"], cwd=d,
                       env=dict(os.environ, PYTHONPATH=d, PYTHONDONTWRITEBYTECODE="1"), capture_output=True, text=True)
    out = r.stderr
    red = [l for l in out.splitlines() if l.startswith(("FAIL:", "ERROR:"))]
    tail = [l for l in out.splitlines() if l.startswith(("Ran", "OK", "FAILED"))]
    print("%s: %s" % (name, label[:90]))
    print("   named test: %s  -> %s" % (test, "RED" if any(test in l for l in red) else "GREEN (survived)"))
    print("   %s" % tail)
    for l in red:
        print("   " + l)
    shutil.rmtree(bk)
