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
  - **`duration` is the proxy's own record, or nothing.** A bmv2 table entry has no age, so
    these two fields were hardcoded zeroes and every P4 rule looked equally new -- measured
    2026-09-07, W16-3. `rule_install_times` supplies the install stamp; an entry it has no
    record of keeps 0/0, which is what `ndt` already reads as "age unknown". See
    KNOWN-ISSUES G-13 and that module's docstring.
"""

from __future__ import annotations

from typing import Any, Optional

from proxy_agent import rule_install_times
from proxy_agent import route_binding

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
#
# [Co-developed with claude code -- Adam] TICKET-P4-roles 2.2-1: the route action's name and its
# port parameter are BASELINE's, not a second spelling of them -- this map used to carry the
# literal, and route_binding.BASELINE is now the only place it is written. A switch bound to a
# package's roles adds ITS action on top (`_vocabulary`).
FORWARDING_ACTIONS = {
    route_binding.BASELINE.action: route_binding.BASELINE.port_param,
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


def _match_to_ryu(match: dict, field_to_ryu=None) -> dict:
    """
    One entry's match fields under Ryu's names.

    Ternary fields whose mask is zero are omitted: a zero mask means "don't care", and emitting
    it as a concrete value would turn a wildcard into a specific match.

    `field_to_ryu` is FIELD_TO_RYU plus a bound switch's route match field (see `_vocabulary`);
    None is FIELD_TO_RYU itself. [Co-developed with claude code -- Adam]
    """
    field_to_ryu = FIELD_TO_RYU if field_to_ryu is None else field_to_ryu
    out: dict[str, Any] = {}
    for p4_name, spec in (match or {}).items():
        ryu_name = field_to_ryu.get(p4_name)
        if ryu_name is None:
            continue

        kind = spec.get("type")
        # Asked of rule_install_times so that the fields this renderer treats as absent are
        # exactly the fields the install-time key treats as absent. Two spellings of "don't
        # care" would mean a rule whose duration is recorded under a key its own flow stats
        # never look up. [Co-developed with claude code -- Adam]
        if rule_install_times.is_dont_care(spec):
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


def _actions_to_ryu(action: Optional[dict], forwarding_actions=None) -> list:
    """
    One entry's actions as Ryu's string forms.

    An empty list is correct for a drop, and the kernel handles it -- Ryu reports its own
    table-miss drop the same way.

    `forwarding_actions` is FORWARDING_ACTIONS plus a bound switch's route action (see
    `_vocabulary`); None is FORWARDING_ACTIONS itself. [Co-developed with claude code -- Adam]
    """
    forwarding_actions = FORWARDING_ACTIONS if forwarding_actions is None else forwarding_actions
    if not action:
        return []

    name = action.get("name") or ""
    params = action.get("params") or {}

    param_name = forwarding_actions.get(name)
    if param_name is not None:
        port = _int(params.get(param_name, b""))
        return [f"OUTPUT:{port}"]

    if name.endswith("send_to_cpu"):
        return [CPU_PORT_OUTPUT]

    # drop(), NoAction, or anything this translator does not know: no output port. Deliberately
    # not guessed -- a wrong port would silently misreport the topology's forwarding.
    return []


def _duration_fields(age_seconds: Optional[float]) -> tuple:
    """
    `(duration_sec, duration_nsec)` for an age in seconds, or `(0, 0)` for an unknown one.

    Split the way OpenFlow splits it: whole seconds and the remainder in nanoseconds, both
    non-negative. `None` -- no install record -- is 0/0, the same pair the endpoint has always
    emitted for a rule nobody can date, so a reader that already treats 0/0 as unknown needs no
    new case. [Co-developed with claude code -- Adam]
    """
    if age_seconds is None:
        return 0, 0
    age = max(0.0, float(age_seconds))
    seconds = int(age)
    nanos = int(round((age - seconds) * 1_000_000_000))
    if nanos >= 1_000_000_000:
        # Rounding the remainder can carry; 1_000_000_000 is not a legal nsec value.
        seconds += 1
        nanos -= 1_000_000_000
    return seconds, nanos


def entry_to_ryu(entry: dict, age_seconds: Optional[float] = None, field_to_ryu=None,
                 forwarding_actions=None) -> Optional[dict]:
    """
    One P4 table entry as a Ryu flow-stats entry, or None if it should not be reported.

    Default actions are skipped: they carry no match fields, so the Classifier would read one as
    a rule that matches every packet at whatever priority it has.

    `age_seconds` is how long ago this proxy installed the entry, or None when it has no record
    of installing it -- see `render_flow_stats`, which is where that is looked up.

    `field_to_ryu` / `forwarding_actions`: the vocabulary for this switch (`_vocabulary`), None
    for NDTwin's own. [Co-developed with claude code -- Adam]
    """
    if entry.get("is_default"):
        return None

    match = _match_to_ryu(entry.get("match") or {}, field_to_ryu)
    if not match:
        # No usable match. Reporting it would be a match-everything rule, as above.
        return None

    duration_sec, duration_nsec = _duration_fields(age_seconds)

    return {
        # bmv2 has one ingress table block; the kernel only needs a stable key here.
        "table_id": 0,
        # Clamped at 0: negative priorities can never win a match in the Classifier, and used to
        # crash it outright.
        "priority": max(0, int(entry.get("priority") or 0)),
        "match": match,
        "actions": _actions_to_ryu(entry.get("action"), forwarding_actions),
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
        # These were hardcoded zeroes too, and for a harder reason than the counters: bmv2 has
        # no per-entry age to read at all (KNOWN-ISSUES G-13). The number below therefore comes
        # from the proxy's own record of writing the rule, and stays 0/0 for a rule it did not
        # write -- which is the answer `ndt` already reads as UNKNOWN, not a claim that the rule
        # is new. [Co-developed with claude code -- Adam]
        "duration_sec": duration_sec,
        "duration_nsec": duration_nsec,
        "idle_timeout": 0,
        "hard_timeout": 0,
        "cookie": 0,
        "flags": 0,
        "length": 0,
    }


# --- whose vocabulary, and what is left out. TICKET-P4-roles 2.5-1 ---------------------------
# [Co-developed with claude code -- Adam]
#
# NDTwin's own pipeline renders exactly as it always did -- every action it declares is one this
# module knows, and an unknown one still renders as an empty action list (the documented choice
# for a future NDTwin action; tests/test_ryu_flow_stats.py pins that body against a capture taken
# at 6291db35).
#
# 🔴 A FOREIGN PIPELINE IS WHERE "UNKNOWN" STOPS MEANING DROP. On somebody else's program an
# action this module does not know is the AUTHOR's semantics -- load_balance's set_ecmp_select,
# multicast's mac_forward -- and rendering it as `actions: []` told the kernel's Classifier "this
# rule drops", which it does not (ANALYSIS section 6). So on a foreign switch such a row is NOT
# LISTED, and `GET /p4/switch_state` says how many were left out (`flow_stats.unrendered_entries`):
# a rule the twin cannot describe is absent and counted, never described wrongly.
#
# The route action is recognised through the switch's binding: a package's roles add its own
# route action and match field to NDTwin's vocabulary. An UNBOUND foreign switch is rendered in
# NDTwin's vocabulary, as it was before roles existed -- so a package without roles keeps its
# /stats/flow body (and the live negative control has the author's entries to compare), except
# for the unknown-action rows the paragraph above now leaves out.

#: Actions that are a drop by name: `drop()` in whichever control declares it, and `NoAction`.
#: Recognised, and rendered as the empty list, on every pipeline.
DROP_ACTION_NAMES = ("drop", "NoAction")


def _vocabulary(binding):
    """(field -> Ryu name, action -> port parameter) this switch's rows are rendered with."""
    if binding is None or binding.source == route_binding.SOURCE_BASELINE:
        return FIELD_TO_RYU, FORWARDING_ACTIONS
    fields = dict(FIELD_TO_RYU)
    fields[binding.match_field] = "nw_dst"
    actions = dict(FORWARDING_ACTIONS)
    actions[binding.action] = binding.port_param
    return fields, actions


