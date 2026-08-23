"""
Translates P4 table entries into Ryu's /stats/flow/<dpid> shape.

[Co-developed with claude code -- Adam]

The kernel polls `/stats/flow/<dpid>` and feeds the body straight to
`Classifier::updateFromQueriedTables`, which is what produces every flow's `path`. In OVS mode
that body comes from `ryu.app.ofctl_rest`; here the proxy produces the same thing from the bmv2
tables, so the Classifier needs no P4-specific branch.

Four properties of the output are load-bearing, and each one has already caused a real failure
or is documented as one in doc/2026-07-27_p4_bmv2_support_plan.md:

  - **The top level is a map keyed by dpid**, `{"1": [entries]}`, exactly as Ryu answers. The
    old stub returned a bare `[]`, and the kernel wraps whatever it gets as
    `{"dpid": N, "flows": <body>}` -- so a list made `flows` a list where the documented shape
    is a map, which the L2 contract flags as a type error.
  - **Actions must be strings** like `"OUTPUT:1"`. `Classifier::parseActionsArrayIntoEffect`
    parses *only* the string form; `{"type": "OUTPUT", "port": N}` is silently ignored, leaving
    the Classifier empty and every path `[]`.
  - **Priority must not be negative.** The Classifier's lookup starts with `bestPriority = -1`
    and a null `best`, so a rule at priority <= -1 used to segfault the kernel through a trace
    line. That guard is fixed now, but emitting a negative priority would still mean the rule
    can never win a match, so it is clamped here.
  - **Match keys must use Ryu's names** (`nw_dst`, `dl_type`, `in_port`, ...). The Classifier
    accepts a fixed set; anything else is dropped without comment, which shows up as rules that
    match nothing rather than as an error.
"""

from __future__ import annotations

from typing import Any, Optional

# Ryu/OpenFlow constant for IPv4, and the value the Classifier expects in dl_type.
ETH_TYPE_IPV4 = 0x0800

# P4 field name -> Ryu match key. Derived from ndtwin_switch.p4's table keys; anything not
# listed is deliberately dropped, because the Classifier ignores unknown keys anyway and
# passing them through would only make the payload look richer than it is.
FIELD_TO_RYU = {
    "hdr.ipv4.dstAddr": "nw_dst",
    "hdr.ipv4.srcAddr": "nw_src",
    "hdr.ipv4.protocol": "nw_proto",
    "meta.l4_src_port": "tp_src",
    "meta.l4_dst_port": "tp_dst",
    "standard_metadata.ingress_port": "in_port",
    "hdr.ethernet.dstAddr": "dl_dst",
}

# Actions that forward out of a port, and which parameter carries it.
FORWARDING_ACTIONS = {
    "MyIngress.ipv4_forward": "port",
    "MyIngress.forward_l2": "port",
}

# Reserved OpenFlow port number Ryu uses for the controller, matching what
# Classifier::parseActionsArrayIntoEffect maps "OUTPUT:CONTROLLER" to.
CPU_PORT_OUTPUT = "OUTPUT:CONTROLLER"


def _int(value: bytes) -> int:
    """A P4Runtime canonical bytestring as an integer (big-endian, leading zeros stripped)."""
    return int.from_bytes(value, "big") if value else 0


def _ipv4(value: bytes) -> str:
    """A 4-byte address as dotted quad. Short values are left-padded, as P4Runtime may strip."""
    padded = value.rjust(4, b"\x00")
    return ".".join(str(b) for b in padded[:4])


def _mac(value: bytes) -> str:
    padded = value.rjust(6, b"\x00")
    return ":".join(f"{b:02x}" for b in padded[:6])


def _prefix_to_netmask_suffix(prefix_len: int) -> str:
    """"/24" for a partial prefix, "" for a host route -- how Ryu renders nw_dst."""
    return "" if prefix_len >= 32 else f"/{prefix_len}"


