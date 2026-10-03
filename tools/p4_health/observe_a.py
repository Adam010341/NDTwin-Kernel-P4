"""Bring-up A's observers (Cut 2): one function per cell, readings in, an observation out.

[Co-developed with claude code -- Adam]

Each function returns the dict verdict.decide reads -- `answer` (NDTwin's half: the proxy, the
kernel, or the proxy's openapi), `oracle` (thrift, ps, the fabric, a sniffer -- never NDTwin),
`negative` (the same-window negative read), `sent` (the SENDER's own count, or the number of
writes the probe issued for a write cell) -- and nothing else is trusted:

  * UNREADABLE IS None. A reply nobody recognised leaves the key None, never False and never 0;
    "looked, and nothing is there" is False / 0 / [] (the observer contract, design 2.1 r4).
  * A negative read is {"absent": True} only when thrift answered and the object was not in a
    reply it recognised; an unreadable negative read is None (step 5 then says NOT RUN).
  * A write cell reads BEFORE it writes: "written then present" needs "absent before" (2.1 r5).
  * `route` comes from the proxy's own openapi (observe.with_route); an unreadable openapi sets
    no route at all. A cell whose endpoint EXISTS but whose request shape the probe does not
    know yet is left unread (`http: None` -> NOT RUN): the fix that adds the endpoint adds its
    client here, in the PR that flips the cell (design 5.1).
"""
from __future__ import annotations

from . import frames as F
from . import observe as OB
from .collect import kernel as K
from .collect import proxy as P
from .collect import ps as PS
from .collect import sniff as S
from .collect import fabric as FB
from .collect import thrift as TH

DPIDS = (1, 2, 3, 4)


# --- small helpers ----------------------------------------------------------------------------

def switches(cfg):
    return OB._switches(P.switch_state(cfg))


def sw_entry(sw, dpid):
    return (sw or {}).get(str(dpid)) if isinstance((sw or {}).get(str(dpid)), dict) else None


def to_int(v):
    """A runtime-JSON value as the int a thrift dump prints: dotted IPv4, a MAC, or a number."""
    if isinstance(v, bool):
        raise ValueError("boolean value %r" % (v,))
    if isinstance(v, int):
        return v
    text = str(v)
    if text.count(".") == 3:
        return int.from_bytes(F.ip_bytes(text), "big")
    if text.count(":") == 5:
        return int.from_bytes(F.mac_bytes(text), "big")
    return int(text, 0)


def runtime_entry_key(entry, key_order, param_order):
    """(table, keys, action, params) of one runtime-JSON entry, the form dump_keys gives."""
    match = entry.get("match") or {}
    keys = []
    for name in key_order:
        v = match[name]
        if isinstance(v, (list, tuple)):
            keys.append((to_int(v[0]), int(v[1])))
        else:
            keys.append((to_int(v),))
    params = tuple(to_int((entry.get("action_params") or {})[p]) for p in param_order)
    return (entry["table"], tuple(keys), entry["action_name"], params)


def dump_keys(table, dump):
    """{(table, keys, action, params)} out of a parsed table_dump; None when unreadable."""
    if dump is None:
        return None
    return {(table, tuple(TH.key_value(k, v) for _f, k, v in e["keys"]), e["action"], tuple(e["params"]))
            for e in dump.get("entries", [])}


def expected_entries(runtimes, orders):
    """{dpid str: {entry keys}} for the package's NON-default entries, and the tables they use.
    `runtimes` {dpid: runtime doc}, `orders` {dpid: (key orders, param orders)} from the p4info."""
    out, tables = {}, set()
    for dpid, doc in runtimes.items():
        keys, params = orders[dpid]
        want = set()
        for e in doc.get("table_entries") or []:
            if e.get("default_action"):
                continue
            want.add(runtime_entry_key(e, keys[e["table"]], params.get(e["action_name"], [])))
            tables.add(e["table"])
        out[str(dpid)] = want
    return out, sorted(tables)


def sentinel(dpid):
    """gen_runtime gives each switch one /32 drop route of its own (T1's negative read)."""
    return ("HcIngress.ipv4_lpm", ((to_int("10.0.99.%d" % dpid), 32),), "HcIngress.drop", ())


# --- PL1 is observe.observe_pl1; M1 is observe.observe_m1 ---------------------------------------

