"""The thrift oracle: READ-ONLY simple_switch_CLI commands, and parsers for what they print.

[Co-developed with claude code -- Adam]

design 2.1 "oracle": `table_dump`, `show_tables`, `counter_read`, `register_read`,
`meter_get_rates`, `mc_dump`, `mirroring_get`, `show_ports` -- plus, for the Q3(b) cells,
`act_prof_dump` and `pvs_get`. Nothing here writes: `check_read_only` admits a command only
when its first word is one of READ_COMMANDS and it is a single line (a newline would hand the
CLI a second command on its stdin). The only thrift writes in tools/p4_health go to throwaway
switches the probe started itself (throwaway.py); a fabric switch is only ever read.

🔴 UNREADABLE IS None, AND IS NEVER "PRESENT". Every parser returns None for output it does not
recognise -- a switch that is not there ("Could not connect"), a name the switch does not have
("Error: Invalid ... name"), an empty reply. A reader that turned those into a match is exactly
what the same-window negative reads exist to catch (design 2.1), and a reader that turns them
into "absent" would hand the negative read a pass it did not earn -- so "absent" is a positive
statement that only a recognised reply can make (`mirroring_get`'s SESSION_NOT_FOUND, a dump
with no such entry, a `pvs_get` that printed its prompt and nothing else).

The output formats were captured from the stock simple_switch of this machine (bmv2 behind
p4c 1.2.5.15) on 2026-10-03; tests/python/fixtures/p4_health/thrift/ holds those captures.

Observed while capturing: `pvs_add` through simple_switch_CLI aborts the stock bmv2
(parser.cpp:535, `new_v.size() == width`), for 40055 and 0x9c97 alike. Read-only `pvs_get` on an
empty set did not. P4Runtime's ValueSetEntry write is refused instead (UNIMPLEMENTED, "ValueSet
writes are not supported yet") and the switch lives -- vs_trial.py, on throwaway switches.
"""
from __future__ import annotations

import re

READ_COMMANDS = ("table_dump", "table_dump_entry_from_key", "show_tables", "counter_read",
                 "register_read", "meter_get_rates", "mc_dump", "mirroring_get", "show_ports",
                 "act_prof_dump", "pvs_get")


class WriteRefused(ValueError):
    pass


def check_read_only(command):
    if "\n" in command or "\r" in command or ";" in command:
        raise WriteRefused("one command per call, no line breaks: %r" % (command,))
    words = command.split()
    word = words[0] if words else ""
    if word not in READ_COMMANDS:
        raise WriteRefused("not a read-only thrift command: %r" % (command,))
    return word


def body(out):
    """What the one command printed, without the CLI's banner and prompts; None when the CLI
    could not talk to the switch or the switch refused the name."""
    if out is None:
        return None
    if "RuntimeCmd: " not in out:          # "Could not connect ...": the CLI never got a prompt
        return None
    text = out.split("RuntimeCmd: ", 1)[1]
    if text.rstrip().endswith("RuntimeCmd:"):
        text = text.rstrip()[: -len("RuntimeCmd:")]
    text = text.strip("\n")
    if text.startswith("Error:") or "Invalid " in text.split("\n", 1)[0] and "SESSION_NOT_FOUND" not in text:
        return None
    return text


# --- table_dump -------------------------------------------------------------------------------

_KEY = re.compile(r"^\*\s+(\S+?)\s*:\s+(EXACT|LPM|TERNARY|RANGE|VALID)\s+(.*)$")


def _hex_params(text):
    text = text.strip()
    if not text:
        return []
    return [int(p.strip(), 16) for p in text.rstrip(",").split(",") if p.strip()]


def _action(line):
    """("HcIngress.ipv4_forward", "08000000ff01, 02") out of an `Action entry:` line; the
    parameter part is empty for an action with none (the line then ends in " -")."""
    m = re.match(r"^Action entry:\s*(\S+)\s*-?\s*(.*)$", line)
    return (m.group(1), m.group(2)) if m else (None, "")


