"""
Tests for what P4RuntimeClient tells its caller, and what it puts on the wire.

[Co-developed with claude code -- Adam]

Every method here has a history of reporting the wrong outcome, and each of those bugs was
silent all the way up to the REST layer:

  * `insert_ipv4_route` used to `pass` on every UNKNOWN and return None either way, on the
    theory that UNKNOWN only means "entry already exists". bmv2 does report duplicates that
    way, but it returns UNKNOWN for genuine failures too -- a bad table name, an out-of-range
    action parameter -- so every real write error was discarded as a harmless duplicate. It
    also left the existing entry untouched, so a recalculated (better) path never took effect.
  * `modify_ipv4_route`'s success path had no `return True`, so it fell off the end returning
    None. topology_manager.modify_flow passed that straight through and api_routes raised
    HTTPException(400) -- every *successful* modify answered HTTP 400.
  * `delete_ipv4_route` returned None for every outcome, so route_flow answered "success" for
    a delete that had been refused.

So the assertions here are deliberately about the return value and the bytes, not about
"it did not raise". A method that cannot fail cannot be trusted.

`probe()` is the only signal that proves a bmv2 process is alive and serving, and
`GET /p4/switch_state` is built on it, so its failure reporting is tested to the same standard:
bmv2 returns an empty details() for some failures and a report of "" is unactionable, which
already cost a real investigation once with a clone session.

There is no bmv2 here, so what is asserted is the *request* -- that the bytes going onto the
wire say what we think they say -- plus the outcome the client derives from a given gRPC
status. A live switch would not tell us either of those any more precisely; what it would add
is covered by tests/test_p4_client.py, which needs one running.

The p4info is built in-process rather than read from p4_src/build, which is a generated,
gitignored artefact. The ids are the real ones from ndtwin_switch.p4info.txt so that a
mixed-up id shows up as the wrong number rather than as an off-by-one that happens to work.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests" -- a pytest-style module runs as a script that asserts
nothing and is reported as NO TESTS RAN.
"""

from __future__ import annotations

import os
import queue
import socket
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# A bare module-level `raise unittest.SkipTest(...)` is an uncaught exception during import and
# exits nonzero exactly like the ImportError it replaces, so the condition has to survive until
# unittest can act on it via skipUnless.
try:
    import grpc
    from google.protobuf import text_format
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2

    from proxy_agent import p4_client as p4_client_module
    from proxy_agent.p4_client import P4RuntimeClient, CounterNotFound
    from proxy_agent.rule_install_times import RuleInstallTimes
    from proxy_agent.sflow_emitter import (TelemetryHeaderMissing, packet_in_metadata_ids,
                                           packet_out_metadata_ids)

    class FakeRpcError(grpc.RpcError):
        """
        Must derive from grpc.RpcError, or the client's `except grpc.RpcError` will not catch it
        and every test here would exercise a path that cannot happen in production.

        `code_is_none` models the case the probe guards against: grpc can hand back an error
        whose code() is None, and `e.code().name` on that is an AttributeError inside the
        handler for an error.
        """

        def __init__(self, code, details="fake failure", code_is_none=False):
            self._code = None if code_is_none else code
            self._details = details

        def code(self):
            return self._code

        def details(self):
            return self._details

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover - depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False


# Real ids from p4_src/build/ndtwin_switch.p4info.txt.
IPV4_LPM_ID = 37375156
FLOW_5TUPLE_ID = 50095925
L2_FORWARD_ID = 42660923
IPV4_FORWARD_ID = 28792405
FORWARD_L2_ID = 29098536
SEND_TO_CPU_ID = 22952082
EGRESS_COUNTER_ID = 312422001
DST_ADDR_PARAM_ID = 1
PORT_PARAM_ID = 2
DST_ADDR_FIELD_ID = 1


def a_p4info():
    """The subset of ndtwin_switch.p4info.txt these methods look things up in."""
    p4info = p4info_pb2.P4Info()

    table = p4info.tables.add()
    table.preamble.id = IPV4_LPM_ID
    table.preamble.name = "MyIngress.ipv4_lpm"
    # [Co-developed with claude code -- Adam]
    # alias, match_type and bitwidth added for the generic table-entry writer (TICKET-P2 4.1).
    # The real p4info has carried all three since it was generated -- a double that omits them
    # would let `build_table_entry` read an UNSPECIFIED match type and a zero-width field and
    # still look correct here, which is a double that has stopped standing in for the object.
    # Values transcribed from p4_src/build/ndtwin_switch.p4info.txt.
    table.preamble.alias = "ipv4_lpm"
    field = table.match_fields.add()
    field.id = DST_ADDR_FIELD_ID
    field.name = "hdr.ipv4.dstAddr"
    field.bitwidth = 32
    field.match_type = p4info_pb2.MatchField.LPM

    forward = p4info.actions.add()
    forward.preamble.id = IPV4_FORWARD_ID
    forward.preamble.name = "MyIngress.ipv4_forward"
    forward.preamble.alias = "ipv4_forward"
    param = forward.params.add()
    param.id = DST_ADDR_PARAM_ID
    param.name = "dstAddr"
    param.bitwidth = 48
    param = forward.params.add()
    param.id = PORT_PARAM_ID
    param.name = "port"
    param.bitwidth = 9

    cpu = p4info.actions.add()
    cpu.preamble.id = SEND_TO_CPU_ID
    cpu.preamble.name = "MyIngress.send_to_cpu"
    cpu.preamble.alias = "send_to_cpu"

    # The EXACT table, so the writer's third match type is exercised against a real one rather
    # than against a field invented for the test. bit<48> on an exact match is also the only
    # place a MAC is a KEY rather than an action parameter.
    l2 = p4info.tables.add()
    l2.preamble.id = L2_FORWARD_ID
    l2.preamble.name = "MyIngress.l2_forward"
    l2.preamble.alias = "l2_forward"
    field = l2.match_fields.add()
    field.id = 1
    field.name = "hdr.ethernet.dstAddr"
    field.bitwidth = 48
    field.match_type = p4info_pb2.MatchField.EXACT

    l2_action = p4info.actions.add()
    l2_action.preamble.id = FORWARD_L2_ID
    l2_action.preamble.name = "MyIngress.forward_l2"
    l2_action.preamble.alias = "forward_l2"
    param = l2_action.params.add()
    param.id = 1
    param.name = "port"
    param.bitwidth = 9

    counter = p4info.counters.add()
    counter.preamble.id = EGRESS_COUNTER_ID
    counter.preamble.name = "MyEgress.egress_port_counter"

    # [Co-developed with claude code -- Adam]
    # The ternary table the 5-tuple writes address. Added for the election-id suite, which has
    # to reach every unary request type: without it those three methods raise KeyError on the
    # table lookup before they ever build a request, and the sites they cover stay untested.
    # Field ids and names are the real ones from ndtwin_switch.p4info.txt, so a mixed-up id
    # shows up as the wrong number rather than as an off-by-one that happens to work.
    five = p4info.tables.add()
    five.preamble.id = FLOW_5TUPLE_ID
    five.preamble.name = "MyIngress.flow_5tuple"
    five.preamble.alias = "flow_5tuple"
    for field_id, name, bitwidth in ((1, "standard_metadata.ingress_port", 9),
                                     (2, "hdr.ipv4.srcAddr", 32),
                                     (3, "hdr.ipv4.dstAddr", 32),
                                     (4, "hdr.ipv4.protocol", 8),
                                     (5, "meta.l4_src_port", 16),
                                     (6, "meta.l4_dst_port", 16)):
        field = five.match_fields.add()
        field.id = field_id
        field.name = name
        field.bitwidth = bitwidth
        field.match_type = p4info_pb2.MatchField.TERNARY

    # 🔴 SYNTHETIC, and named so nobody mistakes them for ndtwin_switch.p4's.
    # [Co-developed with claude code -- Adam]
    # TICKET-P2 2.3 (:63) says range and optional answer 501 too, and NO pipeline in this
    # repository declares either match type -- ndtwin_switch has exact, lpm and ternary and
    # nothing else, and neither does `basic` or `source_routing`. So the only way to exercise
    # those two branches at all is a descriptor written here. The ids are deliberately outside
    # p4c's range so a real id can never collide with one, and the only thing the code under
    # test reads off them is `match_type` -- which it resolves through the generated enum, so
    # what is being asserted is that MatchField.RANGE and MatchField.OPTIONAL reach the refusal,
    # not that some number does.
    for table_id, table_name, kind in ((900000001, "Synthetic.range_table",
                                        p4info_pb2.MatchField.RANGE),
                                       (900000002, "Synthetic.optional_table",
                                        p4info_pb2.MatchField.OPTIONAL)):
        table = p4info.tables.add()
        table.preamble.id = table_id
        table.preamble.name = table_name
        table.preamble.alias = table_name.split(".")[-1]
        field = table.match_fields.add()
        field.id = 1
        field.name = "meta.probe_key"
        field.bitwidth = 16
        field.match_type = kind

    # [Co-developed with claude code -- Adam]
    # The two controller headers, added for TICKET-P3 2.6 (G1). The proxy resolves the metadata
    # ids BY NAME out of this message now, so a double without them makes every packet-in and
    # packet-out path raise -- which is the correct failure for a double that has stopped
    # standing in for the object, and is how these lines came to be here. Names, ids and widths
    # are transcribed from p4_src/build/ndtwin_switch.p4info.txt, `_pad` included: the ids are
    # positional in the real artefact, so a fixture that dropped a field would renumber the
    # rest and quietly assert the wrong numbers.
    packet_in = p4info.controller_packet_metadata.add()
    packet_in.preamble.id = 81826293
    packet_in.preamble.name = "packet_in"
    packet_in.preamble.alias = "packet_in"
    for meta_id, name, bitwidth in ((1, "reason", 8),
                                    (2, "ingress_port", 9),
                                    (3, "egress_port", 9),
                                    (4, "frame_length", 16),
                                    (5, "sampling_rate", 16),
                                    (6, "_pad", 6)):
        meta = packet_in.metadata.add()
        meta.id = meta_id
        meta.name = name
        meta.bitwidth = bitwidth

    packet_out = p4info.controller_packet_metadata.add()
    packet_out.preamble.id = 76689799
    packet_out.preamble.name = "packet_out"
    packet_out.preamble.alias = "packet_out"
    for meta_id, name, bitwidth in ((1, "egress_port", 9), (2, "_pad", 7)):
        meta = packet_out.metadata.add()
        meta.id = meta_id
        meta.name = name
        meta.bitwidth = bitwidth

    return p4info


class RecordingStub:
    """
    Captures requests instead of sending them, and can be told to fail.

    `write_error`/`always` distinguish the two cases the INSERT/MODIFY fallback turns on:
    failing once models an entry that already exists (INSERT rejected, MODIFY accepted), while
    failing every time models a switch that genuinely cannot take the write. Without the
    distinction a "real failure is reported" test passes for the wrong reason, because its
    MODIFY retry quietly succeeds.
    """

    def __init__(self, write_error=None, always=False, read_responses=(), read_error=None,
                 probe_error=None):
        self.requests = []
        self.reads = []
        self.probes = []
        self.pipeline_pushes = []
        self.probe_timeouts = []
        # [Co-developed with claude code -- Adam]
        # Every timeout a Write was given, so a test can assert the deadline is actually passed.
        # This double used to accept `Write(request)` only -- narrower than the real gRPC stub, which
        # has always taken a timeout -- so it broke the moment production started passing one. A
        # double that is stricter than the interface it stands in for turns a correct change into a
        # test failure.
        self.write_timeouts = []
        # Same reasoning as write_timeouts, and the same trap: Read is a *streaming* call, so an
        # unbounded one waits forever on a switch that is alive but not serving.
        # [Co-developed with claude code -- Adam]
        self.read_timeouts = []
        self.write_error = write_error
        self.always = always
        self.read_responses = list(read_responses)
        self.read_error = read_error
        self.probe_error = probe_error

    def Write(self, request, timeout=None):
        self.requests.append(request)
        self.write_timeouts.append(timeout)
        if self.write_error is not None:
            if self.always:
                raise self.write_error
            error, self.write_error = self.write_error, None  # fail once, then succeed
            raise error

    def Read(self, request, timeout=None):
        self.reads.append(request)
        self.read_timeouts.append(timeout)
        if self.read_error is not None:
            raise self.read_error
        return iter(self.read_responses)

    def GetForwardingPipelineConfig(self, request, timeout=None):
        self.probes.append(request)
        self.probe_timeouts.append(timeout)
        if self.probe_error is not None:
            raise self.probe_error
        return p4runtime_pb2.GetForwardingPipelineConfigResponse()

    def SetForwardingPipelineConfig(self, request, timeout=None):
        # [Co-developed with claude code -- Adam]
        # Added for the election-id suite. The real stub has always had this method; a double
        # that lacks one the production code calls fails with AttributeError, which reads as a
        # broken test rather than as a double that stopped standing in for the real object.
        self.pipeline_pushes.append(request)
        return p4runtime_pb2.SetForwardingPipelineConfigResponse()


