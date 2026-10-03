"""What a table entry's match fields and priority may look like, decided in one place.

[Co-developed with claude code -- Adam]

`P4RuntimeClient.build_table_entry` (the proxy, with the switch's p4info in hand) and
`tools/p4_exercise/preflight.check_entry` (the pre-flight, with a package's p4info and no fabric)
both have to answer "may this entry go on a P4Runtime wire". Until this module they answered it
twice, and the two answers were free to differ: the pre-flight refused every ternary field with
"G5 not done" while the writer refused the same field with a 501 of its own. The precedent is
`route_binding.resolve` -- one function, two callers -- and this module follows it.

The rules (design DESIGN.md 2.2, V1-V9; V7, the owner check, is not here because it needs a route
binding, which pre-flight reaches by its own road):

  V1  arity     TERNARY and RANGE take exactly two elements; OPTIONAL takes one value.
  V2  encoding  every value goes through `encode_value`; one that does not fit is refused, never
                truncated.
  V3  a ternary value has no bit set outside its mask. The value is not masked on the author's
                behalf.
  V4  a range has low <= high.
  V5  the second spelling of "don't care" is refused -- a zero mask, the whole range, an lpm /0 --
                with "omit the field". One entry, one wire shape.
  V6  priority  a table with a TERNARY, RANGE or OPTIONAL field has a priority column, and every
                insert, modify and delete names a priority in 1..PRIORITY_MAX; a default entry
                takes none; an EXACT/LPM-only table takes none.
  V8  an EXACT field may not be omitted from a non-default entry.
  V9  an lpm value has no bit set beyond its prefix.

Each of them repeats a refusal bmv2 already makes (measured on a throwaway simple_switch_grpc,
2026-10-04, ternary-a0 items 01-15). They are made here so the answer is a 400 with a sentence
instead of a 502 UNKNOWN, so nothing reaches the wire, and so pre-flight can say the same thing
before the fabric exists.

Deliberately free of gRPC and of protobuf: match types arrive as the p4info's own NAMES
("TERNARY"), which the caller reads out of the generated enum -- that enum skips 1, and
transcribing its numbers is how an lpm entry becomes a /32 (see p4_client._match_type_name).
"""
from __future__ import annotations

import socket

#: Every match type this module can shape. Anything else in the p4info enum (UNSPECIFIED, or a
#: target-specific `other`) is TableEntryUnsupported -> HTTP 501, and is the only 501 left.
BUILDABLE_MATCH_TYPES = ("EXACT", "LPM", "TERNARY", "RANGE", "OPTIONAL")

#: A table with any of these has a priority column (P4Runtime spec; bmv2 refuses a non-zero
#: priority on a table without one and a zero priority on a table with one, ternary-a0 items
#: 14 and 15). Defined by what the table HAS, not by what the writer cannot build: the old
#: definition ("not in BUILDABLE_MATCH_TYPES") would answer False for everything the moment the
#: tuple above grew.
PRIORITY_MATCH_TYPES = ("TERNARY", "RANGE", "OPTIONAL")

#: P4Runtime's `priority` is an int32. ternary-a0 item 07 wrote 13 values from 1 to 2^31-1 and
#: bmv2 took every one of them, without an abort; -1 was refused.
PRIORITY_MAX = (1 << 31) - 1

#: The sentence V5 ends in, and the one thing a client has to do about it.
OMIT_THE_FIELD = "omit the field"


class TableEntryUnsupported(NotImplementedError):
    """
    The p4info describes this entry and this proxy cannot build it. -> HTTP 501.

    [Co-developed with claude code -- Adam]
    Only a match type the P4Runtime enum names and this module does not shape (UNSPECIFIED, or
    `other`) lands here now; EXACT, LPM, TERNARY, RANGE and OPTIONAL are built. A capability
    this writer lacks is not a malformed request and not a missing table -- it is the same thing
    the six group/meter endpoints already mean by 501 (P4RoutingStrategy.cpp:11-23).

    NotImplementedError so an `except Exception` still contains it while `except ValueError`
    -- the shape errors below -- deliberately does not.
    """


class TableEntryInvalid(ValueError):
    """
    The request cannot be represented in this pipeline. -> HTTP 400.

    [Co-developed with claude code -- Adam]
    A value wider than its field, an lpm prefix outside the field, a default action carrying a
    match, a priority the table cannot honour, a ternary value with a bit outside its mask. Every
    one of them is the client's error, and every one of them is refused BEFORE anything reaches
    `stub.Write` -- a rule that lands and is then reported as a 400 is the defect
    `modify_ipv4_route` used to have, inverted.

    `rule` names which of V1-V9 refused it ("V3"), or is None for the older refusals. A caller
    that wants one rule only -- pre-flight, for exact and lpm fields, where it keeps its own
    looser encoder -- asks for it by name rather than by parsing the sentence.

    ValueError, so a caller that already funnels malformed input (AppPackageError is one too)
    keeps catching it.
    """

    def __init__(self, message, rule=None):
        super().__init__(message)
        self.rule = rule