def parse_table_dump(text):
    """{"entries": [...], "default": {...} or None}; None when this is not a table dump."""
    if text is None or "TABLE ENTRIES" not in text:
        return None
    entries, default, cur, section = [], None, None, "entries"
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("Dumping entry"):
            cur = {"handle": int(line.split()[-1], 16), "keys": [], "priority": None,
                   "action": None, "params": [], "member": None, "group": None, "life": None}
            entries.append(cur)
            section = "entries"
        elif line.startswith("Dumping default entry"):
            default = {"action": None, "params": []}
            cur, section = default, "default"
        elif line.startswith("MEMBERS") or line.startswith("GROUPS"):
            cur, section = None, "profile"
        elif cur is None or set(line) == {"*"} or set(line) == {"="}:
            continue
        elif line.startswith("*"):
            m = _KEY.match(line)
            if m is None:
                return None
            field, kind, value = m.group(1), m.group(2), m.group(3).strip()
            cur["keys"].append((field, kind, value))
        elif line.startswith("Priority:"):
            cur["priority"] = int(line.split(":", 1)[1])
        elif line.startswith("Action entry:"):
            name, params = _action(line)
            cur["action"] = name
            cur["params"] = _hex_params(params)
        elif line.startswith("Index:"):
            m = re.search(r"(member|group)\((\d+)\)", line)
            if m:
                cur[m.group(1)] = int(m.group(2))
        elif line.startswith("Life:"):
            m = re.search(r"(\d+)ms since hit, timeout is (\d+)ms", line)
            if m:
                cur["life"] = (int(m.group(1)), int(m.group(2)))
        elif line == "EMPTY" and section == "default":
            default["action"] = None
    return {"entries": entries, "default": default}


def key_value(kind, value):
    """A dumped key as a comparable tuple: EXACT (v,), LPM (v, prefix), TERNARY (v, mask),
    RANGE (lo, hi) -- all ints."""
    if kind == "LPM":
        v, prefix = value.split("/")
        return (int(v, 16), int(prefix))
    if kind == "TERNARY":
        v, mask = [x.strip() for x in value.split("&&&")]
        return (int(v, 16), int(mask, 16))
    if kind == "RANGE":
        lo, hi = [x.strip() for x in value.split("->")]
        return (int(lo, 16), int(hi, 16))
    return (int(value, 16),)


def normalize_entries(dump):
    """{(table-key tuple, action, params tuple, priority)} out of a parsed dump."""
    out = set()
    for e in (dump or {}).get("entries", []):
        keys = tuple((f, k, key_value(k, v)) for f, k, v in e["keys"])
        out.add((keys, e["action"], tuple(e["params"]), e["priority"]))
    return out


# --- the rest -----------------------------------------------------------------------------------

def parse_counter(text):
    """(bytes, packets) or None."""
    if text is None:
        return None
    m = re.search(r"\[\d+\]=\s*\((\d+) bytes, (\d+) packets\)", text)
    return (int(m.group(1)), int(m.group(2))) if m else None


def parse_register(text):
    if text is None:
        return None
    m = re.search(r"\[\d+\]=\s*(-?\d+)\s*$", text.strip())
    return int(m.group(1)) if m else None


def parse_mc_dump(text):
    """{mgid: frozenset(ports)}; None when this is not an mc_dump."""
    if text is None or "MC ENTRIES" not in text:
        return None
    groups, cur = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        m = re.match(r"^mgrp\((\d+)\)", line)
        if m:
            cur = int(m.group(1))
            groups.setdefault(cur, set())
            continue
        m = re.search(r"ports=\[([\d,\s]*)\]", line)
        if m and cur is not None:
            groups[cur] |= {int(p) for p in m.group(1).split(",") if p.strip()}
        if line.startswith("LAGS"):
            break
    return {g: frozenset(p) for g, p in groups.items()}


