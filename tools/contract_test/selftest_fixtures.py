"""
Fixtures for --self-test: real response examples copied from doc/2026-01-02_ndt_api.md.

Purpose: prove the schemas accept what the kernel actually documents, without needing a
running kernel. If a schema rejects the documented example, the schema is wrong -- and
finding that out here is much cheaper than debugging it against a live system.

The invariant cases additionally check that each invariant *fires* on bad data, so we
know the checks are not vacuously passing.

[Co-developed with claude code -- Adam]
"""

from __future__ import annotations

import spec
from schema import Any_, MapOf, Num, OneOf, Str, is_ipv4_string
from spec import PowerState

# --- doc/2026-01-02_ndt_api.md section 3: GET /ndt/get_graph_data -----------------------------
GRAPH_DATA_SAMPLE = {
    "nodes": [
        {"device_name": "s4", "dpid": 106225808380928, "ip": [168430090],
         "is_enabled": True, "is_up": True, "mac": 0, "vertex_type": 0,
         "brand_name": "OVS", "device_layer": 1},
        {"device_name": "h9", "dpid": 0,
         "ip": [1157736640, 1174513856, 1107404992, 1090627776],
         "is_enabled": True, "is_up": True, "mac": 31362038109890,
         "vertex_type": 1, "brand_name": "", "device_layer": 3},
    ],
    "edges": [
        {"dst_dpid": 0, "dst_ip": [50440384, 33663168], "dst_interface": 0,
         "flow_set": [{"dst_ip": 2147592384, "dst_port": 5201, "protocol_number": 6,
                       "src_ip": 16885952, "src_port": 40997}],
         "is_enabled": True, "is_up": True,
         "left_link_bandwidth_bps": 998396604, "left_link_bandwidth_source": "measured",
         "link_bandwidth_bps": 1000000000,
         "link_bandwidth_usage_bps": 1603396,
         "link_bandwidth_utilization_percent": 0.16033960000000347,
         "src_dpid": 106225808402492, "src_ip": [67766794], "src_interface": 1},
    ],
}

# --- doc/2026-01-02_ndt_api.md section 4: GET /ndt/get_detected_flow_data ---------------------
FLOW_DATA_SAMPLE = [
    {"dst_ip": 16885952, "dst_port": 55367,
     "estimated_flow_sending_rate_bps_in_the_last_sec": 1712000,
     "estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot": 1817600,
     "estimated_packet_rate_in_the_last_sec": 3000,
     "estimated_packet_rate_in_the_proceeding_1sec_timeslot": 3200,
     "first_sampled_time": "2025-08-22 10:13:12",
     "latest_sampled_time": "2025-08-22 10:13:17",
     "path": [{"interface": 5, "node": 1359063232},
              {"interface": 22, "node": 106225808391692},
              {"interface": 0, "node": 16885952}],
     "protocol_id": 6, "src_ip": 1359063232, "src_port": 5201},
]

# --- doc/2026-01-02_ndt_api.md section 5: GET /ndt/get_switch_openflow_table_entries ----------
OF_TABLES_SAMPLE = [
    {"dpid": 106225808402492,
     "flows": {"106225808402492": [
         {"actions": ["OUTPUT:1"], "byte_count": 0, "cookie": 0,
          "duration_nsec": 91000000, "duration_sec": 3935, "flags": 0,
          "hard_timeout": 0, "idle_timeout": 0, "length": 96,
          "match": {"dl_type": 2048, "nw_dst": "192.168.1.1"},
          "packet_count": 0, "priority": 10, "table_id": 0}]}},
]

POWER_REPORT_SAMPLE = [
    {"dpid": 106225808391692, "power_consumed": 851157966},
    {"dpid": 106225808380928, "power_consumed": 851152638},
]

# --- GET /ndt/get_flow_dispatch_status (KNOWN-ISSUES A-7) -------------------------------------
# The counters are kept small and self-consistent rather than reproducing the live 262/1/261
# from the A-7 round: at capacity 256 that run had evicted 5 and was holding a full ring, so an
# honest transcription would need 256 records in this file. The shape is what the schema checks.
DISPATCH_STATUS_SAMPLE = {
    "counters": {"dispatched": 3, "succeeded": 1, "failed": 2, "dropped_after_stop": 0},
    "dispatcher_running": True,
    "recent_failures": [
        {"seq": 2, "at_unix_ms": 1756600000000, "op": "install", "dpid": 1,
         "requested_priority": 915,
         "match": {"eth_type": 2048, "ipv4_dst": "10.0.0.240"},
         "controller_status": 200, "message": "Failed to add route"},
        {"seq": 3, "at_unix_ms": 1756600000500, "op": "delete", "dpid": 2,
         "requested_priority": -1,
         "match": {"eth_type": 2048, "ipv4_dst": "10.0.0.241"},
         "controller_status": 0, "message": "controller did not answer"},
    ],
    "recent_failures_capacity": 256,
    "recent_failures_evicted": 0,
    "counters_cover": {
        "dispatch_routes": [
            "/ndt/install_flow_entry",
            "/ndt/modify_flow_entry",
            "/ndt/delete_flow_entry",
            "/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries",
        ],
        "includes_boot_time_programming": False,
        "includes_intent_translator": False,
    },
}

