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
  - **Match keys must be ones the Classifier can evaluate** (`nw_dst`, `dl_type`, `in_port`,
    ...). It builds a mask from the keys it knows and leaves the bits of any other key at zero,
    so a rule carrying an unknown key MATCHES EVERY PACKET at its priority -- not nothing. A
    field with no name in FIELD_TO_RYU is therefore not rendered: a row with no usable match is
    left out of the body (and counted on a foreign switch). `hdr.ethernet.dstAddr` is such a
    field: it used to render as `dl_dst`, which the Classifier does not evaluate.
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
# listed is deliberately not rendered. Passing an unknown key through would be worse than
# useless: the Classifier reads a key it does not know as matching every packet (see the module
# docstring), so a field belongs here only if the Classifier evaluates the name it maps to.
#
# [Co-developed with claude code -- Adam] The route
# match field is BASELINE's, like the route action below -- `hdr.ipv4.dstAddr` is written once,
# in route_binding.BASELINE. (flow_5tuple matches on the same header field and reads it back
# under this same key, so this one entry serves both of NDTwin's tables.)
FIELD_TO_RYU = {
    route_binding.BASELINE.match_field: "nw_dst",
    "hdr.ipv4.srcAddr": "nw_src",
    "hdr.ipv4.protocol": "nw_proto",
    "meta.l4_src_port": "tp_src",
    "meta.l4_dst_port": "tp_dst",
    "standard_metadata.ingress_port": "in_port",
}

# P4 fields that have NO spelling the Classifier can evaluate (see the module docstring): the
# destination MAC. A row keyed on one alone has no usable match and is left out; a row keyed on one
# AND on a listed field is left out too, because listing it with the MAC dropped would describe a
# wider rule than the switch holds. [Co-developed with claude code -- Adam]
UNRENDERABLE_FIELDS = frozenset({"hdr.ethernet.dstAddr"})

# Bit width of the field behind each Ryu name above. Needed to tell a FULL ternary mask from one
# whose leading zero bytes P4Runtime stripped on the way back (ternary-a0 item 10): a 0x00ff mask
# on a 16-bit port and an 0xff mask on an 8-bit protocol read back as the same byte.
RYU_WIDTH = {
    "nw_dst": 32, "nw_src": 32, "nw_proto": 8, "tp_src": 16, "tp_dst": 16,
    "in_port": 9,
}

# Actions that forward out of a port, and which parameter carries it.
#
# [Co-developed with claude code -- Adam] The route action's name and its
# port parameter are BASELINE's, not a second spelling of them -- this map used to carry the
# literal, and route_binding.BASELINE is now the only place it is written. A switch bound to a
# package's roles adds ITS action on top (`_vocabulary`).
FORWARDING_ACTIONS = {
    route_binding.BASELINE.action: route_binding.BASELINE.port_param,
    "MyIngress.forward_l2": "port",
}

# The ternary table NDTwin writes 5-tuple rules into, by its p4info name (the same string
# `P4RuntimeClient.FIVE_TUPLE_TABLE` writes under; tests/test_flow_stats_route.py ties the two).
#
# [Co-developed with claude code -- Adam] The writer stores an OpenFlow priority n as P4 priority
# n + 1 (`topology_manager.p4_priority`: P4Runtime refuses 0 on a ternary table), and a strict
# delete shifts what it is given the same way. Reading the raw P4 value back made a rule
# installed at 100 show as 101, and a delete at the value shown then asked for 102 and found
# nothing. The read-back undoes the shift for this table, so it shows what was installed.
FIVE_TUPLE_TABLE = "MyIngress.flow_5tuple"
FIVE_TUPLE_PRIORITY_SHIFT = 1

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


def _prefix_to_netmask_suffix(prefix_len: int) -> str:
    """"/24" for a partial prefix, "" for a host route -- how Ryu renders nw_dst."""
    return "" if prefix_len >= 32 else f"/{prefix_len}"