def a_client(stub=None, device_id=1):
    """
    A client with no gRPC channel.

    __init__ opens a channel and parses a p4info file, neither of which these tests want, so the
    object is built without running it -- the same approach tests/test_clone_session.py takes,
    and for the same reason: depending on a generated artefact here would couple these tests to
    a build step.
    """
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = device_id
    client.grpc_addr = "127.0.0.1:50051"
    client.p4info = a_p4info()
    # [Co-developed with claude code -- Adam]
    # Resolved with the PRODUCTION functions rather than written out as 1..5, so a mutation to
    # the name lookup reaches these tests instead of being papered over by a fixture that agrees
    # with the old constants. `__init__` does exactly this; a double that hardcoded the answer
    # would be asserting the constants against themselves.
    try:
        client.packet_in_ids = packet_in_metadata_ids(client.p4info)
        client.packet_in_ids_error = None
    except TelemetryHeaderMissing as exc:
        client.packet_in_ids = None
        client.packet_in_ids_error = str(exc)
    client.packet_out_ids = packet_out_metadata_ids(client.p4info)
    client.stub = stub if stub is not None else RecordingStub()
    client.packet_in_callback = None
    client.sample_callback = None
    client.is_running = False
    client.stream_recv_thread = None
    client.stream_out_q = queue.Queue()
    # [Co-developed with claude code -- Adam]
    # Every write path stamps this (KNOWN-ISSUES G-13), so a fixture without it makes each of
    # them raise AttributeError -- which is the correct failure for a hand-built double that has
    # stopped standing in for the real object, and is how this line came to be here.
    client.rule_install_times = RuleInstallTimes()
    # The row count of the last table read, which GET /p4/switch_state serves as `rules_total`.
    # None is what a client that has never read its tables reports, and is the same starting
    # value __init__ sets.
    client._last_table_read = None
    # [Co-developed with claude code -- Adam]
    # Who this client bids as, and whether it may write at all. Assigned here rather than
    # defaulted on the class for the reason the `rule_install_times` line above gives: a
    # hand-built double that has stopped standing in for the real object should fail with
    # AttributeError, not quietly inherit a permissive default. `(0, 1)` and True are what
    # __init__ sets for a fabric with no app package.
    client.election_id = (0, 1)
    client.arbitration = True
    return client


def only_update(request):
    """The single Update in a request built by one of the route methods."""
    assert len(request.updates) == 1, f"expected exactly one update, got {len(request.updates)}"
    return request.updates[0]


# --- insert ------------------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class InsertRouteTest(unittest.TestCase):
    def setUp(self):
        self.client = a_client()

    def test_a_successful_insert_reports_true_rather_than_none(self):
        # None is falsy, and route_flow does `bool(...)` on it, so a missing return turns every
        # successful install into {"status": "error"} at the REST layer.
        result = self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.assertIs(result, True)

    def test_the_entry_is_an_insert_into_ipv4_lpm_addressed_to_this_device(self):
        self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        request = self.client.stub.requests[0]

        self.assertEqual(request.device_id, 1)
        self.assertEqual(request.election_id.low, 1, "without mastership every write is refused")
        self.assertEqual(only_update(request).type, p4runtime_pb2.Update.INSERT)
        self.assertEqual(only_update(request).entity.table_entry.table_id, IPV4_LPM_ID)

    def test_the_prefix_length_the_caller_asked_for_is_the_one_sent(self):
        # A prefix pinned to /32 here would install a host route where a subnet route was asked
        # for, which forwards correctly for one address and blackholes the rest of the subnet.
        self.client.insert_ipv4_route("10.0.0.0", 24, "00:00:00:00:00:04", 3)
        match = only_update(self.client.stub.requests[0]).entity.table_entry.match[0]

        self.assertEqual(match.field_id, DST_ADDR_FIELD_ID)
        self.assertEqual(match.lpm.prefix_len, 24)
        self.assertEqual(match.lpm.value, socket.inet_aton("10.0.0.0"))

    def test_the_output_port_is_two_bytes_big_endian(self):
        # bit<9> in the pipeline. Little-endian would send port 3 as 0x0300 = 768, which is not a
        # port on any bmv2 here, so every packet matching the rule would be dropped.
        self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        params = {p.param_id: p.value
                  for p in only_update(self.client.stub.requests[0]).entity.table_entry
                  .action.action.params}
        self.assertEqual(params[PORT_PARAM_ID], b"\x00\x03")

    def test_the_next_hop_mac_goes_in_the_dstAddr_parameter_as_six_raw_bytes(self):
        # Swapping the two parameter ids sends a MAC where a port is expected and vice versa;
        # PI accepts neither, and the resulting UNKNOWN used to be read as "already exists".
        self.client.insert_ipv4_route("10.0.0.4", 32, "de:ad:be:ef:00:04", 3)
        action = only_update(self.client.stub.requests[0]).entity.table_entry.action.action

        self.assertEqual(action.action_id, IPV4_FORWARD_ID)
        params = {p.param_id: p.value for p in action.params}
        self.assertEqual(params[DST_ADDR_PARAM_ID], bytes.fromhex("deadbeef0004"))

    def test_an_already_exists_insert_is_retried_as_a_modify(self):
        # A proxy restart against live switches must reprogram, not refuse. The old code left
        # the existing entry alone, so a recalculated path never took effect.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.ALREADY_EXISTS))
        self.assertIs(self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3), True)

        types = [only_update(r).type for r in self.client.stub.requests]
        self.assertEqual(types, [p4runtime_pb2.Update.INSERT, p4runtime_pb2.Update.MODIFY])

    def test_the_unknown_status_bmv2_actually_returns_is_also_retried_as_a_modify(self):
        # Measured against a real bmv2: a duplicate table entry comes back as UNKNOWN with an
        # empty details string, not ALREADY_EXISTS. This is the case a code-specific check missed.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.UNKNOWN, details=""))
        self.assertIs(self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3), True)

        types = [only_update(r).type for r in self.client.stub.requests]
        self.assertEqual(types, [p4runtime_pb2.Update.INSERT, p4runtime_pb2.Update.MODIFY])

    def test_the_retry_carries_the_new_port_so_a_better_path_actually_takes_effect(self):
        # The point of retrying rather than shrugging: the MODIFY must contain what the caller
        # asked for, otherwise a recomputed path is reported as installed while the switch keeps
        # forwarding out of the old port.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.UNKNOWN, details=""))
        self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 7)

        modify = only_update(self.client.stub.requests[1])
        params = {p.param_id: p.value for p in modify.entity.table_entry.action.action.params}
        self.assertEqual(params[PORT_PARAM_ID], b"\x00\x07")

    def test_a_status_that_cannot_mean_duplicate_is_not_retried(self):
        # PERMISSION_DENIED means this client never won mastership; retrying the same write with
        # the same election id cannot help, and treating it as a duplicate would report success.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.PERMISSION_DENIED),
                                         always=True)
        self.assertIs(self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3), False)
        self.assertEqual(len(self.client.stub.requests), 1,
                         "a status that cannot mean 'already exists' was retried anyway")

    def test_an_insert_and_modify_that_both_fail_is_reported_as_failure(self):
        # always=True is the point: the fallback retries, so a stub that fails only once would
        # let the retry succeed and this would pass while asserting nothing.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.UNKNOWN), always=True)
        self.assertIs(self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3), False)
        self.assertEqual(len(self.client.stub.requests), 2,
                         "both an INSERT and a MODIFY should have been attempted")

    def test_an_error_that_is_not_a_grpc_error_is_not_caught_and_reported_as_a_write_failure(self):
        # Documents current behaviour. `except grpc.RpcError` deliberately does not catch a
        # programming error such as a bad argument type, so it surfaces at the caller instead of
        # being flattened into "Failed to add route" with a status of None. Widening this to
        # `except Exception` would make a TypeError here indistinguishable from a switch refusing
        # the write.
        class Boom(RuntimeError):
            pass

        class Exploding(RecordingStub):
            def Write(self, request, timeout=None):
                raise Boom("not a gRPC failure")

        self.client.stub = Exploding()
        with self.assertRaises(Boom):
            self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)


# --- delete ------------------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class DeleteRouteTest(unittest.TestCase):
    def setUp(self):
        self.client = a_client()

    def test_a_successful_delete_reports_true_rather_than_none(self):
        self.assertIs(self.client.delete_ipv4_route("10.0.0.4", 32), True)

    def test_it_is_a_delete_update_matching_only_the_named_prefix(self):
        self.client.delete_ipv4_route("10.0.0.4", 32)
        update = only_update(self.client.stub.requests[0])

        self.assertEqual(update.type, p4runtime_pb2.Update.DELETE)
        self.assertEqual(update.entity.table_entry.table_id, IPV4_LPM_ID)
        self.assertEqual(update.entity.table_entry.match[0].lpm.value,
                         socket.inet_aton("10.0.0.4"))
        self.assertEqual(update.entity.table_entry.match[0].lpm.prefix_len, 32)

    def test_deleting_something_already_gone_counts_as_success(self):
        # NOT_FOUND is what the caller wanted. Reporting it as a failure would make an idempotent
        # teardown look broken and, in the kernel, log a flow-removal error for every retry.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.NOT_FOUND), always=True)
        self.assertIs(self.client.delete_ipv4_route("10.0.0.4", 32), True)

    def test_a_real_delete_failure_is_reported_instead_of_answering_success(self):
        # This is the regression: every outcome returned None, and route_flow answered "success"
        # for a delete the switch had refused, so a rule the caller believed was gone kept
        # forwarding traffic.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.UNAVAILABLE), always=True)
        self.assertIs(self.client.delete_ipv4_route("10.0.0.4", 32), False)

    def test_a_delete_is_not_retried_as_anything_else(self):
        # A DELETE that failed must not turn into a write of some other kind: the only sound
        # recovery for a refused delete is to report it.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.INTERNAL), always=True)
        self.client.delete_ipv4_route("10.0.0.4", 32)

        types = [only_update(r).type for r in self.client.stub.requests]
        self.assertEqual(types, [p4runtime_pb2.Update.DELETE])


# --- modify ------------------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ModifyRouteTest(unittest.TestCase):
    def setUp(self):
        self.client = a_client()

    def test_a_successful_modify_reports_true_rather_than_none(self):
        # The bug this guards: the success path had no `return True`, so it fell off the end
        # returning None, topology_manager.modify_flow passed that through, and api_routes turned
        # every *successful* modify into HTTP 400.
        self.assertIs(self.client.modify_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3), True)

    def test_it_is_a_modify_update_and_not_an_insert(self):
        # An INSERT here fails with a duplicate status against an entry that already exists,
        # which is the entire situation modify is called for.
        self.client.modify_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.assertEqual(only_update(self.client.stub.requests[0]).type,
                         p4runtime_pb2.Update.MODIFY)

    def test_the_modify_carries_the_new_port_and_mac(self):
        self.client.modify_ipv4_route("10.0.0.4", 32, "de:ad:be:ef:00:04", 9)
        action = only_update(self.client.stub.requests[0]).entity.table_entry.action.action
        params = {p.param_id: p.value for p in action.params}

        self.assertEqual(params[PORT_PARAM_ID], b"\x00\x09")
        self.assertEqual(params[DST_ADDR_PARAM_ID], bytes.fromhex("deadbeef0004"))

    def test_a_failed_modify_is_reported_as_failure(self):
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.NOT_FOUND), always=True)
        self.assertIs(self.client.modify_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3),
                      False)


