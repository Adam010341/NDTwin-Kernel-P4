"""Every cell, control and self-check of the health check, as rows. Adding one is one row.

[Co-developed with claude code -- Adam]

DESIGN 2.3 (the 47 cells and two controls), 2.1 (the five self-checks and rule D's edges) and
section 12 (the Cut-1 refinements: SC-count, SC-reg, SC-qstamp, SC-ttl, K3's dependency, P4's
verdict). The rows marked q3b are the six categories outside the 16 dimensions and the varbit
cell, added in Cut 1 for the decision-maker's Q3(b); DESIGN.md section 13 (the copy under
doc/audit) describes them so they are reviewed as design.

Predictions are NOT here. They live in doc/audit/2026-10-03_p4-health-check/expected_today.tsv,
committed before any live run, and are read from that file (expected.py) -- a prediction this
module could compute would be a prediction made after the fact.

Each cell's `cannot` and `compare` take the observation dict that verdict.decide documents. The
keys under `answer` / `oracle` each cell reads are named in its function.
"""
from __future__ import annotations

from .verdict import (GREEN, NOT_RUN, PROBE_BROKEN, RED, Verdict, broken, green, not_run,
                      partial, red, unattributed)

# --- the markers' dports, mirrored from exercise/src/hc_main.p4's HC_DPORT_* -------------------
DPORTS = {"K1": 40011, "K2": 40012, "MT1": 40021, "MT3": 40023, "R2": 40031, "D1": 40041,
          "P2": 40050, "C1": 40061, "MCAST": 40062, "Q1": 40071, "TTL1": 40081, "RC1": 40091,
          "HR1": 40092, "HR2": 40093, "VB1": 40095, "CH6": 40096}
ETHERTYPES = {"CH1": 0x1212, "CH2": 0x1234, "CH7": 0x1236, "HU1": 0x86DD, "HB": 0x88B5}

#: TP2 / TP4 / CP4: how long a cut link may take to read `is_up=false` (DESIGN 2.3).
LINK_DOWN_DEADLINE_S = 20.0
#: Q1: the shaped link's rate, kbit/s, on both of its interfaces.
SHAPED_KBIT = 500.0
SHAPED_IFACES = ("s1-eth5", "s3-eth2")

CORE_DIMENSIONS = ("pipeline_load", "tables", "pre_multicast", "pre_clone", "counters", "meters",
                   "registers", "digest", "packet_io", "custom_headers", "queue_metadata",
                   "checksum", "ttl_or_hop", "topology", "control_plane_mode", "verification")
Q3B_DIMENSIONS = ("action_profile", "idle_timeout", "value_set", "recirculate", "hash_random",
                  "header_union")


class Cell(object):
    def __init__(self, id, dimension, scope, kind, bringup, cut, compare=None, cannot=None,
                 gates=(), self_checks=(), red_attribution=("structural",), negative_read=False,
                 needs_oracle=True, precondition=None, alias_of=None, by_design=None, q3b=False):
        self.id, self.dimension, self.scope, self.kind = id, dimension, scope, kind
        self.bringup, self.cut = bringup, cut
        self.compare, self.cannot = compare, cannot
        self.gates, self.self_checks = tuple(gates), tuple(self_checks)
        self.red_attribution = tuple(red_attribution)
        self.negative_read, self.needs_oracle = negative_read, needs_oracle
        self.precondition = precondition          # obs -> (ok, why), or None
        self.alias_of, self.by_design, self.q3b = alias_of, by_design, q3b


class SelfCheck(object):
    def __init__(self, id, check, gates=(), self_checks=(), q3b=False):
        self.id, self.check = id, check
        self.gates, self.self_checks, self.q3b = tuple(gates), tuple(self_checks), q3b


class Control(object):
    """A known-answer control (K1-neg, T3-neg): the answer is a 404, and anything else means
    the instrument is wrong -- PROBE-BROKEN, never RED."""

    def __init__(self, id, of, expect_http):
        self.id, self.of, self.expect_http = id, of, expect_http

    def judge(self, obs):
        if not obs or (obs.get("answer") or {}).get("http") is None:
            return Verdict(NOT_RUN, "control not observed", phase="control")
        http = obs["answer"]["http"]
        if http == self.expect_http:
            return Verdict(GREEN, "answered %d, the expected refusal" % http, phase="control")
        return Verdict(PROBE_BROKEN, "known-answer control answered %s, not %d"
                       % (http, self.expect_http), phase="control")


# --- small readers shared by the rows ------------------------------------------------------------

def A(obs):
    return obs.get("answer") or {}


def O(obs):
    return obs.get("oracle") or {}


def thrift_ev(obs):
    return ("thrift",) if obs.get("oracle") is not None else ()


def route_missing(obs):
    """NDTwin's openapi lacks the endpoint this cell needs. A structural "cannot" -- never the
    same thing as "the object is absent" (mutation M2)."""
    return A(obs).get("route") is False


