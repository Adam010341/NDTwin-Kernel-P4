"""bmv2 `simple_switch_CLI` table commands, as tutorials-shaped P4Runtime runtime entries.

[Co-developed with claude code -- Adam]

The other direction from tools/p4_health/runtime_cli.py, which turns a runtime JSON into CLI
lines for a throwaway switch. This one exists because some published bmv2 apps program part of
their fabric through the CLI instead of a runtime file -- niloysh/int-v1 installs its INT source
rules with `simple_switch_CLI <<< "table_add ..."` in runtime_cmds/s1.sh -- and an NDTwin package
carries P4Runtime entries only: the proxy is the switch's P4Runtime primary, and nothing in a
bring-up speaks thrift to a fabric switch.

Two commands are translated, `table_add` and `table_set_default`, for EXACT, LPM, TERNARY and
RANGE fields. Everything else -- table_modify/delete, mirroring, multicast, registers, counters,
meters, OPTIONAL fields -- is refused with the command named, never skipped: a skipped command
is a rule the app relies on that the fabric does not have, and it presents as an app that "does
nothing" while every switch reports healthy.

The CLI and P4Runtime disagree in three places, and each is translated rather than copied:

  * TERNARY VALUES. The CLI takes `10.0.1.1&&&0xFFFFFF00` and the switch matches it as the
    masked value; P4Runtime refuses a value with a bit outside its mask (match_shape V3). The
    entry carries `value & mask` and the conversion says it did so. A zero mask is the CLI's
    "don't care" and P4Runtime's refused second spelling of it (V5): the field is omitted.
    The same goes for a whole range and an lpm /0. An lpm value with host bits is REFUSED,
    not masked: what the switch does with one was not measured.
  * PRIORITY. In bmv2 the LOWER number wins and 0 is allowed; in P4Runtime the HIGHER number
    wins (spec 9.1) and a ternary/range table needs 1..2^31-1. Only the order inside one table
    means anything, so the translation is p4rt = (largest CLI priority in that table + 1) - CLI
    priority: thrift 0 alone becomes 1, and thrift (0, 5) becomes (6, 1).
  * NAMES. The CLI resolves a name the way runtime_CLI does: the full name, or a dot-separated
    suffix that exactly one object has. The entry carries the full p4info name. A suffix two
    objects share is refused with both candidates named, never picked -- int-v1's program has
    two actions called `nop`.

Values follow runtime_CLI's parser: a dotted quad only for a 32-bit field, a colon MAC only for
a 48-bit one, anything else `int(token, 0)`. A value that does not fit its field is refused. In
the entry, a dotted or MAC value stays a string and every other value is a JSON number (a hex
string would be read by pre-flight's exact/lpm encoder as already-encoded bytes).
"""
from __future__ import annotations

import re
import socket

TRANSLATED_COMMANDS = ("table_add", "table_set_default")
PRIORITY_KINDS = ("TERNARY", "RANGE", "OPTIONAL")
PRIORITY_MAX = (1 << 31) - 1

#: `NAME=value` with no command after it -- the only other line a CLI script may contain. The
#: value is one word or an arithmetic expansion `$((...))` (int-v1 computes its thrift port that
#: way); a command substitution `$(...)` runs a command, and is refused like any other.
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=(?:[^\s$`;&|]*|\$\(\([^()`;&|]*\)\))$")
#: `simple_switch_CLI [flags] <<< "command"` (or 'command').
_CLI_CALL = re.compile(r"""^simple_switch_CLI((?:\s+[^<\s]+)*)\s*<<<\s*(?:"([^"]*)"|'([^']*)')\s*$""")
#: The CLI flags that only say WHERE the switch is. Anything else (`--json`, `--pre`) changes
#: what the CLI resolves names against, which a translation against the package's p4info
#: cannot honour.
_ADDRESS_FLAGS = ("--thrift-port", "--thrift-ip")


class Untranslatable(ValueError):
    """This CLI input has no faithful P4Runtime entry. Refused, never approximated."""


# --- reading the commands ----------------------------------------------------------------------

