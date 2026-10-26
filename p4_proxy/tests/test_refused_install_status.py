"""
A refused install is not a 200, and an empty action list on a 5-tuple match is a drop rule.

[Co-developed with claude code -- Adam]

Two defects on the one endpoint, POST /stats/flowentry/add:

  * KNOWN-ISSUES C-6. A write the switch refused -- every install from the 897th on, on a full
    bmv2 ipv4_lpm (1024 entries, 128 of them the fabric's own host routes) -- answered
    **200** {"status": "error", "message": "Failed to add route"}. A caller reading the status
    line read it as installed. Now a 502, the code POST /p4/table_entry answers "the switch refused
    the write" with, and the body is the same two keys word for word. The three refusals that
    are NOT the switch's (no such switch, no destination, actions this plane cannot express) get
    404 / 400 / 501, so a caller is not sent to look at a switch that was never asked.

  * KNOWN-ISSUES A-4g. The kernel's BLOCK_HOST sends `{"eth_type": 2048, "ipv4_src": <host>}`
    with `actions: []` -- OpenFlow's drop. route_flow returned False for any install without an
    OUTPUT action, so the block never reached the switch. On flow_5tuple, whose action list
    includes drop() and which the pipeline applies before ipv4_lpm, it is now a drop entry.

The handlers are driven directly (no TestClient), with the real TopologyManager and the real
P4RuntimeClient over test_p4_client_writes.py's recording stub where the wire matters.

unittest rather than pytest: tools/test_workflow/l1_unit_tests.sh executes each file directly.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import grpc
    from p4.v1 import p4runtime_pb2

    from proxy_agent import api_routes
    from proxy_agent.topology_manager import TopologyManager
    from tests.test_p4_client_writes import (FLOW_5TUPLE_ID, FakeRpcError, RecordingStub,
                                             a_client, only_update)
    HAVE_DEPS = True
except ImportError:  # pragma: no cover - depends on the interpreter L1 picks
    HAVE_DEPS = False

#: MyIngress.drop's id in ndtwin_switch.p4info.txt. The fixture p4info does not declare it, so it
#: is added here with the real id.
DROP_ID = 25652968

BLOCK_MATCH = {"eth_type": 2048, "ipv4_src": "10.0.0.3"}
DEST_MATCH = {"eth_type": 2048, "ipv4_dst": "10.0.0.240"}
OUTPUT_2 = [{"type": "OUTPUT", "port": 2}]


class FakeRequest:
    def __init__(self, body):
        self._raw = json.dumps(body).encode()

    async def json(self):
        return json.loads(self._raw)


def add(body):
    return asyncio.run(api_routes.add_flow_entry(FakeRequest(body)))


def status_and_body(response):
    """(status, body) of a handler result: a dict is FastAPI's 200, a JSONResponse carries its own."""
    if isinstance(response, dict):
        return 200, response
    return response.status_code, json.loads(response.body)


def a_client_with_drop(stub):
    client = a_client(stub)
    action = client.p4info.actions.add()
    action.preamble.id = DROP_ID
    action.preamble.name = "MyIngress.drop"
    action.preamble.alias = "drop"
    return client


def a_topology(client):
    topo = TopologyManager()
    topo.add_switch(1, client)
    return topo


