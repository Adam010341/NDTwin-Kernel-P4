#!/usr/bin/env python3
# A controllable stand-in for the P4 proxy's northbound-facing REST surface.
# [Co-developed with claude code -- Adam]
#
# Why it exists: ranks 2, 8 and 10 all ask what the kernel does when ONE southbound endpoint,
# or ONE switch's flow table, answers badly while everything else answers correctly. No live
# fabric can be made to do that on demand -- a switch that dies takes its whole row with it.
# This serves the exact shapes p4_proxy/proxy_agent/ryu_topology.py renders (dpid and port_no
# as base-16 strings, links in both directions, hosts with mac + ipv4 + port), built from the
# same shipped topology file the kernel is started on, and reads MODE.json on EVERY request so
# a single endpoint can be degraded live without restarting anything.
import json, os, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOPO = sys.argv[1]
MODE = sys.argv[2]
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8081
d = json.load(open(TOPO))
SW = [n for n in d["nodes"] if n.get("vertex_type") == 0]
HO = [n for n in d["nodes"] if n.get("vertex_type") == 1]
DPIDS = sorted(n["dpid"] for n in SW)
SWIP = {n["ip"][0]: n["dpid"] for n in SW}
HOIP = {n["ip"][0]: n for n in HO}
hexd = lambda x: "%016x" % int(x)
hexp = lambda x: "%08x" % int(x)
macs = lambda m: ":".join(("%012x" % int(m))[i:i+2] for i in range(0, 12, 2))
REQLOG = []


def mode():
    try:
        return json.load(open(MODE))
    except Exception:
        return {}


def ep(dp, po, mac=None):
    o = {"dpid": hexd(dp), "port_no": hexp(po), "name": "s%d-eth%d" % (dp, po)}
    if mac:
        o["hw_addr"] = mac
    return o


def switches():
    return [{"dpid": hexd(x), "ports": []} for x in DPIDS]


def links():
    out = []
    for e in d["edges"]:
        s, t = e["src_ip"][0], e["dst_ip"][0]
        if s in SWIP and t in SWIP:
            out.append({"src": ep(SWIP[s], e["src_interface"]),
                        "dst": ep(SWIP[t], e["dst_interface"])})
    return out


def hosts():
    out = []
    for e in d["edges"]:
        s, t = e["src_ip"][0], e["dst_ip"][0]
        if s in SWIP and t in HOIP:
            h = HOIP[t]
            m = macs(h["mac"])
            out.append({"mac": m, "ipv4": [t], "ipv6": [],
                        "port": ep(SWIP[s], e["src_interface"], mac=m)})
    return out


def flow_rows(dpid, dsts):
    return [{"priority": 1, "table_id": 0, "cookie": 0, "flags": 0, "length": 80,
             "duration_sec": 100, "duration_nsec": 0, "idle_timeout": 0, "hard_timeout": 0,
             "packet_count": 0, "byte_count": 0,
             "match": {"dl_type": 2048, "nw_dst": ip},
             "actions": ["OUTPUT:1"]} for ip in dsts]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, obj, raw=None):
        b = raw if raw is not None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        m = mode()
        p = self.path.split("?")[0]
        REQLOG.append((round(time.time(), 2), p))
        if p == "/v1.0/topology/switches":
            return self._degrade(m.get("switches", "ok"), switches())
        if p == "/v1.0/topology/links":
            L = links()
            drop = int(m.get("links_drop", 0))
            if drop:
                L = L[drop:]
            return self._degrade(m.get("links", "ok"), L)
        if p == "/v1.0/topology/hosts":
            return self._degrade(m.get("hosts", "ok"), hosts())
        if p == "/ryu_server/all_destination_paths":
            return self._send(200, {"status": "success", "all_destination_paths": []})
        if p.startswith("/stats/flow/"):
            dp = p.rsplit("/", 1)[-1]
            fm = (m.get("flows") or {}).get(dp, m.get("flows_default", "ok"))
            dsts = m.get("rules", ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4"])
            if fm == "empty":
                return self._send(200, {dp: []})
            if fm == "malformed":      # a body that is not an array -> "not understood"
                return self._send(200, {dp: {"unexpected": "object"}})
            if fm == "http500":
                return self._send(500, {"error": "synthetic failure for dpid " + dp})
            if fm == "garbage":
                return self._send(200, None, raw=b"<html>not json</html>")
            if fm == "hang":
                time.sleep(40)
                return self._send(200, {dp: flow_rows(dp, dsts)})
            return self._send(200, {dp: flow_rows(dp, dsts)})
        if p == "/reqlog":
            return self._send(200, REQLOG[-400:])
        return self._send(404, {"error": "not found", "path": p})

    def do_POST(self):
        ln = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(ln)
        REQLOG.append((round(time.time(), 2), "POST " + self.path))
        self._send(200, {"status": "success"})

    def _degrade(self, how, ok_body):
        if how == "ok":
            return self._send(200, ok_body)
        if how == "empty":
            return self._send(200, [])
        if how == "http500":
            return self._send(500, {"error": "synthetic endpoint failure"})
        if how == "garbage":
            return self._send(200, None, raw=b"<html>not json</html>")
        if how == "emptybody":
            return self._send(200, None, raw=b"")
        if how == "hang":
            time.sleep(40)
            return self._send(200, ok_body)
        if how == "malformed":
            return self._send(200, {"not": "an array"})
        return self._send(200, ok_body)


print("fake southbound on :%d  switches=%d hosts=%d links=%d" %
      (PORT, len(DPIDS), len(hosts()), len(links())), flush=True)
ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
