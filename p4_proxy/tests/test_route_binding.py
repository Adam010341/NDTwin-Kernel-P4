"""
The route binding: which table a destination route is written into, and when there is none.

[Co-developed with claude code -- Adam]

TICKET-P4-roles section 2.2 (and 2.1-4, whose one function both pre-flight and the proxy run).
Four things are asserted here, each one a way the ticket can be quietly not done:

  * `BASELINE` IS THE LITERALS, and the literals live nowhere else. The five names are
    ndtwin_switch.p4's; every route write spelled them before this module existed, and a
    refactor that left one spelled in place would keep every test on NDTwin's pipeline green
    while ignoring the binding. So the values are asserted, and the production modules are
    walked (AST, not grep -- a docstring quoting the name is not a use of it) for any other
    spelling.
  * `resolve` REFUSES EVERYTHING SECTION 2.1-4 LISTS, each rule by its own test, against the
    real p4infos of tutorials' basic and of `fixtures/renamed_route` -- the fixture in which
    every name differs from NDTwin's. basic spells NDTwin's five names character for character,
    so a test run only on basic cannot tell binding code from literal code (2.2-6).
  * `build_p4_client` DECIDES the binding for all three kinds of switch, and it is the factory
    readopt uses, so a power-cycled switch is re-resolved.
  * AN UNBOUND OR PACKAGE-OWNED ROUTE WRITE IS A 501 with the existing body shape, all the way
    from the HTTP handler; an external control plane's refusal still comes first.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

from __future__ import annotations

import ast
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
    import grpc
    from fastapi import HTTPException
    from google.protobuf import text_format
    from p4.config.v1 import p4info_pb2

    import proxy_agent.main as main
    from proxy_agent import api_routes, route_binding
    from proxy_agent.p4_client import (ControlPlaneReadOnly, P4RuntimeClient,
                                       RouteWriteUnsupported)
    from proxy_agent.route_binding import BASELINE, RouteBinding, RouteBindingError
    from proxy_agent.topology_manager import TopologyManager
    from tests.test_p4_client_writes import (RecordingStub, a_client as a_writes_client,
                                             only_update)

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False

import app_package  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
RENAMED = os.path.join(FIXTURES, "renamed_route")
RENAMED_P4INFO = os.path.join(RENAMED, "build", "renamed_route.p4.p4info.txtpb")
BASIC_P4INFO = os.path.join(REPO, "tools", "p4_exercise", "tests", "fixtures", "basic", "build",
                            "basic.p4.p4info.txtpb")
PROXY_AGENT = os.path.join(PROXY_DIR, "proxy_agent")

#: renamed_route.p4's route table, as package.json spells it.
RENAMED_ROLE = {"owner": "ndtwin", "table": "RouteIngress.dest_routes",
                "match_field": "hdr.ip4.dst", "action": "RouteIngress.send_via",
                "params": {"dst_mac": "next_mac", "port": "out_port"}}
#: basic.p4's -- which is NDTwin's own five names.
BASIC_ROLE = {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm",
              "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward",
              "params": {"dst_mac": "dstAddr", "port": "port"}}

#: renamed_route.p4's ids, read off the committed p4info.
RENAMED_TABLE_ID = 46408899
RENAMED_ACTION_ID = 19229455
RENAMED_OUT_PORT_ID = 1
RENAMED_NEXT_MAC_ID = 2


def a_p4info(path):
    p4info = p4info_pb2.P4Info()
    with open(path) as fh:
        text_format.Merge(fh.read(), p4info)
    return p4info


def role(**changes):
    """RENAMED_ROLE with fields replaced; `params` merges rather than replaces."""
    out = json.loads(json.dumps(RENAMED_ROLE))
    params = changes.pop("params", None)
    out.update(changes)
    if params:
        out["params"].update(params)
    return out


#: `renamed_client`'s default: resolve RENAMED_ROLE. A sentinel, because None means "unbound".
RESOLVE = object()


def renamed_client(binding=RESOLVE, stub=None, device_id=1):
    """A P4RuntimeClient double on renamed_route's p4info, bound as given (default: resolved)."""
    client = a_writes_client(stub=stub, device_id=device_id)
    client.p4info = a_p4info(RENAMED_P4INFO)
    client.bind_routes(route_binding.resolve(RENAMED_ROLE, client.p4info)
                       if binding is RESOLVE else binding)
    return client


