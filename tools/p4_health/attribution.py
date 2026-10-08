"""B's eleven attributions, confirmed: the controller's call AND an independent reading. (Cut 2)

[Co-developed with claude code -- Adam]

design 4.2: B's controller does what NDTwin could not, and "every one is confirmed by thrift or
by the receiving host". So an attribution holds only when BOTH:

  * the controller reports its P4Runtime call succeeded (controller_ext.py's result file), and
  * a reading that does not come from the controller shows the effect: thrift on the switch
    (table_dump, meter_get_rates, mirroring_get + mc_dump, register_read, counter_read), a host's
    sniffer for the packet-out, or -- for the two stream messages, the DigestList and the
    packet-in -- the contents the controller received matching the markers the PROBE sent
    (fields and ingress port the probe chose; the controller cannot know them in advance).

A call that failed, or a reading that is missing or does not match, is ok=False: the A cell it
backs then judges UNATTRIBUTED, never RED (verdict.attribution_holds). `confirm` is pure: the
thrift reads come in through `read(command) -> parsed or None` (collect/thrift.py's parsers).
"""
from __future__ import annotations

from . import controller_ext as CX
from .collect import thrift as TH

#: Which A cell each attribution backs (design 4.2's list against the cells of 2.3).
CELL_ITEMS = {"T4": "ternary", "T5": "range", "T6": "optional", "T7": "priority",
              "MT1": "meter", "MT2": "meter", "MT3": "direct_meter", "D1": "digest",
              "C2": "clone", "R3": "register", "K2": "direct_counter", "P2": "packet_in",
              "P3": "packet_out"}
ITEMS = ("ternary", "range", "optional", "priority", "meter", "direct_meter", "digest", "clone",
         "register", "direct_counter", "packet_in", "packet_out")

METER_RATES = [(CX.METER["cir"] / 1e6, CX.METER["cburst"]), (CX.METER["pir"] / 1e6, CX.METER["pburst"])]


def ip_int(ip):
    return int.from_bytes(bytes(int(x) for x in ip.split(".")), "big")


def thrift_priority(p):
    return 2 ** 31 - 1 - int(p)


def _entries(dump, key, params):
    return [e for e in (dump or {}).get("entries", [])
            if e["keys"] and TH.key_value(e["keys"][0][1], e["keys"][0][2]) == key
            and list(e["params"]) == list(params)]


def _handle(dump, key):
    for e in (dump or {}).get("entries", []):
        if e["keys"] and TH.key_value(e["keys"][0][1], e["keys"][0][2]) == key:
            return e["handle"]
    return None