def encode_value(value, bitwidth) -> bytes:
    """
    One P4Runtime field value, in the ceil(bitwidth/8) bytes the target expects.

    [Co-developed with claude code -- Adam]
    The rules are tutorials' `p4runtime_lib/convert.encode` -- a dotted string is an IPv4
    address, a colon-separated one is a MAC, anything else is an integer, and everything is
    big-endian and exactly as wide as the field. They are re-stated here rather than imported:
    `~/tutorials` is not a dependency of this proxy, it is a directory on one laptop, and a
    writer that only works where somebody cloned a tutorial is not a writer this fabric can
    ship. The agreement is asserted instead -- tests/test_p4_client_writes.py pins each rule
    against the values from the exercises' own runtime files.

    🔴 A VALUE THAT DOES NOT FIT IS REFUSED, NOT TRUNCATED. `int.to_bytes` raises OverflowError,
    but `value & mask` would not, and a silently narrowed value installs a rule for an address
    nobody asked about -- which forwards, and reports success. bmv2 also rejects a value of the
    wrong width outright, so a short or long encoding here surfaces as an opaque UNKNOWN from
    the switch rather than as the client error it is.

    `True` is not 1 here. JSON has a boolean and P4 does not; a manifest that wrote `true` where
    it meant `1` is a file somebody should fix, and accepting it would encode a type confusion.
    """
    try:
        bitwidth = int(bitwidth)
    except (TypeError, ValueError):
        raise TableEntryInvalid(f"bitwidth must be an integer, got {bitwidth!r}", rule="V2")
    if bitwidth <= 0:
        raise TableEntryInvalid(
            f"this pipeline's p4info gives the field a bitwidth of {bitwidth}; a field with no "
            f"width has no encoding, so nothing is guessed here", rule="V2")
    width = (bitwidth + 7) // 8

    if isinstance(value, (bytes, bytearray)):
        raw = bytes(value)
        if len(raw) != width:
            raise TableEntryInvalid(
                f"a bit<{bitwidth}> field takes {width} byte(s), got {len(raw)}", rule="V2")
        return raw

    if isinstance(value, bool):
        raise TableEntryInvalid(
            f"{value!r} is a JSON boolean, not a value for a bit<{bitwidth}> field", rule="V2")

    if isinstance(value, str):
        text = value.strip()
        if ":" in text:
            if bitwidth != 48:
                raise TableEntryInvalid(
                    f"{text!r} is a MAC address (48 bits) and the field is bit<{bitwidth}>",
                    rule="V2")
            groups = text.split(":")
            if len(groups) != 6 or any(len(g) != 2 for g in groups):
                raise TableEntryInvalid(f"{text!r} is not a MAC address like 08:00:00:00:01:11",
                                        rule="V2")
            try:
                return bytes.fromhex("".join(groups))
            except ValueError:
                raise TableEntryInvalid(f"{text!r} is not a MAC address like 08:00:00:00:01:11",
                                        rule="V2")
        if "." in text:
            if bitwidth != 32:
                raise TableEntryInvalid(
                    f"{text!r} is an IPv4 address (32 bits) and the field is bit<{bitwidth}>",
                    rule="V2")
            try:
                return socket.inet_aton(text)
            except OSError:
                raise TableEntryInvalid(f"{text!r} is not an IPv4 address", rule="V2")
        try:
            # base 0 so "0x0a" and "10" both work, which is what the runtime files contain.
            value = int(text, 0)
        except ValueError:
            raise TableEntryInvalid(
                f"{text!r} is neither an address, a MAC, nor an integer literal", rule="V2")

    if not isinstance(value, int):
        raise TableEntryInvalid(
            f"{value!r} ({type(value).__name__}) is not a value for a bit<{bitwidth}> field",
            rule="V2")
    if value < 0:
        raise TableEntryInvalid(f"{value} is negative; P4 fields are unsigned", rule="V2")
    if value >= (1 << bitwidth):
        raise TableEntryInvalid(
            f"{value} does not fit in bit<{bitwidth}> (max {(1 << bitwidth) - 1}); a value this "
            f"wide would have to be truncated, and a truncated rule matches traffic nobody "
            f"asked about", rule="V2")
    return value.to_bytes(width, byteorder="big")


def _as_int(raw: bytes) -> int:
    return int.from_bytes(raw, "big")


def _encode_in_field(where, value, bitwidth):
    """`encode_value`, with the field's name on the message."""
    try:
        return encode_value(value, bitwidth)
    except TableEntryInvalid as exc:
        raise TableEntryInvalid(f"{where}: {exc}", rule=exc.rule)


def table_has_priority_column(kinds) -> bool:
    """Whether a table whose fields have these match-type NAMES carries a priority column."""
    return any(kind in PRIORITY_MATCH_TYPES for kind in kinds)


