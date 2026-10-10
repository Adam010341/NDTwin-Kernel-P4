"""
The generic table-entry writer refuses the tables NDTwin owns: 409 `owned_by_ndtwin`.

[Co-developed with claude code -- Adam]

Adam 2026-10-09, "V7" of the ternary-journal design, Q2 (a). `POST /p4/table_entry` and the
package's own boot entries both end in `P4RuntimeClient.write_table_entry`, and until now that
method looked at no binding at all. Two things it let through:

  * an EMPTY match into `MyIngress.flow_5tuple` -- every field of that table is ternary, so
    "no field written" is a catch-all that matches every packet -- answered 200 and sat in front
    of `ipv4_lpm`;
  * any entry into `MyIngress.ipv4_lpm`, which the next route install silently rewrites.

NDTwin-owned means: every table of a switch bound to NDTwin's own pipeline (`BASELINE`), and, on
a package switch, the one table the package binds as `roles.ipv4_route` with owner `ndtwin`.
Everything else is the author's and stays writable.

🔴 ONE EXCEPTION, and these tests pin its width from every side: ruling 8-1's default action. A
package's BOOT entries may set the default action of its own owner-ndtwin route table, because
main.py installs NDTwin's routes "after the package's entries, so the table's default action is in
place first". That is all: not an API write, not a replay, not a baseline table, not a match entry,
not a delete.

"Nothing was written" is a claim about the wire, so every refusal here asserts
`stub.requests == []`.

Called directly rather than through a TestClient, like tests/test_table_entry_route.py, and for
the same reason. This file builds its own p4info and doubles: `p4_proxy/tests` is not a package,
so importing another test file works under one runner and not under the other.
"""

from __future__ import annotations

import asyncio
import contextlib
import io
import json
import os
import queue
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    from fastapi import HTTPException
    from google.protobuf import text_format
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2
    from starlette.requests import Request

    import proxy_agent.main as main
    from proxy_agent import api_routes
    from proxy_agent import p4_client as p4_client_module
    from proxy_agent import route_binding
    from proxy_agent.p4_client import P4RuntimeClient
    from proxy_agent.rule_install_times import RuleInstallTimes

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False

#: The refusal's exception type. Looked up by name so that, on a tree that has not got the check
#: yet, a test fails because the write was ACCEPTED ("OWNED not raised" -- the defect) and not
#: because this module has no such attribute -- the red a mutation gate or a first run is for.
if HAVE_P4RUNTIME:
    OWNED = getattr(p4_client_module, "TableOwnedByNDTwin",
                    type("TableOwnedByNDTwinIsNotDefinedYet", (Exception,), {}))

REAL_P4INFO_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "p4_src", "build", "ndtwin_switch.p4info.txt")

#: Ids are made up and distinct; nothing here compares them with a compiler's.
_IDS = iter(range(700000001, 700001000))


def _add_table(p4info, name, fields):
    table = p4info.tables.add()
    table.preamble.id = next(_IDS)
    table.preamble.name = name
    table.preamble.alias = name.split(".")[-1]
    for number, (field_name, bits, kind) in enumerate(fields, start=1):
        field = table.match_fields.add()
        field.id = number
        field.name = field_name
        field.bitwidth = bits
        field.match_type = kind
    return table


def _add_action(p4info, name, params=()):
    action = p4info.actions.add()
    action.preamble.id = next(_IDS)
    action.preamble.name = name
    action.preamble.alias = name.split(".")[-1]
    for number, (param_name, bits) in enumerate(params, start=1):
        param = action.params.add()
        param.id = number
        param.name = param_name
        param.bitwidth = bits


