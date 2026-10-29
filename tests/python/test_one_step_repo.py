"""The one-step exercise path against the rest of the repo: ndt serve's --app check, and the
pre-flight captures under tests/python/fixtures/p4_health.

[Co-developed with claude code -- Adam]

    python3 tests/python/test_one_step_repo.py -v

tools/p4_exercise/tests/test_one_step.py holds the rest; these two read files outside
tools/p4_exercise, so they live here, where the whole tree is always present. Neither needs
protobuf: the conversion runs with --no-roles, and the suggestion text is plain JSON.
"""
import json
import os
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
    """The pre-flight captures under tests/python/fixtures/p4_health say what pre-flight prints
    now: each `roles suggestion` row is suggestion_detail() of the role it carries."""

    def test_every_captured_suggestion_row_is_what_preflight_prints_now(self):
        seen = 0
        for name in sorted(os.listdir(P4_HEALTH_FIXTURES)):
            if not (name.startswith("preflight_pft") and name.endswith(".txt")):
                continue
            with open(os.path.join(P4_HEALTH_FIXTURES, name), encoding="utf-8") as fh:
                for line in fh:
                    if "roles suggestion" not in line:
                        continue
                    detail = line.split("roles suggestion", 1)[1].strip()
                    block = json.loads(detail.split('"roles": ', 1)[1].split(" (owner ", 1)[0])
                    # The heuristic hands suggestion_detail its candidate with owner ndtwin
                    # (route_role_candidates resolves with the stricter owner).
                    candidate = dict(block["ipv4_route"], owner="ndtwin")
                    with self.subTest(fixture=name):
                        self.assertEqual(detail, preflight.suggestion_detail(candidate))
                    seen += 1
        self.assertGreaterEqual(seen, 5, "the captures with a suggestion row went missing")


if __name__ == "__main__":
    unittest.main(verbosity=2)
