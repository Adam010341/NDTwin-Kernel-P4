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

import hashlib
import json
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# NDT_CONTRACT_DIR points the import at a COPY of tools/contract_test, so
# tests/shell/mutate_contract_per_node_identity.sh can mutate spec.py and score this file
# without writing a byte into a worktree other sessions are reading. Unset in a normal run.
# The topology models and the captured graph payload are still read from REPO_ROOT: the
# authority a mutated tool is judged against must not be mutated with it.
#
# The NAME is not free choice: tests/python/test_l3_dispatch_drift.py already reads
# NDT_CONTRACT_DIR on trunk for this same mechanism, and fix/e21-link-endpoints-in-contract
# adds a third reader of it. This branch invented a second spelling for the same thing and it
# was renamed to this one on 2026-09-07 (Adam's ruling on E-21 §7-2), so that one directory
# does not end up with two names for one mechanism -- and so that the two branches meet in a
# conflict about content rather than about spelling. The old name is deliberately not written
# down anywhere: a dead environment variable in a comment is a grep that lies.
# [Co-developed with claude code -- Adam]
CONTRACT_DIR = os.environ.get("NDT_CONTRACT_DIR") or os.path.join(
    REPO_ROOT, "tools", "contract_test")
sys.path.insert(0, CONTRACT_DIR)

import spec  # noqa: E402
from run_contract_test import Context  # noqa: E402
from schema import SchemaError, validate  # noqa: E402
from spec import (  # noqa: E402
    ACCOUNTED_FOR,
    TOOL_PRECONDITION,
    PowerState,
    classify_power_state,
)

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

    def __init__(self, switches=2, hosts=1, edges=2, dpids=(1, 2), topk=5, power_state=None,
                 switch_identity=None, host_identity=None):
        self.expected_switches = switches
        self.expected_hosts = hosts
        self.expected_edges = edges
        self.expected_dpids = set(dpids)
        self.topk = topk
        # [Co-developed with claude code -- Adam] -- W3b-3.
        # Per-node identity, absent by default so the cases above still say exactly what they
        # said: they are about the cardinality half, and a stand-in that started asserting
        # identity too would change what those reds mean. The REAL Context always supplies
        # both -- pinned by RealContextSuppliesPerNodeIdentityTest, so this default can never
        # become the production answer.
        self.expected_switch_identity = switch_identity
        self.expected_host_identity = host_identity
        self.switch_identity_unavailable = None
        self.host_identity_unavailable = None
        # [Co-developed with claude code -- Adam] -- A-8.
        # Defaults to a POSITIVE reading that nothing is powered off, not to "no reading".
        # The distinction is the whole of A-8: on a fabric where nothing is off, a down
        # switch is a real failure and every test below still asserts exactly that. Where a
        # test means "the tool does not know", it must say so by passing
        # PowerState.unknown(...) -- silence is not that claim.
        self.power_state = power_state if power_state is not None else PowerState.all_on()


def node(dpid, vertex_type=0, is_up=True, is_enabled=True, name=None):
    return {"device_name": name or f"s{dpid}", "dpid": dpid, "vertex_type": vertex_type,
            "is_up": is_up, "is_enabled": is_enabled}


def edge(src=1, dst=2, is_up=True, is_enabled=True, cap=10 ** 9, used=0.0, pct=0.0,
         telemetry=None, age=None, agent_age=None):
    """
    One edge of get_graph_data.

    [Co-developed with claude code -- Adam]
    `telemetry`/`age`/`agent_age` are omitted unless a test asks for them, because a kernel
    that predates A-4f's fix does not send them and inv_no_silent_telemetry has to behave
    correctly against both shapes. Defaulting them to a value would have hidden exactly the
    case the invariant exists to report.
    """
    e = {"src_dpid": src, "dst_dpid": dst, "src_interface": 1, "dst_interface": 1,
         "is_up": is_up, "is_enabled": is_enabled,
         "link_bandwidth_bps": cap, "link_bandwidth_usage_bps": used,
         "link_bandwidth_utilization_percent": pct}
    if telemetry is not None:
        e["telemetry_status"] = telemetry
    if age is not None:
        e["last_sample_age_seconds"] = age
    if agent_age is not None:
        e["agent_last_sample_age_seconds"] = agent_age
    return e


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


class PoweredDownIsNotAFaultTest(unittest.TestCase):
    """
    KNOWN-ISSUES A-8: three test tools turn red when the system is working correctly.

    Measured twice on a live fabric (2026-08-18 F-2, re-verified 2026-08-30 R-5): the
    Energy-Saving-App powered down s5/s7/s9, the twin reported that accurately, and this
    suite answered with 8 "switch(es) not up" lines and a BROKEN. Every one of the 20 down
    edges was incident to a powered-off switch, so the twin's accounting was right and the
    suite's complaint was wrong.

    The three things pinned here are what stop that recurring without giving up what the
    invariant was written for:

      1. a switch that is down while the power state says it is ON is STILL a failure --
         that is the P4 wiring failure (nothing calls /ndt/inform_switch_entered) and it
         must survive this change intact;
      2. a switch that is down while the power state says OFF is not a failure, and is
         still SAID OUT LOUD, because an explained deviation nobody sees is
         indistinguishable from no deviation;
      3. when the power state cannot be read, the answer is neither -- it is
         TOOL-PRECONDITION-FAILED. A tool must never be able to fail in a way that looks
         like the system failing, and both available guesses are wrong in a different
         direction: "assume all on" recreates the false alarm, "assume all off" hides (1).

    [Co-developed with claude code -- Adam]
    """

    #: The fabric shape from the live round: two switches up, one powered down by the app.
    DOWN_GRAPH = {"nodes": [node(1), node(5, is_up=False, is_enabled=False)]}

    def test_a_down_switch_is_still_a_failure_when_the_power_state_says_it_is_on(self):
        out = spec.inv_all_switches_up(self.DOWN_GRAPH, Ctx(power_state=PowerState.all_on()))
        self.assertTrue(any("switch(es) not up" in m and "s5" in m for m in out), out)

    def test_a_down_switch_the_power_state_calls_off_is_not_a_failure(self):
        out = spec.inv_all_switches_up(self.DOWN_GRAPH,
                                       Ctx(power_state=PowerState({5})))
        self.assertEqual([m for m in out if not m.startswith(ACCOUNTED_FOR)], [], out)

    def test_a_powered_off_switch_is_still_reported_rather_than_silently_dropped(self):
        out = spec.inv_all_switches_up(self.DOWN_GRAPH, Ctx(power_state=PowerState({5})))
        self.assertTrue(any(m.startswith(ACCOUNTED_FOR) and "s5" in m for m in out), out)

    def test_the_p4_wiring_hint_survives_for_a_switch_that_is_not_powered_off(self):
        # The is_enabled half of the invariant is the one whose docstring names
        # /ndt/inform_switch_entered. Powering off switch 5 must not silence it for switch 1.
        data = {"nodes": [node(1, is_enabled=False), node(5, is_up=False, is_enabled=False)]}
        out = spec.inv_all_switches_up(data, Ctx(power_state=PowerState({5})))
        self.assertTrue(any("inform_switch_entered" in m and "s1" in m for m in out), out)
        self.assertFalse(any("inform_switch_entered" in m and "s5" in m for m in out), out)

    def test_an_unreadable_power_state_says_so_instead_of_reporting_a_fault(self):
        out = spec.inv_all_switches_up(
            self.DOWN_GRAPH, Ctx(power_state=PowerState.unknown("kernel returned HTTP 503")))
        self.assertEqual(len(out), 1, out)
        self.assertTrue(out[0].startswith(TOOL_PRECONDITION), out)
        self.assertIn("HTTP 503", out[0])

    def test_the_precondition_message_does_not_reuse_the_failure_wording(self):
        # doc/audit/2026-08-30_live-full-stack-round/harness/{40_r5_p4,50_r5_ovs}.sh grep for
        # the literal "switch(es) not up" to decide whether A-8 is still present. If the
        # precondition or accounted-for line carried that string, the fix would report
        # itself as unfixed -- the instrument mimicking its own finding one level up.
        for state in (PowerState.unknown("no answer"), PowerState({5})):
            for m in spec.inv_all_switches_up(self.DOWN_GRAPH, Ctx(power_state=state)):
                self.assertNotIn("switch(es) not up", m)

    def test_a_ctx_with_no_power_state_at_all_is_unknown_not_all_on(self):
        # A caller that forgot to wire the reading must be told, not given a confident
        # answer built on a default.
        class Bare:
            expected_switches, expected_hosts, expected_edges = 2, 1, 2
            expected_dpids, topk = {1, 5}, 5

        out = spec.inv_all_switches_up(self.DOWN_GRAPH, Bare())
        self.assertEqual(len(out), 1, out)
        self.assertTrue(out[0].startswith(TOOL_PRECONDITION), out)

    def test_a_healthy_fabric_is_unaffected_by_any_of_this(self):
        for state in (PowerState.all_on(), PowerState({5}),
                      PowerState.unknown("no answer")):
            self.assertEqual(
                spec.inv_all_switches_up({"nodes": [node(1), node(2)]},
                                         Ctx(power_state=state)), [])


class PoweredDownEdgesTest(unittest.TestCase):
    """A-8, edge half: 20 down edges, all incident to a powered-off switch."""

    def test_an_edge_incident_to_a_powered_off_switch_is_not_a_failure(self):
        data = {"edges": [edge(1, 5, is_up=False), edge(5, 2, is_up=False)]}
        out = spec.inv_edges_enabled(data, Ctx(power_state=PowerState({5})))
        self.assertEqual([m for m in out if not m.startswith(ACCOUNTED_FOR)], [], out)
        self.assertTrue(any(m.startswith(ACCOUNTED_FOR) and "2 edge(s)" in m for m in out), out)

    def test_an_edge_between_two_powered_on_switches_is_still_a_failure(self):
        data = {"edges": [edge(1, 2, is_up=False), edge(1, 5, is_up=False)]}
        out = spec.inv_edges_enabled(data, Ctx(power_state=PowerState({5})))
        failures = [m for m in out if not m.startswith(ACCOUNTED_FOR)]
        self.assertEqual(len(failures), 1, out)
        self.assertIn("1 edge(s) down/disabled", failures[0])
        self.assertIn("1:1->2:1", failures[0])

    def test_the_summary_count_is_of_the_unexplained_edges_only(self):
        # Twenty down edges, fifteen of them explained: the reader must see 5, not 20, or
        # the number itself keeps telling the old story.
        data = {"edges": [edge(i, 5, is_up=False) for i in range(1, 16)]
                         + [edge(j, j + 1, is_up=False) for j in range(20, 25)]}
        out = spec.inv_edges_enabled(data, Ctx(power_state=PowerState({5})))
        failures = [m for m in out if not m.startswith(ACCOUNTED_FOR)]
        self.assertEqual(len(failures), 1, out)
        self.assertIn("5 edge(s) down/disabled", failures[0])

    def test_an_unreadable_power_state_blocks_the_edge_verdict_too(self):
        data = {"edges": [edge(1, 2, is_up=False)]}
        out = spec.inv_edges_enabled(data, Ctx(power_state=PowerState.unknown("timed out")))
        self.assertEqual(len(out), 1, out)
        self.assertTrue(out[0].startswith(TOOL_PRECONDITION), out)
        self.assertNotIn("edge(s) down/disabled", out[0])


