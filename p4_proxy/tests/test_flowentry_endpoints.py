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
from proxy_agent.topology_manager import MalformedMatchValueError  # noqa: E402
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


class RaisingTopology:
    """Raises the given exception from every write, to exercise the handlers' except branches.

    [Co-developed with claude code -- Adam] RecordingTopology cannot reach them: it answers
    every call with a verdict, so the refusal path stays uncovered.
    """

    def __init__(self, error):
        self.error = error

    def route_flow(self, dpid, match, actions, priority=None):
        raise self.error

    def unroute_flow(self, dpid, match, priority=None):
        raise self.error

    def modify_flow(self, dpid, match, actions, priority=None):
        raise self.error


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


class MalformedMatchValueIsA400Test(unittest.TestCase):
    """
    A CIDR `nw_dst` must surface as 400, not 500. KNOWN-ISSUES B-2c.

    [Co-developed with claude code -- Adam]
    The refusal itself is tested in test_unsupported_match.py, at the layer that raises. What is
    only testable HERE is the conversion: api_routes has exactly one `except UnsupportedMatchError`
    per handler, so MalformedMatchValueError becomes a 400 solely by virtue of being a subclass.
    Break that inheritance and every test in the other file still passes while the endpoint goes
    back to answering 500 -- so the subclass relationship is pinned from the endpoint side too.

    The topology is stubbed to RAISE rather than driven for real: this asserts what the handler
    does with the exception, and a stub that raises is the only way to reach that branch without
    also depending on the manager's internals.
    """

    def setUp(self):
        self.raiser = RaisingTopology(
            MalformedMatchValueError("nw_dst", "10.0.0.5/32", "installed"))
        api_routes.topology = self.raiser

    def tearDown(self):
        api_routes.topology = None

    def test_it_answers_400_on_every_write_endpoint(self):
        body = json.dumps({"dpid": 1, "match": {"nw_dst": "10.0.0.5/32"},
                           "actions": [{"type": "OUTPUT", "port": 1}]}).encode()
        for name, handler in HANDLERS.items():
            with self.subTest(endpoint=name):
                with self.assertRaises(HTTPException) as caught:
                    call(handler, body)
                self.assertEqual(caught.exception.status_code, 400)

    def test_the_400_body_names_the_field_and_the_value_the_caller_sent(self):
        body = json.dumps({"dpid": 1, "match": {"nw_dst": "10.0.0.5/32"},
                           "actions": [{"type": "OUTPUT", "port": 1}]}).encode()
        with self.assertRaises(HTTPException) as caught:
            call(api_routes.add_flow_entry, body)
        detail = caught.exception.detail
        self.assertEqual(detail["fields"], ["nw_dst"])
        self.assertIn("10.0.0.5/32", detail["message"])


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
        #
        # [Co-developed with claude code -- Adam] The match gained its L4 fields on 2026-09-03.
        # This test's own second assertion is about the ternary table -- "on the ternary table
        # a delete that loses the priority removes nothing" -- but the match it sent was
        # destination-only, which compiles to ipv4_lpm, where that priority is not honourable
        # at all and the request is now a 501 (see
        # APriorityThatNamesAnEntryIsRefusedNotObeyedTest). Sending the match the assertion was
        # always describing keeps both claims and stops the test pinning the behaviour the
        # refusal exists to remove.
        match = {"nw_dst": "10.0.0.4", "tp_dst": 5201, "nw_proto": 6}
        for verdict, expected in ((True, "success"), (False, "error")):
            with self.subTest(verdict=verdict):
                recorder = RecordingTopology(verdict=verdict)
                api_routes.topology = recorder
                body = json.dumps({"dpid": 1, "match": match, "priority": 100}).encode()
                reply = call(api_routes.delete_flow_entry, body)
                self.assertEqual(reply["status"], expected)
                # The priority the body carried must reach the manager: on the ternary table a
                # delete that loses it removes nothing and still reports success.
                self.assertEqual(recorder.calls, [("unroute", 1, match, 100)])

    def test_a_delete_without_a_destination_is_refused_not_a_wipe(self):
        # OpenFlow's non-strict delete treats an empty match as "clear the table". Serving
        # that here would turn one malformed kernel call into an empty fabric, so the shared
        # handler must keep unroute_flow's refusal instead.
        tm = TopologyManager.__new__(TopologyManager)
        tm.switches = {1: object()}
        self.assertIs(tm.unroute_flow(1, {}), False)


