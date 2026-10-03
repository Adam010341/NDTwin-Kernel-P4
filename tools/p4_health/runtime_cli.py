"""A tutorials runtime JSON, as simple_switch_CLI commands for a throwaway switch.

[Co-developed with claude code -- Adam]

Used ONLY by S0's offline self-checks, to give a throwaway bmv2 (throwaway.py) the same entries,
groups and clone session a bring-up would. The lab never sees these commands: on a fabric the
entries go in through the proxy's P4Runtime writer, and the probe never writes through thrift to
a fabric switch (design 7.1).
Exact and lpm, default actions, multicast groups and clone sessions -- the kinds the package
format carries; anything else is refused rather than translated by guess.
"""
from __future__ import annotations


class Untranslatable(ValueError):
    pass


def _value(v):
    if isinstance(v, bool):
        raise Untranslatable("boolean match value %r" % (v,))
    return str(v)


def _match_args(entry, key_order):
    match = entry.get("match") or {}
    args = []
    for name in key_order:
        if name not in match:
            raise Untranslatable("entry for %s does not set key %s" % (entry.get("table"), name))
        v = match[name]
        if isinstance(v, (list, tuple)):
            if len(v) != 2:
                raise Untranslatable("match %s=%r is neither exact nor [value, prefix]" % (name, v))
            args.append("%s/%d" % (v[0], int(v[1])))
        else:
            args.append(_value(v))
    if set(match) - set(key_order):
        raise Untranslatable("entry names keys %s the table does not have"
                             % sorted(set(match) - set(key_order)))
    return args


def commands(runtime, key_orders, param_orders):
    """CLI lines for one switch. `key_orders` {table: [key field names in p4info order]},
    `param_orders` {action: [param names in p4info order]} -- both read from the p4info."""
    lines = []
    for entry in runtime.get("table_entries") or []:
        table, action = entry["table"], entry["action_name"]
        params = entry.get("action_params") or {}
        order = param_orders.get(action, sorted(params))
        pargs = [_value(params[p]) for p in order]
        if entry.get("default_action"):
            lines.append(" ".join(["table_set_default", table, action] + pargs))
            continue
        if "priority" in entry:
            raise Untranslatable("priority entries are not in the package format (G5)")
        margs = _match_args(entry, key_orders[table])
        lines.append(" ".join(["table_add", table, action] + margs + ["=>"] + pargs))
    handle = 0
    for group in runtime.get("multicast_group_entries") or []:
        gid = int(group["multicast_group_id"])
        ports = [str(r["egress_port"]) for r in group.get("replicas") or []]
        lines.append("mc_mgrp_create %d" % gid)
        lines.append("mc_node_create %d %s" % (gid, " ".join(ports)))
        lines.append("mc_node_associate %d %d" % (gid, handle))
        handle += 1
    for sess in runtime.get("clone_session_entries") or []:
        sid = int(sess.get("clone_session_id", sess.get("session_id")))
        replicas = sess.get("replicas") or []
        if len(replicas) != 1:
            raise Untranslatable("clone session %d has %d replicas; the CLI's mirroring_add "
                                 "takes one port" % (sid, len(replicas)))
        lines.append("mirroring_add %d %d" % (sid, int(replicas[0]["egress_port"])))
    return lines


def p4info_orders(p4info_text):
    """({table: [key names]}, {action: [param names]}) out of a p4info in text format, read by a
    tiny line parser so S0 does not need protobuf in the interpreter that runs it."""
    keys, params = {}, {}
    section, name, stack = None, None, []
    for raw in p4info_text.splitlines():
        line = raw.strip()
        if line.endswith("{"):
            word = line[:-1].strip()
            stack.append(word)
            if len(stack) == 1 and word in ("tables", "actions"):
                section, name = word, None
            continue
        if line == "}":
            if stack:
                stack.pop()
            if not stack:
                section, name = None, None
            continue
        if not line.startswith("name:"):
            continue
        value = line.split(":", 1)[1].strip().strip('"')
        if section and stack[-1:] == ["preamble"] and len(stack) == 2:
            name = value
            (keys if section == "tables" else params)[name] = []
        elif section == "tables" and stack[-1:] == ["match_fields"] and name:
            keys[name].append(value)
        elif section == "actions" and stack[-1:] == ["params"] and name:
            params[name].append(value)
    return keys, params