class DeclaredDownEdgesTest(unittest.TestCase):
    """
    F-OFFLINE-1 G5: `down_reason: "declared"` is an operator's intent, not a fault.

    [Co-developed with claude code -- Adam]

    W8's whole point is that a declaration does not clear until somebody POSTs a recovery, and
    since W8b which recovery is narrowed further. A run that reports the resulting down edge as
    a broken link raises a false alarm on every fabric where a failure was declared on purpose
    -- including, at the time this was written, the contract test's OWN mutating sequence, whose
    step 1 declares a link down and whose step 3 injects one.

    Same shape as the A-8 power case above and the same three answers, which is the point: the
    difference between "down and nobody knows why" and "down because you said so" has to be
    visible in the output, not decided by whoever reads it.
    """

    @staticmethod
    def declared(src=1, dst=2):
        return {**edge(src, dst, is_up=False), "down_reason": "declared"}

    def test_a_declared_edge_is_accounted_for_not_failed(self):
        out = spec.inv_edges_enabled({"edges": [self.declared()]}, Ctx())
        self.assertEqual([m for m in out if not m.startswith(ACCOUNTED_FOR)], [], out)
        self.assertTrue(any(m.startswith(ACCOUNTED_FOR) and "declared" in m for m in out), out)

    def test_it_is_still_printed_and_still_counted(self):
        # An explained deviation nobody sees is indistinguishable from no deviation at all.
        out = spec.inv_edges_enabled(
            {"edges": [self.declared(1, 2), self.declared(3, 4)]}, Ctx())
        self.assertTrue(any(m.startswith(ACCOUNTED_FOR) and "2 edge(s)" in m for m in out), out)

    def test_a_down_edge_with_any_other_reason_is_still_a_failure(self):
        for reason in ("none", "switch-unreachable"):
            data = {"edges": [{**edge(1, 2, is_up=False), "down_reason": reason}]}
            failures = [m for m in spec.inv_edges_enabled(data, Ctx())
                        if not m.startswith(ACCOUNTED_FOR)]
            self.assertEqual(len(failures), 1, f"{reason}: {failures}")
            self.assertIn("1 edge(s) down/disabled", failures[0])

    def test_a_down_edge_that_names_no_reason_is_still_a_failure(self):
        # The pre-F-14 kernel. Absence of the key is not a declaration, and reading it as one
        # would silence every genuinely broken link on every kernel built before 2026-09-06.
        failures = [m for m in spec.inv_edges_enabled({"edges": [edge(1, 2, is_up=False)]},
                                                      Ctx())
                    if not m.startswith(ACCOUNTED_FOR)]
        self.assertEqual(len(failures), 1, failures)

    def test_the_unexplained_count_excludes_the_declared_ones(self):
        data = {"edges": [self.declared(1, 2), self.declared(3, 4),
                          edge(5, 6, is_up=False)]}
        failures = [m for m in spec.inv_edges_enabled(data, Ctx())
                    if not m.startswith(ACCOUNTED_FOR)]
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("1 edge(s) down/disabled", failures[0])
        self.assertIn("5:1->6:1", failures[0])

    def test_a_declared_edge_that_is_also_incident_to_an_off_switch_is_counted_once(self):
        # Two explanations, one edge. It must not appear in both buckets: the sum of the
        # printed counts is what a reader adds up against the number of down edges.
        data = {"edges": [self.declared(1, 5)]}
        out = spec.inv_edges_enabled(data, Ctx(power_state=PowerState({5})))
        self.assertEqual([m for m in out if not m.startswith(ACCOUNTED_FOR)], [], out)
        counted = sum(int(m.split()[1]) for m in out if m.startswith(ACCOUNTED_FOR))
        self.assertEqual(counted, 1, out)

    def test_an_unreadable_power_state_still_blocks_the_verdict(self):
        # The declaration is readable and the power state is not, so this run cannot tell a
        # declared edge from one incident to a switch it cannot see. No verdict, as before:
        # a new ACCOUNTED-FOR bucket must not become a way past the A-8 precondition.
        out = spec.inv_edges_enabled({"edges": [self.declared()]},
                                     Ctx(power_state=PowerState.unknown("timed out")))
        self.assertEqual(len(out), 1, out)
        self.assertTrue(out[0].startswith(TOOL_PRECONDITION), out)


class PowerStateReadingTest(unittest.TestCase):
    """
    classify_power_state: every way the reading can be untrustworthy must return unknown.

    A wrong-but-confident power reading is worse than none, because it feeds straight into
    the three-way decision above and turns it back into a two-way one.

    [Co-developed with claude code -- Adam]
    """

    IP_TO_DPID = {"192.168.123.11": 1, "192.168.123.15": 5}

    def test_a_complete_reading_maps_off_switches_onto_dpids(self):
        state = classify_power_state(
            {"192.168.123.11": "ON", "192.168.123.15": "OFF"}, self.IP_TO_DPID)
        self.assertTrue(state.known)
        self.assertEqual(set(state.off_dpids), {5})

    def test_all_on_is_a_positive_reading_not_an_absence(self):
        state = classify_power_state(
            {"192.168.123.11": "ON", "192.168.123.15": "ON"}, self.IP_TO_DPID)
        self.assertTrue(state.known)
        self.assertEqual(set(state.off_dpids), set())

    def test_a_switch_missing_from_the_reading_makes_the_whole_reading_unknown(self):
        # Before 04b8933 the kernel omitted a down switch's key from the sibling utilisation
        # maps entirely (live-findings-2026-08-18-ovs.md F-3). Partial coverage here would
        # read a powered-off switch as powered on, which is the A-8 false alarm again.
        state = classify_power_state({"192.168.123.11": "ON"}, self.IP_TO_DPID)
        self.assertFalse(state.known)
        self.assertIn("192.168.123.15", state.error)

    def test_an_unrecognised_power_value_is_unknown_not_assumed_on(self):
        state = classify_power_state(
            {"192.168.123.11": "ON", "192.168.123.15": "MAYBE"}, self.IP_TO_DPID)
        self.assertFalse(state.known)
        self.assertIn("MAYBE", state.error)

    def test_an_ip_that_is_not_in_this_topology_is_unknown(self):
        state = classify_power_state(
            {"192.168.123.11": "ON", "192.168.123.15": "ON", "10.9.9.9": "OFF"},
            self.IP_TO_DPID)
        self.assertFalse(state.known)
        self.assertIn("10.9.9.9", state.error)

    def test_a_non_object_body_is_unknown(self):
        self.assertFalse(classify_power_state([], self.IP_TO_DPID).known)
        self.assertFalse(classify_power_state(None, self.IP_TO_DPID).known)

    def test_the_state_values_are_read_case_insensitively(self):
        state = classify_power_state(
            {"192.168.123.11": "on", "192.168.123.15": " off "}, self.IP_TO_DPID)
        self.assertTrue(state.known, state.error)
        self.assertEqual(set(state.off_dpids), {5})


class ContextCarriesTheJoinTest(unittest.TestCase):
    """The IP-to-dpid join comes from the topology file, so it needs no kernel to build."""

    def test_every_switch_ip_in_the_shipped_topology_maps_to_its_dpid(self):
        ctx = real_ctx()
        self.assertEqual(len(ctx.switch_ip_to_dpid), ctx.expected_switches)
        self.assertEqual(set(ctx.switch_ip_to_dpid.values()), ctx.expected_dpids)

    def test_a_fresh_context_has_not_read_the_power_state_yet(self):
        # Not "all on": constructing a Context is not evidence about the fabric.
        self.assertFalse(real_ctx().power_state.known)


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


# --- telemetry silence (A-4f) --------------------------------------------------------


class SilentTelemetryTest(unittest.TestCase):
    """
    KNOWN-ISSUES A-4f: an OVS power cycle deletes the bridge and with it the sFlow record, so
    the links entering that switch read *exactly* 0 bps for ever while carrying real traffic.
    Nothing in get_graph_data could tell that 0 apart from an idle link's 0.

    [Co-developed with claude code -- Adam]
    Two rules, and the second is the one this whole file exists for.

      1. An edge the kernel marks `silent` is named.
      2. A response whose edges carry no telemetry_status at all does NOT pass. It reports
         that the check could not run. A kernel without the field cannot answer the question,
         and an invariant that says nothing in that case occupies the slot where a real check
         would go -- the failure mode named at the top of this file.

    `idle` is deliberately not a failure: the sampling agent is alive and reporting on its
    other ports, so 0 on this one *is* a measurement. `unknown` is deliberately not a failure
    either, because it is the honest state of a freshly started kernel; that one is pinned
    below as "documents current behaviour" so the next reader can see it was a decision.
    """

    def test_a_silent_edge_is_named(self):
        data = {"edges": [edge(src=3, dst=8, telemetry="silent", age=-1.0, agent_age=-1.0)]}
        out = spec.inv_no_silent_telemetry(data, Ctx())
        self.assertTrue(out, "a silent link produced no finding")
        self.assertIn("3:1->8:1", out[0])

    def test_the_finding_says_the_reading_is_an_absence_not_a_measurement(self):
        # The whole point of the field: a reader who sees 0 bps must be told which 0 it is.
        data = {"edges": [edge(telemetry="silent", age=-1.0, agent_age=-1.0)]}
        out = spec.inv_no_silent_telemetry(data, Ctx())
        self.assertTrue(any("silent" in m for m in out), out)

    def test_an_idle_edge_is_not_a_failure(self):
        # The agent is sampling on its other ports, so 0 here is a real measurement.
        data = {"edges": [edge(telemetry="idle", age=-1.0, agent_age=0.4)]}
        self.assertEqual(spec.inv_no_silent_telemetry(data, Ctx()), [])

    def test_a_live_edge_is_not_a_failure(self):
        data = {"edges": [edge(telemetry="live", age=0.3, agent_age=0.3)]}
        self.assertEqual(spec.inv_no_silent_telemetry(data, Ctx()), [])

    def test_an_unknown_edge_is_not_a_failure_documents_current_behaviour(self):
        # A kernel that started ten seconds ago has seen no sample from anyone yet. Failing
        # here would make the contract test red on every fresh stack, which is how a check
        # gets disabled.
        data = {"edges": [edge(telemetry="unknown", age=-1.0, agent_age=-1.0)]}
        self.assertEqual(spec.inv_no_silent_telemetry(data, Ctx()), [])

    def test_a_kernel_without_the_field_is_reported_rather_than_passed(self):
        # The defect this invariant exists for is invisible without the field. Passing here
        # would mean the check reports green precisely when it cannot see anything.
        data = {"edges": [edge(), edge(src=2, dst=1)]}
        out = spec.inv_no_silent_telemetry(data, Ctx())
        self.assertTrue(out, "an unanswerable check reported success")
        self.assertIn("telemetry_status", out[0])

    def test_one_edge_carrying_the_field_is_enough_for_the_check_to_run(self):
        # Mixed shapes mean the kernel does have the field; the bare edges are then just
        # edges, not evidence of an old kernel.
        data = {"edges": [edge(), edge(src=2, dst=1, telemetry="live", age=0.2, agent_age=0.2)]}
        self.assertEqual(spec.inv_no_silent_telemetry(data, Ctx()), [])

    def test_an_empty_edge_list_is_reported_not_passed(self):
        # "Examined nothing" is the failure mode this file was written for.
        #
        # [Co-developed with claude code -- Adam] The first version of this test asserted only
        # that *something* was returned, and the mutation gate killed it: deleting the
        # empty-edge branch entirely left the test green, because an empty list also has no
        # edge carrying telemetry_status and fell through to the other branch. Two different
        # situations were reporting the same way. An empty graph is not an old kernel, and
        # telling an operator to go looking for a missing field when the real problem is that
        # the topology never loaded sends them to the wrong place -- so the message is asserted,
        # not just its existence.
        out = spec.inv_no_silent_telemetry({"edges": []}, Ctx())
        self.assertTrue(out, "examined zero edges and reported success")
        self.assertIn("no edges", out[0])
        self.assertNotIn("telemetry_status", out[0])

    def test_at_most_ten_silent_edges_are_listed(self):
        data = {"edges": [edge(src=i, telemetry="silent", age=-1.0, agent_age=-1.0)
                          for i in range(20)]}
        self.assertLessEqual(len(spec.inv_no_silent_telemetry(data, Ctx())), 10)

    def test_the_invariant_is_registered_on_get_graph_data(self):
        # An invariant nobody runs is not an invariant. get_graph_data is the endpoint that
        # serves the zero.
        ep = next(e for e in spec.ENDPOINTS if e["name"] == "get_graph_data")
        self.assertIn(spec.inv_no_silent_telemetry, ep["invariants"])

    @staticmethod
    def _wire_edge(**kw):
        """An edge with every field GRAPH_EDGE requires, for the schema assertions.

        edge() above is shaped for the invariants and omits src_ip/dst_ip/flow_set, which the
        invariants never read but the schema does.
        """
        e = edge(**kw)
        e.update({"src_ip": [16777226], "dst_ip": [33554442], "flow_set": []})
        return e

    def test_the_edge_schema_accepts_the_three_new_fields(self):
        self.assertEqual(
            validate(spec.GRAPH_EDGE,
                     self._wire_edge(telemetry="silent", age=-1.0, agent_age=-1.0)),
            [])

    def test_the_edge_schema_still_accepts_an_edge_without_them(self):
        # /ndt/ is a cross-repo contract: a kernel that predates the fix must not fail
        # structurally.
        self.assertEqual(validate(spec.GRAPH_EDGE, self._wire_edge()), [])

    def test_the_edge_schema_rejects_a_telemetry_status_it_does_not_define(self):
        # A typo'd or invented status must not slip through as a string.
        self.assertTrue(validate(spec.GRAPH_EDGE, self._wire_edge(telemetry="probably fine")))


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
                  "install_flow_entries_modify_flow_entries_and_delete_flow_entries",
                  # [Co-developed with claude code -- Adam] -- E-21. The heaviest writes in the
                  # table: two of them declare a link down until somebody withdraws it, and two
                  # of them attach netem to a real interface. A read-only run must never reach
                  # them, so a category slip here is the one that costs a fabric.
                  "link_failure_detected", "link_recovery_detected",
                  "inject_link_failure", "inject_link_recovery")
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
        # A real rename here would persist, so the body re-sets the name it found.
        #
        # 🔴 The REASON changed on 2026-09-06 and the assertion did not. This comment used to
        # read "modify_device_name writes to the topology JSON on disk, so a real rename here
        # would edit a shipped file (and possibly the wrong one)". W10 stopped the kernel
        # writing setting/*.json: the name now goes to .test_run/nickname_overlay/, which is
        # gitignored. The tree no longer goes dirty -- and the rename still survives a restart,
        # so a contract run must still not leave a device called something else. What changed
        # is that the leftover is now INVISIBLE to `git status` rather than a 1300-line diff.
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


