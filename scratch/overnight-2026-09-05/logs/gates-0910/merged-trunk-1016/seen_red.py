"""seen_red.py <clone> <gate log> <module>... : which tests of each module the gate log shows red at least once
(a mutant's named killer, or an `also red` line), and which it never does. [Co-developed with claude code -- Adam]"""
import os, re, subprocess, sys
clone, log, mods = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(log, encoding="utf-8").read()
red = set(re.findall(r"also red: (\S+)", text))
named = set(re.findall(r"\((test_\w+) went red\)", text))
py = os.path.join(clone, "p4_proxy", "venv", "bin", "python")
code = ("import sys, unittest\nsys.path.insert(0, '.')\n"
        "def walk(s):\n    for t in s:\n        yield from (walk(t) if isinstance(t, unittest.TestSuite) else [t])\n"
        "for m in sys.argv[1:]:\n    for t in walk(unittest.defaultTestLoader.loadTestsFromName(m)):\n        print(t.id())\n")
ids = subprocess.run([py, "-c", code] + mods, cwd=os.path.join(clone, "p4_proxy"), capture_output=True, text=True,
                     env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1")).stdout.split()
ids = [i for i in ids if i.startswith("tests.")]   # importing main prints the package line on stdout
never = []
for i in ids:
    if i in red or i.rsplit(".", 1)[-1] in named:
        continue
    never.append(i)
print("tests: %d, seen red: %d, never seen red: %d" % (len(ids), len(ids) - len(never), len(never)))
for i in never:
    print("  never red: " + i)
