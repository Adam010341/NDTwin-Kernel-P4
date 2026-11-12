"""An in-process fake of the NDTwin kernel for the SDK and example tests (not a test itself).

[Co-developed with claude code -- Adam]

It serves, on 127.0.0.1 and an ephemeral port, the kernel routes the SDK and the energy-saving
examples use:
  * GET /ndt/get_graph_data: tests/python/fixtures/p4_energy_saving/basic_pod_topo_graph.json, a
    reply of a kernel serving the tutorials' `basic` exercise (pod-topo: h1,h2 on s1; h3,h4 on s2;
    s3 and s4 each joined to s1 and s2) brought up with `ndt up p4 --app`;
  * GET/POST /ndt/p4/table_entry: the four switches' `MyIngress.ipv4_lpm` as the exercise's
    pod-topo/sN-runtime.json fills it, in the GET shape of doc/2026-01-02_ndt_api.md §3, with
    `X-NDTwin-Origin: proxy`; a modify replaces the entry's action, an insert adds an entry and a
    delete removes one, and the switch's own reason comes back in `p4rt_error`: ALREADY_EXISTS for
    an insert of an entry that is there and NOT_FOUND for a delete of one that is not, as bmv2
    1.15.5 gives them, and NOT_FOUND for a modify of one that is not, as P4Runtime specifies (not
    observed on bmv2); an insert of a default entry is a modify, as the proxy sends it;
  * the lock (§27, §28, §29), average link usage (§24), power report (§6, MININET's synthetic
    figures for dpids 1..4) and power state (§7, §8) routes, in the shapes the API document gives.
    A switch that is off answers a table read with the proxy's 503 `table not read`.
    `table_size` gives a switch's table a declared size: an insert into it when it is full is
    refused with UNKNOWN "Error when adding match entry to target", as bmv2 1.15.5 does.
Any other route answers 404 and is recorded, and the tests check the exact sequence of calls.
A fault can be queued for the next matching request (`fault`); `apply` says whether the write still
lands, a status of None closes the connection without a reply, a bytes body is sent as is, and a
str body is sent as text/plain (the proxy's own 500 is Starlette's "Internal Server Error").
The MAC address of a written entry is stored in lower case, as the switch shows it.

The lock has a lease that runs out: `now` is a clock in seconds that moves by
`seconds_per_request` at every request (0 by default, so a lease never runs out unless a test
asks), and an acquire, renew or release after the lease ran out answers as the kernel does.
A power command changes the switch's commanded state and `reachable` in the graph and in §7 at
once, as the kernel does for a bmv2 switch: a power-off marks it down
(src/ndt_core/power_management/P4PowerStrategy.cpp:282, TopologyAndFlowMonitor.cpp:5171) and a
power-on that succeeded marks it up (P4PowerStrategy.cpp:221). The links are left as they were,
since the kernel sees those change only later.

`FakeKernel(graph, routes, power_mw)` serves another fabric (`ring_fabric` and `chain_fabric`
below); the defaults are the pod topology above. `walk` follows the tables with the route check of
examples/p4_energy_saving/route_walk.py, which the tests import from there.
"""
import copy
import json
import os
import re
import socket
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GRAPH_PATH = os.path.join(REPO, "tests", "python", "fixtures", "p4_energy_saving",
                          "basic_pod_topo_graph.json")
EXAMPLE_DIR = os.path.join(REPO, "examples", "p4_energy_saving")
if EXAMPLE_DIR not in sys.path:
    sys.path.append(EXAMPLE_DIR)  # after any directory a test put first
import route_walk  # noqa: E402

