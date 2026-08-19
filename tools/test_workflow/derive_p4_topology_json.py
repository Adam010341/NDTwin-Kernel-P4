"""Derive a P4 topology model from the OVS one of the same size.

The kernel's static model is per-topology, and the only P4 model that exists is the 4-host
one -- so a P4 run at any other host count has no model to load. The two families turned out
to differ in exactly one field: switch nodes carry `brand_name` "OVS" or "BMv2", and every
other key, the host nodes and all 288 edges are byte-identical in structure. So the P4 model
for a given size is derivable rather than hand-written, which also removes the chance of the
two drifting apart.

Verified 2026-08-19 by comparing StaticNetworkTopologyP4_10Switches_4Hosts.json against
StaticNetworkTopologyMininet_10Switches.json: the only differing key on a switch node is
`brand_name`.

Usage:  python derive_p4_topology_json.py <ovs.json> <out-p4.json>

[Co-developed with claude code -- Adam]
"""
import json
import sys

SWITCH = 0  # vertex_type for a switch


def derive(src, dst):
    with open(src) as fh:
        model = json.load(fh)

    switches = 0
    for node in model["nodes"]:
        if node.get("vertex_type") == SWITCH:
            if node.get("brand_name") != "OVS":
                raise SystemExit(
                    f"refusing: switch {node.get('device_name')} has brand_name "
                    f"{node.get('brand_name')!r}, expected 'OVS' -- is {src} really the OVS model?"
                )
            node["brand_name"] = "BMv2"
            switches += 1

    if not switches:
        raise SystemExit(f"refusing: no switch nodes (vertex_type={SWITCH}) found in {src}")

    with open(dst, "w") as fh:
        json.dump(model, fh, indent=4)

    hosts = len(model["nodes"]) - switches
    print(f"{dst}: {switches} switches -> BMv2, {hosts} hosts, {len(model['edges'])} edges")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    derive(sys.argv[1], sys.argv[2])
