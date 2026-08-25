"""
Contract definitions for every /ndt/* endpoint the kernel registers.

Three kinds of check per endpoint, matching doc/2026-07-27_testing_workflow.md's L2 layer:

  1. structure  -- the response is valid JSON with the right fields and types
  2. invariants -- the values make sense together (10 switches, all up, paths non-empty)
  3. error path -- bad input yields a sane 4xx, not a 500 and not a fake success

Shapes are taken from doc/2026-01-02_ndt_api.md and cross-checked against the dispatch table in
src/ndt_core/http/HttpSession.cpp. Endpoint names/methods here are the kernel's actual
registrations, which is why a few appear that 2026-01-02_ndt_api.md does not document.

[Co-developed with claude code -- Adam]
"""

from __future__ import annotations

from schema import (
    Any_,
    Bool,
    Int,
    List,
    MapOf,
    Num,
    Obj,
    OneOf,
    Str,
    is_decimal_string,
    is_ipv4_string,
)

# --- categories -------------------------------------------------------------------
READ = "read"        # safe: never changes network state
MUTATE = "mutate"    # changes flow rules / power / names; needs --allow-mutations
ERRORPATH = "error"  # deliberately bad input; asserts a sane failure

# Lock type used by the lock checks. Must be one the kernel accepts
# (routing_lock / graph_lock / power_lock) or acquireLock rejects it outright.
# graph_lock is real but unused by every app in the workspace, so these checks get real
# mutual-exclusion semantics with no risk of disturbing a running application.
LOCK_TYPE = "graph_lock"
LOCK_TTL = 5

# --- reusable sub-schemas ---------------------------------------------------------

# ip is a list because a node may have several addresses (see get_graph_data docs).
# Bounded to uint32: the kernel stores IPv4 in network order as uint32, so a value above
# 0xFFFFFFFF means something overflowed or a field was misread.
UINT32_MAX = 0xFFFFFFFF
IP_LIST = List(Int(min=0, max=UINT32_MAX))

FLOW_KEY = Obj({
    "src_ip": Int(min=0, max=UINT32_MAX),
    "dst_ip": Int(min=0, max=UINT32_MAX),
    "src_port": Int(min=0, max=65535),
    "dst_port": Int(min=0, max=65535),
    "protocol_number": Int(min=0, max=255),
})

GRAPH_NODE = Obj({
    "device_name": Str(),
    "dpid": Int(min=0),
    "ip": IP_LIST,
    "is_enabled": Bool(),
    "is_up": Bool(),
    "mac": Int(min=0),
    "vertex_type": Int(min=0, max=1),   # 0 = switch, 1 = host
    "brand_name": Str(),
    "device_layer": Int(),
}, optional={"nickname": Str()})

GRAPH_EDGE = Obj({
    "src_dpid": Int(min=0),
    "dst_dpid": Int(min=0),
    "src_interface": Int(min=0),
    "dst_interface": Int(min=0),
    "src_ip": IP_LIST,
    "dst_ip": IP_LIST,
    "is_enabled": Bool(),
    "is_up": Bool(),
    "link_bandwidth_bps": Int(min=0),
    "link_bandwidth_usage_bps": Num(min=0),
    "link_bandwidth_utilization_percent": Num(min=0),
    "flow_set": List(FLOW_KEY),
}, optional={"left_link_bandwidth_bps": Num()})

GRAPH_DATA = Obj({"nodes": List(GRAPH_NODE, min_len=1), "edges": List(GRAPH_EDGE)})

PATH_HOP = Obj({"node": Int(min=0), "interface": Int(min=0)})

FLOW_RECORD = Obj({
    "src_ip": Int(min=0, max=UINT32_MAX),
    "dst_ip": Int(min=0, max=UINT32_MAX),
    "src_port": Int(min=0, max=65535),
    "dst_port": Int(min=0, max=65535),
    "protocol_id": Int(min=0, max=255),
    "estimated_flow_sending_rate_bps_in_the_last_sec": Num(min=0),
    "estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot": Num(min=0),
    "estimated_packet_rate_in_the_last_sec": Num(min=0),
    "estimated_packet_rate_in_the_proceeding_1sec_timeslot": Num(min=0),
    "first_sampled_time": Str(nonempty=True),
    "latest_sampled_time": Str(nonempty=True),
    "path": List(PATH_HOP),
})

# Ryu /stats/flow shape. actions are STRINGS ("OUTPUT:1") -- Classifier.cpp parses only
# the string form and silently ignores {"type":"OUTPUT","port":N}, so this is a real
# contract requirement for the P4 proxy, not a formatting preference.
OF_FLOW_ENTRY = Obj({
    "actions": List(Str()),
    "match": Obj({}, strict=False),
    "priority": Int(),
    "table_id": Int(min=0),
}, optional={
    "byte_count": Int(min=0), "packet_count": Int(min=0), "cookie": Int(),
    "duration_sec": Int(min=0), "duration_nsec": Int(min=0), "flags": Int(),
    "hard_timeout": Int(min=0), "idle_timeout": Int(min=0), "length": Int(min=0),
})

OF_TABLES = List(Obj({
    "dpid": Int(min=0),
    "flows": MapOf(List(OF_FLOW_ENTRY), key_check=is_decimal_string, key_desc="decimal dpid"),
}))

STATUS_OK = Obj({"status": Str(nonempty=True)})


