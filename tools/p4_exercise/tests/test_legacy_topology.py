"""The 2018-19 tutorials topology format, converted by that harness's own rules.

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests \
        -t tools/p4_exercise/tests -v

Apps written for the P4 Developer Day 2018/2019 VMs -- Princeton-Cabernet's ONTAS (bmv2_p4_16) is
the one in hand -- carry a topology.json whose `hosts` is a list of names and whose links name a
switch with no port. The harness of that era (p4lang/tutorials 948a890, utils/run_exercise.py,
ExerciseTopo.__init__ and parse_links) numbered the ports and addressed the hosts itself; convert
reproduces those numbers, because the app's runtime entries are written against them (ONTAS keys
twenty tables on ingress port 1 and forwards to port 2). No file of ONTAS is copied here: the
topologies below are written for the test, in that format.
"""
import io
import contextlib
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(os.path.dirname(HERE))
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

from p4_exercise import common, convert  # noqa: E402

#: The shape of ONTAS's src/topology.json: one switch, two hosts, links with no port.
ONE_SWITCH = {"hosts": ["h1", "h2"], "switches": {"s1": {"runtime_json": "s1-runtime.json"}},
              "links": [["h1", "s1"], ["h2", "s1"]]}


class TheHarnessRules(unittest.TestCase):
    def test_hosts_get_10_0_switch_host_and_the_harness_mac(self):
        topo = convert.legacy_topology(ONE_SWITCH)
        self.assertEqual(topo["hosts"], {
            "h1": {"ip": "10.0.1.1/24", "mac": "00:00:00:00:01:01", "commands": []},
            "h2": {"ip": "10.0.1.2/24", "mac": "00:00:00:00:01:02", "commands": []},
        })

    def test_host_links_take_the_first_ports_in_sorted_order(self):
        topo = convert.legacy_topology({
            "hosts": ["h1", "h2", "h3"],
            "switches": {"s1": {}, "s2": {}},
            # Out of order, and one link written switch-first: the harness orders each link's
            # ends alphabetically, then sorts host links, then switch links.
            "links": [["s2", "s1"], ["h3", "s2"], ["s1", "h1"], ["h2", "s1"]]})
        self.assertEqual(topo["links"], [["h1", "s1-p1"], ["h2", "s1-p2"], ["h3", "s2-p1"],
                                         ["s1-p3", "s2-p2"]])

    def test_a_latency_and_bandwidth_ride_along(self):
        topo = convert.legacy_topology({"hosts": ["h1"], "switches": {"s1": {}},
                                        "links": [["h1", "s1", "5ms", 10]]})
        self.assertEqual(topo["links"], [["h1", "s1-p1", "5ms", 10]])

    def test_a_port_in_a_legacy_topology_is_refused(self):
        with self.assertRaises(convert.ConversionError) as caught:
            convert.legacy_topology({"hosts": ["h1"], "switches": {"s1": {}},
                                     "links": [["h1", "s1-p1"]]})
        self.assertIn("neither format", str(caught.exception))

    def test_a_host_with_no_link_is_refused(self):
        with self.assertRaises(convert.ConversionError) as caught:
            convert.legacy_topology({"hosts": ["h1", "h2"], "switches": {"s1": {}},
                                     "links": [["h1", "s1"]]})
        self.assertIn("h2", str(caught.exception))

    def test_the_current_format_is_not_legacy(self):
        self.assertFalse(convert.is_legacy_topology({"hosts": {"h1": {}}}))
        self.assertTrue(convert.is_legacy_topology(ONE_SWITCH))


class ConvertingALegacyApp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_legacy_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.app = os.path.join(self.tmp, "app")
        os.makedirs(os.path.join(self.app, "build"))
        with open(os.path.join(self.app, "topology.json"), "w") as fh:
            json.dump(ONE_SWITCH, fh)
        with open(os.path.join(self.app, "s1-runtime.json"), "w") as fh:
            json.dump({"target": "bmv2", "p4info": "build/app.p4.p4info.txt",
                       "bmv2_json": "build/app.json", "table_entries": []}, fh)
        for rel in ("build/app.p4.p4info.txt", "build/app.json", "app.p4"):
            with open(os.path.join(self.app, rel), "w") as fh:
                fh.write("x\n")

    def convert(self):
        return convert.convert(self.app, "topology.json", os.path.join(self.tmp, "pkg"),
                               p4_rel="app.p4")

    def test_the_package_has_the_harness_hosts_and_ports(self):
        package, model, _written = self.convert()
        self.assertEqual(package["hosts"]["h1"]["ip"], "10.0.1.1")
        self.assertEqual(package["hosts"]["h2"]["mac"], "00:00:00:00:01:02")
        self.assertEqual(sorted((l["a"], l["b"]) for l in package["links"]),
                         [(["h1", 1], ["s1", 1]), (["h2", 1], ["s1", 2])])
        self.assertEqual(package["source"]["topology_format"],
                         "tutorials-2018 (hosts a list; ports and addresses derived)")

    def test_the_apps_topology_file_is_carried_unchanged(self):
        _package, _model, _written = self.convert()
        with open(os.path.join(self.tmp, "pkg", "topology.json")) as fh:
            self.assertEqual(json.load(fh), ONE_SWITCH)

    def test_the_command_line_says_what_it_derived_and_what_it_did_not_carry(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = convert.main([self.app, "--topology", "topology.json", "--p4", "app.p4",
                               "--out", os.path.join(self.tmp, "cli")])
        self.assertEqual(rc, 0)
        self.assertIn("948a890", out.getvalue())
        self.assertIn("h2 10.0.1.2/24 00:00:00:00:01:02 on s1 port 2", out.getvalue())
        self.assertIn("default route", out.getvalue())
        self.assertIn("not carried", out.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
