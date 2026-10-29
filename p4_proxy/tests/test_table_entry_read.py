"""
`GET /p4/table_entry?dpid=<n>&table=<name>` -- a table's entries read back in the shape
`POST /p4/table_entry` takes, so an entry read back can be sent straight back.

[Co-developed with claude code -- Adam]

What this suite holds the route to:

    200  every entry of the table, each `{dpid, table, match, action_name, action_params,
         priority, default_action}`, the default entry last; an empty table is the default entry
         alone. One form per value: bit<32> dotted, bit<48> a MAC, any other width an integer.
    404  an unknown dpid, or a table this switch's p4info does not describe; nothing is read
    422  a missing or non-integer dpid, a missing or empty table
    503  the read failed (the switch is not connected, a deadline), with the gRPC status name;
         a switch being re-adopted; no topology yet

and to the round trip the route exists for: an entry written through POST, read back, and sent
back unchanged as a modify or a delete, through the writer's own encoder
(`build_table_entry` and `match_shape.shape_field`).

The switch is `TableStore`, a stub that keeps what it is written and answers a Read the way bmv2
does: a wildcard read of a table returns its entries and not its default, a read with
`is_default_action` returns the default only (measured on simple_switch_grpc, 2026-10-04).

Handlers are called directly, as in test_table_entry_route.py. The 422 rows and the GET/POST
dispatch are FastAPI's, so those few go through the real ASGI app instead: an ASGI call needs no
`httpx`, which is what keeps starlette's TestClient out of this venv.

Run with:  p4_proxy/venv/bin/python -m unittest tests.test_table_entry_read
"""

from __future__ import annotations

import asyncio
import json
import os
import queue
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import grpc
    from fastapi import FastAPI, HTTPException
    from starlette.requests import Request
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2

    from proxy_agent import api_routes
    from proxy_agent import match_shape
    from proxy_agent import route_binding
    from proxy_agent.p4_client import P4RuntimeClient, RPC_TIMEOUT_S
    from proxy_agent.rule_install_times import RuleInstallTimes

    class FakeRpcError(grpc.RpcError):
        def __init__(self, code, details="fake failure"):
            self._code = code
            self._details = details

        def code(self):
            return self._code

        def details(self):
            return self._details

        def trailing_metadata(self):
            return None

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False


# Synthetic ids, one block per table, so a mixed-up id shows as the wrong table.
LPM_ID, DMAC_ID, TUNNEL_ID, ACL_ID, PROFILED_ID = 41000001, 41000002, 41000003, 41000004, 41000005
FORWARD_ID, SET_PORT_ID, PERMIT_ID, DROP_ID, NOACTION_ID = 21000001, 21000002, 21000003, 21000004, 21000005


def a_p4info():
    """A package pipeline with one table per match kind the route has to read back:

        PkgIngress.ipv4_lpm  lpm on a bit<32>          -> ipv4_forward(dstAddr bit<48>, port bit<9>)
        PkgIngress.dmac      exact on a bit<48>        -> set_port(port bit<9>)
        PkgIngress.tunnel    exact on a bit<16>        -> set_port
        PkgIngress.acl       ternary bit<32>, range bit<16>, optional bit<8> (a priority table)
                                                       -> permit(port bit<9>) / drop()
        PkgIngress.profiled  exact on a bit<16>, an action-profile table POST cannot write
    """
    p4info = p4info_pb2.P4Info()

    def table(tid, name, fields):
        t = p4info.tables.add()
        t.preamble.id, t.preamble.name, t.preamble.alias = tid, name, name.split(".")[-1]
        for fid, (fname, width, kind) in enumerate(fields, start=1):
            f = t.match_fields.add()
            f.id, f.name, f.bitwidth, f.match_type = fid, fname, width, kind
        return t

    M = p4info_pb2.MatchField
    table(LPM_ID, "PkgIngress.ipv4_lpm", [("hdr.ipv4.dstAddr", 32, M.LPM)])
    table(DMAC_ID, "PkgIngress.dmac", [("hdr.ethernet.dstAddr", 48, M.EXACT)])
    table(TUNNEL_ID, "PkgIngress.tunnel", [("hdr.myTunnel.dst_id", 16, M.EXACT)])
    table(ACL_ID, "PkgIngress.acl", [("hdr.ipv4.dstAddr", 32, M.TERNARY),
                                     ("hdr.udp.srcPort", 16, M.RANGE),
                                     ("hdr.ipv4.protocol", 8, M.OPTIONAL)])
    table(PROFILED_ID, "PkgIngress.profiled", [("meta.key", 16, M.EXACT)])

    def action(aid, name, params):
        a = p4info.actions.add()
        a.preamble.id, a.preamble.name, a.preamble.alias = aid, name, name.split(".")[-1]
        for pid, (pname, width) in enumerate(params, start=1):
            p = a.params.add()
            p.id, p.name, p.bitwidth = pid, pname, width

    action(FORWARD_ID, "PkgIngress.ipv4_forward", [("dstAddr", 48), ("port", 9)])
    action(SET_PORT_ID, "PkgIngress.set_port", [("port", 9)])
    action(PERMIT_ID, "PkgIngress.permit", [("port", 9)])
    action(DROP_ID, "PkgIngress.drop", [])
    action(NOACTION_ID, "NoAction", [])
    return p4info


