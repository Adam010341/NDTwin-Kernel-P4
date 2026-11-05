"""
`/stats/flowentry/*` on a switch startup did not push to answers 409 `switch not primary`.

[Co-developed with claude code -- Adam]

Startup withholds a switch whose arbitration this proxy never held (main.startup). Its client is
still in the topology, so without the refusal the three flow verbs would write into tables
another controller holds: an equal election id is accepted while that controller is up. The
refusal is a 409 whose body names the switch, says to readopt it once no other controller holds
the switch and this proxy's own stream to it has ended (or to restart the proxy), and says that
nothing was written, deleted or modified.

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
    from proxy_agent.topology_manager import TopologyManager
    from tests.test_flowentry_endpoints import FakeRequest
    from tests.test_flowentry_read_only import handlers

#: What each verb says it did not do, as `_refuse_withheld` is called with it.
NOTHING_WAS = {"add": "Nothing was written", "delete": "Nothing was deleted",
               "modify": "Nothing was modified"}


def answer(topology, handler, dpid):
    """(status, body) of one flow verb for `dpid`, with `topology` behind the endpoints."""
    body = {"dpid": dpid, "match": {"dl_type": 2048, "nw_dst": "10.0.1.1"},
            "actions": [{"type": "OUTPUT", "port": 1}]}
    saved = api_routes.topology
    api_routes.topology = topology
    try:
        reply = asyncio.run(handler(FakeRequest(json.dumps(body).encode())))
    except HTTPException as err:
        return err.status_code, err.detail
    finally:
        api_routes.topology = saved
    if hasattr(reply, "status_code"):
        return reply.status_code, json.loads(reply.body)
    return 200, reply


def add_answer(topology, dpid):
    return answer(topology, handlers()["add"], dpid)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class AWithheldSwitchRefusesFlowWritesTest(unittest.TestCase):
    """A switch startup did not push to is written to by none of the three flow verbs."""

    def setUp(self):
        from tests.test_flowentry_endpoints import LpmClient

        self.topo = TopologyManager()
        self.held, self.free = LpmClient(), LpmClient()
        self.topo.add_switch(1, self.held)
        self.topo.add_switch(2, self.free)
        self.topo.add_host("10.0.1.1", "00:00:00:00:00:aa", 1, 2)
        self.topo.add_host("10.0.1.2", "00:00:00:00:00:bb", 2, 2)
        self.topo.withhold_routes(1)

    def test_every_verb_is_409_naming_the_switch_and_nothing_is_written(self):
        for name, handler in handlers().items():
            with self.subTest(endpoint=name):
                status, body = answer(self.topo, handler, 1)
                self.assertEqual(status, 409, body)
                self.assertEqual(body["error"], "switch not primary")
                self.assertEqual(body["dpid"], 1)
                text = json.dumps(body)
                self.assertIn("switch 1", text)
                self.assertIn("/p4/readopt/1", text)
                self.assertIn("restart the proxy", text)
                self.assertIn(NOTHING_WAS[name], text)
        self.assertEqual(self.held.calls, [], "a write reached a switch this proxy is not primary on")

    def test_a_switch_that_was_released_is_written_to_again(self):
        self.topo.release_routes(1)
        status, body = answer(self.topo, handlers()["add"], 1)
        self.assertEqual(status, 200, body)
        self.assertEqual(len(self.held.calls), 1)

    def test_a_switch_that_was_never_withheld_is_unaffected(self):
        status, body = answer(self.topo, handlers()["add"], 2)
        self.assertEqual(status, 200, body)
        self.assertEqual(len(self.free.calls), 1)
        status, body = answer(self.topo, handlers()["modify"], 2)
        self.assertEqual(status, 200, body)
        status, body = answer(self.topo, handlers()["delete"], 2)
        self.assertEqual(status, 200, body)


if __name__ == "__main__":
    unittest.main(verbosity=2)
