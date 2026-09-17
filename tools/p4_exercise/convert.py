#!/usr/bin/env python3
"""Turn a p4lang-tutorials exercise into an NDTwin P4 app package (TICKET-P1 §1, §3).

[Co-developed with claude code -- Adam]

    tools/p4_exercise/convert.py <exercise_dir> --topology pod-topo/topology.json \
        [--p4 solution/basic.p4] --out <package_dir>

What comes out:

    <package_dir>/package.json           the contract of TICKET-P1 §1
    <package_dir>/ndtwin/topology.json   an NDTwin topology model, same schema as
                                         setting/StaticNetworkTopologyP4_10Switches_4Hosts.json
    <package_dir>/<exercise-relative copies of every file package.json names>

🔴 WHY THE COPIES KEEP THEIR EXERCISE-RELATIVE PATHS. A tutorials `sX-runtime.json` names its
own p4info and bmv2 json with paths like `build/basic.p4.p4info.txtpb`, and tutorials resolves
them against the *current working directory*, which for `make run` is the exercise directory
(`utils/run_exercise.py:278`, `workdir=os.getcwd()`). Copy `pod-topo/s1-runtime.json` to
`<package_dir>/pod-topo/s1-runtime.json` and `build/basic.p4.p4info.txtpb` to
`<package_dir>/build/basic.p4.p4info.txtpb` and those interior paths resolve unchanged with the
package directory as the new root -- so the runtime files are byte-identical copies rather than
rewritten ones, and the package does not depend on ~/tutorials still being there. It also makes
the two path conventions in §1 (paths relative to package_dir; example values that are
exercise-relative, e.g. "pod-topo/s1-runtime.json") the same string.

What it deliberately does NOT do:

  * It does not invent a pipeline. `switches[*].pipeline` is null in stage one, which the
    reader turns into NDTwin's own artefact; G4 is a later stage and pre-flight refuses
    anything else rather than pretending.
  * It does not apply link shaping. tutorials' optional latency/bandwidth elements are
    recorded on the package's `links` and nothing acts on them yet (G2-C, stage three).
  * It does not guess a prefix length. A tutorials host address without one is refused -- an
    assumed /24 is exactly the silent default that makes a wrong fabric look built.
"""
import argparse
import os
import shutil
import sys

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from p4_exercise import common
else:
    from . import common


class ConversionError(ValueError):
    """The exercise cannot be expressed as a package. Refused, never degraded."""


# --- reading the tutorials side ------------------------------------------------------------

def parse_endpoint(node):
    """`h1` -> ('host', 'h1', 1); `s1-p3` -> ('switch', 's1', 3).

    Host port 1: a tutorials host has exactly one interface and the shipped NDTwin models put
    `src_interface: 1` on the host side of every access link.
    """
    if not isinstance(node, str) or not node:
        raise ConversionError(f"link endpoint {node!r} is not a node name")
    if "-" in node:
        name, port = node.split("-", 1)
        if not (port.startswith("p") and port[1:].isdigit()):
            raise ConversionError(
                f"link endpoint {node!r}: the part after '-' should be pN (a switch port); "
                f"tutorials' own parser asserts the same thing "
                f"(utils/run_exercise.py parse_switch_node)")
        common.switch_name_to_dpid(name)
        return ("switch", name, int(port[1:]))
    if node[0] == "h":
        return ("host", node, 1)
    raise ConversionError(
        f"link endpoint {node!r} names neither a host (hN) nor a switch port (sN-pM)")


def parse_links(raw_links):
    """tutorials `links` -> [(end_a, end_b, latency_ms_or_None, bandwidth_mbps_or_None)].

    🔴 The optional elements are [latency, bandwidth] IN THAT ORDER, not bandwidth first:
    `utils/run_exercise.py:212-232` reads `link[2]` as latency and `link[3]` as bandwidth, and
    the two exercises that use them (ecn, mri) spell it `["s1-p3", "s2-p3", "0", 0.5]` -- a
    0.5 Mbit/s link with no added delay. Getting this backwards would silently produce a
    500 Mbit/s link in a package whose whole point is a bottleneck.
    """
    out = []
    for raw in raw_links:
        if not isinstance(raw, (list, tuple)) or len(raw) < 2:
            raise ConversionError(f"link {raw!r} needs at least two endpoints")
        a, b = parse_endpoint(raw[0]), parse_endpoint(raw[1])
        latency = _latency_ms(raw[2]) if len(raw) > 2 else None
        bandwidth = float(raw[3]) if len(raw) > 3 and raw[3] is not None else None
        if a[0] == "host" and b[0] == "host":
            raise ConversionError(f"link {raw!r} joins two hosts; a host attaches to a switch")
        # Hosts first, so the package's `links` entries read the way TICKET-P1 §1 spells them.
        if b[0] == "host":
            a, b = b, a
        out.append((a, b, latency, bandwidth))
    return out


