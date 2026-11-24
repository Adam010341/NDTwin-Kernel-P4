#!/usr/bin/env python3
"""Do two topology models describe the same network? `ndt up p4` refuses an NDT_TOPO that does not.

[Co-developed with claude code -- Adam]

On the P4 plane the fabric is built from the model in setting/ that has the asked-for host count,
whatever NDT_TOPO says, so `ndt up p4` compares NDT_TOPO with that model before anything is built and
prints what `topo_from_json.network_diff` returns. Each way a network can differ has to be seen to be
named -- and the differences that must not count have to be seen to pass, or a comparison that flags
everything would look like one that works.

Imports only topo_from_json (stdlib), so it runs in CI, which has no mininet. The mutation gate
tests/shell/mutate_topo_network_diff.sh points TOPO_FROM_JSON_DIR at a directory holding a mutated copy
of the module; the test names below are what that gate names, so they are not to be renamed lightly.

Run:  python3 tests/python/test_topo_network_diff.py -v
"""
import copy
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODDIR = os.environ.get("TOPO_FROM_JSON_DIR") or os.path.join(REPO, "p4_proxy", "mininet")
MODFILE = os.path.join(MODDIR, "topo_from_json.py")
_spec = importlib.util.spec_from_file_location("topo_from_json_under_test", MODFILE)
T = importlib.util.module_from_spec(_spec)
sys.modules["topo_from_json_under_test"] = T
_spec.loader.exec_module(T)

SETTING = os.path.join(REPO, "setting")
P4_4 = os.path.join(SETTING, "StaticNetworkTopologyP4_10Switches_4Hosts.json")
P4_4_NAME = os.path.basename(P4_4)
OVS_4 = os.path.join(SETTING, "StaticNetworkTopologyOVS_10Switches_4Hosts.json")
P4_128 = os.path.join(SETTING, "StaticNetworkTopologyP4_10Switches_128Hosts.json")
MN_128 = os.path.join(SETTING, "StaticNetworkTopologyMininet_10Switches.json")
BASE = T.load(P4_4)
TMP = None


def setUpModule():
    global TMP
    TMP = tempfile.mkdtemp(prefix="topo-network-diff-")


def tearDownModule():
    shutil.rmtree(TMP, ignore_errors=True)


def write_model(name, model):
    path = os.path.join(TMP, name)
    with open(path, "w") as fh:
        json.dump(model, fh)
    return path


def write_text(name, text):
    path = os.path.join(TMP, name)
    with open(path, "w") as fh:
        fh.write(text)
    return path


def cable_edges(model, a_end, b_end):
    """The stored directions of the cable between (dpid, port) a_end and b_end."""
    out = [e for e in model["edges"]
           if {(e.get("src_dpid"), e.get("src_interface")),
               (e.get("dst_dpid"), e.get("dst_interface"))} == {a_end, b_end}]
    assert len(out) == 2, (a_end, b_end, len(out))
    return out


def recable(model, old_a, old_b, new_a, new_b):
    """Move the cable old_a--old_b so that it joins new_a--new_b."""
    for e in cable_edges(model, old_a, old_b):
        if (e["src_dpid"], e["src_interface"]) == old_a:
            e["src_dpid"], e["src_interface"], e["dst_dpid"], e["dst_interface"] = (*new_a, *new_b)
        else:
            e["dst_dpid"], e["dst_interface"], e["src_dpid"], e["src_interface"] = (*new_a, *new_b)


def node(model, **match):
    return next(n for n in model["nodes"] if all(n.get(k) == v for k, v in match.items()))


def diff(a, b, limit=5):
    return T.network_diff(a, b, limit=limit)


class SameNetwork(unittest.TestCase):
    def test_byte_copy_is_the_same_network(self):
        self.assertEqual(diff(P4_4, write_model("copy_of_p4_4.json", copy.deepcopy(BASE))), [])

    def test_nicknames_and_bandwidths_are_not_compared(self):
        m = copy.deepcopy(BASE)
        for n in m["nodes"]:
            n["nickname"] = "x" + str(n.get("nickname"))
        for e in m["edges"]:
            e["link_bandwidth_bps"] = 100000000
        self.assertEqual(diff(P4_4, write_model("renick.json", m)), [])


