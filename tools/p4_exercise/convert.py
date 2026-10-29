#!/usr/bin/env python3
"""Turn a p4lang-tutorials exercise into an NDTwin P4 app package.

[Co-developed with claude code -- Adam]

    tools/p4_exercise/convert.py <exercise_dir> --topology pod-topo/topology.json \
        [--p4 solution/basic.p4] --out <package_dir> \
        [--role-ipv4-route [owner=package,]table=MyIngress.ipv4_lpm,match_field=hdr.ipv4.dstAddr,\
                           action=MyIngress.ipv4_forward,dst_mac=dstAddr,port=port
         | --auto-role] [--table-owner package|ndtwin]

`ndt up p4 --app <exercise dir>` runs this for you (through one_step.py, with --auto-role) and
then pre-flight and the bring-up; calling it by hand is for a package you want to keep or edit.

What comes out:

    <package_dir>/package.json           the package format's contract
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

  * It does not invent a pipeline. `switches[*].pipeline` names only artefacts the exercise
    has ALREADY been built into (`make build`), copied into the package beside the runtime files
    it already copies; an unbuilt exercise is refused with that command rather than converted
    into a package naming files that are not there. With no `--p4` -- and with
    `--ndtwin-pipeline` -- every switch is `null`, which the reader turns into NDTwin's own
    artefact.
  * It does not apply link shaping. tutorials' optional latency/bandwidth elements are
    recorded on the package's `links` and nothing acts on them yet (G2-C, stage three).
  * It does not guess a prefix length. A tutorials host address without one is refused -- an
    assumed /24 is exactly the silent default that makes a wrong fabric look built.
"""
import argparse
import json
import os
import re
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
        # Hosts first, so the package's `links` entries read the way the package format spells them.
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
    """tutorials `switches` -> {dpid: {name, entries, program}} (both may be None).

    🔴 `program` IS READ, NOT DROPPED. It is tutorials' per-switch pipeline override --
    `utils/run_exercise.py:76-79` passes it to the switch as `json_path` -- and exactly one of
    the thirteen shipped exercises uses it: firewall's pod-topo puts `build/firewall.json` on
    s1 and leaves s2-s4 on the Makefile's `DEFAULT_PROG basic.p4`. A converter that threw the
    field away produced a package whose four switches all run one program, i.e. an exercise
    whose whole point (traffic crosses a firewall on the way to the others) cannot happen,
    while every switch comes up and forwards.
    """
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
        program = spec.get("program")
        if program is not None and not (isinstance(program, str) and program):
            raise ConversionError(
                f"switch {name!r} has a 'program' that is not a path: {program!r}")
        out[dpid] = {"name": name, "entries": spec.get("runtime_json"), "program": program,
                     "cpu_port": _cpu_port(name, spec)}
    return out


def _cpu_port(name, spec):
    """tutorials `switches[s].cpu_port` as an int, or None when the switch does not name one.

    [Co-developed with claude code -- Adam]
    🔴 IT IS A STRING IN AT LEAST ONE SHIPPED EXERCISE. `flowcache/topology.json` writes
    `"cpu_port": "510"`, and tutorials' own reader passes it straight to the switch's argv where
    it becomes a string on a command line and works. A package reader wants a number
    (`app_package` validates 0..511 as an int), so the conversion happens here rather than
    being discovered later as a type error inside a bring-up.

    `None`, not 255, for a switch that names none: the DEFAULT is the package's business and is
    applied once in `plan()`. Returning the default here would make "this exercise asked for
    255" and "this exercise asked for nothing" the same answer, and the check that every switch
    agrees could then not tell a real disagreement from a partially-specified topology.
    """
    raw = spec.get("cpu_port")
    if raw is None:
        return None
    if isinstance(raw, bool):
        raise ConversionError(f"switch {name!r} has cpu_port {raw!r}, which is not a port number")
    if isinstance(raw, int):
        value = raw
    elif isinstance(raw, str) and raw.strip():
        try:
            value = int(raw.strip(), 0)
        except ValueError:
            raise ConversionError(
                f"switch {name!r} has cpu_port {raw!r}, which is not a port number")
    else:
        raise ConversionError(
            f"switch {name!r} has cpu_port {raw!r}, which is not a port number")
    if not 0 <= value <= 511:
        raise ConversionError(
            f"switch {name!r} has cpu_port {value}, outside bmv2's port range 0..511")
    return value


def package_cpu_port(switches):
    """The one cpu_port this package declares, or the default when no switch names one.

    [Co-developed with claude code -- Adam]
    🔴 ONE NUMBER FOR THE WHOLE PACKAGE, because `package.json` has one field for it
    (`bmv2.cpu_port`, which `app_package` validates and the bring-up passes to every switch).
    Two switches asking for two different CPU ports is therefore not something this format can
    carry, and converting it anyway would silently give one of them the other's -- a switch
    whose pipeline sends packets to a port the controller is not listening on, which presents as
    "telemetry from nine of ten switches" with no error. So it is refused, and the message names
    the two switches rather than saying "inconsistent".
    """
    declared = {dpid: spec["cpu_port"] for dpid, spec in switches.items()
                if spec.get("cpu_port") is not None}
    if not declared:
        return common.DEFAULT_CPU_PORT
    values = sorted(set(declared.values()))
    if len(values) > 1:
        first = sorted(d for d, v in declared.items() if v == values[0])[0]
        second = sorted(d for d, v in declared.items() if v == values[1])[0]
        raise ConversionError(
            f"the exercise gives two switches different CPU ports: "
            f"{switches[first]['name']} asks for {values[0]} and "
            f"{switches[second]['name']} for {values[1]}. A package carries ONE "
            f"bmv2.cpu_port for the whole fabric, so one of them would silently be given the "
            f"other's and would send packets to a port nothing is listening on")
    return values[0]


