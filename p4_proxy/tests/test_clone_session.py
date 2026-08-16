"""
Tests for the PRE clone session and CPU-packet dispatch.

[Co-developed with claude code -- Adam]

These need the P4Runtime protobufs, so they are skipped where those are not installed. Run
them with the p4dev interpreter:

    PYTHONPATH=p4_proxy /home/adam/p4dev-python-venv/bin/python3 \
        p4_proxy/tests/test_clone_session.py

The clone session is worth its own tests because getting it wrong is silent in both
directions: bmv2 drops a clone to an unconfigured session without an error, and PI rejects
some field combinations in ways that surface only as a gRPC status nobody reads. There is no
bmv2 here, so what is asserted is the *request* -- that the bytes going onto the wire say what
we think they say -- which is the part a live test would not tell us any more precisely.
"""

from __future__ import annotations

import os
import queue
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# A bare `raise unittest.SkipTest(...)` at module level does not actually skip gracefully: it
# is an uncaught exception during import, which exits nonzero exactly like the ImportError it
# replaces. The condition has to survive until unittest can act on it via skipUnless.
try:
    import grpc  # noqa: F401
    from p4.v1 import p4runtime_pb2
    from proxy_agent.p4_client import (
        CPU_PORT,
        SAMPLE_SESSION_ID,
        P4RuntimeClient,
    )

    class FakeRpcError(grpc.RpcError):
        """
        Must derive from grpc.RpcError, or the client's `except grpc.RpcError` will not catch
        it and the test would exercise a path that cannot happen in production.
        """

        def __init__(self, code):
            self._code = code

        def code(self):
            return self._code

        def details(self):
            return "fake"

    HAVE_P4RUNTIME = True
except ImportError:
    HAVE_P4RUNTIME = False

from proxy_agent.sflow_emitter import (  # noqa: E402
    PKTIN_META_EGRESS_PORT,
    PKTIN_META_FRAME_LENGTH,
    PKTIN_META_INGRESS_PORT,
    PKTIN_META_REASON,
    PKTIN_META_SAMPLING_RATE,
    PKTIN_REASON_PACKET_IN,
    PKTIN_REASON_SAMPLE,
)


class RecordingStub:
    """
    Captures WriteRequests instead of sending them, and can be told to fail.

    `always` distinguishes the two cases that matter for the INSERT/MODIFY fallback: failing
    once models an existing session (INSERT rejected, MODIFY accepted), while failing every
    time models a switch that genuinely cannot take the session. Without the distinction the
    "real failure is reported" test would pass for the wrong reason, because its MODIFY retry
    would quietly succeed.
    """

    def __init__(self, error=None, always=False, times=1, fail_calls=None):
        self.requests = []
        # [Co-developed with claude code -- Adam]
        # Recorded, and `timeout` accepted, because the real gRPC stub has always taken one. This
        # double was narrower than the interface it stands in for, so all eleven tests here broke
        # with `TypeError: Write() got an unexpected keyword argument 'timeout'` the moment
        # production started passing a deadline -- a correct change turned into a test failure by
        # the test's own scaffolding. The identical fix was made in test_p4_client_writes.py at the
        # time; this file's separate stub was missed, and the miss survived because an interpreter
        # without grpc skips every test in here and reports the suite as OK.
        self.write_timeouts = []
        self.error = error
        # With the DELETE-first reset, "an existing session" costs *two* failures before the
        # MODIFY fallback is reached (the DELETE eats the first). `times` says how many calls
        # fail; the default 1 now models a first boot, where only the DELETE fails.
        self.remaining_failures = float("inf") if always else times
        # `fail_calls` targets failures by 0-based call index instead, for the settle pair:
        # its writes come *after* a successful registration, which leading-failure counting
        # cannot reach.
        self.fail_calls = set(fail_calls or ())
        self._call_no = -1

    def Write(self, request, timeout=None):
        self._call_no += 1
        self.requests.append(request)
        self.write_timeouts.append(timeout)
        if self.fail_calls:
            if self._call_no in self.fail_calls:
                raise self.error
            return
        if self.error is not None and self.remaining_failures > 0:
            self.remaining_failures -= 1
            raise self.error


