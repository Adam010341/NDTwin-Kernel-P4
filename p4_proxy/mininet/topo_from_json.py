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
import glob
import json
import os
import sys

SWITCH = 0  # VertexType::SWITCH in include/common_types/GraphTypes.hpp
HOST = 1

#: Where the kernel's topology models live. Same derivation as p4_testbed_topo.py's SETTING_DIR
#: -- this file sits at the same depth -- so the two cannot end up scanning different directories.
SETTING_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), "setting")

#: The directive file that says how many hosts this fabric builds.
HOST_COUNT_OVERRIDE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "host_count_override")

#: What the fabric builds when nothing says otherwise.
DEFAULT_HOST_COUNT = 4


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

    The model stores both directions; a fabric needs each cable once. Empty is returned for a
    one-switch model and refused for any other -- see the comment at the bottom of the function.
    """
    dpids = {d for d, _ in switches(model)}
    seen, out = set(), []
    # [Co-developed with claude code -- Adam]
    # A switch port is one cable. Both directions of a cable are one key, so the same cable seen
    # twice is fine; a second DIFFERENT cable on an end already taken is a copy-pasted port
    # number, and building it would issue two addLink calls on one interface, which fail only
    # after `mn -c` has torn the running fabric down.
    owner = {}
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
        if key[0] == key[1]:
            raise TopologyModelError(
                f"switch {key[0][0]} port {key[0][1]} is cabled to itself; a port carries one cable "
                f"and a cable has two ends")
        for end in key:
            if end in owner:
                raise TopologyModelError(
                    f"switch {end[0]} port {end[1]} is used by two links: "
                    f"s{owner[end][0][0]} port {owner[end][0][1]} - "
                    f"s{owner[end][1][0]} port {owner[end][1][1]} and "
                    f"s{key[0][0]} port {key[0][1]} - s{key[1][0]} port {key[1][1]}")
        for end in key:
            owner[end] = key
        seen.add(key)
        out.append((key[0][0], key[0][1], key[1][0], key[1][1]))
    if not out:
        # [Co-developed with claude code -- Adam]
        # 🔴 ZERO CABLES IS A FACT ABOUT A ONE-SWITCH FABRIC AND A DEFECT IN ANY OTHER.
        # This raised unconditionally, which is right for the models it was written for: a
        # ten-switch fabric with no inter-switch edge is a file whose `edges` were dropped, and
        # building it would give ten islands that ping nothing while every topology view reads
        # correct. But `exercises/calc` -- and `basic_tunnel`, `load_balance`, `multicast`,
        # every single-switch exercise -- declares one switch and two hosts, and a switch has
        # nothing to be cabled TO. Refusing those said "this model is broken" about a model that
        # is complete, and the operator's only route past it was to invent a second switch.
        # The discriminator is the switch count, not the edge count.
        if len(dpids) == 1:
            return []
        raise TopologyModelError(
            f"model declares no inter-switch links, and it has {len(dpids)} switches "
            f"({sorted(dpids)}). Zero cables is legitimate for exactly one switch -- a "
            f"single-switch exercise has nothing to cable to -- and for two or more it means "
            f"the edges are missing: the fabric would come up as isolated islands, each one "
            f"healthy, forwarding nothing between them")
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
    # [Co-developed with claude code -- Adam]
    # Two hosts on one switch port, or a host on a port an inter-switch cable already uses.
    # The cable ends are read here directly (not through switch_links, whose "no cables" rule is
    # a different question), skipping the edges switch_links itself refuses.
    taken = {}
    for edge in model.get("edges", []):
        if not edge:
            continue
        s, d = edge.get("src_dpid"), edge.get("dst_dpid")
        sp, dp = edge.get("src_interface"), edge.get("dst_interface")
        if s in dpids and d in dpids and s and d and sp and dp:
            taken[(int(s), int(sp))] = f"the cable to s{int(d)} port {int(dp)}"
            taken[(int(d), int(dp))] = f"the cable to s{int(s)} port {int(sp)}"
    for name, dpid, port in dedup:
        if (dpid, port) in taken:
            raise TopologyModelError(
                f"switch {dpid} port {port} is used by two links: {taken[(dpid, port)]} and "
                f"host {name}")
        taken[(dpid, port)] = f"host {name}"
    return dedup


# --- who reads which model, and how many hosts it has -----------------------------------------
#
# [Co-developed with claude code -- Adam]
#
# These three were `_topology_model_path`, `_host_count_override` and `_mac_str` in
# p4_testbed_topo.py, which imports Mininet at module scope and therefore cannot be imported by
# the proxy or by a unit test that is not running as root. They moved here because the PROXY now
# needs the same three answers: it builds its host table from the model too (main.build_host_table),
# and a second implementation of "which file, how many hosts, what MAC" is precisely the shape
# that let the proxy know four hosts while the fabric built 128 -- the defect main.py's host-table
# comment describes. p4_testbed_topo keeps its old private names as one-line delegates so nothing
# that calls them has to move.
#
# This file still only parses: the model path is *chosen* here, nothing is built.


def mac_str(mac, name):
    """The model stores a host MAC as an integer; Mininet and the proxy want the colon form.

    Falls back to deriving it from the host index when the model has no MAC, which is what the
    formulas this replaced did. Note the proxy's old formula was `00:00:00:00:00:{i:02x}` and
    produced an invalid 7-digit address at i >= 256; formatting the integer as a 48-bit address
    is correct there instead. Nothing has ever run at that size.
    """
    try:
        value = int(mac)
    except (TypeError, ValueError):
        value = 0
    if value <= 0:
        value = int(name[1:]) if name[1:].isdigit() else 0
    return ":".join(f"{(value >> shift) & 0xFF:02x}" for shift in (40, 32, 24, 16, 8, 0))


def host_count_override(path=None):
    """How many hosts this fabric builds. Default 4; one directive line to change it.

    Same shape as the bmv2 binary override next to it: first non-comment, non-blank line wins,
    blank lines and #-comments ignored, and a malformed file is refused loudly rather than
    silently falling back -- a run that quietly built the wrong number of hosts would look
    exactly like a successful one.
    """
    path = path or HOST_COUNT_OVERRIDE_PATH
    if not os.path.exists(path):
        return DEFAULT_HOST_COUNT
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if not line.isdigit():
                raise ValueError(f"{path}: expected a host count, got {line!r}")
            return int(line)
    return DEFAULT_HOST_COUNT


def model_path(host_num, setting_dir=None, env=None):
    """The P4 model with this many hosts -- the same rule `ndt up` uses to pick one.

    Refuses rather than guessing: building a fabric the twin has no model for is the exact
    failure this reader exists to prevent, so an unmatched host count must stop the run instead
    of falling back to some other file.
    """
    setting_dir = SETTING_DIR if setting_dir is None else setting_dir
    env = os.environ if env is None else env
    override = env.get("NDTWIN_P4_TOPO_FILE")
    if override:
        if not os.path.exists(override):
            raise TopologyModelError(f"NDTWIN_P4_TOPO_FILE={override} does not exist")
        # [Co-developed with claude code -- Adam]
        # The override is checked against the host count too, not trusted on sight. It used to
        # return here immediately -- which made the docstring above a lie, and produced exactly
        # the mismatch this function exists to prevent: an override naming the 4-host model with
        # host_count_override at 128 built a 4-host fabric while the kernel was handed the
        # 128-host model, silently. Found by review, 2026-08-21.
        #
        # An explicit override still wins over the *scan*; what it cannot do is disagree with the
        # host count the rest of the run is using, because both sides read that count separately.
        try:
            declared = len(hosts(load(override)))
        except (OSError, ValueError, KeyError) as exc:
            raise TopologyModelError(
                f"NDTWIN_P4_TOPO_FILE={override} is not a usable topology model: {exc}") from exc
        if declared != host_num:
            raise TopologyModelError(
                f"NDTWIN_P4_TOPO_FILE={override} declares {declared} hosts but this run wants "
                f"{host_num} (from NDTWIN_P4_HOST_NUM or host_count_override). Point them at the "
                f"same size: the fabric would be built from the model while everything else "
                f"sizes itself from the count.")
        return override
    candidates = sorted(glob.glob(os.path.join(setting_dir, "StaticNetworkTopologyP4_*.json")))
    unreadable = []
    for path in candidates:
        try:
            if len(hosts(load(path))) == host_num:
                return path
        except (ValueError, KeyError) as exc:
            # Skipped, but counted: "no model has N hosts" reads as "you need to derive one",
            # which is the wrong instruction when the right model is sitting there unparseable.
            unreadable.append(f"{os.path.basename(path)} ({exc.__class__.__name__})")
    detail = f"; {len(unreadable)} could not be read: {', '.join(unreadable)}" if unreadable else ""
    raise TopologyModelError(
        f"no P4 topology model in {setting_dir} has {host_num} hosts "
        f"(looked at {len(candidates)}){detail}. Derive one with "
        f"tools/test_workflow/derive_p4_topology_json.py before building this fabric")


# --- are two models the same network ----------------------------------------------------------
#
# [Co-developed with claude code -- Adam]
#
# On the P4 plane the fabric is always built from the model in setting/ that has the asked-for
# host count (model_path above, in a process that never sees the operator's environment), while
# the kernel and the proxy's sFlow/LLDP view load whatever `NDT_TOPO` names. Comparing the two by
# host count alone let a different wiring with the same number of hosts through, and the twin
# then described a network that was not there. `network` reads out what the fabric would be built
# from, in a shape two models can be compared in; `network_diff` says, by switch and port, where
# two of them disagree.
#
# Compared: each switch's dpid, device_name, bridge name (the name switches() gives it: the fabric
# names a switch by it and the kernel addresses Mininet by it), brand_name and ip (the kernel
# attributes sFlow samples by that address); each cable as the pair of (dpid, port) ends, and
# whether a cable is stored in both directions or in one only (the kernel then holds one directed
# edge); each host's device_name, address, MAC and (dpid, port).
# NOT compared: declared link bandwidths, nicknames, ecmp_groups, smart-plug fields and every other
# field of a node or an edge that is not listed above -- the kernel reads some of them (ecmp_groups
# among them), so two models that differ only there are the same network HERE, not necessarily the
# same to the kernel.


def _switch_facts(model):
    """{dpid: (device_name, bridge name, brand_name, ip)} for the switch nodes.

    The bridge name is the one switches() gives the switch (bridge_name, else device_name, else
    s<dpid>); switches() also refuses a duplicate dpid or a switch without one, as the fabric does.
    """
    bridge = dict(switches(model))
    out = {}
    for node in model.get("nodes", []):
        if not node or node.get("vertex_type") != SWITCH:
            continue
        out[int(node["dpid"])] = (node.get("device_name"), bridge[int(node["dpid"])],
                                  node.get("brand_name"), _first_ip(node.get("ip")))
    return out


def _one_way_cables(model):
    """{(dpid, port): (dpid, port)} for each inter-switch edge stored in ONE direction only.

    A cable is stored as two edges, one per direction. The fabric builds the cable either way, but
    the kernel holds one directed edge for a cable stored once, so it is not the same network.
    """
    dpids = {d for d, _ in switches(model)}
    directed = set()
    for edge in model.get("edges", []):
        if not edge:
            continue
        s, d = edge.get("src_dpid"), edge.get("dst_dpid")
        sp, dp = edge.get("src_interface"), edge.get("dst_interface")
        if s in dpids and d in dpids and s and d and sp and dp:
            directed.add(((int(s), int(sp)), (int(d), int(dp))))
    return {src: dst for src, dst in directed if (dst, src) not in directed}


def network(model):
    """What a fabric built from `model` is made of, as plain comparable data.

    {"switches": {dpid: (device_name, bridge name, brand_name, ip)},
     "ends": {(dpid, port): (dpid, port)}                      every cable, from both of its ends,
     "one_way": {(dpid, port): (dpid, port)}                   the cables stored in one direction only
     "hosts": {address: (device_name, mac, (dpid, port))}}     (None where the host is not attached)

    Raises TopologyModelError for a model the fabric itself would refuse (two cables on one port,
    a host on a cabled port, no cables on a multi-switch model, ...): such a model describes no
    network that can exist.
    """
    ends = {}
    for a_dpid, a_port, b_dpid, b_port in switch_links(model):
        ends[(a_dpid, a_port)] = (b_dpid, b_port)
        ends[(b_dpid, b_port)] = (a_dpid, a_port)
    ip_of = {name: ip for name, ip, _mac in hosts(model)}
    attached = {ip_of[name]: (dpid, port) for name, dpid, port in host_links(model)}
    out_hosts = {}
    for node in model.get("nodes", []):
        if not node or node.get("vertex_type") != HOST:
            continue
        ip = (node.get("ip") or [None])[0]
        out_hosts[ip] = (node.get("device_name"), node.get("mac", 0), attached.get(ip))
    return {"switches": _switch_facts(model), "ends": ends, "one_way": _one_way_cables(model),
            "hosts": out_hosts}


def _label(a, b):
    """Short names for the two files a difference line is about: the base names, unless equal."""
    la, lb = os.path.basename(a), os.path.basename(b)
    return (a, b) if la == lb else (la, lb)


def _sw(dpid):
    return f"s{dpid}"


def _end(end):
    return "nothing" if end is None else f"{_sw(end[0])} port {end[1]}"


def _runs(dpids):
    """[1, 2, 3, 5] -> 's1..s3, s5'."""
    out, ds = [], sorted(dpids)
    i = 0
    while i < len(ds):
        j = i
        while j + 1 < len(ds) and ds[j + 1] == ds[j] + 1:
            j += 1
        out.append(_sw(ds[i]) if i == j else f"{_sw(ds[i])}..{_sw(ds[j])}")
        i = j + 1
    return ", ".join(out)


def _refused(path, exc):
    return f"not a model the fabric could build: {path}: {exc}"


def network_diff(a, b, limit=5):
    """Where the two model files describe different networks, as lines naming switch and port.

    Empty when they describe the same network (see the block comment above for what that
    means). At most `limit` differences are returned, then one `(+N more)` line when there were
    more. A file the fabric's own reader refuses is reported as `not a model the fabric could
    build: <file>: <its message>` and nothing else is said about it.
    """
    nets, bad = [], []
    for path in (a, b):
        try:
            nets.append(network(load(path)))
        except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError) as exc:
            bad.append(_refused(path, exc))
    if bad:
        return bad
    na, nb = nets
    la, lb = _label(a, b)
    found = []

    # Switches: one line per (field, value in a, value in b), the dpids that share it folded
    # into a range, so ten switches that differ in brand are one line and not ten.
    only = {"a": [], "b": []}
    groups = {}
    for dpid in sorted(set(na["switches"]) | set(nb["switches"])):
        fa, fb = na["switches"].get(dpid), nb["switches"].get(dpid)
        if fa is None or fb is None:
            only["a" if fb is None else "b"].append(dpid)
            continue
        for i, field in enumerate(("name", "bridge name", "brand", "ip")):
            if fa[i] != fb[i]:
                groups.setdefault((field, fa[i], fb[i]), []).append(dpid)
    for key, dpids in sorted(groups.items(), key=lambda kv: min(kv[1])):
        field, va, vb = key
        found.append((min(dpids), 0, f"{_runs(dpids)}: {field} {va} in {la}, {vb} in {lb}"))
    for side, name in (("a", la), ("b", lb)):
        if only[side]:
            found.append((min(only[side]), 0, f"{_runs(only[side])}: only in {name}"))

    # Cables, by the end that differs: sorted by switch and port, so the lowest switch is first.
    for end in sorted(set(na["ends"]) | set(nb["ends"])):
        pa, pb = na["ends"].get(end), nb["ends"].get(end)
        if pa != pb:
            found.append((end[0], end[1],
                          f"{_sw(end[0])} port {end[1]}: {_end(pa)} in {la}, {_end(pb)} in {lb}"))

    # A cable stored in one direction only, in either model: named by the end it is stored from.
    for src in sorted(set(na["one_way"]) | set(nb["one_way"])):
        wa, wb = na["one_way"].get(src), nb["one_way"].get(src)
        if wa != wb:
            side = la if wa is not None else lb
            dst = wa if wa is not None else wb
            found.append((src[0], src[1], f"{_sw(src[0])} port {src[1]} -> {_end(dst)}: "
                                          f"stored in one direction only in {side}"))

    # Hosts, by address.
    for ip in sorted(set(na["hosts"]) | set(nb["hosts"]),
                     key=lambda v: [int(x) if str(x).isdigit() else 0 for x in str(v).split(".")]):
        ha, hb = na["hosts"].get(ip), nb["hosts"].get(ip)
        if ha is None or hb is None:
            found.append((1 << 30, 0, f"host {ip}: only in {la if hb is None else lb}"))
            continue
        if ha[0] != hb[0]:
            found.append((1 << 30, 0, f"host {ip}: named {ha[0]} in {la}, {hb[0]} in {lb}"))
        if _mac_value(ha[1]) != _mac_value(hb[1]):
            found.append((1 << 30, 0, f"host {ip}: MAC {mac_str(ha[1], str(ha[0]))} in {la}, "
                                      f"{mac_str(hb[1], str(hb[0]))} in {lb}"))
        if ha[2] != hb[2]:
            found.append((1 << 30, 0, f"host {ip}: on {_end(ha[2])} in {la}, {_end(hb[2])} in {lb}"))

    found.sort(key=lambda t: (t[0], t[1]))
    lines = [t[2] for t in found[:limit]]
    if len(found) > limit:
        lines.append(f"(+{len(found) - limit} more)")
    return lines


def _mac_value(mac):
    try:
        return int(mac)
    except (TypeError, ValueError):
        return mac


# --- the same two questions, for `ndt` --------------------------------------------------------
#
# `ndt` has to ask which model the fabric will be built from and whether NDT_TOPO names the same
# network, before it builds anything. It asks this module, so the answer is the fabric's own and
# not a second copy of the rule in shell. Run as `python3 -I -B topo_from_json.py <command>`:
#
#   fabric-model <setting dir> <host count>   the model path on stdout, rc 0; nothing on stdout (still
#                                             rc 0) when no model in the directory has that many
#                                             hosts, and also when the one that does cannot be read
#   diff <model a> <model b>                  the lines of network_diff on stdout; rc 0 when the two
#                                             describe the same network, 1 when they do not -- and
#                                             1 as well, with a traceback on stderr, when the
#                                             comparison itself raises an exception nobody expected
# Any other use is rc 2 with a sentence on stderr.


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "fabric-model" and len(argv) == 4 and argv[3].isdigit():
        try:
            print(model_path(int(argv[3]), setting_dir=argv[2], env={}))
        except TopologyModelError:
            pass
        return 0
    if cmd == "diff" and len(argv) == 4:
        lines = network_diff(argv[2], argv[3])
        for line in lines:
            print(line)
        return 1 if lines else 0
    print("usage: topo_from_json.py fabric-model <setting dir> <host count> | "
          "diff <model a> <model b>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
