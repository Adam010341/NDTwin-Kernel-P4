"""Tests for tools/make_topology.py, the OVS topology-model generator.

[Co-developed with claude code -- Adam]

The generator exists to give the all-pairs walk sweep its intermediate scales (8/16/32/64
hosts), because two points cannot separate the walk's linear half from its quadratic one.

What makes this worth testing rather than eyeballing: a wrong port number produces a model that
parses, loads, passes every topology view, and black-holes traffic. That is the 2026-08-17
failure exactly -- Ryu installed `nw_dst=10.0.0.2 actions=output:4` on an s1 with no port 4,
every host pair was 100% loss, and both Ryu's view and the kernel's graph reported ten
switches, forty edges, all up. So the assertions here are about agreement between the model's
two consumers, not about the file parsing.

`make_topology.check()` already round-trips against the two shipped models on every run, and
`main()` refuses to write when it fails. These tests cover the parts that check does not: that
`validate()` actually rejects the malformed models it claims to, and that generated models
satisfy both consumers.

Needs networkx: run under p4_proxy/venv/bin/python3.
"""

from __future__ import annotations

import copy
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(__file__)
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "p4_proxy", "mininet"))

import topo_from_json as T  # the fabric builder, the model's other consumer

_spec = importlib.util.spec_from_file_location(
    "make_topology", os.path.join(REPO, "tools", "make_topology.py"))
M = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(M)

#: The sizes the sweep needs. 4 and 128 ship; these are generated.
GENERATED = (8, 16, 32, 64)


def fabric():
    return M.fabric_from(M.KNOWN[128])


def model(hosts):
    nodes, edges = fabric()
    return M.build(hosts, nodes, edges)


class RoundTrip(unittest.TestCase):
    """The generator reproduces both shipped models. This is the whole licence to trust it."""

    def test_check_passes(self):
        self.assertTrue(M.check(verbose=False))

    def test_each_shipped_model_is_reproduced_from_the_other(self):
        for hosts, path in M.KNOWN.items():
            with self.subTest(hosts=hosts):
                other = M.KNOWN[next(h for h in M.KNOWN if h != hosts)]
                nodes, edges = M.fabric_from(other)
                self.assertTrue(M.same(M.build(hosts, nodes, edges), M.load(path)))

    def test_the_two_shipped_fabrics_are_identical(self):
        """The premise of copying the fabric instead of generating it."""
        a, b = M.fabric_from(M.KNOWN[4]), M.fabric_from(M.KNOWN[128])
        self.assertEqual(a, b)


class HostCountGuard(unittest.TestCase):
    """Hosts split over s1..s4, so the count must divide by four -- same rule as ndt's."""

    def test_rejects_non_multiples_of_four(self):
        for n in (1, 2, 3, 5, 6, 7, 9, 30, 127):
            with self.subTest(n=n), self.assertRaises(ValueError):
                model(n)

    def test_rejects_zero_and_negative(self):
        for n in (0, -4):
            with self.subTest(n=n), self.assertRaises(ValueError):
                model(n)

    def test_accepts_every_size_the_sweep_needs(self):
        for n in GENERATED:
            with self.subTest(n=n):
                self.assertEqual(len([x for x in model(n)["nodes"]
                                      if x.get("vertex_type") == M.HOST]), n)


class Layout(unittest.TestCase):
    """The conventions read off the shipped models."""

    def test_hosts_only_on_the_edge_switches(self):
        attached = {e["src_dpid"] for e in model(32)["edges"] if e.get("dst_dpid") == 0}
        self.assertEqual(attached, set(M.EDGE_SWITCHES))

    def test_hosts_split_evenly(self):
        counts = {}
        for e in model(32)["edges"]:
            if e.get("dst_dpid") == 0:
                counts[e["src_dpid"]] = counts.get(e["src_dpid"], 0) + 1
        self.assertEqual(set(counts.values()), {8})

    def test_host_ports_start_above_the_uplinks(self):
        ports = {e["src_interface"] for e in model(16)["edges"] if e.get("dst_dpid") == 0}
        self.assertEqual(min(ports), M.FIRST_HOST_PORT)
        self.assertEqual(ports, set(range(3, 3 + 4)))

    def test_addresses_follow_the_host_number(self):
        hosts = [n for n in model(16)["nodes"] if n.get("vertex_type") == M.HOST]
        for i, n in enumerate(hosts, start=1):
            self.assertEqual(n["device_name"], f"h{i}")
            self.assertEqual(n["ip"], [f"10.0.0.{i}"])
            self.assertEqual(n["mac"], i)

    def test_switch_fabric_is_passed_through_untouched(self):
        nodes, edges = fabric()
        built = model(64)
        self.assertEqual([n for n in built["nodes"] if n.get("vertex_type") == M.SWITCH], nodes)
        self.assertEqual([e for e in built["edges"]
                          if e.get("src_dpid") and e.get("dst_dpid")], edges)


