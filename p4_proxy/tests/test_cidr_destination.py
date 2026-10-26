"""
A CIDR destination on the Ryu-compatible routing path is accepted and installed as that prefix.

[Co-developed with claude code -- Adam]

CIDR destinations are accepted, and /32 behaves as the bare address always has. Until now every
destination carrying a prefix length was refused with 400
(topology_manager.MalformedMatchValueError), because route_flow wrote every destination as a
hard-coded /32. ipv4_lpm (ndtwin_switch.p4) is an LPM table, so the switch could always hold a
prefix; the proxy could not name one.

What this file pins:

  * a well-formed prefix on a destination-only match answers 200 on all three write endpoints
    and reaches the switch as that prefix (network address, length), host bits cleared;
  * "a.b.c.d/32" is exactly the bare address: same write, same route key, same record;
  * a /32 and a /24 that overlap are two entries side by side, and the path view picks the
    longest prefix for each destination, as the switch does;
  * unroute and modify of a prefix touch that prefix only; a prefix is never handed back to
    the control plane (A-4d's restore is for the control plane's own /32 host routes);
  * A-4d's delete-restores-route still holds for a /32 with a covering /24 present;
  * a readopt forgets the prefix routes of the switch it re-pushed;
  * a malformed prefix, a prefix on a five-tuple match, and a prefix on a source are still
    refused with 400 before anything reaches the switch;
  * an address that is not a full dotted quad ("10.0.1/24", "10.1/16", "10.1") is refused, as the
    kernel refuses it, rather than re-read as another address;
  * an address field that is present but "" or null is refused (an absent one is absent);
  * the two spellings of one address field are refused when they name different addresses;
  * the strict-delete 501 does not promise a restore for a prefix.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from fastapi import HTTPException  # noqa: E402

from proxy_agent import api_routes, ryu_topology  # noqa: E402
from proxy_agent import topology_manager as tm  # noqa: E402
from proxy_agent.topology_manager import (  # noqa: E402
    FlowRequestUnusable, MalformedMatchValueError, TopologyManager, UnsupportedMatchError,
    check_match_values)

ZERO_MAC = "00:00:00:00:00:00"

#: The fabric:  SRC -- s1 --(2|2)-- s2 --3-- HOST_A
#:                                     \--4-- HOST_B
SRC, SRC_MAC = "10.0.9.1", "00:00:00:00:09:01"
HOST_A, HOST_A_MAC = "10.0.1.7", "00:00:00:00:01:07"   # has its own /32
HOST_B, HOST_B_MAC = "10.0.1.5", "00:00:00:00:01:05"   # reached through the /24 only
NET24 = "10.0.1.0/24"


class LpmClient:
    """The P4RuntimeClient write surface, recording table, verb, address, length, MAC, port."""

    def __init__(self, verdict=True):
        self.verdict = verdict
        self.calls = []

    def insert_ipv4_route(self, dst_ip, prefix_len, mac, port):
        self.calls.append(("insert", dst_ip, prefix_len, mac, port))
        return self.verdict

    def modify_ipv4_route(self, dst_ip, prefix_len, mac, port):
        self.calls.append(("modify", dst_ip, prefix_len, mac, port))
        return self.verdict

    def delete_ipv4_route(self, dst_ip, prefix_len):
        self.calls.append(("delete", dst_ip, prefix_len))
        return self.verdict

    def insert_5tuple_rule(self, keys, priority, mac, port):
        self.calls.append(("insert5", dict(keys), priority, port))
        return self.verdict

    def modify_5tuple_rule(self, keys, priority, mac, port):
        self.calls.append(("modify5", dict(keys), priority, port))
        return self.verdict

    def delete_5tuple_rule(self, keys, priority):
        self.calls.append(("delete5", dict(keys), priority))
        return self.verdict


def out(port):
    return [{"type": "OUTPUT", "port": port}]


def two_switches(routed=False):
    """The fabric above, with each switch's client. `routed` runs the control plane's refill."""
    topo = TopologyManager()
    c1, c2 = LpmClient(), LpmClient()
    topo.add_switch(1, c1)
    topo.add_switch(2, c2)
    topo.add_link(1, 2, src_port=2, dst_port=2)
    topo.add_host(SRC, SRC_MAC, 1, 1)
    topo.add_host(HOST_A, HOST_A_MAC, 2, 3)
    topo.add_host(HOST_B, HOST_B_MAC, 2, 4)
    if routed:
        topo.install_initial_routes()
        c1.calls.clear()
        c2.calls.clear()
    return topo, c1, c2


def one_switch():
    topo = TopologyManager()
    client = LpmClient()
    topo.add_switch(1, client)
    return topo, client


class FakeRequest:
    def __init__(self, raw):
        self._raw = raw

    async def json(self):
        return json.loads(self._raw)


def post(handler, body):
    return asyncio.run(handler(FakeRequest(json.dumps(body).encode())))


# --- accepted, and installed as the prefix -------------------------------------------------

class APrefixIsInstalledAsThatPrefixTest(unittest.TestCase):

    def test_route_flow_writes_the_network_and_its_length(self):
        topo, client = one_switch()
        self.assertTrue(topo.route_flow(1, {"eth_type": 2048, "nw_dst": NET24}, out(2)))
        self.assertEqual(client.calls, [("insert", "10.0.1.0", 24, ZERO_MAC, 2)])

    def test_both_spellings_of_the_destination(self):
        for field in ("nw_dst", "ipv4_dst"):
            with self.subTest(field=field):
                topo, client = one_switch()
                self.assertTrue(topo.route_flow(1, {field: "10.2.0.0/16"}, out(5)))
                self.assertEqual(client.calls, [("insert", "10.2.0.0", 16, ZERO_MAC, 5)])

    def test_host_bits_are_cleared_as_ovs_does(self):
        # Ryu's ofctl sends OVS "10.0.1.5/24" as address plus netmask and the switch masks it;
        # P4Runtime requires the masked bits of an lpm value to be zero.
        topo, client = one_switch()
        self.assertTrue(topo.route_flow(1, {"nw_dst": "10.0.1.5/24"}, out(2)))
        self.assertEqual(client.calls, [("insert", "10.0.1.0", 24, ZERO_MAC, 2)])
        self.assertEqual(topo.installed_routes(), {(1, NET24): 2})

    def test_the_record_is_keyed_by_the_prefix(self):
        topo, _client = one_switch()
        topo.route_flow(1, {"nw_dst": NET24}, out(2))
        self.assertEqual(topo.installed_routes(), {(1, NET24): 2})

    def test_a_slash_32_is_the_bare_address(self):
        # "/32 as before": the same write, the same key, as the bare address has always made.
        topo_a, ca = one_switch()
        topo_b, cb = one_switch()
        topo_a.route_flow(1, {"nw_dst": "10.0.0.4/32"}, out(3))
        topo_b.route_flow(1, {"nw_dst": "10.0.0.4"}, out(3))
        self.assertEqual(ca.calls, [("insert", "10.0.0.4", 32, ZERO_MAC, 3)])
        self.assertEqual(ca.calls, cb.calls)
        self.assertEqual(topo_a.installed_routes(), {(1, "10.0.0.4"): 3})
        self.assertEqual(topo_a.installed_routes(), topo_b.installed_routes())

    def test_a_prefix_out_of_a_host_port_carries_that_hosts_mac(self):
        # ipv4_forward rewrites the destination MAC. The /24 on s2 out of port 4 reaches
        # HOST_B only, so it must carry HOST_B's MAC or the host drops the frame; the /24 on
        # s1 leads to another switch and carries zero, which s2's own entry replaces.
        topo, c1, c2 = two_switches()
        topo.route_flow(2, {"nw_dst": NET24}, out(4))
        topo.route_flow(1, {"nw_dst": NET24}, out(2))
        self.assertEqual(c2.calls, [("insert", "10.0.1.0", 24, HOST_B_MAC, 4)])
        self.assertEqual(c1.calls, [("insert", "10.0.1.0", 24, ZERO_MAC, 2)])


class TheEndpointsAnswer200Test(unittest.TestCase):

    def setUp(self):
        self.topo, self.client = one_switch()
        api_routes.topology = self.topo

    def tearDown(self):
        api_routes.topology = None

    def test_add_delete_and_modify_of_a_prefix(self):
        body = {"dpid": 1, "match": {"eth_type": 2048, "nw_dst": NET24}, "actions": out(2)}
        added = post(api_routes.add_flow_entry, body)
        self.assertEqual((added["status"], added["table"]), ("success", "ipv4_lpm"))
        moved = post(api_routes.modify_flow_entry, dict(body, actions=out(3)))
        self.assertEqual(moved["status"], "success")
        gone = post(api_routes.delete_flow_entry, {"dpid": 1, "match": body["match"]})
        self.assertEqual(gone["status"], "success")
        self.assertEqual(self.client.calls, [("insert", "10.0.1.0", 24, ZERO_MAC, 2),
                                             ("modify", "10.0.1.0", 24, ZERO_MAC, 3),
                                             ("delete", "10.0.1.0", 24)])
        self.assertEqual(self.topo.installed_routes(), {})


# --- overlap: the longest prefix wins ------------------------------------------------------

class OverlappingPrefixesTest(unittest.TestCase):

    def setUp(self):
        topo, self.c1, self.c2 = two_switches()
        self.topo = topo
        # Back towards SRC on both switches, so the reverse paths exist too.
        topo.route_flow(1, {"nw_dst": SRC}, out(1))
        topo.route_flow(2, {"nw_dst": SRC}, out(2))
        # HOST_A: a /32 on each switch. The /24 covers both hosts.
        topo.route_flow(1, {"nw_dst": HOST_A}, out(2))
        topo.route_flow(2, {"nw_dst": HOST_A}, out(3))
        topo.route_flow(1, {"nw_dst": NET24}, out(2))
        topo.route_flow(2, {"nw_dst": NET24}, out(4))

    def paths(self):
        body = ryu_topology.render_destination_paths(self.topo.net, (),
                                                     self.topo.installed_routes())
        return {(p[0][0], p[-1][0]): p for p in body["all_destination_paths"]}

    def test_both_entries_are_written_and_recorded(self):
        routes = self.topo.installed_routes()
        self.assertEqual(routes[(2, HOST_A)], 3)
        self.assertEqual(routes[(2, NET24)], 4)

    def test_the_slash_32_wins_for_its_host(self):
        self.assertEqual(self.paths()[(SRC, HOST_A)], [[SRC, 1], [1, 2], [2, 3], [HOST_A, 0]])

    def test_the_slash_24_carries_the_rest(self):
        self.assertEqual(self.paths()[(SRC, HOST_B)], [[SRC, 1], [1, 2], [2, 4], [HOST_B, 0]])

    def test_the_lookup_alone_picks_the_longest(self):
        installed = {(2, HOST_A): 3, (2, NET24): 4, (2, "10.0.0.0/16"): 9}
        prefixes = ryu_topology.prefix_routes(installed)
        self.assertEqual(ryu_topology.lpm_out_port(installed, prefixes, 2, HOST_A), 3)
        self.assertEqual(ryu_topology.lpm_out_port(installed, prefixes, 2, HOST_B), 4)
        self.assertEqual(ryu_topology.lpm_out_port(installed, prefixes, 2, "10.0.200.1"), 9)
        self.assertIsNone(ryu_topology.lpm_out_port(installed, prefixes, 2, "10.1.0.1"))
        self.assertIsNone(ryu_topology.lpm_out_port(installed, prefixes, 1, HOST_B))

    def test_installed_path_follows_a_prefix(self):
        installed = {(1, NET24): 2, (2, NET24): 4}
        self.assertEqual(ryu_topology.installed_path(self.topo.net, installed, SRC, HOST_B),
                         [SRC, 1, 2, HOST_B])


# --- unroute and modify of a prefix ---------------------------------------------------------

class UnrouteAndModifyOfAPrefixTest(unittest.TestCase):

    def test_unroute_removes_the_prefix_and_leaves_the_host_routes(self):
        topo, _c1, c2 = two_switches(routed=True)
        topo.route_flow(2, {"nw_dst": NET24}, out(4))
        c2.calls.clear()
        self.assertTrue(topo.unroute_flow(2, {"nw_dst": NET24}))
        self.assertEqual(c2.calls, [("delete", "10.0.1.0", 24)])
        routes = topo.installed_routes()
        self.assertNotIn((2, NET24), routes)
        self.assertEqual((routes[(2, HOST_A)], routes[(2, HOST_B)]), (3, 4))

    def test_unroute_of_a_prefix_is_never_a_control_plane_restore(self):
        # Even with dest_paths naming the key: the control plane writes /32 host routes only,
        # so handing a prefix's slot "back" would write an entry nobody installed.
        topo, _c1, c2 = two_switches(routed=True)
        topo.dest_paths[NET24] = {2: {"path": [2, HOST_B], "length": 1}}
        topo.route_flow(2, {"nw_dst": NET24}, out(3))
        c2.calls.clear()
        topo.unroute_flow(2, {"nw_dst": NET24})
        self.assertEqual(c2.calls, [("delete", "10.0.1.0", 24)])

    def test_modify_moves_the_prefix_and_its_record(self):
        topo, client = one_switch()
        topo.route_flow(1, {"nw_dst": NET24}, out(2))
        self.assertTrue(topo.modify_flow(1, {"nw_dst": "10.0.1.9/24"}, out(6)))
        self.assertEqual(client.calls[-1], ("modify", "10.0.1.0", 24, ZERO_MAC, 6))
        self.assertEqual(topo.installed_routes(), {(1, NET24): 6})

    def test_a_modify_naming_the_prefixs_install_priority_is_honoured(self):
        # The slot record is keyed by the route key, so the prefix's own
        # install priority names it -- and the /32 of its network address is a different slot.
        topo, client = one_switch()
        topo.route_flow(1, {"nw_dst": NET24}, out(2), priority=100)
        topo.route_flow(1, {"nw_dst": "10.0.1.0"}, out(3), priority=200)
        self.assertTrue(topo.modify_flow(1, {"nw_dst": NET24}, out(6), priority=100))
        self.assertEqual(client.calls[-1], ("modify", "10.0.1.0", 24, ZERO_MAC, 6))
        with self.assertRaises(tm.SlotPriorityNotHeld):
            topo.modify_flow(1, {"nw_dst": NET24}, out(7), priority=200)


# --- A-4d with a covering prefix present ----------------------------------------------------

class DeleteRestoresRouteWithPrefixesTest(unittest.TestCase):

    def test_deleting_a_hosts_slash_32_still_restores_the_control_plane_route(self):
        topo, _c1, c2 = two_switches(routed=True)
        topo.route_flow(2, {"nw_dst": NET24}, out(4))
        topo.route_flow(2, {"nw_dst": HOST_A}, out(4))      # an app migrates HOST_A
        c2.calls.clear()
        self.assertTrue(topo.unroute_flow(2, {"nw_dst": HOST_A}))
        self.assertEqual(c2.calls, [("insert", HOST_A, 32, HOST_A_MAC, 3)])
        routes = topo.installed_routes()
        self.assertEqual((routes[(2, HOST_A)], routes[(2, NET24)]), (3, 4))

    def test_deleting_the_prefix_leaves_an_apps_slash_32_alone(self):
        topo, _c1, c2 = two_switches(routed=True)
        topo.route_flow(2, {"nw_dst": HOST_A}, out(4))
        topo.route_flow(2, {"nw_dst": NET24}, out(4))
        c2.calls.clear()
        topo.unroute_flow(2, {"nw_dst": NET24})
        self.assertEqual(c2.calls, [("delete", "10.0.1.0", 24)])
        self.assertEqual(topo.installed_routes()[(2, HOST_A)], 4)

    def test_a_slash_32_removed_for_good_falls_back_to_the_prefix_in_the_path_view(self):
        # HOST_A unroutable for the control plane: its /32 delete is a real removal, and the
        # switch then forwards HOST_A by the /24 -- the view must say the same.
        topo, _c1, _c2 = two_switches()
        topo.route_flow(1, {"nw_dst": SRC}, out(1))
        topo.route_flow(2, {"nw_dst": SRC}, out(2))
        topo.route_flow(1, {"nw_dst": NET24}, out(2))
        topo.route_flow(2, {"nw_dst": NET24}, out(3))
        topo.route_flow(1, {"nw_dst": HOST_A}, out(2))
        topo.route_flow(2, {"nw_dst": HOST_A}, out(4))       # a wrong /32, then withdrawn
        topo.dest_paths = {}
        self.assertTrue(topo.unroute_flow(2, {"nw_dst": HOST_A}))
        body = ryu_topology.render_destination_paths(topo.net, (), topo.installed_routes())
        got = {(p[0][0], p[-1][0]): p for p in body["all_destination_paths"]}
        self.assertEqual(got[(SRC, HOST_A)], [[SRC, 1], [1, 2], [2, 3], [HOST_A, 0]])


# --- readopt forgets the prefixes of the re-pushed switch -----------------------------------

class ReadoptForgetsPrefixRoutesTest(unittest.TestCase):

    def test_a_readopt_drops_that_switchs_prefix_records_only(self):
        import test_readopt as R  # the readopt doubles; imported here, not collected here
        topo, _old1, _old2 = R.build_topology()
        topo._installed_routes[(1, NET24)] = 2
        topo._installed_routes[(2, NET24)] = 2
        real_sleep = tm.time.sleep
        tm.time.sleep = lambda _s: None
        try:
            result = topo.readopt_switch(1, lambda dpid: R.FakeClient(dpid), R.sample_sink,
                                         settle_s=0)
        finally:
            tm.time.sleep = real_sleep
        self.assertEqual(result["status"], "success")
        routes = topo.installed_routes()
        self.assertNotIn((1, NET24), routes,
                         "the push emptied switch 1 and the refill writes no prefix")
        self.assertEqual(routes[(2, NET24)], 2, "switch 2 was not re-pushed")
        self.assertIn((1, R.H1), routes, "the refill's host routes must stay recorded")


# --- still refused --------------------------------------------------------------------------

#: Each of these is refused on a destination-only match. The short forms ("10.0.1/24", "10.1/16",
#: "10.1") are refused as the kernel's flow-batch check refuses them: inet_aton read them as
#: 10.0.0.1/24, 10.0.0.1/16 and 10.0.0.1, which installed a prefix nobody wrote.
MALFORMED = ("10.0.1.0/33", "10.0.1.0/0", "10.0.1.0/", "10.0.1.0/24/8", "10.0.1.0/ 24",
             "10.0.1.0/+24", "10.0.1.0/024", "10.0.1.0/255.255.255.0", "bogus/24",
             "10.0.1.0/٢٤", "/24", "10.0.1.0/-1",
             "10.0.1/24", "10.1/16", "10.1", "10.0.1", "10/8", "10.0.1/32",
             "0x0a000001", "0x0a.0.1.0/24", "10.0.0.02", "10.0.0.02/24", " 10.0.0.4", "10.0.0.4 ",
             "10.0.0.4\n", "10.0.0.4/24\n", "010.0.0.4", "10.0.0.256")


class StillRefusedTest(unittest.TestCase):

    def test_a_malformed_prefix_is_refused_by_every_verb_before_any_write(self):
        for value in MALFORMED:
            for verb in ("route", "unroute", "modify"):
                with self.subTest(value=value, verb=verb):
                    topo, client = one_switch()
                    with self.assertRaises(MalformedMatchValueError):
                        if verb == "route":
                            topo.route_flow(1, {"nw_dst": value}, out(2))
                        elif verb == "unroute":
                            topo.unroute_flow(1, {"nw_dst": value})
                        else:
                            topo.modify_flow(1, {"nw_dst": value}, out(2))
                    self.assertEqual(client.calls, [])

    def test_the_400_says_what_a_destination_may_be(self):
        with self.assertRaises(MalformedMatchValueError) as caught:
            check_match_values({"nw_dst": "10.0.1.0/33"}, "installed")
        text = str(caught.exception)
        self.assertIn('"10.0.1.0/33"', text)
        self.assertIn("IPv4 prefix with a length from 1 to 32", text)
        self.assertIn("No rule was installed", text)
        self.assertNotIn("one /32 host route per destination", text)

    def test_the_endpoint_answers_400_for_a_malformed_prefix(self):
        topo, client = one_switch()
        api_routes.topology = topo
        self.addCleanup(setattr, api_routes, "topology", None)
        with self.assertRaises(HTTPException) as caught:
            post(api_routes.add_flow_entry,
                 {"dpid": 1, "match": {"nw_dst": "10.0.1.0/33"}, "actions": out(2)})
        self.assertEqual(caught.exception.status_code, 400)
        self.assertEqual(client.calls, [])

    def test_a_prefix_on_a_five_tuple_match_is_refused_and_says_why(self):
        topo, client = one_switch()
        match = {"nw_dst": NET24, "ip_proto": 17, "udp_dst": 5001}
        with self.assertRaises(MalformedMatchValueError) as caught:
            topo.route_flow(1, match, out(2), 100)
        self.assertEqual(client.calls, [])
        self.assertIn("accepted only as the destination of a destination-only match",
                      str(caught.exception))

    def test_a_prefix_on_a_source_is_refused(self):
        for field in ("nw_src", "ipv4_src"):
            with self.subTest(field=field):
                with self.assertRaises(UnsupportedMatchError):
                    check_match_values({field: "10.0.0.0/16", "nw_dst": "10.0.0.4"},
                                       "installed")


# --- a present address field must be a readable address -------------------------------------
# [Co-developed with claude code -- Adam]
# "" and null used to be read as "no destination given": `nw_dst or ipv4_dst` fell through them,
# and on a delete that could leave a match broader than the one the caller wrote. The kernel
# answers 400 for the same values before queueing; the proxy now does too.

UNREADABLE = ("", None)


def call_verb(topo, verb, match):
    if verb == "route":
        return topo.route_flow(1, match, out(2))
    if verb == "unroute":
        return topo.unroute_flow(1, match)
    return topo.modify_flow(1, match, out(2))


class APresentAddressFieldMustBeReadableTest(unittest.TestCase):

    def test_an_empty_or_null_destination_is_refused_by_every_verb(self):
        for field in ("nw_dst", "ipv4_dst"):
            for value in UNREADABLE:
                for verb in ("route", "unroute", "modify"):
                    with self.subTest(field=field, value=value, verb=verb):
                        topo, client = one_switch()
                        with self.assertRaises(MalformedMatchValueError):
                            call_verb(topo, verb, {"eth_type": 2048, field: value})
                        self.assertEqual(client.calls, [])

    def test_an_empty_destination_does_not_fall_through_to_the_other_spelling(self):
        # {"nw_dst": "", "ipv4_dst": X} used to act on X; the caller wrote two things that
        # disagree and one of them is unreadable.
        for first, second in (("nw_dst", "ipv4_dst"), ("ipv4_dst", "nw_dst")):
            for verb in ("route", "unroute", "modify"):
                with self.subTest(first=first, verb=verb):
                    topo, client = one_switch()
                    with self.assertRaises(MalformedMatchValueError):
                        call_verb(topo, verb, {first: "", second: HOST_A})
                    self.assertEqual(client.calls, [])

    def test_an_empty_or_null_source_is_refused(self):
        for field in ("nw_src", "ipv4_src"):
            for value in UNREADABLE:
                with self.subTest(field=field, value=value):
                    with self.assertRaises(MalformedMatchValueError):
                        check_match_values({field: value, "nw_dst": HOST_A}, "installed")

    def test_an_absent_field_is_still_absent(self):
        # No address field at all: nothing to read, so it is not a malformed value; the verbs
        # give their answer for a match with no destination, the 400 "unsupported match".
        # [Co-developed with claude code -- Adam]
        topo, client = one_switch()
        for verb in ("route", "unroute", "modify"):
            with self.subTest(verb=verb):
                try:
                    got = call_verb(topo, verb, {"eth_type": 2048})
                except Exception as exc:  # noqa: BLE001 -- the exact type is what is asserted
                    caught = exc
                else:
                    self.fail(f"{verb} answered {got!r} for a match with no destination")
                self.assertIs(type(caught), FlowRequestUnusable, repr(caught))
                self.assertEqual((caught.status, caught.error), (400, "unsupported match"))
        self.assertEqual(client.calls, [])

    def test_the_endpoints_answer_400_for_an_empty_destination(self):
        topo, client = one_switch()
        api_routes.topology = topo
        self.addCleanup(setattr, api_routes, "topology", None)
        for handler in (api_routes.add_flow_entry, api_routes.delete_flow_entry,
                        api_routes.modify_flow_entry):
            for value in UNREADABLE:
                with self.subTest(handler=handler.__name__, value=value):
                    with self.assertRaises(HTTPException) as caught:
                        post(handler, {"dpid": 1, "match": {"nw_dst": value},
                                       "actions": out(2)})
                    self.assertEqual(caught.exception.status_code, 400)
        self.assertEqual(client.calls, [])

    def test_the_400_names_the_field_and_what_was_not_done(self):
        with self.assertRaises(MalformedMatchValueError) as caught:
            check_match_values({"nw_dst": ""}, "deleted")
        text = str(caught.exception)
        self.assertIn("nw_dst", text)
        self.assertIn("No rule was deleted", text)


# --- the two spellings of one field must agree ----------------------------------------------
# [Co-developed with claude code -- Adam]
# The proxy reads nw_dst first and the kernel's cache reads ipv4_dst first, so a request with
# both and different values was installed under one and recorded under the other. The kernel
# refuses it before queueing; the proxy refuses it too. The same address in both is accepted.

class TheTwoSpellingsMustAgreeTest(unittest.TestCase):

    def test_different_destinations_are_refused_by_every_verb(self):
        for a, b in ((HOST_A, HOST_B), (NET24, "10.0.2.0/24"), (HOST_A, NET24),
                     (NET24, "10.0.1.0/25")):
            for verb in ("route", "unroute", "modify"):
                with self.subTest(a=a, b=b, verb=verb):
                    topo, client = one_switch()
                    with self.assertRaises(MalformedMatchValueError) as caught:
                        call_verb(topo, verb, {"nw_dst": a, "ipv4_dst": b})
                    self.assertEqual(client.calls, [])
                    text = str(caught.exception)
                    self.assertIn("name different addresses", text)
                    self.assertIn(a, text)
                    self.assertIn(b, text)

    def test_the_same_destination_in_both_spellings_is_accepted(self):
        # Equal after normalisation: host bits cleared, /32 == bare.
        for a, b, written in ((HOST_A, HOST_A, (HOST_A, 32)),
                              (HOST_A, HOST_A + "/32", (HOST_A, 32)),
                              (NET24, NET24, ("10.0.1.0", 24)),
                              (NET24, "10.0.1.99/24", ("10.0.1.0", 24))):
            with self.subTest(a=a, b=b):
                topo, client = one_switch()
                self.assertTrue(topo.route_flow(1, {"nw_dst": a, "ipv4_dst": b}, out(2)))
                self.assertEqual(client.calls, [("insert", written[0], written[1], ZERO_MAC, 2)])

    def test_different_sources_are_refused(self):
        for verb in ("route", "unroute", "modify"):
            with self.subTest(verb=verb):
                topo, client = one_switch()
                with self.assertRaises(MalformedMatchValueError) as caught:
                    call_verb(topo, verb, {"nw_dst": HOST_A, "nw_src": SRC, "ipv4_src": HOST_B})
                self.assertEqual(client.calls, [])
                self.assertIn("name different addresses", str(caught.exception))

    def test_the_same_source_in_both_spellings_is_accepted(self):
        topo, client = one_switch()
        match = {"nw_dst": HOST_A, "nw_src": SRC, "ipv4_src": SRC}
        self.assertTrue(topo.route_flow(1, match, out(2), 100))
        self.assertEqual(len(client.calls), 1)
        self.assertEqual(client.calls[0][0], "insert5")

    def test_the_endpoint_answers_400_for_conflicting_spellings(self):
        topo, client = one_switch()
        api_routes.topology = topo
        self.addCleanup(setattr, api_routes, "topology", None)
        for handler in (api_routes.add_flow_entry, api_routes.delete_flow_entry,
                        api_routes.modify_flow_entry):
            with self.subTest(handler=handler.__name__):
                with self.assertRaises(HTTPException) as caught:
                    post(handler, {"dpid": 1, "actions": out(2),
                                   "match": {"nw_dst": HOST_A, "ipv4_dst": HOST_B}})
                self.assertEqual(caught.exception.status_code, 400)
        self.assertEqual(client.calls, [])


# --- the strict-delete 501 says what a delete does for this destination ---------------------
# [Co-developed with claude code -- Adam]
# A /32 that has a control-plane route is handed back to it; a prefix has none, and a delete of
# it removes the entry. The refusal text used to promise the restore for both.

class TheStrictDeleteRefusalIsTrueForThePrefixTest(unittest.TestCase):

    def refusal(self, destination):
        topo, _client = one_switch()
        api_routes.topology = topo
        self.addCleanup(setattr, api_routes, "topology", None)
        with self.assertRaises(HTTPException) as caught:
            post(api_routes.delete_flow_entry,
                 {"dpid": 1, "match": {"nw_dst": destination}, "priority": 100})
        self.assertEqual(caught.exception.status_code, 501)
        return caught.exception.detail

    def test_a_prefix_refusal_does_not_promise_a_restore(self):
        for destination in (NET24, "10.0.0.0/8", "10.0.1.7/31", "10.0.1.0/33"):
            with self.subTest(destination=destination):
                detail = self.refusal(destination)
                self.assertNotIn("restores the route", detail["remedy"])
                self.assertNotIn("hands the destination back", detail["message"])
                self.assertIn("nothing is restored", detail["remedy"])
                self.assertIn("restores nothing", detail["message"])

    def test_a_slash_32_refusal_still_says_the_route_is_restored(self):
        for destination in (HOST_A, HOST_A + "/32"):
            with self.subTest(destination=destination):
                detail = self.refusal(destination)
                self.assertIn("restores the route", detail["remedy"])
                self.assertIn("hands the destination back", detail["message"])


if __name__ == "__main__":
    unittest.main()
