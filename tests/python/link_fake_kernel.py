"""An in-process fake of the kernel's link-injection routes for tests/python/test_ndtwin_sdk_link.py
and the README example test (not a test itself).

[Co-developed with claude code -- Adam]

It serves, on 127.0.0.1 and an ephemeral port:
  * GET /ndt/get_graph_data: switches s1, s2, s3, cables s1:1-s2:1 and s2:2-s3:1 (both directions)
    and host 10.0.0.1 on s1's port 3, with `down_reason` "declared" on a declared link;
  * POST /ndt/inject_link_failure and /ndt/inject_link_recovery, answered from a model of the
    kernel's state: which switch pairs are declared down, which interfaces carry a netem this
    kernel attached ("ours"), another one ("foreign"), or one that replaced this kernel's
    ("replaced"), and which switches the topology file gives no bridge name. The order of the checks and every body are
    the kernel's at 922d9e4ec, plus the port check that follows the edge lookup (HS.cpp,
    refuseWrongPorts): a request whose ports are not the link's is answered 404 naming the link;
    the model of the qdisc tree is a made-up minimum (one line per interface), since only the
    kernel reads it.
Any other route answers the kernel's 404 `Not Found`. A test queues other replies with `script`;
each is used once, in order, before the model. A reply of None closes the connection without
answering; a reply body of bytes is sent as it is. Every request is recorded as
(method, path, body).

Line numbers are of 922d9e4ec: HS.cpp = src/ndt_core/http/HttpSession.cpp, NLF =
include/utils/NetemLinkFault.hpp.
"""
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

INJECT, RECOVER, GRAPH = ("/ndt/inject_link_failure", "/ndt/inject_link_recovery",
                          "/ndt/get_graph_data")
SKIPPED = "skipped (not MININET)"

# HS.cpp:665-668 (labClaimJson), with no claim file. Added as a body key to every reply of these two
# routes whose body is a JSON object, refusals included (HS.cpp:342-343, HS.cpp:757).
LAB_CLAIM = {"state": "none", "owner": "", "expires_at": 0, "note": ""}

INVALID = {"error": "Invalid link-failure payload"}                       # HS.cpp:1255, :1370
HOST_EDGE = {"error": "src_dpid and dst_dpid must both name a switch: dpid 0 is the host end of a "
                      "host edge, and a host edge is not addressed by this endpoint -- it would "
                      "resolve to whichever host edge of the other switch comes first in the "
                      "graph"}                                              # HS.cpp:879-882
NO_EDGE = {"error": "edge not found in topology"}                         # HS.cpp:1272, :1388


def wrong_ports(a, ap, b, bp, held):
    """The 404 for ports that are not the link's (HS.cpp, refuseWrongPorts); `held` is the link's
    (port on a, port on b)."""
    return {"error": f"no link {a}:{ap} -> {b}:{bp} in the topology (dpid:port -> dpid:port): the "
                     f"link between these two switches is {a}:{held[0]} -> {b}:{held[1]}. "
                     f"Nothing was changed",
            "link": {"src_dpid": a, "src_interface": held[0], "dst_dpid": b,
                     "dst_interface": held[1]}}


#: The body above for s1:2 -> s2:1 when the link is s1:1 - s2:1.
WRONG_PORTS = wrong_ports(1, 2, 2, 1, (1, 1))
NO_REVERSE_INJECT = {"error": "reverse edge missing from the topology; nothing was injected"}
#                                                                           ^ HS.cpp:1289
NO_REVERSE_RECOVER = {"error": "reverse edge missing from the topology; nothing was withdrawn"}
#                                                                           ^ HS.cpp:1401
JSON_ERROR = {"error": "JSON parsing error",                               # HS.cpp:600
              "details": "[json.exception.type_error.316] invalid UTF-8 byte at index 7: 0xFF"}
INTERNAL = {"error": "Internal server error", "details": "std::bad_alloc"}  # HS.cpp:613
ALREADY = ("netem is already attached to this interface; refusing to stack a second one, because "
           "the restore could then not tell them apart. Remove the existing one first")  # NLF:186
UNREADABLE = ("could not read the qdisc tree (tc qdisc show returned 1); on this machine that "
              "usually means sudo -n was refused")                        # NLF:468-470


def ip_int(dotted):
    """The kernel's integer form of an IPv4 address (topology.py, ip_str)."""
    return int.from_bytes(socket.inet_aton(dotted), "little")