def shape_field(where, kind, bitwidth, raw):
    """
    One match field's value, checked and encoded. `where` is "table.field" for the messages.

    Returns a tuple led by the match type name, then the bytes the wire carries:

        ("EXACT", value)             ("LPM", value, prefix_len)
        ("TERNARY", value, mask)     ("RANGE", low, high)          ("OPTIONAL", value)

    Raises TableEntryUnsupported for a match type this module does not shape, and
    TableEntryInvalid (carrying the V-rule that refused it) for everything else.
    """
    if kind == "EXACT":
        # 🔴 ONE ELEMENT IS UNWRAPPED, TWO ARE STILL REFUSED (TICKET-P3 section 9 ruling 23②).
        # [Co-developed with claude code -- Adam]
        #
        # The upstream exercises write an exact value as a one-element list --
        # `basic_tunnel/sX-runtime.json` has `"hdr.myTunnel.dst_id": [1]` -- and the reference
        # controller they are written against unwraps it before inferring a type
        # (~/tutorials/utils/p4runtime_lib/convert.py:71-75, `encode`). This writer refused it,
        # so `basic_tunnel/solution` came up with three of its six entries missing on every
        # switch and the exercise failed in both live passes (probe2-basic_tunnel-proxy.log).
        # A proxy stricter than the reference implementation is a proxy the exercises cannot
        # be brought up on.
        #
        # Two elements stay a refusal, and not for symmetry: `[value, prefix_len]` is the LPM
        # shape and `[value, mask]` the ternary one. Taking either here would install a rule
        # matching ONE address where the author wrote one matching a subnet -- it forwards, it
        # blackholes the rest, and nothing errors.
        #
        # Before the type is inferred, exactly like upstream's, so a string inside the list is
        # still read as a MAC or an address rather than as an integer literal.
        if isinstance(raw, (list, tuple)):
            if len(raw) != 1:
                raise TableEntryInvalid(
                    f"{where} is an EXACT match, so its value is a plain value or a "
                    f"one-element list, not {list(raw)!r}", rule="V1")
            raw = raw[0]
        return ("EXACT", encode_value(raw, bitwidth))

    if kind == "LPM":
        if not isinstance(raw, (list, tuple)) or len(raw) != 2:
            raise TableEntryInvalid(
                f"{where} is an LPM match, so its value is [value, prefix_len]; got {raw!r}",
                rule="V1")
        value, prefix_len = raw
        if isinstance(prefix_len, bool) or not isinstance(prefix_len, int):
            raise TableEntryInvalid(
                f"{where}: the prefix length must be an integer, got {prefix_len!r}", rule="V1")
        if not 0 <= prefix_len <= int(bitwidth):
            raise TableEntryInvalid(
                f"{where}: prefix length {prefix_len} is outside 0..{bitwidth}", rule="V1")
        encoded = encode_value(value, bitwidth)
        return ("LPM", encoded, prefix_len)

    if kind == "TERNARY":
        value = _encode_in_field(where, raw[0], bitwidth)
        mask = _encode_in_field(where, raw[1], bitwidth)
        return ("TERNARY", value, mask)

    if kind == "RANGE":
        low = _encode_in_field(where, raw[0], bitwidth)
        high = _encode_in_field(where, raw[1], bitwidth)
        return ("RANGE", low, high)

    if kind == "OPTIONAL":
        if isinstance(raw, (list, tuple)):
            raw = raw[0]
        return ("OPTIONAL", _encode_in_field(where, raw, bitwidth))

    raise TableEntryUnsupported(
        f"{where} is a {kind} match, and this proxy builds {', '.join(BUILDABLE_MATCH_TYPES)} "
        f"entries only. Nothing was written.")


def shape_match(table_name, fields, match, is_default=False):
    """
    The whole match of one entry, field by field. `fields` is `[(name, kind, bitwidth), ...]` for
    every field of the table; every key of `match` must already be one of those names (the caller
    resolved them, and a name it could not resolve is its own 404).

    Returns `{field name: shape_field(...)}`, in the order `match` gave them. V8 lives here: an
    EXACT field of the table that a non-default entry does not name is refused, because bmv2
    would refuse it (ternary-a0 item 03) with an UNKNOWN the proxy reports as 502.
    """
    by_name = {name: (kind, bitwidth) for name, kind, bitwidth in fields}
    shaped = {}
    for name, raw in (match or {}).items():
        kind, bitwidth = by_name[name]
        shaped[name] = shape_field(f"{table_name}.{name}", kind, bitwidth, raw)
    return shaped


def shape_priority(table_name, kinds, priority, is_default=False):
    """The priority an entry may carry on this table, as the int that goes on the wire.

    `kinds` is the match-type names of the table's fields. A non-zero priority on a table with
    no priority column is refused; everything else is passed through.
    """
    if priority is not None and (isinstance(priority, bool) or not isinstance(priority, int)):
        raise TableEntryInvalid(
            f"{table_name}: 'priority' must be an integer or null, got {priority!r}", rule="V6")
    value = priority or 0
    if value and not table_has_priority_column(kinds):
        raise TableEntryInvalid(
            f"priority not honourable on this table: {table_name} matches only on "
            f"{list(kinds)} fields, which have no priority column -- precedence there is the "
            f"prefix length and the table holds one entry per key, so priority {priority} "
            f"cannot select an entry. Omit it, or write to a table with a ternary field.",
            rule="V6")
    return value