def no_route(what):
    def cannot(obs):
        if route_missing(obs):
            return red("no route: the proxy's openapi has no %s endpoint" % what, "structural",
                       *thrift_ev(obs))
        return None
    return cannot


def http_cannot(codes, what):
    def cannot(obs):
        http = A(obs).get("http")
        if http in codes:
            return red("%s answered %d" % (what, http), "structural", *thrift_ev(obs))
        return None
    return cannot


def counter_reading(a):
    """NDTwin's counter delta, or None unless the read was a 200. A 503 is EXPLICITLY NOT A ZERO
    (api_routes.py:963-1029); reading it as one is mutation M5."""
    if a.get("http") != 200:
        return None
    return a.get("delta")


def heartbeat_usable(hb):
    """`heartbeat.state == "usable"` -- not "the heartbeat block is there": the proxy runs a
    watchdog on every foreign fabric (main.py:2326-2332), so non-null proves nothing (M15)."""
    return isinstance(hb, dict) and hb.get("state") == "usable"


def g1_holds(g1):
    """G1 (_common.sh:911,1065-1140): the on-path set is non-empty, the main path's integral is
    above zero, and every link off the path saw less than one sample."""
    if not isinstance(g1, dict):
        return False
    return bool(g1.get("on_path")) and (g1.get("main_integral") or 0) > 0 \
        and (g1.get("off_path_max") if g1.get("off_path_max") is not None else 1) < 1


def side_row_grew(a, ethertype):
    """The side table has a row for exactly this ethertype AND this host pair, and its
    `samples` went up inside the window (DESIGN 2.3 CH7; section 12 item 6)."""
    pair = a.get("pair") or {}
    src, dst = str(pair.get("src_mac", "")).lower(), str(pair.get("dst_mac", "")).lower()

    def find(rows):
        for row in rows or []:
            et = row.get("ethertype")
            try:
                et = int(et, 0) if isinstance(et, str) else int(et)
            except (TypeError, ValueError):
                continue
            if et == ethertype and str(row.get("src_mac", "")).lower() == src \
                    and str(row.get("dst_mac", "")).lower() == dst:
                return row
        return None
    after = find(a.get("side_after"))
    if after is None:
        return False
    before = find(a.get("side_before"))
    return int(after.get("samples") or 0) > int((before or {}).get("samples") or 0)


def deadline_met(seconds):
    return seconds is not None and seconds <= LINK_DOWN_DEADLINE_S


# --- the rows' functions, one block per dimension --------------------------------------------------

def pl1(obs):
    a, o, expect = A(obs), O(obs), obs.get("expect") or {}
    for dpid, sha in sorted(expect.get("pipelines", {}).items()):
        got = (a.get("pipelines") or {}).get(dpid)
        if got != sha:
            return red("s%s reports pipeline %s, expected %s" % (dpid, got, sha), "structural")
    if o.get("alt_table", {}).get("1") is not True:
        return red("thrift: s1 does not list the table only hc_alt has", "structural", "thrift")
    return green("every switch runs its program; only s1 lists the hc_alt table")


def pl2(obs):
    a, o = A(obs), O(obs)
    if "pipeline_push" not in (a.get("skipped") or []):
        return red("the proxy did not skip pipeline_push on an external fabric", "structural")
    if o.get("primary") is not True:
        return red("the external controller is not primary", "structural")
    if o.get("set_pipeline_ok") is not True:
        return red("the controller's SetForwardingPipelineConfig did not return OK", "structural")
    return green("pipeline_push skipped; the controller is primary and pushed its own")


def t1(obs):
    a, o, expect = A(obs), O(obs), obs.get("expect") or {}
    for dpid, counts in sorted((a.get("counts") or {}).items()):
        if counts.get("failed", 0) > 0:
            return red("s%s: %d entr(ies) failed" % (dpid, counts["failed"]), "structural")
        if counts.get("recorded") != counts.get("applied"):
            return red("s%s: recorded %s, applied %s" % (dpid, counts.get("recorded"),
                                                         counts.get("applied")), "structural")
    for dpid, want in sorted((expect.get("entries") or {}).items()):
        got = (o.get("dumps") or {}).get(dpid)
        if got is None or set(got) != set(want):
            return red("s%s: the thrift dump is not the package's entries" % dpid, "structural",
                       "thrift")
    return green("recorded == applied, failed == 0, every dump matches entry for entry")


def t2(obs):
    a, o = A(obs), O(obs)
    if a.get("applied") is not True:
        return red("NDTwin does not report s2's runtime default as applied", "structural")
    got = o.get("s2_default") or (None, ())
    if (got[0], tuple(got[1])) != ("HcIngress.stamp", (0x2A,)):
        return red("thrift: s2's default is %r, not stamp(0x2A)" % (o.get("s2_default"),),
                   "structural", "thrift")
    return green("s2's default is the runtime stamp(0x2A)")


