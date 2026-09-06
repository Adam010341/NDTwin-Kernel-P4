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

# --- verdict prefixes an invariant may return instead of a plain failure ------------
# [Co-developed with claude code -- Adam]
# An invariant returns a list of strings and the runner used to treat every one of them as
# "the system is broken". That gave the suite exactly two outputs, so the one thing it could
# not say was "I cannot tell" -- and a tool whose failure is serialised the same way as its
# finding will mislead you precisely when it matters (KNOWN-ISSUES A-8; the memory note
# instrument-must-not-mimic-its-own-finding). These two prefixes are the third and fourth
# answers. run_contract_test.check_endpoint partitions on them; anything unprefixed is still
# a red failure, so an invariant that has not been taught about them cannot change meaning.
TOOL_PRECONDITION = "TOOL-PRECONDITION-FAILED: "
ACCOUNTED_FOR = "ACCOUNTED-FOR: "


class PowerState:
    """
    Which switches the operator has deliberately powered down -- or why we do not know.

    [Co-developed with claude code -- Adam] -- KNOWN-ISSUES A-8.

    The graph invariants need to separate "this switch is down because the
    Energy-Saving-App turned it off" from "this switch never connected". Those are the same
    bit in the graph (is_up=false), and the second is the P4 wiring failure the suite exists
    to catch, so neither may be dropped and neither may be assumed.

    Hence three states, not two. `known` false means the reading is not trustworthy, and the
    invariants answer TOOL-PRECONDITION-FAILED rather than guessing in either direction:
    guessing "all on" reproduces the false alarm, guessing "all off" hides the wiring failure.
    An empty `off_dpids` with `known` true is a real, positive statement -- nothing is
    powered off -- and is not the same object as `unknown()`.
    """

    def __init__(self, off_dpids=(), error=None, unreachable_dpids=()):
        self.off_dpids = frozenset(off_dpids)
        # [Co-developed with claude code -- Adam] -- Q12.
        # The endpoint used to answer one question with a word that named the other: its ON/OFF
        # was derived from the graph's `is_up`, so "powered off" and "not answering" were the
        # same reading. They are separate fields now, and so are these -- `off_dpids` is what
        # the operator ASKED FOR and is the only thing that may account for a deviation.
        self.unreachable_dpids = frozenset(unreachable_dpids)
        self.error = error

    @property
    def known(self) -> bool:
        return self.error is None

    @classmethod
    def unknown(cls, error: str) -> "PowerState":
        return cls((), error)

    @classmethod
    def all_on(cls) -> "PowerState":
        """A positive reading that nothing is powered off. For tests and for empty fabrics."""
        return cls(())

    def describe(self) -> str:
        if not self.known:
            return f"unknown ({self.error})"
        if not self.off_dpids:
            return "all switches powered on"
        return f"powered off: {sorted(self.off_dpids)}"


def classify_power_state(payload, ip_to_dpid) -> PowerState:
    """
    Turn a /ndt/get_switches_power_state body into a PowerState. Pure; no I/O.

    Every branch that cannot produce a *complete and unambiguous* dpid set returns unknown
    with a reason, including the quiet ones:

      * a value that is neither ON nor OFF -- treating an unrecognised state as "on" is
        exactly how a tool acquires a confident wrong answer;
      * a key that is not a switch in this topology -- then the reading describes some other
        fabric and mapping it onto this one is a guess;
      * a switch in the topology with no key in the reading -- partial coverage would make
        a powered-off switch look powered on, which is the A-8 false alarm again. The kernel
        has form here: before 04b8933 the CPU/memory maps omitted a down switch's key
        entirely (live-findings-2026-08-18-ovs.md, F-3).

    [Co-developed with claude code -- Adam]
    """
    if not isinstance(payload, dict):
        return PowerState.unknown(
            f"expected an object keyed by switch IP, got {type(payload).__name__}")

    off = set()
    unreachable = set()
    for ip, value in payload.items():
        dpid = ip_to_dpid.get(ip)
        if dpid is None:
            return PowerState.unknown(
                f"reading names {ip!r}, which is not a switch in this topology")

        # [Co-developed with claude code -- Adam] -- Q12.
        # TWO SHAPES, on purpose. This tool is pointed at whatever kernel is deployed: a kernel
        # from before the split answers with the scalar "ON"/"OFF", one from after answers with
        # {"admin_state": "on"|"off", "reachable": bool}. Refusing the old shape would turn every
        # pre-Q12 run into TOOL-PRECONDITION-FAILED, which is this file's own definition of a
        # tool failing in a way that looks like the system failing.
        if isinstance(value, dict):
            admin = value.get("admin_state")
            if admin is None:
                return PowerState.unknown(
                    f"{ip} reports no admin_state; the reading cannot say what was commanded")
            admin = str(admin).strip().lower()
            if admin == "off":
                off.add(dpid)
            elif admin != "on":
                return PowerState.unknown(
                    f"{ip} reports admin_state {value.get('admin_state')!r}, not on or off")
            if value.get("reachable") is False:
                unreachable.add(dpid)
            continue

        state = str(value).strip().upper()
        if state == "OFF":
            off.add(dpid)
            # The old shape cannot tell the two apart -- that is the finding. A pre-Q12 "OFF"
            # therefore contributes to `off_dpids` only, and `unreachable_dpids` stays empty
            # rather than being filled with a guess.
        elif state != "ON":
            return PowerState.unknown(f"{ip} reports power state {value!r}, not ON or OFF")

    missing = sorted(set(ip_to_dpid) - set(payload))
    if missing:
        return PowerState.unknown(
            f"no power reading for {len(missing)} switch(es): {', '.join(missing)}")

    return PowerState(off, unreachable_dpids=unreachable)