# --- the 2018-06 .. 2019-08 tutorials topology format ----------------------------------------------
#
# [Co-developed with claude code -- Adam]
#
# Apps written against the P4 Developer Day 2018/2019 VMs (Princeton-Cabernet's ONTAS is one) carry
# the topology.json of that era: `hosts` is a LIST of names, and a link names a switch with no port
# (`["h1", "s1"]`). That harness gave every host its address and every link its ports itself, by
# rules in its utils/run_exercise.py (p4lang/tutorials 948a890, ExerciseTopo.__init__ and
# parse_links; replaced by the current format in 76a9067, 2019-08-14):
#
#   * each link's two ends are ordered alphabetically (so a host, `h...`, is always node1);
#   * host links, then switch links, are each sorted by node1 + node2;
#   * a switch's ports are numbered 1, 2, ... in that order -- every host link first, then every
#     switch link, which takes a port on both of its switches;
#   * host hN on switch sM is 10.0.M.N/24 with MAC 00:00:00:00:MM:NN (two hex digits each).
#
# This converts such a topology into the current form by those same rules, so the rest of convert
# reads one format. What it cannot carry is said, not dropped: that harness also gave each host a
# static ARP entry for a phony gateway 10.0.N.254 with the SWITCH PORT's MAC, a route to it and a
# default route via it (program_hosts), and that MAC only exists in the Mininet it built -- the
# package's hosts get no commands, and convert prints so, with each host's derived port.

LEGACY_NOTE = ("a 2018-19 tutorials topology (hosts as a list, links without ports): ports and "
               "addresses derived by that harness's rules (p4lang/tutorials 948a890 "
               "utils/run_exercise.py ExerciseTopo); its per-host setup -- a static ARP entry "
               "for a phony gateway 10.0.<host>.254 with the switch port's MAC, a route to it and "
               "a default route via it -- used a MAC only that Mininet had, and is not carried")


def is_legacy_topology(topo):
    return isinstance(topo.get("hosts"), list)


def legacy_topology(topo):
    """The current-format topology the 2018-19 harness would have built from `topo`."""
    hosts = topo.get("hosts")
    if not all(isinstance(h, str) and h for h in hosts):
        raise ConversionError(f"legacy topology: hosts {hosts!r} is not a list of host names")
    links = []
    for raw in topo.get("links") or []:
        if not isinstance(raw, (list, tuple)) or len(raw) < 2:
            raise ConversionError(f"legacy topology: link {raw!r} needs two endpoints")
        s, t = str(raw[0]), str(raw[1])
        if "-" in s or "-" in t:
            raise ConversionError(
                f"legacy topology: link {raw!r} names a port, but this format has none -- a "
                f"topology with `hosts` as a list and `sN-pM` endpoints is neither format")
        if s > t:
            s, t = t, s
        links.append((s, t, list(raw[2:])))
    host_links = sorted((l for l in links if l[0][0] == "h"), key=lambda l: l[0] + l[1])
    switch_links = sorted((l for l in links if l[0][0] != "h"), key=lambda l: l[0] + l[1])
    ports, out_links, out_hosts = {}, [], {}

    def take(sw):
        ports[sw] = ports.get(sw, 0) + 1
        return ports[sw]

    for host, sw, extra in host_links:
        if sw[0] != "s" or not sw[1:].isdigit() or not host[1:].isdigit():
            raise ConversionError(f"legacy topology: link {host}-{sw} is not hN to sM")
        n, m = int(host[1:]), int(sw[1:])
        if not (0 < m < 256 and 0 < n < 256):
            raise ConversionError(f"legacy topology: {host} on {sw} has no 10.0.M.N address")
        if host in out_hosts:
            raise ConversionError(f"legacy topology: {host} is attached twice")
        out_hosts[host] = {"ip": f"10.0.{m}.{n}/24", "mac": f"00:00:00:00:{m:02x}:{n:02x}",
                           "commands": []}
        out_links.append([host, f"{sw}-p{take(sw)}"] + extra)
    for a, b, extra in switch_links:
        out_links.append([f"{a}-p{take(a)}", f"{b}-p{take(b)}"] + extra)
    missing = sorted(set(hosts) - set(out_hosts))
    if missing:
        raise ConversionError(f"legacy topology: hosts with no link: {missing}")
    return {"hosts": out_hosts, "switches": topo.get("switches") or {}, "links": out_links}


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


#: The two names tutorials' utils/Makefile has given a p4info: `.p4.p4info.txtpb` since
#: ffd07f2 (2024-10-15, "Updates to use the suffix 'txtpb' instead of 'txt'"), `.p4.p4info.txt`
#: before it. An app that vendored the older utils/ -- niloysh/int-v1 is one, and its own
#: sX-runtime.json names `build/int.p4.p4info.txt` -- builds the older name. The current one is
#: first: with neither on disk, the refusal names what `make` writes today.
#: [Co-developed with claude code -- Adam]
P4INFO_SUFFIXES = (".p4.p4info.txtpb", ".p4.p4info.txt")


def _p4info_rel(exercise_dir, directory, stem):
    """The p4info a build left beside `<directory>/<stem>.json`, by either Makefile's name.

    [Co-developed with claude code -- Adam]
    🔴 BOTH ON DISK IS REFUSED, NOT RESOLVED. Two p4infos for one stem are two compiles, and
    which one the bmv2 json beside them came from is not something a file name can say; picking
    one would be a package whose entries are checked against a program the switch may not run.
    `exercise_dir` None (the naming rule asked in the abstract) answers with the current name.
    """
    names = [os.path.join(directory, stem + suffix) for suffix in P4INFO_SUFFIXES]
    if exercise_dir is None:
        return names[0]
    present = [rel for rel in names if os.path.isfile(os.path.join(exercise_dir, rel))]
    if len(present) > 1:
        raise ConversionError(
            f"{exercise_dir} holds both {present[0]!r} and {present[1]!r}: two p4infos for one "
            f"program, i.e. two builds, and nothing says which one {stem}.json came from. Remove "
            f"the stale one, or delete build/ and run `make build`")
    return present[0] if present else names[0]