class Cables(unittest.TestCase):
    def test_cable_missing_names_the_switch_and_port(self):
        m = copy.deepcopy(BASE)
        for e in cable_edges(m, (1, 1), (5, 1)):
            m["edges"].remove(e)
        lines = diff(P4_4, write_model("e1.json", m))
        self.assertTrue(lines)
        self.assertEqual(lines[0], f"s1 port 1: s5 port 1 in {P4_4_NAME}, nothing in e1.json")

    def test_two_ports_swapped_names_both(self):
        m = copy.deepcopy(BASE)
        recable(m, (1, 1), (5, 1), (1, 1), (6, 1))
        recable(m, (1, 2), (6, 1), (1, 2), (5, 1))
        lines = diff(P4_4, write_model("e1b.json", m))
        self.assertGreaterEqual(len(lines), 2)
        self.assertEqual(lines[0], f"s1 port 1: s5 port 1 in {P4_4_NAME}, s6 port 1 in e1b.json")
        self.assertEqual(lines[1], f"s1 port 2: s6 port 1 in {P4_4_NAME}, s5 port 1 in e1b.json")

    def test_two_cables_on_one_port_is_not_a_model_the_fabric_could_build(self):
        m = copy.deepcopy(BASE)
        recable(m, (1, 2), (6, 1), (1, 1), (6, 1))
        lines = diff(P4_4, write_model("e3.json", m))
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("not a model the fabric could build: "), lines)
        self.assertIn("e3.json", lines[0])
        self.assertIn("used by two links", lines[0])

    def test_cable_present_only_in_the_second_model(self):
        m = copy.deepcopy(BASE)
        for a, b in (((9, 20), (10, 20)), ((10, 20), (9, 20))):
            m["edges"].append({"src_dpid": a[0], "src_interface": a[1], "dst_dpid": b[0],
                               "dst_interface": b[1], "link_bandwidth_bps": 1000000000})
        lines = diff(P4_4, write_model("extra_cable.json", m))
        self.assertEqual(lines, ["s9 port 20: nothing in StaticNetworkTopologyP4_10Switches_4Hosts.json, "
                                 "s10 port 20 in extra_cable.json",
                                 "s10 port 20: nothing in StaticNetworkTopologyP4_10Switches_4Hosts.json, "
                                 "s9 port 20 in extra_cable.json"])

    def test_cable_stored_in_one_direction_only_is_a_difference(self):
        m = copy.deepcopy(BASE)
        m["edges"].remove(next(e for e in m["edges"] if (e.get("src_dpid"), e.get("src_interface"),
                                                         e.get("dst_dpid"), e.get("dst_interface")) == (5, 1, 1, 1)))
        lines = diff(P4_4, write_model("one_way.json", m))
        self.assertEqual(lines, ["s1 port 1 -> s5 port 1: stored in one direction only in one_way.json"])
        # and the same file as the FIRST argument names the first side
        self.assertEqual(diff(write_model("one_way.json", m), P4_4),
                         ["s1 port 1 -> s5 port 1: stored in one direction only in one_way.json"])

    def test_cable_stored_one_way_in_both_models_is_the_same(self):
        m = copy.deepcopy(BASE)
        m["edges"].remove(next(e for e in m["edges"] if (e.get("src_dpid"), e.get("src_interface"),
                                                         e.get("dst_dpid"), e.get("dst_interface")) == (5, 1, 1, 1)))
        self.assertEqual(diff(write_model("one_way_a.json", m), write_model("one_way_b.json", m)), [])


class Switches(unittest.TestCase):
    def test_switch_name_is_compared(self):
        m = copy.deepcopy(BASE)
        node(m, dpid=2)["device_name"] = "edge2"
        self.assertEqual(diff(P4_4, write_model("sw_name.json", m)),
                         [f"s2: name s2 in {P4_4_NAME}, edge2 in sw_name.json"])

    def test_bridge_name_swap_between_two_switches_is_a_difference(self):
        m = copy.deepcopy(BASE)
        node(m, dpid=3)["bridge_name"], node(m, dpid=9)["bridge_name"] = "s9", "s3"
        self.assertEqual(diff(P4_4, write_model("bridge_swap.json", m)),
                         [f"s3: bridge name s3 in {P4_4_NAME}, s9 in bridge_swap.json",
                          f"s9: bridge name s9 in {P4_4_NAME}, s3 in bridge_swap.json"])

    def test_switch_agent_address_is_compared(self):
        m = copy.deepcopy(BASE)
        node(m, dpid=3)["ip"] = ["192.168.123.99"]
        self.assertEqual(diff(P4_4, write_model("sw_ip.json", m)),
                         [f"s3: ip 192.168.123.13 in {P4_4_NAME}, 192.168.123.99 in sw_ip.json"])

    def test_bridge_name_left_out_is_the_name_the_fabric_gives_not_a_difference(self):
        m = copy.deepcopy(BASE)
        for n in m["nodes"]:
            if n.get("vertex_type") == T.SWITCH:
                del n["bridge_name"]
        self.assertEqual(diff(P4_4, write_model("no_bridge_names.json", m)), [])

    def _without_s10(self):
        m = copy.deepcopy(BASE)
        m["nodes"] = [n for n in m["nodes"] if n.get("dpid") != 10]
        m["edges"] = [e for e in m["edges"] if 10 not in (e.get("src_dpid"), e.get("dst_dpid"))]
        return write_model("no_s10.json", m)

    def test_switch_present_only_in_the_first_model(self):
        lines = diff(P4_4, self._without_s10(), limit=50)
        self.assertIn(f"s10: only in {P4_4_NAME}", lines)

    def test_switch_present_only_in_the_second_model(self):
        lines = diff(self._without_s10(), P4_4, limit=50)
        self.assertIn(f"s10: only in {P4_4_NAME}", lines)
        self.assertNotIn("s10: only in no_s10.json", lines)