def _strip(raw):
    """A value as a target may send it: P4Runtime's canonical form drops leading zero bytes."""
    return raw.lstrip(b"\x00") or b"\x00"


class TableStore:
    """A switch that keeps what it is written and answers Reads as bmv2 does.

    Every table starts with the compiler's default, NoAction. A wildcard read of a table returns
    its entries and not that default; a read with `is_default_action` returns the default only.
    `canonical` strips leading zero bytes off every value it sends back. `read_error` makes the
    next Read raise. Records every Read request, its deadline and its thread."""

    def __init__(self, canonical=False):
        self.entries = {}       # (table_id, match key, priority) -> TableEntry
        self.defaults = {}
        for tid in (LPM_ID, DMAC_ID, TUNNEL_ID, ACL_ID, PROFILED_ID):
            d = p4runtime_pb2.TableEntry(table_id=tid, is_default_action=True)
            d.action.action.action_id = NOACTION_ID
            self.defaults[tid] = d
        self.canonical = canonical
        self.read_error = None
        self.reads, self.timeouts, self.threads, self.writes = [], [], [], []

    @staticmethod
    def key(te):
        return (te.table_id, tuple(sorted(m.SerializeToString() for m in te.match)), te.priority)

    def put(self, te):
        self.entries[self.key(te)] = te

    def Write(self, request, timeout=None):
        self.writes.append(request)
        for update in request.updates:
            te = p4runtime_pb2.TableEntry()
            te.CopyFrom(update.entity.table_entry)
            if te.is_default_action:
                if update.type != p4runtime_pb2.Update.MODIFY:
                    raise FakeRpcError(grpc.StatusCode.UNKNOWN, "default entry: modify only")
                self.defaults[te.table_id] = te
                continue
            k = self.key(te)
            if update.type == p4runtime_pb2.Update.INSERT:
                if k in self.entries:
                    raise FakeRpcError(grpc.StatusCode.UNKNOWN, "ALREADY_EXISTS")
                self.entries[k] = te
            elif update.type == p4runtime_pb2.Update.MODIFY:
                if k not in self.entries:
                    raise FakeRpcError(grpc.StatusCode.UNKNOWN, "NOT_FOUND")
                self.entries[k] = te
            else:
                if k not in self.entries:
                    raise FakeRpcError(grpc.StatusCode.UNKNOWN, "NOT_FOUND")
                del self.entries[k]

    def _sent(self, te):
        out = p4runtime_pb2.TableEntry()
        out.CopyFrom(te)
        if self.canonical:
            for m in out.match:
                for part in ("exact", "lpm", "ternary", "optional"):
                    if m.HasField(part):
                        getattr(m, part).value = _strip(getattr(m, part).value)
                if m.HasField("ternary"):
                    m.ternary.mask = _strip(m.ternary.mask)
                if m.HasField("range"):
                    m.range.low, m.range.high = _strip(m.range.low), _strip(m.range.high)
            for p in out.action.action.params:
                p.value = _strip(p.value)
        return out

    def Read(self, request, timeout=None):
        self.reads.append(request)
        self.timeouts.append(timeout)
        self.threads.append(threading.get_ident())
        if self.read_error is not None:
            raise self.read_error
        out = []
        for entity in request.entities:
            want = entity.table_entry
            if want.is_default_action:
                found = [self.defaults[want.table_id]] if want.table_id in self.defaults else []
            else:
                found = [te for (tid, _m, _p), te in sorted(self.entries.items())
                         if want.table_id in (0, tid)]
            for te in found:
                response = p4runtime_pb2.ReadResponse()
                response.entities.add().table_entry.CopyFrom(self._sent(te))
                out.append(response)
        return iter(out)