def write_then_read(what):
    """POST answered 200 and thrift shows the entry afterwards (T3-T6, M2, AP1, ...)."""
    def compare(obs):
        a, o = A(obs), O(obs)
        if a.get("http") is not None and a.get("http") != 200:
            return red("%s answered %s" % (what, a.get("http")), "structural")
        for key in ("present_after", "mask_ok", "priority_ok", "ports_ok", "points_to_member"):
            if key in o and o[key] is not True:
                return red("thrift after the write: %s is not true" % key, "structural", "thrift")
        return green("written, and thrift shows it")
    return compare


def t7(obs):
    a, o = A(obs), O(obs)
    if a.get("http") != 200:
        return red("POST answered %s for the overlapping pair" % a.get("http"), "structural")
    if o.get("order_ok") is not True:
        return red("thrift: the two overlapping entries' priorities are in the wrong order",
                   "structural", "thrift")
    return green("both overlapping entries present, priority order right")


def t8_cannot(obs):
    if A(obs).get("journaled") is False:
        return red("switch_state's `journaled` is the constant false (api_routes.py:765-767)",
                   "structural")
    return None


def t8(obs):
    if A(obs).get("journaled") is True:
        return green("journaled; the restart half is deferred (DESIGN 2.3)")
    return not_run("switch_state carries no journaled field for the entry")


def pft_cannot(obs):
    a = A(obs)
    if a.get("rc") not in (None, 0) and a.get("g5_rows", 0) >= 1 and a.get("other_fail_rows", 0) == 0:
        return red("pre-flight refuses a boot entry that names a TERNARY field (G5 not done)",
                   "structural")
    return None


def pft(obs):
    a = A(obs)
    if a.get("rc") == 0:
        return green("pre-flight accepts a boot ternary entry")
    return broken("pre-flight failed on something other than the ternary row (%s other FAIL "
                  "row(s)): a path or format error, not the G5 answer" % a.get("other_fail_rows"))


def m1(obs):
    a, o = A(obs), O(obs)
    if a.get("applied") != a.get("recorded"):
        return red("multicast applied %s of %s" % (a.get("applied"), a.get("recorded")), "structural")
    if o.get("s1_group1") != frozenset({1, 2}):
        return red("thrift: s1's group 1 is %r, not {1, 2}" % (o.get("s1_group1"),), "structural",
                   "thrift")
    return green("group 1 on s1 replicates to {p1, p2}")


def m2(obs):
    a, o = A(obs), O(obs)
    if a.get("http") != 200:
        return red("POST /p4/multicast_group answered %s" % a.get("http"), "structural")
    if o.get("group2_after") != frozenset(o.get("declared") or ()):
        return red("thrift: group 2 is %r after the write" % (o.get("group2_after"),),
                   "structural", "thrift")
    return green("group 2 written and replicating to the declared ports")


def c1(obs):
    a, o = A(obs), O(obs)
    if a.get("applied") != 1:
        return red("clone applied %s, not 1" % a.get("applied"), "structural")
    if o.get("ports") != frozenset({1}):
        return red("thrift: session 7's group replicates to %r, not {p1}" % (o.get("ports"),),
                   "structural", "thrift")
    return green("session 7 on s2 mirrors to p1")


def k1_cannot(obs):
    if A(obs).get("http") == 404:
        return red("GET /p4/counter answered 404 (not in this pipeline)", "structural",
                   *thrift_ev(obs))
    return None


def counter_equal(obs):
    a, o = A(obs), O(obs)
    mine = counter_reading(a)
    if mine is None:
        return red("GET /p4/counter answered %s, which is not a reading" % a.get("http"),
                   "structural", "thrift")
    if mine != o.get("delta"):
        return red("NDTwin read %s, thrift %s" % (mine, o.get("delta")), "structural", "thrift")
    return green("NDTwin's counter delta equals thrift's (%s)" % mine)


def rates_written(obs):
    a, o = A(obs), O(obs)
    if a.get("http") is not None and a.get("http") != 200:
        return red("the meter write answered %s" % a.get("http"), "structural")
    if o.get("rates_after") != o.get("target"):
        return red("thrift: the meter's rates are %r, not %r" % (o.get("rates_after"), o.get("target")),
                   "structural", "thrift")
    return green("the rates written are the rates thrift reads")


def r2(obs):
    a, o = A(obs), O(obs)
    if a.get("value") is None:
        return not_run("NDTwin returned no register value")
    if a["value"] != o.get("value"):
        return red("NDTwin read %s, thrift %s" % (a["value"], o.get("value")), "structural", "thrift")
    return green("NDTwin's register read equals register_read")


def r3(obs):
    o = O(obs)
    if o.get("value_after") != o.get("target"):
        return red("thrift: the register holds %s, not %s" % (o.get("value_after"), o.get("target")),
                   "structural", "thrift")
    return green("the value written is the value register_read returns")