def split_node(dpid, admin_state="on", reachable=True, is_enabled=True, name=None):
    """
    One node of get_graph_data AFTER Q12: `admin_state` and `reachable` are separate, and
    `is_up` is the deprecated alias that still tracks `reachable`.

    [Co-developed with claude code -- Adam]
    The alias is emitted here rather than omitted because that is what the kernel emits; a
    fixture that dropped it would let a spec change that reads the alias by mistake stay green.
    """
    return {"device_name": name or f"s{dpid}", "dpid": dpid, "vertex_type": 0,
            "admin_state": admin_state, "reachable": reachable, "is_up": reachable,
            "is_enabled": is_enabled}


class SplitFieldsMakeTheThreeStateCheckAbleToFireTest(unittest.TestCase):
    """
    Q12 / A-8: the three-state check compared a bit against itself.

    [Co-developed with claude code -- Adam]

    inv_all_switches_up asks "is this switch down" and then "is it down because we powered it
    off". Before the split BOTH sides read `is_up`: the kernel derived
    /ndt/get_switches_power_state's ON/OFF answer from the same graph flag the invariant was
    testing, so every down switch was in `power.off_dpids` and `unexplained_down` was
    STRUCTURALLY EMPTY on any real kernel. The unit tests above hide that, because they hand
    the invariant a PowerState no live kernel could have produced.

    With `admin_state` and `reachable` separate, "down but nobody asked for it" is a state the
    data can express -- so the check can fire, and these cases are the ones that prove it can.
    """

    def test_a_switch_that_is_unreachable_while_commanded_on_is_reported(self):
        # 🔴 The case that could not happen before. A crashed switch: nothing commanded it off,
        # and it is not answering. This is the P4 wiring failure the invariant exists for.
        data = {"nodes": [split_node(1), split_node(5, admin_state="on", reachable=False)]}
        out = spec.inv_all_switches_up(data, Ctx())
        self.assertTrue(any("switch(es) not up" in m and "s5" in m for m in out), out)

    def test_a_switch_that_is_unreachable_while_commanded_off_is_accounted_for(self):
        data = {"nodes": [split_node(1), split_node(5, admin_state="off", reachable=False)]}
        out = spec.inv_all_switches_up(data, Ctx())
        self.assertEqual([m for m in out if not m.startswith(ACCOUNTED_FOR)], [], out)
        self.assertTrue(any(m.startswith(ACCOUNTED_FOR) and "s5" in m for m in out), out)

    def test_the_two_dead_switches_are_reported_differently(self):
        # The whole point of the ruling, in one call: same reachability, different verdicts.
        data = {"nodes": [split_node(1),
                          split_node(5, admin_state="off", reachable=False),
                          split_node(7, admin_state="on", reachable=False)]}
        out = spec.inv_all_switches_up(data, Ctx())
        failures = [m for m in out if not m.startswith(ACCOUNTED_FOR)]
        self.assertTrue(any("s7" in m for m in failures), out)
        self.assertFalse(any("s5" in m for m in failures), out)

    def test_the_node_fields_are_used_even_when_no_power_reading_was_taken(self):
        # The reading was the only source before, and it is an extra HTTP call that can fail.
        # Now the graph answers for itself, so a missing power reading is no longer a reason to
        # decline a verdict -- TOOL-PRECONDITION-FAILED here would be the tool declining to use
        # evidence it was handed.
        data = {"nodes": [split_node(5, admin_state="on", reachable=False)]}
        out = spec.inv_all_switches_up(
            data, Ctx(power_state=PowerState.unknown("kernel returned HTTP 503")))
        self.assertFalse(any(m.startswith(TOOL_PRECONDITION) for m in out), out)
        self.assertTrue(any("switch(es) not up" in m and "s5" in m for m in out), out)

    def test_a_healthy_split_fabric_reports_nothing(self):
        data = {"nodes": [split_node(1), split_node(2)]}
        self.assertEqual(spec.inv_all_switches_up(data, Ctx()), [])

    def test_a_kernel_that_predates_the_split_still_uses_the_power_reading(self):
        # Old shape, no admin_state anywhere. The contract tool runs against whatever kernel is
        # deployed, so the previous path must survive intact.
        data = {"nodes": [node(1), node(5, is_up=False, is_enabled=False)]}
        out = spec.inv_all_switches_up(data, Ctx(power_state=PowerState({5})))
        self.assertEqual([m for m in out if not m.startswith(ACCOUNTED_FOR)], [], out)

    def test_a_mixed_graph_falls_back_rather_than_guessing(self):
        # Some switches carrying admin_state and some not is a reading nobody should act on:
        # the missing ones would silently count as "commanded on" and turn into failures. Same
        # discipline as classify_power_state's partial-coverage rule.
        data = {"nodes": [split_node(1), node(5, is_up=False, is_enabled=False)]}
        out = spec.inv_all_switches_up(
            data, Ctx(power_state=PowerState.unknown("kernel returned HTTP 503")))
        self.assertTrue(any(m.startswith(TOOL_PRECONDITION) for m in out), out)

    def test_reachable_beats_the_deprecated_alias_when_they_disagree(self):
        # A consumer reading the alias where the field exists is reading a copy. Pinned with the
        # two disagreeing, which is the only arrangement that can tell which one was used.
        n = split_node(5, admin_state="on", reachable=False)
        n["is_up"] = True
        out = spec.inv_all_switches_up({"nodes": [n]}, Ctx())
        self.assertTrue(any("switch(es) not up" in m and "s5" in m for m in out), out)


class PowerStateReadingCarriesBothFieldsTest(unittest.TestCase):
    """
    /ndt/get_switches_power_state now answers with an object per switch, so classify_power_state
    has two shapes to read: the old scalar (a kernel that predates Q12) and the new object.

    [Co-developed with claude code -- Adam]
    Both, not one. This tool is pointed at whatever kernel is deployed, and refusing the old
    shape would turn every pre-Q12 run into TOOL-PRECONDITION-FAILED.
    """

    IP_TO_DPID = {"192.168.123.11": 1, "192.168.123.15": 5}

    def test_the_new_object_shape_maps_commanded_off_switches_onto_dpids(self):
        state = classify_power_state(
            {"192.168.123.11": {"admin_state": "on", "reachable": True},
             "192.168.123.15": {"admin_state": "off", "reachable": False}}, self.IP_TO_DPID)
        self.assertTrue(state.known, state.error)
        self.assertEqual(set(state.off_dpids), {5})

    def test_off_dpids_follows_the_command_not_the_observation(self):
        # 🔴 The conflation, in the endpoint that caused it. A switch that crashed is NOT a
        # switch the operator powered down, and off_dpids is what tells the invariants which
        # deviations are accounted for.
        state = classify_power_state(
            {"192.168.123.11": {"admin_state": "on", "reachable": True},
             "192.168.123.15": {"admin_state": "on", "reachable": False}}, self.IP_TO_DPID)
        self.assertTrue(state.known, state.error)
        self.assertEqual(set(state.off_dpids), set(),
                         "a crashed switch was reported as deliberately powered down")
        self.assertEqual(set(state.unreachable_dpids), {5})

    def test_the_old_scalar_shape_still_reads(self):
        state = classify_power_state(
            {"192.168.123.11": "ON", "192.168.123.15": "OFF"}, self.IP_TO_DPID)
        self.assertTrue(state.known, state.error)
        self.assertEqual(set(state.off_dpids), {5})

    def test_an_object_missing_admin_state_is_unknown_not_assumed_on(self):
        state = classify_power_state(
            {"192.168.123.11": {"reachable": True},
             "192.168.123.15": {"admin_state": "off", "reachable": False}}, self.IP_TO_DPID)
        self.assertFalse(state.known)
        self.assertIn("192.168.123.11", state.error)

    def test_an_unrecognised_admin_state_is_unknown(self):
        state = classify_power_state(
            {"192.168.123.11": {"admin_state": "standby", "reachable": True},
             "192.168.123.15": {"admin_state": "off", "reachable": False}}, self.IP_TO_DPID)
        self.assertFalse(state.known)
        self.assertIn("standby", state.error)

    def test_the_node_schema_accepts_both_shapes(self):
        base = {"device_name": "s1", "dpid": 1, "ip": [], "is_enabled": True, "is_up": True,
                "mac": 1, "vertex_type": 0, "brand_name": "x", "device_layer": 1}
        # validate() returns a LIST OF FAILURES; empty means it conforms.
        self.assertEqual(validate(spec.GRAPH_NODE, base), [],
                         "the pre-Q12 shape stopped validating")
        self.assertEqual(validate(spec.GRAPH_NODE,
                                  {**base, "admin_state": "off", "reachable": False}), [])

    def test_the_schema_pins_the_admin_state_vocabulary(self):
        base = {"device_name": "s1", "dpid": 1, "ip": [], "is_enabled": True, "is_up": True,
                "mac": 1, "vertex_type": 0, "brand_name": "x", "device_layer": 1}
        self.assertTrue(validate(spec.GRAPH_NODE, {**base, "admin_state": "OFF"}),
                        "a third spelling of the same state is a contract change")


# --- E-21: the four link endpoints -------------------------------------------------
# [Co-developed with claude code -- Adam]


#: The declined reply, verbatim from doc/2026-01-02_ndt_api.md §2 and measured on arm lw8b3
#: (2026-09-07 20:26:47, s1:1 -> s5:1). Repeated here rather than imported from
#: selftest_fixtures so that a fixture edited to match a broken kernel does not also move the
#: assertions -- the two files check the same shape from opposite sides on purpose.
DECLINED_RECOVERY = {
    "status": "link recovery processed",
    "declaration_retained": True,
    "detail": "a link failure is declared for this link and nothing ever reported it broken, so "
              "this recovery report did not withdraw it and the link is still down. That is what "
              "an injected failure surviving a control-plane restart looks like. Withdraw it with "
              "POST /ndt/inject_link_recovery",
    "until": "/ndt/inject_link_recovery",
}

#: The 200 an APPLIED recovery gives, and the one an unconditional withdrawal gave for the whole
#: of lw8b. The two are the same bytes, which is why the body of the declined case is load-bearing.
APPLIED_RECOVERY = {"status": "link recovery processed"}

LINK_ENDPOINT_PATHS = ("/ndt/link_failure_detected", "/ndt/link_recovery_detected",
                       "/ndt/inject_link_failure", "/ndt/inject_link_recovery")

#: The mutating sequence, in the order it must run. Named here so a reordering is a test failure
#: rather than a silently weaker suite -- see the class docstring.
LINK_SEQUENCE = ["link_failure_detected", "link_recovery_detected", "inject_link_failure",
                 "link_recovery_detected__declined_after_injection", "inject_link_recovery",
                 "inject_link_recovery_cleanup"]