def tree(iface, netem=False):
    """A made-up qdisc tree of one interface: a TCLink shaper, and a netem under it."""
    lines = ["qdisc htb 5: root refcnt 2 r2q 10 default 0x1 direct_packets_stat 0"]
    if netem:
        lines.append("qdisc netem 801d: parent 5:1 limit 1000 loss 100%")
    return "\n".join(lines) + "\n"


def cut_ok(iface):
    """One end that cutInterface cut (NLF:556-600)."""
    return {"interface": iface, "ok": True, "qdisc_before": tree(iface),
            "attached_at": "parent 5:0x1",
            "command": f"qdisc add dev {iface} parent 5:0x1 netem loss 100%",
            "qdisc_after": tree(iface, True)}


def removed(iface):
    """One end restoreSightedNetem took a netem of this kernel's off (NLF:676-684 over
    detachSightedNetem, NLF:518-546)."""
    return {"interface": iface, "ok": True, "qdisc_before": tree(iface, True),
            "detached_at": "parent 5:1", "command": f"qdisc del dev {iface} parent 5:1",
            "qdisc_after": tree(iface),
            "was": f"attached by this kernel at 2026-11-24 18:00:00.000 (801d: at parent 5:0x1)"}


def noop(iface):
    """One end with no netem on it (NLF:686-692; the `why` NLF:480)."""
    return {"interface": iface, "ok": True, "qdisc_before": tree(iface),
            "noop": "no netem qdisc is attached to this interface"}


def foreign(iface, replaced=False):
    """One end whose netem this kernel did not attach (NLF:694-704). The `why`: NLF:504-506, or,
    when this kernel attached one there and somebody replaced it, NLF:497-499."""
    why = (f"this kernel attached 801d: to {iface} at 2026-11-24 18:00:00.000, but the netem "
           f"there now is 802a: -- somebody replaced it, so it is not this kernel's to remove"
           if replaced else
           f"this kernel did not attach the netem on {iface} (801d:); no injection through "
           f"/ndt/inject_link_failure recorded it")
    return {"interface": iface, "ok": False, "qdisc_before": tree(iface, True),
            "refused": why + f". Nothing was deleted here: remove it yourself with 'sudo tc qdisc "
                             f"del dev {iface} parent 5:1' once you know whose experiment it "
                             f"belongs to"}


def delete_refused(iface):
    """One end whose netem this kernel attached and whose delete tc refused: detachSightedNetem
    returns before reading the tree again (NLF:520-532), and restoreSightedNetem adds `was`
    (NLF:676-684)."""
    return {"interface": iface, "ok": False, "qdisc_before": tree(iface, True),
            "detached_at": "parent 5:1", "command": f"qdisc del dev {iface} parent 5:1",
            "error": "tc refused the delete (status 1)",
            "was": "attached by this kernel at 2026-11-24 18:00:00.000 (801d: at parent 5:0x1)"}


def attach_refused(iface):
    """One end whose attach tc refused (cutInterface, NLF:556-596)."""
    return {"interface": iface, "ok": False, "qdisc_before": tree(iface),
            "attached_at": "parent 5:0x1",
            "command": f"qdisc add dev {iface} parent 5:0x1 netem loss 100%",
            "error": "tc refused the attach (status 2)"}


NO_BRIDGE_CUT = {"interface": None, "ok": False,                          # NLF:758-767
                 "refused": "the topology file gives this switch no bridge_name, so the twin "
                            "cannot name its interface"}
NO_BRIDGE_RESTORE = {"interface": None, "ok": False,                      # HS.cpp:1503-1508
                     "refused": "the topology file gives this switch no bridge_name"}


def unreadable(iface):
    """One end whose tree could not be read (NLF:708, the `why` NLF:468-470)."""
    return {"interface": iface, "ok": False, "error": UNREADABLE}


def injected(ends_tc):
    """The 200 of a cut of both ends (HS.cpp:1303-1305, `tc` HS.cpp:1337)."""
    return {"status": "link failure injected", "down_reason": "declared",
            "until": "/ndt/inject_link_recovery", "tc": ends_tc}


def not_attached(ends_tc, why):
    """The 200 of a cut that attached nothing (HS.cpp:1339-1349)."""
    return {"status": "link failure declared; nothing was attached", "down_reason": "declared",
            "until": "/ndt/inject_link_recovery", "tc": ends_tc,
            "wire": "no netem was attached to either end: " + why + ". The declaration stands and "
                    "the twin reports this link down, but packets are still flowing. Withdraw it "
                    "with POST /ndt/inject_link_recovery"}