def artefacts_for_p4(p4_rel, exercise_dir=None):
    """`solution/basic.p4` -> ("build/basic.p4.p4info.txtpb", "build/basic.json").

    The exercises' shared Makefile compiles every `*.p4` into `$(BUILD_DIR)/<stem>.json` with
    `--p4runtime-files $(BUILD_DIR)/<stem>.p4.p4info.txtpb` (~/tutorials/utils/Makefile), which
    is why the .p4's own directory does not appear on the left: `solution/basic.p4` and
    `basic.p4` are compiled to the same two files. Given the exercise directory, the p4info is
    whichever of the two Makefile names it holds (P4INFO_SUFFIXES).
    """
    stem = _p4_stem(p4_rel)
    return (_p4info_rel(exercise_dir, "build", stem), f"build/{stem}.json")


def artefacts_for_program(program_rel, exercise_dir=None):
    """`build/firewall.json` -> ("build/firewall.p4.p4info.txtpb", "build/firewall.json").

    tutorials' `program` names the bmv2 json; the p4info that was emitted beside it is the same
    stem with the Makefile's `.p4.p4info.txtpb` suffix, in the same directory (or the older
    `.p4.p4info.txt`, given the exercise directory to look in).
    """
    directory, base = os.path.split(program_rel)
    stem = os.path.splitext(base)[0]
    return (_p4info_rel(exercise_dir, directory, stem), program_rel)


def switch_pipelines(exercise_dir, switches, p4_rel, ndtwin_pipeline=False):
    """({dpid: pipeline-or-None}, [(abs_source, package_rel)]) -- G4.

    Three cases, and the third is a refusal rather than a mixture:

      * `--ndtwin-pipeline`: every switch gets `null`, i.e. NDTwin's own artefacts. This is the
        phase-1 cell -- the package's topology, hosts and entries on NDTwin's pipeline -- kept
        reachable on purpose so that what phase 1 measured can still be measured.
      * `--p4 <prog>`: every switch runs the exercise's programs. `<prog>`'s artefacts are the
        fabric default and a switch that declares its own `program` overrides it (firewall: s1
        runs firewall.json, s2-s4 run the Makefile default). Both halves must already be built;
        a package that named a pipeline it does not carry could not be brought up.
      * neither, on a topology where some switch declares `program`: REFUSED. Honouring the
        override alone would put s1 on firewall.json and leave s2-s4 on `ndtwin_switch` -- a
        fabric of two different data planes that nothing downstream would report -- and
        ignoring it would silently produce the "all four switches run one program" package the
        `program` field exists to prevent. Neither is a package anybody asked for.
    """
    declared = {dpid: switches[dpid].get("program") for dpid in switches}
    if ndtwin_pipeline:
        return {dpid: None for dpid in switches}, []
    if not p4_rel:
        named = sorted(dpid for dpid, prog in declared.items() if prog)
        if named:
            raise ConversionError(
                f"switch(es) {[switches[d]['name'] for d in named]} declare their own "
                f"'program' (e.g. {declared[named[0]]!r}) but no --p4 was given, so every other "
                f"switch would be left on NDTwin's own pipeline while these ran the exercise's. "
                f"Pass --p4 <the exercise's DEFAULT_PROG, e.g. basic.p4> so the whole fabric "
                f"runs the exercise's programs, or --ndtwin-pipeline to put every switch on "
                f"NDTwin's")
        return {dpid: None for dpid in switches}, []

    default = artefacts_for_p4(p4_rel, exercise_dir)
    out, copies = {}, []
    for dpid in sorted(switches):
        p4info_rel, json_rel = (artefacts_for_program(declared[dpid], exercise_dir)
                                if declared[dpid] else default)
        for rel in (p4info_rel, json_rel):
            abs_path = os.path.join(exercise_dir, rel)
            if not os.path.isfile(abs_path):
                raise ConversionError(
                    f"switch {switches[dpid]['name']} runs {json_rel!r}, whose artefact {rel!r} "
                    f"is not at {abs_path}. Build the exercise first (`make build` in "
                    f"{exercise_dir}) -- a package that names a pipeline it does not carry "
                    f"cannot be pre-flighted and cannot be brought up")
            copies.append((abs_path, rel))
        out[dpid] = {"p4info": p4info_rel, "bmv2_json": json_rel}
    return out, copies


def plan(exercise_dir, topology_rel, p4_rel=None, name=None, mode="auto",
         ndtwin_pipeline=False):
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
    # [Co-developed with claude code -- Adam] The 2018-19 tutorials format (`hosts` a list, links
    # without ports) is converted into the current one by that harness's own rules, first.
    legacy = isinstance(topo, dict) and is_legacy_topology(topo)
    if legacy:
        topo = legacy_topology(topo)
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

    pipelines, pipeline_copies = switch_pipelines(exercise_dir, switches, p4_rel,
                                                  ndtwin_pipeline=ndtwin_pipeline)
    copies.extend(pipeline_copies)

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
            # This switch's own program, or null for NDTwin's own artefacts. See
            # switch_pipelines() for which of the three cases produced it.
            "pipeline": pipelines[dpid],
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
    if legacy:
        # Only when it applies, so every current-format package is byte-for-byte what it was.
        source["topology_format"] = "tutorials-2018 (hosts a list; ports and addresses derived)"
    if p4_rel:
        p4_abs = os.path.join(exercise_dir, p4_rel)
        if not os.path.isfile(p4_abs):
            raise ConversionError(f"--p4 {p4_rel!r} is not at {p4_abs}")
        copies.append((p4_abs, p4_rel))
        copies.extend(_local_includes(exercise_dir, p4_rel))
        for key, rel in zip(("p4info", "bmv2_json"), artefacts_for_p4(p4_rel, exercise_dir)):
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
        # The exercise's own, when it names one -- flowcache's is 510 (G9b).
        "bmv2": {"cpu_port": package_cpu_port(switches)},
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
    # Only present when the exercise asks for a delay that is not zero.
    #
    # 🔴 A DECLARED ZERO AND AN ABSENT ELEMENT ARE THE SAME THING, and the authority for that is
    # tutorials itself: `parse_links` defaults a link with no third element to `'0ms'` and then
    # passes `delay=link['latency']` to addLink either way (utils/run_exercise.py:212-232). So
    # ecn's and mri's `["s1-p3", "s2-p3", "0", 0.5]` asks for exactly the delay pod-topo's
    # `["h1", "s1-p1"]` asks for -- none. Recording `delay_ms: 0.0` for one and nothing for the
    # other would make two packages that describe the same shaping look different, and would
    # hand G2-C (stage three) a netem qdisc to install for no delay.
    if latency:
        entry["delay_ms"] = latency
    return entry