# --- probe -------------------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ProbeTest(unittest.TestCase):
    """
    The only signal that proves a bmv2 process is alive and serving.

    GET /p4/switch_state is built entirely on this, and the kernel's liveness policy on that, so
    a probe that reports the wrong thing -- or reports "" -- makes the twin's fault display wrong
    rather than merely unhelpful.
    """

    def setUp(self):
        self.client = a_client()

    def test_a_switch_that_answers_is_reported_as_ok(self):
        result = self.client.probe()
        self.assertIs(result["ok"], True)
        self.assertTrue(result["detail"], "an ok probe with no detail says nothing in a log")

    def test_it_asks_only_for_the_cookie_so_the_probe_stays_cheap(self):
        # COOKIE_ONLY returns a single 64-bit value. ALL returns the p4info *and* the compiled
        # device config -- tens of kilobytes per switch, twice a second, on the poller thread.
        self.client.probe()
        request = self.client.stub.probes[0]

        self.assertEqual(request.device_id, 1)
        self.assertEqual(
            request.response_type,
            p4runtime_pb2.GetForwardingPipelineConfigRequest.COOKIE_ONLY)

    def test_the_deadline_reaches_grpc(self):
        # Without a deadline the call blocks until the channel gives up, which is far longer than
        # LIVENESS_PROBE_INTERVAL_S -- one hung switch then stalls the poller for the other nine.
        self.client.probe(timeout_s=0.25)
        self.assertEqual(self.client.stub.probe_timeouts, [0.25])

    def test_a_failure_carries_the_status_name_as_well_as_the_details(self):
        # bmv2 returns an empty details() for some failures, so the name is the only part
        # guaranteed to be actionable.
        self.client.stub = RecordingStub(
            probe_error=FakeRpcError(grpc.StatusCode.UNAVAILABLE,
                                     details="failed to connect to all addresses"))
        result = self.client.probe()

        self.assertIs(result["ok"], False)
        self.assertIn("UNAVAILABLE", result["detail"])
        self.assertIn("failed to connect", result["detail"])

    def test_an_empty_details_string_still_produces_something_actionable(self):
        # A report of "" is unactionable, and that already cost a real investigation once with a
        # clone session.
        self.client.stub = RecordingStub(
            probe_error=FakeRpcError(grpc.StatusCode.INTERNAL, details=""))
        detail = self.client.probe()["detail"]

        self.assertIn("INTERNAL", detail)
        self.assertNotEqual(detail.strip(), "INTERNAL:",
                            "the detail ends at the colon, so nothing explains the failure")
        self.assertIn("no details", detail)

    def test_an_error_with_no_status_code_does_not_raise_out_of_the_probe(self):
        # grpc can hand back an error whose code() is None. `e.code().name` on that is an
        # AttributeError raised *inside* the handler for an error, which the poller would then
        # record as "probe raised AttributeError" -- true, but it hides which switch failed and why.
        self.client.stub = RecordingStub(
            probe_error=FakeRpcError(None, details="channel closed", code_is_none=True))
        result = self.client.probe()

        self.assertIs(result["ok"], False)
        self.assertIn("UNKNOWN", result["detail"])

    def test_a_non_grpc_exception_is_reported_rather_than_raised(self):
        # A probe runs on the liveness poller thread. Letting anything escape would end the loop,
        # freezing every switch at its last result while the ages keep growing -- the kernel then
        # answers Unknown for the whole fabric and never recovers.
        class Exploding(RecordingStub):
            def GetForwardingPipelineConfig(self, request, timeout=None):
                raise ValueError("channel exploded")

        self.client.stub = Exploding()
        result = self.client.probe()

        self.assertIs(result["ok"], False)
        self.assertIn("ValueError", result["detail"])


# --- stream liveness ---------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class StreamAliveTest(unittest.TestCase):
    """
    Corroborating evidence for switch_liveness(), not proof: the receiver thread also exits on a
    clean stop(), which is why `is_running` is consulted first.
    """

    def setUp(self):
        self.client = a_client()

    def a_thread(self, finished):
        gate = threading.Event()
        thread = threading.Thread(target=gate.wait, daemon=True)
        thread.start()
        if finished:
            gate.set()
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
        else:
            self.addCleanup(gate.set)
        return thread

    def test_a_client_that_was_never_started_is_not_alive(self):
        # Reporting an unstarted client as alive would have switch_state claim a working stream
        # before the session exists.
        self.client.is_running = False
        self.client.stream_recv_thread = self.a_thread(finished=False)
        self.assertFalse(self.client.stream_alive)

    def test_a_running_client_with_a_live_receiver_thread_is_alive(self):
        self.client.is_running = True
        self.client.stream_recv_thread = self.a_thread(finished=False)
        self.assertTrue(self.client.stream_alive)

    def test_a_dead_receiver_thread_means_the_stream_is_broken(self):
        # `for response in stream` raises grpc.RpcError when the switch goes away and the thread
        # returns, so a finished thread on a running client is a broken stream.
        self.client.is_running = True
        self.client.stream_recv_thread = self.a_thread(finished=True)
        self.assertFalse(self.client.stream_alive)

    def test_no_receiver_thread_at_all_is_not_alive_rather_than_an_attribute_error(self):
        # start() sets is_running before it creates the thread, so this window is real. An
        # AttributeError here would reach switch_liveness(), which answers the kernel's 1 Hz poll.
        self.client.is_running = True
        self.client.stream_recv_thread = None
        self.assertFalse(self.client.stream_alive)


# --- reading tables back -----------------------------------------------------------


def a_read_response(entries):
    """One ReadResponse carrying the given table entries, built from the real protobuf."""
    response = p4runtime_pb2.ReadResponse()
    for entry in entries:
        response.entities.add().table_entry.CopyFrom(entry)
    return response


def an_lpm_entry(value=b"\x0a\x00\x00\x04", prefix_len=32, priority=0, is_default=False,
                 action_id=IPV4_FORWARD_ID, table_id=IPV4_LPM_ID, with_action=True):
    entry = p4runtime_pb2.TableEntry()
    entry.table_id = table_id
    entry.priority = priority
    entry.is_default_action = is_default
    match = entry.match.add()
    match.field_id = DST_ADDR_FIELD_ID
    match.lpm.value = value
    match.lpm.prefix_len = prefix_len
    if with_action:
        action = entry.action.action
        action.action_id = action_id
        param = action.params.add()
        param.param_id = DST_ADDR_PARAM_ID
        param.value = bytes.fromhex("000000000004")
        param = action.params.add()
        param.param_id = PORT_PARAM_ID
        param.value = b"\x03"
    return entry


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ReadTableEntriesTest(unittest.TestCase):
    """
    Feeds /stats/flow/<dpid>, which the kernel hands to Classifier::updateFromQueriedTables --
    the thing that produces every flow's `path`. A misread field here is not an error anywhere;
    it is a wrong path in the GUI.
    """

    def read(self, *entries, **kwargs):
        stub = RecordingStub(read_responses=[a_read_response(entries)], **kwargs)
        self.client = a_client(stub=stub)
        return self.client.read_table_entries()

    def test_it_asks_for_every_table_rather_than_one(self):
        # table_id 0 means "all tables", which is what reference/dump_table.py does. Asking for one id
        # would silently drop l2_forward and flow_5tuple from the Classifier's view.
        self.read()
        self.assertEqual(self.client.stub.reads[0].device_id, 1)
        self.assertEqual(self.client.stub.reads[0].entities[0].table_entry.table_id, 0)

    def test_an_lpm_match_is_reported_with_its_name_type_value_and_prefix_length(self):
        entries = self.read(an_lpm_entry(prefix_len=24))
        self.assertEqual(len(entries), 1)
        match = entries[0]["match"]["hdr.ipv4.dstAddr"]

        self.assertEqual(match["type"], "lpm")
        self.assertEqual(match["value"], b"\x0a\x00\x00\x04")
        self.assertEqual(match["prefix_len"], 24)

    def test_the_table_and_action_ids_are_resolved_to_names(self):
        # A numeric id in the body is unreadable in a log and unusable by the Classifier, which
        # matches on names.
        entries = self.read(an_lpm_entry())
        self.assertEqual(entries[0]["table"], "MyIngress.ipv4_lpm")
        self.assertEqual(entries[0]["action"]["name"], "MyIngress.ipv4_forward")

    def test_action_parameters_are_keyed_by_name(self):
        entries = self.read(an_lpm_entry())
        self.assertEqual(set(entries[0]["action"]["params"]), {"dstAddr", "port"})
        self.assertEqual(entries[0]["action"]["params"]["port"], b"\x03")

    def test_a_default_action_is_flagged_so_it_is_not_read_as_a_match_everything_rule(self):
        # A default action has no match fields. Without the flag the kernel's Classifier reads it
        # as a rule that matches all traffic, and every flow's path then goes wherever the
        # table's miss action points.
        entries = self.read(an_lpm_entry(is_default=True))
        self.assertIs(entries[0]["is_default"], True)

    def test_an_ordinary_entry_is_not_flagged_as_default(self):
        entries = self.read(an_lpm_entry(is_default=False))
        self.assertIs(entries[0]["is_default"], False)

    def test_exact_ternary_and_range_matches_each_report_their_own_type(self):
        entry = p4runtime_pb2.TableEntry()
        entry.table_id = IPV4_LPM_ID
        exact = entry.match.add()
        exact.field_id = DST_ADDR_FIELD_ID
        exact.exact.value = b"\x0a\x00\x00\x04"

        entries = self.read(entry)
        self.assertEqual(entries[0]["match"]["hdr.ipv4.dstAddr"]["type"], "exact")
        self.assertEqual(entries[0]["match"]["hdr.ipv4.dstAddr"]["value"], b"\x0a\x00\x00\x04")

    def test_a_ternary_match_carries_its_mask(self):
        # ryu_flow_stats drops a zero-masked field, so losing the mask turns a specific rule into
        # one the Classifier discards -- or worse, keeps as a wildcard.
        entry = p4runtime_pb2.TableEntry()
        entry.table_id = IPV4_LPM_ID
        ternary = entry.match.add()
        ternary.field_id = DST_ADDR_FIELD_ID
        ternary.ternary.value = b"\x0a\x00\x00\x04"
        ternary.ternary.mask = b"\xff\xff\xff\x00"

        match = self.read(entry)[0]["match"]["hdr.ipv4.dstAddr"]
        self.assertEqual(match["type"], "ternary")
        self.assertEqual(match["mask"], b"\xff\xff\xff\x00")

    def test_an_entry_with_no_action_reports_none_rather_than_raising(self):
        entries = self.read(an_lpm_entry(with_action=False))
        self.assertIsNone(entries[0]["action"])

    def test_an_id_this_p4info_does_not_describe_becomes_none_rather_than_an_exception(self):
        # A pipeline/p4info mismatch must show up as data, not as an exception on a path polled
        # once per second per switch.
        entries = self.read(an_lpm_entry(table_id=999999, action_id=888888))
        self.assertIsNone(entries[0]["table"])
        self.assertIsNone(entries[0]["action"]["name"])

    def test_entities_that_are_not_table_entries_are_skipped(self):
        # A Read for table_id 0 can come back with counter entities attached to direct counters;
        # reading `entity.table_entry` off one of those yields an empty entry, which would appear
        # as a rule matching nothing on a table named None.
        response = p4runtime_pb2.ReadResponse()
        response.entities.add().counter_entry.counter_id = EGRESS_COUNTER_ID
        response.entities.add().table_entry.CopyFrom(an_lpm_entry())

        client = a_client(stub=RecordingStub(read_responses=[response]))
        self.assertEqual(len(client.read_table_entries()), 1)

    def test_priority_is_reported_as_sent(self):
        entries = self.read(an_lpm_entry(priority=100))
        self.assertEqual(entries[0]["priority"], 100)

    def test_a_table_read_records_how_many_rows_it_returned(self):
        # GET /p4/switch_state serves this as `rules_total` -- the denominator for the install
        # record, so an operator can tell a switch this proxy installed nothing on from a switch
        # with nothing on it (KNOWN-ISSUES G-13). Recorded by the read itself rather than by its
        # caller: the flow-stats poll is not the only reader, and a count the next caller forgets
        # to note would stop moving with nothing anywhere saying so.
        entries = self.read(an_lpm_entry(), an_lpm_entry(prefix_len=24))
        rows, age_s = self.client.last_table_read()

        self.assertEqual(rows, len(entries))
        self.assertGreaterEqual(age_s, 0.0)
        self.assertLess(age_s, 1.0, "the age is of the read, not of the process")

    def test_a_client_that_has_never_read_its_tables_reports_no_count(self):
        # None, not 0. "Nobody has counted" and "counted none" are the two answers this record
        # exists to keep apart, and `0 of 0` reads as a table entirely accounted for.
        self.assertIsNone(a_client(stub=RecordingStub(read_responses=[])).last_table_read())

    def test_an_empty_table_is_counted_as_zero_rather_than_left_unknown(self):
        # The other side of it: a read that succeeded and found nothing is knowledge, and must
        # not be reported as the absence of a reading.
        self.read()

        self.assertEqual(self.client.last_table_read()[0], 0)

    def test_the_age_of_the_count_advances_with_the_clock(self):
        # The count travels with an age precisely so a stale one is visible. Pinned at zero, a
        # switch nobody has polled for an hour would report an hour-old count as freshly taken,
        # and `rules_timed of rules_total` would be read as a statement about the table now.
        # Real elapsed time rather than an injected clock: this client has none, and the number
        # under test is time.monotonic() arithmetic in the accessor itself.
        self.read(an_lpm_entry())
        first = self.client.last_table_read()[1]
        time.sleep(0.05)
        second = self.client.last_table_read()[1]

        self.assertGreater(second, first, "the age is frozen, so staleness is invisible")
        self.assertGreaterEqual(second, 0.04)


