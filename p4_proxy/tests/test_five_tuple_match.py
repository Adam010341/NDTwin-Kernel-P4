"""
Tests for the match -> table decision that wires up flow_5tuple.

[Co-developed with claude code -- Adam]

## What was wrong

`ndtwin_switch.p4:307` has carried a six-key ternary `flow_5tuple` table with real priority and
its own counter since the pipeline was written. Nothing on the proxy side ever compiled to it.
`HONOURED_MATCH_FIELDS` was `{nw_dst, ipv4_dst}`, so any match naming a source address, a
protocol or an L4 port was refused with a 400 reading "ipv4_lpm keys on the destination address
only" -- accurate about the table being written, and misleading about the pipeline, which could
express the rule the whole time.

## The two assertions that carry this file

1. **A destination-only match must still go to ipv4_lpm.** Every route in the fabric is
   destination-only. Routing them through a ternary table instead would change the forwarding
   behaviour of the entire fabric to deliver a feature nobody asked for, and it would do it
   invisibly -- the rules would still be installed and traffic would still flow.
2. **Two spellings of one key with different values must raise.** `nw_src` and `ipv4_src` map to
   the same P4 field; resolving a disagreement by dict order installs a rule the caller did not
   ask for, in the one table people reach for precisely when they need exactness.
"""

from __future__ import annotations

import os
import sys
import unittest

# The package root, not proxy_agent/: topology_manager does `from proxy_agent import
# ryu_topology`, so it must be importable as a package member. Same convention as
# test_readopt.py and test_flowentry_endpoints.py.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent import topology_manager as tm  # noqa: E402


class NeedsFiveTupleTest(unittest.TestCase):
    def test_destination_only_stays_on_ipv4_lpm(self):
        # THE load-bearing one. If this flips, every route in the fabric silently moves to a
        # different table and nothing in the logs says so.
        for match in ({"nw_dst": "10.0.0.1"},
                      {"ipv4_dst": "10.0.0.1"},
                      {"dl_type": 2048, "nw_dst": "10.0.0.1"},
                      {"eth_type": 0x0800, "ipv4_dst": "10.0.0.1"}):
            with self.subTest(match=match):
                self.assertFalse(tm.needs_five_tuple(match),
                                 f"{match} would have been diverted off ipv4_lpm")

    def test_any_field_beyond_destination_selects_five_tuple(self):
        for match in ({"nw_dst": "10.0.0.1", "nw_src": "10.0.0.2"},
                      {"nw_dst": "10.0.0.1", "ip_proto": 6},
                      {"nw_dst": "10.0.0.1", "tcp_dst": 80},
                      {"in_port": 3},
                      {"udp_src": 53}):
            with self.subTest(match=match):
                self.assertTrue(tm.needs_five_tuple(match),
                                f"{match} would have been squeezed into a destination-only table")

    def test_a_non_dict_is_not_a_five_tuple_match(self):
        # needs_five_tuple runs before validation in some call orders; it must not raise here,
        # because the caller's error path is UnsupportedMatchError from the validator, and an
        # AttributeError escaping instead is how this file's neighbours became 500s.
        for junk in (None, [], "nw_dst", 7):
            with self.subTest(junk=junk):
                self.assertFalse(tm.needs_five_tuple(junk))


class UnsupportedFieldsTest(unittest.TestCase):
    def test_five_tuple_fields_are_no_longer_refused(self):
        match = {"dl_type": 2048, "nw_src": "10.0.0.2", "nw_dst": "10.0.0.1",
                 "nw_proto": 6, "tp_src": 1234, "tp_dst": 80, "in_port": 2}
        self.assertEqual(tm.unsupported_match_fields(match), [])

    def test_genuinely_unsupported_fields_are_still_refused(self):
        # The refusal must survive: the pipeline has no L2 or VLAN keys in this table, and
        # quietly servicing such a rule as if it were IPv4 is the failure the refusal exists for.
        match = {"nw_dst": "10.0.0.1", "dl_src": "00:00:00:00:00:01", "vlan_vid": 100}
        self.assertEqual(tm.unsupported_match_fields(match), ["dl_src", "vlan_vid"])

    def test_a_non_ipv4_eth_type_is_still_refused(self):
        self.assertEqual(tm.unsupported_match_fields({"dl_type": 0x0806}), ["dl_type"])

    def test_a_non_dict_match_still_raises_the_400_subclass(self):
        with self.assertRaises(tm.MalformedMatchError):
            tm.unsupported_match_fields(["nw_dst"])


