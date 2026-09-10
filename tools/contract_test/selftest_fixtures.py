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
#
# [Co-developed with claude code -- Adam]
# W11 (#54), 2026-09-06: `succeeded`/`failed` are now `dispatched_ok`/`dispatch_failed`, and
# switch_outcome is the second group. The three switch-side numbers are not filled in at random --
# they are what THIS body's own failure records imply, so the fixture stays readable as one story:
# one dispatch succeeded on a plane that confirms nothing (unknown), one failed with the P4
# proxy's 200-plus-error-body, which is a switch-side refusal (rejected), and one failed with
# controller_status 0, which is nothing answering at all and therefore says nothing about a
# switch (unknown). 0 + 1 + 2 == dispatched.
DISPATCH_STATUS_SAMPLE = {
    "counters": {"dispatched": 3, "dispatched_ok": 1, "dispatch_failed": 2,
                 "dropped_after_stop": 0},
    "switch_outcome": {
        "accepted_by_switch": 0,
        "rejected_by_switch": 1,
        "unknown": 2,
        "why_unknown": "a count of jobs whose plane's reply is not evidence about any switch. "
                       "On the OVS/OpenFlow plane that is every job",
    },
    "renamed_keys": {"succeeded": "counters.dispatched_ok",
                     "failed": "counters.dispatch_failed"},
    "request_ids_tracked": 2,
    "request_ids_capacity": 256,
    "request_ids_forgotten": 0,
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

# [Co-developed with claude code -- Adam]
# W11. A kernel from between the A-7 follow-up and the 2026-09-06 rename: the follow-up fields are
# there, the counters still carry the old names, and there is no switch_outcome. The schema and
# inv_dispatch_counters_close must both still bite on it -- a contract that only understands the
# newest kernel cannot be pointed at the one that is deployed.
DISPATCH_STATUS_PRE_W11 = {
    "counters": {"dispatched": 3, "succeeded": 1, "failed": 2, "dropped_after_stop": 0},
    "dispatcher_running": True,
    "recent_failures": [],
    "recent_failures_capacity": 256,
    "recent_failures_evicted": 0,
    "counters_cover": {
        "dispatch_routes": ["/ndt/install_flow_entry"],
        "includes_boot_time_programming": False,
        "includes_intent_translator": False,
    },
}

# [Co-developed with claude code -- Adam]
# W11 / R6 K-4: GET /ndt/get_flow_dispatch_status?request_id=<id>. `complete` is False here on
# purpose -- 2 of the 3 jobs have come back -- because that is the state the process-wide body
# cannot express and the one a caller polling for its own result is actually in.
DISPATCH_STATUS_FOR_REQUEST_SAMPLE = {
    "request_id": 41,
    "enqueued": 3,
    "counters": {"dispatched": 2, "dispatched_ok": 2, "dispatch_failed": 0},
    "switch_outcome": {
        "accepted_by_switch": 0,
        "rejected_by_switch": 0,
        "unknown": 2,
        "why_unknown": "OpenFlow does not acknowledge a FLOW_MOD",
    },
    "complete": False,
    "dispatcher_running": True,
    "detail": "counters for this request only",
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

# --- doc/2026-01-02_ndt_api.md section 37: GET /ndt/get_openflow_capacity ---------------------
# [Co-developed with claude code -- Adam] W17. Trimmed to the fields the invariants read; the
# vendor blocks keep their catalogue numbers and say so, and the bmv2 block carries the three
# figures that have to close. 512 rather than 1024 on purpose -- see the note at the fixture.
OPENFLOW_CAPACITY_SAMPLE = {
    "OVS": {"source": "vendor table",
            "tables": [{"id": 0, "max_entries": 1000000}]},
    "BrocadeICX7250": {"source": "vendor table",
                       "tables": [{"id": 0, "max_entries": 3072}]},
    "HPE5520": {"source": "vendor table",
                "tables": [{"id": 0, "max_entries": 65535}]},
    "bmv2": {
        "plane": "bmv2",
        "source": "/home/adam/p4_src/build/ndtwin_switch.json max_size",
        "source_kind": "argv of a running bmv2 switch (pid 4242)",
        "flow_entry_table": "MyIngress.ipv4_lpm",
        "max_entries": 512,
        "tables": [{"name": "MyIngress.ipv4_lpm", "max_entries": 512},
                   {"name": "MyIngress.flow_5tuple", "max_entries": 512}],
        "per_switch": [{"dpid": 1, "max_entries": 512, "in_use": 128, "available": 384},
                       {"dpid": 2, "max_entries": 512, "in_use": 128, "available": 384}],
        "note": "max_entries is the compiled pipeline's own max_size ...",
    },
}


def _endpoint_schema(endpoint_name):
    """spec.py's own schema object for `endpoint_name`, so no copy of it can drift.

    [Co-developed with claude code -- Adam] -- G2. Several entries below hold a private copy
    deliberately (an older kernel's shape, a narrower sample); this is for the ones that have
    no reason to.
    """
    for endpoint in spec.ENDPOINTS:
        if endpoint["name"] == endpoint_name:
            return endpoint["schema"]
    raise KeyError(f"no endpoint named {endpoint_name!r} in spec.ENDPOINTS")


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
    # [Co-developed with claude code -- Adam]
    # F-OFFLINE-1 G2, 2026-09-11. This was `(spec.STATUS_OK, {"status": "Flow installed"})` --
    # a private copy of the schema, one required field short of the endpoint's, and a sample no
    # kernel has emitted since the dispatcher became asynchronous. --self-test printed
    # "ok install_flow_entry" for a body the live run rejects on structure, which is the one
    # thing a self-test whose purpose is "the schemas accept what the kernel documents" must not
    # do. Now the endpoint's own schema object and doc/2026-01-02_ndt_api.md 9's success body,
    # verbatim, so `queued` also exercises inv_flow_write_is_honest_about_being_queued.
    # Pinned by tests/python/test_contract_spec.py::SelftestFixturesMatchTheEndpointTable.
    "install_flow_entry": (
        _endpoint_schema("install_flow_entry"),
        {"status": "queued", "accepted": 1,
         "detail": "entries accepted for programming; per-entry outcomes are reported in the "
                   "kernel log and, since they are not in this response, are readable "
                   "afterwards from GET /ndt/get_flow_dispatch_status"}),
    "modify_nickname": (
        spec.Obj({"status": Str()}, optional={"message": Str()}),
        {"status": "success", "message": "Nickname updated successfully."}),
    # [Co-developed with claude code -- Adam] W17. The sample is the shape the kernel emits
    # now: a vendor block that says it is a vendor block, and a bmv2 block whose ceiling came
    # from a pipeline artifact. The ceiling here is 512, not the 1024 this repository's own
    # artifact carries, for the same reason the C++ fixtures avoid 1024 -- a sample that happens
    # to match the one true answer cannot tell a read from a constant.
    "get_openflow_capacity": (Any_(), OPENFLOW_CAPACITY_SAMPLE),
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
    # [Co-developed with claude code -- Adam] W11: both sides of the 2026-09-06 rename, because
    # one schema has to describe a deployed kernel as well as a freshly built one.
    "get_flow_dispatch_status (kernel from before the W11 rename)": (
        spec.DISPATCH_STATUS, DISPATCH_STATUS_PRE_W11),
    "get_flow_dispatch_status?request_id=<id>": (
        spec.DISPATCH_STATUS_FOR_REQUEST, DISPATCH_STATUS_FOR_REQUEST_SAMPLE),

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

# [Co-developed with claude code -- Adam]
# F-OFFLINE-1 G2/G13, 2026-09-11. Which endpoint each fixture above is an example FOR.
#
# 17 of the 31 fixtures carry a private copy of the schema rather than spec.py's object, and one
# of the 17 had drifted: `install_flow_entry` described `{"status": ...}` alone while the endpoint
# has required `accepted` since 2026-09-06, so the self-test was proving a schema nothing runs.
# A copy is not the defect -- several are deliberate, and the reasons are written above each one
# -- but a copy nobody compares is, so tests/python/test_contract_spec.py cross-checks every
# sample here against the schema the contract test actually validates with. This function is the
# join that check needs.
#
# 🔴 The join used to be guessable and that is why nothing checked it. Reading the key as an
# endpoint name resolves 22 of 31; the other 9 look like fixtures for endpoints that do not
# exist, which is how the offline round came to count them that way. They are variants -- one
# endpoint, several kernels or several outcomes -- and the convention below is the whole of it:
#
#   <endpoint name>                     the endpoint's documented success body
#   <endpoint name> (<note>)            the same endpoint, another kernel or another outcome
#
# with the three exceptions listed. A query-string suffix is deliberately NOT part of the
# convention: the one fixture that carries one answers with a DIFFERENT shape from its base
# endpoint, so stripping it would apply the wrong schema and call that a pass. Guessing is
# confined to the convention; every case the convention gets wrong is written down here rather
# than left to be rediscovered by counting.
#
# A value of (None, reason) means "this shape has no endpoint, and here is why" -- a declared
# exception, not an unresolved name.
FIXTURE_TARGET_OVERRIDES = {
    # Step 4 of the link sequence, not step 2: the DECLINED reply belongs to the endpoint that
    # answers an injection nothing paired with. Resolving it by name attributes it to step 2,
    # whose invariant then reports a correctly declined recovery as a failure.
    "link_recovery_detected (declined: declaration_retained)":
        ("link_recovery_detected__declined_after_injection", "schema"),
    # The only fixture here that is a REQUEST rather than a response. All four link endpoints
    # take it; the first one is named so the cross-check has a `request_schema` to reach.
    "link request body (all four endpoints take the same one)":
        ("link_failure_detected", "request_schema"),
    # No endpoint by design, and the design is upstream of this file: obtaining a request_id
    # means POSTing a flow batch, which is a mutation, and this endpoint's value is that it is
    # safe to read on a live fabric (see DISPATCH_STATUS_FOR_REQUEST in spec.py). The shape is
    # carried here so a reader learns it; it must not be validated against the unparameterised
    # endpoint, whose reply has three required fields this one does not.
    "get_flow_dispatch_status?request_id=<id>":
        (None, "the parameterised form is not registered as a probe: reading it needs a "
               "request_id, and getting one is a mutation"),
}


def fixture_target(fixture_name):
    """
    (endpoint name, "schema" | "request_schema") for a key of FIXTURES, or (None, why).

    [Co-developed with claude code -- Adam] -- G2/G13.
    """
    if fixture_name in FIXTURE_TARGET_OVERRIDES:
        return FIXTURE_TARGET_OVERRIDES[fixture_name]
    base = fixture_name
    if base.endswith(")") and "(" in base:
        base = base[:base.rindex("(")]
    base = base.strip()
    if any(ep["name"] == base for ep in spec.ENDPOINTS):
        return base, "schema"
    return None, (f"{fixture_name!r} does not name an endpoint: it reads as {base!r}, which is "
                  f"not in spec.ENDPOINTS. Rename it to '<endpoint> (<note>)' or add it to "
                  f"FIXTURE_TARGET_OVERRIDES with the reason")


class FakeCtx:
    """Stands in for the topology-derived Context during self-test."""

    def __init__(self, switches=2, hosts=1, edges=1, dpids=None, topk=5, power_state=None,
                 switch_identity=None, host_identity=None):
        self.expected_switches = switches
        self.expected_hosts = hosts
        self.expected_edges = edges
        self.expected_dpids = dpids if dpids is not None else {106225808380928}
        self.topk = topk
        # [Co-developed with claude code -- Adam] -- W3b-3.
        # Per-node identity, defaulting to None = "this stand-in has only cardinalities". The
        # real Context (run_contract_test.py) always builds both, so None is never the
        # production answer -- pinned in tests/python/test_contract_spec.py. Cases that want
        # the identity checks pass GOOD_IDENTITY below, or a deliberately wrong version of it.
        self.expected_switch_identity = switch_identity
        self.expected_host_identity = host_identity
        # [Co-developed with claude code -- Adam] -- A-8.
        # A *positive* reading that nothing is powered off, so the switch/edge cases below
        # still assert what they were written to assert: a down switch on a fully powered-on
        # fabric is a real failure. Leaving this unset would make them assert the
        # precondition path instead, which is a different claim wearing the same red.
        self.power_state = power_state if power_state is not None else PowerState.all_on()


# A graph matching FakeCtx exactly, used as the "good" case.
_GOOD_CTX = FakeCtx(switches=1, hosts=1, edges=1, dpids={106225808380928})

# [Co-developed with claude code -- Adam] -- W3b-3.
# The identity GRAPH_DATA_SAMPLE really carries, derived from the sample itself rather than
# transcribed: a hand-typed copy would be a second chance to get the address decoding wrong,
# and the decoding is the part of this comparison that is easy to get wrong (network order --
# the FIRST octet is the LOW byte).
_GOOD_SWITCH_IDENTITY = {
    n["dpid"]: {"device_name": n["device_name"], "brand_name": n["brand_name"],
                "ips": spec.address_set(n)}
    for n in GRAPH_DATA_SAMPLE["nodes"] if n["vertex_type"] == 0}
_GOOD_HOST_IDENTITY = {
    n["mac"]: {"device_name": n["device_name"], "ips": spec.address_set(n)}
    for n in GRAPH_DATA_SAMPLE["nodes"] if n["vertex_type"] == 1}
_IDENTITY_CTX = FakeCtx(switches=1, hosts=1, edges=1, dpids={106225808380928},
                        switch_identity=_GOOD_SWITCH_IDENTITY,
                        host_identity=_GOOD_HOST_IDENTITY)
#: The one field that decides power and telemetry dispatch, changed and nothing else.
_WRONG_BRAND_CTX = FakeCtx(
    switches=1, hosts=1, edges=1, dpids={106225808380928},
    switch_identity={d: {**v, "brand_name": "BMv2"}
                     for d, v in _GOOD_SWITCH_IDENTITY.items()},
    host_identity=_GOOD_HOST_IDENTITY)
#: One switch address changed. Same count, same dpid: invisible to everything above.
_WRONG_SWITCH_IP_CTX = FakeCtx(
    switches=1, hosts=1, edges=1, dpids={106225808380928},
    switch_identity={d: {**v, "ips": frozenset({"10.10.10.99"})}
                     for d, v in _GOOD_SWITCH_IDENTITY.items()},
    host_identity=_GOOD_HOST_IDENTITY)
#: The host is a different host: right count, right dpid (0, like every host), wrong mac.
_WRONG_HOST_MAC_CTX = FakeCtx(
    switches=1, hosts=1, edges=1, dpids={106225808380928},
    switch_identity=_GOOD_SWITCH_IDENTITY,
    host_identity={12345: {"device_name": "h9", "ips": frozenset({"10.0.0.9"})}})
#: A rename, which persists by design -- reported, never failed.
_RENAMED_CTX = FakeCtx(
    switches=1, hosts=1, edges=1, dpids={106225808380928},
    switch_identity={d: {**v, "device_name": "core-4"}
                     for d, v in _GOOD_SWITCH_IDENTITY.items()},
    host_identity=_GOOD_HOST_IDENTITY)

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

# --- W11 (#54): the switch-side group ----------------------------------------------------------
# [Co-developed with claude code -- Adam]

#: The group stops partitioning the same jobs -- one dispatch is in no bucket at all, which is
#: what a record() that returned early on some op would produce.
_SWITCH_OUTCOME_OPEN = {
    **DISPATCH_STATUS_SAMPLE,
    "switch_outcome": {**DISPATCH_STATUS_SAMPLE["switch_outcome"], "unknown": 1},
}

#: The failure this group exists to prevent: dispatched_ok stood in for a switch's acceptance, so
#: an OVS fabric reports every dispatch as confirmed. Caught by direction rather than by knowing
#: which plane it is -- an acceptance count above the successful dispatches is impossible either way.
_SWITCH_OUTCOME_BORROWED_FROM_DISPATCH = {
    **DISPATCH_STATUS_SAMPLE,
    "switch_outcome": {**DISPATCH_STATUS_SAMPLE["switch_outcome"],
                       "accepted_by_switch": 3, "unknown": 0, "rejected_by_switch": 0},
}

#: The number without its reason. On OVS `unknown` equals `dispatched` for good and always will,
#: so a body that publishes the count and drops the explanation hands the reader a permanent
#: "nothing to see here".
_SWITCH_OUTCOME_UNEXPLAINED = {
    **DISPATCH_STATUS_SAMPLE,
    "switch_outcome": {**DISPATCH_STATUS_SAMPLE["switch_outcome"], "why_unknown": "   "},
}

#: The state A-7 is about: the queue is dead, install_flow_entry still answers 200 "queued".
_DISPATCH_STOPPED = {
    **DISPATCH_STATUS_SAMPLE,
    "dispatcher_running": False,
    "counters": {"dispatched": 3, "succeeded": 1, "failed": 2, "dropped_after_stop": 12},
}

# (name, invariant, data, ctx, expect_failures)
# Every invariant is checked both ways: silent on good data, loud on bad data.
# [Co-developed with claude code -- Adam] W17.
_CAPACITY_UNSOURCED = {
    "OVS": {"tables": [{"id": 0, "max_entries": 1000000}]},
}

_CAPACITY_BROKEN_SUM = {
    "bmv2": {
        "plane": "bmv2",
        "source": "/p4/build/ndtwin_switch.json max_size",
        "max_entries": 512,
        "per_switch": [{"dpid": 1, "max_entries": 512, "in_use": 128, "available": 512}],
    },
}

_CAPACITY_UNPOLLED = {
    "OVS": {"source": "vendor table", "tables": [{"id": 0, "max_entries": 1000000}]},
    "bmv2": {
        "plane": "bmv2",
        "source": "/p4/build/ndtwin_switch.json max_size",
        "max_entries": 512,
        "per_switch": [{"dpid": 1, "max_entries": 512, "in_use": None, "available": None,
                        "why": "not polled yet"}],
    },
}

INVARIANT_CASES = [
    ("graph_matches_topology: accepts matching graph",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, _GOOD_CTX, False),
    ("graph_matches_topology: catches wrong switch count",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, FakeCtx(switches=10, hosts=1,
     edges=1, dpids={106225808380928}), True),
    ("graph_matches_topology: catches missing dpid",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, FakeCtx(switches=1, hosts=1,
     edges=1, dpids={999}), True),

    # [Co-developed with claude code -- Adam] -- W3b-3. Per-node identity. Every ctx below has
    # the SAME counts and the SAME dpid as the good one, so anything these catch is something
    # the cardinality checks above cannot see.
    ("graph_matches_topology: a graph that matches node for node reports nothing",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, _IDENTITY_CTX, False),
    ("graph_matches_topology: catches a switch served under the wrong brand",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, _WRONG_BRAND_CTX, True),
    ("graph_matches_topology: catches a switch served with the wrong address",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, _WRONG_SWITCH_IP_CTX, True),
    ("graph_matches_topology: catches a different host behind the right host count",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, _WRONG_HOST_MAC_CTX, True),
    ("graph_matches_topology: a renamed device is accounted for, not failed",
     spec.inv_graph_matches_topology, GRAPH_DATA_SAMPLE, _RENAMED_CTX, False),

    # [Co-developed with claude code -- Adam] W17.
    ("capacity_names_its_source: accepts a fully labelled report",
     spec.inv_capacity_names_its_source, OPENFLOW_CAPACITY_SAMPLE, _GOOD_CTX, False),
    ("capacity_names_its_source: catches a block with no provenance",
     spec.inv_capacity_names_its_source, _CAPACITY_UNSOURCED, _GOOD_CTX, True),
    ("capacity_available_closes: accepts max - in_use",
     spec.inv_capacity_available_closes, OPENFLOW_CAPACITY_SAMPLE, _GOOD_CTX, False),
    ("capacity_available_closes: catches available that does not close",
     spec.inv_capacity_available_closes, _CAPACITY_BROKEN_SUM, _GOOD_CTX, True),
    ("capacity_available_closes: an unpolled switch is not a failure",
     spec.inv_capacity_available_closes, _CAPACITY_UNPOLLED, _GOOD_CTX, False),

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

    # --- W11 (#54): the switch-side group -----------------------------------------------------
    # [Co-developed with claude code -- Adam]
    ("switch_outcome_closes: accepts a group that partitions the dispatches",
     spec.inv_switch_outcome_closes, DISPATCH_STATUS_SAMPLE, _GOOD_CTX, False),
    ("switch_outcome_closes: catches a dispatch in no bucket",
     spec.inv_switch_outcome_closes, _SWITCH_OUTCOME_OPEN, _GOOD_CTX, True),
    ("switch_outcome_closes: catches acceptance borrowed from dispatched_ok",
     spec.inv_switch_outcome_closes, _SWITCH_OUTCOME_BORROWED_FROM_DISPATCH, _GOOD_CTX, True),
    ("switch_outcome_closes: catches an unknown count with no reason beside it",
     spec.inv_switch_outcome_closes, _SWITCH_OUTCOME_UNEXPLAINED, _GOOD_CTX, True),
    ("switch_outcome_closes: says nothing about a kernel that predates the group",
     spec.inv_switch_outcome_closes, DISPATCH_STATUS_PRE_W11, _GOOD_CTX, False),

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