def exit_cannot(what, cite):
    def cannot(obs):
        if A(obs).get("exit") is False:
            return red("NDTwin has no %s exit (%s)" % (what, cite), "structural")
        return None
    return cannot


def d1(obs):
    a, o = A(obs), O(obs)
    if a.get("fields") != o.get("fields"):
        return red("NDTwin's digest content %r is not the marker's %r" % (a.get("fields"), o.get("fields")),
                   "structural")
    return green("NDTwin's digest equals the marker's fields")


def argv_flag(flag, value, what):
    def compare(obs):
        o = O(obs)
        if o.get("argv_has") is True:
            return green("the bmv2 argv has %s%s" % (flag, " %s" % value if value else ""))
        return red("the bmv2 argv lacks %s%s (%s)" % (flag, " %s" % value if value else "", what),
                   "structural")
    return compare


def delivered(obs):
    if (O(obs).get("received") or 0) >= 1:
        return green("delivered")
    return red("nothing arrived where NDTwin's endpoint said it would", "structural")


def p4(obs):
    """Section 12 item 8, decided: the controller receiving its packet-in is PARTIAL(b) -- the
    exercise's own controller did NDTwin's half of packet_io (GAP-2b 0.3 (b)). Nothing arriving
    is RED, attributed only when B's controller shows it is primary and its own writes work."""
    if O(obs).get("received") is True:
        return partial("b", "the controller got its packet-in; no NDTwin code is on that path")
    return red("no packet-in on dport 40050 reached the external controller")


def identity_cell(ethertype=None, partial_ok=False, g1=True):
    """CH1/CH2/CH7/CH8/HU1/V1-shaped cells: G1, then flow identity, then the side table."""
    def compare(obs):
        a = A(obs)
        if g1 and not g1_holds(a.get("g1")):
            return red("G1 does not hold: link usage is not on the path", "structural")
        if a.get("flow_identity") is True:
            return green("G1 holds and the flow table has the sender's 5-tuple")
        if ethertype is not None and side_row_grew(a, ethertype):
            if partial_ok:
                return partial("a", "only the side table: ethertype 0x%04X, this host pair, "
                                    "samples grew" % ethertype)
            return green("G1 holds and the side table has 0x%04X for this pair, samples grew"
                         % ethertype)
        if ethertype is None and not partial_ok:
            return green("G1 holds")
        return red("no flow identity and no side-table row for this pair", "structural")
    return compare


def flow_correct(obs):
    if A(obs).get("flow_identity") is True:
        return green("the flow table has the right identity")
    return red("the flow table's identity is wrong or missing", "structural")


def ch4(obs):
    ident = A(obs).get("identity")
    if ident in ("correct", "disclosed"):
        return green("flow port is the real port, or NDTwin says it cannot decode the shim")
    return red("the flow table shows a port that is not the real one", "structural")


def q1(obs):
    a, o = A(obs), O(obs)
    if o.get("shaped") is not True:
        return red("no 0.5 Mbit/s qdisc on %s" % " and ".join(SHAPED_IFACES), "structural")
    if set(a.get("sent_idents") or ()) != {0}:
        return not_run("the sender did not send identification 0, so a flag proves nothing")
    stamped = [r for r in (o.get("received") or []) if int(r.get("ident", 0)) & 0x8000]
    if not stamped:
        return not_run("no packet carried the 0x8000 stamp flag")
    if any(int(r["ident"]) & 0x7FFF > 0 for r in stamped):
        return green("shaped, stamped, and at least one qdepth > 0")
    return unattributed("shaped and stamped, but qdepth was 0 on every packet")


def cs1(obs):
    hosts = O(obs).get("tx_checksum_off") or {}
    if hosts and all(v is True for v in hosts.values()):
        return green("tx-checksumming off on every host")
    return red("tx-checksumming is on (or unknown) on %s"
               % sorted(h for h, v in hosts.items() if v is not True), "structural")


def ttl1(obs):
    if (O(obs).get("received") or 0) >= 1:
        return green("the marker reached the receiver")
    return not_run("no marker arrived")


def tp1(obs):
    a, o = A(obs), O(obs)
    for item in ("switches", "hosts", "edges", "ports"):
        if a.get(item) != o.get(item):
            return red("get_graph_data's %s differ from the fabric's" % item, "structural")
    return green("switches, hosts (IP, MAC), edges and ports all equal the fabric")


def link_cut(obs):
    a = A(obs)
    if not deadline_met(a.get("down_after_s")):
        return red("the cut edge read is_up=false after %s s (deadline %d s)"
                   % (a.get("down_after_s"), LINK_DOWN_DEADLINE_S), "structural")
    if a.get("recovered") is not True:
        return red("the edge did not come back after the netem was removed", "structural")
    return green("is_up=false within the deadline, and back after")


