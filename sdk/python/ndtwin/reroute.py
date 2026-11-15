"""Moving the routes of one forwarding table off a switch: which entries change, to which port,
and a check that every host still reaches every other host afterwards.

[Co-developed with claude code -- Adam]

`Kernel.plan_routes_off` and `Kernel.move_routes_off` call `plan`, which reads nothing and writes
nothing: it works on a `Topology` and the tables already read. Standard library only.
"""
import ipaddress
from collections import deque

from .errors import NoDetour


class RoutePlan(list):
    """The entries to send as modifies, in order (a list, so `p4.modify_all(plan)` takes it).

    `old` holds each of them as it was read, in the same order: `p4.modify_all(plan.old)` moves
    the routes back. `dpid` is the switch the routes were moved off, `table` the table."""

    def __init__(self, entries=(), old=(), dpid=None, table=None):
        super().__init__(entries)
        self.old, self.dpid, self.table = list(old), dpid, table


def _destination(value):
    """(network as an integer, prefix length) of a destination match: `[address, prefix_len]`
    (lpm), an address (exact) or `[address]`. ValueError for anything else."""
    if isinstance(value, (list, tuple)) and len(value) == 1:
        value = value[0]
    if isinstance(value, (list, tuple)) and len(value) == 2:
        net = ipaddress.IPv4Network(f"{value[0]}/{value[1]}", strict=False)
    elif isinstance(value, str):
        net = ipaddress.IPv4Network(value.strip())
    else:
        raise ValueError(f"not an IPv4 address or prefix: {value!r}")
    return int(net.network_address), net.prefixlen


def _holds(dest, ip_int):
    net, plen = dest
    return (ip_int >> (32 - plen)) == (net >> (32 - plen)) if plen else True


class _Route:
    """One entry of a table as the check follows it."""

    def __init__(self, entry, dest, port):
        self.entry, self.dest, self.port, self.moved, self.old = entry, dest, port, False, None


def _next(routes, ip_int):
    """The most specific route whose destination holds the address, or None."""
    best = None
    for route in routes:
        if route.dest is not None and _holds(route.dest, ip_int) and (
                best is None or route.dest[1] > best.dest[1]):
            best = route
    return best


def _follow(tables, links, hosts, src, ip, avoid, blind=()):
    """(hops, what happened, whether it ended where the check cannot follow) for a packet to `ip`
    entering switch `src`. `hops` lists (dpid, egress port or None, whether that entry is a moved
    one), and ends with the switch a loop comes back to, or `avoid`, as (dpid, None, False).

    What happened: "delivered", "loop", "are dropped" (no route, a route without a port, a port
    that leads to no switch and no host), or "reach s<avoid>". The last value is True when the
    packet found no route it follows at a switch in `blind`: one whose table forwards through a
    default entry whose action has parameters, or an entry that matches every address, which the
    check does not follow."""
    ip_int, here, hops, seen = int(ipaddress.IPv4Address(ip)), src, [], set()
    while True:
        if here == avoid:
            return hops + [(here, None, False)], f"reach s{avoid}", False
        if here in seen:
            return hops + [(here, None, False)], "loop", False
        seen.add(here)
        route = _next(tables.get(here, ()), ip_int)
        if route is None or route.port is None:
            return hops + [(here, None, False)], "are dropped", route is None and here in blind
        hops.append((here, route.port, route.moved))
        if hosts.get(ip) == (here, route.port):
            return hops, "delivered", False
        here = links.get(here, {}).get(route.port)
        if here is None:
            return hops, "are dropped", False


def _describe(hops):
    return " -> ".join(f"s{d}" + ("" if p is None else f" port {p}") + (" (moved)" if m else "")
                       for d, p, m in hops)


def _distances(links, target, blocked):
    """{dpid: hops to switch `target`} over `links`, never through a switch in `blocked`."""
    dist, queue = {target: 0}, deque([target])
    while queue:
        here = queue.popleft()
        for dpid in sorted(links):
            if dpid in dist or dpid in blocked:
                continue
            if here in links[dpid].values():
                dist[dpid] = dist[here] + 1
                queue.append(dpid)
    return dist


def refusal(table, avoid, why, dpid=None, entry=None, switches=None):
    """The NoDetour for `why`, naming the entry of switch `dpid` when there is one."""
    where = "" if entry is None else f"s{dpid} {entry.get('match')}: "
    err = NoDetour(f"cannot move the routes of {table} off s{avoid}: {where}{why}")
    err.entry, err.switches = entry, switches
    return err


OFF = ("it is off or unreachable: neighbours() leaves out every link to a switch that is not "
       "usable, so which entries lead to it cannot be told")