def _ternary_as_ryu(ryu_name: str, spec: dict):
    """
    `("exact", value)` / `("prefix", n)` for a ternary field Ryu can express, else None.

    A mask with every bit of the field set is an exact match. On an address field a mask that is
    a run of leading ones is a prefix, rendered like an lpm field (value/n). Any other mask has
    no Ryu spelling: rendering its value alone would describe a rule matching ONE address where
    the switch matches a pattern, which is the wrong-description failure this module refuses.
    A mask of 0 never gets here (`is_dont_care` drops the field first).
    """
    width = RYU_WIDTH.get(ryu_name)
    if width is None:
        return None
    full = (1 << width) - 1
    mask = _int(spec.get("mask", b"")) & full
    if mask == full:
        return ("exact", _int(spec.get("value", b"")))
    if ryu_name in ("nw_dst", "nw_src"):
        wild = full ^ mask
        if wild & (wild + 1) == 0:       # the wild bits are a run of ones at the bottom
            return ("prefix", width - wild.bit_length())
    return None


def _translate_match(match: dict, field_to_ryu=None):
    """
    `(Ryu match dict, untranslatable)` for one entry's match fields.

    `untranslatable` is True when a field this module maps has a form Ryu cannot say: a ternary
    mask that is not full and, on an address, not a run of leading ones; or any range; or a field
    in UNRENDERABLE_FIELDS (the destination MAC) beside a field that does translate. The row is
    then not to be listed at all (the dict is whatever was translated and must not be used):
    listing the fields that did translate would widen the rule.

    Ternary fields whose mask is zero are omitted: a zero mask means "don't care". Emitting the
    value would turn a wildcard into a specific match.

    `field_to_ryu` is FIELD_TO_RYU plus a bound switch's route match field (see `_vocabulary`);
    None is FIELD_TO_RYU itself. [Co-developed with claude code -- Adam]
    """
    field_to_ryu = FIELD_TO_RYU if field_to_ryu is None else field_to_ryu
    out: dict[str, Any] = {}
    untranslatable = False
    unrenderable_field_set = False
    for p4_name, spec in (match or {}).items():
        ryu_name = field_to_ryu.get(p4_name)
        if ryu_name is None:
            if p4_name in UNRENDERABLE_FIELDS and not rule_install_times.is_dont_care(spec):
                unrenderable_field_set = True
            continue

        kind = spec.get("type")
        # Asked of rule_install_times so that the fields this renderer treats as absent are
        # exactly the fields the install-time key treats as absent. Two spellings of "don't
        # care" would mean a rule whose duration is recorded under a key its own flow stats
        # never look up. [Co-developed with claude code -- Adam]
        if rule_install_times.is_dont_care(spec):
            continue

        if kind == "range":
            untranslatable = True
            continue
        if kind == "ternary":
            shaped = _ternary_as_ryu(ryu_name, spec)
            if shaped is None:
                untranslatable = True
                continue
            if shaped[0] == "prefix":
                out[ryu_name] = _ipv4(spec.get("value", b"")) + _prefix_to_netmask_suffix(shaped[1])
                continue

        if ryu_name in ("nw_dst", "nw_src"):
            text = _ipv4(spec.get("value", b""))
            if kind == "lpm":
                text += _prefix_to_netmask_suffix(spec.get("prefix_len", 32))
            out[ryu_name] = text
        else:
            out[ryu_name] = _int(spec.get("value", b""))

    # A field the Classifier cannot evaluate beside fields it can: the translated ones alone would
    # be a wider rule than the switch's, so the row is not to be listed. (On its own such a field
    # leaves `out` empty and the row has no usable match, as before.)
    if unrenderable_field_set and out:
        untranslatable = True

    # The Classifier keys IPv4 rules off dl_type, so a rule matching on an IP field must say so.
    if any(k in out for k in ("nw_dst", "nw_src", "nw_proto", "tp_src", "tp_dst")):
        out.setdefault("dl_type", ETH_TYPE_IPV4)
    return out, untranslatable


def _match_to_ryu(match: dict, field_to_ryu=None) -> dict:
    """One entry's match fields under Ryu's names (see `_translate_match`)."""
    return _translate_match(match, field_to_ryu)[0]


def match_is_untranslatable(entry: dict, field_to_ryu=None) -> bool:
    """Whether a non-default entry has a field Ryu cannot express, so the row is left out."""
    return _translate_match(entry.get("match") or {}, field_to_ryu)[1]


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