def partition_messages(messages):
    """
    Split invariant output into (failures, preconditions, accounted_for).

    Kept here rather than in the runner so that l3_component_check.py and any future caller
    classify identically -- three tools disagreeing about what red means is how A-8 became
    three separate false alarms instead of one.
    """
    failures, preconditions, accounted = [], [], []
    for m in messages:
        if m.startswith(TOOL_PRECONDITION):
            preconditions.append(m[len(TOOL_PRECONDITION):])
        elif m.startswith(ACCOUNTED_FOR):
            accounted.append(m[len(ACCOUNTED_FOR):])
        else:
            failures.append(m)
    return failures, preconditions, accounted


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

# [Co-developed with claude code -- Adam]
# A-4f. The kernel's four-valued answer to "is this edge's 0 bps a measurement or an absence?".
# Written out here rather than as a bare Str() so a typo'd or invented state fails the contract
# instead of arriving as a plausible-looking string.
#
#   live    -- a sample was attributed to this edge inside the freshness window
#   idle    -- none for this edge, but the sampling agent reported on another of its ports,
#              so the agent is alive and 0 IS a measurement
#   silent  -- the sampling agent reported on no port at all while the switch is up, so 0 is
#              NOT a measurement. This is A-4f firing.
#   unknown -- that agent has never reported since the kernel started; a fresh kernel and a
#              switch that was never given an sFlow record are indistinguishable here
TELEMETRY_STATES = ("live", "idle", "silent", "unknown")

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
}, optional={
    "nickname": Str(),
    # [Co-developed with claude code -- Adam] -- Q12, Adam's ruling (a) of 2026-09-03.
    # `is_up` above answered two questions at once. These are the two answers; `is_up` stays
    # REQUIRED because it is now a deprecated alias of `reachable` that four external consumers
    # still read (one of them with a throwing j.at()).
    #
    # Optional, not required, for the same reason left_link_bandwidth_source is: a kernel built
    # before the split must still pass the structural check. Listing them pins the vocabulary --
    # "OFF", "disabled" or a free-form string is a contract change and fails here.
    "admin_state": Str(allowed=("on", "off")),
    "reachable": Bool(),
})

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
}, optional={
    "left_link_bandwidth_bps": Num(),
    # [Co-developed with claude code -- Adam]
    # F-8. Optional, not required: a kernel built before the field existed must still pass, and
    # Obj is non-strict so an added key was already accepted. Listing it pins the vocabulary --
    # a fourth value, or a free-form string, would be a contract change and should fail here.
    "left_link_bandwidth_source": Str(allowed=("declared", "measured", "unknown")),
    # [Co-developed with claude code -- Adam]
    # A-4f. Optional, not required: /ndt/ is a cross-repo contract read by seven components and
    # a kernel that predates the fix must still pass the structural check. Whether the field is
    # *present* is the business of inv_no_silent_telemetry, which reports its absence rather
    # than passing -- keeping the two apart is what stops a missing field from reading as a
    # structural break on one side and as silence on the other.
    "telemetry_status": Str(allowed=TELEMETRY_STATES),
    "last_sample_age_seconds": Num(),
    "agent_last_sample_age_seconds": Num(),
})

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
}, optional={
    # [Co-developed with claude code -- Adam]
    # KNOWN-ISSUES B-x. The liveness triple, added 2026-09-02. OPTIONAL rather than required, and
    # deliberately: this file is run against a live kernel, and a kernel built before the patch
    # emits twelve fields. Making them required would turn the contract test into a version check
    # and report "contract broken" for an old binary that is behaving exactly as it was built to.
    # Listing them at all is what stops a later refactor from dropping them silently -- Obj is
    # non-strict by default (schema.py:129-138), so an unlisted field is simply invisible here.
    "liveness": Str(nonempty=True),
    "last_seen_ms": Int(min=0),
    "ended_at_ms": Int(min=0),
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

# [Co-developed with claude code -- Adam]
# GET /ndt/get_flow_dispatch_status -- KNOWN-ISSUES A-7's answer surface, and until now one of
# the registered endpoints with no contract at all. It is the endpoint whose whole purpose is to
# stop a silent write failure, so leaving it uncovered means the suite would stay green if the
# thing that reports failures stopped reporting them.
#
# recent_failures[].requested_priority is named for FINDING-07: on the destination-only path the
# switch programs the rule into a P4 LPM table that has no priority column, so this field is what
# the caller ASKED for and never what the table holds. The schema keeps the name as-is on purpose;
# renaming it to `priority` would restore exactly the confusion the name was chosen to prevent.
DISPATCH_FAILURE = Obj({
    "seq": Int(min=0),
    "at_unix_ms": Int(min=0),
    "op": Str(allowed=("install", "modify", "delete")),
    "dpid": Int(min=0),
    "requested_priority": Int(),
    "match": Obj({}, strict=False),
    # 0 is a real value here: it means nothing answered at all (no HTTP status was ever
    # received), which is different from an error status and must not be schema-rejected.
    "controller_status": Int(min=0),
    "message": Str(),
})

DISPATCH_STATUS = Obj({
    "counters": Obj({
        "dispatched": Int(min=0),
        "succeeded": Int(min=0),
        "failed": Int(min=0),
    }, optional={
        # Added after the endpoint shipped. Optional so the contract still describes a kernel
        # built from an earlier commit rather than reporting a false regression against one.
        "dropped_after_stop": Int(min=0),
    }),
    "recent_failures": List(DISPATCH_FAILURE),
    "recent_failures_capacity": Int(min=1),
    "recent_failures_evicted": Int(min=0),
}, optional={
    # Both added by the A-7 follow-up; optional for the same reason as dropped_after_stop.
    "dispatcher_running": Bool(),
    "counters_cover": Obj({
        "dispatch_routes": List(Str(nonempty=True), min_len=1),
        "includes_boot_time_programming": Bool(),
        "includes_intent_translator": Bool(),
    }),
})


# --- invariants -------------------------------------------------------------------
# Each takes (data, ctx) and returns a list of human-readable failures.
# ctx carries expectations derived from the topology JSON, so nothing is hardcoded
# to "10 switches" -- point the runner at a different topology and it adapts.

def dotted_ip(value):
    """One address as a dotted string, whichever of the two encodings it arrived in.

    [Co-developed with claude code -- Adam]
    A topology file writes `"192.168.123.11"`. The graph writes `in_addr::s_addr` read as a
    native integer -- NETWORK order, so the first octet is the LOW byte, which is why
    10.0.0.1 arrives as 16777226 and not as 167772161. Comparing the two sides without this
    compares a string to an int and finds a difference every single time; reading the wrong
    end of the integer finds a different network every time. Both failure modes report a
    healthy fabric as broken, which is the one thing this suite must not do.
    """
    if isinstance(value, str):
        return value
    if isinstance(value, bool) or not isinstance(value, int):
        return str(value)
    return ".".join(str((value >> (8 * i)) & 0xFF) for i in range(4))


def address_set(node):
    """A node's addresses as a set of dotted strings, from either side of the comparison.

    A SET, not a list: `_ipAlias4_*` hosts carry four addresses each and nothing promises the
    kernel serves them in the file's order. Order is not identity here; membership is.
    """
    return frozenset(dotted_ip(v) for v in (node.get("ip") or []))


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

    out += _switch_identity(switches, ctx)
    out += _host_identity(hosts, ctx)
    return out


# [Co-developed with claude code -- Adam] -- W3b-3, since 2026-09-07.
#
# 🔴 WHY THE COUNTS ARE NOT ENOUGH, and what the two functions below add.
#
# Everything above answers "is this the right SIZE of network". None of it answers "is this the
# right network". `setting/` ships two models with ten switches, four hosts, forty edges and the
# same ten dpids (OVS and P4), and `tools/test_workflow/run_layers.sh:135` picks the model by
# (mode, live host count) rather than by asking the kernel which file it loaded -- so validating
# a fabric against a model that is not the one it is running is reachable, and came out ALL
# GREEN. That is KNOWN-ISSUES L-1's family: the twin compared to a DIFFERENT network, and the
# difference read as a verdict about the product. Here it read as no verdict at all.
#
# It is also what four of R0b's five topology-door findings looked like from this invariant:
# every one of the six deliberately broken files (rounds/05-R0b-postmerge2.md §2.1) differs from
# the shipped model in ONE field, and four of them keep every count and every dpid identical.
#
# What is compared, and what deliberately is not:
#
#   switches, keyed by dpid   -- brand_name and the address set are FAILURES. Neither can change
#                                at runtime; a difference means a different model.
#   hosts, keyed by mac       -- the address set is a FAILURE. Not by dpid, which is 0 for every
#                                host (the collision that made probes.switch_flags count 128
#                                hosts as one switch, test_probes.py); not by device_name, which
#                                is the field a rename moves.
#   device_name (both kinds)  -- reported as ACCOUNTED-FOR, never as a failure. `modify_nickname`
#                                and `modify_device_name` persist a rename -- into the model file
#                                before W10, into `.test_run/nickname_overlay/` and back over the
#                                graph at load after it -- so a name that disagrees with the file
#                                is an expected state of a healthy fabric. Printed rather than
#                                failed, because an explained deviation nobody sees is
#                                indistinguishable from no deviation.
#   bridge_name, ecmp_groups  -- not compared, because `get_graph_data` does not carry them.
#                                Files d and e of that round differ from the shipped model only
#                                in those, and stay green here. Saying so is the point: this
#                                invariant reads the graph, and what the graph does not say it
#                                cannot check.
#
# The two expectation maps come from run_contract_test.Context. A ctx that does not carry them
# is a hand-built stand-in that has only cardinalities to offer, and gets the cardinality checks
# alone -- the REAL Context always builds them, which is pinned by
# tests/python/test_contract_spec.py so that "absent" can never quietly become the production
# answer.

def _switch_identity(switches, ctx):
    why = getattr(ctx, "switch_identity_unavailable", None)
    if why:
        return [TOOL_PRECONDITION + why]
    expected = getattr(ctx, "expected_switch_identity", None)
    if expected is None:
        return []
    out = []
    for s in sorted(switches, key=lambda n: n["dpid"]):
        want = expected.get(s["dpid"])
        if want is None:
            continue                    # already reported above as an unknown dpid
        got_ips = address_set(s)
        if got_ips != want["ips"]:
            out.append(f"switch dpid {s['dpid']} is served with addresses "
                       f"{sorted(got_ips)}, topology file says {sorted(want['ips'])}")
        if s.get("brand_name", "") != want["brand_name"]:
            out.append(f"switch dpid {s['dpid']} is served as brand "
                       f"{s.get('brand_name', '')!r}, topology file says "
                       f"{want['brand_name']!r} -- brand_name decides power and telemetry "
                       f"dispatch, so this is a different machine, not a different label")
        if s.get("device_name", "") != want["device_name"]:
            out.append(ACCOUNTED_FOR + f"switch dpid {s['dpid']} is named "
                       f"{s.get('device_name', '')!r} in the graph and "
                       f"{want['device_name']!r} in the topology file; a rename through "
                       f"modify_device_name/modify_nickname persists and does exactly this")
    return out


def _host_identity(hosts, ctx):
    # 🔴 The duplicate-mac check below runs either way: the precondition says the FILE cannot
    # identify its hosts, and the check says the GRAPH is serving two hosts under one L2
    # identity. Those are different facts, and the second is a verdict about the twin -- the
    # nickname overlay keys hosts by mac, so a collision there is ambiguous by construction.
    out = []
    macs = [h.get("mac") for h in hosts]
    dupes = sorted({m for m in macs if macs.count(m) > 1}, key=repr)
    if dupes:
        out.append(f"duplicate host mac(s): {dupes} -- hosts all carry dpid 0, so the mac is "
                   f"the only thing that tells them apart")

    why = getattr(ctx, "host_identity_unavailable", None)
    if why:
        return out + [TOOL_PRECONDITION + why]
    expected = getattr(ctx, "expected_host_identity", None)
    if expected is None:
        return out
    unknown = sorted(m for m in set(macs) if m not in expected)
    if unknown:
        out.append(f"host mac(s) not present in the topology file: {unknown}")
    absent = sorted(m for m in expected if m not in set(macs))
    if absent:
        out.append(f"host mac(s) in the topology file but missing from the graph: {absent}")

    for h in sorted(hosts, key=lambda n: (n.get("mac") is None, n.get("mac"))):
        want = expected.get(h.get("mac"))
        if want is None:
            continue
        got_ips = address_set(h)
        if got_ips != want["ips"]:
            out.append(f"host {want['device_name']!r} (mac {h.get('mac')}) is served with "
                       f"addresses {sorted(got_ips)}, topology file says "
                       f"{sorted(want['ips'])}")
        if h.get("device_name", "") != want["device_name"]:
            out.append(ACCOUNTED_FOR + f"host mac {h.get('mac')} is named "
                       f"{h.get('device_name', '')!r} in the graph and "
                       f"{want['device_name']!r} in the topology file; a rename persists")
    return out


def _node_reachable(n) -> bool:
    """
    Whether the twin can reach this switch.

    [Co-developed with claude code -- Adam] -- Q12.
    `reachable` is the field; `is_up` is the deprecated alias kept so external readers keep
    working. Where both exist the field wins: a consumer that reads the alias is reading a copy,
    and the two can disagree if anything ever emits them separately.
    """
    return bool(n["reachable"]) if "reachable" in n else bool(n["is_up"])


def _node_commanded_off(n):
    """
    Whether an operator commanded this switch off, or None when the node does not say.

    [Co-developed with claude code -- Adam] -- Q12.
    None is a third answer and it is load-bearing: a kernel from before the split emits no
    `admin_state`, and reading that absence as "commanded on" would turn every deliberately
    powered-down switch into a failure -- the A-8 false alarm this file exists to have fixed.
    """
    if "admin_state" not in n:
        return None
    return str(n["admin_state"]).strip().lower() == "off"


def _power_state(ctx):
    """
    The powered-off switches this run is allowed to account for, or None if unknown.

    [Co-developed with claude code -- Adam]
    A ctx with no `power_state` attribute at all is treated as UNKNOWN rather than as
    "everything is powered on". A caller that forgot to wire the reading must be told so,
    not handed a confident answer built on a default.
    """
    return getattr(ctx, "power_state", None)


def _describe(nodes):
    return ", ".join(f"{n['device_name']}(dpid={n['dpid']})" for n in nodes)


def inv_all_switches_up(data, ctx):
    """
    The single highest-value invariant for P4 work.

    In P4 mode the graph currently stays isEnabled=false because nothing calls
    /ndt/inform_switch_entered, which silently empties BFS pathing, flow-table polling
    and link usage. This turns that into an explicit failure.

    [Co-developed with claude code -- Adam] -- A-8.
    Written to catch a P4 wiring failure, it was applied unconditionally in both modes, and a
    switch the Energy-Saving-App had *correctly* powered down is indistinguishable from one
    that never connected: both are is_up=false. On 2026-08-18 and again on 2026-08-30 that
    turned a healthy, deliberately degraded fabric red (8 lines plus a BROKEN), with the
    endpoint's own note reading "if this breaks, everything breaks".

    So the invariant now asks *why* a switch is down before calling it a fault, and it has
    three answers, not two:

      down, and powered ON            -> a real failure. The P4 detection is untouched.
      down, and powered OFF           -> accounted for. Reported, not failed.
      down, and the power state is not readable
                                      -> TOOL-PRECONDITION-FAILED. The tool says it cannot
                                         decide, which must not look like the fabric being
                                         broken (instrument-must-not-mimic-its-own-finding).

    NOTE for anyone editing the strings below: `switch(es) not up` is grepped by
    doc/audit/2026-08-30_live-full-stack-round/harness/{40_r5_p4,50_r5_ovs}.sh as the F-2/A-8
    detector. It must stay on the *real failure* path and must not appear in the
    accounted-for or precondition wording, or those harnesses will keep reporting A-8 as
    present after it is fixed.

    admin_disabled is deliberately NOT the key here: per doc/2026-08-10_p4_manual_test_runbook.md
    it marks the Intent Translator's DisableSwitch, not the power app, and was measured false
    for all three powered-off switches on 2026-08-18.
    """
    out = []
    switches = [n for n in data["nodes"] if n["vertex_type"] == 0]
    down = [n for n in switches if not _node_reachable(n)]
    disabled = [n for n in switches if not n["is_enabled"]]
    if not down and not disabled:
        return out

    # [Co-developed with claude code -- Adam] -- Q12, and the reason this check could not fire.
    #
    # 🔴 BOTH SIDES OF THIS COMPARISON USED TO READ THE SAME BIT. The graph's "is this switch
    # down" was `is_up`, and the kernel derived /ndt/get_switches_power_state's ON/OFF answer
    # FROM THAT SAME FLAG -- so on any real kernel every down switch was in `off_dpids`,
    # `unexplained_down` was structurally empty, and the highest-value invariant in the suite
    # could not report a fault. (The cases above hide it: they hand this function a PowerState
    # no live kernel could have produced.)
    #
    # After the split the graph answers for itself, and the two answers have different writers:
    # `admin_state` is written only by the power strategies, `reachable` only by liveness. So
    # prefer the node -- one document, internally consistent, and no second HTTP call that can
    # fail. The power reading stays as the fallback for a kernel that predates the split.
    #
    # ALL of them or none: a graph where some switches carry `admin_state` and some do not is a
    # reading nobody should act on, because the silent ones would count as "commanded on" and
    # become failures. Same discipline as classify_power_state's partial-coverage rule.
    commanded = [_node_commanded_off(n) for n in switches]
    if switches and all(c is not None for c in commanded):
        source = "the graph's own admin_state"
        unexplained_down = [n for n in down if not _node_commanded_off(n)]
        explained_down = [n for n in down if _node_commanded_off(n)]
        unexplained_disabled = [n for n in disabled if not _node_commanded_off(n)]
        explained_disabled = [n for n in disabled if _node_commanded_off(n)]
    else:
        source = "/ndt/get_switches_power_state"
        power = _power_state(ctx)
        if power is None or not power.known:
            why = power.error if power is not None else "the runner did not read it"
            return [
                TOOL_PRECONDITION
                + f"{len(down)} switch(es) report is_up=false and {len(disabled)} report "
                  f"is_enabled=false, and the power state could not be read ({why}), so this "
                  f"check cannot tell a deliberate power-down from a switch that never "
                  f"connected. No verdict on the fabric."
            ]

        unexplained_down = [n for n in down if n["dpid"] not in power.off_dpids]
        explained_down = [n for n in down if n["dpid"] in power.off_dpids]
        unexplained_disabled = [n for n in disabled if n["dpid"] not in power.off_dpids]
        explained_disabled = [n for n in disabled if n["dpid"] in power.off_dpids]

    if unexplained_down:
        out.append(f"switch(es) not up: {_describe(unexplained_down)}")
    if unexplained_disabled:
        out.append(
            f"switch(es) not enabled (not connected to a controller): "
            f"{_describe(unexplained_disabled)}"
            " -- in P4 mode this usually means the proxy never called"
            " /ndt/inform_switch_entered"
        )

    accounted = sorted({n["dpid"] for n in explained_down + explained_disabled})
    if accounted:
        out.append(
            ACCOUNTED_FOR
            + f"{len(accounted)} switch(es) are down/disabled because "
              f"{source} reports them commanded off: "
              f"{_describe(explained_down or explained_disabled)}"
              " -- a powered-down switch is the Energy-Saving-App doing its job"
        )
    return out


def inv_edges_enabled(data, ctx):
    """
    [Co-developed with claude code -- Adam] -- A-8, same three answers as inv_all_switches_up.

    An edge incident to a powered-off switch is down for a reason the run already knows. On
    2026-08-18 all 20 down edges were exactly the links incident to the three switches the
    power app had turned off, and the suite still called them a fault.
    """
    def name(e):
        return f"{e['src_dpid']}:{e['src_interface']}->{e['dst_dpid']}:{e['dst_interface']}"

    down = [e for e in data["edges"] if not e["is_up"] or not e["is_enabled"]]
    if not down:
        return []

    power = _power_state(ctx)
    if power is None or not power.known:
        why = power.error if power is not None else "the runner did not read it"
        return [
            TOOL_PRECONDITION
            + f"{len(down)} edge(s) are down/disabled and the power state could not be read "
              f"({why}), so this check cannot tell a link incident to a deliberately "
              f"powered-off switch from a broken one. No verdict on the fabric."
        ]

    def incident_to_off(e):
        return e["src_dpid"] in power.off_dpids or e["dst_dpid"] in power.off_dpids

    unexplained = [e for e in down if not incident_to_off(e)]
    explained = [e for e in down if incident_to_off(e)]

    out = []
    if unexplained:
        names = [name(e) for e in unexplained]
        shown = ", ".join(names[:5]) + (f" (+{len(names) - 5} more)" if len(names) > 5 else "")
        out.append(f"{len(names)} edge(s) down/disabled: {shown}")
    if explained:
        out.append(
            ACCOUNTED_FOR
            + f"{len(explained)} edge(s) are down/disabled because they are incident to a "
              f"switch /ndt/get_switches_power_state reports OFF"
        )
    return out


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


def inv_no_silent_telemetry(data, ctx):
    """
    A link reading 0 bps because nothing is measuring it must not look like an idle link.

    [Co-developed with claude code -- Adam]
    KNOWN-ISSUES A-4f. An OVS power cycle runs `ovs-vsctl del-br`, which destroys the bridge
    row and with it the sFlow record hanging off it (OVSPowerStrategy.cpp:171). powerOn
    rebuilds the bridge, the ports and the controller and never re-creates the record
    (OVSPowerStrategy.cpp:97-112), so that switch stops sampling for good. The edges *entering*
    it -- m_counterReports is keyed by the sampler's ingress port, resolved through
    getAgentKeyFromTheOtherSide -- then publish exactly 0 every second, which is bit-identical
    to an idle link and to a kernel that has not received a sample yet. Measured: 0 bps on a
    link carrying 103 Mbps.

    Two rules:

      1. Any edge the kernel marks `silent` is reported. That is the twin saying, in its own
         words, that the number it is serving is an absence rather than a measurement.

      2. A response whose edges carry no telemetry_status at all is ALSO reported -- as a check
         that could not run, not as a pass. Three of this file's invariants were once found
         reporting PASS while examining zero records, and that is the more dangerous shape:
         it occupies the slot where a real check would go. A kernel without the field cannot
         answer the question, so the honest output is "cannot tell", never green.

    `idle` is not a failure: the sampling agent reported on another of its ports inside the
    window, so it is alive and this link's 0 is a genuine measurement. `unknown` is not a
    failure either -- it is the truthful state of a kernel that started moments ago, and
    failing on it would make the contract test red on every fresh stack, which is how a check
    gets switched off. Both are decisions, not oversights; tests/python/test_contract_spec.py
    pins them.

    The raw ages travel alongside the label in the response for the reason the rate-divisor
    gate logs two numbers instead of a verdict (FlowLinkUsageCollector.cpp:2010-2019): a label
    is the code grading its own homework, and a reader who cannot see the inputs cannot tell a
    passing check from a check that never ran.
    """
    edges = data["edges"]
    if not edges:
        return ["no edges in the graph, so this check examined nothing -- it is not a pass"]

    answered = [e for e in edges if "telemetry_status" in e]
    if not answered:
        return [
            f"no edge of {len(edges)} carries telemetry_status, so whether any link has gone "
            f"silent cannot be determined from this response. This kernel predates the A-4f "
            f"fix: a link that stopped being sampled reads exactly 0 bps and is "
            f"indistinguishable here from an idle one. Reported rather than passed."
        ]

    out = []
    for e in answered:
        if e.get("telemetry_status") != "silent":
            continue
        out.append(
            f"edge {e['src_dpid']}:{e['src_interface']}->{e['dst_dpid']}:{e['dst_interface']} "
            f"is silent: its sampling agent has reported on no port for "
            f"{e.get('agent_last_sample_age_seconds', 'an unknown time')}s, so its "
            f"{e['link_bandwidth_usage_bps']} bps is an absence of telemetry and not a "
            f"measurement (A-4f). If this switch was power-cycled, its sFlow record was not "
            f"restored."
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


def inv_dispatch_counters_close(data, ctx):
    """
    dispatched == succeeded + failed, and the failure list is consistent with the count.

    [Co-developed with claude code -- Adam]
    The three counters are written at one call site (DispatchOutcomeLog::record), so arithmetic
    closure is the cheapest proof that no path increments one without the others -- a `record()`
    that returned early on some op would leave `dispatched` ahead of the sum, and every number
    would still look plausible on its own.

    dropped_after_stop is deliberately NOT in the sum: those jobs were refused before any
    southbound attempt, so they are disjoint from all three. Adding it here would make a healthy
    shutdown look like a counting bug.
    """
    c = data.get("counters") or {}
    dispatched, succeeded, failed = c.get("dispatched"), c.get("succeeded"), c.get("failed")
    if None in (dispatched, succeeded, failed):
        return ["counters is missing one of dispatched/succeeded/failed"]

    out = []
    if dispatched != succeeded + failed:
        out.append(f"dispatched ({dispatched}) != succeeded ({succeeded}) + failed ({failed}) "
                   f"= {succeeded + failed}; some outcome is counted in one place and not the "
                   f"other")

    # A failure list longer than the failures counted, or non-empty with failed == 0, means the
    # ring and the counter disagree about what happened.
    listed = len(data.get("recent_failures") or [])
    capacity = data.get("recent_failures_capacity") or 0
    evicted = data.get("recent_failures_evicted") or 0
    if listed > failed:
        out.append(f"recent_failures lists {listed} entries but only {failed} failure(s) were "
                   f"counted")
    if capacity and listed > capacity:
        out.append(f"recent_failures lists {listed} entries, above its stated capacity "
                   f"{capacity}")
    if evicted and listed < capacity:
        out.append(f"recent_failures_evicted is {evicted} while the list holds {listed} of "
                   f"{capacity} -- nothing should have aged out of a list that is not full")
    return out


def inv_dispatcher_is_running(data, ctx):
    """
    The dispatcher must be accepting work.

    [Co-developed with claude code -- Adam]
    Checked only when the field is present, so this describes an older kernel correctly instead
    of failing it for lacking a field it never had.

    Why it is worth a check at all: a stopped dispatcher refuses every job it is handed and
    counts it under dropped_after_stop, while POST /ndt/install_flow_entry goes on answering
    200 {"status":"queued"}. Every other contract check in this file would stay green through
    that, which is A-7's shape exactly -- the write fails and no API surface says so.
    """
    if "dispatcher_running" not in data:
        return []
    if data["dispatcher_running"] is not True:
        dropped = (data.get("counters") or {}).get("dropped_after_stop", "unknown")
        return [f"the flow dispatcher is not running, so every queued write is being refused "
                f"(dropped_after_stop={dropped}) while install_flow_entry still answers "
                f"'queued'"]
    return []


def inv_power_state_values(data, ctx):
    """
    [Co-developed with claude code -- Adam] -- Q12.
    Two shapes, because this tool is pointed at whatever kernel is deployed: the pre-split
    scalar "ON"/"OFF", and the post-split {"admin_state": "on"|"off", "reachable": bool}. An
    object missing either half is reported: half an answer here is what made a crashed switch
    and a commanded-off one indistinguishable in the first place.
    """
    bad = {}
    for k, v in data.items():
        if isinstance(v, dict):
            if str(v.get("admin_state", "")).strip().lower() not in ("on", "off") \
                    or not isinstance(v.get("reachable"), bool):
                bad[k] = v
        elif v not in ("ON", "OFF"):
            bad[k] = v
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
                     inv_edges_enabled, inv_link_bandwidth_sane,
                     inv_no_silent_telemetry],
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

    # [Co-developed with claude code -- Adam]
    # KNOWN-ISSUES A-7's answer surface. Registered since 636f9ab and uncovered until now, which
    # is the wrong endpoint to leave uncovered: it exists so that a queued write that failed can
    # be found, so if it stopped reporting, this suite going green would be the symptom AND the
    # reason nobody noticed.
    #
    # READ, not MUTATE: it reads counters off the dispatcher under its own lock and programs
    # nothing. Safe on a live fabric and safe to run without --allow-mutations, which matters
    # because it is most useful precisely when a mutation check has just failed.
    dict(name="get_flow_dispatch_status", method="GET",
         path="/ndt/get_flow_dispatch_status",
         category=READ, schema=DISPATCH_STATUS,
         invariants=[inv_dispatch_counters_close, inv_dispatcher_is_running],
         note="A-7: the only API surface on which a failed queued write is visible. "
              "counters cover the four dispatch routes only -- boot-time programming runs in "
              "a different process and is not counted here"),

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
         # [Co-developed with claude code -- Adam] -- Q12.
         # OneOf, not a replacement: a kernel from before the split answers with the bare
         # "ON"/"OFF" string, and the contract tool is run against deployed kernels. The object
         # form is the one that can tell a commanded power-off from a switch that crashed --
         # which is the entire reason this endpoint is named in the finding.
         schema=MapOf(OneOf(Str(),
                            Obj({"admin_state": Str(allowed=("on", "off")),
                                 "reachable": Bool()})),
                      key_check=is_ipv4_string, key_desc="IPv4 address"),
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

    # [Co-developed with claude code -- Adam]
    # OV-3, 2026-09-04. This accepted all three answers, so it agreed with the kernel whichever
    # one came back -- and the one that did come back was 200 {"num_of_flows": 0}, which is the
    # defect: a dpid that names no switch was indistinguishable from a real switch carrying no
    # traffic. Tightened to 404 alone, the same answer install_flow_entry has always given for
    # the same dpid. A kernel from before that fix now fails this check, which is the point.
    dict(name="get_num_of_flows__unknown_dpid", method="POST",
         path="/ndt/get_num_of_flows_passing_a_switch",
         body={"dpid": 999999999999},
         category=ERRORPATH, expect_status=[404],
         schema=Any_(),
         note="404, not 200-with-zero: 'no such switch' and 'no traffic' must be"
              " distinguishable. install_flow_entry answers 404 for this dpid."),

    # The twin. It had no error-path case at all, so the same defect on the traffic-load endpoint
    # was outside the contract's field of view entirely.
    dict(name="get_total_input_traffic_load__unknown_dpid", method="POST",
         path="/ndt/get_total_input_traffic_load_passing_a_switch",
         body={"dpid": 999999999999},
         category=ERRORPATH, expect_status=[404],
         schema=Any_(),
         note="the twin of get_num_of_flows__unknown_dpid; added 2026-09-04 with OV-3"),

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
         schema=OneOf(Obj({"status": Str(nonempty=True), "recording": Bool()},
                          optional={"message": Str()}),
                      Obj({"error": Str(nonempty=True)}, optional={"details": Str()})),
         note="state is a QUERY parameter, not a body field -- the body is ignored. "
              "`recording` is required on the success shape: all three documented success "
              "shapes carry it and two of them mean 'no row will ever be written', so "
              "status=='success' cannot tell a caller whether logging is live "
              "(2026-01-02_ndt_api.md section 39)"),

    dict(name="historical_logging_disable", method="POST", path="/ndt/historical_logging",
         query={"state": "disable"},
         category=MUTATE, expect_status=[200, 500],
         schema=OneOf(Obj({"status": Str(nonempty=True), "recording": Bool()},
                          optional={"message": Str()}),
                      Obj({"error": Str(nonempty=True)}, optional={"details": Str()})),
         note="restores whatever the enable above changed. `recording` required, as above"),

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
