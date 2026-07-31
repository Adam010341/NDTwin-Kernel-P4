"""
Tests that a match ipv4_lpm cannot express is refused rather than quietly narrowed.

[Co-developed with claude code -- Adam]

These exist because of a measured silent success. A rule posted as

    {"ipv4_src": "10.0.0.1", "ipv4_dst": "10.0.0.4", "ip_proto": 17,
     "udp_src": 35909, "udp_dst": 5001}   priority 100

was installed against a live bmv2 fabric as "10.0.0.4/32 -> port 1", and the proxy answered 200.
The rule took effect -- traffic really did follow the new port, verified by the flow's path
changing from s1:2 to s1:1 -- but it applied to *all* traffic to 10.0.0.4 rather than the single
flow named, and the table read back priority 0 rather than 100. A Traffic-Engineering rule aimed
at one flow became a rule for an entire destination, with nothing reporting the difference.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from proxy_agent.topology_manager import (  # noqa: E402
    UnsupportedMatchError,
    unsupported_match_fields,
)


class UnsupportedMatchFieldsTest(unittest.TestCase):
    def test_a_destination_only_match_is_expressible(self):
        # The shape the proxy's own install_initial_routes and the OVS-side apps use.
        self.assertEqual(unsupported_match_fields({"dl_type": 2048, "nw_dst": "10.0.0.4"}), [])
        self.assertEqual(unsupported_match_fields({"eth_type": 2048, "ipv4_dst": "10.0.0.4"}), [])

    def test_the_five_tuple_that_was_silently_narrowed_is_now_named(self):
        # The regression. Every field beyond the destination has to be reported, because each one
        # the caller sent and we ignored widens the rule's reach.
        self.assertEqual(
            unsupported_match_fields(
                {
                    "eth_type": 2048,
                    "ipv4_src": "10.0.0.1",
                    "ipv4_dst": "10.0.0.4",
                    "ip_proto": 17,
                    "udp_src": 35909,
                    "udp_dst": 5001,
                }
            ),
            ["ip_proto", "ipv4_src", "udp_dst", "udp_src"],
        )

    def test_a_non_ipv4_eth_type_is_refused_rather_than_served_as_ipv4(self):
        # ipv4_lpm is IPv4 by construction, so eth_type 0x0800 is a tautology and may be ignored.
        # ARP (0x0806) or IPv6 must not be quietly serviced as though it were IPv4.
        self.assertEqual(unsupported_match_fields({"eth_type": 2054, "nw_dst": "10.0.0.4"}),
                         ["eth_type"])
        self.assertEqual(unsupported_match_fields({"dl_type": 34525, "nw_dst": "10.0.0.4"}),
                         ["dl_type"])

    def test_an_unparseable_eth_type_is_refused_not_assumed(self):
        # A match body comes from a REST caller, so the value may not be an integer at all.
        # Guessing IPv4 here would be the same class of mistake as ignoring the field.
        self.assertEqual(unsupported_match_fields({"dl_type": "oops", "nw_dst": "10.0.0.4"}),
                         ["dl_type"])
        self.assertEqual(unsupported_match_fields({"dl_type": None, "nw_dst": "10.0.0.4"}),
                         ["dl_type"])

    def test_l2_and_ingress_fields_are_refused(self):
        # The kernel's own flow-stats mapping knows dl_dst and in_port, so they are realistic
        # inputs; ipv4_lpm keys on neither.
        self.assertEqual(
            unsupported_match_fields({"nw_dst": "10.0.0.4", "in_port": 1,
                                      "dl_dst": "00:00:00:00:00:04"}),
            ["dl_dst", "in_port"],
        )

    def test_an_empty_or_absent_match_names_nothing(self):
        # Reported as expressible; the caller's own "needs nw_dst" check rejects it separately,
        # and conflating "nothing to honour" with "cannot honour" would give a confusing error.
        self.assertEqual(unsupported_match_fields({}), [])
        self.assertEqual(unsupported_match_fields(None), [])

    def test_the_field_list_is_sorted_so_the_error_is_stable(self):
        # The list goes into an HTTP error body and into logs; dict ordering must not make two
        # identical faults look different.
        first = unsupported_match_fields({"udp_dst": 1, "ip_proto": 17, "ipv4_src": "10.0.0.1"})
        second = unsupported_match_fields({"ipv4_src": "10.0.0.1", "udp_dst": 1, "ip_proto": 17})
        self.assertEqual(first, second)
        self.assertEqual(first, sorted(first))


class UnsupportedMatchErrorTest(unittest.TestCase):
    def test_the_message_names_the_table_and_every_offending_field(self):
        err = UnsupportedMatchError({"udp_dst", "ip_proto"})
        self.assertEqual(err.fields, ["ip_proto", "udp_dst"])
        text = str(err)
        self.assertIn("ipv4_lpm", text)
        self.assertIn("ip_proto", text)
        self.assertIn("udp_dst", text)

    def test_it_is_a_value_error_so_an_unaware_caller_still_fails(self):
        # api_routes catches it explicitly and returns 400. Anything that does not catch it must
        # still fail rather than continue with a narrowed rule, so it must not be a bare Exception
        # subclass that reads as control flow.
        self.assertTrue(issubclass(UnsupportedMatchError, ValueError))


if __name__ == "__main__":
    unittest.main()