def observe_t1(cfg, runner, runtimes, orders, sent, dpids=DPIDS):
    """T1: switch_state's recorded/applied/failed per switch, and every thrift dump entry for
    entry against the package. Negative: no switch's dump holds another switch's sentinel."""
    expect, tables = expected_entries(runtimes, orders)
    reader = TH.ThriftReader(cfg, runner)
    dumps = {}
    for d in dpids:
        got = set()
        for t in tables:
            part = dump_keys(t, reader.read(d, "table_dump %s" % t))
            if part is None:
                got = None
                break
            got |= part
        dumps[str(d)] = got
    sw = switches(cfg)
    answer = None
    if sw is not None:
        counts = {}
        for d in dpids:
            te = (sw_entry(sw, d) or {}).get("table_entries")
            counts[str(d)] = dict(te) if isinstance(te, dict) else None
        answer = {"counts": counts}
    oracle = None
    if all(v is not None for v in dumps.values()):
        oracle = {"dumps": dumps}
    negative = None
    if oracle is not None:
        foreign = [(d, e) for d in dpids for e in dpids if e != d and sentinel(e) in dumps[str(d)]]
        negative = {"absent": not foreign,
                    "why": "s%s holds s%s's sentinel route" % foreign[0] if foreign else ""}
    return {"answer": answer, "oracle": oracle, "negative": negative, "sent": sent,
            "expect": {"entries": expect}}


def observe_t2(cfg, runner):
    """T2: s2's runtime default stamp(0x2A) through thrift; NDTwin's half is s2's own counts
    (switch_state has no per-entry record; the default is one of s2's counted entries). Negative:
    s3, which got no runtime default, shows the compiled stamp(0)."""
    reader = TH.ThriftReader(cfg, runner)
    d2 = reader.read(2, "table_dump HcIngress.t_default_only")
    d3 = reader.read(3, "table_dump HcIngress.t_default_only")
    sw = switches(cfg)
    answer = None
    if sw is not None:
        te = (sw_entry(sw, 2) or {}).get("table_entries")
        if isinstance(te, dict) and te.get("recorded") is not None:
            answer = {"applied": bool(te.get("failed") == 0 and te.get("recorded", 0) > 0
                                      and te.get("applied") == te.get("recorded"))}
        else:
            answer = {"applied": None}
    oracle = None
    if d2 is not None and d2.get("default") is not None and d2["default"].get("action"):
        oracle = {"s2_default": (d2["default"]["action"], list(d2["default"]["params"]))}
    negative = None
    if d3 is not None and d3.get("default") is not None:
        got = (d3["default"].get("action"), tuple(d3["default"].get("params") or ()))
        negative = {"absent": got == ("HcIngress.stamp", (0,)),
                    "why": "s3's default reads %r, not the compiled stamp(0)" % (got,)}
    return {"answer": answer, "oracle": oracle, "negative": negative}


def write_cell(cfg, runner, cell, dpid, table, body, find, checks, post=None):
    """T3-T7: read the table, write through POST /p4/table_entry, read it again.

    `find(dump)` -> the entries the write would put there; `checks(found)` -> {check: bool}.
    The negative read is "none of them before"; sent is 1 when the POST was issued and answered."""
    reader = TH.ThriftReader(cfg, runner)
    before = reader.read(dpid, "table_dump %s" % table)
    status, body_out = (post or P.post_table_entry)(cfg, body)
    after = reader.read(dpid, "table_dump %s" % table)
    answer = OB.with_route(None if status is None else {"http": status}, cfg, cell)
    oracle = None if after is None else checks(find(after))
    negative = None if before is None else {"absent": not find(before),
                                            "why": "the entry was already there before the write"}
    return {"answer": answer, "oracle": oracle, "negative": negative,
            "sent": 1 if status is not None else 0, "response": body_out}


def entries_with(table_key, action=None, params=None):
    """A `find` for write_cell: the dump's entries whose (only) key equals `table_key`."""
    def find(dump):
        out = []
        for e in (dump or {}).get("entries", []):
            keys = tuple(TH.key_value(k, v) for _f, k, v in e["keys"])
            if keys == (table_key,) and (action is None or e["action"] == action) \
                    and (params is None or tuple(e["params"]) == tuple(params)):
                out.append(e)
        return out
    return find