def _match_to_ryu(match: dict) -> dict:
    """
    One entry's match fields under Ryu's names.

    Ternary fields whose mask is zero are omitted: a zero mask means "don't care", and emitting
    it as a concrete value would turn a wildcard into a specific match.
    """
    out: dict[str, Any] = {}
    for p4_name, spec in (match or {}).items():
        ryu_name = FIELD_TO_RYU.get(p4_name)
        if ryu_name is None:
            continue

        kind = spec.get("type")
        if kind == "ternary" and _int(spec.get("mask", b"")) == 0:
            continue

        if ryu_name in ("nw_dst", "nw_src"):
            text = _ipv4(spec.get("value", b""))
            if kind == "lpm":
                text += _prefix_to_netmask_suffix(spec.get("prefix_len", 32))
            out[ryu_name] = text
        elif ryu_name == "dl_dst":
            out[ryu_name] = _mac(spec.get("value", b""))
        else:
            out[ryu_name] = _int(spec.get("value", b""))

    # The Classifier keys IPv4 rules off dl_type, so a rule matching on an IP field must say so.
    if any(k in out for k in ("nw_dst", "nw_src", "nw_proto", "tp_src", "tp_dst")):
        out.setdefault("dl_type", ETH_TYPE_IPV4)
    return out


def _actions_to_ryu(action: Optional[dict]) -> list:
    """
    One entry's actions as Ryu's string forms.

    An empty list is correct for a drop, and the kernel handles it -- Ryu reports its own
    table-miss drop the same way.
    """
    if not action:
        return []

    name = action.get("name") or ""
    params = action.get("params") or {}

    param_name = FORWARDING_ACTIONS.get(name)
    if param_name is not None:
        port = _int(params.get(param_name, b""))
        return [f"OUTPUT:{port}"]

    if name.endswith("send_to_cpu"):
        return [CPU_PORT_OUTPUT]

    # drop(), NoAction, or anything this translator does not know: no output port. Deliberately
    # not guessed -- a wrong port would silently misreport the topology's forwarding.
    return []


def entry_to_ryu(entry: dict) -> Optional[dict]:
    """
    One P4 table entry as a Ryu flow-stats entry, or None if it should not be reported.

    Default actions are skipped: they carry no match fields, so the Classifier would read one as
    a rule that matches every packet at whatever priority it has.
    """
    if entry.get("is_default"):
        return None

    match = _match_to_ryu(entry.get("match") or {})
    if not match:
        # No usable match. Reporting it would be a match-everything rule, as above.
        return None

    return {
        # bmv2 has one ingress table block; the kernel only needs a stable key here.
        "table_id": 0,
        # Clamped at 0: negative priorities can never win a match in the Classifier, and used to
        # crash it outright.
        "priority": max(0, int(entry.get("priority") or 0)),
        "match": match,
        "actions": _actions_to_ryu(entry.get("action")),
        # Counters the kernel tolerates being absent but Ryu always sends. Still emitted even
        # when unknown, so the payload shape matches OVS's, which the L4 differential compares.
        #
        # These were hardcoded zeroes. Both ingress tables carry a direct_counter
        # (ndtwin_switch.p4:263-264) added for exactly this endpoint, and the values were being
        # read off the switch and then dropped one layer below. A rule with real traffic on it
        # now reports real traffic. [Co-developed with claude code -- Adam]
        #
        # Absent counter data still renders 0, and that is indistinguishable from a genuinely
        # idle rule -- an ambiguity the payload shape cannot express, so it is recorded here
        # rather than papered over.
        "byte_count": int((entry.get("counters") or {}).get("bytes") or 0),
        "packet_count": int((entry.get("counters") or {}).get("packets") or 0),
        "duration_sec": 0,
        "duration_nsec": 0,
        "idle_timeout": 0,
        "hard_timeout": 0,
        "cookie": 0,
        "flags": 0,
        "length": 0,
    }


def render_flow_stats(dpid: int, entries) -> dict:
    """
    A whole switch's tables in Ryu's `/stats/flow/<dpid>` shape.

    The dpid key is a **string**, as Ryu emits and as the kernel's own
    get_switch_openflow_table_entries reproduces.
    """
    flows = []
    for entry in entries or []:
        converted = entry_to_ryu(entry)
        if converted is not None:
            flows.append(converted)
    return {str(dpid): flows}
