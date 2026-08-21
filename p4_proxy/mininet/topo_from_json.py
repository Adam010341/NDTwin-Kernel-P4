"""Read a Mininet fabric's wiring out of the kernel's topology model.

[Co-developed with claude code -- Adam]

Why this exists. Until now the model and the fabric were two independent descriptions of the
same network: the kernel loaded `setting/StaticNetworkTopology*.json`, while the fabric was
built from literal `addLink` calls repeated in three files. Nothing checked that they agreed,
and when they disagreed the failure was silent -- see the 2026-08-21 round, where Ryu computed
routes for 128 hosts on a 4-host fabric and every topology view still read correct.

Deliberately NOT a Mininet dependency: this module only parses. The caller decides what to do
with the result, which is what lets the same reader serve the bmv2 topology, the OVS one and a
test that compares both against the hard-coded lists they replace.

What it does not do, on purpose:

  * It does not decide which switches to *power on*. The model is an inventory of what is
    installed -- a site that leaves switches unpowered still has them in the file, with their
    smart-plug address, because that is how they get turned back on. "Which are up" is runtime
    state (isUp / isEnabled / adminDisabled), not a property of the model, and conflating the
    two would mean expressing "switch is off" by deleting it from the twin.
  * It does not invent ports. Every port here is read from the file; a model that omits one is
    an error rather than something to paper over with a counter.
"""
import json

SWITCH = 0  # VertexType::SWITCH in include/common_types/GraphTypes.hpp
HOST = 1


def _first_ip(value):
    """Addresses in this model are lists (an interface may hold several). Take the first."""
    if isinstance(value, (list, tuple)):
        return value[0] if value else None
    return value


class TopologyModelError(ValueError):
    """The model cannot describe a buildable fabric. Raised rather than silently degraded."""


def load(path):
    with open(path) as fh:
        return json.load(fh)


def switches(model):
    """[(dpid, name)] sorted by dpid."""
    out = []
    for node in model.get("nodes", []):
        if not node or node.get("vertex_type") != SWITCH:
            continue
        dpid = node.get("dpid")
        if not dpid:
            raise TopologyModelError(f"switch node without a dpid: {node.get('device_name')!r}")
        # bridge_name is what the kernel matches Mininet on (it reads the same field); prefer it
        # so the fabric and the model cannot end up using different names for one switch.
        out.append((int(dpid), node.get("bridge_name") or node.get("device_name") or f"s{dpid}"))

    # [Co-developed with claude code -- Adam]
    # Two switches sharing a dpid is not a curiosity, it silently deletes links. Every lookup
    # downstream keys on dpid, so the second switch's cables collapse onto the first's: measured
    # 2026-08-21, a duplicate dpid took a 20-link fabric to 17 and removed a host's access link
    # entirely, with the build reporting success. Refused here, where it is one line, rather than
    # left to be discovered as missing connectivity.
    seen = {}
    for dpid, name in out:
        if dpid in seen:
            raise TopologyModelError(
                f"dpid {dpid} is claimed by two switches ({seen[dpid]!r} and {name!r}); "
                f"links and hosts are addressed by dpid, so one of them would lose its cabling")
        seen[dpid] = name
    return sorted(out)


def hosts(model):
    """[(name, ip, mac)] ordered by the host's address, which is how h<N> is numbered."""
    out = []
    for node in model.get("nodes", []):
        if not node or node.get("vertex_type") != HOST:
            continue
        ips = node.get("ip") or []
        if not ips:
            raise TopologyModelError(f"host node without an ip: {node.get('device_name')!r}")
        ip = ips[0]
        idx = int(str(ip).rsplit(".", 1)[-1])
        out.append((idx, f"h{idx}", ip, node.get("mac", 0)))
    out.sort()
    return [(name, ip, mac) for _idx, name, ip, mac in out]


def switch_links(model):
    """[(a_dpid, a_port, b_dpid, b_port)] once per physical link, lower dpid first.

    The model stores both directions; a fabric needs each cable once.
    """
    dpids = {d for d, _ in switches(model)}
    seen, out = set(), []
    for edge in model.get("edges", []):
        if not edge:
            continue
        s, d = edge.get("src_dpid"), edge.get("dst_dpid")
        sp, dp = edge.get("src_interface"), edge.get("dst_interface")
        if s not in dpids or d not in dpids:
            continue                      # host-facing, or an endpoint this model does not define
        if not (s and d and sp and dp):
            raise TopologyModelError(f"inter-switch edge missing a port: {edge}")
        key = tuple(sorted(((int(s), int(sp)), (int(d), int(dp)))))
        if key in seen:
            continue
        seen.add(key)
        out.append((key[0][0], key[0][1], key[1][0], key[1][1]))
    if not out:
        raise TopologyModelError("model declares no inter-switch links")
    return sorted(out)


def host_links(model):
    """[(host_name, switch_dpid, switch_port)] -- where each host plugs in."""
    dpids = {d for d, _ in switches(model)}
    by_ip = {ip: name for name, ip, _mac in hosts(model)}
    out = []
    for edge in model.get("edges", []):
        if not edge:
            continue
        s, d = edge.get("src_dpid"), edge.get("dst_dpid")
        # Host-facing edges carry dpid 0 on the host side and the host's address beside it.
        # `src_ip`/`dst_ip` are LISTS here, the same shape as a node's `ip` -- an interface can
        # hold several addresses. Both directions are stored, so each host appears twice.
        if s in dpids and not d:
            ip, port = _first_ip(edge.get("dst_ip")), edge.get("src_interface")
        elif d in dpids and not s:
            ip, port = _first_ip(edge.get("src_ip")), edge.get("dst_interface")
        else:
            continue
        name = by_ip.get(ip)
        if name is None or not port:
            continue
        out.append((name, int(s or d), int(port)))
    # One entry per host; the model stores both directions here too.
    dedup = sorted(set(out), key=lambda t: (int(t[0][1:]), t[1], t[2]))
    counts = {}
    for name, _dpid, _port in dedup:
        counts[name] = counts.get(name, 0) + 1
    doubled = [n for n, c in counts.items() if c > 1]
    if doubled:
        raise TopologyModelError(f"hosts attached more than once: {doubled[:5]}")
    return dedup
