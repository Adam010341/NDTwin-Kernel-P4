"""Does requirements.txt describe a given venv? Every `name==ver` / `name>=ver` line vs `pip freeze`.

Worker REQ (TICKET-p4proxy-requirements). The ticket's defect is "the file and the venv every
test and live run uses disagree". The suites cannot see that -- they pass under either -- so this
is the check that must be red on the old file and green on the new one.

  check_pins_vs_venv.py <requirements.txt> <freeze.txt> [--allow name ...]

A pin counts as matching only when it is `==` and equals the venv's version. A floor (`>=`) is
reported as NOT DESCRIBING the venv even when satisfied: it names no version anyone tested.
--allow names a package whose mismatch is declared (reported, not counted as red).

[Co-developed with claude code -- Adam]
"""
import re
import sys

req_path, freeze_path, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
allow = set()
if rest and rest[0] == "--allow":
    allow = {re.sub(r"[-_.]+", "-", a).lower() for a in rest[1:]}


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


venv = {}
for line in open(freeze_path):
    m = re.match(r"^([A-Za-z0-9_.\-]+)==(\S+)", line.strip())
    if m:
        venv[norm(m.group(1))] = m.group(2)

bad = 0
for raw in open(req_path):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    m = re.match(r"^([A-Za-z0-9_.\-]+)\s*(==|>=|~=|<=|>|<)?\s*([^\s;]*)", line)
    name, op, ver = norm(m.group(1)), m.group(2) or "", m.group(3)
    have = venv.get(name, "<absent>")
    if op == "==" and ver == have:
        verdict = "MATCH"
    elif name in allow:
        verdict = "DECLARED-MISMATCH"
    else:
        verdict = "MISMATCH" if op == "==" else "FLOOR(names no tested version)"
        bad += 1
    print(f"{verdict:32s} {name:28s} file {op}{ver:14s} venv {have}")
print(f"RESULT: {'GREEN' if bad == 0 else 'RED'} ({bad} line(s) do not describe the venv)")
sys.exit(1 if bad else 0)