TABLE = "MyIngress.ipv4_lpm"
FIELD = "hdr.ipv4.dstAddr"
# (destination, dstAddr, port) per switch: the exercise's pod-topo/sN-runtime.json.
ROUTES = {
    1: [("10.0.1.1", "08:00:00:00:01:11", 1), ("10.0.2.2", "08:00:00:00:02:22", 2),
        ("10.0.3.3", "08:00:00:00:03:00", 3), ("10.0.4.4", "08:00:00:00:04:00", 4)],
    2: [("10.0.1.1", "08:00:00:00:03:00", 4), ("10.0.2.2", "08:00:00:00:04:00", 3),
        ("10.0.3.3", "08:00:00:00:03:33", 1), ("10.0.4.4", "08:00:00:00:04:44", 2)],
    3: [("10.0.1.1", "08:00:00:00:01:00", 1), ("10.0.2.2", "08:00:00:00:01:00", 1),
        ("10.0.3.3", "08:00:00:00:02:00", 2), ("10.0.4.4", "08:00:00:00:02:00", 2)],
    4: [("10.0.1.1", "08:00:00:00:01:00", 2), ("10.0.2.2", "08:00:00:00:01:00", 2),
        ("10.0.3.3", "08:00:00:00:02:00", 1), ("10.0.4.4", "08:00:00:00:02:00", 1)],
}
# GET /ndt/get_power_report under MININET: syntheticPowerMilliwattsFor(dpid), dpids 1..4.
POWER_MW = {1: 92465, 2: 98110, 3: 49053, 4: 73978}
MGMT_IP = {d: f"192.168.123.{10 + d}" for d in ROUTES}
STATEFUL = ("/ndt/p4/counter/", "/ndt/p4/direct_counter/", "/ndt/p4/register/")
STATEFUL_NAMES = {"counter": ("MyIngress.c_port",), "direct_counter": ("MyIngress.dc_route",),
                  "register": ("MyIngress.r_mark",)}
MAC = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
LAB_CLAIM = '{"expires_at":0,"note":"","owner":"","state":"none"}'
LEASE = 41
TELEMETRY_HEALTH = {"status": "ok", "samples_in_window": 120, "offered_in_window": 120,
                    "dropped_in_window": 0, "socket_drops_in_window": 0, "app_drops_in_window": 0,
                    "loss_fraction": 0.0, "window_seconds": 5.0, "rx_total": 5000,
                    "addressed_total": 5000, "sock_ovfl_total": 0, "app_drop_total": 0}
REPLAYED_WHEN = ("at proxy startup, on a switch whose pipeline cookie confirms it is the fabric "
                 "this journal was written on, and after a readopt later in the same proxy run "
                 "(a readopt reads no cookie: this run's startup already decided)")


def grpc_502(grpc_status, dpid=1):
    """The proxy's 502 for a gRPC failure that carries no per-update reason (no `p4rt_error`): the
    write may have landed (a deadline, an unavailable switch, a cancelled call)."""
    return {"detail": {"error": "the switch refused the write", "dpid": dpid,
                       "grpc_status": grpc_status,
                       "message": f"switch {dpid} refused this entry: {grpc_status}"}}


def refused_502(dpid, code, message):
    """The proxy's 502 for a write the switch refused, with its per-update reason."""
    return {"detail": {"error": "the switch refused the write", "dpid": dpid,
                       "grpc_status": "UNKNOWN",
                       "message": f"switch {dpid} refused this entry: UNKNOWN ({code}: {message})",
                       "p4rt_error": {"code": code, "message": message}}}


