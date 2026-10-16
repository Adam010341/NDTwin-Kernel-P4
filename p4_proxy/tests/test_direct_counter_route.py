"""
`GET /p4/direct_counter/{name}` -- every entry of the counter's table with its byte and packet
counts -- and the deadline both counter reads now carry.

[Co-developed with claude code -- Adam]

A direct counter has no index: it is one cell per table entry. `GET /p4/counter` only ever
looked in `p4info.counters`, so a sketch or measurement app that counts with a direct counter
(the health check's K2) got 404 "not in this pipeline" for a counter that IS in the pipeline.
bmv2 answers a DirectCounterEntry read -- one entry or the whole table -- on both builds, stock
and bmv2-fast (doc/audit/2026-10-16_p4-register-read/DESIGN.md section 1), so the route reads the
whole table in ONE wildcard RPC and the app finds its entry by match.

The three outcomes are GET /p4/counter's:

    200  a real reading, INCLUDING a truthful (0, 0) and an empty table
    404  an unknown dpid, or a name this switch's p4info does not list as a direct counter
    503  the read failed (a deadline included) -- NOT a zero

The handler is called directly, as in test_counter_route.py and for its reason (starlette's
TestClient does not import in this venv), and TheRouteIsRegisteredTest asserts the decorator.

Run with:  p4_proxy/venv/bin/python -m unittest tests.test_direct_counter_route
"""

from __future__ import annotations

import asyncio
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import grpc
    from fastapi import HTTPException
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2

    from proxy_agent import api_routes
    from proxy_agent import route_binding
    from proxy_agent.p4_client import P4RuntimeClient, RPC_TIMEOUT_S

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


T_DCOUNT_ID = 44315755
T_ACL_ID = 44315756
T_PK_ID = 44315757
DC_K2_ID = 329684557
DC_ACL_ID = 329684558
DC_PK_ID = 329684559
C_IN_ID = 317599709
DPORT_FIELD = 1
SRC_FIELD, DST_FIELD, SPORT_FIELD, PROTO_FIELD = 1, 2, 3, 4


def a_p4info():
    """hc_main's t_dcount / dc_k2 (the ids the 2026-10-16 measurement read), a second table whose
    match uses every other kind, a third whose direct counter counts packets only, and one indexed
    counter."""
    p4info = p4info_pb2.P4Info()
    t = p4info.tables.add()
    t.preamble.id, t.preamble.name, t.preamble.alias = T_DCOUNT_ID, "HcIngress.t_dcount", "t_dcount"
    f = t.match_fields.add()
    f.id, f.name, f.bitwidth = DPORT_FIELD, "hdr.udp.dstPort", 16
    f.match_type = p4info_pb2.MatchField.EXACT
    t.direct_resource_ids.append(DC_K2_ID)

    acl = p4info.tables.add()
    acl.preamble.id, acl.preamble.name, acl.preamble.alias = T_ACL_ID, "PkgIngress.acl", "acl"
    for fid, name, width, kind in ((SRC_FIELD, "hdr.ipv4.srcAddr", 32, p4info_pb2.MatchField.LPM),
                                   (DST_FIELD, "hdr.ipv4.dstAddr", 32, p4info_pb2.MatchField.TERNARY),
                                   (SPORT_FIELD, "hdr.udp.srcPort", 16, p4info_pb2.MatchField.RANGE),
                                   (PROTO_FIELD, "hdr.ipv4.protocol", 8, p4info_pb2.MatchField.OPTIONAL)):
        g = acl.match_fields.add()
        g.id, g.name, g.bitwidth, g.match_type = fid, name, width, kind
    acl.direct_resource_ids.append(DC_ACL_ID)

    dc = p4info.direct_counters.add()
    dc.preamble.id, dc.preamble.name, dc.preamble.alias = DC_K2_ID, "HcIngress.dc_k2", "dc_k2"
    dc.direct_table_id = T_DCOUNT_ID
    dc.spec.unit = p4info_pb2.CounterSpec.BOTH
    dc2 = p4info.direct_counters.add()
    dc2.preamble.id, dc2.preamble.name, dc2.preamble.alias = DC_ACL_ID, "PkgIngress.acl_counter", "acl_counter"
    dc2.direct_table_id = T_ACL_ID
    dc2.spec.unit = p4info_pb2.CounterSpec.BOTH

    pk = p4info.tables.add()
    pk.preamble.id, pk.preamble.name, pk.preamble.alias = T_PK_ID, "HcIngress.t_pk", "t_pk"
    h = pk.match_fields.add()
    h.id, h.name, h.bitwidth, h.match_type = DPORT_FIELD, "hdr.udp.dstPort", 16, p4info_pb2.MatchField.EXACT
    pk.direct_resource_ids.append(DC_PK_ID)
    dc3 = p4info.direct_counters.add()
    dc3.preamble.id, dc3.preamble.name, dc3.preamble.alias = DC_PK_ID, "HcIngress.dc_pk", "dc_pk"
    dc3.direct_table_id = T_PK_ID
    dc3.spec.unit = p4info_pb2.CounterSpec.PACKETS

    c = p4info.counters.add()
    c.preamble.id, c.preamble.name, c.preamble.alias = C_IN_ID, "HcIngress.c_in", "c_in"
    return p4info