class Hosts(unittest.TestCase):
    def test_host_named_another_way(self):
        m = copy.deepcopy(BASE)
        node(m, ip=["10.0.0.4"])["device_name"] = "hz"
        self.assertEqual(diff(P4_4, write_model("e2.json", m)),
                         [f"host 10.0.0.4: named h4 in {P4_4_NAME}, hz in e2.json"])

    def test_host_on_another_switch_port(self):
        m = copy.deepcopy(BASE)
        for e in m["edges"]:
            if e.get("src_ip") == ["10.0.0.4"]:
                e["dst_interface"] += 7
            elif e.get("dst_ip") == ["10.0.0.4"]:
                e["src_interface"] += 7
        lines = diff(P4_4, write_model("moved.json", m))
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("host 10.0.0.4: on s4 port 3 in "), lines)

    def test_host_mac_is_compared(self):
        m = copy.deepcopy(BASE)
        node(m, ip=["10.0.0.4"])["mac"] = 99
        self.assertEqual(diff(P4_4, write_model("mac.json", m)),
                         [f"host 10.0.0.4: MAC 00:00:00:00:00:04 in {P4_4_NAME}, 00:00:00:00:00:63 in mac.json"])

    def test_host_present_only_in_the_second_model(self):
        m = copy.deepcopy(BASE)
        m["nodes"].append({"vertex_type": 1, "dpid": 0, "device_name": "h9", "ip": ["10.0.0.9"], "mac": 9})
        ip, sip = ["10.0.0.9"], ["192.168.123.11"]
        m["edges"].append({"src_dpid": 0, "src_interface": 1, "src_ip": ip, "dst_dpid": 1,
                           "dst_interface": 20, "dst_ip": sip})
        m["edges"].append({"src_dpid": 1, "src_interface": 20, "src_ip": sip, "dst_dpid": 0,
                           "dst_interface": 1, "dst_ip": ip})
        self.assertEqual(diff(P4_4, write_model("extra_host.json", m)),
                         ["host 10.0.0.9: only in extra_host.json"])


class Shipped(unittest.TestCase):
    def test_ovs_4_differs_from_p4_4_only_in_brand(self):
        self.assertEqual(diff(P4_4, OVS_4),
                         [f"s1..s10: brand BMv2 in {P4_4_NAME}, OVS in StaticNetworkTopologyOVS_10Switches_4Hosts.json"])

    def test_mininet_128_differs_from_p4_128_only_in_brand(self):
        self.assertEqual(diff(P4_128, MN_128),
                         ["s1..s10: brand BMv2 in StaticNetworkTopologyP4_10Switches_128Hosts.json, "
                          "OVS in StaticNetworkTopologyMininet_10Switches.json"])

    def test_a_different_size_is_cut_at_the_limit_with_the_rest_counted(self):
        lines = diff(P4_4, P4_128)
        self.assertEqual(len(lines), 6)
        self.assertTrue(lines[-1].startswith("(+") and lines[-1].endswith(" more)"), lines)


class Unreadable(unittest.TestCase):
    def test_text_that_is_not_json_is_named_not_a_traceback(self):
        lines = diff(P4_4, write_text("junk.json", "{ this is not json"))
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("not a model the fabric could build: "), lines)
        self.assertIn("junk.json", lines[0])

    def test_json_that_is_not_a_model_is_named_not_a_traceback(self):
        lines = diff(P4_4, write_model("a_string.json", "not a model"))
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("not a model the fabric could build: "), lines)


def cli(*args, env=None):
    r = subprocess.run([sys.executable, "-I", "-B", MODFILE, *args], capture_output=True, text=True, env=env)
    return r.returncode, r.stdout, r.stderr


class CommandLine(unittest.TestCase):
    """The two questions `ndt` asks through `python3 -I -B topo_from_json.py`."""

    def test_fabric_model_names_the_model_a_4_host_fabric_is_built_from(self):
        rc, out, _ = cli("fabric-model", SETTING, "4")
        self.assertEqual((rc, out.strip()), (0, P4_4))

    def test_fabric_model_answers_rc_0_and_nothing_for_a_size_no_model_has(self):
        self.assertEqual(cli("fabric-model", SETTING, "7")[:2], (0, ""))

    def test_fabric_model_does_not_read_the_callers_ndtwin_p4_topo_file(self):
        rc, out, _ = cli("fabric-model", SETTING, "4", env={**os.environ, "NDTWIN_P4_TOPO_FILE": P4_128})
        self.assertEqual((rc, out.strip()), (0, P4_4))

    def test_diff_says_rc_1_and_where_for_a_different_network(self):
        m = copy.deepcopy(BASE)
        for e in cable_edges(m, (1, 1), (5, 1)):
            m["edges"].remove(e)
        rc, out, _ = cli("diff", P4_4, write_model("cli_e1.json", m))
        self.assertEqual(rc, 1)
        self.assertTrue(out.startswith("s1 port 1: "), out)

    def test_diff_says_rc_0_and_nothing_for_the_same_network(self):
        self.assertEqual(cli("diff", P4_4, write_model("cli_copy.json", copy.deepcopy(BASE)))[:2], (0, ""))

    def test_anything_else_is_rc_2(self):
        rc, out, err = cli("diff", P4_4)
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("usage", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
