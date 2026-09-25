"""Bits every p4_exercise tool needs: where the repo is, and how to read the package back.

[Co-developed with claude code -- Adam]

`topo_from_json` lives in `p4_proxy/mininet` and is imported by path, the same way
`tools/test_workflow/test_topo_from_json.py` already does it. That is deliberate: the reader
that checks a generated model must be the *same* reader the fabric and the proxy use, or the
check is a second opinion about a third thing. A copy here would drift, and the failure mode of
a drifted copy is a model that passes conversion and builds a different network.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
MININET_DIR = os.path.join(REPO, "p4_proxy", "mininet")

#: The package format this tool writes and reads. TICKET-P1 §1.
PACKAGE_FORMAT = 1

#: Stage one pins both of these; see TICKET-P1 §1. They are checked rather than assumed
#: because the fabric's port assignment lives in grpc_ports.py and nothing else ties the two
#: together -- the same "two copies of one number" shape F-15 was about.
REQUIRED_GRPC_BASE = 30050
REQUIRED_DEVICE_ID = "dpid"

#: Switch management addresses in the shipped models are 192.168.123.<10+dpid>. Not cosmetic:
#: the kernel's loader refuses a switch whose `ip` array is empty (TopologyAndFlowMonitor.cpp
#: "has an empty \"ip\" array"), and ten call sites do `ip.front()` without checking.
AGENT_IP_PREFIX = "192.168.123."
AGENT_IP_OFFSET = 10

#: What the shipped models put on a link when nothing says otherwise.
DEFAULT_LINK_BPS = 1000000000

#: The CPU port a package gets when no switch in the exercise names one. bmv2's own default and
#: the number ndtwin_switch.p4 compiles in (`const bit<9> CPU_PORT = 255`), so a package that
#: says nothing gets a fabric whose switches and whose pipeline agree.
#: [Co-developed with claude code -- Adam]
#: 🔴 NOT COSMETIC AND NOT GUESSABLE: `flowcache/topology.json` asks for 510 (as the STRING
#: "510"), and a switch launched on 255 while its program sends to 510 drops every controller
#: packet with nothing logged on either side.
DEFAULT_CPU_PORT = 255


def import_topo_from_json():
    """The proxy's model reader, imported by path rather than copied."""
    if MININET_DIR not in sys.path:
        sys.path.insert(0, MININET_DIR)
    import topo_from_json  # noqa: E402  (path has to be set first)

    return topo_from_json


def import_grpc_ports():
    """The fabric's gRPC port block, for the F-15 pre-check."""
    if MININET_DIR not in sys.path:
        sys.path.insert(0, MININET_DIR)
    import grpc_ports  # noqa: E402

    return grpc_ports


#: The proxy's root, for the one proxy module pre-flight shares. [Co-developed with claude code
#: -- Adam]
PROXY_DIR = os.path.join(REPO, "p4_proxy")


def import_app_package():
    """The proxy's package loader, imported by path -- for `parse_roles`, so pre-flight refuses a
    `roles` shape with the loader's own sentence (TICKET-P4-roles 2.1-4).
    [Co-developed with claude code -- Adam]"""
    if MININET_DIR not in sys.path:
        sys.path.insert(0, MININET_DIR)
    import app_package  # noqa: E402

    return app_package


def import_route_binding():
    """`p4_proxy/proxy_agent/route_binding`, imported by path.

    [Co-developed with claude code -- Adam]
    🔴 THE SAME FUNCTION THE PROXY RUNS (TICKET-P4-roles 2.1-4): `resolve()` is what the proxy
    calls when it builds each client, and a pre-flight with a copy of it would be a second
    opinion that is free to disagree -- and the disagreement would surface as a proxy that
    refuses to start on a package this tool passed. The module imports nothing from the proxy
    and no gRPC; only its match-type lookup touches protobuf.
    """
    if PROXY_DIR not in sys.path:
        sys.path.insert(0, PROXY_DIR)
    from proxy_agent import route_binding  # noqa: E402

    return route_binding


def agent_ip(dpid):
    """The management address a switch with this dpid gets in the generated model."""
    last = AGENT_IP_OFFSET + int(dpid)
    if not 1 <= last <= 254:
        raise ValueError(
            f"dpid {dpid} maps to {AGENT_IP_PREFIX}{last}, which is not a host address in "
            f"{AGENT_IP_PREFIX}0/24. The generated model gives every switch a management "
            f"address because the kernel's loader refuses a switch without one; a topology "
            f"this large needs a wider block chosen on purpose, not an address that wraps.")
    return f"{AGENT_IP_PREFIX}{last}"


def dumps(obj):
    """One JSON spelling, so two conversions of one exercise are byte-identical.

    sort_keys plus a fixed indent plus the trailing newline: the reproducibility test compares
    sha256, and an unordered dict would make that test pass or fail on dict insertion order.
    """
    return json.dumps(obj, indent=2, sort_keys=True) + "\n"


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def switch_name_to_dpid(name):
    """`s7` -> 7. The naming rule the whole stack already assumes (TICKET-P1 §1)."""
    if not (isinstance(name, str) and len(name) > 1 and name[0] == "s" and name[1:].isdigit()):
        raise ValueError(
            f"switch name {name!r} is not of the form sN. The dpid is read out of the name in "
            f"the fabric, the proxy and the model, so a name that does not carry one has no "
            f"dpid to be addressed by")
    dpid = int(name[1:])
    if dpid < 1:
        raise ValueError(f"switch {name!r} would have dpid {dpid}; dpids start at 1")
    return dpid


def host_index_from_ip(ip):
    """The number `topo_from_json.hosts()` will name this host after (`topo_from_json.py:86`)."""
    return int(str(ip).rsplit(".", 1)[-1])


def mac_to_int(mac):
    """`08:00:00:00:01:11` -> 8796093026577. The model stores an integer; `_mac_str` formats back."""
    text = str(mac).replace(":", "").replace("-", "")
    if len(text) != 12:
        raise ValueError(f"MAC {mac!r} is not 48 bits")
    return int(text, 16)
