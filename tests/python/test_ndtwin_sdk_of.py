#!/usr/bin/env python3
"""`k.of.write` and `k.of.dispatch_status` of sdk/python/ndtwin against an in-process fake of the
kernel's flow-entry routes (tests/python/of_fake_kernel.py).

[Co-developed with claude code -- Adam]

The SDK is imported from sdk/python (or $NDTWIN_SDK_UNDER_TEST, which
tests/shell/mutate_ndtwin_sdk_of.sh points at its mutated copies). Covered: the body each op
sends and the route it goes to, the wait on the kernel's dispatch record, how each reply of the
POST and each failure record maps onto an exception and whether the POST is sent again, and what
is refused before anything is sent. Every canned reply names, in of_fake_kernel.py or beside it
here, the line of the kernel (at 9c0569de5) or of the P4 proxy it was copied from
(HS.cpp = src/ndt_core/http/HttpSession.cpp, HRSB.cpp =
src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp). Standard library only; runs
under Python 3.8 too, like tests/python/test_ndtwin_sdk.py.

    python3 tests/python/test_ndtwin_sdk_of.py -v
"""
import contextlib
import io
import os
import re
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from of_fake_kernel import (DISPATCH, LAB_CLAIM, OfFakeKernel, failure, queued,  # noqa: E402
                            record, serve)

SDK_DIR = os.environ.get("NDTWIN_SDK_UNDER_TEST") or os.path.join(REPO, "sdk", "python")
README = os.path.join(REPO, "sdk", "python", "README.md")
sys.path.insert(0, SDK_DIR)
import ndtwin  # noqa: E402

INSTALL, MODIFY, DELETE = ("/ndt/install_flow_entry", "/ndt/modify_flow_entry",
                           "/ndt/delete_flow_entry")
MATCH = {"eth_type": 2048, "ipv4_dst": "10.0.0.2"}
ENTRY = {"dpid": 1, "priority": 100, "match": MATCH, "actions": [{"type": "OUTPUT", "port": 3}]}


def with_claim(body):
    """A refusal of a write route, with the lab_claim key the kernel adds to it (HS.cpp:757)."""
    return dict(body, lab_claim=dict(LAB_CLAIM))


class OfTest(unittest.TestCase):
    def setUp(self):
        self.fake = OfFakeKernel()
        self.server = serve(self.fake)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.k = ndtwin.Kernel(self.url, timeout=5, retry_wait=0)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def posts(self):
        return self.fake.count("POST")

    def gets(self):
        return self.fake.count("GET", DISPATCH)


class WriteSendsTest(OfTest):
    """The body and route of each op, and what the return carries."""

    def test_each_op_sends_the_entry_as_is_to_its_own_route(self):
        install = dict(ENTRY, idle_timeout=30)
        modify = dict(ENTRY, actions=[{"type": "OUTPUT", "port": 4}])
        delete = {"dpid": 1, "priority": 100, "match": MATCH}
        for op, entry, path in (("install", install, INSTALL), ("modify", modify, MODIFY),
                                ("delete", delete, DELETE)):
            with self.subTest(op):
                self.fake.requests.clear()
                self.k.of.write(entry, op)
                posts = [r for r in self.fake.requests if r[0] == "POST"]
                self.assertEqual([(p, q, b) for _, p, q, b in posts], [(path, {}, entry)])

    def test_install_is_the_default_op(self):
        self.k.of.write(ENTRY)
        self.assertEqual(self.fake.requests[0][1], INSTALL)

    def test_the_return_carries_the_bodys_request_id_accepted_and_lab_claim(self):
        # HS.cpp:2731-2738 and :757: lab_claim is a key of the body; these routes send no
        # X-NDTwin-Lab-Claim header (buildResponse, HS.cpp:358-370), and the fake sends none.
        claim = {"state": "active", "owner": "alice", "expires_at": 1764000000, "note": "run 3"}
        self.fake.script("POST", INSTALL, (200, dict(queued(41), lab_claim=claim)))
        result = self.k.of.write(ENTRY)
        self.assertIsInstance(result, ndtwin.FlowWrite)
        self.assertEqual((result.request_id, result.accepted, result.lab_claim), (41, 1, claim))
        self.assertEqual(result.body["status"], "queued")
        self.assertEqual(self.fake.requests[1][2], {"request_id": "41"})

    def test_the_entry_is_a_flow_entry_with_properties(self):
        e = ndtwin.FlowEntry(dict(ENTRY, idle_timeout=5))
        self.assertEqual((e.dpid, e.priority, e.match, e.actions, e.idle_timeout),
                         (1, 100, MATCH, ENTRY["actions"], 5))
        self.assertIsNone(ndtwin.FlowEntry({"dpid": 2}).priority)

    def test_k_of_is_the_of_namespace(self):
        self.assertIsInstance(self.k.of, ndtwin.OF)


