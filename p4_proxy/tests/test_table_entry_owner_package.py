"""
The owned-table refusal, end to end, on a package that really declares `roles.ipv4_route`.

[Co-developed with claude code -- Adam]

tests/test_table_entry_owner.py hand-builds its package binding. That is the right shape for each
decision on its own, and it cannot see whether the binding the PRODUCTION factory resolves -- from
a package the converter really wrote, against a p4info a compiler really produced -- is the one
the refusal reads. This file goes the whole way:

  * `convert.py --role-ipv4-route owner=ndtwin,...` over `fixtures/renamed_route` writes the
    package (the table is `RouteIngress.dest_routes`, which shares no name with NDTwin's);
  * `main.build_p4_client` binds the client for it, exactly as startup and readopt do;
  * the POSTs go to the route handler, the package's entries go through `startup()` and
    `readopt_switch()`, and a recording stub stands in for the switch.

The package is built here, not committed, for the reason test_foreign_pipeline gives: the
converter is what produces it in production, and a copy would be a second answer.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
REPO = os.path.dirname(PROXY_DIR)
sys.path.insert(0, PROXY_DIR)
sys.path.insert(0, os.path.join(PROXY_DIR, "mininet"))

try:
    from fastapi import HTTPException
    from starlette.requests import Request
    from p4.v1 import p4runtime_pb2

    import proxy_agent.main as main
    from proxy_agent import api_routes
    from proxy_agent import p4_client as p4_client_module
    from proxy_agent.topology_manager import TopologyManager
    from tests.test_startup import run_startup

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False

import app_package  # noqa: E402

RENAMED = os.path.join(HERE, "fixtures", "renamed_route")
ROLE_FLAG = ("owner=ndtwin,table=RouteIngress.dest_routes,match_field=hdr.ip4.dst,"
             "action=RouteIngress.send_via,dst_mac=next_mac,port=out_port")

OWNED_ROUTE = {"dpid": 1, "op": "insert", "table": "RouteIngress.dest_routes",
               "match": {"hdr.ip4.dst": ["10.9.9.9", 32]},
               "action_name": "RouteIngress.send_via",
               "action_params": {"out_port": 1, "next_mac": "08:00:00:00:01:11"}}
OWNED_DEFAULT = {"dpid": 1, "op": "modify", "table": "RouteIngress.dest_routes",
                 "default_action": True, "action_name": "RouteIngress.discard",
                 "action_params": {}}
USER_TABLE = {"dpid": 1, "op": "insert", "table": "RouteIngress.proto_tags",
              "match": {"hdr.ip4.proto": 6}, "action_name": "RouteIngress.tag_proto",
              "action_params": {"tag": 1}}


def the_owned(spec, **changes):
    out = json.loads(json.dumps(spec))
    out.update(changes)
    return out


class RecordingStub:
    def __init__(self):
        self.requests = []

    def Write(self, request, timeout=None):
        self.requests.append(request)


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


def a_request(body):
    payload = json.dumps(body).encode()

    async def receive():
        return {"type": "http.request", "body": payload, "more_body": False}

    return Request({"type": "http", "http_version": "1.1", "method": "POST",
                    "path": "/p4/table_entry", "raw_path": b"/p4/table_entry",
                    "root_path": "", "scheme": "http", "query_string": b"",
                    "headers": [(b"content-type", b"application/json")],
                    "client": ("127.0.0.1", 0), "server": ("127.0.0.1", 8081)}, receive)


def default_entries(client):
    """The default-action entries that reached the stub, as (table id, action id)."""
    out = []
    for request in client.stub.requests:
        entry = request.updates[0].entity.table_entry
        if entry.is_default_action:
            out.append((entry.table_id, entry.action.action.action_id))
    return out


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class AnOwnerNdtwinRolesPackageEndToEndTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ndtwin_owner_package_")
        tools = os.path.join(REPO, "tools")
        if tools not in sys.path:
            sys.path.insert(0, tools)
        from p4_exercise import convert  # noqa: E402

        out = os.path.join(cls.tmp, "renamed")
        convert.convert(RENAMED, "pod-topo/topology.json", out, p4_rel="renamed_route.p4",
                        role_ipv4_route=convert.parse_role_flag(ROLE_FLAG))
        cls.package = app_package.load(out)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, True)

    def setUp(self):
        self.saved = (dict(main._pipelines), dict(main._table_entries), dict(main._api_writes),
                      api_routes.topology, api_routes.note_api_table_entry_write)
        self.addCleanup(self.restore)

    def restore(self):
        for live, saved in ((main._pipelines, self.saved[0]),
                            (main._table_entries, self.saved[1]),
                            (main._api_writes, self.saved[2])):
            live.clear()
            live.update(saved)
        api_routes.topology, api_routes.note_api_table_entry_write = self.saved[3:]

    def real_client(self, dpid=1):
        """The client PRODUCTION builds for this switch, with a recording stub for the wire."""
        client = main.build_p4_client(dpid, package=self.package)
        self.addCleanup(client.channel.close)
        client.stub = RecordingStub()
        client.events = []
        client.set_forwarding_pipeline_config = lambda c=client: c.events.append("pipeline")
        client.write_clone_session = lambda c=client: c.events.append("clone") or True
        return client

    def post(self, client, body):
        api_routes.topology = FakeTopology({body["dpid"]: client})
        api_routes.note_api_table_entry_write = lambda dpid: None
        return asyncio.run(api_routes.table_entry(a_request(body)))

    def refused(self, client, body):
        with self.assertRaises(HTTPException) as caught:
            self.post(client, body)
        return caught.exception

    def test_the_factory_binds_the_converted_role_as_owner_ndtwin(self):
        binding = self.real_client().route_binding
        self.assertEqual((binding.table, binding.owner, binding.source),
                         ("RouteIngress.dest_routes", "ndtwin", "package"))

    def test_the_full_name_and_the_alias_of_the_owned_table_are_both_409(self):
        client = self.real_client()
        for table in ("RouteIngress.dest_routes", "dest_routes"):
            for body in (the_owned(OWNED_ROUTE, table=table, action_name="send_via"),
                         the_owned(OWNED_DEFAULT, table=table, action_name="discard")):
                with self.subTest(table=table, default=bool(body.get("default_action"))):
                    error = self.refused(client, body)
                    self.assertEqual(error.status_code, 409)
                    self.assertEqual(error.detail["outcome"], "owned_by_ndtwin")
        self.assertEqual(client.stub.requests, [])

    def test_another_table_of_the_same_package_is_written(self):
        client = self.real_client()
        for body in (USER_TABLE, the_owned(USER_TABLE, table="proto_tags",
                                           action_name="tag_proto")):
            self.assertEqual(self.post(client, body)["status"], "success")
        self.assertEqual(len(client.stub.requests), 2)

    def test_startup_applies_the_packages_default_and_fails_nothing(self):
        clients = {spec.dpid: self.real_client(spec.dpid) for spec in self.package.switches}
        summary, _ = run_startup(clients, package=self.package)
        recorded = self.package.entries_recorded()
        for dpid, client in clients.items():
            with self.subTest(dpid=dpid):
                counts = summary["table_entries"][str(dpid)]
                self.assertEqual(counts["failed"], 0, counts)
                self.assertGreaterEqual(counts["applied"], 1)
                self.assertEqual(counts["applied"], recorded[str(dpid)])
                self.assertEqual(len(default_entries(client)), 1,
                                 "the package's default action must reach the wire")
                update = client.stub.requests[0].updates[0]
                self.assertEqual(update.type, p4runtime_pb2.Update.MODIFY)

    def test_readopt_applies_the_packages_default_again(self):
        old = self.real_client()
        topo = TopologyManager()
        topo.add_switch(1, old)
        old.stop = lambda: None
        made = []

        def factory(dpid):
            client = self.real_client(dpid)
            client.start = lambda push_config=True: None
            client.stop = lambda: None
            client.mastership_confirmed = True
            made.append(client)
            return client

        result = main.readopt_switch(topo, 1, factory, lambda *a, **k: None,
                                     package=self.package)
        self.assertEqual(result["status"], "success", result)
        counts = result["table_entries"]
        self.assertEqual((counts["failed"], counts["applied"]),
                         (0, self.package.entries_recorded()["1"]), counts)
        self.assertEqual(len(default_entries(made[0])), 1)


if __name__ == "__main__":
    unittest.main()