def commands_from_text(text, source):
    """[(line number, CLI command)] out of a commands file or a CLI shell script.

    A path ending in `.sh` is a script: blank lines, comments, the shebang and plain
    `NAME=value` assignments are skipped, every `simple_switch_CLI ... <<< "cmd"` contributes
    its command, and ANY other line is refused -- this reads the script, it does not run it, so
    a loop, an `echo` or a `source` would be a command the switch got that nobody can see here.
    A command that needs the shell to expand it (`$X`) is refused for the same reason. Any other
    path is a plain commands file, one CLI command per line, `#` comments allowed.
    """
    shell = str(source).endswith(".sh")
    out = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if not shell:
            out.append((number, line))
            continue
        if _ASSIGNMENT.match(line):
            continue
        m = _CLI_CALL.match(line)
        if m is None:
            raise Untranslatable(
                f"{source} line {number}: {line!r} is neither a `simple_switch_CLI ... <<< "
                f"\"command\"` call nor a variable assignment. This script is read, not run, "
                f"so a line whose effect cannot be seen here is refused")
        flags = m.group(1).split()
        i = 0
        while i < len(flags):
            if flags[i] in _ADDRESS_FLAGS and i + 1 < len(flags):
                i += 2
                continue
            raise Untranslatable(
                f"{source} line {number}: simple_switch_CLI flag {flags[i]!r} is not one of "
                f"{list(_ADDRESS_FLAGS)}; it changes what the CLI resolves names against, and "
                f"the translation resolves them against the package's p4info")
        command = (m.group(2) if m.group(2) is not None else m.group(3)).strip()
        if "$" in command or "`" in command:
            raise Untranslatable(
                f"{source} line {number}: {command!r} needs the shell to expand it ($ or `), "
                f"and this script is read, not run")
        out.append((number, command))
    return out


# --- the program's names ------------------------------------------------------------------------

class Schema:
    """Tables and actions of one p4info, with the CLI's way of finding them by name."""

    def __init__(self, tables, actions):
        #: {full name: {"fields": [(name, KIND, bitwidth)], "actions": [full names]}}
        self.tables = tables
        #: {full name: [(param name, bitwidth)]}
        self.actions = actions

    @staticmethod
    def _resolve(kind, token, names):
        if token in names:
            return token
        hits = sorted(n for n in names if n.endswith("." + token))
        if len(hits) == 1:
            return hits[0]
        if not hits:
            raise Untranslatable(f"{kind} {token!r} is not in the p4info (neither a full name "
                                 f"nor a dotted suffix of one)")
        raise Untranslatable(f"{kind} {token!r} is ambiguous: {hits} all end in it. The CLI "
                             f"refuses it too; write the longer name")

    def table(self, token):
        return self._resolve("table", token, self.tables)

    def action(self, token):
        return self._resolve("action", token, self.actions)


def schema_from_p4info(p4info):
    """A Schema out of a parsed p4info protobuf. Match kinds are read out of the enum by name
    (p4info.proto skips 1; preflight.match_type_name's note)."""
    from p4.config.v1 import p4info_pb2

    kind = p4info_pb2.MatchField.MatchType.Name
    action_names = {a.preamble.id: a.preamble.name for a in p4info.actions}
    actions = {a.preamble.name: [(p.name, p.bitwidth) for p in a.params] for a in p4info.actions}
    tables = {}
    for t in p4info.tables:
        tables[t.preamble.name] = {
            "fields": [(f.name, kind(f.match_type), f.bitwidth) for f in t.match_fields],
            "actions": [action_names.get(ref.id) for ref in t.action_refs],
        }
    return Schema(tables, actions)


def schema_from_p4info_path(path):
    from google.protobuf import text_format
    from p4.config.v1 import p4info_pb2

    pb = p4info_pb2.P4Info()
    with open(path, encoding="utf-8") as fh:
        text_format.Merge(fh.read(), pb, allow_unknown_field=True)
    return schema_from_p4info(pb)


# --- values ---------------------------------------------------------------------------------

def _parse(token, bitwidth, what):
    """(int value, JSON spelling) for one CLI value of a bit<bitwidth> field."""
    text = token.strip()
    if "." in text:
        if bitwidth != 32:
            raise Untranslatable(f"{what}: {text!r} is an IPv4 address and the field is "
                                 f"bit<{bitwidth}>")
        try:
            value = int.from_bytes(socket.inet_aton(text), "big")
        except OSError:
            raise Untranslatable(f"{what}: {text!r} is not an IPv4 address")
        if text.count(".") != 3:
            raise Untranslatable(f"{what}: {text!r} is not a dotted quad")
        return value, "ipv4"
    if ":" in text:
        groups = text.split(":")
        if bitwidth != 48 or len(groups) != 6 or any(len(g) != 2 for g in groups):
            raise Untranslatable(f"{what}: {text!r} is not a MAC for a bit<{bitwidth}> field")
        try:
            return int("".join(groups), 16), "mac"
        except ValueError:
            raise Untranslatable(f"{what}: {text!r} is not a MAC")
    try:
        value = int(text, 0)
    except ValueError:
        raise Untranslatable(f"{what}: {text!r} is neither an address, a MAC nor an integer")
    if value < 0:
        raise Untranslatable(f"{what}: {value} is negative; P4 fields are unsigned")
    return value, "int"


