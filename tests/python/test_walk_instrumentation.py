"""
Tests for the two-phase timing on `install_all_pair_paths` in intelligent_router.py.

[Co-developed with claude code -- Adam]

The walk is the largest unattributed term in the 128-host failover budget, and the two figures
on record disagree by 4.6x -- ~13 s derived (a 73 s control-plane start minus the 60 s
hub.sleep, so an upper bound covering the parse and graph build too) against ~60 s asserted in
four places, all tracing to doc/2026-07-29_HANDOFF.md 1g, which predates 128 hosts being
runnable. The instrumentation exists so the next run settles it without a dedicated lab
session.

## What is actually worth asserting

Not the durations -- those are the measurement, and a unit test that pins them would only be
testing this machine. What matters is that the split measures **what its comment claims it
measures**, because that is the part a reader will rely on when the number lands in a slide:

    rules   one OpenFlow entry per (switch, dst)   -> grows with switches x hosts
    paths   one entry per ORDERED host pair        -> grows with n(n-1)

Those are different functions of host count, so running the same fabric at two sizes separates
them. If someone later moves the `report_seconds` accumulator inside the wrong loop, or counts
rules where they meant paths, these ratios break while a single-size test would still pass.

## Why the method is extracted rather than imported

Same reason as test_route_reinstall.py: importing intelligent_router pulls in Ryu, which lives
in a separate conda env, so it would not run under the interpreter the rest of the Python
suites use. The method is read out of the real file by AST and executed here, so this tests the
shipped source. It is not a copy.

Needs networkx: run under p4_proxy/venv/bin/python3, not the system python3.
"""

from __future__ import annotations

import ast
import os
import re
import unittest
from time import monotonic, sleep

# Guarded for the L1 kernel-side lane, which runs under plain python3 without networkx by
# that lane's own design; an unguarded import there read as FAIL ran=0 since this file was
# added. Under p4_proxy/venv (the interpreter the docstring names) everything runs.
try:
    import networkx as nx
    HAVE_NETWORKX = True
except ImportError:
    HAVE_NETWORKX = False

ROUTER = os.path.join(os.path.dirname(__file__), "..", "..", "intelligent_router.py")
METHOD = "install_all_pair_paths"

#: The log line the method emits, and the only interface this test depends on.
DONE_RE = re.compile(
    r"install_all_pair_paths done: hosts=(\d+) pairs=(\d+) rules=(\d+) paths=(\d+) "
    r"walk=([\d.]+)s install=([\d.]+)s report=([\d.]+)s"
)


def extract_method():
    """`install_all_pair_paths`, verbatim from the real file."""
    with open(ROUTER) as f:
        source = f.read()
    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == METHOD:
            return ast.get_source_segment(source, node)
    raise AssertionError(
        f"intelligent_router.py no longer defines {METHOD}; this test is stale"
    )


class FakeLogger:
    def __init__(self):
        self.lines = []

    def _add(self, msg, *args):
        self.lines.append(msg % args if args else msg)

    warning = info = error = _add

    def text(self):
        return "\n".join(self.lines)


class FakeParser:
    """OFPMatch/OFPActionOutput only have to be constructible and comparable."""

    def OFPMatch(self, **kw):
        return ("match", tuple(sorted(kw.items())))

    def OFPActionOutput(self, port):
        return ("output", port)


class FakeDatapath:
    def __init__(self):
        self.ofproto_parser = FakeParser()


def build_fabric(hosts_per_switch, switch_count=2):
    """A line of switches, `hosts_per_switch` hosts hanging off each.

    Returns (graph, host_ip_by_node). Hosts are keyed by MAC-ish strings and carry `ip_list`,
    which is how the real method tells a host from a switch.
    """
    net = nx.DiGraph()
    for dpid in range(1, switch_count + 1):
        net.add_node(dpid)
    for a in range(1, switch_count):
        # Inter-switch ports are numbered above any host port so they cannot collide.
        net.add_edge(a, a + 1, port=100 + a)
        net.add_edge(a + 1, a, port=200 + a)

    ip_by_host = {}
    n = 0
    for dpid in range(1, switch_count + 1):
        for i in range(hosts_per_switch):
            n += 1
            host = f"00:00:00:00:00:{n:02x}"
            ip = f"10.0.0.{n}"
            net.add_node(host, ip_list=[ip])
            net.add_edge(dpid, host, port=i + 1)
            net.add_edge(host, dpid, port=0)
            ip_by_host[host] = ip
    return net, ip_by_host