def _openflow_priority(entry: dict, ndtwin_pipeline: bool = True) -> int:
    """
    The priority `entry` is shown with: the raw P4 value, less the writer's shift for a row of
    NDTwin's own 5-tuple table. Never negative: the Classifier can never match a rule below 0.

    The shift is NDTwin's own writer's, so it is undone only on NDTwin's own pipeline; a
    foreign program's table that happens to share the name was not written by it.
    [Co-developed with claude code -- Adam]
    """
    priority = int(entry.get("priority") or 0)
    if ndtwin_pipeline and entry.get("table") == FIVE_TUPLE_TABLE:
        priority -= FIVE_TUPLE_PRIORITY_SHIFT
    return max(0, priority)


def entry_to_ryu(entry: dict, age_seconds: Optional[float] = None, field_to_ryu=None,
                 forwarding_actions=None, ndtwin_pipeline: bool = True) -> Optional[dict]:
    """
    One P4 table entry as a Ryu flow-stats entry, or None if it should not be reported.

    Default actions are skipped: they carry no match fields, so the Classifier would read one as
    a rule that matches every packet at whatever priority it has.

    `age_seconds` is how long ago this proxy installed the entry, or None when it has no record
    of installing it -- see `render_flow_stats`, which is where that is looked up.

    `field_to_ryu` / `forwarding_actions`: the vocabulary for this switch (`_vocabulary`), None
    for NDTwin's own. `ndtwin_pipeline` says whether the 5-tuple priority shift is undone (see
    `_openflow_priority`). [Co-developed with claude code -- Adam]
    """
    if entry.get("is_default"):
        return None

    match, untranslatable = _translate_match(entry.get("match") or {}, field_to_ryu)
    if untranslatable:
        # A field with no Ryu spelling (a partial ternary mask, a range): listing the row with
        # that field missing or flattened would describe a different rule.
        return None
    if not match:
        # No usable match. Reporting it would be a match-everything rule, as above.
        return None

    duration_sec, duration_nsec = _duration_fields(age_seconds)

    return {
        # bmv2 has one ingress table block; the kernel only needs a stable key here.
        "table_id": 0,
        # Clamped at 0: negative priorities can never win a match in the Classifier, and used to
        # crash it outright. A 5-tuple row is shown at the priority it was installed with.
        "priority": _openflow_priority(entry, ndtwin_pipeline),
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


# --- whose vocabulary, and what is left out ---------------------------------------
# [Co-developed with claude code -- Adam]
#
# NDTwin's own pipeline renders its body as it always did, with two deliberate changes -- every
# action it declares is one this module knows, and an unknown one still renders as an empty
# action list (the documented choice for a future NDTwin action; tests/test_ryu_flow_stats.py
# pins that body against a capture taken at 6291db35). The changes: a 5-tuple row is shown at the
# priority it was installed with, and a row keyed on the destination MAC is left out. What the
# ternary writer added there is the rows it leaves out and counts (see the paragraph on the
# baseline count below).
#
# 🔴 A FOREIGN PIPELINE IS WHERE "UNKNOWN" STOPS MEANING DROP. On somebody else's program an
# action this module does not know is the AUTHOR's semantics -- load_balance's set_ecmp_select,
# multicast's mac_forward -- and rendering it as `actions: []` told the kernel's Classifier "this
# rule drops", which it does not. So on a foreign switch such a row is NOT
# LISTED, and `GET /p4/switch_state` says how many were left out (`flow_stats.unrendered_entries`):
# a rule the twin cannot describe is absent and counted, never described wrongly.
#
# 🔴 ON A FOREIGN PIPELINE THE COUNT IS EVERY NON-DEFAULT ROW NOT LISTED: an unknown action, OR a
# match this module cannot translate (reporting that row would be a match-everything rule, so it
# is not listed on any pipeline). Counting only unknown-action rows whose match it could
# translate would miss a foreign program's non-route tables, which match on the program's own
# field names (renamed_route's proto_tags: `hdr.ip4.proto`): their real rows would be neither
# listed nor counted. A default row is not a rule and is never counted.
# On NDTwin's own pipeline the count is narrower: see the paragraph on the baseline count.
#
# 🔴 A MATCH RYU CANNOT SAY IS THE SAME CASE, ON EVERY PIPELINE (the ternary writer). A ternary field
# whose mask is a run of leading ones on an address renders as value/prefix like an lpm field; a
# full mask is an exact value; any other mask, and any range field, has no Ryu spelling, so the row
# is NOT LISTED and IS COUNTED. Listing it with the value alone would describe a rule matching one
# address where the switch matches a pattern.
#
# NDTwin's own pipeline is not counted for unknown ACTIONS: its body is the base's apart from the
# two changes above, so a row whose action is unknown still lists, with the empty action list, as
# it always did. It
# IS counted for a match Ryu cannot say (the paragraph above), and `get_flow_stats` records that
# count for it exactly as for a foreign switch, so `flow_stats.unrendered_entries` is the number
# of such rows on NDTwin's own pipeline too. For the rows NDTwin writes itself that count stays 0:
# that holds only while NDTwin is the only writer of the baseline tables -- NDTwin's own 5-tuple
# writer always uses full masks, and the generic `POST /p4/table_entry` cannot write into them any
# more (the owner check, V7, answers 409 owned_by_ndtwin for every table of NDTwin's own
# pipeline). A row some other writer put there with a partial mask or a range is left out of the
# body and counted, instead of being described wrongly.
#
# A row with no usable match at all (an empty match, or one on fields Ryu has no name for) is left
# out of the body on every pipeline but counted only on a foreign one: NDTwin's own pipeline does
# not count it. That is pinned, and whether it should be counted there is the owner's call.
#
# 🔴 ON A PACKAGE BINDING ONLY THE BOUND TABLE IS RENDERED. Every row is emitted as `table_id: 0`
# and the kernel's Classifier merges what it is given into one table, highest priority first, so
# a package's other tables (an ACL whose permits are `NoAction`, a tag table) would be read as
# competing routes -- a permit rendered as a drop at priority 10 beat the routes and the flow
# read "no rule matches". The rows of every table but `binding.table` are left out and counted in
# `unrendered_entries` (a default row is not a rule and is not counted). A switch with no binding
# names no route table and keeps every table, as before roles existed.
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

    `binding` is the switch's route binding: BASELINE (NDTwin's own pipeline -- the rows counted
    are the non-default ones with a ternary mask or range Ryu cannot spell; an unknown action
    still lists, and a row with no usable match is left out but not counted), a package binding,
    or None (a foreign switch with no roles). On a foreign switch an unknown action and a row with
    no usable match are left out and counted too. On a package binding only the rows of
    `binding.table` are rendered; every non-default row of another table is left out and counted.
    """
    foreign = binding is None or binding.source != route_binding.SOURCE_BASELINE
    field_to_ryu, forwarding_actions = _vocabulary(binding)
    # [Co-developed with claude code -- Adam] On a package's pipeline only the route table the
    # binding names is rendered. The kernel's Classifier merges every row it is given into one
    # table, so another table's rows (an ACL's NoAction permits, a tag table) would compete with
    # the routes; each is absent and counted instead. A switch with no binding names no table,
    # and NDTwin's own pipeline owns all of its tables.
    bound_table = binding.table if foreign and binding is not None else None
    flows, unrendered = [], 0
    for entry in entries or []:
        counts = foreign and not entry.get("is_default")
        if bound_table is not None and counts and entry.get("table") != bound_table:
            unrendered += 1
            continue
        if counts and not recognises_action(entry.get("action"), forwarding_actions):
            unrendered += 1
            continue
        if not entry.get("is_default") and match_is_untranslatable(entry, field_to_ryu):
            # On EVERY pipeline, NDTwin's own included (and `get_flow_stats` keeps the count for
            # all of them): see the paragraph on the baseline count.
            unrendered += 1
            continue
        age = None
        if install_times is not None:
            age = install_times.age_seconds(dpid, entry.get("table"), entry.get("priority"),
                                            entry.get("match"))
        converted = entry_to_ryu(entry, age_seconds=age, field_to_ryu=field_to_ryu,
                                 forwarding_actions=forwarding_actions,
                                 ndtwin_pipeline=not foreign)
        if converted is not None:
            flows.append(converted)
        elif counts:
            # A known action on a match this module cannot translate: not listed, so counted.
            unrendered += 1
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

    `binding` -- see `render_flow_stats_counted`. The default is NDTwin's
    own pipeline, which is what every caller before roles meant.
    """
    return render_flow_stats_counted(dpid, entries, install_times=install_times,
                                     binding=binding)[0]