def _fits(value, bitwidth, what):
    if value >= (1 << bitwidth):
        raise Untranslatable(f"{what}: {value:#x} does not fit in bit<{bitwidth}>; the "
                             f"P4Runtime writer refuses it rather than truncate it")
    return value


def _spell(value, form):
    if form == "ipv4":
        return socket.inet_ntoa(value.to_bytes(4, "big"))
    if form == "mac":
        return ":".join(f"{b:02x}" for b in value.to_bytes(6, "big"))
    return value


def _key(field, token, where, notes):
    """(JSON match value, or None for "omit the field") for one key token of one field."""
    name, kind, width = field
    what = f"{where} {name}"
    if kind == "EXACT":
        value, form = _parse(token, width, what)
        return _spell(_fits(value, width, what), form)
    if kind == "LPM":
        if "/" not in token:
            raise Untranslatable(f"{what}: an lpm key is written value/prefix_len, got {token!r}")
        text, plen = token.rsplit("/", 1)
        value, form = _parse(text, width, what)
        _fits(value, width, what)
        try:
            plen = int(plen)
        except ValueError:
            raise Untranslatable(f"{what}: {plen!r} is not a prefix length")
        if not 0 <= plen <= width:
            raise Untranslatable(f"{what}: /{plen} is outside 0..{width}")
        host = (1 << (width - plen)) - 1
        if value & host:
            raise Untranslatable(
                f"{what}: {token} has bits set beyond its /{plen}. P4Runtime refuses that "
                f"(match_shape V9), and what the CLI's switch does with it was not measured, so "
                f"it is not masked here by assumption -- write the network address")
        if plen == 0:
            notes.append(f"{what}: {token} matches everything; omitted (P4Runtime spells "
                         f"\"don't care\" by leaving the field out, match_shape V5)")
            return None
        return [_spell(value, form), plen]
    if kind == "TERNARY":
        if "&&&" not in token:
            raise Untranslatable(f"{what}: a ternary key is written value&&&mask, got {token!r}")
        vtext, mtext = token.split("&&&", 1)
        value, form = _parse(vtext, width, what)
        mask, _mform = _parse(mtext, width, what + " mask")
        _fits(value, width, what)
        _fits(mask, width, what + " mask")
        if mask == 0:
            notes.append(f"{what}: {token} has a zero mask, i.e. don't care; omitted "
                         f"(P4Runtime refuses a zero mask, match_shape V5)")
            return None
        masked = value & mask
        if masked != value:
            notes.append(f"{what}: {token} -> {_spell(masked, form)} under mask {mask:#x}: "
                         f"value masked (the CLI's switch matches value & mask; P4Runtime "
                         f"refuses a value bit outside its mask, match_shape V3)")
        return [_spell(masked, form), mask]
    if kind == "RANGE":
        if "->" not in token:
            raise Untranslatable(f"{what}: a range key is written low->high, got {token!r}")
        ltext, htext = token.split("->", 1)
        low, lform = _parse(ltext, width, what)
        high, _hform = _parse(htext, width, what)
        _fits(low, width, what)
        _fits(high, width, what)
        if low > high:
            raise Untranslatable(f"{what}: {token} runs backwards")
        if low == 0 and high == (1 << width) - 1:
            notes.append(f"{what}: {token} is the whole range; omitted (match_shape V5)")
            return None
        return [_spell(low, lform), _spell(high, lform)]
    raise Untranslatable(f"{what}: match kind {kind} is not translated from the CLI")


# --- commands -------------------------------------------------------------------------------

def _params(action_name, params, tokens, where):
    if len(tokens) != len(params):
        raise Untranslatable(
            f"{where}: {action_name} takes {len(params)} parameter(s) "
            f"{[p for p, _w in params]}, the command gives {len(tokens)}")
    out = {}
    for (pname, width), token in zip(params, tokens):
        what = f"{where} parameter {pname}"
        value, form = _parse(token, width, what)
        out[pname] = _spell(_fits(value, width, what), form)
    return out