def dport_entry(dport, byte_count=None, packet_count=None, table_id=None, no_data=False):
    """A DirectCounterEntry as bmv2's wildcard read returns it: the entry's table id and match,
    no action, and `data` -- empty (all zero) until the entry has counted something. `no_data`:
    the field left out altogether, which bmv2 was not seen to do and another target may."""
    e = p4runtime_pb2.Entity()
    te = e.direct_counter_entry.table_entry
    te.table_id = T_DCOUNT_ID if table_id is None else table_id
    m = te.match.add()
    m.field_id = DPORT_FIELD
    m.exact.value = dport.to_bytes(2, "big")
    e.direct_counter_entry.data.SetInParent()
    if byte_count is not None:
        e.direct_counter_entry.data.byte_count = byte_count
        e.direct_counter_entry.data.packet_count = packet_count
    if no_data:
        e.direct_counter_entry.ClearField("data")
    return e


def acl_entry():
    e = p4runtime_pb2.Entity()
    te = e.direct_counter_entry.table_entry
    te.table_id = T_ACL_ID
    te.priority = 10
    m = te.match.add()
    m.field_id = SRC_FIELD
    m.lpm.value, m.lpm.prefix_len = bytes([10, 0, 1, 0]), 24
    m = te.match.add()
    m.field_id = DST_FIELD
    m.ternary.value, m.ternary.mask = bytes([10, 0, 2, 0]), bytes([255, 255, 255, 0])
    m = te.match.add()
    m.field_id = SPORT_FIELD
    m.range.low, m.range.high = (1000).to_bytes(2, "big"), (2000).to_bytes(2, "big")
    m = te.match.add()
    m.field_id = PROTO_FIELD
    m.optional.value = bytes([17])
    e.direct_counter_entry.data.byte_count = 640
    e.direct_counter_entry.data.packet_count = 10
    return e


class ReadingStub:
    """Answers a Read with the entities configured for the table the request names, or raises.
    Records every request and the deadline it carried."""

    def __init__(self, by_table=None, read_error=None, counter_entries=None):
        self.by_table = dict(by_table or {})
        self.read_error = read_error
        self.counter_entries = dict(counter_entries or {})
        self.reads = []
        self.timeouts = []
        self.threads = []

    def Read(self, request, timeout=None):
        self.reads.append(request)
        self.timeouts.append(timeout)
        self.threads.append(threading.get_ident())
        if self.read_error is not None:
            raise self.read_error
        out = []
        for entity in request.entities:
            if entity.HasField("direct_counter_entry"):
                for ent in self.by_table.get(entity.direct_counter_entry.table_entry.table_id, []):
                    response = p4runtime_pb2.ReadResponse()
                    response.entities.add().CopyFrom(ent)
                    out.append(response)
            elif entity.HasField("counter_entry"):
                key = (entity.counter_entry.counter_id, entity.counter_entry.index.index)
                if key in self.counter_entries:
                    response = p4runtime_pb2.ReadResponse()
                    a = response.entities.add().counter_entry
                    a.counter_id, a.index.index = key
                    a.data.byte_count, a.data.packet_count = self.counter_entries[key]
                    out.append(response)
        return iter(out)


def a_client(stub, arbitration=True, binding=None):
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = 2
    client.grpc_addr = "127.0.0.1:50051"
    client.p4info = a_p4info()
    client.stub = stub
    client.arbitration = arbitration
    client.election_id = (0, 1)
    client.route_binding = binding
    return client


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