def a_client() -> P4RuntimeClient:
    """
    A client with no gRPC channel.

    __init__ opens a channel and reads a p4info, neither of which these tests need, so the
    object is built without running it. That is deliberate: requiring a p4info file here would
    couple these tests to a generated artefact that is gitignored.
    """
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = 1
    client.stub = RecordingStub()
    client.packet_in_callback = None
    client.sample_callback = None
    return client


class FakeStream:
    """
    Stands in for the StreamChannel bidirectional call that start() opens.

    Iterable and immediately exhausted: start() hands the stream to a receiver thread that
    iterates it, so a non-iterable stand-in makes that thread raise and print a traceback
    that looks like a test failure without being one.
    """

    def __iter__(self):
        return iter(())

    def cancel(self):
        pass


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class StartOrderingTest(unittest.TestCase):
    """
    start(push_config=False) must not program the clone session.

    The clone session lives in the pipeline's PRE, so bmv2 rejects it with FAILED_PRECONDITION
    ("No forwarding pipeline config set for this device") when no pipeline is loaded. main.py
    starts every switch with push_config=False so it can batch the pipeline pushes and then
    programs the sessions itself, so a write from inside start() is always too early -- it
    failed on all ten switches in a live run.
    """

    def a_startable_client(self):
        client = a_client()
        client.is_running = False
        client.json_path = "/nonexistent/pipeline.json"
        client.stream_out_q = queue.Queue()
        client.stream = None
        client.stream_recv_thread = None
        client.p4info_helper = None

        self.pipeline_pushes = 0
        self.clone_writes = 0

        def fake_push():
            self.pipeline_pushes += 1

        def fake_clone(*args, **kwargs):
            self.clone_writes += 1
            # Record ordering, not just counts: a clone write is only valid after a push.
            self.order.append(("clone", self.pipeline_pushes))
            return True

        self.order = []
        client.set_forwarding_pipeline_config = lambda: (
            fake_push(), self.order.append(("push", None)))[0]
        client.write_clone_session = fake_clone
        client.stub.StreamChannel = lambda _it: FakeStream()
        return client

    def test_push_config_false_does_not_write_the_clone_session(self):
        client = self.a_startable_client()
        client.start(push_config=False)

        self.assertEqual(self.pipeline_pushes, 0, "no pipeline should have been pushed")
        self.assertEqual(self.clone_writes, 0,
                         "the clone session would be rejected with FAILED_PRECONDITION here; "
                         "the caller programs it after its own batched push")

    def test_push_config_true_writes_the_clone_session_after_the_push(self):
        client = self.a_startable_client()
        client.start(push_config=True)

        self.assertEqual(self.pipeline_pushes, 1)
        self.assertEqual(self.clone_writes, 1)
        self.assertEqual(self.order, [("push", None), ("clone", 1)],
                         "the clone session must come after the pipeline push, never before")


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class CloneSessionRequestTest(unittest.TestCase):
    def setUp(self):
        self.client = a_client()

    def types(self):
        return [r.updates[0].type for r in self.client.stub.requests]

    def sent(self):
        # Happy path: best-effort DELETE, registration INSERT, then the settle pair
        # (DELETE+INSERT) that collapses a possibly-stacked group to one replica. The
        # settle INSERT (last) is the write the switch is left holding, so content is
        # asserted on it.
        self.assertEqual(self.types(),
                         [p4runtime_pb2.Update.DELETE, p4runtime_pb2.Update.INSERT,
                          p4runtime_pb2.Update.DELETE, p4runtime_pb2.Update.INSERT])
        return self.client.stub.requests[3]

    def session(self):
        update = self.sent().updates[0]
        return update.entity.packet_replication_engine_entry.clone_session_entry

    def test_installs_the_session_the_pipeline_clones_to(self):
        self.assertTrue(self.client.write_clone_session())
        # A mismatch with SAMPLE_SESSION in ndtwin_switch.p4 means every clone is dropped.
        self.assertEqual(self.session().session_id, SAMPLE_SESSION_ID)
        self.assertEqual(self.session().session_id, 250)

    def test_the_replica_targets_the_cpu_port(self):
        self.client.write_clone_session()
        replicas = self.session().replicas
        self.assertEqual(len(replicas), 1, "a second replica would duplicate every sample")
        self.assertEqual(replicas[0].egress_port, CPU_PORT)
        self.assertEqual(replicas[0].instance, 1)

    def test_sets_only_one_of_the_port_kind_oneof(self):
        # Replica.port_kind is a oneof: egress_port is the uint32 form, port a bytestring.
        # PI dispatches on which one is set, so setting the wrong one sends a port id it would
        # try to read as bytes.
        self.client.write_clone_session()
        self.assertEqual(self.session().replicas[0].WhichOneof("port_kind"), "egress_port")

    def test_class_of_service_stays_zero(self):
        # PI rejects a non-zero class_of_service as unsupported.
        self.client.write_clone_session()
        self.assertEqual(self.session().class_of_service, 0)

    def test_does_not_truncate_on_the_switch(self):
        # 0 means no truncation. The emitter truncates instead; it is the side with tests.
        self.client.write_clone_session()
        self.assertEqual(self.session().packet_length_bytes, 0)

    def test_is_an_insert_addressed_to_this_device(self):
        self.client.write_clone_session()
        self.assertEqual(self.sent().device_id, 1)
        self.assertEqual(self.sent().election_id.low, 1)
        self.assertEqual(self.sent().updates[0].type, p4runtime_pb2.Update.INSERT)

    def test_deletes_the_leftover_session_before_inserting(self):
        # Best-effort hygiene for the cases it can reach (a session the server still has in
        # its bookkeeping). The raw-client repro showed this DELETE cannot reach a
        # cross-commit orphan -- that is the settle pair's job below -- but where it does
        # land it must address the same session the INSERT recreates.
        self.client.write_clone_session()

        delete = self.client.stub.requests[0]
        self.assertEqual(delete.updates[0].type, p4runtime_pb2.Update.DELETE)
        self.assertEqual(
            delete.updates[0].entity.packet_replication_engine_entry.clone_session_entry
            .session_id, SAMPLE_SESSION_ID,
            "the DELETE must address the same session the INSERT recreates")

    def test_a_failed_delete_is_the_normal_first_boot_and_is_tolerated(self):
        # On a fresh switch there is nothing to delete; the DELETE fails and the INSERT must
        # proceed as if nothing happened.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.NOT_FOUND))
        self.assertTrue(self.client.write_clone_session())
        self.assertEqual(self.types(),
                         [p4runtime_pb2.Update.DELETE, p4runtime_pb2.Update.INSERT,
                          p4runtime_pb2.Update.DELETE, p4runtime_pb2.Update.INSERT])

    def test_an_existing_session_is_modified_rather_than_failing(self):
        # A proxy restart against live switches must reconfigure, not refuse to start. Two
        # failures: the DELETE eats the first, the INSERT the second, then MODIFY lands --
        # and the settle pair still follows, because the MODIFY path holds the session in
        # the bookkeeping just the same.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.ALREADY_EXISTS), times=2)
        self.assertTrue(self.client.write_clone_session())

        self.assertEqual(self.types(), [p4runtime_pb2.Update.DELETE,
                                        p4runtime_pb2.Update.INSERT,
                                        p4runtime_pb2.Update.MODIFY,
                                        p4runtime_pb2.Update.DELETE,
                                        p4runtime_pb2.Update.INSERT])

    def test_the_code_bmv2_actually_returns_also_falls_back_to_modify(self):
        # This is the case that matters, and the one the original ALREADY_EXISTS-only check
        # missed. Measured against a real bmv2: inserting an existing clone session returns
        # UNKNOWN with an empty details string, not ALREADY_EXISTS. MODIFY then succeeds.
        #
        # With the old check, every switch reported "clone session failed, NO telemetry from it"
        # on a proxy restart while the session was in fact perfectly good -- the exact scenario
        # the fallback exists for.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.UNKNOWN), times=2)
        self.assertTrue(self.client.write_clone_session())

        self.assertEqual(self.types(), [p4runtime_pb2.Update.DELETE,
                                        p4runtime_pb2.Update.INSERT,
                                        p4runtime_pb2.Update.MODIFY,
                                        p4runtime_pb2.Update.DELETE,
                                        p4runtime_pb2.Update.INSERT])

    def test_any_insert_failure_is_retried_as_modify(self):
        # Deliberately not code-specific: PI/bmv2 has already surprised us once about which
        # status a duplicate produces, and being narrow is what hid the bug. Nothing is masked,
        # because a genuine failure fails the MODIFY too (see the next test).
        for code in (grpc.StatusCode.INVALID_ARGUMENT, grpc.StatusCode.UNKNOWN,
                     grpc.StatusCode.ALREADY_EXISTS):
            client = a_client()
            client.stub = RecordingStub(FakeRpcError(code), times=2)
            self.assertTrue(client.write_clone_session(), f"no MODIFY retry after {code.name}")

    def test_a_real_failure_is_reported_rather_than_swallowed(self):
        # Returning True here would leave the proxy believing telemetry works when no sample
        # will ever arrive -- the exact failure this phase exists to remove.
        #
        # always=True is the point: the fallback retries every INSERT failure as a MODIFY, so a
        # stub that fails a bounded number of times would let a later attempt succeed and this
        # would pass without testing anything.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.INTERNAL), always=True)
        self.assertFalse(self.client.write_clone_session())

        self.assertEqual(self.types(), [p4runtime_pb2.Update.DELETE,
                                        p4runtime_pb2.Update.INSERT,
                                        p4runtime_pb2.Update.MODIFY],
                         "all three should have been attempted before giving up")

    def test_a_custom_session_and_port_are_honoured(self):
        self.client.write_clone_session(session_id=300, egress_port=64)
        self.assertEqual(self.session().session_id, 300)
        self.assertEqual(self.session().replicas[0].egress_port, 64)
        # Every write of the sequence must address the same custom session -- a settle pair
        # aimed at the default id would tear down the wrong session and leave the stacked
        # one alone.
        for req in self.client.stub.requests:
            self.assertEqual(
                req.updates[0].entity.packet_replication_engine_entry.clone_session_entry
                .session_id, 300)

    # --- the settle pair -----------------------------------------------------------
    # Raw-client repro, 2026-08-16 (doc/audit/2026-08-16_clone-stacking-raw-repro.md):
    # a pipeline commit empties the server's clone bookkeeping while the PRE group
    # survives, so the next INSERT appends a replica (1 -> 2 -> 3 across restarts) and a
    # DELETE issued after the commit cannot reach the orphan. Phase E found the one
    # deletion that can: with the session registered, DELETE destroys the whole backing
    # group, stacked replicas included. Hence: after every successful registration,
    # DELETE + INSERT once more, leaving exactly one replica on every path.

    def test_the_settle_pair_recreates_exactly_what_was_registered(self):
        self.assertTrue(self.client.write_clone_session())
        requests = self.client.stub.requests
        self.assertEqual(requests[3], requests[1],
                         "the settle INSERT must be byte-identical to the registration "
                         "INSERT, or the heal changes the session it just installed")
        self.assertEqual(requests[2].updates[0].type, p4runtime_pb2.Update.DELETE)

    def test_a_settle_delete_failure_is_reported_not_swallowed(self):
        # After a successful registration the bookkeeping holds the session, so this DELETE
        # failing is a real failure -- answering True would hand back a session that may
        # still multiply every sample, the exact lie the reconciliation harness caught.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.INTERNAL),
                                         fail_calls={2})
        self.assertFalse(self.client.write_clone_session())

    def test_a_settle_insert_failure_is_reported_not_swallowed(self):
        # Worse than the delete failing: the group is gone and nothing recreates it, so no
        # telemetry at all. Must be False.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.INTERNAL),
                                         fail_calls={3})
        self.assertFalse(self.client.write_clone_session())

    def test_the_session_id_is_inside_the_range_pi_accepts(self):
        # PI validates 1 <= session_id < 32768 (pre_clone_mgr.h) and rejects anything else.
        self.assertGreaterEqual(SAMPLE_SESSION_ID, 1)
        self.assertLess(SAMPLE_SESSION_ID, 32768)