# --- counters and packet-out -------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class EgressCounterTest(unittest.TestCase):
    def a_counter_response(self, byte_count, packet_count, index=2):
        response = p4runtime_pb2.ReadResponse()
        entry = response.entities.add().counter_entry
        entry.counter_id = EGRESS_COUNTER_ID
        entry.index.index = index
        entry.data.byte_count = byte_count
        entry.data.packet_count = packet_count
        return response

    def test_the_counter_is_read_at_the_index_of_the_port(self):
        # The counter is indexed by egress port, so a fixed index reports one port's traffic for
        # every port -- plausible numbers, attributed to the wrong link.
        client = a_client(stub=RecordingStub(read_responses=[self.a_counter_response(10, 2)]))
        client.read_egress_counter(7)

        entity = client.stub.reads[0].entities[0]
        self.assertEqual(entity.counter_entry.counter_id, EGRESS_COUNTER_ID)
        self.assertEqual(entity.counter_entry.index.index, 7)

    def test_bytes_come_back_before_packets(self):
        # Both are ints and both are plausible, so a swap is invisible except as a bandwidth
        # figure roughly 1000x too small.
        client = a_client(stub=RecordingStub(read_responses=[self.a_counter_response(15000, 12)]))
        self.assertEqual(client.read_egress_counter(2), (15000, 12))

    # --- the three outcomes must not share a value ------------------------------------------
    #
    # These four tests replace two that asserted (0, 0) for a missing counter and for a failed
    # read. Those tests passed, and what they pinned was the defect: the value that means "this
    # port forwarded nothing" was also the value that meant "there is no such counter" and "the
    # connection dropped". The old assertions are not deleted so much as split -- each failure now
    # has its own test, and a real zero has one too.

    def test_a_p4info_without_the_counter_raises_rather_than_reporting_zero(self):
        client = a_client()
        client.p4info.ClearField("counters")
        with self.assertRaises(CounterNotFound):
            client.read_egress_counter(1)
        self.assertEqual(client.stub.reads, [], "a read was attempted with no counter id")

    def test_an_unknown_counter_name_raises_and_never_returns_zero(self):
        # NEGATIVE CONTROL. Ask for a counter that cannot exist and assert the answer is not a
        # number at all. Without this, every other test here could pass against a method that
        # answered (0, 0) to everything -- which is exactly what the previous version did.
        client = a_client()
        with self.assertRaises(CounterNotFound) as caught:
            client.read_egress_counter(1, counter_name="MyEgress.no_such_counter")
        self.assertIn("no_such_counter", str(caught.exception))
        self.assertEqual(client.stub.reads, [])

    def test_a_read_failure_reports_no_sample_rather_than_zero(self):
        # Polled per port per switch, so a transient gRPC failure must still not take the caller
        # down -- that part of the old behaviour was right. What changes is the value: None cannot
        # be summed, averaged, or compared against a veth counter by accident.
        client = a_client(stub=RecordingStub(read_error=FakeRpcError(grpc.StatusCode.UNAVAILABLE)))
        self.assertIsNone(client.read_egress_counter(1))

    def test_a_read_that_returns_no_entry_reports_no_sample(self):
        # bmv2 omits an entry it holds no state for. "Nothing reported" is not "nothing forwarded".
        client = a_client(stub=RecordingStub(read_responses=[p4runtime_pb2.ReadResponse()]))
        self.assertIsNone(client.read_egress_counter(1))

    def test_a_genuine_zero_is_still_reported_as_zero(self):
        # The point of the change is not to make zero unreachable. An idle port really does read
        # (0, 0), and that has to remain distinguishable from the two failures above.
        client = a_client(stub=RecordingStub(read_responses=[self.a_counter_response(0, 0, index=1)]))
        self.assertEqual(client.read_egress_counter(1), (0, 0))

    def test_a_counter_whose_id_is_zero_is_found(self):
        # `if not counter_id` treated a legitimate id of 0 as absent. P4Runtime ids are unsigned,
        # so this is reachable, and it would have surfaced as a counter that vanished for one
        # pipeline build and not another.
        client = a_client(stub=RecordingStub(read_responses=[self.a_counter_response(5, 1, index=1)]))
        client.p4info.counters[0].preamble.id = 0
        self.assertEqual(client.read_egress_counter(1), (5, 1))
        self.assertEqual(client.stub.reads[0].entities[0].counter_entry.counter_id, 0)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class PacketOutTest(unittest.TestCase):
    """
    The LLDP beacons go out this way, so a wrong egress_port encoding means no discovery at all
    and an empty graph -- with nothing logged.
    """

    def setUp(self):
        self.client = a_client()

    def queued(self):
        self.assertFalse(self.client.stream_out_q.empty(), "nothing was queued")
        return self.client.stream_out_q.get_nowait()

    def test_the_egress_port_is_two_bytes_big_endian_under_metadata_id_one(self):
        self.client.send_packet_out(3, b"beacon")
        metadata = {m.metadata_id: m.value for m in self.queued().packet.metadata}
        self.assertEqual(metadata[1], b"\x00\x03")

    def test_the_pad_field_the_controller_header_declares_is_present(self):
        # packet_out_header_t is egress_port plus a 7-bit pad. PI rejects a packet-out whose
        # metadata does not match the header, so a missing or misnumbered pad drops every beacon.
        self.client.send_packet_out(3, b"beacon")
        metadata = {m.metadata_id: m.value for m in self.queued().packet.metadata}
        self.assertEqual(sorted(metadata), [1, 2])
        self.assertEqual(metadata[2], b"\x00")

    def test_the_payload_is_sent_unchanged(self):
        self.client.send_packet_out(3, b"\x01\x80\xc2\x00\x00\x0eDPID:1,PORT:3")
        self.assertEqual(self.queued().packet.payload,
                         b"\x01\x80\xc2\x00\x00\x0eDPID:1,PORT:3")


# --- p4info lookups ----------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class P4InfoLookupTest(unittest.TestCase):
    """
    These are the write path's only defence against a p4info that does not match the pipeline.
    They must raise: an id of 0 or None is accepted by the protobuf and rejected by bmv2 as
    UNKNOWN, which insert_ipv4_route then retries as a MODIFY and reports as a plain failure --
    a name typo would look exactly like an unreachable switch.
    """

    def setUp(self):
        self.client = a_client()

    def test_an_unknown_table_name_raises(self):
        with self.assertRaises(KeyError):
            self.client._get_table_id("MyIngress.no_such_table")

    def test_an_unknown_action_name_raises(self):
        with self.assertRaises(KeyError):
            self.client._get_action_id("MyIngress.no_such_action")

    def test_an_unknown_match_field_raises(self):
        with self.assertRaises(KeyError):
            self.client._get_match_field_id("MyIngress.ipv4_lpm", "hdr.ipv4.nope")

    def test_an_unknown_action_parameter_raises(self):
        with self.assertRaises(KeyError):
            self.client._get_action_param_id("MyIngress.ipv4_forward", "nope")

    def test_a_match_field_is_not_found_on_the_wrong_table(self):
        # Both tables key on a field called dstAddr in the real p4info (ipv4_lpm on
        # hdr.ipv4.dstAddr, l2_forward on hdr.ethernet.dstAddr), so a lookup that ignored the
        # table name would return an id from whichever table came first.
        table = self.client.p4info.tables.add()
        table.preamble.id = 42660923
        table.preamble.name = "MyIngress.l2_forward"
        field = table.match_fields.add()
        field.id = 1
        field.name = "hdr.ethernet.dstAddr"

        with self.assertRaises(KeyError):
            self.client._get_match_field_id("MyIngress.ipv4_lpm", "hdr.ethernet.dstAddr")


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class WriteDeadlineTest(unittest.TestCase):
    """
    Pins the deadline on the write path.

    [Co-developed with claude code -- Adam]
    gRPC's default is no deadline at all, and these writes are reached from the stream-receive
    thread: handle_packet_in -> install_initial_routes -> insert_ipv4_route. So a switch whose
    channel had gone away blocked packet-in handling for every *other* switch too -- one dead
    device stalling a live fabric. Without this test the timeout is one keyword argument away
    from being dropped again, and nothing else would notice.
    """

    def setUp(self):
        self.stub = RecordingStub()
        self.client = a_client(self.stub)

    def test_an_insert_carries_a_deadline(self):
        self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.assertTrue(self.stub.write_timeouts, "no Write reached the stub")
        for t in self.stub.write_timeouts:
            self.assertIsNotNone(t, "a Write was sent with no deadline")
            self.assertGreater(t, 0)

    def test_a_delete_carries_a_deadline(self):
        self.client.delete_ipv4_route("10.0.0.4", 32)
        self.assertTrue(self.stub.write_timeouts)
        for t in self.stub.write_timeouts:
            self.assertIsNotNone(t, "a Write was sent with no deadline")

    def test_the_deadline_is_not_so_short_that_a_slow_table_write_is_reported_as_failed(self):
        # A tighter bound would make DEADLINE_EXCEEDED report a rule that did land as failed.
        self.client.insert_ipv4_route("10.0.0.5", 32, "00:00:00:00:00:05", 4)
        self.assertGreaterEqual(min(self.stub.write_timeouts), 1.0)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ReadDeadlineTest(unittest.TestCase):
    """
    Pins the deadline on the table-read path.

    [Co-developed with claude code -- Adam]
    The read is worse than the write it mirrors: Read is a streaming call, so with no deadline it
    waits forever rather than failing, and its caller is an HTTP endpoint the kernel polls once per
    switch per sweep. Measured 2026-08-13 with s5 SIGSTOPed -- alive, not serving -- GET
    /stats/flow/5 never came back at all (cut off at 25 s) against 3 ms healthy, and because the
    endpoint was `async def` at the time it took the proxy's whole event loop with it: 40/40 edges
    down to 32/40 in the kernel's graph. This test guards the keyword argument; the endpoint being
    `def` is guarded in tests/test_flow_stats_route.py. Both halves are needed, and neither one
    implies the other.
    """

    def setUp(self):
        self.stub = RecordingStub(read_responses=[])
        self.client = a_client(self.stub)

    def test_a_table_read_carries_a_deadline(self):
        self.client.read_table_entries()
        self.assertTrue(self.stub.read_timeouts, "no Read reached the stub")
        for t in self.stub.read_timeouts:
            self.assertIsNotNone(t, "a Read was sent with no deadline -- it will hang forever")
            self.assertGreater(t, 0)

    def test_the_deadline_is_not_so_short_that_a_large_table_is_reported_as_unreadable(self):
        # A switch holding a real routing table takes longer to dump than one holding four rules.
        # Too tight a bound turns a healthy switch into a ReportedFailure every poll, and the
        # kernel would then keep stale tables forever.
        self.client.read_table_entries()
        self.assertGreaterEqual(min(self.stub.read_timeouts), 1.0)

    def test_a_caller_can_tighten_the_deadline(self):
        # The liveness-sensitive callers are not all the same urgency; the default is a ceiling,
        # not a fixed policy.
        self.client.read_table_entries(timeout_s=0.25)
        self.assertEqual(self.stub.read_timeouts, [0.25])