class FakeJournals:
    """api_routes.table_journals during a readopt: `pending` is what POST /p4/table_entry asks."""

    def __init__(self, pending=()):
        self.pending_dpids = set(pending)

    def pending(self, dpid):
        return dpid in self.pending_dpids


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class DirectCounterRouteTestBase(unittest.TestCase):
    def setUp(self):
        self.saved = api_routes.topology, api_routes.table_journals
        self.addCleanup(self.restore)
        self.stub = ReadingStub({T_DCOUNT_ID: [dport_entry(40012, 335, 5), dport_entry(40013)],
                                 T_ACL_ID: [acl_entry()],
                                 T_PK_ID: [dport_entry(40014, 670, 10, table_id=T_PK_ID)]},
                                counter_entries={(C_IN_ID, 0): (134, 2)})
        self.client = a_client(self.stub)
        api_routes.topology = FakeTopology({2: self.client})
        api_routes.table_journals = None

    def restore(self):
        api_routes.topology, api_routes.table_journals = self.saved

    def get(self, name="HcIngress.dc_k2", dpid=2):
        return asyncio.run(api_routes.direct_counter(name, dpid=dpid))

    def refused(self, **kwargs):
        with self.assertRaises(HTTPException) as caught:
            self.get(**kwargs)
        return caught.exception


class TheReadingItselfTest(DirectCounterRouteTestBase):
    def test_a_reading_is_200_with_every_entry_of_the_table(self):
        self.assertEqual(self.get(), {
            "dpid": 2, "counter": "HcIngress.dc_k2", "table": "HcIngress.t_dcount", "unit": "both",
            "entries": [
                {"match": {"hdr.udp.dstPort": {"type": "exact", "value": 40012}},
                 "priority": 0, "bytes": 335, "packets": 5},
                {"match": {"hdr.udp.dstPort": {"type": "exact", "value": 40013}},
                 "priority": 0, "bytes": 0, "packets": 0}]})

    def test_the_request_is_one_wildcard_read_over_the_counters_own_table(self):
        # The one thing a caller cannot check from the body: a handler that read some other
        # table, or one entry, would still return a plausible list.
        self.get()
        self.assertEqual(len(self.stub.reads), 1)
        req = self.stub.reads[0]
        self.assertEqual(req.device_id, 2)
        self.assertEqual(len(req.entities), 1)
        te = req.entities[0].direct_counter_entry.table_entry
        self.assertEqual(te.table_id, T_DCOUNT_ID)
        self.assertEqual(len(te.match), 0, "a match would make it a one-entry read")

    def test_the_read_carries_a_deadline(self):
        # A Read with no deadline waits forever on a SIGSTOPed bmv2 (read_table_entries'
        # docstring, measured 2026-08-13), and here it would hold a threadpool thread per request.
        self.get()
        self.assertEqual(self.stub.timeouts, [RPC_TIMEOUT_S])

    def test_a_truthful_zero_entry_is_part_of_the_200(self):
        body = self.get()
        self.assertEqual((body["entries"][1]["bytes"], body["entries"][1]["packets"]), (0, 0))

    def test_an_empty_table_is_200_with_no_entries(self):
        self.stub.by_table[T_DCOUNT_ID] = []
        self.assertEqual(self.get()["entries"], [])

    def test_an_alias_names_the_same_counter(self):
        body = self.get(name="dc_k2")
        self.assertEqual(body["counter"], "HcIngress.dc_k2")
        self.assertEqual(body["entries"][0]["packets"], 5)

    def test_every_match_kind_is_rendered_as_integers_with_the_priority(self):
        body = self.get(name="PkgIngress.acl_counter")
        self.assertEqual(body["table"], "PkgIngress.acl")
        self.assertEqual(body["entries"], [{
            "match": {"hdr.ipv4.srcAddr": {"type": "lpm", "value": 0x0A000100, "prefix_len": 24},
                      "hdr.ipv4.dstAddr": {"type": "ternary", "value": 0x0A000200,
                                           "mask": 0xFFFFFF00},
                      "hdr.udp.srcPort": {"type": "range", "low": 1000, "high": 2000},
                      "hdr.ipv4.protocol": {"type": "optional", "value": 17}},
            "priority": 10, "bytes": 640, "packets": 10}])

    def test_an_entry_the_switch_sent_no_data_for_is_null_not_zero(self):
        # read_table_entries keeps such an entry with counters None; a 0 here would be a
        # measurement nobody made.
        self.stub.by_table[T_DCOUNT_ID] = [dport_entry(40012, 335, 5), dport_entry(40013, no_data=True)]
        entries = self.get()["entries"]
        self.assertEqual((entries[0]["bytes"], entries[0]["packets"]), (335, 5))
        self.assertEqual((entries[1]["bytes"], entries[1]["packets"]), (None, None))

    def test_a_packets_only_counter_reports_no_bytes_and_says_its_unit(self):
        # The protobuf default for the byte count a PACKETS counter never keeps is 0.
        body = self.get(name="HcIngress.dc_pk")
        self.assertEqual(body["unit"], "packets")
        self.assertEqual((body["entries"][0]["bytes"], body["entries"][0]["packets"]), (None, 10))

    def test_a_bytes_only_counter_reports_no_packets(self):
        self.client.p4info.direct_counters[2].spec.unit = p4info_pb2.CounterSpec.BYTES
        body = self.get(name="HcIngress.dc_pk")
        self.assertEqual(body["unit"], "bytes")
        self.assertEqual((body["entries"][0]["bytes"], body["entries"][0]["packets"]), (670, None))

    def test_a_name_that_is_both_kinds_is_read_as_the_direct_counter(self):
        # An indexed counter whose alias is the direct counter's: this route must not send the
        # caller to /p4/counter for a name it can read.
        c = self.client.p4info.counters.add()
        c.preamble.id, c.preamble.name, c.preamble.alias = 317599710, "HcEgress.k2_copy", "dc_k2"
        self.assertEqual(self.get(name="dc_k2")["entries"][0]["packets"], 5)

    def test_an_answer_this_p4info_cannot_render_is_502_and_not_a_read_failure(self):
        def broken(table_id, match):
            raise KeyError("field id 9 is not in this table")
        self.client._match_as_dict = broken
        error = self.refused()
        self.assertEqual(error.status_code, 502)
        self.assertEqual(error.detail["error"], "direct counter not rendered")
        self.assertNotIn("ran out of time", error.detail["message"])
        self.assertEqual(len(self.stub.reads), 1, "the switch was read; it answered")

    def test_an_entity_of_another_table_is_not_reported(self):
        # A target that answered a wildcard with more than was asked must not have that
        # reported under this counter's name.
        self.stub.by_table[T_DCOUNT_ID] = [dport_entry(40012, 335, 5), acl_entry()]
        self.assertEqual(len(self.get()["entries"]), 1)