# --- invariants -------------------------------------------------------------------
# Each takes (data, ctx) and returns a list of human-readable failures.
# ctx carries expectations derived from the topology JSON, so nothing is hardcoded
# to "10 switches" -- point the runner at a different topology and it adapts.

def inv_graph_matches_topology(data, ctx):
    out = []
    nodes = data["nodes"]
    switches = [n for n in nodes if n["vertex_type"] == 0]
    hosts = [n for n in nodes if n["vertex_type"] == 1]

    if len(switches) != ctx.expected_switches:
        out.append(f"switch count is {len(switches)}, topology file says {ctx.expected_switches}")
    if len(hosts) != ctx.expected_hosts:
        out.append(f"host count is {len(hosts)}, topology file says {ctx.expected_hosts}")
    if len(data["edges"]) != ctx.expected_edges:
        out.append(f"edge count is {len(data['edges'])}, topology file says {ctx.expected_edges}")

    seen = [s["dpid"] for s in switches]
    dupes = {d for d in seen if seen.count(d) > 1}
    if dupes:
        out.append(f"duplicate switch dpid(s): {sorted(dupes)}")

    unknown = sorted(set(seen) - ctx.expected_dpids)
    if unknown:
        out.append(f"dpid(s) not present in the topology file: {unknown}")
    absent = sorted(ctx.expected_dpids - set(seen))
    if absent:
        out.append(f"dpid(s) in the topology file but missing from the graph: {absent}")
    return out


def inv_all_switches_up(data, ctx):
    """
    The single highest-value invariant for P4 work.

    In P4 mode the graph currently stays isEnabled=false because nothing calls
    /ndt/inform_switch_entered, which silently empties BFS pathing, flow-table polling
    and link usage. This turns that into an explicit failure.
    """
    out = []
    down = [f"{n['device_name']}(dpid={n['dpid']})"
            for n in data["nodes"] if n["vertex_type"] == 0 and not n["is_up"]]
    if down:
        out.append(f"switch(es) not up: {', '.join(down)}")

    disabled = [f"{n['device_name']}(dpid={n['dpid']})"
                for n in data["nodes"] if n["vertex_type"] == 0 and not n["is_enabled"]]
    if disabled:
        out.append(
            f"switch(es) not enabled (not connected to a controller): {', '.join(disabled)}"
            " -- in P4 mode this usually means the proxy never called"
            " /ndt/inform_switch_entered"
        )
    return out


def inv_edges_enabled(data, ctx):
    down = [f"{e['src_dpid']}:{e['src_interface']}->{e['dst_dpid']}:{e['dst_interface']}"
            for e in data["edges"] if not e["is_up"] or not e["is_enabled"]]
    if down:
        shown = ", ".join(down[:5]) + (f" (+{len(down) - 5} more)" if len(down) > 5 else "")
        return [f"{len(down)} edge(s) down/disabled: {shown}"]
    return []


def inv_link_bandwidth_sane(data, ctx):
    out = []
    for e in data["edges"]:
        cap = e["link_bandwidth_bps"]
        used = e["link_bandwidth_usage_bps"]
        if cap > 0 and used > cap:
            out.append(
                f"edge {e['src_dpid']}:{e['src_interface']} reports usage {used} bps "
                f"above capacity {cap} bps"
            )
        pct = e["link_bandwidth_utilization_percent"]
        if not 0 <= pct <= 100:
            out.append(
                f"edge {e['src_dpid']}:{e['src_interface']} utilization {pct}% out of 0..100"
            )
    return out[:10]


def inv_flows_present(data, ctx):
    """Only meaningful with traffic running; gated by --with-traffic."""
    if not data:
        return ["no flows detected, but --with-traffic says traffic should be running"]
    return []


def _is_routable_unicast(ip_u32):
    """
    True when a destination could plausibly have a unicast path through the fabric.

    `src_ip`/`dst_ip` hold in_addr::s_addr -- network byte order read as a native integer --
    so the first octet is the low byte on a little-endian host. See doc/2026-01-02_ndt_api.md.

    Multicast (224/4), broadcast and link-local (169.254/16) are excluded because they have no
    unicast path by definition, so demanding one is a bug in the check rather than in the
    kernel. This is not hypothetical: a real run failed on
    192.168.123.16 -> 224.0.0.251, which is the host's own Avahi mDNS leaking onto a switch
    management interface and into the sFlow sample set. Whether that fires depends on whether
    Avahi happened to announce during the sampling window, so leaving it in makes the check
    non-deterministic.
    """
    first_octet = ip_u32 & 0xFF
    if 224 <= first_octet <= 239:      # 224.0.0.0/4 multicast
        return False
    if ip_u32 == 0xFFFFFFFF or first_octet == 255:
        # 255.255.255.255 and 255.0.0.0/8 only. A *directed* broadcast such as 10.0.0.255 has first
        # octet 10 and is still required to have a path, which this cannot know without the netmask
        # -- the flow record does not carry one. Left as is deliberately: being over-strict fails
        # loudly with the address named, which is fixable in a minute, whereas guessing a /24 would
        # silently excuse a real missing path to host .255. The comment used to just say
        # "broadcast", which claimed more than the line does.
        # [Co-developed with claude code -- Adam]
        return False
    if first_octet == 169 and ((ip_u32 >> 8) & 0xFF) == 254:
        return False                   # 169.254.0.0/16 link-local
    return True