T3_BODY = {"dpid": 2, "op": "insert", "table": "HcIngress.port_exact",
           "match": {"standard_metadata.ingress_port": 7}, "action_name": "HcIngress.set_port_tag",
           "action_params": {"tag": 0x33}}


def observe_t3(cfg, runner):
    find = entries_with((7,), "HcIngress.set_port_tag", (0x33,))
    return write_cell(cfg, runner, "T3", 2, "HcIngress.port_exact", T3_BODY, find,
                      lambda f: {"present_after": len(f) == 1})


def observe_t3_neg(cfg):
    """T3-neg: a table the pipeline does not have -- the endpoint's own 404 and its error word."""
    status, body = P.post_table_entry(cfg, dict(T3_BODY, table="HcIngress.no_such_table"))
    detail = (body or {}).get("detail") if isinstance(body, dict) else None
    error = detail.get("error") if isinstance(detail, dict) else detail
    answer = OB.answer_or_none(status, {"http": status, "error": error})
    return {"answer": OB.with_route(answer, cfg, "T3-neg")}


#: T4-T7 on s2: the probe's own requested masks and priorities (P4Runtime semantics: a higher
#: number wins). bmv2's thrift dump prints the priority PI wrote, which is INT32_MAX minus the
#: P4Runtime one (lower wins there): requested 10 dumps as 2147483637. Seen on throwaway stock
#: and bmv2-fast simple_switch_grpc switches with controller_ext.py's own writes (Cut 2).
BMV2_PRIORITY_TOP = 2 ** 31 - 1


def thrift_priority(p4rt_priority):
    return BMV2_PRIORITY_TOP - int(p4rt_priority)


T4_BODY = {"dpid": 2, "op": "insert", "table": "HcIngress.t_ternary",
           "match": {"hdr.ipv4.srcAddr": ["10.0.4.4", "255.255.255.0"]},
           "action_name": "HcIngress.set_mark", "action_params": {"v": 4}, "priority": 10}
T5_BODY = {"dpid": 2, "op": "insert", "table": "HcIngress.t_range",
           "match": {"hdr.udp.dstPort": [40100, 40110]},
           "action_name": "HcIngress.set_mark", "action_params": {"v": 5}, "priority": 10}
T6_BODY = {"dpid": 2, "op": "insert", "table": "HcIngress.t_optional",
           "match": {"hdr.ipv4.protocol": 17},
           "action_name": "HcIngress.set_mark", "action_params": {"v": 6}, "priority": 10}
T7_BODIES = ({"dpid": 2, "op": "insert", "table": "HcIngress.t_ternary",
              "match": {"hdr.ipv4.srcAddr": ["10.0.6.6", "255.255.255.255"]},
              "action_name": "HcIngress.set_mark", "action_params": {"v": 71}, "priority": 30},
             {"dpid": 2, "op": "insert", "table": "HcIngress.t_ternary",
              "match": {"hdr.ipv4.srcAddr": ["10.0.6.0", "255.255.255.0"]},
              "action_name": "HcIngress.set_mark", "action_params": {"v": 72}, "priority": 20})


def observe_t4(cfg, runner):
    v, m = to_int("10.0.4.4") & to_int("255.255.255.0"), to_int("255.255.255.0")

    def find(dump):
        return [e for e in (dump or {}).get("entries", [])
                if e["keys"] and TH.key_value(e["keys"][0][1], e["keys"][0][2])[0] == v
                and e["action"] == "HcIngress.set_mark" and e["params"] == [4]]

    def checks(f):
        return {"present_after": len(f) == 1,
                "mask_ok": len(f) == 1 and TH.key_value(f[0]["keys"][0][1], f[0]["keys"][0][2]) == (v, m),
                "priority_ok": len(f) == 1 and f[0]["priority"] == thrift_priority(10)}
    return write_cell(cfg, runner, "T4", 2, "HcIngress.t_ternary", T4_BODY, find, checks)


def observe_t5(cfg, runner):
    def find(dump):
        return [e for e in entries_with((40100, 40110))(dump) if e["params"] == [5]]
    return write_cell(cfg, runner, "T5", 2, "HcIngress.t_range", T5_BODY, find,
                      lambda f: {"present_after": len(f) == 1,
                                 "priority_ok": len(f) == 1 and f[0]["priority"] == thrift_priority(10)})


