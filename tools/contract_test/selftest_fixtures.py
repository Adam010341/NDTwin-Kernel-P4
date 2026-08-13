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
         "left_link_bandwidth_bps": 998396604, "link_bandwidth_bps": 1000000000,
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

FIXTURES = {
    "get_graph_data": (spec.GRAPH_DATA, GRAPH_DATA_SAMPLE),
    "get_detected_flow_data": (spec.List(spec.FLOW_RECORD), FLOW_DATA_SAMPLE),
    "get_detected_top_k_flow_data": (spec.List(spec.FLOW_RECORD), FLOW_DATA_SAMPLE),
    "get_switch_openflow_table_entries": (spec.OF_TABLES, OF_TABLES_SAMPLE),
    "get_power_report": (
        spec.List(spec.Obj({"dpid": spec.Int(min=0), "power_consumed": Num()})),
        POWER_REPORT_SAMPLE),
    "get_switches_power_state": (
        MapOf(Str(), key_check=is_ipv4_string), {"10.10.10.10": "ON"}),
    "get_cpu_utilization": (
        MapOf(Num(min=0, max=100), key_check=is_ipv4_string),
        {"10.10.10.10": 1, "10.10.10.3": 1, "10.10.10.4": 1, "10.10.10.9": 1}),
    "get_memory_utilization": (
        MapOf(Num(min=0, max=100), key_check=is_ipv4_string),
        {"10.10.10.10": 28, "10.10.10.3": 27}),
    # Mixed int/string values are intentional: the kernel explains why a reading is absent.
    "get_temperature": (
        MapOf(OneOf(Num(), Str()), key_check=is_ipv4_string),
        {"10.10.10.15": "The temperature function only supports the HPE 5520.",
         "10.10.10.16": 29, "10.10.10.17": "The switch is down."}),
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
}


class FakeCtx:
    """Stands in for the topology-derived Context during self-test."""

    def __init__(self, switches=2, hosts=1, edges=1, dpids=None, topk=5):
        self.expected_switches = switches
        self.expected_hosts = hosts
        self.expected_edges = edges
        self.expected_dpids = dpids if dpids is not None else {106225808380928}
        self.topk = topk


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

    ("edges_enabled: accepts healthy edges",
     spec.inv_edges_enabled, GRAPH_DATA_SAMPLE, _GOOD_CTX, False),
    ("edges_enabled: catches a down edge",
     spec.inv_edges_enabled, _GRAPH_EDGE_DOWN, _GOOD_CTX, True),

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
]
