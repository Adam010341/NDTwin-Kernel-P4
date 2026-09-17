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
