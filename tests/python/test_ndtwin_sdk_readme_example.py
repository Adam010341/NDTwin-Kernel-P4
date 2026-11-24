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
The examples of "Cutting a link" run against tests/python/link_fake_kernel.py.
README_UNDER_TEST points at another copy of the README.

    python3 tests/python/test_ndtwin_sdk_readme_example.py -v
"""
import contextlib
import io
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
import link_fake_kernel as lfk  # noqa: E402  [Co-developed with claude code -- Adam]

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
        """Runs the example and returns what it printed."""
        code = readme_example()
        self.assertEqual(code.count(URL_IN_README), 1, "the example names the kernel once")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            exec(compile(code.replace(URL_IN_README, repr(self.url)), README, "exec"),
                 {"__name__": "readme_example", "ndtwin": ndtwin})
        return out.getvalue()

    def test_it_prints_the_routes_it_moved_and_the_power_state(self):
        # [Co-developed with claude code -- Adam]
        # Run as shown, the example must tell the user what it did: each moved route with its
        # new port, and the state power_off read back.
        lines = self.run_example().splitlines()
        for dpid, address, port in ((1, "10.0.4.4", 3), (2, "10.0.2.2", 4)):
            with self.subTest(dpid=dpid):
                self.assertTrue([ln for ln in lines if ln.startswith(f"s{dpid} ")
                                 and address in ln and ln.endswith(f" {port}")],
                                f"no line says s{dpid}'s route to {address} moved to port {port}")
        self.assertTrue([ln for ln in lines if "admin_state='off'" in ln],
                        "no line shows the power state read back after power_off")

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


class LinkExamplesTest(unittest.TestCase):
    """The examples of the README's "Cutting a link", run as written with `k` and `ndtwin` against
    the fake of the link routes (tests/python/link_fake_kernel.py).
    [Co-developed with claude code -- Adam]"""

    def setUp(self):
        self.fake = lfk.LinkFakeKernel()
        self.server = lfk.serve(self.fake)
        self.k = ndtwin.Kernel("http://127.0.0.1:%d" % self.server.server_address[1], timeout=5,
                               retry_wait=0)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def run_block(self, marker):
        with open(README) as fh:
            blocks = re.findall(r"^```python\n(.*?)^```", fh.read(), re.M | re.S)
        code = [b for b in blocks if marker in b][0]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            exec(compile(code, README, "exec"), {"k": self.k, "ndtwin": ndtwin})
        return out.getvalue().splitlines()

    def recoveries(self):
        return self.fake.posts(lfk.RECOVER)

    def test_the_with_example_cuts_the_link_and_puts_it_back(self):
        lines = self.run_block("k.link_down(")
        self.assertEqual(lines, ["on the wire: True ('s1-eth1', 's2-eth1')",
                                 "restored: ('s1-eth1', 's2-eth1')"])
        self.assertEqual([p for m, p, b in self.fake.requests if m == "POST"],
                         [lfk.INJECT, lfk.RECOVER])
        self.assertEqual((self.fake.netem, self.fake.declared), ({}, set()))

    def test_the_with_example_says_what_was_not_restored(self):
        self.fake.script("POST", lfk.RECOVER, (500, lfk.INTERNAL))   # HS.cpp:609-616
        lines = self.run_block("k.link_down(")
        self.assertEqual(lines[-1], "not restored: ('s1-eth1', 's2-eth1') "
                                    "k.restore_link(((1, 1), (2, 1)))")

    def test_the_cleanup_example_restores_what_a_killed_app_left(self):
        body = {"src_dpid": 2, "src_interface": 2, "dst_dpid": 3, "dst_interface": 1}
        self.fake.handle("POST", lfk.INJECT, body)     # the injection of an app that was killed
        self.fake.requests.clear()
        lines = self.run_block("k.restore_link(link)")
        self.assertEqual(lines, ["s2-s3 restored: ('s2-eth2', 's3-eth1')"])
        self.assertEqual(self.recoveries(), [body])
        self.assertEqual((self.fake.netem, self.fake.declared), ({}, set()))

    def test_the_cleanup_example_goes_on_past_a_link_it_cannot_restore(self):
        for body in ({"src_dpid": 1, "src_interface": 1, "dst_dpid": 2, "dst_interface": 1},
                     {"src_dpid": 2, "src_interface": 2, "dst_dpid": 3, "dst_interface": 1}):
            self.fake.handle("POST", lfk.INJECT, body)     # two injections an app left
        self.fake.netem["s1-eth1"] = "replaced"            # somebody replaced one netem
        lines = self.run_block("k.restore_link(link)")
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].startswith("s1-s2 not restored: ('s1-eth1',) s1-eth1: "))
        self.assertEqual(lines[1], "s2-s3 restored: ('s2-eth2', 's3-eth1')")

    def test_the_cleanup_example_skips_a_link_it_cannot_address_and_goes_on(self):
        self.fake.cables.append((1, 2, 2, 3))                # a second link between s1 and s2
        for body in ({"src_dpid": 1, "src_interface": 1, "dst_dpid": 2, "dst_interface": 1},
                     {"src_dpid": 2, "src_interface": 2, "dst_dpid": 3, "dst_interface": 1}):
            self.fake.handle("POST", lfk.INJECT, body)
        self.fake.requests.clear()
        lines = self.run_block("k.restore_link(link)")
        self.assertEqual(sorted(ln.split(":")[0] for ln in lines),
                         ["s1-s2 skipped", "s1-s2 skipped", "s2-s3 restored"])
        self.assertIn("have another link between them", lines[0])
        body = {"src_dpid": 2, "src_interface": 2, "dst_dpid": 3, "dst_interface": 1}
        self.assertEqual(self.recoveries(), [body])
        self.assertEqual(self.fake.declared, {frozenset((1, 2))})


if __name__ == "__main__":
    unittest.main()
