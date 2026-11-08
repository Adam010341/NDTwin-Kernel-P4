"""
A protocol or L4 port the 5-tuple key cannot hold is the caller's error on every write endpoint.

[Co-developed with claude code -- Adam]

flow_5tuple's protocol key is bit<8> and its two L4 port keys are bit<16>. A value that is not a
number ("abc", "80.5") made `int(value)` raise ValueError inside the 5-tuple encoder, and one that
does not fit (256 for a protocol, 65536 for a port, -1 for either) made `to_bytes` raise
OverflowError. Both are raised while the request is built, which is before any of the three verbs'
try blocks, and api_routes catches only the proxy's own refusal classes -- so, unchecked, add,
delete and modify all answered **500**. `topology_manager.check_match_values` now runs the real
encoder over every spelling of those keys first, as it does for in_port, so the answer is a 400
that names the field and the switch is not written.

The control is the other half: a value the encoder took before is still taken, and goes out as the
same bytes. The bytes are written out below, not computed by the encoder, so a change to the
encoder's output cannot agree with itself.

These tests drive the real handlers, the real TopologyManager and the real P4RuntimeClient over a
recording stub (the client of tests/test_p4_client_writes.py), so a refusal that is issued after
the write would show as a request on the stub.

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
    from fastapi import HTTPException

    from proxy_agent import api_routes
    from proxy_agent.topology_manager import (
        FIVE_TUPLE_FIELD_MAP, MalformedMatchValueError, TopologyManager, check_match_values)
    from tests.test_p4_client_writes import RecordingStub, a_client

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False


class FakeRequest:
    def __init__(self, body):
        self._raw = json.dumps(body).encode()

    async def json(self):
        return json.loads(self._raw)


#: (the spellings of one key, the flow_5tuple match-field id in the p4info, the key's largest
#: value, what the message calls the number). The widths are bit<8> / bit<16> / bit<16> in
#: ndtwin_switch.p4; they are written out here on purpose, so a width that moves in the code
#: moves a test with it.
FAMILIES = (
    (("ip_proto", "nw_proto"), 4, 255, "a protocol number"),
    (("tp_src", "tcp_src", "udp_src"), 5, 65535, "a port number"),
    (("tp_dst", "tcp_dst", "udp_dst"), 6, 65535, "a port number"),
)
ALL_SPELLINGS = tuple(f for spellings, _, _, _ in FAMILIES for f in spellings)


def refused_values(largest):
    """What the encoder rejects for a key whose largest value is `largest`."""
    # "a.b" and "1.2.3.4.5" are dotted strings inet_aton cannot read (OSError); "80.5" and
    # "1.2.3.4" it reads as four bytes, which no key here takes (ValueError).
    return ("abc", largest + 1, -1, "80.5", "-1", str(largest + 1), "", None, 2.5e30,
            "1.2.3.4", "a.b", "1.2.3.4.5", [], {})


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class AnL4ValueTheKeyCannotHoldTest(unittest.TestCase):
    HANDLERS = (("add", "add_flow_entry", True), ("delete", "delete_flow_entry", False),
                ("modify", "modify_flow_entry", True))

    def setUp(self):
        self.stub = RecordingStub()
        self.topo = TopologyManager()
        self.topo.add_switch(1, a_client(self.stub))
        api_routes.topology = self.topo

    def tearDown(self):
        api_routes.topology = None

    def body(self, field, value):
        return {"dpid": 1, "match": {field: value, "nw_dst": "10.0.0.4"},
                "actions": [{"type": "OUTPUT", "port": 3}], "priority": 100}

    def call(self, handler_name, field, value, dpid=1):
        body = self.body(field, value)
        body["dpid"] = dpid
        return asyncio.run(getattr(api_routes, handler_name)(FakeRequest(body)))

    # --- the refusal ------------------------------------------------------------------------

    def test_every_spelling_answers_400_on_every_verb_for_a_value_the_key_cannot_hold(self):
        for spellings, _, largest, noun in FAMILIES:
            for field in spellings:
                for verb, handler, _ in self.HANDLERS:
                    for bad in refused_values(largest):
                        with self.subTest(field=field, verb=verb, value=bad):
                            with self.assertRaises(HTTPException) as caught:
                                self.call(handler, field, bad)
                            self.assertEqual(caught.exception.status_code, 400)
                            detail = caught.exception.detail
                            self.assertEqual(detail["fields"], [field])
                            self.assertIn(f"match field {field} ", detail["message"])
                            self.assertIn(f"{noun} from 0 to {largest} ", detail["message"])
                            self.assertIn("No rule was", detail["message"])

    def test_the_switch_is_not_written_for_any_refused_l4_value(self):
        for spellings, _, largest, _ in FAMILIES:
            for field in spellings:
                for verb, handler, _ in self.HANDLERS:
                    for bad in refused_values(largest):
                        with self.subTest(field=field, verb=verb, value=bad):
                            with self.assertRaises(HTTPException):
                                self.call(handler, field, bad)
        self.assertEqual(self.stub.requests, [], "a refused L4 value reached the wire")

    def test_a_bad_port_on_a_rule_with_no_output_action_is_400_and_writes_nothing(self):
        # An add or modify with "actions": [] is the 5-tuple drop path, which builds its keys
        # without the OUTPUT branch; the check runs ahead of it as well.
        for handler in ("add_flow_entry", "delete_flow_entry", "modify_flow_entry"):
            for field, bad in (("tp_dst", 70000), ("udp_src", "abc"), ("ip_proto", 256),
                               ("nw_proto", "a.b")):
                with self.subTest(handler=handler, field=field, value=bad):
                    body = self.body(field, bad)
                    body["actions"] = []
                    with self.assertRaises(HTTPException) as caught:
                        asyncio.run(getattr(api_routes, handler)(FakeRequest(body)))
                    self.assertEqual(caught.exception.status_code, 400)
                    self.assertEqual(caught.exception.detail["fields"], [field])
        self.assertEqual(self.stub.requests, [])

    def test_the_message_names_the_value_that_was_sent_and_the_action_that_did_not_happen(self):
        expected_action = {"add_flow_entry": "installed", "delete_flow_entry": "deleted",
                           "modify_flow_entry": "modified"}
        for handler, action in expected_action.items():
            with self.subTest(handler=handler):
                with self.assertRaises(HTTPException) as caught:
                    self.call(handler, "tp_dst", 70000)
                message = caught.exception.detail["message"]
                self.assertIn("70000", message)
                self.assertIn("No rule was " + action, message)
                self.assertNotIn("IPv4", message)
        with self.assertRaises(HTTPException) as caught:
            self.call("add_flow_entry", "ip_proto", "abc")
        self.assertIn('carries "abc"', caught.exception.detail["message"])

    def test_the_bad_field_is_the_one_named_when_a_good_one_sits_beside_it(self):
        body = {"dpid": 1,
                "match": {"nw_dst": "10.0.0.4", "ip_proto": 6, "tp_src": 1234, "tp_dst": 70000},
                "actions": [{"type": "OUTPUT", "port": 3}], "priority": 100}
        for handler in ("add_flow_entry", "delete_flow_entry", "modify_flow_entry"):
            with self.subTest(handler=handler):
                with self.assertRaises(HTTPException) as caught:
                    asyncio.run(getattr(api_routes, handler)(FakeRequest(body)))
                self.assertEqual(caught.exception.status_code, 400)
                self.assertEqual(caught.exception.detail["fields"], ["tp_dst"])
        self.assertEqual(self.stub.requests, [])

    def test_the_check_itself_raises_the_proxys_own_refusal_for_each_spelling(self):
        # The same refusal one layer down, without the handler, so a handler that happened to
        # swallow the wrong exception would not hide a check that stopped raising.
        for spellings, _, largest, noun in FAMILIES:
            for field in spellings:
                for bad in ("abc", largest + 1, -1, "80.5"):
                    with self.subTest(field=field, value=bad):
                        with self.assertRaises(MalformedMatchValueError) as caught:
                            check_match_values({field: bad}, "installed")
                        self.assertEqual(caught.exception.fields, [field])
                        self.assertIn(f"{noun} from 0 to {largest} ", str(caught.exception))

    def test_a_read_only_client_answers_400_for_a_bad_value_and_still_409_for_a_good_one(self):
        # Ahead of the writer's own refusals, as the address and in_port checks are.
        stub = RecordingStub()
        client = a_client(stub)
        client.arbitration = False
        self.topo.add_switch(2, client)
        for verb, handler, _ in self.HANDLERS:
            for value, status in (("abc", 400), (65536, 400), (80, 409)):
                with self.subTest(verb=verb, value=value):
                    with self.assertRaises(HTTPException) as caught:
                        self.call(handler, "tp_dst", value, dpid=2)
                    self.assertEqual(caught.exception.status_code, status)
        self.assertEqual(stub.requests, [])

    # --- the spellings the check covers ------------------------------------------------------

    def test_the_check_covers_exactly_the_eight_protocol_and_port_spellings(self):
        from proxy_agent.topology_manager import (
            IN_PORT_MATCH_FIELDS, IPV4_VALUED_MATCH_FIELDS, L4_VALUED_MATCH_FIELDS)
        self.assertEqual(set(L4_VALUED_MATCH_FIELDS), set(ALL_SPELLINGS))
        self.assertEqual(len(ALL_SPELLINGS), 8)
        # Nothing numeric in the table is left to a third, unchecked, group.
        self.assertEqual(set(FIVE_TUPLE_FIELD_MAP),
                         set(L4_VALUED_MATCH_FIELDS) | set(IN_PORT_MATCH_FIELDS)
                         | set(IPV4_VALUED_MATCH_FIELDS))

    # --- control: what was accepted is still accepted, as the same bytes ---------------------

    def sent(self):
        entry = self.stub.requests[-1].updates[0].entity.table_entry
        return {m.field_id: (m.ternary.value, m.ternary.mask) for m in entry.match}

    def test_in_range_values_still_install_on_every_verb(self):
        for spellings, _, largest, _ in FAMILIES:
            for field in spellings:
                for verb, handler, answers_success in self.HANDLERS:
                    for good in (0, 6, largest, str(largest), "17"):
                        with self.subTest(field=field, verb=verb, value=good):
                            before = len(self.stub.requests)
                            answer = self.call(handler, field, good)
                            if answers_success:
                                self.assertEqual(answer["status"], "success")
                            self.assertEqual(len(self.stub.requests), before + 1,
                                             "an in-range value did not reach the switch")

    def test_in_range_values_go_out_as_the_same_bytes_as_before(self):
        # (key, value as sent) -> (value bytes, mask bytes) as the encoder put them on the wire
        # before the check existed. A string reads as the number it spells.
        cases = (
            ("ip_proto", 6, 4, b"\x06", b"\xff"),
            ("nw_proto", "17", 4, b"\x11", b"\xff"),
            ("ip_proto", 255, 4, b"\xff", b"\xff"),
            ("ip_proto", 0, 4, b"\x00", b"\xff"),
            ("tp_src", 80, 5, b"\x00\x50", b"\xff\xff"),
            ("tcp_src", "8080", 5, b"\x1f\x90", b"\xff\xff"),
            ("udp_src", 65535, 5, b"\xff\xff", b"\xff\xff"),
            ("tp_dst", 80, 6, b"\x00\x50", b"\xff\xff"),
            ("tcp_dst", "8080", 6, b"\x1f\x90", b"\xff\xff"),
            ("udp_dst", 0, 6, b"\x00\x00", b"\xff\xff"),
        )
        for field, value, field_id, value_bytes, mask_bytes in cases:
            with self.subTest(field=field, value=value):
                self.call("add_flow_entry", field, value)
                self.assertEqual(self.sent()[field_id], (value_bytes, mask_bytes))

    def test_what_int_reads_stays_accepted_a_bool_a_float_and_a_padded_digit_string(self):
        # Kept exactly as the encoder took them before: a bool is an int in Python (True is 1), a
        # float is truncated, and int() trims blanks and reads a sign and underscores. Pinned so
        # that narrowing the set is a decision and not an accident.
        cases = ((True, b"\x01"), (False, b"\x00"), (6.0, b"\x06"), (6.9, b"\x06"),
                 (" 6 ", b"\x06"), ("+6", b"\x06"), ("0_6", b"\x06"), ("-0", b"\x00"))
        for value, value_bytes in cases:
            with self.subTest(value=value):
                self.call("add_flow_entry", "ip_proto", value)
                self.assertEqual(self.sent()[4], (value_bytes, b"\xff"))
        self.assertIsNone(check_match_values({"tp_dst": True, "ip_proto": 6.0}, "installed"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
