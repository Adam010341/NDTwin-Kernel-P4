#!/usr/bin/env python3
"""sdk/python/ndtwin against an in-process fake kernel (tests/python/p4_fake_kernel.py).

[Co-developed with claude code -- Adam]

The SDK is imported from sdk/python (or $NDTWIN_SDK_UNDER_TEST), so nothing has to be installed.
Covered: how each kernel and proxy reply maps onto an exception and whether it is retried, the
read-back of a write, the dpid to management-address mapping, the lock, the topology and the
package's own shape (standard library only, only /ndt/ routes). The replies the P4 proxy's own
handler builds are read by the SDK in p4_proxy/tests/test_ndtwin_sdk_proxy_replies.py, which needs
the proxy's packages. This file needs none and runs under Python 3.8 too, as a test lane may pick
it (the SDK itself declares 3.10).
"""
import ast
import contextlib
import copy
import http.client
import importlib.util
import json
import os
import re
import socket
import sys
import sysconfig
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from p4_fake_kernel import (FIELD, MGMT_IP, POWER_MW, REPO, TABLE, FakeKernel, calls,  # noqa: E402
                            grpc_502, serve)

SDK_DIR = os.environ.get("NDTWIN_SDK_UNDER_TEST") or os.path.join(REPO, "sdk", "python")
sys.path.insert(0, SDK_DIR)
import ndtwin  # noqa: E402
from ndtwin.topology import Topology, ip_str, mac_str  # noqa: E402

ENTRY = "/ndt/p4/table_entry"


def TableEntry_of(entry, **changes):  # noqa: N802
    """A copy of an entry (a ndtwin.TableEntry) with top-level fields replaced."""
    return ndtwin.TableEntry(dict(copy.deepcopy(entry), **changes))


def proxy_detail(error, **extra):
    return {"detail": dict(error=error, dpid=1, message="m", **extra)}


def kernel_body(error, request_sent=None, **extra):
    body = dict(error=error, origin="kernel", message="m", **extra)
    if request_sent is not None:
        body["request_sent"] = request_sent
    return body


class SdkTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeKernel()
        self.server = serve(self.fake)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.k = ndtwin.Kernel(self.url, timeout=5, retry_wait=0)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def count(self, method, path):
        return sum(1 for m, p, _, _ in self.fake.requests if (m, p) == (method, path))

    def reset(self):
        self.fake.requests.clear()
        self.fake.faults.clear()
        self.fake.locks.clear()

    def route_entry(self, dpid=1, port=4):
        """The entry of s<dpid> for 10.0.4.4 as the API shows it."""
        entries = self.k.p4.read_table(dpid, TABLE).entries
        return next(e for e in entries if e.match[FIELD][0] == "10.0.4.4")