# --- the baseline is the literals --------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheBaselineIsTheLiteralsTest(unittest.TestCase):
    """TICKET-P4-roles 2.2-1: BASELINE's values ARE what every route write used to spell."""

    def test_the_baseline_binding_is_ndtwin_switchs_own_five_names(self):
        self.assertEqual(
            (BASELINE.table, BASELINE.match_field, BASELINE.action, BASELINE.dst_mac_param,
             BASELINE.port_param),
            ("MyIngress.ipv4_lpm", "hdr.ipv4.dstAddr", "MyIngress.ipv4_forward", "dstAddr",
             "port"))

    def test_the_baseline_is_ndtwin_owned_from_the_baseline_and_two_bytes_of_port(self):
        self.assertEqual((BASELINE.owner, BASELINE.source), ("ndtwin", "baseline"))
        self.assertEqual((BASELINE.port_bitwidth, BASELINE.port_bytes), (9, 2))

    def test_every_client_that_was_never_bound_writes_through_the_baseline(self):
        # The class default. A hand-built double (and every client that existed before roles)
        # must keep writing what it always wrote.
        self.assertIs(P4RuntimeClient.route_binding, BASELINE)

    def test_the_loader_and_the_resolver_agree_on_the_shape(self):
        # app_package cannot import route_binding (a Mininet script runs it with the standard
        # library only), so the three tuples are spelled twice. Checked, not assumed.
        self.assertEqual(app_package.ROLE_KEYS, route_binding.ROLE_KEYS)
        self.assertEqual(app_package.ROLE_PARAM_KEYS, route_binding.PARAM_KEYS)
        self.assertEqual(app_package.ROLE_OWNERS, route_binding.OWNERS)


def _string_constants(tree):
    """[(value, lineno, qualified function name or '')] for every str constant that is not a
    docstring. A docstring naming the table is documentation; a string it is compared against
    is a use."""
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = getattr(node, "body", [])
            if body and isinstance(body[0], ast.Expr) and isinstance(
                    getattr(body[0], "value", None), ast.Constant) and isinstance(
                    body[0].value.value, str):
                docstrings.add(id(body[0].value))
    out = []

    def visit(node, scope):
        for child in ast.iter_child_nodes(node):
            name = scope
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                name = f"{scope}.{child.name}" if scope else child.name
            if (isinstance(child, ast.Constant) and isinstance(child.value, str)
                    and id(child) not in docstrings):
                out.append((child.value, child.lineno, scope))
            visit(child, name)

    visit(tree, "")
    return out


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheLiteralsLiveOnlyInTheBaselineTest(unittest.TestCase):
    """TICKET-P4-roles 2.2-1: after the refactor the literals appear only in BASELINE.

    [Co-developed with claude code -- Adam]
    🔴 ONE DISCLOSED EXCEPTION. `P4RuntimeClient.IPV4_LPM_TABLE = "MyIngress.ipv4_lpm"` stays a
    literal because tests/shell/mutate_p4_rule_install_time.sh (not this ticket's file) anchors
    on that exact line and mutates it; removing it would break that gate. It is not a route
    name any write uses -- the writes use the binding -- it is the install-time record's key for
    a client bound to the baseline, and it is asserted equal to BASELINE.table below.
    """

    def modules(self):
        for filename in sorted(os.listdir(PROXY_AGENT)):
            if filename.endswith(".py") and filename != "route_binding.py":
                path = os.path.join(PROXY_AGENT, filename)
                with open(path) as fh:
                    yield filename, ast.parse(fh.read())

    @staticmethod
    def the_disclosed_exception(tree):
        """The line of `P4RuntimeClient.IPV4_LPM_TABLE = "..."`, or None."""
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef) and node.name == "P4RuntimeClient":
                for stmt in node.body:
                    if (isinstance(stmt, ast.Assign) and len(stmt.targets) == 1
                            and isinstance(stmt.targets[0], ast.Name)
                            and stmt.targets[0].id == "IPV4_LPM_TABLE"):
                        return stmt.value.lineno
        return None

    def test_no_other_module_spells_the_route_table_or_the_route_action(self):
        found, scanned = [], 0
        for filename, tree in self.modules():
            scanned += 1
            allowed = self.the_disclosed_exception(tree) if filename == "p4_client.py" else None
            for value, lineno, scope in _string_constants(tree):
                if value in (BASELINE.table, BASELINE.action) and lineno != allowed:
                    found.append(f"{filename}:{lineno} ({scope or 'module'}) {value!r}")
        self.assertGreaterEqual(scanned, 10, "the scan read almost nothing -- wrong directory?")
        self.assertEqual(found, [], "the route table / action is spelled outside BASELINE")

    def test_the_one_disclosed_exception_is_the_baselines_own_table_name(self):
        self.assertEqual(P4RuntimeClient.IPV4_LPM_TABLE, BASELINE.table)

    def test_no_route_write_spells_any_of_the_five_names(self):
        writes = {"insert_ipv4_route", "modify_ipv4_route", "delete_ipv4_route",
                  "_ipv4_route_present", "_forget_route", "_lpm_match", "_build_route_entry",
                  "insert_5tuple_rule", "modify_5tuple_rule", "delete_5tuple_rule"}
        five = {BASELINE.table, BASELINE.match_field, BASELINE.action, BASELINE.dst_mac_param,
                BASELINE.port_param}
        with open(os.path.join(PROXY_AGENT, "p4_client.py")) as fh:
            constants = _string_constants(ast.parse(fh.read()))
        seen = {scope.rsplit(".", 1)[-1] for _v, _l, scope in constants}
        # Guard the guard: a rename that took these out of `writes` would make this vacuous.
        self.assertLessEqual({"insert_ipv4_route", "modify_ipv4_route", "delete_ipv4_route",
                              "_build_route_entry", "insert_5tuple_rule", "_lpm_match"}, seen)
        found = [f"p4_client.py:{lineno} {scope} {value!r}" for value, lineno, scope in constants
                 if scope.rsplit(".", 1)[-1] in writes and value in five]
        self.assertEqual(found, [])

    def test_the_renderer_takes_the_route_action_from_the_baseline(self):
        from proxy_agent import ryu_flow_stats

        self.assertEqual(ryu_flow_stats.FORWARDING_ACTIONS.get(BASELINE.action),
                         BASELINE.port_param)


