"""
Tests for the contract test's own invariants and endpoint table.

[Co-developed with claude code -- Adam]

tools/contract_test/spec.py decides whether the whole system passes an L2 contract check, and
it had no tests at all. That matters more than it sounds: three of its checks were found
reporting PASS while examining zero records. An invariant that cannot fail is worse than a
missing one, because it occupies the slot where a real check would go and reports green.

So the first thing tested here is the thing that went wrong: an invariant handed nothing to
examine must FAIL, not pass. inv_flow_paths_non_empty and inv_tables_non_empty are written that
way and are pinned here. The three that still pass on empty input are pinned too, in tests
named "documents current behaviour" -- so the next person can see which ones are deliberate
(no traffic is a legitimate state) and which are a gap waiting to be closed.

The second thing tested is the endpoint table's safety properties, because a mistake there is
not a false pass, it is damage: `set_switches_power_state` deliberately sends action=on, since
"off" would cut a real device in TESTBED mode, and the flow writes deliberately aim at
ctx.probe_ip rather than a real host address. Those are one-character edits away from being
destructive and nothing else checks them.

_is_routable_unicast gets its own class because its whole subtlety is byte order: `src_ip` and
`dst_ip` carry in_addr::s_addr -- network byte order read as a native integer -- so on a
little-endian host the *first* octet is the *low* byte. Reading the wrong end silently swaps
which addresses are excluded, and the excluded set is what decides whether the check examines
anything at all.

Lives in tests/python/ rather than p4_proxy/tests/ because L1 runs this directory under a plain
python3 with no PYTHONPATH -- so nothing here may import grpc, networkx or requests, and spec.py
plus schema.py are deliberately dependency-free for the same reason.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests" -- a pytest-style module runs as a script that asserts
nothing and is reported as NO TESTS RAN. In this directory "Ran 0" is a hard failure.
"""

from __future__ import annotations

import os
import sys
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO_ROOT, "tools", "contract_test"))

import spec  # noqa: E402
from run_contract_test import Context  # noqa: E402
from schema import SchemaError, validate  # noqa: E402

#: The shipped P4 topology, used to build a *real* Context. See real_ctx().
P4_TOPOLOGY = os.path.join(REPO_ROOT, "setting",
                           "StaticNetworkTopologyP4_10Switches_4Hosts.json")

#: An address no host in any shipped topology owns, so a probe rule installed for it moves no
#: real traffic. Matches run_contract_test's --probe-ip default contract.
PROBE_IP = "10.255.255.254"


def real_ctx(topk=5):
    """
    The runner's own Context, not a double.

    Every endpoint whose query/body is a callable is invoked with this rather than with the
    hand-built Ctx below. That is a deliberate correction: the first version of this file used a
    stub for these too, and the stub was missing `a_switch_ip`, which the real Context does set
    (run_contract_test.py:112). The test "passed" for set_switches_power_state right up until it
    was run, and would then have reported an AttributeError as if spec.py were broken. A double
    that is missing an attribute the real object has will happily let you assert a contract that
    does not exist -- so where the contract is about what the runner actually supplies, use the
    runner's object.

    Context only reads a JSON file, so this needs no network and no kernel.
    """
    return Context(P4_TOPOLOGY, topk, PROBE_IP)


def ip(a, b, c, d):
    """
    An address the way the kernel puts it in a flow record.

    in_addr::s_addr is network byte order read as a native integer, so on a little-endian host
    the first octet is the low byte. Building it this way rather than with a shift-24 makes the
    convention explicit, and it is the convention the invariant has to get right.
    """
    return a | (b << 8) | (c << 16) | (d << 24)


class Ctx:
    """
    Stands in for run_contract_test.Context, for the INVARIANTS only.

    The invariants read only these four expectation fields, and a hand-built object lets each
    test state its expectations in one place instead of deriving them from a 17 kB topology file.

    It is deliberately NOT used for the endpoint query/body callables -- those get real_ctx().
    See the note there for why.
    """

    def __init__(self, switches=2, hosts=1, edges=2, dpids=(1, 2), topk=5):
        self.expected_switches = switches
        self.expected_hosts = hosts
        self.expected_edges = edges
        self.expected_dpids = set(dpids)
        self.topk = topk


def node(dpid, vertex_type=0, is_up=True, is_enabled=True, name=None):
    return {"device_name": name or f"s{dpid}", "dpid": dpid, "vertex_type": vertex_type,
            "is_up": is_up, "is_enabled": is_enabled}


def edge(src=1, dst=2, is_up=True, is_enabled=True, cap=10 ** 9, used=0.0, pct=0.0):
    return {"src_dpid": src, "dst_dpid": dst, "src_interface": 1, "dst_interface": 1,
            "is_up": is_up, "is_enabled": is_enabled,
            "link_bandwidth_bps": cap, "link_bandwidth_usage_bps": used,
            "link_bandwidth_utilization_percent": pct}


def flow(dst, src=None, path=(), last_sec=1000.0, next_sec=1000.0):
    return {"src_ip": src if src is not None else ip(10, 0, 0, 1), "dst_ip": dst,
            "path": list(path),
            "estimated_flow_sending_rate_bps_in_the_last_sec": last_sec,
            "estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot": next_sec}


A_PATH = [{"node": 1, "interface": 2}]