class LinkEndpointContractTest(unittest.TestCase):
    """
    Adam's ruling E-21: the four link endpoints join the contract.

    They had none. `declaration_retained` -- the one field on the wire that says "this kernel
    deliberately left your link down" -- was documented in §2, emitted by HttpSession.cpp and
    named by no schema anywhere, so it could have been dropped without a single check going red.

    Two properties are checked here that nothing else can check:

      * the DECLINED reply must be distinguishable from the applied one. On the wire they share
        a status line (200, deliberately: Ryu's on_link_add logs "NDT REJECTED this notification"
        on any 4xx) and, before W8b, they shared a body as well. The body is the whole signal;
        if the check that reads it can pass without it, the contract has re-acquired the defect.
      * the sequence order. Step 4 is only meaningful because step 3 injected a declaration that
        no report pairs with -- sort these six by name and step 4 asks a link nobody declared
        down to decline, which it will not, and the check reports a kernel fault that is really
        a suite fault. Same failure the lock sequence has.
    """

    def named(self, name):
        found = [e for e in spec.ENDPOINTS if e["name"] == name]
        self.assertEqual(len(found), 1, f"{name} appears {len(found)} times")
        return found[0]

    def entries_for(self, path):
        return [e for e in spec.ENDPOINTS if e["path"] == path]

    # --- the family is present at all --------------------------------------------------------

    def test_all_four_link_endpoints_are_in_the_contract(self):
        # The ruling, stated as a test: before E-21 every one of these had zero entries and the
        # suite was green.
        for path in LINK_ENDPOINT_PATHS:
            self.assertTrue(self.entries_for(path), f"{path} has no contract entry at all")

    def test_every_link_endpoint_is_reached_by_post(self):
        # components.KERNEL_ENDPOINTS records all four as POST, and the kernel matches on method
        # and target together: a GET falls through to 404 and looks like a missing endpoint.
        for path in LINK_ENDPOINT_PATHS:
            for entry in self.entries_for(path):
                self.assertEqual(entry["method"], "POST", entry["name"])

    # --- the declined reply, which is what E-21 is about --------------------------------------

    def test_the_declined_recovery_must_report_declaration_retained(self):
        # THE CHECK THIS TICKET EXISTS FOR. A reply without the field is the lw8b behaviour --
        # the injection withdrawn by a report nothing paired with -- and it must not pass.
        self.assertEqual(
            spec.inv_recovery_was_declined_and_said_so(DECLINED_RECOVERY, None), [])
        self.assertTrue(
            spec.inv_recovery_was_declined_and_said_so(APPLIED_RECOVERY, None),
            "a recovery that withdrew an injected declaration passed the declined check, so "
            "the field E-21 put in the contract is not actually being read")

    def test_a_declined_reply_that_says_only_true_is_not_enough(self):
        # `declaration_retained: true` with nothing else leaves the caller holding a link that is
        # down for a reason they cannot act on. The reply has to name the way out.
        bare = {"status": "link recovery processed", "declaration_retained": True}
        self.assertTrue(spec.inv_recovery_was_declined_and_said_so(bare, None))

    def test_the_declined_reply_must_point_at_the_endpoint_that_can_withdraw_it(self):
        wrong = {**DECLINED_RECOVERY, "until": "/ndt/link_recovery_detected"}
        problems = spec.inv_recovery_was_declined_and_said_so(wrong, None)
        self.assertTrue(problems)
        self.assertIn("inject_link_recovery", problems[0])

    def test_a_truthy_string_is_not_declaration_retained(self):
        # Bool(), not Any_(): "true" and "yes" are how a field degrades into decoration.
        self.assertEqual(validate(spec.LINK_RECOVERY_REPORTED, DECLINED_RECOVERY), [])
        self.assertTrue(validate(spec.LINK_RECOVERY_REPORTED,
                                 {**DECLINED_RECOVERY, "declaration_retained": "true"}))

    def test_the_paired_withdrawal_must_not_decline(self):
        # The other direction of the pairing rule, and the one the W8b gate's over-fitting
        # mutations (M11-M13) attack: a rule that declines everything is just as green.
        self.assertEqual(spec.inv_recovery_withdrew_the_declaration(APPLIED_RECOVERY, None), [])
        self.assertTrue(spec.inv_recovery_withdrew_the_declaration(DECLINED_RECOVERY, None))

    def test_the_two_recovery_checks_are_opposites_on_the_same_two_bodies(self):
        # Stated once, so nobody "fixes" one of them into agreeing with the other. Between them
        # they say: a report buys exactly one withdrawal, and an injection buys none.
        for body in (APPLIED_RECOVERY, DECLINED_RECOVERY):
            applied = not spec.inv_recovery_withdrew_the_declaration(body, None)
            declined = not spec.inv_recovery_was_declined_and_said_so(body, None)
            self.assertNotEqual(applied, declined, body)

    # --- the sticky declaration -----------------------------------------------------------

    def test_a_bare_status_from_trunk_is_reported_rather_than_passed(self):
        # 2026-01-02_ndt_api.md §1 states the trunk answer in as many words. It passes the
        # STRUCTURAL check -- the keys are optional, as every added field in spec.py is -- and is
        # reported by the invariant, because a declaration the next poll undoes within 30 s is
        # indistinguishable from a sticky one if the reply does not say.
        trunk = {"status": "link failure processed"}
        self.assertEqual(validate(spec.LINK_FAILURE_REPORTED, trunk), [])
        self.assertTrue(spec.inv_declared_failure_says_who_can_withdraw_it(trunk, None))

    def test_the_branch_answer_passes_both_halves(self):
        branch = {"status": "link failure processed", "down_reason": "declared",
                  "until": "/ndt/link_recovery_detected"}
        self.assertEqual(validate(spec.LINK_FAILURE_REPORTED, branch), [])
        self.assertEqual(spec.inv_declared_failure_says_who_can_withdraw_it(branch, None), [])

    def test_a_down_reason_this_family_does_not_have_is_rejected(self):
        # The vocabulary is pinned for the same reason DOWN_REASONS is: an invented value that
        # validates is a contract change nobody had to make.
        self.assertTrue(validate(spec.LINK_FAILURE_REPORTED,
                                 {"status": "ok", "down_reason": "maintenance"}))

    def test_the_injection_reply_must_name_the_only_endpoint_that_ends_it(self):
        # W8b on the wire: a link_recovery_detected cannot end an injection, so a reply pointing
        # a caller there would send them to the endpoint that is about to refuse them.
        self.assertTrue(validate(
            spec.LINK_FAILURE_INJECTED,
            {"status": "link failure injected", "down_reason": "declared",
             "until": "/ndt/link_recovery_detected", "tc": "skipped (not MININET)"}))

    def test_the_injection_reply_must_carry_a_tc_report(self):
        # Required here and optional on §1, deliberately: §2b does not exist on trunk (that path
        # answers 404), so there is no older kernel whose reply would be wrongly failed -- and
        # `tc` is the only thing separating "the graph changed" from "the packets stopped".
        without = {"status": "link failure injected", "down_reason": "declared",
                   "until": "/ndt/inject_link_recovery"}
        self.assertTrue(validate(spec.LINK_FAILURE_INJECTED, without))

    # --- the tc half ----------------------------------------------------------------------

    def test_the_tc_report_accepts_both_documented_shapes_and_no_third(self):
        cut = {"status": "link failure injected", "down_reason": "declared",
               "until": "/ndt/inject_link_recovery",
               "tc": [{"interface": "s1-eth1", "ok": True, "command": "qdisc add ..."},
                      {"interface": "s5-eth1", "ok": True, "command": "qdisc add ..."}]}
        self.assertEqual(validate(spec.LINK_FAILURE_INJECTED, cut), [])
        self.assertEqual(validate(spec.LINK_FAILURE_INJECTED,
                                  {**cut, "tc": "skipped (not MININET)"}), [])
        self.assertTrue(validate(spec.LINK_FAILURE_INJECTED, {**cut, "tc": "skipped"}),
                        "a free-form excuse in tc lets 'skipped' mean anything")

    def test_one_end_cut_is_a_different_fault_not_a_weaker_one(self):
        # faults.txt L-2: unidirectional loss kills LLDP one way only and leaves the control
        # plane's graph permanently asymmetric.
        both = [{"interface": "s1-eth1", "ok": True, "command": "qdisc add ..."},
                {"interface": "s5-eth1", "ok": True, "command": "qdisc add ..."}]
        self.assertEqual(spec.inv_tc_half_is_reported_per_interface({"tc": both}, None), [])
        self.assertTrue(spec.inv_tc_half_is_reported_per_interface({"tc": both[:1]}, None))

    def test_a_tc_entry_that_did_nothing_must_say_why(self):
        silent = [{"interface": "s1-eth1", "ok": False},
                  {"interface": "s5-eth1", "ok": True, "command": "qdisc add ..."}]
        self.assertTrue(spec.inv_tc_half_is_reported_per_interface({"tc": silent}, None))

    def test_a_refused_entry_is_accounted_for_rather_than_failed(self):
        # "The physical lab gets C only" (Adam, 2026-09-05), and a machine without the NOPASSWD
        # tc grants is a lab set up differently, not a kernel that is broken. Printed either way.
        refused = [{"interface": None, "ok": False,
                    "refused": "the topology file gives this switch no bridge_name"},
                   {"interface": "s5-eth1", "ok": True, "command": "qdisc add ..."}]
        messages = spec.inv_tc_half_is_reported_per_interface({"tc": refused}, None)
        failures, _pre, accounted = spec.partition_messages(messages)
        self.assertEqual(failures, [])
        self.assertTrue(accounted, "the refusal was swallowed instead of being printed")

    def test_the_skipped_half_is_reported_rather_than_silently_passing(self):
        messages = spec.inv_tc_half_is_reported_per_interface(
            {"tc": "skipped (not MININET)"}, None)
        failures, _pre, accounted = spec.partition_messages(messages)
        self.assertEqual(failures, [])
        self.assertTrue(accounted)

    def test_an_ok_entry_that_names_no_command_is_reported(self):
        # A 200 that names no tc is not evidence anything happened on the wire.
        claimed = [{"interface": "s1-eth1", "ok": True},
                   {"interface": "s5-eth1", "ok": True, "command": "qdisc add ..."}]
        self.assertTrue(spec.inv_tc_half_is_reported_per_interface({"tc": claimed}, None))

    def test_the_idempotent_restore_is_a_success_not_a_missing_command(self):
        # §2c: removing a netem that is not there reports "noop" with ok true, because a caller
        # must be able to bring a fabric back to health without knowing what was done to it.
        noop = [{"interface": "s1-eth1", "ok": True, "noop": "no netem qdisc is attached"},
                {"interface": "s5-eth1", "ok": True, "noop": "no netem qdisc is attached"}]
        self.assertEqual(spec.inv_tc_half_is_reported_per_interface({"tc": noop}, None), [])

    # --- the payloads, which are the half that can do damage ----------------------------------

    def test_every_link_body_is_a_valid_link_request(self):
        # The runner validates responses, not requests, so nothing else would catch a body with
        # three of the four keys -- it would earn an honest 400 and be recorded as the kernel
        # refusing a valid request. modify_nickname spent months in exactly that state.
        ctx = real_ctx()
        for entry in spec.ENDPOINTS:
            schema = entry.get("request_schema")
            if schema is None:
                continue
            body = entry["body"](ctx) if callable(entry["body"]) else entry["body"]
            self.assertEqual(validate(schema, body), [], entry["name"])

    def test_the_mutating_sequence_names_one_switch_to_switch_link_of_this_topology(self):
        # Both ends must be switches: dpid 0 is a host end, all four endpoints refuse it, and a
        # host edge is raised again by the host poll anyway.
        ctx = real_ctx()
        body = spec.link_endpoint_body(ctx)
        self.assertTrue(body["src_dpid"] and body["dst_dpid"],
                        "the sequence addresses a host edge by dpid 0")
        with open(P4_TOPOLOGY) as fh:
            edges = json.load(fh)["edges"]
        self.assertIn(
            (body["src_dpid"], body["src_interface"], body["dst_dpid"], body["dst_interface"]),
            {(e["src_dpid"], e["src_interface"], e["dst_dpid"], e["dst_interface"])
             for e in edges},
            "the sequence names a link this topology does not hold, so every step would 404")

    def test_all_six_steps_act_on_the_same_link(self):
        # Injecting on one link and withdrawing on another leaves the first one cut, with netem
        # attached, and the run still green.
        ctx = real_ctx()
        bodies = [self.named(n)["body"](ctx) for n in LINK_SEQUENCE]
        self.assertEqual(len({tuple(sorted(b.items())) for b in bodies}), 1, bodies)

    def test_the_chosen_link_is_deterministic(self):
        # Two runs must act on the same link, or a report naming s1:1 -> s5:1 does not mean the
        # same thing twice. min(), for the reason Context.a_dpid uses it.
        self.assertEqual(spec.switch_to_switch_link(P4_TOPOLOGY),
                         {"src_dpid": 1, "src_interface": 1, "dst_dpid": 5, "dst_interface": 1})

    def test_a_topology_with_no_switch_to_switch_link_is_refused_not_guessed(self):
        # Inventing a link would inject a fault on whatever edge happened to match. The fallback
        # is a payload all four endpoints refuse, so the run fails loudly and changes nothing.
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"nodes": [], "edges": [{"src_dpid": 1, "src_interface": 1,
                                               "dst_dpid": 0, "dst_interface": 0}]}, fh)
            path = fh.name
        try:
            self.assertIsNone(spec.switch_to_switch_link(path))

            class Bare:
                topology_path = path

            body = spec.link_endpoint_body(Bare())
            self.assertEqual(body, spec.NO_LINK_CHOSEN_PAYLOAD)
        finally:
            os.unlink(path)

    def test_an_unreadable_topology_does_not_raise_inside_the_runner(self):
        # A body callable that throws surfaces as the ENDPOINT being broken rather than the spec.
        self.assertIsNone(spec.switch_to_switch_link("/no/such/topology.json"))
        self.assertIsNone(spec.switch_to_switch_link(None))

    # --- the error paths --------------------------------------------------------------------

    def test_all_four_endpoints_have_a_dpid_zero_door(self):
        # W8-7 put four doors in, and the ruling (E-18) kept all four. One missing door is a link
        # nobody could have injected but that inject_link_recovery would still run tc against.
        doors = {e["path"] for e in spec.ENDPOINTS
                 if e["category"] == spec.ERRORPATH
                 and e.get("body") == spec.HOST_EDGE_PAYLOAD}
        self.assertEqual(doors, set(LINK_ENDPOINT_PATHS))

    def test_the_dpid_zero_doors_accept_only_400(self):
        # 404 would be the answer if the door were removed and the lookup ran: the invented host
        # edge exists, so accepting it as well would make the check agree with either kernel.
        for entry in spec.ENDPOINTS:
            if entry.get("body") == spec.HOST_EDGE_PAYLOAD:
                self.assertEqual(entry["expect_status"], [400], entry["name"])

    def test_the_dpid_zero_payload_really_names_a_host_end(self):
        self.assertEqual(spec.HOST_EDGE_PAYLOAD["dst_dpid"], 0)
        self.assertTrue(spec.HOST_EDGE_PAYLOAD["src_dpid"],
                        "with both ends zero this would be refused for the wrong reason")

    def test_the_unknown_edge_payload_gets_past_the_door_it_is_not_testing(self):
        # Both dpids non-zero, or the 404 branch is never reached and the check proves the door
        # twice instead of the lookup once.
        self.assertTrue(spec.NO_SUCH_LINK_PAYLOAD["src_dpid"])
        self.assertTrue(spec.NO_SUCH_LINK_PAYLOAD["dst_dpid"])
        for key in ("src_dpid", "dst_dpid"):
            self.assertGreater(spec.NO_SUCH_LINK_PAYLOAD[key], 10 ** 9, key)

    def test_the_unknown_edge_checks_require_404_alone(self):
        names = ("link_failure_detected__unknown_edge", "link_recovery_detected__unknown_edge",
                 "inject_link_failure__unknown_edge", "inject_link_recovery__unknown_edge")
        for name in names:
            self.assertEqual(self.named(name)["expect_status"], [404], name)

    # --- the sequence -----------------------------------------------------------------------

    def test_the_six_steps_run_in_the_order_the_pairing_rule_needs(self):
        # Step 4 is only meaningful after step 3, and step 3's cut is only undone by steps 5-6.
        names = [e["name"] for e in spec.endpoints_by_category([spec.MUTATE])]
        positions = [names.index(n) for n in LINK_SEQUENCE]
        self.assertEqual(positions, sorted(positions), names)

    def test_the_sequence_ends_with_a_withdrawal_that_needs_no_agreement(self):
        # /ndt/link_recovery_detected cannot end an injection -- that is the whole of W8b -- so a
        # sequence ending on it leaves the link declared down and, on MININET, still cut.
        self.assertEqual(self.named(LINK_SEQUENCE[-1])["path"], "/ndt/inject_link_recovery")
        self.assertEqual(self.named(LINK_SEQUENCE[-2])["path"], "/ndt/inject_link_recovery")

    def test_the_link_sequence_is_the_last_thing_the_run_does(self):
        # It cuts a real link for the length of two requests. Anything reading the graph while it
        # is cut would be reading a network this suite broke.
        names = [e["name"] for e in spec.ENDPOINTS]
        self.assertEqual(names[-len(LINK_SEQUENCE):], LINK_SEQUENCE)

    def test_every_step_of_the_sequence_needs_allow_mutations(self):
        for name in LINK_SEQUENCE:
            self.assertEqual(self.named(name)["category"], spec.MUTATE, name)

    def test_the_declined_step_is_checked_by_the_invariant_written_for_it(self):
        # The two recovery entries share a path and a schema; only the invariant tells them
        # apart, so a copy-paste that gives both the same one silently deletes half the check.
        self.assertEqual(self.named("link_recovery_detected")["invariants"],
                         [spec.inv_recovery_withdrew_the_declaration])
        self.assertEqual(
            self.named("link_recovery_detected__declined_after_injection")["invariants"],
            [spec.inv_recovery_was_declined_and_said_so])


