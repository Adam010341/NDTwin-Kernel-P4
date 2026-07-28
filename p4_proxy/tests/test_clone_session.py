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
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import grpc  # noqa: F401
    from p4.v1 import p4runtime_pb2
except ImportError:  # pragma: no cover
    raise unittest.SkipTest("P4Runtime protobufs not available in this interpreter")

from proxy_agent.p4_client import (  # noqa: E402
    CPU_PORT,
    SAMPLE_SESSION_ID,
    P4RuntimeClient,
)
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
    """Captures WriteRequests instead of sending them, and can be told to fail."""

    def __init__(self, error=None):
        self.requests = []
        self.error = error

    def Write(self, request):
        self.requests.append(request)
        if self.error is not None:
            error, self.error = self.error, None  # fail once, then succeed
            raise error


class FakeRpcError(grpc.RpcError):
    """
    Must derive from grpc.RpcError, or the client's `except grpc.RpcError` will not catch it and
    the test would exercise a path that cannot happen in production.
    """

    def __init__(self, code):
        self._code = code

    def code(self):
        return self._code

    def details(self):
        return "fake"


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


class CloneSessionRequestTest(unittest.TestCase):
    def setUp(self):
        self.client = a_client()

    def sent(self):
        self.assertEqual(len(self.client.stub.requests), 1)
        return self.client.stub.requests[0]

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

    def test_an_existing_session_is_modified_rather_than_failing(self):
        # A proxy restart against live switches must reconfigure, not refuse to start.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.ALREADY_EXISTS))
        self.assertTrue(self.client.write_clone_session())

        types = [r.updates[0].type for r in self.client.stub.requests]
        self.assertEqual(types, [p4runtime_pb2.Update.INSERT, p4runtime_pb2.Update.MODIFY])

    def test_a_real_failure_is_reported_rather_than_swallowed(self):
        # Returning True here would leave the proxy believing telemetry works when no sample
        # will ever arrive -- the exact failure this phase exists to remove.
        self.client.stub = RecordingStub(FakeRpcError(grpc.StatusCode.INTERNAL))
        self.assertFalse(self.client.write_clone_session())

    def test_a_custom_session_and_port_are_honoured(self):
        self.client.write_clone_session(session_id=300, egress_port=64)
        self.assertEqual(self.session().session_id, 300)
        self.assertEqual(self.session().replicas[0].egress_port, 64)

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
