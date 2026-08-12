"""
Renders the proxy's topology in the shape Ryu's REST API returns.

[Co-developed with claude code -- Adam]

The kernel learns switch, host and link state by polling Ryu's `/v1.0/topology/*` endpoints and
parsing them in `TopologyAndFlowMonitor::updateSwitches` / `updateHosts` / `updateLinks`. Serving
the same shapes from the proxy means those three functions work unchanged in P4 mode -- the same
approach already used for sFlow, where the proxy synthesises what the kernel already knows how to
read rather than adding a second ingest path. Nothing in the kernel needs to change, so the OVS
path carries no risk from this.

**Why this is needed at all.** `/ndt/inform_switch_entered` was expected to be sufficient, but it
only enables the switch *vertex*. Measured on a live kernel: after notifying all ten switches,
`is_enabled` went 0/10 -> 10/10 for switches but stayed **0/40 for edges**, and
`get_path_switch_count` still answered "Path not found" -- because BFS needs enabled *edges*, and
edges are enabled by `updateLinks()`, which only runs off this poll.

**Encoding.** dpid and port_no are **hex strings**, because the kernel parses them with
`stoull(s, nullptr, 16)` and `portStringToUint` (also base 16). Emitting decimal here would make
dpid 10 read as 16 -- silently, since the parse succeeds.
"""

from __future__ import annotations

from typing import Any, Optional

# Widths Ryu uses. Not load-bearing for the kernel's base-16 parse, but matching them keeps the
# payloads diffable against a real Ryu capture.
DPID_HEX_WIDTH = 16
PORT_HEX_WIDTH = 8


def _dpid_hex(dpid: int) -> str:
    return f"{int(dpid):0{DPID_HEX_WIDTH}x}"


def _port_hex(port: int) -> str:
    return f"{int(port):0{PORT_HEX_WIDTH}x}"


def _mac_str(mac: Any) -> Optional[str]:
    """
    A MAC as the colon-separated string the kernel requires.

    [Co-developed with claude code -- Adam]
    Normalising rather than passing through, because the kernel calls
    `utils::macToUint64(host["mac"])` and nlohmann throws `json::type_error` on a number. That
    exception is not a `parse_error`, so it used to escape `updateHosts` and abort the whole
    kernel -- observed: feeding it `"mac": 1` killed the process. The kernel now logs and skips
    instead, but emitting the right type is this side's job. The shipped topology files store
    MACs as integers, so this is a real case, not a hypothetical one.
    """
    if mac is None:
        return None
    if isinstance(mac, str):
        return mac
    if isinstance(mac, int):
        h = f"{mac:012x}"
        return ":".join(h[i:i + 2] for i in range(0, 12, 2))
    return str(mac)


def _port_endpoint(dpid: int, port: int, mac: Optional[str] = None) -> dict:
    """One `{"dpid":..., "port_no":..., ...}` object, as Ryu nests inside links and hosts."""
    out: dict[str, Any] = {
        "dpid": _dpid_hex(dpid),
        "port_no": _port_hex(port),
        "name": f"s{dpid}-eth{port}",
    }
    if mac is not None:
        out["hw_addr"] = mac
    return out


def render_switches(switch_dpids) -> list:
    """
    The switches the proxy holds a P4Runtime session with.

    Only connected switches are listed, which makes this an honest liveness signal rather than a
    restatement of the topology file: a switch the proxy cannot reach does not appear, so the
    kernel does not mark it enabled.
    """
    return [{"dpid": _dpid_hex(d), "ports": []} for d in sorted(switch_dpids)]


def render_links(net, down_endpoints=()) -> list:
    """
    Inter-switch links, both directions, as Ryu reports them.

    Ryu emits one entry per direction, and the kernel's `updateLinks` enables the edge keyed on
    (src dpid, src port) -- so both directions must be present or half the edges stay disabled.

    Host links are excluded: Ryu reports those through `/v1.0/topology/hosts`, and including them
    here would have the kernel look for a switch vertex whose dpid is a host IP.

    `down_endpoints` is the set of `(dpid, port)` the beacon watchdog believes is down; those
    directions are left out. [Co-developed with claude code -- Adam]

    Omitting them is load-bearing, not tidiness. `updateLinks` only ever sets isUp/isEnabled to
    true, so a link that stayed in this list would be re-enabled by the next topology poll,
    silently undoing the watchdog's report. There is no way to say "down" in this reply, so the
    only way to stop the poll contradicting the failure is to stop mentioning the link.
    See TopologyManager.down_link_endpoints.

    The poll runs every 5 s for the kernel process's first 90 s and every 30 s after that
    (kWhileConverging / kOnceConverged / kConvergingFor in TopologyAndFlowMonitor.cpp's run()).
    This used to say "once a second ... within a second", which was a misreading of the 1 s sleep
    slice inside that loop; the slice is there so stop() returns promptly, not because the poll
    is 1 Hz.
    """
    links = []
    down = set(down_endpoints)
    for src, dst, data in net.edges(data=True):
        if net.nodes.get(src, {}).get("type") != "switch":
            continue
        if net.nodes.get(dst, {}).get("type") != "switch":
            continue
        src_port = data.get("port", 0)
        if (src, src_port) in down:
            continue
        # The reverse edge carries the far end's port number; add_link() stores them that way.
        dst_port = net.get_edge_data(dst, src, default={}).get("port", 0)
        links.append({
            "src": _port_endpoint(src, src_port),
            "dst": _port_endpoint(dst, dst_port),
        })
    return links