class GraphNodePowerPathTest(unittest.TestCase):
    """E-25 / E-30: the exemption mark on the wire. [Co-developed with claude code -- Adam]

    The schema is the sixth side of this change -- kernel, graph serialiser, power manager, the
    startup WARN, the manual, and this. It is the only one of the six that an external consumer
    is checked against, so a value the kernel invents and nobody listed here would pass the
    contract run in silence.
    """

    BASE = {"device_name": "s1", "dpid": 1, "ip": [], "is_enabled": True, "is_up": True,
            "mac": 1, "vertex_type": 0, "brand_name": "x", "device_layer": 1}

    def test_a_node_carrying_both_marks_conforms(self):
        for power, telemetry in (("synthetic", "none"), ("snmp", "snmp"), ("ssh", "snmp"),
                                 ("none", "none")):
            with self.subTest(power_path=power, telemetry_path=telemetry):
                self.assertEqual(
                    validate(spec.GRAPH_NODE,
                             {**self.BASE, "power_path": power, "telemetry_path": telemetry}),
                    [],
                    "a pair GraphTypes.hpp actually emits was rejected by the schema")

    def test_a_node_carrying_neither_mark_still_conforms(self):
        # Both are optional and both must stay optional: a kernel built before 2026-09-07 emits
        # neither, and a HOST node never carries them at all.
        self.assertEqual(validate(spec.GRAPH_NODE, self.BASE), [],
                         "the pre-E-25 node shape stopped validating")

    def test_the_schema_pins_the_power_path_vocabulary(self):
        # An unlisted word is a contract change, not a detail: `power_path == "none"` is what a
        # consumer reads to know this build cannot drive the switch, and a fifth spelling would
        # be read as "some path we have not heard of" rather than as "no path".
        self.assertTrue(validate(spec.GRAPH_NODE, {**self.BASE, "power_path": "None"}),
                        "a second spelling of none was accepted")
        self.assertTrue(validate(spec.GRAPH_NODE, {**self.BASE, "power_path": "telnet"}),
                        "an invented mechanism was accepted")

    def test_the_telemetry_vocabulary_is_the_smaller_one_and_not_a_copy(self):
        # Deliberately narrower than power_path's: telemetryPathForBrandName can only ever answer
        # "snmp" or "none". "synthetic" is a power-only mechanism (the Mininet fake), and
        # accepting it here would let a kernel claim health telemetry that KNOWN-ISSUES F-1 says
        # does not exist for a software switch.
        self.assertTrue(validate(spec.GRAPH_NODE, {**self.BASE, "telemetry_path": "synthetic"}),
                        "telemetry_path accepted a power-only mechanism")
        self.assertTrue(validate(spec.GRAPH_NODE, {**self.BASE, "telemetry_path": "ssh"}),
                        "telemetry_path accepted a power-only mechanism")


# =============================================================================================
# W3b-3: per-node identity, and the six deliberately broken models
#
# [Co-developed with claude code -- Adam]
#
# `inv_graph_matches_topology` compared three cardinalities and the dpid SET. That answers "is
# this the right size of network" and cannot answer "is this the right network" -- and being
# pointed at the wrong model is reachable, not hypothetical: tools/test_workflow/run_layers.sh
# picks the topology by (mode, live host count), never by asking the kernel which file it
# loaded, and `setting/` ships two ten-switch four-host models with the same ten dpids.
#
# The fixtures are R0b's six broken topology files (rounds/05-R0b-postmerge2.md 2.1, the same
# six R3 built), each one field away from setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json.
# They are REBUILT here rather than committed, and the rebuild is pinned by the sha256 of the
# artefact that actually went through the kernel -- 138 kB of near-duplicates of a shipped file
# would be a worse fixture, not a better one, and the sha is a stronger claim than the copy:
# it says the single mutation below is the WHOLE difference.
#
# 🔴 Two pairings, because they answer different questions and only one of them improves:
#
#   crossed   -- the kernel serves the shipped model, the runner was handed a broken one.
#                This is the reachable mistake, and per-node identity is what catches it.
#   same-file -- the kernel loaded the broken model and serves it faithfully.
#                Per-node identity does NOT help here and cannot: the invariant compares the
#                graph to the file, so a faithfully served bad file matches by construction.
#                That is the loader's job -- doors 3a-3e -- and this test says so out loud so
#                that "the contract test now looks at per-node identity" is never read as
#                "the contract test now catches #90 and #91".
# =============================================================================================

SHIPPED_OVS4 = os.path.join(REPO_ROOT, "setting",
                            "StaticNetworkTopologyOVS_10Switches_4Hosts.json")
P4_128_TOPOLOGY = os.path.join(REPO_ROOT, "setting",
                               "StaticNetworkTopologyP4_10Switches_128Hosts.json")
#: A REAL captured get_graph_data payload (chaos harness fixture, 2026-08-29), and the shipped
#: model it was captured from. The known-good output this file's projection is checked against.
CAPTURED_P4_GRAPH = os.path.join(REPO_ROOT, "doc", "audit", "2026-08-28_chaos-harness",
                                 "harness", "fixtures", "graph_p4_138nodes.json")



def read_json(path):
    """Closed explicitly: L1 runs these files directly, and an unclosed-file ResourceWarning
    in the output is noise in a lane whose only signal is the last two lines."""
    with open(path) as fh:
        return json.load(fh)


def _s7(topo):
    return [n for n in topo["nodes"] if n.get("device_name") == "s7"][0]


def _add_addressless_host(topo):
    """R0b file a. Verbatim, including `mac: 1` -- which h1 already has (see below)."""
    topo["nodes"].append({"brand_name": "", "device_layer": 3, "device_name": "h9",
                          "nickname": "h9", "dpid": 0, "ip": [], "mac": 1, "vertex_type": 1,
                          "bridge_name": "h9"})


def _empty_switch_ip(topo):
    _s7(topo)["ip"] = []


def _unknown_brand(topo):
    _s7(topo)["brand_name"] = "NOT_A_REAL_KIND"


def _drop_bridge_name(topo):
    del _s7(topo)["bridge_name"]


def _negative_ecmp_port(topo):
    _s7(topo)["ecmp_groups"] = [{"members": [{"type": "port", "port_id": -1},
                                             {"type": "port", "port_id": 999999}]}]


def _edge_to_unknown_dpid(topo):
    topo["edges"].append({"src_dpid": 1, "src_interface": 9,
                          "src_ip": ["192.168.123.11"], "dst_dpid": 4242,
                          "dst_interface": 1, "dst_ip": ["192.168.123.99"],
                          "link_bandwidth_bps": 1000000000})


#: letter -> (the R3/R0b filename, its sha256, the one mutation, what R0b measured the kernel do)
BROKEN_MODELS = {
    "a": ("r3-topo-a-host-empty-ip.json",
          "adff4661ccdf59d2cd2b43e25bea1c9e1d25bf565d066fbdc5c837a96ace335a",
          _add_addressless_host, "accepted (#90)"),
    "b": ("r3-topo-b-switch-empty-ip.json",
          "42a33fc305882ce8b1d9fdb79cf383916500d504746b375f2bc92a5092c420a5",
          _empty_switch_ip, "refused at load (door 3b)"),
    "c": ("r3-topo-c-bad-switch-kind.json",
          "ad2bc613501e8cd5f3788c97cd7cdddd1e661630ae24a260a6086f1df458e920",
          _unknown_brand, "accepted (#91)"),
    "d": ("r3-topo-d-no-bridge-name.json",
          "f861b517a7ce2ac555f3bf2277123b95b1500ee29e684198c7c1603048ee3a3a",
          _drop_bridge_name, "refused at load (door 3c)"),
    "e": ("r3-topo-e-ecmp-negative-port.json",
          "e907877123b3aef523e48a00b4989899826590326e407ed827b764fc7d3e5bb7",
          _negative_ecmp_port, "refused at load"),
    "f": ("r3-topo-f-edge-to-unknown-dpid.json",
          "44b51679af93c18e7a7302ef2c5dabc62588362fe250c2a346841ba43b26d172",
          _edge_to_unknown_dpid, "refused at load (#61)"),
}