class Router:
    """The minimum surface `install_all_pair_paths` touches."""

    def __init__(self, net, ip_by_host):
        self.logger = FakeLogger()
        self.net = net
        self.ip_by_host = ip_by_host
        self.ip_to_host = {ip: h for h, ip in ip_by_host.items()}
        self.switches = {n: FakeDatapath() for n in net.nodes if self.is_switch(n)}
        self.all_destination_paths = []
        self.flows = []

    # -- the helpers the method calls out to ---------------------------------------------
    def debug_print_graph(self, net):
        pass

    def is_switch(self, node):
        return isinstance(node, int)

    def find_host_by_ip(self, net, ip):
        return self.ip_to_host[ip]

    def find_connected_switch(self, net, host):
        return next(n for n in net.neighbors(host) if self.is_switch(n))

    def get_host_port(self, net, host, switch):
        return net[switch][host]["port"]

    def hash_dst_ip(self, s):
        return hash(s)

    def add_flow(self, datapath, priority, match, actions):
        self.flows.append((id(datapath), priority, match, actions))

    # -- the extracted method ------------------------------------------------------------
    def parsed(self):
        """(hosts, pairs, rules, paths, walk, install, report) from the emitted log line."""
        m = DONE_RE.search(self.logger.text())
        if m is None:
            raise AssertionError(
                "install_all_pair_paths emitted no parseable 'done' line; got:\n"
                + self.logger.text()
            )
        ints = [int(g) for g in m.groups()[:4]]
        floats = [float(g) for g in m.groups()[4:]]
        return (*ints, *floats)


NAMESPACE = {"monotonic": monotonic, "is_all_dst_biased": False,
             "all_dst_ecmp_biased_factor": 1}
exec(compile(extract_method(), ROUTER, "exec"), NAMESPACE)
Router.install_all_pair_paths = NAMESPACE[METHOD]


def run(hosts_per_switch, switch_count=2):
    net, ips = build_fabric(hosts_per_switch, switch_count)
    r = Router(net, ips)
    r.install_all_pair_paths(net)
    return r


@unittest.skipUnless(HAVE_NETWORKX,
                     "networkx not available; run under p4_proxy/venv/bin/python3")
class WalkAccounting(unittest.TestCase):
    """The counts in the log line are the ones the comment promises."""

    def test_counts_at_four_hosts(self):
        hosts, pairs, rules, paths, _, _, _ = run(2).parsed()
        self.assertEqual(hosts, 4)
        # Ordered, because the reporting loop builds an entry per direction.
        self.assertEqual(pairs, 12)
        # One rule per (switch, dst): 2 switches x 4 destinations.
        self.assertEqual(rules, 8)
        self.assertEqual(paths, 12)

    def test_rules_and_paths_scale_differently(self):
        """The whole point of the split: these are different functions of host count.

        Doubling hosts on the same two switches doubles the rules and quadruples the paths.
        A test at one size cannot tell the two counters apart.
        """
        small = run(2).parsed()
        large = run(4).parsed()
        _, _, rules_s, paths_s, *_ = small
        _, _, rules_l, paths_l, *_ = large

        self.assertEqual(rules_l, 2 * rules_s, "rules should track switches x hosts")
        # 8*7 / (4*3) = 56/12, not 2x.
        self.assertEqual(paths_l, 56)
        self.assertEqual(paths_s, 12)
        self.assertGreater(paths_l / paths_s, rules_l / rules_s,
                           "the reporting loop must grow faster than the install loop")

    def test_pairs_matches_paths_on_a_connected_fabric(self):
        """`pairs` is computed from the host count; `paths` is counted while walking.

        On a fabric where every host can reach every other they must agree -- if they drift,
        either the graph lost an edge mid-walk or the ordered/unordered convention slipped.
        """
        for hps in (1, 2, 4):
            with self.subTest(hosts_per_switch=hps):
                _, pairs, _, paths, *_ = run(hps).parsed()
                self.assertEqual(pairs, paths)

    def test_three_switches(self):
        """BFS reaches every switch, so rules = switches x hosts regardless of diameter."""
        hosts, _, rules, paths, *_ = run(2, switch_count=3).parsed()
        self.assertEqual(hosts, 6)
        self.assertEqual(rules, 3 * 6)
        self.assertEqual(paths, 30)


#: Hosts-per-switch for the timing tests: 64 per switch = 128 hosts = 16,256 ordered pairs, the
#: same pair count as the real 128-host fabric. The log line has millisecond resolution and this
#: stub is far cheaper per pair than the real thing (no OpenFlow writes), so smaller fabrics
#: round to zero -- measured on this machine, 32 hosts is ~2 ms and lands on one or two ticks,
#: 128 hosts is ~39 ms. Raise this, not the resolution, if a faster machine flattens it.
TIMED = 64