def recognises_action(action, forwarding_actions=None) -> bool:
    """Whether this module knows what `action` does: forwards, goes to the CPU, or drops."""
    forwarding_actions = FORWARDING_ACTIONS if forwarding_actions is None else forwarding_actions
    name = (action or {}).get("name") or ""
    if not name:
        return False
    if name in forwarding_actions or name.endswith("send_to_cpu"):
        return True
    return name.rsplit(".", 1)[-1] in DROP_ACTION_NAMES


def render_flow_stats_counted(dpid: int, entries, install_times=None,
                              binding=route_binding.BASELINE):
    """
    `(render_flow_stats(...), how many rows were left out as unrecognised)`.

    `binding` is the switch's route binding: BASELINE (NDTwin's own pipeline -- nothing is ever
    left out, the count is 0), a package binding, or None (a foreign switch with no roles).
    """
    foreign = binding is None or binding.source != route_binding.SOURCE_BASELINE
    field_to_ryu, forwarding_actions = _vocabulary(binding)
    flows, unrendered = [], 0
    for entry in entries or []:
        if (foreign and not entry.get("is_default")
                and not recognises_action(entry.get("action"), forwarding_actions)):
            # Counted only when it would otherwise have been listed: a default row or a row
            # with no usable match is never reported, on any pipeline, so it is not "left out".
            if _match_to_ryu(entry.get("match") or {}, field_to_ryu):
                unrendered += 1
            continue
        age = None
        if install_times is not None:
            age = install_times.age_seconds(dpid, entry.get("table"), entry.get("priority"),
                                            entry.get("match"))
        converted = entry_to_ryu(entry, age_seconds=age, field_to_ryu=field_to_ryu,
                                 forwarding_actions=forwarding_actions)
        if converted is not None:
            flows.append(converted)
    return {str(dpid): flows}, unrendered


def render_flow_stats(dpid: int, entries, install_times=None,
                      binding=route_binding.BASELINE) -> dict:
    """
    A whole switch's tables in Ryu's `/stats/flow/<dpid>` shape.

    The dpid key is a **string**, as Ryu emits and as the kernel's own
    get_switch_openflow_table_entries reproduces.

    `install_times` is the `rule_install_times.RuleInstallTimes` of the client these entries were
    read from -- the only thing on the P4 plane that knows when a rule was installed. Omit it and
    every rule reports `duration 0/0`, which is exactly what this endpoint did before G-13; that
    default exists so the translation stays testable as a pure function, and
    `api_routes.get_flow_stats` passes the real one. The lookup is by
    `rule_install_times.entry_key`, the same key the write paths record under.

    `binding` -- TICKET-P4-roles 2.5-1, see `render_flow_stats_counted`. The default is NDTwin's
    own pipeline, which is what every caller before roles meant.
    """
    return render_flow_stats_counted(dpid, entries, install_times=install_times,
                                     binding=binding)[0]