class TheRefusalsTest(DirectCounterRouteTestBase):
    def test_an_unknown_dpid_is_404_and_reads_nothing(self):
        error = self.refused(dpid=9)
        self.assertEqual(error.status_code, 404)
        self.assertEqual(error.detail["error"], "unknown switch")
        self.assertEqual(self.stub.reads, [])

    def test_a_name_that_is_no_direct_counter_is_404_and_reads_nothing(self):
        error = self.refused(name="HcIngress.no_such_counter")
        self.assertEqual(error.status_code, 404)
        self.assertEqual(error.detail["error"], "not in this pipeline")
        self.assertEqual(self.stub.reads, [])

    def test_an_indexed_counter_is_404_and_points_at_the_counter_route(self):
        error = self.refused(name="HcIngress.c_in")
        self.assertEqual(error.status_code, 404)
        self.assertEqual(error.detail["error"], "indexed counter")
        self.assertIn("/p4/counter/", error.detail["message"])
        self.assertEqual(self.stub.reads, [])

    def test_a_failed_read_is_503_and_says_it_is_not_a_zero(self):
        self.stub.read_error = FakeRpcError(grpc.StatusCode.UNAVAILABLE)
        error = self.refused()
        self.assertEqual(error.status_code, 503)
        self.assertEqual(error.detail["error"], "direct counter not read")
        self.assertIn("NOT a reading of zero", error.detail["message"])

    def test_a_deadline_is_503_too(self):
        self.stub.read_error = FakeRpcError(grpc.StatusCode.DEADLINE_EXCEEDED, "Deadline Exceeded")
        self.assertEqual(self.refused().status_code, 503)

    def test_no_topology_is_503(self):
        api_routes.topology = None
        self.assertEqual(self.refused().status_code, 503)

    def test_a_switch_being_readopted_is_503_replay_pending_and_reads_nothing(self):
        # As POST /p4/table_entry answers in that window: the tables are being put back, so a
        # read now would report entries missing that are about to return.
        api_routes.table_journals = FakeJournals(pending={2})
        error = self.refused()
        self.assertEqual(error.status_code, 503)
        self.assertEqual(error.detail["error"], "replay pending")
        self.assertEqual(self.stub.reads, [])

    def test_another_switch_being_readopted_does_not_stop_this_read(self):
        api_routes.table_journals = FakeJournals(pending={3})
        self.assertEqual(self.get()["entries"][0]["packets"], 5)


