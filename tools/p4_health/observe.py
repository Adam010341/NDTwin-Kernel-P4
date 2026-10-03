"""From readings to observations: what each cell's `answer`, `oracle` and `negative` hold.

[Co-developed with claude code -- Adam]

Cut 1 builds the observers the reading layer's tests need to pin the three rules that are about
WHERE a number comes from (DESIGN 5.2-②): `sent` is the sender's own report, the oracle column is
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
#: endpoint names its path here in the same PR that flips the cell (DESIGN 5.1).
ROUTE_PREFIXES = {
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


def observe_counter(cfg, runner, dpid, name, index, stimulate, cell):
    """K1 / K3: NDTwin's counter delta and thrift's, around one stimulus.

    `stimulate()` runs the sender and returns its stdout; `sent` is what that stdout says."""
    reader = TH.ThriftReader(cfg, runner)
    full = name if "." in name else "HcIngress." + name
    st0, mine0 = P.counter(cfg, full, dpid, index)
    th0 = reader.read(dpid, "counter_read %s %d" % (full, index))
    out = stimulate()
    st1, mine1 = P.counter(cfg, full, dpid, index)
    th1 = reader.read(dpid, "counter_read %s %d" % (full, index))
    answer = {"http": st1 if st1 != 200 else st0,
              "delta": (mine1 - mine0) if (st0 == 200 and st1 == 200) else None}
    oracle = {"delta": th1[1] - th0[1]} if (th0 is not None and th1 is not None) else None
    return {"answer": answer, "oracle": oracle, "sent": S.sent(out, cell)}


def observe_m1(cfg, runner, dpids=(1, 2, 3, 4)):
    """M1: s1's group 1 from thrift; the negative read is "s2-s4 have no group 1"."""
    reader = TH.ThriftReader(cfg, runner)
    dumps = {d: reader.read(d, "mc_dump") for d in dpids}
    state = P.switch_state(cfg) or {}
    pre = (((state.get("switches") or {}).get("1") or {}).get("pre_entries") or {}).get("multicast") or {}
    oracle = None if dumps[1] is None else {"s1_group1": dumps[1].get(1)}
    others = [dumps[d] for d in dpids if d != 1]
    if any(o is None for o in others):
        negative = None                       # unreadable is not absent
    else:
        negative = {"absent": all(1 not in o for o in others)}
    return {"answer": {"applied": pre.get("applied"), "recorded": pre.get("recorded")},
            "oracle": oracle, "negative": negative}


def observe_pl1(cfg, runner, expect_pipelines, alt_table="HcIngress.alt_port_stamp", dpids=(1, 2, 3, 4)):
    reader = TH.ThriftReader(cfg, runner)
    tables = {d: reader.read(d, "show_tables") for d in dpids}
    state = P.switch_state(cfg) or {}
    pipes = {k: (v.get("pipeline") or {}).get("p4info_sha256")
             for k, v in (state.get("switches") or {}).items()}
    oracle = None if tables[1] is None else {"alt_table": {"1": alt_table in tables[1]}}
    others = [tables[d] for d in dpids if d != 1]
    negative = None if any(t is None for t in others) else {"absent": all(alt_table not in t for t in others)}
    return {"answer": {"pipelines": pipes}, "oracle": oracle, "negative": negative,
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
