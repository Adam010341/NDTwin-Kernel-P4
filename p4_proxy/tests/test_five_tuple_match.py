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
import threading
import types
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

class RecordingClient:
    """Stands in for P4RuntimeClient, recording which table each write went to."""

    def __init__(self, verdict=True):
        self.verdict = verdict
        self.calls = []

    def insert_ipv4_route(self, dst_ip, prefix_len, mac, port):
        self.calls.append(("lpm_insert", dst_ip, prefix_len, port))
        return self.verdict

    def delete_ipv4_route(self, dst_ip, prefix_len):
        self.calls.append(("lpm_delete", dst_ip, prefix_len))
        return self.verdict

    def modify_ipv4_route(self, dst_ip, prefix_len, mac, port):
        self.calls.append(("lpm_modify", dst_ip, prefix_len, port))
        return self.verdict

    def insert_5tuple_rule(self, keys, priority, mac, port):
        self.calls.append(("5t_insert", dict(keys), priority, port))
        return self.verdict

    def modify_5tuple_rule(self, keys, priority, mac, port):
        self.calls.append(("5t_modify", dict(keys), priority, port))
        return self.verdict

    def delete_5tuple_rule(self, keys, priority):
        self.calls.append(("5t_delete", dict(keys), priority))
        return self.verdict


def manager_with(client):
    """A TopologyManager with just enough state for the three flow methods."""
    mgr = tm.TopologyManager.__new__(tm.TopologyManager)
    mgr.switches = {1: client}
    mgr.net = types.SimpleNamespace(nodes={})
    mgr._installed_routes = {}
    mgr._net_lock = threading.RLock()
    return mgr


OUT = [{"type": "OUTPUT", "port": 3}]


class PriorityMappingTest(unittest.TestCase):
    def test_openflow_priority_shifts_by_one_and_preserves_order(self):
        # P4Runtime rejects priority 0 on a ternary table, so the scale is shifted rather than
        # clamped: clamping 0 to 1 would collapse OpenFlow 0 and 1 onto each other, silently
        # reordering exactly the rules a caller ranked most carefully.
        self.assertEqual(tm.p4_priority(0), 1)
        self.assertEqual(tm.p4_priority(1), 2)
        self.assertEqual(tm.p4_priority(100), 101)
        self.assertLess(tm.p4_priority(10), tm.p4_priority(11))

    def test_a_missing_or_junk_priority_lands_in_the_lowest_band(self):
        for junk in (None, "", "abc", [1]):
            with self.subTest(junk=junk):
                self.assertEqual(tm.p4_priority(junk), 1)


class RouteFlowTableChoiceTest(unittest.TestCase):
    def test_a_destination_only_rule_still_writes_ipv4_lpm(self):
        # The whole fabric's routes are destination-only. If this ever writes the ternary
        # table instead, forwarding changes everywhere and nothing says so.
        c = RecordingClient()
        mgr = manager_with(c)
        self.assertTrue(mgr.route_flow(1, {"dl_type": 2048, "nw_dst": "10.0.0.1"}, OUT, 100))
        self.assertEqual([x[0] for x in c.calls], ["lpm_insert"])

    def test_a_five_tuple_rule_writes_flow_5tuple_with_the_mapped_priority(self):
        c = RecordingClient()
        mgr = manager_with(c)
        ok = mgr.route_flow(1, {"dl_type": 2048, "nw_dst": "10.0.0.1",
                                "nw_proto": 6, "tp_dst": 80}, OUT, 100)
        self.assertTrue(ok)
        self.assertEqual(len(c.calls), 1)
        kind, keys, prio, port = c.calls[0]
        self.assertEqual(kind, "5t_insert")
        self.assertEqual(prio, 101)
        self.assertEqual(port, 3)
        self.assertEqual(keys, {"hdr.ipv4.dstAddr": "10.0.0.1",
                                "hdr.ipv4.protocol": 6,
                                "meta.l4_dst_port": 80})

    def test_a_five_tuple_rule_is_not_recorded_in_installed_routes(self):
        # _installed_routes answers "which port does this switch use for this destination",
        # and a 5-tuple rule has no single-valued answer -- two rules can send one destination
        # different ways on different L4 ports. Writing one in makes render_destination_paths
        # confidently wrong instead of silent.
        c = RecordingClient()
        mgr = manager_with(c)
        mgr.route_flow(1, {"nw_dst": "10.0.0.1", "tp_dst": 80}, OUT, 5)
        self.assertEqual(mgr._installed_routes, {})

    def test_a_destination_only_rule_IS_recorded(self):
        # The accept path for the line above: without it, a route_flow that recorded nothing
        # at all would pass that test too.
        c = RecordingClient()
        mgr = manager_with(c)
        mgr.route_flow(1, {"nw_dst": "10.0.0.1"}, OUT, 5)
        self.assertEqual(mgr._installed_routes, {(1, "10.0.0.1"): 3})

    def test_a_failed_five_tuple_write_is_reported_as_failure(self):
        c = RecordingClient(verdict=False)
        mgr = manager_with(c)
        self.assertFalse(mgr.route_flow(1, {"nw_dst": "10.0.0.1", "tp_dst": 80}, OUT, 5))


class UnrouteAndModifyTest(unittest.TestCase):
    def test_delete_of_a_five_tuple_rule_carries_the_priority(self):
        # On a ternary table the priority is part of the entry's identity: a delete without it
        # removes nothing and reports success.
        c = RecordingClient()
        mgr = manager_with(c)
        self.assertTrue(mgr.unroute_flow(1, {"nw_dst": "10.0.0.1", "tp_dst": 80}, 100))
        self.assertEqual(c.calls[0][0], "5t_delete")
        self.assertEqual(c.calls[0][2], 101)

    def test_delete_of_a_destination_only_rule_still_uses_lpm(self):
        c = RecordingClient()
        mgr = manager_with(c)
        self.assertTrue(mgr.unroute_flow(1, {"nw_dst": "10.0.0.1"}, 100))
        self.assertEqual(c.calls[0][0], "lpm_delete")

    def test_modify_of_a_five_tuple_rule_carries_the_priority(self):
        c = RecordingClient()
        mgr = manager_with(c)
        self.assertTrue(mgr.modify_flow(1, {"nw_dst": "10.0.0.1", "tp_dst": 80}, OUT, 7))
        self.assertEqual(c.calls[0][0], "5t_modify")
        self.assertEqual(c.calls[0][2], 8)

    def test_an_unsupported_field_is_still_refused_on_every_path(self):
        c = RecordingClient()
        mgr = manager_with(c)
        for fn, args in ((mgr.route_flow, ({"nw_dst": "10.0.0.1", "vlan_vid": 5}, OUT, 1)),
                         (mgr.unroute_flow, ({"nw_dst": "10.0.0.1", "vlan_vid": 5}, 1)),
                         (mgr.modify_flow, ({"nw_dst": "10.0.0.1", "vlan_vid": 5}, OUT, 1))):
            with self.subTest(fn=fn.__name__):
                with self.assertRaises(tm.UnsupportedMatchError):
                    fn(1, *args)
        self.assertEqual(c.calls, [], "a refused rule still reached the switch")


if __name__ == "__main__":
    unittest.main(verbosity=2)