def observe_t6(cfg, runner):
    def find(dump):     # bmv2 dumps an optional key as TERNARY with a full mask
        return [e for e in entries_with((17, 0xFF))(dump) if e["params"] == [6]]
    return write_cell(cfg, runner, "T6", 2, "HcIngress.t_optional", T6_BODY, find,
                      lambda f: {"present_after": len(f) == 1,
                                 "priority_ok": len(f) == 1 and f[0]["priority"] == thrift_priority(10)})


def observe_t7(cfg, runner):
    """T7: two overlapping ternary entries; the dump must keep the requested priority order
    (the /32 asked for 30 must outrank the /24 asked for 20 -- in thrift's numbers, where lower
    wins, the /32's must be the SMALLER)."""
    reader = TH.ThriftReader(cfg, runner)
    narrow, wide = (to_int("10.0.6.6"), 0xFFFFFFFF), (to_int("10.0.6.0"), 0xFFFFFF00)

    def pick(dump, key):
        return [e for e in (dump or {}).get("entries", [])
                if e["keys"] and TH.key_value(e["keys"][0][1], e["keys"][0][2]) == key]
    before = reader.read(2, "table_dump HcIngress.t_ternary")
    statuses = [P.post_table_entry(cfg, b)[0] for b in T7_BODIES]
    after = reader.read(2, "table_dump HcIngress.t_ternary")
    answer = None
    if all(s is not None for s in statuses):
        answer = OB.with_route({"http": next((s for s in statuses if s != 200), 200)}, cfg, "T3")
    oracle = None
    if after is not None:
        n, w = pick(after, narrow), pick(after, wide)
        oracle = {"order_ok": len(n) == 1 and len(w) == 1 and n[0]["priority"] is not None
                  and w[0]["priority"] is not None and n[0]["priority"] < w[0]["priority"]}
    negative = None
    if before is not None:
        negative = {"absent": not pick(before, narrow) and not pick(before, wide)}
    return {"answer": answer, "oracle": oracle, "negative": negative,
            "sent": sum(1 for s in statuses if s is not None)}


def observe_t8(cfg):
    """T8: switch_state's `journaled` for the switch T3 wrote to (api_routes.py:803-806)."""
    sw = switches(cfg)
    if sw is None:
        return {"answer": None}
    te = (sw_entry(sw, 2) or {}).get("table_entries")
    return {"answer": {"journaled": te.get("journaled") if isinstance(te, dict) else None}}


# --- PRE ----------------------------------------------------------------------------------------

M2_BODY = {"dpid": 1, "op": "insert", "multicast_group_id": 2,
           "replicas": [{"egress_port": 2, "instance": 1}, {"egress_port": 3, "instance": 1}]}


def observe_m2(cfg, runner):
    reader = TH.ThriftReader(cfg, runner)
    before = reader.read(1, "mc_dump")
    status, _b = P.post_multicast_group(cfg, M2_BODY)
    after = reader.read(1, "mc_dump")
    declared = [r["egress_port"] for r in M2_BODY["replicas"]]
    oracle = None if after is None else {"group2_after": after.get(2, frozenset()),
                                         "declared": declared}
    negative = None if before is None else {"absent": 2 not in before}
    return {"answer": OB.answer_or_none(status, {"http": status}), "oracle": oracle,
            "negative": negative, "sent": 1 if status is not None else 0}


def clone_ports(reader, dpid, session):
    """(present, ports): mirroring_get then mc_dump of its mgid (p4_client.py:780-786).
    None when either read is unreadable."""
    m = reader.read(dpid, "mirroring_get %d" % session)
    if m is None:
        return None
    if not m["present"]:
        return (False, frozenset())
    if m.get("mgid") is None:
        return (True, frozenset([m["port"]]) if m.get("port") is not None else frozenset())
    groups = reader.read(dpid, "mc_dump")
    if groups is None:
        return None
    return (True, groups.get(m["mgid"], frozenset()))


def observe_c1(cfg, runner):
    reader = TH.ThriftReader(cfg, runner)
    s2 = clone_ports(reader, 2, 7)
    others = [clone_ports(reader, d, 7) for d in (1, 3, 4)]
    sw = switches(cfg)
    answer = None
    if sw is not None:
        clone = (((sw_entry(sw, 2) or {}).get("pre_entries") or {}).get("clone")) or {}
        answer = {"applied": clone.get("applied")}
    oracle = None if s2 is None or not s2[0] else {"ports": s2[1]}
    if s2 is not None and not s2[0]:
        oracle = {"ports": frozenset()}
    negative = None if any(o is None for o in others) else {"absent": not any(o[0] for o in others)}
    return {"answer": answer, "oracle": oracle, "negative": negative}