class ValidateRejects(unittest.TestCase):
    """`validate` is the guard; every branch of it must actually fire.

    Each case corrupts a *valid* model in one way and asserts the guard notices. Without these
    the guard could be vacuous and every generated model would still look fine.
    """

    def corrupt(self, hosts, fn):
        m = copy.deepcopy(model(hosts))
        fn(m)
        with self.assertRaises(AssertionError):
            M.validate(m, hosts)

    def test_accepts_a_clean_model(self):
        for n in GENERATED:
            with self.subTest(n=n):
                M.validate(model(n), n)  # must not raise

    def test_duplicate_ip(self):
        def dup(m):
            hosts = [n for n in m["nodes"] if n.get("vertex_type") == M.HOST]
            hosts[1]["ip"] = list(hosts[0]["ip"])
        self.corrupt(8, dup)

    def test_duplicate_mac(self):
        def dup(m):
            hosts = [n for n in m["nodes"] if n.get("vertex_type") == M.HOST]
            hosts[1]["mac"] = hosts[0]["mac"]
        self.corrupt(8, dup)

    def test_wrong_host_count(self):
        def drop(m):
            for i, n in enumerate(m["nodes"]):
                if n.get("vertex_type") == M.HOST:
                    del m["nodes"][i]
                    return
        self.corrupt(8, drop)

    def test_port_collision_between_two_hosts(self):
        """The 2026-08-17 shape: two hosts told to use one switch port."""
        def collide(m):
            downs = [e for e in m["edges"] if e.get("dst_dpid") == 0]
            a, b = downs[0], downs[1]
            b["src_dpid"], b["src_interface"] = a["src_dpid"], a["src_interface"]
        self.corrupt(8, collide)

    def test_host_port_collides_with_an_uplink(self):
        def collide(m):
            for e in m["edges"]:
                if e.get("dst_dpid") == 0:
                    e["src_interface"] = 1  # an uplink port
                    return
        self.corrupt(8, collide)

    def test_direction_pair_disagrees_on_the_port(self):
        def skew(m):
            for e in m["edges"]:
                if e.get("dst_dpid") == 0:
                    e["src_interface"] += 50
                    return
        self.corrupt(8, skew)

    def test_host_attached_to_two_switches(self):
        def move(m):
            for e in m["edges"]:
                if e.get("src_dpid") == 0:
                    e["dst_dpid"] = 4 if e["dst_dpid"] != 4 else 3
                    return
        self.corrupt(8, move)

    def test_missing_downlink(self):
        def drop(m):
            for i, e in enumerate(m["edges"]):
                if e.get("dst_dpid") == 0:
                    del m["edges"][i]
                    return
        self.corrupt(8, drop)


class BothConsumersAgree(unittest.TestCase):
    """The property the 2026-08-17 failure violated: fabric and router describe one network."""

    def test_fabric_builder_loads_every_generated_size(self):
        for n in GENERATED:
            with self.subTest(hosts=n):
                m = model(n)
                self.assertEqual(len(T.hosts(m)), n)
                self.assertEqual(len(T.switches(m)), 10)
                self.assertEqual(len(T.switch_links(m)), 16)
                self.assertEqual(len(T.host_links(m)), n)

    def test_every_host_attaches_exactly_once(self):
        """topo_from_json raises TopologyModelError if a host appears on two ports."""
        for n in GENERATED:
            with self.subTest(hosts=n):
                names = [name for name, _d, _p in T.host_links(model(n))]
                self.assertEqual(len(names), len(set(names)))

    def test_fabric_ports_match_the_model(self):
        for n in GENERATED:
            with self.subTest(hosts=n):
                m = model(n)
                from_fabric = {(name, d, p) for name, d, p in T.host_links(m)}
                from_model = set()
                by_ip = {ip: name for name, ip, _mac in T.hosts(m)}
                for e in m["edges"]:
                    if e.get("dst_dpid") == 0:
                        from_model.add(
                            (by_ip[e["dst_ip"][0]], e["src_dpid"], e["src_interface"]))
                self.assertEqual(from_fabric, from_model)


class ShippedSizesAreNotOverwritten(unittest.TestCase):
    def test_known_sizes_are_the_shipped_files(self):
        """4 and 128 must resolve to the files already in setting/, not to new ones."""
        for hosts, path in M.KNOWN.items():
            with self.subTest(hosts=hosts):
                self.assertTrue(os.path.exists(path), f"{path} is gone; KNOWN is stale")


if __name__ == "__main__":
    unittest.main(verbosity=2)