class ErrorMappingTest(SdkTest):
    """Each row: a reply to a write on /ndt/p4/table_entry -> the exception, `nothing_written`,
    how many times the write was sent, whether `WriteError` catches it."""

    ROWS = [
        # name, status, origin, body, class, nothing_written, sends, in WriteError
        ("kernel 504 request_sent false", 504, "kernel", kernel_body("timed out", False),
         ndtwin.Busy, True, 3, True),
        ("kernel 502 request_sent false", 502, "kernel", kernel_body("unreachable", False),
         ndtwin.Busy, True, 3, True),
        ("kernel 504 request_sent true", 504, "kernel", kernel_body("timed out", True),
         ndtwin.OutcomeUnknown, None, 1, True),
        ("kernel 502 request_sent true", 502, "kernel", kernel_body("unreadable", True),
         ndtwin.OutcomeUnknown, None, 1, True),
        # Defensive: the kernel always sends `request_sent` with a 502/504 of /ndt/p4.
        ("kernel 502 without request_sent", 502, "kernel", kernel_body("no reply"),
         ndtwin.OutcomeUnknown, None, 1, True),
        ("kernel 500", 500, "kernel", kernel_body("Internal server error"),
         ndtwin.OutcomeUnknown, None, 1, True),
        ("kernel 501 not a P4 fabric", 501, "kernel", kernel_body("not a P4 fabric"),
         ndtwin.NDTwinError, True, 1, False),
        ("kernel 404 not a pass-through route", 404, "kernel",
         kernel_body("not a P4 pass-through route"), ndtwin.NotFound, True, 1, True),
        ("kernel 405", 405, "kernel", kernel_body("method not allowed"),
         ndtwin.Refused, True, 1, True),
        ("proxy 400", 400, "proxy", proxy_detail("invalid table entry"),
         ndtwin.Refused, True, 1, True),
        ("proxy 404 unknown switch", 404, "proxy", proxy_detail("unknown switch"),
         ndtwin.NotFound, True, 1, True),
        ("proxy 409 owned by NDTwin", 409, "proxy", proxy_detail("owned by NDTwin"),
         ndtwin.Refused, True, 1, True),
        ("proxy 422", 422, "proxy", {"detail": [{"loc": ["body"], "msg": "bad"}]},
         ndtwin.Refused, True, 1, True),
        ("proxy 501", 501, "proxy", proxy_detail("match type not supported"),
         ndtwin.NDTwinError, True, 1, False),
        ("proxy 502 the switch refused", 502, "proxy",
         proxy_detail("the switch refused the write", grpc_status="UNKNOWN",
                      p4rt_error={"code": "PERMISSION_DENIED", "message": "const"}),
         ndtwin.SwitchRefused, True, 1, True),
        ("proxy 502 DEADLINE_EXCEEDED without p4rt_error", 502, "proxy",
         grpc_502("DEADLINE_EXCEEDED"), ndtwin.OutcomeUnknown, None, 1, True),
        ("proxy 502 UNAVAILABLE without p4rt_error", 502, "proxy", grpc_502("UNAVAILABLE"),
         ndtwin.OutcomeUnknown, None, 1, True),
        ("proxy 502 CANCELLED without p4rt_error", 502, "proxy", grpc_502("CANCELLED"),
         ndtwin.OutcomeUnknown, None, 1, True),
        ("proxy 502 UNKNOWN without p4rt_error", 502, "proxy", grpc_502("UNKNOWN"),
         ndtwin.OutcomeUnknown, None, 1, True),
        ("proxy 503 switch busy", 503, "proxy", proxy_detail("switch busy"),
         ndtwin.Busy, True, 3, True),
        ("proxy 503 replay pending", 503, "proxy", proxy_detail("replay pending"),
         ndtwin.Busy, True, 3, True),
        ("proxy 503 with a string detail", 503, "proxy", {"detail": "proxy has no topology yet"},
         ndtwin.Busy, True, 3, True),
        ("proxy 500, Starlette's text/plain", 500, "proxy", "Internal Server Error",
         ndtwin.OutcomeUnknown, None, 1, True),
        # Defensive: the kernel sets X-NDTwin-Origin on every reply of /ndt/p4.
        ("no origin 500", 500, None, {"error": "Internal server error"},
         ndtwin.NDTwinError, None, 1, False),
        ("no origin 503", 503, None, {"error": "unavailable"},
         ndtwin.NDTwinError, None, 1, False),
    ]

    def test_each_row(self):
        for name, status, origin, body, cls, nothing_written, sends, in_write_error in self.ROWS:
            with self.subTest(name):
                self.reset()
                self.fake.fault("POST", ENTRY, status, body, origin=origin, times=sends + 2)
                with self.assertRaises(ndtwin.NDTwinError) as ctx:
                    self.k.p4.write(self.route_entry(), "modify")
                err = ctx.exception
                self.assertIs(type(err), cls)
                self.assertIs(err.nothing_written, nothing_written)
                self.assertEqual(err.may_have_landed, nothing_written is not True)
                self.assertEqual((err.method, err.path, err.status, err.origin),
                                 ("POST", ENTRY, status, origin))
                self.assertEqual(err.body, {"raw": body} if isinstance(body, str) else body)
                self.assertEqual(self.count("POST", ENTRY), sends, "times the write was sent")
                self.assertEqual(isinstance(err, ndtwin.WriteError), in_write_error)

    def test_a_proxy_502_carries_the_switchs_own_reason(self):
        self.fake.fault("POST", ENTRY, 502, proxy_detail(
            "the switch refused the write", grpc_status="UNKNOWN",
            p4rt_error={"code": "PERMISSION_DENIED", "message": "const default"}), origin="proxy")
        with self.assertRaises(ndtwin.SwitchRefused) as ctx:
            self.k.p4.write(self.route_entry(), "modify")
        self.assertEqual(ctx.exception.grpc_status, "UNKNOWN")
        self.assertEqual(ctx.exception.p4rt_error["code"], "PERMISSION_DENIED")

    def test_a_proxy_502_without_the_switchs_reason_keeps_the_grpc_status_and_is_sent_once(self):
        # The proxy's own 5 s deadline answers 502 although the write may still land.
        self.fake.fault("POST", ENTRY, 502, grpc_502("DEADLINE_EXCEEDED"), origin="proxy",
                        apply=True, times=3)
        entry = self.route_entry().with_params(port=3)
        with self.assertRaises(ndtwin.OutcomeUnknown) as ctx:
            self.k.p4.write(entry, "modify")
        self.assertEqual(ctx.exception.grpc_status, "DEADLINE_EXCEEDED")
        self.assertTrue(ctx.exception.may_have_landed)
        self.assertEqual(self.count("POST", ENTRY), 1)
        self.assertEqual(self.fake.tables[1][3]["action_params"]["port"], 3)  # it did land

    def test_the_switch_refusing_an_insert_of_an_existing_entry(self):
        with self.assertRaises(ndtwin.SwitchRefused) as ctx:
            self.k.p4.write(self.route_entry())  # op defaults to insert; the entry exists
        self.assertEqual(ctx.exception.p4rt_error["code"], "ALREADY_EXISTS")
        self.assertEqual(self.fake.requests[-1][3]["op"], "insert")
        self.assertEqual(self.count("POST", ENTRY), 1)

    def test_a_busy_switch_that_answers_on_the_retry_is_not_an_error(self):
        self.fake.fault("POST", ENTRY, 503, proxy_detail("switch busy"), origin="proxy")
        entry = self.route_entry()
        result = self.k.p4.write(entry.with_params(port=3), "modify")
        self.assertEqual(result.body["status"], "success")
        self.assertEqual(self.count("POST", ENTRY), 2)

    def test_retries_can_be_turned_off(self):
        k = ndtwin.Kernel(self.url, timeout=5, retries=0)
        self.fake.fault("POST", ENTRY, 503, proxy_detail("switch busy"), origin="proxy", times=3)
        with self.assertRaises(ndtwin.Busy):
            k.p4.write(self.route_entry(), "modify")
        self.assertEqual(self.count("POST", ENTRY), 1)

    def test_retries_wait_between_tries(self):
        k = ndtwin.Kernel(self.url, timeout=5, retries=2, retry_wait=0.25)
        self.fake.fault("POST", ENTRY, 503, proxy_detail("switch busy"), origin="proxy", times=3)
        with mock.patch("ndtwin._http.time.sleep") as sleep:
            with self.assertRaises(ndtwin.Busy):
                k.p4.write(self.route_entry(), "modify")
        self.assertEqual(sleep.call_args_list, [mock.call(0.25), mock.call(0.25)])

    def test_an_unknown_outcome_is_sent_once_even_when_it_would_have_landed(self):
        self.fake.fault("POST", ENTRY, 504, kernel_body("timed out", True), origin="kernel",
                        apply=True)
        entry = self.route_entry().with_params(port=3)
        with self.assertRaises(ndtwin.OutcomeUnknown):
            self.k.p4.write(entry, "modify")
        self.assertEqual(self.count("POST", ENTRY), 1)
        landed = next(e for e in self.fake.tables[1] if e["match"] == entry["match"])
        self.assertEqual(landed["action_params"]["port"], 3)  # it did land, as the docs warn

    # --- connections -------------------------------------------------------------------------

    def test_a_connection_that_breaks_after_a_write_is_an_unknown_outcome(self):
        self.fake.fault("POST", ENTRY, None, apply=True, times=3)
        with self.assertRaises(ndtwin.OutcomeUnknown) as ctx:
            self.k.p4.write(self.route_entry().with_params(port=3), "modify")
        self.assertIsNone(ctx.exception.status)
        self.assertIsNone(ctx.exception.nothing_written)
        self.assertEqual(self.count("POST", ENTRY), 1)

    def test_a_connection_that_breaks_during_a_read_is_retried(self):
        self.fake.fault("GET", "/ndt/get_average_link_usage", None, times=1)
        self.assertEqual(self.k.average_link_usage(), 0.05)
        self.assertEqual(self.count("GET", "/ndt/get_average_link_usage"), 2)
        self.reset()
        self.fake.fault("GET", "/ndt/get_average_link_usage", None, times=5)
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.average_link_usage()
        self.assertIs(type(ctx.exception), ndtwin.NDTwinError)
        self.assertIs(ctx.exception.nothing_written, True)
        self.assertEqual(self.count("GET", "/ndt/get_average_link_usage"), 3)

    def test_nothing_listening_is_kernel_unreachable_for_reads_and_writes(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        k = ndtwin.Kernel(f"http://127.0.0.1:{port}", timeout=2, retry_wait=0)
        real, tries = http.client.HTTPConnection.connect, []

        def counting(conn):
            tries.append(1)
            return real(conn)

        with mock.patch.object(http.client.HTTPConnection, "connect", counting):
            for what in (k.average_link_usage, lambda: k.p4.write({"dpid": 1, "table": TABLE}, "modify")):
                del tries[:]
                with self.assertRaises(ndtwin.KernelUnreachable) as ctx:
                    what()
                self.assertIs(ctx.exception.nothing_written, True)
                self.assertIsNone(ctx.exception.status)
                self.assertEqual(len(tries), 3, "nothing was sent, so both are tried 3 times")

    def test_a_kernel_that_never_answers_times_out_as_a_lost_connection(self):
        silent = socket.socket()
        silent.bind(("127.0.0.1", 0))
        silent.listen(5)
        self.addCleanup(silent.close)
        accepted = []
        self.addCleanup(lambda: [conn.close() for conn, _ in accepted])
        threading.Thread(target=lambda: [accepted.append(silent.accept()) for _ in range(2)],
                         daemon=True).start()
        k = ndtwin.Kernel("http://127.0.0.1:%d" % silent.getsockname()[1], timeout=0.3, retries=0)
        with self.assertRaises(ndtwin.OutcomeUnknown):
            k.p4.write({"dpid": 1, "table": TABLE}, "modify")
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            k.average_link_usage()
        self.assertIs(ctx.exception.nothing_written, True)

    def test_a_reply_that_is_not_json_is_an_error(self):
        self.fake.fault("POST", ENTRY, 200, b"<html>hi</html>", origin="proxy")
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.p4.write(self.route_entry(), "modify")
        self.assertIsNone(ctx.exception.nothing_written)
        self.fake.fault("GET", "/ndt/get_average_link_usage", 200, b"nope")
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.average_link_usage()
        self.assertIs(ctx.exception.nothing_written, True)

    # --- reads -------------------------------------------------------------------------------

    def test_a_read_without_an_origin_is_retried_on_502_503_504_and_not_on_500_or_4xx(self):
        for status in (502, 503, 504):
            with self.subTest(status):
                self.reset()
                self.fake.fault("GET", "/ndt/get_average_link_usage", status, {"error": "x"},
                                times=2)
                self.assertEqual(self.k.average_link_usage(), 0.05)
                self.assertEqual(self.count("GET", "/ndt/get_average_link_usage"), 3)
        for status, cls in ((500, ndtwin.NDTwinError), (400, ndtwin.Refused), (404, ndtwin.NotFound)):
            with self.subTest(status):
                self.reset()
                self.fake.fault("GET", "/ndt/get_average_link_usage", status, {"error": "x"})
                with self.assertRaises(cls) as ctx:
                    self.k.average_link_usage()
                self.assertIs(type(ctx.exception), cls)
                self.assertIs(ctx.exception.nothing_written, True)
                self.assertEqual(self.count("GET", "/ndt/get_average_link_usage"), 1)

    def test_a_read_is_not_sent_again_after_a_proxy_502_but_is_after_a_kernel_502(self):
        # The proxy's 502 on a read is deterministic (a direct counter it cannot render; the
        # table route never answers 502); the kernel's means a lost connection or a proxy that
        # did not answer.
        dc = "/ndt/p4/direct_counter/MyIngress.dc_route"
        self.fake.fault("GET", dc, 502, proxy_detail("direct counter not rendered"),
                        origin="proxy", times=3)
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.p4.direct_counter("MyIngress.dc_route", 1)
        self.assertIs(type(ctx.exception), ndtwin.NDTwinError)
        self.assertIs(ctx.exception.nothing_written, True)
        self.assertEqual(self.count("GET", dc), 1)
        self.reset()
        self.fake.fault("GET", ENTRY, 502, kernel_body("no reply", True), origin="kernel", times=2)
        self.assertEqual(len(self.k.p4.read_table(1, TABLE).entries), 4)
        self.assertEqual(self.count("GET", ENTRY), 3)

    def test_a_table_read_the_kernel_timed_out_on_after_sending_it_is_sent_once(self):
        # The first read may still hold one of the proxy's read slots: asking again at once
        # would queue a second read behind it.
        self.fake.fault("GET", ENTRY, 504, kernel_body("timed out", True), origin="kernel",
                        times=3)
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.p4.read_table(1, TABLE)
        self.assertIs(type(ctx.exception), ndtwin.NDTwinError)
        self.assertIs(ctx.exception.nothing_written, True)
        self.assertEqual(self.count("GET", ENTRY), 1)

    def test_a_table_read_the_kernel_could_not_send_is_retried(self):
        self.fake.fault("GET", ENTRY, 504, kernel_body("timed out", False), origin="kernel")
        self.assertEqual(len(self.k.p4.read_table(1, TABLE).entries), 4)
        self.assertEqual(self.count("GET", ENTRY), 2)

    def test_a_table_read_of_a_switch_the_proxy_does_not_have_is_not_found(self):
        with self.assertRaises(ndtwin.NotFound) as ctx:
            self.k.p4.read_table(99, TABLE)
        self.assertEqual((ctx.exception.origin, ctx.exception.body["detail"]["error"]),
                         ("proxy", "unknown switch"))
        self.assertEqual(self.count("GET", ENTRY), 1)

    def test_a_table_read_that_the_proxy_could_not_do_is_busy_after_the_retries(self):
        self.fake.fault("GET", ENTRY, 503, proxy_detail("table not read", grpc_status="UNAVAILABLE"),
                        origin="proxy", times=3)
        with self.assertRaises(ndtwin.Busy) as ctx:
            self.k.p4.read_table(1, TABLE)
        self.assertEqual(self.count("GET", ENTRY), 3)
        self.assertIs(ctx.exception.nothing_written, True)

    def test_an_unknown_table_is_not_found(self):
        with self.assertRaises(ndtwin.NotFound) as ctx:
            self.k.p4.read_table(1, "MyIngress.nope")
        self.assertEqual(ctx.exception.origin, "proxy")
        self.assertEqual(self.count("GET", ENTRY), 1)

    def test_kernel_url_must_be_http_and_may_end_in_a_slash(self):
        for bad in ("localhost:8000", "ftp://x", "http://"):
            with self.assertRaises(ValueError):
                ndtwin.Kernel(bad)
        with self.assertRaises(ValueError):
            ndtwin.Kernel(self.url, retries=-1)  # would send nothing and return None
        self.assertEqual(ndtwin.Kernel(self.url, retries=0).average_link_usage(), 0.05)
        self.assertEqual(ndtwin.Kernel(self.url + "/", timeout=5).average_link_usage(), 0.05)

    def test_a_negative_infinite_or_nan_retry_wait_is_refused(self):
        # It would be slept after a request already went out, and time.sleep's ValueError would
        # escape the NDTwinError an app catches.
        for wait in (-1, float("nan"), float("inf")):
            with self.subTest(wait), self.assertRaisesRegex(ValueError, "retry_wait"):
                ndtwin.Kernel(self.url, retry_wait=wait)
        self.assertEqual(self.fake.requests, [])


class WriteAndReadBackTest(SdkTest):
    def test_read_table_separates_the_default_entry_and_keeps_the_wire_shape(self):
        table = self.k.p4.read_table(1, "ipv4_lpm")  # the alias
        self.assertEqual(table.name, TABLE)
        self.assertEqual(len(table.entries), 4)
        self.assertTrue(table.default.is_default)
        self.assertEqual(table.default["action_name"], "MyIngress.drop")
        self.assertEqual(table.unrendered, [])
        entry = table.entries[3]
        self.assertEqual(entry, self.fake.tables[1][3])
        self.assertEqual((entry.dpid, entry.table, entry.match, entry.params, entry.priority),
                         (1, TABLE, {FIELD: ["10.0.4.4", 32]},
                          {"dstAddr": "08:00:00:00:04:00", "port": 4}, None))

    def test_a_table_that_is_not_fully_shown_is_refused_unless_asked_for(self):
        self.fake.unrendered[1] = [{"default_action": False, "priority": None, "reason": "profile"}]
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.p4.read_table(1, TABLE)
        self.assertIs(type(ctx.exception), ndtwin.NDTwinError)
        self.assertIs(ctx.exception.nothing_written, True)
        table = self.k.p4.read_table(1, TABLE, strict=False)
        self.assertEqual(table.unrendered[0]["reason"], "profile")
        self.assertEqual(len(table.entries), 4)

    def test_with_params_copies_and_changes_only_the_named_parameters(self):
        entry = self.route_entry()
        before = copy.deepcopy(entry)
        new = entry.with_params(port=3)
        self.assertEqual(entry, before)
        self.assertEqual(new.params, {"dstAddr": "08:00:00:00:04:00", "port": 3})
        self.assertEqual({k: v for k, v in new.items() if k != "action_params"},
                         {k: v for k, v in entry.items() if k != "action_params"})
        self.assertIsNot(new.match, entry.match)
        self.assertIsInstance(new, ndtwin.TableEntry)

    def test_write_sends_the_entry_whole_with_the_op_and_does_not_change_it(self):
        entry = self.route_entry().with_params(port=3)
        entry["idle_timeout_ns"] = 600000000
        entry["action_params"]["wide"] = "0x20000000000001"
        before = copy.deepcopy(entry)
        for op in ("modify", "delete"):
            self.fake.requests.clear()
            with contextlib.suppress(ndtwin.SwitchRefused):
                self.k.p4.write(entry, op)
            self.assertEqual(self.fake.requests[0][3], dict(before, op=op))
        self.assertEqual(entry, before)

    def test_write_refuses_an_op_it_does_not_know_before_sending(self):
        entry = self.route_entry()
        self.fake.requests.clear()
        with self.assertRaises(ValueError):
            self.k.p4.write(entry, "upsert")
        self.assertEqual(self.fake.requests, [])

    def test_the_lab_claim_header_is_kept_on_an_error_reply_too(self):
        self.fake.lab_claim = '{"state":"active","owner":"alice","expires_at":5,"note":"n"}'
        self.fake.fault("POST", ENTRY, 502, grpc_502("DEADLINE_EXCEEDED"), origin="proxy")
        with self.assertRaises(ndtwin.OutcomeUnknown) as ctx:
            self.k.p4.write(self.route_entry(), "modify")
        self.assertEqual(ctx.exception.lab_claim["owner"], "alice")
        self.fake.fault("POST", ENTRY, 200, b"<html>hi</html>", origin="proxy")
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.p4.write(self.route_entry(), "modify")
        self.assertEqual(ctx.exception.lab_claim["state"], "active")
        with self.assertRaises(ndtwin.NotFound) as ctx:
            self.k.p4.read_table(1, "nope")
        self.assertIsNone(ctx.exception.lab_claim)  # a GET carries none

    def test_the_lab_claim_header_is_parsed(self):
        result = self.k.p4.write(self.route_entry().with_params(port=3), "modify")
        self.assertEqual(result.lab_claim, {"expires_at": 0, "note": "", "owner": "", "state": "none"})
        self.assertEqual(result.body["op"], "modify")
        self.fake.lab_claim = '{"state":"active","owner":"alice","expires_at":5,"note":"n"}'
        result = self.k.p4.write(self.route_entry(), "modify")
        self.assertEqual((result.lab_claim["state"], result.lab_claim["owner"]), ("active", "alice"))
        self.fake.lab_claim = "not json"
        self.assertIsNone(self.k.p4.write(self.route_entry(), "modify").lab_claim)
        self.fake.lab_claim = None
        self.assertIsNone(self.k.p4.write(self.route_entry(), "modify").lab_claim)

    # --- verify=True -------------------------------------------------------------------------

    def test_verify_passes_when_the_table_shows_the_entry(self):
        new = self.route_entry().with_params(port=3)
        self.fake.requests.clear()
        shown = self.k.p4.modify(new)
        self.assertEqual(calls(self.fake), ["POST table s1", "GET table s1"])
        self.assertEqual(shown, new)
        self.assertEqual(shown.params["port"], 3)
        self.assertEqual(self.fake.tables[1][3]["action_params"]["port"], 3)

    def test_verify_accepts_the_alias_the_switch_expands(self):
        new = self.route_entry().with_params(port=3)
        new["action_name"] = "ipv4_forward"
        self.assertEqual(self.k.p4.modify(new).params["port"], 3)

    def test_verify_fails_when_an_answered_write_is_not_in_the_table(self):
        self.fake.fault("POST", ENTRY, 200, {"status": "success", "dpid": 1}, origin="proxy")
        new = self.route_entry().with_params(port=3)
        with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
            self.k.p4.modify(new)
        err = ctx.exception
        self.assertIsNone(err.nothing_written)
        self.assertTrue(err.may_have_landed)
        self.assertIsInstance(err, ndtwin.WriteError)
        self.assertIn("read back", str(err))
        self.assertEqual(self.count("POST", ENTRY), 1)

    def test_verify_fails_when_the_switch_kept_another_idle_timeout(self):
        self.fake.tables[1][3]["idle_timeout_ns"] = 1000000
        new = self.route_entry().with_params(port=3)
        self.assertEqual(new["idle_timeout_ns"], 1000000)
        self.assertEqual(self.k.p4.modify(new).params["port"], 3)  # sent back whole: verified
        new["idle_timeout_ns"] = 2000000  # the fake keeps 1000000, as bmv2 would not
        with self.assertRaises(ndtwin.WriteNotVerified):
            self.k.p4.modify(new)

    def test_verify_fails_when_the_read_back_itself_fails(self):
        new = self.route_entry().with_params(port=3)
        self.fake.fault("GET", ENTRY, 503, proxy_detail("switch busy"), origin="proxy", times=3)
        with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
            self.k.p4.modify(new)
        err = ctx.exception
        self.assertIsNone(err.nothing_written)
        self.assertIsInstance(err.__cause__, ndtwin.Busy)
        self.assertEqual(err.status, 503)

    def test_verify_finds_the_entry_by_match_and_priority(self):
        twin = copy.deepcopy(self.fake.tables[1][3])
        twin.update(priority=10, action_params={"dstAddr": "08:00:00:00:09:99", "port": 1})
        self.fake.tables[1].insert(4, twin)  # same match as the entry before it, other priority
        entries = self.k.p4.read_table(1, TABLE).entries
        other = next(e for e in entries if e.priority == 10)
        self.assertEqual(self.k.p4.modify(other.with_params(port=2)).priority, 10)
        self.assertEqual(self.fake.tables[1][3]["action_params"]["port"], 4)  # the first is untouched

    def test_a_table_the_read_back_cannot_show_in_full_is_not_verified(self):
        new = self.route_entry().with_params(port=3)
        self.fake.unrendered_after_write[1] = [
            {"default_action": False, "priority": None, "reason": "the action comes from a profile"}]
        with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
            self.k.p4.modify(new)
        err = ctx.exception
        self.assertIsNone(err.nothing_written)
        self.assertIn("the action comes from a profile", str(err))
        self.assertEqual(self.fake.tables[1][3]["action_params"]["port"], 3)  # the write landed

    def test_verify_compares_the_form_the_get_returns(self):
        # The switch shows a MAC address in lower case; a value sent in another form reads back
        # differently and is not verified, although the write landed.
        new = self.route_entry().with_params(dstAddr="08:00:00:00:04:AA")
        with self.assertRaises(ndtwin.WriteNotVerified):
            self.k.p4.modify(new)
        self.assertEqual(self.fake.tables[1][3]["action_params"]["dstAddr"], "08:00:00:00:04:aa")
        again = self.route_entry().with_params(dstAddr="08:00:00:00:04:aa")
        self.assertEqual(self.k.p4.modify(again).params["dstAddr"], "08:00:00:00:04:aa")

    def test_verify_checks_the_default_entry_of_a_default_modify(self):
        default = self.k.p4.read_table(1, TABLE).default
        new = TableEntry_of(default, action_name="MyIngress.ipv4_forward",
                            action_params={"dstAddr": "08:00:00:00:09:09", "port": 2})
        shown = self.k.p4.modify(new)
        self.assertTrue(shown.is_default)
        self.assertEqual(shown.params["port"], 2)
        self.assertEqual(self.fake.tables[1][-1]["action_name"], "MyIngress.ipv4_forward")
        self.assertEqual(len(self.k.p4.read_table(1, TABLE).entries), 4)  # not among the others
        self.fake.fault("POST", ENTRY, 200, {"status": "success", "dpid": 1}, origin="proxy")
        with self.assertRaises(ndtwin.WriteNotVerified):
            self.k.p4.modify(TableEntry_of(new, action_params={"dstAddr": "08:00:00:00:09:09",
                                                               "port": 3}))

    def test_verify_fails_cleanly_when_the_switch_shows_no_action_name(self):
        self.fake.tables[1][3]["action_name"] = None
        self.fake.fault("POST", ENTRY, 200, {"status": "success", "dpid": 1}, origin="proxy")
        new = self.route_entry()
        new["action_name"] = "ipv4_forward"
        with self.assertRaises(ndtwin.WriteNotVerified):
            self.k.p4.modify(new)

    def test_verify_fails_when_the_action_differs_though_the_parameters_match(self):
        self.fake.fault("POST", ENTRY, 200, {"status": "success", "dpid": 1}, origin="proxy")
        new = self.route_entry()
        new["action_name"] = "MyIngress.drop"
        with self.assertRaises(ndtwin.WriteNotVerified):
            self.k.p4.modify(new)

    def test_verify_false_does_not_read(self):
        self.fake.requests.clear()
        self.k.p4.modify(self.route_entry().with_params(port=3), verify=False)
        self.assertEqual(calls(self.fake)[-1], "POST table s1")
        self.assertEqual(self.count("GET", ENTRY), 1)  # the read that fetched the entry above
        self.fake.fault("POST", ENTRY, 200, {"status": "success"}, origin="proxy")
        self.k.p4.modify(self.route_entry().with_params(port=2), verify=False)  # not checked

    def test_modify_all_writes_in_order_then_reads_each_switch_once(self):
        e1, e2 = self.route_entry(1).with_params(port=3), self.route_entry(2).with_params(port=3)
        e1b = self.k.p4.read_table(1, TABLE).entries[2].with_params(port=4)
        self.fake.requests.clear()
        shown = self.k.p4.modify_all([e2, e1, e1b])
        self.assertEqual(calls(self.fake), ["POST table s2", "POST table s1", "POST table s1",
                                            "GET table s1", "GET table s2"])
        self.assertEqual([s.params["port"] for s in shown], [3, 3, 4])

    def test_modify_all_stops_at_the_first_failed_write_and_reads_nothing(self):
        e1, e2, e3 = (self.route_entry(d).with_params(port=3) for d in (1, 2, 3))
        self.fake.fault("POST", ENTRY, 502, proxy_detail(
            "the switch refused the write", grpc_status="UNKNOWN",
            p4rt_error={"code": "NOT_FOUND", "message": ""}), origin="proxy",
            match=lambda q, b: b["dpid"] == 2)
        self.fake.requests.clear()
        with self.assertRaises(ndtwin.SwitchRefused) as ctx:
            self.k.p4.modify_all([e1, e2, e3])
        self.assertEqual(calls(self.fake), ["POST table s1", "POST table s2"])
        self.assertEqual(ctx.exception.written, [e1])  # answered before the refusal
        self.fake.fault("POST", ENTRY, 503, proxy_detail("switch busy"), origin="proxy", times=3)
        with self.assertRaises(ndtwin.Busy) as ctx:
            self.k.p4.modify_all([e1, e2])
        self.assertEqual(ctx.exception.written, [])

    def test_modify_all_of_nothing_sends_nothing(self):
        self.assertEqual(self.k.p4.modify_all([]), [])
        self.assertEqual(self.fake.requests, [])


class PowerTest(SdkTest):
    def test_power_off_addresses_the_switch_by_its_decoded_management_ip(self):
        state = self.k.power_off(4)
        self.assertEqual(state, ndtwin.PowerState("off", True))  # `reachable` lags (§7)
        post = next(q for m, p, q, b in self.fake.requests if p == "/ndt/set_switches_power_state")
        self.assertEqual(post, {"ip": "192.168.123.14", "action": "off"})
        self.assertEqual(calls(self.fake), ["GET get_graph_data", "POST power 192.168.123.14 off",
                                            "GET get_switches_power_state"])
        self.assertEqual(self.fake.power_state["192.168.123.14"]["admin_state"], "off")

    def test_the_address_map_comes_from_the_last_topology_read(self):
        self.k.topology()
        self.fake.requests.clear()
        self.assertEqual(self.k.power_state(3), ndtwin.PowerState("on", True))
        self.k.power_off(3)
        self.assertNotIn("GET get_graph_data", calls(self.fake))

    def test_a_switch_the_topology_does_not_have_is_not_found_and_nothing_is_sent_to_it(self):
        with self.assertRaises(ndtwin.NotFound) as ctx:
            self.k.power_off(99)
        self.assertIs(ctx.exception.nothing_written, True)
        self.assertEqual(calls(self.fake), ["GET get_graph_data"])
        with self.assertRaises(ndtwin.NotFound):
            self.k.power_state(99)

    def test_a_power_command_that_failed_may_have_switched_and_is_sent_once(self):
        # The kernel's 500 is the same whether the bmv2 power helper never touched the switch or
        # signalled it and gave up after 10 s, and for a hardware switch whose plug was switched.
        for brand in ("BMv2", "HPE5520"):
            with self.subTest(brand):
                self.reset()
                self.k = ndtwin.Kernel(self.url, timeout=5, retry_wait=0)
                for node in self.fake.graph["nodes"]:
                    if node["vertex_type"] == 0 and node["dpid"] == 4:
                        node["brand_name"] = brand
                self.fake.fault("POST", "/ndt/set_switches_power_state", 500,
                                {"error": "Failed to change switch power state"}, times=3)
                with self.assertRaises(ndtwin.PowerError) as ctx:
                    self.k.power_off(4)
                err = ctx.exception
                self.assertIsNone(err.nothing_written)
                self.assertTrue(err.may_have_landed)
                self.assertEqual(err.status, 500)
                self.assertEqual(self.count("POST", "/ndt/set_switches_power_state"), 1)
                self.assertEqual(self.count("GET", "/ndt/get_switches_power_state"), 0)

    def test_another_500_of_the_power_route_is_an_unknown_outcome_not_a_power_error(self):
        self.fake.fault("POST", "/ndt/set_switches_power_state", 500, {"error": "Internal server error"})
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.power_off(4)
        self.assertIs(type(ctx.exception), ndtwin.NDTwinError)
        self.assertIsNone(ctx.exception.nothing_written)
        self.assertEqual(self.count("POST", "/ndt/set_switches_power_state"), 1)

    def test_a_state_that_does_not_show_off_is_a_power_error_with_unknown_outcome(self):
        # The kernel records the commanded state before its 200; another app's power-on in
        # between is one way to read something else.
        self.fake.fault("GET", "/ndt/get_switches_power_state", 200,
                        {"192.168.123.14": {"admin_state": "on", "reachable": True}})
        with self.assertRaises(ndtwin.PowerError) as ctx:
            self.k.power_off(4)
        self.assertIsNone(ctx.exception.nothing_written)
        self.assertIn("admin_state 'on'", str(ctx.exception))

    def test_a_state_that_cannot_be_read_after_the_command_is_a_power_error(self):
        self.fake.fault("GET", "/ndt/get_switches_power_state", 500, {"error": "Internal server error"})
        with self.assertRaises(ndtwin.PowerError) as ctx:
            self.k.power_off(4)
        self.assertIsNone(ctx.exception.nothing_written)
        self.assertIsInstance(ctx.exception.__cause__, ndtwin.NDTwinError)

    def test_an_address_the_kernel_does_not_know_is_not_found(self):
        self.fake.fault("POST", "/ndt/set_switches_power_state", 404, {"error": "Unknown switch IP"})
        with self.assertRaises(ndtwin.NotFound):
            self.k.power_off(4)

    def test_a_dead_connection_on_the_power_command_is_an_unknown_outcome(self):
        self.fake.fault("POST", "/ndt/set_switches_power_state", None, apply=True, times=3)
        with self.assertRaises(ndtwin.OutcomeUnknown):
            self.k.power_off(4)
        self.assertEqual(self.count("POST", "/ndt/set_switches_power_state"), 1)


class LockTest(SdkTest):
    def release_bodies(self):
        return [b for m, p, q, b in self.fake.requests if p == "/ndt/release_lock"]

    def test_acquire_and_release_with_the_lease(self):
        with self.k.lock("routing_lock", ttl=60) as lease:
            self.assertEqual((lease.name, lease.id, lease.ttl), ("routing_lock", 41, 60))
            self.assertEqual(calls(self.fake), ["POST acquire_lock"])
        self.assertEqual(self.fake.requests[0][3], {"type": "routing_lock", "ttl": 60})
        self.assertEqual(self.release_bodies(), [{"type": "routing_lock", "lease": 41}])
        self.assertEqual(calls(self.fake), ["POST acquire_lock", "POST release_lock"])

    def renew_bodies(self):
        return [b for m, p, q, b in self.fake.requests if p == "/ndt/renew_lock"]

    def test_renew_extends_the_lease_and_names_it(self):
        with self.k.lock("routing_lock", ttl=60) as lease:
            lease.renew()
            lease.renew(30)
            self.assertEqual(lease.ttl, 30)
            self.assertEqual(calls(self.fake), ["POST acquire_lock", "POST renew_lock",
                                                "POST renew_lock"])
        self.assertEqual(self.renew_bodies(), [{"type": "routing_lock", "ttl": 60, "lease": 41},
                                               {"type": "routing_lock", "ttl": 30, "lease": 41}])
        self.assertEqual(self.release_bodies(), [{"type": "routing_lock", "lease": 41}])

    def test_a_lease_that_ran_out_cannot_be_renewed_and_the_error_says_so(self):
        self.fake.fault("POST", "/ndt/renew_lock", 412, {"error": "Renew failed", "reason": "expired"})
        with self.assertRaises(ndtwin.Refused) as ctx:
            with self.k.lock("routing_lock") as lease:
                lease.renew()
        self.assertEqual(ctx.exception.status, 412)
        self.assertIs(ctx.exception.nothing_written, True)
        self.assertEqual(len(self.renew_bodies()), 1)  # not sent again
        self.assertEqual(len(self.release_bodies()), 1)  # the block ended, so release is tried

    def test_released_when_the_body_raises_and_the_error_is_the_bodys(self):
        for exc in (ValueError("boom"), KeyboardInterrupt()):
            with self.subTest(type(exc).__name__):
                self.reset()
                with self.assertRaises(type(exc)) as ctx:
                    with self.k.lock("routing_lock"):
                        raise exc
                self.assertIs(ctx.exception, exc)
                self.assertEqual(self.release_bodies(), [{"type": "routing_lock", "lease": 41}])

    def test_released_when_the_body_raises_an_sdk_error(self):
        with self.assertRaises(ndtwin.NotFound):
            with self.k.lock("routing_lock"):
                self.k.p4.read_table(1, "nope")
        self.assertEqual(len(self.release_bodies()), 1)

    def test_a_failed_release_does_not_hide_the_bodys_error(self):
        self.fake.fault("POST", "/ndt/release_lock", 409, {"error": "Release failed",
                                                          "reason": "lease_mismatch"})
        with self.assertRaises(ValueError):
            with self.k.lock("routing_lock"):
                raise ValueError("boom")
        self.assertEqual(len(self.release_bodies()), 1)

    def test_a_failed_release_after_a_clean_body_is_raised(self):
        for status, reason in ((409, "lease_mismatch"), (412, "expired")):
            with self.subTest(reason):
                self.reset()
                self.fake.fault("POST", "/ndt/release_lock", status,
                                {"error": "Release failed", "reason": reason})
                with self.assertRaises(ndtwin.Refused) as ctx:
                    with self.k.lock("routing_lock"):
                        pass
                self.assertEqual(ctx.exception.status, status)

    def test_after_ctrl_c_the_release_is_tried_once_without_waiting(self):
        k = ndtwin.Kernel(self.url, timeout=2, retries=2, retry_wait=0.5)
        real, tries = http.client.HTTPConnection.connect, []

        def counting(conn):
            tries.append(1)
            return real(conn)

        with mock.patch("ndtwin._http.time.sleep") as sleep, \
                mock.patch.object(http.client.HTTPConnection, "connect", counting):
            with self.assertRaises(KeyboardInterrupt):
                with k.lock("routing_lock"):
                    self.server.shutdown()
                    self.server.server_close()  # the kernel is gone
                    raise KeyboardInterrupt()
        self.assertEqual(len(tries), 2, "the acquire, then one try of the release")
        self.assertEqual(sleep.call_args_list, [])

    def test_a_lease_that_ran_out_is_not_renewed_and_cannot_be_released(self):
        self.fake.seconds_per_request = 10
        with self.assertRaises(ndtwin.Refused) as ctx:
            with self.k.lock("routing_lock", ttl=15) as lease:
                lease.renew()          # 10 s after the acquire: still held
                self.k.topology()
                lease.renew()          # 20 s after the last renew: ran out
        self.assertEqual((ctx.exception.status, ctx.exception.body["reason"]), (412, "expired"))
        self.assertEqual(len(self.renew_bodies()), 2)
        self.assertEqual(len(self.release_bodies()), 1)  # tried; the lock is no longer held
        self.assertEqual(self.fake.locks, {})

    def test_a_held_lock_is_lock_busy_and_is_neither_retried_nor_released(self):
        self.fake.lock_busy = True
        ran = []
        with self.assertRaises(ndtwin.LockBusy) as ctx:
            with self.k.lock("routing_lock"):
                ran.append(1)
        err = ctx.exception
        self.assertEqual((err.status, err.retry_after_s, err.held_by_lease), (423, 30, 7))
        self.assertIsInstance(err, ndtwin.Refused)
        self.assertIs(err.nothing_written, True)
        self.assertEqual(ran, [])
        self.assertEqual(calls(self.fake), ["POST acquire_lock"])

    def test_an_invalid_lock_name_is_refused(self):
        self.fake.fault("POST", "/ndt/acquire_lock", 400, {"error": "Invalid lock request"})
        with self.assertRaises(ndtwin.Refused):
            with self.k.lock("alpha"):
                pass
        self.assertEqual(calls(self.fake), ["POST acquire_lock"])


class TopologyTest(SdkTest):
    def test_the_decoding_of_the_kernels_address_integers(self):
        self.assertEqual(ip_str(192653504), "192.168.123.11")   # s_addr, little-endian
        self.assertEqual(ip_str(16842762), "10.0.1.1")
        self.assertEqual(ip_str(242985152), "192.168.123.14")
        self.assertNotEqual(ip_str(192653504), "11.123.168.192")
        self.assertEqual(mac_str(8796093022481), "08:00:00:00:01:11")

    def test_dpid_to_management_ip_comes_from_the_graph(self):
        topo = self.k.topology()
        self.assertEqual({d: s.mgmt_ip for d, s in topo.switches.items()}, MGMT_IP)
        self.assertEqual(list(topo.switches), [1, 2, 3, 4])

    def test_switches_hosts_and_links(self):
        topo = self.k.topology()
        sw = topo.switches[1]
        self.assertEqual((sw.name, sw.admin_state, sw.reachable, sw.usable, sw.power_path,
                          sw.brand), ("s1", "on", True, True, "synthetic", "BMv2"))
        graph = copy.deepcopy(self.fake.graph)
        next(n for n in graph["nodes"] if n["dpid"] == 4 and n["vertex_type"] == 0)["brand_name"] = "HPE5520"
        self.assertEqual(Topology.from_graph(graph).switches[4].brand, "HPE5520")
        self.assertEqual(sw.capabilities["ipv4_route"], "package")
        self.assertEqual(sorted(topo.hosts), ["10.0.1.1", "10.0.2.2", "10.0.3.3", "10.0.4.4"])
        h4 = topo.hosts["10.0.4.4"]
        self.assertEqual((h4.name, h4.mac, h4.switch, h4.port), ("h4", "08:00:00:00:04:44", 2, 2))
        self.assertEqual(len(topo.links), 16)
        link = next(l for l in topo.links if (l.src, l.src_port) == (1, 3))
        self.assertEqual((link.dst, link.dst_port, link.up, link.utilization_percent,
                          link.telemetry_status), (3, 1, True, 0.0, "idle"))
        self.assertEqual(topo.neighbours(1), {3: 3, 4: 4})
        self.assertEqual(topo.neighbour(1, 3), 3)
        self.assertIsNone(topo.neighbour(1, 1))      # towards a host
        self.assertIsNone(topo.neighbour(1, 99))
        self.assertIsNone(topo.neighbour(99, 1))

    def test_busiest_is_the_highest_utilisation_of_a_link_touching_the_switch(self):
        for edge in self.fake.graph["edges"]:
            if edge["src_dpid"] == 4 and edge["dst_dpid"] == 2:
                edge["link_bandwidth_utilization_percent"] = 85.0
        topo = self.k.topology()
        self.assertEqual((topo.busiest(4), topo.busiest(2), topo.busiest(1), topo.busiest(3)),
                         (85.0, 85.0, 0.0, 0.0))
        self.assertEqual(topo.busiest(99), 0.0)

    def test_a_switch_that_is_off_or_unreachable_is_not_usable_and_its_links_do_not_count(self):
        for edge in self.fake.graph["edges"]:
            if {edge["src_dpid"], edge["dst_dpid"]} == {1, 4}:
                edge["link_bandwidth_utilization_percent"] = 90.0
        for field, value in (("admin_state", "off"), ("reachable", False)):
            with self.subTest(field):
                graph = copy.deepcopy(self.fake.graph)
                next(n for n in graph["nodes"] if n["dpid"] == 4 and n["vertex_type"] == 0)[field] = value
                topo = Topology.from_graph(graph)
                self.assertFalse(topo.switches[4].usable)
                self.assertEqual(topo.neighbours(1), {3: 3})
                self.assertIsNone(topo.neighbour(1, 4))
                self.assertEqual(topo.busiest(1), 0.0)
                self.assertIn(4, topo.switches)

    def test_a_down_link_and_the_hosts_behind_a_down_link_or_switch_are_left_out(self):
        graph = copy.deepcopy(self.fake.graph)
        for edge in graph["edges"]:
            if {edge["src_dpid"], edge["dst_dpid"]} == {1, 3}:
                edge["is_up"] = False
            if edge["src_dpid"] == 1 and edge["src_interface"] == 2:
                edge["is_up"] = False  # s1 -> h2
        topo = Topology.from_graph(graph)
        self.assertIsNone(topo.neighbour(1, 3))
        self.assertIsNone(topo.neighbour(3, 1))
        self.assertNotIn("10.0.2.2", topo.hosts)
        self.assertEqual(sorted(topo.hosts), ["10.0.1.1", "10.0.3.3", "10.0.4.4"])
        graph = copy.deepcopy(self.fake.graph)
        next(n for n in graph["nodes"] if n["dpid"] == 2 and n["vertex_type"] == 0)["reachable"] = False
        self.assertEqual(sorted(Topology.from_graph(graph).hosts), ["10.0.1.1", "10.0.2.2"])

    def test_a_switch_with_a_host_behind_a_down_link_is_still_an_edge_switch(self):
        graph = copy.deepcopy(self.fake.graph)
        self.assertEqual(Topology.from_graph(graph).edge_switches, {1, 2})
        h9 = "10.0.9.9"
        graph["nodes"].append({"vertex_type": 1, "dpid": 0, "device_name": "h9", "ip": [
            int.from_bytes(socket.inet_aton(h9), "little")], "mac": 0})
        for src, sport, dst, dport, ip_key in ((4, 9, 0, 1, "dst_ip"), (0, 1, 4, 9, "src_ip")):
            edge = copy.deepcopy(graph["edges"][0])
            edge.update(src_dpid=src, src_interface=sport, dst_dpid=dst, dst_interface=dport,
                        is_up=False)
            edge[ip_key] = [int.from_bytes(socket.inet_aton(h9), "little")]
            graph["edges"].append(edge)
        topo = Topology.from_graph(graph)
        self.assertEqual(topo.edge_switches, {1, 2, 4})
        self.assertNotIn(h9, topo.hosts)  # not reachable now, but s4 is its switch

    def test_attached_hosts_include_those_behind_a_down_link_or_an_unusable_switch(self):
        graph = copy.deepcopy(self.fake.graph)
        for edge in graph["edges"]:
            if edge["src_dpid"] == 1 and edge["src_interface"] == 2:
                edge["is_up"] = False  # s1 -> h2
        next(n for n in graph["nodes"] if n["dpid"] == 2 and n["vertex_type"] == 0)["reachable"] = False
        topo = Topology.from_graph(graph)
        self.assertEqual(sorted(topo.hosts), ["10.0.1.1"])
        attached = topo.attached_hosts
        self.assertEqual(sorted(attached), ["10.0.1.1", "10.0.2.2", "10.0.3.3", "10.0.4.4"])
        self.assertEqual((attached["10.0.2.2"].switch, attached["10.0.2.2"].port), (1, 2))
        self.assertEqual((attached["10.0.4.4"].name, attached["10.0.4.4"].switch,
                          attached["10.0.4.4"].port), ("h4", 2, 2))
        self.assertIs(attached["10.0.1.1"], topo.hosts["10.0.1.1"])

    def test_a_graph_the_sdk_cannot_read_is_an_ndtwin_error(self):
        for graph in ({"nodes": [{"vertex_type": 0}], "edges": []}, {"edges": []}, [1, 2]):
            with self.subTest(graph):
                self.reset()
                self.fake.fault("GET", "/ndt/get_graph_data", 200, graph)
                with self.assertRaises(ndtwin.NDTwinError) as ctx:
                    self.k.topology()
                self.assertIs(type(ctx.exception), ndtwin.NDTwinError)
                self.assertIs(ctx.exception.nothing_written, True)
                self.assertEqual(ctx.exception.body, graph)

    def test_hosts_in_a_destination_match(self):
        topo = self.k.topology()
        ips = lambda value: sorted(h.ip for h in topo.hosts_in(value))  # noqa: E731
        self.assertEqual(ips(["10.0.4.4", 32]), ["10.0.4.4"])
        self.assertEqual(ips(["10.0.4.0", 24]), ["10.0.4.4"])
        self.assertEqual(ips(["10.0.0.0", 16]), ["10.0.1.1", "10.0.2.2", "10.0.3.3", "10.0.4.4"])
        self.assertEqual(ips(["10.0.9.9", 32]), [])
        self.assertEqual(ips("10.0.3.3"), ["10.0.3.3"])
        self.assertEqual(ips("10.0.3.4"), [])
        self.assertEqual(ips(None), [])

    def test_average_link_usage_is_a_fraction_and_the_power_report_is_by_dpid(self):
        self.fake.avg = 0.3125
        self.assertEqual(self.k.average_link_usage(), 0.3125)
        self.assertEqual(self.k.power_report(), POWER_MW)

    def test_average_link_usage_carries_the_telemetry_health(self):
        self.fake.telemetry_health = {"status": "severe_loss", "loss_fraction": 0.725}
        usage = self.k.average_link_usage()
        self.assertIsInstance(usage, ndtwin.LinkUsage)
        self.assertEqual(usage.telemetry_health["status"], "severe_loss")
        self.assertLess(usage, 0.4)  # still a float
        self.fake.fault("GET", "/ndt/get_average_link_usage", 200,
                        {"status": "success", "avg_link_usage": 0.1})
        self.assertIsNone(self.k.average_link_usage().telemetry_health)


class _Clock:
    """A stand-in for the `time` module of ndtwin.p4: `sleep` moves `monotonic` on, and so does
    each request, by `per_request` seconds (the time a kernel takes to answer). That small default
    also ends a `settle` that never decides once its budget runs out. Like `time.sleep`, `sleep`
    refuses a negative or NaN length (ValueError) and an infinite one (OverflowError)."""

    def __init__(self):
        self.now, self.sleeps, self.per_request = 1000.0, [], 0.1

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        if seconds != seconds or seconds < 0:
            raise ValueError(f"sleep length must be non-negative, not {seconds!r}")
        if seconds == float("inf"):
            raise OverflowError("sleep length is too large")
        self.sleeps.append(seconds)
        self.now += seconds


class SettleTest(SdkTest):
    """P4.settle: re-send the identical write after OutcomeUnknown, read the switch's answer,
    then read the table once (doc/2026-01-02_ndt_api.md §43)."""

    def setUp(self):
        super().setUp()
        self.clock = _Clock()
        patcher = mock.patch.object(ndtwin.p4, "time", self.clock)
        patcher.start()
        self.addCleanup(patcher.stop)
        handle = self.fake.handle

        def charged(*args):
            self.clock.now += self.clock.per_request
            return handle(*args)
        self.fake.handle = charged

    def new_entry(self):
        return ndtwin.TableEntry({"dpid": 1, "table": TABLE, "match": {FIELD: ["10.0.9.9", 32]},
                                  "action_name": "MyIngress.ipv4_forward",
                                  "action_params": {"dstAddr": "08:00:00:00:09:99", "port": 2},
                                  "priority": None, "default_action": False})

    def timed_out(self, apply, times=1):
        self.fake.fault("POST", ENTRY, 504, kernel_body("P4 proxy timed out", True),
                        origin="kernel", apply=apply, times=times)

    def unknown_write(self, entry, op, apply):
        """The first write, answered 504 with request_sent true; `apply`: it landed."""
        self.fake.requests.clear()
        self.timed_out(apply)
        with self.assertRaises(ndtwin.OutcomeUnknown):
            self.k.p4.write(entry, op)
        self.assertEqual(self.count("POST", ENTRY), 1)  # the SDK did not send it again
        self.fake.requests.clear()

    def shown(self, entry):
        return [e for e in self.fake.tables[1] if e["match"] == entry["match"]]

    def posts(self):
        return [b for m, p, _, b in self.fake.requests if (m, p) == ("POST", ENTRY)]

    def assert_identical_resends(self, entry, op, n):
        self.assertEqual(self.posts(), [dict(entry, op=op)] * n)

    def test_an_insert_that_landed_is_settled_by_already_exists(self):
        entry = self.new_entry()
        self.unknown_write(entry, "insert", apply=True)
        settled = self.k.p4.settle(entry, "insert", wait_s=2)
        self.assertEqual(self.clock.sleeps, [2])  # it waits before the first re-send too
        self.assertIsInstance(settled, ndtwin.Settled)
        self.assertEqual((settled.original_landed, settled.attempts), (True, 1))
        self.assertEqual(settled.entry["action_params"], entry["action_params"])
        self.assert_identical_resends(entry, "insert", 1)
        self.assertEqual(calls(self.fake), ["POST table s1", "GET table s1"])
        self.assertEqual(len(self.shown(entry)), 1)

    def test_an_insert_that_did_not_land_is_settled_by_the_resent_write(self):
        entry = self.new_entry()
        self.unknown_write(entry, "insert", apply=False)
        self.assertEqual(self.shown(entry), [])
        settled = self.k.p4.settle(entry, "insert")
        self.assertEqual((settled.original_landed, settled.attempts), (False, 1))
        self.assertEqual(len(self.shown(entry)), 1)
        self.assertEqual(calls(self.fake), ["POST table s1", "GET table s1"])

    def test_a_delete_that_landed_is_settled_by_not_found(self):
        entry = self.route_entry()
        self.fake.fault("POST", ENTRY, 502, grpc_502("DEADLINE_EXCEEDED"), origin="proxy",
                        apply=True)
        with self.assertRaises(ndtwin.OutcomeUnknown):
            self.k.p4.write(entry, "delete")
        self.fake.requests.clear()
        settled = self.k.p4.settle(entry, "delete")
        self.assertEqual((settled.entry, settled.original_landed, settled.attempts), (None, True, 1))
        self.assertEqual(self.shown(entry), [])
        self.assert_identical_resends(entry, "delete", 1)

    def test_a_delete_that_did_not_land_is_settled_by_the_resent_write(self):
        entry = self.route_entry()
        self.unknown_write(entry, "delete", apply=False)
        self.assertEqual(len(self.shown(entry)), 1)
        settled = self.k.p4.settle(entry, "delete")
        self.assertEqual((settled.entry, settled.original_landed), (None, False))
        self.assertEqual(self.shown(entry), [])

    def test_a_modify_is_applied_again_and_cannot_say_whether_the_first_landed(self):
        entry = self.route_entry().with_params(port=3)
        for apply in (True, False):
            with self.subTest(apply=apply):
                self.unknown_write(entry, "modify", apply=apply)
                settled = self.k.p4.settle(entry, "modify")
                self.assertEqual((settled.original_landed, settled.attempts), (None, 1))
                self.assertEqual(settled.entry["action_params"]["port"], 3)
                self.assert_identical_resends(entry, "modify", 1)

    def test_still_unknown_when_the_budget_runs_out_raises_unsettled_with_the_last_status(self):
        entry = self.new_entry()
        self.unknown_write(entry, "insert", apply=False)
        self.timed_out(apply=False, times=50)
        self.clock.per_request = 0   # answers take no time: the last re-send is due exactly at 3 s
        with self.assertRaises(ndtwin.Unsettled) as ctx:
            self.k.p4.settle(entry, "insert", budget_s=3, wait_s=1)
        err = ctx.exception
        self.assertIsInstance(err, ndtwin.OutcomeUnknown)
        self.assertTrue(err.may_have_landed)
        self.assertEqual((err.status, err.origin, err.attempts), (504, "kernel", 2))
        self.assertIs(err.body["request_sent"], True)
        self.assertIsInstance(err.last, ndtwin.OutcomeUnknown)
        self.assertEqual(self.clock.sleeps, [1, 1])   # re-sends at 1 and 2 s; none would start at 3 s
        self.assert_identical_resends(entry, "insert", 2)  # one POST per attempt, no hidden retries
        self.assertEqual(self.count("GET", ENTRY), 0)
        self.assertEqual(self.shown(entry), [])

    def test_the_time_spent_waiting_for_answers_counts_against_the_budget(self):
        # Each 504 comes 15 s after the request, as the kernel's deadline on this route.
        entry = self.new_entry()
        self.timed_out(apply=False, times=50)
        self.clock.per_request = 15
        with self.assertRaises(ndtwin.Unsettled) as ctx:
            self.k.p4.settle(entry, "insert", budget_s=60, wait_s=1)
        self.assertEqual(ctx.exception.attempts, 4)   # sent at 1, 17, 33 and 49 s
        self.assertEqual(self.clock.now - 1000.0, 64)

    def test_a_budget_of_zero_sends_it_once(self):
        entry = self.new_entry()
        self.timed_out(apply=False)
        with self.assertRaises(ndtwin.Unsettled) as ctx:
            self.k.p4.settle(entry, "insert", budget_s=0)
        self.assertEqual(ctx.exception.attempts, 1)
        self.assertEqual(self.clock.sleeps, [self.k._http.retry_wait])

    def test_a_busy_answer_to_the_resent_write_is_sent_again_after_wait_s(self):
        entry = self.new_entry()
        self.unknown_write(entry, "insert", apply=True)
        self.fake.fault("POST", ENTRY, 503, proxy_detail("switch busy"), origin="proxy")
        self.fake.fault("POST", ENTRY, 504, kernel_body("P4 proxy timed out", False),
                        origin="kernel")
        settled = self.k.p4.settle(entry, "insert", wait_s=0.5)
        # Busy says the re-send changed nothing, so ALREADY_EXISTS is about the first write.
        self.assertEqual((settled.original_landed, settled.attempts), (True, 3))
        self.assertEqual(self.clock.sleeps, [0.5, 0.5, 0.5])
        self.assert_identical_resends(entry, "insert", 3)

    def test_a_kernel_that_cannot_be_reached_is_tried_again(self):
        entry = self.new_entry()
        self.unknown_write(entry, "insert", apply=True)
        real, calls_made = http.client.HTTPConnection.connect, []

        def connect(conn):
            calls_made.append(conn)
            if len(calls_made) == 1:
                raise ConnectionRefusedError("refused")
            return real(conn)
        with mock.patch.object(http.client.HTTPConnection, "connect", connect):
            settled = self.k.p4.settle(entry, "insert", wait_s=0.5)
        self.assertEqual((settled.original_landed, settled.attempts), (True, 2))
        self.assert_identical_resends(entry, "insert", 1)  # the first never reached the kernel

    def test_a_resent_write_that_times_out_again_is_sent_again(self):
        # As on bmv2 1.15.5 with the proxy's pool held: the retry at once got 504 again.
        entry = self.new_entry()
        self.unknown_write(entry, "insert", apply=True)
        self.timed_out(apply=False)
        settled = self.k.p4.settle(entry, "insert")
        self.assertEqual(settled.attempts, 2)
        self.assertIsNone(settled.original_landed)  # the 504'd re-send may be what is there
        self.assertEqual(len(self.shown(entry)), 1)

    def test_already_exists_after_an_own_resend_timed_out_does_not_blame_the_first(self):
        # The first write did not land; settle's first re-send timed out but landed; the second
        # re-send meets that one.
        entry = self.new_entry()
        self.unknown_write(entry, "insert", apply=False)
        self.timed_out(apply=True)
        settled = self.k.p4.settle(entry, "insert")
        self.assertEqual((settled.original_landed, settled.attempts), (None, 2))
        self.assertEqual(len(self.shown(entry)), 1)
        entry = self.route_entry()
        self.unknown_write(entry, "delete", apply=False)
        self.timed_out(apply=True)
        settled = self.k.p4.settle(entry, "delete")
        self.assertEqual((settled.entry, settled.original_landed, settled.attempts), (None, None, 2))

    def test_a_refusal_that_says_the_write_is_invalid_is_raised_and_nothing_is_read(self):
        entry = self.new_entry()
        for code in ("INVALID_ARGUMENT", "OUT_OF_RANGE", "UNIMPLEMENTED"):
            with self.subTest(code):
                self.fake.requests.clear()
                self.fake.fault("POST", ENTRY, 502, proxy_detail(
                    "the switch refused the write", grpc_status="UNKNOWN",
                    p4rt_error={"code": code, "message": "m"}), origin="proxy")
                with self.assertRaises(ndtwin.SwitchRefused) as ctx:
                    self.k.p4.settle(entry, "insert")
                self.assertNotIsInstance(ctx.exception, ndtwin.Unsettled)
                self.assertEqual(ctx.exception.p4rt_error["code"], code)
                self.assertEqual(self.count("POST", ENTRY), 1)
                self.assertEqual(self.count("GET", ENTRY), 0)

    def assert_unsettled_by(self, cls, op="insert", entry=None):
        self.fake.requests.clear()
        with self.assertRaises(ndtwin.Unsettled) as ctx:
            self.k.p4.settle(entry or self.new_entry(), op, budget_s=60)
        err = ctx.exception
        self.assertIs(type(err.last), cls)
        self.assertEqual((err.attempts, err.status), (1, err.last.status))
        self.assertTrue(err.may_have_landed)
        self.assertEqual(self.count("POST", ENTRY), 1)   # not sent again: it would answer the same
        self.assertEqual(self.count("GET", ENTRY), 0)
        return err

    def test_a_switch_code_that_does_not_decide_it_is_unsettled(self):
        self.fake.fault("POST", ENTRY, 502, proxy_detail(
            "the switch refused the write", grpc_status="UNKNOWN",
            p4rt_error={"code": "RESOURCE_EXHAUSTED", "message": "table full"}), origin="proxy")
        err = self.assert_unsettled_by(ndtwin.SwitchRefused)
        self.assertEqual(err.last.p4rt_error["code"], "RESOURCE_EXHAUSTED")

    def test_a_modify_of_an_entry_that_is_gone_is_unsettled_at_once(self):
        # Another writer may have deleted it after an earlier copy landed; NOT_FOUND says only
        # that it is gone now, and would come back on every re-send.
        err = self.assert_unsettled_by(ndtwin.SwitchRefused, "modify")
        self.assertEqual(err.last.p4rt_error["code"], "NOT_FOUND")

    def readme_recipes(self):
        """The README's expressions that read `err.last.p4rt_error`, as written there."""
        with open(os.path.join(SDK_DIR, "README.md")) as fh:
            text = fh.read()
        found = re.findall(r"^\s*\w+ = (.*err\.last\.p4rt_error.*)$", text, re.M)
        found += re.findall(r"`([^`\n]*err\.last\.p4rt_error[^`\n]*)`", text)
        self.assertTrue(found, "the README gives no recipe")
        return found

    def test_the_readme_recipe_tells_a_gone_entry_from_a_budget_that_ran_out(self):
        self.timed_out(apply=False, times=50)
        with self.assertRaises(ndtwin.Unsettled) as ctx:
            self.k.p4.settle(self.new_entry(), "insert", budget_s=0)
        ran_out = ctx.exception
        self.fake.faults.clear()
        gone = self.assert_unsettled_by(ndtwin.SwitchRefused, "modify")
        for expr in self.readme_recipes():
            with self.subTest(expr):
                self.assertIs(eval(expr, {"ndtwin": ndtwin, "err": ran_out}), False)
                self.assertIs(eval(expr, {"ndtwin": ndtwin, "err": gone}), True)

    def test_a_default_entry_is_applied_again_and_cannot_say_whether_the_first_landed(self):
        # The proxy sends a default entry's insert as a modify, so its 200 says nothing.
        default = TableEntry_of(self.k.p4.read_table(1, TABLE).default, action_name="ipv4_forward",
                                action_params={"dstAddr": "08:00:00:00:09:09", "port": 2})
        self.unknown_write(default, "insert", apply=False)
        settled = self.k.p4.settle(default, "insert")
        self.assertEqual((settled.original_landed, settled.attempts), (None, 1))
        self.assertEqual(settled.entry["action_params"]["port"], 2)

    def test_a_4xx_to_the_resent_write_is_unsettled(self):
        self.fake.fault("POST", ENTRY, 409, proxy_detail("owned by the package"), origin="proxy")
        self.assertEqual(self.assert_unsettled_by(ndtwin.Refused).status, 409)

    def test_a_resent_write_answered_200_with_no_json_is_unsettled(self):
        self.fake.fault("POST", ENTRY, 200, b"<html>ok</html>", origin="proxy", apply=True)
        err = self.assert_unsettled_by(ndtwin.NDTwinError)
        self.assertEqual(err.status, 200)

    def test_already_exists_with_another_action_is_not_settled_as_landed(self):
        # Another writer's entry holds the key: ALREADY_EXISTS, and the read shows other params.
        entry = self.route_entry().with_params(port=3)
        with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
            self.k.p4.settle(entry, "insert")
        self.assertIsNone(ctx.exception.nothing_written)

    def test_a_delete_the_table_still_shows_is_not_verified(self):
        entry = self.route_entry()
        self.fake.fault("POST", ENTRY, 200, {"status": "success"}, origin="proxy")  # not applied
        with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
            self.k.p4.settle(entry, "delete")
        # The 200 says the re-sent delete was applied; the entry being there now does not undo that.
        self.assertEqual((ctx.exception.original_landed, ctx.exception.attempts), (False, 1))
        self.fake.unrendered[1] = [{"default_action": False, "priority": None, "reason": "r"}]
        with self.assertRaises(ndtwin.WriteNotVerified):
            self.k.p4.settle(self.new_entry(), "insert")

    def test_a_delete_is_not_confirmed_by_a_match_written_in_another_form(self):
        # The delete is sent in another form than the table shows. The fake compares raw text and
        # answers NOT_FOUND, as a switch would if the entry had been inserted again after the
        # delete landed: the read must not then call the entry "gone".
        base = self.route_entry()
        self.fake.tables[1].insert(0, dict(copy.deepcopy(dict(base)),
                                           match={"hdr.ethernet.dstAddr": "08:00:00:00:04:aa"}))
        for match in ({"hdr.ethernet.dstAddr": "08:00:00:00:04:AA"},
                      {FIELD: ["0x0a000404", 32]}):
            with self.subTest(match):
                entry = TableEntry_of(base, match=match)
                with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
                    self.k.p4.settle(entry, "delete")
                # NOT_FOUND said "gone"; the read shows the entry, so that decision is dropped.
                self.assertEqual((ctx.exception.original_landed, ctx.exception.attempts), (None, 1))
        self.assertEqual(len(self.fake.tables[1]), 6)   # nothing was deleted

    def test_a_delete_whose_match_has_a_form_the_table_never_shows_is_not_confirmed(self):
        base = self.route_entry()
        for value in ("167773188", " 10.0.4.4"):   # 10.0.4.4 as decimal text, with a space
            with self.subTest(value):
                entry = TableEntry_of(base, match={FIELD: [value, 32]})
                with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
                    self.k.p4.settle(entry, "delete")
                self.assertIn("cannot be compared", str(ctx.exception))
                # The read could not contradict NOT_FOUND, so the decision is kept.
                self.assertEqual((ctx.exception.original_landed, ctx.exception.attempts), (True, 1))
        self.assertEqual(len(self.fake.tables[1]), 5)   # nothing was deleted

    def test_the_confirming_read_is_one_request(self):
        entry = self.new_entry()
        self.fake.fault("GET", ENTRY, 503, proxy_detail("busy"), origin="proxy", times=3)
        with self.assertRaises(ndtwin.WriteNotVerified):
            self.k.p4.settle(entry, "insert")
        self.assertEqual(self.count("GET", ENTRY), 1)

    def test_a_confirming_read_that_fails_keeps_what_settle_decided(self):
        entry = self.new_entry()
        self.unknown_write(entry, "insert", apply=True)
        self.fake.fault("GET", ENTRY, 503, proxy_detail("busy"), origin="proxy")
        with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
            self.k.p4.settle(entry, "insert")
        self.assertEqual((ctx.exception.original_landed, ctx.exception.attempts), (True, 1))
        with self.assertRaises(ndtwin.WriteNotVerified) as ctx:   # the read shows other params
            self.k.p4.settle(entry.with_params(port=3), "insert")
        # ALREADY_EXISTS said "there", but the entry there is another: the read contradicts it.
        self.assertEqual((ctx.exception.original_landed, ctx.exception.attempts), (None, 1))

    def test_already_exists_and_a_read_with_no_entry_is_not_settled_as_landed(self):
        # ALREADY_EXISTS said "there", and the read shows no entry for the key: contradicted.
        entry = self.new_entry()
        self.fake.fault("POST", ENTRY, 502, proxy_detail(
            "the switch refused the write", grpc_status="UNKNOWN",
            p4rt_error={"code": "ALREADY_EXISTS", "message": "Match entry exists"}), origin="proxy")
        with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
            self.k.p4.settle(entry, "insert")
        self.assertEqual((ctx.exception.original_landed, ctx.exception.attempts), (None, 1))

    def test_a_resend_that_was_applied_stays_applied_whatever_the_read_shows(self):
        # The re-send is answered 200 (applied), and the read does not show it: that says the
        # entry is not there now, not that the re-send was not applied.
        entry = self.new_entry()
        self.fake.fault("POST", ENTRY, 200, {"status": "success"}, origin="proxy")  # not applied
        with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
            self.k.p4.settle(entry, "insert")
        self.assertEqual((ctx.exception.original_landed, ctx.exception.attempts), (False, 1))

    def test_settle_checks_a_retry_wait_set_after_the_client_was_made(self):
        # Kernel refuses a bad retry_wait, but the attribute, or a transport of the caller's own
        # passed to ndtwin.P4, can still carry one; settle refuses it before sending anything.
        for wait in (-1, float("nan"), float("inf")):
            with self.subTest(wait):
                self.k._http.retry_wait = wait
                with self.assertRaisesRegex(ValueError, "budget_s and wait_s must be finite"):
                    self.k.p4.settle(self.new_entry(), "insert")
        self.assertEqual(self.fake.requests, [])

    def test_a_delete_in_the_other_forms_the_proxy_takes_is_not_confirmed_by_a_late_reinsert(self):
        # An exact match sent as a one-element list, and priority 0 on a table that has none
        # (the GET shows None): the fake compares raw values and answers NOT_FOUND, as a switch
        # would if the entry had been inserted again after the delete landed.
        base = self.route_entry()
        self.fake.tables[1].insert(0, dict(copy.deepcopy(dict(base)), match={"meta.vrf": 7}))
        for entry in (TableEntry_of(base, match={"meta.vrf": [7]}), TableEntry_of(base, priority=0)):
            with self.subTest(match=entry["match"], priority=entry["priority"]):
                with self.assertRaises(ndtwin.WriteNotVerified) as ctx:
                    self.k.p4.settle(entry, "delete")
                # NOT_FOUND said "gone"; the read shows the entry, so that decision is dropped.
                self.assertEqual((ctx.exception.original_landed, ctx.exception.attempts), (None, 1))
        self.assertEqual(len(self.fake.tables[1]), 6)   # nothing was deleted

    def test_read_table_refuses_negative_retries_before_sending(self):
        with self.assertRaises(ValueError):
            self.k.p4.read_table(1, TABLE, retries=-1)
        self.assertEqual(self.fake.requests, [])

    def test_a_wait_longer_than_the_budget_still_sends_once(self):
        self.timed_out(apply=False)
        with self.assertRaises(ndtwin.Unsettled) as ctx:
            self.k.p4.settle(self.new_entry(), "insert", budget_s=0, wait_s=5)
        self.assertEqual((ctx.exception.attempts, self.clock.sleeps), (1, [5]))

    def test_an_unknown_op_or_a_negative_budget_or_wait_is_refused_before_sending(self):
        with self.assertRaises(ValueError):
            self.k.p4.settle(self.new_entry(), "upsert")
        # time.sleep (and the fake clock) would refuse a negative or NaN wait too, but only
        # settle's own check names the arguments, and NaN or infinite budgets need it.
        refused = "budget_s and wait_s must be finite and 0 or more"
        for kw in ({"budget_s": -1}, {"wait_s": -0.5}, {"budget_s": float("nan")},
                   {"budget_s": float("inf")}, {"wait_s": float("nan")}, {"wait_s": float("inf")}):
            with self.subTest(**kw), self.assertRaisesRegex(ValueError, refused):
                self.k.p4.settle(self.new_entry(), "insert", **kw)
        self.assertEqual(self.fake.requests, [])


class CounterAndRegisterTest(SdkTest):
    """The three stateful reads are thin: same retry rule as every read, the proxy's reply shape."""

    def last_query(self):
        return self.fake.requests[-1][2]

    def test_counter_reads_one_cell(self):
        c = self.k.p4.counter("MyIngress.c_port", 2, index=1)
        self.assertEqual(c, ndtwin.Counter(dpid=2, name="MyIngress.c_port", index=1, bytes=670,
                                           packets=10))
        self.assertEqual(self.fake.requests[-1][:3],
                         ("GET", "/ndt/p4/counter/MyIngress.c_port", {"dpid": "2", "index": "1"}))
        self.assertEqual(self.k.p4.counter("MyIngress.c_port", 2).index, 0)
        self.assertEqual(self.last_query(), {"dpid": "2", "index": "0"})

    def test_counter_errors(self):
        with self.assertRaises(ndtwin.NotFound) as ctx:
            self.k.p4.counter("MyIngress.nope", 1)
        self.assertEqual((ctx.exception.origin, ctx.exception.status), ("proxy", 404))
        self.assertIs(ctx.exception.nothing_written, True)
        self.reset()
        self.fake.fault("GET", "/ndt/p4/counter/MyIngress.c_port", 503,
                        proxy_detail("counter not read"), origin="proxy", times=3)
        with self.assertRaises(ndtwin.Busy):
            self.k.p4.counter("MyIngress.c_port", 1)
        self.assertEqual(self.count("GET", "/ndt/p4/counter/MyIngress.c_port"), 3)

    def test_direct_counter_reads_every_entry(self):
        d = self.k.p4.direct_counter("MyIngress.dc_route", 1)
        self.assertEqual((d.dpid, d.name, d.table, d.unit), (1, "MyIngress.dc_route", TABLE, "both"))
        self.assertEqual((d.entries[0]["bytes"], d.entries[0]["packets"], d.entries[0]["priority"]),
                         (335, 5, 0))
        self.assertEqual(d.entries[0]["match"][FIELD]["type"], "lpm")
        self.assertEqual(self.fake.requests[-1][:3], ("GET", "/ndt/p4/direct_counter/MyIngress.dc_route",
                                                       {"dpid": "1"}))

    def test_direct_counter_errors(self):
        self.fake.fault("GET", "/ndt/p4/direct_counter/MyIngress.dc_route", 404,
                        proxy_detail("indexed counter"), origin="proxy")
        with self.assertRaises(ndtwin.NotFound):
            self.k.p4.direct_counter("MyIngress.dc_route", 1)
        self.reset()
        self.fake.fault("GET", "/ndt/p4/direct_counter/MyIngress.dc_route", 502,
                        proxy_detail("direct counter not rendered"), origin="proxy", times=3)
        with self.assertRaises(ndtwin.NDTwinError) as ctx:
            self.k.p4.direct_counter("MyIngress.dc_route", 1)
        self.assertIs(type(ctx.exception), ndtwin.NDTwinError)
        self.assertIs(ctx.exception.nothing_written, True)

    def test_register_reads_a_cell_a_range_or_the_array(self):
        one = self.k.p4.register("MyIngress.r_mark", 2, index=3)
        self.assertEqual((one.values, one.start, one.size, one.bitwidth, one.source),
                         ([103], 3, 16, 32, "bmv2-thrift"))
        self.assertEqual(self.last_query(), {"dpid": "2", "index": "3"})
        many = self.k.p4.register("MyIngress.r_mark", 2, start=4, count=2)
        self.assertEqual((many.values, many.start), ([104, 105], 4))
        self.assertEqual(self.last_query(), {"dpid": "2", "start": "4", "count": "2"})
        whole = self.k.p4.register("MyIngress.r_mark", 2)
        self.assertEqual((len(whole.values), whole.name), (16, "MyIngress.r_mark"))
        self.assertEqual(self.last_query(), {"dpid": "2"})
        self.assertEqual(self.k.p4.register("MyIngress.r_mark", 2, index=0).values, [100])

    def test_register_errors(self):
        with self.assertRaises(ndtwin.Refused) as ctx:
            self.k.p4.register("MyIngress.r_mark", 2, index=99)
        self.assertEqual(ctx.exception.status, 400)
        self.assertIs(type(ctx.exception), ndtwin.Refused)
        self.assertEqual(self.count("GET", "/ndt/p4/register/MyIngress.r_mark"), 1)
        for status, error in ((501, "register too wide"), (413, "too many cells")):
            self.reset()
            self.fake.fault("GET", "/ndt/p4/register/MyIngress.r_mark", status, proxy_detail(error),
                            origin="proxy")
            with self.assertRaises(ndtwin.NDTwinError) as ctx:
                self.k.p4.register("MyIngress.r_mark", 2)
            self.assertIs(ctx.exception.nothing_written, True)
            self.assertEqual(self.count("GET", "/ndt/p4/register/MyIngress.r_mark"), 1)
        self.reset()
        self.fake.fault("GET", "/ndt/p4/register/MyIngress.r_mark", 503,
                        proxy_detail("register not read"), origin="proxy")
        self.assertEqual(len(self.k.p4.register("MyIngress.r_mark", 2).values), 16)  # retried
        self.assertEqual(self.count("GET", "/ndt/p4/register/MyIngress.r_mark"), 2)

    def test_a_kernel_that_is_not_a_p4_fabric_is_not_retried(self):
        self.fake.fault("GET", "/ndt/p4/counter/MyIngress.c_port", 501,
                        kernel_body("not a P4 fabric"), origin="kernel")
        with self.assertRaises(ndtwin.NDTwinError):
            self.k.p4.counter("MyIngress.c_port", 1)
        self.assertEqual(self.count("GET", "/ndt/p4/counter/MyIngress.c_port"), 1)

    def test_a_name_is_one_path_segment(self):
        with self.assertRaises(ndtwin.NotFound):
            self.k.p4.counter("a/b", 1)
        self.assertEqual(self.fake.requests[-1][1], "/ndt/p4/counter/a%2Fb")


def is_stdlib(name):
    """Whether `name` is a standard-library module: `sys.stdlib_module_names` from Python 3.10 on;
    before that, a built-in module or one found in the standard library's directory, so the suite
    also runs under an older interpreter a test lane may pick."""
    if hasattr(sys, "stdlib_module_names"):
        return name in sys.stdlib_module_names
    if name in sys.builtin_module_names:
        return True
    spec = importlib.util.find_spec(name)
    if spec is None or not spec.origin:
        return False
    stdlib = os.path.realpath(sysconfig.get_paths()["stdlib"])
    origin = os.path.realpath(spec.origin)
    return origin.startswith(stdlib + os.sep) and "site-packages" not in origin


class PackageTest(unittest.TestCase):
    def sources(self):
        pkg = os.path.join(SDK_DIR, "ndtwin")
        for name in sorted(os.listdir(pkg)):
            if name.endswith(".py"):
                with open(os.path.join(pkg, name)) as fh:
                    yield name, fh.read()

    def test_it_imports_only_the_standard_library(self):
        for name, src in self.sources():
            for node in ast.walk(ast.parse(src)):
                mods = []
                if isinstance(node, ast.Import):
                    mods = [a.name for a in node.names]
                elif isinstance(node, ast.ImportFrom) and not node.level:
                    mods = [node.module]
                for mod in mods:
                    self.assertTrue(is_stdlib(mod.split(".")[0]), f"{name}: {mod}")

    def test_it_calls_only_ndt_routes(self):
        for name, src in self.sources():
            for node in ast.walk(ast.parse(src)):
                if isinstance(node, ast.Constant) and isinstance(node.value, str):
                    if node.value.startswith("/") and len(node.value) > 1 and " " not in node.value:
                        self.assertTrue(node.value.startswith("/ndt/"), f"{name}: {node.value}")
                    self.assertNotIn(":8081", node.value, name)

    def test_the_project_file_declares_no_dependencies_and_python_3_10(self):
        with open(os.path.join(SDK_DIR, "pyproject.toml")) as fh:
            text = fh.read()
        self.assertRegex(text, r'(?m)^name = "ndtwin"$')
        self.assertRegex(text, r'(?m)^requires-python = ">=3\.10"$')
        self.assertRegex(text, r"(?m)^dependencies = \[\]$")
        self.assertIsNone(re.search(r"(?m)^(install_requires|\[project\.optional)", text))
        self.assertRegex(text, r'(?m)^requires = \["setuptools>=64"\]$')  # PEP 660 editable installs

    def test_the_exception_tree(self):
        for cls in (ndtwin.KernelUnreachable, ndtwin.Refused, ndtwin.SwitchRefused, ndtwin.Busy,
                    ndtwin.OutcomeUnknown, ndtwin.WriteNotVerified, ndtwin.PowerError):
            self.assertTrue(issubclass(cls, ndtwin.NDTwinError), cls)
        self.assertTrue(issubclass(ndtwin.Unsettled, ndtwin.OutcomeUnknown))
        self.assertTrue(issubclass(ndtwin.NotFound, ndtwin.Refused))
        self.assertTrue(issubclass(ndtwin.LockBusy, ndtwin.Refused))
        self.assertEqual(
            {c.__name__ for c in ndtwin.WriteError},
            {"OutcomeUnknown", "SwitchRefused", "Busy", "WriteNotVerified", "Refused"})
        self.assertEqual(json.dumps(ndtwin.__version__), '"1.0.0"')


if __name__ == "__main__":
    unittest.main()
