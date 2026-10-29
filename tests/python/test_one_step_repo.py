"""The one-step exercise path against the rest of the repo: ndt serve's --app check, the
hand-edited pre-flight captures under tests/python/fixtures/p4_health, and the `make` advice
NDTwin prints.

[Co-developed with claude code -- Adam]

    python3 tests/python/test_one_step_repo.py -v

tools/p4_exercise/tests/test_one_step.py holds the rest; these two read files outside
tools/p4_exercise, so they live here, where the whole tree is always present. Neither needs
protobuf: the conversion runs with --no-roles, and the suggestion text is plain JSON.
"""
import ast
import json
import os
import re
import shutil
import sys
import tempfile
import unittest

# abspath, not realpath: a gate that links tests/ into a copy of the tree must import the copy.
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "ndt_serve"))

from p4_exercise import one_step, preflight  # noqa: E402
import verbs  # noqa: E402

FIXTURES = os.path.join(REPO, "tools", "p4_exercise", "tests", "fixtures")
P4_HEALTH_FIXTURES = os.path.join(REPO, "tests", "python", "fixtures", "p4_health")


class NdtServeAndTheStagingDirectoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_one_step_repo_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.run_dir = os.path.join(self.tmp, "repo", ".test_run")

    def test_ndt_serve_will_not_take_a_staging_directory(self):
        # The real check ndt serve applies to `up --app` (verbs.app_dir), with its default root.
        root = os.path.join(self.run_dir, "packages")
        stage = os.path.join(one_step.staging_root(self.run_dir), "basic-00000000.new-abc")
        os.makedirs(stage)
        with self.assertRaises(verbs.Refused):
            verbs.app_dir(stage, [root])
        exercise = os.path.join(self.tmp, "exercises", "basic")
        shutil.copytree(os.path.join(FIXTURES, "basic"), exercise)
        shutil.rmtree(os.path.join(exercise, "triangle-topo"))
        shutil.copyfile(os.path.join(exercise, "solution", "basic.p4"),
                        os.path.join(exercise, "basic.p4"))
        result = one_step.prepare(exercise, self.run_dir, no_roles=True)
        self.assertEqual(verbs.app_dir(result["dest"], [root]), os.path.realpath(result["dest"]))


class CapturedSuggestionRowsTest(unittest.TestCase):
    """The hand-edited pre-flight captures under tests/python/fixtures/p4_health say what
    pre-flight prints now: each `roles suggestion` row is suggestion_detail() of the role it
    carries. (That row was edited by hand; every other row is as captured -- see line 1 of each.)"""

    def test_every_captured_suggestion_row_is_what_preflight_prints_now(self):
        seen = 0
        for name in sorted(os.listdir(P4_HEALTH_FIXTURES)):
            if not (name.startswith("preflight_pft") and name.endswith(".txt")):
                continue
            with open(os.path.join(P4_HEALTH_FIXTURES, name), encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith("#") or "roles suggestion" not in line:
                        continue                    # line 1 is the capture's own header
                    detail = line.split("roles suggestion", 1)[1].strip()
                    block = json.loads(detail.split('"roles": ', 1)[1].split(" (owner ", 1)[0])
                    # The heuristic hands suggestion_detail its candidate with owner ndtwin
                    # (route_role_candidates resolves with the stricter owner).
                    candidate = dict(block["ipv4_route"], owner="ndtwin")
                    with self.subTest(fixture=name):
                        self.assertEqual(detail, preflight.suggestion_detail(candidate))
                    seen += 1
        self.assertGreaterEqual(seen, 5, "the captures with a suggestion row went missing")

    def test_every_capture_says_its_suggestion_row_was_edited_by_hand(self):
        for name in sorted(os.listdir(P4_HEALTH_FIXTURES)):
            if name.startswith("preflight_pft") and name.endswith(".txt"):
                with open(os.path.join(P4_HEALTH_FIXTURES, name), encoding="utf-8") as fh:
                    first = fh.readline()
                with self.subTest(fixture=name):
                    self.assertIn("the `roles suggestion` row was edited by hand on 2026-10-30",
                                  first)
                    self.assertIn("every other row is as captured", first)



#: A `make` command NDTwin must never advise: `make clean` (tutorials' `clean: stop` runs
#: `sudo mn -c`, which tears down NDTwin's own fabric) and a `make` that is not `make build`
#: (the default target is `run`, which starts tutorials' own Mininet). Only the command form is
#: matched -- quoted or backticked, or followed by a target or `&&` -- not the English verb.
MAKE_ADVICE = re.compile(r"\bmake clean\b|[`'\"(]make(?! build)\b|\bmake (run|all|stop)\b"
                         r"|\bmake\s*&&")


def printed_python_strings(path):
    """(line, text) of every string literal in a module that can reach a user: everything but
    docstrings, plus the module docstring's first line (argparse's description)."""
    tree = ast.parse(open(path, encoding="utf-8").read())
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = node.body
            if (body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant)
                    and isinstance(body[0].value.value, str)):
                docstrings.add(id(body[0].value))
                if isinstance(node, ast.Module):
                    yield body[0].value.lineno, body[0].value.value.splitlines()[0]
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) \
                and id(node) not in docstrings:
            yield node.lineno, node.value


class NoMakeAdviceThatRunsMininetTest(unittest.TestCase):
    """[Co-developed with claude code -- Adam]"""

    def test_the_pattern_tells_the_command_from_the_verb(self):
        for bad in ("Remove the stale one (or `make clean && make`)", "run 'make'",
                    "(`make`)", "make run", "make && sudo"):
            self.assertRegex(bad, MAKE_ADVICE)
        for fine in ("run `make build`", "'make build' has compiled it", "would make a package",
                     "make build"):
            self.assertNotRegex(fine, MAKE_ADVICE)

    def test_no_printed_string_in_tools_p4_exercise_advises_make(self):
        bad = []
        folder = os.path.join(REPO, "tools", "p4_exercise")
        for name in sorted(os.listdir(folder)):
            if name.endswith(".py"):
                for line, text in printed_python_strings(os.path.join(folder, name)):
                    if MAKE_ADVICE.search(text):
                        bad.append(f"{name}:{line}: {text.strip()[:100]!r}")
        self.assertEqual(bad, [])

    def test_no_line_of_ndt_but_its_comments_advises_make(self):
        bad = []
        with open(os.path.join(REPO, "tools", "test_workflow", "ndt"), encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                if not line.lstrip().startswith("#") and MAKE_ADVICE.search(line):
                    bad.append(f"ndt:{n}: {line.strip()[:100]!r}")
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
