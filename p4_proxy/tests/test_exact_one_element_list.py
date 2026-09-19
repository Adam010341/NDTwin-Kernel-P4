"""
An EXACT match value written as a one-element list. TICKET-P3 section 9 ruling 23②.

[Co-developed with claude code -- Adam]

🔴 THIS WAS FOUND BY A LIVE RUN, NOT BY A TEST, and the reason is worth writing down: every
fixture this repository had for the table-entry writer was one somebody wrote while reading the
writer. The upstream exercises are the actual input, and `p4lang/tutorials`'
`basic_tunnel/sX-runtime.json` spells an exact-match value as `"hdr.myTunnel.dst_id": [1]` --
a one-element list. The reference controller those exercises are written against unwraps it:

    /home/adam/tutorials/utils/p4runtime_lib/convert.py:71-75

        def encode(x, bitwidth):
            'Tries to infer the type of `x` and encode it'
            byte_len = bitwidthToBytes(bitwidth)
            if (type(x) == list or type(x) == tuple) and len(x) == 1:
                x = x[0]

so `switch.WriteTableEntry` accepts those three entries and this proxy refused them. Live
evidence (`scratch/overnight-2026-09-05/logs/orchestrator-0919/probe2-basic_tunnel-proxy.log`),
three of six entries on every switch:

    [Proxy Agent] switch 1: table entry 3 into MyIngress.myTunnel_exact was NOT applied --
    TableEntryInvalid: MyIngress.myTunnel_exact.hdr.myTunnel.dst_id is an EXACT match, so its
    value is a plain value, not the pair [1]

A refusal, so nothing was silently wrong -- but the fabric came up forwarding half the exercise,
and `basic_tunnel/solution` failed in both live passes.

🔴 THE TWO-ELEMENT CASE IS STILL REFUSED, and that is not symmetry for its own sake: `[value,
prefix_len]` is the LPM shape and `[value, mask]` the ternary one. Accepting either on an EXACT
field would take a rule meant to match a subnet and install it as a rule matching one address --
which forwards, and blackholes everything else, with no error anywhere.

The subject is the REAL runtime file and the REAL compiled p4info, copied byte-for-byte out of
~/tutorials into tools/p4_exercise/tests/fixtures/basic_tunnel/.

Run with:  p4_proxy/venv/bin/python -m unittest tests.test_exact_one_element_list
"""

from __future__ import annotations

import json
import os
import queue
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2
    from google.protobuf import text_format

    from proxy_agent.p4_client import P4RuntimeClient, TableEntryInvalid
    from proxy_agent.rule_install_times import RuleInstallTimes
    from proxy_agent.sflow_emitter import (TelemetryHeaderMissing, packet_in_metadata_ids,
                                           packet_out_metadata_ids)

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE = os.path.join(REPO_ROOT, "tools", "p4_exercise", "tests", "fixtures", "basic_tunnel")
RUNTIME_JSON = os.path.join(FIXTURE, "s1-runtime.json")
P4INFO = os.path.join(FIXTURE, "build", "basic_tunnel.p4.p4info.txtpb")

#: The upstream helper this proxy has to agree with, quoted where a reader can check it.
UPSTREAM_ENCODE = "/home/adam/tutorials/utils/p4runtime_lib/convert.py:71-75"


def the_real_entries():
    """The six entries `basic_tunnel/s1-runtime.json` ships, in file order."""
    with open(RUNTIME_JSON) as fh:
        return json.load(fh)["table_entries"]


def the_real_p4info():
    p4info = p4info_pb2.P4Info()
    with open(P4INFO) as fh:
        text_format.Merge(fh.read(), p4info)
    return p4info


class RecordingStub:
    def __init__(self):
        self.requests = []

    def Write(self, request, timeout=None):
        self.requests.append(request)


