#!/usr/bin/env python3
# oldcode_selfcheck_mutants.hbr6.py -- the mutation gate of oldcode_selftest.sh --self-check.
#
# [Co-developed with claude code -- Adam]
#
# Round 6 (finding 3 of the round-5 verdict) gave the oldcode tool a --self-check that feeds its
# verdict code wrong expectations. This is that self-check's own red: each MUTANT below breaks one
# verdict path of the tool (a copy, written beside the real tool as .oldcode-mut-<pid>-<k>.sh so it
# finds the spike exactly as the real one does -- covered by spike/.gitignore), and the self-check
# case written for that path must then answer NOT AS IT MUST, rc 1. Nothing here touches a lab;
# what runs is the copy's --self-check, i.e. the spike's --self-test on copies, with
# SELFTEST_PROBE_SUDO and FAULTS_TC removed from the environment.
#
#   python3 oldcode_selfcheck_mutants.hbr6.py <spike dir>
import os
import subprocess
import sys

D = os.path.abspath(sys.argv[1])
TOOL = os.path.join(D, "oldcode_selftest.sh")
src = open(TOOL).read()

# name -> (the tool's text, what it becomes, the self-check case that must then fail)
MUTANTS = {
    "reason-check-gone": ("            if reason and reason not in reds[hits[0]]:\n",
                          "            if False:\n", "wrong-reason"),
    "count-check-silent": ('                problems.append(f"expected red once, got {len(hits)}: {text_!r}")\n',
                           "                pass\n", "extra-line"),
    "unnamed-check-gone": ("            if i not in matched:\n", "            if False:\n", "unnamed-red"),
    "exit0-check-gone": ("        elif p.returncode == 0:\n", "        elif False:\n", "reddens-nothing"),
    "control-rc-check-gone": ("            if p.returncode != 0:\n                problems.append(f\"the control's",
                              "            if False:\n                problems.append(f\"the control's", "dirty-control"),
    "anchor-check-gone": ("            if found != count:\n", "            if False:\n", "anchor-absent"),
    "repoint-check-gone": ('        if text["spike"].count(REPOINT) != 1:\n', "        if False:\n", "watch-line"),
    "always-unexpected": ("        ok = not problems\n", "        ok = False\n", "real-row"),
}

env = {k: v for k, v in os.environ.items() if k not in ("SELFTEST_PROBE_SUDO", "FAULTS_TC")}
rows = []
for k, (name, (new, old, case)) in enumerate(MUTANTS.items()):
    n = src.count(new)
    if n != 1:
        print(f"### {name}: the mutation applies {n} time(s), written for 1 -- nothing run")
        sys.exit(2)
    copy = os.path.join(D, f".oldcode-mut-{os.getpid()}-{k}.sh")
    try:
        with open(copy, "w") as fh:
            fh.write(src.replace(new, old))
        print(f"\n### mutant {name}: {new.strip()!r} -> {old.strip()!r}; self-check case {case} must now fail")
        p = subprocess.run(["bash", copy, "--self-check", case], env=env, capture_output=True, text=True)
    finally:
        try:
            os.remove(copy)
        except OSError:
            pass
    out = p.stdout + p.stderr
    for line in out.splitlines():
        if line.startswith(f"### self-check {case}:") or line.startswith("    | ### PROBLEM") \
                or line.startswith("    | ### case:") or line.startswith("    | ### control:") \
                or line.startswith("    | ### R4-3:") or line.startswith("SELF-CHECK") or line.startswith("EVERY"):
            print(line)
    caught = p.returncode == 1 and f"### self-check {case}: NOT AS IT MUST" in out
    print(f"### mutant {name}: the self-check answered rc {p.returncode} -- "
          + ("CAUGHT" if caught else "NOT CAUGHT"))
    rows.append((name, case, p.returncode, caught))

print("\n### per mutant of the tool: the self-check case written for it, its rc, verdict")
for name, case, rc, caught in rows:
    print(f"    {name:22s} {case:16s} {rc:3d}  {'caught' if caught else 'NOT CAUGHT'}")
ok = all(r[3] for r in rows)
print("THE SELF-CHECK CATCHES EVERY MUTANT OF THE TOOL'S VERDICT CODE" if ok else "A MUTANT WAS NOT CAUGHT")
sys.exit(0 if ok else 1)