#: A quoted `#include` -- the preprocessor looks for it beside the including file first. An
#: angle include (`<core.p4>`) is the compiler's own and is never carried.
_QUOTED_INCLUDE = re.compile(r'^\s*#\s*include\s*"([^"]+)"', re.M)


def _local_includes(exercise_dir, p4_rel):
    """[(abs, package_rel)] for every file `p4_rel` pulls in by a quoted `#include`, transitively.

    [Co-developed with claude code -- Adam]
    A program in several files (niloysh/int-v1: int.p4 and five `include/*.p4`) is not carried by
    copying the top file alone -- pre-flight recompiles `source.p4` INSIDE the package, and on
    int-v1 that failed (`p4c-bm2-ss rc=1`), so `ndt up p4 --app` refused the package. Each include
    is resolved beside the file that names it, the way the preprocessor resolves it first. One
    that is not there is left to the compiler's own include path (a system header written with
    quotes); one that resolves OUTSIDE the app directory is refused, because a package that
    carried it would carry somebody else's file and one that did not would not compile.
    Only `#include` lines count: a name in a comment is not an include.
    """
    root = os.path.realpath(exercise_dir)
    # `seen` is keyed by the RESOLVED file: keyed by the lexical path, a directory symlink that
    # points at an ancestor makes include/include/include/... a new name every round, until the
    # path is too long to open.
    out, seen, todo = [], {os.path.realpath(os.path.join(exercise_dir, p4_rel))}, [p4_rel]
    while todo:
        rel = todo.pop()
        try:
            with open(os.path.join(exercise_dir, rel), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as exc:
            raise ConversionError(f"{rel} (an included file of {p4_rel}) cannot be read: "
                                  f"{type(exc).__name__}: {exc}") from exc
        for name in _QUOTED_INCLUDE.findall(text):
            cand = os.path.normpath(os.path.join(os.path.dirname(rel), name))
            real = os.path.realpath(os.path.join(exercise_dir, cand))
            if not os.path.isfile(real):
                continue
            if not real.startswith(root + os.sep):
                raise ConversionError(
                    f"{rel} includes {name!r}, which resolves to {real}, outside {exercise_dir}. "
                    f"A package carries the app's own files only")
            if real in seen:
                continue
            seen.add(real)
            # Written where the file IS, relative to the app (relpath of the resolved path), not
            # where the include's text happened to spell it: an include spelled through `..`
            # that comes back inside the app would otherwise be written outside the package.
            out.append((real, os.path.relpath(real, root)))
            todo.append(cand)
    return out


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
                f"exercise first (`make build` in {exercise_dir}) -- a package that names a p4info "
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


# --- `roles.ipv4_route` --------------------------------------------------------------------
#
# [Co-developed with claude code -- Adam]
#
# 🔴 EVERY NAME IS WRITTEN OUT BY THE OPERATOR. The flag takes table, match_field, action,
# dst_mac and port, and a missing one is refused rather than filled in from the p4info: a table
# that merely LOOKS like a route table is a guess, and the guess is exactly what the roles
# contract exists to replace. preflight.py is the one place that looks at a
# p4info and SUGGESTS a block; the author accepts it by typing it here.
#
# [Co-developed with claude code -- Adam]
# `owner=` may be left out, and is then `package` (or what `--table-owner` says): the author
# keeps the table and NDTwin only reads it to compute flow paths. `owner=ndtwin` is still there
# for apps that write OpenFlow-shaped routes through NDTwin.
#
# `--auto-role` is the one way the suggestion is applied, and only when exactly ONE candidate
# qualifies: the block preflight.route_role_candidates finds, with owner `package` unless
# `--table-owner ndtwin` is given. Zero or several candidates leave the package without roles
# and say so. `ndt up p4 --app <exercise dir>` passes it; a bare convert.py call does not, so a
# call without it writes what it always wrote.
#
# 🔴 WITHOUT THE FLAG NOTHING HERE RUNS, and the package is byte-for-byte what it was
# (tests/test_convert.py compares every written file against a capture taken at 6291db35).
# With it, and owner `ndtwin`, this is the first thing convert does that REWRITES a runtime file
# instead of copying it: NDTwin owns that table exclusively, so the
# exercise's match entries for it are taken out -- and counted, per switch, in convert's own
# report. The table's default action stays; it is not a route, and pre-flight discloses it.

ROLE_FLAG_KEYS = ("owner", "table", "match_field", "action", "dst_mac", "port")
ROLE_OWNERS = ("ndtwin", "package")
#: The owner of a role that does not name one. [Co-developed with claude code -- Adam]
DEFAULT_ROLE_OWNER = "package"


def parse_role_flag(text, owner=None):
    """`table=...,match_field=...,...` -> the `roles.ipv4_route` object package.json carries.

    The five names each once, none empty, nothing else; `owner=` is optional and is `ndtwin` or
    `package`. Left out, it is `owner` (the `--table-owner` flag) or else DEFAULT_ROLE_OWNER;
    written out and different from a given `owner`, the two are refused rather than ranked.
    [Co-developed with claude code -- Adam]
    """
    if not isinstance(text, str) or not text.strip():
        raise ConversionError("--role-ipv4-route needs table=,match_field=,action=,"
                              "dst_mac=,port= (and optionally owner=)")
    values = {}
    for part in text.split(","):
        if "=" not in part:
            raise ConversionError(f"--role-ipv4-route: {part!r} is not key=value")
        key, value = (x.strip() for x in part.split("=", 1))
        if key not in ROLE_FLAG_KEYS:
            raise ConversionError(f"--role-ipv4-route: unknown key {key!r}; the keys are "
                                  f"{list(ROLE_FLAG_KEYS)}")
        if key in values:
            raise ConversionError(f"--role-ipv4-route: {key!r} is given twice")
        if not value:
            raise ConversionError(f"--role-ipv4-route: {key!r} is empty")
        values[key] = value
    if owner is not None and owner not in ROLE_OWNERS:
        raise ConversionError(f"--table-owner must be one of {list(ROLE_OWNERS)}, got {owner!r}")
    if owner is not None and values.get("owner", owner) != owner:
        raise ConversionError(f"--role-ipv4-route says owner={values['owner']} and "
                              f"--table-owner says {owner}: drop one of them")
    # The one key that may be left out is filled before the check below, so that check still
    # names every other missing key.
    values.setdefault("owner", owner or DEFAULT_ROLE_OWNER)
    missing = [k for k in ROLE_FLAG_KEYS if k not in values]
    if missing:
        raise ConversionError(
            f"--role-ipv4-route: missing {missing}. Every name is written out -- nothing is "
            f"guessed from the p4info")
    if values["owner"] not in ROLE_OWNERS:
        raise ConversionError(f"--role-ipv4-route: owner must be one of {list(ROLE_OWNERS)}, "
                              f"got {values['owner']!r}")
    return {"owner": values["owner"], "table": values["table"],
            "match_field": values["match_field"], "action": values["action"],
            "params": {"dst_mac": values["dst_mac"], "port": values["port"]}}


def _table_names(p4info_path, table):
    """{full name, alias} of `table` in this p4info, or {table} when it is not there.

    An entry may spell the table either way (tutorials' helper accepts both), and "is this
    entry for the owned table" has to answer yes to both spellings.
    """
    from p4_exercise import preflight  # local: protobuf is only needed with the flag

    try:
        found = preflight.P4InfoIndex.parse(p4info_path).table(table)
    except Exception:  # noqa: BLE001 -- pre-flight reports an unreadable p4info by name
        found = None
    if found is None:
        return {table}
    return {found.preamble.name, found.preamble.alias} - {""}


#: Said wherever a package is left without a route role on the package's own program.
#: [Co-developed with claude code -- Adam]
NO_PATHS_WARNING = ("the twin will show no flow paths for this fabric unless its forwarding "
                    "table uses NDTwin's own names")


def role_flag_text(role):
    """The `--role-ipv4-route` value that names `role`, owner left out (it defaults).
    [Co-developed with claude code -- Adam]"""
    return (f"table={role['table']},match_field={role['match_field']},action={role['action']},"
            f"dst_mac={role['params']['dst_mac']},port={role['params']['port']}")


def _describe_candidate(role):
    return (f"{role['table']} {role['match_field']} -> {role['action']}"
            f"({role['params']['dst_mac']}, {role['params']['port']})")


def auto_route_role(exercise_dir, package, model, owner=DEFAULT_ROLE_OWNER):
    """`--auto-role`: the route role pre-flight's heuristic finds, when exactly one qualifies.

    Returns {"role": the roles.ipv4_route object or None, "candidates": [every candidate],
    "why": None when a role was chosen, else the sentence saying why none was, "warn": True when
    that leaves the package's own program with no flow paths}. The candidates are
    preflight.route_role_candidates over the p4info of every switch that runs the package's own
    program -- the same function that prints the suggestion, so there is one heuristic -- and each
    has already been through route_binding.resolve on every one of those switches.

    🔴 `owner` ndtwin with no single candidate is REFUSED, not warned about: it asks NDTwin to
    write the forwarding table, and a package with no role would answer every one of those
    writes with 501 while the conversion said it had done what was asked.
    [Co-developed with claude code -- Adam]
    """
    if owner not in ROLE_OWNERS:
        raise ConversionError(f"--table-owner must be one of {list(ROLE_OWNERS)}, got {owner!r}")
    found = {"role": None, "candidates": [], "why": None, "warn": False}
    own = {dpid: spec for dpid, spec in package["switches"].items() if spec.get("pipeline")}
    external = package["control_plane"]["mode"] == "external"
    if external:
        found["why"] = ("the control plane is external: the exercise's own controller owns "
                        "every table, so a route role would bind nothing")
    elif not own:
        found["why"] = "every switch runs NDTwin's own pipeline, which needs no route role"
    else:
        from p4_exercise import preflight  # local: protobuf is only needed with the flag

        p4infos = {}
        for dpid in sorted(own, key=int):
            path = os.path.join(exercise_dir, own[dpid]["pipeline"]["p4info"])
            try:
                p4infos[dpid] = preflight.P4InfoIndex.parse(path).p4info
            except Exception as exc:  # noqa: BLE001 -- named, then refused
                raise ConversionError(f"{own[dpid]['pipeline']['p4info']} (the p4info of "
                                      f"s{dpid}) does not parse: {type(exc).__name__}: "
                                      f"{exc}") from exc
        found["candidates"] = preflight.route_role_candidates(
            common.import_route_binding(), p4infos, {"model": model, "reads": read_back(model)})
        if len(found["candidates"]) == 1:
            found["role"] = dict(found["candidates"][0], owner=owner)
        elif not found["candidates"]:
            found["why"] = ("no table of the program is shaped like a destination route (one "
                            "32-bit LPM match field, and an action taking a 48-bit MAC and a "
                            "port) on every switch that runs it")
            found["warn"] = True
        else:
            found["why"] = (f"{len(found['candidates'])} candidates qualify, and picking one "
                            f"would be a guess: "
                            + "; ".join(_describe_candidate(c) for c in found["candidates"]))
            found["warn"] = True
    if owner == "ndtwin" and found["role"] is None:
        # [Co-developed with claude code -- Adam] Each case its own way out: on an external
        # plane no role can be written at all (apply_route_role refuses one), and several
        # candidates are named as the flag line that picks each, as one_step.py prints them.
        if external is True:
            raise ConversionError(
                "--table-owner ndtwin asks NDTwin to write this program's forwarding table, and "
                "the control plane is external: the exercise's own controller owns every table, "
                "so NDTwin can own none. Drop --table-owner")
        if len(found["candidates"]) > 1:
            raise ConversionError(
                "--table-owner ndtwin asks NDTwin to write this program's forwarding table, and "
                f"{len(found['candidates'])} candidates qualify. Pick one by adding its line: "
                + "; ".join(f"--role-ipv4-route owner=ndtwin,{role_flag_text(c)}"
                            for c in found["candidates"]))
        raise ConversionError(
            f"--table-owner ndtwin asks NDTwin to write this program's forwarding table, and no "
            f"single one was found: {found['why']}. Name it with --role-ipv4-route")
    return found


def auto_role_lines(found):
    """The report lines for auto_route_role's answer; none when --auto-role was not given.
    [Co-developed with claude code -- Adam]"""
    if not found:
        return []
    if found.get("role") is not None:
        return ["  route role    : auto-filled from the p4info -- its one (table, action) "
                "candidate shaped like a destination route: " + _describe_candidate(found["role"])]
    lines = [f"  route role    : none -- {found['why']}"]
    if found.get("warn"):
        lines.append(f"  WARNING       : {NO_PATHS_WARNING}")
    return lines


def apply_route_role(exercise_dir, package, copies, role, rewrites=None):
    """Put `roles.ipv4_route` in `package`; with owner ndtwin, take the owned table's match
    entries out of every switch that runs the package's own program.

    Returns (package, copies, rewrites, removed): `copies` without the rewritten runtime files,
    `rewrites` {package-relative path: new text}, `removed` {dpid as string: entries taken out}.
    A `rewrites` passed in (the CLI translation's) is the starting text of those files, so the
    entries it appended are still there after the owned table's are taken out.
    [Co-developed with claude code -- Adam]
    """
    if package["control_plane"]["mode"] == "external":
        raise ConversionError(
            "--role-ipv4-route on an external control plane: the exercise's own controller "
            "owns every table and NDTwin writes none, so a route role would bind nothing")
    own_program = {dpid: spec for dpid, spec in package["switches"].items()
                   if spec.get("pipeline")}
    if not own_program:
        raise ConversionError(
            "--role-ipv4-route binds a table of the package's OWN program, and this package "
            "puts every switch on NDTwin's pipeline (no --p4, or --ndtwin-pipeline) -- the "
            "role would apply to no switch. Pass --p4 <the exercise's program>")
    package = dict(package)
    package["roles"] = {"ipv4_route": role}
    rewrites, removed = dict(rewrites or {}), {}
    if role["owner"] != "ndtwin":
        return package, copies, rewrites, removed
    for dpid in sorted(own_program, key=int):
        spec = own_program[dpid]
        rel = spec.get("entries")
        if not rel:
            continue
        doc = (json.loads(rewrites[rel]) if rel in rewrites
               else common.load_json(os.path.join(exercise_dir, rel)))
        names = _table_names(os.path.join(exercise_dir, spec["pipeline"]["p4info"]),
                             role["table"])
        kept, gone = [], 0
        for entry in doc.get("table_entries") or []:
            if (isinstance(entry, dict) and entry.get("table") in names
                    and not entry.get("default_action")):
                gone += 1
                continue
            kept.append(entry)
        removed[str(dpid)] = gone
        if gone:
            doc["table_entries"] = kept
            rewrites[rel] = json.dumps(doc, indent=2) + "\n"
    copies = [(src, rel) for src, rel in copies if rel not in rewrites]
    return package, copies, rewrites, removed


# --- `--thrift-commands` (bmv2 CLI table commands, translated) ------------------------------------
#
# [Co-developed with claude code -- Adam]
#
# A published app may program part of its fabric through `simple_switch_CLI` rather than a
# runtime file -- niloysh/int-v1's runtime_cmds/s1.sh installs its INT source rules that way. A
# package carries P4Runtime entries only, so the commands are translated (thrift_cli.py, which
# says where the CLI and P4Runtime disagree) and APPENDED to that switch's runtime file in the
# package. The script itself is carried too, at its app-relative path, and named in
# `source.thrift_commands`, so the package says which of its entries were not in the app's
# runtime file. Without the flag nothing here runs and every file is what it was.

def parse_thrift_flags(values):
    """`["s1=runtime_cmds/s1.sh", ...]` -> {"s1": "runtime_cmds/s1.sh"}; each switch once."""
    out = {}
    for value in values or []:
        name, sep, path = str(value).partition("=")
        name, path = name.strip(), path.strip()
        if not sep or not name or not path:
            raise ConversionError(f"--thrift-commands {value!r}: write it sN=<path relative to "
                                  f"the app directory>")
        if name in out:
            raise ConversionError(f"--thrift-commands names {name} twice")
        out[name] = path
    return out


def apply_thrift_commands(exercise_dir, package, copies, mapping):
    """Translate each named switch's CLI commands and append them to its runtime file.

    Returns (package, copies, rewrites, report): `rewrites` {package-relative path: new text},
    `report` {dpid as string: {"file", "translated", "notes"}}.
    """
    from p4_exercise import thrift_cli  # local: protobuf is only needed with the flag

    by_name = {spec["name"]: dpid for dpid, spec in package["switches"].items()}
    unknown = sorted(set(mapping) - set(by_name))
    if unknown:
        raise ConversionError(f"--thrift-commands names {unknown}, which the topology does not "
                              f"declare (it has {sorted(by_name)})")
    # (Spelled through `mode`, not as apply_route_role's identical line: that line is another
    # gate's mutation anchor, tests/shell/mutate_roles_binding.sh, and an anchor must be unique.)
    mode = package["control_plane"]["mode"]
    if mode == "external":
        raise ConversionError(
            "--thrift-commands on an external control plane: the app's own controller owns "
            "every table and NDTwin writes none, so translated entries would never be written")
    package = dict(package)
    root = os.path.realpath(exercise_dir)
    rewrites, report, recorded = {}, {}, {}
    for name in sorted(mapping, key=lambda n: int(by_name[n])):
        dpid = by_name[name]
        spec = package["switches"][dpid]
        rel = mapping[name]
        if not spec.get("pipeline"):
            raise ConversionError(
                f"--thrift-commands {name}={rel}: {name} runs NDTwin's own pipeline (no --p4, or "
                f"--ndtwin-pipeline), and the commands name tables of the app's program")
        if not spec.get("entries"):
            raise ConversionError(
                f"--thrift-commands {name}={rel}: {name} has no runtime_json to carry the "
                f"translated entries; this flag appends to the app's own runtime file")
        source_abs = os.path.join(exercise_dir, rel)
        real = os.path.realpath(source_abs)
        if os.path.isabs(rel) or not real.startswith(root + os.sep):
            # The script is copied into the package at this same relative path, so one that
            # resolves outside the app would be written outside the package too.
            raise ConversionError(f"--thrift-commands {name}={rel}: resolves to {real}, outside "
                                  f"{exercise_dir}; the package carries the app's own files only")
        if not os.path.isfile(real):
            raise ConversionError(f"--thrift-commands {name}={rel}: no such file under "
                                  f"{exercise_dir}")
        # Compared by the RESOLVED file: `./s1-runtime.json` and `s1-runtime.json` are one file,
        # and comparing the spellings let two switches share it unnoticed.
        target = os.path.realpath(os.path.join(exercise_dir, spec["entries"]))
        sharing = sorted(package["switches"][d]["name"] for d in package["switches"]
                         if package["switches"][d].get("entries") and os.path.realpath(
                             os.path.join(exercise_dir, package["switches"][d]["entries"]))
                         == target)
        if len(sharing) > 1:
            # The smaller of the two fixes (refuse, rather than give each switch its own copy):
            # the translated entries are for ONE switch, and appending them to a file several
            # switches read would install them on all of them.
            raise ConversionError(
                f"--thrift-commands {name}={rel}: {spec['entries']} is the runtime file of "
                f"{sharing}, so entries translated for {name} would be installed on every one of "
                f"them. Give {name} its own runtime_json in the topology first")
        with open(real, encoding="utf-8") as fh:
            text = fh.read()
        schema = thrift_cli.schema_from_p4info_path(
            os.path.join(exercise_dir, spec["pipeline"]["p4info"]))
        try:
            commands, script_notes = thrift_cli.read_script(text, rel)
            entries, notes = thrift_cli.translate(commands, schema)
        except thrift_cli.Untranslatable as exc:
            raise ConversionError(f"--thrift-commands {name}={rel}: {exc}") from exc
        notes = script_notes + notes
        doc = common.load_json(os.path.join(exercise_dir, spec["entries"]))
        existing = doc.get("table_entries") or []
        # No refusal for a table the file already writes over P4Runtime: the CLI priorities are
        # translated to their exact inverse, so bmv2 holds the CLI's own numbers and the two
        # sets rank against each other as they would natively (thrift_cli's PRIORITY note).
        doc["table_entries"] = list(existing) + entries
        rewrites[spec["entries"]] = json.dumps(doc, indent=2) + "\n"
        # The package path is where the script IS (relpath of the resolved file), not the
        # spelling the flag was given: `../app/runtime_cmds/s1.sh` would otherwise be written
        # outside the package directory.
        dest = os.path.relpath(real, root)
        copies = list(copies) + [(real, dest)]
        recorded[name] = dest
        report[dpid] = {"file": dest, "translated": len(entries), "notes": notes}
    copies = [(src, r) for src, r in _dedup_copies(copies) if r not in rewrites]
    package["source"] = dict(package["source"], thrift_commands=dict(sorted(recorded.items())))
    return package, copies, rewrites, report


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


def write(out_dir, package, model, copies, rewrites=None):
    """Write the package. Returns the list of files written, package-relative.

    `rewrites` -- {package-relative path: text} for the runtime files `apply_route_role` took
    owned-table entries out of. None (every caller without --role-ipv4-route) writes nothing
    extra. [Co-developed with claude code -- Adam]
    """
    out_dir = os.path.abspath(out_dir)
    os.makedirs(os.path.join(out_dir, "ndtwin"), exist_ok=True)
    written = []
    for abs_src, rel in copies:
        dest = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(abs_src, dest)
        written.append(rel)
    for rel, text in sorted((rewrites or {}).items()):
        dest = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(text)
        written.append(rel)
    with open(os.path.join(out_dir, "ndtwin", "topology.json"), "w", encoding="utf-8") as fh:
        fh.write(common.dumps(model))
    written.append("ndtwin/topology.json")
    with open(os.path.join(out_dir, "package.json"), "w", encoding="utf-8") as fh:
        fh.write(common.dumps(package))
    written.append("package.json")
    return sorted(written)


def convert(exercise_dir, topology_rel, out_dir, p4_rel=None, name=None, mode="auto",
            ndtwin_pipeline=False, role_ipv4_route=None, removed=None, thrift_commands=None,
            thrift_report=None, auto_role=False, owner=None, auto_report=None):
    """Plan, read back, write. `role_ipv4_route` is `parse_role_flag`'s object (or None); when
    given, `removed` (a dict, if passed) is filled with {dpid: owned-table entries taken out}.
    `thrift_commands` is `parse_thrift_flags`' {switch name: CLI file} (or None); when given,
    `thrift_report` (a dict, if passed) is filled with apply_thrift_commands' report. The CLI
    entries go in first, so an owner-ndtwin role takes the owned table's entries out of the
    translated file too. `auto_role` fills the role from auto_route_role (with `owner`, default
    package) and fills `auto_report` (a dict, if passed) with its answer; it and
    `role_ipv4_route` are two answers to one question and are refused together.
    [Co-developed with claude code -- Adam]"""
    if auto_role and role_ipv4_route is not None:
        raise ConversionError("--auto-role and --role-ipv4-route both name the route role; "
                              "give one of them")
    package, model, copies = plan(exercise_dir, topology_rel, p4_rel=p4_rel, name=name,
                                  mode=mode, ndtwin_pipeline=ndtwin_pipeline)
    rewrites = None
    if thrift_commands:
        package, copies, rewrites, translated = apply_thrift_commands(
            os.path.abspath(exercise_dir), package, copies, thrift_commands)
        if thrift_report is not None:
            thrift_report.update(translated)
    if auto_role:
        found = auto_route_role(os.path.abspath(exercise_dir), package, model,
                                owner or DEFAULT_ROLE_OWNER)
        if auto_report is not None:
            auto_report.update(found)
        role_ipv4_route = found["role"]
    if role_ipv4_route is not None:
        package, copies, rewrites, taken = apply_route_role(
            os.path.abspath(exercise_dir), package, copies, role_ipv4_route, rewrites)
        if removed is not None:
            removed.update(taken)
    read_back(model)
    return package, model, write(out_dir, package, model, copies, rewrites)


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
    ap.add_argument("--ndtwin-pipeline", action="store_true",
                    help="put every switch on NDTwin's own compiled pipeline instead of the "
                         "exercise's programs (the package still carries its topology, hosts "
                         "and entries). Overrides --p4 and any per-switch `program`.")
    ap.add_argument("--role-ipv4-route", default=None, metavar="[owner=,]table=,match_field=,"
                    "action=,dst_mac=,port=",
                    help="declare roles.ipv4_route: every name written "
                         "out, none guessed. owner defaults to package (NDTwin only reads the "
                         "table). owner=ndtwin also takes the exercise's match "
                         "entries for that table out of every runtime file (counted below).")
    # [Co-developed with claude code -- Adam]
    ap.add_argument("--auto-role", action="store_true",
                    help="fill roles.ipv4_route from the p4info when it has exactly one "
                         "(table, action) candidate shaped like a destination route (what "
                         "pre-flight suggests); with none or several, write no roles and say why")
    ap.add_argument("--table-owner", default=None, choices=ROLE_OWNERS,
                    help="the owner of a role that does not name one (--auto-role, or a "
                         "--role-ipv4-route without owner=); default package. ndtwin also takes "
                         "the exercise's match entries for that table out (counted below)")
    ap.add_argument("--thrift-commands", action="append", default=[], metavar="sN=<file>",
                    help="translate this switch's simple_switch_CLI table commands (a commands "
                         "file, or a .sh of `simple_switch_CLI <<< \"...\"` lines) into "
                         "P4Runtime entries appended to its runtime file; repeatable, one per "
                         "switch. Every place an entry differs from the command is printed.")
    args = ap.parse_args(argv)

    removed, translated, auto = {}, {}, {}
    try:
        # [Co-developed with claude code -- Adam] A --table-owner with no role to give it to would
        # be a flag that did nothing while the command exited 0.
        if args.table_owner is not None and args.role_ipv4_route is None and not args.auto_role:
            raise ConversionError("--table-owner names the owner of a route role, and neither "
                                  "--role-ipv4-route nor --auto-role asks for one")
        role = (None if args.role_ipv4_route is None
                else parse_role_flag(args.role_ipv4_route, owner=args.table_owner))
        thrift = parse_thrift_flags(args.thrift_commands)
        package, model, written = convert(args.exercise_dir, args.topology, args.out,
                                          p4_rel=args.p4, name=args.name, mode=args.mode,
                                          ndtwin_pipeline=args.ndtwin_pipeline,
                                          role_ipv4_route=role, removed=removed,
                                          thrift_commands=thrift, thrift_report=translated,
                                          auto_role=args.auto_role, owner=args.table_owner,
                                          auto_report=auto)
    except ConversionError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1

    n_sw = len([n for n in model["nodes"] if n["vertex_type"] == 0])
    n_h = len([n for n in model["nodes"] if n["vertex_type"] == 1])
    print(f"package '{package['name']}' -> {os.path.abspath(args.out)}")
    print(f"  control plane : {package['control_plane']['mode']}")
    if package["source"].get("topology_format"):
        # [Co-developed with claude code -- Adam]
        print(f"  topology      : {LEGACY_NOTE}")
        for name in sorted(package["hosts"], key=_host_sort_key):
            h = package["hosts"][name]
            ports = [f"{l['b'][0]} port {l['b'][1]}" for l in package["links"]
                     if l["a"][0] == name]
            print(f"                  {name} {h['ip']}/{h['prefix_len']} {h['mac']} on "
                  f"{', '.join(ports) or 'no switch'}")
    # Per switch, and spelled out even when they are all the same: "which program does this
    # switch run" is the question a converted exercise exists to answer, and a summary that
    # only appeared when the answers differed would make the uniform case unreadable.
    print("  pipelines     : " + ", ".join(
        f"{package['switches'][k]['name']}="
        + (package["switches"][k]["pipeline"]["bmv2_json"]
           if package["switches"][k]["pipeline"] else "NDTwin's own")
        for k in sorted(package["switches"], key=int)))
    print(f"  model         : {n_sw} switches, {n_h} hosts, {len(model['edges'])} edges "
          f"({len(model['edges']) // 2} links, both directions stored)")
    for line in auto_role_lines(auto):
        print(line)
    if "roles" in package:
        route = package["roles"]["ipv4_route"]
        print(f"  roles         : ipv4_route owner={route['owner']} table={route['table']} "
              f"match_field={route['match_field']} action={route['action']} "
              f"dst_mac={route['params']['dst_mac']} port={route['params']['port']}")
        if route["owner"] == "ndtwin":
            per = ", ".join(f"s{d}: {n}" for d, n in sorted(removed.items(), key=lambda kv:
                                                            int(kv[0])))
            print(f"  owned table   : {sum(removed.values())} match entr"
                  f"{'y' if sum(removed.values()) == 1 else 'ies'} for {route['table']} taken "
                  f"out of the runtime files ({per or 'no switch had any'}); its default "
                  f"action stays")
    for dpid in sorted(translated, key=int):
        item = translated[dpid]
        print(f"  CLI commands  : s{dpid}: {item['translated']} entr"
              f"{'y' if item['translated'] == 1 else 'ies'} from {item['file']} appended to "
              f"{package['switches'][dpid]['entries']}")
        for note in item["notes"]:
            print(f"                  {note}")
    print(f"  files         : {len(written)}")
    for rel in written:
        print(f"                  {rel}")
    print("  read back through p4_proxy/mininet/topo_from_json.py: ok")
    print("  next: tools/p4_exercise/preflight.py " + os.path.abspath(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