def broken_model_bytes(letter):
    """One of the six, byte for byte. `indent=4` is the shipped file's own serialisation --
    verified by the sha256 assertions in TheSixBrokenModelsTest."""
    topo = read_json(SHIPPED_OVS4)
    BROKEN_MODELS[letter][2](topo)
    return json.dumps(topo, indent=4).encode()


def context_for(topology_bytes):
    """A REAL run_contract_test.Context over an in-memory model."""
    with tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False) as fh:
        fh.write(topology_bytes)
        path = fh.name
    try:
        return Context(path, 5, PROBE_IP)
    finally:
        os.unlink(path)


def graph_as_served(topology):
    """The get_graph_data payload a kernel serving this model would produce, as far as
    inv_graph_matches_topology reads it.

    Checked against a real captured payload rather than believed -- see
    TheProjectionTest. Addresses become network-order integers because that is what the
    kernel emits and what the invariant has to normalise back.
    """
    def encode(dotted):
        parts = [int(p) for p in str(dotted).split(".")]
        return sum(p << (8 * i) for i, p in enumerate(parts))

    nodes = []
    for n in topology["nodes"]:
        nodes.append({
            "device_name": n.get("device_name", ""),
            "dpid": n.get("dpid", 0),
            "ip": [encode(v) if isinstance(v, str) else v for v in (n.get("ip") or [])],
            "is_enabled": True, "is_up": True,
            "mac": n.get("mac", 0),
            "vertex_type": n.get("vertex_type", 0),
            "brand_name": n.get("brand_name", ""),
            "device_layer": n.get("device_layer", 0),
        })
    return {"nodes": nodes, "edges": list(topology.get("edges", []))}


class TheSixBrokenModelsTest(unittest.TestCase):
    """The fixtures are the artefacts R0b fed to the kernel, or they are not evidence."""

    def test_each_broken_model_is_reproduced_byte_for_byte(self):
        for letter, (name, want_sha, _mut, _measured) in sorted(BROKEN_MODELS.items()):
            got = hashlib.sha256(broken_model_bytes(letter)).hexdigest()
            self.assertEqual(got, want_sha,
                             f"{letter} ({name}) no longer rebuilds to the file R0b ran: the "
                             f"shipped model or the mutation has moved, and this fixture is "
                             f"no longer the thing that went through the kernel")

    def test_the_broken_models_differ_from_the_shipped_one_in_exactly_one_place(self):
        base = read_json(SHIPPED_OVS4)
        for letter in sorted(BROKEN_MODELS):
            bad = json.loads(broken_model_bytes(letter).decode())
            diffs = sum(1 for i, n in enumerate(bad["nodes"])
                        if i >= len(base["nodes"]) or n != base["nodes"][i])
            diffs += abs(len(bad["edges"]) - len(base["edges"]))
            self.assertEqual(diffs, 1, f"{letter} changes more than one thing")


class TheProjectionTest(unittest.TestCase):
    """graph_as_served is an instrument. It is checked against a real capture, not believed."""

    def test_the_projection_reproduces_a_real_captured_payload(self):
        captured = read_json(CAPTURED_P4_GRAPH)
        projected = graph_as_served(read_json(P4_128_TOPOLOGY))
        self.assertEqual(len(projected["nodes"]), len(captured["nodes"]))
        by_key = {(n["vertex_type"], n["dpid"], n["device_name"]): n for n in captured["nodes"]}
        self.assertEqual(len(by_key), len(captured["nodes"]), "the capture's keys collide")
        for n in projected["nodes"]:
            real = by_key[(n["vertex_type"], n["dpid"], n["device_name"])]
            for field in ("ip", "mac", "brand_name"):
                self.assertEqual(n[field], real[field],
                                 f"projection disagrees with the capture on {field} of "
                                 f"{n['device_name']}")

    def test_the_captured_payload_and_its_own_model_agree_node_for_node(self):
        """The control the whole class rests on: a REAL graph against the REAL model it was
        captured from must be silent, or every red below is just this check being wrong."""
        captured = read_json(CAPTURED_P4_GRAPH)
        self.assertEqual(spec.inv_graph_matches_topology(
            captured, Context(P4_128_TOPOLOGY, 5, PROBE_IP)), [])


class RealContextSuppliesPerNodeIdentityTest(unittest.TestCase):
    """existence != wiring. spec.py falls back to cardinalities when a ctx carries no identity;
    that fallback is for hand-built stand-ins, and this is what stops it becoming production."""

    def test_the_runner_builds_both_maps_for_every_shipped_model(self):
        for name in sorted(os.listdir(os.path.join(REPO_ROOT, "setting"))):
            if not name.startswith("StaticNetworkTopology") or not name.endswith(".json"):
                continue
            ctx = Context(os.path.join(REPO_ROOT, "setting", name), 5, PROBE_IP)
            self.assertIsNone(ctx.switch_identity_unavailable, name)
            self.assertIsNone(ctx.host_identity_unavailable, name)
            self.assertEqual(len(ctx.expected_switch_identity), ctx.expected_switches, name)
            self.assertEqual(len(ctx.expected_host_identity), ctx.expected_hosts, name)

    def test_a_model_whose_hosts_share_a_mac_yields_no_verdict_instead_of_a_wrong_one(self):
        # File a is exactly this: R3 built h9 by copying h1, mac and all. A keyed map would
        # have silently dropped one of them and then compared the graph against a host that
        # is not there.
        ctx = context_for(broken_model_bytes("a"))
        self.assertIsNone(ctx.expected_host_identity)
        self.assertIn("same mac", ctx.host_identity_unavailable)
        out = spec.inv_graph_matches_topology(
            graph_as_served(json.loads(broken_model_bytes("a").decode())), ctx)
        failures, preconditions, _ = spec.partition_messages(out)
        self.assertTrue(any("same mac" in p for p in preconditions), out)


class PerNodeIdentityAgainstTheBrokenModelsTest(unittest.TestCase):
    """The crossed pairing: a healthy fabric, validated against a model that is not the one it
    is running."""

    def setUp(self):
        self.healthy = graph_as_served(read_json(SHIPPED_OVS4))

    def failures_against(self, letter):
        ctx = context_for(broken_model_bytes(letter))
        failures, _pre, _acc = spec.partition_messages(
            spec.inv_graph_matches_topology(self.healthy, ctx))
        return failures

    def test_the_shipped_model_against_its_own_graph_is_silent(self):
        # The control. Without it every red below could be this check firing on everything.
        ctx = Context(SHIPPED_OVS4, 5, PROBE_IP)
        self.assertEqual(spec.inv_graph_matches_topology(self.healthy, ctx), [])

    def test_a_switch_with_no_address_in_the_model_is_now_named(self):
        """b. Same 14 nodes, same 40 edges, same ten dpids -- invisible to every count."""
        out = self.failures_against("b")
        self.assertTrue(any("dpid 7" in m and "addresses" in m for m in out), out)

    def test_a_switch_with_the_wrong_brand_in_the_model_is_now_named(self):
        """c. Same shape again; brand_name decides power and telemetry dispatch."""
        out = self.failures_against("c")
        self.assertTrue(any("dpid 7" in m and "brand" in m for m in out), out)

    def test_a_field_the_graph_does_not_carry_is_still_invisible_and_that_is_stated(self):
        """d and e differ only in bridge_name / ecmp_groups, which get_graph_data does not
        serve. This invariant reads the graph, so it cannot see them -- and a test that
        claimed otherwise would be the instrument lying about its own reach."""
        for letter in ("d", "e"):
            self.assertEqual(self.failures_against(letter), [],
                             f"{letter} is not reachable from the graph payload")

    def test_the_two_the_counts_already_caught_are_still_caught(self):
        """a (an extra host) and f (an extra edge) were the only two of the six the old
        cardinality checks could see. A fix that lost them would be a regression."""
        self.assertTrue(any("host count" in m for m in self.failures_against("a")))
        self.assertTrue(any("edge count" in m for m in self.failures_against("f")))

    def test_the_cardinality_only_check_saw_only_those_two(self):
        """The BEFORE column, computed rather than remembered: with the identity maps taken
        away, four of the six broken models produce nothing at all."""
        silent = []
        for letter in sorted(BROKEN_MODELS):
            ctx = context_for(broken_model_bytes(letter))
            ctx.expected_switch_identity = None
            ctx.expected_host_identity = None
            ctx.switch_identity_unavailable = None
            ctx.host_identity_unavailable = None
            failures, _p, _a = spec.partition_messages(
                spec.inv_graph_matches_topology(self.healthy, ctx))
            if not failures:
                silent.append(letter)
        self.assertEqual(silent, ["b", "c", "d", "e"],
                         "the before-picture moved; the claim about what was gained rests "
                         "on this list")


class PerNodeIdentityDoesNotCloseTheLoaderDoorsTest(unittest.TestCase):
    """The same-file pairing, and the limit it makes explicit.

    #90 and #91 are files the kernel ACCEPTS and then serves faithfully. This invariant
    compares the graph to the file it was handed, so when they are the same file it matches by
    construction -- before this change and after it. The doors in
    validateStaticTopologyJson are what close those, and this test exists so that nobody reads
    "the contract test now checks per-node identity" as "the contract test now catches them".
    """

    def test_a_faithfully_served_unknown_brand_is_still_green(self):
        """c / #91: the kernel took the file, mapped NOT_A_REAL_KIND to hardware, and serves
        the string back. Graph and file agree, so this invariant has nothing to say."""
        topo = json.loads(broken_model_bytes("c").decode())
        ctx = context_for(broken_model_bytes("c"))
        self.assertEqual(spec.inv_graph_matches_topology(graph_as_served(topo), ctx), [])

    def test_a_faithfully_served_addressless_host_is_still_green(self):
        """a / #90, with R3's mac collision removed so that the collision is not what makes
        this test pass. `('h9', [])` is served exactly as the file declares it."""
        topo = json.loads(broken_model_bytes("a").decode())
        [h for h in topo["nodes"] if h["device_name"] == "h9"][0]["mac"] = 9
        ctx = context_for(json.dumps(topo, indent=4).encode())
        self.assertIsNone(ctx.host_identity_unavailable)
        self.assertEqual(spec.inv_graph_matches_topology(graph_as_served(topo), ctx), [])


class AddressDecodingTest(unittest.TestCase):
    """The comparison is only as good as this, and getting it backwards finds a different
    network on every node of a healthy fabric."""

    def test_the_first_octet_is_the_low_byte(self):
        self.assertEqual(spec.dotted_ip(16777226), "10.0.0.1")
        self.assertEqual(spec.dotted_ip(192653504), "192.168.123.11")

    def test_a_dotted_string_is_already_dotted(self):
        self.assertEqual(spec.dotted_ip("10.0.0.1"), "10.0.0.1")

    def test_both_encodings_of_one_address_compare_equal(self):
        self.assertEqual(spec.address_set({"ip": [16777226]}),
                         spec.address_set({"ip": ["10.0.0.1"]}))

    def test_the_address_set_is_a_set_because_four_aliases_have_no_promised_order(self):
        self.assertEqual(spec.address_set({"ip": ["10.0.0.1", "10.0.0.2"]}),
                         spec.address_set({"ip": ["10.0.0.2", "10.0.0.1"]}))

    def test_a_missing_ip_key_is_the_empty_set_not_a_crash(self):
        self.assertEqual(spec.address_set({}), frozenset())


class RenameIsAccountedForNotFailedTest(unittest.TestCase):
    """W10 moved renames into .test_run/nickname_overlay/ and lays them back over the graph at
    load, so a device_name that disagrees with the model file is a normal state of a healthy
    fabric. Failing on it would turn every rename into a red L2 run."""

    def setUp(self):
        self.graph = graph_as_served(read_json(SHIPPED_OVS4))
        self.ctx = Context(SHIPPED_OVS4, 5, PROBE_IP)

    def test_a_renamed_switch_is_reported_and_does_not_fail_the_check(self):
        for n in self.graph["nodes"]:
            if n["dpid"] == 7:
                n["device_name"] = "spine-7"
        failures, _pre, accounted = spec.partition_messages(
            spec.inv_graph_matches_topology(self.graph, self.ctx))
        self.assertEqual(failures, [])
        self.assertTrue(any("spine-7" in a for a in accounted), accounted)

    def test_a_renamed_switch_that_also_moved_address_still_fails(self):
        # The rename explains the name and nothing else. A check that let the name excuse the
        # whole node would be an exemption, not an explanation.
        for n in self.graph["nodes"]:
            if n["dpid"] == 7:
                n["device_name"] = "spine-7"
                n["ip"] = [1]
        failures, _pre, _acc = spec.partition_messages(
            spec.inv_graph_matches_topology(self.graph, self.ctx))
        self.assertTrue(any("dpid 7" in m and "addresses" in m for m in failures), failures)

    def test_a_renamed_host_is_reported_and_does_not_fail_the_check(self):
        for n in self.graph["nodes"]:
            if n["vertex_type"] == 1 and n["mac"] == 2:
                n["device_name"] = "laptop"
        failures, _pre, accounted = spec.partition_messages(
            spec.inv_graph_matches_topology(self.graph, self.ctx))
        self.assertEqual(failures, [])
        self.assertTrue(any("laptop" in a for a in accounted), accounted)


