"""
Tests for install_all_pair_paths surviving an asymmetric (half-dead) link graph.

[Co-developed with claude code -- Adam]

Live 2026-08-13 (overnight OVS round, C report Phase 3D): a unidirectional dataplane failure
(netem loss on one end only) kills LLDP in one direction, so Ryu fires exactly one
EventLinkDelete and the DiGraph is left asymmetric *permanently* -- the paired event that the
on_link_delete comment counts on never arrives. install_all_pair_paths then walked the
still-present direction and crashed at `net[current][prev]["port"]` (KeyError) looking up the
removed reverse edge. The exception aborted the whole recompute round, every OpenFlow rule
stayed stale, and the flow blackholed for 291 s (zero self-heal) while the twin reported it
healthy. The same crash fired once during normal startup LLDP jitter (KeyError: 1 in ryu.log),
so the asymmetric state is reachable without any injected fault.

The fix makes BFS walk a link only when both directed edges exist: the switch behind the
half-dead link is then reached through any healthy neighbor and traffic routes around the dead
direction; if no healthy path exists, that switch alone goes unrouted for the round instead of
the round dying.

## Why the methods are extracted rather than imported

Same reason as test_route_reinstall.py: importing intelligent_router pulls in Ryu, which only
exists in a separate conda env. The methods under test are read out of the real file by AST and
executed here, so this tests the shipped source, not a copy.

## Why the graph is a stub rather than networkx

Everything in tests/python runs under plain `python3` and may depend on nothing outside the
standard library -- l1_unit_tests.sh enforces that, and it caught this file importing networkx
on its first real run. DiGraphStub below implements only the operations the extracted code
performs, with the behaviours this test turns on stated and pinned by DiGraphStubTest: a
missing edge raises KeyError from `net[u][v]` (that KeyError is the defect), `.get` returns
None, and `has_edge` is direction-sensitive. The stub is why the mutation evidence matters
doubly here -- the mutants must still go red through it, which they do (see the commit).
"""

from __future__ import annotations

import ast
import hashlib
import logging
import os
import textwrap
import types
import unittest
from time import monotonic


class _NodeView:
    """`net.nodes`: iterable of nodes, indexable to each node's attribute dict."""

    def __init__(self, data):
        self._data = data

    def __iter__(self):
        return iter(self._data)

    def __getitem__(self, node):
        return self._data[node]

    def __contains__(self, node):
        return node in self._data


class DiGraphStub:
    """The slice of networkx.DiGraph the extracted code uses. Directed; edges carry attrs."""

    def __init__(self):
        self._succ = {}
        self._node_attrs = {}

    def add_node(self, node, **attrs):
        self._succ.setdefault(node, {})
        self._node_attrs.setdefault(node, {}).update(attrs)

    def add_edge(self, u, v, **attrs):
        self.add_node(u)
        self.add_node(v)
        self._succ[u][v] = dict(attrs)

    def remove_edge(self, u, v):
        del self._succ[u][v]

    @property
    def nodes(self):
        return _NodeView(self._node_attrs)

    # [Co-developed with claude code -- Adam]
    # Added for 957a646, which caches the host-IP index and keys the cache on
    # (id(net), number_of_nodes(), number_of_edges()) so a graph that changed shape cannot be
    # served a stale index. The stub is deliberately only the slice of networkx the extracted
    # code touches, so it grows when that code reaches for something new.
    def number_of_nodes(self):
        return len(self._node_attrs)

    def number_of_edges(self):
        return sum(len(v) for v in self._succ.values())

    def __getitem__(self, u):
        # KeyError on an unknown node, and the returned mapping raises KeyError on an unknown
        # edge -- the exact shape that aborted the recompute.
        return self._succ[u]

    def neighbors(self, u):
        return iter(self._succ[u])

    def has_edge(self, u, v):
        return v in self._succ.get(u, {})

ROUTER = os.path.join(os.path.dirname(__file__), "..", "..", "intelligent_router.py")
METHODS = (
    "install_all_pair_paths",
    "find_host_by_ip",
    "find_connected_switch",
    "get_host_port",
    "is_switch",
    "hash_dst_ip",
)


def extract_methods():
    """The methods under test, verbatim from the real file."""
    with open(ROUTER) as f:
        source = f.read()
    tree = ast.parse(source)
    found = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name in METHODS:
            found[node.name] = textwrap.dedent(ast.get_source_segment(source, node))
    missing = set(METHODS) - set(found)
    if missing:
        raise AssertionError(f"methods not found in {ROUTER}: {missing}")
    return found


class FakeParser:
    @staticmethod
    def OFPMatch(**kwargs):
        return kwargs

    @staticmethod
    def OFPActionOutput(port):
        return port


class FakeDatapath:
    ofproto_parser = FakeParser

    def __init__(self, dpid):
        self.id = dpid


