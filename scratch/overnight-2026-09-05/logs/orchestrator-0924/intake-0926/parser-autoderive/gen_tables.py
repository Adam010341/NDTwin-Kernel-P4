#!/usr/bin/env python3
"""Per-path appendix for REPORT.md, generated from results.json (no hand transcription).
[Co-developed with claude code -- Adam]"""
import json
import os
import re
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
d = json.load(open(os.path.join(HERE, "results.json")))

# Today's twin per path -- READ, not run: include/common_types/SFlowType.hpp identifyFrame and
# src/ndt_core/collection/FlowLinkUsageCollector.cpp:1642-1648 (flow-table gate).
B_V4 = "OK IPv4 5-tuple, flow table [SFlowType.hpp:327-399; FLUC.cpp:1642-1648]"
B_V4_OTHER = ("OK IPv4 identity; flow table only if proto 6/17/1 and frag 0 "
              "[FLUC.cpp:1642-1646]")
B_V4_OPT = "OK IPv4 5-tuple, ports at ihl*4 [SFlowType.hpp:347-369]"
B_L2_WRONG = ("MISS: L2 key (MACs+ethertype) into the side table; inner IPv4 not found "
              "[SFlowType.hpp:508-510; FLUC.cpp:1049-1100]")
B_L2_OK = "OK L2 key into the side table (no IP on this path) [SFlowType.hpp:508-510]"
B_DEFAULT = ("by ethertype: 0x0800/0x86DD get IPv4/IPv6, everything else L2 "
             "[SFlowType.hpp:327,401,508]")
B_CPU = "n/a: CPU port only, never on a sampled veth"
BASE = {
    ("basic", "P1"): B_V4, ("basic", "P2"): B_DEFAULT,
    ("basic_tunnel", "P1"): B_L2_WRONG, ("basic_tunnel", "P2"): B_L2_OK + " (IPv6 inside: MISS)",
    ("basic_tunnel", "P3"): B_V4, ("basic_tunnel", "P4"): B_DEFAULT,
    ("calc", "P1"): B_L2_OK, ("calc", "P2"): B_L2_OK, ("calc", "P3"): B_DEFAULT,
    ("ecn", "P1"): B_V4, ("ecn", "P2"): B_DEFAULT,
    ("firewall_basic", "P1"): B_V4, ("firewall_basic", "P2"): B_DEFAULT,
    ("firewall_fw", "P1"): B_V4, ("firewall_fw", "P2"): B_V4_OTHER,
    ("firewall_fw", "P3"): B_DEFAULT,
    ("flowcache", "P1"): B_CPU, ("flowcache", "P2"): B_V4 + " (never reads ingress_port)",
    ("flowcache", "P3"): B_DEFAULT,
    ("link_monitor", "P1"): B_V4, ("link_monitor", "P2"): B_L2_OK,
    ("link_monitor", "P3"): B_L2_OK, ("link_monitor", "P4"): B_DEFAULT,
    ("load_balance", "P1"): B_V4, ("load_balance", "P2"): B_V4_OTHER,
    ("load_balance", "P3"): B_DEFAULT,
    ("mri", "P1"): B_V4, ("mri", "P2"): B_V4_OPT, ("mri", "P3"): B_V4_OPT,
    ("mri", "P4"): B_V4_OPT, ("mri", "P5"): B_DEFAULT,
    ("multicast", "P1"): B_DEFAULT + " -- incl. the IPv4 pings",
    ("p4runtime", "P1"): B_L2_WRONG, ("p4runtime", "P2"): B_L2_OK, ("p4runtime", "P3"): B_V4,
    ("p4runtime", "P4"): B_DEFAULT,
    ("qos", "P1"): B_V4, ("qos", "P2"): B_DEFAULT,
    ("source_routing", "P1"): B_L2_WRONG,
    ("source_routing", "P2"): B_DEFAULT + " -- incl. the last-hop IPv4",
    ("ndtwin_switch", "P1"): B_CPU, ("ndtwin_switch", "P2"): B_CPU,
    ("ndtwin_switch", "P3"): B_CPU, ("ndtwin_switch", "P4"): B_CPU,
    ("ndtwin_switch", "P5"): B_CPU,
    ("ndtwin_switch", "P6"): B_V4, ("ndtwin_switch", "P7"): B_V4,
    ("ndtwin_switch", "P8"): B_V4, ("ndtwin_switch", "P9"): B_V4_OTHER,
    ("ndtwin_switch", "P10"): B_DEFAULT,
}

cases = defaultdict(list)
for row in d["cases"]:
    if re.match(r"^P\d+$", str(row["path"])):
        cases[(row["prog"], row["path"])].append(f"{row['id']}={row['verdict']}")

print("| program | path | walk (loops as patterns) | class | construct | IP offset | "
      "synth cases (RAN) | real frames (RAN) | today's twin (READ) |")
print("|---|---|---|---|---|---|---|---|---|")
for r in d["path_table"]:
    s = d["static"][r["prog"]][int(r["pid"][1:]) - 1]
    off = "-" if s["ip_offset_min"] is None else (
        f"{s['ip_offset_min']}" if s["ip_offset_min"] == s["ip_offset_max"]
        else f"{s['ip_offset_min']}..{s['ip_offset_max']}")
    cons = ",".join(x[2:] for x in s["n_constructs"]) or ",".join(
        t for t in s["tags"] if not t.startswith("N:")) or "-"
    walk = s["path"].replace("|", "\\|")
    klass = r["klass"] + (" (CPU-only)" if r["cpu_only"] else "")
    print(f"| {r['prog']} | {r['pid']} | `{walk}` | {klass} | {cons} | {off} | "
          f"{', '.join(cases[(r['prog'], r['pid'])]) or '-'} | {r['pcap_frames']} | "
          f"{BASE[(r['prog'], r['pid'])]} |")
