"""Run a unittest suite and write one verdict per test id to a file.

Worker REQ (TICKET-p4proxy-requirements). Equal "Ran N / OK (skipped=1)" lines are not equal
results: a pass that became a skip, or a different test skipping, leaves both lines unchanged.
This records test id -> ok | skip: <reason> | FAIL | ERROR | xfail | UNEXPECTED-SUCCESS, sorted,
so two interpreters can be diffed per test. Runs under the interpreter being judged; stdlib only.

  verdicts.py <out> modules <name>...          (like `python -m unittest <name>...`)
  verdicts.py <out> discover <start> <top>     (like `python -m unittest discover -s -t`)

[Co-developed with claude code -- Adam]
"""
import sys
import unittest

out, mode, args = sys.argv[1], sys.argv[2], sys.argv[3:]
loader = unittest.TestLoader()
if mode == "modules":
    suite = loader.loadTestsFromNames(args)
elif mode == "discover":
    suite = loader.discover(start_dir=args[0], top_level_dir=args[1])
else:
    raise SystemExit(f"unknown mode {mode!r}")


class Recording(unittest.TextTestResult):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.verdicts = {}

    def addSuccess(self, test):
        super().addSuccess(test)
        self.verdicts[test.id()] = "ok"

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.verdicts[test.id()] = "skip: " + " ".join(str(reason).split())

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.verdicts[test.id()] = "FAIL"

    def addError(self, test, err):
        super().addError(test, err)
        self.verdicts[test.id()] = "ERROR"

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.verdicts[test.id()] = "xfail"

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self.verdicts[test.id()] = "UNEXPECTED-SUCCESS"

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            self.verdicts[subtest.id()] = "FAIL(subtest)"


res = unittest.TextTestRunner(resultclass=Recording, verbosity=1).run(suite)
with open(out, "w") as f:
    for tid in sorted(res.verdicts):
        f.write(f"{tid}\t{res.verdicts[tid]}\n")
print(f"verdicts: {len(res.verdicts)} ids written to {out}")
sys.exit(0 if res.wasSuccessful() else 1)