def a_client(stub, device_id=2):
    """A P4RuntimeClient with no gRPC channel, on a package pipeline with no `roles`."""
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = device_id
    client.grpc_addr = "127.0.0.1:50051"
    client.p4info = a_p4info()
    client.stub = stub
    client.packet_in_callback = None
    client.sample_callback = None
    client.is_running = False
    client.stream_recv_thread = None
    client.stream_out_q = queue.Queue()
    client.rule_install_times = RuleInstallTimes()
    client._last_table_read = None
    client.election_id = (0, 1)
    client.arbitration = True
    client.bind_routes(None)
    return client


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


class FakeJournals:
    def __init__(self, pending=()):
        self.pending_dpids = set(pending)

    def pending(self, dpid):
        return dpid in self.pending_dpids


def a_post(body):
    payload = json.dumps(body).encode()

    async def receive():
        return {"type": "http.request", "body": payload, "more_body": False}

    return Request({"type": "http", "http_version": "1.1", "method": "POST",
                    "path": "/p4/table_entry", "raw_path": b"/p4/table_entry",
                    "root_path": "", "scheme": "http", "query_string": b"",
                    "headers": [(b"content-type", b"application/json")],
                    "client": ("127.0.0.1", 0), "server": ("127.0.0.1", 8081)},
                   receive)


def asgi(method, path, query=b"", body=b""):
    """One request through a FastAPI app carrying this router: `(status, decoded body)`."""
    app = FastAPI()
    app.include_router(api_routes.router)
    sent = []

    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
             "method": method, "path": path, "raw_path": path.encode(), "root_path": "",
             "scheme": "http", "query_string": query,
             "headers": [(b"content-type", b"application/json")],
             "client": ("127.0.0.1", 0), "server": ("127.0.0.1", 8081)}
    asyncio.run(app(scope, receive, send))
    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    payload = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    return status, json.loads(payload)


