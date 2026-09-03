"""
The path chosen between two hosts must be a function of the topology, and nothing else.

[Co-developed with claude code -- Adam]

Round 5 (2026-09-03, `doc/audit/2026-09-03_night-rounds/round5-topology-repro/`) measured the
defect these tests exist for. Ten `ndt up p4 4` / `ndt down` cycles, the same command, the same
topology file, each from a machine verified clean, produced **four different fabric-wide routing
tables in eight fully captured bring-ups**; with identical h3 -> h1 traffic s3 left via s7 four
times and via s8 four times, and the utilisation published for the s3-s7 link took five distinct
values -- {0.0, 1.476, 1.771, 2.951, 2.952}. `/ndt/get_path_switch_count` was byte-identical
across all eight, because it publishes a hop *count*: the endpoint a researcher would use to ask
"did the path change?" structurally could not see it.

Cause: the shipped 4-host P4 fabric has eight equal-length h3 -> h1 paths; `nx.shortest_path` is
BFS; BFS breaks an equal-length tie by neighbour iteration order; `nx.DiGraph` iterates in
insertion order; and insertion is `TopologyManager.add_link` running on ten concurrent gRPC
receive threads. The tie was decided by which LLDP packet-in landed first.

🔴 These tests assert DETERMINISM, not an answer. Nothing here says "the path is via s7". A test
pinned to one of the eight would go red the day the tie-break is legitimately changed -- and
would have passed just as happily on the unfixed code for any run that happened to agree with it.
What is pinned instead:

  1. the fabric really does contain the tie (otherwise every other assertion is vacuous);
  2. the same edge set inserted in many orders gives ONE path;
  3. the advertised path agrees hop by hop with the rule each switch installs for itself;
  4. the tie-break does not collapse onto a single physical uplink;
  5. the answer survives a different PYTHONHASHSEED, i.e. it is not `hash()` in disguise.
"""

from __future__ import annotations

import json
import os
import random
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(HERE, ".."))

#: The fabric the defect was measured on. Tracked, so this is a fixture and not an environment.
TOPO = os.path.join(REPO, "setting", "StaticNetworkTopologyP4_10Switches_4Hosts.json")

try:
    import networkx as nx
    from proxy_agent import ryu_topology as rt
    HAVE_DEPS = True
except ImportError:
    HAVE_DEPS = False

#: How many insertion orders each determinism assertion tries. Fixed seed: a gate that samples a
#: different set of orders on every run reports a different thing on every run.
ORDERS = 120
SEED = 20260903


def topology_ops(path=TOPO):
    """
    The shipped topology as the sequence of calls TopologyManager makes while discovering it.

    Returned as ops rather than as a graph precisely so the order can be permuted: `add_link`
    and `add_host` are what fill `net`, and their order is the thing under test.
    """
    with open(path) as fh:
        doc = json.load(fh)
    switches = sorted(n["dpid"] for n in doc["nodes"] if n.get("vertex_type") == 0)
    ops = []
    seen = set()
    for edge in doc["edges"]:
        src, dst = edge["src_dpid"], edge["dst_dpid"]
        src_port, dst_port = edge["src_interface"], edge["dst_interface"]
        if src == 0 or dst == 0:
            # Host attachment. The file states it in both directions; add_host does both at
            # once, so only the switch -> host direction is turned into an op.
            if src == 0:
                continue
            ops.append(("host", (edge["dst_ip"][0], src, src_port)))
            continue
        key = tuple(sorted(((src, src_port), (dst, dst_port))))
        if key in seen:
            continue
        seen.add(key)
        ops.append(("link", (src, dst, src_port, dst_port)))
    return switches, ops


def build(switches, ops):
    """Exactly what TopologyManager.add_switch / add_link / add_host build, in the given order."""
    net = nx.DiGraph()
    for dpid in switches:
        net.add_node(dpid, type="switch")
    for kind, args in ops:
        if kind == "link":
            src, dst, src_port, dst_port = args
            net.add_edge(src, dst, port=src_port)
            net.add_edge(dst, src, port=dst_port)
        else:
            ip, dpid, port = args
            net.add_node(ip, type="host", mac=0)
            net.add_edge(dpid, ip, port=port)
            net.add_edge(ip, dpid, port=0)
    return net


def insertion_orders(ops, count=ORDERS):
    """The discovery order as shipped, then `count - 1` shuffles of it."""
    rng = random.Random(SEED)
    orders = [list(ops)]
    for _ in range(count - 1):
        perm = list(ops)
        rng.shuffle(perm)
        orders.append(perm)
    return orders


