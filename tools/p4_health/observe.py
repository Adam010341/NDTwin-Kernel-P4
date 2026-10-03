"""From readings to observations: what each cell's `answer`, `oracle` and `negative` hold.

[Co-developed with claude code -- Adam]

Cut 1 builds the observers the reading layer's tests need to pin the three rules that are about
WHERE a number comes from (design 5.2-②): `sent` is the sender's own report, the oracle column is
thrift's and never the proxy's, and a negative read is only "absent" when thrift said so in a
reply it recognised. The remaining cells' observers are Cut 2-4's, written against the same
collectors.
"""
from __future__ import annotations

from .collect import proxy as P
from .collect import sniff as S
from .collect import thrift as TH
from . import frames as F

#: Where each "no route" cell would find its endpoint in the proxy's openapi. A fix that adds the
#: endpoint names its path here in the same PR that flips the cell (design 5.1).
#: (r4, Cut 1 follow-ups) K1 / K2 / K3 / T3 and the two controls are in it, so their observers can
#: say `route: False` and the "no route" decision (design 14.6, MINOR 3) can be reached at all.
ROUTE_PREFIXES = {
    "K1": ("/p4/counter",), "K2": ("/p4/counter",), "K3": ("/p4/counter",), "K1-neg": ("/p4/counter",),
    "T3": ("/p4/table_entry",), "T3-neg": ("/p4/table_entry",),
    "C2": ("/p4/clone_session",), "MT2": ("/p4/meter",), "MT3": ("/p4/direct_meter",),
    "R2": ("/p4/register",), "R3": ("/p4/register",), "P3": ("/p4/packet_out",),
    "AP1": ("/p4/action_profile",), "AS1": ("/p4/action_profile", "/p4/action_selector"),
    "VS1": ("/p4/value_set",),
}


def route_answer(paths, cell):
    """True / False for "the proxy has this cell's endpoint", None when openapi was unreadable."""
    if paths is None:
        return None
    return any(p.startswith(prefix) for p in paths for prefix in ROUTE_PREFIXES[cell])


def answer_or_none(status, answer):
    """NDTwin's answer, or None when nothing answered (step 0: unreadable is NOT RUN)."""
    return None if status is None else answer


def with_route(answer, cfg, cell):
    """`answer` plus `route`: whether the proxy's openapi has this cell's endpoint. Left out when
    openapi was unreadable -- an unreadable document is not a missing route (the cell then stays
    NOT RUN or PROBE-BROKEN, never the RED "no route")."""
    route = route_answer(P.openapi_paths(cfg), cell)
    if answer is not None and route is not None:
        answer = dict(answer, route=route)
    return answer


def observe_counter(cfg, runner, dpid, name, index, stimulate, cell):
    """K1 / K3: NDTwin's counter delta and thrift's, around one stimulus.

    `stimulate()` runs the sender and returns its stdout; `sent` is what that stdout says.
    (r4) The answer carries `route`, so a proxy without the endpoint reads as "no route" and not
    as FastAPI's own 404."""
    reader = TH.ThriftReader(cfg, runner)
    full = name if "." in name else "HcIngress." + name
    st0, mine0, _e0 = P.counter(cfg, full, dpid, index)
    th0 = reader.read(dpid, "counter_read %s %d" % (full, index))
    out = stimulate()
    st1, mine1, _e1 = P.counter(cfg, full, dpid, index)
    th1 = reader.read(dpid, "counter_read %s %d" % (full, index))
    answer = None
    if st0 is not None and st1 is not None:
        answer = {"http": st1 if st1 != 200 else st0,
                  "delta": (mine1 - mine0) if (st0 == 200 and st1 == 200) else None}
    oracle = {"delta": th1[1] - th0[1]} if (th0 is not None and th1 is not None) else None
    return {"answer": with_route(answer, cfg, cell), "oracle": oracle, "sent": S.sent(out, cell)}


def observe_counter_control(cfg, dpid, name="HcIngress.no_such_counter"):
    """K1-neg: a counter name the pipeline does not have. The answer keeps the error WORD, so
    FastAPI's own 404 (a missing route) cannot pass for the endpoint's refusal (review MINOR 21).
    (r4) And it carries `route`: with no /p4/counter in openapi the control has nothing to ask
    (NOT RUN), and K1 is RED "no route" instead of the whole round PROBE-BROKEN."""
    status, _packets, error = P.counter(cfg, name, dpid, 0)
    return {"answer": with_route(answer_or_none(status, {"http": status, "error": error}), cfg, "K1-neg")}


def _switches(state):
    return (state or {}).get("switches") if isinstance((state or {}).get("switches"), dict) else None


def observe_m1(cfg, runner, dpids=(1, 2, 3, 4)):
    """M1: s1's group 1 from thrift; the negative read is "s2-s4 have no group 1"."""
    reader = TH.ThriftReader(cfg, runner)
    dumps = {d: reader.read(d, "mc_dump") for d in dpids}
    switches = _switches(P.switch_state(cfg))
    answer = None
    if switches is not None:
        pre = (((switches.get("1") or {}).get("pre_entries") or {}).get("multicast")) or {}
        answer = {"applied": pre.get("applied"), "recorded": pre.get("recorded")}
    oracle = None if dumps[1] is None else {"s1_group1": dumps[1].get(1)}
    others = [dumps[d] for d in dpids if d != 1]
    if any(o is None for o in others):
        negative = None                       # unreadable is not absent
    else:
        negative = {"absent": all(1 not in o for o in others)}
    return {"answer": answer, "oracle": oracle, "negative": negative}


def observe_pl1(cfg, runner, expect_pipelines, alt_table="HcIngress.alt_port_stamp", dpids=(1, 2, 3, 4)):
    reader = TH.ThriftReader(cfg, runner)
    tables = {d: reader.read(d, "show_tables") for d in dpids}
    switches = _switches(P.switch_state(cfg))
    answer = None
    if switches is not None:
        answer = {"pipelines": {k: (v.get("pipeline") or {}).get("p4info_sha256")
                                for k, v in switches.items() if isinstance(v, dict)}}
    oracle = None if tables[1] is None else {"alt_table": {"1": alt_table in tables[1]}}
    others = [tables[d] for d in dpids if d != 1]
    negative = None if any(t is None for t in others) else {"absent": all(alt_table not in t for t in others)}
    return {"answer": answer, "oracle": oracle, "negative": negative,
            "expect": {"pipelines": expect_pipelines}}


def lpm_routes(dump):
    """{dst ip: port} out of an ipv4_lpm dump (the walk SC-ttl uses, section 12 item 4)."""
    out = {}
    for e in (dump or {}).get("entries", []):
        if e["action"] != "HcIngress.ipv4_forward" or not e["keys"]:
            continue
        v, _prefix = TH.key_value(e["keys"][0][1], e["keys"][0][2])
        out[F.ip_str(v.to_bytes(4, "big"))] = e["params"][-1]
    return out


def v6_routes(dump):
    """{dst low-32: port} out of a v6_host dump (SC-union's walk, review MINOR 4)."""
    out = {}
    for e in (dump or {}).get("entries", []):
        if e["action"] != "HcIngress.v6_forward" or not e["keys"]:
            continue
        (v,) = TH.key_value(e["keys"][0][1], e["keys"][0][2])
        out[v] = e["params"][-1]
    return out
