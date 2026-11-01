"""The kernel's topology (GET /ndt/get_graph_data, doc/2026-01-02_ndt_api.md §3) as plain objects.

[Co-developed with claude code -- Adam]
"""
import ipaddress
import socket
from dataclasses import dataclass, field


def ip_str(n):
    """A dotted IPv4 address from the kernel's integer form.

    The kernel serialises an address as `in_addr.s_addr`, the four bytes in network order read as
    a little-endian integer: 192653504 is 192.168.123.11.
    """
    return socket.inet_ntoa(int(n).to_bytes(4, "little"))


def mac_str(n):
    """A MAC address from the kernel's integer form (the six bytes, most significant first)."""
    return ":".join(f"{(int(n) >> shift) & 0xFF:02x}" for shift in range(40, -8, -8))


@dataclass(frozen=True)
class Switch:
    dpid: int
    name: str
    mgmt_ip: str          # the address the power API takes; "" when the switch has none
    admin_state: str      # "on" / "off": what the twin commanded
    reachable: bool       # whether the twin can reach it now
    capabilities: dict = field(default=None, compare=False)
    power_path: str = None
    brand: str = ""       # brand_name: "BMv2" for a P4 switch (§38)

    @property
    def usable(self):
        """On and reachable."""
        return self.admin_state == "on" and bool(self.reachable)


@dataclass(frozen=True)
class Host:
    name: str
    ip: str
    mac: str
    switch: int           # the switch the host hangs off
    port: int             # that switch's port towards the host


@dataclass(frozen=True)
class Link:
    """One direction of a link, as the kernel stores it. A host end has dpid 0."""

    src: int
    src_port: int
    dst: int
    dst_port: int
    up: bool
    utilization_percent: float    # 0..100 (the average of §24 is a 0..1 fraction)
    usage_bps: int
    bandwidth_bps: int
    telemetry_status: str
    flows: list = field(default=None, compare=False)


class Topology:
    """Switches, hosts and links. "Usable" means a switch that is on and reachable.

    `hosts` holds the hosts that hang off a usable switch through a link that is up.
    `attached_hosts` holds every host with a link to a switch, whether that link is up and that
    switch usable or not: a route check that must still hold when such a link comes back walks
    these. `edge_switches` holds every switch with a link to a host, up or down: a host behind a
    link that is down for a moment still needs its switch.
    `neighbours` and `busiest` count only links that are up between usable switches
    (or between a usable switch and a host).
    """

    def __init__(self, switches, hosts, links, attached_hosts=None):
        self.switches = dict(sorted(switches.items()))
        self.hosts = dict(hosts)
        self.attached_hosts = dict(hosts if attached_hosts is None else attached_hosts)
        self.links = list(links)
        self.edge_switches = {link.src or link.dst for link in self.links
                              if bool(link.src) != bool(link.dst)}
        usable = {dpid for dpid, sw in self.switches.items() if sw.usable}
        self._ports, self._busiest = {}, {}
        for link in self.links:
            if not link.up or (link.src and link.src not in usable) or (
                    link.dst and link.dst not in usable):
                continue
            for dpid in (link.src, link.dst):
                if dpid:
                    self._busiest[dpid] = max(self._busiest.get(dpid, 0.0), link.utilization_percent)
            if link.src and link.dst:
                self._ports.setdefault(link.src, {})[link.src_port] = link.dst

    @classmethod
    def from_graph(cls, graph):
        """Build from the body of GET /ndt/get_graph_data."""
        switches, host_nodes = {}, {}
        for node in graph["nodes"]:
            ips = node.get("ip") or []
            if node["vertex_type"] == 0:
                switches[node["dpid"]] = Switch(
                    dpid=node["dpid"], name=node.get("device_name") or node.get("nickname") or "",
                    mgmt_ip=ip_str(ips[0]) if ips else "", admin_state=node.get("admin_state"),
                    reachable=bool(node.get("reachable")), capabilities=node.get("capabilities"),
                    power_path=node.get("power_path"), brand=node.get("brand_name") or "")
            elif ips:
                host_nodes[ip_str(ips[0])] = node
        links, hosts, attached = [], {}, {}
        for e in graph["edges"]:
            links.append(Link(
                src=e["src_dpid"], src_port=e["src_interface"], dst=e["dst_dpid"],
                dst_port=e["dst_interface"], up=bool(e.get("is_up")),
                utilization_percent=e.get("link_bandwidth_utilization_percent", 0.0),
                usage_bps=e.get("link_bandwidth_usage_bps", 0),
                bandwidth_bps=e.get("link_bandwidth_bps", 0),
                telemetry_status=e.get("telemetry_status"), flows=e.get("flow_set", [])))
            sw = switches.get(e["src_dpid"])
            if sw is not None and not e["dst_dpid"]:
                ip = ip_str(e["dst_ip"][0])
                node = host_nodes.get(ip, {})
                attached[ip] = Host(name=node.get("device_name") or ip, ip=ip,
                                    mac=mac_str(node["mac"]) if node.get("mac") else "",
                                    switch=e["src_dpid"], port=e["src_interface"])
                if e.get("is_up") and sw.usable:
                    hosts[ip] = attached[ip]
        return cls(switches, hosts, links, attached)

    def neighbours(self, dpid):
        """{port: neighbouring switch dpid} over links that are up between usable switches."""
        return dict(self._ports.get(dpid, {}))

    def neighbour(self, dpid, port):
        """The switch on the other side of `dpid`'s `port`, or None (a host, a down link)."""
        return self._ports.get(dpid, {}).get(port)

    def busiest(self, dpid):
        """The highest utilisation (percent, 0..100) of a link that touches `dpid`; 0.0 if none."""
        return self._busiest.get(dpid, 0.0)

    def hosts_in(self, match_value):
        """The hosts a destination match holds: `[value, prefix_len]` (lpm) or the value (exact)."""
        if isinstance(match_value, (list, tuple)):
            net = ipaddress.ip_network(f"{match_value[0]}/{match_value[1]}", strict=False)
            return [h for h in self.hosts.values() if ipaddress.ip_address(h.ip) in net]
        return [h for h in self.hosts.values() if h.ip == match_value]
