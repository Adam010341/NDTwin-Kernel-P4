"""
The five packet_in metadata ids come from the switch's own p4info, by field name. TICKET-P3 2.6.

[Co-developed with claude code -- Adam]

🔴 WHY THIS IS NOT COSMETIC. p4c numbers a @controller_header's fields POSITIONALLY: `reason` is
1 because it is declared first. So `PKTIN_META_EGRESS_PORT = 3` is a fact about
ndtwin_switch.p4 and about no other program, and the moment a package brings its own
telemetry-carrying pipeline -- which p4_src/ndtwin_telemetry.p4 exists to make possible -- a
positional read of it does NOT fail. It reads `egress_port` where `ingress_port` is, and both
are 9-bit port numbers with plausible values, so the kernel credits every sampled byte to the
other end of the link and nothing anywhere reports an error. The twin is simply wrong, in a
direction, forever.

The p4infos here are built in memory rather than compiled, because the property under test is
"the lookup follows the names" and a compiler cannot be asked to emit a deliberately odd
ordering. The agreement with the REAL artefact is asserted separately, in
test_sflow_emitter.P4InfoAgreementTest, and against the real compiled `basic_telemetry` fixture
in tools/p4_exercise/tests/test_telemetry_include.py.

Run with:  p4_proxy/venv/bin/python -m unittest tests.test_packet_in_by_name
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    from p4.config.v1 import p4info_pb2
    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover - depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False

from proxy_agent.sflow_emitter import (  # noqa: E402
    PACKET_IN_FIELDS,
    PKTIN_META_EGRESS_PORT,
    PKTIN_META_FRAME_LENGTH,
    PKTIN_META_INGRESS_PORT,
    PKTIN_META_REASON,
    PKTIN_META_SAMPLING_RATE,
    PKTIN_REASON_SAMPLE,
    PacketInIds,
    SampledPacket,
    TelemetryHeaderMissing,
    packet_in_metadata_ids,
    packet_out_metadata_ids,
    sample_from_packet_in,
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NDTWIN_P4INFO = os.path.join(REPO_ROOT, "p4_proxy", "p4_src", "build",
                             "ndtwin_switch.p4info.txt")

#: ndtwin_switch.p4's packet_in_header_t, in declaration order. `_pad` is included because the
#: ids are positional: a fixture that dropped it would renumber nothing here but would stop
#: standing in for the artefact the moment a field moved.
NDTWIN_PACKET_IN = (("reason", 8), ("ingress_port", 9), ("egress_port", 9),
                    ("frame_length", 16), ("sampling_rate", 16), ("_pad", 6))
NDTWIN_PACKET_OUT = (("egress_port", 9), ("_pad", 7))


def a_p4info(packet_in=NDTWIN_PACKET_IN, packet_out=NDTWIN_PACKET_OUT):
    """A p4info carrying just the controller headers, with ids assigned the way p4c assigns
    them -- 1..N in declaration order. Pass `None` for a program that declares neither."""
    p4info = p4info_pb2.P4Info()
    for name, fields in (("packet_in", packet_in), ("packet_out", packet_out)):
        if fields is None:
            continue
        header = p4info.controller_packet_metadata.add()
        header.preamble.id = 1000 + len(p4info.controller_packet_metadata)
        header.preamble.name = name
        header.preamble.alias = name
        for index, (field_name, bitwidth) in enumerate(fields, start=1):
            meta = header.metadata.add()
            meta.id = index
            meta.name = field_name
            meta.bitwidth = bitwidth
    return p4info


class FakeMetadata:
    def __init__(self, metadata_id, value):
        self.metadata_id = metadata_id
        self.value = value


class FakePacketIn:
    """A PacketIn with P4Runtime's canonical encoding (leading zero bytes stripped)."""

    def __init__(self, payload: bytes, **fields: int):
        self.payload = payload
        self.metadata = [FakeMetadata(mid, self._canonical(value))
                         for mid, value in fields.values()]

    @staticmethod
    def _canonical(value: int) -> bytes:
        if value == 0:
            return b"\x00"
        return value.to_bytes((value.bit_length() + 7) // 8, "big")


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheIdsComeFromTheP4InfoTest(unittest.TestCase):
    def test_ndtwins_own_header_resolves_to_one_through_five(self):
        ids = packet_in_metadata_ids(a_p4info())
        self.assertEqual(ids, PacketInIds(reason=1, ingress_port=2, egress_port=3,
                                          frame_length=4, sampling_rate=5))
        # And those five numbers are the constants the rest of the proxy documents, so the
        # by-name lookup is a strict generalisation of what it replaced rather than a change of
        # behaviour on the fabric that exists today.
        self.assertEqual(
            (ids.reason, ids.ingress_port, ids.egress_port, ids.frame_length, ids.sampling_rate),
            (PKTIN_META_REASON, PKTIN_META_INGRESS_PORT, PKTIN_META_EGRESS_PORT,
             PKTIN_META_FRAME_LENGTH, PKTIN_META_SAMPLING_RATE))

    def test_the_real_generated_p4info_resolves_to_the_same_five(self):
        if not os.path.exists(NDTWIN_P4INFO):
            self.skipTest("p4info not built; run tools/test_workflow/l0_build_check.sh p4")
        from google.protobuf import text_format
        p4info = p4info_pb2.P4Info()
        with open(NDTWIN_P4INFO) as fh:
            text_format.Merge(fh.read(), p4info)
        self.assertEqual(packet_in_metadata_ids(p4info),
                         PacketInIds(reason=1, ingress_port=2, egress_port=3,
                                     frame_length=4, sampling_rate=5))
        self.assertEqual(packet_out_metadata_ids(p4info), {"egress_port": 1, "_pad": 2})

    def test_a_reordered_header_gives_reordered_ids(self):
        # 🔴 THE WHOLE POINT. The same five fields, declared backwards. A positional reader
        # returns the same 1..5 here and silently swaps ingress_port with sampling_rate.
        reordered = (("sampling_rate", 16), ("frame_length", 16), ("egress_port", 9),
                     ("ingress_port", 9), ("reason", 8))
        ids = packet_in_metadata_ids(a_p4info(packet_in=reordered))
        self.assertEqual(ids, PacketInIds(sampling_rate=1, frame_length=2, egress_port=3,
                                          ingress_port=4, reason=5))

    def test_an_offset_header_is_followed_rather_than_assumed(self):
        # A program that declares two fields of its own before ours pushes every id up by two.
        prefixed = (("my_flag", 8), ("my_cookie", 16)) + NDTWIN_PACKET_IN
        ids = packet_in_metadata_ids(a_p4info(packet_in=prefixed))
        self.assertEqual(ids, PacketInIds(reason=3, ingress_port=4, egress_port=5,
                                          frame_length=6, sampling_rate=7))

    def test_a_missing_field_raises_and_names_it(self):
        without_rate = tuple(f for f in NDTWIN_PACKET_IN if f[0] != "sampling_rate")
        with self.assertRaises(TelemetryHeaderMissing) as cm:
            packet_in_metadata_ids(a_p4info(packet_in=without_rate))
        self.assertEqual(cm.exception.missing, ("sampling_rate",))
        self.assertIn("sampling_rate", str(cm.exception))
        # The names that WERE there, so a reader can see it is one field rather than a pipeline
        # with no telemetry at all.
        self.assertIn("reason", cm.exception.present)

    def test_a_pipeline_with_no_controller_header_names_all_five(self):
        with self.assertRaises(TelemetryHeaderMissing) as cm:
            packet_in_metadata_ids(a_p4info(packet_in=None, packet_out=None))
        self.assertEqual(sorted(cm.exception.missing), sorted(PACKET_IN_FIELDS))
        self.assertIn("ndtwin_telemetry.p4", str(cm.exception),
                      "the refusal has to say what to do about it")

    def test_packet_out_ids_are_empty_rather_than_an_error(self):
        # A tutorials pipeline has no packet_out header, and the decision not to beacon at it is
        # made a level up. Raising here would turn a decision into an exception to catch.
        self.assertEqual(packet_out_metadata_ids(a_p4info(packet_out=None)), {})

    def test_packet_out_ids_follow_the_names_too(self):
        ids = packet_out_metadata_ids(a_p4info(packet_out=(("_pad", 7), ("egress_port", 9))))
        self.assertEqual(ids, {"_pad": 1, "egress_port": 2})


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheDecoderUsesTheIdsItIsGivenTest(unittest.TestCase):
    """`sample_from_packet_in` reads five ids and must read the ones it was handed."""

    def test_a_reordered_pipelines_sample_decodes_correctly(self):
        reordered = (("sampling_rate", 16), ("frame_length", 16), ("egress_port", 9),
                     ("ingress_port", 9), ("reason", 8))
        ids = packet_in_metadata_ids(a_p4info(packet_in=reordered))
        packet = FakePacketIn(
            b"FRAME",
            sampling_rate=(ids.sampling_rate, 256),
            frame_length=(ids.frame_length, 1514),
            egress_port=(ids.egress_port, 7),
            ingress_port=(ids.ingress_port, 3),
            reason=(ids.reason, PKTIN_REASON_SAMPLE))

        sample = sample_from_packet_in(packet, ids)
        self.assertEqual(
            (sample.ingress_port, sample.egress_port, sample.frame_length, sample.sampling_rate),
            (3, 7, 1514, 256))

    def test_the_old_positional_numbering_swaps_the_two_ports_without_complaining(self):
        # 🔴 THE NEGATIVE CONTROL, and the reason this ticket exists. A program that declares the
        # same five fields with ingress_port and egress_port the other way round decodes under
        # ndtwin's numbering into a PERFECTLY VALID SampledPacket with the two ports exchanged.
        # The kernel then credits every sampled byte to the reverse edge -- "s1 port 3 received
        # 4 MB" for traffic that left on port 3 -- and there is no downstream check that could
        # notice, because both values are ports the fabric really has.
        swapped = (("reason", 8), ("egress_port", 9), ("ingress_port", 9),
                   ("frame_length", 16), ("sampling_rate", 16), ("_pad", 6))
        real_ids = packet_in_metadata_ids(a_p4info(packet_in=swapped))
        packet = FakePacketIn(
            b"FRAME",
            reason=(real_ids.reason, PKTIN_REASON_SAMPLE),
            egress_port=(real_ids.egress_port, 7),
            ingress_port=(real_ids.ingress_port, 3),
            frame_length=(real_ids.frame_length, 1514),
            sampling_rate=(real_ids.sampling_rate, 256))

        right = sample_from_packet_in(packet, real_ids)
        self.assertEqual((right.ingress_port, right.egress_port), (3, 7))

        ndtwin_ids = packet_in_metadata_ids(a_p4info())
        wrong = sample_from_packet_in(packet, ndtwin_ids)
        self.assertIsNotNone(wrong, "the misread is silent -- that is what makes it dangerous")
        self.assertEqual((wrong.ingress_port, wrong.egress_port), (7, 3))

    def test_the_old_positional_numbering_can_also_drop_every_sample(self):
        # The other shape of the same defect. When the reordering moves `reason`, a positional
        # reader finds something that is not PKTIN_REASON_SAMPLE at id 1 and returns None -- so
        # the switch produces samples, the proxy discards all of them, and every edge reads
        # zero with no error at any step.
        reordered = (("sampling_rate", 16), ("frame_length", 16), ("egress_port", 9),
                     ("ingress_port", 9), ("reason", 8))
        real_ids = packet_in_metadata_ids(a_p4info(packet_in=reordered))
        packet = FakePacketIn(
            b"FRAME",
            sampling_rate=(real_ids.sampling_rate, 256),
            frame_length=(real_ids.frame_length, 1514),
            egress_port=(real_ids.egress_port, 7),
            ingress_port=(real_ids.ingress_port, 3),
            reason=(real_ids.reason, PKTIN_REASON_SAMPLE))

        self.assertIsNotNone(sample_from_packet_in(packet, real_ids))
        self.assertIsNone(sample_from_packet_in(packet, packet_in_metadata_ids(a_p4info())))

    def test_sample_from_packet_in_requires_the_ids(self):
        # No default. A default is invisible at the call site, so the one caller that forgot to
        # pass the switch's real numbering would look exactly like the ones that did.
        with self.assertRaises(TypeError):
            sample_from_packet_in(FakePacketIn(b"FRAME"))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheClientResolvesItsOwnIdsTest(unittest.TestCase):
    """Construction reads the p4info once; the hot path must not walk it per packet."""

    def build(self, p4info):
        from proxy_agent.p4_client import P4RuntimeClient
        client = P4RuntimeClient.__new__(P4RuntimeClient)
        client.device_id = 1
        client.p4info = p4info
        client.sample_callback = None
        client.packet_in_callback = None
        try:
            client.packet_in_ids = packet_in_metadata_ids(p4info)
            client.packet_in_ids_error = None
        except TelemetryHeaderMissing as exc:
            client.packet_in_ids = None
            client.packet_in_ids_error = str(exc)
        client.packet_out_ids = packet_out_metadata_ids(p4info)
        return client

    def test_a_foreign_pipeline_client_is_built_rather_than_refused(self):
        # `basic` and `source_routing` declare no controller header, and such a switch still has
        # to be probeable, readable and writable -- everything an `external` fabric does.
        client = self.build(a_p4info(packet_in=None, packet_out=None))
        self.assertIsNone(client.packet_in_ids)
        self.assertIn("packet_in", client.packet_in_ids_error)
        self.assertEqual(client.packet_out_ids, {})

    def test_a_packet_in_on_a_foreign_pipeline_reaches_the_discovery_path(self):
        from proxy_agent.p4_client import P4RuntimeClient
        client = self.build(a_p4info(packet_in=None, packet_out=None))
        seen, samples = [], []
        client.packet_in_callback = lambda dpid, port, payload: seen.append((dpid, port, payload))
        client.sample_callback = lambda dpid, s: samples.append(s)

        P4RuntimeClient.handle_packet_in(client, FakePacketIn(b"LLDP"))

        self.assertEqual(samples, [], "there is no numbering with which to read a sample")
        self.assertEqual(seen, [(1, 0, b"LLDP")])

    def test_a_sample_is_decoded_with_this_switchs_own_numbering(self):
        from proxy_agent.p4_client import P4RuntimeClient
        reordered = (("sampling_rate", 16), ("frame_length", 16), ("egress_port", 9),
                     ("ingress_port", 9), ("reason", 8))
        client = self.build(a_p4info(packet_in=reordered))
        samples = []
        client.sample_callback = lambda dpid, s: samples.append(s)
        ids = client.packet_in_ids
        packet = FakePacketIn(
            b"FRAME",
            sampling_rate=(ids.sampling_rate, 256),
            frame_length=(ids.frame_length, 900),
            egress_port=(ids.egress_port, 4),
            ingress_port=(ids.ingress_port, 2),
            reason=(ids.reason, PKTIN_REASON_SAMPLE))

        P4RuntimeClient.handle_packet_in(client, packet)

        self.assertEqual(len(samples), 1)
        self.assertIsInstance(samples[0], SampledPacket)
        self.assertEqual((samples[0].ingress_port, samples[0].egress_port), (2, 4))

    def test_the_ids_are_disclosable_by_name(self):
        # `GET /p4/switch_state` publishes them, because "the proxy reads egress_port as id 3"
        # stopped being something a reader can look up in the source.
        ids = packet_in_metadata_ids(a_p4info())
        self.assertEqual(ids.as_dict(),
                         {"reason": 1, "ingress_port": 2, "egress_port": 3,
                          "frame_length": 4, "sampling_rate": 5})


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ThePacketOutIsByteIdenticalOnNdtwinsPipelineTest(unittest.TestCase):
    """The LLDP beacon is the one packet this proxy PUTS on the fabric. Its encoding may not
    move, or discovery stops and the graph is empty with nothing logged."""

    def client(self, p4info):
        import queue
        from proxy_agent.p4_client import P4RuntimeClient
        client = P4RuntimeClient.__new__(P4RuntimeClient)
        client.device_id = 1
        client.p4info = p4info
        client.arbitration = True
        client.stream_out_q = queue.Queue()
        client.packet_out_ids = packet_out_metadata_ids(p4info)
        return client

    def test_ndtwins_beacon_still_uses_ids_one_and_two(self):
        from proxy_agent.p4_client import P4RuntimeClient
        client = self.client(a_p4info())
        P4RuntimeClient.send_packet_out(client, 3, b"beacon")
        request = client.stream_out_q.get_nowait()
        metadata = {m.metadata_id: m.value for m in request.packet.metadata}
        self.assertEqual(sorted(metadata), [1, 2])
        self.assertEqual(metadata[1], b"\x00\x03")
        self.assertEqual(metadata[2], b"\x00")
        self.assertEqual(request.packet.payload, b"beacon")

    def test_a_reordered_packet_out_header_is_followed(self):
        from proxy_agent.p4_client import P4RuntimeClient
        client = self.client(a_p4info(packet_out=(("_pad", 7), ("egress_port", 9))))
        P4RuntimeClient.send_packet_out(client, 3, b"beacon")
        metadata = {m.metadata_id: m.value
                    for m in client.stream_out_q.get_nowait().packet.metadata}
        self.assertEqual(metadata[2], b"\x00\x03", "egress_port is id 2 in this program")
        self.assertEqual(metadata[1], b"\x00")

    def test_a_header_with_no_pad_sends_no_pad(self):
        # Sending a metadata id the program does not declare is refused by PI, so the pad is
        # conditional rather than assumed.
        from proxy_agent.p4_client import P4RuntimeClient
        client = self.client(a_p4info(packet_out=(("egress_port", 9),)))
        P4RuntimeClient.send_packet_out(client, 5, b"beacon")
        metadata = {m.metadata_id: m.value
                    for m in client.stream_out_q.get_nowait().packet.metadata}
        self.assertEqual(metadata, {1: b"\x00\x05"})

    def test_a_pipeline_with_no_packet_out_header_refuses_rather_than_inventing_an_id(self):
        from proxy_agent.p4_client import P4RuntimeClient
        client = self.client(a_p4info(packet_out=None))
        with self.assertRaises(TelemetryHeaderMissing):
            P4RuntimeClient.send_packet_out(client, 3, b"beacon")
        self.assertTrue(client.stream_out_q.empty(), "nothing may be queued for a refusal")


if __name__ == "__main__":
    unittest.main(verbosity=2)
