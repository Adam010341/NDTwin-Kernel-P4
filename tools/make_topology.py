#!/usr/bin/env python3
"""Generate an OVS topology model with N hosts, for sweeping the all-pairs walk across scales.

[Co-developed with claude code -- Adam]

## Why

`setting/` ships two OVS models -- 4 hosts and 128 -- and the walk timed by `c2afbac` is
suspected of dominating the 128-host failover budget. Two points cannot tell a linear cost from
a quadratic one, and the two halves of that walk are expected to scale differently: the BFS
installs one rule per (switch, dst) while the reporting loop builds one entry per ordered host
pair. Intermediate sizes are what separates them.

`ndt` finds a model by counting hosts in every `StaticNetworkTopologyOVS_*.json` and
`StaticNetworkTopologyMininet_*.json` (`topo_for_hosts`), so a file dropped into `setting/`
with the right name is picked up with no wiring: `ndt up ovs32` just works.

## The switch fabric is copied, not invented

The ten switch nodes and the thirty-two directed switch-to-switch edges are **byte-identical**
between the shipped 4-host and 128-host models -- verified, not assumed; see `check()`. So this
reads them out of an existing file and re-emits them untouched. Only hosts are generated.
Rewriting the fabric from a description of it would be a second source of truth for the part of
the model nobody is varying, and the failure mode for getting it subtly wrong is the one from
2026-08-17: every topology view reads correct while the fabric black-holes.

## Layout, read off the shipped models

  * Hosts live only on s1..s4. s5..s10 are transit. `ndt`'s `set_host_count` enforces the same
    rule ("must be a multiple of 4 and at least 4 (hosts split over s1-s4)").
  * Hosts go in contiguous blocks: with N hosts, s1 takes the first N/4, s2 the next, and so on.
  * Host ports start at 3 -- ports 1 and 2 are the switch's uplinks, which is what s1's
    `ecmp_groups` names.
  * h<i> is 10.0.0.<i> with mac <i>. Ryu keys the graph by `int_to_mac(mac)` and reads the
    address list from the node's `ip` field, so both must be unique per host.

## Refuses to write until it has reproduced both shipped models

`--hosts` runs `check()` first and exits non-zero if either round-trip differs. A generator for
a format this quiet -- a wrong port number produces a model that loads, validates and
mis-routes -- has to be checked against known-good output rather than against its own idea of
the format. Run `--check` alone to verify without generating.

Usage:
    tools/make_topology.py --check
    tools/make_topology.py --hosts 16 32 64
    tools/make_topology.py --hosts 16 --stdout
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SETTING = REPO / "setting"

#: The shipped models, and the host counts they carry. These are the round-trip fixtures.
KNOWN = {
    4: SETTING / "StaticNetworkTopologyOVS_10Switches_4Hosts.json",
    128: SETTING / "StaticNetworkTopologyMininet_10Switches.json",
}

SWITCH, HOST = 0, 1
EDGE_SWITCHES = (1, 2, 3, 4)  # dpids that carry hosts
FIRST_HOST_PORT = 3           # 1 and 2 are uplinks
HOST_LINK_BPS = 1_000_000_000


def load(path):
    with open(path) as fh:
        return json.load(fh)


def fabric_from(path):
    """(switch nodes, switch-to-switch edges) exactly as they appear in `path`."""
    topo = load(path)
    nodes = [n for n in topo["nodes"] if n and n.get("vertex_type") == SWITCH]
    edges = [e for e in topo["edges"]
             if e and e.get("src_dpid") and e.get("dst_dpid")]
    return nodes, edges


def switch_ip(switch_nodes, dpid):
    for n in switch_nodes:
        if n["dpid"] == dpid:
            return n["ip"]
    raise KeyError(f"no switch with dpid {dpid} in the fabric")


def build(hosts, switch_nodes, switch_edges):
    """A complete topology dict with `hosts` hosts on the given fabric."""
    if hosts < 4 or hosts % 4:
        raise ValueError(
            f"host count must be a multiple of 4 and at least 4 "
            f"(they split over s{EDGE_SWITCHES[0]}..s{EDGE_SWITCHES[-1]}); got {hosts}")

    per_switch = hosts // len(EDGE_SWITCHES)
    host_nodes, host_edges = [], []

    index = 0
    for dpid in EDGE_SWITCHES:
        sw_ip = switch_ip(switch_nodes, dpid)
        for slot in range(per_switch):
            index += 1
            ip = [f"10.0.0.{index}"]
            port = FIRST_HOST_PORT + slot
            host_nodes.append({
                "brand_name": "",
                "device_layer": 3,
                "device_name": f"h{index}",
                "nickname": f"h{index}",
                "dpid": 0,
                "ip": ip,
                "mac": index,
                "vertex_type": HOST,
            })
            # Emitted host-then-switch, in host order, matching the shipped models.
            host_edges.append({
                "src_dpid": 0, "src_interface": 1, "src_ip": ip,
                "dst_dpid": dpid, "dst_interface": port, "dst_ip": sw_ip,
                "link_bandwidth_bps": HOST_LINK_BPS,
            })
            host_edges.append({
                "src_dpid": dpid, "src_interface": port, "src_ip": sw_ip,
                "dst_dpid": 0, "dst_interface": 1, "dst_ip": ip,
                "link_bandwidth_bps": HOST_LINK_BPS,
            })

    return {"nodes": switch_nodes + host_nodes, "edges": switch_edges + host_edges}


def validate(topo, hosts):
    """Structural checks on generated output. Raises AssertionError with the first failure."""
    nodes = topo["nodes"]
    got = [n for n in nodes if n.get("vertex_type") == HOST]
    assert len(got) == hosts, f"expected {hosts} hosts, built {len(got)}"

    ips = [n["ip"][0] for n in got]
    macs = [n["mac"] for n in got]
    assert len(set(ips)) == hosts, "duplicate host IP"
    assert len(set(macs)) == hosts, "duplicate host mac"
    assert all(0 < m < 2 ** 48 for m in macs), "mac outside int_to_mac's range"

    # Every host: exactly one edge each way, and the pair agrees on the switch port.
    out_edges, in_edges = {}, {}
    for e in topo["edges"]:
        if e.get("src_dpid") == 0:
            out_edges.setdefault(e["src_ip"][0], []).append(e)
        elif e.get("dst_dpid") == 0:
            in_edges.setdefault(e["dst_ip"][0], []).append(e)
    for ip in ips:
        assert len(out_edges.get(ip, [])) == 1, f"{ip} has {len(out_edges.get(ip, []))} uplinks"
        assert len(in_edges.get(ip, [])) == 1, f"{ip} has {len(in_edges.get(ip, []))} downlinks"
        up, down = out_edges[ip][0], in_edges[ip][0]
        assert up["dst_dpid"] == down["src_dpid"], f"{ip} attached to two switches"
        assert up["dst_interface"] == down["src_interface"], f"{ip} port disagrees by direction"

    # A port collision is the 2026-08-17 failure: the model loads, every view reads correct,
    # and traffic goes to a port that belongs to someone else.
    used = {}
    for e in topo["edges"]:
        if e.get("dst_dpid") == 0:
            key = (e["src_dpid"], e["src_interface"])
            assert key not in used, (
                f"s{key[0]} port {key[1]} assigned to both {used[key]} and {e['dst_ip'][0]}")
            used[key] = e["dst_ip"][0]
        if e.get("src_dpid") and e.get("dst_dpid"):
            key = (e["src_dpid"], e["src_interface"])
            assert key not in used, (
                f"s{key[0]} port {key[1]} is an uplink and was also given to {used.get(key)}")
            used[key] = f"s{e['dst_dpid']}"


def same(a, b):
    """Compare two models by content, ignoring key order within objects."""
    def norm(t):
        return json.dumps({"nodes": t["nodes"], "edges": t["edges"]},
                          sort_keys=True, separators=(",", ":"))
    return norm(a) == norm(b)


def check(verbose=True):
    """Reproduce both shipped models from the fabric of the other one. True if both match."""
    ok = True
    # Cross-sourced deliberately: build the 4-host model from the 128-host file's fabric and
    # vice versa. Same-source would pass even if the two fabrics had silently diverged.
    for hosts, path in KNOWN.items():
        other = KNOWN[next(h for h in KNOWN if h != hosts)]
        nodes, edges = fabric_from(other)
        built = build(hosts, nodes, edges)
        shipped = load(path)
        match = same(built, shipped)
        ok &= match
        if verbose:
            print(f"  {'ok  ' if match else 'FAIL'} {hosts:>3} hosts: rebuilt from "
                  f"{other.name} == {path.name}")
        if not match and verbose:
            bn = {n["device_name"] for n in built["nodes"]}
            sn = {n["device_name"] for n in shipped["nodes"]}
            print(f"       nodes {len(built['nodes'])} vs {len(shipped['nodes'])}, "
                  f"edges {len(built['edges'])} vs {len(shipped['edges'])}")
            if bn ^ sn:
                print(f"       differing node names: {sorted(bn ^ sn)[:8]}")
    return bool(ok)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--hosts", type=int, nargs="+", metavar="N",
                    help="host counts to generate (multiples of 4)")
    ap.add_argument("--check", action="store_true",
                    help="only verify the round-trip against the shipped models")
    ap.add_argument("--stdout", action="store_true",
                    help="print instead of writing to setting/")
    ap.add_argument("--force", action="store_true",
                    help="overwrite an existing file")
    args = ap.parse_args()

    if not args.hosts and not args.check:
        ap.error("give --hosts, or --check")

    print("round-trip against the shipped models:")
    if not check():
        print("\nREFUSING TO GENERATE: this script no longer reproduces the shipped models, "
              "so its idea of the format is wrong. Fix that before trusting its output.")
        return 1
    if args.check and not args.hosts:
        return 0

    nodes, edges = fabric_from(KNOWN[128])
    print()
    for hosts in args.hosts:
        topo = build(hosts, nodes, edges)
        validate(topo, hosts)
        # 2-space indent, following the 128-host model; the 4-host one uses 4. Cosmetic, and
        # nothing reads these files by column.
        text = json.dumps(topo, indent=2) + "\n"

        if args.stdout:
            print(text)
            continue
        out = SETTING / f"StaticNetworkTopologyOVS_10Switches_{hosts}Hosts.json"
        if out.exists() and not args.force:
            print(f"  skip  {out.name} exists (--force to overwrite)")
            continue
        if hosts in KNOWN:
            print(f"  skip  {hosts} hosts already ships as {KNOWN[hosts].name}")
            continue
        out.write_text(text)
        pairs = hosts * (hosts - 1)
        print(f"  wrote {out.name}: {hosts} hosts, {pairs} ordered pairs, "
              f"{len(topo['edges'])} edges, {len(text):,} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