# The same body from a kernel built before the A-7 follow-up: no dispatcher_running, no
# counters_cover, no dropped_after_stop. The schema must still accept it, or the contract
# reports a regression against a kernel that never had the field.
DISPATCH_STATUS_OLDER_KERNEL = {
    "counters": {"dispatched": 0, "succeeded": 0, "failed": 0},
    "recent_failures": [],
    "recent_failures_capacity": 256,
    "recent_failures_evicted": 0,
}

# --- doc/2026-01-02_ndt_api.md §1, §2, §2b, §2c: the four link endpoints ----------------------
# [Co-developed with claude code -- Adam] -- Adam's ruling E-21, 2026-09-07.
# Every one of these is the documented example, copied. Where the document writes "..." for a
# value it does not spell out (qdisc_before/qdisc_after), a plausible string of the right type is
# used and nothing else is invented; where it does not print an example at all (§2c's tc entries)
# the shape is transcribed from utils::NetemLinkFault.hpp's restoreInterface, which builds them,
# and the fixture name says so.

#: §1 success on fix/w8-declared-link-failure-sticky and later.
LINK_FAILURE_REPORTED_SAMPLE = {
    "status": "link failure processed",
    "down_reason": "declared",
    "until": "/ndt/link_recovery_detected",
}

#: The same endpoint on trunk. The document states this in as many words: "A kernel built from
#: trunk answers {"status": "link failure processed"} alone." It must pass the STRUCTURAL check --
#: the two keys are optional -- and be caught by the invariant, which is the split this pair pins.
LINK_FAILURE_REPORTED_TRUNK = {"status": "link failure processed"}

#: §2 success, the paired withdrawal.
LINK_RECOVERY_APPLIED_SAMPLE = {"status": "link recovery processed"}

#: §2 declining an injected declaration -- the shape E-21 is about. Copied from the document's
#: "Success, but nothing was withdrawn" block, and measured on the wire in arm lw8b3
#: (2026-09-07 20:26:47, s1:1 -> s5:1, edge still is_up=false afterwards).
LINK_RECOVERY_DECLINED_SAMPLE = {
    "status": "link recovery processed",
    "declaration_retained": True,
    "detail": "a link failure is declared for this link and nothing ever reported it broken, so "
              "this recovery report did not withdraw it and the link is still down. That is what "
              "an injected failure surviving a control-plane restart looks like. Withdraw it with "
              "POST /ndt/inject_link_recovery",
    "until": "/ndt/inject_link_recovery",
}

#: §2b success on MININET.
LINK_FAILURE_INJECTED_SAMPLE = {
    "status": "link failure injected",
    "down_reason": "declared",
    "until": "/ndt/inject_link_recovery",
    "tc": [
        {"interface": "s1-eth1", "ok": True, "attached_at": "parent 5:0x1",
         "command": "qdisc add dev s1-eth1 parent 5:0x1 netem loss 100%",
         "qdisc_before": "qdisc htb 5: root refcnt 2",
         "qdisc_after": "qdisc netem 10: parent 5:1 limit 1000 loss 100%"},
        {"interface": "s5-eth1", "ok": True, "attached_at": "root",
         "command": "qdisc add dev s5-eth1 root netem loss 100%",
         "qdisc_before": "qdisc noqueue 0: root refcnt 2",
         "qdisc_after": "qdisc netem 8001: root refcnt 2 limit 1000 loss 100%"},
    ],
}

#: §2b on anything that is not MININET. There is no way for the twin to cut a physical cable and
#: a reply that did not say so would let a caller believe the packets had stopped.
LINK_FAILURE_INJECTED_NOT_MININET = {
    "status": "link failure injected",
    "down_reason": "declared",
    "until": "/ndt/inject_link_recovery",
    "tc": "skipped (not MININET)",
}