LPM = {"table": "PkgIngress.ipv4_lpm", "match": {"hdr.ipv4.dstAddr": ["10.0.1.0", 24]},
       "action_name": "PkgIngress.ipv4_forward",
       "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
DMAC = {"table": "PkgIngress.dmac", "match": {"hdr.ethernet.dstAddr": "08:00:00:00:02:22"},
        "action_name": "PkgIngress.set_port", "action_params": {"port": 2}}
TUNNEL = {"table": "PkgIngress.tunnel", "match": {"hdr.myTunnel.dst_id": [3]},
          "action_name": "PkgIngress.set_port", "action_params": {"port": 3}}
ACL = {"table": "PkgIngress.acl",
       "match": {"hdr.ipv4.dstAddr": ["10.0.2.0", "255.255.255.0"],
                 "hdr.udp.srcPort": [1000, 2000], "hdr.ipv4.protocol": 17},
       "action_name": "PkgIngress.permit", "action_params": {"port": 4}, "priority": 10}


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TableReadTestBase(unittest.TestCase):
    def setUp(self):
        # `table_journals` is isolated as in test_table_entry_route.py: once any test has imported
        # `main`, the route holds the real journals, and a POST here would append to them.
        self.saved = (api_routes.topology, api_routes.table_journals,
                      api_routes.note_api_table_entry_write)
        self.addCleanup(self.restore)
        api_routes.table_journals = None
        api_routes.note_api_table_entry_write = None
        self.store = TableStore()
        self.client = a_client(self.store)
        api_routes.topology = FakeTopology({2: self.client})

    def restore(self):
        (api_routes.topology, api_routes.table_journals,
         api_routes.note_api_table_entry_write) = self.saved

    def write(self, spec, op="insert"):
        return asyncio.run(api_routes.table_entry(a_post(dict(spec, dpid=2, op=op))))

    def read(self, table, dpid=2):
        return api_routes.read_table_entry(dpid=dpid, table=table)

    def refused(self, table, dpid=2):
        with self.assertRaises(HTTPException) as caught:
            self.read(table, dpid=dpid)
        return caught.exception

    def entries(self, table):
        return self.read(table)["entries"]

    def built(self, spec):
        """The TableEntry the writer's own encoder builds from `spec`, as bytes on the wire."""
        entry, _types = self.client.build_table_entry(spec)
        return entry.SerializeToString()


class EachMatchKindReadsBackTest(TableReadTestBase):
    def test_an_lpm_entry_reads_back_as_value_and_prefix_with_a_mac_and_a_port(self):
        self.write(LPM)
        self.assertEqual(self.entries("PkgIngress.ipv4_lpm")[0], {
            "dpid": 2, "table": "PkgIngress.ipv4_lpm",
            "match": {"hdr.ipv4.dstAddr": ["10.0.1.0", 24]},
            "action_name": "PkgIngress.ipv4_forward",
            "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1},
            "priority": None, "default_action": False})

    def test_an_exact_mac_reads_back_as_a_mac(self):
        self.write(DMAC)
        self.assertEqual(self.entries("PkgIngress.dmac")[0]["match"],
                         {"hdr.ethernet.dstAddr": "08:00:00:00:02:22"})

    def test_an_exact_value_of_another_width_reads_back_as_a_plain_integer(self):
        # Written as the one-element list basic_tunnel's runtime files use; read back plain.
        self.write(TUNNEL)
        self.assertEqual(self.entries("PkgIngress.tunnel")[0]["match"],
                         {"hdr.myTunnel.dst_id": 3})

    def test_a_ternary_entry_reads_back_with_its_mask_and_its_priority(self):
        self.write(ACL)
        entry = self.entries("PkgIngress.acl")[0]
        self.assertEqual(entry["match"]["hdr.ipv4.dstAddr"], ["10.0.2.0", "255.255.255.0"])
        self.assertEqual(entry["priority"], 10)

    def test_a_range_reads_back_as_low_and_high(self):
        self.write(ACL)
        self.assertEqual(self.entries("PkgIngress.acl")[0]["match"]["hdr.udp.srcPort"],
                         [1000, 2000])

    def test_an_optional_reads_back_as_a_plain_value(self):
        self.write(ACL)
        self.assertEqual(self.entries("PkgIngress.acl")[0]["match"]["hdr.ipv4.protocol"], 17)

    def test_a_field_left_out_stays_left_out(self):
        # "Any value" is said by omitting the field; reading it back must not invent one.
        self.write(dict(ACL, match={"hdr.udp.srcPort": [1000, 2000]}, priority=5))
        self.assertEqual(self.entries("PkgIngress.acl")[0]["match"],
                         {"hdr.udp.srcPort": [1000, 2000]})

    def test_one_spelling_per_width_whatever_the_entry_was_written_in(self):
        # 167772416 is 10.0.1.0 and 0x0001 is port 1: an integer written to a bit<32> field reads
        # back dotted, a hex string to a bit<9> reads back an integer.
        self.write(dict(LPM, match={"hdr.ipv4.dstAddr": [167772416, 24]},
                        action_params={"dstAddr": "08:00:00:00:01:11", "port": "0x0001"}))
        entry = self.entries("PkgIngress.ipv4_lpm")[0]
        self.assertEqual(entry["match"], {"hdr.ipv4.dstAddr": ["10.0.1.0", 24]})
        self.assertEqual(entry["action_params"]["port"], 1)

    def test_values_sent_without_their_leading_zero_bytes_read_the_same(self):
        # P4Runtime lets a target strip leading zero bytes; the width comes from the p4info.
        self.store.canonical = True
        self.write(dict(LPM, match={"hdr.ipv4.dstAddr": ["0.0.1.0", 24]}))
        self.write(dict(DMAC, match={"hdr.ethernet.dstAddr": "00:00:00:00:02:22"}))
        self.write(TUNNEL)
        lpm = self.entries("PkgIngress.ipv4_lpm")[0]
        self.assertEqual(lpm["match"], {"hdr.ipv4.dstAddr": ["0.0.1.0", 24]})
        self.assertEqual(lpm["action_params"], {"dstAddr": "08:00:00:00:01:11", "port": 1})
        self.assertEqual(self.entries("PkgIngress.dmac")[0]["match"],
                         {"hdr.ethernet.dstAddr": "00:00:00:00:02:22"})
        self.assertEqual(self.entries("PkgIngress.tunnel")[0]["match"],
                         {"hdr.myTunnel.dst_id": 3})

    def test_an_alias_names_the_same_table_and_the_answer_gives_the_full_name(self):
        self.write(LPM)
        body = self.read("ipv4_lpm")
        self.assertEqual(body["table"], "PkgIngress.ipv4_lpm")
        self.assertEqual(body["entries"][0]["table"], "PkgIngress.ipv4_lpm")


class DefaultAndEmptyTest(TableReadTestBase):
    def test_an_empty_table_reads_back_as_its_default_entry_alone(self):
        self.assertEqual(self.read("PkgIngress.dmac"), {
            "dpid": 2, "table": "PkgIngress.dmac",
            "entries": [{"dpid": 2, "table": "PkgIngress.dmac", "match": {},
                         "action_name": "NoAction", "action_params": {},
                         "priority": None, "default_action": True}],
            "unrendered": []})

    def test_the_default_entry_comes_last_and_carries_what_was_written(self):
        self.write(DMAC)
        self.write({"table": "PkgIngress.dmac", "default_action": True,
                    "action_name": "PkgIngress.set_port", "action_params": {"port": 9}})
        entries = self.entries("PkgIngress.dmac")
        self.assertEqual([e["default_action"] for e in entries], [False, True])
        self.assertEqual(entries[1]["action_params"], {"port": 9})

    def test_a_default_entry_on_a_priority_table_has_no_priority(self):
        entry = self.entries("PkgIngress.acl")[-1]
        self.assertTrue(entry["default_action"])
        self.assertIsNone(entry["priority"])

    def test_the_two_reads_are_of_this_table_one_for_its_entries_one_for_its_default(self):
        # The one thing a caller cannot check from the body: bmv2 returns the default only to a
        # read that asks for it, so a single wildcard read would silently lose it.
        self.read("PkgIngress.dmac")
        asked = [(r.entities[0].table_entry.table_id, r.entities[0].table_entry.is_default_action)
                 for r in self.store.reads]
        self.assertEqual(asked, [(DMAC_ID, False), (DMAC_ID, True)])
        self.assertTrue(all(len(r.entities) == 1 and r.device_id == 2 for r in self.store.reads))

    def test_a_default_returned_by_the_wildcard_read_is_not_reported_twice(self):
        # Another target may return the default to the wildcard read as well.
        real_read = self.store.Read

        def generous(request, timeout=None):
            replies = list(real_read(request, timeout))
            if not request.entities[0].table_entry.is_default_action:
                response = p4runtime_pb2.ReadResponse()
                response.entities.add().table_entry.CopyFrom(self.store.defaults[DMAC_ID])
                replies.append(response)
            return iter(replies)
        self.store.Read = generous
        self.assertEqual([e["default_action"] for e in self.entries("PkgIngress.dmac")], [True])

    def test_an_entry_of_another_table_is_not_reported(self):
        self.write(LPM)
        self.store.put(self.client.build_table_entry(dict(DMAC))[0])
        real_read = self.store.Read

        def everything(request, timeout=None):
            request.entities[0].table_entry.table_id = 0
            return real_read(request, timeout)
        self.store.Read = everything
        self.assertEqual([e["table"] for e in self.entries("PkgIngress.ipv4_lpm")
                          if not e["default_action"]], ["PkgIngress.ipv4_lpm"])

    def test_every_read_carries_a_deadline(self):
        self.read("PkgIngress.dmac")
        self.assertEqual(self.store.timeouts, [RPC_TIMEOUT_S, RPC_TIMEOUT_S])


class RoundTripTest(TableReadTestBase):
    """The route's reason to exist: read an entry, send it back unchanged."""

    def test_every_entry_read_back_builds_the_entry_the_switch_holds(self):
        # Through the writer's own encoder: what build_table_entry makes of the read-back spec is
        # byte for byte what the switch was written.
        for spec in (LPM, DMAC, TUNNEL, ACL):
            self.write(spec)
            back = [e for e in self.entries(spec["table"]) if not e["default_action"]][0]
            self.assertEqual(self.built(back), self.built(spec), spec["table"])

    def test_read_then_post_it_back_as_a_modify_is_a_200_that_changes_nothing(self):
        for spec in (LPM, DMAC, TUNNEL, ACL):
            self.write(spec)
            before = self.read(spec["table"])
            for entry in before["entries"]:
                self.assertEqual(self.write(entry, op="modify")["status"], "success")
            self.assertEqual(self.read(spec["table"]), before, spec["table"])

    def test_a_modify_built_from_a_read_changes_the_action_of_that_same_entry(self):
        self.write(ACL)
        entry = self.entries("PkgIngress.acl")[0]
        self.write(dict(entry, action_params={"port": 7}), op="modify")
        entries = self.entries("PkgIngress.acl")
        self.assertEqual(len(entries), 2, "the modify must not have made a second entry")
        self.assertEqual(entries[0]["action_params"], {"port": 7})

    def test_an_entry_read_back_deletes_that_entry(self):
        for spec in (LPM, ACL):
            self.write(spec)
            entry = self.entries(spec["table"])[0]
            self.assertEqual(self.write(entry, op="delete")["status"], "success")
            self.assertEqual([e["default_action"] for e in self.entries(spec["table"])], [True])

    def test_the_default_entry_read_back_is_a_modify_too(self):
        default = self.entries("PkgIngress.dmac")[-1]
        self.assertEqual(self.write(dict(default, action_name="PkgIngress.set_port",
                                         action_params={"port": 5}), op="modify")["op"], "modify")
        self.assertEqual(self.entries("PkgIngress.dmac")[-1]["action_params"], {"port": 5})

    def test_render_field_is_the_inverse_of_shape_field_for_every_kind(self):
        # The pair the route rests on, without a switch in between.
        for kind, width, raw in (("EXACT", 32, "10.0.0.1"), ("EXACT", 48, "aa:bb:cc:dd:ee:ff"),
                                 ("EXACT", 9, 511), ("LPM", 32, ["10.1.0.0", 16]),
                                 ("TERNARY", 32, ["10.0.2.0", "255.255.255.0"]),
                                 ("TERNARY", 16, [0x0100, 0xff00]),
                                 ("RANGE", 16, [1000, 2000]), ("OPTIONAL", 8, 17)):
            wire = match_shape.shape_field("t.f", kind, width, raw)
            self.assertEqual(match_shape.render_field("t.f", width, wire), raw, kind)


class UnrenderableEntriesTest(TableReadTestBase):
    def test_an_action_profile_entry_is_listed_as_unrendered_not_dropped(self):
        te = p4runtime_pb2.TableEntry(table_id=PROFILED_ID)
        m = te.match.add()
        m.field_id, m.exact.value = 1, (7).to_bytes(2, "big")
        te.action.action_profile_member_id = 3
        self.store.put(te)
        body = self.read("PkgIngress.profiled")
        self.assertEqual([e["default_action"] for e in body["entries"]], [True])
        self.assertEqual(len(body["unrendered"]), 1)
        self.assertIn("action profile", body["unrendered"][0]["reason"])

    def test_a_match_field_id_this_p4info_does_not_describe_is_unrendered(self):
        te = self.client.build_table_entry(dict(TUNNEL))[0]
        te.match[0].field_id = 99
        self.store.put(te)
        body = self.read("PkgIngress.tunnel")
        self.assertEqual(len(body["unrendered"]), 1)
        self.assertIn("does not describe", body["unrendered"][0]["reason"])

    def test_a_match_of_another_kind_than_the_p4info_declares_is_unrendered(self):
        # An lpm value on an exact field: rendering it as exact would describe another entry.
        te = self.client.build_table_entry(dict(TUNNEL))[0]
        value = te.match[0].exact.value
        te.match[0].lpm.value, te.match[0].lpm.prefix_len = value, 16
        self.store.put(te)
        body = self.read("PkgIngress.tunnel")
        self.assertEqual([e["default_action"] for e in body["entries"]], [True])
        self.assertIn("declared EXACT", body["unrendered"][0]["reason"])

    def test_an_action_without_one_of_its_parameters_is_unrendered(self):
        # The writer refuses an action with a parameter left out, so this one could not go back.
        te = self.client.build_table_entry(dict(LPM))[0]
        del te.action.action.params[1]
        self.store.put(te)
        body = self.read("PkgIngress.ipv4_lpm")
        self.assertEqual(len(body["unrendered"]), 1)
        self.assertIn("without its parameter 'port'", body["unrendered"][0]["reason"])

    def test_an_action_this_p4info_does_not_describe_is_unrendered(self):
        te = self.client.build_table_entry(dict(TUNNEL))[0]
        te.action.action.action_id = 99
        self.store.put(te)
        body = self.read("PkgIngress.tunnel")
        self.assertEqual(len(body["unrendered"]), 1)
        self.assertIn("action id 99", body["unrendered"][0]["reason"])

    def test_a_parameter_the_action_does_not_declare_is_unrendered(self):
        te = self.client.build_table_entry(dict(TUNNEL))[0]
        extra = te.action.action.params.add()
        extra.param_id, extra.value = 7, b"\x01"
        self.store.put(te)
        body = self.read("PkgIngress.tunnel")
        self.assertEqual(len(body["unrendered"]), 1)
        self.assertIn("does not declare", body["unrendered"][0]["reason"])

    def test_a_value_wider_than_its_field_is_unrendered_not_narrowed(self):
        te = self.client.build_table_entry(dict(TUNNEL))[0]
        te.action.action.params[0].value = (1 << 9).to_bytes(2, "big")   # port is bit<9>
        self.store.put(te)
        body = self.read("PkgIngress.tunnel")
        self.assertEqual(len(body["unrendered"]), 1)
        self.assertIn("does not fit", body["unrendered"][0]["reason"])


class RefusalsTest(TableReadTestBase):
    def test_an_unknown_dpid_is_404_and_reads_nothing(self):
        error = self.refused("PkgIngress.dmac", dpid=9)
        self.assertEqual(error.status_code, 404)
        self.assertEqual(error.detail["error"], "unknown switch")
        self.assertEqual(self.store.reads, [])

    def test_a_table_this_pipeline_does_not_have_is_404_and_reads_nothing(self):
        error = self.refused("PkgIngress.no_such_table")
        self.assertEqual(error.status_code, 404)
        self.assertEqual(error.detail["error"], "not in this pipeline")
        self.assertIn("no_such_table", error.detail["message"])
        self.assertEqual(self.store.reads, [])

    def test_a_switch_that_is_not_connected_is_503_with_the_grpc_status_name(self):
        self.store.read_error = FakeRpcError(grpc.StatusCode.UNAVAILABLE, "failed to connect")
        error = self.refused("PkgIngress.dmac")
        self.assertEqual(error.status_code, 503)
        self.assertEqual(error.detail["error"], "table not read")
        self.assertEqual(error.detail["grpc_status"], "UNAVAILABLE")
        self.assertIn("NOT an empty table", error.detail["message"])

    def test_a_deadline_is_503_too(self):
        self.store.read_error = FakeRpcError(grpc.StatusCode.DEADLINE_EXCEEDED)
        error = self.refused("PkgIngress.dmac")
        self.assertEqual((error.status_code, error.detail["grpc_status"]),
                         (503, "DEADLINE_EXCEEDED"))

    def test_a_failure_of_the_default_read_alone_is_503_not_a_table_without_a_default(self):
        real_read = self.store.Read

        def second_fails(request, timeout=None):
            if request.entities[0].table_entry.is_default_action:
                raise FakeRpcError(grpc.StatusCode.DEADLINE_EXCEEDED)
            return real_read(request, timeout)
        self.store.Read = second_fails
        self.assertEqual(self.refused("PkgIngress.dmac").status_code, 503)

    def test_an_error_that_is_not_grpc_is_not_called_a_failed_read(self):
        self.store.read_error = RuntimeError("a bug, not the switch")
        with self.assertRaises(RuntimeError):
            self.read("PkgIngress.dmac")

    def test_a_switch_being_readopted_is_503_replay_pending_and_reads_nothing(self):
        api_routes.table_journals = FakeJournals(pending={2})
        error = self.refused("PkgIngress.dmac")
        self.assertEqual(error.status_code, 503)
        self.assertEqual(error.detail["error"], "replay pending")
        self.assertEqual(self.store.reads, [])

    def test_another_switch_being_readopted_does_not_stop_this_read(self):
        api_routes.table_journals = FakeJournals(pending={3})
        self.assertEqual(len(self.entries("PkgIngress.dmac")), 1)

    def test_no_topology_is_503(self):
        api_routes.topology = None
        self.assertEqual(self.refused("PkgIngress.dmac").status_code, 503)


class ReadsAreNotOwnerCheckedTest(TableReadTestBase):
    """Ownership restricts writes. On NDTwin's own pipeline every table is NDTwin's, and
    reading one changes nothing."""

    def test_a_table_ndtwin_owns_is_still_read(self):
        self.write(DMAC)
        self.client.route_binding = route_binding.BASELINE
        self.assertTrue(self.client.table_owned_by_ndtwin(self.client.p4info.tables[1]))
        self.assertEqual(len(self.entries("PkgIngress.dmac")), 2)

    def test_an_external_control_plane_can_still_read(self):
        self.write(DMAC)
        self.client.arbitration = False
        self.assertEqual(len(self.entries("PkgIngress.dmac")), 2)


class ThroughTheAppTest(TableReadTestBase):
    """What FastAPI decides: the query parameters' 422s, and that a GET reaches this handler."""

    def test_a_get_reaches_the_reader_and_answers_200(self):
        self.write(DMAC)
        status, body = asgi("GET", "/p4/table_entry", b"dpid=2&table=dmac")
        self.assertEqual(status, 200)
        self.assertEqual(body["entries"][0]["match"], {"hdr.ethernet.dstAddr": "08:00:00:00:02:22"})

    def test_the_read_runs_off_the_event_loop(self):
        # FastAPI sends a `def` endpoint to its threadpool; the read must not run on the loop,
        # which `asgi` runs on this thread. Compared by thread identity, the property that
        # matters, as well as by the predicate FastAPI branches on.
        self.assertFalse(asyncio.iscoroutinefunction(api_routes.read_table_entry))
        asgi("GET", "/p4/table_entry", b"dpid=2&table=dmac")
        self.assertEqual(len(self.store.threads), 2)
        self.assertNotIn(threading.get_ident(), self.store.threads)

    def test_a_404_keeps_the_error_body(self):
        status, body = asgi("GET", "/p4/table_entry", b"dpid=2&table=nope")
        self.assertEqual(status, 404)
        self.assertEqual(body["detail"]["error"], "not in this pipeline")

    def test_a_missing_table_is_422(self):
        self.assertEqual(asgi("GET", "/p4/table_entry", b"dpid=2")[0], 422)

    def test_an_empty_table_name_is_422(self):
        self.assertEqual(asgi("GET", "/p4/table_entry", b"dpid=2&table=")[0], 422)

    def test_a_missing_or_non_integer_dpid_is_422(self):
        self.assertEqual(asgi("GET", "/p4/table_entry", b"table=dmac")[0], 422)
        self.assertEqual(asgi("GET", "/p4/table_entry", b"dpid=two&table=dmac")[0], 422)
        self.assertEqual(self.store.reads, [])

    def test_post_still_reaches_the_writer(self):
        status, body = asgi("POST", "/p4/table_entry",
                            body=json.dumps(dict(DMAC, dpid=2)).encode())
        self.assertEqual((status, body["status"]), (200, "success"))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheRouteIsRegisteredTest(unittest.TestCase):
    def test_get_p4_table_entry_is_on_the_router(self):
        matching = [r for r in api_routes.router.routes
                    if getattr(r, "path", None) == "/p4/table_entry" and "GET" in r.methods]
        self.assertEqual(len(matching), 1, "the read is not registered at that path")
        self.assertIs(matching[0].endpoint, api_routes.read_table_entry)


if __name__ == "__main__":
    unittest.main(verbosity=2)
