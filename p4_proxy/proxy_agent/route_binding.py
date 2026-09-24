"""Which table, match field, action and parameters a destination route is written with.

[Co-developed with claude code -- Adam]

TICKET-P4-roles section 2.2. Until this module every destination route this proxy wrote --
`insert/modify/delete_ipv4_route`, `install_initial_routes`, the delete's read-back -- spelled
five names as string literals: `MyIngress.ipv4_lpm`, `hdr.ipv4.dstAddr`, `MyIngress.ipv4_forward`,
`dstAddr`, `port`. Those are ndtwin_switch.p4's names. Seven of the thirteen tutorials exercises
declare the same five names for a table that means the same thing (ANALYSIS section 3), so the
literals WROTE INTO THE AUTHOR'S TABLE on a foreign pipeline -- and where the author had already
declared the same /32, the INSERT failed and the MODIFY fallback overwrote it (ANALYSIS 2.1
INFERRED 1). Names are not consent.

So a route is written through a `RouteBinding`, and there are exactly three answers to "which
binding does this switch have", decided when its client is built (`main.build_p4_client`, which
readopt uses too):

  * NDTwin's own pipeline      -> `BASELINE`, whose five names are the literals above. The only
                                  place they are spelled (the gate in tests/test_route_binding.py
                                  asserts it), so the baseline cannot drift from itself;
  * a foreign pipeline whose package declares `roles.ipv4_route`
                               -> `resolve(...)` of that declaration against THIS switch's p4info;
  * a foreign pipeline with no `roles`
                               -> None: unbound. Every route write is refused with 501
                                  `unsupported_on_p4`, reason `unbound`.

🔴 NAMES ARE NEVER GUESSED HERE. `resolve` checks what the package said against the p4info and
refuses anything that does not fit; it does not look for a table that "looks like" a route
table. The heuristic exists, and it lives in exactly one place -- tools/p4_exercise/preflight.py,
where it prints a SUGGESTION an author may paste (section 2.1-6).

🔴 ONE FUNCTION, TWO CALLERS (section 2.1-4). `resolve` is what pre-flight runs before the fabric
exists and what the proxy runs when it builds each client, so the two refuse the same packages
with the same sentence. A proxy-side failure refuses startup; it does NOT fall back to unbound,
because a package that asked for a binding and silently did not get one would run with every
route write answering 501 and nothing saying why.

Deliberately free of gRPC: pre-flight imports this module, and the only protobuf it touches is
the generated enum `p4info_pb2.MatchField.MatchType`, read by name rather than transcribed (the
numbering skips 1).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

#: Where a binding came from.
SOURCE_BASELINE = "baseline"
SOURCE_PACKAGE = "package"

#: Who owns the table a binding names (section 2.1-2). `ndtwin`: NDTwin writes it, exclusively
#: -- the package's own entries for it are refused at pre-flight (Adam's ruling 8-1).
#: `package`: the author owns it; NDTwin knows the binding (to read and render the table) and
#: writes nothing into it.
OWNER_NDTWIN = "ndtwin"
OWNER_PACKAGE = "package"
OWNERS = (OWNER_NDTWIN, OWNER_PACKAGE)

#: The keys of `roles.ipv4_route` and of its `params`, exactly. app_package validates the shape
#: with these same tuples; they are here because `resolve` is handed the same dict.
ROLE_KEYS = ("owner", "table", "match_field", "action", "params")
PARAM_KEYS = ("dst_mac", "port")

#: What a destination route's match must be: one LPM field, 32 bits wide.
ROUTE_MATCH_TYPE = "LPM"
ROUTE_MATCH_BITWIDTH = 32
#: What the next-hop MAC parameter must be.
DST_MAC_BITWIDTH = 48

#: Why a route write was refused with 501. `unbound` and `owned_by_package` are section 2.2-3's
#: two words; `no_five_tuple_role` is the 5-tuple refusal on a foreign switch (this cut has no
#: 5-tuple role, so a foreign pipeline cannot take one whatever its roles say).
REASON_UNBOUND = "unbound"
REASON_OWNED_BY_PACKAGE = "owned_by_package"
REASON_NO_FIVE_TUPLE_ROLE = "no_five_tuple_role"


@dataclass(frozen=True)
class RouteBinding:
    """The five names a destination route is written with, and whose table they name.

    `port_bitwidth` is the width the p4info gives the port parameter; the value goes on the
    wire in ceil(width/8) bytes. It is not one of the seven fields TICKET-P4-roles 2.2-1 lists
    -- it is carried because a package binding's port may be any width the p4info declares, and
    re-deriving it on every write would put a p4info walk on the route path. BASELINE's 9 is
    ndtwin_switch.p4's `bit<9>`, i.e. the two bytes the literal code always wrote.
    """

    table: str
    match_field: str
    action: str
    dst_mac_param: str
    port_param: str
    owner: str
    source: str
    port_bitwidth: int = 9

    @property
    def port_bytes(self) -> int:
        return (int(self.port_bitwidth) + 7) // 8


#: 🔴 THE ONLY PLACE THESE FIVE NAMES ARE SPELLED FOR A ROUTE WRITE. They are ndtwin_switch.p4's
#: ipv4_lpm / ipv4_forward, and they are the literals every write path used before this module
#: existed -- so a client bound to BASELINE puts the same bytes on the wire it always did
#: (tests/test_p4_client_writes.py compares the serialised WriteRequests against a capture taken
#: at 6291db35). tests/test_route_binding.py asserts each value, and asserts that no other
#: production module spells the table or action name.
BASELINE = RouteBinding(
    table="MyIngress.ipv4_lpm",
    match_field="hdr.ipv4.dstAddr",
    action="MyIngress.ipv4_forward",
    dst_mac_param="dstAddr",
    port_param="port",
    owner=OWNER_NDTWIN,
    source=SOURCE_BASELINE,
    port_bitwidth=9,
)


class RouteBindingError(ValueError):
    """A package's `roles.ipv4_route` does not fit a switch's p4info. Refuses startup.

    ValueError, like AppPackageError, so a caller that already funnels malformed-package
    failures keeps catching it. The message names the switch and every field that does not fit:
    pre-flight prints it as a FAIL row and the proxy raises it, word for word.
    """


class RouteWriteUnsupported(NotImplementedError):
    """This switch has no binding NDTwin may write a route through. -> HTTP 501.

    [Co-developed with claude code -- Adam]
    NotImplementedError for the reason TableEntryUnsupported is one: it is not a malformed
    request and not a switch fault -- the request is well-formed OpenFlow that this data plane,
    as declared, does not implement -- and api_routes turns it into the 501 shape the six
    group/meter endpoints and the priority refusal already use (`outcome: unsupported_on_p4`).

    Raised BEFORE anything is built or sent, and after `_refuse_write`: an external control
    plane's 409-shaped refusal keeps precedence over this one (section 2.2-4).
    """

    def __init__(self, reason, device_id, what):
        self.reason = reason
        self.device_id = device_id
        self.what = what
        super().__init__(describe_refusal(reason, device_id, what))


def describe_refusal(reason, device_id, what):
    """The sentence a 501 carries, per reason. One place, so the log and the body agree."""
    if reason == REASON_UNBOUND:
        why = ("this switch runs the app package's own pipeline and the package declares no "
               "roles.ipv4_route, so NDTwin does not know which of its tables is a route "
               "table and writes none of them")
    elif reason == REASON_OWNED_BY_PACKAGE:
        why = ("the app package declares roles.ipv4_route with owner 'package': the author "
               "owns that table, and NDTwin reads it but does not write it")
    elif reason == REASON_NO_FIVE_TUPLE_ROLE:
        why = ("this switch runs the app package's own pipeline, which has no 5-tuple role "
               "(TICKET-P4-roles first cut: only a destination route can be bound)")
    else:
        why = f"no route binding ({reason})"
    return f"switch {device_id}: refusing {what} -- {why}"


# --- resolving a package's declaration against one p4info ---------------------------------------


def _match_type_name(field):
    """The p4info's own name for a match type. Read out of the generated enum, never transcribed:
    P4Runtime skips 1 (EXACT=2, LPM=3, TERNARY=4, ...), so a hand-written table is one off."""
    from p4.config.v1 import p4info_pb2  # local: keep this module importable without protobuf

    try:
        return p4info_pb2.MatchField.MatchType.Name(int(field.match_type))
    except ValueError:
        return f"match_type {field.match_type}"


def _by_name(items, name):
    for item in items:
        if name in (item.preamble.name, item.preamble.alias):
            return item
    return None


def bits_for_port(port):
    """How many bits a port number needs. 0 still needs one bit."""
    return max(1, int(port).bit_length())


def resolve(role, p4info, max_port=None, where="roles.ipv4_route"):
    """
    The RouteBinding `role` names on this p4info, or RouteBindingError listing every mismatch.

    [Co-developed with claude code -- Adam]
    `role` is `roles.ipv4_route` exactly as package.json spells it -- `{"owner", "table",
    "match_field", "action", "params": {"dst_mac", "port"}}` -- because pre-flight hands this
    the raw manifest and the proxy hands it `app_package.RouteRole.as_manifest()`. `max_port` is
    the largest port the package's topology gives this switch (None skips that one check, for a
    caller that has no model). `where` prefixes every message ("s1: roles.ipv4_route").

    Checked, in section 2.1-4's order, and ALL reported rather than the first:
      * the table exists;
      * `match_field` is a field of that table, its match type is LPM and it is 32 bits wide
        (a route is a destination prefix; anything else would be written as one and mean
        something else);
      * `action` is one of that table's action refs;
      * both params exist on the action, `dst_mac` is 48 bits, `port` is as wide as the p4info
        says AND wide enough for `max_port`;
      * the action takes no third parameter -- NDTwin would have nothing to put in it, and an
        omitted parameter is written as zero (TableEntryInvalid's argument).

    Names may be given as the p4info's full name or its alias -- tutorials' own helper accepts
    both -- and the binding always carries the FULL name, which is what read_table_entries
    reports back, so the renderer and the install-time record compare like with like.
    """
    problems = []
    if not isinstance(role, dict):
        raise RouteBindingError(f"{where}: must be an object, got {type(role).__name__}")
    missing = [k for k in ROLE_KEYS if k not in role]
    if missing:
        raise RouteBindingError(f"{where}: missing {missing}")
    params = role.get("params")
    if not isinstance(params, dict) or [k for k in PARAM_KEYS if k not in params]:
        raise RouteBindingError(f"{where}.params: must name both {list(PARAM_KEYS)}")
    owner = role["owner"]
    if owner not in OWNERS:
        raise RouteBindingError(f"{where}.owner: must be one of {list(OWNERS)}, got {owner!r}")

    table = _by_name(p4info.tables, role["table"])
    if table is None:
        known = sorted(t.preamble.name for t in p4info.tables)
        raise RouteBindingError(
            f"{where}.table: {role['table']!r} is not a table of this pipeline "
            f"(it has: {known[:8]})")

    field = None
    for candidate in table.match_fields:
        if candidate.name == role["match_field"]:
            field = candidate
    if field is None:
        problems.append(
            f"{where}.match_field: {table.preamble.name} has no match field "
            f"{role['match_field']!r} (it matches on {[f.name for f in table.match_fields]})")
    else:
        kind = _match_type_name(field)
        if kind != ROUTE_MATCH_TYPE:
            problems.append(
                f"{where}.match_field: {table.preamble.name}.{field.name} is a {kind} match; a "
                f"destination route is an {ROUTE_MATCH_TYPE} match")
        if int(field.bitwidth) != ROUTE_MATCH_BITWIDTH:
            problems.append(
                f"{where}.match_field: {table.preamble.name}.{field.name} is {field.bitwidth} "
                f"bits; an IPv4 destination is {ROUTE_MATCH_BITWIDTH}")
        if len(table.match_fields) != 1:
            problems.append(
                f"{where}.table: {table.preamble.name} matches on "
                f"{[f.name for f in table.match_fields]}; a route table matches on the "
                f"destination alone, and NDTwin would leave the other key(s) unset")

    action = _by_name(p4info.actions, role["action"])
    dst_mac = port = None
    if action is None:
        problems.append(f"{where}.action: {role['action']!r} is not an action of this pipeline")
    else:
        refs = {ref.id for ref in table.action_refs}
        if action.preamble.id not in refs:
            problems.append(
                f"{where}.action: {action.preamble.name} is not one of "
                f"{table.preamble.name}'s actions")
        by_name = {p.name: p for p in action.params}
        dst_mac = by_name.get(params["dst_mac"])
        port = by_name.get(params["port"])
        if dst_mac is None:
            problems.append(
                f"{where}.params.dst_mac: {action.preamble.name} has no parameter "
                f"{params['dst_mac']!r} (it takes {sorted(by_name)})")
        elif int(dst_mac.bitwidth) != DST_MAC_BITWIDTH:
            problems.append(
                f"{where}.params.dst_mac: {action.preamble.name}.{dst_mac.name} is "
                f"{dst_mac.bitwidth} bits; a MAC address is {DST_MAC_BITWIDTH}")
        if port is None:
            problems.append(
                f"{where}.params.port: {action.preamble.name} has no parameter "
                f"{params['port']!r} (it takes {sorted(by_name)})")
        elif int(port.bitwidth) <= 0:
            problems.append(
                f"{where}.params.port: {action.preamble.name}.{port.name} has no width in "
                f"this p4info, so a port number cannot be encoded")
        elif max_port is not None and bits_for_port(max_port) > int(port.bitwidth):
            problems.append(
                f"{where}.params.port: {action.preamble.name}.{port.name} is "
                f"{port.bitwidth} bits and the topology gives this switch port {max_port}")
        if dst_mac is not None and port is not None and dst_mac.name == port.name:
            problems.append(f"{where}.params: dst_mac and port name the same parameter")
        extra = sorted(set(by_name) - {params["dst_mac"], params["port"]})
        if extra:
            problems.append(
                f"{where}.action: {action.preamble.name} also takes {extra}; NDTwin has "
                f"nothing to put there, and an omitted parameter is written as zero")

    if problems:
        raise RouteBindingError("; ".join(problems))
    return RouteBinding(table=table.preamble.name, match_field=field.name,
                        action=action.preamble.name, dst_mac_param=dst_mac.name,
                        port_param=port.name, owner=owner, source=SOURCE_PACKAGE,
                        port_bitwidth=int(port.bitwidth))


def capability_word(binding: Optional[RouteBinding]) -> str:
    """`capabilities.ipv4_route` for a binding: its owner, or `unbound` (section 2.5-2)."""
    return REASON_UNBOUND if binding is None else binding.owner


def source_word(binding: Optional[RouteBinding]):
    """`capabilities.binding_source`: `baseline`, `package`, or None for unbound."""
    return None if binding is None else binding.source