def _table_add(words, schema, where, notes):
    if "=>" not in words:
        raise Untranslatable(f"{where}: table_add needs `=>` between the keys and the "
                             f"action parameters")
    arrow = words.index("=>")
    head, tail = words[1:arrow], words[arrow + 1:]
    if len(head) < 2:
        raise Untranslatable(f"{where}: table_add <table> <action> <keys> => <params>")
    table = schema.table(head[0])
    spec = schema.tables[table]
    action = schema.action(head[1])
    if action not in spec["actions"]:
        raise Untranslatable(f"{where}: {table} does not take action {action}")
    keys = head[2:]
    fields = spec["fields"]
    if len(keys) != len(fields):
        raise Untranslatable(f"{where}: {table} has {len(fields)} key field(s) "
                             f"{[f[0] for f in fields]}, the command gives {len(keys)}")
    needs_priority = any(f[1] in PRIORITY_KINDS for f in fields)
    priority = None
    if needs_priority:
        if len(tail) != len(schema.actions[action]) + 1:
            raise Untranslatable(
                f"{where}: {table} has a ternary/range field, so the CLI takes a priority after "
                f"{action}'s {len(schema.actions[action])} parameter(s); the command gives "
                f"{len(tail)} value(s) after `=>`")
        try:
            priority = int(tail[-1])
        except ValueError:
            raise Untranslatable(f"{where}: priority {tail[-1]!r} is not an integer")
        if priority < 0:
            raise Untranslatable(f"{where}: priority {priority} is negative")
        tail = tail[:-1]
    match = {}
    for field, token in zip(fields, keys):
        value = _key(field, token, where, notes)
        if value is not None:
            match[field[0]] = value
    entry = {"table": table, "match": match, "action_name": action,
             "action_params": _params(action, schema.actions[action], tail, where)}
    return entry, priority


def _table_set_default(words, schema, where):
    if len(words) < 3:
        raise Untranslatable(f"{where}: table_set_default <table> <action> <params>")
    table = schema.table(words[1])
    action = schema.action(words[2])
    if action not in schema.tables[table]["actions"]:
        raise Untranslatable(f"{where}: {table} does not take action {action}")
    return {"table": table, "default_action": True, "action_name": action,
            "action_params": _params(action, schema.actions[action], words[3:], where)}


def translate(commands, schema):
    """([runtime entries], [notes]) for [(line number, command)], in command order.

    `notes` says every place the entry is not the command's literal spelling -- a masked
    value, an omitted don't-care field, a priority mapping -- so a converted package never
    differs from its app silently.
    """
    entries, notes, cli_priority = [], [], []
    for number, command in commands:
        words = command.split()
        where = f"line {number} ({' '.join(words[:2])})"
        if not words:
            continue
        verb = words[0]
        try:
            if verb == "table_add":
                entry, prio = _table_add(words, schema, where, notes)
            elif verb == "table_set_default":
                entry, prio = _table_set_default(words, schema, where), None
            else:
                raise Untranslatable(
                    f"line {number}: {verb!r} is not translated -- only "
                    f"{list(TRANSLATED_COMMANDS)} are; anything else would be a rule the app "
                    f"relies on and the package does not carry")
        except Untranslatable as exc:
            if str(exc).startswith(f"line {number}"):
                raise
            raise Untranslatable(f"{where}: {exc}") from exc
        entries.append(entry)
        cli_priority.append(prio)

    largest = {}
    for entry, prio in zip(entries, cli_priority):
        if prio is not None:
            largest[entry["table"]] = max(prio, largest.get(entry["table"], prio))
    for entry, prio in zip(entries, cli_priority):
        if prio is None:
            continue
        p4rt = largest[entry["table"]] + 1 - prio
        if not 1 <= p4rt <= PRIORITY_MAX:
            raise Untranslatable(f"{entry['table']}: priority {prio} maps to {p4rt}, outside "
                                 f"P4Runtime's 1..{PRIORITY_MAX}")
        entry["priority"] = p4rt
        notes.append(f"{entry['table']}: CLI priority {prio} -> P4Runtime priority {p4rt} "
                     f"(bmv2's CLI: lower wins; P4Runtime: higher wins; order kept within the "
                     f"table, largest CLI priority here {largest[entry['table']]})")
    return entries, notes