def a_p4info():
    """One p4info holding the baseline's table names AND a package's own, for both kinds of switch.

    A real switch runs one pipeline; the double carries both sets of names so the SAME tables can
    be asked about under each binding -- which is the whole subject: ownership comes from the
    binding, not from the table's name or shape.
    """
    p4info = p4info_pb2.P4Info()
    lpm, ternary, exact = (p4info_pb2.MatchField.LPM, p4info_pb2.MatchField.TERNARY,
                           p4info_pb2.MatchField.EXACT)
    # NDTwin's own tables. flow_5tuple's real six fields are all ternary; two are enough to be a
    # table with a priority column, and the headline entry names none of them.
    _add_table(p4info, "MyIngress.ipv4_lpm", [("hdr.ipv4.dstAddr", 32, lpm)])
    _add_table(p4info, "MyIngress.flow_5tuple", [("hdr.ipv4.srcAddr", 32, ternary),
                                                 ("hdr.ipv4.protocol", 8, ternary)])
    _add_table(p4info, "MyIngress.l2_forward", [("hdr.ethernet.dstAddr", 48, exact)])
    # A package's own tables: a route table it hands to NDTwin, and one that is only its own.
    _add_table(p4info, "PkgIngress.routes", [("hdr.ip4.dst", 32, lpm)])
    _add_table(p4info, "PkgIngress.acl", [("hdr.ip4.src", 32, exact)])
    _add_action(p4info, "MyIngress.ipv4_forward", [("dstAddr", 48), ("port", 9)])
    _add_action(p4info, "MyIngress.send_to_cpu")
    _add_action(p4info, "MyIngress.drop")
    _add_action(p4info, "PkgIngress.send_via", [("next_mac", 48), ("out_port", 9)])
    _add_action(p4info, "PkgIngress.no_route")
    return p4info


class RecordingStub:
    def __init__(self):
        self.requests = []

    def Write(self, request, timeout=None):
        self.requests.append(request)


def a_client(binding, p4info=None, arbitration=True):
    """A P4RuntimeClient with no channel, bound to `binding` the way build_p4_client binds one.

    `binding` is given explicitly, always: a double that inherited the class default would be a
    baseline client by accident, which is the thing this file refuses to leave implicit.
    """
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = 1
    client.grpc_addr = "127.0.0.1:50051"
    client.p4info = p4info if p4info is not None else a_p4info()
    client.stub = RecordingStub()
    client.packet_in_callback = None
    client.sample_callback = None
    client.is_running = False
    client.stream_recv_thread = None
    client.stream_out_q = queue.Queue()
    client.rule_install_times = RuleInstallTimes()
    client._last_table_read = None
    client.election_id = (0, 1)
    client.arbitration = arbitration
    client.bind_routes(binding)
    return client


def package_binding(owner):
    """What `roles.ipv4_route` resolves to for PkgIngress.routes, with the given owner."""
    return route_binding.RouteBinding(
        table="PkgIngress.routes", match_field="hdr.ip4.dst", action="PkgIngress.send_via",
        dst_mac_param="next_mac", port_param="out_port", owner=owner,
        source=route_binding.SOURCE_PACKAGE, port_bitwidth=9)


def baseline_client(**kw):
    return a_client(route_binding.BASELINE, **kw)


def owned_package_client(**kw):
    return a_client(package_binding(route_binding.OWNER_NDTWIN), **kw)


def lpm_entry(table, **overrides):
    spec = {"table": table, "match": {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]},
            "action_name": "MyIngress.ipv4_forward",
            "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
    spec.update(overrides)
    return spec


def pkg_route_entry(**overrides):
    spec = {"table": "PkgIngress.routes", "match": {"hdr.ip4.dst": ["10.0.1.1", 32]},
            "action_name": "PkgIngress.send_via",
            "action_params": {"next_mac": "08:00:00:00:01:11", "out_port": 1}}
    spec.update(overrides)
    return spec


def pkg_default_entry(**overrides):
    spec = {"table": "PkgIngress.routes", "default_action": True,
            "action_name": "PkgIngress.no_route", "action_params": {}}
    spec.update(overrides)
    return spec


def acl_entry(**overrides):
    spec = {"table": "PkgIngress.acl", "match": {"hdr.ip4.src": "10.0.1.1"},
            "action_name": "PkgIngress.no_route", "action_params": {}}
    spec.update(overrides)
    return spec


#: What the headline defect looks like: no match at all, into a table whose every field is ternary.
EMPTY_MATCH_FLOW_5TUPLE = {"table": "MyIngress.flow_5tuple", "match": {},
                           "action_name": "MyIngress.drop", "action_params": {}, "priority": 1}