def parse_mirroring(text):
    """{"present": True, "port": .., "mgid": ..} | {"present": False} | None (unreadable)."""
    if text is None:
        return None
    if "SESSION_NOT_FOUND" in text:
        return {"present": False}
    m = re.search(r"MirroringSessionConfig\(port=(\w+), mgid=(\w+)\)", text)
    if not m:
        return None
    conv = lambda s: None if s == "None" else int(s)  # noqa: E731
    return {"present": True, "port": conv(m.group(1)), "mgid": conv(m.group(2))}


def parse_meter_rates(text):
    """[(rate, burst), ...]; [] for a meter nobody configured; None when unreadable."""
    if text is None:
        return None
    if "but only received 0" in text:
        return []
    rates = re.findall(r"info rate = ([0-9.eE+-]+), burst size = (\d+)", text)
    if not rates:
        return None
    return [(float(r), int(b)) for r, b in rates]


def parse_act_prof(text):
    """{"members": {id: (action, params)}, "groups": {id: [member ids]}}; None if unreadable."""
    if text is None or "MEMBERS" not in text:
        return None
    members, groups, cur_m, cur_g = {}, {}, None, None
    for raw in text.splitlines():
        line = raw.strip()
        m = re.match(r"^Dumping member (\d+)", line)
        if m:
            cur_m, cur_g = int(m.group(1)), None
            continue
        m = re.match(r"^Dumping group (\d+)", line)
        if m:
            cur_g, cur_m = int(m.group(1)), None
            continue
        if line.startswith("Action entry:") and cur_m is not None:
            name, params = _action(line)
            members[cur_m] = (name, tuple(_hex_params(params)))
        m = re.match(r"^Members: \[([\d,\s]*)\]", line)
        if m and cur_g is not None:
            groups[cur_g] = [int(x) for x in m.group(1).split(",") if x.strip()]
    return {"members": members, "groups": groups}


def parse_pvs(text):
    """The set of values in a parser value set (ints); None when unreadable."""
    if text is None:
        return None
    values = set()
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if not re.match(r"^(0x)?[0-9a-fA-F]+$", line):
            return None
        values.add(int(line, 16))
    return values


def parse_show_tables(text):
    """{table name: (implementation or None, match-key text)}; None when unreadable/empty."""
    if text is None:
        return None
    out = {}
    for line in text.splitlines():
        m = re.match(r"^(\S+)\s+\[implementation=(\S+?), mk=(.*)\]\s*$", line.strip())
        if m:
            out[m.group(1)] = (None if m.group(2) == "None" else m.group(2), m.group(3))
    return out or None


def parse_show_ports(text):
    """{port: iface}; None when unreadable/empty."""
    if text is None:
        return None
    out = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(\d+)\s+(\S+)\s+(UP|DOWN)\b", line)
        if m:
            out[int(m.group(1))] = m.group(2)
    return out or None


PARSERS = {"table_dump": parse_table_dump, "table_dump_entry_from_key": parse_table_dump,
           "show_tables": parse_show_tables, "counter_read": parse_counter,
           "register_read": parse_register, "meter_get_rates": parse_meter_rates,
           "mc_dump": parse_mc_dump, "mirroring_get": parse_mirroring,
           "show_ports": parse_show_ports, "act_prof_dump": parse_act_prof, "pvs_get": parse_pvs}


class ThriftReader(object):
    """One read-only command against one fabric switch, through the injected Runner."""

    def __init__(self, cfg, runner):
        self.cfg = cfg
        self.runner = runner

    def raw(self, dpid, command):
        check_read_only(command)
        argv = self.cfg.thrift_cli + ["--thrift-port", str(self.cfg.thrift_port(dpid))]
        res = self.runner.run(argv, input_text=command + "\n", timeout=30)
        return res.stdout if res.rc == 0 else None

    def read(self, dpid, command):
        word = check_read_only(command)
        out = self.raw(dpid, command)
        text = body(out)
        if word == "table_dump_entry_from_key" and text is not None and "TABLE ENTRIES" not in text:
            text = "TABLE ENTRIES\n" + text
        return PARSERS[word](text)