def rolled_back(iface, blocked, undone):
    """An end phase 3 of cutLinkEnds attached and then rolled back (NLF:872-886); `undone` is
    restoreSightedNetem's report of the rollback."""
    end = cut_ok(iface)
    end.update(ok=False, rolled_back=undone,
               refused="attached, then removed again: the other end could not be cut (" + blocked
                       + "), and this endpoint cuts both ends or neither")
    return end


def recovered(ends_tc):
    """The 200 of a recovery (HS.cpp:1486, `tc` HS.cpp:1519)."""
    return {"status": "link recovery injected", "tc": ends_tc}


def left_standing(ends_tc, ifaces):
    """The 200 of a recovery that left a netem it did not attach (HS.cpp:1520-1528)."""
    return {"status": "declaration withdrawn; a netem this kernel did not attach was left "
                      "standing", "netem_left_standing": list(ifaces), "tc": ends_tc}


def conflict(ifaces):
    """The 409 of a recovery of a link nothing declared, carrying a netem this kernel did not
    attach (HS.cpp:1440-1458; describeArgv joins with spaces)."""
    return {"error": "not declared by this kernel; a netem is present on " + " ".join(ifaces)
                     + " that this kernel did not attach -- remove it yourself, or find out whose "
                       "experiment it belongs to first. Nothing was changed: no declaration was "
                       "withdrawn and no qdisc was deleted",
            "netem_not_ours": list(ifaces),
            "why": f"this kernel did not attach the netem on {ifaces[0]} (801d:); no injection "
                   f"through /ndt/inject_link_failure recorded it"}


def with_claim(body):
    return dict(body, lab_claim=dict(LAB_CLAIM)) if isinstance(body, dict) else body


