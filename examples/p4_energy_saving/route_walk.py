"""Where a packet goes when it follows the forwarding tables, one switch at a time.

[Co-developed with claude code -- Adam]

Both energy-saving apps use it to check a plan before they write it: with the tables as they will
be after the rewrites, every host must still reach every other host, and no packet may pass the
switch that is about to be turned off. Rewriting only the entries that point straight at that
switch is not enough on every topology: a switch further back can keep sending packets towards
it, and the rewritten switch can send them back, so they loop. The walk finds that.

It is part of the example, not of the ndtwin SDK. Standard library only.
"""
import ipaddress


def prefix_len(match_value, ip):
    """How specifically a destination match holds `ip`: the prefix length of an lpm match
    (`[value, prefix_len]`), 32 for an exact match on that address, None when it does not hold it."""
    if isinstance(match_value, (list, tuple)):
        net = ipaddress.ip_network(f"{match_value[0]}/{match_value[1]}", strict=False)
        return net.prefixlen if ipaddress.ip_address(ip) in net else None
    return 32 if match_value == ip else None


def next_port(entries, dst_ip, field, port_param):
    """The egress port of the most specific entry whose `field` holds dst_ip, or None.

    An entry without `field` in its match is not followed, and the walk counts a packet that only
    such an entry would take as dropped. That covers the default entry (its match is empty), even
    one whose action forwards, and an lpm entry that matches any address (the API leaves the field
    out of its match). Both are conservative: a fabric that relies on either reads as broken, and
    the apps then turn nothing off."""
    best_len, best = -1, None
    for entry in entries:
        value = (entry.get("match") or {}).get(field)
        length = None if value is None else prefix_len(value, dst_ip)
        if length is not None and length > best_len:
            best_len, best = length, entry
    return None if best is None else (best.get("action_params") or {}).get(port_param)


def walk(tables, links, hosts, src, dst_ip, field, port_param):
    """(the switches a packet to dst_ip visits from switch `src`, whether it reaches the host).

    tables {dpid: entries}, links {dpid: {port: neighbour dpid}}, hosts {ip: (dpid, port)}.
    The walk stops, not delivered, at a switch it has already visited (a loop), at a switch with
    no table (one that is off), at a switch with no entry for dst_ip, and at a port that leads
    neither to the host nor to another switch.
    """
    here, seen = src, []
    while here not in seen:
        seen.append(here)
        if here not in tables:
            return seen, False
        port = next_port(tables[here], dst_ip, field, port_param)
        if port is None:
            return seen, False
        if hosts.get(dst_ip) == (here, port):
            return seen, True
        nxt = links.get(here, {}).get(port)
        if nxt is None:
            return seen, False
        here = nxt
    return seen + [here], False


def first_broken_route(tables, links, hosts, avoid, field, port_param):
    """None when every host reaches every other host over `tables` without passing switch
    `avoid`; otherwise the first pair that does not, as "10.0.1.1 -> 10.0.4.4: s1 s2 s1"."""
    for src_ip, (src, _port) in sorted(hosts.items()):
        for dst_ip in sorted(hosts):
            if dst_ip == src_ip:
                continue
            path, delivered = walk(tables, links, hosts, src, dst_ip, field, port_param)
            if not delivered or avoid in path:
                how = "passes" if delivered else "stops"
                return f"{src_ip} -> {dst_ip} {how}: " + " ".join(f"s{d}" for d in path)
    return None
