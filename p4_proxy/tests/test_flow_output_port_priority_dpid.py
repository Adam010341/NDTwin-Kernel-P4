"""
An OUTPUT action's port, a priority and a dpid that are not whole numbers are the caller's error.

[Co-developed with claude code -- Adam]

tests/test_l4_match_values.py and tests/test_in_port_value.py hold the match keys to a JSON integer.
Three more numbers in a flow request were still read by int() or by a dict lookup:

  * the OUTPUT action's `port`: `true` was written as port 1 and 512 as 0x0200 (the parameter is
    bit<9>), while 1.5, a string, a list, a negative number and 65536 or more reached
    `port.to_bytes(...)` and answered 500;
  * `priority`: `true` was 1, 1.5 was 1, and Infinity reached int() and answered 500;
  * `dpid`: `true` and `1.0` found switch 1, and NaN or Infinity made the 404 or the 400's own JSON
    body unrenderable (500).

The proxy now answers 400, nothing written, for a JSON boolean or float in any of the three
(NaN, Infinity and 1e400 included), and for a port outside 0-511 or that is no number. A port that
is a JSON integer from 0 to 511, or a string of digits that int() reads as one, is still written,
as the int. An integer dpid the proxy does not know is still 404.

These tests drive the real handlers, the real TopologyManager and the real P4RuntimeClient over a
recording stub (the client of tests/test_p4_client_writes.py), so a refusal issued after the write
would show as a request on the stub. The last class sends raw requests through the real router
with a hand-made ASGI call (TestClient needs httpx, which this venv does not have) so that the
response is rendered by FastAPI itself, where a NaN in a body would turn into a 500.

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
    from fastapi import FastAPI, HTTPException

    from proxy_agent import api_routes
    from proxy_agent.topology_manager import TopologyManager
    from tests.test_p4_client_writes import RecordingStub, a_client

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False

LPM = '{"nw_dst": "10.0.0.4"}'
FIVE = '{"nw_dst": "10.0.0.4", "ip_proto": 6}'
#: (table, match, the priority a modify of that table can name). A destination-only modify names
#: no priority: ipv4_lpm has no priority column and refuses a named one (501).
TABLES = (("ipv4_lpm", LPM, None), ("flow_5tuple", FIVE, "100"))
HANDLERS = (("add", "add_flow_entry", "installed"), ("delete", "delete_flow_entry", "deleted"),
            ("modify", "modify_flow_entry", "modified"))

#: Literals as a client writes them. `80.0` and `1e0` are floats once parsed.
WIRE_BOOLS = ("true", "false")
WIRE_FLOATS = ("1.5", "80.0", "1e0", "2.0", "0.0", "-0.0", "NaN", "Infinity", "-Infinity", "1e400")


def raw_body(match, actions, priority, dpid="1"):
    parts = ['"dpid": %s' % dpid, '"match": %s' % match, '"actions": %s' % actions]
    if priority is not None:
        parts.append('"priority": %s' % priority)
    return "{" + ", ".join(parts) + "}"


def output(port):
    return '[{"type": "OUTPUT", "port": %s}]' % port


class WireRequest:
    def __init__(self, text):
        self._text = text

    async def json(self):
        return json.loads(self._text)


def answer(handler_name, text):
    """(status, detail-or-body) of a handler given the request as text, as a client sends it."""
    try:
        got = asyncio.run(getattr(api_routes, handler_name)(WireRequest(text)))
    except HTTPException as exc:
        return exc.status_code, exc.detail
    if isinstance(got, dict):
        return 200, got
    return got.status_code, json.loads(got.body)


class _Base(unittest.TestCase):
    def setUp(self):
        self.stub = RecordingStub()
        self.topo = TopologyManager()
        self.topo.add_switch(1, a_client(self.stub))
        api_routes.topology = self.topo

    def tearDown(self):
        api_routes.topology = None

    def message_of(self, detail):
        """The sentence of a refusal, whichever shape the verb answers it in: an add's body
        keeps its old `message` and puts the sentence in `reason`; the others use `message`."""
        return detail["reason"] if "reason" in detail else detail["message"]


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class AnOutputPortTheSwitchCannotHoldTest(_Base):
    """add and modify, on both tables. A delete does not read the port."""

    WRITERS = tuple(h for h in HANDLERS if h[0] != "delete")

    def refused(self, port_texts, kind=None, shown=None):
        for table, match, priority in TABLES:
            for verb, handler, past in self.WRITERS:
                for text in port_texts:
                    with self.subTest(table=table, verb=verb, port=text):
                        status, detail = answer(
                            handler, raw_body(match, output(text), priority))
                        self.assertEqual(status, 400)
                        self.assertEqual(detail["error"], "malformed action")
                        message = self.message_of(detail)
                        self.assertIn("the OUTPUT action's port is ", message)
                        self.assertIn("not a switch port number from 0 to 511 ", message)
                        self.assertIn("Nothing was " + ("written" if verb == "add" else past),
                                      message)
                        if kind:
                            self.assertIn(f"port is {kind},", message)
                        if shown:
                            self.assertIn(f"port is {shown},", message)
        self.assertEqual(self.stub.requests, [], "a refused port reached the wire")

    def test_a_json_boolean_port_is_refused_with_400_on_add_and_modify_on_both_tables(self):
        self.refused(WIRE_BOOLS, kind="a bool")

    def test_a_json_float_port_is_refused_with_400_on_add_and_modify_on_both_tables(self):
        self.refused(WIRE_FLOATS, kind="a float")

    def test_a_port_the_nine_bit_parameter_cannot_hold_is_refused_with_400(self):
        # 512 to 65535 fit the two bytes it is sent in and used to be installed (512 as 0x0200);
        # the rest, and a negative number, were a 500.
        for text in ("512", "513", "65535", "65536", "70000", "-1", '"512"', '"-1"'):
            # A number is shown as itself, a string between quotes: the literal as sent.
            self.refused((text,), shown=text)

    def test_a_port_that_is_no_number_is_refused_with_400(self):
        self.refused(('"abc"', '""', '"3.5"', '"1.2.3.4"', "[3]", "[]", "{}", '{"a": 1}'))

    def test_the_largest_port_is_511_and_the_message_says_so(self):
        status, detail = answer("modify_flow_entry",
                                raw_body(FIVE, output("512"), "100"))
        self.assertEqual(status, 400)
        self.assertIn("from 0 to 511 (the port is 9 bits wide)", self.message_of(detail))
        self.assertIn("port is 512,", self.message_of(detail))

    def test_a_port_that_is_an_integer_or_a_string_of_digits_is_written_as_that_port(self):
        # The control: the same switch, the same request, a port the parameter can hold. The
        # bytes are written out, not computed by the writer.
        cases = (("0", b"\x00\x00"), ("3", b"\x00\x03"), ("511", b"\x01\xff"),
                 ('"3"', b"\x00\x03"), ('" 3 "', b"\x00\x03"), ('"+3"', b"\x00\x03"),
                 ('"0_3"', b"\x00\x03"), ('"511"', b"\x01\xff"))
        for table, match, priority in TABLES:
            for verb, handler, _ in self.WRITERS:
                for text, expected in cases:
                    with self.subTest(table=table, verb=verb, port=text):
                        before = len(self.stub.requests)
                        status, _ = answer(handler, raw_body(match, output(text), priority))
                        self.assertEqual(status, 200)
                        self.assertEqual(len(self.stub.requests), before + 1)
                        entry = self.stub.requests[-1].updates[0].entity.table_entry
                        self.assertEqual(entry.action.action.params[-1].value, expected)

    def test_every_output_action_is_checked_not_only_the_last(self):
        for table, match, priority in TABLES:
            for verb, handler, _ in self.WRITERS:
                for actions in (
                        '[{"type": "OUTPUT", "port": 1.5}, {"type": "OUTPUT", "port": 3}]',
                        '[{"type": "OUTPUT", "port": 3}, {"type": "OUTPUT", "port": true}]'):
                    with self.subTest(table=table, verb=verb, actions=actions):
                        status, detail = answer(handler, raw_body(match, actions, priority))
                        self.assertEqual(status, 400)
                        self.assertEqual(detail["error"], "malformed action")
        self.assertEqual(self.stub.requests, [])

    def test_a_delete_does_not_read_the_output_port(self):
        # Unchanged: the delete names the entry by its match and ignores the actions.
        for table, match, priority in TABLES:
            for text in ("true", "1.5", "512", '"abc"'):
                with self.subTest(table=table, port=text):
                    status, _ = answer("delete_flow_entry",
                                       raw_body(match, output(text), priority))
                    self.assertEqual(status, 200)

    def test_a_port_that_is_absent_or_null_is_still_the_answer_for_no_output_action(self):
        # Unchanged: not a bad port, no port. 501 on both verbs, nothing written.
        for table, match, priority in TABLES:
            for verb, handler, _ in self.WRITERS:
                for actions in ('[{"type": "OUTPUT"}]', output("null")):
                    with self.subTest(table=table, verb=verb, actions=actions):
                        status, _ = answer(handler, raw_body(match, actions, priority))
                        self.assertEqual(status, 501)
        self.assertEqual(self.stub.requests, [])


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class APriorityOrADpidThatIsNotAnIntegerTest(_Base):
    """The proxy called straight, as the kernel never does: it sends an integer in both."""

    def refused(self, field, texts, kind):
        for table, match, priority in TABLES:
            for verb, handler, past in HANDLERS:
                for text in texts:
                    with self.subTest(field=field, table=table, verb=verb, value=text):
                        if field == "priority":
                            body = raw_body(match, output("3"), text)
                        else:
                            body = raw_body(match, output("3"), priority, dpid=text)
                        status, detail = answer(handler, body)
                        self.assertEqual(status, 400)
                        self.assertEqual(detail["error"], f"malformed {field}")
                        self.assertEqual(detail["fields"], [field])
                        self.assertIn(f"{field} is {kind}, which is not a JSON integer",
                                      detail["message"])
                        self.assertIn("No rule was " + past, detail["message"])
        self.assertEqual(self.stub.requests, [], "a refused number reached the wire")

    def test_a_json_boolean_priority_is_refused_with_400_on_every_verb_and_table(self):
        self.refused("priority", WIRE_BOOLS, "a bool")

    def test_a_json_float_priority_is_refused_with_400_on_every_verb_and_table(self):
        self.refused("priority", WIRE_FLOATS, "a float")

    def test_a_json_boolean_dpid_is_refused_with_400_on_every_verb_and_table(self):
        self.refused("dpid", WIRE_BOOLS, "a bool")

    def test_a_json_float_dpid_is_refused_with_400_on_every_verb_and_table(self):
        # 1.0 is the switch the proxy knows: equal to 1, so a dict lookup used to find it.
        self.refused("dpid", WIRE_FLOATS, "a float")

    def test_the_message_never_carries_the_value_of_a_float(self):
        for text in ("NaN", "Infinity", "80.5"):
            for field, body in (("priority", raw_body(FIVE, output("3"), text)),
                                ("dpid", raw_body(FIVE, output("3"), "100", dpid=text))):
                with self.subTest(field=field, value=text):
                    _, detail = answer("add_flow_entry", body)
                    self.assertNotIn(text.lower(), json.dumps(detail).lower())

    def test_an_integer_dpid_the_proxy_does_not_know_is_still_404(self):
        for verb, handler, _ in HANDLERS:
            for table, match, priority in TABLES:
                for dpid in ("2", "99", "0", "-1"):
                    with self.subTest(verb=verb, table=table, dpid=dpid):
                        status, _ = answer(handler, raw_body(match, output("3"), priority,
                                                             dpid=dpid))
                        self.assertEqual(status, 404)
        self.assertEqual(self.stub.requests, [])

    def test_an_integer_a_string_or_no_priority_is_not_refused_here(self):
        # The refusal is the type, not the value: a string, a negative number and null are
        # read as they always were (this change does not narrow them).
        for verb, handler, _ in HANDLERS:
            for text in ("0", "100", "-1", "65536", '"100"', "null", None):
                with self.subTest(verb=verb, priority=text):
                    status, _ = answer(handler, raw_body(FIVE, output("3"), text))
                    self.assertEqual(status, 200)


class _AsgiAnswer:
    def __init__(self, status, body):
        self.status = status
        self.body = body


def asgi_post(app, path, raw):
    """One POST through the whole app, no TestClient: (status, body bytes). A 500 is a status."""
    sent = []
    delivered = []

    async def receive():
        if not delivered:
            delivered.append(True)
            return {"type": "http.request", "body": raw, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "POST",
             "path": path, "raw_path": path.encode(), "query_string": b"", "root_path": "",
             "scheme": "http", "server": ("testserver", 80), "client": ("testclient", 5000),
             "headers": [(b"content-type", b"application/json"),
                         (b"content-length", str(len(raw)).encode())]}
    try:
        asyncio.run(app(scope, receive, send))
    except Exception as exc:  # noqa: BLE001 -- the server answers 500 and the test client re-raises
        return _AsgiAnswer(500, repr(exc).encode())
    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    return _AsgiAnswer(status, body)


def strict_json(body):
    def refuse(token):
        raise ValueError("a body carries the non-JSON token " + token)
    return json.loads(body, parse_constant=refuse)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ARefusalIsRenderedByTheRealAppAsAnHonestFourHundredTest(_Base):
    """
    NaN, Infinity and 1e400 are floats after json.loads, and Starlette renders a body with
    allow_nan=False: a refusal that carried the value back would turn into a 500 at that step,
    after the handler had answered. The handlers are called directly everywhere else, which never
    renders anything.
    """

    PATHS = ("/stats/flowentry/add", "/stats/flowentry/delete", "/stats/flowentry/delete_strict",
             "/stats/flowentry/modify")

    def setUp(self):
        super().setUp()
        self.app = FastAPI()
        self.app.include_router(api_routes.router)

    def post(self, path, text):
        return asgi_post(self.app, path, text.encode())

    def test_every_non_integer_number_this_proxy_reads_is_a_400_with_a_strict_json_body(self):
        nums = ("NaN", "Infinity", "-Infinity", "1e400", "80.0", "true")
        for path in self.PATHS:
            for num in nums:
                for label, body in (
                        ("in_port", raw_body('{"nw_dst": "10.0.0.4", "in_port": %s}' % num,
                                             output("3"), "100")),
                        ("tp_dst", raw_body('{"nw_dst": "10.0.0.4", "tp_dst": %s}' % num,
                                            output("3"), "100")),
                        ("ip_proto", raw_body('{"nw_dst": "10.0.0.4", "ip_proto": %s}' % num,
                                              output("3"), "100")),
                        ("port", raw_body(FIVE, output(num), "100")),
                        ("priority", raw_body(FIVE, output("3"), num)),
                        ("dpid", raw_body(FIVE, output("3"), "100", dpid=num))):
                    if label == "port" and "delete" in path:
                        continue  # a delete does not read the port
                    with self.subTest(path=path, field=label, value=num):
                        got = self.post(path, body)
                        self.assertEqual(got.status, 400, got.body[:200])
                        strict_json(got.body)  # no NaN / Infinity token in what was sent back
        self.assertEqual(self.stub.requests, [], "a refused number reached the wire")

    def test_the_same_requests_with_integers_are_a_200_through_the_app(self):
        # The control: a harness that answered 400 to everything would pass the test above.
        for path in ("/stats/flowentry/add", "/stats/flowentry/modify"):
            with self.subTest(path=path):
                got = self.post(path, raw_body(FIVE, output("3"), "100"))
                self.assertEqual(got.status, 200, got.body[:200])
        self.assertEqual(len(self.stub.requests), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