@unittest.skipUnless(HAVE_DEPS, "networkx not available")
class ShippedFabricHasTheTie(unittest.TestCase):
    """The premise. Without this, everything below could pass on a fabric with no choice to make."""

    def test_h3_to_h1_has_eight_equal_length_paths(self):
        switches, ops = topology_ops()
        net = build(switches, ops)
        paths = list(nx.all_shortest_paths(net, "10.0.0.3", "10.0.0.1"))
        self.assertEqual(len(paths), 8,
                         "the fabric these tests reason about no longer contains the 8-way tie; "
                         "the determinism assertions below would be vacuous")
        self.assertEqual({len(p) for p in paths}, {7}, "all eight are the same length")

    def test_bfs_alone_does_not_settle_it(self):
        """
        The instrument's own control: raw `nx.shortest_path` over these same orders is NOT
        stable. If this ever reports one answer, the harness has stopped being able to see the
        defect and the passes below mean nothing.
        """
        switches, ops = topology_ops()
        seen = set()
        for order in insertion_orders(ops):
            net = build(switches, order)
            seen.add(tuple(nx.shortest_path(net, source="10.0.0.3", target="10.0.0.1")))
        self.assertGreater(len(seen), 1,
                           "insertion order no longer moves plain BFS on this fabric; this gate "
                           "can no longer distinguish a fixed tie-break from an unfixed one")


@unittest.skipUnless(HAVE_DEPS, "networkx not available")
class PathIsAFunctionOfTheTopology(unittest.TestCase):
    """The gate: same edge set, any insertion order, one answer."""

    def test_every_host_pair_is_insertion_order_independent(self):
        switches, ops = topology_ops()
        answers = {}
        for order in insertion_orders(ops):
            net = build(switches, order)
            hosts = [n for n, a in net.nodes(data=True) if a.get("type") == "host"]
            for src in hosts:
                for dst in hosts:
                    if src == dst:
                        continue
                    path = rt.canonical_path(net, src, dst)
                    answers.setdefault((src, dst), set()).add(tuple(path))
        self.assertTrue(answers, "no host pairs were examined")
        unstable = {pair: sorted(v) for pair, v in answers.items() if len(v) != 1}
        self.assertEqual(unstable, {},
                         f"{len(unstable)} host pairs answered differently depending on the "
                         f"order their links were discovered in")

    def test_all_pairs_including_switch_sources_are_stable(self):
        """Switch -> host is the pair that becomes an installed rule, so it matters most."""
        switches, ops = topology_ops()
        answers = {}
        for order in insertion_orders(ops):
            net = build(switches, order)
            for dst in [n for n, a in net.nodes(data=True) if a.get("type") == "host"]:
                for src, path in rt.canonical_paths_to(net, dst).items():
                    answers.setdefault((src, dst), set()).add(tuple(path))
        self.assertTrue(answers)
        self.assertEqual([p for p, v in answers.items() if len(v) != 1], [])

    def test_topology_manager_all_pairs_is_stable(self):
        """
        The real call site. `calculate_all_paths` is what `install_initial_routes` consumes, so
        a fix that only reached the renderer would leave the switches themselves undefined.
        """
        try:
            from proxy_agent.topology_manager import TopologyManager
        except Exception as exc:                      # pragma: no cover - dependency-dependent
            self.skipTest(f"TopologyManager not importable: {exc}")
        switches, ops = topology_ops()
        answers = {}
        # Fewer orders here: this is the whole all-pairs computation, not one pair.
        for order in insertion_orders(ops, count=12):
            manager = TopologyManager.__new__(TopologyManager)
            import threading
            manager.net = build(switches, order)
            manager._net_lock = threading.RLock()
            manager.dest_paths = {}
            for dst, by_src in manager.calculate_all_paths().items():
                for src, info in by_src.items():
                    answers.setdefault((src, dst), set()).add(tuple(info["path"]))
        self.assertTrue(answers, "calculate_all_paths returned nothing to compare")
        self.assertEqual([p for p, v in answers.items() if len(v) != 1], [],
                         "calculate_all_paths still depends on graph insertion order")


@unittest.skipUnless(HAVE_DEPS, "networkx not available")
class TheChosenPathIsTheInstalledPath(unittest.TestCase):
    """
    `ipv4_lpm` holds one next hop per (switch, destination IP): forwarding is destination-based
    and the source is not in the key. So a path is only honest if every switch on it would pick
    the same next hop when asked on its own behalf -- otherwise the twin advertises a route the
    fabric does not run, which is the 2026-08-10 shape of defect all over again.
    """

    def test_advertised_hops_match_each_switch_own_next_hop(self):
        switches, ops = topology_ops()
        net = build(switches, ops)
        hosts = [n for n, a in net.nodes(data=True) if a.get("type") == "host"]
        disagreements = []
        for dst in hosts:
            dist = rt.hop_distances_to(net, dst)
            for src in net.nodes():
                if src == dst:
                    continue
                path = rt.canonical_path(net, src, dst, dist)
                if path is None:
                    continue
                for i, node in enumerate(path[:-1]):
                    own = rt.canonical_path(net, node, dst, dist)
                    if own[1] != path[i + 1]:
                        disagreements.append((src, dst, node, path[i + 1], own[1]))
        self.assertEqual(disagreements, [],
                         "a hop on an advertised path is not the hop that switch would install")

    def test_renderer_and_route_installer_agree(self):
        """The reported topology and the computed routes must come from one rule, not two."""
        switches, ops = topology_ops()
        net = build(switches, ops)
        rendered = rt.render_destination_paths(net)
        self.assertEqual(rendered["status"], "success")
        for entry in rendered["all_destination_paths"]:
            nodes = [hop[0] for hop in entry]
            src, dst = nodes[0], nodes[-1]
            self.assertEqual(nodes, rt.canonical_path(net, src, dst))