@unittest.skipUnless(HAVE_DEPS, "P4Runtime protobufs / FastAPI not available in this interpreter")
class ARefusedInstallIsNotA200Test(unittest.TestCase):
    """C-6: the status line says the write did not happen; the body is what it always was."""

    def setUp(self):
        self._saved = api_routes.topology

    def tearDown(self):
        api_routes.topology = self._saved

    def _wire(self, stub):
        api_routes.topology = a_topology(a_client_with_drop(stub))

    def test_a_write_the_switch_refuses_is_a_502_with_the_unchanged_body(self):
        # What a full table looks like from here: bmv2 answers UNKNOWN with no details to the
        # INSERT and to the MODIFY retry alike (C-6's 21 proxy-log lines).
        self._wire(RecordingStub(write_error=FakeRpcError(grpc.StatusCode.UNKNOWN, ""),
                                 always=True))
        status, body = status_and_body(add({"dpid": 1, "priority": 10, "match": DEST_MATCH,
                                            "actions": OUTPUT_2}))
        self.assertEqual(status, 502)
        self.assertEqual(body, {"status": "error", "message": "Failed to add route"})

    def test_a_write_the_switch_takes_is_still_a_200_success(self):
        # The accept path: a guard that refuses everything passes every refusal test.
        self._wire(RecordingStub())
        status, body = status_and_body(add({"dpid": 1, "priority": 10, "match": DEST_MATCH,
                                            "actions": OUTPUT_2}))
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "success")

    def test_an_unknown_switch_is_a_404_not_the_switchs_refusal(self):
        stub = RecordingStub()
        self._wire(stub)
        status, body = status_and_body(add({"dpid": 99, "priority": 10, "match": DEST_MATCH,
                                            "actions": OUTPUT_2}))
        self.assertEqual(status, 404)
        self.assertEqual((body["status"], body["message"]), ("error", "Failed to add route"))
        self.assertEqual(body["error"], "unknown switch")
        self.assertEqual(stub.requests, [], "nothing may reach a switch")

    def test_a_match_with_no_destination_is_a_400(self):
        stub = RecordingStub()
        self._wire(stub)
        status, body = status_and_body(add({"dpid": 1, "priority": 10,
                                            "match": {"eth_type": 2048}, "actions": OUTPUT_2}))
        self.assertEqual(status, 400)
        self.assertEqual(body["status"], "error")
        self.assertEqual(stub.requests, [])

    def test_a_destination_only_drop_is_a_501_unsupported_on_p4(self):
        # ipv4_lpm holds one entry per destination: a drop there would replace the route, which
        # is not what a drop rule means on OVS (it layers over the route). Refused, not obeyed.
        stub = RecordingStub()
        self._wire(stub)
        status, body = status_and_body(add({"dpid": 1, "priority": 10, "match": DEST_MATCH,
                                            "actions": []}))
        self.assertEqual(status, 501)
        self.assertEqual(body["outcome"], "unsupported_on_p4")
        self.assertEqual(body["status"], "error")
        self.assertEqual(stub.requests, [])

    def test_a_non_output_action_on_a_five_tuple_match_is_a_501(self):
        stub = RecordingStub()
        self._wire(stub)
        status, body = status_and_body(add({"dpid": 1, "priority": 10, "match": BLOCK_MATCH,
                                            "actions": [{"type": "SET_FIELD", "field": "x"}]}))
        self.assertEqual(status, 501)
        self.assertEqual(stub.requests, [])