class TheAddResponseSaysWhetherThePriorityWasHonouredTest(unittest.TestCase):
    """
    FINDING-07's residue: `success` was true about the request and false about the consequence.

    [Co-developed with claude code -- Adam]
    Seventeen rules were POSTed at priorities 902 and 910-927 on 2026-08-30 and every one came
    back off the switch at priority 0. The corrected reading is that nothing dropped the value:
    a destination-only match compiles to `ipv4_lpm`, a P4 LPM table with no priority column at
    all, where precedence is the prefix length. So the priority is not lost in transit -- it is
    unrepresentable at the destination, and the endpoint accepted it, routed it to that table,
    and answered `{"status": "success"}` with nothing said.

    That is what these tests pin, and only that. They do NOT assert a refusal: a 200 -> 400 here
    is a breaking change for a caller that does not read status codes, which this project has
    (T-15 Option 0, and the 2026-08-30 §1.2 ruling it cites). The disclosure is additive, so the
    kernel -- whose only check on this body is `status == "error"`,
    HttpRoutingStrategyBase.cpp:123-125 -- cannot see the difference.

    The topology is stubbed: which table a match compiles to is decided by `needs_five_tuple` on
    the match alone, so driving a real TopologyManager would add a gRPC dependency without adding
    coverage of the thing under test.
    """

    def setUp(self):
        self.recorder = RecordingTopology(verdict=True)
        api_routes.topology = self.recorder

    def tearDown(self):
        api_routes.topology = None

    @staticmethod
    def _add(match, priority=None, port=2):
        body = {"dpid": 1, "match": match, "actions": [{"type": "OUTPUT", "port": port}]}
        if priority is not None:
            body["priority"] = priority
        return call(api_routes.add_flow_entry, json.dumps(body).encode())

    def test_a_destination_only_rule_says_its_priority_was_not_honoured(self):
        # The exact shape of FINDING-07's seventeen: dl_type + nw_dst, priority 915.
        out = self._add({"dl_type": 2048, "nw_dst": "10.0.0.240"}, priority=915)
        self.assertEqual(out["status"], "success")
        self.assertEqual(out["table"], "ipv4_lpm")
        self.assertIs(out["priority_honoured"], False)
        self.assertIn("prefix length", out["priority_note"])

    def test_a_five_tuple_rule_says_its_priority_was_honoured(self):
        # More than a destination, so it compiles to the ternary table that has a priority
        # column. The same request shape must NOT carry the caveat, or the caveat means nothing.
        out = self._add({"dl_type": 2048, "nw_dst": "10.0.0.240", "tp_dst": 5201,
                         "nw_proto": 6}, priority=915)
        self.assertEqual(out["status"], "success")
        self.assertEqual(out["table"], "flow_5tuple")
        self.assertIs(out["priority_honoured"], True)
        self.assertNotIn("priority_note", out)

    def test_the_note_is_only_for_a_caller_that_actually_asked_for_a_priority(self):
        # Every rule the kernel writes itself is destination-only and sends no priority. Telling
        # those callers their priority was ignored would make the caveat noise, and a caveat that
        # fires on every call is one nobody reads by the time it matters.
        out = self._add({"dl_type": 2048, "nw_dst": "10.0.0.240"})
        self.assertEqual(out["table"], "ipv4_lpm")
        self.assertIs(out["priority_honoured"], False)
        self.assertNotIn("priority_note", out)

    def test_a_failed_write_is_still_reported_as_an_error(self):
        # The disclosure must not leak onto the failure path and turn a refused write into
        # something that reads like a qualified success.
        self.recorder.verdict = False
        out = self._add({"dl_type": 2048, "nw_dst": "10.0.0.240"}, priority=915)
        self.assertEqual(out["status"], "error")
        self.assertNotIn("priority_honoured", out)

    def test_the_priority_still_reaches_the_topology_unchanged(self):
        # Disclosing that a value is unused must not become a reason to stop forwarding it: the
        # ternary path needs it, and the two paths share this handler.
        self._add({"dl_type": 2048, "nw_dst": "10.0.0.240"}, priority=915)
        self.assertEqual(self.recorder.calls[-1][0], "route")
        self.assertEqual(self.recorder.calls[-1][4], 915)




