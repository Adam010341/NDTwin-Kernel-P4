"""
`POST /p4/table_entry` -- the status code each refusal gets, and that none of them wrote.

[Co-developed with claude code -- Adam]

TICKET-P2 2.3 fixes a status code to each way this can fail, and the reason the map matters is
that the kernel and an operator act differently on each one: a 502 is the switch's refusal and is
worth retrying, a 404 means somebody named a table this pipeline does not have and retrying it
forever is what the P4 plane already did once with `/stats/flowentry/delete` (live 2026-08-16,
404 on the kernel's most natural delete). A 409 says this fabric belongs to somebody else's
controller, which is a configuration, not a fault.

🔴 EVERY REFUSAL THIS PROXY MAKES ITSELF ASSERTS `stub.requests == []` -- the 400, 404, 409 and
501 rows. "Nothing was written" is a claim about the wire, and a handler that put the entry on
the switch and then failed while building its own response would be indistinguishable from one
that refused, if all we checked was the exception.

🔴 THE 502 IS THE EXCEPTION AND IT IS NOT AN OVERSIGHT. That status is the SWITCH's answer, so
the WriteRequest necessarily went out; asserting an empty stub there would be asserting
something false. `test_a_switch_that_refuses_the_write_is_502_carrying_the_grpc_status_name`
therefore checks the status name and not the wire. (An earlier version of this paragraph said
"every non-200", which the test below correctly did not do -- the doc was the wrong half.)

The handler is called directly rather than through a FastAPI TestClient -- the convention
test_flow_stats_route.py and test_flowentry_endpoints.py both state, and here also a
necessity: `starlette.testclient` in this venv refuses to import without `httpx2`, and
installing into the shared venv is not this ticket's to do. What a TestClient would have added
over this is the routing layer, so the routing layer is asserted directly instead
(TheRouteIsRegisteredTest).
"""

from __future__ import annotations

import asyncio
import json
import os
import queue
import socket
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import grpc
    from fastapi import HTTPException
    from starlette.requests import Request
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2

    from proxy_agent import api_routes
    from proxy_agent import p4_client as p4_client_module
    from proxy_agent.p4_client import P4RuntimeClient
    from proxy_agent.rule_install_times import RuleInstallTimes

    class FakeRpcError(grpc.RpcError):
        """Must derive from grpc.RpcError or the client's `except` would not catch it."""

        def __init__(self, code, details="fake failure"):
            self._code = code
            self._details = details

        def code(self):
            return self._code

        def details(self):
            return self._details

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False


# Real ids from p4_src/build/ndtwin_switch.p4info.txt, so a mixed-up id shows up as the wrong
# number rather than as an off-by-one that happens to work.
IPV4_LPM_ID = 37375156
FLOW_5TUPLE_ID = 50095925
IPV4_FORWARD_ID = 28792405


def a_p4info():
    """The subset this endpoint's tests look things up in.

    Built here rather than imported from test_p4_client_writes.py: `p4_proxy/tests` has no
    `__init__.py`, so a cross-file import works under `-m unittest tests.x` and is a coin flip
    under `l1_unit_tests.sh`, which runs each file as a script. A fixture that only loads under
    one of the two runners is a test nobody notices has stopped running.
    """
    p4info = p4info_pb2.P4Info()

    table = p4info.tables.add()
    table.preamble.id = IPV4_LPM_ID
    table.preamble.name = "MyIngress.ipv4_lpm"
    table.preamble.alias = "ipv4_lpm"
    field = table.match_fields.add()
    field.id = 1
    field.name = "hdr.ipv4.dstAddr"
    field.bitwidth = 32
    field.match_type = p4info_pb2.MatchField.LPM

    five = p4info.tables.add()
    five.preamble.id = FLOW_5TUPLE_ID
    five.preamble.name = "MyIngress.flow_5tuple"
    five.preamble.alias = "flow_5tuple"
    field = five.match_fields.add()
    field.id = 4
    field.name = "hdr.ipv4.protocol"
    field.bitwidth = 8
    field.match_type = p4info_pb2.MatchField.TERNARY

    # 🔴 SYNTHETIC, and named so nobody mistakes them for ndtwin_switch.p4's. No pipeline in
    # this repository declares a RANGE or an OPTIONAL match -- ndtwin_switch has exact, lpm and
    # ternary, and so do `basic` and `source_routing` -- so the only way to reach the 501 that
    # TICKET-P2 2.3 (:63) promises for those two is a descriptor written here. Same fixture and
    # same reasoning as test_p4_client_writes.a_p4info(). [Co-developed with claude code -- Adam]
    for table_id, table_name, kind in ((900000001, "Synthetic.range_table",
                                        p4info_pb2.MatchField.RANGE),
                                       (900000002, "Synthetic.optional_table",
                                        p4info_pb2.MatchField.OPTIONAL)):
        table = p4info.tables.add()
        table.preamble.id = table_id
        table.preamble.name = table_name
        table.preamble.alias = table_name.split(".")[-1]
        field = table.match_fields.add()
        field.id = 1
        field.name = "meta.probe_key"
        field.bitwidth = 16
        field.match_type = kind

    forward = p4info.actions.add()
    forward.preamble.id = IPV4_FORWARD_ID
    forward.preamble.name = "MyIngress.ipv4_forward"
    forward.preamble.alias = "ipv4_forward"
    param = forward.params.add()
    param.id = 1
    param.name = "dstAddr"
    param.bitwidth = 48
    param = forward.params.add()
    param.id = 2
    param.name = "port"
    param.bitwidth = 9

    return p4info


