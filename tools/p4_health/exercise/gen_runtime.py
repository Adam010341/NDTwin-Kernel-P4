#!/usr/bin/env python3
"""Write the health check's tutorials-shaped exercise files from one table of routes.

[Co-developed with claude code -- Adam]

    python3 tools/p4_health/exercise/gen_runtime.py            # rewrite the files in place
    python3 tools/p4_health/exercise/gen_runtime.py --check    # rc 1 if any committed file differs

The files are committed; this script is how they were made and how a test proves they still
match one table (tests/python/test_p4_health_cells.py). DESIGN section 2.2:

       h1 h2 h3                h4
        \\ | /                  |
         s1 -- p4 --- p2 ---- s2 -- p3 --- p2 -- s4 -- h6
          `- p5 -(0.5 Mbit/s)- p2 -- s3 -- p3 --- p3 '
                                     |
                                     h5

s1 runs hc_alt, s2-s4 hc_main. PRE: multicast group 1 on s1 = {p1, p2}; clone session 7 on s2 to
p1. Every switch also gets a sentinel /32 route of its own (10.0.99.<dpid>) that no other switch
is given: T1's same-window negative read is "the others' sentinels are not in my dump".
"""
from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

HOSTS = {1: 1, 2: 1, 3: 1, 4: 2, 5: 3, 6: 4}            # host -> the switch it hangs off
HOST_PORT = {1: 1, 2: 2, 3: 3, 4: 1, 5: 1, 6: 1}        # host -> that switch's port
#: switch-to-switch links: (a, a_port, b, b_port, bandwidth Mbit/s or None)
SWITCH_LINKS = [(1, 4, 2, 2, None), (1, 5, 3, 2, 0.5), (2, 3, 4, 2, None), (3, 3, 4, 3, None)]
#: next-hop port per switch per destination host (shortest paths; s1 reaches h5 over the
#: shaped link on purpose -- Q1 needs a queue at s1-eth5)
ROUTES = {
    1: {1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 4},
    2: {1: 2, 2: 2, 3: 2, 4: 1, 5: 3, 6: 3},
    3: {1: 2, 2: 2, 3: 2, 4: 3, 5: 1, 6: 3},
    4: {1: 2, 2: 2, 3: 2, 4: 2, 5: 3, 6: 1},
}
CPU_PORT = 510
DPORT_K2 = 40012
DPORT_MT3 = 40023
T2_RUNTIME_DEFAULT = 0x2A
MCAST = {1: [{"multicast_group_id": 1,
              "replicas": [{"egress_port": 1, "instance": 1}, {"egress_port": 2, "instance": 1}]}]}
CLONE = {2: [{"clone_session_id": 7, "replicas": [{"egress_port": 1, "instance": 1}]}]}


def host_ip(h):
    return "10.0.%d.%d" % (h, h)


def host_mac(h):
    return "08:00:00:00:%02x:%02x" % (h, h * 0x11)


def transit_mac(dpid):
    return "08:00:00:00:ff:%02x" % dpid


def program(dpid):
    return "hc_alt" if dpid == 1 else "hc_main"


def neighbour(dpid, port):
    """('host', h) or ('switch', dpid) at the far end of (dpid, port)."""
    for h, s in HOSTS.items():
        if s == dpid and HOST_PORT[h] == port:
            return ("host", h)
    for a, ap, b, bp, _bw in SWITCH_LINKS:
        if (a, ap) == (dpid, port):
            return ("switch", b)
        if (b, bp) == (dpid, port):
            return ("switch", a)
    raise KeyError((dpid, port))


def next_mac(dpid, dst_host):
    kind, far = neighbour(dpid, ROUTES[dpid][dst_host])
    return host_mac(far) if kind == "host" else transit_mac(far)


