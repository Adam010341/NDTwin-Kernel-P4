"""
`GET /p4/counter/{name}` -- three outcomes, three status codes, and none of them is a zero.
TICKET-P3 2.6 (G7).

[Co-developed with claude code -- Adam]

🔴 THE POINT OF THE ENDPOINT IS THE 503. `read_egress_counter` was given a three-outcome
contract precisely because answering `0, 0` to "counter absent from the p4info", "the RPC
failed" and "this port forwarded nothing" makes the instrument's failure mode identical to its
most interesting finding. An endpoint that flattened those three back into one number would undo
that, so the mapping is asserted here one row at a time:

    200  a real reading, INCLUDING a truthful (0, 0)
    404  the counter is not in this pipeline (structural, permanent), or the dpid is unknown
    503  the read failed, or the switch reported no entry for that index

The handler is called directly rather than through a FastAPI TestClient, the convention
test_table_entry_route.py states and for its reason: `starlette.testclient` will not import in
this venv, so the routing layer is asserted directly instead (TheRouteIsRegisteredTest).

Run with:  p4_proxy/venv/bin/python -m unittest tests.test_counter_route
"""

from __future__ import annotations

import asyncio
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import grpc
    from fastapi import HTTPException
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2

    from proxy_agent import api_routes
    from proxy_agent.p4_client import P4RuntimeClient

    class FakeRpcError(grpc.RpcError):
        def __init__(self, code=None, details="fake failure"):
            self._code = code
            self._details = details

        def code(self):
            return self._code

        def details(self):
            return self._details

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False


EGRESS_COUNTER_ID = 312422001
SWID_COUNTER_ID = 312422002


def a_p4info():
    """Two counters: ndtwin's own, and one whose alias differs from its full name.

    The second exists because tutorials' helpers spell a counter both ways -- `MyEgress.swid`
    and `swid` name one object -- and an endpoint that accepted only `preamble.name` would turn
    a correct request into "not in this pipeline", which reads as a wiring error.
    """
    p4info = p4info_pb2.P4Info()
    egress = p4info.counters.add()
    egress.preamble.id = EGRESS_COUNTER_ID
    egress.preamble.name = "MyEgress.egress_port_counter"
    egress.preamble.alias = "egress_port_counter"

    swid = p4info.counters.add()
    swid.preamble.id = SWID_COUNTER_ID
    swid.preamble.name = "MyEgress.swid_counter"
    swid.preamble.alias = "swid_counter"
    return p4info


class ReadingStub:
    """Answers Read with a counter entry, with nothing, or with an error."""

    def __init__(self, entries=None, read_error=None):
        #: {(counter_id, index): (bytes, packets)}
        self.entries = dict(entries or {})
        self.read_error = read_error
        self.reads = []

    def Read(self, request, timeout=None):
        self.reads.append(request)
        if self.read_error is not None:
            raise self.read_error
        out = []
        for entity in request.entities:
            if not entity.HasField("counter_entry"):
                continue
            key = (entity.counter_entry.counter_id, entity.counter_entry.index.index)
            if key not in self.entries:
                continue
            byte_count, packet_count = self.entries[key]
            response = p4runtime_pb2.ReadResponse()
            answer = response.entities.add()
            answer.counter_entry.counter_id = key[0]
            answer.counter_entry.index.index = key[1]
            answer.counter_entry.data.byte_count = byte_count
            answer.counter_entry.data.packet_count = packet_count
            out.append(response)
        return iter(out)


def a_client(stub, device_id=1, arbitration=True):
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = device_id
    client.grpc_addr = "127.0.0.1:50051"
    client.p4info = a_p4info()
    client.stub = stub
    client.arbitration = arbitration
    client.election_id = (0, 1)
    return client


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class CounterRouteTestBase(unittest.TestCase):
    def setUp(self):
        self.saved = api_routes.topology
        self.addCleanup(self.restore)
        self.stub = ReadingStub({(EGRESS_COUNTER_ID, 3): (4096, 12),
                                 (EGRESS_COUNTER_ID, 4): (0, 0),
                                 (SWID_COUNTER_ID, 1): (99, 1)})
        self.client = a_client(self.stub)
        api_routes.topology = FakeTopology({1: self.client})

    def restore(self):
        api_routes.topology = self.saved

    def get(self, name="MyEgress.egress_port_counter", dpid=1, index=3):
        return asyncio.run(api_routes.counter(name, dpid=dpid, index=index))

    def refused(self, **kwargs):
        with self.assertRaises(HTTPException) as caught:
            self.get(**kwargs)
        return caught.exception