@unittest.skipUnless(HAVE_DEPS, "P4Runtime protobufs / FastAPI not available in this interpreter")
class BlockHostIsADropRuleTest(unittest.TestCase):
    """A-4g: the kernel's BLOCK_HOST request reaches flow_5tuple as a drop entry."""

    def setUp(self):
        self._saved = api_routes.topology

    def tearDown(self):
        api_routes.topology = self._saved

    def test_block_host_writes_one_flow_5tuple_drop_entry_on_the_source(self):
        stub = RecordingStub()
        api_routes.topology = a_topology(a_client_with_drop(stub))

        status, body = status_and_body(add({"dpid": 1, "priority": 50000, "match": BLOCK_MATCH,
                                            "actions": []}))

        self.assertEqual(status, 200, body)
        self.assertEqual(body["status"], "success")
        self.assertEqual(body["table"], "flow_5tuple")
        self.assertEqual(len(stub.requests), 1)
        update = only_update(stub.requests[0])
        self.assertEqual(update.type, p4runtime_pb2.Update.INSERT)
        entry = update.entity.table_entry
        self.assertEqual(entry.table_id, FLOW_5TUPLE_ID)
        self.assertEqual(entry.action.action.action_id, DROP_ID)
        self.assertEqual(list(entry.action.action.params), [], "drop() takes no parameters")
        self.assertEqual(entry.priority, 50001, "OpenFlow 50000 on the +1 scale")
        self.assertEqual([m.field_id for m in entry.match], [2], "srcAddr is the second field")
        self.assertEqual(entry.match[0].ternary.value, bytes([10, 0, 0, 3]))
        self.assertEqual(entry.match[0].ternary.mask, b"\xff\xff\xff\xff")

    def test_an_existing_entry_is_turned_into_a_drop_by_the_modify_retry(self):
        # bmv2 answers UNKNOWN to an INSERT of a key that is there; the retry is a MODIFY.
        stub = RecordingStub(write_error=FakeRpcError(grpc.StatusCode.UNKNOWN, ""))
        api_routes.topology = a_topology(a_client_with_drop(stub))

        status, _ = status_and_body(add({"dpid": 1, "priority": 50000, "match": BLOCK_MATCH,
                                         "actions": []}))

        self.assertEqual(status, 200)
        self.assertEqual([only_update(r).type for r in stub.requests],
                         [p4runtime_pb2.Update.INSERT, p4runtime_pb2.Update.MODIFY])
        self.assertEqual(only_update(stub.requests[1]).entity.table_entry.action.action.action_id,
                         DROP_ID)

    def test_a_drop_the_switch_refuses_is_a_502(self):
        stub = RecordingStub(write_error=FakeRpcError(grpc.StatusCode.UNKNOWN, ""), always=True)
        api_routes.topology = a_topology(a_client_with_drop(stub))

        status, body = status_and_body(add({"dpid": 1, "priority": 50000, "match": BLOCK_MATCH,
                                            "actions": []}))

        self.assertEqual(status, 502)
        self.assertEqual(body, {"status": "error", "message": "Failed to add route"})


def call_handler(handler, body):
    """(status, body) for any of the three handlers, HTTPException included (modify raises)."""
    from fastapi import HTTPException
    try:
        return status_and_body(asyncio.run(handler(FakeRequest(body))))
    except HTTPException as err:
        return err.status_code, {"detail": err.detail}


FIVE_TUPLE_MATCH = {"eth_type": 2048, "ipv4_dst": "10.0.0.240", "tcp_dst": 80, "ip_proto": 6}