#: §2c. The document prints `{"status":"link recovery injected","tc":[ ... ]}` and describes the
#: entries in prose; the two shown here are the two restoreInterface() actually builds -- one that
#: removed a netem, one that found none and reports the documented idempotent "noop".
LINK_RECOVERY_INJECTED_SAMPLE = {
    "status": "link recovery injected",
    "tc": [
        {"interface": "s1-eth1", "ok": True, "detached_at": "parent 5:1",
         "command": "qdisc del dev s1-eth1 parent 5:1",
         "qdisc_before": "qdisc netem 10: parent 5:1 limit 1000 loss 100%",
         "qdisc_after": "qdisc htb 5: root refcnt 2"},
        {"interface": "s5-eth1", "ok": True,
         "noop": "no netem qdisc is attached to this interface",
         "qdisc_before": "qdisc noqueue 0: root refcnt 2"},
    ],
}

FIXTURES = {
    "get_graph_data": (spec.GRAPH_DATA, GRAPH_DATA_SAMPLE),
    "get_detected_flow_data": (spec.List(spec.FLOW_RECORD), FLOW_DATA_SAMPLE),
    "get_detected_top_k_flow_data": (spec.List(spec.FLOW_RECORD), FLOW_DATA_SAMPLE),
    "get_switch_openflow_table_entries": (spec.OF_TABLES, OF_TABLES_SAMPLE),
    "get_power_report": (
        spec.List(spec.Obj({"dpid": spec.Int(min=0), "power_consumed": Num()})),
        POWER_REPORT_SAMPLE),
    # [Co-developed with claude code -- Adam] -- Q12, Adam's ruling (a) of 2026-09-03.
    # The sample is the NEW shape, because --self-test's job is "prove the schemas accept what
    # the kernel emits" and this is what it emits now. The scalar branch stays in the schema for
    # a kernel that predates the split; it has its own case in tests/python/test_contract_spec.py
    # rather than a second sample here, because a fixture map is keyed by endpoint.
    "get_switches_power_state": (
        MapOf(OneOf(Str(), spec.Obj({"admin_state": Str(allowed=("on", "off")),
                                     "reachable": spec.Bool()})),
              key_check=is_ipv4_string),
        {"10.10.10.10": {"admin_state": "on", "reachable": True}}),
    # [Co-developed with claude code -- Adam]
    # min=-1, matching spec.py. These fixtures carry their own copy of each schema rather than
    # reading spec.py's, and this copy had drifted narrower than the one the contract test
    # actually runs: spec.py:502 is Num(min=-1, max=100) with a comment explaining that -1 is
    # the documented "unavailable" sentinel, while this said min=0 and would have rejected it.
    # A self-test whose purpose is "prove the schemas accept what the kernel documents" cannot
    # do that against a schema the kernel does not use.
    #
    # The samples now carry a -1 as well, so --self-test exercises the sentinel instead of
    # merely tolerating it. It is no longer a rare case: since the F-1 fix, MININET mode reports
    # -1 for every switch on all three endpoints rather than inventing a figure.
    # Pinned by tests/python/test_unavailable_metric_sentinel.py.
    "get_cpu_utilization": (
        MapOf(Num(min=-1, max=100), key_check=is_ipv4_string),
        {"10.10.10.10": 1, "10.10.10.3": 1, "10.10.10.4": 1, "10.10.10.9": -1}),
    "get_memory_utilization": (
        MapOf(Num(min=-1, max=100), key_check=is_ipv4_string),
        {"10.10.10.10": 28, "10.10.10.3": 27, "10.10.10.9": -1}),
    # Mixed int/string values are intentional: the kernel explains why a reading is absent by
    # model, and reports the numeric sentinel when it has no reading at all. The down switch is
    # -1 here, not "The switch is down." -- spec.py:511-513 records that no current build emits
    # that string, so keeping it as the only unavailable case pinned a shape that is gone.
    "get_temperature": (
        MapOf(OneOf(Num(), Str()), key_check=is_ipv4_string),
        {"10.10.10.15": "The temperature function only supports the HPE 5520.",
         "10.10.10.16": 29, "10.10.10.17": -1}),
    "get_average_link_usage": (
        spec.Obj({"status": Str(), "avg_link_usage": Num()}),
        {"status": "success", "avg_link_usage": 0.12}),
    "get_path_switch_count": (
        spec.Obj({"status": Str(), "src_ip": Str(), "dst_ip": Str(),
                  "switch_count": spec.Int(min=0)}),
        {"status": "success", "src_ip": "10.0.0.1", "dst_ip": "10.0.0.2",
         "switch_count": 1}),
    "get_num_of_flows_passing_a_switch": (
        spec.Obj({"status": Str(), "num_of_flows": spec.Int(min=0)}),
        {"status": "success", "num_of_flows": 42}),
    "get_total_input_traffic_load_passing_a_switch": (
        spec.Obj({"status": Str(), "total_input_traffic_load_bps": Num(min=0)}),
        {"status": "success", "total_input_traffic_load_bps": 12345678}),
    "get_nickname": (spec.Obj({"nickname": Str()}), {"nickname": "Main-Web-Server"}),
    "acquire_lock": (
        spec.Obj({"status": Str()}, optional={"type": Str(), "ttl": spec.Int()}),
        {"status": "locked", "type": "routing_lock", "ttl": 30}),
    "release_lock": (
        spec.Obj({"status": Str()}, optional={"type": Str()}),
        {"status": "released", "type": "routing_lock"}),
    "install_flow_entry": (spec.STATUS_OK, {"status": "Flow installed"}),
    "modify_nickname": (
        spec.Obj({"status": Str()}, optional={"message": Str()}),
        {"status": "success", "message": "Nickname updated successfully."}),
    "get_openflow_capacity": (Any_(), {"anything": True}),
    # [Co-developed with claude code -- Adam]
    # Not from doc/2026-01-02_ndt_api.md -- that document predates the endpoint. This is the
    # body HttpSession::handleGetFlowDispatchStatus builds, transcribed field by field from
    # src/ndt_core/http/HttpSession.cpp, with a failure record taken from the shape recorded
    # live in doc/audit/2026-08-30_a7-dispatch-visibility (a rule naming a nonexistent port).
    #
    # controller_status is 200 on purpose and it is not a typo: the P4 proxy answers HTTP 200
    # with an error body when a write fails, so this field has no discriminative power in P4
    # mode. Encoding the real value here stops anyone "fixing" the fixture to a 4xx and then
    # writing a check that the live system can never satisfy.
    "get_flow_dispatch_status": (spec.DISPATCH_STATUS, DISPATCH_STATUS_SAMPLE),
    "get_flow_dispatch_status (kernel without the A-7 follow-up fields)": (
        spec.DISPATCH_STATUS, DISPATCH_STATUS_OLDER_KERNEL),
    # --- E-21: the four link endpoints -------------------------------------------------------
    "link_failure_detected": (spec.LINK_FAILURE_REPORTED, LINK_FAILURE_REPORTED_SAMPLE),
    "link_failure_detected (kernel from trunk, no down_reason/until)": (
        spec.LINK_FAILURE_REPORTED, LINK_FAILURE_REPORTED_TRUNK),
    "link_recovery_detected (withdrawn)": (
        spec.LINK_RECOVERY_REPORTED, LINK_RECOVERY_APPLIED_SAMPLE),
    "link_recovery_detected (declined: declaration_retained)": (
        spec.LINK_RECOVERY_REPORTED, LINK_RECOVERY_DECLINED_SAMPLE),
    "inject_link_failure (MININET)": (
        spec.LINK_FAILURE_INJECTED, LINK_FAILURE_INJECTED_SAMPLE),
    "inject_link_failure (tc skipped, not MININET)": (
        spec.LINK_FAILURE_INJECTED, LINK_FAILURE_INJECTED_NOT_MININET),
    "inject_link_recovery": (
        spec.LINK_RECOVERY_INJECTED, LINK_RECOVERY_INJECTED_SAMPLE),
    "link request body (all four endpoints take the same one)": (
        spec.LINK_REQUEST,
        {"src_dpid": 106225808402492, "src_interface": 23,
         "dst_dpid": 106225808387660, "dst_interface": 23}),
}