def runtime(dpid, with_ternary=False):
    stem = program(dpid)
    entries = [{"table": "HcIngress.ipv4_lpm", "default_action": True,
                "action_name": "HcIngress.drop", "action_params": {}}]
    for h in sorted(ROUTES[dpid]):
        entries.append({"table": "HcIngress.ipv4_lpm", "match": {"hdr.ipv4.dstAddr": [host_ip(h), 32]},
                        "action_name": "HcIngress.ipv4_forward",
                        "action_params": {"dstAddr": next_mac(dpid, h), "port": ROUTES[dpid][h]}})
    entries.append({"table": "HcIngress.ipv4_lpm",
                    "match": {"hdr.ipv4.dstAddr": ["10.0.99.%d" % dpid, 32]},
                    "action_name": "HcIngress.drop", "action_params": {}})
    for h in sorted(ROUTES[dpid]):
        entries.append({"table": "HcIngress.tunnel_exact", "match": {"meta.dst_id": h},
                        "action_name": "HcIngress.tunnel_forward",
                        "action_params": {"port": ROUTES[dpid][h]}})
    for h in sorted(ROUTES[dpid]):
        entries.append({"table": "HcIngress.v6_host", "match": {"meta.v6_lo": h},
                        "action_name": "HcIngress.v6_forward",
                        "action_params": {"dstAddr": next_mac(dpid, h), "port": ROUTES[dpid][h]}})
    entries.append({"table": "HcIngress.t_dcount", "match": {"hdr.udp.dstPort": DPORT_K2},
                    "action_name": "HcIngress.dc_hit", "action_params": {}})
    entries.append({"table": "HcIngress.t_dmeter", "match": {"hdr.udp.dstPort": DPORT_MT3},
                    "action_name": "HcIngress.dm_read", "action_params": {}})
    if dpid == 1:
        # HR1/HR2: h4 over either uplink; the hash or the coin picks.
        for choice, port, via in ((0, 4, 2), (1, 5, 3)):
            entries.append({"table": "HcIngress.t_multipath",
                            "match": {"hdr.ipv4.dstAddr": host_ip(4), "meta.mp_choice": choice},
                            "action_name": "HcIngress.ipv4_forward",
                            "action_params": {"dstAddr": transit_mac(via), "port": port}})
    if dpid == 2:
        entries.append({"table": "HcIngress.t_default_only", "default_action": True,
                        "action_name": "HcIngress.stamp", "action_params": {"v": T2_RUNTIME_DEFAULT}})
    if with_ternary:
        # PF-T: a boot entry that names a TERNARY field. Pre-flight must refuse it (G5).
        entries.append({"table": "HcIngress.t_ternary", "priority": 10,
                        "match": {"hdr.ipv4.srcAddr": [host_ip(1), "255.255.255.255"]},
                        "action_name": "HcIngress.set_mark", "action_params": {"v": 7}})
    doc = {"target": "bmv2", "p4info": "build/%s.p4.p4info.txtpb" % stem,
           "bmv2_json": "build/%s.json" % stem, "table_entries": entries}
    if dpid in MCAST:
        doc["multicast_group_entries"] = MCAST[dpid]
    if dpid in CLONE:
        doc["clone_session_entries"] = CLONE[dpid]
    return doc


def topology(kind):
    """kind: 'a' (entries), 'b' (external: no entries), 'pft' (s2 carries a ternary entry)."""
    hosts = {}
    for h in sorted(HOSTS):
        gw = "10.0.%d.%d0" % (h, h)
        hosts["h%d" % h] = {"ip": "%s/24" % host_ip(h), "mac": host_mac(h),
                            "commands": ["route add default gw %s dev eth0" % gw,
                                         "arp -i eth0 -s %s 08:00:00:00:%02x:00" % (gw, h)]}
    switches = {}
    for dpid in (1, 2, 3, 4):
        spec = {"cpu_port": CPU_PORT}
        if kind == "a" or (kind == "pft" and dpid != 2):
            spec["runtime_json"] = "runtime/s%d-runtime.json" % dpid
        elif kind == "pft":
            spec["runtime_json"] = "runtime/s2-runtime-pft.json"
        if dpid == 1:
            spec["program"] = "build/hc_alt.json"
        switches["s%d" % dpid] = spec
    links = [["h%d" % h, "s%d-p%d" % (HOSTS[h], HOST_PORT[h])] for h in sorted(HOSTS)]
    for a, ap, b, bp, bw in SWITCH_LINKS:
        link = ["s%d-p%d" % (a, ap), "s%d-p%d" % (b, bp)]
        if bw is not None:
            link += ["0", bw]
        links.append(link)
    return {"hosts": hosts, "switches": switches, "links": links}


def files():
    out = {}
    for dpid in (1, 2, 3, 4):
        out["runtime/s%d-runtime.json" % dpid] = runtime(dpid)
    out["runtime/s2-runtime-pft.json"] = runtime(2, with_ternary=True)
    out["topology.json"] = topology("a")
    out["topology-b.json"] = topology("b")
    out["topology-pft.json"] = topology("pft")
    return {rel: json.dumps(doc, indent=2, sort_keys=True) + "\n" for rel, doc in out.items()}


def main(argv):
    check = "--check" in argv
    bad = []
    for rel, text in sorted(files().items()):
        path = os.path.join(HERE, rel)
        if check:
            try:
                with open(path, encoding="utf-8") as fh:
                    if fh.read() != text:
                        bad.append(rel)
            except OSError:
                bad.append(rel)
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    if bad:
        print("differs from the generator: %s" % ", ".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
