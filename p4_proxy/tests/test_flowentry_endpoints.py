"""
The flow-entry endpoints' request plumbing: malformed bodies and the two delete routes.

[Co-developed with claude code -- Adam]

Both defects here were found by the 2026-08-16 write-path live round, not by reading:

  * A body that was not JSON at all -- or was JSON but not an object -- escaped
    `await request.json()` / `data.get(...)` as an exception and FastAPI answered
    **500 Internal Server Error** for what is squarely the client's mistake. Same defect
    class MalformedMatchError closed one layer down, one layer up.
  * The proxy served only /stats/flowentry/delete_strict. But the kernel's
    FlowRoutingManager::deleteAnEntry defaults priority to -1, which
    HttpRoutingStrategyBase turns into the non-strict POST /stats/flowentry/delete -- so
    the kernel's most natural delete (and the IntentTranslator's only one) answered 404
    in P4 mode while working in OVS mode.

Handlers are called directly rather than through a FastAPI TestClient, the same trade
test_flow_stats_route.py documents: they read only their request argument and the module
globals, so the routing layer would add a dependency without adding coverage. The one
thing that *is* the routing layer's -- which paths exist -- is asserted against
api_routes.router's route table instead.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of
these files directly and parses "Ran N tests".
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from fastapi import HTTPException  # noqa: E402

from proxy_agent import api_routes  # noqa: E402
from proxy_agent.topology_manager import TopologyManager  # noqa: E402


class FakeRequest:
    """Only the surface the handlers touch: an awaitable .json() over raw bytes."""

    def __init__(self, raw: bytes):
        self._raw = raw

    async def json(self):
        return json.loads(self._raw)


class RecordingTopology:
    """Answers every write with a canned verdict and records what it was asked."""

    def __init__(self, verdict=True):
        self.verdict = verdict
        self.calls = []

    # `priority` is passed through as of 2026-08-24: it is meaningless for ipv4_lpm but both
    # meaningful and mandatory for the ternary flow_5tuple table a richer match now compiles to.
    # Recorded rather than merely accepted, so a handler that silently stopped forwarding it
    # fails here instead of at a switch. [Co-developed with claude code -- Adam]
    def route_flow(self, dpid, match, actions, priority=None):
        self.calls.append(("route", dpid, match, actions, priority))
        return self.verdict

    def unroute_flow(self, dpid, match, priority=None):
        self.calls.append(("unroute", dpid, match, priority))
        return self.verdict

    def modify_flow(self, dpid, match, actions, priority=None):
        self.calls.append(("modify", dpid, match, actions, priority))
        return self.verdict


HANDLERS = {
    "add": api_routes.add_flow_entry,
    "delete": api_routes.delete_flow_entry,
    "modify": api_routes.modify_flow_entry,
}


def call(handler, raw: bytes):
    return asyncio.run(handler(FakeRequest(raw)))


class MalformedBodyIsTheClientsErrorTest(unittest.TestCase):
    """A 400 that names the problem, on every write endpoint -- never a 500."""

    def tearDown(self):
        api_routes.topology = None

    def test_a_body_that_is_not_json_answers_400_on_every_write_endpoint(self):
        # Live 2026-08-16: this was a 500. The topology stays None on purpose -- the parse
        # must fail before anything touches it, or a malformed body could still actuate.
        for name, handler in HANDLERS.items():
            with self.subTest(endpoint=name):
                with self.assertRaises(HTTPException) as caught:
                    call(handler, b"this is not json")
                self.assertEqual(caught.exception.status_code, 400)
                self.assertEqual(caught.exception.detail["error"], "malformed body")

    def test_a_json_body_that_is_not_an_object_answers_400_not_500(self):
        # Valid JSON, wrong shape: data.get() over a list was an AttributeError and a 500.
        for name, handler in HANDLERS.items():
            for raw in (b'"just a string"', b"[1, 2]", b"7"):
                with self.subTest(endpoint=name, body=raw):
                    with self.assertRaises(HTTPException) as caught:
                        call(handler, raw)
                    self.assertEqual(caught.exception.status_code, 400)
                    self.assertIn("JSON object", caught.exception.detail["message"])

    def test_a_malformed_body_reaches_no_topology_call(self):
        recorder = RecordingTopology()
        api_routes.topology = recorder
        for handler in HANDLERS.values():
            with self.assertRaises(HTTPException):
                call(handler, b"[]")
        self.assertEqual(recorder.calls, [])


class NonStrictDeleteRouteTest(unittest.TestCase):
    """The kernel's priority-less delete path must exist and be the strict handler."""

    def tearDown(self):
        api_routes.topology = None

    def test_both_delete_paths_are_registered_on_the_same_handler(self):
        # deleteAnEntry(priority=-1) posts /stats/flowentry/delete; only /delete_strict
        # existed, so the kernel's natural delete answered 404 in P4 mode (live 2026-08-16).
        paths = {route.path: route.endpoint for route in api_routes.router.routes}
        self.assertIn("/stats/flowentry/delete", paths)
        self.assertIn("/stats/flowentry/delete_strict", paths)
        self.assertIs(paths["/stats/flowentry/delete"],
                      paths["/stats/flowentry/delete_strict"])

    def test_the_delete_handler_still_reports_the_real_outcome(self):
        # Plumbing check on the now-shared handler: the verdict from unroute_flow is what
        # the body says, for both the success and the refusal.
        for verdict, expected in ((True, "success"), (False, "error")):
            with self.subTest(verdict=verdict):
                recorder = RecordingTopology(verdict=verdict)
                api_routes.topology = recorder
                body = json.dumps({"dpid": 1, "match": {"nw_dst": "10.0.0.4"},
                                   "priority": 100}).encode()
                reply = call(api_routes.delete_flow_entry, body)
                self.assertEqual(reply["status"], expected)
                # The priority the body carried must reach the manager: on the ternary table a
                # delete that loses it removes nothing and still reports success.
                self.assertEqual(recorder.calls,
                                 [("unroute", 1, {"nw_dst": "10.0.0.4"}, 100)])

    def test_a_delete_without_a_destination_is_refused_not_a_wipe(self):
        # OpenFlow's non-strict delete treats an empty match as "clear the table". Serving
        # that here would turn one malformed kernel call into an empty fabric, so the shared
        # handler must keep unroute_flow's refusal instead.
        tm = TopologyManager.__new__(TopologyManager)
        tm.switches = {1: object()}
        self.assertIs(tm.unroute_flow(1, {}), False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