def observe_c2(cfg, runner):
    """C2: a runtime clone session (9) through NDTwin. Today there is no route: the answer is
    route False and the oracle and negative read are still taken (session 9 absent before)."""
    reader = TH.ThriftReader(cfg, runner)
    before = clone_ports(reader, 2, 9)
    answer = OB.with_route({"http": None}, cfg, "C2")
    after = clone_ports(reader, 2, 9)
    oracle = None if after is None else {"present_after": after[0], "ports_ok": after[1] == frozenset({1})}
    negative = None if before is None else {"absent": not before[0]}
    return {"answer": answer, "oracle": oracle, "negative": negative}


# --- counters ------------------------------------------------------------------------------------

def handle_of(dump, key):
    for e in (dump or {}).get("entries", []):
        if e["keys"] and tuple(TH.key_value(k, v) for _f, k, v in e["keys"]) == (key,):
            return e["handle"]
    return None


def observe_k2(cfg, runner, stimulate, dpid=2, dport=40012):
    """K2: the direct counter on t_dcount's dport entry, read by thrift through the entry's
    handle; NDTwin's half is GET /p4/counter for the direct counter's name."""
    reader = TH.ThriftReader(cfg, runner)
    handle = handle_of(reader.read(dpid, "table_dump HcIngress.t_dcount"), (dport,))
    full = "HcIngress.dc_k2"
    st0, mine0, _e = P.counter(cfg, full, dpid, 0)
    th0 = None if handle is None else reader.read(dpid, "counter_read %s %d" % (full, handle))
    out = stimulate()
    st1, mine1, _e = P.counter(cfg, full, dpid, 0)
    th1 = None if handle is None else reader.read(dpid, "counter_read %s %d" % (full, handle))
    answer = None
    if st0 is not None and st1 is not None:
        answer = {"http": st1 if st1 != 200 else st0,
                  "delta": (mine1 - mine0) if (st0 == 200 and st1 == 200) else None}
    oracle = {"delta": th1[1] - th0[1]} if (th0 is not None and th1 is not None) else None
    return {"answer": OB.with_route(answer, cfg, "K2"), "oracle": oracle, "sent": S.sent(out, "K2")}


# --- meters -----------------------------------------------------------------------------------

#: the rates the probe asks for, as thrift prints them (bytes per microsecond, burst bytes):
#: 1000 kbit/s = 125000 B/s = 0.125 B/us, burst 12500 B, the same for both bands.
METER_TARGET = [(0.125, 12500), (0.125, 12500)]
MT1_BODY = {"dpid": 2, "meter_id": 1, "flags": ["KBPS"],
            "bands": [{"type": "DROP", "rate": 1000, "burst_size": 12500}]}


def meter_cell(cfg, runner, cell, read_cmd, write):
    reader = TH.ThriftReader(cfg, runner)
    before = reader.read(2, read_cmd)
    answer = write()
    after = reader.read(2, read_cmd)
    oracle = None if after is None else {"rates_after": after, "target": list(METER_TARGET)}
    negative = None if before is None else {"absent": before != METER_TARGET}
    return {"answer": answer, "oracle": oracle, "negative": negative,
            "sent": 1 if answer is not None and answer.get("http") is not None else 0}


def kernel_post(cfg, path, body):
    reply = cfg.kernel.post(path, body)
    return reply.status


def observe_mt1(cfg, runner):
    """MT1: the kernel's /ndt/install_meter_entry (501 unsupported_on_p4 today)."""
    def write():
        st = kernel_post(cfg, "/ndt/install_meter_entry", MT1_BODY)
        return None if st is None else {"http": st}
    return meter_cell(cfg, runner, "MT1", "meter_get_rates HcIngress.m_in 0", write)


def observe_mt2(cfg, runner):
    return meter_cell(cfg, runner, "MT2", "meter_get_rates HcIngress.m_in 1",
                      lambda: OB.with_route({"http": None}, cfg, "MT2"))