def table_of(dpid, routes=None):
    entries = [{"dpid": dpid, "table": TABLE, "match": {FIELD: [dst, 32]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": mac, "port": port},
                "priority": None, "default_action": False}
               for dst, mac, port in (routes or ROUTES)[dpid]]
    entries.append({"dpid": dpid, "table": TABLE, "match": {}, "action_name": "MyIngress.drop",
                    "action_params": {}, "priority": None, "default_action": True})
    return entries


def decode_ip(n):
    """The kernel's integer form of an IPv4 address: s_addr read as a little-endian integer."""
    return socket.inet_ntoa(int(n).to_bytes(4, "little"))


def encode_ip(dotted):
    """The kernel's integer form of a dotted IPv4 address (the inverse of decode_ip)."""
    return int.from_bytes(socket.inet_aton(dotted), "little")


class FakeKernel:
    def __init__(self, graph=None, routes=None, power_mw=None):
        if graph is None:
            with open(GRAPH_PATH) as fh:
                graph = json.load(fh)
        self.graph = graph
        self.routes = routes or ROUTES
        self.power_mw = power_mw or POWER_MW
        self.mgmt_ip = {n["dpid"]: decode_ip(n["ip"][0]) for n in graph["nodes"]
                        if n["vertex_type"] == 0}
        self.tables = {d: table_of(d, self.routes) for d in self.routes}
        self.avg = 0.05
        self.avg_of = None                 # a function of the fake giving the average, when set
        self.telemetry_health = copy.deepcopy(TELEMETRY_HEALTH)
        self.power_state = {self.mgmt_ip[d]: {"admin_state": "on", "reachable": True}
                            for d in self.routes}
        self.lock_busy = False
        self.locks = {}                    # name -> the time its lease runs out
        self.now = 0.0
        self.seconds_per_request = 0.0
        self.unrendered = {}
        self.unrendered_after_write = {}   # dpid -> list shown from the first landed write on
        self.table_size = {}               # dpid -> the declared size; an insert past it is refused
        self.lab_claim = LAB_CLAIM
        self.faults = []
        self.requests = []

    def fault(self, method, path, status, body=None, origin=None, apply=False, times=1,
              match=None):
        """Answer the next `times` matching requests with `status` and `body` (status None: close
        the connection with no reply). `apply`: the request is also carried out. `match`: a
        function of (query, body) that must be true for the fault to fire."""
        for _ in range(times):
            self.faults.append((method, path, status, body, origin, apply, match))

    def handle(self, method, path, query, body):
        self.requests.append((method, path, query, body))
        self.now += self.seconds_per_request
        for i, (m, p, status, fbody, origin, apply, match) in enumerate(self.faults):
            if m == method and p == path and (match is None or match(query, body)):
                del self.faults[i]
                if apply:
                    self.route(method, path, query, body)
                return status, origin, fbody
        return self.route(method, path, query, body)

    def lock_state(self, name):
        """"held", "expired" (the lease ran out and is reclaimed now) or "free"."""
        if name not in self.locks:
            return "free"
        if self.now > self.locks[name]:
            del self.locks[name]
            return "expired"
        return "held"

    def route_lock(self, path, body):
        name, ttl = body["type"], body.get("ttl", 5)
        state = self.lock_state(name)
        if path == "/ndt/acquire_lock":
            if self.lock_busy or state == "held":
                return 423, None, {"error": "Lock acquisition failed",
                                   "detail": f"lock \"{name}\" is held by another client; retry "
                                             f"after its TTL",
                                   "held_by_lease": 7, "retry_after_s": 30}
            self.locks[name] = self.now + ttl
            return 200, None, {"status": "locked", "type": name, "ttl": ttl, "lease": LEASE,
                               "reclaimed_expired_lease": state == "expired"}
        verb = "Renew" if path == "/ndt/renew_lock" else "Release"
        if state != "held":
            return 412, None, {"error": f"{verb} failed",
                               "reason": "expired" if state == "expired" else "not_held",
                               "detail": f"Lock '{name}' is not held"}
        if verb == "Renew":
            self.locks[name] = self.now + ttl
            return 200, None, {"status": "renewed", "type": name, "ttl": ttl, "lease": LEASE}
        del self.locks[name]
        return 200, None, {"status": "released", "type": name, "lease": LEASE}

    def route(self, method, path, query, body):
        if method == "POST" and path in ("/ndt/acquire_lock", "/ndt/renew_lock",
                                         "/ndt/release_lock"):
            return self.route_lock(path, body)
        if (method, path) == ("GET", "/ndt/get_graph_data"):
            return 200, None, self.graph
        if (method, path) == ("GET", "/ndt/get_average_link_usage"):
            avg = self.avg_of(self) if self.avg_of else self.avg
            return 200, None, {"status": "success", "avg_link_usage": avg,
                               "telemetry_health": self.telemetry_health}
        if (method, path) == ("GET", "/ndt/get_power_report"):
            return 200, None, [{"dpid": d, "power_consumed": mw, "power_path": "synthetic"}
                               for d, mw in self.power_mw.items()]
        if path == "/ndt/p4/table_entry":
            return self.table_entry(method, query, body)
        if method == "GET" and path.startswith(STATEFUL):
            return self.stateful(path, query)
        if (method, path) == ("POST", "/ndt/set_switches_power_state"):
            # As src/ndt_core/http/HttpSession.cpp:2064-2102 answers: 400 for a missing ip or an
            # action other than on/off, 404 for an address it does not know, 200 {ip: "Success"}.
            # `reachable` follows at once (see the module docstring).
            # [Co-developed with claude code -- Adam]
            ip, action = query.get("ip"), query.get("action")
            if not ip or action not in ("on", "off"):
                return 400, None, {"error": "Missing or invalid ip/action"}
            if ip not in self.power_state:
                return 404, None, {"error": "Unknown switch IP"}
            self.power_state[ip].update(admin_state=action, reachable=action == "on")
            for node in self.graph["nodes"]:
                if node["vertex_type"] == 0 and self.mgmt_ip.get(node["dpid"]) == ip:
                    node.update(admin_state=action, reachable=action == "on")
            return 200, None, {ip: "Success"}
        if (method, path) == ("GET", "/ndt/get_switches_power_state"):
            ip = query.get("ip")
            if ip not in self.power_state:
                return 404, None, {"error": "Unknown switch IP"}
            return 200, None, {ip: self.power_state[ip]}
        return 404, None, {"error": "not a route of this fake"}

    def stateful(self, path, query):
        """GET /ndt/p4/{counter,direct_counter,register}/{name}, in the proxy's reply shapes."""
        kind, name = path[len("/ndt/p4/"):].split("/", 1)
        dpid = int(query["dpid"])
        if name not in STATEFUL_NAMES[kind]:
            return 404, "proxy", {"detail": {"error": "not in this pipeline", "dpid": dpid,
                                             kind: name, "message": "no such object"}}
        if kind == "counter":
            index = int(query.get("index", 0))
            return 200, "proxy", {"dpid": dpid, "counter": name, "index": index,
                                  "bytes": 335 * (index + 1), "packets": 5 * (index + 1)}
        if kind == "direct_counter":
            return 200, "proxy", {
                "dpid": dpid, "counter": name, "table": TABLE, "unit": "both",
                "entries": [{"match": {FIELD: {"type": "lpm", "value": 167838209, "prefix_len": 32}},
                             "priority": 0, "bytes": 335, "packets": 5}]}
        size, cells = 16, list(range(100, 116))
        if "index" in query:
            start, count = int(query["index"]), 1
        else:
            start, count = int(query.get("start", 0)), int(query.get("count", size))
        if start >= size or start + count > size:
            return 400, "proxy", {"detail": {"error": "index out of range", "dpid": dpid,
                                             "register": name, "size": size, "message": "m"}}
        return 200, "proxy", {"dpid": dpid, "register": name, "bitwidth": 32, "size": size,
                              "start": start, "values": cells[start:start + count],
                              "source": "bmv2-thrift"}

    def table_entry(self, method, query, body):
        dpid = int(query["dpid"]) if method == "GET" else body["dpid"]
        table = query.get("table") if method == "GET" else body.get("table")
        if dpid not in self.tables:
            return 404, "proxy", {"detail": {
                "error": "unknown switch", "dpid": dpid, "table": table,
                "message": f"switch {dpid} is not one of the switches this proxy set up; nothing "
                           f"was {'read' if method == 'GET' else 'written'}"}}
        if table not in (TABLE, "ipv4_lpm"):
            return 404, "proxy", {"detail": {"error": "not in this pipeline", "dpid": dpid,
                                             "table": table,
                                             "message": f"no table named {table!r}"}}
        if method == "GET" and self.power_state[self.mgmt_ip[dpid]]["admin_state"] == "off":
            # The proxy's answer for a switch whose bmv2 is gone (p4_proxy/proxy_agent/
            # api_routes.py:1602-1604; seen on bmv2 1.15.5, 2026-11-11 UTC).
            # [Co-developed with claude code -- Adam]
            return 503, "proxy", {"detail": {
                "error": "table not read", "dpid": dpid, "table": TABLE,
                "grpc_status": "UNAVAILABLE",
                "message": f"reading {TABLE} from switch {dpid} failed: UNAVAILABLE. This is NOT "
                           f"an empty table"}}
        if method == "GET":
            return 200, "proxy", {"dpid": dpid, "table": TABLE,
                                  "entries": copy.deepcopy(self.tables[dpid]),
                                  "unrendered": self.unrendered.get(dpid, [])}
        op = body.get("op")
        if op == "insert" and body.get("default_action"):
            op = "modify"   # the proxy sends a default entry's insert as a modify
        same = [e for e in self.tables[dpid] if e["match"] == body["match"]
                and e["priority"] == body.get("priority")
                and e["default_action"] == bool(body.get("default_action"))]
        if op == "insert" and same:
            return 502, "proxy", refused_502(dpid, "ALREADY_EXISTS", "Match entry exists")
        if op == "delete" and same:
            self.tables[dpid].remove(same[0])
            return 200, "proxy", self.write_reply(dpid, op)
        if op == "insert" and len([e for e in self.tables[dpid] if not e["default_action"]]) >= (
                self.table_size.get(dpid, 1 << 30)):
            # bmv2 1.15.5's answer to a new key into a full table (2026-11-05).
            return 502, "proxy", refused_502(dpid, "UNKNOWN", "Error when adding match entry to "
                                                              "target")
        if op == "insert":
            same = [{k: copy.deepcopy(body.get(k)) for k in ("dpid", "match", "priority")}]
            same[0].update(table=TABLE, default_action=False)
            self.tables[dpid].insert(len(self.tables[dpid]) - 1, same[0])  # before the default
        for entry in same[:1] if op in ("insert", "modify") else ():
            name = body["action_name"]  # the switch answers with the full name
            entry["action_name"] = name if "." in name else "MyIngress." + name
            entry["action_params"] = {k: v.lower() if isinstance(v, str) and MAC.match(v) else v
                                      for k, v in copy.deepcopy(body["action_params"]).items()}
            if dpid in self.unrendered_after_write:
                self.unrendered[dpid] = self.unrendered_after_write[dpid]
            return 200, "proxy", self.write_reply(dpid, op)
        return 502, "proxy", refused_502(dpid, "NOT_FOUND", "")

    @staticmethod
    def write_reply(dpid, op):
        return {"status": "success", "dpid": dpid, "op": op, "table": TABLE,
                "match_types": {FIELD: "LPM"}, "priority": None, "priority_honoured": True,
                "journaled": True,
                "journal": {"recorded": True, "enabled": True, "replay": REPLAYED_WHEN}}

    # --- what the data plane would do with these tables -------------------------------------

    def wiring(self):
        """({dpid: {port: neighbour dpid}}, {host ip: (dpid, port)}): every cable in the graph,
        up or not, as the data plane has it."""
        links, hosts = {}, {}
        for e in self.graph["edges"]:
            if e["src_dpid"] and e["dst_dpid"]:
                links.setdefault(e["src_dpid"], {})[e["src_interface"]] = e["dst_dpid"]
            elif e["src_dpid"]:
                hosts[decode_ip(e["dst_ip"][0])] = (e["src_dpid"], e["src_interface"])
        return links, hosts

    def walk(self, src_switch, dst_ip, tables=None):
        """(the switches a packet to dst_ip visits from src_switch, whether it is delivered),
        following `tables` (the fake's own by default) on the switches that are on."""
        tables = self.tables if tables is None else tables
        links, hosts = self.wiring()
        on = {d: t for d, t in tables.items()
              if self.power_state[self.mgmt_ip[d]]["admin_state"] != "off"}
        return route_walk.walk(on, links, hosts, src_switch, dst_ip, FIELD, "port")


def fabric_graph(switch_links, host_links, hot=()):
    """A GET /ndt/get_graph_data body for a made-up fabric of bmv2 switches.

    switch_links: [(a, a_port, b, b_port)], one cable each, listed in both directions in the
    graph; host_links: [(dpid, port, host ip)]; hot: cables {(a, b)} at 85 % utilisation. Switch d
    has management address 192.168.123.(10 + d). Telemetry is "idle" between switches and
    "unknown" towards a host, as in the recorded pod topology."""
    def edge(src, sport, dst, dport, util, status, dst_ip=0, src_ip=0):
        return {"src_dpid": src, "src_interface": sport, "dst_dpid": dst, "dst_interface": dport,
                "src_ip": [src_ip], "dst_ip": [dst_ip], "is_up": True, "is_enabled": True,
                "admin_disabled": False, "down_reason": "none",
                "link_bandwidth_bps": 1000000000, "left_link_bandwidth_bps": 1000000000,
                "left_link_bandwidth_source": "measured", "link_bandwidth_usage_bps": 0,
                "link_bandwidth_utilization_percent": util, "telemetry_status": status,
                "last_sample_age_seconds": 1.0, "agent_last_sample_age_seconds": 1.0,
                "flow_set": []}
    dpids = sorted({d for a, _, b, _ in switch_links for d in (a, b)}
                   | {d for d, _, _ in host_links})
    nodes = [{"vertex_type": 0, "dpid": d, "device_name": f"s{d}", "nickname": f"s{d}",
              "ip": [encode_ip(f"192.168.123.{10 + d}")], "mac": 0, "admin_state": "on",
              "reachable": True, "is_up": True, "brand_name": "BMv2", "power_path": "synthetic",
              "capabilities": {"ipv4_route": "package"}} for d in dpids]
    edges = []
    for a, ap, b, bp in switch_links:
        util = 85.0 if (a, b) in hot or (b, a) in hot else 0.0
        edges.append(edge(a, ap, b, bp, util, "idle"))
        edges.append(edge(b, bp, a, ap, util, "idle"))
    for d, port, ip in host_links:
        name = "h" + ip.rsplit(".", 1)[1]
        nodes.append({"vertex_type": 1, "dpid": 0, "device_name": name, "nickname": name,
                      "ip": [encode_ip(ip)], "mac": 0, "admin_state": "on", "reachable": True,
                      "is_up": True, "brand_name": ""})
        edges.append(edge(d, port, 0, 1, 0.0, "unknown", dst_ip=encode_ip(ip)))
        edges.append(edge(0, 1, d, port, 0.0, "idle", src_ip=encode_ip(ip)))
    return {"nodes": nodes, "edges": edges}


def ring_fabric(hot=()):
    r"""(graph, routes, power_mw) of a fabric where rewriting only the entries that point at the
    switch being turned off makes a loop.

        h1 - s1 - s2 - s3 - s4 - h4        s3 draws the most power, then s2, s5, s6, s7
              \                /
               s5 --- s6 --- s7

    Shortest paths, as the tables hold them: h1 <-> h4 over s2, s3. With s3 off, s2's entry for h4
    (which pointed at s3) would point back at s1, the way around, while s1 still sends to s2: a
    loop. With s2 off, s3's entry for h1 would point at s4, which still sends to s3."""
    switch_links = [(1, 2, 2, 1), (2, 2, 3, 1), (3, 2, 4, 2), (1, 3, 5, 1), (5, 2, 6, 1),
                    (6, 2, 7, 1), (7, 2, 4, 3)]
    host_links = [(1, 1, "10.0.1.1"), (4, 1, "10.0.4.4")]
    mac = "08:00:00:00:0{}:00".format
    routes = {
        1: [("10.0.1.1", "08:00:00:00:01:11", 1), ("10.0.4.4", mac(2), 2)],
        2: [("10.0.1.1", mac(1), 1), ("10.0.4.4", mac(3), 2)],
        3: [("10.0.1.1", mac(2), 1), ("10.0.4.4", mac(4), 2)],
        4: [("10.0.1.1", mac(3), 2), ("10.0.4.4", "08:00:00:00:04:44", 1)],
        5: [("10.0.1.1", mac(1), 1), ("10.0.4.4", mac(6), 2)],
        6: [("10.0.1.1", mac(5), 1), ("10.0.4.4", mac(7), 2)],
        7: [("10.0.1.1", mac(6), 1), ("10.0.4.4", mac(4), 2)],
    }
    power_mw = {1: 90000, 2: 80000, 3: 95000, 4: 90000, 5: 70000, 6: 60000, 7: 50000}
    return fabric_graph(switch_links, host_links, hot), routes, power_mw


def spine3_fabric(power_mw=None):
    r"""(graph, routes, power_mw) of a pod with three spines, two of which can be turned off.

        h1 - s1 ==== s3, s4, s5 ==== s2 - h2      each spine joined to s1 and s2; s5 draws the
                                                  most power, then s4, s3
    s1 sends h2's packets over s5 and s2 sends h1's over s4.
    [Co-developed with claude code -- Adam]"""
    switch_links = [(1, 3, 3, 1), (1, 4, 4, 1), (1, 5, 5, 1), (2, 3, 3, 2), (2, 4, 4, 2),
                    (2, 5, 5, 2)]
    host_links = [(1, 1, "10.0.1.1"), (2, 1, "10.0.2.2")]
    mac = "08:00:00:00:0{}:00".format
    spine = [("10.0.1.1", mac(1), 1), ("10.0.2.2", mac(2), 2)]
    routes = {1: [("10.0.1.1", "08:00:00:00:01:11", 1), ("10.0.2.2", mac(5), 5)],
              2: [("10.0.2.2", "08:00:00:00:02:22", 1), ("10.0.1.1", mac(4), 4)],
              3: list(spine), 4: list(spine), 5: list(spine)}
    power_mw = power_mw or {1: 60000, 2: 60000, 3: 70000, 4: 90000, 5: 95000}
    return fabric_graph(switch_links, host_links), routes, power_mw


def chain_fabric():
    r"""(graph, routes, power_mw) of a fabric where a host behind a link that is down for now is
    the only one whose route loops after the rewrites.

        h9 . s2 - s3 - s4 - h4         s3 draws the most power, then s2 and s4, s5, s1
             |         |               h9's link to s2 is down; h5 hangs off s5
             s1 ----- s5 - h5

    s1 sends h4's packets to s2 and s2 sends them to s3. With s3 off, s2's entry for h4 would point
    at s1, the way around, while s1 still sends to s2. h4 and h5 never pass s1 or s2, so a check
    that walks only the hosts behind links that are up finds nothing; h9's packets loop once its
    link is back."""
    switch_links = [(1, 2, 2, 1), (2, 2, 3, 1), (3, 2, 4, 2), (1, 3, 5, 1), (5, 2, 4, 3)]
    host_links = [(4, 1, "10.0.4.4"), (5, 9, "10.0.5.5"), (2, 9, "10.0.9.9")]
    mac = "08:00:00:00:0{}:00".format
    routes = {
        1: [("10.0.4.4", mac(2), 2), ("10.0.5.5", mac(5), 3), ("10.0.9.9", mac(2), 2)],
        2: [("10.0.4.4", mac(3), 2), ("10.0.5.5", mac(1), 1), ("10.0.9.9", "08:00:00:00:09:99", 9)],
        3: [("10.0.4.4", mac(4), 2), ("10.0.5.5", mac(4), 2), ("10.0.9.9", mac(2), 1)],
        4: [("10.0.4.4", "08:00:00:00:04:44", 1), ("10.0.5.5", mac(5), 3), ("10.0.9.9", mac(5), 3)],
        5: [("10.0.4.4", mac(4), 2), ("10.0.5.5", "08:00:00:00:05:55", 9), ("10.0.9.9", mac(1), 1)],
    }
    power_mw = {1: 60000, 2: 90000, 3: 95000, 4: 90000, 5: 70000}
    graph = fabric_graph(switch_links, host_links)
    h9 = encode_ip("10.0.9.9")
    for edge in graph["edges"]:
        if h9 in edge["dst_ip"] + edge["src_ip"]:
            edge["is_up"] = False
    return graph, routes, power_mw


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def _do(self):
            url = urllib.parse.urlsplit(self.path)
            query = dict(urllib.parse.parse_qsl(url.query))
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            body = json.loads(raw) if raw else None
            status, origin, reply = fake.handle(self.command, url.path, query, body)
            if status is None:
                self.close_connection = True  # no reply at all
                return
            if isinstance(reply, str):
                data, ctype = reply.encode(), "text/plain; charset=utf-8"
            else:
                data = reply if isinstance(reply, bytes) else json.dumps(reply).encode()
                ctype = "application/json"
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            if origin:
                self.send_header("X-NDTwin-Origin", origin)
            if url.path == "/ndt/p4/table_entry" and self.command == "POST" and fake.lab_claim:
                self.send_header("X-NDTwin-Lab-Claim", fake.lab_claim)
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = _do

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, args=(0.05,), daemon=True).start()
    return server


def calls(fake):
    """The requests as compact strings, in order."""
    out = []
    for method, path, query, body in fake.requests:
        if path == "/ndt/p4/table_entry":
            out.append(f"{method} table s{query['dpid'] if method == 'GET' else body['dpid']}")
        elif path == "/ndt/set_switches_power_state":
            out.append(f"POST power {query['ip']} {query['action']}")
        else:
            out.append(f"{method} {path.rsplit('/', 1)[1]}")
    return out