# --- resolve(): the names the package wrote, checked against one p4info ------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ResolvingTheRenamedFixtureTest(unittest.TestCase):
    """2.2-6: every name differs from NDTwin's, so these can only pass by reading the role."""

    def setUp(self):
        self.p4info = a_p4info(RENAMED_P4INFO)

    def test_the_renamed_role_resolves_to_the_renamed_names(self):
        binding = route_binding.resolve(RENAMED_ROLE, self.p4info)
        self.assertEqual(
            (binding.table, binding.match_field, binding.action, binding.dst_mac_param,
             binding.port_param),
            ("RouteIngress.dest_routes", "hdr.ip4.dst", "RouteIngress.send_via", "next_mac",
             "out_port"))

    def test_the_renamed_port_width_comes_from_the_p4info(self):
        binding = route_binding.resolve(RENAMED_ROLE, self.p4info)
        self.assertEqual((binding.port_bitwidth, binding.port_bytes), (8, 1))

    def test_a_resolved_binding_says_where_it_came_from_and_who_owns_it(self):
        for owner in ("ndtwin", "package"):
            with self.subTest(owner=owner):
                binding = route_binding.resolve(role(owner=owner), self.p4info)
                self.assertEqual((binding.owner, binding.source), (owner, "package"))

    def test_an_alias_resolves_to_the_full_name_read_table_entries_reports(self):
        binding = route_binding.resolve(role(table="dest_routes", action="send_via"),
                                        self.p4info)
        self.assertEqual((binding.table, binding.action),
                         ("RouteIngress.dest_routes", "RouteIngress.send_via"))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ResolvingBasicTest(unittest.TestCase):
    """basic's role names NDTwin's five literals -- resolved, but from the PACKAGE."""

    def test_basics_role_resolves_to_the_baseline_names_but_is_the_packages(self):
        binding = route_binding.resolve(BASIC_ROLE, a_p4info(BASIC_P4INFO))
        self.assertEqual(
            (binding.table, binding.match_field, binding.action, binding.dst_mac_param,
             binding.port_param, binding.port_bitwidth),
            (BASELINE.table, BASELINE.match_field, BASELINE.action, BASELINE.dst_mac_param,
             BASELINE.port_param, BASELINE.port_bitwidth))
        self.assertEqual(binding.source, "package")
        self.assertIsNot(binding, BASELINE)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ResolveRefusesOnTheRenamedFixtureTest(unittest.TestCase):
    """Every rule of section 2.1-4, one test each, on the renamed fixture's real p4info."""

    def setUp(self):
        self.p4info = a_p4info(RENAMED_P4INFO)

    def refused(self, the_role, max_port=None):
        with self.assertRaises(RouteBindingError) as caught:
            route_binding.resolve(the_role, self.p4info, max_port=max_port,
                                  where="s1: roles.ipv4_route")
        return str(caught.exception)

    def test_a_table_the_pipeline_does_not_have(self):
        message = self.refused(role(table="MyIngress.ipv4_lpm"))
        self.assertIn("roles.ipv4_route.table", message)
        self.assertIn("MyIngress.ipv4_lpm", message)

    def test_a_match_field_the_table_does_not_have(self):
        self.assertIn("match_field", self.refused(role(match_field="hdr.ipv4.dstAddr")))

    def test_a_match_that_is_not_lpm(self):
        message = self.refused(role(table="RouteIngress.proto_tags", match_field="hdr.ip4.proto",
                                    action="RouteIngress.tag_proto",
                                    params={"dst_mac": "tag", "port": "tag"}))
        self.assertIn("is a EXACT match", message)

    def test_a_match_that_is_not_32_bits(self):
        self.assertIn("is 8 bits; an IPv4 destination is 32",
                      self.refused(role(table="RouteIngress.proto_tags",
                                        match_field="hdr.ip4.proto",
                                        action="RouteIngress.tag_proto",
                                        params={"dst_mac": "tag", "port": "tag"})))

    def test_an_action_the_pipeline_does_not_have(self):
        self.assertIn("is not an action of this pipeline",
                      self.refused(role(action="RouteIngress.forward")))

    def test_an_action_the_table_does_not_list(self):
        self.assertIn("is not one of RouteIngress.dest_routes's actions",
                      self.refused(role(action="RouteIngress.tag_proto",
                                        params={"dst_mac": "tag", "port": "tag"})))

    def test_a_dst_mac_parameter_the_action_does_not_take(self):
        self.assertIn("params.dst_mac", self.refused(role(params={"dst_mac": "dstAddr"})))

    def test_a_port_parameter_the_action_does_not_take(self):
        self.assertIn("params.port", self.refused(role(params={"port": "port"})))

    def test_a_dst_mac_that_is_not_48_bits(self):
        # Swapped: out_port (bit<8>) named as the MAC.
        message = self.refused(role(params={"dst_mac": "out_port", "port": "next_mac"}))
        self.assertIn("is 8 bits; a MAC address is 48", message)

    def test_a_port_too_narrow_for_the_topologys_largest_port(self):
        message = self.refused(RENAMED_ROLE, max_port=300)
        self.assertIn("out_port is 8 bits and the topology gives this switch port 300", message)

    def test_a_port_that_fits_is_not_refused(self):
        self.assertEqual(route_binding.resolve(RENAMED_ROLE, self.p4info, max_port=255)
                         .port_param, "out_port")

    def test_an_action_with_a_third_parameter(self):
        p4info = a_p4info(RENAMED_P4INFO)
        for action in p4info.actions:
            if action.preamble.name == "RouteIngress.send_via":
                extra = action.params.add()
                extra.id, extra.name, extra.bitwidth = 3, "vlan", 12
        with self.assertRaises(RouteBindingError) as caught:
            route_binding.resolve(RENAMED_ROLE, p4info)
        self.assertIn("also takes ['vlan']", str(caught.exception))

    def test_an_owner_outside_the_two_words(self):
        self.assertIn("owner", self.refused(role(owner="kernel")))

    def test_every_problem_is_reported_not_just_the_first(self):
        message = self.refused(role(match_field="hdr.nope", action="RouteIngress.nope"))
        self.assertIn("match_field", message)
        self.assertIn("RouteIngress.nope", message)

    def test_the_message_names_the_switch_it_is_about(self):
        self.assertTrue(self.refused(role(table="Nope.t")).startswith("s1: roles.ipv4_route"))