class WaitTest(OfTest):
    """The wait on the dispatch record, `wait_s=0`, and `dispatch_status`."""

    def test_it_waits_until_the_record_is_complete(self):
        # HS.cpp:1949: complete is dispatched >= enqueued; a job still queued reads false.
        self.fake.script("POST", INSTALL, (200, queued(9)))
        self.fake.script("GET", DISPATCH, (200, record(9, dispatched=0, ok=0)),
                         (200, record(9, dispatched=0, ok=0)), (200, record(9)))
        result = self.k.of.write(ENTRY)
        self.assertEqual((self.posts(), self.gets()), (1, 3))
        self.assertIsNone(result.on_switch, "on OVS nothing says the switch has the rule")
        self.assertEqual(result.failures, [])

    def test_wait_s_0_returns_after_the_post_and_reads_no_record(self):
        result = self.k.of.write(ENTRY, wait_s=0)
        self.assertEqual((self.posts(), self.gets()), (1, 0))
        self.assertIsNone(result.on_switch)
        self.assertIsNone(result.failures)
        self.assertIsInstance(result.request_id, int)

    def test_wait_s_must_be_finite_and_not_negative(self):
        for bad in (-1, float("inf"), float("nan"), "10"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    self.k.of.write(ENTRY, wait_s=bad)
        self.assertEqual(self.fake.requests, [])

    def test_dispatch_status_returns_the_record_as_the_kernel_gives_it(self):
        self.fake.script("GET", DISPATCH, (200, record(5)))
        self.assertEqual(self.k.of.dispatch_status(5), record(5))
        self.assertEqual(self.fake.requests[0][1:3], (DISPATCH, {"request_id": "5"}))
        for bad in (0, -1, "5", True):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    self.k.of.dispatch_status(bad)


class WaitFailsTest(OfTest):
    """A wait that cannot tell the outcome: the record stays incomplete, the dispatcher
    stopped, the record cannot be read."""

    def test_a_record_still_incomplete_at_wait_s_is_outcome_unknown_with_the_request_id(self):
        self.fake.script("POST", INSTALL, (200, queued(12)))
        self.fake.script("GET", DISPATCH, *[(200, record(12, dispatched=0, ok=0))] * 100)
        started = time.monotonic()
        with self.assertRaises(ndtwin.OutcomeUnknown) as ctx:
            self.k.of.write(ENTRY, wait_s=0.3)
        self.assertLess(time.monotonic() - started, 3)
        err = ctx.exception
        self.assertEqual(err.request_id, 12)
        self.assertIsNone(err.nothing_written)
        self.assertIn("not complete within", str(err))
        self.assertEqual(self.posts(), 1)
        self.assertGreaterEqual(self.gets(), 2)

    def test_a_stopped_dispatcher_is_outcome_unknown_at_once(self):
        # HS.cpp:1965 and its note at :1950-1953: complete false with dispatcher_running false
        # means the jobs were dropped before any southbound attempt; a worker may also still be
        # draining a burst it took before the stop (FlowDispatcher.cpp:115).
        self.fake.script("POST", INSTALL, (200, queued(13)))
        self.fake.script("GET", DISPATCH, (200, record(13, dispatched=0, ok=0, running=False)))
        with self.assertRaises(ndtwin.OutcomeUnknown) as ctx:
            self.k.of.write(ENTRY, wait_s=5)
        self.assertEqual(ctx.exception.request_id, 13)
        self.assertIn("dispatcher stopped", str(ctx.exception))
        self.assertEqual(self.gets(), 1)

    def test_an_unknown_request_id_is_outcome_unknown(self):
        # HS.cpp:1922-1934: 404 `unknown request_id` (aged out, or the kernel restarted).
        self.fake.script("POST", INSTALL, (200, queued(14)))
        self.fake.script("GET", DISPATCH, (404, {
            "status": "error", "error": "unknown request_id", "request_id": 14,
            "request_ids_forgotten": 3, "request_ids_capacity": 1024,
            # shortened: HS.cpp:1928-1933 has a longer detail
            "detail": "this kernel has no record of that request."}))
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.of.write(ENTRY)
        err = ctx.exception
        self.assertIs(type(err), ndtwin.OutcomeUnknown)
        self.assertIsNone(err.nothing_written)
        self.assertEqual(err.request_id, 14)
        self.assertEqual(self.posts(), 1)

    def test_a_record_that_is_not_a_dict_is_outcome_unknown(self):
        # Made up: the kernel always answers an object (HS.cpp:1938-1966).
        for reply in ([], "complete"):
            with self.subTest(reply=reply):
                self.fake.script("POST", INSTALL, (200, queued(15)))
                self.fake.script("GET", DISPATCH, (200, reply))
                with self.assertRaises(ndtwin.NDTwinError) as ctx:
                    self.k.of.write(ENTRY)
                self.assertIs(type(ctx.exception), ndtwin.OutcomeUnknown)
                self.assertEqual(ctx.exception.request_id, 15)

    def test_dispatch_status_alone_raises_not_found_for_an_unknown_id(self):
        self.fake.script("GET", DISPATCH, (404, {"status": "error", "error": "unknown request_id",
                                                 "request_id": 99}))
        with self.assertRaises(ndtwin.NotFound):
            self.k.of.dispatch_status(99)


# Failure records as the kernel writes them (HS.cpp:1855-1880 via of_fake_kernel.failure). The
# message is HRSB.cpp:244-248 ("<describe()> returned HTTP <status>[: <200 bytes of body>]") for a
# far end that answered, :225-227 for one that did not, :200-203 for curl that never ran.
# describe(): "Ryu controller" (OpenFlowRoutingStrategy.hpp:23), "P4 proxy agent"
# (P4RoutingStrategy.hpp:32). refused_by: HRSB.cpp:88-95 (refuserOf). Ryu's empty bodies:
# ryu/app/ofctl_rest.py `command_method` (Ryu 4.34), `Response(status=...)` with no body. Texts
# marked "invented" or "shortened" below are not copied from any code.
RYU = "Ryu controller returned HTTP "
OVS_ROWS = [
    # name, failure record, class, nothing_written
    ("Ryu 404: no such datapath",
     failure(20, 404, RYU + "404", "controller"), ndtwin.NotFound, True),
    ("Ryu 400: invalid syntax",
     failure(20, 400, RYU + "400", "controller"), ndtwin.Refused, True),
    ("Ryu 501: a request this OpenFlow version does not support",  # ofctl_rest.py:281-284
     failure(20, 501, RYU + "501", "controller"), ndtwin.Refused, True),
    ("controller_status 0: no answer within 5 s",          # HRSB.cpp:221-233 (unreachable)
     failure(20, 0, "no response from Ryu controller at 127.0.0.1:8080 within 5s"),
     ndtwin.OutcomeUnknown, None),
    ("500 with no refused_by: curl never ran",              # HRSB.cpp:198-204 (notSent)
     failure(20, 500, "this kernel could not run curl, so the Ryu controller at 127.0.0.1:8080 "
                      "was never asked: exit 127"),          # the part after ": " is invented
     ndtwin.NDTwinError, True),
    ("Ryu 500: an exception inside Ryu",                    # the HTML body is invented
     failure(20, 500, RYU + "500: <html><body><h1>500 Internal Server Error</h1>",
             "controller"), ndtwin.OutcomeUnknown, None),
    ("404 with no refused_by: the kernel lost the switch",  # FlowRoutingManager.cpp:120 (install)
     failure(20, 404, "no routing strategy for dpid 1"), ndtwin.NotFound, True),
]


class DispatchFailureTest(OfTest):
    """Each failure record of a write on OVS, and records the SDK cannot read -> the exception."""

    def raised(self, rec, enqueued=1, failed=1, retained=None, **record_kw):
        self.fake.requests.clear()
        self.fake.script("POST", INSTALL, (200, queued(20)))
        failures = [rec] if retained is None else retained
        self.fake.script("GET", DISPATCH, (200, record(
            20, enqueued=enqueued, dispatched=enqueued, ok=enqueued - failed, failed=failed,
            failures=failures, **record_kw)))
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.of.write(ENTRY)
        return ctx.exception

    def test_ryu_404_is_not_found_and_says_the_switch_is_not_connected(self):
        err = self.raised(OVS_ROWS[0][1])
        self.assertIs(type(err), ndtwin.NotFound)
        self.assertIs(err.nothing_written, True)
        self.assertIn("not connected to the controller", str(err))
        self.assertEqual((err.request_id, err.failures), (20, [OVS_ROWS[0][1]]))
        self.assertEqual(err.lab_claim, LAB_CLAIM)

    def test_each_row(self):
        for name, rec, cls, nothing_written in OVS_ROWS:
            with self.subTest(name):
                err = self.raised(rec)
                self.assertIs(type(err), cls)
                self.assertIs(err.nothing_written, nothing_written)
                self.assertEqual(err.request_id, 20)
                self.assertEqual(err.failures, [rec])
                self.assertEqual((self.posts(), self.gets()), (1, 1))

    def test_a_record_without_a_readable_status_is_outcome_unknown(self):
        # The kernel always writes an integer controller_status (HS.cpp:1864); these records are
        # made up to stand for a reply the SDK cannot read.
        missing = failure(20, 400, RYU + "400", "controller")
        del missing["controller_status"]
        for rec in (failure(20, None, RYU + "400", "controller"),
                    failure(20, "404", RYU + "404", "controller"), missing):
            with self.subTest(rec=rec):
                err = self.raised(rec)
                self.assertIs(type(err), ndtwin.OutcomeUnknown)
                self.assertIsNone(err.nothing_written)

    def test_a_4xx_with_no_refused_by_is_refused(self):
        # No flow job gets this at 9c0569de5: FlowRoutingManager.cpp:162 answers it for a group or
        # meter payload without a dpid (dispatchByPayloadDpid). Kept for the SDK's branch.
        err = self.raised(failure(20, 400, "install flow entry requires a dpid"))
        self.assertIs(type(err), ndtwin.Refused)
        self.assertIs(err.nothing_written, True)

    def test_a_status_the_sdk_cannot_place_is_outcome_unknown(self):
        # Made up: no path of the kernel at 9c0569de5 records a 503 without refused_by.
        err = self.raised(failure(20, 503, "a far end said 503"))
        self.assertIs(type(err), ndtwin.OutcomeUnknown)
        self.assertIsNone(err.nothing_written)

    def test_a_failure_the_kernel_no_longer_keeps_is_outcome_unknown(self):
        # HS.cpp:1961: failures_not_retained, records the ring has dropped.
        err = self.raised(None, retained=[], not_retained=1)
        self.assertIs(type(err), ndtwin.OutcomeUnknown)
        self.assertIsNone(err.nothing_written)
        self.assertIn("no longer keeps", str(err))


# The P4 plane: dpids of bmv2 switches go to the P4 proxy (FlowRoutingManager.cpp:79-82), whose
# answer is about the switch (P4RoutingStrategy.hpp:38): a 2xx is accepted_by_switch and a non-2xx
# rejected_by_switch (DispatchOutcomeLog.hpp:299-310, HRSB.cpp:244-256 withProgrammingRefused).
PROXY = "P4 proxy agent returned HTTP "
P4_SWITCH_REFUSED = failure(30, 502, PROXY + '502: {"status":"error","message":"Failed to add '
                                    'route"}', "switch")     # api_routes.py:729, :793
P4_UNSUPPORTED = failure(                                     # api_routes.py:227-257
    30, 501, PROXY + '501: {"detail":{"error":"no NDTwin route binding for this write",'
                     '"outcome":"unsupported_on_p4","reason":"owned_by_package","remedy":"the '
                     'package owns this table: use POST /p4/table_entry","dpid":1,"message...',
    # the message is cut by hand, not at the kernel's 200 bytes (HRSB.cpp:62-79)
    "proxy", outcome="unsupported_on_p4", reason="owned_by_package",
    remedy="the package owns this table: use POST /p4/table_entry")
P4_UNKNOWN_SWITCH = failure(                                  # api_routes.py:704-715,
    30, 404, PROXY + '404: {"status":"error","message":"Failed to add route","error":"unknown '
                     'switch","dpid":1,"reason":"switch 1 is not connected to the proxy; nothing '
                     'was written"}', "proxy",                # topology_manager.py:1426-1428
    reason="switch 1 is not connected to the proxy; nothing was written")
P4_PROXY_500 = failure(                                       # an exception in a proxy handler:
    30, 500, PROXY + "500: Internal Server Error", "proxy")   # Starlette's text/plain 500
P4_NOT_PRIMARY = failure(                                     # api_routes.py:704-715,
    30, 409, PROXY + '409: {"status":"error","message":"Failed to add route","error":"switch '
                     'not primary"...', "proxy",              # topology_manager.py:1941-1946
    reason="switch 1 was not given a pipeline at proxy start because this proxy is not primary "
           "on it")                                       # shortened, as is the message


class P4PlaneTest(OfTest):
    """The same call on a bmv2 switch, through the P4 proxy."""

    def write(self, rec, accepted=0, rejected=0):
        self.fake.script("POST", INSTALL, (200, queued(30)))
        failed = 1 if rec else 0
        self.fake.script("GET", DISPATCH, (200, record(
            30, ok=1 - failed, failed=failed, accepted=accepted, rejected=rejected,
            failures=[rec] if rec else [])))
        return self.k.of.write(ENTRY)

    def test_accepted_by_the_switch_is_on_switch_true(self):
        result = self.write(None, accepted=1)
        self.assertIs(result.on_switch, True)
        self.assertEqual(result.failures, [])

    def test_a_write_the_proxy_reports_failed_is_outcome_unknown(self):
        # The proxy answers 502 for any write that came back False, gRPC errors of its own
        # included (api_routes.py:779-793), and the record keeps no p4rt_error (HS.cpp:1855-1880).
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.write(P4_SWITCH_REFUSED, rejected=1)
        err = ctx.exception
        self.assertIs(type(err), ndtwin.OutcomeUnknown)
        self.assertIsNone(err.nothing_written)
        self.assertTrue(err.may_have_landed)
        self.assertIn("does not say whether the switch has it", str(err))
        self.assertEqual(err.failures, [P4_SWITCH_REFUSED])

    def test_a_switch_the_proxy_does_not_know_is_not_found(self):
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.write(P4_UNKNOWN_SWITCH, rejected=1)
        self.assertIs(type(ctx.exception), ndtwin.NotFound)
        self.assertIs(ctx.exception.nothing_written, True)

    def test_a_proxy_5xx_other_than_502_is_outcome_unknown(self):
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.write(P4_PROXY_500, rejected=1)
        self.assertIs(type(ctx.exception), ndtwin.OutcomeUnknown)
        self.assertIsNone(ctx.exception.nothing_written)

    def test_a_package_pipeline_is_refused_with_the_proxys_remedy(self):
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.write(P4_UNSUPPORTED, rejected=1)
        err = ctx.exception
        self.assertIs(type(err), ndtwin.Refused)
        self.assertIs(err.nothing_written, True)
        self.assertEqual(err.remedy, "the package owns this table: use POST /p4/table_entry")
        self.assertEqual(err.failures[0]["outcome"], "unsupported_on_p4")

    def test_a_switch_the_proxy_is_not_primary_on_is_refused(self):
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.write(P4_NOT_PRIMARY, rejected=1)
        self.assertIs(type(ctx.exception), ndtwin.Refused)
        self.assertIsNone(ctx.exception.remedy)


# Replies of the POST itself (no X-NDTwin-Origin on these routes: buildResponse, HS.cpp:358-370).
POST_ROWS = [
    # name, status, body, class, nothing_written
    ("400 malformed flow entry", 400, with_claim({                       # HS.cpp:2472-2478
        "status": "error", "error": "malformed flow entry",
        "entries": [{"field": "install_flow_entries", "index": 0,
                     "problem": '"priority" must be an integer from 0 to 65535 (omit it for the '
                                'default)'}],
        "detail": "nothing was queued; these entries cannot form a rule whatever the switch "
                  "answers, so the whole batch is rejected rather than partly applied"}),
     ndtwin.Refused, True),
    ("400 Bad entry", 400, with_claim({"error": "Bad entry"}),            # HS.cpp:2576
     ndtwin.Refused, True),
    ("400 must be arrays", 400, with_claim({                              # HS.cpp:2426
        "error": "install_flow_entries/modify_flow_entries/delete_flow_entries must be arrays"}),
     ndtwin.Refused, True),
    ("404 unknown dpid", 404, with_claim({                                # HS.cpp:2636-2641
        "status": "error", "error": "unknown dpid", "unknown_dpids": [1],
        "detail": "these dpids are not switches in the loaded topology; check the dpid, or that "
                  "the topology file matches the running network"}),
     ndtwin.NotFound, True),
    ("404 Not Found: a kernel without the route", 404, {"error": "Not Found"},   # HS.cpp:3830
     ndtwin.NotFound, True),
    ("501 a P4 delete the proxy cannot honour", 501, with_claim({        # HS.cpp:2618-2625,
        "status": "error", "error": "priority not honourable on this table",   # :2513-2522
        "outcome": "unsupported_on_p4",
        "detail": "nothing was queued: every entry is a delete the P4 proxy refuses before it "
                  "reaches the switch",
        # FlowJob.hpp:462-465
        "refused_on_p4": [{"index": 0, "dpid": 1, "requested_priority": 100}],
        # shortened: HS.cpp:2515-2521 has the whole sentence
        "refused_on_p4_reason": "priority not honourable on this table: ... Remedy: match the "
                                "full five-tuple, or omit the priority"}),
     ndtwin.Refused, True),
    ("400 JSON parsing error on a body the SDK built", 400, with_claim({  # HS.cpp:596-600
        "error": "JSON parsing error",
        # `details` follows nlohmann's type_error.302 text; not copied from a run
        "details": "[json.exception.type_error.302] type must be number, but is string"}),
     ndtwin.OutcomeUnknown, None),
    ("500 Internal server error", 500, with_claim({                      # HS.cpp:608-613
        "error": "Internal server error", "details": "std::bad_alloc"}),   # details invented
     ndtwin.OutcomeUnknown, None),
    ("500 An unknown error occurred", 500, with_claim({                  # HS.cpp:617-621
        "error": "An unknown error occurred"}), ndtwin.OutcomeUnknown, None),
]


class PostRepliesTest(OfTest):
    """A POST that is not answered 200 `queued` with a request id. It is sent once and no
    dispatch record is read."""

    def test_each_row(self):
        for name, status, body, cls, nothing_written in POST_ROWS:
            with self.subTest(name):
                self.fake.requests.clear()
                self.fake.script("POST", INSTALL, (status, body))
                with self.assertRaises(ndtwin.NDTwinError) as ctx:
                    self.k.of.write(ENTRY)
                err = ctx.exception
                self.assertIs(type(err), cls)
                self.assertIs(err.nothing_written, nothing_written)
                self.assertEqual((err.method, err.path, err.status), ("POST", INSTALL, status))
                self.assertEqual(err.body, body)
                self.assertEqual(err.lab_claim, body.get("lab_claim"))
                self.assertEqual((self.posts(), self.gets()), (1, 0), "sent once, no wait")

    def test_a_json_parsing_error_is_outcome_unknown_and_not_sent_again(self):
        # The router's catch (HS.cpp:596-600) also answers a throw after enqueue (HS.cpp:2682,
        # the table update at :2699): the entry may be queued already.
        self.fake.script("POST", MODIFY, (400, with_claim({"error": "JSON parsing error",
                                                           "details": "type_error.302"})))
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.of.write(ENTRY, "modify")
        self.assertIs(type(ctx.exception), ndtwin.OutcomeUnknown)
        self.assertTrue(ctx.exception.may_have_landed)
        self.assertEqual(self.posts(), 1)

    def test_a_500_is_outcome_unknown_and_not_sent_again(self):
        self.fake.script("POST", INSTALL, (500, with_claim({"error": "Internal server error",
                                                            "details": "x"})))
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.of.write(ENTRY)
        self.assertIs(type(ctx.exception), ndtwin.OutcomeUnknown)
        self.assertEqual(self.posts(), 1)

    def test_a_connection_that_breaks_after_sending_is_outcome_unknown_and_not_sent_again(self):
        self.fake.script("POST", INSTALL, None)
        with self.assertRaises(ndtwin.OutcomeUnknown):
            self.k.of.write(ENTRY)
        self.assertEqual((self.posts(), self.gets()), (1, 0))

    def test_a_2xx_that_is_not_queued_is_outcome_unknown(self):
        # What the route answered before it said `queued` (HS.cpp:2702): it may have written.
        self.fake.script("POST", INSTALL, (200, with_claim(
            {"status": "Flows installed, modified and deleted"})))
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.of.write(ENTRY)
        self.assertIs(type(ctx.exception), ndtwin.OutcomeUnknown)
        self.assertIsNone(ctx.exception.nothing_written)
        self.assertEqual((self.posts(), self.gets()), (1, 0))

    def test_a_queued_reply_without_a_positive_request_id_is_outcome_unknown(self):
        # Made up: the kernel's ids start at 1 (HS.cpp:2672-2673).
        for rid in (0, -3, "8"):
            for wait_s in (0, 10):
                with self.subTest(request_id=rid, wait_s=wait_s):
                    self.fake.requests.clear()
                    self.fake.script("POST", INSTALL, (200, queued(rid)))
                    with self.assertRaises(ndtwin.NDTwinError) as ctx:
                        self.k.of.write(ENTRY, wait_s=wait_s)
                    self.assertIs(type(ctx.exception), ndtwin.OutcomeUnknown)
                    self.assertEqual((self.posts(), self.gets()), (1, 0))

    def test_a_reply_the_sdk_cannot_read_is_outcome_unknown(self):
        # Made up: the kernel answers neither (a redirect, a 200 that is not JSON).
        for status, body in ((302, {"location": "/elsewhere"}), (200, b"OK")):
            with self.subTest(status=status):
                self.fake.requests.clear()
                self.fake.script("POST", INSTALL, (status, body))
                with self.assertRaises(ndtwin.NDTwinError) as ctx:
                    self.k.of.write(ENTRY)
                self.assertIs(type(ctx.exception), ndtwin.OutcomeUnknown)
                self.assertIsNone(ctx.exception.nothing_written)
                self.assertEqual(self.posts(), 1)

    def test_no_kernel_is_kernel_unreachable(self):
        self.server.shutdown()
        self.server.server_close()
        k = ndtwin.Kernel(self.url, timeout=2, retries=0)
        with self.assertRaises(ndtwin.KernelUnreachable) as ctx:
            k.of.write(ENTRY)
        self.assertIs(ctx.exception.nothing_written, True)
        self.server = serve(self.fake)      # for tearDown


class RefusedBeforeSendingTest(OfTest):
    """Entries the kernel or the controller would take and then not do what they say are
    refused with ValueError, and nothing is sent."""

    CASES = [
        # name, entry, op
        ("cookie: the kernel drops it", dict(ENTRY, cookie=7), "install"),
        ("hard_timeout: the kernel drops it", dict(ENTRY, hard_timeout=30), "install"),
        ("table_id: the kernel drops it", dict(ENTRY, table_id=1), "install"),
        ("idle_timeout on a modify", dict(ENTRY, idle_timeout=30), "modify"),
        ("idle_timeout on a delete", {"dpid": 1, "match": MATCH, "idle_timeout": 30}, "delete"),
        ("actions on a delete", {"dpid": 1, "match": MATCH, "actions": []}, "delete"),
        ("match is not a dict", dict(ENTRY, match=[["ipv4_dst", "10.0.0.2"]]), "install"),
        ("a match key Ryu does not know", dict(ENTRY, match={"eth_type": 2048,
                                                             "ip_dst": "10.0.0.2"}), "install"),
        ("eth_type as a string", dict(ENTRY, match={"eth_type": "0x0800",
                                                    "ipv4_dst": "10.0.0.2"}), "modify"),
        ("ip_proto as a string", dict(ENTRY, match=dict(MATCH, ip_proto="6")), "install"),
        ("tcp_dst as a string", dict(ENTRY, match=dict(MATCH, ip_proto=6, tcp_dst="80")),
         "modify"),
        ("udp_dst as a string", dict(ENTRY, match=dict(MATCH, ip_proto=17, udp_dst="53")),
         "install"),
        ("eth_type as a bool", dict(ENTRY, match={"eth_type": True}), "install"),
        ("tp_dst without ip_proto", dict(ENTRY, match=dict(MATCH, tp_dst=80)), "install"),
        ("actions missing on an install", {"dpid": 1, "match": MATCH}, "install"),
        ("actions not a list", dict(ENTRY, actions={"type": "OUTPUT", "port": 3}), "install"),
        ("an action that is not a dict", dict(ENTRY, actions=["OUTPUT:3"]), "modify"),
        ("an action type Ryu does not know", dict(ENTRY, actions=[{"type": "OUTPT", "port": 3}]),
         "install"),
        ("a delete with no match", {"dpid": 1, "priority": 100}, "delete"),
        ("a delete with an empty match", {"dpid": 1, "match": {}}, "delete"),
        ("an op the kernel has no route for", ENTRY, "insert"),
        ("an entry that is not a dict", [("dpid", 1)], "install"),
    ]

    def test_each_case(self):
        for name, entry, op in self.CASES:
            with self.subTest(name):
                with self.assertRaises(ValueError):
                    self.k.of.write(entry, op)
        self.assertEqual(self.fake.requests, [], "nothing may be sent")

    def test_a_string_eth_type_is_refused(self):
        with self.assertRaises(ValueError) as ctx:
            self.k.of.write(dict(ENTRY, match={"eth_type": "0x0800", "ipv4_dst": "10.0.0.2"}),
                            "modify")
        self.assertIn("eth_type", str(ctx.exception))
        self.assertEqual(self.fake.requests, [])

    def test_a_string_port_is_refused(self):
        for op, match in (("modify", dict(MATCH, ip_proto=6, tcp_dst="80")),
                          ("install", dict(MATCH, ip_proto=17, udp_dst="53"))):
            with self.subTest(op=op, match=match):
                with self.assertRaises(ValueError) as ctx:
                    self.k.of.write(dict(ENTRY, match=match), op)
                self.assertIn("must be an integer", str(ctx.exception))
        self.assertEqual(self.fake.requests, [])

    def test_a_delete_with_no_match_needs_all_rules(self):
        with self.assertRaises(ValueError) as ctx:
            self.k.of.write({"dpid": 1}, "delete")
        self.assertIn("all_rules=True", str(ctx.exception))
        self.assertEqual(self.fake.requests, [])
        self.k.of.write({"dpid": 1}, "delete", all_rules=True)
        self.assertEqual(self.fake.requests[0][1:4], (DELETE, {}, {"dpid": 1}))

    def test_what_the_controller_reads_is_sent(self):
        # The router's own spellings, OF1.0 names, a drop rule, a priority-less delete.
        router = {"dl_type": 2048, "nw_dst": "10.0.0.0/24"}
        for entry, op in ((dict(ENTRY, match=router), "install"),
                          (dict(ENTRY, actions=[]), "install"),
                          (dict(ENTRY, match=dict(MATCH, ip_proto=17, tp_dst=53)), "modify"),
                          ({"dpid": 1, "match": MATCH}, "delete")):
            with self.subTest(entry=entry, op=op):
                self.k.of.write(entry, op)
        self.assertEqual(self.posts(), 4)


class ReadmeExampleTest(OfTest):
    """The example of the README's "OVS flow entries", run as written with `k` and `ndtwin`."""

    def run_example(self):
        with open(README) as fh:
            blocks = re.findall(r"^```python\n(.*?)^```", fh.read(), re.M | re.S)
        code = [b for b in blocks if "k.of.write(" in b][0]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            exec(compile(code, README, "exec"), {"k": self.k, "ndtwin": ndtwin})
        return out.getvalue()

    def test_it_reports_a_write_the_controller_took(self):
        out = self.run_example()
        self.assertRegex(out, r"^request \d+ taken by the controller; on the switch: None$")
        self.assertEqual((self.posts(), self.gets()), (1, 1))

    def test_it_reports_a_switch_that_is_not_connected_as_refused(self):
        self.fake.script("POST", INSTALL, (200, queued(21)))
        self.fake.script("GET", DISPATCH, (200, record(
            21, ok=0, failed=1, failures=[failure(21, 404, "Ryu controller returned HTTP 404",
                                                  "controller")])))
        self.assertTrue(self.run_example().startswith("refused: "))


if __name__ == "__main__":
    unittest.main()