def down_edges(net, down_endpoints) -> list:
    """
    The `(u, v)` edges whose source endpoint the watchdog believes is down.

    [Co-developed with claude code -- Adam]
    `down_endpoints` is keyed `(dpid, port)`, which is enough to identify the edge because a
    physical port carries either an inter-switch link or a host link, never both -- so a host edge
    can never be caught by a switch port number that failed.
    """
    down = set(down_endpoints)
    if not down:
        return []
    return [(u, v) for u, v, data in net.edges(data=True)
            if (u, data.get("port", 0)) in down]


def installed_path(net, installed, src_host, dst_host, down_endpoints=()):
    """
    The hops a packet really takes, by following the rules written to the switches.

    [Co-developed with claude code -- Adam]
    Returns None when no such path exists: no rule at some switch, a rule pointing out a port
    whose link is down, a port with no link behind it, or a loop.

    This walks `installed` -- (dpid, dst_ip) -> out_port, what the switches were actually told --
    rather than searching `net`. The difference only shows up after a link fails: the search finds
    a new shortest path around the break, the switches have never been told about it, and the
    packets keep going into the dead link. Measured on 2026-08-10: ping stopped dead while every
    endpoint went on advertising a route.

    Bounded by the node count, so a rule set that points in a circle terminates rather than
    hanging the reply thread.
    """
    down = set(down_endpoints)
    first_hops = [v for v in net.neighbors(src_host)]
    if not first_hops:
        return None

    hops = [src_host]
    current = first_hops[0]
    for _ in range(net.number_of_nodes() + 1):
        hops.append(current)
        if current == dst_host:
            return hops
        out_port = installed.get((current, dst_host))
        if out_port is None:
            return None  # this switch has no rule for that destination
        if (current, out_port) in down:
            return None  # the rule points out of a port whose link has failed
        nxt = None
        for neighbour in net.neighbors(current):
            if net.get_edge_data(current, neighbour, default={}).get("port") == out_port:
                nxt = neighbour
                break
        if nxt is None or nxt in hops:
            return None  # port with nothing behind it, or a loop
        current = nxt
    return None