@unittest.skipUnless(HAVE_DEPS, "networkx not available")
class DeterministicWithoutCollapsingOntoOneLink(unittest.TestCase):
    """
    Deterministic is necessary, not sufficient. "Always take the lowest dpid" is deterministic
    and leaves half the core carrying nothing. These assert spread as a property -- which links
    get used is never named, only that more than one does.
    """

    def test_a_tied_switch_does_not_send_every_destination_out_one_uplink(self):
        switches, ops = topology_ops()
        net = build(switches, ops)
        hosts = [n for n, a in net.nodes(data=True) if a.get("type") == "host"]
        spread = set()
        for dpid in switches:
            hops = set()
            for dst in hosts:
                dist = rt.hop_distances_to(net, dst)
                nxt = rt.canonical_next_hop(net, dpid, dst, dist)
                if nxt is not None and net.nodes[nxt].get("type") == "switch":
                    hops.add(nxt)
            if len(hops) > 1:
                spread.add(dpid)
        self.assertTrue(spread,
                        "every switch sends every destination to the same neighbour: the "
                        "tie-break is deterministic but has collapsed onto one uplink each")

    def test_no_switch_on_a_shortest_path_is_left_dark(self):
        """
        A switch is *eligible* for a destination when some neighbour's shortest path to that
        destination can legitimately go through it. Every switch eligible for anything must be
        chosen for something: a tie-break that leaves an eligible switch carrying no rule at all
        is concentrating load onto its rivals.

        Names no switch and no path -- it compares the set the topology makes available against
        the set the tie-break actually uses -- so it survives the tie-break being changed, and
        goes red for "lowest dpid wins", which on this fabric leaves three of the ten dark.
        """
        switches, ops = topology_ops()
        net = build(switches, ops)
        hosts = [n for n, a in net.nodes(data=True) if a.get("type") == "host"]
        eligible, used = set(), set()
        for dst in hosts:
            dist = rt.hop_distances_to(net, dst)
            for dpid in switches:
                if dpid not in dist:
                    continue
                for nxt in net.successors(dpid):
                    if dist.get(nxt) == dist[dpid] - 1 and net.nodes[nxt].get("type") == "switch":
                        eligible.add(nxt)
                chosen = rt.canonical_next_hop(net, dpid, dst, dist)
                if chosen is not None and net.nodes[chosen].get("type") == "switch":
                    used.add(chosen)
        self.assertTrue(eligible, "no switch was ever an eligible next hop; nothing was tested")
        self.assertEqual(sorted(eligible - used), [],
                         f"{sorted(eligible - used)} can carry traffic on a shortest path and "
                         f"never do; only {sorted(used)} of {sorted(eligible)} are ever chosen")


@unittest.skipUnless(HAVE_DEPS, "networkx not available")
class StableAcrossProcesses(unittest.TestCase):
    """
    A tie-break built on `hash()` would pass every test above inside one process and swap the
    answer on the next run, because PYTHONHASHSEED randomises str hashing per process. That is
    the same defect with a different clock, so it gets its own assertion.
    """

    SNIPPET = (
        "import json,sys;"
        "sys.path.insert(0, %r);"
        "from proxy_agent import ryu_topology as rt;"
        "sys.path.insert(0, %r);"
        "from test_path_determinism import topology_ops, build;"
        "s,o = topology_ops();"
        "n = build(s,o);"
        "print(json.dumps([rt.canonical_path(n,'10.0.0.3','10.0.0.1'),"
        "rt.canonical_path(n,'10.0.0.4','10.0.0.2')]))"
    )

    def _answer(self, seed):
        env = dict(os.environ)
        env["PYTHONHASHSEED"] = seed
        env["PYTHONPATH"] = os.path.join(HERE, "..")
        out = subprocess.run(
            [sys.executable, "-c", self.SNIPPET % (os.path.join(HERE, ".."), HERE)],
            capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def test_same_answer_under_different_hash_seeds(self):
        answers = {self._answer(seed) for seed in ("0", "1", "12345")}
        self.assertEqual(len(answers), 1,
                         f"the path changed with PYTHONHASHSEED: {answers}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
