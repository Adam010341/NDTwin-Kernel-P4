"""
Property-based tests for the topology graph state machine.

[Co-developed with claude code -- Adam]

## Why this shape rather than the obvious one

The research report proposed driving the *live* stack with Hypothesis. That does not work:
one rule (break a link, wait for detection, wait for reroute) costs tens of seconds, and
stateful testing only earns its keep over hundreds of steps. What it would actually buy is a
handful of slow random sequences -- worse than the fault catalogue, which at least chooses
its failures deliberately.

The graph is where the value is. Both blackhole defects this project has hit were graph state
machine bugs, not networking bugs:

  * 2026-08-13, OVS: a unidirectional failure left the DiGraph asymmetric *permanently* (the
    paired EventLinkDelete never arrives), and the all-pairs walk then raised KeyError looking
    up the missing reverse edge. Every route went stale; the flow blackholed for 291 s while
    the twin reported it healthy.
  * The same asymmetric shape appeared once during ordinary startup LLDP jitter.

Those are reachable in milliseconds here, with no Mininet at all. So the rules below build and
tear down links -- including one direction at a time, which is the shape nobody wrote a test
for -- and the invariants assert the things that were actually violated.

## What the invariants are worth

`calculate_all_paths` not raising is the load-bearing one: the live defect was an exception,
not a wrong answer. The rest pin what a correct answer looks like, so a future "fix" that
silences the exception by producing nonsense still fails.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hypothesis import HealthCheck, settings  # noqa: E402
from hypothesis.stateful import (  # noqa: E402
    RuleBasedStateMachine,
    initialize,
    invariant,
    rule,
)
from hypothesis.strategies import sampled_from  # noqa: E402

from proxy_agent.topology_manager import TopologyManager  # noqa: E402

#: Small enough that Hypothesis explores the interesting states, big enough to have a choice of
#: routes -- a square with two hosts, the same shape the unidirectional-loss unit tests use.
SWITCHES = (1, 2, 3, 4)
LINKS = ((1, 2, 2, 1), (1, 3, 3, 1), (2, 4, 3, 2), (3, 4, 4, 3))
HOSTS = (("10.0.0.1", "00:00:00:00:00:01", 1, 9), ("10.0.0.2", "00:00:00:00:00:02", 4, 9))


class TopologyStateMachine(RuleBasedStateMachine):
    """Random sequences of link up/down -- including one-way -- against the path computation."""

    @initialize()
    def build(self):
        self.topo = TopologyManager()
        for a, b, pa, pb in LINKS:
            self.topo.add_link(a, b, pa, pb)
        for ip, mac, dpid, port in HOSTS:
            self.topo.add_host(ip, mac, dpid, port)

    # --- rules: the events a real fabric produces -------------------------------------

    @rule(link=sampled_from(LINKS))
    def link_up(self, link):
        a, b, pa, pb = link
        self.topo.add_link(a, b, pa, pb)

    @rule(link=sampled_from(LINKS))
    def link_down_both_ways(self, link):
        a, b = link[0], link[1]
        with self.topo._net_lock:
            self.topo.net.remove_edge(a, b) if self.topo.net.has_edge(a, b) else None
            self.topo.net.remove_edge(b, a) if self.topo.net.has_edge(b, a) else None

    @rule(link=sampled_from(LINKS))
    def link_down_one_way(self, link):
        """The shape that caused the 291-second blackhole: only one direction disappears.

        LLDP dies in one direction, exactly one EventLinkDelete fires, and the graph is
        asymmetric for as long as the fault lasts -- a steady state, not a transient.
        """
        a, b = link[0], link[1]
        with self.topo._net_lock:
            if self.topo.net.has_edge(a, b):
                self.topo.net.remove_edge(a, b)

    @rule()
    def recompute(self):
        self.topo.calculate_all_paths(self.topo.reroutable_down_endpoints())

    # --- invariants -------------------------------------------------------------------

    @invariant()
    def recompute_never_raises(self):
        """The live defect was an exception, not a wrong answer."""
        self.topo.calculate_all_paths(self.topo.reroutable_down_endpoints())

    @invariant()
    def a_recomputed_path_set_is_consistent(self):
        """Recompute first, then check -- the contract is "consistent when used", not "always".

        The first version of this file checked dest_paths as it stood after each rule and
        immediately found "path 2->1 claims hop 2->1, which is not in the graph". That was the
        test being wrong, not the code: dest_paths is an internal intermediate, every consumer
        recomputes before reading it (`install_initial_routes` opens with calculate_all_paths,
        and `render_destination_paths` searches the graph it is handed rather than this field),
        so a stale interval between a link change and the next recompute has no observer.
        Asserting the stronger property would have failed forever while describing nothing real.
        """
        self.topo.calculate_all_paths(self.topo.reroutable_down_endpoints())
        for dst, sources in self.topo.dest_paths.items():
            for src, info in sources.items():
                hops = info["path"]
                for u, v in zip(hops, hops[1:]):
                    assert self.topo.net.has_edge(u, v), (
                        "path %s->%s claims hop %r->%r, which is not in the graph"
                        % (src, dst, u, v))
                assert len(hops) == len(set(hops)), (
                    "path %s->%s revisits a node: %r" % (src, dst, hops))
                assert info["length"] == len(info["path"]) - 1, (
                    "path %s->%s reports length %d for %d hops"
                    % (src, dst, info["length"], len(info["path"])))


# suppress_health_check: rebuilding the manager per example is the point, and it is cheap.
TopologyStateMachine.TestCase.settings = settings(
    max_examples=150,
    stateful_step_count=25,
    deadline=None,
    suppress_health_check=[HealthCheck.data_too_large],
)

TopologyPropertyTest = TopologyStateMachine.TestCase


if __name__ == "__main__":
    unittest.main()