def tp2_pre(obs):
    hb = A(obs).get("heartbeat")
    if not heartbeat_usable(hb):
        return False, "heartbeat state is %r, not usable" % ((hb or {}).get("state"),)
    if (hb or {}).get("missing_directions"):
        return False, "heartbeat missing directions %s" % hb["missing_directions"]
    return True, ""


def tp4_pre(obs):
    a = A(obs)
    if a.get("drop_check_rc") != 0:
        return False, "drop check rc %s" % a.get("drop_check_rc")
    if a.get("withheld") is not False:
        return False, "heartbeat.withheld present (or unknown)"
    if not heartbeat_usable(a.get("heartbeat")):
        return False, "heartbeat not usable"
    return True, ""


def cp2(obs):
    a, o = A(obs), O(obs)
    if a.get("http") == 200 or o.get("entry_present") is True:
        return red("the proxy wrote on an external fabric (POST %s)" % a.get("http"), "structural")
    if a.get("http") != 409:
        return red("POST answered %s, not the refusal 409" % a.get("http"), "structural")
    if o.get("controller_entry_present") is not True:
        return broken("the same dump does not show the controller's own entry, so this read "
                      "cannot tell absent from unreadable")
    return green("409, nothing written, and the controller's own entry is there")


def cp4_pre(obs):
    if not heartbeat_usable(A(obs).get("heartbeat")):
        return False, "heartbeat not usable"
    return True, ""


def cp4(obs):
    a, o = A(obs), O(obs)
    caps = a.get("capabilities") or {}
    if (caps.get("ipv4_route"), caps.get("binding_source"), caps.get("reroute")) != ("ndtwin", "package", True):
        return red("capabilities are %r" % (caps,), "structural")
    if o.get("kernel_route_present") is not True:
        return red("thrift: no kernel-written route on s1", "structural", "thrift")
    if o.get("port_after_cut") != 5 or not deadline_met(a.get("rerouted_after_s")):
        return red("s1's route to h6 did not move to p5 within the deadline", "structural", "thrift")
    return green("roles bound, the kernel's route moved to p5 after the cut")


def v2(obs):
    a = A(obs)
    if a.get("bytes_match") is not True:
        return red("link bytes do not match netdev", "structural")
    if a.get("flow_identity") is True:
        return green("bytes match and the flow table has the identity")
    return partial("a", "bytes match; the identity is only in the side table")


def ap1(obs):
    return write_then_read("the action-profile write")(obs)


def it1_cannot(obs):
    a = A(obs)
    if a.get("idle_field") is False or a.get("notification_exit") is False:
        return red("NDTwin can neither write an idle timeout nor pass IdleTimeoutNotification on "
                   "(p4_client.py:526-551 handles packet and arbitration only)", "structural")
    return None


def it1(obs):
    if A(obs).get("timeout_reported") is True:
        return green("NDTwin reported the entry's idle timeout")
    return red("the entry aged out on the switch and NDTwin said nothing", "structural")


def rc1(obs):
    a = A(obs)
    if not g1_holds(a.get("g1")):
        return red("G1 does not hold for the recirculated flow", "structural")
    if a.get("bytes_match") is not True:
        return red("link usage is not netdev's bytes: the twin counted a recirculated or "
                   "resubmitted pass as traffic", "structural")
    if a.get("flow_identity") is not True:
        return red("the flow table lost the recirculated flow's identity", "structural")
    return green("counted once, on the path, with its identity")


def multipath(obs):
    """HR1 / HR2: the twin shows usage on exactly the uplinks netdev says carried the flow.
    (HR2's "the coin used both" is its precondition, hr2_pre, not repeated here.)"""
    if True:
        a, o = A(obs), O(obs)
        carried = o.get("carried") or {}
        seen = a.get("seen") or {}
        wrong = sorted(l for l in ("s1-eth4", "s1-eth5") if bool(carried.get(l)) != bool(seen.get(l)))
        if wrong:
            return red("the twin's link usage disagrees with netdev on %s" % ", ".join(wrong),
                       "structural")
        return green("the twin shows usage on exactly the uplinks netdev says carried it")


def hr2_pre(obs):
    carried = O(obs).get("carried") or {}
    if all(carried.get(l) for l in ("s1-eth4", "s1-eth5")):
        return True, ""
    return False, "netdev does not show both uplinks carrying the random flow"


# --- self-checks ---------------------------------------------------------------------------------

def hops_from_lpm(dumps, links, start_dpid, dst_ip, max_hops=8):
    """How many switches a packet to `dst_ip` crosses from `start_dpid`, walked over the lpm
    entries THRIFT read off each switch (section 12 item 4: h4->h6 has a 2-hop and a 4-hop path,
    so the topology alone cannot say which). `dumps` {dpid: {dst_ip: port}}, `links`
    {(dpid, port): dpid of the next switch}; a port not in `links` is a host port. None when the
    walk leaves the dumps or loops."""
    dpid, hops, seen = start_dpid, 0, set()
    while hops < max_hops:
        if dpid in seen:
            return None
        seen.add(dpid)
        port = (dumps.get(dpid) or {}).get(dst_ip)
        if port is None:
            return None
        hops += 1
        nxt = links.get((dpid, port))
        if nxt is None:
            return hops
        dpid = nxt
    return None