def inv_flow_paths_non_empty(data, ctx):
    """
    The second highest-value P4 invariant.

    A flow's path comes from the Classifier, which is fed by
    get_switch_openflow_table_entries. The P4 proxy currently stubs that endpoint with
    [], so every path is empty -- visible here, invisible in the GUI.

    Only unicast destinations are required to have a path; see _is_routable_unicast.

    [Co-developed with claude code -- Adam]
    The empty-candidate case is a FAILURE, not a pass. Without that, a sample consisting entirely of
    multicast, broadcast or link-local traffic produced an empty `bad` list and the invariant reported
    success -- indistinguishable from "every flow had a path", with nothing saying zero flows were
    examined. That is not a hypothetical sample: the exclusion exists because a real run failed on
    192.168.123.16 -> 224.0.0.251, the host's own Avahi mDNS, so samples dominated by non-unicast
    chatter demonstrably happen here. A short quiet capture window is exactly when this check matters
    least and is most likely to be believed.
    """
    checked = [f for f in data if _is_routable_unicast(f["dst_ip"])]
    if not checked:
        return [f"no routable-unicast flows among {len(data)} sampled flow(s), so this invariant "
                "examined nothing -- generate unicast traffic (see --with-traffic) and re-run; "
                "a sample of only multicast/broadcast/link-local cannot confirm that paths resolve"]

    bad = [f"{f['src_ip']}->{f['dst_ip']}" for f in checked if not f["path"]]
    if bad:
        shown = ", ".join(bad[:5]) + (f" (+{len(bad) - 5} more)" if len(bad) > 5 else "")
        return [f"{len(bad)} of {len(checked)} routable flow(s) with an empty path: {shown}"
                " -- the Classifier has no flow-table data (check /stats/flow/<dpid>)"]
    return []


def inv_flow_rates_nonzero(data, ctx):
    zero = [f"{f['src_ip']}->{f['dst_ip']}" for f in data
            if f["estimated_flow_sending_rate_bps_in_the_last_sec"] == 0
            and f["estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot"] == 0]
    if len(zero) == len(data) and data:
        return ["every detected flow reports a rate of 0 -- telemetry is arriving but"
                " rate computation is not working"]
    return []


def inv_tables_non_empty(data, ctx):
    if not data:
        return ["no switch reported a flow table"
                " -- in P4 mode /stats/flow/<dpid> is probably still the [] stub"]
    empty = []
    for entry in data:
        total = sum(len(v) for v in entry["flows"].values())
        if total == 0:
            empty.append(str(entry["dpid"]))
    if empty:
        return [f"switch(es) with an empty flow table: {', '.join(empty)}"]
    return []


def inv_topk_bounded(data, ctx):
    if len(data) > ctx.topk:
        return [f"asked for top {ctx.topk} flows, got {len(data)}"]
    return []


def inv_power_covers_switches(data, ctx):
    reported = {e["dpid"] for e in data}
    missing = sorted(ctx.expected_dpids - reported)
    if missing:
        return [f"no power reading for dpid(s): {missing}"]
    return []


def inv_util_map_covers_switches(data, ctx):
    """CPU/memory maps are keyed by switch IP, so we check count rather than dpid."""
    if len(data) < ctx.expected_switches:
        return [f"only {len(data)} switch(es) reported, expected {ctx.expected_switches}"]
    return []


def inv_avg_link_usage_range(data, ctx):
    v = data["avg_link_usage"]
    if not 0 <= v <= 100:
        return [f"avg_link_usage is {v}, expected 0..100"]
    return []


def inv_lock_acquired(data, ctx):
    """
    A 200 from acquire_lock is not enough: the body must say it was actually locked.
    Guards against a handler that returns success while the LockManager refused.
    """
    status = str(data.get("status", "")).lower()
    if status not in ("locked", "acquired", "success", "ok"):
        return [f"acquire_lock returned 200 but status is {data.get('status')!r}, "
                f"which does not indicate the lock was taken"]
    return []


def inv_flow_write_is_honest_about_being_queued(data, ctx):
    """
    The flow-entry endpoints enqueue onto an asynchronous dispatcher and return before any
    request reaches the controller, so they cannot know whether the entries were programmed.
    They used to answer "Flow installed" regardless -- a rejected rule and a success were the
    same response. This pins the honest wording so it cannot regress to a false claim.
    """
    status = str(data.get("status", "")).lower()
    if status != "queued":
        return [f"expected status 'queued' (the dispatcher is asynchronous, so the outcome "
                f"is not known yet), got {data.get('status')!r} -- if this now reports a real "
                f"per-entry outcome, a synchronous path was added and this check should be "
                f"updated to verify it"]
    if "accepted" not in data:
        return ["response does not say how many entries were accepted"]
    return []


def inv_power_state_values(data, ctx):
    bad = {k: v for k, v in data.items() if v not in ("ON", "OFF")}
    if bad:
        return [f"unexpected power state value(s): {bad}"]
    return []


# --- endpoint table ---------------------------------------------------------------
# query/body may be callables taking ctx, for values derived from the topology.