class GraphSideDuplicateHostMacTest(unittest.TestCase):
    """A duplicate mac in the GRAPH is a verdict about the twin, not about the model: the
    nickname overlay keys hosts by mac, so two hosts under one mac are ambiguous by
    construction."""

    def test_two_hosts_served_under_one_mac_are_named(self):
        graph = graph_as_served(read_json(SHIPPED_OVS4))
        for n in graph["nodes"]:
            if n["vertex_type"] == 1 and n["mac"] == 2:
                n["mac"] = 1
        failures, _p, _a = spec.partition_messages(
            spec.inv_graph_matches_topology(graph, Context(SHIPPED_OVS4, 5, PROBE_IP)))
        self.assertTrue(any("duplicate host mac" in m for m in failures), failures)


class ModelUnderTestTest(unittest.TestCase):
    """
    E-2: the kernel now says which model it loaded, and the contract asserts it is the one this
    run was pointed at.

    [Co-developed with claude code -- Adam]
    The three directions that matter are the same three the invariant documents: a matching
    kernel is silent, a MISSING field is a precondition rather than a pass or a failure, and a
    kernel serving a different file fails. The middle one is the widening -- treating "the
    kernel did not say" as either verdict is how a pre-E-2 kernel would be reported broken, or
    how a real mismatch would be reported fine.
    """

    def _ctx(self):
        return real_ctx()

    def _body(self, **extra):
        return {"nodes": [node(1)], "edges": [], **extra}

    def test_the_three_keys_are_optional_so_a_pre_e2_kernel_still_validates(self):
        base = {"nodes": [{"device_name": "s1", "dpid": 1, "ip": [], "is_enabled": True,
                           "is_up": True, "mac": 1, "vertex_type": 0, "brand_name": "x",
                           "device_layer": 1}], "edges": []}
        self.assertEqual(validate(spec.GRAPH_DATA, base), [],
                         "baseline 28b8b13 serves none of the three and must still validate")
        digest = "a" * 64
        self.assertEqual(validate(spec.GRAPH_DATA,
                                  {**base, "topology_file": "/x.json",
                                   "topology_sha256": digest,
                                   "topology_loaded_at": 1757000000}), [])

    def test_the_three_keys_are_type_checked_when_present(self):
        base = {"nodes": [{"device_name": "s1", "dpid": 1, "ip": [], "is_enabled": True,
                           "is_up": True, "mac": 1, "vertex_type": 0, "brand_name": "x",
                           "device_layer": 1}], "edges": []}
        self.assertTrue(validate(spec.GRAPH_DATA, {**base, "topology_file": ""}),
                        "an empty path is not an answer and must not validate")
        self.assertTrue(validate(spec.GRAPH_DATA, {**base, "topology_loaded_at": "yesterday"}),
                        "the timestamp is epoch seconds, not text")

    def test_a_kernel_serving_the_model_under_test_reports_nothing(self):
        ctx = self._ctx()
        with open(ctx.topology_path, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        out = spec.inv_kernel_serves_the_model_under_test(
            self._body(topology_file=ctx.topology_path, topology_sha256=digest), ctx)
        self.assertEqual(out, [])

    def test_a_relative_and_an_absolute_name_for_one_file_are_not_a_mismatch(self):
        ctx = self._ctx()
        relative = os.path.relpath(ctx.topology_path, os.getcwd())
        out = spec.inv_kernel_serves_the_model_under_test(
            self._body(topology_file=os.path.join(os.getcwd(), relative)), ctx)
        self.assertEqual(out, [], "two spellings of one file are not two files")

    def test_a_kernel_serving_a_different_model_fails(self):
        ctx = self._ctx()
        other = os.path.join(REPO_ROOT, "setting", "StaticNetworkTopologyMininet_10Switches.json")
        out = spec.inv_kernel_serves_the_model_under_test(
            self._body(topology_file=other), ctx)
        self.assertTrue(out, "the whole point: a wrong model is green in every other check")
        self.assertFalse(any(m.startswith(TOOL_PRECONDITION) for m in out),
                         "this is a finding, not an inability to check")
        self.assertIn(other, out[0])

    def test_a_kernel_that_does_not_say_is_a_precondition_not_a_verdict(self):
        out = spec.inv_kernel_serves_the_model_under_test(self._body(), self._ctx())
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0].startswith(TOOL_PRECONDITION),
                        "a pre-E-2 kernel is not broken, and it is not confirmed either")

    def test_a_file_edited_since_the_load_fails(self):
        ctx = self._ctx()
        out = spec.inv_kernel_serves_the_model_under_test(
            self._body(topology_file=ctx.topology_path, topology_sha256="0" * 64), ctx)
        self.assertTrue(out)
        self.assertFalse(any(m.startswith(TOOL_PRECONDITION) for m in out))
        self.assertIn("edited since the kernel loaded it", out[0])

    def test_a_digest_that_is_not_sha256_hex_is_a_contract_change(self):
        ctx = self._ctx()
        out = spec.inv_kernel_serves_the_model_under_test(
            self._body(topology_file=ctx.topology_path, topology_sha256="DEADBEEF"), ctx)
        self.assertTrue(any("64 lowercase hex" in m for m in out), out)


class SelftestFixturesMatchTheEndpointTable(unittest.TestCase):
    """
    Every --self-test fixture, against the schema the contract test actually validates with.

    [Co-developed with claude code -- Adam] -- F-OFFLINE-1 G2/G13, 2026-09-11.

    17 of the 31 fixtures hold a private copy of a schema instead of spec.py's object. Several
    of those copies are deliberate and say why. What was missing was anyone comparing them: on
    2026-09-11 `install_flow_entry`'s copy described `{"status": ...}` while its endpoint has
    required `accepted` since 2026-09-06, so --self-test was reporting "ok install_flow_entry"
    for a body the live run would have failed on structure. A self-test whose stated purpose is
    "prove the schemas accept what the kernel documents" cannot do that against a schema the
    kernel's contract does not use.

    This is the cross-application the offline round found missing (G3's third leg): the two
    halves of the tool -- endpoint table and fixture map -- were only ever run against
    themselves. It is a cheap check and it is the only one that can see a copy drift.
    """

    @classmethod
    def setUpClass(cls):
        import selftest_fixtures  # noqa: PLC0415 -- same sys.path dance as spec, see above
        cls.fx = selftest_fixtures
        cls.by_name = {ep["name"]: ep for ep in spec.ENDPOINTS}

    def test_every_fixture_names_an_endpoint_or_says_why_it_cannot(self):
        unresolved = []
        for name in self.fx.FIXTURES:
            endpoint, which = self.fx.fixture_target(name)
            if endpoint is None:
                # (None, reason) is only allowed for a DECLARED exception. A key that simply
                # fails to resolve is the typo this test exists to catch.
                if name not in self.fx.FIXTURE_TARGET_OVERRIDES:
                    unresolved.append(which)
            elif endpoint not in self.by_name:
                unresolved.append(f"{name!r} resolves to {endpoint!r}, not in ENDPOINTS")
        self.assertEqual(unresolved, [], "\n".join(unresolved))

    def test_every_fixture_sample_validates_against_its_endpoints_schema(self):
        problems = []
        for name, (_own_schema, sample) in self.fx.FIXTURES.items():
            endpoint, which = self.fx.fixture_target(name)
            if endpoint is None:
                continue  # reported by the test above; not this test's finding
            schema = self.by_name[endpoint].get(which)
            if schema is None:
                problems.append(f"{name!r}: endpoint {endpoint!r} has no {which}")
                continue
            errs = validate(schema, sample)
            if errs:
                problems.append(f"{name!r} vs {endpoint}.{which}: {errs}")
        self.assertEqual(problems, [], "\n".join(problems))

    def test_a_private_copy_that_has_drifted_is_caught(self):
        # The positive control, so a green run above is not "the loop examined nothing".
        # STATUS_OK is what install_flow_entry's fixture used to carry, and it is exactly one
        # required field short of the endpoint's schema.
        endpoint = self.by_name["install_flow_entry"]
        self.assertTrue(validate(endpoint["schema"], {"status": "Flow installed"}),
                        "the endpoint schema no longer requires anything beyond `status`, so "
                        "this control cannot fail and the check above proves nothing")

    def test_the_naming_convention_resolves_the_variant_fixtures(self):
        # G13 counted 9 fixtures as belonging to no endpoint. They are variants; this pins the
        # convention that says so, because a convention nothing asserts is a guess.
        self.assertEqual(
            self.fx.fixture_target("inject_link_failure (MININET)"),
            ("inject_link_failure", "schema"))
        self.assertEqual(
            self.fx.fixture_target("link_failure_detected (kernel from trunk, "
                                   "no down_reason/until)"),
            ("link_failure_detected", "schema"))
        # A query suffix is NOT stripped, and this probe is a name the override table does not
        # carry, so it is the convention being asserted and not the exception. The one query
        # fixture in the file answers with three required fields the unparameterised endpoint's
        # reply does not have: stripping the suffix validates a sample against the wrong schema
        # and prints `ok`.
        self.assertIsNone(self.fx.fixture_target("get_graph_data?since=1")[0])

    def test_the_declared_exceptions_resolve_where_they_say_they_do(self):
        # Not "the table exists" -- the values. Every one of these was wrong before, in a way
        # no test could see: a fixture attributed to the wrong endpoint validates against a
        # schema that happens to fit, and the mis-attribution only surfaces when an invariant
        # is applied (which is what G3 adds).
        self.assertEqual(
            self.fx.fixture_target("link_recovery_detected (declined: declaration_retained)"),
            ("link_recovery_detected__declined_after_injection", "schema"),
            "the DECLINED reply is step 4's, not step 2's")
        self.assertEqual(
            self.fx.fixture_target("link request body (all four endpoints take the same one)"),
            ("link_failure_detected", "request_schema"),
            "a request body must be checked against request_schema, not against a response")
        endpoint, why = self.fx.fixture_target("get_flow_dispatch_status?request_id=<id>")
        self.assertIsNone(endpoint)
        self.assertIn("mutation", why, "a declared exception has to say why it is one")
        endpoint, why = self.fx.fixture_target("no_such_endpoint (invented)")
        self.assertIsNone(endpoint)
        self.assertIn("not in spec.ENDPOINTS", why)