def render_destination_paths(net, down_endpoints=(), installed=None) -> dict:
    """
    Every host-to-host path, in the shape `FlowLinkUsageCollector::setAllPaths` consumes.

    [Co-developed with claude code -- Adam]

    `down_endpoints` is excluded before the search, for the same reason `render_links` withholds
    them, and it is the more consequential of the two: this reply fills `m_switchCountMap`, so a
    path computed over a dead link makes `/ndt/get_path_switch_count` answer with a route the
    traffic cannot take. Withholding the link from `/v1.0/topology/links` alone does not help
    here -- `fetchAllDestinationPaths` reads *this* endpoint, and it never consults the graph the
    poll built.

    Format taken from `intelligent_router.py`, which is the working reference -- OVS mode really
    does answer `switch_count: 5` off this, so the shape is known-good rather than inferred:

        {"status": "success",
         "all_destination_paths": [
             [["10.0.0.1", 3], [1, 1], [6, 2], [4, 3], ["10.0.0.4", 0]],
             ...
         ]}

    Each entry is one path as `[node, out_port]` pairs, where `out_port` is the port on that node
    *towards the next hop*. Three details are load-bearing:

      - The first and last nodes must be **host IPs as strings**, and everything between them a
        **switch dpid as a number**. The kernel discriminates on the JSON type: a string goes
        through `ipStringToUint32`, a number through `get<uint64_t>()`.
      - `switchCount` is computed as `path.size() - 2`, so the host endpoints must be present or
        every count is off by two.
      - The final hop's port is 0, since there is no next hop to leave by.

    The `{"status": "success", ...}` envelope is required: the kernel refuses the body outright
    if `status` is missing or not "success".

    `installed` -- (dpid, dst_ip) -> out_port, the rules actually written to the switches -- makes
    this report where packets really go instead of where the graph says they could go. **An empty
    or absent map means "we do not know what is installed", and the shortest-path search is used.**
    That asymmetry is deliberate and is a judgement call worth knowing about:

      - Knowing the rules and ignoring them is what produced the 2026-08-10 defect: a link broke,
        the search found a detour no switch had been told about, all twelve paths stayed
        advertised, and 38% of the packets were dropped while every endpoint read healthy.
      - Treating "no record" as "nothing installed" would introduce the opposite fault. bmv2 keeps
        its table entries across a proxy restart, so a restarted proxy has an empty record and a
        fully working fabric; withdrawing every path there would be just as wrong, and the kernel
        refuses an empty snapshot anyway, so it would sit on stale data with no signal.

    So: silence about the rules falls back to the old behaviour, and knowledge overrides it.
    """
    hosts = [n for n, a in net.nodes(data=True) if a.get("type") == "host"]

    # A view, not a copy: the search must not see the failed links, but nothing here may mutate
    # the graph the LLDP thread owns. Port lookups below still read `net`, since removing an edge
    # from the search does not change the port numbers of the edges that remain.
    search = net
    drop = down_edges(net, down_endpoints)
    if drop:
        try:
            import networkx as nx
            search = nx.restricted_view(net, [], drop)
        except Exception:
            # Better to answer with paths that ignore the failure than to answer with none:
            # setAllPaths refuses an empty snapshot outright, so returning nothing here would
            # leave the kernel on its previous -- equally stale -- data with no signal either way.
            search = net

    paths = []
    for src in hosts:
        for dst in hosts:
            if src == dst:
                continue
            if installed:
                # [Co-developed with claude code -- Adam]
                # Report where packets actually go, not where they would go if the switches had
                # been reprogrammed. A pair with no working installed route is omitted -- the twin
                # saying "unreachable" is correct, and is the whole point: it used to keep
                # advertising all twelve paths while a third of the packets were being dropped.
                hops = installed_path(net, installed, src, dst, down_endpoints)
            else:
                hops = _shortest_path(search, src, dst)
            if hops is None:
                continue
            entry = []
            for i, node in enumerate(hops):
                if i == 0:
                    # The source entry carries the *ingress* port -- the port on the first
                    # switch that the host hangs off -- not an egress port like every other
                    # hop. Asymmetric, but it is what intelligent_router.py emits
                    # (`net[src_switch][src_host]["port"]`), and matching the working
                    # reference beats inventing a tidier convention the kernel has never seen.
                    port = (net.get_edge_data(hops[1], node, default={}).get("port", 0)
                            if len(hops) > 1 else 0)
                elif i + 1 < len(hops):
                    port = net.get_edge_data(node, hops[i + 1], default={}).get("port", 0)
                else:
                    # No next hop to leave by.
                    port = 0
                # str for hosts, int for switches: the kernel discriminates on the JSON type.
                entry.append([str(node) if node in (src, dst) else int(node), port])
            paths.append(entry)

    return {"status": "success", "all_destination_paths": paths}


def _shortest_path(net, src, dst):
    """Shortest path as a node list, or None when the two are not connected."""
    try:
        import networkx as nx
        return nx.shortest_path(net, source=src, target=dst)
    except Exception:
        # NetworkXNoPath, NodeNotFound, or networkx missing. A pair with no route is normal
        # while discovery is still converging, so it is skipped rather than raised.
        return None


def render_hosts(net) -> list:
    """
    Hosts, keyed the way `updateHosts` reads them.

    It requires a non-empty `ipv4` list and then matches the vertex by MAC, so both must be
    present. `port.dpid` identifies the attachment switch.
    """
    hosts = []
    for node, attrs in net.nodes(data=True):
        if attrs.get("type") != "host":
            continue
        mac = _mac_str(attrs.get("mac"))
        if not mac:
            # Without a MAC the kernel cannot match the vertex, so the entry would be inert.
            continue

        dpid, port = None, 0
        for neighbour in net.predecessors(node) if hasattr(net, "predecessors") else []:
            if net.nodes.get(neighbour, {}).get("type") == "switch":
                dpid = neighbour
                port = net.get_edge_data(neighbour, node, default={}).get("port", 0)
                break
        if dpid is None:
            continue

        hosts.append({
            "mac": mac,
            "ipv4": [str(node)],
            "ipv6": [],
            "port": _port_endpoint(dpid, port, mac=mac),
        })
    return hosts