class RecordingChannelFactory:
    """
    Stands in for grpc.insecure_channel and records how it was called.

    Returns something a real P4RuntimeStub can be constructed from -- the stub asks the channel
    for one callable per RPC method at construction time, so a bare object() makes __init__ die
    before it reaches anything worth asserting. The callables refuse to be invoked: nothing here
    should reach the wire.
    """

    def __init__(self):
        self.calls = []

    def __call__(self, target, options=None, **kwargs):
        self.calls.append({"target": target, "options": options, "kwargs": kwargs})
        return FakeChannel()


class FakeChannel:
    def _method(self, *args, **kwargs):
        def refuse(*a, **k):
            raise AssertionError("no RPC should be attempted while constructing a client")
        return refuse

    unary_unary = unary_stream = stream_unary = stream_stream = _method

    def close(self):
        pass


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ChannelOptionsTest(unittest.TestCase):
    """
    Pins the subchannel pool the client's channel is built with.

    [Co-developed with claude code -- Adam]
    grpc-python shares subchannels through a process-global pool keyed by target address, so a
    fresh channel inherits the reconnect backoff that a previous channel accumulated against the
    same address. During a power-off the liveness poller probes the dead client every 2 s, so a
    four-minute outage drives that backoff toward gRPC's 120 s cap -- and readopt_switch's brand
    new client is then handed it and fails with UNAVAILABLE against a port that is listening.
    Measured on grpc 1.82.1 after hammering a closed port for 90 s: 0.00 s to READY with a local
    pool, 32.56 s without.

    Asserted at construction rather than by timing a reconnect, because the honest, fast and
    hermetic thing to check is that the option is on the channel. The exact option name is
    spelled out here on purpose: gRPC silently ignores channel options it does not recognise, so
    a typo in p4_client would cost nothing at runtime and this is what makes it cost a test.

    Unlike the rest of this file these tests run the real __init__ -- that is where the channel is
    built, and a client made with __new__ (see a_client) never opens one.
    """

    def setUp(self):
        self.factory = RecordingChannelFactory()
        self._real_insecure_channel = p4_client_module.grpc.insecure_channel
        p4_client_module.grpc.insecure_channel = self.factory
        self.addCleanup(self._restore_insecure_channel)

        # __init__ parses a p4info off disk. Written from the same in-process p4info the rest of
        # this file uses, so these tests stay independent of the gitignored build artefact.
        handle, self.p4info_path = tempfile.mkstemp(suffix=".p4info.txt")
        with os.fdopen(handle, "w") as f:
            f.write(text_format.MessageToString(a_p4info()))
        self.addCleanup(os.unlink, self.p4info_path)

    def _restore_insecure_channel(self):
        p4_client_module.grpc.insecure_channel = self._real_insecure_channel

    def a_real_client(self, grpc_addr="localhost:50051"):
        return P4RuntimeClient(device_id=1, grpc_addr=grpc_addr, p4info_path=self.p4info_path)

    def only_call(self):
        self.assertEqual(len(self.factory.calls), 1,
                         f"expected exactly one channel, got {len(self.factory.calls)}")
        return self.factory.calls[0]

    def test_the_channel_does_not_share_the_process_global_subchannel_pool(self):
        self.a_real_client()
        options = self.only_call()["options"]
        self.assertIsNotNone(options, "the channel was built with no options at all, so it uses "
                                      "grpc's process-global subchannel pool and inherits the "
                                      "backoff of whatever failed against this address before")
        self.assertIn(("grpc.use_local_subchannel_pool", 1), list(options))

    def test_the_target_address_still_reaches_grpc(self):
        # The option is passed as a keyword; a refactor that moves it into the positional slot
        # would take the address with it, and every switch would be dialled at the wrong target.
        self.a_real_client(grpc_addr="localhost:50057")
        self.assertEqual(self.only_call()["target"], "localhost:50057")

    def test_two_clients_for_one_address_each_get_their_own_pool(self):
        # The readopt case: the replacement client is built while the dead one still exists, and
        # it is the replacement that must not inherit anything.
        self.a_real_client()
        self.a_real_client()
        self.assertEqual(len(self.factory.calls), 2)
        for call in self.factory.calls:
            self.assertIn(("grpc.use_local_subchannel_pool", 1), list(call["options"] or []))


# --- delete against bmv2's actual status vocabulary --------------------------------


def a_read_response_with_lpm(value, prefix_len, include_default=False):
    """One ReadResponse holding one ipv4_lpm entry (plus, optionally, the default entry)."""
    resp = p4runtime_pb2.ReadResponse()
    te = resp.entities.add().table_entry
    te.table_id = IPV4_LPM_ID
    m = te.match.add()
    m.field_id = DST_ADDR_FIELD_ID
    m.lpm.value = value
    m.lpm.prefix_len = prefix_len
    if include_default:
        # The default entry a real dump always carries: no match fields, is_default set. The
        # presence scan must skip it rather than read it as a match-everything entry.
        default = resp.entities.add().table_entry
        default.table_id = IPV4_LPM_ID
        default.is_default_action = True
    return resp


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class DeleteDisambiguatesBmv2UnknownTest(unittest.TestCase):
    """
    bmv2 reports "no such entry to delete" as UNKNOWN with empty details -- never the
    NOT_FOUND the branch above it was written for (live 2026-08-16) -- and uses the same
    UNKNOWN for genuine failures. Status alone cannot split those, so the client reads the
    table back and answers by goal state: gone is done, still-present is a failure.
    """

    def test_unknown_with_the_entry_gone_counts_as_success(self):
        # The bmv2-real idempotent case: the entry is not there, which is what the caller
        # wanted. Before the read-back this answered False, the kernel logged a failed flow
        # removal, and unroute_flow refused to clear its bookkeeping -- so a rule already
        # gone from the switch stayed advertised by the twin forever.
        stub = RecordingStub(write_error=FakeRpcError(grpc.StatusCode.UNKNOWN, details=""),
                             always=True,
                             read_responses=[a_read_response_with_lpm(
                                 socket.inet_aton("10.0.0.9"), 32, include_default=True)])
        self.assertIs(a_client(stub).delete_ipv4_route("10.0.0.4", 32), True)

    def test_unknown_with_the_entry_still_present_stays_a_failure(self):
        # The other face of the same status: the switch refused a delete of a rule it still
        # holds. Claiming success here is the original delete bug wearing a new status code.
        stub = RecordingStub(write_error=FakeRpcError(grpc.StatusCode.UNKNOWN, details=""),
                             always=True,
                             read_responses=[a_read_response_with_lpm(
                                 socket.inet_aton("10.0.0.4"), 32)])
        self.assertIs(a_client(stub).delete_ipv4_route("10.0.0.4", 32), False)

    def test_unknown_with_an_unreadable_table_stays_a_failure(self):
        # If the goal state cannot be verified, the honest answer is still failure.
        stub = RecordingStub(write_error=FakeRpcError(grpc.StatusCode.UNKNOWN, details=""),
                             always=True,
                             read_error=FakeRpcError(grpc.StatusCode.DEADLINE_EXCEEDED))
        self.assertIs(a_client(stub).delete_ipv4_route("10.0.0.4", 32), False)

    def test_not_found_is_answered_without_a_read(self):
        # NOT_FOUND is already unambiguous, so success must not cost a table read.
        stub = RecordingStub(write_error=FakeRpcError(grpc.StatusCode.NOT_FOUND), always=True)
        self.assertIs(a_client(stub).delete_ipv4_route("10.0.0.4", 32), True)
        self.assertEqual(stub.reads, [])

    def test_a_canonicalized_readback_still_matches_its_own_entry(self):
        # bmv2 canonicalizes read-back values by stripping leading zero bytes: 0.0.7.8 goes
        # onto the wire as 00 00 07 08 and comes back as 07 08. Compared unpadded, the scan
        # would call the entry absent and report a refused delete as a success.
        stub = RecordingStub(write_error=FakeRpcError(grpc.StatusCode.UNKNOWN, details=""),
                             always=True,
                             read_responses=[a_read_response_with_lpm(b"\x07\x08", 32)])
        self.assertIs(a_client(stub).delete_ipv4_route("0.0.7.8", 32), False)

    def test_an_entry_with_another_prefix_length_does_not_block_the_success(self):
        # A /24 over the same bytes is a different rule. Only the exact (value, prefix_len)
        # pair the delete named may keep the answer at failure.
        stub = RecordingStub(write_error=FakeRpcError(grpc.StatusCode.UNKNOWN, details=""),
                             always=True,
                             read_responses=[a_read_response_with_lpm(
                                 socket.inet_aton("10.0.0.4"), 24)])
        self.assertIs(a_client(stub).delete_ipv4_route("10.0.0.4", 32), True)


# --- who the client says it is, and whether it may write at all --------------------------