class DeclinedRecoveryPremiseTest(unittest.TestCase):
    """
    F-OFFLINE-1 G10: the declined check accuses the kernel of something it may not have done.

    [Co-developed with claude code -- Adam] -- KNOWN-ISSUES A-8, E-21, 2026-09-11.

    inv_recovery_was_declined_and_said_so is step 4 of the mutating sequence and its whole
    premise is step 3: "the check immediately before this one injected a failure through
    /ndt/inject_link_failure, which records no report, so nothing pairs with this recovery."
    The function had no branch for the premise being false. Applied to a bare
    {"status": "link recovery processed"} it returned, in one sentence, an accusation that the
    kernel "either withdrew a declaration nothing ever answered for, or withdrew nothing and
    did not say so".

    On a kernel that predates /ndt/inject_link_failure -- which spec.py's own comment records
    as every trunk build -- step 3 answers 404, nothing is declared, and step 4's reply is
    then exactly that bare 200. The check blamed the kernel for withdrawing something that
    was never declared.

    Fixed at the invariant rather than only at the endpoint table: l3_component_check.py and
    these tests reach the function directly, and a guard that only exists in the runner is a
    guard the next caller does not get.
    """

    class Landed:
        """A run that recorded step 3's injection as having succeeded."""

        link_failure_injected = True

    class DidNotLand:
        link_failure_injected = False

    BARE = {"status": "link recovery processed"}

    def test_a_run_that_did_not_record_the_injection_makes_no_claim(self):
        out = spec.inv_recovery_was_declined_and_said_so(self.BARE, None)
        self.assertEqual(len(out), 1, out)
        self.assertTrue(out[0].startswith(TOOL_PRECONDITION), out)

    def test_a_run_whose_injection_failed_makes_no_claim_either(self):
        out = spec.inv_recovery_was_declined_and_said_so(self.BARE, self.DidNotLand())
        self.assertEqual(len(out), 1, out)
        self.assertTrue(out[0].startswith(TOOL_PRECONDITION), out)

    def test_with_the_premise_established_it_is_still_an_accusation(self):
        # The control, and the one that matters: this is the lw8b failure mode and gating it
        # must not be a way to stop reporting it.
        out = spec.inv_recovery_was_declined_and_said_so(self.BARE, self.Landed())
        self.assertEqual(len(out), 1, out)
        self.assertFalse(out[0].startswith(TOOL_PRECONDITION), out)
        self.assertIn("was not declined", out[0])

    def test_a_correctly_declined_reply_is_unaffected_by_any_of_this(self):
        # The premise only gates the accusation. A reply that DID decline is checked in full
        # whatever the run knows, because there is nothing to misattribute.
        for ctx in (None, self.Landed(), self.DidNotLand()):
            self.assertEqual(
                spec.inv_recovery_was_declined_and_said_so(DECLINED_RECOVERY, ctx), [], ctx)
            self.assertTrue(
                spec.inv_recovery_was_declined_and_said_so(
                    {**DECLINED_RECOVERY, "until": "/ndt/link_recovery_detected"}, ctx))

    def test_the_injection_step_is_the_one_that_records_it(self):
        # Existence is not wiring. The state has to be written by the step whose outcome it
        # describes, or the branch above is dead and the check is silently off.
        injection = next(ep for ep in spec.ENDPOINTS if ep["name"] == "inject_link_failure")
        self.assertEqual(injection.get("records"), "link_failure_injected")
        declined = next(ep for ep in spec.ENDPOINTS
                        if ep["name"] == "link_recovery_detected__declined_after_injection")
        self.assertIsNone(declined.get("records"),
                          "the step that reads the state must not also write it")

    def test_the_runner_writes_what_the_step_declares(self):
        import run_contract_test as runner
        endpoint = next(ep for ep in spec.ENDPOINTS if ep["name"] == "inject_link_failure")
        ctx = Context(P4_TOPOLOGY, 5, PROBE_IP)
        self.assertIsNone(getattr(ctx, "link_failure_injected", None),
                          "unknown until the step runs, not True")

        def fake_request(base_url, ep, _ctx, timeout):
            return (200, {"status": "link failure injected", "down_reason": "declared",
                          "until": "/ndt/inject_link_recovery",
                          "tc": "skipped (not MININET)"}, None)

        real = runner.request
        runner.request = fake_request
        try:
            # check_endpoint alone, with nothing else called: the recording has to be part
            # of running the step, or a caller that runs one check by hand gets a ctx that
            # never learns anything -- and "the loop forgot to call the recorder" is then a
            # mutation no test can see.
            runner.check_endpoint("http://127.0.0.1:0", endpoint, ctx,
                                  LinkStepPreconditionTest.Args())
            self.assertTrue(ctx.link_failure_injected)

            runner.request = lambda *a, **k: (404, {"status": "error"}, None)
            runner.check_endpoint("http://127.0.0.1:0", endpoint, ctx,
                                  LinkStepPreconditionTest.Args())
            self.assertFalse(ctx.link_failure_injected)
        finally:
            runner.request = real


class LinkStepPreconditionTest(unittest.TestCase):
    """
    F-OFFLINE-1 G11: a step that could not choose a link must make no claim about the kernel.

    [Co-developed with claude code -- Adam] -- KNOWN-ISSUES A-8, 2026-09-11.

    switch_to_switch_link() returns None when the topology holds no switch-to-switch edge, and
    link_endpoint_body() then sends NO_LINK_CHOSEN_PAYLOAD -- four zeros, which all four link
    endpoints refuse by design (W8-7's dpid-0 doors). None of the six MUTATE steps declared an
    expect_status, so the default [200] applied and that correct refusal was recorded as

        HTTP status 404, expected 200

    against the kernel. The intent behind the fallback was right -- refuse rather than guess a
    link, because a guessed link means a fault injected on an edge nobody chose -- and the
    reporting was the A-8 shape: a tool that cannot establish its own precondition failing in
    a way that looks like the system failing.

    Loud either way. Louder, in fact: the request is not sent at all.
    """

    class Args:
        timeout = 1
        with_traffic = False

    HOST_EDGE_ONLY = {"nodes": [{"dpid": 1, "vertex_type": 0, "device_name": "s1",
                                 "ip": ["10.0.0.1"], "mac": 1},
                                {"dpid": 0, "vertex_type": 1, "device_name": "h1",
                                 "ip": ["10.0.0.2"], "mac": 2}],
                      "edges": [{"src_dpid": 1, "src_interface": 1,
                                 "dst_dpid": 0, "dst_interface": 0}]}

    LINK_STEPS = ("link_failure_detected", "link_recovery_detected", "inject_link_failure",
                  "link_recovery_detected__declined_after_injection", "inject_link_recovery",
                  "inject_link_recovery_cleanup")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.no_link = os.path.join(self.tmp.name, "no_switch_link.json")
        with open(self.no_link, "w", encoding="utf-8") as fh:
            json.dump(self.HOST_EDGE_ONLY, fh)
        spec.switch_to_switch_link.cache_clear()
        self.addCleanup(spec.switch_to_switch_link.cache_clear)

    def _run(self, endpoint_name, topology, reply=(404, {"status": "error"}, None)):
        """check_endpoint with the network stubbed. Returns (Result, requests sent)."""
        import run_contract_test as runner
        endpoint = next(ep for ep in spec.ENDPOINTS if ep["name"] == endpoint_name)
        ctx = Context(topology, 5, PROBE_IP)
        sent = []

        def fake_request(base_url, ep, _ctx, timeout):
            sent.append(ep["name"])
            return reply

        real = runner.request
        runner.request = fake_request
        try:
            return runner.check_endpoint("http://127.0.0.1:0", endpoint, ctx, self.Args()), sent
        finally:
            runner.request = real

    def test_every_link_step_makes_no_claim_when_no_link_could_be_chosen(self):
        for name in self.LINK_STEPS:
            res, sent = self._run(name, self.no_link)
            self.assertEqual(res.failures, [], f"{name} blamed the kernel: {res.failures}")
            self.assertEqual(len(res.preconditions), 1, f"{name}: {res.preconditions}")
            self.assertTrue(res.preconditions[0].startswith(TOOL_PRECONDITION), name)
            self.assertEqual(sent, [], f"{name} sent a request it knew would be refused")

    def test_the_precondition_names_the_topology_it_could_not_use(self):
        res, _sent = self._run("inject_link_failure", self.no_link)
        self.assertIn("no_switch_link.json", res.preconditions[0])

    def test_a_topology_with_a_switch_link_still_runs_the_step(self):
        # The control. A precondition that is never satisfied is a check that has been deleted.
        res, sent = self._run("inject_link_failure", P4_TOPOLOGY,
                              reply=(200, {"status": "link failure injected",
                                           "down_reason": "declared",
                                           "until": "/ndt/inject_link_recovery",
                                           "tc": "skipped (not MININET)"}, None))
        self.assertEqual(res.preconditions, [], res.preconditions)
        self.assertEqual(sent, ["inject_link_failure"])
        self.assertTrue(res.ok, res.failures)

    def test_a_real_refusal_on_a_real_link_is_still_a_failure(self):
        # The other control, and the one that matters: the precondition must not become a way
        # for a 404 on a link this topology DOES hold to stop counting.
        res, sent = self._run("inject_link_failure", P4_TOPOLOGY)
        self.assertEqual(res.preconditions, [])
        self.assertEqual(sent, ["inject_link_failure"])
        self.assertTrue(any("404" in f for f in res.failures), res.failures)


class CrossApplicationStagesTest(unittest.TestCase):
    """
    --self-test's two cross-application stages, on stand-in fixture maps.

    [Co-developed with claude code -- Adam] -- F-OFFLINE-1 G3, 2026-09-11.

    The stages are what found G3, so they need their own positive controls: a stage that
    cannot go red is the shape it exists to remove. Each test hands the stage a fixture map
    built here rather than the shipped one, so the shipped one going green (or not) is a
    separate question from whether the stage works.
    """

    class Pal:
        def red(self, s):
            return s

        green = dim = yellow = red

    class Fx:
        """The three attributes the stages read off selftest_fixtures."""

        def __init__(self, fixtures, exceptions=None, targets=None):
            self.FIXTURES = fixtures
            self.FIXTURE_INVARIANT_EXCEPTIONS = exceptions or {}
            self._targets = targets or {}
            self.SELFTEST_CTX = Ctx()

        def fixture_target(self, name):
            return self._targets.get(name, (name, "schema"))

    # The stages print as they go, which is their job in the runner and noise here: an L1 log
    # that carries a deliberately-red stand-in run reads as a real failure to whoever greps it.
    def _schemas(self, fx):
        import contextlib
        import io
        import run_contract_test as runner
        with contextlib.redirect_stdout(io.StringIO()):
            return runner._cross_apply_schemas(self.Pal(), fx)

    def _invariants(self, fx):
        import contextlib
        import io
        import run_contract_test as runner
        with contextlib.redirect_stdout(io.StringIO()):
            return runner._cross_apply_invariants(self.Pal(), fx)

    def test_a_schema_that_accepts_every_foreign_body_is_reported(self):
        fx = self.Fx({"get_graph_data": (spec.GRAPH_DATA, {"nodes": [], "edges": []}),
                      "get_openflow_capacity": (spec.Any_(), {"OVS": {}})})
        _passed, failed = self._schemas(fx)
        self.assertGreaterEqual(failed, 1, "Any_() rejects nothing and must be reported")

    def test_the_shipped_capacity_schema_is_not_that(self):
        # The G3 fix itself, asserted here and not only through the runner's output.
        capacity = next(ep for ep in spec.ENDPOINTS if ep["name"] == "get_openflow_capacity")
        self.assertTrue(validate(capacity["schema"], [{"OVS": {}}]),
                        "a list is not a map keyed by switch family")
        self.assertTrue(validate(capacity["schema"], "no capacity for you"))
        self.assertEqual(validate(capacity["schema"], {"OVS": {}, "bmv2": {}}), [],
                         "the keys stay unenumerated: a different fabric has different ones")

    #: One endpoint, one registered invariant (inv_avg_link_usage_range), so the four tests
    #: below isolate the stage's decision instead of the graph endpoint's six invariants.
    HEALTHY = {"status": "success", "avg_link_usage": 0.12}
    OUT_OF_RANGE = {"status": "success", "avg_link_usage": 500}

    def _one_endpoint(self, sample, exceptions=None):
        return self.Fx({"get_average_link_usage": (spec.Any_(), sample)},
                       exceptions=exceptions)

    def test_a_fixture_that_contradicts_its_endpoints_invariant_is_reported(self):
        _passed, failed = self._invariants(self._one_endpoint(self.OUT_OF_RANGE))
        self.assertEqual(failed, 1)

    def test_a_declared_exception_turns_that_red_into_a_pass(self):
        fx = self._one_endpoint(
            self.OUT_OF_RANGE,
            exceptions={("get_average_link_usage", "inv_avg_link_usage_range"):
                        "on purpose, for this test"})
        _passed, failed = self._invariants(fx)
        self.assertEqual(failed, 0, "a declared exception is not a failure")

    def test_an_exception_that_no_longer_fires_is_a_failure(self):
        # The allowlist's lesson. An excuse nobody rechecks outlives its reason.
        fx = self._one_endpoint(
            self.HEALTHY,
            exceptions={("get_average_link_usage", "inv_avg_link_usage_range"):
                        "stale: nothing reports now"})
        _passed, failed = self._invariants(fx)
        self.assertEqual(failed, 1)

    def test_an_exception_naming_a_pair_that_does_not_exist_is_a_failure(self):
        fx = self._one_endpoint(self.HEALTHY,
                                exceptions={("renamed_fixture", "inv_gone"):
                                            "points at nothing"})
        _passed, failed = self._invariants(fx)
        self.assertEqual(failed, 1)

    def test_an_invariant_that_raises_is_a_failure_and_not_a_pass(self):
        # A tool bug must never read as the kernel being fine.
        _passed, failed = self._invariants(self._one_endpoint({"status": "success"}))
        self.assertEqual(failed, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
