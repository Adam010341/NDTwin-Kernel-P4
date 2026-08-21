"""
Tests for `find_host_by_ip` -- the helper that has now been the walk's bottleneck twice.

[Co-developed with claude code -- Adam]

First as a linear scan (cubic walk, 13.7x, WALK_SWEEP.md), then as an index whose cache token
called `net.number_of_edges()` per lookup -- O(V) in networkx, which made the "indexed" walk
1.69x slower than the scan it replaced (walk_variants.txt in the same audit dir). Both
versions looked obviously fine and shipped. So besides behaviour, these tests pin the cost
discipline itself: the helper may not call any graph method that walks the graph.

## Why the method is extracted rather than imported

Same reason as the other suites here: importing intelligent_router pulls in Ryu, which lives
in a separate conda env. AST extraction runs the shipped source under this interpreter.
Needs networkx: run under p4_proxy/venv/bin/python3.
"""

from __future__ import annotations

import ast
import os
import unittest

# The L1 kernel-side lane runs these files under plain python3, which by that lane's own
# design carries no networkx -- an unguarded import there reads as FAIL ran=0, which is a
# worse signal than an honest skip. Under p4_proxy/venv (the documented interpreter) the
# guard is inert and every test runs.
try:
    import networkx as nx
    HAVE_NETWORKX = True
except ImportError:
    HAVE_NETWORKX = False

ROUTER = os.path.join(os.path.dirname(__file__), "..", "..", "intelligent_router.py")
METHOD = "find_host_by_ip"


def load_helper():
    with open(ROUTER) as fh:
        src = fh.read()
    tree = ast.parse(src)
    func = next((n for n in ast.walk(tree)
                 if isinstance(n, ast.FunctionDef) and n.name == METHOD), None)
    assert func is not None, f"{METHOD} not found in {ROUTER} -- was it renamed?"
    ns = {}
    exec(compile(ast.Module(body=[func], type_ignores=[]), ROUTER, "exec"), ns)
    return ns[METHOD]


if HAVE_NETWORKX:
    class CountingGraph(nx.DiGraph):
        """A DiGraph that counts calls to every method that walks the whole graph.

        `number_of_nodes` and `__len__` are deliberately not counted: they are len() of a
        dict, and the token is allowed to use them.
        """

        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            self.walked = 0

        def number_of_edges(self, u=None, v=None):
            self.walked += 1
            return super().number_of_edges(u, v)

        def size(self, weight=None):
            self.walked += 1
            return super().size(weight)

        @property
        def degree(self):
            self.walked += 1
            return super().degree


class Router:
    pass


def fabric(hosts, offset=0):
    net = CountingGraph()
    net.add_node(1)
    for i in range(1, hosts + 1):
        net.add_node(f"h{i + offset}", ip_list=[f"10.0.{offset}.{i}"])
    return net


@unittest.skipUnless(HAVE_NETWORKX,
                     "networkx not available; run under p4_proxy/venv/bin/python3")
class FindHostByIpTest(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.router = Router()

    def test_finds_the_owner_and_misses_cleanly(self):
        net = fabric(4)
        self.assertEqual(self.helper(self.router, net, "10.0.0.3"), "h3")
        self.assertIsNone(self.helper(self.router, net, "10.9.9.9"))

    def test_a_node_added_after_the_first_lookup_is_found(self):
        # The cache's one legitimate invalidation event. A token that never invalidates would
        # pass every other test here and quietly serve a stale index to the reinstall path.
        net = fabric(2)
        self.assertIsNone(self.helper(self.router, net, "10.0.0.3"))
        net.add_node("h3", ip_list=["10.0.0.3"])
        self.assertEqual(self.helper(self.router, net, "10.0.0.3"), "h3")

    def test_duplicate_address_keeps_first_in_iteration_order(self):
        # The scan's documented behaviour, preserved across both rewrites.
        net = CountingGraph()
        net.add_node("first", ip_list=["10.0.0.1"])
        net.add_node("second", ip_list=["10.0.0.1"])
        self.assertEqual(self.helper(self.router, net, "10.0.0.1"), "first")

    def test_two_graphs_do_not_share_a_cache(self):
        # static_net and dynamic_net are both live; _active_net alternates between them.
        a, b = fabric(2), fabric(2, offset=100)
        self.assertEqual(self.helper(self.router, a, "10.0.0.1"), "h1")
        self.assertEqual(self.helper(self.router, b, "10.0.100.1"), "h101")
        self.assertIsNone(self.helper(self.router, a, "10.0.100.1"),
                          "graph a answered for an address only graph b owns -- the caches "
                          "are cross-contaminated")

    def test_lookups_never_walk_the_graph(self):
        # The regression this file exists for. 957a646's token called number_of_edges() per
        # lookup; networkx computes that as a sum over every node's degree, so 180k lookups
        # at 128 hosts each paid an O(V) toll and the "index" lost to the scan. The token is
        # allowed len()-class calls only -- for everything else, one call anywhere in this
        # loop is the defect coming back.
        net = fabric(64)
        for i in range(1, 65):
            self.helper(self.router, net, f"10.0.0.{i}")
        self.assertEqual(
            net.walked, 0,
            f"find_host_by_ip made {net.walked} graph-walking call(s) "
            f"(number_of_edges/size/degree) across 64 lookups; the cache token must be O(1)")


if __name__ == "__main__":
    unittest.main()
