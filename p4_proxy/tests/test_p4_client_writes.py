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
IPV4_FORWARD_ID = 28792405
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
    field = table.match_fields.add()
    field.id = DST_ADDR_FIELD_ID
    field.name = "hdr.ipv4.dstAddr"

    forward = p4info.actions.add()
    forward.preamble.id = IPV4_FORWARD_ID
    forward.preamble.name = "MyIngress.ipv4_forward"
    param = forward.params.add()
    param.id = DST_ADDR_PARAM_ID
    param.name = "dstAddr"
    param = forward.params.add()
    param.id = PORT_PARAM_ID
    param.name = "port"

    cpu = p4info.actions.add()
    cpu.preamble.id = SEND_TO_CPU_ID
    cpu.preamble.name = "MyIngress.send_to_cpu"

    counter = p4info.counters.add()
    counter.preamble.id = EGRESS_COUNTER_ID
    counter.preamble.name = "MyEgress.egress_port_counter"

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
    client.stub = stub if stub is not None else RecordingStub()
    client.packet_in_callback = None
    client.sample_callback = None
    client.is_running = False
    client.stream_recv_thread = None
    client.stream_out_q = queue.Queue()
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