def _latency_ms(value):
    """tutorials writes a latency either as a number of ms or as a string like '0.05ms'."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    for suffix, scale in (("ms", 1.0), ("us", 0.001), ("s", 1000.0)):
        if text.endswith(suffix):
            return float(text[: -len(suffix)]) * scale
    return float(text)


def parse_hosts(raw_hosts):
    """tutorials `hosts` -> {name: {ip, prefix_len, mac, commands}} with the naming rule checked."""
    out = {}
    for name in sorted(raw_hosts):
        spec = raw_hosts[name] or {}
        raw_ip = spec.get("ip")
        if not raw_ip:
            raise ConversionError(f"host {name!r} has no ip")
        if "/" not in str(raw_ip):
            raise ConversionError(
                f"host {name!r} has ip {raw_ip!r} with no prefix length. Refused rather than "
                f"assumed to be /24: the prefix decides which addresses the host thinks are "
                f"on-link, and a wrong one shows up as a partial pingall, not as an error")
        addr, prefix = str(raw_ip).split("/", 1)
        if not prefix.isdigit() or not 0 <= int(prefix) <= 32:
            raise ConversionError(f"host {name!r}: {prefix!r} is not an IPv4 prefix length")
        mac = spec.get("mac")
        if not mac:
            raise ConversionError(f"host {name!r} has no mac")
        common.mac_to_int(mac)
        # 🔴 The naming rule, checked at the one moment it can still be fixed. The proxy's
        # reader does not read `device_name` for a host -- it *derives* h<N> from the last
        # octet of the address (topo_from_json.py:86). So a tutorials host called h1 on
        # 10.0.0.7 does not fail anywhere: it silently becomes h7, and every later cross
        # reference (the package's own `hosts` map, the exercise's runtime entries, the
        # commands) is then about a host that is not there.
        expected = f"h{common.host_index_from_ip(addr)}"
        if name != expected:
            raise ConversionError(
                f"host {name!r} has address {addr}, and the fabric names hosts after the last "
                f"octet of their address (topo_from_json.hosts, p4_proxy/mininet/"
                f"topo_from_json.py:86) -- so this host would be built as {expected!r}. Rename "
                f"the host or renumber it; a package whose host names do not survive the "
                f"round trip cannot address its own hosts")
        out[name] = {
            "ip": addr,
            "prefix_len": int(prefix),
            "mac": str(mac),
            "commands": list(spec.get("commands") or []),
        }
    return out


def parse_switches(raw_switches):
    """tutorials `switches` -> {dpid: {name, entries_rel}} (entries_rel may be None)."""
    out = {}
    for name in sorted(raw_switches):
        spec = raw_switches[name] or {}
        dpid = common.switch_name_to_dpid(name)
        if dpid in out:
            raise ConversionError(f"two switches claim dpid {dpid}")
        if "cli_input" in spec:
            raise ConversionError(
                f"switch {name!r} is configured through the bmv2 CLI (`cli_input`), which this "
                f"package format does not carry. Only `runtime_json` (P4Runtime) is supported")
        out[dpid] = {"name": name, "entries": spec.get("runtime_json")}
    return out


# --- writing the NDTwin side ---------------------------------------------------------------

def switch_node(dpid, name):
    """One switch, with the twelve keys the shipped 4-host P4 model uses and no more.

    `ecmp_groups: []`, not a fabricated group. Evidence that an empty list is accepted, not a
    guess: the file loader reads it with `nodeJson.value("ecmp_groups", std::vector<EcmpGroup>{})`
    (TopologyAndFlowMonitor.cpp:769 and :1384) and its own comment records that two of the
    thirteen shipped topology files carry no such key at all; the only thing done with the
    contents is a per-member port range check, which an empty list passes by having nothing to
    check. `get_graph_data`'s baseline diff allowlist already covers switches whose group list
    is empty. An invented group would be a claim about how this exercise's program forwards,
    and a converted tutorials program does not do ECMP at all.
    """
    return {
        "brand_name": "BMv2",
        "bridge_name": name,
        "device_layer": 2,
        "device_name": name,
        "dpid": dpid,
        "ecmp_groups": [],
        "ip": [common.agent_ip(dpid)],
        "mac": 0,
        "nickname": name,
        "smart_plug_ip": "",
        "smart_plug_outlet": 0,
        "vertex_type": 0,
    }


def host_node(name, host):
    """One host, with the eight keys the shipped model uses for a host (no smart plug, no brand)."""
    return {
        "brand_name": "",
        "device_layer": 3,
        "device_name": name,
        "dpid": 0,
        "ip": [host["ip"]],
        "mac": common.mac_to_int(host["mac"]),
        "nickname": name,
        "vertex_type": 1,
    }


def _edge(src_dpid, src_if, src_ip, dst_dpid, dst_if, dst_ip, bps):
    return {
        "src_dpid": src_dpid,
        "src_interface": src_if,
        "src_ip": [src_ip],
        "dst_dpid": dst_dpid,
        "dst_interface": dst_if,
        "dst_ip": [dst_ip],
        "link_bandwidth_bps": bps,
    }


def build_model(hosts, switches, links):
    """The NDTwin topology model for this exercise.

    🔴 EVERY EDGE IS STORED TWICE, once per direction. That is not redundancy to be tidied
    away: `topo_from_json.host_links()` finds a host through whichever direction has the host's
    dpid falsy (`topo_from_json.py:127-133`), and the kernel's own shipped models all store
    both. Emitting one direction leaves half the reads finding nothing -- and finding nothing
    is spelled `continue`, not an error, so the fabric comes up with links missing.
    """
    nodes = [switch_node(dpid, switches[dpid]["name"]) for dpid in sorted(switches)]
    nodes += [host_node(name, hosts[name]) for name in sorted(hosts, key=_host_sort_key)]

    edges = []
    for a, b, _latency, bandwidth in links:
        bps = int(bandwidth * 1e6) if bandwidth is not None else common.DEFAULT_LINK_BPS
        _kind_b, b_name, b_port = b
        b_dpid = common.switch_name_to_dpid(b_name)
        b_ip = common.agent_ip(b_dpid)
        if a[0] == "host":
            host = hosts.get(a[1])
            if host is None:
                raise ConversionError(f"link names host {a[1]!r}, which the topology does not declare")
            edges.append(_edge(0, a[2], host["ip"], b_dpid, b_port, b_ip, bps))
            edges.append(_edge(b_dpid, b_port, b_ip, 0, a[2], host["ip"], bps))
        else:
            a_dpid = common.switch_name_to_dpid(a[1])
            a_ip = common.agent_ip(a_dpid)
            edges.append(_edge(a_dpid, a[2], a_ip, b_dpid, b_port, b_ip, bps))
            edges.append(_edge(b_dpid, b_port, b_ip, a_dpid, a[2], a_ip, bps))

    # `links` is a top-level key in every shipped model and is empty in all of them.
    return {"nodes": nodes, "edges": edges, "links": []}


def _host_sort_key(name):
    return (int(name[1:]) if name[1:].isdigit() else 1 << 30, name)


# --- putting a package together --------------------------------------------------------------

def _p4_stem(p4_rel):
    return os.path.splitext(os.path.basename(p4_rel))[0]


def plan(exercise_dir, topology_rel, p4_rel=None, name=None, mode="auto"):
    """Everything the package will contain, without writing anything.

    Returns (package_dict, model_dict, copies) where copies is [(abs_source, package_rel_dest)].
    Separated from the writing so the tests can exercise the whole conversion in memory.
    """
    exercise_dir = os.path.abspath(exercise_dir)
    if not os.path.isdir(exercise_dir):
        raise ConversionError(f"no exercise directory at {exercise_dir}")
    topo_path = os.path.join(exercise_dir, topology_rel)
    if not os.path.isfile(topo_path):
        raise ConversionError(f"no topology at {topo_path}")

    topo = common.load_json(topo_path)
    hosts = parse_hosts(topo.get("hosts") or {})
    switches = parse_switches(topo.get("switches") or {})
    links = parse_links(topo.get("links") or [])
    if not hosts:
        raise ConversionError("the topology declares no hosts")
    if not switches:
        raise ConversionError("the topology declares no switches")

    _check_link_endpoints(hosts, switches, links)

    if mode == "auto":
        mode = "external" if os.path.isfile(os.path.join(exercise_dir, "mycontroller.py")) else "ndtwin"
    if mode not in ("ndtwin", "external"):
        raise ConversionError(f"control plane mode {mode!r} is neither 'ndtwin' nor 'external'")

    copies = [(topo_path, topology_rel)]

    pkg_switches = {}
    for dpid in sorted(switches):
        entries_rel = switches[dpid]["entries"]
        if entries_rel:
            entries_abs = os.path.join(exercise_dir, entries_rel)
            if not os.path.isfile(entries_abs):
                raise ConversionError(
                    f"switch {switches[dpid]['name']} names runtime entries {entries_rel!r}, "
                    f"which is not at {entries_abs}")
            copies.append((entries_abs, entries_rel))
            copies.extend(_runtime_json_dependencies(exercise_dir, entries_abs, entries_rel))
        pkg_switches[str(dpid)] = {
            "name": switches[dpid]["name"],
            # Stage one: NDTwin's own artefact, always. Pre-flight refuses anything else with
            # "G4 not done" rather than loading a pipeline nothing downstream can push.
            "pipeline": None,
            "entries": entries_rel,
        }

    source = {
        "kind": "p4lang-tutorials",
        "exercise_dir": exercise_dir,
        "topology_json": topology_rel,
        "p4": p4_rel,
        # Recorded, not required by the reader: with `control_plane.mode: external` there are
        # no runtime entries and therefore no file naming a p4info, and pre-flight still has to
        # be able to parse one. Derived from the .p4's name the way the exercises' Makefiles
        # do; left null when the exercise has not been built, never pointed at a file that is
        # not there.
        "p4info": None,
        "bmv2_json": None,
        "controller": "mycontroller.py" if mode == "external" else None,
    }
    if p4_rel:
        p4_abs = os.path.join(exercise_dir, p4_rel)
        if not os.path.isfile(p4_abs):
            raise ConversionError(f"--p4 {p4_rel!r} is not at {p4_abs}")
        copies.append((p4_abs, p4_rel))
        stem = _p4_stem(p4_rel)
        for key, rel in (("p4info", f"build/{stem}.p4.p4info.txtpb"),
                         ("bmv2_json", f"build/{stem}.json")):
            abs_path = os.path.join(exercise_dir, rel)
            if os.path.isfile(abs_path):
                source[key] = rel
                copies.append((abs_path, rel))
    if mode == "external":
        controller_abs = os.path.join(exercise_dir, "mycontroller.py")
        if not os.path.isfile(controller_abs):
            raise ConversionError(
                "control plane mode is 'external' but the exercise has no mycontroller.py; "
                "external means the exercise brings its own controller")

    package = {
        "format": common.PACKAGE_FORMAT,
        "name": name or os.path.basename(exercise_dir),
        "source": source,
        "topology": "ndtwin/topology.json",
        "hosts": hosts,
        "switches": pkg_switches,
        "control_plane": {
            "mode": mode,
            # (0, 65535) rather than the baseline's (0, 1): an impostor that claims (0, 1) then
            # loses the election and is refused with PERMISSION_DENIED instead of taking
            # mastership and clearing the tables (p4_client.py:60-74, measured 08-13).
            "election_id": [0, 65535],
            "grpc_base": common.REQUIRED_GRPC_BASE,
            "device_id": common.REQUIRED_DEVICE_ID,
        },
        "bmv2": {"cpu_port": 255},
        "links": [_package_link(a, b, latency, bandwidth) for a, b, latency, bandwidth in links],
    }
    model = build_model(hosts, switches, links)
    return package, model, _dedup_copies(copies)


def _package_link(a, b, latency, bandwidth):
    entry = {
        "a": [a[1], a[2]],
        "b": [b[1], b[2]],
        "bandwidth_bps": int(bandwidth * 1e6) if bandwidth is not None else common.DEFAULT_LINK_BPS,
    }
    # Only present when the exercise declared one, so a package for an exercise that says
    # nothing about delay does not claim 0 ms as a measured fact.
    if latency is not None:
        entry["delay_ms"] = latency
    return entry


def _check_link_endpoints(hosts, switches, links):
    names = {s["name"] for s in switches.values()}
    attached = {}
    for a, b, _lat, _bw in links:
        for kind, name, _port in (a, b):
            if kind == "switch" and name not in names:
                raise ConversionError(f"a link names switch {name!r}, which the topology does not declare")
            if kind == "host":
                if name not in hosts:
                    raise ConversionError(f"a link names host {name!r}, which the topology does not declare")
                attached[name] = attached.get(name, 0) + 1
    doubled = sorted(n for n, c in attached.items() if c > 1)
    if doubled:
        # topo_from_json.host_links() raises on this too; caught here so the message names the
        # exercise file rather than the generated model.
        raise ConversionError(f"hosts attached more than once: {doubled}")
    missing = sorted(set(hosts) - set(attached))
    if missing:
        raise ConversionError(f"hosts with no link: {missing}")


def _runtime_json_dependencies(exercise_dir, entries_abs, entries_rel):
    """The p4info and bmv2 json a tutorials runtime file names, as (abs, package_rel) copies.

    The interior paths are kept exactly as written, so they resolve against the package
    directory the way they resolve against the exercise directory today -- see the module
    docstring.
    """
    conf = common.load_json(entries_abs)
    out = []
    for key in ("p4info", "bmv2_json"):
        rel = conf.get(key)
        if not rel:
            continue
        if os.path.isabs(rel):
            raise ConversionError(
                f"{entries_rel} names an absolute {key} ({rel!r}); the package keeps these "
                f"paths as written so they must be relative to the exercise directory")
        abs_path = os.path.join(exercise_dir, rel)
        if not os.path.isfile(abs_path):
            raise ConversionError(
                f"{entries_rel} names {key} {rel!r}, which is not at {abs_path}. Build the "
                f"exercise first (`make` in {exercise_dir}) -- a package that names a p4info "
                f"it does not carry cannot be pre-flighted")
        out.append((abs_path, rel))
    return out


def _dedup_copies(copies):
    seen, out = set(), []
    for abs_src, rel in copies:
        if rel in seen:
            continue
        seen.add(rel)
        out.append((abs_src, rel))
    return sorted(out, key=lambda t: t[1])


def read_back(model):
    """Read the generated model with the proxy's own reader; raise if any of the four refuse.

    This is the check that matters: a model that convert.py is happy with and topo_from_json
    cannot read is a file, not a topology.
    """
    T = common.import_topo_from_json()
    try:
        return {
            "switches": T.switches(model),
            "hosts": T.hosts(model),
            "switch_links": T.switch_links(model),
            "host_links": T.host_links(model),
        }
    except T.TopologyModelError as exc:
        raise ConversionError(
            f"the generated model does not read back through p4_proxy/mininet/"
            f"topo_from_json.py, which is the reader the fabric and the proxy use: {exc}") from exc


def write(out_dir, package, model, copies):
    """Write the package. Returns the list of files written, package-relative."""
    out_dir = os.path.abspath(out_dir)
    os.makedirs(os.path.join(out_dir, "ndtwin"), exist_ok=True)
    written = []
    for abs_src, rel in copies:
        dest = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(abs_src, dest)
        written.append(rel)
    with open(os.path.join(out_dir, "ndtwin", "topology.json"), "w", encoding="utf-8") as fh:
        fh.write(common.dumps(model))
    written.append("ndtwin/topology.json")
    with open(os.path.join(out_dir, "package.json"), "w", encoding="utf-8") as fh:
        fh.write(common.dumps(package))
    written.append("package.json")
    return sorted(written)


def convert(exercise_dir, topology_rel, out_dir, p4_rel=None, name=None, mode="auto"):
    package, model, copies = plan(exercise_dir, topology_rel, p4_rel=p4_rel, name=name, mode=mode)
    read_back(model)
    return package, model, write(out_dir, package, model, copies)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("exercise_dir")
    ap.add_argument("--topology", required=True,
                    help="the tutorials topology.json, relative to exercise_dir")
    ap.add_argument("--p4", default=None, help="the .p4 program, relative to exercise_dir")
    ap.add_argument("--out", required=True, help="package directory to create")
    ap.add_argument("--name", default=None, help="package name (default: the exercise directory's)")
    ap.add_argument("--mode", default="auto", choices=("auto", "ndtwin", "external"),
                    help="control plane mode; auto = external when the exercise has a mycontroller.py")
    args = ap.parse_args(argv)

    try:
        package, model, written = convert(args.exercise_dir, args.topology, args.out,
                                          p4_rel=args.p4, name=args.name, mode=args.mode)
    except ConversionError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1

    n_sw = len([n for n in model["nodes"] if n["vertex_type"] == 0])
    n_h = len([n for n in model["nodes"] if n["vertex_type"] == 1])
    print(f"package '{package['name']}' -> {os.path.abspath(args.out)}")
    print(f"  control plane : {package['control_plane']['mode']}")
    print(f"  model         : {n_sw} switches, {n_h} hosts, {len(model['edges'])} edges "
          f"({len(model['edges']) // 2} links, both directions stored)")
    print(f"  files         : {len(written)}")
    for rel in written:
        print(f"                  {rel}")
    print("  read back through p4_proxy/mininet/topo_from_json.py: ok")
    print("  next: tools/p4_exercise/preflight.py " + os.path.abspath(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