class TheReadingItselfTest(CounterRouteTestBase):
    def test_a_reading_is_200_with_both_numbers(self):
        body = self.get()
        self.assertEqual(body, {"dpid": 1, "counter": "MyEgress.egress_port_counter",
                                "index": 3, "bytes": 4096, "packets": 12})

    def test_the_request_names_the_counter_id_and_the_index_it_was_asked_for(self):
        # The one thing a caller cannot verify from the response: a handler that read index 0
        # for every request would return a perfectly plausible body.
        self.get(index=4)
        self.assertEqual(len(self.stub.reads), 1)
        entity = self.stub.reads[0].entities[0]
        self.assertEqual(entity.counter_entry.counter_id, EGRESS_COUNTER_ID)
        self.assertEqual(entity.counter_entry.index.index, 4)
        self.assertEqual(self.stub.reads[0].device_id, 1)

    def test_a_truthful_zero_is_a_200_and_not_a_503(self):
        # A port that forwarded nothing is a MEASUREMENT. Collapsing it into the failure code
        # would be the same conflation the three-outcome contract was written to end.
        self.assertEqual(self.get(index=4), {"dpid": 1,
                                             "counter": "MyEgress.egress_port_counter",
                                             "index": 4, "bytes": 0, "packets": 0})

    def test_an_alias_names_the_same_counter(self):
        body = self.get(name="swid_counter", index=1)
        self.assertEqual((body["bytes"], body["packets"]), (99, 1))
        self.assertEqual(self.stub.reads[0].entities[0].counter_entry.counter_id,
                         SWID_COUNTER_ID)

    def test_the_full_name_names_it_too(self):
        body = self.get(name="MyEgress.swid_counter", index=1)
        self.assertEqual((body["bytes"], body["packets"]), (99, 1))

    def test_a_read_needs_no_election_id(self):
        # 🔴 P4Runtime's ReadRequest HAS NO election_id FIELD AT ALL -- that is the mechanism
        # behind "this endpoint works under an external control plane", and it is a fact about
        # the protobuf rather than about this proxy. Asserted here because every other reason
        # the external case works is downstream of it: if a future P4Runtime added the field and
        # PI started requiring it, the 200 below would become PERMISSION_DENIED and the fix
        # would not be in this file.
        self.get()
        fields = {f.name for f in self.stub.reads[0].DESCRIPTOR.fields}
        self.assertNotIn("election_id", fields)
        self.assertIn("device_id", fields)
        self.assertIn("entities", fields)


class TheRefusalsTest(CounterRouteTestBase):
    def test_an_unknown_dpid_is_404(self):
        error = self.refused(dpid=9)
        self.assertEqual(error.status_code, 404)
        self.assertEqual(error.detail["error"], "unknown switch")
        self.assertEqual(self.stub.reads, [], "nothing may be read from a switch we do not have")

    def test_a_counter_this_pipeline_does_not_have_is_404(self):
        error = self.refused(name="MyEgress.no_such_counter")
        self.assertEqual(error.status_code, 404)
        self.assertEqual(error.detail["error"], "not in this pipeline")
        # The message has to say it is structural, or a caller retries a permanent condition.
        self.assertIn("not a measurement of zero", error.detail["message"])
        self.assertEqual(self.stub.reads, [])

    def test_an_index_with_no_entry_is_503_and_says_it_is_not_a_zero(self):
        error = self.refused(index=7)
        self.assertEqual(error.status_code, 503)
        self.assertEqual(error.detail["error"], "counter not read")
        self.assertIn("NOT a reading of zero", error.detail["message"])
        self.assertEqual(len(self.stub.reads), 1, "the read was attempted; it answered nothing")

    def test_a_failed_read_is_503_rather_than_a_zero(self):
        self.stub.read_error = FakeRpcError(grpc.StatusCode.UNAVAILABLE)
        error = self.refused()
        self.assertEqual(error.status_code, 503)
        self.assertIn("NOT a reading of zero", error.detail["message"])

    def test_a_negative_index_is_400_and_reaches_no_switch(self):
        error = self.refused(index=-1)
        self.assertEqual(error.status_code, 400)
        self.assertEqual(self.stub.reads, [])

    def test_no_topology_is_503(self):
        api_routes.topology = None
        error = self.refused()
        self.assertEqual(error.status_code, 503)


class AnExternalControlPlaneCanStillReadTest(CounterRouteTestBase):
    """🔴 The one endpoint of this ticket that is NOT 409 under `external`."""

    def setUp(self):
        super().setUp()
        self.client.arbitration = False
        api_routes.topology = FakeTopology({1: self.client})

    def test_a_read_only_client_answers_200(self):
        body = self.get()
        self.assertEqual((body["bytes"], body["packets"]), (4096, 12))

    def test_the_read_still_went_to_the_switch(self):
        self.get()
        self.assertEqual(len(self.stub.reads), 1)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheRouteIsRegisteredTest(unittest.TestCase):
    """A handler nothing routes to is a handler nobody can call, and every test above would
    still pass. This is the only assertion that the decorator is on it."""

    def test_the_path_and_method_are_on_the_router(self):
        matches = [r for r in api_routes.router.routes
                   if getattr(r, "path", None) == "/p4/counter/{name}"]
        self.assertEqual(len(matches), 1, "the counter route is not registered")
        self.assertIn("GET", matches[0].methods)

    def test_the_name_is_a_path_parameter_so_a_dotted_name_survives(self):
        # `MyEgress.egress_port_counter` has dots in it. A query parameter would have worked
        # too; a path parameter is what the ticket specifies, and a path parameter that somebody
        # later makes greedy (`{name:path}`) would start swallowing slashes.
        matches = [r for r in api_routes.router.routes
                   if getattr(r, "path", None) == "/p4/counter/{name}"]
        self.assertEqual(matches[0].param_convertors["name"].__class__.__name__,
                         "StringConvertor")


if __name__ == "__main__":
    unittest.main(verbosity=2)