def observe_mt3(cfg, runner):
    reader = TH.ThriftReader(cfg, runner)
    handle = handle_of(reader.read(2, "table_dump HcIngress.t_dmeter"), (40023,))
    if handle is None:
        ans = OB.with_route({"http": None}, cfg, "MT3")
        return {"answer": ans, "oracle": None, "negative": None, "sent": 0}
    return meter_cell(cfg, runner, "MT3", "meter_get_rates HcIngress.dm_mt3 %d" % handle,
                      lambda: OB.with_route({"http": None}, cfg, "MT3"))


# --- registers -----------------------------------------------------------------------------------

def observe_r2(cfg, runner, stimulate, chosen):
    """R2 and SC-reg: the marker writes `chosen` (its sport) into r_mark[0] on s2."""
    reader = TH.ThriftReader(cfg, runner)
    out = stimulate()
    value = reader.read(2, "register_read HcIngress.r_mark 0")
    answer = OB.with_route({"value": None}, cfg, "R2")
    return ({"answer": answer, "oracle": None if value is None else {"value": value},
             "sent": S.sent(out, "R2")},
            {"chosen": chosen, "register": value})


R3_TARGET = 0xBEEF


def observe_r3(cfg, runner):
    reader = TH.ThriftReader(cfg, runner)
    before = reader.read(2, "register_read HcIngress.r_mark 1")
    answer = OB.with_route({"http": None}, cfg, "R3")
    after = reader.read(2, "register_read HcIngress.r_mark 1")
    return {"answer": answer,
            "oracle": None if after is None else {"value_after": after, "target": R3_TARGET},
            "negative": None if before is None else {"absent": before != R3_TARGET}}


# --- digest and packet I/O --------------------------------------------------------------------

def exit_answer(cfg, cell, extra=None):
    """D1 / P2: NDTwin's exit for a digest or a packet-in is an endpoint in its openapi. None
    when openapi was unreadable (not "no exit")."""
    route = OB.route_answer(P.openapi_paths(cfg), cell)
    if route is None:
        return None
    return dict(extra or {}, exit=route, fields=None)


def observe_d1(cfg, stimulate, src_ip, sport, dport=40041):
    out = stimulate()
    return {"answer": exit_answer(cfg, "D1"), "sent": S.sent(out, "D1"),
            "oracle": {"fields": {"src": src_ip, "sport": sport, "dport": dport}}}


def observe_p2(cfg, stimulate):
    out = stimulate()
    return {"answer": exit_answer(cfg, "P2"), "sent": S.sent(out, "P2"), "oracle": None}


def observe_p3(cfg):
    return {"answer": OB.with_route({"http": None}, cfg, "P3"), "oracle": None}


def observe_p1(cfg, runner, dpids=DPIDS):
    lines = PS.ps_lines(runner)
    has = [PS.has_flag(PS.bmv2_argv(lines, cfg.thrift_port(d)), "--cpu-port", 510) for d in dpids]
    return {"oracle": None if any(h is None for h in has) else {"argv_has": all(has)}}


def observe_cs1(hosts, names):
    """CS1: `ethtool -k` inside every host's namespace; one unreadable host makes it unread."""
    got = {}
    for h in names:
        text = hosts.run_in(h, ["ethtool", "-k", "eth0"])
        got[h] = FB.checksum_offload_off(text)
    if any(v is None for v in got.values()):
        return {"oracle": None}
    return {"oracle": {"tx_checksum_off": got}}


# --- TTL1 / SC-ttl -------------------------------------------------------------------------------

def observe_ttl1(cfg, runner, window_out, dst_ip, links, start=2):
    """TTL1 and SC-ttl from one window: (sender stdout, receiver stdout)."""
    sent_out, rx = window_out
    recs = None if rx is None else S.received(rx, "TTL1")
    reader = TH.ThriftReader(cfg, runner)
    dumps = {}
    for d in DPIDS:
        parsed = reader.read(d, "table_dump HcIngress.ipv4_lpm")
        if parsed is not None:
            dumps[d] = OB.lpm_routes(parsed)
    hops = None
    if links is not None and len(dumps) == len(DPIDS):
        from .cells.table import hops_from_lpm
        hops = hops_from_lpm(dumps, links, start, dst_ip)
    cell = {"oracle": None if recs is None else {"received": len(recs)}, "sent": S.sent(sent_out, "TTL1")}
    sc = {"hops_lpm": hops, "ttls": [r.get("ttl") for r in (recs or [])], "sent_ttl": 64}
    return cell, sc