class FakeCtx:
    """Stands in for the topology-derived Context during self-test."""

    def __init__(self, switches=2, hosts=1, edges=1, dpids=None, topk=5, power_state=None):
        self.expected_switches = switches
        self.expected_hosts = hosts
        self.expected_edges = edges
        self.expected_dpids = dpids if dpids is not None else {106225808380928}
        self.topk = topk
        # [Co-developed with claude code -- Adam] -- A-8.
        # A *positive* reading that nothing is powered off, so the switch/edge cases below
        # still assert what they were written to assert: a down switch on a fully powered-on
        # fabric is a real failure. Leaving this unset would make them assert the
        # precondition path instead, which is a different claim wearing the same red.
        self.power_state = power_state if power_state is not None else PowerState.all_on()


# A graph matching FakeCtx exactly, used as the "good" case.
_GOOD_CTX = FakeCtx(switches=1, hosts=1, edges=1, dpids={106225808380928})

# Same graph but with the switch marked down / not enabled.
_GRAPH_SWITCH_DOWN = {
    "nodes": [
        {**GRAPH_DATA_SAMPLE["nodes"][0], "is_up": False, "is_enabled": False},
        GRAPH_DATA_SAMPLE["nodes"][1],
    ],
    "edges": GRAPH_DATA_SAMPLE["edges"],
}