def sc_fwd(obs):
    ok, total = obs.get("pingall") or (0, 0)
    want = obs.get("expected_total", 30)
    if total != want or ok != want:
        return False, "pingall %s/%s, expected %s/%s" % (ok, total, want, want)
    if obs.get("dump_ok") is not True:
        return False, "thrift table_dump does not show every T1 entry"
    return True, "pingall %d/%d and the T1 entries are in the dumps" % (ok, total)


def sc_count(obs):
    """Section 12 item 1: thrift's delta equals what crossed the counting switch -- its ingress
    netdev delta for the markers when that is known, else the sender's count AND zero loss at
    the receiver (an upstream drop would otherwise read as a counting bug)."""
    delta = obs.get("thrift_delta")
    if obs.get("netdev_in") is not None:
        if delta == obs["netdev_in"]:
            return True, "c_in delta %s == markers in at the switch" % delta
        return False, "c_in delta %s != %s markers in at the switch" % (delta, obs["netdev_in"])
    sent, got = obs.get("sent"), obs.get("received")
    if not sent or got != sent:
        # Loss somewhere on the path: the counting switch may have seen fewer than were sent, so
        # neither "equal" nor "unequal" says anything about the program. Not judged -> NOT RUN.
        return None, "the receiver got %s of %s sent: with loss on the path the count cannot be judged" % (got, sent)
    if delta == sent:
        return True, "c_in delta %s == sent == received" % delta
    return False, "c_in delta %s, sent and received %s" % (delta, sent)


def sc_reg(obs):
    """Section 12 item 2: the register must hold the NON-ZERO value the marker chose."""
    chosen, got = obs.get("chosen"), obs.get("register")
    if not chosen:
        return False, "the marker chose no non-zero value"
    if got != chosen:
        return False, "register_read %s, the marker wrote %s" % (got, chosen)
    return True, "register holds the marker's %s" % chosen


def sc_qstamp(obs):
    """Section 12 item 3: the sender must have sent identification 0, so the flag cannot be the
    sender's own."""
    if set(obs.get("sent_idents") or ()) != {0}:
        return False, "the sender's identifications were %s, not {0}" % sorted(obs.get("sent_idents") or ())
    if (obs.get("stamped") or 0) < 1:
        return False, "no received packet carries the 0x8000 flag"
    return True, "%d stamped packet(s)" % obs["stamped"]


def sc_ttl(obs):
    hops = obs.get("hops_lpm")
    if hops is None:
        return False, "no hop count from the thrift-read lpm path"
    ttls = obs.get("ttls") or []
    want = obs.get("sent_ttl", 64) - hops
    if not ttls:
        return False, "no marker received"
    bad = [t for t in ttls if t != want]
    if bad:
        return False, "ttl %s, expected %d (64 - %d hops)" % (sorted(set(bad)), want, hops)
    return True, "ttl %d after %d hops" % (want, hops)


def sc_recirc(obs):
    flags = obs.get("flags") or []
    if not flags:
        return False, "no recirculation marker received"
    bad = [f for f in flags if f & 0x0C != 0x0C]
    if bad:
        return False, "diffserv flags %s lack resubmit|recirculate (0x0C)" % sorted(set(bad))
    return True, "resubmitted and recirculated"


def sc_union(obs):
    hops = obs.get("hops")
    lims = obs.get("hop_limits") or []
    if hops is None or not lims:
        return False, "no IPv6 marker received, or no hop count"
    want = obs.get("sent_hop_limit", 64) - hops
    if any(h != want for h in lims):
        return False, "hop limits %s, expected %d" % (sorted(set(lims)), want)
    return True, "the union's IPv6 member was forwarded and rewritten"


SELF_CHECKS = [
    SelfCheck("SC-fwd", sc_fwd, gates=("PL1", "T1", "TP1")),
    SelfCheck("SC-count", sc_count, self_checks=("SC-fwd",)),
    SelfCheck("SC-reg", sc_reg, self_checks=("SC-fwd",)),
    SelfCheck("SC-qstamp", sc_qstamp, self_checks=("SC-fwd",)),
    SelfCheck("SC-ttl", sc_ttl, gates=("TP1",), self_checks=("SC-fwd",)),
    SelfCheck("SC-recirc", sc_recirc, self_checks=("SC-fwd",), q3b=True),
    SelfCheck("SC-union", sc_union, gates=("TP1",), self_checks=("SC-fwd",), q3b=True),
]