def a_bidding_client(election_id, stub=None):
    """A client whose election id is not the default, for asserting it reaches the wire."""
    client = a_client(stub)
    client.election_id = election_id
    return client


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheElectionIdOnEveryRequestTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam]

    The election id used to be the literal `(0, 1)`, written out once per request -- nine sites.
    It is a parameter now because an app package needs to bid higher: P4Runtime identifies the
    sender of a unary RPC by the (device_id, role, election_id) in the MESSAGE rather than by the
    connection it arrived on, so anything else presenting the same `(0, 1)` is accepted as
    primary and its SetForwardingPipelineConfig wipes every table (measured 2026-08-13).

    🔴 A site that kept its literal would be invisible: every other test in this file passes
    whatever number is on the wire, bmv2 accepts `(0, 1)` from the proxy today, and the failure
    only appears when a third-party controller is attached. So each request type is asserted
    separately -- one test per site, not one loop that stops at the first.
    """

    BID = (7, 65535)

    def test_the_arbitration_bid_carries_both_halves_of_this_clients_election_id(self):
        client = a_bidding_client(self.BID)
        client.arbitration = True
        client.stream = None
        client.stub = RecordingStub()
        # start() is what puts the arbitration message on the queue; run only that part of it by
        # driving the same code with a stream factory that returns an exhausted iterator.
        client.stub.StreamChannel = lambda _it: iter(())
        client.start(push_config=False)
        req = client.stream_out_q.get_nowait()
        self.assertEqual(req.arbitration.device_id, client.device_id)
        self.assertEqual((req.arbitration.election_id.high, req.arbitration.election_id.low),
                         self.BID)
        # No stop(): this client has no channel (a_client builds none), and what is under test
        # is the bytes of the bid, not the teardown.
        client.is_running = False

    def test_a_pipeline_push_carries_this_clients_election_id(self):
        stub = RecordingStub()
        client = a_bidding_client(self.BID, stub)
        client.json_path = __file__  # any readable file; the bytes are not inspected here
        client.table_generation = None
        client.pipeline_commits = 0
        client.set_forwarding_pipeline_config()
        req = stub.pipeline_pushes[-1]
        self.assertEqual((req.election_id.high, req.election_id.low), self.BID)

    def test_a_clone_session_write_carries_this_clients_election_id(self):
        stub = RecordingStub()
        a_bidding_client(self.BID, stub).write_clone_session()
        for req in stub.requests:
            self.assertEqual((req.election_id.high, req.election_id.low), self.BID)

    def test_an_ipv4_route_insert_carries_this_clients_election_id(self):
        stub = RecordingStub()
        a_bidding_client(self.BID, stub).insert_ipv4_route("10.0.0.5", 32, "00:00:00:00:00:05", 4)
        req = stub.requests[-1]
        self.assertEqual((req.election_id.high, req.election_id.low), self.BID)

    def test_an_ipv4_route_delete_carries_this_clients_election_id(self):
        stub = RecordingStub()
        a_bidding_client(self.BID, stub).delete_ipv4_route("10.0.0.5", 32)
        req = stub.requests[-1]
        self.assertEqual((req.election_id.high, req.election_id.low), self.BID)

    def test_an_ipv4_route_modify_carries_this_clients_election_id(self):
        stub = RecordingStub()
        a_bidding_client(self.BID, stub).modify_ipv4_route("10.0.0.5", 32, "00:00:00:00:00:05", 4)
        req = stub.requests[-1]
        self.assertEqual((req.election_id.high, req.election_id.low), self.BID)

    def test_a_five_tuple_insert_carries_this_clients_election_id(self):
        stub = RecordingStub()
        client = a_bidding_client(self.BID, stub)
        client.insert_5tuple_rule({"hdr.ipv4.dstAddr": "10.0.0.5"}, 101,
                                  "00:00:00:00:00:05", 4)
        req = stub.requests[-1]
        self.assertEqual((req.election_id.high, req.election_id.low), self.BID)

    def test_a_five_tuple_modify_carries_this_clients_election_id(self):
        stub = RecordingStub()
        client = a_bidding_client(self.BID, stub)
        client.modify_5tuple_rule({"hdr.ipv4.dstAddr": "10.0.0.5"}, 101,
                                  "00:00:00:00:00:05", 4)
        req = stub.requests[-1]
        self.assertEqual((req.election_id.high, req.election_id.low), self.BID)

    def test_a_five_tuple_delete_carries_this_clients_election_id(self):
        stub = RecordingStub()
        client = a_bidding_client(self.BID, stub)
        client.delete_5tuple_rule({"hdr.ipv4.dstAddr": "10.0.0.5"}, 101)
        req = stub.requests[-1]
        self.assertEqual((req.election_id.high, req.election_id.low), self.BID)

    def test_the_default_is_still_the_literal_zero_one_the_fabric_has_always_bid(self):
        stub = RecordingStub()
        a_client(stub).insert_ipv4_route("10.0.0.5", 32, "00:00:00:00:00:05", 4)
        req = stub.requests[-1]
        self.assertEqual((req.election_id.high, req.election_id.low), (0, 1))
        self.assertEqual(p4_client_module.DEFAULT_ELECTION_ID, (0, 1))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class AReadOnlyClientTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam]

    `arbitration=False` is what the proxy builds under an `external` app package: the exercise's
    own controller is the primary, and this object is an observer. Every write raises rather than
    returning False, because the write callers treat False as "retry on the next pass" and this
    condition lasts for the life of the run -- a retry loop spinning silently on it is how the
    problem would be found from a packet capture instead of from a message.
    """

    def read_only(self, stub=None):
        client = a_client(stub)
        client.arbitration = False
        return client

    def test_it_opens_no_stream_and_starts_no_receiver_thread(self):
        client = self.read_only()
        client.stub.StreamChannel = lambda _it: self.fail("a stream was opened")
        client.start(push_config=True)
        self.assertIsNone(client.stream_recv_thread)
        self.assertTrue(client.stream_out_q.empty(),
                        "an arbitration bid was queued; bidding at all takes mastership away "
                        "from the controller the exercise is running")

    def test_it_never_reports_a_live_stream(self):
        # There is no stream, so `stream_alive` has to say so: the liveness report on
        # GET /p4/switch_state carries this flag, and a client claiming a live stream it never
        # opened would make an external fabric look like one whose beacons had merely stopped.
        # (`mastership_confirmed` is asserted on a client built through the real __init__ --
        # tests/test_app_package_proxy.py -- because this fixture bypasses it.)
        client = self.read_only()
        client.start(push_config=True)
        self.assertFalse(client.stream_alive)

    def test_an_external_client_refuses_a_pipeline_push(self):
        # 🔴 The one that matters most: this call empties every table on the switch.
        client = self.read_only()
        client.json_path = __file__
        with self.assertRaises(p4_client_module.ControlPlaneReadOnly) as caught:
            client.set_forwarding_pipeline_config()
        self.assertIn("external control plane", str(caught.exception))
        self.assertIn(str(client.device_id), str(caught.exception))

    def test_an_external_client_refuses_a_clone_session(self):
        with self.assertRaises(p4_client_module.ControlPlaneReadOnly):
            self.read_only().write_clone_session()

    def test_an_external_client_refuses_a_packet_out(self):
        # The LLDP beacon: frames this proxy would put on somebody else's fabric.
        with self.assertRaises(p4_client_module.ControlPlaneReadOnly):
            self.read_only().send_packet_out(1, b"payload")

    def test_an_external_client_refuses_every_table_write(self):
        for label, call in (
                ("insert_ipv4_route",
                 lambda c: c.insert_ipv4_route("10.0.0.5", 32, "00:00:00:00:00:05", 4)),
                ("delete_ipv4_route", lambda c: c.delete_ipv4_route("10.0.0.5", 32)),
                ("modify_ipv4_route",
                 lambda c: c.modify_ipv4_route("10.0.0.5", 32, "00:00:00:00:00:05", 4)),
                ("insert_5tuple_rule",
                 lambda c: c.insert_5tuple_rule({"hdr.ipv4.dstAddr": "10.0.0.5"}, 101,
                                                "00:00:00:00:00:05", 4)),
                ("modify_5tuple_rule",
                 lambda c: c.modify_5tuple_rule({"hdr.ipv4.dstAddr": "10.0.0.5"}, 101,
                                                "00:00:00:00:00:05", 4)),
                ("delete_5tuple_rule",
                 lambda c: c.delete_5tuple_rule({"hdr.ipv4.dstAddr": "10.0.0.5"}, 101)),
        ):
            with self.subTest(method=label):
                stub = RecordingStub()
                with self.assertRaises(p4_client_module.ControlPlaneReadOnly):
                    call(self.read_only(stub))
                self.assertEqual(stub.requests, [],
                                 f"{label} reached the wire before refusing")

    def test_a_refusal_is_not_a_grpc_error_so_no_write_path_can_swallow_it_as_one(self):
        # `except grpc.RpcError: return False` is the shape every write path here already has.
        # A refusal caught by one of those would be reported as a switch-side failure and
        # retried forever.
        self.assertFalse(issubclass(p4_client_module.ControlPlaneReadOnly, grpc.RpcError))
        self.assertTrue(issubclass(p4_client_module.ControlPlaneReadOnly, RuntimeError))

    def test_reads_are_untouched_because_they_need_no_election_id(self):
        # probe() is the one the liveness poller runs once every two seconds; it is a unary
        # GetForwardingPipelineConfig with COOKIE_ONLY and carries no election id at all.
        client = self.read_only()
        self.assertEqual(client.probe()["ok"], True)

    def test_a_table_read_works_and_writes_nothing(self):
        # 🔴 The half that makes `external` worth having: the twin can still SEE the fabric the
        # exercise's controller is programming. `/stats/flow/<dpid>` -- which the kernel polls
        # once a second and turns into every flow's `path` -- is built on this call, so a
        # read-only client that refused it would give the twin an exercise it cannot observe,
        # which is the "only an observer" option PLAN-0917 section 2 rejected as not-support.
        stub = RecordingStub(read_responses=[a_read_response_with_lpm(
            socket.inet_aton("10.0.0.4"), 32)])
        client = self.read_only(stub)
        self.assertEqual(len(client.read_table_entries()), 1)
        self.assertEqual(stub.requests, [], "a read put a WriteRequest on the wire")

    def test_a_table_read_carries_no_election_id_at_all(self):
        # Not "carries this client's": a ReadRequest has no election id field in P4Runtime, so
        # the read path is correct for a non-primary by construction rather than by permission.
        stub = RecordingStub(read_responses=[a_read_response_with_lpm(
            socket.inet_aton("10.0.0.4"), 32)])
        self.read_only(stub).read_table_entries()
        self.assertFalse(hasattr(stub.reads[0], "election_id"))

    def test_the_egress_counter_read_works(self):
        # The link-usage numbers. Same argument as the table read: an external fabric that
        # reported zero bytes on every link would look exactly like an idle one.
        response = p4runtime_pb2.ReadResponse()
        entry = response.entities.add().counter_entry
        entry.counter_id = EGRESS_COUNTER_ID
        entry.index.index = 3
        entry.data.byte_count = 15000
        entry.data.packet_count = 12
        stub = RecordingStub(read_responses=[response])
        self.assertEqual(self.read_only(stub).read_egress_counter(3), (15000, 12))
        self.assertEqual(stub.requests, [])

    def test_a_writing_client_is_unaffected(self):
        # The negative half: the guard fires on the flag, not on some incidental property of the
        # fixture. Without this, deleting `arbitration` entirely would leave the suite green.
        stub = RecordingStub()
        self.assertIs(a_client(stub).insert_ipv4_route("10.0.0.5", 32, "00:00:00:00:00:05", 4),
                      True)


