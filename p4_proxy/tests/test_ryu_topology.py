"""
Tests for the Ryu-shaped topology renderer.

[Co-developed with claude code -- Adam]

The kernel parses these payloads in TopologyAndFlowMonitor, and every field it reads has a
required *type* as well as a name. Two of those cost real debugging time and are pinned here:

  - dpid and port_no must be **hex strings**. The kernel uses `stoull(s, nullptr, 16)` and
    `portStringToUint` (also base 16), so emitting decimal makes dpid 10 read as 16 -- the parse
    succeeds, so nothing complains.
  - mac must be a **string**. `utils::macToUint64(host["mac"])` throws `json::type_error` on a
    number, which is not a `parse_error`, so it escaped `updateHosts` and aborted the whole
    kernel. Observed: serving `"mac": 1` killed the process. The shipped topology files store
    MACs as integers, so this is a real case.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import networkx as nx
    from proxy_agent import ryu_topology as rt
    HAVE_DEPS = True
except ImportError:
    HAVE_DEPS = False


def a_net(switches=(1, 5), links=((1, 5, 1, 2),), hosts=()):
    """
    A graph shaped the way TopologyManager builds one.

    `links` are (src_dpid, dst_dpid, src_port, dst_port); `hosts` are (ip, mac, dpid, port).
    Both directions are added for links, mirroring TopologyManager.add_link.
    """
    net = nx.DiGraph()
    for d in switches:
        net.add_node(d, type="switch")
    for src, dst, sp, dp in links:
        net.add_edge(src, dst, port=sp)
        net.add_edge(dst, src, port=dp)
    for ip, mac, dpid, port in hosts:
        net.add_node(ip, type="host", mac=mac)
        net.add_edge(dpid, ip, port=port)
        net.add_edge(ip, dpid, port=0)
    return net


@unittest.skipUnless(HAVE_DEPS, "networkx not available in this interpreter")
class SwitchesTest(unittest.TestCase):
    def test_dpid_is_a_16_digit_hex_string(self):
        # dpid 10 must be "…0a", not "10": the kernel parses base 16, so decimal reads as 16.
        out = rt.render_switches([1, 10])
        self.assertEqual([s["dpid"] for s in out],
                         ["0000000000000001", "000000000000000a"])

    def test_only_the_given_switches_are_listed(self):
        # Fed from the sessions the proxy actually holds, so an unreachable switch is absent
        # and the kernel does not mark it enabled.
        self.assertEqual(len(rt.render_switches([1, 2, 3])), 3)
        self.assertEqual(rt.render_switches([]), [])

    def test_output_is_sorted_so_captures_are_diffable(self):
        self.assertEqual([s["dpid"] for s in rt.render_switches([3, 1, 2])],
                         [f"{d:016x}" for d in (1, 2, 3)])


@unittest.skipUnless(HAVE_DEPS, "networkx not available in this interpreter")
class LinksTest(unittest.TestCase):
    def test_reports_both_directions(self):
        # updateLinks enables the edge keyed on (src dpid, src port), so a single direction
        # would leave half the edges disabled.
        out = rt.render_links(a_net(links=((1, 5, 1, 2),)))
        self.assertEqual(len(out), 2)
        pairs = {(l["src"]["dpid"], l["dst"]["dpid"]) for l in out}
        self.assertEqual(pairs, {(f"{1:016x}", f"{5:016x}"), (f"{5:016x}", f"{1:016x}")})

    def test_each_direction_carries_its_own_port(self):
        # The reverse edge holds the far end's port; mixing them up sends traffic to the wrong
        # interface while looking structurally correct.
        out = rt.render_links(a_net(links=((1, 5, 7, 9),)))
        forward = next(l for l in out if l["src"]["dpid"].endswith("1"))
        self.assertEqual(forward["src"]["port_no"], f"{7:08x}")
        self.assertEqual(forward["dst"]["port_no"], f"{9:08x}")

    def test_host_links_are_excluded(self):
        # Ryu reports host attachment through /hosts. Including it here would make the kernel
        # look for a switch vertex whose dpid is a host IP.
        net = a_net(switches=(1,), links=(), hosts=(("10.0.0.1", "00:00:00:00:00:01", 1, 3),))
        self.assertEqual(rt.render_links(net), [])

    def test_no_links_yields_an_empty_list_not_an_error(self):
        self.assertEqual(rt.render_links(a_net(switches=(1, 2), links=())), [])


@unittest.skipUnless(HAVE_DEPS, "networkx not available in this interpreter")
class HostsTest(unittest.TestCase):
    def test_an_integer_mac_is_rendered_as_a_string(self):
        # This exact case aborted the kernel: json::type_error escaped updateHosts.
        net = a_net(switches=(1,), links=(), hosts=(("10.0.0.1", 1, 1, 3),))
        out = rt.render_hosts(net)
        self.assertEqual(out[0]["mac"], "00:00:00:00:00:01")
        self.assertIsInstance(out[0]["mac"], str)

    def test_a_string_mac_is_passed_through_unchanged(self):
        net = a_net(switches=(1,), links=(), hosts=(("10.0.0.2", "aa:bb:cc:dd:ee:ff", 1, 4),))
        self.assertEqual(rt.render_hosts(net)[0]["mac"], "aa:bb:cc:dd:ee:ff")

    def test_ipv4_is_a_non_empty_list(self):
        # updateHosts skips any host whose ipv4 list is empty, before it looks at anything else.
        net = a_net(switches=(1,), links=(), hosts=(("10.0.0.1", 1, 1, 3),))
        self.assertEqual(rt.render_hosts(net)[0]["ipv4"], ["10.0.0.1"])

    def test_port_identifies_the_attachment_switch_and_port(self):
        net = a_net(switches=(1,), links=(), hosts=(("10.0.0.1", 1, 1, 6),))
        port = rt.render_hosts(net)[0]["port"]
        self.assertEqual(port["dpid"], f"{1:016x}")
        self.assertEqual(port["port_no"], f"{6:08x}")

    def test_a_host_with_no_mac_is_skipped(self):
        # The kernel matches the vertex by MAC, so the entry would be inert anyway -- better to
        # omit it than to have the kernel warn about a host it cannot place.
        net = nx.DiGraph()
        net.add_node(1, type="switch")
        net.add_node("10.0.0.9", type="host")  # no mac attribute
        net.add_edge(1, "10.0.0.9", port=3)
        self.assertEqual(rt.render_hosts(net), [])

    def test_a_host_not_attached_to_a_switch_is_skipped(self):
        net = nx.DiGraph()
        net.add_node("10.0.0.9", type="host", mac="00:00:00:00:00:09")
        self.assertEqual(rt.render_hosts(net), [])

    def test_switches_are_not_reported_as_hosts(self):
        self.assertEqual(rt.render_hosts(a_net()), [])


@unittest.skipUnless(HAVE_DEPS, "networkx not available in this interpreter")
class DestinationPathsTest(unittest.TestCase):
    """
    setAllPaths reads `path.front()` as the source IP, `path.back()` as the destination, and
    computes switchCount as `size - 2`. All three depend on the exact shape, and the kernel
    discriminates host from switch by JSON *type* -- string vs number.
    """

    def a_three_switch_net(self):
        net = nx.DiGraph()
        for d in (1, 6, 4):
            net.add_node(d, type="switch")
        for a, b, pa, pb in ((1, 6, 1, 1), (6, 4, 2, 2)):
            net.add_edge(a, b, port=pa)
            net.add_edge(b, a, port=pb)
        for ip, dp, p in (("10.0.0.1", 1, 3), ("10.0.0.4", 4, 7)):
            net.add_node(ip, type="host", mac="00:00:00:00:00:01")
            net.add_edge(dp, ip, port=p)
            net.add_edge(ip, dp, port=0)
        return net

    def paths(self, net):
        return rt.render_destination_paths(net)["all_destination_paths"]

    def test_the_status_envelope_is_present(self):
        # The kernel refuses the body outright when status is missing or not "success".
        out = rt.render_destination_paths(self.a_three_switch_net())
        self.assertEqual(out["status"], "success")
        self.assertIn("all_destination_paths", out)

    def test_endpoints_are_host_ip_strings_and_middle_hops_are_numeric_dpids(self):
        # The kernel routes a string through ipStringToUint32 and a number through
        # get<uint64_t>(), so the types decide whether a hop is read as a host or a switch.
        path = next(p for p in self.paths(self.a_three_switch_net())
                    if p[0][0] == "10.0.0.1")
        self.assertIsInstance(path[0][0], str)
        self.assertIsInstance(path[-1][0], str)
        for hop, _ in path[1:-1]:
            self.assertIsInstance(hop, int)

    def test_switch_count_is_size_minus_two(self):
        path = next(p for p in self.paths(self.a_three_switch_net())
                    if p[0][0] == "10.0.0.1")
        self.assertEqual(len(path) - 2, 3, "three switches between the two hosts")

    def test_the_source_hop_carries_the_ingress_port(self):
        # Asymmetric on purpose: intelligent_router.py emits the port on the *first switch*
        # facing the host here, not an egress port like every other hop.
        path = next(p for p in self.paths(self.a_three_switch_net())
                    if p[0][0] == "10.0.0.1")
        self.assertEqual(path[0][1], 3, "s1's port towards h1")

    def test_the_final_hop_has_port_zero(self):
        path = next(p for p in self.paths(self.a_three_switch_net())
                    if p[0][0] == "10.0.0.1")
        self.assertEqual(path[-1][1], 0, "there is no next hop to leave by")

    def test_both_directions_are_emitted(self):
        paths = self.paths(self.a_three_switch_net())
        self.assertEqual(len(paths), 2)
        self.assertEqual({p[0][0] for p in paths}, {"10.0.0.1", "10.0.0.4"})

    def test_unreachable_pairs_are_skipped_rather_than_raising(self):
        # Normal while discovery is still converging.
        net = nx.DiGraph()
        for ip, dp in (("10.0.0.1", 1), ("10.0.0.9", 9)):
            net.add_node(dp, type="switch")
            net.add_node(ip, type="host", mac="00:00:00:00:00:01")
            net.add_edge(dp, ip, port=3)
            net.add_edge(ip, dp, port=0)
        # s1 and s9 are not linked, so neither host can reach the other.
        self.assertEqual(self.paths(net), [])

    def test_a_topology_with_no_hosts_yields_no_paths(self):
        net = nx.DiGraph()
        net.add_node(1, type="switch")
        self.assertEqual(self.paths(net), [])


@unittest.skipUnless(HAVE_DEPS, "networkx not available in this interpreter")
class ShippedTopologyTest(unittest.TestCase):
    """
    Renders the real P4 topology file and checks the counts the kernel should see.

    Measured against a live kernel with these payloads: switches 0/10 -> 10/10 enabled,
    hosts 4/4, edges 0/40 -> 40/40 up and enabled.
    """

    TOPO = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "..", "setting",
                        "StaticNetworkTopologyP4_10Switches_4Hosts.json")

    def setUp(self):
        if not os.path.exists(self.TOPO):
            self.skipTest("shipped P4 topology not found")
        import json
        with open(self.TOPO) as fh:
            self.topo = json.load(fh)

    def build(self):
        switches = {n["dpid"] for n in self.topo["nodes"] if n.get("vertex_type") == 0}
        net = nx.DiGraph()
        for d in switches:
            net.add_node(d, type="switch")
        hosts_by_ip = {}
        for n in self.topo["nodes"]:
            if n.get("vertex_type") == 1:
                hosts_by_ip[n["ip"][0]] = n["mac"]
                net.add_node(n["ip"][0], type="host", mac=n["mac"])
        for e in self.topo["edges"]:
            s, d = e["src_dpid"], e["dst_dpid"]
            if s in switches and d in switches and s and d:
                net.add_edge(s, d, port=e["src_interface"])
            elif s in switches and d == 0:
                ip = e["dst_ip"][0]
                if ip in hosts_by_ip:
                    net.add_edge(s, ip, port=e["src_interface"])
                    net.add_edge(ip, s, port=0)
        return switches, net

    def test_counts_match_the_topology_file(self):
        switches, net = self.build()
        self.assertEqual(len(rt.render_switches(switches)), 10)
        self.assertEqual(len(rt.render_links(net)), 32, "inter-switch directed edges")
        self.assertEqual(len(rt.render_hosts(net)), 4)

    def test_every_mac_renders_as_a_string(self):
        # The shipped file stores them as integers, which is what aborted the kernel.
        _, net = self.build()
        for host in rt.render_hosts(net):
            self.assertIsInstance(host["mac"], str)
            self.assertEqual(len(host["mac"].split(":")), 6)


class InstalledRoutesDecideWhatIsAdvertisedTest(unittest.TestCase):
    """
    A path may only be advertised if the switches have actually been told to use it.

    [Co-developed with claude code -- Adam]
    Measured on 2026-08-10: a mid-path link was broken, the proxy recomputed a route around it and
    kept advertising all twelve destination paths, and 38% of the packets were dropped, because
    nothing had reinstalled the rules. Every endpoint stayed green while the ping was dead. These
    tests pin the property that failure violated -- what is advertised must be what is installed --
    and they are written against that requirement, not against the walk that now implements it.
    """

    def a_line_net(self):
        """
        h1 - s1 - s6 - s4 - h4, plus a *shorter* direct s1 - s4 link and a spare s1 - s9 - s4.

        Neither alternative is ever installed. The direct link is deliberately shorter than the
        installed route, so "advertise what is installed" and "advertise the shortest path" give
        different answers and a test can tell them apart.
        """
        net = nx.DiGraph()
        for dp in (1, 6, 4, 9):
            net.add_node(dp, type="switch")
        for a, b, pa, pb in ((1, 6, 1, 1), (6, 4, 2, 2), (1, 9, 4, 4), (9, 4, 5, 5),
                             (1, 4, 5, 6)):
            net.add_edge(a, b, port=pa)
            net.add_edge(b, a, port=pb)
        for ip, dp, p in (("10.0.0.1", 1, 3), ("10.0.0.4", 4, 7)):
            net.add_node(ip, type="host", mac="00:00:00:00:00:01")
            net.add_edge(dp, ip, port=p)
            net.add_edge(ip, dp, port=0)
        return net

    def routes_along_s6(self):
        """The rules as installed at discovery: everything to 10.0.0.4 goes via s6."""
        return {
            (1, "10.0.0.4"): 1,   # s1 -> s6
            (6, "10.0.0.4"): 2,   # s6 -> s4
            (4, "10.0.0.4"): 7,   # s4 -> h4
            (4, "10.0.0.1"): 2,   # s4 -> s6
            (6, "10.0.0.1"): 1,   # s6 -> s1
            (1, "10.0.0.1"): 3,   # s1 -> h1
        }

    def pair(self, out, src, dst):
        for path in out["all_destination_paths"]:
            if path[0][0] == src and path[-1][0] == dst:
                return [hop[0] for hop in path]
        return None

    def test_the_advertised_path_is_the_installed_one_not_the_shortest_one(self):
        # The direct s1 - s4 link is shorter, and no switch has ever been told to use it.
        net = self.a_line_net()
        out = rt.render_destination_paths(net, (), self.routes_along_s6())
        self.assertEqual(self.pair(out, "10.0.0.1", "10.0.0.4"),
                         ["10.0.0.1", 1, 6, 4, "10.0.0.4"])

    def test_a_pair_whose_installed_route_crosses_a_failed_link_is_not_advertised(self):
        # This is the case that was being reported as healthy while packets were dropped.
        net = self.a_line_net()
        out = rt.render_destination_paths(net, [(1, 1)], self.routes_along_s6())
        self.assertIsNone(self.pair(out, "10.0.0.1", "10.0.0.4"))

    def test_it_does_not_substitute_any_route_that_was_never_installed(self):
        # The tempting wrong fix: notice the break, find another way through, advertise that. The
        # switches still send everything out port 1, so every such path is fiction. Nothing
        # advertised may use the direct s1-s4 link or s9, neither of which was ever installed.
        net = self.a_line_net()
        out = rt.render_destination_paths(net, [(1, 1)], self.routes_along_s6())
        self.assertIsNone(self.pair(out, "10.0.0.1", "10.0.0.4"))
        for path in out["all_destination_paths"]:
            self.assertNotIn(9, [hop[0] for hop in path])

    def test_a_one_way_failure_withdraws_only_the_direction_that_broke(self):
        # down_endpoints is keyed on the *source* endpoint, so (1, 1) is s1->s6 and says nothing
        # about s6->s1. The reverse route still works and withdrawing it would be a false report.
        net = self.a_line_net()
        out = rt.render_destination_paths(net, [(1, 1)], self.routes_along_s6())
        self.assertIsNone(self.pair(out, "10.0.0.1", "10.0.0.4"))
        self.assertEqual(self.pair(out, "10.0.0.4", "10.0.0.1"),
                         ["10.0.0.4", 4, 6, 1, "10.0.0.1"])

    def test_both_directions_go_when_both_directions_of_the_link_fail(self):
        net = self.a_line_net()
        out = rt.render_destination_paths(net, [(1, 1), (6, 1)], self.routes_along_s6())
        self.assertIsNone(self.pair(out, "10.0.0.1", "10.0.0.4"))
        self.assertIsNone(self.pair(out, "10.0.0.4", "10.0.0.1"))

    def test_a_switch_with_no_rule_for_a_destination_yields_no_path(self):
        routes = self.routes_along_s6()
        del routes[(6, "10.0.0.4")]
        out = rt.render_destination_paths(self.a_line_net(), (), routes)
        self.assertIsNone(self.pair(out, "10.0.0.1", "10.0.0.4"))

    def test_rules_pointing_in_a_circle_terminate_instead_of_hanging(self):
        # A reply thread that never returns is worse than a missing path.
        net = self.a_line_net()
        routes = self.routes_along_s6()
        routes[(6, "10.0.0.4")] = 1   # s6 sends it back to s1
        out = rt.render_destination_paths(net, (), routes)
        self.assertIsNone(self.pair(out, "10.0.0.1", "10.0.0.4"))

    def test_omitting_installed_keeps_the_old_shortest_path_behaviour(self):
        # The parameter is opt-in so existing callers are unaffected.
        out = rt.render_destination_paths(self.a_line_net())
        self.assertEqual(self.pair(out, "10.0.0.1", "10.0.0.4"),
                         ["10.0.0.1", 1, 4, "10.0.0.4"])

if __name__ == "__main__":
    unittest.main(verbosity=2)