def apply_boot(client, entries):
    """`main.apply_package_entries` over a runtime file holding `entries`; returns its counts."""
    with tempfile.TemporaryDirectory(prefix="ndt-owner-test-") as tmp:
        path = os.path.join(tmp, "s1-runtime.json")
        with open(path, "w") as fh:
            json.dump({"table_entries": entries}, fh)
        return main.apply_package_entries(client, path)


def a_request(body):
    payload = json.dumps(body).encode()

    async def receive():
        return {"type": "http.request", "body": payload, "more_body": False}

    return Request({"type": "http", "http_version": "1.1", "method": "POST",
                    "path": "/p4/table_entry", "raw_path": b"/p4/table_entry",
                    "root_path": "", "scheme": "http", "query_string": b"",
                    "headers": [(b"content-type", b"application/json")],
                    "client": ("127.0.0.1", 0), "server": ("127.0.0.1", 8081)}, receive)


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


def written_tables(client):
    return [r.updates[0].entity.table_entry.table_id for r in client.stub.requests]


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ABaselineSwitchOwnsEveryTableTest(unittest.TestCase):
    """A switch bound to NDTwin's own pipeline: nothing the generic writer is asked to write."""

    def setUp(self):
        self.client = baseline_client()

    def refuse(self, spec, op="insert", **kw):
        with self.assertRaises(OWNED):
            self.client.write_table_entry(spec, op, **kw)
        self.assertEqual(self.client.stub.requests, [], "a refusal must not reach the switch")

    def test_an_empty_match_into_flow_5tuple_is_refused_and_nothing_is_written(self):
        # 🔴 THE HEADLINE. Before this, the same call returned a result and put an INSERT with
        # priority 1 and no match field on the wire: a rule that matches every packet.
        self.refuse(EMPTY_MATCH_FLOW_5TUPLE)

    def test_a_write_into_ipv4_lpm_naming_its_field_is_refused(self):
        self.refuse(lpm_entry("MyIngress.ipv4_lpm"))

    def test_every_op_is_refused_not_only_insert(self):
        for op in ("insert", "modify", "delete"):
            with self.subTest(op=op):
                self.refuse(lpm_entry("MyIngress.ipv4_lpm"), op)

    def test_every_table_in_the_pipeline_is_refused(self):
        specs = {"MyIngress.l2_forward": {
            "table": "MyIngress.l2_forward", "match": {"hdr.ethernet.dstAddr": "08:00:00:00:01:11"},
            "action_name": "MyIngress.send_to_cpu", "action_params": {}}}
        for table in self.client.p4info.tables:
            with self.subTest(table=table.preamble.name):
                spec = specs.get(table.preamble.name,
                                 {"table": table.preamble.name, "match": {},
                                  "action_name": "MyIngress.drop", "action_params": {}})
                self.refuse(spec)

    def test_the_alias_is_refused_like_the_full_name(self):
        self.refuse(lpm_entry("ipv4_lpm", action_name="ipv4_forward"))

    def test_a_default_action_change_on_a_baseline_table_is_refused(self):
        for table in ("MyIngress.ipv4_lpm", "MyIngress.l2_forward", "MyIngress.flow_5tuple"):
            for op in ("insert", "modify"):
                with self.subTest(table=table, op=op):
                    self.refuse({"table": table, "default_action": True,
                                 "action_name": "MyIngress.drop", "action_params": {}}, op)

    def test_a_baseline_default_is_refused_when_the_caller_says_boot(self):
        # The exception is for a PACKAGE's route table. A baseline table's default is NDTwin's
        # packet-in path, whoever asks.
        self.refuse({"table": "MyIngress.ipv4_lpm", "default_action": True,
                     "action_name": "MyIngress.drop", "action_params": {}},
                    "modify", source="boot")

    def test_a_baseline_default_is_refused_inside_the_boot_block_too(self):
        counts = apply_boot(self.client, [
            {"table": "MyIngress.ipv4_lpm", "default_action": True,
             "action_name": "MyIngress.drop", "action_params": {}}])
        self.assertEqual((counts["applied"], counts["failed"]), (0, 1))
        self.assertEqual(self.client.stub.requests, [])

    def test_a_baseline_match_entry_is_refused_at_boot_too(self):
        counts = apply_boot(self.client, [lpm_entry("MyIngress.ipv4_lpm")])
        self.assertEqual((counts["applied"], counts["failed"]), (0, 1))
        self.assertEqual(self.client.stub.requests, [])

    def test_the_refusal_names_the_table_and_the_reason(self):
        with self.assertRaises(OWNED) as caught:
            self.client.write_table_entry(EMPTY_MATCH_FLOW_5TUPLE)
        self.assertIn("MyIngress.flow_5tuple", str(caught.exception))
        self.assertIn("NDTwin", str(caught.exception))

    def test_the_real_compiled_pipelines_every_table_is_refused(self):
        if not os.path.isfile(REAL_P4INFO_PATH):  # pragma: no cover -- needs l0_build_check.sh p4
            self.skipTest(f"{REAL_P4INFO_PATH} is not built")
        p4info = p4info_pb2.P4Info()
        with open(REAL_P4INFO_PATH) as fh:
            text_format.Merge(fh.read(), p4info)
        client = baseline_client(p4info=p4info)
        names = [t.preamble.name for t in p4info.tables]
        self.assertIn("MyIngress.flow_5tuple", names)
        for name in names:
            with self.subTest(table=name):
                with self.assertRaises(OWNED):
                    client.write_table_entry({"table": name, "match": {},
                                              "action_name": "MyIngress.drop",
                                              "action_params": {}, "priority": 1})
        self.assertEqual(client.stub.requests, [])


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class APackageSwitchOwnsOnlyItsBoundRouteTableTest(unittest.TestCase):
    """`roles.ipv4_route` with owner ndtwin: that one table is NDTwin's, the rest is the author's."""

    def setUp(self):
        self.client = owned_package_client()

    def refuse(self, spec, op="insert", **kw):
        with self.assertRaises(OWNED):
            self.client.write_table_entry(spec, op, **kw)
        self.assertEqual(self.client.stub.requests, [], "a refusal must not reach the switch")

    def test_an_api_match_entry_into_the_owned_route_table_is_refused(self):
        self.refuse(pkg_route_entry())

    def test_every_op_on_the_owned_route_table_is_refused(self):
        for op in ("insert", "modify", "delete"):
            with self.subTest(op=op):
                self.refuse(pkg_route_entry(), op)

    def test_an_api_default_action_change_on_the_owned_route_table_is_refused(self):
        self.refuse(pkg_default_entry())
        self.refuse(pkg_default_entry(), "modify")

    def test_a_replayed_default_is_refused_like_an_api_one(self):
        self.refuse(pkg_default_entry(), source="replay")

    def test_an_explicit_api_source_is_refused(self):
        self.refuse(pkg_default_entry(), source="api")

    def test_the_alias_of_the_owned_route_table_is_refused(self):
        self.refuse(pkg_route_entry(table="routes", action_name="send_via"))

    def test_the_boot_default_of_the_owned_route_table_still_installs(self):
        # Ruling 8-1's exception: the package's default action is in place before NDTwin's
        # routes go in. Without it bring-up C would report `failed = 1`.
        counts = apply_boot(self.client, [pkg_default_entry()])
        self.assertEqual((counts["applied"], counts["failed"]), (1, 0), counts)
        entry = self.client.stub.requests[0].updates[0].entity.table_entry
        self.assertTrue(entry.is_default_action)
        self.assertEqual(self.client.stub.requests[0].updates[0].type,
                         p4runtime_pb2.Update.MODIFY)

    def test_an_explicit_boot_source_installs_the_default(self):
        result = self.client.write_table_entry(pkg_default_entry(), source="boot")
        self.assertTrue(result["is_default_action"])
        self.assertEqual(len(self.client.stub.requests), 1)

    def test_a_boot_match_entry_into_the_owned_route_table_is_refused(self):
        counts = apply_boot(self.client, [pkg_route_entry()])
        self.assertEqual((counts["applied"], counts["failed"]), (0, 1), counts)
        self.assertEqual(self.client.stub.requests, [])

    def test_a_boot_entry_with_no_match_that_is_not_a_default_is_refused(self):
        # An omitted match field is a wildcard, so "no match at all" on an ordinary entry is the
        # entry that matches everything. It is not the default action, and must not be let in as
        # one: the exception reads `default_action` and not merely the absence of a match.
        for spec in (pkg_route_entry(match={}), pkg_route_entry(match=None),
                     pkg_route_entry(match={}, default_action=False),
                     pkg_default_entry(default_action="yes")):
            with self.subTest(spec=spec):
                self.refuse(spec, "insert", source="boot")
                self.refuse(spec, "modify", source="boot")

    def test_a_boot_default_that_also_names_a_match_is_refused(self):
        # Not "a default action" at all -- two rules in one. Refused here as owned, before the
        # builder gets to call it a 400: the exception is for exactly `default, no match`.
        self.refuse(pkg_default_entry(match={"hdr.ip4.dst": ["10.0.1.1", 32]}),
                    "modify", source="boot")

    def test_a_boot_delete_of_the_default_is_refused(self):
        self.refuse(pkg_default_entry(), "delete", source="boot")

    def test_the_boot_exception_does_not_outlive_the_boot_block(self):
        apply_boot(self.client, [pkg_default_entry()])
        self.client.stub.requests.clear()
        self.refuse(pkg_default_entry())

    def test_the_boot_exception_does_not_survive_a_refused_boot_entry(self):
        apply_boot(self.client, [pkg_route_entry()])
        self.refuse(pkg_default_entry())

    def test_an_unknown_source_is_a_valueerror_and_writes_nothing(self):
        # Both an owned table and the author's own: the word is validated before the table is
        # looked at, so the answer cannot depend on which table was named.
        for spec in (pkg_default_entry(), acl_entry()):
            with self.subTest(table=spec["table"]):
                with self.assertRaises(ValueError):
                    self.client.write_table_entry(spec, source="startup")
        with self.assertRaises(ValueError):
            with p4_client_module.entry_source("startup"):
                pass
        self.assertEqual(self.client.stub.requests, [])

    def test_a_write_into_the_packages_own_user_table_is_still_accepted(self):
        for op in ("insert", "modify", "delete"):
            with self.subTest(op=op):
                self.client.write_table_entry(acl_entry(), op)
        self.assertEqual(len(self.client.stub.requests), 3)

    def test_a_user_table_default_action_through_the_api_is_still_accepted(self):
        self.client.write_table_entry({"table": "PkgIngress.acl", "default_action": True,
                                       "action_name": "PkgIngress.no_route",
                                       "action_params": {}})
        self.assertEqual(len(self.client.stub.requests), 1)

    def test_a_user_table_that_borrows_a_baseline_name_is_still_accepted(self):
        # Ownership comes from the binding. A package table that happens to be called
        # `ipv4_lpm` on a switch whose package binds a DIFFERENT table is the author's.
        client = a_client(package_binding(route_binding.OWNER_NDTWIN))
        client.write_table_entry(lpm_entry("MyIngress.ipv4_lpm"))
        self.assertEqual(len(client.stub.requests), 1)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ATableTheAuthorOwnsIsTheAuthorsTest(unittest.TestCase):
    def test_a_route_table_with_owner_package_takes_every_write_including_at_api(self):
        client = a_client(package_binding(route_binding.OWNER_PACKAGE))
        client.write_table_entry(pkg_route_entry())
        client.write_table_entry(pkg_default_entry())
        self.assertEqual(len(client.stub.requests), 2)

    def test_a_foreign_switch_with_no_roles_owns_nothing(self):
        client = a_client(None)
        for spec in (lpm_entry("MyIngress.ipv4_lpm"), EMPTY_MATCH_FLOW_5TUPLE,
                     pkg_route_entry(), pkg_default_entry()):
            client.write_table_entry(spec)
        self.assertEqual(len(client.stub.requests), 4)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheOrderOfRefusalsTest(unittest.TestCase):
    def test_an_external_control_plane_is_still_told_that_first(self):
        client = baseline_client(arbitration=False)
        with self.assertRaises(p4_client_module.ControlPlaneReadOnly):
            client.write_table_entry(EMPTY_MATCH_FLOW_5TUPLE)

    def test_a_table_this_pipeline_does_not_have_is_still_a_keyerror_not_a_409(self):
        client = baseline_client()
        with self.assertRaises(KeyError):
            client.write_table_entry(lpm_entry("MyIngress.firewall"))

    def test_a_malformed_spec_is_still_a_400_shaped_error_not_a_409(self):
        client = baseline_client()
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            client.write_table_entry(["not", "an", "object"])
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            client.write_table_entry({"match": {}})
        self.assertEqual(client.stub.requests, [])


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ThePostAnswers409Test(unittest.TestCase):
    def setUp(self):
        self.saved = (api_routes.topology, api_routes.note_api_table_entry_write)
        self.addCleanup(self.restore)
        self.counted = []
        api_routes.note_api_table_entry_write = self.counted.append

    def restore(self):
        api_routes.topology, api_routes.note_api_table_entry_write = self.saved

    def post(self, client, body):
        api_routes.topology = FakeTopology({1: client})
        return asyncio.run(api_routes.table_entry(a_request(dict(body, dpid=1))))

    def refused(self, client, body):
        with self.assertRaises(HTTPException) as caught:
            self.post(client, body)
        return caught.exception

    def test_the_headline_post_is_409_owned_by_ndtwin_and_writes_nothing(self):
        client = baseline_client()
        error = self.refused(client, EMPTY_MATCH_FLOW_5TUPLE)
        self.assertEqual(error.status_code, 409)
        self.assertEqual(error.detail["error"], "owned by NDTwin")
        self.assertEqual(error.detail["outcome"], "owned_by_ndtwin")
        self.assertEqual(error.detail["dpid"], 1)
        self.assertIn("MyIngress.flow_5tuple", error.detail["message"])
        self.assertEqual(client.stub.requests, [])
        self.assertEqual(self.counted, [], "a refused write must not be counted as an API write")

    def test_a_named_field_post_into_ipv4_lpm_is_409(self):
        client = baseline_client()
        self.assertEqual(self.refused(client, lpm_entry("MyIngress.ipv4_lpm")).status_code, 409)

    def test_an_api_default_change_on_the_owned_package_route_table_is_409(self):
        client = owned_package_client()
        error = self.refused(client, pkg_default_entry())
        self.assertEqual((error.status_code, error.detail["outcome"]), (409, "owned_by_ndtwin"))
        self.assertEqual(client.stub.requests, [])

    def test_the_remedy_and_where_it_ends_are_inside_the_first_200_bytes_of_the_body(self):
        # A long answer gets cut around 200 bytes (measured 2026-09-11, api_routes.py's priority
        # refusal). The whole remedy has to be on the near side of the cut, not only its key.
        for client, body in ((baseline_client(), EMPTY_MATCH_FLOW_5TUPLE),
                             (owned_package_client(), pkg_default_entry())):
            with self.subTest(binding=client.route_binding.source):
                error = self.refused(client, body)
                text = json.dumps({"detail": error.detail})
                remedy = json.dumps(error.detail["remedy"])
                self.assertLess(text.index('"owned_by_ndtwin"'), 200)
                self.assertLess(text.index(remedy) + len(remedy), 200)

    def test_on_ndtwins_own_pipeline_the_409_says_so_and_points_at_the_route_endpoints(self):
        # l2_forward is a table NDTwin writes nothing into; the answer must not say it does.
        l2 = {"table": "MyIngress.l2_forward", "match": {"hdr.ethernet.dstAddr": "08:00:00:00:01:11"},
              "action_name": "MyIngress.send_to_cpu", "action_params": {}}
        error = self.refused(baseline_client(), l2)
        message, remedy = error.detail["message"], error.detail["remedy"]
        self.assertIn("MyIngress.l2_forward is owned by NDTwin", message)
        self.assertIn("every table of NDTwin's own pipeline", message)
        self.assertNotIn("written by NDTwin", message)
        self.assertIn("/stats/flowentry/", remedy)
        self.assertIn("package pipeline", remedy)
        self.assertNotIn("roles.ipv4_route", remedy)

    def test_on_a_package_pipeline_the_409_names_the_role_and_points_at_another_table(self):
        error = self.refused(owned_package_client(), pkg_route_entry())
        message, remedy = error.detail["message"], error.detail["remedy"]
        self.assertIn("PkgIngress.routes is owned by NDTwin", message)
        self.assertIn("roles.ipv4_route", message)
        self.assertIn("roles.ipv4_route", remedy)
        self.assertIn("another table", remedy)
        self.assertNotIn("/stats/flowentry/", remedy)

    def test_an_external_control_plane_keeps_its_own_409_words(self):
        error = self.refused(baseline_client(arbitration=False), EMPTY_MATCH_FLOW_5TUPLE)
        self.assertEqual(error.status_code, 409)
        self.assertEqual(error.detail["error"], "external control plane")

    def test_a_post_into_the_packages_user_table_is_200(self):
        client = owned_package_client()
        body = self.post(client, acl_entry())
        self.assertEqual(body["status"], "success")
        self.assertEqual(body["table"], "PkgIngress.acl")
        self.assertEqual(len(client.stub.requests), 1)
        self.assertEqual(self.counted, [1])


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheLogLabelTest(unittest.TestCase):
    """The line a write prints says "(default action)" only for a default action."""

    def written_line(self, client, spec):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            client.write_table_entry(spec)
        return buffer.getvalue()

    def test_an_empty_match_entry_that_is_not_a_default_is_not_labelled_default(self):
        # An unbound foreign switch owns nothing, so this is the one place the catch-all shape
        # can still be written, and the log must not dress it as the table's default.
        line = self.written_line(a_client(None), EMPTY_MATCH_FLOW_5TUPLE)
        self.assertIn("MyIngress.flow_5tuple", line)
        self.assertNotIn("default action", line)

    def test_a_default_action_is_labelled_default(self):
        line = self.written_line(a_client(None), {
            "table": "PkgIngress.acl", "default_action": True,
            "action_name": "PkgIngress.no_route", "action_params": {}})
        self.assertIn("(default action)", line)

    def test_a_named_field_entry_lists_its_fields(self):
        self.assertIn("hdr.ip4.src", self.written_line(a_client(None), acl_entry()))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheBootMarkBelongsToOneThreadTest(unittest.TestCase):
    """A boot write in flight does not turn a concurrent API write into a boot one."""

    def test_an_api_write_is_refused_while_a_boot_write_is_blocked_on_the_wire(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)

        class BlockingFirstWrite:
            """The first Write waits for `release`; later ones return at once."""

            def __init__(self):
                self.requests = []

            def Write(self, request, timeout=None):
                self.requests.append(request)
                if len(self.requests) == 1:
                    entered.set()
                    release.wait(10)

        client = owned_package_client()
        client.stub = BlockingFirstWrite()
        outcome = {}

        def boot():
            try:
                with p4_client_module.entry_source("boot"):
                    client.write_table_entry(pkg_default_entry())
                outcome["boot"] = "written"
            except BaseException as err:  # noqa: BLE001 -- reported to the asserting thread
                outcome["boot"] = err

        def api():
            try:
                client.write_table_entry(pkg_default_entry())
                outcome["api"] = "written"
            except OWNED:
                outcome["api"] = "refused"
            except BaseException as err:  # noqa: BLE001
                outcome["api"] = err

        thread_a = threading.Thread(target=boot)
        thread_a.start()
        self.assertTrue(entered.wait(10), "the boot write never reached the wire")
        thread_b = threading.Thread(target=api)
        thread_b.start()
        thread_b.join(10)
        self.assertFalse(thread_b.is_alive())
        self.assertEqual(outcome.get("api"), "refused")
        self.assertEqual(len(client.stub.requests), 1, "only the boot write may be on the wire")

        release.set()
        thread_a.join(10)
        self.assertEqual(outcome.get("boot"), "written")
        entry = client.stub.requests[0].updates[0].entity.table_entry
        self.assertTrue(entry.is_default_action)
        self.assertEqual(len(client.stub.requests), 1)


if __name__ == "__main__":
    unittest.main()