# --- build_p4_client decides, for all three kinds of switch ------------------------------------


def converted_package(root, exercise, topology, p4, role_flag, name):
    tools = os.path.join(REPO, "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    from p4_exercise import convert  # noqa: E402

    out = os.path.join(root, name)
    convert.convert(exercise, topology, out, p4_rel=p4,
                    role_ipv4_route=(None if role_flag is None
                                     else convert.parse_role_flag(role_flag)))
    return app_package.load(out)


RENAMED_FLAG = ("owner=ndtwin,table=RouteIngress.dest_routes,match_field=hdr.ip4.dst,"
                "action=RouteIngress.send_via,dst_mac=next_mac,port=out_port")


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheFactoryBindsEveryClientTest(unittest.TestCase):
    """2.2-2: startup and readopt build clients through one factory, and it decides."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ndtwin_route_binding_")
        basic = os.path.join(REPO, "tools", "p4_exercise", "tests", "fixtures", "basic")
        cls.renamed = converted_package(cls.tmp, RENAMED, "pod-topo/topology.json",
                                        "renamed_route.p4", RENAMED_FLAG, "renamed")
        cls.unbound = converted_package(cls.tmp, RENAMED, "pod-topo/topology.json",
                                        "renamed_route.p4", None, "renamed_unbound")
        cls.basic_owned = converted_package(
            cls.tmp, basic, "pod-topo/topology.json", "solution/basic.p4",
            "owner=package,table=MyIngress.ipv4_lpm,match_field=hdr.ipv4.dstAddr,"
            "action=MyIngress.ipv4_forward,dst_mac=dstAddr,port=port", "basic_package_owned")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, True)

    def build(self, package, dpid=1):
        client = main.build_p4_client(dpid, package=package)
        self.addCleanup(client.channel.close)
        return client

    def test_ndtwins_own_pipeline_is_bound_to_the_baseline(self):
        self.assertIs(self.build(app_package.baseline()).route_binding, BASELINE)

    def test_a_renamed_foreign_pipeline_with_roles_is_bound_to_the_renamed_names(self):
        binding = self.build(self.renamed).route_binding
        self.assertEqual((binding.table, binding.action, binding.source),
                         ("RouteIngress.dest_routes", "RouteIngress.send_via", "package"))

    def test_a_foreign_pipeline_without_roles_is_unbound(self):
        self.assertIsNone(self.build(self.unbound).route_binding)

    def test_an_owner_package_role_is_bound_but_owned_by_the_package(self):
        binding = self.build(self.basic_owned).route_binding
        self.assertEqual((binding.owner, binding.source), ("package", "package"))

    def test_the_install_time_record_keys_by_the_renamed_table(self):
        # The record's key is the table name read_table_entries will report for this switch.
        self.assertEqual(self.build(self.renamed).IPV4_LPM_TABLE, "RouteIngress.dest_routes")
        self.assertEqual(self.build(app_package.baseline()).IPV4_LPM_TABLE, BASELINE.table)

    def test_a_role_that_does_not_fit_refuses_rather_than_falling_back_to_unbound(self):
        import dataclasses
        broken = dataclasses.replace(self.renamed, roles=app_package.Roles(
            ipv4_route=dataclasses.replace(self.renamed.roles.ipv4_route,
                                           table="MyIngress.ipv4_lpm")))
        with self.assertRaises(RouteBindingError) as caught:
            main.build_p4_client(1, package=broken)
        self.assertIn("s1: roles.ipv4_route.table", str(caught.exception))

    def test_the_startup_loop_does_not_swallow_the_refusal_as_a_down_switch(self):
        import dataclasses
        from unittest import mock
        broken = dataclasses.replace(self.renamed, roles=app_package.Roles(
            ipv4_route=dataclasses.replace(self.renamed.roles.ipv4_route, action="Nope.a")))
        with mock.patch.object(main.profile, "current", return_value=broken):
            with self.assertRaises(RouteBindingError):
                main.build_p4_clients(dpids=(1,))

    def test_readopt_builds_its_client_through_the_same_factory(self):
        # So a power-cycled switch's binding is re-resolved against the program it now runs.
        # Read off main.py's own module-level wiring rather than off api_routes' globals, which
        # other suites re-inject with doubles and do not all put back.
        self.assertEqual(module_level_calls(main.__file__, "inject_readopt")[0][0],
                         "build_p4_client")

    def test_a_second_build_of_the_same_switch_is_resolved_again_not_remembered(self):
        # What readopt relies on: the switch that comes back is bound by what it runs NOW.
        first = self.build(self.renamed)
        second = self.build(self.unbound)
        self.assertIsNotNone(first.route_binding)
        self.assertIsNone(second.route_binding)


def module_level_calls(path, attribute):
    """[[argument names]] of every module-level `<x>.<attribute>(...)` call in `path`."""
    with open(path) as fh:
        tree = ast.parse(fh.read())
    out = []
    for stmt in tree.body:
        call = getattr(stmt, "value", None)
        if (isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
                and call.func.attr == attribute):
            out.append([a.id if isinstance(a, ast.Name) else None for a in call.args])
    return out


# --- the writes -> 501 at the HTTP layer --------------------------------------------------------


class FakeRequest:
    def __init__(self, body):
        self._body = body

    async def json(self):
        return self._body


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class AWriteWithNoBindingIs501OnTheRenamedFixtureTest(unittest.TestCase):
    """2.2-3: unbound / owner package / a 5-tuple on a foreign switch -> 501 unsupported_on_p4."""

    def setUp(self):
        self.saved = api_routes.topology
        self.addCleanup(setattr, api_routes, "topology", self.saved)
        self.topo = TopologyManager()
        api_routes.topology = self.topo

    def switch(self, binding, arbitration=True):
        client = renamed_client(binding=binding)
        client.arbitration = arbitration
        self.topo.add_switch(1, client)
        self.topo.add_host("10.0.1.1", "08:00:00:00:01:11", 1, 1)
        return client

    def post(self, handler, body):
        with self.assertRaises(HTTPException) as caught:
            asyncio.run(handler(FakeRequest(body)))
        return caught.exception

    ROUTE = {"dpid": 1, "match": {"dl_type": 2048, "nw_dst": "10.0.1.1"},
             "actions": [{"type": "OUTPUT", "port": 1}]}

    def test_an_unbound_switch_answers_501_unbound_on_all_three_verbs(self):
        client = self.switch(None)
        for name, handler in (("add", api_routes.add_flow_entry),
                              ("delete", api_routes.delete_flow_entry),
                              ("modify", api_routes.modify_flow_entry)):
            with self.subTest(verb=name):
                err = self.post(handler, dict(self.ROUTE))
                self.assertEqual(err.status_code, 501)
                self.assertEqual(err.detail["outcome"], "unsupported_on_p4")
                self.assertEqual(err.detail["reason"], "unbound")
        self.assertEqual(client.stub.requests, [], "an unbound switch was written to")

    def test_an_owner_package_switch_answers_501_owned_by_package(self):
        client = self.switch(route_binding.resolve(role(owner="package"),
                                                   a_p4info(RENAMED_P4INFO)))
        err = self.post(api_routes.add_flow_entry, dict(self.ROUTE))
        self.assertEqual((err.status_code, err.detail["reason"]), (501, "owned_by_package"))
        self.assertEqual(client.stub.requests, [])

    def test_a_five_tuple_write_on_a_foreign_switch_answers_501(self):
        client = self.switch(route_binding.resolve(RENAMED_ROLE, a_p4info(RENAMED_P4INFO)))
        body = dict(self.ROUTE, match={"dl_type": 2048, "nw_dst": "10.0.1.1", "ip_proto": 6,
                                       "nw_src": "10.0.2.2"})
        err = self.post(api_routes.add_flow_entry, body)
        self.assertEqual((err.status_code, err.detail["reason"]), (501, "no_five_tuple_role"))
        self.assertEqual(client.stub.requests, [])

    def test_the_body_keeps_the_shape_the_other_501s_use_and_the_remedy_fits_the_window(self):
        self.switch(None)
        err = self.post(api_routes.add_flow_entry, dict(self.ROUTE))
        self.assertEqual(list(err.detail)[:4], ["error", "outcome", "reason", "remedy"])
        # HttpRoutingStrategyBase keeps briefly(body, 200); the remedy has to be inside it.
        wire = json.dumps({"detail": err.detail}, separators=(",", ":"))
        self.assertLess(wire.index(err.detail["remedy"]) + len(err.detail["remedy"]), 200)

    def test_an_external_control_plane_refuses_first_as_it_always_did(self):
        # 2.2-4: _refuse_write keeps precedence over the binding -- same exception as before.
        client = self.switch(None, arbitration=False)
        with self.assertRaises(ControlPlaneReadOnly):
            asyncio.run(api_routes.add_flow_entry(FakeRequest(dict(self.ROUTE))))
        self.assertEqual(client.stub.requests, [])

    def test_a_bound_ndtwin_owned_switch_is_written_through_its_binding(self):
        client = self.switch(route_binding.resolve(RENAMED_ROLE, a_p4info(RENAMED_P4INFO)))
        body = asyncio.run(api_routes.add_flow_entry(FakeRequest(dict(self.ROUTE))))
        self.assertEqual(body["status"], "success")
        self.assertEqual(only_update(client.stub.requests[0]).entity.table_entry.table_id,
                         RENAMED_TABLE_ID)


if __name__ == "__main__":
    unittest.main(verbosity=2)