class LinkFakeKernel:
    def __init__(self, mininet=True):
        self.mininet = mininet
        self.cables = [(1, 1, 2, 1), (2, 2, 3, 1)]     # (a, a_port, b, b_port)
        self.hosts = [(1, 3, "10.0.0.1")]               # (switch, port, ip)
        self.declared = set()                           # frozenset({a, b})
        self.netem = {}             # interface -> "ours" | "foreign" | "replaced" (ours, swapped)
        self.no_bridge = set()      # dpids the topology file gives no bridge_name
        self.requests = []
        self.scripted = {}
        self.lock = threading.Lock()

    def script(self, method, path, *replies):
        with self.lock:
            self.scripted.setdefault((method, path), []).extend(replies)

    def posts(self, path=None):
        return [b for m, p, b in self.requests if m == "POST" and path in (None, p)]

    def handle(self, method, path, body):
        with self.lock:
            self.requests.append((method, path, body))
            queue = self.scripted.get((method, path))
            if queue:
                status_body = queue.pop(0)
                if status_body is None or not isinstance(status_body[1], dict):
                    return status_body
                status, reply = status_body
                return status, with_claim(reply) if path in (INJECT, RECOVER) else reply
            if method == "GET" and path == GRAPH:
                return 200, self.graph()
            if method == "POST" and path in (INJECT, RECOVER):
                status, reply = self.link_route(path, body)
                return status, with_claim(reply)
        return 404, {"error": "Not Found"}      # HS.cpp:3830 (handleNotFound)

    # --- the model ----------------------------------------------------------------------------

    def graph(self):
        """The keys of GET /ndt/get_graph_data that topology.py reads (edges HS.cpp:1635-1684,
        nodes GraphTypes.hpp to_json); made-up values elsewhere."""
        nodes = [{"vertex_type": 0, "dpid": d, "device_name": f"s{d}",
                  "ip": [ip_int(f"192.168.123.{10 + d}")], "admin_state": "on",
                  "reachable": True, "brand_name": "Open vSwitch"} for d in (1, 2, 3)]
        nodes += [{"vertex_type": 1, "dpid": 0, "device_name": "h1", "ip": [ip_int(ip)],
                   "mac": 1} for _, _, ip in self.hosts]
        edges = []

        def edge(a, ap, b, bp, dst_ip=()):
            down = frozenset((a, b)) in self.declared
            edges.append({"src_dpid": a, "src_interface": ap, "dst_dpid": b,
                          "dst_interface": bp, "is_up": not down,
                          "down_reason": "declared" if down else "none",
                          "dst_ip": list(dst_ip), "link_bandwidth_bps": 1000000000,
                          "link_bandwidth_usage_bps": 0,
                          "link_bandwidth_utilization_percent": 0.0,
                          "telemetry_status": "ok", "flow_set": []})

        for a, ap, b, bp in self.cables:
            edge(a, ap, b, bp)
            edge(b, bp, a, ap)
        for sw, port, ip in self.hosts:
            edge(sw, port, 0, 0, [ip_int(ip)])
            edge(0, 0, sw, port, [ip_int(f"192.168.123.{10 + sw}")])
        return {"nodes": nodes, "edges": edges}

    def link_route(self, path, body):
        """The checks of handleInjectLinkFailure / handleInjectLinkRecovery, in their order."""
        keys = ("src_dpid", "src_interface", "dst_dpid", "dst_interface")
        if not isinstance(body, dict) or any(not isinstance(body.get(k), int) for k in keys):
            return 400, INVALID                                     # HS.cpp:1251-1256
        a, ap, b, bp = (body[k] for k in keys)
        if not (a and b):
            return 400, HOST_EDGE                                   # HS.cpp:1261-1266
        pair = frozenset((a, b))
        if not any(frozenset((c[0], c[2])) == pair for c in self.cables):
            return 404, NO_EDGE                    # by the two dpids only, HS.cpp:1268-1274
        # The ports must be the link's. The kernel's graph holds one edge per direction between two
        # switches, the first the topology file lists, so the first cable here is the link.
        cable = next(c for c in self.cables if frozenset((c[0], c[2])) == pair)
        held = (cable[1], cable[3]) if cable[0] == a else (cable[3], cable[1])
        if (ap, bp) != held:
            return 404, wrong_ports(a, ap, b, bp, held)
        ifaces = [None if d in self.no_bridge else f"s{d}-eth{p}" for d, p in ((a, ap), (b, bp))]
        if path == INJECT:
            return self.inject(pair, ifaces)
        return self.recover(pair, ifaces)

    def inject(self, pair, ifaces):
        self.declared.add(pair)                                     # HS.cpp:1297
        if not self.mininet:
            return 200, {"status": "link failure injected", "down_reason": "declared",
                         "until": "/ndt/inject_link_recovery", "tc": SKIPPED}  # HS.cpp:1303-1312
        blocked = [i for i in ifaces if i is None or i in self.netem]
        if blocked:
            # cutLinkEnds phase 1 (NLF:758-767, NLF:796-802) and the ends that could have been cut
            # (NLF:826-831)
            why = ("one of this link's switches has no bridge_name in the topology file"
                   if blocked[0] is None else f"{blocked[0]}: {ALREADY}")
            ends = []
            for i in ifaces:
                if i is None:
                    ends.append(dict(NO_BRIDGE_CUT))
                elif i in self.netem:
                    ends.append({"interface": i, "ok": False, "qdisc_before": tree(i, True),
                                 "refused": ALREADY})
                else:
                    ends.append({"interface": i, "ok": False, "qdisc_before": tree(i),
                                 "refused": "the other end of this link could not be cut (" + why
                                            + "), and a link failure injected at one end only is "
                                              "a different, subtler fault (faults.txt L-2). "
                                              "Nothing was attached here either"})
            return 200, not_attached(ends, why)
        for i in ifaces:
            self.netem[i] = "ours"
        return 200, injected([cut_ok(i) for i in ifaces])

    def recover(self, pair, ifaces):
        if self.mininet:
            seen = [self.netem.get(i) for i in ifaces]
            theirs = [i for i, s in zip(ifaces, seen) if s in ("foreign", "replaced")]
            if pair not in self.declared and "ours" not in seen and theirs:
                return 409, conflict(theirs)
        self.declared.discard(pair)                                 # HS.cpp:1484
        if not self.mininet:
            return 200, {"status": "link recovery injected", "tc": SKIPPED}  # HS.cpp:1486-1491
        ends, standing = [], []
        for i in ifaces:
            state = self.netem.get(i)
            if i is None:
                ends.append(dict(NO_BRIDGE_RESTORE))
            elif state == "ours":
                del self.netem[i]
                ends.append(removed(i))
            elif state in ("foreign", "replaced"):
                ends.append(foreign(i, replaced=state == "replaced"))
                standing.append(i)
            else:
                ends.append(noop(i))
        return 200, left_standing(ends, standing) if standing else recovered(ends)


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def _do(self):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            body = json.loads(raw) if raw else None
            reply = fake.handle(self.command, self.path.split("?")[0], body)
            if reply is None:
                self.close_connection = True
                self.connection.shutdown(2)      # no answer: the client sees a broken connection
                return
            status, payload = reply
            data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = _do

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05},
                     daemon=True).start()
    return server
