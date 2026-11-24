"""
Tests for tools/test_workflow/derive_p4_topology_json.py -- the script `ndt up p4 <n>` points at when
setting/ has no P4 model of <n> hosts.

[Co-developed with claude code -- Adam]

`ndt up p4 <n>` finds a model by the number of hosts it declares, never by its name. The advice used to
derive the 128-host Mininet model into `StaticNetworkTopologyP4_10Switches_<n>Hosts.json` for every <n>;
the script wrote that file, it declared 128 hosts, it was never found for <n>, and the same refusal came
back. The script now refuses a name that carries a host count the model does not declare, and writes
nothing. These cells run the real script on the shipped models, writing only into a temporary directory.

Needs nothing but the standard library: run it with plain python3.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# DERIVE_UNDER_TEST=<path> scores another copy of the script (the base file, or a mutant).
SCRIPT = os.environ.get("DERIVE_UNDER_TEST") or os.path.join(
    REPO, "tools", "test_workflow", "derive_p4_topology_json.py")
SETTING = os.path.join(REPO, "setting")
OVS_8 = os.path.join(SETTING, "StaticNetworkTopologyOVS_10Switches_8Hosts.json")
OVS_4 = os.path.join(SETTING, "StaticNetworkTopologyOVS_10Switches_4Hosts.json")
MININET_128 = os.path.join(SETTING, "StaticNetworkTopologyMininet_10Switches.json")


def derive(src, dst):
    """Run the script as a user does; return (rc, combined output)."""
    p = subprocess.run([sys.executable, "-I", "-B", SCRIPT, src, dst],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout


def hosts_of(path):
    with open(path) as fh:
        return sum(1 for n in json.load(fh)["nodes"] if n.get("vertex_type") == 1)


def brands_of(path):
    with open(path) as fh:
        return {n.get("brand_name") for n in json.load(fh)["nodes"] if n.get("vertex_type") == 0}


class DeriveNameAgainstCount(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="derive-p4-")
        self.tmp = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def out(self, name):
        return os.path.join(self.tmp, name)

    def test_the_shipped_sources_are_what_these_cells_assume(self):
        # Guards the cells below against a setting/ whose models moved: a different count here would
        # turn every "refused" into a refusal of something else.
        self.assertEqual(hosts_of(MININET_128), 128)
        self.assertEqual(hosts_of(OVS_8), 8)
        self.assertEqual(hosts_of(OVS_4), 4)

    def test_the_128_host_model_into_a_name_for_8_hosts_is_refused_and_nothing_is_written(self):
        dst = self.out("StaticNetworkTopologyP4_10Switches_8Hosts.json")
        rc, text = derive(MININET_128, dst)
        self.assertNotEqual(rc, 0, text)
        self.assertFalse(os.path.exists(dst), "a refused derive left a file behind")
        self.assertEqual(os.listdir(self.tmp), [])
        self.assertIn("8 hosts", text)
        self.assertIn("declares 128", text)

    def test_a_refusal_leaves_an_existing_file_as_it_was(self):
        dst = self.out("StaticNetworkTopologyP4_10Switches_8Hosts.json")
        with open(dst, "w") as fh:
            fh.write("keep me\n")
        rc, _ = derive(MININET_128, dst)
        self.assertNotEqual(rc, 0)
        with open(dst) as fh:
            self.assertEqual(fh.read(), "keep me\n")

    def test_the_other_direction_is_refused_too(self):
        dst = self.out("StaticNetworkTopologyP4_10Switches_128Hosts.json")
        rc, text = derive(OVS_8, dst)
        self.assertNotEqual(rc, 0, text)
        self.assertFalse(os.path.exists(dst))

    def test_the_8_host_ovs_model_into_a_name_for_8_hosts_is_derived(self):
        dst = self.out("StaticNetworkTopologyP4_10Switches_8Hosts.json")
        rc, text = derive(OVS_8, dst)
        self.assertEqual(rc, 0, text)
        self.assertEqual(hosts_of(dst), 8)
        self.assertEqual(brands_of(dst), {"BMv2"})
        self.assertIn("8 hosts", text)

    def test_the_128_host_model_into_a_name_for_128_hosts_is_derived(self):
        dst = self.out("StaticNetworkTopologyP4_10Switches_128Hosts.json")
        rc, text = derive(MININET_128, dst)
        self.assertEqual(rc, 0, text)
        self.assertEqual(hosts_of(dst), 128)
        self.assertEqual(brands_of(dst), {"BMv2"})

    def test_a_name_that_says_nothing_about_a_size_is_not_checked(self):
        # The control: refusing every output would pass the refusals above and break
        # the script's other use, a model under any name the caller chooses.
        for name in ("m.json", "some_Hosts.json", "Hosts8.json"):
            dst = self.out(name)
            rc, text = derive(OVS_8, dst)
            self.assertEqual(rc, 0, (name, text))
            self.assertEqual(hosts_of(dst), 8)

    def test_the_brand_check_still_refuses_a_model_that_is_not_ovs(self):
        p4 = self.out("already_p4.json")
        rc, _ = derive(OVS_8, p4)
        self.assertEqual(rc, 0)
        dst = self.out("again.json")
        rc, text = derive(p4, dst)
        self.assertNotEqual(rc, 0, text)
        self.assertFalse(os.path.exists(dst))
        self.assertIn("expected 'OVS'", text)


if __name__ == "__main__":
    unittest.main()