def a_client(stub=None):
    """A client with no gRPC channel, holding basic_tunnel's own compiled p4info."""
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = 1
    client.grpc_addr = "127.0.0.1:50051"
    client.p4info = the_real_p4info()
    client.stub = stub if stub is not None else RecordingStub()
    client.packet_in_callback = None
    client.sample_callback = None
    client.is_running = False
    client.stream_recv_thread = None
    client.stream_out_q = queue.Queue()
    client.rule_install_times = RuleInstallTimes()
    client._last_table_read = None
    client.election_id = (0, 1)
    client.arbitration = True
    try:
        client.packet_in_ids = packet_in_metadata_ids(client.p4info)
        client.packet_in_ids_error = None
    except TelemetryHeaderMissing as exc:
        client.packet_in_ids = None
        client.packet_in_ids_error = str(exc)
    client.packet_out_ids = packet_out_metadata_ids(client.p4info)
    return client


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheFixtureIsTheUpstreamFileTest(unittest.TestCase):
    """If this stops being the exercise's own file, everything below is about nothing."""

    def test_it_has_six_entries_three_of_them_exact_in_a_list(self):
        entries = the_real_entries()
        self.assertEqual(len(entries), 6)
        wrapped = [e for e in entries
                   if e["table"] == "MyIngress.myTunnel_exact"
                   and isinstance(e["match"]["hdr.myTunnel.dst_id"], list)]
        self.assertEqual(len(wrapped), 3)
        self.assertEqual([e["match"]["hdr.myTunnel.dst_id"] for e in wrapped],
                         [[1], [2], [3]])

    def test_the_exact_field_really_is_EXACT_in_the_compiled_p4info(self):
        # The refusal was about the MATCH TYPE, so the fixture has to state it. A p4info in
        # which this field were ternary would make the acceptance below a different claim.
        table = [t for t in the_real_p4info().tables
                 if t.preamble.name == "MyIngress.myTunnel_exact"][0]
        field = table.match_fields[0]
        self.assertEqual(field.name, "hdr.myTunnel.dst_id")
        self.assertEqual(p4info_pb2.MatchField.MatchType.Name(field.match_type), "EXACT")
        self.assertEqual(field.bitwidth, 16)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheProxyAcceptsWhatTheExerciseWritesTest(unittest.TestCase):
    def setUp(self):
        self.stub = RecordingStub()
        self.client = a_client(self.stub)

    def test_all_six_of_basic_tunnels_entries_go_on(self):
        # 🔴 THE RED THIS FIX IS FOR. On the code before it, three of these raise
        # TableEntryInvalid and `stub.requests` ends at 3.
        for index, entry in enumerate(the_real_entries()):
            with self.subTest(entry=index, table=entry["table"]):
                self.client.write_table_entry(entry, "insert")
        self.assertEqual(len(self.stub.requests), 6,
                         "every entry the upstream exercise ships must reach the switch")

    def test_the_unwrapped_value_is_the_number_and_not_the_list(self):
        # Unwrapping is only correct if what goes on the wire is the VALUE. A one-element list
        # encoded as something else would be accepted here and refused by bmv2 -- or worse,
        # accepted by bmv2 as a tunnel id nobody asked for.
        entry = [e for e in the_real_entries()
                 if e["match"].get("hdr.myTunnel.dst_id") == [2]][0]
        self.client.write_table_entry(entry, "insert")
        written = self.stub.requests[0].updates[0].entity.table_entry
        self.assertEqual(len(written.match), 1)
        self.assertEqual(written.match[0].exact.value, (2).to_bytes(2, "big"))

    def test_a_plain_value_is_unchanged(self):
        # The shape that always worked, asserted beside the new one so the fix cannot have
        # moved it.
        entry = dict(the_real_entries()[3])
        entry["match"] = {"hdr.myTunnel.dst_id": 2}
        self.client.write_table_entry(entry, "insert")
        written = self.stub.requests[0].updates[0].entity.table_entry
        self.assertEqual(written.match[0].exact.value, (2).to_bytes(2, "big"))

    def test_a_one_element_tuple_is_unwrapped_too(self):
        # `encode` accepts `list` or `tuple`; a runtime file cannot carry a tuple, but a caller
        # of POST /p4/table_entry through a Python client can.
        entry = dict(the_real_entries()[3])
        entry["match"] = {"hdr.myTunnel.dst_id": (2,)}
        self.client.write_table_entry(entry, "insert")
        written = self.stub.requests[0].updates[0].entity.table_entry
        self.assertEqual(written.match[0].exact.value, (2).to_bytes(2, "big"))

    def test_a_one_element_list_holding_an_address_is_unwrapped_too(self):
        # The unwrap happens BEFORE the type is inferred, exactly as upstream's does -- so a
        # string inside the list is still read as a MAC or an address rather than as an integer
        # literal that fails to parse.
        table = self.client.p4info.tables.add()
        table.preamble.id = 900000009
        table.preamble.name = "Synthetic.mac_exact"
        table.preamble.alias = "mac_exact"
        field = table.match_fields.add()
        field.id = 1
        field.name = "hdr.ethernet.dstAddr"
        field.bitwidth = 48
        field.match_type = p4info_pb2.MatchField.EXACT
        self.client.write_table_entry(
            {"table": "Synthetic.mac_exact",
             "match": {"hdr.ethernet.dstAddr": ["08:00:00:00:01:11"]},
             # basic_tunnel's own action, so the entry is refused for the shape under test or
             # for nothing at all -- an entry with no action is refused a step earlier.
             "action_name": "MyIngress.myTunnel_forward",
             "action_params": {"port": 1}}, "insert")
        written = self.stub.requests[0].updates[0].entity.table_entry
        self.assertEqual(written.match[0].exact.value,
                         bytes.fromhex("080000000111"))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheRefusalsThatStayTest(unittest.TestCase):
    """The control. Accepting one element must not become accepting a list."""

    def setUp(self):
        self.stub = RecordingStub()
        self.client = a_client(self.stub)

    def refused(self, value):
        entry = dict(the_real_entries()[3])
        entry["match"] = {"hdr.myTunnel.dst_id": value}
        with self.assertRaises(TableEntryInvalid) as caught:
            self.client.write_table_entry(entry, "insert")
        self.assertEqual(self.stub.requests, [], "a refusal must reach no switch")
        return str(caught.exception)

    def test_a_two_element_pair_on_an_exact_field_is_still_refused(self):
        # 🔴 `[value, prefix_len]` is the LPM shape. Taking it on an EXACT field would install a
        # rule matching one address where the author wrote one matching a subnet: it forwards,
        # and it blackholes everything else, with nothing erroring.
        message = self.refused([2, 16])
        self.assertIn("EXACT", message)
        self.assertIn("[2, 16]", message)

    def test_an_empty_list_is_refused(self):
        self.refused([])

    def test_a_three_element_list_is_refused(self):
        self.refused([1, 2, 3])

    def test_a_nested_one_element_list_is_refused(self):
        # One unwrap, not a loop. `[[1]]` is not something any exercise writes, and a recursive
        # unwrap would accept shapes upstream's own encode() rejects.
        self.refused([[1]])

    def test_the_message_still_names_the_shape_it_wanted(self):
        message = self.refused([2, 16])
        self.assertIn("hdr.myTunnel.dst_id", message)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheProxyAndPreFlightAgreeTest(unittest.TestCase):
    """
    One package, two readers, one answer. TICKET-P3 section 9 ruling 23② asks for this cell.

    [Co-developed with claude code -- Adam]
    `tools/p4_exercise/preflight.py` already accepted `[1]` on an EXACT field -- its live report
    for this package says "entries match p4info PASS" -- while the proxy refused it. That is the
    worst arrangement the two can be in: pre-flight is the thing an operator runs to be told
    whether `ndt up p4 --app` will work, so a package it passes and the proxy then half-applies
    is a green light followed by a fabric forwarding half an exercise.

    preflight is D's file and is NOT edited here; this test only asserts the two agree, and
    would say so loudly if they did not.
    """

    def setUp(self):
        tools = os.path.join(REPO_ROOT, "tools")
        if tools not in sys.path:
            sys.path.insert(0, tools)
        from p4_exercise import preflight
        self.preflight = preflight
        self.index = preflight.P4InfoIndex.parse(P4INFO)
        self.client = a_client()

    def proxy_accepts(self, entry):
        try:
            self.client.write_table_entry(entry, "insert")
            return True
        except Exception:  # noqa: BLE001 -- the question is accept/refuse, not which refusal
            return False

    def preflight_accepts(self, entry):
        return self.preflight.check_entry(entry, self.index, "s1") == []

    def test_both_accept_every_entry_the_exercise_ships(self):
        for index, entry in enumerate(the_real_entries()):
            with self.subTest(entry=index, table=entry["table"]):
                mine, theirs = self.proxy_accepts(entry), self.preflight_accepts(entry)
                self.assertTrue(theirs, "pre-flight refused an upstream entry")
                self.assertEqual(mine, theirs,
                                 "pre-flight and the proxy disagree about an entry the "
                                 "upstream exercise ships -- a green pre-flight followed by a "
                                 "half-applied fabric is the shape this cell exists to catch")

    def test_both_refuse_a_two_element_pair_on_an_exact_field(self):
        # The agreement has to hold in the refusing direction too, or "they agree" would be
        # satisfied by a pre-flight that accepts everything.
        entry = dict(the_real_entries()[3])
        entry["match"] = {"hdr.myTunnel.dst_id": [2, 16]}
        self.assertFalse(self.preflight_accepts(entry))
        self.assertFalse(self.proxy_accepts(entry))


if __name__ == "__main__":
    unittest.main(verbosity=2)