class TheReadStaysOffTheEventLoopTest(DirectCounterRouteTestBase):
    """Both routes are `async def`, so the gRPC read is put on a worker thread by hand
    (run_in_threadpool). A rewrite that called it directly would return the same body and park
    the event loop -- every endpoint of the proxy -- behind one switch that stopped answering
    (test_flow_stats_route.py's BlockingWorkStaysOffTheEventLoopTest, measured 2026-08-13).
    Compared by thread identity, the property that matters, not by the spelling of the call."""

    def on_loop(self, coro_fn, *a, **kw):
        async def drive():
            return threading.get_ident(), await coro_fn(*a, **kw)
        return asyncio.run(drive())

    def test_the_direct_read_runs_on_a_worker_thread(self):
        loop_thread, body = self.on_loop(api_routes.direct_counter, "HcIngress.dc_k2", dpid=2)
        self.assertEqual(body["entries"][0]["packets"], 5)
        self.assertEqual(len(self.stub.threads), 1)
        self.assertNotEqual(self.stub.threads[0], loop_thread,
                            "GET /p4/direct_counter read the switch on the event loop thread")

    def test_the_indexed_read_runs_on_a_worker_thread(self):
        loop_thread, body = self.on_loop(api_routes.counter, "HcIngress.c_in", dpid=2, index=0)
        self.assertEqual(body["packets"], 2)
        self.assertEqual(len(self.stub.threads), 1)
        self.assertNotEqual(self.stub.threads[0], loop_thread,
                            "GET /p4/counter read the switch on the event loop thread")


class ReadsAreNotOwnerChecked(DirectCounterRouteTestBase):
    """V7 is about WRITES into NDTwin's tables. On NDTwin's own pipeline every table is NDTwin's,
    and GET /stats/flow already reports its direct counters; a read changes nothing."""

    def test_a_counter_on_a_table_ndtwin_owns_is_still_read(self):
        self.client.route_binding = route_binding.BASELINE
        self.assertTrue(self.client.table_owned_by_ndtwin(self.client.p4info.tables[0]))
        self.assertEqual(self.get()["entries"][0]["packets"], 5)


class AnExternalControlPlaneCanStillReadTest(DirectCounterRouteTestBase):
    def setUp(self):
        super().setUp()
        self.client.arbitration = False

    def test_a_read_only_client_answers_200(self):
        self.assertEqual(self.get()["entries"][0]["bytes"], 335)
        self.assertEqual(len(self.stub.reads), 1)


class TheIndexedCounterRouteTest(DirectCounterRouteTestBase):
    """GET /p4/counter's two changes: its read now has a deadline, and a direct counter's name
    is told where to go instead of being called absent."""

    def counter(self, name="HcIngress.c_in", index=0):
        return asyncio.run(api_routes.counter(name, dpid=2, index=index))

    def test_the_indexed_read_carries_a_deadline_too(self):
        self.assertEqual(self.counter(), {"dpid": 2, "counter": "HcIngress.c_in", "index": 0,
                                          "bytes": 134, "packets": 2})
        self.assertEqual(self.stub.timeouts, [RPC_TIMEOUT_S])

    def test_a_direct_counter_name_is_404_and_points_at_the_direct_route(self):
        with self.assertRaises(HTTPException) as caught:
            self.counter(name="HcIngress.dc_k2")
        self.assertEqual(caught.exception.status_code, 404)
        self.assertEqual(caught.exception.detail["error"], "direct counter")
        self.assertIn("/p4/direct_counter/HcIngress.dc_k2", caught.exception.detail["message"])
        self.assertEqual(self.stub.reads, [])

    def test_a_name_that_is_neither_keeps_the_old_404(self):
        # The health check's K1-neg control reads exactly this word for an unknown counter.
        with self.assertRaises(HTTPException) as caught:
            self.counter(name="HcIngress.no_such_counter")
        self.assertEqual(caught.exception.status_code, 404)
        self.assertEqual(caught.exception.detail["error"], "not in this pipeline")


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheRouteIsRegisteredTest(unittest.TestCase):
    def matches(self):
        return [r for r in api_routes.router.routes
                if getattr(r, "path", None) == "/p4/direct_counter/{name}"]

    def test_the_path_and_method_are_on_the_router(self):
        self.assertEqual(len(self.matches()), 1, "the direct counter route is not registered")
        self.assertIn("GET", self.matches()[0].methods)

    def test_the_name_is_a_plain_path_parameter(self):
        self.assertEqual(self.matches()[0].param_convertors["name"].__class__.__name__,
                         "StringConvertor")


if __name__ == "__main__":
    unittest.main(verbosity=2)