class RecordingStub:
    """Captures WriteRequests instead of sending them, and can be told to fail."""

    def __init__(self, write_error=None):
        self.requests = []
        self.write_error = write_error

    def Write(self, request, timeout=None):
        self.requests.append(request)
        if self.write_error is not None:
            raise self.write_error


def a_client(stub=None, device_id=1, arbitration=True):
    """A P4RuntimeClient with no gRPC channel -- __init__ would open one and read a file."""
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = device_id
    client.grpc_addr = "127.0.0.1:50051"
    client.p4info = a_p4info()
    client.stub = stub if stub is not None else RecordingStub()
    client.packet_in_callback = None
    client.sample_callback = None
    client.is_running = False
    client.stream_recv_thread = None
    client.stream_out_q = queue.Queue()
    client.rule_install_times = RuleInstallTimes()
    client._last_table_read = None
    client.election_id = (0, 1)
    client.arbitration = arbitration
    return client


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


def a_request(body, raw=None):
    """One POST, as starlette hands it to the handler.

    `raw` bypasses the JSON encoding so the malformed-body path can be reached -- that branch is
    `_flowentry_body`'s, and it exists because a body that is not JSON used to be a 500.
    """
    payload = raw if raw is not None else json.dumps(body).encode()

    async def receive():
        return {"type": "http.request", "body": payload, "more_body": False}

    return Request({"type": "http", "http_version": "1.1", "method": "POST",
                    "path": "/p4/table_entry", "raw_path": b"/p4/table_entry",
                    "root_path": "", "scheme": "http", "query_string": b"",
                    "headers": [(b"content-type", b"application/json")],
                    "client": ("127.0.0.1", 0), "server": ("127.0.0.1", 8081)},
                   receive)