class Meta:
    def __init__(self, metadata_id, value):
        self.metadata_id = metadata_id
        self.value = value


class Pkt:
    """
    Stands in for a P4Runtime PacketIn.

    Takes (id, value) pairs rather than keyword arguments because the ids are integers, and
    encodes each value the way P4Runtime does -- canonical byte strings with leading zeros
    stripped, so the width varies with the value.
    """

    def __init__(self, payload, *fields):
        self.payload = payload
        self.metadata = [Meta(i, v.to_bytes(max(1, (v.bit_length() + 7) // 8), "big"))
                         for i, v in fields]


def a_sample_packet(payload=b"FRAME", ingress=3, egress=7, frame_length=1514, rate=256):
    return Pkt(payload,
               (PKTIN_META_REASON, PKTIN_REASON_SAMPLE),
               (PKTIN_META_INGRESS_PORT, ingress),
               (PKTIN_META_EGRESS_PORT, egress),
               (PKTIN_META_FRAME_LENGTH, frame_length),
               (PKTIN_META_SAMPLING_RATE, rate))


def a_discovery_packet(payload=b"LLDP", ingress=4):
    return Pkt(payload,
               (PKTIN_META_REASON, PKTIN_REASON_PACKET_IN),
               (PKTIN_META_INGRESS_PORT, ingress))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class PacketInDispatchTest(unittest.TestCase):
    """
    Samples and genuine packet-ins share one channel, and must not cross over.

    A sample reaching the LLDP parser is not merely wasteful: sampling is 1-in-256 of *all*
    traffic, so discovery would be handed a flood of frames it cannot use. A packet-in reaching
    the telemetry path would invent flows the network does not have.
    """

    def setUp(self):
        self.client = a_client()
        self.samples = []
        self.packet_ins = []
        self.client.sample_callback = lambda dpid, s: self.samples.append((dpid, s))
        self.client.packet_in_callback = \
            lambda dpid, port, payload: self.packet_ins.append((dpid, port, payload))

    def test_a_sample_goes_to_the_telemetry_path_only(self):
        self.client.handle_packet_in(a_sample_packet())

        self.assertEqual(len(self.samples), 1)
        self.assertEqual(self.packet_ins, [], "a sample reached the LLDP parser")
        dpid, sample = self.samples[0]
        self.assertEqual(dpid, 1)
        self.assertEqual(sample.ingress_port, 3)
        self.assertEqual(sample.egress_port, 7)
        self.assertEqual(sample.frame_length, 1514)
        self.assertEqual(sample.sampling_rate, 256)
        self.assertEqual(sample.frame, b"FRAME")

    def test_a_genuine_packet_in_goes_to_the_discovery_path_only(self):
        self.client.handle_packet_in(a_discovery_packet())

        self.assertEqual(self.samples, [], "a packet-in was treated as telemetry")
        self.assertEqual(self.packet_ins, [(1, 4, b"LLDP")])

    def test_ingress_port_is_read_from_the_right_metadata_id(self):
        # ingress_port moved from id 1 to id 2 when `reason` was added. Reading id 1 would
        # report the reason code as a port number -- 0 or 1, both plausible-looking.
        self.client.handle_packet_in(a_discovery_packet(ingress=9))
        self.assertEqual(self.packet_ins[0][1], 9)

    def test_missing_callbacks_do_not_raise(self):
        # The proxy registers these after construction, so a packet arriving in between must
        # not kill the stream receiver thread.
        self.client.sample_callback = None
        self.client.packet_in_callback = None
        self.client.handle_packet_in(a_sample_packet())
        self.client.handle_packet_in(a_discovery_packet())


if __name__ == "__main__":
    unittest.main(verbosity=2)