ENDPOINTS = [
    # ---------- read-only: topology and telemetry ----------
    dict(name="get_graph_data", method="GET", path="/ndt/get_graph_data",
         category=READ, schema=GRAPH_DATA,
         invariants=[inv_graph_matches_topology, inv_all_switches_up,
                     inv_edges_enabled, inv_link_bandwidth_sane],
         note="used by all 7 tools/apps -- if this breaks, everything breaks"),

    dict(name="get_detected_flow_data", method="GET", path="/ndt/get_detected_flow_data",
         category=READ, schema=List(FLOW_RECORD),
         invariants=[inv_flow_rates_nonzero],
         traffic_invariants=[inv_flows_present, inv_flow_paths_non_empty],
         note="used by 5 components; depends on sFlow telemetry"),

    dict(name="get_detected_top_k_flow_data", method="GET",
         path="/ndt/get_detected_top_k_flow_data",
         query=lambda ctx: {"k": str(ctx.topk)},
         category=READ, schema=List(FLOW_RECORD),
         invariants=[inv_topk_bounded]),

    dict(name="get_switch_openflow_table_entries", method="GET",
         path="/ndt/get_switch_openflow_table_entries",
         category=READ, schema=OF_TABLES,
         invariants=[inv_tables_non_empty],
         note="feeds the Classifier, which produces every flow's path"),

    dict(name="get_static_topology_json", method="GET", path="/ndt/get_static_topology_json",
         category=READ, schema=Obj({}, strict=False)),

    dict(name="get_average_link_usage", method="GET", path="/ndt/get_average_link_usage",
         category=READ,
         schema=Obj({"status": Str(), "avg_link_usage": Num()}),
         invariants=[inv_avg_link_usage_range]),

    # The second branch was previously Obj({"status"}, strict=False), which accepts ANY
    # object containing "status" -- switch_count could vanish entirely and still pass.
    # Both branches now require a concrete shape.
    #
    # [Co-developed with claude code -- Adam]
    # expect_status accepts 404 as of 2026-08-25 (P1-3 closeout, Adam's ruling relayed by the
    # 08-24 audit session). Root-cause fix is deferred until after the 2026-09-03 report.
    #
    # WHAT WAS MEASURED (doc/audit/2026-08-24_path-switch-count-404/): the 404 reproduces, and it
    # is a first-query-after-boot transient -- 1x404 on sample 1, then 200 on all nine subsequent
    # samples at 12s intervals. The kernel fills its path map from a control-plane fetch on a
    # timer; immediately after boot that map is empty or partial, and the contract harness runs
    # right after bring-up, so it queries inside exactly that window.
    #
    # STRENGTHENED 2026-08-25 by the audit session's seal run
    # (scratch/review-2026-08-25/seal_404_transient.txt). On a boot that was CLEAN by every
    # available check -- `ndt up` rc=0, "10 switches up+enabled", graph matching 128 hosts /
    # 288 edges, h1 -> 10.0.0.2 forwarding, no XX at all -- the same endpoint went:
    #
    #     t+0  ->  404        t+30  ->  200        t+90  ->  200
    #
    # That is the recovery measured directly on one boot, not inferred from where a failure fell
    # in a series, and the clean-boot precondition rules out "the 404 came from a degraded fabric"
    # -- which is exactly the objection the post-commit shadow review raised against the two-arm
    # acceptance below.
    #
    # 🔴 THE GAP THAT REMAINS, and it is still why this is an allowlist rather than a fix: what has
    # been measured is the ANSWER flipping, not the MAP filling. Nobody has watched the path map
    # populate. "First query lands before a timer-driven fetch completes" is still the inferred
    # cause of an observed recovery. Note also that the column originally added to discriminate
    # this measured nothing -- repro_404.sh's `paths_known` reported a constant 2 on every row
    # including the 404, because the extractor took len() of the endpoint's JSON and counted
    # top-level keys rather than paths. Do not write the mechanism down as confirmed until someone
    # has instrumented the fill itself.
    #
    # WHAT THIS TRADES AWAY: a path map that is permanently empty -- not transiently -- now passes
    # this check, because 404 is the same answer in both cases and this endpoint cannot tell them
    # apart. That is a real loss of coverage and it is accepted knowingly. It is partly covered
    # elsewhere: get_graph_data's invariants still assert the graph is populated, and L4's
    # all_paths_populated compares against the baseline. If this entry is still here after the
    # 09-03 report, the fix to make is a startup-readiness distinction (503 while the map has
    # never been filled, 404 only for a genuinely unknown pair), not a wider allowlist.
    #
    # NOTE the 404 path logs NOTHING (HttpSession.cpp, the else branch that sets not_found), so
    # there is no warning_allowlist.txt entry to pair with this one -- and adding one would sit
    # permanently unmatched and be reported as stale.
    dict(name="get_path_switch_count", method="GET", path="/ndt/get_path_switch_count",
         query=lambda ctx: {"src_ip": ctx.src_host_ip, "dst_ip": ctx.dst_host_ip},
         category=READ,
         expect_status=[200, 404],
         schema=OneOf(
             Obj({"status": Str(), "src_ip": Str(), "dst_ip": Str(),
                  "switch_count": Int(min=0)}),
             # Documented alternative: all known paths when the parameters are omitted.
             Obj({"status": Str(), "paths": Any_()}),
             # Explicit "not found" style answer.
             Obj({"status": Str(), "message": Str()}),
         )),

    dict(name="get_num_of_flows_passing_a_switch", method="POST",
         path="/ndt/get_num_of_flows_passing_a_switch",
         body=lambda ctx: {"dpid": ctx.a_dpid},
         category=READ,
         schema=Obj({"status": Str(), "num_of_flows": Int(min=0)})),

    dict(name="get_total_input_traffic_load_passing_a_switch", method="POST",
         path="/ndt/get_total_input_traffic_load_passing_a_switch",
         body=lambda ctx: {"dpid": ctx.a_dpid},
         category=READ,
         schema=Obj({"status": Str(), "total_input_traffic_load_bps": Num(min=0)})),

    # ---------- read-only: device health ----------
    dict(name="get_power_report", method="GET", path="/ndt/get_power_report",
         category=READ,
         schema=List(Obj({"dpid": Int(min=0), "power_consumed": Num(min=0)})),
         invariants=[inv_power_covers_switches]),

    dict(name="get_switches_power_state", method="GET", path="/ndt/get_switches_power_state",
         category=READ,
         schema=MapOf(Str(), key_check=is_ipv4_string, key_desc="IPv4 address"),
         invariants=[inv_power_state_values]),

    # min=-1, not 0: -1 is the documented "unavailable" sentinel, not an out-of-range
    # utilisation. doc/2026-01-02_ndt_api.md: "A value of -1 means SNMP query failed or data is
    # unavailable", and Web-GUI's DeviceInformation.tsx renders `=== -1` as "unavailable".
    # Before 04b8933 the kernel omitted a down switch's key entirely, so the schema never saw
    # the sentinel and this check passed while inv_util_map_covers_switches failed on the count
    # instead. Since 04b8933 the key is present with -1 and the schema was the thing that was
    # wrong. [Co-developed with claude code -- Adam]
    dict(name="get_cpu_utilization", method="GET", path="/ndt/get_cpu_utilization",
         category=READ,
         schema=MapOf(Num(min=-1, max=100), key_check=is_ipv4_string, key_desc="IPv4 address"),
         invariants=[inv_util_map_covers_switches]),

    dict(name="get_memory_utilization", method="GET", path="/ndt/get_memory_utilization",
         category=READ,
         schema=MapOf(Num(min=-1, max=100), key_check=is_ipv4_string, key_desc="IPv4 address"),
         invariants=[inv_util_map_covers_switches]),

    # Values are numeric; a down switch reads -1, the same sentinel as the two endpoints above.
    # Str() is retained only for kernels older than 04b8933, which returned the literal
    # "The switch is down." here -- that string is no longer emitted and the branch is dead
    # against any current build. [Co-developed with claude code -- Adam]
    dict(name="get_temperature", method="GET", path="/ndt/get_temperature",
         category=READ,
         schema=MapOf(OneOf(Num(), Str()), key_check=is_ipv4_string, key_desc="IPv4 address")),

    dict(name="get_openflow_capacity", method="GET", path="/ndt/get_openflow_capacity",
         category=READ, schema=Any_(),
         note="undocumented in 2026-01-02_ndt_api.md; reads doc/2026-01-02_OpenflowCapacity.json"),

    dict(name="get_nickname", method="GET", path="/ndt/get_nickname",
         query=lambda ctx: {"dpid": str(ctx.a_dpid)},
         category=READ, schema=Obj({"nickname": Str()})),

    # ---------- locks: stateful, but self-contained ----------
    #
    # LOCK_TYPE below must be one the kernel recognises: LockManager::stringToLockType
    # accepts only routing_lock / graph_lock / power_lock and returns Unknown otherwise,
    # and acquireLock/renew reject Unknown. An invented type therefore makes every lock
    # check fail while never exercising the mutual-exclusion logic at all.
    #
    # graph_lock is used because it is a real type that NO application uses -- grepping
    # the workspace finds only routing_lock (Energy-Saving-App, Traffic-Engineering-App).
    # So these checks exercise genuine locking without being able to disturb a running
    # app. If an app ever starts using graph_lock, move this to power_lock.
    dict(name="acquire_lock", method="POST", path="/ndt/acquire_lock",
         body={"type": LOCK_TYPE, "ttl": LOCK_TTL},
         category=READ,
         schema=Obj({"status": Str()}, optional={"type": Str(), "ttl": Int()}),
         invariants=[inv_lock_acquired],
         note=f"uses {LOCK_TYPE}: a real lock type that no application uses"),

    dict(name="acquire_lock_conflict", method="POST", path="/ndt/acquire_lock",
         body={"type": LOCK_TYPE, "ttl": LOCK_TTL},
         category=ERRORPATH, expect_status=[423],
         schema=Any_(),
         note="second acquire of a held lock must return 423 Locked -- this is the "
              "only check that proves mutual exclusion actually works"),

    dict(name="renew_lock", method="POST", path="/ndt/renew_lock",
         body={"type": LOCK_TYPE, "ttl": LOCK_TTL},
         category=READ,
         schema=Obj({"status": Str()}, optional={"type": Str(), "ttl": Int()})),

    dict(name="release_lock", method="POST", path="/ndt/release_lock",
         body={"type": LOCK_TYPE},
         category=READ,
         schema=Obj({"status": Str()}, optional={"type": Str()})),

    dict(name="acquire_lock_after_release", method="POST", path="/ndt/acquire_lock",
         body={"type": LOCK_TYPE, "ttl": LOCK_TTL},
         category=READ,
         schema=Obj({"status": Str()}, optional={"type": Str(), "ttl": Int()}),
         invariants=[inv_lock_acquired],
         note="a released lock must be acquirable again -- catches a release that "
              "reports success without actually clearing the lock"),

    dict(name="release_lock_cleanup", method="POST", path="/ndt/release_lock",
         body={"type": LOCK_TYPE},
         category=READ,
         schema=Obj({"status": Str()}, optional={"type": Str()}),
         note="leaves no lock held behind"),

    dict(name="release_lock_not_held", method="POST", path="/ndt/release_lock",
         body={"type": LOCK_TYPE},
         category=ERRORPATH, expect_status=[412, 400, 404],
         schema=Any_(),
         # known_gap removed: handleReleaseLock now answers 412 for a lock that is not held or
         # whose type is invalid, matching the sibling renew handler and doc/2026-07-27_testing_workflow.md.
         # [Co-developed with claude code -- Adam]
         note="releasing an already-released lock must not report success"),

    dict(name="acquire_lock_invalid_type", method="POST", path="/ndt/acquire_lock",
         body={"type": "no_such_lock_type_exists", "ttl": 5},
         category=ERRORPATH, expect_status=[400, 422, 423],
         schema=Any_(),
         note="an unknown lock type must be rejected; the kernel currently answers 423, "
              "which is indistinguishable from 'busy' but is at least not a success"),

    # ---------- error paths: bad input must fail cleanly, never 500, never fake 200 ----
    dict(name="install_flow_entry__unknown_dpid", method="POST",
         path="/ndt/install_flow_entry",
         body={"dpid": 999999999999, "priority": 1,
               "match": {"eth_type": 2048, "ipv4_dst": "10.255.255.254"},
               "actions": [{"type": "OUTPUT", "port": 1}]},
         category=ERRORPATH, expect_status=[400, 404, 422],
         schema=Any_(),
         note="a dpid that is not in the topology must be rejected, not silently"
              " forwarded to Ryu (see FlowRoutingManager::getStrategyForDpid)"),

    dict(name="install_flow_entry__malformed_json", method="POST",
         path="/ndt/install_flow_entry",
         raw_body="{this is not json",
         category=ERRORPATH, expect_status=[400],
         schema=Any_()),

    dict(name="install_flow_entry__missing_fields", method="POST",
         path="/ndt/install_flow_entry", body={"dpid": 1},
         category=ERRORPATH, expect_status=[400, 422],
         schema=Any_()),

    dict(name="get_path_switch_count__bad_ip", method="GET",
         path="/ndt/get_path_switch_count",
         query={"src_ip": "not.an.ip", "dst_ip": "999.999.999.999"},
         category=ERRORPATH, expect_status=[200, 400, 404],
         schema=Any_(),
         note="must not 500 -- an empty result is acceptable, a crash is not"),

    dict(name="get_num_of_flows__unknown_dpid", method="POST",
         path="/ndt/get_num_of_flows_passing_a_switch",
         body={"dpid": 999999999999},
         category=ERRORPATH, expect_status=[200, 400, 404],
         schema=Any_()),

    dict(name="get_nickname__unknown_dpid", method="GET", path="/ndt/get_nickname",
         query={"dpid": "999999999999"},
         category=ERRORPATH, expect_status=[400, 404],
         schema=Any_()),

    dict(name="inform_switch_entered__bad_dpid", method="GET",
         path="/ndt/inform_switch_entered", query={"dpid": "not_a_number"},
         category=ERRORPATH, expect_status=[400, 404],
         schema=Any_(),
         note="HttpSession.cpp calls std::stoull unguarded; a non-numeric dpid"
              " must not surface as a 500"),

    dict(name="unknown_endpoint", method="GET", path="/ndt/there_is_no_such_endpoint",
         category=ERRORPATH, expect_status=[404],
         schema=Any_()),

    # ---------- mutating: only with --allow-mutations ----------
    dict(name="install_flow_entry", method="POST", path="/ndt/install_flow_entry",
         body=lambda ctx: {
             "dpid": ctx.a_dpid, "priority": 1,
             "match": {"eth_type": 2048, "ipv4_dst": ctx.probe_ip},
             "actions": [{"type": "OUTPUT", "port": 1}]},
         category=MUTATE, schema=Obj({"status": Str(nonempty=True), "accepted": Int(min=0)},
                     optional={"detail": Str()}),
         invariants=[inv_flow_write_is_honest_about_being_queued]),

    dict(name="modify_flow_entry", method="POST", path="/ndt/modify_flow_entry",
         body=lambda ctx: {
             "dpid": ctx.a_dpid, "priority": 1,
             "match": {"eth_type": 2048, "ipv4_dst": ctx.probe_ip},
             "actions": [{"type": "OUTPUT", "port": 2}]},
         category=MUTATE, schema=Obj({"status": Str(nonempty=True), "accepted": Int(min=0)},
                     optional={"detail": Str()}),
         invariants=[inv_flow_write_is_honest_about_being_queued]),

    dict(name="delete_flow_entry", method="POST", path="/ndt/delete_flow_entry",
         body=lambda ctx: {
             "dpid": ctx.a_dpid,
             "match": {"eth_type": 2048, "ipv4_dst": ctx.probe_ip}},
         category=MUTATE, schema=Obj({"status": Str(nonempty=True), "accepted": Int(min=0)},
                     optional={"detail": Str()}),
         invariants=[inv_flow_write_is_honest_about_being_queued]),

    dict(name="batch_flow_entries", method="POST",
         path="/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries",
         body=lambda ctx: {
             "install_flow_entries": [{
                 "dpid": ctx.a_dpid, "priority": 1,
                 "match": {"eth_type": 2048, "ipv4_dst": ctx.probe_ip},
                 "actions": [{"type": "OUTPUT", "port": 1}]}],
             "modify_flow_entries": [],
             "delete_flow_entries": [{
                 "dpid": ctx.a_dpid,
                 "match": {"eth_type": 2048, "ipv4_dst": ctx.probe_ip}}]},
         category=MUTATE, schema=Obj({"status": Str(nonempty=True), "accepted": Int(min=0)},
                     optional={"detail": Str(), "rejected": Int(min=0),
                               "rejected_dpids": List(Int(min=0))}),
         invariants=[inv_flow_write_is_honest_about_being_queued]),

    # [Co-developed with claude code -- Adam]
    # A batch mixing one real switch with one that does not exist. This is the case the unit tests
    # cannot reach: partitionFlowBatchByKnownDpid is covered directly, but the 200-with-rejections
    # versus 404-for-nothing-applicable branch lives in HttpSession and needs a real
    # TopologyAndFlowMonitor, which the routing harness passes as nullptr.
    #
    # The endpoint applied nothing at all for such a batch until 2026-08-09, and answered 404. Both
    # applications that write flows discard the response, so that silently dropped their good
    # entries too. It now applies the good entry and names the bad dpid.
    dict(name="batch_flow_entries__mixed_known_and_unknown_dpid", method="POST",
         path="/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries",
         body=lambda ctx: {
             "install_flow_entries": [
                 {"dpid": ctx.a_dpid, "priority": 1,
                  "match": {"eth_type": 2048, "ipv4_dst": ctx.probe_ip},
                  "actions": [{"type": "OUTPUT", "port": 1}]},
                 {"dpid": 999999999999, "priority": 1,
                  "match": {"eth_type": 2048, "ipv4_dst": "10.255.255.253"},
                  "actions": [{"type": "OUTPUT", "port": 1}]}],
             "modify_flow_entries": [],
             "delete_flow_entries": []},
         category=MUTATE, expect_status=[200],
         schema=Obj({"status": Str(nonempty=True), "accepted": Int(min=1),
                     "rejected": Int(min=1), "rejected_dpids": List(Int(min=0), min_len=1)},
                    optional={"detail": Str()}),
         note="the good entry must still be accepted, and the bad dpid must be named in"
              " rejected_dpids -- naming it is what makes a 200 checkable"),

    dict(name="batch_flow_entries__all_unknown_dpids", method="POST",
         path="/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries",
         body={"install_flow_entries": [
                   {"dpid": 999999999999, "priority": 1,
                    "match": {"eth_type": 2048, "ipv4_dst": "10.255.255.252"},
                    "actions": [{"type": "OUTPUT", "port": 1}]}],
               "modify_flow_entries": [], "delete_flow_entries": []},
         category=ERRORPATH, expect_status=[404],
         schema=Any_(),
         note="nothing applicable must not answer 200: a caller reading only the status code"
              " would take accepted == 0 for success"),

    dict(name="inform_switch_entered", method="GET", path="/ndt/inform_switch_entered",
         query=lambda ctx: {"dpid": str(ctx.a_dpid)},
         category=MUTATE, schema=STATUS_OK,
         note="the only path that sets isEnabled=true"),

    # The field is new_nickname, not nickname (2026-01-02_ndt_api.md, modify_nickname's
    # request table). Sending "nickname" made the kernel answer 400 "key 'new_nickname'
    # not found", so this check had never passed -- MUTATE only runs under
    # --allow-mutations, which is rare enough that nobody saw it. Writes the current
    # nickname back, for the reason modify_device_name below does.
    dict(name="modify_nickname", method="POST", path="/ndt/modify_nickname",
         body=lambda ctx: {"identifier": {"type": "dpid", "value": ctx.a_dpid},
                           "new_nickname": ctx.original_nickname},
         category=MUTATE,
         schema=Obj({"status": Str()}, optional={"message": Str()})),

    # ---------- endpoints with real consumers that previously had no contract --------
    # Each of these is called by a shipped component but was only ever verified as
    # "not a 404" by L3. They mutate state, so they sit behind --allow-mutations.

    dict(name="app_register", method="POST", path="/ndt/app_register",
         body={"app_name": "ndt_contract_test",
               "simulation_completed_url": "http://127.0.0.1:9/ndt_contract_test"},
         category=MUTATE,
         schema=Obj({"app_id": OneOf(Int(min=0), Str())},
                    optional={"message": Str(), "status": Str()}),
         note="used by Energy-Saving-App and Simulation-Platform-Manager. Registering "
              "creates an NFS directory for the app, so this leaves a stray "
              "'ndt_contract_test' registration behind"),

    # Same defect as modify_nickname: the documented field is new_name (section 15), and
    # "device_name" earned a 400 every time this check ran.
    dict(name="modify_device_name", method="POST", path="/ndt/modify_device_name",
         body=lambda ctx: {"vertex_type": 0, "dpid": ctx.a_dpid,
                           "new_name": ctx.original_device_name},
         category=MUTATE,
         schema=Obj({"status": Str(nonempty=True)}, optional={"message": Str()}),
         note="Web-GUI depends on this. Writes the name back to the topology JSON, so "
              "the body deliberately re-sets the CURRENT name: a rename here would edit "
              "the topology file on disk (and, per issue 12 of the P4 plan, possibly "
              "the wrong one). EXPECT A DIRTY TREE ANYWAY: even writing the same name "
              "back re-serialises the whole file, and the kernel's writer emits edges "
              "before nodes with its own key order, so setting/*.json comes out as a "
              "~1300-line diff whose content is byte-for-byte equivalent (verified by "
              "parsing both sides, 2026-08-17). git checkout it after a mutation run. "
              "Nobody had seen this because the check was sending the wrong field and "
              "the kernel never got as far as writing"),

    dict(name="set_switches_power_state", method="POST",
         path="/ndt/set_switches_power_state",
         query=lambda ctx: {"ip": ctx.a_switch_ip, "action": "on"},
         category=MUTATE,
         schema=MapOf(Str(), key_check=is_ipv4_string, key_desc="IPv4 address"),
         note="Energy-Saving-App depends on this. Deliberately sends action=on to an "
              "already-powered switch: 'off' would cut a real device in TESTBED mode"),

    # Historical logging: an enable/disable pair, in declaration order, for the same
    # reason the lock sequence is a sequence -- the second call puts the state back.
    # 2026-01-02_ndt_api.md section 39 documents 500 as the answer when HistoricalDataManager
    # is absent, which is how stack.sh starts the kernel (--no-ai), so both statuses are
    # in the contract. What this pins either way is that a documented state value is never
    # answered with a 4xx: that would mean the parameter contract had moved.
    dict(name="historical_logging_enable", method="POST", path="/ndt/historical_logging",
         query={"state": "enable"},
         category=MUTATE, expect_status=[200, 500],
         schema=OneOf(Obj({"status": Str(nonempty=True)}, optional={"message": Str()}),
                      Obj({"error": Str(nonempty=True)}, optional={"details": Str()})),
         note="state is a QUERY parameter, not a body field -- the body is ignored"),

    dict(name="historical_logging_disable", method="POST", path="/ndt/historical_logging",
         query={"state": "disable"},
         category=MUTATE, expect_status=[200, 500],
         schema=OneOf(Obj({"status": Str(nonempty=True)}, optional={"message": Str()}),
                      Obj({"error": Str(nonempty=True)}, optional={"details": Str()})),
         note="restores whatever the enable above changed"),

    # The simulation endpoints forward to the Simulation-Platform-Manager, which is not
    # part of a normal kernel test run, so a success-path contract would be flaky. Their
    # input validation is testable without it, and that is where a 500 would hurt.
    dict(name="received_a_simulation_case__malformed", method="POST",
         path="/ndt/received_a_simulation_case", raw_body="{not json",
         category=ERRORPATH, expect_status=[400],
         schema=Any_(),
         note="used by Energy-Saving-App and Simulation-Platform-Manager"),

    dict(name="received_a_simulation_case__missing_fields", method="POST",
         path="/ndt/received_a_simulation_case", body={},
         category=ERRORPATH, expect_status=[400, 422],
         schema=Any_()),

    dict(name="simulation_completed__malformed", method="POST",
         path="/ndt/simulation_completed", raw_body="{not json",
         category=ERRORPATH, expect_status=[400],
         schema=Any_(),
         note="used by Simulation-Platform-Manager"),

    dict(name="app_register__missing_fields", method="POST", path="/ndt/app_register",
         body={}, category=ERRORPATH, expect_status=[400, 422],
         schema=Any_()),

    dict(name="historical_logging__bad_state", method="POST",
         path="/ndt/historical_logging", query={"state": "bad"},
         category=ERRORPATH, expect_status=[400],
         schema=Any_(),
         note="section 39 measured this 400 live on a kernel that answers 500 for a "
              "valid state, so parameter validation provably runs before the availability "
              "check -- which is why this one check is exact where the pair above has to "
              "accept two statuses"),

    # The success path of intent_translator/text stays out, for the reasons recorded when
    # it was first excluded: it needs an OpenAI token, costs money per call, and its
    # response is model-dependent, so a contract check would be flaky and expensive.
    # None of that applies to the error path, which needs no token at all -- and the error
    # path is where the damage was. Until 2026-08-11 the handler dereferenced a null
    # IntentTranslator, so ONE well-formed POST segfaulted the whole kernel process
    # (2026-01-02_ndt_api.md section 41); the mitigation was a paragraph asking people not
    # to call it, and the fix was a guard. Nothing has re-tested that guard since. A body
    # missing "session" reaches it without an LLM: 400 if validation answers first, 503 if
    # the disabled-mode guard does, and the section documents both. A 500 or a 200 here is
    # the regression.
    dict(name="intent_translator_text__incomplete_body", method="POST",
         path="/ndt/intent_translator/text",
         body={"prompt": "contract check -- no intent is expected to be executed"},
         category=ERRORPATH, expect_status=[400, 503],
         schema=Any_(),
         note="guards the null-IntentTranslator crash fixed 2026-08-11; deliberately "
              "incomplete so no intent can execute even if the kernel has AI enabled"),
]


def endpoints_by_category(categories) -> list[dict]:
    """Preserves declaration order, which matters for the lock and probe-rule sequences."""
    wanted = set(categories)
    return [e for e in ENDPOINTS if e["category"] in wanted]