NEG = dict(negative_read=True)
BM = ("structural", "bmv2")

CELLS = [
    # pipeline_load
    Cell("PL1", "pipeline_load", "core", "static", "A", 2, pl1, **NEG),
    Cell("PL2", "pipeline_load", "core", "active", "B", 4, pl2),
    # tables
    Cell("T1", "tables", "core", "active", "A", 2, t1, **NEG),
    Cell("T2", "tables", "core", "static", "A", 2, t2, **NEG),
    Cell("T3", "tables", "core", "active", "A", 2, write_then_read("POST /p4/table_entry"),
         cannot=http_cannot((404, 501), "POST /p4/table_entry"), **NEG),
    Cell("T4", "tables", "ext", "active", "A", 2, write_then_read("POST /p4/table_entry (ternary)"),
         cannot=http_cannot((501,), "POST /p4/table_entry (ternary)"), red_attribution=BM, **NEG),
    Cell("T5", "tables", "ext", "active", "A", 2, write_then_read("POST /p4/table_entry (range)"),
         cannot=http_cannot((501,), "POST /p4/table_entry (range)"), red_attribution=BM, **NEG),
    Cell("T6", "tables", "ext", "active", "A", 2, write_then_read("POST /p4/table_entry (optional)"),
         cannot=http_cannot((501,), "POST /p4/table_entry (optional)"), red_attribution=BM, **NEG),
    Cell("T7", "tables", "ext", "active", "A", 2, t7, gates=("T4",), red_attribution=BM, **NEG),
    Cell("T8", "tables", "ext", "static", "A", 2, t8, cannot=t8_cannot, needs_oracle=False),
    Cell("PF-T", "tables", "ext", "static", "S0", 1, pft, cannot=pft_cannot, needs_oracle=False,
         red_attribution=("structural", "bmv2|static")),
    # pre_multicast
    Cell("M1", "pre_multicast", "core", "static", "A", 2, m1, **NEG),
    Cell("M2", "pre_multicast", "core", "active", "A", 2, m2, **NEG),
    # pre_clone
    Cell("C1", "pre_clone", "core", "static", "A", 2, c1, **NEG),
    Cell("C2", "pre_clone", "ext", "static", "A", 2, write_then_read("the clone-session write"),
         cannot=no_route("clone-session"), red_attribution=BM, **NEG),
    # counters
    Cell("K1", "counters", "core", "active", "A", 2, counter_equal, cannot=k1_cannot,
         self_checks=("SC-count",), red_attribution=("structural", "thrift")),
    Cell("K2", "counters", "ext", "active", "A", 2, counter_equal, cannot=k1_cannot,
         red_attribution=BM, precondition=lambda o: ((o.get("pre") or {}).get("ok") is True,
                                                      (o.get("pre") or {}).get("why", ""))),
    Cell("K3", "counters", "core", "active", "B", 4, counter_equal, self_checks=("SC-count",),
         red_attribution=("structural", "thrift")),
    # meters
    Cell("MT1", "meters", "core", "active", "A", 2, rates_written,
         cannot=http_cannot((501,), "/ndt/install_meter_entry"), red_attribution=BM, **NEG),
    Cell("MT2", "meters", "core", "static", "A", 2, rates_written, cannot=no_route("meter"),
         red_attribution=BM, **NEG),
    Cell("MT3", "meters", "ext", "static", "A", 2, rates_written, cannot=no_route("direct-meter"),
         red_attribution=BM, **NEG),
    # registers
    Cell("R2", "registers", "core", "active", "A", 2, r2, cannot=no_route("register read"),
         self_checks=("SC-reg",), red_attribution=("structural", "thrift")),
    Cell("R3", "registers", "core", "static", "A", 2, r3, cannot=no_route("register write"),
         red_attribution=BM, **NEG),
    # digest
    Cell("D1", "digest", "core", "active", "A", 2, d1,
         cannot=exit_cannot("digest", "the stream drops them, p4_client.py:544-545"),
         red_attribution=BM),
    # packet_io
    Cell("P1", "packet_io", "core", "static", "A", 2, argv_flag("--cpu-port", 510, "P1")),
    Cell("P2", "packet_io", "core", "active", "A", 2, delivered,
         cannot=exit_cannot("packet-in", "telemetry/LLDP only, p4_client.py:553-586"),
         red_attribution=BM),
    Cell("P3", "packet_io", "core", "active", "A", 2, delivered, cannot=no_route("packet-out"),
         red_attribution=BM),
    Cell("P4", "packet_io", "core", "active", "B", 4, p4, red_attribution=("bmv2",)),
    # custom_headers
    Cell("CH1", "custom_headers", "core", "active", "A", 3,
         identity_cell(ETHERTYPES["CH1"], partial_ok=True)),
    Cell("CH2", "custom_headers", "core", "active", "A", 3,
         identity_cell(ETHERTYPES["CH2"], partial_ok=True)),
    Cell("CH3", "custom_headers", "core", "active", "A", 3, flow_correct),
    Cell("CH4", "custom_headers", "ext", "active", "A", 3, ch4,
         red_attribution=("structural", "wire")),
    Cell("CH5", "custom_headers", "core", "active", "A", 3, flow_correct),
    Cell("CH6", "custom_headers", "ext", "active", "A", 3, flow_correct),
    Cell("CH7", "custom_headers", "core", "active", "A", 3, identity_cell(ETHERTYPES["CH7"])),
    Cell("CH8", "custom_headers", "ext", "active", "A", 3,
         identity_cell(ETHERTYPES["CH1"], partial_ok=True, g1=False)),
    Cell("VB1", "custom_headers", "ext", "active", "A", 3, q3b=True,
         by_design="NDTwin's half of a varbit tail is CH6's: the twin never parses past L4, and on "
                   "the wire the tail is UDP payload; p4c and bmv2 accepting varbit is proved by "
                   "S0's compile and offline probe, which are not NDTwin's half"),
    # queue_metadata
    Cell("Q1", "queue_metadata", "core", "active", "A", 3, q1, self_checks=("SC-qstamp",)),
    Cell("Q2", "queue_metadata", "ext", "static", "A", 3, argv_flag("--priority-queues", None, "Q2"),
         red_attribution=("structural", "static")),
    # checksum
    Cell("CS1", "checksum", "core", "static", "A", 2, cs1),
    # ttl_or_hop
    Cell("TTL1", "ttl_or_hop", "core", "active", "A", 2, ttl1, self_checks=("SC-ttl",)),
    # topology
    Cell("TP1", "topology", "core", "static", "A", 2, tp1),
    Cell("TP2", "topology", "core", "active", "A", 3, link_cut, precondition=tp2_pre),
    Cell("TP4", "topology", "core", "active", "B", 4, link_cut, precondition=tp4_pre),
    # control_plane_mode
    Cell("CP1", "control_plane_mode", "core", "active", "A", 2, alias_of="T1"),
    Cell("CP2", "control_plane_mode", "core", "active", "B", 4, cp2),
    Cell("CP4", "control_plane_mode", "core", "active", "C", 4, cp4, precondition=cp4_pre, **NEG),
    # verification
    Cell("V1", "verification", "core", "active", "A", 3, identity_cell(None)),
    Cell("V2", "verification", "core", "active", "A", 3, v2),
    # Q3(b): the six categories outside the 16 dimensions (DESIGN.md section 13)
    Cell("AP1", "action_profile", "ext", "active", "A", 2, ap1, cannot=no_route("action-profile member"),
         red_attribution=BM, q3b=True, **NEG),
    Cell("AS1", "action_profile", "ext", "active", "A", 2, ap1, cannot=no_route("action-selector group"),
         red_attribution=BM, q3b=True, **NEG),
    Cell("IT1", "idle_timeout", "ext", "active", "A", 2, it1, cannot=it1_cannot,
         red_attribution=BM, q3b=True),
    Cell("VS1", "value_set", "ext", "active", "A", 2, write_then_read("the value-set write"),
         cannot=no_route("value-set"), red_attribution=BM, q3b=True, **NEG),
    Cell("RC1", "recirculate", "ext", "active", "A", 3, rc1, self_checks=("SC-recirc",), q3b=True),
    Cell("HR1", "hash_random", "ext", "active", "A", 3, multipath, q3b=True),
    Cell("HR2", "hash_random", "ext", "active", "A", 3, multipath, precondition=hr2_pre,
         q3b=True),
    Cell("HU1", "header_union", "ext", "active", "A", 3,
         identity_cell(ETHERTYPES["HU1"], partial_ok=True), self_checks=("SC-union",), q3b=True),
]

CONTROLS = [Control("K1-neg", "K1", 404), Control("T3-neg", "T3", 404)]


class Table(object):
    def __init__(self, cells, self_checks, controls):
        self.cells = list(cells)
        self.self_checks = list(self_checks)
        self.controls = list(controls)
        self.core_dimensions = CORE_DIMENSIONS
        self.dimensions = CORE_DIMENSIONS + Q3B_DIMENSIONS
        ids = [c.id for c in self.cells] + [s.id for s in self.self_checks] + [c.id for c in self.controls]
        if len(ids) != len(set(ids)):
            raise ValueError("duplicate ids in the cell table")

    def cell(self, cid):
        for c in self.cells:
            if c.id == cid:
                return c
        raise KeyError(cid)

    def counted(self, scope=None, q3b=None):
        """The cells that count (CP1 is T1 and is not counted twice)."""
        return [c for c in self.cells if c.alias_of is None
                and (scope is None or c.scope == scope) and (q3b is None or c.q3b == q3b)]


TABLE = Table(CELLS, SELF_CHECKS, CONTROLS)
