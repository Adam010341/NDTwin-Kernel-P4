"""
`/stats/flowentry/*` on an external control plane answers 409, not 500 -- ruling 5(a).

[Co-developed with claude code -- Adam]

TICKET-P4-heartbeat segment W, the ticket's ruling 5(a) ("`/stats/flowentry/*` 500→409"), which
the first cut recorded as its own open item (TICKET-P4-roles section 7 ruling 5 (a)): under
`control_plane.mode: external` every write is refused by `P4RuntimeClient._refuse_write`, which
RAISES `ControlPlaneReadOnly` -- raised, never returned False, precisely so no retry loop spins on
it. `POST /p4/table_entry` already turned that into a 409; the three OpenFlow-shaped flowentry
endpoints did not catch it, so FastAPI answered 500 -- the proxy looking broken over a request
that was refused on purpose, with nothing sent to the switch.

The 409 body is `/p4/table_entry`'s own: one refusal, one shape. And "nothing was sent" is a
claim about the wire, so the real-path cases check the stub's requests, as
test_table_entry_route.py does for its 409.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import fastapi  # noqa: F401
    import grpc  # noqa: F401
    import networkx  # noqa: F401

    HAVE_PROXY = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_PROXY = False

if HAVE_PROXY:
    from fastapi import HTTPException

    from proxy_agent import api_routes
    from proxy_agent.p4_client import ControlPlaneReadOnly
    from proxy_agent.topology_manager import TopologyManager
    from tests.test_flowentry_endpoints import FakeRequest, RaisingTopology
    from tests.test_table_entry_route import a_client

ROUTE = {"dpid": 1, "match": {"dl_type": 2048, "nw_dst": "10.0.1.1"},
         "actions": [{"type": "OUTPUT", "port": 1}]}


def handlers():
    return {"add": api_routes.add_flow_entry, "delete": api_routes.delete_flow_entry,
            "modify": api_routes.modify_flow_entry}


def refused(handler, body=ROUTE):
    try:
        asyncio.run(handler(FakeRequest(json.dumps(body).encode())))
    except HTTPException as err:
        return err
    raise AssertionError("the handler answered instead of refusing")


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class ARefusedWriteIsA409Test(unittest.TestCase):
    """The handlers, against a topology that raises what `_refuse_write` raises."""

    def setUp(self):
        saved = api_routes.topology
        self.addCleanup(lambda: setattr(api_routes, "topology", saved))
        api_routes.topology = RaisingTopology(ControlPlaneReadOnly(
            "switch 1 (127.0.0.1:50051): refusing an ipv4_lpm route insert -- this fabric's app "
            "package declares an external control plane"))

    def test_add_is_409(self):
        self.assertEqual(refused(handlers()["add"]).status_code, 409)

    def test_delete_is_409(self):
        self.assertEqual(refused(handlers()["delete"]).status_code, 409)

    def test_modify_is_409(self):
        self.assertEqual(refused(handlers()["modify"]).status_code, 409)

    def test_the_body_is_the_table_entry_endpoints_own(self):
        for name, handler in handlers().items():
            with self.subTest(endpoint=name):
                detail = refused(handler).detail
                self.assertEqual(detail["error"], "external control plane")
                self.assertEqual(detail["dpid"], 1)
                self.assertIn("external control plane", detail["message"])

    def test_both_delete_routes_are_that_handler(self):
        paths = {r.path: r.endpoint for r in api_routes.router.routes}
        self.assertIs(paths["/stats/flowentry/delete_strict"], api_routes.delete_flow_entry)
        self.assertIs(paths["/stats/flowentry/delete"], api_routes.delete_flow_entry)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class ThroughTheRealWriterNothingReachesTheSwitchTest(unittest.TestCase):
    """A real TopologyManager over a real P4RuntimeClient built for `external` (no channel)."""

    def setUp(self):
        saved = api_routes.topology
        self.addCleanup(lambda: setattr(api_routes, "topology", saved))
        self.client = a_client(arbitration=False)
        topo = TopologyManager()
        topo.add_switch(1, self.client)
        api_routes.topology = topo

    def test_every_verb_is_409_and_the_switch_saw_nothing(self):
        for name, handler in handlers().items():
            with self.subTest(endpoint=name):
                self.assertEqual(refused(handler).status_code, 409)
        self.assertEqual(self.client.stub.requests, [])

    def test_a_five_tuple_write_is_409_too(self):
        body = {"dpid": 1, "priority": 100,
                "match": {"dl_type": 2048, "nw_dst": "10.0.1.1", "nw_proto": 6, "tp_dst": 80},
                "actions": [{"type": "OUTPUT", "port": 1}]}
        self.assertEqual(refused(handlers()["add"], body).status_code, 409)
        self.assertEqual(self.client.stub.requests, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