AN_LPM_ENTRY = {"dpid": 1, "table": "MyIngress.ipv4_lpm",
                "match": {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TableEntryRouteTestBase(unittest.TestCase):
    def setUp(self):
        self.saved = (api_routes.topology, api_routes.note_api_table_entry_write)
        self.addCleanup(self.restore)
        self.stub = RecordingStub()
        self.client = a_client(self.stub)
        api_routes.topology = FakeTopology({1: self.client})
        self.counted = []
        api_routes.note_api_table_entry_write = self.counted.append

    def restore(self):
        api_routes.topology, api_routes.note_api_table_entry_write = self.saved

    def post(self, body=None, **overrides):
        payload = dict(AN_LPM_ENTRY if body is None else body)
        payload.update(overrides)
        return asyncio.run(api_routes.table_entry(a_request(payload)))

    def refused(self, body=None, **overrides):
        with self.assertRaises(HTTPException) as caught:
            self.post(body, **overrides)
        return caught.exception


class AnAcceptedEntryTest(TableEntryRouteTestBase):
    def test_a_well_formed_insert_answers_success_and_reaches_the_switch(self):
        body = self.post()
        self.assertEqual(body["status"], "success")
        self.assertEqual(body["dpid"], 1)
        self.assertEqual(body["op"], "insert")
        self.assertEqual(body["table"], "MyIngress.ipv4_lpm")
        self.assertEqual(len(self.stub.requests), 1)

    def test_the_response_names_the_match_type_the_pipeline_declared(self):
        # Not the shape the caller sent. `[v, 32]` is an lpm entry on this table and a ternary
        # value/mask pair on another, and a caller who cannot see which one they got cannot tell
        # a host route from a wildcard.
        self.assertEqual(self.post()["match_types"], {"hdr.ipv4.dstAddr": "LPM"})

    def test_priority_honoured_is_false_on_a_table_with_no_priority_column(self):
        self.assertFalse(self.post()["priority_honoured"])

    def test_every_success_says_the_entry_is_not_journaled_and_what_that_costs(self):
        # 🔴 Adam 2026-09-18, option a. The rule is on the switch and it is recorded nowhere: a
        # proxy restart loses it and nothing replays it. This response is the only place a
        # caller will ever be told.
        body = self.post()
        self.assertIs(body["journaled"], False)
        self.assertIn("lost when the proxy restarts", body["note"])

    def test_an_accepted_write_is_counted_where_switch_state_can_report_it(self):
        self.post()
        self.assertEqual(self.counted, [1])

    def test_an_alias_names_the_same_table_and_the_response_gives_the_full_name(self):
        body = self.post(table="ipv4_lpm", action_name="ipv4_forward")
        self.assertEqual(body["table"], "MyIngress.ipv4_lpm")
        self.assertEqual(only_table_id(self.stub.requests[0]), IPV4_LPM_ID)

    def test_modify_and_delete_are_accepted_verbs(self):
        self.assertEqual(self.post(op="modify")["op"], "modify")
        self.assertEqual(self.post(op="delete")["op"], "delete")
        self.assertEqual([r.updates[0].type for r in self.stub.requests],
                         [p4runtime_pb2.Update.MODIFY, p4runtime_pb2.Update.DELETE])


def only_table_id(request):
    return request.updates[0].entity.table_entry.table_id


class EveryRefusalIsItsOwnStatusCodeTest(TableEntryRouteTestBase):
    """One test per status code in TICKET-P2 2.3, and each asserts nothing was written."""

    def test_an_unknown_dpid_is_404(self):
        error = self.refused(dpid=9)
        self.assertEqual(error.status_code, 404)
        self.assertIn("not connected", error.detail["message"])
        self.assertEqual(self.stub.requests, [])

    def test_a_table_this_pipeline_does_not_have_is_404(self):
        error = self.refused(table="MyIngress.firewall")
        self.assertEqual(error.status_code, 404)
        self.assertIn("MyIngress.firewall", error.detail["message"])
        self.assertEqual(self.stub.requests, [])

    def test_an_action_this_pipeline_does_not_have_is_404(self):
        error = self.refused(action_name="MyIngress.set_swid")
        self.assertEqual(error.status_code, 404)
        self.assertEqual(self.stub.requests, [])

    def test_a_match_field_this_table_does_not_have_is_404(self):
        error = self.refused(match={"hdr.ipv4.srcAddr": ["10.0.1.1", 32]})
        self.assertEqual(error.status_code, 404)
        self.assertEqual(self.stub.requests, [])

    def test_an_action_parameter_this_action_does_not_have_is_404(self):
        error = self.refused(action_params={"dstAddr": "08:00:00:00:01:11", "port": 1,
                                            "swid": 3})
        self.assertEqual(error.status_code, 404)
        self.assertEqual(self.stub.requests, [])

    def test_a_value_wider_than_its_field_is_400(self):
        error = self.refused(action_params={"dstAddr": "08:00:00:00:01:11", "port": 512})
        self.assertEqual(error.status_code, 400)
        self.assertIn("511", error.detail["message"])
        self.assertEqual(self.stub.requests, [])

    def test_an_lpm_prefix_outside_the_field_width_is_400(self):
        error = self.refused(match={"hdr.ipv4.dstAddr": ["10.0.1.1", 33]})
        self.assertEqual(error.status_code, 400)
        self.assertEqual(self.stub.requests, [])

    def test_a_priority_this_table_cannot_honour_is_400(self):
        error = self.refused(priority=777)
        self.assertEqual(error.status_code, 400)
        self.assertIn("priority not honourable", error.detail["message"])
        self.assertEqual(self.stub.requests, [])

    def test_a_default_action_carrying_a_match_is_400(self):
        error = self.refused(default_action=True)
        self.assertEqual(error.status_code, 400)
        self.assertEqual(self.stub.requests, [])

    def test_a_dpid_that_is_not_an_integer_is_400(self):
        error = self.refused(dpid="one")
        self.assertEqual(error.status_code, 400)
        self.assertEqual(self.stub.requests, [])

    def test_a_body_that_is_not_json_is_400(self):
        with self.assertRaises(HTTPException) as caught:
            asyncio.run(api_routes.table_entry(a_request(None, raw=b"not json at all")))
        self.assertEqual(caught.exception.status_code, 400)
        self.assertEqual(self.stub.requests, [])

    def test_a_ternary_match_is_501_and_names_the_match_type(self):
        error = self.refused(table="MyIngress.flow_5tuple",
                             match={"hdr.ipv4.protocol": [6, 255]})
        self.assertEqual(error.status_code, 501)
        self.assertIn("TERNARY", error.detail["message"])
        self.assertEqual(error.detail["outcome"], "unsupported_on_p4")
        self.assertEqual(self.stub.requests, [])

    def test_a_range_match_is_501_and_names_RANGE(self):
        # TICKET-P2 2.3 (:63) promises 501 for all three, and this one had no test until round 2.
        # It matters more than the ternary case, not less: a range value is `[lo, hi]`, the same
        # shape an lpm entry uses for `[value, prefix_len]`, so this is the one a writer that
        # guessed from the value would build as a real rule instead of refusing.
        error = self.refused(table="Synthetic.range_table",
                             match={"meta.probe_key": [1024, 3000]},
                             action_name="MyIngress.ipv4_forward")
        self.assertEqual(error.status_code, 501)
        self.assertIn("RANGE", error.detail["message"])
        self.assertEqual(error.detail["outcome"], "unsupported_on_p4")
        self.assertEqual(self.stub.requests, [])

    def test_an_optional_match_is_501_and_names_OPTIONAL(self):
        # An optional value is a plain value, indistinguishable by shape from an exact one.
        error = self.refused(table="Synthetic.optional_table",
                             match={"meta.probe_key": 7},
                             action_name="MyIngress.ipv4_forward")
        self.assertEqual(error.status_code, 501)
        self.assertIn("OPTIONAL", error.detail["message"])
        self.assertEqual(self.stub.requests, [])

    def test_an_external_control_plane_is_409(self):
        # Not a 400 and not a 502: nothing about the request is wrong and the switch never saw
        # it. This fabric's package says somebody else's controller owns these tables.
        self.client.arbitration = False
        error = self.refused()
        self.assertEqual(error.status_code, 409)
        self.assertIn("external control plane", error.detail["message"])
        self.assertEqual(self.stub.requests, [])

    def test_a_switch_that_refuses_the_write_is_502_carrying_the_grpc_status_name(self):
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.PERMISSION_DENIED))
        error = self.refused()
        self.assertEqual(error.status_code, 502)
        self.assertEqual(error.detail["grpc_status"], "PERMISSION_DENIED")

    def test_a_refusal_is_not_counted_as_an_api_write(self):
        # `switch_state`'s api_writes says how many rules this endpoint put on the switch. A
        # refusal counted there is a rule an operator would go looking for.
        self.refused(table="MyIngress.firewall")
        self.assertEqual(self.counted, [])

    def test_no_topology_at_all_is_503(self):
        api_routes.topology = None
        error = self.refused()
        self.assertEqual(error.status_code, 503)


class TheRouteIsRegisteredTest(unittest.TestCase):
    """
    The handler above is reachable at the path and method the ticket names.

    [Co-developed with claude code -- Adam]
    This is what a TestClient would have added over calling the function, and it is worth
    asserting on its own: a decorator that names the wrong path leaves every test in this file
    green and the endpoint 404 for everybody.
    """

    @unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available")
    def test_post_p4_table_entry_is_on_the_router(self):
        matching = [route for route in api_routes.router.routes
                    if getattr(route, "path", None) == "/p4/table_entry"]
        self.assertEqual(len(matching), 1, "the endpoint is not registered at that path")
        self.assertEqual(set(matching[0].methods), {"POST"})
        self.assertIs(matching[0].endpoint, api_routes.table_entry)


if __name__ == "__main__":
    unittest.main(verbosity=2)

# [Co-developed with claude code -- Adam]