def plan(topo, tables, avoid, table, port_param="port", mac_param=None,
         match_field="hdr.ipv4.dstAddr"):
    """The `RoutePlan` that moves every route of `tables` leaving towards switch `avoid` onto
    another way, or NoDetour. `tables` {dpid: Table} holds the table of every usable switch but
    `avoid`. See `Kernel.plan_routes_off` for the rules."""
    links = {d: topo.neighbours(d) for d, sw in topo.switches.items() if sw.usable}
    hosts = {h.ip: (h.switch, h.port) for h in topo.attached_hosts.values() if h.switch in links}

    def refuse(why, dpid=None, entry=None, switches=None):
        return refusal(table, avoid, why, dpid, entry, switches)

    if avoid not in links:
        raise refuse(OFF)
    routes, moving, blind = {}, [], set()
    for dpid in sorted(tables):
        tbl = tables[dpid]
        default = (tbl.default.params or {}) if tbl.default is not None else {}
        if topo.neighbour(dpid, default.get(port_param)) == avoid:
            raise refuse(f"its default entry sends packets to s{avoid}", dpid, tbl.default)
        if default:  # it forwards through a port, or through a parameter the check cannot read
            blind.add(dpid)
        routes[dpid] = []
        for entry in tbl.entries:
            params = entry.params or {}
            if entry.priority not in (None, 0):
                raise refuse(f"the entry has priority {entry.priority}: the check follows the "
                             f"longest prefix, not priorities", dpid, entry)
            extra = sorted(set(entry.match or {}) - {match_field})
            if extra:
                raise refuse(f"its match also has {', '.join(extra)}, not only {match_field}: the "
                             f"check follows the {match_field} match alone, so it cannot tell "
                             f"which entry the switch applies", dpid, entry)
            if params and port_param not in params:
                raise refuse(f"its action {entry.get('action_name')} has no parameter "
                             f"{port_param!r}, so where it sends packets is not known", dpid, entry)
            if mac_param and params and mac_param not in params:
                raise refuse(f"its action {entry.get('action_name')} has no parameter "
                             f"{mac_param!r} to take the next hop's MAC address from", dpid, entry)
            value = (entry.match or {}).get(match_field)
            try:
                dest = None if value is None else _destination(value)
            except ValueError:
                raise refuse(f"its {match_field} match {value!r} is not an IPv4 address or prefix",
                             dpid, entry) from None
            route = _Route(entry, dest, params.get(port_param))
            routes[dpid].append(route)
            if dest is None and route.port is not None:
                blind.add(dpid)
            if topo.neighbour(dpid, route.port) == avoid:
                moving.append((dpid, route))
    reach = {}
    for dpid, route in moving:
        entry = route.entry
        if route.dest is None:
            raise refuse(f"its match has no {match_field}, so it matches every address and where "
                         f"its packets go is not known", dpid, entry)
        ips = sorted(ip for ip in hosts if _holds(route.dest, int(ipaddress.IPv4Address(ip))))
        if not ips:
            raise refuse("no host the topology knows is in its destination", dpid, entry)
        for ip in ips:
            if hosts[ip][0] in (avoid, dpid):
                raise refuse(f"{ip} hangs off s{hosts[ip][0]} itself", dpid, entry)
        targets = sorted({hosts[ip][0] for ip in ips})
        for target in targets:
            if (dpid, target) not in reach:
                reach[dpid, target] = _distances(links, target, {avoid, dpid})
        ways = []
        for p, nbr in sorted(links[dpid].items()):
            dist = [reach[dpid, t].get(nbr) for t in targets]
            if nbr != avoid and None not in dist:
                ways.append((sum(dist), p))
        if not ways:
            raise refuse(f"no neighbour but s{avoid} reaches "
                         f"{', '.join(f's{t}' for t in targets)} without passing s{avoid} or "
                         f"coming back through s{dpid}", dpid, entry)
        new = {port_param: min(ways)[1]}
        if mac_param:
            donors = {r.entry.params.get(mac_param) for r in routes[dpid]
                      if not r.moved and r.port == new[port_param]}
            if len(donors) != 1:
                raise refuse(f"{'no entry' if not donors else 'entries that disagree'} of "
                             f"s{dpid} leaving on port {new[port_param]} to take {mac_param} from",
                             dpid, entry)
            new[mac_param] = donors.pop()
        route.entry, route.moved, route.port = (entry.with_params(**new), True,
                                                new[port_param])
        route.old = entry
    sources = sorted({sw for sw, _ in hosts.values()} - {avoid})
    for ip in sorted(ip for ip in hosts if hosts[ip][0] != avoid):
        for src in sources:
            hops, what, unseen = _follow(routes, links, hosts, src, ip, avoid, blind)
            if what == "delivered":
                continue
            # The tables differ only in the moved entries, so a way that takes none of them was
            # the same before the moves. A packet that meets a default entry or an entry that
            # matches every address is not followed, so nothing is known about it.
            note = ""
            if unseen:
                note = (f"; s{hops[-1][0]} forwards through a default entry or an entry that "
                        f"matches every address: not followed, so it is not known whether "
                        f"these packets are delivered")
            elif not any(moved for _, _, moved in hops):
                note = "; no moved entry is on that way, so it is broken already"
            raise refuse(f"after the moves, packets for {ip} entering s{src} {what}: "
                         f"{_describe(hops)}{note}", switches=[d for d, _, _ in hops])
    moved = [r for _, r in moving]
    return RoutePlan([r.entry for r in moved], [r.old for r in moved], avoid, table)
