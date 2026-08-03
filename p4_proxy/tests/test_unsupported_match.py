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
    MAX_REPORTED_FIELDS,
    MalformedMatchError,
    parse_eth_type,
)
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


class EthTypeParsingTest(unittest.TestCase):
    """
    A hex-string ethertype is a valid IPv4 rule and must not be refused.

    [Co-developed with claude code -- Adam]
    `int(value)` raised ValueError on "0x0800", the except branch appended the field to `bad`, and a
    perfectly good rule was **rejected with 400**. That direction is the worse one: letting something
    through can be caught downstream, but refusing a valid request breaks a working client outright.
    No caller in this repo sends hex today -- Traffic-Engineering-App and Energy-Saving-App both send
    the integer 2048 -- but hex is how OpenFlow tooling normally writes an ethertype, and this code
    claims to validate the field. Found by agy-review 0072.
    """

    def test_the_integer_form_every_current_caller_uses(self):
        self.assertEqual(parse_eth_type(2048), 0x0800)
        self.assertEqual(parse_eth_type(0x0800), 0x0800)

    def test_the_decimal_string_form(self):
        self.assertEqual(parse_eth_type("2048"), 0x0800)

    def test_the_hex_string_forms_that_used_to_be_refused(self):
        for text in ("0x0800", "0x800", "0X800", "0X0800", " 0x0800 "):
            self.assertEqual(parse_eth_type(text), 0x0800, text)

    def test_a_valid_ipv4_rule_with_a_hex_ethertype_is_accepted(self):
        # The end-to-end shape of the bug, not just the parser.
        for text in ("0x0800", "2048", 2048):
            self.assertEqual(
                unsupported_match_fields({"eth_type": text, "ipv4_dst": "10.0.0.4"}),
                [],
                f"a valid IPv4 rule was rejected for eth_type={text!r}",
            )

    def test_a_non_ipv4_ethertype_is_still_refused_in_either_notation(self):
        # ARP is 0x0806. Accepting hex must not accidentally accept everything.
        for text in (0x0806, "2054", "0x0806"):
            self.assertEqual(
                unsupported_match_fields({"eth_type": text, "ipv4_dst": "10.0.0.4"}),
                ["eth_type"],
                f"eth_type={text!r} is not IPv4 and must be refused",
            )

    def test_garbage_is_not_an_ethertype(self):
        for value in ("abc", "", "0x", "0xzz", None, [], {}, 1.5):
            self.assertIsNone(parse_eth_type(value), repr(value))

    def test_true_is_not_ethertype_one(self):
        # bool is an int subclass and True == 1, so without an explicit check {"eth_type": true}
        # would parse as ethertype 1 rather than being refused.
        self.assertIsNone(parse_eth_type(True))
        self.assertIsNone(parse_eth_type(False))


class MalformedMatchTest(unittest.TestCase):
    """
    `match` that is not an object must be a 400, not a 500.

    [Co-developed with claude code -- Adam]
    `(match_dict or {}).items()` raised AttributeError for a list, string or number. api_routes
    catches only UnsupportedMatchError, so it escaped and FastAPI answered **500 Internal Server
    Error** for a malformed request -- the same defect class as the three 500s already fixed on the
    kernel side. Found by agy-review 0072.
    """

    def test_a_non_object_match_raises_rather_than_crashing(self):
        for value in (["ipv4_dst"], "ipv4_dst", 42, 1.5, True):
            with self.assertRaises(MalformedMatchError, msg=repr(value)):
                unsupported_match_fields(value)

    def test_it_is_an_unsupported_match_error_so_the_existing_catch_answers_400(self):
        # The whole reason it is a subclass. If this stops holding, api_routes needs a second catch
        # and a malformed match goes back to being a 500.
        try:
            unsupported_match_fields(["x"])
        except UnsupportedMatchError as e:
            self.assertIsInstance(e, MalformedMatchError)
        else:
            self.fail("no exception raised")

    def test_the_message_names_the_type_and_does_not_echo_the_value(self):
        # The value is attacker-controlled and may be huge; the type is what a caller needs.
        try:
            unsupported_match_fields(["secret"] * 1000)
        except MalformedMatchError as e:
            self.assertIn("list", str(e))
            self.assertNotIn("secret", str(e))
            self.assertLess(len(str(e)), 200)

    def test_none_and_empty_are_still_treated_as_no_match_at_all(self):
        self.assertEqual(unsupported_match_fields(None), [])
        self.assertEqual(unsupported_match_fields({}), [])


class ReportedFieldCapTest(unittest.TestCase):
    """
    The offending-field list is capped before being formatted.

    [Co-developed with claude code -- Adam]
    `match` arrives in an unauthenticated REST body, so a caller can send thousands of keys; all of
    them were sorted, joined, printed to stdout and echoed in the 400 response. A modest
    amplification, and free to remove. Found by agy-review 0072.
    """

    def test_a_huge_field_list_produces_a_bounded_message(self):
        error = UnsupportedMatchError([f"field{i:04d}" for i in range(2000)])
        text = str(error)
        self.assertLess(len(text), 500, "the message grows with the caller's payload")
        self.assertIn("+1988 more", text, "the count of omitted fields must still be reported")

    def test_a_normal_sized_list_is_reported_in_full_with_no_suffix(self):
        error = UnsupportedMatchError(["ip_proto", "udp_dst"])
        self.assertIn("ip_proto", str(error))
        self.assertIn("udp_dst", str(error))
        self.assertNotIn("more)", str(error))

    def test_the_full_list_is_still_available_on_the_exception(self):
        # api_routes puts `fields` in the JSON body. Capping the *message* must not lose the data.
        error = UnsupportedMatchError([f"f{i}" for i in range(50)])
        self.assertEqual(len(error.fields), 50)

    def test_exactly_at_the_cap_has_no_suffix(self):
        error = UnsupportedMatchError([f"f{i:02d}" for i in range(MAX_REPORTED_FIELDS)])
        self.assertNotIn("more)", str(error))


if __name__ == "__main__":
    unittest.main()