@unittest.skipUnless(HAVE_NETWORKX,
                     "networkx not available; run under p4_proxy/venv/bin/python3")
class WalkTiming(unittest.TestCase):
    """The two phases partition the walk.

    Deliberately not asserted: *which* phase is larger. In this stub the reporting loop
    dominates (~87% at 128 hosts) because `add_flow` is a list append here and an OpenFlow write
    in production -- that ratio is a property of the stub, not of the router, and pinning it
    would make this test lie about what it verifies. Which phase dominates on a real fabric is
    the open question the instrumentation exists to answer; a unit test must not pre-empt it.
    """

    def test_install_and_report_sum_to_walk(self):
        # install is walk - report by construction, so the only slack is rounding: the line
        # prints each of the three to 3 places independently, and two of those roundings can
        # each move a value by up to 0.5 ms in opposite directions.
        _, _, _, _, walk, install, report = run(TIMED).parsed()
        self.assertAlmostEqual(install + report, walk, delta=0.0011)

    def test_both_phases_register(self):
        """Neither phase is zero at this size, so each accumulator is actually running.

        A `report_started` hoisted out of the `dst_ip` loop, or an accumulator that never
        accumulates, shows up here as a zero or a negative rather than as a plausible number.
        """
        _, _, _, _, walk, install, report = run(TIMED).parsed()
        self.assertGreater(walk, 0.0)
        self.assertGreater(report, 0.0)
        self.assertGreater(install, 0.0)

    def test_report_does_not_exceed_the_walk(self):
        _, _, _, _, walk, _, report = run(TIMED).parsed()
        self.assertLessEqual(report, walk,
                             "report time is measured inside the walk; it cannot exceed it")


@unittest.skipUnless(HAVE_NETWORKX,
                     "networkx not available; run under p4_proxy/venv/bin/python3")
class PhasesAreLabelledCorrectly(unittest.TestCase):
    """`install` and `report` are not interchangeable, and this is what pins which is which.

    Every other timing assertion here is symmetric: swap the two values in the log line and the
    sum still holds, both are still positive, and neither exceeds the walk. Nothing above would
    notice. So this makes the install phase cost a known, dominant amount -- `add_flow` is the
    only call the BFS makes and the reporting loop does not -- and checks that the number
    labelled `install` is the one that moved. The bound is machine-independent: it comes from a
    sleep this test asked for, not from how fast anything runs.
    """

    #: Per add_flow. 8 rules at 4 hosts -> >=40 ms of install against a reporting loop of ~12
    #: pairs, which is microseconds. Large enough that no plausible machine confuses the two.
    DELAY = 0.005

    def slow_run(self):
        net, ips = build_fabric(2)
        r = Router(net, ips)
        real_add_flow = r.add_flow

        def slow_add_flow(*a, **k):
            sleep(self.DELAY)
            return real_add_flow(*a, **k)

        r.add_flow = slow_add_flow
        r.install_all_pair_paths(net)
        return r

    def test_install_carries_the_add_flow_cost(self):
        _, _, rules, _, walk, install, report = self.slow_run().parsed()
        floor = rules * self.DELAY
        self.assertGreaterEqual(
            install, floor * 0.9,
            f"{rules} add_flow calls slept {floor:.3f}s in total; `install` must contain it")
        self.assertGreater(
            install, report,
            "the phase carrying the add_flow calls is `install`; the labels look swapped")
        self.assertGreaterEqual(walk, floor * 0.9)


@unittest.skipUnless(HAVE_NETWORKX,
                     "networkx not available; run under p4_proxy/venv/bin/python3")
class LogLineContract(unittest.TestCase):
    """The line is the interface the sweep parses; keep it greppable."""

    def test_emitted_once_per_walk(self):
        r = run(2)
        self.assertEqual(len(DONE_RE.findall(r.logger.text())), 1)
        r.install_all_pair_paths(r.net)
        self.assertEqual(len(DONE_RE.findall(r.logger.text())), 2)

    def test_counters_reset_between_walks(self):
        """They are locals, not attributes -- a second walk must not accumulate the first."""
        r = run(2)
        first = r.parsed()
        r.logger.lines.clear()
        r.install_all_pair_paths(r.net)
        second = r.parsed()
        self.assertEqual(first[:4], second[:4])


if __name__ == "__main__":
    unittest.main(verbosity=2)