class APriorityThatNamesAnEntryIsRefusedNotObeyedTest(unittest.TestCase):
    """
    The half of FINDING-07 that disclosure cannot reach.

    [Co-developed with claude code -- Adam]
    `TheAddResponseSaysWhetherThePriorityWasHonouredTest` above pins the *install* answer, and
    deliberately does not assert a refusal: on an install the priority is a request about
    *precedence*, the rule is programmed and does forward, and the 2026-08-30 §1.2 ruling
    (T-15 Option 0) settled that a 200 -> 4xx there is a breaking change this project cannot
    take. None of that transfers to delete_strict and modify, because on those two verbs the
    priority is not precedence, it is *identity*: it names WHICH entry the caller means.

    ipv4_lpm holds one entry per destination and has no priority column, so every priority
    names that one entry. Measured 2026-09-03 (doc/audit/2026-09-03_night-rounds/): a modify at
    priority 777, a priority that had never existed on the switch, rewrote the entry that was
    there; a delete at priority 999 removed it. Both answered success. That is not an
    under-delivery a note can qualify after the fact -- the rule the caller never named is
    already gone by the time anyone reads the body. The only honest answer is to not do it.

    The two-sidedness is the point and is asserted in both directions: this must fire for a
    priority the table cannot honour, and must NOT fire for the requests the kernel itself
    makes. A refusal that refused everything would satisfy half these tests and break the
    fabric.
    """

    def setUp(self):
        self.recorder = RecordingTopology(verdict=True)
        api_routes.topology = self.recorder

    def tearDown(self):
        api_routes.topology = None

    @staticmethod
    def _body(match, priority=None, port=2):
        body = {"dpid": 1, "match": match, "actions": [{"type": "OUTPUT", "port": port}]}
        if priority is not None:
            body["priority"] = priority
        return json.dumps(body).encode()

    DEST_ONLY = {"dl_type": 2048, "nw_dst": "10.0.0.240"}
    FIVE_TUPLE = {"dl_type": 2048, "nw_dst": "10.0.0.240", "tp_dst": 5201, "nw_proto": 6}

    # --- the refusal fires, for the reason it claims -------------------------------------

    def test_a_delete_naming_a_priority_ipv4_lpm_cannot_honour_is_501(self):
        # The measured call: delete at 999 against a rule that is not at 999.
        with self.assertRaises(HTTPException) as caught:
            call(api_routes.delete_flow_entry, self._body(self.DEST_ONLY, priority=999))
        self.assertEqual(caught.exception.status_code, 501)
        self.assertEqual(caught.exception.detail["outcome"], "unsupported_on_p4")
        self.assertEqual(caught.exception.detail["requested_priority"], 999)
        self.assertIn("ipv4_lpm", caught.exception.detail["message"])

    def test_a_modify_naming_a_priority_ipv4_lpm_cannot_honour_is_501(self):
        # The measured call: modify at 777, a priority that never existed.
        with self.assertRaises(HTTPException) as caught:
            call(api_routes.modify_flow_entry, self._body(self.DEST_ONLY, priority=777))
        self.assertEqual(caught.exception.status_code, 501)
        self.assertEqual(caught.exception.detail["outcome"], "unsupported_on_p4")
        self.assertEqual(caught.exception.detail["requested_priority"], 777)

    def test_the_refused_write_never_reaches_the_switch(self):
        # A refusal that answers 501 *after* actuating is the same defect wearing a status
        # code. Nothing may be handed to the topology on either verb.
        for handler, raw in ((api_routes.delete_flow_entry,
                              self._body(self.DEST_ONLY, priority=999)),
                             (api_routes.modify_flow_entry,
                              self._body(self.DEST_ONLY, priority=777))):
            with self.assertRaises(HTTPException):
                call(handler, raw)
        self.assertEqual(self.recorder.calls, [])

    # --- and does not fire for anything else ---------------------------------------------

    def test_the_kernels_own_priority_less_delete_still_works(self):
        # FlowRoutingManager::deleteAnEntry defaults to -1, which HttpRoutingStrategyBase turns
        # into the non-strict route with NO priority key at all. This is every delete the
        # control plane and the IntentTranslator make.
        out = call(api_routes.delete_flow_entry, self._body(self.DEST_ONLY))
        self.assertEqual(out["status"], "success")
        self.assertEqual(self.recorder.calls[-1][0], "unroute")

    def test_the_kernels_own_modify_at_the_absent_priority_default_still_works(self):
        # HttpSession::makeModifyJob defaults an absent priority to 0, so 0 reaches here on
        # every ordinary modify. Refusing 0 would refuse the whole modify path.
        out = call(api_routes.modify_flow_entry, self._body(self.DEST_ONLY, priority=0))
        self.assertEqual(out["status"], "success")
        self.assertEqual(self.recorder.calls[-1][0], "modify")

    def test_the_non_strict_delete_sentinel_is_not_a_named_priority(self):
        # -1 is "delete anything matching", not a request for precedence -1.
        out = call(api_routes.delete_flow_entry, self._body(self.DEST_ONLY, priority=-1))
        self.assertEqual(out["status"], "success")
        self.assertEqual(self.recorder.calls[-1][0], "unroute")

    def test_a_five_tuple_match_at_the_same_priority_is_not_refused(self):
        # Same verb, same priority, a match that compiles to the ternary table -- where the
        # priority IS the entry's identity and IS programmed. If this were refused too, the
        # refusal would be about the verb rather than about what the plane can honour.
        for handler, verb in ((api_routes.delete_flow_entry, "unroute"),
                              (api_routes.modify_flow_entry, "modify")):
            with self.subTest(verb=verb):
                out = call(handler, self._body(self.FIVE_TUPLE, priority=999))
                self.assertEqual(out["status"], "success")
                self.assertEqual(self.recorder.calls[-1][0], verb)
                self.assertIs(out["priority_honoured"], True)

    def test_an_install_is_still_disclosed_rather_than_refused(self):
        # The standing ruling, pinned from this class as well so that widening the refusal to
        # the install path reddens the test that names the ruling rather than passing quietly.
        out = call(api_routes.add_flow_entry, self._body(self.DEST_ONLY, priority=500))
        self.assertEqual(out["status"], "success")
        self.assertIs(out["priority_honoured"], False)

    # --- and the answers that are not refused still say where the rule went ---------------

    def test_a_delete_that_is_honoured_says_which_table_it_reached(self):
        out = call(api_routes.delete_flow_entry, self._body(self.DEST_ONLY))
        self.assertEqual(out["table"], "ipv4_lpm")
        self.assertIs(out["priority_honoured"], False)

    def test_a_failed_delete_is_still_reported_as_an_error(self):
        # The disclosure must not leak onto the failure path, as on the add endpoint.
        self.recorder.verdict = False
        out = call(api_routes.delete_flow_entry, self._body(self.DEST_ONLY))
        self.assertEqual(out["status"], "error")
        self.assertNotIn("priority_honoured", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