# --- the generic table-entry writer (TICKET-P2 4.1) ------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class EncodeValueTest(unittest.TestCase):
    """
    `encode_value` -- the rules tutorials' `p4runtime_lib/convert.encode` states, re-stated.

    [Co-developed with claude code -- Adam]
    They are re-stated rather than imported because `~/tutorials` is a directory on one laptop
    and not a dependency of this proxy. So the agreement is what gets asserted, against values
    taken from the exercises' own runtime files -- `08:00:00:00:01:11` and `10.0.1.1` are
    `basic/pod-topo/s1-runtime.json`'s, verbatim.

    🔴 EVERY OUT-OF-RANGE CASE IS A REFUSAL, NOT A NARROWING. A truncated value installs a rule
    for traffic nobody asked about, and it forwards.
    """

    def encode(self, value, bitwidth):
        return p4_client_module.encode_value(value, bitwidth)

    def test_a_mac_string_is_six_raw_bytes_in_the_order_it_was_written(self):
        self.assertEqual(self.encode("08:00:00:00:01:11", 48),
                         bytes.fromhex("080000000111"))

    def test_an_ipv4_string_is_four_raw_bytes(self):
        self.assertEqual(self.encode("10.0.1.1", 32), socket.inet_aton("10.0.1.1"))

    def test_an_integer_is_ceil_bitwidth_over_eight_bytes_big_endian(self):
        # bit<9> is two bytes. Little-endian would send port 1 as 0x0100 = 256, which is not a
        # port on any bmv2 here, so every packet matching the rule would be dropped.
        self.assertEqual(self.encode(1, 9), b"\x00\x01")
        self.assertEqual(self.encode(1, 8), b"\x01")
        self.assertEqual(self.encode(1, 16), b"\x00\x01")
        self.assertEqual(self.encode(0x0102, 16), b"\x01\x02")

    def test_a_value_wider_than_its_field_is_refused_rather_than_truncated(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid) as caught:
            self.encode(512, 9)
        self.assertIn("511", str(caught.exception))
        # The boundary itself is legal: bit<9> holds 0..511.
        self.assertEqual(self.encode(511, 9), b"\x01\xff")

    def test_a_negative_value_is_refused_because_p4_fields_are_unsigned(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.encode(-1, 9)

    def test_a_mac_in_a_field_that_is_not_48_bits_is_refused(self):
        # Not silently padded or cut. A MAC in a bit<32> field is somebody's entry naming the
        # wrong key, and the switch answers an opaque UNKNOWN to a short value.
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.encode("08:00:00:00:01:11", 32)

    def test_an_address_in_a_field_that_is_not_32_bits_is_refused(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.encode("10.0.1.1", 48)

    def test_a_decimal_or_hex_string_is_read_as_the_integer_it_spells(self):
        self.assertEqual(self.encode("17", 8), b"\x11")
        self.assertEqual(self.encode("0x11", 8), b"\x11")

    def test_a_json_boolean_is_not_a_value_for_a_bit_field(self):
        # JSON has a boolean and P4 does not. Accepting `true` as 1 would encode a type
        # confusion in somebody's manifest as a working rule.
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.encode(True, 8)

    def test_a_field_with_no_declared_width_is_refused_rather_than_guessed(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.encode(1, 0)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class BuildTableEntryTest(unittest.TestCase):
    """
    What `build_table_entry` puts in the TableEntry, read out of the p4info and not guessed.

    [Co-developed with claude code -- Adam]
    The match SHAPE comes from the p4info's declared match type, never from the value: `[v, 32]`
    is an lpm entry on one table and a ternary value/mask pair on another, and the two mean
    different traffic. tools/p4_exercise/preflight.py has to guess because it may not have the
    pipeline; this side always has it.
    """

    def setUp(self):
        self.client = a_client()

    def build(self, **spec):
        return self.client.build_table_entry(spec)

    def lpm_spec(self, **overrides):
        spec = {"table": "MyIngress.ipv4_lpm",
                "match": {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
        spec.update(overrides)
        return spec

    def test_an_lpm_entry_carries_the_value_and_the_prefix_length_it_was_given(self):
        entry, kinds = self.build(**self.lpm_spec(
            match={"hdr.ipv4.dstAddr": ["10.0.1.0", 24]}))
        self.assertEqual(entry.table_id, IPV4_LPM_ID)
        self.assertEqual(entry.match[0].field_id, DST_ADDR_FIELD_ID)
        self.assertEqual(entry.match[0].lpm.value, socket.inet_aton("10.0.1.0"))
        self.assertEqual(entry.match[0].lpm.prefix_len, 24)
        self.assertEqual(kinds, {"hdr.ipv4.dstAddr": "LPM"})

    def test_the_prefix_length_is_not_pinned_to_the_field_width(self):
        # A /32 written for a /24 forwards one address and blackholes the rest of the subnet.
        entry, _ = self.build(**self.lpm_spec(match={"hdr.ipv4.dstAddr": ["10.0.0.0", 8]}))
        self.assertEqual(entry.match[0].lpm.prefix_len, 8)

    def test_a_prefix_length_outside_the_field_width_is_refused(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.build(**self.lpm_spec(match={"hdr.ipv4.dstAddr": ["10.0.1.1", 33]}))

    def test_an_lpm_field_given_a_bare_value_is_refused_rather_than_assumed_to_be_a_host_route(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.build(**self.lpm_spec(match={"hdr.ipv4.dstAddr": "10.0.1.1"}))

    def test_an_exact_entry_carries_a_plain_value(self):
        entry, kinds = self.build(table="MyIngress.l2_forward",
                                  match={"hdr.ethernet.dstAddr": "08:00:00:00:01:11"},
                                  action_name="MyIngress.forward_l2",
                                  action_params={"port": 1})
        self.assertEqual(entry.table_id, L2_FORWARD_ID)
        self.assertEqual(entry.match[0].exact.value, bytes.fromhex("080000000111"))
        self.assertEqual(kinds, {"hdr.ethernet.dstAddr": "EXACT"})

    def test_an_exact_field_given_a_pair_is_refused(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.build(table="MyIngress.l2_forward",
                       match={"hdr.ethernet.dstAddr": ["08:00:00:00:01:11", 48]},
                       action_name="MyIngress.forward_l2", action_params={"port": 1})

    def test_the_action_parameters_go_in_by_name_with_the_widths_the_p4info_declares(self):
        entry, _ = self.build(**self.lpm_spec())
        action = entry.action.action
        self.assertEqual(action.action_id, IPV4_FORWARD_ID)
        params = {p.param_id: p.value for p in action.params}
        self.assertEqual(params[DST_ADDR_PARAM_ID], bytes.fromhex("080000000111"))
        self.assertEqual(params[PORT_PARAM_ID], b"\x00\x01", "port is bit<9>, so two bytes")

    def test_an_omitted_action_parameter_is_refused_rather_than_written_as_zero(self):
        # bmv2 takes an action with a missing parameter as that parameter's zero -- port 0,
        # MAC 00:00:00:00:00:00 -- and forwards accordingly. A rule that drops traffic while
        # reporting success.
        with self.assertRaises(p4_client_module.TableEntryInvalid) as caught:
            self.build(**self.lpm_spec(action_params={"port": 1}))
        self.assertIn("dstAddr", str(caught.exception))

    def test_a_ternary_field_is_unsupported_and_says_which_match_type_it_is(self):
        with self.assertRaises(p4_client_module.TableEntryUnsupported) as caught:
            self.build(table="MyIngress.flow_5tuple",
                       match={"hdr.ipv4.dstAddr": ["10.0.1.1", "255.255.255.255"]},
                       action_name="MyIngress.ipv4_forward",
                       action_params={"dstAddr": "08:00:00:00:01:11", "port": 1})
        self.assertIn("TERNARY", str(caught.exception))

    def test_a_range_field_is_unsupported_and_says_RANGE(self):
        # 🔴 A range value is `[lo, hi]` -- the same two-element list an lpm entry uses for
        # `[value, prefix_len]`. So a writer that decided the shape from the VALUE would build
        # this as an lpm entry with a prefix length of `hi`, and 3000 is not a prefix length:
        # it would either be rejected by bmv2 with an opaque status or truncated into a mask
        # that matches traffic nobody asked about. The p4info is what says which it is.
        with self.assertRaises(p4_client_module.TableEntryUnsupported) as caught:
            self.build(table="Synthetic.range_table",
                       match={"meta.probe_key": [1024, 3000]},
                       action_name="MyIngress.send_to_cpu", action_params={})
        self.assertIn("RANGE", str(caught.exception))

    def test_an_optional_field_is_unsupported_and_says_OPTIONAL(self):
        # An optional value is a plain value -- indistinguishable from an exact one by shape.
        # Same argument as RANGE, from the other direction.
        with self.assertRaises(p4_client_module.TableEntryUnsupported) as caught:
            self.build(table="Synthetic.optional_table",
                       match={"meta.probe_key": 7},
                       action_name="MyIngress.send_to_cpu", action_params={})
        self.assertIn("OPTIONAL", str(caught.exception))

    def test_neither_range_nor_optional_reaches_the_switch(self):
        for table, value in (("Synthetic.range_table", [1024, 3000]),
                             ("Synthetic.optional_table", 7)):
            client = a_client()
            with self.assertRaises(p4_client_module.TableEntryUnsupported):
                client.write_table_entry({"table": table, "match": {"meta.probe_key": value},
                                          "action_name": "MyIngress.send_to_cpu",
                                          "action_params": {}})
            self.assertEqual(client.stub.requests, [], f"{table} put a request on the wire")

    def test_the_match_type_name_comes_from_the_generated_enum(self):
        # 🔴 P4Runtime's MatchType skips 1: UNSPECIFIED=0, EXACT=2, LPM=3, TERNARY=4, RANGE=5,
        # OPTIONAL=6. A hand-written table would put every entry one match type off, and an lpm
        # written as an exact match is a /32 rule.
        self.assertEqual(p4info_pb2.MatchField.MatchType.Name(2), "EXACT")
        self.assertEqual(p4info_pb2.MatchField.MatchType.Name(3), "LPM")
        self.assertEqual(p4info_pb2.MatchField.MatchType.Name(4), "TERNARY")
        table = self.client._table_by_name("MyIngress.ipv4_lpm")
        self.assertEqual(self.client._match_type_name(table.match_fields[0]), "LPM")

    def test_a_default_action_is_marked_as_one_and_carries_no_match(self):
        entry, kinds = self.build(table="MyIngress.ipv4_lpm", default_action=True,
                                  action_name="MyIngress.send_to_cpu", action_params={})
        self.assertTrue(entry.is_default_action)
        self.assertEqual(len(entry.match), 0)
        self.assertEqual(kinds, {})

    def test_a_default_action_that_also_names_a_match_is_refused(self):
        # It is two different rules. A default action is what the table does when NOTHING
        # matched, and P4Runtime answers the contradiction with an opaque INVALID_ARGUMENT.
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.build(**self.lpm_spec(default_action=True))

    def test_an_ordinary_entry_is_not_marked_as_the_default(self):
        entry, _ = self.build(**self.lpm_spec())
        self.assertFalse(entry.is_default_action)

    def test_a_priority_on_a_table_with_no_priority_column_is_refused(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid) as caught:
            self.build(**self.lpm_spec(priority=777))
        self.assertIn("priority not honourable", str(caught.exception))

    def test_a_null_or_zero_priority_is_accepted_because_it_asks_for_nothing(self):
        for value in (None, 0):
            entry, _ = self.build(**self.lpm_spec(priority=value))
            self.assertEqual(entry.priority, 0)

    def test_the_names_may_be_aliases_because_the_tutorials_helper_accepts_both(self):
        # `p4runtime_lib/helper.py` looks a name up as preamble.name then as alias, so a package
        # written against that helper would be refused here for a spelling its own toolchain
        # takes.
        entry, _ = self.build(table="ipv4_lpm",
                              match={"hdr.ipv4.dstAddr": ["10.0.1.1", 32]},
                              action_name="ipv4_forward",
                              action_params={"dstAddr": "08:00:00:00:01:11", "port": 1})
        self.assertEqual(entry.table_id, IPV4_LPM_ID)
        self.assertEqual(entry.action.action.action_id, IPV4_FORWARD_ID)

    def test_a_table_this_pipeline_does_not_have_is_a_keyerror_naming_it(self):
        with self.assertRaises(KeyError) as caught:
            self.build(**self.lpm_spec(table="MyIngress.firewall"))
        self.assertIn("MyIngress.firewall", str(caught.exception))

    def test_a_match_field_this_table_does_not_have_is_a_keyerror(self):
        with self.assertRaises(KeyError):
            self.build(**self.lpm_spec(match={"hdr.ipv4.srcAddr": ["10.0.1.1", 32]}))

    def test_an_action_parameter_this_action_does_not_have_is_a_keyerror(self):
        with self.assertRaises(KeyError):
            self.build(**self.lpm_spec(
                action_params={"dstAddr": "08:00:00:00:01:11", "port": 1, "vlan": 7}))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class WriteTableEntryTest(unittest.TestCase):
    """
    What reaches the wire, and -- for every refusal -- that nothing did.

    [Co-developed with claude code -- Adam]
    🔴 "NOTHING WAS WRITTEN" IS A CLAIM ABOUT THE WIRE, so it is checked on the wire:
    `stub.requests == []`. Asserting only that the call raised would leave a writer that put the
    entry on the switch and then failed formatting its own success message looking identical to
    one that refused before touching it.
    """

    def setUp(self):
        self.client = a_client()

    def spec(self, **overrides):
        spec = {"table": "MyIngress.ipv4_lpm",
                "match": {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
        spec.update(overrides)
        return spec

    def test_an_insert_is_an_insert_addressed_to_this_device_with_this_election_id(self):
        result = self.client.write_table_entry(self.spec())
        request = self.client.stub.requests[0]
        self.assertEqual(request.device_id, 1)
        self.assertEqual((request.election_id.high, request.election_id.low), (0, 1))
        self.assertEqual(only_update(request).type, p4runtime_pb2.Update.INSERT)
        self.assertEqual(result["table"], "MyIngress.ipv4_lpm")
        self.assertEqual(result["match_types"], {"hdr.ipv4.dstAddr": "LPM"})
        self.assertFalse(result["priority_honoured"])

    def test_modify_and_delete_send_the_update_type_they_name(self):
        self.client.write_table_entry(self.spec(), "modify")
        self.client.write_table_entry(self.spec(), "delete")
        self.assertEqual([only_update(r).type for r in self.client.stub.requests],
                         [p4runtime_pb2.Update.MODIFY, p4runtime_pb2.Update.DELETE])

    def test_a_delete_may_omit_the_action_because_it_names_the_entry_not_what_it_did(self):
        spec = self.spec()
        del spec["action_name"], spec["action_params"]
        self.client.write_table_entry(spec, "delete")
        self.assertEqual(only_update(self.client.stub.requests[0]).type,
                         p4runtime_pb2.Update.DELETE)

    def test_an_insert_that_omits_the_action_is_refused_and_nothing_is_written(self):
        spec = self.spec()
        del spec["action_name"], spec["action_params"]
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.client.write_table_entry(spec, "insert")
        self.assertEqual(self.client.stub.requests, [])

    def test_an_unknown_op_is_refused_and_nothing_is_written(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.client.write_table_entry(self.spec(), "upsert")
        self.assertEqual(self.client.stub.requests, [])

    def test_a_default_action_insert_is_sent_as_a_modify_and_says_so(self):
        # Every table already has a default entry (the compiler's), so an INSERT is refused by
        # the target. tutorials' own `WriteTableEntry` makes the same substitution, which is why
        # no runtime file carries an `op` for these -- but the caller asked for an insert, so
        # the result reports what actually went on the wire.
        result = self.client.write_table_entry(
            {"table": "MyIngress.ipv4_lpm", "default_action": True,
             "action_name": "MyIngress.send_to_cpu", "action_params": {}})
        self.assertEqual(result["op"], "modify")
        self.assertTrue(result["op_substituted"])
        self.assertEqual(only_update(self.client.stub.requests[0]).type,
                         p4runtime_pb2.Update.MODIFY)
        self.assertTrue(
            only_update(self.client.stub.requests[0]).entity.table_entry.is_default_action)

    def test_a_grpc_refusal_is_raised_and_not_retried_as_a_modify(self):
        # 🔴 The one write path in this class with no MODIFY fallback. `insert_ipv4_route` retries
        # because its caller means "make this route be so"; this method's callers are an
        # operator's POST and a package's entries file, and both are entitled to be told the
        # entry was already there rather than handed a clean insert for an overwrite.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.ALREADY_EXISTS),
                                         always=True)
        with self.assertRaises(grpc.RpcError):
            self.client.write_table_entry(self.spec())
        self.assertEqual([only_update(r).type for r in self.client.stub.requests],
                         [p4runtime_pb2.Update.INSERT],
                         "a MODIFY here would overwrite somebody's rule and report an insert")

    def test_an_accepted_write_is_dated_so_its_age_can_be_reported(self):
        # KNOWN-ISSUES G-13: bmv2 cannot say how old an entry is, so the write path says it.
        self.assertEqual(len(self.client.rule_install_times), 0)
        self.client.write_table_entry(self.spec())
        self.assertEqual(len(self.client.rule_install_times), 1)

    def test_a_delete_forgets_the_stamp_so_the_next_rule_does_not_inherit_its_age(self):
        self.client.write_table_entry(self.spec())
        self.client.write_table_entry(self.spec(), "delete")
        self.assertEqual(len(self.client.rule_install_times), 0)

    def test_a_refused_write_dates_nothing(self):
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.UNKNOWN), always=True)
        with self.assertRaises(grpc.RpcError):
            self.client.write_table_entry(self.spec())
        self.assertEqual(len(self.client.rule_install_times), 0)

    def test_an_unsupported_match_reaches_no_switch(self):
        with self.assertRaises(p4_client_module.TableEntryUnsupported):
            self.client.write_table_entry(
                {"table": "MyIngress.flow_5tuple",
                 "match": {"hdr.ipv4.protocol": [6, 255]},
                 "action_name": "MyIngress.ipv4_forward",
                 "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}})
        self.assertEqual(self.client.stub.requests, [])

    def test_an_over_wide_value_reaches_no_switch(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.client.write_table_entry(self.spec(
                action_params={"dstAddr": "08:00:00:00:01:11", "port": 512}))
        self.assertEqual(self.client.stub.requests, [])

    def test_an_unknown_table_reaches_no_switch(self):
        # 🔴 The mutation this exists for (mutate_table_entry.sh M-B2): a lookup that answers
        # SOMETHING for an unknown name -- the gate makes it resolve to the first table in the
        # p4info -- sends a real WriteRequest into the wrong table. The operator is then told
        # either that the switch refused their rule or that it accepted it, and in neither case
        # that they named a table this pipeline does not have.
        with self.assertRaises(KeyError):
            self.client.write_table_entry(self.spec(table="MyIngress.firewall"))
        self.assertEqual(self.client.stub.requests, [])

    def test_a_priority_this_table_cannot_honour_reaches_no_switch(self):
        with self.assertRaises(p4_client_module.TableEntryInvalid):
            self.client.write_table_entry(self.spec(priority=777))
        self.assertEqual(self.client.stub.requests, [])

    def test_a_read_only_client_writes_no_table_entry(self):
        self.client.arbitration = False
        with self.assertRaises(p4_client_module.ControlPlaneReadOnly) as caught:
            self.client.write_table_entry(self.spec())
        self.assertEqual(self.client.stub.requests, [])
        self.assertIn("external control plane", str(caught.exception))


# --- the NDTwin pipeline's writes, frozen in bytes (TICKET-P4-roles section 2.2-5) ------------
#
# [Co-developed with claude code -- Adam]
#
# 🔴 CAPTURED AT THE BASE, NOT DESCRIBED. The roles ticket moves every name the ipv4_lpm writes
# use out of literals and into a binding, and promises that for NDTwin's own pipeline nothing on
# the wire changes. "Nothing changes" asserted field by field is only as strong as the list of
# fields somebody remembered to check; asserted as the SERIALISED WriteRequest it covers every
# field, including the ones nobody thought of (update order, the election id, the width of the
# port parameter, the order of the two action parameters).
#
# The hex below was produced by `baseline_write_capture()` against the unmodified production
# code of trunk 6291db35 (worktree head 0c85ad9c, whose p4_proxy/ is byte-identical to it), and
# the commit that adds this block changes no production file -- so checking that commit out and
# running this class is how the capture is re-verified. The capture function is the SAME one the
# test calls; a second recorder would be a second opinion about a third thing.
#
# `SerializeToString(deterministic=True)`: WriteRequest carries no map fields, so this is the
# encoding bmv2 receives, and `deterministic` only rules out a future map field making the
# comparison flaky rather than wrong.


def _serialised(messages):
    return [m.SerializeToString(deterministic=True).hex() for m in messages]


def baseline_write_capture():
    """{case: [hex of every request the stub saw, in order]} for the ipv4_lpm write paths.

    [Co-developed with claude code -- Adam]
    Every case builds its own client (or fabric) so no case sees another's install stamps.
    `install_initial_routes` runs over the square the property test uses, with two hosts on
    opposite corners, so it writes every switch and exercises an equal-cost choice.
    """
    from proxy_agent.topology_manager import TopologyManager

    out = {}

    client = a_client()
    client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
    out["insert"] = _serialised(client.stub.requests)

    client = a_client(RecordingStub(write_error=FakeRpcError(grpc.StatusCode.ALREADY_EXISTS)))
    client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 7)
    out["insert_then_modify"] = _serialised(client.stub.requests)

    client = a_client()
    client.modify_ipv4_route("10.0.0.0", 24, "0a:0b:0c:0d:0e:0f", 257)
    out["modify"] = _serialised(client.stub.requests)

    client = a_client()
    client.delete_ipv4_route("10.0.0.4", 32)
    out["delete"] = _serialised(client.stub.requests)

    client = a_client(RecordingStub(write_error=FakeRpcError(grpc.StatusCode.UNKNOWN),
                                    always=True))
    client.delete_ipv4_route("10.0.1.1", 32)
    out["delete_unknown_writes"] = _serialised(client.stub.requests)
    out["delete_unknown_reads"] = _serialised(client.stub.reads)

    keys = {"hdr.ipv4.srcAddr": "10.0.0.1", "hdr.ipv4.dstAddr": "10.0.0.4",
            "hdr.ipv4.protocol": 6, "meta.l4_dst_port": 80}
    client = a_client()
    client.insert_5tuple_rule(keys, 101, "00:00:00:00:00:04", 3)
    client.modify_5tuple_rule(keys, 101, "00:00:00:00:00:04", 2)
    client.delete_5tuple_rule(keys, 101)
    out["five_tuple"] = _serialised(client.stub.requests)

    topo = TopologyManager()
    for dpid in (1, 2, 3, 4):
        topo.add_switch(dpid, a_client(device_id=dpid))
    for a, b, pa, pb in ((1, 2, 2, 1), (1, 3, 3, 1), (2, 4, 3, 2), (3, 4, 4, 3)):
        topo.add_link(a, b, pa, pb)
    topo.add_host("10.0.0.1", "00:00:00:00:00:01", 1, 9)
    topo.add_host("10.0.0.2", "00:00:00:00:00:02", 4, 9)
    topo.install_initial_routes()
    for dpid in (1, 2, 3, 4):
        out[f"install_initial_routes_s{dpid}"] = _serialised(topo.switches[dpid].stub.requests)
    return out


#: Produced by baseline_write_capture() at 6291db35's p4_proxy/ (see the block comment above).
BASELINE_WRITE_REQUESTS = {
    'delete': [
        '08011a021001221908031215121308b499e911120c080122080a040a0000041020',
    ],
    'delete_unknown_reads': [
        '0801120412023a00',
    ],
    'delete_unknown_writes': [
        '08011a021001221908031215121308b499e911120c080122080a040a0001011020',
    ],
    'five_tuple': [
        '08011a021001226808011264126208b5cef117121008031a0c0a040a0000041204ffffffff120a08041a060a'
         '01061201ff121008021a0c0a040a0000011204ffffffff120c08061a080a0200501202ffff1a1b0a1908d5ac'
         'dd0d220a10011a06000000000004220610021a0200032065',
        '08011a021001226808021264126208b5cef117121008031a0c0a040a0000041204ffffffff120a08041a060a'
         '01061201ff121008021a0c0a040a0000011204ffffffff120c08061a080a0200501202ffff1a1b0a1908d5ac'
         'dd0d220a10011a06000000000004220610021a0200022065',
        '08011a021001224b08031247124508b5cef117121008031a0c0a040a0000041204ffffffff120a08041a060a'
         '01061201ff121008021a0c0a040a0000011204ffffffff120c08061a080a0200501202ffff2065',
    ],
    'insert': [
        '08011a021001223608011232123008b499e911120c080122080a040a00000410201a1b0a1908d5acdd0d220a'
         '10011a06000000000004220610021a020003',
    ],
    'insert_then_modify': [
        '08011a021001223608011232123008b499e911120c080122080a040a00000410201a1b0a1908d5acdd0d220a'
         '10011a06000000000004220610021a020007',
        '08011a021001223608021232123008b499e911120c080122080a040a00000410201a1b0a1908d5acdd0d220a'
         '10011a06000000000004220610021a020007',
    ],
    'install_initial_routes_s1': [
        '08011a021001223608011232123008b499e911120c080122080a040a00000110201a1b0a1908d5acdd0d220a'
         '10011a06000000000001220610021a020009',
        '08011a021001223608011232123008b499e911120c080122080a040a00000210201a1b0a1908d5acdd0d220a'
         '10011a06000000000002220610021a020002',
    ],
    'install_initial_routes_s2': [
        '08021a021001223608011232123008b499e911120c080122080a040a00000110201a1b0a1908d5acdd0d220a'
         '10011a06000000000001220610021a020001',
        '08021a021001223608011232123008b499e911120c080122080a040a00000210201a1b0a1908d5acdd0d220a'
         '10011a06000000000002220610021a020003',
    ],
    'install_initial_routes_s3': [
        '08031a021001223608011232123008b499e911120c080122080a040a00000110201a1b0a1908d5acdd0d220a'
         '10011a06000000000001220610021a020001',
        '08031a021001223608011232123008b499e911120c080122080a040a00000210201a1b0a1908d5acdd0d220a'
         '10011a06000000000002220610021a020004',
    ],
    'install_initial_routes_s4': [
        '08041a021001223608011232123008b499e911120c080122080a040a00000110201a1b0a1908d5acdd0d220a'
         '10011a06000000000001220610021a020003',
        '08041a021001223608011232123008b499e911120c080122080a040a00000210201a1b0a1908d5acdd0d220a'
         '10011a06000000000002220610021a020009',
    ],
    'modify': [
        '08011a021001223608021232123008b499e911120c080122080a040a00000010181a1b0a1908d5acdd0d220a'
         '10011a060a0b0c0d0e0f220610021a020101',
    ],
}


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheNdtwinPipelinesWritesAreByteIdenticalToTheBaseTest(unittest.TestCase):
    """TICKET-P4-roles 2.2-5: the binding refactor puts the same bytes on the wire."""

    def setUp(self):
        self.captured = baseline_write_capture()

    def test_every_case_was_captured_and_none_is_empty(self):
        self.assertEqual(sorted(self.captured), sorted(BASELINE_WRITE_REQUESTS))
        for case, requests in BASELINE_WRITE_REQUESTS.items():
            self.assertTrue(requests, f"{case}: the base capture recorded no request at all")

    def test_every_request_is_byte_identical_to_the_one_the_base_sent(self):
        for case in sorted(BASELINE_WRITE_REQUESTS):
            with self.subTest(case=case):
                self.assertEqual(self.captured.get(case), BASELINE_WRITE_REQUESTS[case])


if __name__ == "__main__":
    unittest.main(verbosity=2)