_GRAPH_EDGE_DOWN = {
    "nodes": GRAPH_DATA_SAMPLE["nodes"],
    "edges": [{**GRAPH_DATA_SAMPLE["edges"][0], "is_up": False}],
}

# [Co-developed with claude code -- Adam] -- A-8.
# The same two graphs, read against a run that knows why they look that way. _GOOD_CTX asserts
# nothing is powered off, so above they are genuine failures; here the reading explains them.
_CTX_THAT_SWITCH_OFF = FakeCtx(switches=1, hosts=1, edges=1, dpids={106225808380928},
                               power_state=PowerState({106225808380928}))
_CTX_EDGE_SRC_OFF = FakeCtx(switches=1, hosts=1, edges=1, dpids={106225808380928},
                            power_state=PowerState({106225808402492}))
_CTX_POWER_UNKNOWN = FakeCtx(switches=1, hosts=1, edges=1, dpids={106225808380928},
                             power_state=PowerState.unknown("kernel returned HTTP 503"))

_GRAPH_OVER_CAPACITY = {
    "nodes": GRAPH_DATA_SAMPLE["nodes"],
    "edges": [{**GRAPH_DATA_SAMPLE["edges"][0],
               "link_bandwidth_usage_bps": 2_000_000_000,
               "link_bandwidth_utilization_percent": 200.0}],
}

_FLOWS_EMPTY_PATH = [{**FLOW_DATA_SAMPLE[0], "path": []}]
_FLOWS_ZERO_RATE = [{
    **FLOW_DATA_SAMPLE[0],
    "estimated_flow_sending_rate_bps_in_the_last_sec": 0,
    "estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot": 0,
}]
_TABLES_EMPTY = [{"dpid": 106225808402492, "flows": {"106225808402492": []}}]


# [Co-developed with claude code -- Adam]
# Samples that inv_flow_paths_non_empty must NOT report as a pass, because it examined nothing.
#
# `dst_ip` is in_addr::s_addr -- network byte order read as a native integer -- so the first octet is
# the low byte on a little-endian host. Built with a helper rather than hand-computed constants, so
# these cannot drift out of step with _is_routable_unicast's own arithmetic.
def _s_addr(dotted: str) -> int:
    a, b, c, d = (int(x) for x in dotted.split("."))
    return a | (b << 8) | (c << 16) | (d << 24)


def _flow_to(dotted: str, path: list) -> dict:
    return {**FLOW_DATA_SAMPLE[0], "dst_ip": _s_addr(dotted), "path": path}


#: The measured real case: a sampling window that caught only the host's own Avahi mDNS. The
#: exclusion of 224/4 exists because a real run failed on 192.168.123.16 -> 224.0.0.251, so this
#: sample is not hypothetical -- and with every flow filtered out, `bad` was empty and the invariant
#: reported success, indistinguishable from "every flow had a path".
_FLOWS_ALL_MULTICAST = [_flow_to("224.0.0.251", []), _flow_to("239.255.255.250", [])]
_FLOWS_ALL_BROADCAST = [_flow_to("255.255.255.255", [])]
_FLOWS_ALL_LINK_LOCAL = [_flow_to("169.254.13.7", [])]

#: One routable flow among the noise is enough to make the invariant meaningful again.
_FLOWS_MULTICAST_PLUS_GOOD = [_flow_to("224.0.0.251", []), _flow_to("10.0.0.4", [[1, 2], [2, 3]])]
_FLOWS_MULTICAST_PLUS_BAD = [_flow_to("224.0.0.251", []), _flow_to("10.0.0.4", [])]

# --- A-7 dispatch status: the bad shapes ------------------------------------------------------
# [Co-developed with claude code -- Adam]

#: record() counted a dispatch and then returned before classifying it, so the sum is short.
_DISPATCH_COUNTERS_OPEN = {**DISPATCH_STATUS_SAMPLE,
                           "counters": {"dispatched": 9, "succeeded": 1, "failed": 2}}

#: The ring holds failures the counter never counted -- the two disagree about what happened.
_DISPATCH_LISTS_MORE_THAN_COUNTED = {**DISPATCH_STATUS_SAMPLE,
                                     "counters": {"dispatched": 2, "succeeded": 1, "failed": 1}}

#: Eviction reported while the ring is nowhere near full: the bounded buffer is dropping records
#: for some reason other than being full, which is the silent-truncation shape one level down.
_DISPATCH_EVICTED_WHILE_NOT_FULL = {**DISPATCH_STATUS_SAMPLE, "recent_failures_evicted": 4}

