"""
Tests for the P4-table-entry to Ryu flow-stats translation.

[Co-developed with claude code -- Adam]

The C++ side of this contract is checked by tests/test_P4FlowStatsToClassifier.cpp, which feeds
this module's real output into the actual Classifier. These tests cover the translation itself:
the value encodings, and the cases where emitting something would be worse than emitting nothing.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent import ryu_flow_stats as rf  # noqa: E402


def an_lpm_route(dst=b"\x0a\x00\x00\x04", prefix=32, port=6, priority=0, default=False):
    return {
        "table": "MyIngress.ipv4_lpm",
        "priority": priority,
        "is_default": default,
        "match": {"hdr.ipv4.dstAddr": {"type": "lpm", "value": dst, "prefix_len": prefix}},
        "action": {"name": "MyIngress.ipv4_forward", "params": {"port": bytes([port])}},
    }


def a_ternary_rule(priority=100, port=9, in_port_mask=b"\xff"):
    return {
        "table": "MyIngress.flow_5tuple",
        "priority": priority,
        "is_default": False,
        "match": {
            "hdr.ipv4.srcAddr": {"type": "ternary", "value": b"\x0a\x00\x00\x01",
                                 "mask": b"\xff\xff\xff\xff"},
            "hdr.ipv4.dstAddr": {"type": "ternary", "value": b"\x0a\x00\x00\x04",
                                 "mask": b"\xff\xff\xff\xff"},
            "hdr.ipv4.protocol": {"type": "ternary", "value": b"\x06", "mask": b"\xff"},
            "standard_metadata.ingress_port": {"type": "ternary", "value": b"\x03",
                                               "mask": in_port_mask},
        },
        "action": {"name": "MyIngress.ipv4_forward", "params": {"port": bytes([port])}},
    }


class EnvelopeTest(unittest.TestCase):
    def test_the_top_level_is_a_map_keyed_by_dpid_as_a_string(self):
        # Ryu answers {"1": [...]}, and the kernel wraps the body as {"dpid":N,"flows":<body>}.
        # The old stub returned a bare [], which made `flows` a list where the documented shape
        # is a map -- flagged by the L2 contract as a type error.
        out = rf.render_flow_stats(1, [an_lpm_route()])
        self.assertEqual(list(out.keys()), ["1"])
        self.assertIsInstance(out["1"], list)

    def test_dpid_ten_is_keyed_as_ten_not_hex(self):
        # Unlike the topology endpoints, this key is decimal -- that is what Ryu emits here.
        self.assertEqual(list(rf.render_flow_stats(10, []).keys()), ["10"])

    def test_no_entries_yields_an_empty_list(self):
        self.assertEqual(rf.render_flow_stats(1, []), {"1": []})
        self.assertEqual(rf.render_flow_stats(1, None), {"1": []})


class MatchTranslationTest(unittest.TestCase):
    def flows(self, entries):
        return rf.render_flow_stats(1, entries)["1"]

    def test_lpm_host_route_has_no_netmask_suffix(self):
        m = self.flows([an_lpm_route(prefix=32)])[0]["match"]
        self.assertEqual(m["nw_dst"], "10.0.0.4")

    def test_lpm_prefix_route_carries_the_suffix(self):
        m = self.flows([an_lpm_route(dst=b"\x0a\x00\x00\x00", prefix=24)])[0]["match"]
        self.assertEqual(m["nw_dst"], "10.0.0.0/24")

    def test_ipv4_rules_always_declare_dl_type(self):
        # The Classifier keys IPv4 rules off dl_type; without it the packed key does not match
        # at lookup time, so the rule is stored and never fires.
        for entry in (an_lpm_route(), a_ternary_rule()):
            self.assertEqual(self.flows([entry])[0]["match"]["dl_type"], 0x0800)

    def test_a_zero_masked_ternary_field_is_dropped(self):
        # A zero mask means "don't care". Emitting the value would narrow a wildcard into a
        # specific match, so the rule would stop matching traffic it should catch.
        m = self.flows([a_ternary_rule(in_port_mask=b"\x00")])[0]["match"]
        self.assertNotIn("in_port", m)

    def test_a_fully_masked_ternary_field_is_kept(self):
        m = self.flows([a_ternary_rule(in_port_mask=b"\xff")])[0]["match"]
        self.assertEqual(m["in_port"], 3)

    def test_five_tuple_fields_use_ryu_names(self):
        m = self.flows([a_ternary_rule()])[0]["match"]
        self.assertEqual(m["nw_src"], "10.0.0.1")
        self.assertEqual(m["nw_dst"], "10.0.0.4")
        self.assertEqual(m["nw_proto"], 6)

    def test_a_mac_match_is_rendered_as_a_mac_string(self):
        entry = {
            "table": "MyIngress.l2_forward", "priority": 0, "is_default": False,
            "match": {"hdr.ethernet.dstAddr": {"type": "exact",
                                               "value": b"\x00\x00\x00\x00\x00\x04"}},
            "action": {"name": "MyIngress.forward_l2", "params": {"port": b"\x03"}},
        }
        self.assertEqual(self.flows([entry])[0]["match"]["dl_dst"], "00:00:00:00:00:04")

    def test_a_short_address_value_is_left_padded(self):
        # P4Runtime canonical form strips leading zero bytes, so 10.0.0.4 may arrive as 3 bytes
        # or fewer. Reading it without padding would shift every octet.
        m = self.flows([an_lpm_route(dst=b"\x0a\x00\x00\x04")])[0]["match"]
        self.assertEqual(m["nw_dst"], "10.0.0.4")
        short = self.flows([an_lpm_route(dst=b"\x00\x00\x04")])[0]["match"]
        self.assertEqual(short["nw_dst"], "0.0.0.4")

    def test_unknown_p4_fields_are_dropped_rather_than_passed_through(self):
        entry = an_lpm_route()
        entry["match"]["meta.something_new"] = {"type": "exact", "value": b"\x01"}
        m = self.flows([entry])[0]["match"]
        self.assertNotIn("meta.something_new", m)
        self.assertNotIn("something_new", m)


class ActionTranslationTest(unittest.TestCase):
    def flows(self, entries):
        return rf.render_flow_stats(1, entries)["1"]

    def test_forwarding_becomes_a_string_output_action(self):
        # Classifier::parseActionsArrayIntoEffect handles ONLY the string form; the object form
        # is silently ignored, leaving the rule matching but forwarding nowhere.
        self.assertEqual(self.flows([an_lpm_route(port=6)])[0]["actions"], ["OUTPUT:6"])

    def test_send_to_cpu_becomes_output_controller(self):
        entry = an_lpm_route()
        entry["action"] = {"name": "MyIngress.send_to_cpu", "params": {}}
        self.assertEqual(self.flows([entry])[0]["actions"], ["OUTPUT:CONTROLLER"])

    def test_drop_becomes_an_empty_action_list(self):
        # Correct, and what Ryu reports for its own table-miss drop. The kernel handles it --
        # though an unguarded front() on this used to crash it (see test_ClassifierDropRule).
        entry = an_lpm_route()
        entry["action"] = {"name": "MyIngress.drop", "params": {}}
        self.assertEqual(self.flows([entry])[0]["actions"], [])

    def test_an_unknown_action_yields_no_port_rather_than_a_guess(self):
        entry = an_lpm_route()
        entry["action"] = {"name": "MyIngress.some_future_action", "params": {"port": b"\x05"}}
        self.assertEqual(self.flows([entry])[0]["actions"], [])

    def test_a_missing_action_does_not_raise(self):
        entry = an_lpm_route()
        entry["action"] = None
        self.assertEqual(self.flows([entry])[0]["actions"], [])


class RuleSelectionTest(unittest.TestCase):
    def flows(self, entries):
        return rf.render_flow_stats(1, entries)["1"]

    def test_default_actions_are_not_reported(self):
        # A default action has no match fields, so the Classifier would read it as a rule that
        # matches every packet at whatever priority it carries.
        self.assertEqual(self.flows([an_lpm_route(default=True)]), [])

    def test_an_entry_with_no_usable_match_is_not_reported(self):
        entry = an_lpm_route()
        entry["match"] = {}
        self.assertEqual(self.flows([entry]), [])

    def test_a_negative_priority_is_clamped_to_zero(self):
        # The Classifier's lookup starts at bestPriority = -1 with a null best, so a rule at
        # <= -1 can never win a match -- and used to segfault the process through a trace line.
        self.assertEqual(self.flows([an_lpm_route(priority=-1)])[0]["priority"], 0)

    def test_priority_is_otherwise_preserved(self):
        # flow_5tuple must outrank ipv4_lpm, or traffic leaves by the wrong port.
        self.assertEqual(self.flows([a_ternary_rule(priority=100)])[0]["priority"], 100)

    def test_counter_fields_are_present_so_the_shape_matches_ovs(self):
        # The L4 differential compares shapes against an OVS baseline; missing keys read as
        # differences even when the values are meaningless here.
        flow = self.flows([an_lpm_route()])[0]
        for key in ("byte_count", "packet_count", "duration_sec", "idle_timeout",
                    "hard_timeout", "cookie", "flags", "length", "table_id"):
            self.assertIn(key, flow)


class CounterPassthroughTest(unittest.TestCase):
    """
    Direct-counter values must reach the payload.

    Both ingress tables carry a direct_counter (ndtwin_switch.p4:263-264) added specifically so
    /stats/flow/<dpid> could report per-entry byte and packet counts. Until 2026-08-24 the
    renderer hardcoded zeroes, so a rule carrying gigabytes reported the same numbers as one
    that had never matched -- and the endpoint's whole purpose is telling those apart.
    """

    def flows(self, entries):
        return rf.render_flow_stats(1, entries)["1"]

    def test_real_counters_reach_the_payload(self):
        entry = an_lpm_route()
        entry["counters"] = {"bytes": 123456, "packets": 789}
        flow = self.flows([entry])[0]
        self.assertEqual(flow["byte_count"], 123456)
        self.assertEqual(flow["packet_count"], 789)

    def test_absent_counters_still_render_zero_rather_than_missing(self):
        # The L4 differential compares shapes against an OVS baseline, so the keys must exist
        # even when the switch said nothing. This is also the ambiguity worth knowing about:
        # 0 here means "not reported" as well as "idle", and the payload cannot say which.
        entry = an_lpm_route()
        entry.pop("counters", None)
        flow = self.flows([entry])[0]
        self.assertEqual(flow["byte_count"], 0)
        self.assertEqual(flow["packet_count"], 0)

    def test_a_null_counters_field_does_not_raise(self):
        # read_table_entries sets counters=None when the switch returned no counter_data; the
        # renderer runs on the kernel's 1 Hz polling path and must not raise there.
        entry = an_lpm_route()
        entry["counters"] = None
        flow = self.flows([entry])[0]
        self.assertEqual((flow["byte_count"], flow["packet_count"]), (0, 0))


if __name__ == "__main__":
    unittest.main(verbosity=2)