# --- TP1 ---------------------------------------------------------------------------------------

def ip_from_kernel(v):
    """The kernel's IPv4 integers are s_addr read little-endian (tools/twin_audit/criteria.py)."""
    if isinstance(v, str):
        return v
    return F.ip_str(int(v).to_bytes(4, "little"))


def mac_from_kernel(v):
    if isinstance(v, str):
        return v.lower()
    return F.mac_str(int(v).to_bytes(6, "big"))


def graph_view(graph):
    """get_graph_data as the four sets TP1 compares; None when unreadable."""
    if not isinstance(graph, dict) or not isinstance(graph.get("nodes"), list) \
            or not isinstance(graph.get("edges"), list):
        return None
    switches_, hosts_ = set(), set()
    for n in graph["nodes"]:
        if not isinstance(n, dict):
            continue
        if n.get("vertex_type") == 1:
            ips = n.get("ip") or []
            if ips:
                hosts_.add((ip_from_kernel(ips[0]), mac_from_kernel(n.get("mac"))))
        elif n.get("dpid"):
            switches_.add(int(n["dpid"]))
    edges, ports = set(), set()
    for e in graph["edges"]:
        if not isinstance(e, dict):
            continue
        ends = []
        for side in ("src", "dst"):
            dpid = e.get("%s_dpid" % side)
            if dpid:
                ends.append(("s", int(dpid), int(e.get("%s_interface" % side))))
                ports.add((int(dpid), int(e.get("%s_interface" % side))))
            else:
                ip = (e.get("%s_ip" % side) or [None])[0]
                ends.append(("h", ip_from_kernel(ip) if ip is not None else None, 0))
        edges.add(frozenset(ends))
    return {"switches": switches_, "hosts": hosts_, "edges": edges, "ports": ports}


def fabric_view(cfg, runner, hosts, names, dpids=DPIDS):
    """The fabric as the same four sets: thrift show_ports per switch, veth peers in the root
    namespace, and each host's own interface (its address, MAC and peer) inside its namespace."""
    reader = TH.ThriftReader(cfg, runner)
    res = runner.run(["ip", "-o", "link", "show"], timeout=10)
    if res.rc != 0:
        return None
    peers, index = FB.veth_peers(res.stdout), FB.ifindex(res.stdout)
    by_index = {i: n for n, i in index.items()}
    port_of = {}
    for d in dpids:
        sp = reader.read(d, "show_ports")
        if sp is None:
            return None
        for port, iface in sp.items():
            port_of[iface] = (d, port)
    edges, ports, hosts_ = set(), set(port_of.values()), set()
    for iface, (d, port) in port_of.items():
        peer = by_index.get(peers.get(iface))
        if peer in port_of:
            edges.add(frozenset([("s",) + port_of[iface], ("s",) + port_of[peer]]))
    for h in names:
        link = hosts.run_in(h, ["ip", "-o", "link", "show", "dev", "eth0"])
        addr = hosts.run_in(h, ["ip", "-o", "addr", "show", "dev", "eth0"])
        got = FB.host_addr((addr or "") + "\n" + (link or "")) if link and addr else None
        hpeer = FB.veth_peers(link or "")
        if got is None or not hpeer:
            return None
        hosts_.add(got)
        sw_iface = by_index.get(list(hpeer.values())[0])
        if sw_iface not in port_of:
            return None
        edges.add(frozenset([("h", got[0], 0), ("s",) + port_of[sw_iface]]))
    return {"switches": set(dpids), "hosts": hosts_, "edges": edges, "ports": ports}


def observe_tp1(cfg, runner, hosts, names):
    oracle = fabric_view(cfg, runner, hosts, names)
    answer = graph_view(K.graph(cfg))
    return {"answer": answer, "oracle": oracle}


def links_from(view):
    """{(dpid, port): the next switch} out of a fabric view's switch-to-switch edges."""
    if view is None:
        return None
    out = {}
    for e in view["edges"]:
        ends = sorted(e)
        if all(x[0] == "s" for x in ends) and len(ends) == 2:
            a, b = ends
            out[(a[1], a[2])] = b[1]
            out[(b[1], b[2])] = a[1]
    return out