@unittest.skipUnless(HAVE_DEPS, "P4Runtime protobufs / FastAPI not available in this interpreter")
class ARefusedDeleteOrModifyIsNotA200Or400Test(unittest.TestCase):
    """
    C-6's delete and modify halves. A delete the switch refused was a
    200 {"status":"error"}; a modify the switch refused was a 400, the client's-mistake code.
    Both are 502 now with their bodies unchanged; the refusals that are not the switch's get the
    same 404 / 400 / 501 split as add.
    """

    def setUp(self):
        self._saved = api_routes.topology

    def tearDown(self):
        api_routes.topology = self._saved

    def _wire(self, stub):
        api_routes.topology = a_topology(a_client_with_drop(stub))

    @staticmethod
    def _refusing():
        # NOT_FOUND on every write: what bmv2 answers a delete or modify of an absent entry.
        return RecordingStub(write_error=FakeRpcError(grpc.StatusCode.NOT_FOUND, ""), always=True)

    # --- the switch said no: 502, body as it was --------------------------------------------

    def test_a_destination_delete_the_switch_refuses_is_a_502_with_the_unchanged_body(self):
        # Not NOT_FOUND here: delete_ipv4_route counts "already gone" as done, and so does an
        # UNKNOWN whose read-back finds no entry. A refusal that leaves the entry is anything else.
        self._wire(RecordingStub(write_error=FakeRpcError(grpc.StatusCode.INTERNAL, ""),
                                 always=True))
        status, body = call_handler(api_routes.delete_flow_entry,
                                    {"dpid": 1, "match": DEST_MATCH})
        self.assertEqual(status, 502)
        self.assertEqual(body, {"status": "error", "message": "Failed to delete route"})

    def test_a_five_tuple_delete_the_switch_refuses_is_a_502(self):
        self._wire(self._refusing())
        status, body = call_handler(api_routes.delete_flow_entry,
                                    {"dpid": 1, "priority": 100, "match": FIVE_TUPLE_MATCH})
        self.assertEqual(status, 502)
        self.assertEqual(body["status"], "error")

    def test_a_destination_modify_the_switch_refuses_is_a_502_not_a_400(self):
        self._wire(self._refusing())
        status, body = call_handler(api_routes.modify_flow_entry,
                                    {"dpid": 1, "match": DEST_MATCH, "actions": OUTPUT_2})
        self.assertEqual(status, 502)
        self.assertEqual(body, {"detail": "Failed to modify flow entry in P4 switch"})

    def test_a_five_tuple_modify_the_switch_refuses_is_a_502(self):
        self._wire(self._refusing())
        status, _ = call_handler(api_routes.modify_flow_entry,
                                 {"dpid": 1, "priority": 100, "match": FIVE_TUPLE_MATCH,
                                  "actions": OUTPUT_2})
        self.assertEqual(status, 502)

    # --- the accept paths, so a guard that refuses everything cannot pass ---------------------

    def test_a_delete_the_switch_takes_is_still_a_200_success(self):
        self._wire(RecordingStub())
        status, body = call_handler(api_routes.delete_flow_entry,
                                    {"dpid": 1, "match": DEST_MATCH})
        self.assertEqual((status, body["status"]), (200, "success"))

    def test_a_modify_the_switch_takes_is_still_a_200_success(self):
        self._wire(RecordingStub())
        status, body = call_handler(api_routes.modify_flow_entry,
                                    {"dpid": 1, "match": DEST_MATCH, "actions": OUTPUT_2})
        self.assertEqual((status, body["status"]), (200, "success"))

    # --- not the switch's refusal: 404 / 400 / 501, nothing on the wire ------------------------

    def test_an_unknown_switch_is_a_404_on_delete_and_modify(self):
        stub = RecordingStub()
        self._wire(stub)
        status, body = call_handler(api_routes.delete_flow_entry,
                                    {"dpid": 99, "match": DEST_MATCH})
        self.assertEqual(status, 404)
        self.assertEqual((body["status"], body["message"], body["error"]),
                         ("error", "Failed to delete route", "unknown switch"))
        status, body = call_handler(api_routes.modify_flow_entry,
                                    {"dpid": 99, "match": DEST_MATCH, "actions": OUTPUT_2})
        self.assertEqual(status, 404)
        self.assertEqual(body["detail"]["error"], "unknown switch")
        self.assertEqual(stub.requests, [])

    def test_a_match_with_no_destination_is_a_400_on_delete_and_modify(self):
        stub = RecordingStub()
        self._wire(stub)
        status, _ = call_handler(api_routes.delete_flow_entry,
                                 {"dpid": 1, "match": {"eth_type": 2048}})
        self.assertEqual(status, 400)
        status, _ = call_handler(api_routes.modify_flow_entry,
                                 {"dpid": 1, "match": {"eth_type": 2048}, "actions": OUTPUT_2})
        self.assertEqual(status, 400)
        self.assertEqual(stub.requests, [])

    def test_a_modify_without_an_output_action_is_a_501_unsupported_on_p4(self):
        stub = RecordingStub()
        self._wire(stub)
        status, body = call_handler(api_routes.modify_flow_entry,
                                    {"dpid": 1, "match": DEST_MATCH, "actions": []})
        self.assertEqual(status, 501)
        self.assertEqual(body["detail"]["outcome"], "unsupported_on_p4")
        self.assertEqual(stub.requests, [])


if __name__ == "__main__":
    unittest.main()