def confirm(result, read, p3_received, expect):
    """{item: {"ok": bool, "why": str}}.

    `result` the controller's result document (None: it wrote none); `read(cmd)` a parsed thrift
    read on the attribution switch; `p3_received` how many packet-out markers the receiving host's
    sniffer saw (None: unread); `expect` the probe's own stimulus: {"digest": [src ip int, sport,
    dport], "packet_in_port": <port>, "packet_in_cell": "P2", "token": .., "k2_sent": n}."""
    res = result or {}
    calls = res.get("attributions") or {}
    out = {}

    def call_ok(item):
        c = calls.get(item) or {}
        return c.get("ok") is True, c.get("error") or "the controller did not report this call"

    def put(item, ok, why):
        out[item] = {"ok": bool(ok), "why": why}

    def table_item(item, cmd, key, params, priority):
        ok, err = call_ok(item)
        if not ok:
            return put(item, False, "controller: %s" % err)
        found = _entries(read(cmd), key, params)
        if len(found) != 1:
            return put(item, False, "thrift: %d matching entr(ies) after the write" % len(found))
        if found[0]["priority"] != thrift_priority(priority):
            return put(item, False, "thrift: priority %s, not %s" % (found[0]["priority"], thrift_priority(priority)))
        put(item, True, "thrift shows the entry, mask and priority")

    t, r, o = CX.TERNARY, CX.RANGE, CX.OPTIONAL
    table_item("ternary", "table_dump %s" % t["table"], (ip_int(t["value"]), ip_int(t["mask"])),
               [t["mark"]], t["priority"])
    table_item("range", "table_dump %s" % r["table"], (r["low"], r["high"]), [r["mark"]], r["priority"])
    table_item("optional", "table_dump %s" % o["table"], (o["value"], 0xFF), [o["mark"]], o["priority"])

    ok, err = call_ok("priority")
    if not ok:
        put("priority", False, "controller: %s" % err)
    else:
        dump = read("table_dump %s" % t["table"])
        hi, lo = CX.PRIORITY
        a = _entries(dump, (ip_int(hi["value"]), ip_int(hi["mask"])), [hi["mark"]])
        b = _entries(dump, (ip_int(lo["value"]), ip_int(lo["mask"])), [lo["mark"]])
        if len(a) != 1 or len(b) != 1:
            put("priority", False, "thrift: the two overlapping entries are not both there")
        elif not (a[0]["priority"] == thrift_priority(hi["priority"])
                  and b[0]["priority"] == thrift_priority(lo["priority"]) and a[0]["priority"] < b[0]["priority"]):
            put("priority", False, "thrift: priorities %s / %s are not in the requested order"
                % (a[0]["priority"], b[0]["priority"]))
        else:
            put("priority", True, "thrift keeps the requested order")

    def rates_item(item, cmd):
        ok, err = call_ok(item)
        if not ok:
            return put(item, False, "controller: %s" % err)
        rates = read(cmd) if cmd else None
        if rates != METER_RATES:
            return put(item, False, "thrift: rates %r, not %r" % (rates, METER_RATES))
        put(item, True, "thrift reads the configured rates")

    rates_item("meter", "meter_get_rates HcIngress.m_in %d" % CX.METER_INDEX)
    h = _handle(read("table_dump HcIngress.t_dmeter"), (CX.DIRECT_METER_DPORT,))
    rates_item("direct_meter", None if h is None else "meter_get_rates HcIngress.dm_mt3 %d" % h)

    ok, err = call_ok("digest")
    want = list(expect.get("digest") or [])
    got = [d.get("members") for d in res.get("digests") or []]
    if not ok:
        put("digest", False, "controller: %s" % err)
    elif not want:
        put("digest", False, "the probe sent no digest marker")
    elif want not in got:
        put("digest", False, "no DigestList carried the marker's fields %r (got %r)" % (want, got[:3]))
    else:
        put("digest", True, "a DigestList carried the marker's fields")

    ok, err = call_ok("clone")
    m = read("mirroring_get %d" % CX.CLONE["session"])
    if not ok:
        put("clone", False, "controller: %s" % err)
    elif not m or not m.get("present"):
        put("clone", False, "thrift: no session %d" % CX.CLONE["session"])
    else:
        groups = read("mc_dump") if m.get("mgid") is not None else None
        ports = (groups or {}).get(m.get("mgid")) if m.get("mgid") is not None else frozenset([m.get("port")])
        if ports != frozenset([CX.CLONE["port"]]):
            put("clone", False, "thrift: session %d replicates to %r" % (CX.CLONE["session"], ports))
        else:
            put("clone", True, "thrift: the session replicates to the declared port")

    ok, err = call_ok("register")
    if not ok:
        put("register", False, "controller: %s" % err)
    else:
        v = read("register_read %s %d" % (CX.REGISTER["name"], CX.REGISTER["index"]))
        put("register", v == CX.REGISTER["value"], "thrift: register holds %r" % (v,))

    ok, err = call_ok("direct_counter")
    h = _handle(read("table_dump HcIngress.t_dcount"), (CX.DIRECT_COUNTER_DPORT,))
    th = read("counter_read HcIngress.dc_k2 %d" % h) if h is not None else None
    mine = ((calls.get("direct_counter") or {}).get("detail") or {}).get("packets")
    if not ok:
        put("direct_counter", False, "controller: %s" % err)
    elif th is None:
        put("direct_counter", False, "thrift: the direct counter is unreadable")
    elif not mine or mine != th[1]:
        put("direct_counter", False, "controller read %r packets, thrift %r" % (mine, th[1]))
    else:
        put("direct_counter", True, "the controller's read equals thrift's (%d)" % mine)

    pins = res.get("packet_ins") or []
    ours = [p for p in pins if (p.get("marker") or [None, None])[:2] == [expect.get("token"), expect.get("packet_in_cell", "P2")]]
    if not ours:
        put("packet_in", False, "no packet-in carried the probe's marker (%d packet-in(s))" % len(pins))
    elif any(p.get("ingress_port") != expect.get("packet_in_port") for p in ours):
        put("packet_in", False, "packet-in ingress_port %r, not %r" % (ours[0].get("ingress_port"),
                                                                       expect.get("packet_in_port")))
    else:
        put("packet_in", True, "%d packet-in(s) carried the probe's marker" % len(ours))

    ok, err = call_ok("packet_out")
    if not ok:
        put("packet_out", False, "controller: %s" % err)
    elif not p3_received:
        put("packet_out", False, "the receiving host saw %r packet-out marker(s)" % (p3_received,))
    else:
        put("packet_out", True, "the receiving host got %d packet-out marker(s)" % p3_received)
    return out


def for_cells(confirmed):
    """{cell: {"bmv2": ok}} for verdict.attribution_holds; items B never confirmed are False."""
    return {cell: {"bmv2": bool((confirmed or {}).get(item, {}).get("ok"))}
            for cell, item in CELL_ITEMS.items()}