class FiveTupleKeysTest(unittest.TestCase):
    def test_each_accepted_spelling_maps_to_its_p4_key(self):
        keys = tm.five_tuple_keys({"in_port": 2, "nw_src": "10.0.0.2", "nw_dst": "10.0.0.1",
                                   "nw_proto": 6, "tp_src": 1234, "tp_dst": 80})
        self.assertEqual(keys, {
            "standard_metadata.ingress_port": 2,
            "hdr.ipv4.srcAddr": "10.0.0.2",
            "hdr.ipv4.dstAddr": "10.0.0.1",
            "hdr.ipv4.protocol": 6,
            "meta.l4_src_port": 1234,
            "meta.l4_dst_port": 80,
        })

    def test_of13_spellings_reach_the_same_keys(self):
        of10 = tm.five_tuple_keys({"nw_src": "10.0.0.2", "nw_proto": 6, "tp_dst": 80})
        of13 = tm.five_tuple_keys({"ipv4_src": "10.0.0.2", "ip_proto": 6, "tcp_dst": 80})
        self.assertEqual(of10, of13)

    def test_tcp_and_udp_ports_share_one_key(self):
        # The pipeline parses either L4 header into the same metadata field; the protocol key is
        # what distinguishes them.
        self.assertEqual(tm.five_tuple_keys({"tcp_dst": 80}),
                         tm.five_tuple_keys({"udp_dst": 80}))

    def test_two_spellings_disagreeing_raises_rather_than_picking_one(self):
        with self.assertRaises(tm.UnsupportedMatchError):
            tm.five_tuple_keys({"nw_src": "10.0.0.2", "ipv4_src": "10.0.0.9"})

    def test_two_spellings_agreeing_is_fine(self):
        # Redundant but not contradictory: refusing this would reject a caller who merely sent
        # both vocabularies for safety.
        self.assertEqual(tm.five_tuple_keys({"nw_src": "10.0.0.2", "ipv4_src": "10.0.0.2"}),
                         {"hdr.ipv4.srcAddr": "10.0.0.2"})

    def test_fields_outside_the_map_are_dropped_not_guessed(self):
        # eth_type is validated elsewhere and is a tautology for this table; it must not become
        # a key. Anything genuinely unsupported was already refused by the validator.
        self.assertEqual(tm.five_tuple_keys({"dl_type": 2048, "nw_dst": "10.0.0.1"}),
                         {"hdr.ipv4.dstAddr": "10.0.0.1"})


class EncodeTernaryValueTest(unittest.TestCase):
    """
    The wire encoding of a single flow_5tuple key.

    P4Runtime encodes a bit<N> field in ceil(N/8) bytes and bmv2 rejects the wrong width
    outright, so these widths are load-bearing rather than cosmetic.
    """

    @classmethod
    def setUpClass(cls):
        try:
            from proxy_agent.p4_client import P4RuntimeClient
        except Exception as exc:            # grpc / p4runtime stubs absent
            raise unittest.SkipTest(f"p4_client not importable: {exc}")
        cls.enc = P4RuntimeClient._encode_5tuple_value

    def test_ipv4_addresses_encode_as_four_bytes(self):
        v, m = self.enc("hdr.ipv4.srcAddr", "10.0.0.2")
        self.assertEqual(v, b"\x0a\x00\x00\x02")
        self.assertEqual(m, b"\xff\xff\xff\xff")

    def test_protocol_is_one_byte(self):
        v, m = self.enc("hdr.ipv4.protocol", 6)
        self.assertEqual((v, m), (b"\x06", b"\xff"))

    def test_l4_ports_are_two_bytes(self):
        v, m = self.enc("meta.l4_dst_port", 80)
        self.assertEqual((v, m), (b"\x00\x50", b"\xff\xff"))

    def test_ingress_port_is_two_bytes_because_it_is_bit9(self):
        v, m = self.enc("standard_metadata.ingress_port", 2)
        self.assertEqual((v, m), (b"\x00\x02", b"\xff\xff"))

    def test_every_mask_is_all_ones(self):
        # THE load-bearing one. The ternary table is used for its priority, not for
        # wildcarding: keys the caller did not name are simply absent, which P4Runtime already
        # treats as don't-care. A partial mask here would silently widen a rule someone wrote
        # precisely -- and it would still install, and traffic would still flow.
        for field, value in (("hdr.ipv4.srcAddr", "10.0.0.2"),
                             ("hdr.ipv4.dstAddr", "10.0.0.1"),
                             ("hdr.ipv4.protocol", 17),
                             ("meta.l4_src_port", 1234),
                             ("meta.l4_dst_port", 53),
                             ("standard_metadata.ingress_port", 3)):
            with self.subTest(field=field):
                _, mask = self.enc(field, value)
                self.assertEqual(set(mask), {0xFF},
                                 f"{field} got a partial mask: {mask!r}")

    def test_a_value_too_wide_for_its_key_raises(self):
        # A protocol of 300 is a caller error; encoding it as 0x2C silently would install a rule
        # matching ICMP-ish traffic nobody asked about.
        with self.assertRaises(OverflowError):
            self.enc("hdr.ipv4.protocol", 300)

    def test_an_integer_ipv4_still_encodes_to_its_width(self):
        v, _ = self.enc("hdr.ipv4.dstAddr", 0x0A000001)
        self.assertEqual(v, b"\x0a\x00\x00\x01")

if __name__ == "__main__":
    unittest.main(verbosity=2)
