#!/usr/bin/env python3
"""The first example of sdk/python/README.md, run as written against the fake `basic` kernel.

[Co-developed with claude code -- Adam]

The README's example is the code a newcomer copies first. It moves the routes off the spine s4
of the tutorials' `basic` pod topology and powers s4 off, so on that fabric it must leave every
host reachable without s4: both s1's route to h4 and s2's route to h2 leave towards s4 there, and
an example that moved only one of them would strand the other. The fake kernel
(tests/python/p4_fake_kernel.py) serves a recorded reply of that topology and its tables, and
walks the tables the way examples/p4_energy_saving/route_walk.py does.

The example is taken from the README's first ```python block; only its kernel URL is replaced.
README_UNDER_TEST points at another copy of the README.

    python3 tests/python/test_ndtwin_sdk_readme_example.py -v
"""
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(HERE))
SDK_DIR = os.path.join(REPO_DIR, "sdk", "python")
README = os.environ.get("README_UNDER_TEST") or os.path.join(SDK_DIR, "README.md")
sys.path.insert(0, HERE)
from p4_fake_kernel import FIELD, FakeKernel, calls, serve  # noqa: E402

sys.path.insert(0, SDK_DIR)
import ndtwin  # noqa: E402

URL_IN_README = '"http://localhost:8000"'


def readme_example():
    """The README's first python block, the one that makes a Kernel."""
    with open(README) as fh:
        blocks = re.findall(r"^```python\n(.*?)^```", fh.read(), re.M | re.S)
    first = [b for b in blocks if "ndtwin.Kernel(" in b][0]
    return first


class ReadmeExampleTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeKernel()
        self.server = serve(self.fake)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def run_example(self):
        code = readme_example()
        self.assertEqual(code.count(URL_IN_README), 1, "the example names the kernel once")
        exec(compile(code.replace(URL_IN_README, repr(self.url)), README, "exec"),
             {"__name__": "readme_example", "ndtwin": ndtwin})

    def test_it_moves_every_route_that_leaves_towards_s4_and_no_other(self):
        self.run_example()
        written = sorted((b["dpid"], b["match"][FIELD][0], b["action_params"]["port"])
                         for m, p, q, b in self.fake.requests
                         if m == "POST" and p == "/ndt/p4/table_entry")
        # s1's port 4 and s2's port 3 lead to s4; their other spine, s3, is on s1's port 3 and
        # s2's port 4 (tests/python/fixtures/p4_energy_saving/basic_pod_topo_graph.json).
        self.assertEqual(written, [(1, "10.0.4.4", 3), (2, "10.0.2.2", 4)])

    def test_every_host_still_reaches_every_other_without_s4(self):
        self.run_example()
        attach = {"10.0.1.1": 1, "10.0.2.2": 1, "10.0.3.3": 2, "10.0.4.4": 2}
        for src, switch in attach.items():
            for dst in attach:
                if dst == src:
                    continue
                with self.subTest(src=src, dst=dst):
                    path, ok = self.fake.walk(switch, dst)
                    self.assertTrue(ok, f"{src} -> {dst} stops at {path}")
                    self.assertNotIn(4, path, f"{src} -> {dst} still crosses s4")

    def test_it_powers_s4_off_and_on_again_under_the_lock(self):
        self.run_example()
        seq = calls(self.fake)
        self.assertEqual(seq[0], "POST acquire_lock")
        self.assertEqual(seq[-1], "POST release_lock")
        power = [c for c in seq if c.startswith("POST power")]
        self.assertEqual(power, ["POST power 192.168.123.14 off", "POST power 192.168.123.14 on"])
        self.assertLess(seq.index("POST renew_lock"), seq.index(power[0]))


if __name__ == "__main__":
    unittest.main()