# --- the failure mode this file exists for -----------------------------------------


class ExaminedNothingTest(unittest.TestCase):
    """
    An invariant handed nothing to examine must fail.

    This is not hypothetical. The exclusion of multicast exists because a real run failed on
    192.168.123.16 -> 224.0.0.251 -- the host's own Avahi mDNS leaking onto a switch management
    interface and into the sFlow sample set. Whether that fires depends on whether Avahi
    happened to announce during the sampling window, so a short quiet capture can easily consist
    of nothing but excluded traffic. That is exactly when the check matters least and is most
    likely to be believed.
    """

    def test_a_sample_of_only_multicast_fails_rather_than_reporting_every_path_resolved(self):
        data = [flow(ip(224, 0, 0, 251), path=A_PATH), flow(ip(239, 255, 255, 250))]
        out = spec.inv_flow_paths_non_empty(data, Ctx())

        self.assertEqual(len(out), 1, "an all-multicast sample was reported as a pass")
        self.assertIn("examined nothing", out[0])

    def test_a_sample_of_only_link_local_and_broadcast_also_fails(self):
        data = [flow(ip(169, 254, 3, 4)), flow(ip(255, 255, 255, 255))]
        self.assertTrue(spec.inv_flow_paths_non_empty(data, Ctx()))

    def test_an_entirely_empty_flow_list_fails_too(self):
        # Zero sampled flows is the most obvious version of "examined nothing", and the one most
        # likely to be read as success.
        self.assertTrue(spec.inv_flow_paths_non_empty([], Ctx()))

    def test_no_switch_reporting_a_flow_table_at_all_fails(self):
        # /stats/flow/<dpid> was a hardcoded [] stub in P4 mode. An empty list here has to fail,
        # or that stub reads as "every switch's table is fine".
        out = spec.inv_tables_non_empty([], Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("no switch reported a flow table", out[0])

    def test_a_switch_present_but_with_an_empty_table_is_named(self):
        data = [{"dpid": 1, "flows": {"1": [{"actions": []}]}},
                {"dpid": 2, "flows": {}}]
        out = spec.inv_tables_non_empty(data, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("2", out[0])

    def test_a_table_map_with_keys_but_no_entries_still_counts_as_empty(self):
        # {"0": []} is what a switch answers when it has a table and no rules in it. Counting the
        # keys rather than the entries would read that as a populated table.
        out = spec.inv_tables_non_empty([{"dpid": 3, "flows": {"0": [], "1": []}}], Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("3", out[0])

    def test_populated_tables_report_nothing(self):
        data = [{"dpid": 1, "flows": {"1": [{"actions": ["OUTPUT:1"]}]}}]
        self.assertEqual(spec.inv_tables_non_empty(data, Ctx()), [])


class ExaminedNothingButPassesTest(unittest.TestCase):
    """
    The invariants that still report success on empty input. Documents current behaviour.

    Two of these are defensible and one is a gap:

      * inv_flow_rates_nonzero -- no flows at all is a legitimate state (nothing is generating
        traffic), and inv_flows_present covers "there should be traffic" under --with-traffic.
      * inv_edges_enabled and inv_link_bandwidth_sane -- an empty edge list means the graph has
        no links, which inv_graph_matches_topology fails on separately, so the condition is
        caught. It is caught by a *different* check though, which is worth knowing when reading
        a report that says these two passed.

    Pinned rather than fixed because changing them is a behaviour change to the contract test,
    which is not this file's job.
    """

    def test_an_empty_flow_list_is_not_a_rate_failure(self):
        self.assertEqual(spec.inv_flow_rates_nonzero([], Ctx()), [])

    def test_an_empty_edge_list_passes_the_edge_check_having_examined_no_edges(self):
        self.assertEqual(spec.inv_edges_enabled({"nodes": [], "edges": []}, Ctx()), [])

    def test_an_empty_edge_list_passes_the_bandwidth_check_having_examined_no_edges(self):
        self.assertEqual(spec.inv_link_bandwidth_sane({"nodes": [], "edges": []}, Ctx()), [])


# --- address classification --------------------------------------------------------


class RoutableUnicastTest(unittest.TestCase):
    """
    Which destinations are required to have a path.

    Getting this wrong in the permissive direction makes the check fail on the host's own mDNS,
    which is non-deterministic; getting it wrong in the strict direction empties the candidate
    set, which is the "examined nothing" failure above.
    """

    def test_the_first_octet_is_read_from_the_low_byte_as_the_kernel_encodes_it(self):
        # The pair that catches a byte-order mistake: these two are byte-reversals of each other,
        # so reading the high byte instead of the low one swaps both answers and nothing else in
        # this class would notice.
        self.assertFalse(spec._is_routable_unicast(ip(224, 0, 0, 10)))
        self.assertTrue(spec._is_routable_unicast(ip(10, 0, 0, 224)))

    def test_the_multicast_address_that_broke_a_real_run_is_excluded(self):
        self.assertFalse(spec._is_routable_unicast(ip(224, 0, 0, 251)))

    def test_the_top_of_the_multicast_range_is_excluded_too(self):
        # 239.255.255.250 is SSDP, which any Windows or media device on the management LAN emits.
        self.assertFalse(spec._is_routable_unicast(ip(239, 255, 255, 250)))

    def test_the_address_just_below_multicast_is_still_required_to_have_a_path(self):
        self.assertTrue(spec._is_routable_unicast(ip(223, 1, 2, 3)))

    def test_the_255_prefix_and_the_limited_broadcast_are_excluded(self):
        self.assertFalse(spec._is_routable_unicast(0xFFFFFFFF))
        self.assertFalse(spec._is_routable_unicast(ip(255, 0, 0, 1)))

    def test_a_directed_broadcast_is_deliberately_still_required_to_have_a_path(self):
        # 10.0.0.255 has first octet 10. The flow record carries no netmask, so the check cannot
        # know it is a broadcast; being over-strict fails loudly with the address named, which is
        # fixable in a minute, whereas guessing a /24 would silently excuse a real missing path
        # to host .255.
        self.assertTrue(spec._is_routable_unicast(ip(10, 0, 0, 255)))

    def test_link_local_is_excluded(self):
        self.assertFalse(spec._is_routable_unicast(ip(169, 254, 1, 1)))

    def test_a_169_address_outside_link_local_is_still_required_to_have_a_path(self):
        # 169.0.0.0/8 is ordinary routable space; only 169.254/16 is link-local. Excluding the
        # whole /8 would drop real destinations from the candidate set.
        self.assertTrue(spec._is_routable_unicast(ip(169, 1, 2, 3)))

    def test_an_ordinary_host_address_is_routable(self):
        self.assertTrue(spec._is_routable_unicast(ip(10, 0, 0, 4)))
        self.assertTrue(spec._is_routable_unicast(ip(192, 168, 123, 16)))


class FlowPathInvariantTest(unittest.TestCase):
    def test_a_unicast_flow_with_no_path_is_named(self):
        out = spec.inv_flow_paths_non_empty([flow(ip(10, 0, 0, 4))], Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("empty path", out[0])

    def test_unicast_flows_that_all_have_a_path_report_nothing(self):
        data = [flow(ip(10, 0, 0, 4), path=A_PATH), flow(ip(10, 0, 0, 2), path=A_PATH)]
        self.assertEqual(spec.inv_flow_paths_non_empty(data, Ctx()), [])

    def test_multicast_chatter_alongside_real_flows_is_excluded_by_destination(self):
        # The exclusion is on the *destination*, which is the end that determines whether a
        # unicast path can exist. Excluding by source would drop a real flow whose source happens
        # to be excluded, and keep mDNS traffic whose source is an ordinary host address.
        data = [flow(ip(224, 0, 0, 251), src=ip(192, 168, 123, 16)),
                flow(ip(10, 0, 0, 4), path=A_PATH)]
        self.assertEqual(spec.inv_flow_paths_non_empty(data, Ctx()), [])

    def test_the_failure_counts_only_the_flows_it_examined(self):
        # "1 of 3" when only 2 were candidates would misstate how much was checked, which is the
        # number a reader uses to decide whether to believe the result.
        data = [flow(ip(224, 0, 0, 251)),
                flow(ip(10, 0, 0, 4)),
                flow(ip(10, 0, 0, 5), path=A_PATH)]
        out = spec.inv_flow_paths_non_empty(data, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("1 of 2", out[0])


class FlowRateInvariantTest(unittest.TestCase):
    def test_every_flow_reporting_zero_is_a_failure(self):
        data = [flow(ip(10, 0, 0, 4), last_sec=0, next_sec=0),
                flow(ip(10, 0, 0, 5), last_sec=0, next_sec=0)]
        out = spec.inv_flow_rates_nonzero(data, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("rate computation is not working", out[0])

    def test_a_flow_with_a_rate_in_either_window_is_not_counted_as_zero(self):
        # The two windows are the last second and the next; a flow that started mid-window has
        # one of them at zero and is working perfectly well.
        data = [flow(ip(10, 0, 0, 4), last_sec=0, next_sec=5000),
                flow(ip(10, 0, 0, 5), last_sec=0, next_sec=0)]
        self.assertEqual(spec.inv_flow_rates_nonzero(data, Ctx()), [])


# --- graph invariants --------------------------------------------------------------


class GraphInvariantTest(unittest.TestCase):
    def a_graph(self, nodes=None, edges=None):
        return {"nodes": nodes if nodes is not None else [node(1), node(2),
                                                         node(0, vertex_type=1, name="h1")],
                "edges": edges if edges is not None else [edge(1, 2), edge(2, 1)]}

    def test_a_graph_that_matches_the_topology_file_reports_nothing(self):
        self.assertEqual(spec.inv_graph_matches_topology(self.a_graph(), Ctx()), [])

    def test_a_missing_switch_is_reported_with_both_counts(self):
        graph = self.a_graph(nodes=[node(1), node(0, vertex_type=1, name="h1")])
        out = spec.inv_graph_matches_topology(graph, Ctx())
        self.assertTrue(any("switch count is 1" in m for m in out))

    def test_the_host_count_is_checked_separately_from_the_switch_count(self):
        # Counting by vertex_type is the only thing that separates them, and a host miscounted as
        # a switch would make both totals wrong in compensating directions.
        graph = self.a_graph(nodes=[node(1), node(2)])
        out = spec.inv_graph_matches_topology(graph, Ctx())
        self.assertTrue(any("host count is 0" in m for m in out), out)

    def test_the_edge_count_is_checked(self):
        graph = self.a_graph(edges=[edge(1, 2)])
        out = spec.inv_graph_matches_topology(graph, Ctx())
        self.assertTrue(any("edge count is 1" in m for m in out), out)

    def test_a_duplicate_dpid_is_reported(self):
        graph = self.a_graph(nodes=[node(1), node(1), node(0, vertex_type=1, name="h1")])
        out = spec.inv_graph_matches_topology(graph, Ctx())
        self.assertTrue(any("duplicate switch dpid" in m for m in out), out)

    def test_a_dpid_the_topology_file_does_not_contain_is_named(self):
        graph = self.a_graph(nodes=[node(1), node(99), node(0, vertex_type=1, name="h1")])
        out = spec.inv_graph_matches_topology(graph, Ctx())
        self.assertTrue(any("not present in the topology file: [99]" in m for m in out), out)

    def test_a_dpid_in_the_topology_file_but_missing_from_the_graph_is_named(self):
        graph = self.a_graph(nodes=[node(1), node(99), node(0, vertex_type=1, name="h1")])
        out = spec.inv_graph_matches_topology(graph, Ctx())
        self.assertTrue(any("missing from the graph: [2]" in m for m in out), out)


class SwitchesUpTest(unittest.TestCase):
    """
    The single highest-value invariant for P4 work: in P4 mode the graph stays isEnabled=false
    unless the proxy calls /ndt/inform_switch_entered, which silently empties BFS pathing,
    flow-table polling and link usage.
    """

    def test_a_switch_that_is_down_is_named(self):
        data = {"nodes": [node(1), node(2, is_up=False)]}
        out = spec.inv_all_switches_up(data, Ctx())
        self.assertTrue(any("not up" in m and "s2" in m for m in out), out)

    def test_a_switch_that_is_not_enabled_is_named_with_the_cause_to_look_for(self):
        data = {"nodes": [node(1, is_enabled=False)]}
        out = spec.inv_all_switches_up(data, Ctx())
        self.assertTrue(any("inform_switch_entered" in m for m in out), out)

    def test_a_host_that_is_down_is_not_reported_as_a_switch_fault(self):
        # Hosts in the shipped topology are down almost all the time -- static ARP means most
        # host edges never come up. Reporting them here would make this invariant permanently red
        # and therefore permanently ignored.
        data = {"nodes": [node(1), node(0, vertex_type=1, is_up=False, name="h1")]}
        self.assertEqual(spec.inv_all_switches_up(data, Ctx()), [])

    def test_a_healthy_fabric_reports_nothing(self):
        self.assertEqual(spec.inv_all_switches_up({"nodes": [node(1), node(2)]}, Ctx()), [])


class EdgeInvariantTest(unittest.TestCase):
    def test_an_edge_that_is_up_but_not_enabled_is_still_reported(self):
        # These are separate fields with separate causes: is_up is link state, is_enabled means
        # the control plane can drive it. Requiring both to be false before complaining would
        # hide the P4 case entirely, where edges come up and are never enabled.
        data = {"edges": [edge(1, 2, is_up=True, is_enabled=False)]}
        out = spec.inv_edges_enabled(data, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("1 edge(s) down/disabled", out[0])

    def test_an_edge_that_is_enabled_but_down_is_reported(self):
        data = {"edges": [edge(1, 2, is_up=False, is_enabled=True)]}
        self.assertEqual(len(spec.inv_edges_enabled(data, Ctx())), 1)

    def test_a_long_list_of_down_edges_is_summarised_rather_than_printed_in_full(self):
        # The shipped topology has 40 edges and 254 of 256 host edges are down in OVS mode, so an
        # unbounded list here is a screenful that hides every other failure in the report.
        data = {"edges": [edge(i, i + 1, is_up=False) for i in range(1, 21)]}
        out = spec.inv_edges_enabled(data, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("(+15 more)", out[0])

    def test_healthy_edges_report_nothing(self):
        self.assertEqual(spec.inv_edges_enabled({"edges": [edge(1, 2)]}, Ctx()), [])


class BandwidthInvariantTest(unittest.TestCase):
    def test_usage_above_capacity_is_reported(self):
        data = {"edges": [edge(cap=1000, used=1001)]}
        out = spec.inv_link_bandwidth_sane(data, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("above capacity", out[0])

    def test_a_zero_capacity_edge_is_exempt_because_the_capacity_is_unknown(self):
        # An edge with no declared capacity cannot be over it. Complaining would make every
        # untyped link a failure.
        data = {"edges": [edge(cap=0, used=999999)]}
        self.assertEqual(spec.inv_link_bandwidth_sane(data, Ctx()), [])

    def test_a_utilisation_outside_zero_to_one_hundred_is_reported(self):
        data = {"edges": [edge(pct=101.0)]}
        out = spec.inv_link_bandwidth_sane(data, Ctx())
        self.assertTrue(any("out of 0..100" in m for m in out), out)

    def test_a_negative_utilisation_is_reported(self):
        data = {"edges": [edge(pct=-0.5)]}
        self.assertTrue(spec.inv_link_bandwidth_sane(data, Ctx()))

    def test_at_most_ten_problems_are_returned(self):
        # 40 edges each producing two messages would bury the rest of the report.
        data = {"edges": [edge(cap=1000, used=2000, pct=200.0) for _ in range(20)]}
        self.assertEqual(len(spec.inv_link_bandwidth_sane(data, Ctx())), 10)

    def test_a_sane_edge_reports_nothing(self):
        data = {"edges": [edge(cap=10 ** 9, used=5.0e8, pct=50.0)]}
        self.assertEqual(spec.inv_link_bandwidth_sane(data, Ctx()), [])


# --- answers that claim success -----------------------------------------------------


class HonestAnswerTest(unittest.TestCase):
    """
    Two checks whose entire purpose is to reject a 200 that claims more than the kernel knows.
    """

    def test_a_200_whose_status_does_not_say_locked_is_a_failure(self):
        out = spec.inv_lock_acquired({"status": "busy"}, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("does not indicate the lock was taken", out[0])

    def test_a_missing_status_is_a_failure_rather_than_a_default_success(self):
        self.assertTrue(spec.inv_lock_acquired({}, Ctx()))

    def test_the_status_is_compared_without_regard_to_case(self):
        # The kernel has answered both "locked" and "Locked" across versions; a case-sensitive
        # comparison would turn a working lock into a contract failure.
        self.assertEqual(spec.inv_lock_acquired({"status": "LOCKED"}, Ctx()), [])

    def test_each_wording_the_kernel_uses_for_a_taken_lock_is_accepted(self):
        for status in ("locked", "acquired", "success", "ok"):
            self.assertEqual(spec.inv_lock_acquired({"status": status}, Ctx()), [],
                             f"{status!r} was rejected")

    def test_a_flow_write_that_claims_success_instead_of_queued_is_a_failure(self):
        # The flow endpoints enqueue onto an asynchronous dispatcher and return before any request
        # reaches the controller, so they cannot know whether the entries were programmed. They
        # used to answer "Flow installed" regardless.
        out = spec.inv_flow_write_is_honest_about_being_queued(
            {"status": "success", "accepted": 1}, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("expected status 'queued'", out[0])

    def test_a_queued_answer_that_does_not_say_how_many_were_accepted_is_a_failure(self):
        out = spec.inv_flow_write_is_honest_about_being_queued({"status": "queued"}, Ctx())
        self.assertEqual(out, ["response does not say how many entries were accepted"])

    def test_an_honest_queued_answer_passes(self):
        self.assertEqual(spec.inv_flow_write_is_honest_about_being_queued(
            {"status": "queued", "accepted": 2}, Ctx()), [])


class SimpleRangeInvariantTest(unittest.TestCase):
    def test_a_power_state_that_is_neither_on_nor_off_is_reported(self):
        out = spec.inv_power_state_values({"10.0.0.1": "UNKNOWN"}, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("UNKNOWN", out[0])

    def test_on_and_off_are_accepted(self):
        self.assertEqual(
            spec.inv_power_state_values({"10.0.0.1": "ON", "10.0.0.2": "OFF"}, Ctx()), [])

    def test_an_average_link_usage_outside_the_percentage_range_is_reported(self):
        out = spec.inv_avg_link_usage_range({"avg_link_usage": 250.0}, Ctx())
        self.assertEqual(len(out), 1)
        self.assertIn("expected 0..100", out[0])

    def test_an_average_link_usage_inside_the_range_passes(self):
        self.assertEqual(spec.inv_avg_link_usage_range({"avg_link_usage": 12.5}, Ctx()), [])

    def test_more_flows_than_k_is_reported(self):
        out = spec.inv_topk_bounded([{}] * 6, Ctx(topk=5))
        self.assertEqual(len(out), 1)
        self.assertIn("asked for top 5", out[0])

    def test_fewer_flows_than_k_is_not_a_failure(self):
        # A quiet network genuinely has fewer than k flows; requiring exactly k would fail on a
        # correct answer.
        self.assertEqual(spec.inv_topk_bounded([{}] * 2, Ctx(topk=5)), [])

    def test_a_switch_with_no_power_reading_is_named(self):
        out = spec.inv_power_covers_switches([{"dpid": 1, "power_consumed": 3.0}],
                                            Ctx(dpids=(1, 2)))
        self.assertEqual(len(out), 1)
        self.assertIn("[2]", out[0])

    def test_a_power_report_covering_every_switch_passes(self):
        data = [{"dpid": 1, "power_consumed": 3.0}, {"dpid": 2, "power_consumed": 4.0}]
        self.assertEqual(spec.inv_power_covers_switches(data, Ctx(dpids=(1, 2))), [])

    def test_a_utilisation_map_missing_switches_is_reported(self):
        out = spec.inv_util_map_covers_switches({"10.0.0.1": 5.0}, Ctx(switches=2))
        self.assertEqual(len(out), 1)
        self.assertIn("only 1", out[0])


# --- the endpoint table ------------------------------------------------------------


class LockTypeTest(unittest.TestCase):
    def test_the_lock_type_is_one_the_kernel_actually_accepts(self):
        # LockManager::stringToLockType accepts only these three and returns Unknown otherwise,
        # and acquireLock/renew reject Unknown. An invented type makes every lock check fail
        # while never exercising the mutual-exclusion logic at all -- a red report that proves
        # nothing about locking.
        self.assertIn(spec.LOCK_TYPE, ("routing_lock", "graph_lock", "power_lock"))

    def test_the_lock_type_is_not_one_a_shipped_application_uses(self):
        # Energy-Saving-App and Traffic-Engineering-App both take routing_lock. Using it here
        # would let a contract run block a running application, or be blocked by one and report a
        # kernel fault.
        self.assertNotEqual(spec.LOCK_TYPE, "routing_lock")

    def test_every_lock_endpoint_uses_the_same_type(self):
        # The sequence is acquire / conflict / renew / release / re-acquire; a different type in
        # any one of them makes the conflict check pass for the wrong reason.
        lock_bodies = [e["body"] for e in spec.ENDPOINTS
                       if e["path"].endswith(("acquire_lock", "renew_lock", "release_lock"))]
        self.assertTrue(lock_bodies, "no lock endpoints found at all")
        types = {b["type"] for b in lock_bodies if isinstance(b, dict) and "type" in b}
        self.assertEqual(types - {"no_such_lock_type_exists"}, {spec.LOCK_TYPE})


class EndpointTableTest(unittest.TestCase):
    def named(self, name):
        found = [e for e in spec.ENDPOINTS if e["name"] == name]
        self.assertEqual(len(found), 1, f"{name} appears {len(found)} times")
        return found[0]

    def test_every_endpoint_name_is_unique(self):
        # The runner keys results by name, and the lock sequence relies on distinct names for
        # what are deliberately repeated calls to the same path.
        names = [e["name"] for e in spec.ENDPOINTS]
        dupes = sorted({n for n in names if names.count(n) > 1})
        self.assertEqual(dupes, [])

    def test_every_endpoint_declares_a_schema(self):
        # A missing schema is a KeyError in the runner at the point of checking, which reads as a
        # broken endpoint rather than a broken spec.
        missing = [e["name"] for e in spec.ENDPOINTS if not e.get("schema")]
        self.assertEqual(missing, [])

    def test_every_error_path_endpoint_says_which_statuses_it_will_accept(self):
        # Without expect_status an error-path check has nothing to assert, so a 500 would pass.
        missing = [e["name"] for e in spec.ENDPOINTS
                   if e["category"] == spec.ERRORPATH and not e.get("expect_status")]
        self.assertEqual(missing, [])

    def test_no_error_path_accepts_a_500(self):
        # The whole point of the category: the kernel has already shipped three 500s on malformed
        # input. Accepting 5xx anywhere here would let the next one through.
        #
        # 503 is the one exception, and only because it is not the same event. A 500/502/504 on
        # an error path means an unhandled exception reached the client; a 503 means the route
        # was reached and deliberately declined -- which is what the --no-ai guard on
        # intent_translator/text does, and that guard is itself the fix for a null dereference
        # that used to kill the process. Banning it would force the check to assert a status the
        # kernel provably does not return (measured live 2026-08-17), i.e. to be deleted. The
        # same distinction is drawn in l3_component_check.probe_exists.
        allowed_5xx = {503}
        bad = [(e["name"], e["expect_status"]) for e in spec.ENDPOINTS
               if e["category"] == spec.ERRORPATH
               and any(s >= 500 and s not in allowed_5xx for s in e["expect_status"])]
        self.assertEqual(bad, [])

    def test_only_the_disabled_translator_is_allowed_to_answer_5xx(self):
        # The exception above is narrow on purpose: it exists for one endpoint whose 503 is
        # documented. If a second error path starts accepting 503, that is a decision someone
        # should have to make here rather than inherit.
        accepting_503 = sorted(e["name"] for e in spec.ENDPOINTS
                               if e["category"] == spec.ERRORPATH
                               and 503 in e["expect_status"])
        self.assertEqual(accepting_503, ["intent_translator_text__incomplete_body"])

    def test_the_lock_conflict_check_requires_423_and_nothing_else(self):
        # This is the only check that proves mutual exclusion works. Accepting a 200 as well
        # would make it pass against a LockManager that hands the same lock to everyone.
        self.assertEqual(self.named("acquire_lock_conflict")["expect_status"], [423])

    def test_every_path_is_under_the_ndt_prefix(self):
        odd = [e["name"] for e in spec.ENDPOINTS if not e["path"].startswith("/ndt/")]
        self.assertEqual(odd, [])

    def test_categories_are_only_the_three_the_runner_knows(self):
        # The runner selects by category; an unrecognised one silently never runs.
        unknown = {e["category"] for e in spec.ENDPOINTS} - {spec.READ, spec.MUTATE,
                                                             spec.ERRORPATH}
        self.assertEqual(unknown, set())


class DestructiveEndpointTest(unittest.TestCase):
    """
    The properties whose failure is damage rather than a false report.

    Each of these is one character away from doing something to a live network, and nothing else
    in the repo checks them.
    """

    def named(self, name):
        found = [e for e in spec.ENDPOINTS if e["name"] == name]
        self.assertEqual(len(found), 1)
        return found[0]

    def test_nothing_that_changes_state_is_categorised_as_a_read(self):
        # READ means "safe: never changes network state", and a read-only run does not need
        # --allow-mutations. A write endpoint mislabelled READ would run unasked.
        writes = ("install_flow_entry", "modify_flow_entry", "delete_flow_entry",
                  "set_switches_power_state", "modify_nickname", "modify_device_name",
                  "app_register", "inform_switch_entered", "received_a_simulation_case",
                  "install_flow_entries_modify_flow_entries_and_delete_flow_entries")
        offenders = [e["name"] for e in spec.ENDPOINTS
                     if e["category"] == spec.READ and e["path"].split("/")[-1] in writes]
        self.assertEqual(offenders, [])

    def test_the_power_endpoint_deliberately_switches_a_switch_on_not_off(self):
        # "off" would cut a real device in TESTBED mode. The endpoint is exercised by sending
        # action=on to an already-powered switch.
        query = self.named("set_switches_power_state")["query"](real_ctx())
        self.assertEqual(query["action"], "on")

    def test_the_power_endpoint_names_a_switch_address_not_a_host_one(self):
        # The switches are 192.168.123.x management addresses and the hosts are 10.0.0.x. Sending
        # a host address to a power endpoint in TESTBED mode addresses the wrong machine.
        query = self.named("set_switches_power_state")["query"](real_ctx())
        self.assertEqual(query["ip"], real_ctx().a_switch_ip)
        self.assertTrue(query["ip"].startswith("192.168.123."), query["ip"])

    def test_the_flow_writes_aim_at_a_probe_address_rather_than_a_real_host(self):
        # A rule installed for a real host address on a live fabric changes where that host's
        # traffic goes, for the rest of the run.
        ctx = real_ctx()
        for name in ("install_flow_entry", "modify_flow_entry", "delete_flow_entry"):
            body = self.named(name)["body"](ctx)
            self.assertEqual(body["match"]["ipv4_dst"], PROBE_IP,
                             f"{name} writes a rule for a real host address")
            self.assertNotIn(body["match"]["ipv4_dst"], (ctx.src_host_ip, ctx.dst_host_ip), name)

    def test_the_batch_write_deletes_everything_it_installs(self):
        # It leaves no rule behind, which is the only reason it is safe to run against a live
        # fabric at all.
        body = self.named("batch_flow_entries")["body"](real_ctx())
        installed = {(e["dpid"], e["match"]["ipv4_dst"]) for e in body["install_flow_entries"]}
        deleted = {(e["dpid"], e["match"]["ipv4_dst"]) for e in body["delete_flow_entries"]}
        self.assertEqual(installed, deleted)
        self.assertTrue(installed, "the batch installs nothing, so it proves nothing")

    def test_the_device_rename_writes_back_the_name_it_found(self):
        # modify_device_name writes to the topology JSON on disk, so a real rename here would
        # edit a shipped file (and possibly the wrong one).
        #
        # The field is `new_name`, per 2026-01-02_ndt_api.md section 15 and the kernel's own
        # parse. This assertion said `device_name` until 2026-08-17, which is what the check
        # was sending -- so the meta-test agreed with the check and both disagreed with the
        # documented contract, and the kernel had been answering an honest 400 to every run.
        # Nothing noticed because MUTATE only runs behind --allow-mutations.
        ctx = real_ctx()
        body = self.named("modify_device_name")["body"](ctx)
        self.assertEqual(body["new_name"], ctx.original_device_name)
        self.assertEqual(body["dpid"], ctx.a_dpid)

    def test_the_nickname_rename_writes_back_the_nickname_it_found(self):
        # Same defect, same commit, same reason it went unseen: the field is `new_nickname`.
        ctx = real_ctx()
        body = self.named("modify_nickname")["body"](ctx)
        self.assertEqual(body["new_nickname"], ctx.original_nickname)
        self.assertEqual(body["identifier"]["value"], ctx.a_dpid)

    def test_every_ctx_field_the_spec_reads_is_one_the_runner_actually_supplies(self):
        # The failure this exists for: a query/body lambda that reads a field Context does not
        # set raises AttributeError *inside the runner*, which surfaces as that endpoint being
        # broken rather than as the spec being wrong. Invoking every callable against the real
        # Context is the only thing that catches it, and it is cheap -- Context just reads a file.
        #
        # It is also how the first version of this file was wrong, in the other direction: it
        # invoked these against a hand-built double that was missing a_switch_ip, so the check
        # asserted a contract the runner could not have honoured.
        ctx = real_ctx()
        for endpoint in spec.ENDPOINTS:
            for key in ("query", "body"):
                value = endpoint.get(key)
                if callable(value):
                    try:
                        value(ctx)
                    except AttributeError as err:
                        self.fail(f"{endpoint['name']}'s {key} reads a Context field that "
                                  f"run_contract_test.Context does not set: {err}")

    def test_the_unknown_dpid_error_paths_use_a_dpid_no_topology_could_contain(self):
        # If it collided with a real dpid the check would install a rule on a live switch and
        # then assert that it failed.
        for name in ("install_flow_entry__unknown_dpid", "get_num_of_flows__unknown_dpid"):
            self.assertGreater(self.named(name)["body"]["dpid"], 10 ** 9, name)


class CategorySelectionTest(unittest.TestCase):
    def test_only_the_categories_asked_for_are_returned(self):
        chosen = spec.endpoints_by_category([spec.ERRORPATH])
        self.assertTrue(chosen)
        self.assertEqual({e["category"] for e in chosen}, {spec.ERRORPATH})

    def test_declaration_order_is_preserved_because_the_lock_sequence_depends_on_it(self):
        # acquire must run before the conflict check, which must run before the release, which
        # must run before the re-acquire. Sorting these -- by name, or by anything else -- makes
        # the conflict check acquire a free lock and pass while proving nothing.
        names = [e["name"] for e in spec.endpoints_by_category([spec.READ])]
        sequence = ["acquire_lock", "acquire_lock_conflict", "renew_lock", "release_lock",
                    "acquire_lock_after_release", "release_lock_cleanup"]
        positions = [names.index(n) for n in sequence if n in names]
        self.assertEqual(positions, sorted(positions), names)
        self.assertEqual(len(positions), len(sequence) - 1,
                         "acquire_lock_conflict is an error path, so it is not in READ")

    def test_asking_for_nothing_returns_nothing(self):
        self.assertEqual(spec.endpoints_by_category([]), [])


# --- the schemas themselves --------------------------------------------------------


class SchemaDeclarationTest(unittest.TestCase):
    """
    A schema that accepts anything is the same failure as an invariant that examines nothing.
    """

    def test_openflow_actions_must_be_strings_because_the_classifier_parses_only_that_form(self):
        # Classifier.cpp parses "OUTPUT:1" and silently ignores {"type":"OUTPUT","port":1}, so
        # this is a contract requirement for the P4 proxy, not a formatting preference. Accepting
        # both would let the proxy ship a shape that produces empty paths.
        good = {"actions": ["OUTPUT:1"], "match": {}, "priority": 1, "table_id": 0}
        bad = {"actions": [{"type": "OUTPUT", "port": 1}], "match": {}, "priority": 1,
               "table_id": 0}
        self.assertEqual(validate(spec.OF_FLOW_ENTRY, good), [])
        self.assertTrue(validate(spec.OF_FLOW_ENTRY, bad),
                        "the dict action form was accepted; the Classifier ignores it")

    def test_a_graph_node_missing_its_liveness_fields_is_rejected(self):
        # is_up and is_enabled are what inv_all_switches_up reads; a node without them would make
        # that invariant raise KeyError rather than report.
        complete = {"device_name": "s1", "dpid": 1, "ip": [167772161], "is_enabled": True,
                    "is_up": True, "mac": 1, "vertex_type": 0, "brand_name": "x",
                    "device_layer": 1}
        self.assertEqual(validate(spec.GRAPH_NODE, complete), [])
        without = dict(complete)
        del without["is_up"]
        self.assertTrue(validate(spec.GRAPH_NODE, without))

    def test_an_ip_above_uint32_is_rejected_so_an_overflow_shows_up(self):
        # The kernel stores IPv4 as a uint32 in network order, so a larger value means something
        # overflowed or a field was misread -- which is invisible if the schema accepts any int.
        self.assertEqual(validate(spec.IP_LIST, [0, 0xFFFFFFFF]), [])
        self.assertTrue(validate(spec.IP_LIST, [0x1FFFFFFFF]))

    def test_the_path_switch_count_alternatives_each_require_a_concrete_shape(self):
        # One branch used to be Obj({"status": ...}, strict=False), which accepts ANY object
        # containing "status" -- switch_count could vanish entirely and still pass.
        schema = [e for e in spec.ENDPOINTS if e["name"] == "get_path_switch_count"][0]["schema"]
        self.assertEqual(validate(schema, {"status": "success", "src_ip": "10.0.0.1",
                                           "dst_ip": "10.0.0.4", "switch_count": 3}), [])
        self.assertTrue(validate(schema, {"status": "success"}),
                        "a bare status object was accepted, so switch_count is unchecked")

    def test_a_flow_record_must_carry_a_path_field(self):
        # inv_flow_paths_non_empty reads f["path"]; without it the invariant raises rather than
        # reporting, which in the runner reads as a broken check rather than a missing path.
        record = {"src_ip": 1, "dst_ip": 2, "src_port": 1, "dst_port": 2, "protocol_id": 6,
                  "estimated_flow_sending_rate_bps_in_the_last_sec": 1.0,
                  "estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot": 1.0,
                  "estimated_packet_rate_in_the_last_sec": 1.0,
                  "estimated_packet_rate_in_the_proceeding_1sec_timeslot": 1.0,
                  "first_sampled_time": "t", "latest_sampled_time": "t", "path": []}
        self.assertEqual(validate(spec.FLOW_RECORD, record), [])
        without = dict(record)
        del without["path"]
        self.assertTrue(validate(spec.FLOW_RECORD, without))

    def test_the_graph_must_have_at_least_one_node(self):
        # An empty node list is what a kernel with no topology loaded returns, and every graph
        # invariant reports success on it except the count check.
        self.assertTrue(validate(spec.GRAPH_DATA, {"nodes": [], "edges": []}))

    def test_a_schema_error_names_the_field_that_broke(self):
        # The module exists for precise messages; "get_graph_data failed" is barely better than
        # eyeballing the GUI.
        with self.assertRaises(SchemaError) as caught:
            spec.GRAPH_NODE.check({"device_name": 1, "dpid": 1, "ip": [], "is_enabled": True,
                                   "is_up": True, "mac": 1, "vertex_type": 0,
                                   "brand_name": "x", "device_layer": 1}, "nodes[0]")
        self.assertIn("nodes[0].device_name", str(caught.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