def make_router(switch_ids):
    """A stand-in self carrying the real (extracted) methods plus recording fakes."""
    # Whatever the extracted methods reference at module scope has to be supplied here, because
    # exec gives them this dict as their globals rather than the real module's. `monotonic` is
    # the walk timing added 2026-08-21; leaving it out raises NameError from inside the walk,
    # which reads like a routing bug rather than like a missing stub.
    # [Co-developed with claude code -- Adam]
    namespace = {
        "hashlib": hashlib,
        "is_all_dst_biased": False,
        "monotonic": monotonic,
    }
    for name, src in extract_methods().items():
        exec(src, namespace)  # noqa: S102 - executing the shipped source is the point

    router = types.SimpleNamespace()
    router.logger = logging.getLogger("test_unidirectional_link_loss")
    router.switches = {dpid: FakeDatapath(dpid) for dpid in switch_ids}
    router.installed = []  # (dpid, dst_ip, out_port)
    router.debug_print_graph = lambda net: None
    router.add_flow = lambda datapath, priority, match, actions: router.installed.append(
        (datapath.id, match["ipv4_dst"], actions[0]))
    for name in METHODS:
        setattr(router, name, types.MethodType(namespace[name], router))
    return router


def square_net():
    """s1--s2, s1--s3, s2--s4, s3--s4 (both directions), h1 on s1, h2 on s4.

    Edge u->v carries u's egress port toward v, matching what the topology events store.
    """
    net = DiGraphStub()
    for a, b, port_a, port_b in [(1, 2, 2, 1), (1, 3, 3, 1), (2, 4, 3, 2), (3, 4, 4, 3)]:
        net.add_edge(a, b, port=port_a)
        net.add_edge(b, a, port=port_b)
    net.add_node("h1", ip_list=["10.0.0.1"])
    net.add_node("h2", ip_list=["10.0.0.2"])
    net.add_edge(1, "h1", port=9)
    net.add_edge("h1", 1, port=0)
    net.add_edge(4, "h2", port=9)
    net.add_edge("h2", 4, port=0)
    return net


def flows_for(router, dst_ip):
    return {dpid: port for dpid, ip, port in router.installed if ip == dst_ip}


class DiGraphStubTest(unittest.TestCase):
    """The stub stands in for networkx here, so the behaviours the tests turn on are pinned."""

    def test_missing_edge_raises_keyerror_and_get_returns_none(self):
        net = square_net()
        net.remove_edge(1, 2)
        with self.assertRaises(KeyError):
            _ = net[1][2]["port"]
        self.assertIsNone(net[1].get(2))
        self.assertEqual(net[2][1]["port"], 1, "the reverse edge must be untouched")

    def test_has_edge_is_direction_sensitive(self):
        net = square_net()
        net.remove_edge(1, 2)
        self.assertFalse(net.has_edge(1, 2))
        self.assertTrue(net.has_edge(2, 1))
        self.assertFalse(net.has_edge(1, 99), "an unknown node is not an edge, not an error")

    def test_neighbours_are_successors_only(self):
        net = square_net()
        net.remove_edge(1, 2)
        self.assertEqual(sorted(str(n) for n in net.neighbors(1)), ["3", "h1"])
        self.assertIn(1, list(net.neighbors(2)), "2 -> 1 survives the one-way removal")


class SymmetricBaselineTest(unittest.TestCase):
    def test_all_switches_routed_on_healthy_graph(self):
        router = make_router([1, 2, 3, 4])
        router.install_all_pair_paths(square_net())
        for dst_ip in ("10.0.0.1", "10.0.0.2"):
            self.assertEqual(set(flows_for(router, dst_ip)), {1, 2, 3, 4},
                             f"every switch should hold a rule toward {dst_ip}")
        # s1's rule toward h2 exits via a real uplink, s4's via its host port.
        self.assertIn(flows_for(router, "10.0.0.2")[1], (2, 3))
        self.assertEqual(flows_for(router, "10.0.0.2")[4], 9)


class UnidirectionalLossTest(unittest.TestCase):
    """The live failure shape: one direction of one link removed, the reverse kept."""

    def test_reroutes_around_the_dead_direction(self):
        net = square_net()
        net.remove_edge(1, 2)  # LLDP s1->s2 died; s2->s1 survived (asymmetric steady state)
        router = make_router([1, 2, 3, 4])
        router.install_all_pair_paths(net)  # the old code raised KeyError here

        toward_h2 = flows_for(router, "10.0.0.2")
        self.assertEqual(set(toward_h2), {1, 2, 3, 4},
                         "the round must still route every switch")
        self.assertEqual(toward_h2[1], 3,
                         "s1 must send toward s3, around the dead s1->s2 direction")
        self.assertTrue(hasattr(router, "all_destination_paths"),
                        "the recompute must reach its final report")
        h1_paths = [p for p in router.all_destination_paths
                    if p and p[0][0] == "10.0.0.1" and p[-1] != ("10.0.0.1", 0)]
        self.assertTrue(any((1, 3) in path for path in h1_paths),
                        f"h1's reported path must detour via s3, got {h1_paths}")

    def test_isolated_switch_costs_only_that_switch(self):
        # Startup-jitter shape: both of s1's outgoing LLDP directions missing at once.
        net = square_net()
        net.remove_edge(1, 2)
        net.remove_edge(1, 3)
        router = make_router([1, 2, 3, 4])
        router.install_all_pair_paths(net)  # the old code raised KeyError here too

        toward_h2 = flows_for(router, "10.0.0.2")
        self.assertEqual(set(toward_h2), {2, 3, 4},
                         "healthy switches keep their routes; only s1 goes unrouted")


if __name__ == "__main__":
    unittest.main()