#: A clean shutdown that refused four jobs. Arithmetic still closes, because those jobs were
#: never attempted and so are not among succeeded/failed.
_DISPATCH_CLEAN_SHUTDOWN_DROP = {
    **DISPATCH_STATUS_SAMPLE,
    "counters": {"dispatched": 3, "succeeded": 1, "failed": 2, "dropped_after_stop": 4},
}

#: The state A-7 is about: the queue is dead, install_flow_entry still answers 200 "queued".
_DISPATCH_STOPPED = {
    **DISPATCH_STATUS_SAMPLE,
    "dispatcher_running": False,
    "counters": {"dispatched": 3, "succeeded": 1, "failed": 2, "dropped_after_stop": 12},
}

# (name, invariant, data, ctx, expect_failures)
# Every invariant is checked both ways: silent on good data, loud on bad data.
INVARIANT_CASES = [
    ("graph_matches_topology: accepts matching graph",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, _GOOD_CTX, False),
    ("graph_matches_topology: catches wrong switch count",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, FakeCtx(switches=10, hosts=1,
     edges=1, dpids={106225808380928}), True),
    ("graph_matches_topology: catches missing dpid",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, FakeCtx(switches=1, hosts=1,
     edges=1, dpids={999}), True),

    ("all_switches_up: accepts healthy graph",
     spec.inv_all_switches_up, GRAPH_DATA_SAMPLE, _GOOD_CTX, False),
    ("all_switches_up: catches switch down / not enabled",
     spec.inv_all_switches_up, _GRAPH_SWITCH_DOWN, _GOOD_CTX, True),
    # [Co-developed with claude code -- Adam] -- A-8.
    ("all_switches_up: a switch the power state says is OFF is not a failure",
     spec.inv_all_switches_up, _GRAPH_SWITCH_DOWN, _CTX_THAT_SWITCH_OFF, False),
    ("all_switches_up: an unreadable power state is not a failure either",
     spec.inv_all_switches_up, _GRAPH_SWITCH_DOWN, _CTX_POWER_UNKNOWN, False),

    ("edges_enabled: accepts healthy edges",
     spec.inv_edges_enabled, GRAPH_DATA_SAMPLE, _GOOD_CTX, False),
    ("edges_enabled: catches a down edge",
     spec.inv_edges_enabled, _GRAPH_EDGE_DOWN, _GOOD_CTX, True),
    ("edges_enabled: a down edge incident to a powered-off switch is not a failure",
     spec.inv_edges_enabled, _GRAPH_EDGE_DOWN, _CTX_EDGE_SRC_OFF, False),

    ("link_bandwidth_sane: accepts usage below capacity",
     spec.inv_link_bandwidth_sane, GRAPH_DATA_SAMPLE, _GOOD_CTX, False),
    ("link_bandwidth_sane: catches usage above capacity",
     spec.inv_link_bandwidth_sane, _GRAPH_OVER_CAPACITY, _GOOD_CTX, True),

    ("flows_present: catches no flows while traffic runs",
     spec.inv_flows_present, [], _GOOD_CTX, True),
    ("flows_present: accepts flows",
     spec.inv_flows_present, FLOW_DATA_SAMPLE, _GOOD_CTX, False),

    ("flow_paths_non_empty: accepts populated path",
     spec.inv_flow_paths_non_empty, FLOW_DATA_SAMPLE, _GOOD_CTX, False),
    ("flow_paths_non_empty: catches empty path (the P4 Classifier gap)",
     spec.inv_flow_paths_non_empty, _FLOWS_EMPTY_PATH, _GOOD_CTX, True),
    # [Co-developed with claude code -- Adam]
    # A sample with nothing to check must FAIL, not pass. Before this the filter could empty the
    # candidate list entirely and the invariant reported success having examined zero flows.
    ("flow_paths_non_empty: refuses an all-multicast sample (checked nothing)",
     spec.inv_flow_paths_non_empty, _FLOWS_ALL_MULTICAST, _GOOD_CTX, True),
    ("flow_paths_non_empty: refuses an all-broadcast sample (checked nothing)",
     spec.inv_flow_paths_non_empty, _FLOWS_ALL_BROADCAST, _GOOD_CTX, True),
    ("flow_paths_non_empty: refuses an all-link-local sample (checked nothing)",
     spec.inv_flow_paths_non_empty, _FLOWS_ALL_LINK_LOCAL, _GOOD_CTX, True),
    ("flow_paths_non_empty: one routable flow among multicast noise is enough",
     spec.inv_flow_paths_non_empty, _FLOWS_MULTICAST_PLUS_GOOD, _GOOD_CTX, False),
    ("flow_paths_non_empty: still catches the bad one among multicast noise",
     spec.inv_flow_paths_non_empty, _FLOWS_MULTICAST_PLUS_BAD, _GOOD_CTX, True),

    ("flow_rates_nonzero: accepts non-zero rates",
     spec.inv_flow_rates_nonzero, FLOW_DATA_SAMPLE, _GOOD_CTX, False),
    ("flow_rates_nonzero: catches all-zero rates",
     spec.inv_flow_rates_nonzero, _FLOWS_ZERO_RATE, _GOOD_CTX, True),

    ("tables_non_empty: accepts populated table",
     spec.inv_tables_non_empty, OF_TABLES_SAMPLE, _GOOD_CTX, False),
    ("tables_non_empty: catches the [] stub",
     spec.inv_tables_non_empty, [], _GOOD_CTX, True),
    ("tables_non_empty: catches an empty per-switch table",
     spec.inv_tables_non_empty, _TABLES_EMPTY, _GOOD_CTX, True),

    ("topk_bounded: accepts k or fewer",
     spec.inv_topk_bounded, FLOW_DATA_SAMPLE, FakeCtx(topk=5), False),
    ("topk_bounded: catches more than k",
     spec.inv_topk_bounded, FLOW_DATA_SAMPLE * 6, FakeCtx(topk=5), True),

    ("power_covers_switches: accepts full coverage",
     spec.inv_power_covers_switches, POWER_REPORT_SAMPLE,
     FakeCtx(dpids={106225808391692, 106225808380928}), False),
    ("power_covers_switches: catches a missing switch",
     spec.inv_power_covers_switches, POWER_REPORT_SAMPLE,
     FakeCtx(dpids={106225808391692, 999}), True),

    ("avg_link_usage_range: accepts 0..100",
     spec.inv_avg_link_usage_range, {"status": "success", "avg_link_usage": 0.12},
     _GOOD_CTX, False),
    ("avg_link_usage_range: catches out-of-range",
     spec.inv_avg_link_usage_range, {"status": "success", "avg_link_usage": 150},
     _GOOD_CTX, True),

    ("power_state_values: accepts ON/OFF",
     spec.inv_power_state_values, {"10.0.0.1": "ON", "10.0.0.2": "OFF"}, _GOOD_CTX, False),
    ("power_state_values: catches an unexpected value",
     spec.inv_power_state_values, {"10.0.0.1": "MAYBE"}, _GOOD_CTX, True),

    ("util_map_covers_switches: accepts full coverage",
     spec.inv_util_map_covers_switches, {"10.0.0.1": 5, "10.0.0.2": 6},
     FakeCtx(switches=2), False),
    ("util_map_covers_switches: catches partial coverage",
     spec.inv_util_map_covers_switches, {"10.0.0.1": 5}, FakeCtx(switches=2), True),

    # --- A-7 dispatch status ------------------------------------------------------------------
    # [Co-developed with claude code -- Adam]
    ("dispatch_counters_close: accepts closed arithmetic",
     spec.inv_dispatch_counters_close, DISPATCH_STATUS_SAMPLE, _GOOD_CTX, False),
    ("dispatch_counters_close: catches dispatched ahead of the sum",
     spec.inv_dispatch_counters_close, _DISPATCH_COUNTERS_OPEN, _GOOD_CTX, True),
    ("dispatch_counters_close: catches more failures listed than counted",
     spec.inv_dispatch_counters_close, _DISPATCH_LISTS_MORE_THAN_COUNTED, _GOOD_CTX, True),
    ("dispatch_counters_close: catches eviction from a list that is not full",
     spec.inv_dispatch_counters_close, _DISPATCH_EVICTED_WHILE_NOT_FULL, _GOOD_CTX, True),
    # dropped_after_stop is disjoint from the sum. If it were folded in, this case -- a clean
    # shutdown that refused four jobs -- would be reported as a counting bug.
    ("dispatch_counters_close: a shutdown drop is not a counting error",
     spec.inv_dispatch_counters_close, _DISPATCH_CLEAN_SHUTDOWN_DROP, _GOOD_CTX, False),
    ("dispatch_counters_close: still checks a kernel without the newer fields",
     spec.inv_dispatch_counters_close, DISPATCH_STATUS_OLDER_KERNEL, _GOOD_CTX, False),

    ("dispatcher_is_running: accepts a live dispatcher",
     spec.inv_dispatcher_is_running, DISPATCH_STATUS_SAMPLE, _GOOD_CTX, False),
    ("dispatcher_is_running: catches a stopped dispatcher still answering 'queued'",
     spec.inv_dispatcher_is_running, _DISPATCH_STOPPED, _GOOD_CTX, True),
    ("dispatcher_is_running: says nothing about a kernel that lacks the field",
     spec.inv_dispatcher_is_running, DISPATCH_STATUS_OLDER_KERNEL, _GOOD_CTX, False),

    # --- E-21: the four link endpoints ---------------------------------------------------------
    # [Co-developed with claude code -- Adam]
    # Each invariant both ways, and the "bad" side of each one is a body a real kernel has
    # actually produced: the trunk answer to §1, and the unconditional withdrawal measured on arm
    # lw8b (2026-09-07 00:08, 9 of 9 samples).
    ("declared_failure_says_who_can_withdraw_it: accepts the branch's answer",
     spec.inv_declared_failure_says_who_can_withdraw_it,
     LINK_FAILURE_REPORTED_SAMPLE, _GOOD_CTX, False),
    ("declared_failure_says_who_can_withdraw_it: reports trunk's bare status",
     spec.inv_declared_failure_says_who_can_withdraw_it,
     LINK_FAILURE_REPORTED_TRUNK, _GOOD_CTX, True),
    ("declared_failure_says_who_can_withdraw_it: catches the wrong withdrawal endpoint",
     spec.inv_declared_failure_says_who_can_withdraw_it,
     {**LINK_FAILURE_REPORTED_SAMPLE, "until": "/ndt/inject_link_recovery"}, _GOOD_CTX, True),

    ("recovery_withdrew_the_declaration: accepts the paired withdrawal",
     spec.inv_recovery_withdrew_the_declaration,
     LINK_RECOVERY_APPLIED_SAMPLE, _GOOD_CTX, False),
    ("recovery_withdrew_the_declaration: catches a report the rule refused to spend",
     spec.inv_recovery_withdrew_the_declaration,
     LINK_RECOVERY_DECLINED_SAMPLE, _GOOD_CTX, True),

    ("recovery_was_declined_and_said_so: accepts the declined reply (the E-21 shape)",
     spec.inv_recovery_was_declined_and_said_so,
     LINK_RECOVERY_DECLINED_SAMPLE, _GOOD_CTX, False),
    # The lw8b failure mode: the injection was withdrawn by a report nothing paired with, and the
    # reply is the same bare 200 a legitimate withdrawal gives.
    ("recovery_was_declined_and_said_so: catches an injection withdrawn anyway",
     spec.inv_recovery_was_declined_and_said_so,
     LINK_RECOVERY_APPLIED_SAMPLE, _GOOD_CTX, True),
    ("recovery_was_declined_and_said_so: catches a decline that names no way out",
     spec.inv_recovery_was_declined_and_said_so,
     {"status": "link recovery processed", "declaration_retained": True,
      "detail": "..."}, _GOOD_CTX, True),

    ("tc_half_is_reported_per_interface: accepts both ends cut and named",
     spec.inv_tc_half_is_reported_per_interface,
     LINK_FAILURE_INJECTED_SAMPLE, _GOOD_CTX, False),
    ("tc_half_is_reported_per_interface: accepts the idempotent restore",
     spec.inv_tc_half_is_reported_per_interface,
     LINK_RECOVERY_INJECTED_SAMPLE, _GOOD_CTX, False),
    ("tc_half_is_reported_per_interface: a skipped half is accounted for, not failed",
     spec.inv_tc_half_is_reported_per_interface,
     LINK_FAILURE_INJECTED_NOT_MININET, _GOOD_CTX, False),
    ("tc_half_is_reported_per_interface: catches one end cut instead of two",
     spec.inv_tc_half_is_reported_per_interface,
     {**LINK_FAILURE_INJECTED_SAMPLE, "tc": LINK_FAILURE_INJECTED_SAMPLE["tc"][:1]},
     _GOOD_CTX, True),
    ("tc_half_is_reported_per_interface: catches a failure that does not say why",
     spec.inv_tc_half_is_reported_per_interface,
     {**LINK_FAILURE_INJECTED_SAMPLE,
      "tc": [{"interface": "s1-eth1", "ok": False},
             LINK_FAILURE_INJECTED_SAMPLE["tc"][1]]},
     _GOOD_CTX, True),
    ("tc_half_is_reported_per_interface: catches an ok that names no command",
     spec.inv_tc_half_is_reported_per_interface,
     {**LINK_FAILURE_INJECTED_SAMPLE,
      "tc": [{"interface": "s1-eth1", "ok": True},
             LINK_FAILURE_INJECTED_SAMPLE["tc"][1]]},
     _GOOD_CTX, True),
]
