#!/usr/bin/env python3
"""Say, item by item, whether a P4 app package could be brought up -- before it is (TICKET-P1 §3).

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python tools/p4_exercise/preflight.py <package_dir>

Exit 0 when every check passes, 1 when any fails. Needs no root, no Mininet and no fabric: it
reads files and parses protobuf, which is the whole point -- the failures it is looking for are
exactly the ones that today show up after `ndt up p4` as a switch that came up with an empty
table and a twin that reports zero rather than an error (GAP-ANALYSIS §5-①).

Each check prints PASS or FAIL with a reason. A check that cannot be run prints FAIL, never
PASS -- "could not tell" is not "fine". The one exception is the p4c compile, which prints
`NOT COMPILED (p4c-bm2-ss absent)` and does not pass or fail: a machine without the compiler
can still legitimately run a package built from an already-compiled artefact, and claiming a
compile that did not happen is the thing this whole file exists to prevent.

What it does NOT check, said out loud:

  * That the entries would actually be *installed*. Stage one records them and applies none
    (G5 is stage two); this checks that they *could* be, against the p4info they came with.
  * That NDTwin's own pipeline can run this program's entries. It cannot, and it is not asked
    to: `pipeline: null` means the switch runs `ndtwin_switch`, and the entries are checked
    against the exercise's own p4info because that is the only program they were ever written
    for. Stage two's G4 is what makes the two agree.
  * ternary / range / optional matches. Refused with "G5 not done" rather than accepted and
    silently dropped later.
"""
import argparse
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from p4_exercise import common
else:
    from . import common

PASS = "PASS"
FAIL = "FAIL"
INFO = "INFO"

_MAC_RE = re.compile(r"^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$")
_IPV4_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")

#: Stage one installs exact and lpm only. TICKET-P1 §3; the rest is G5, stage two.
_SUPPORTED_MATCH = ("EXACT", "LPM")


def match_type_name(value):
    """The p4info name of a MatchField.MatchType number.

    🔴 READ OUT OF THE ENUM, NOT TRANSCRIBED. The numbering is not 0,1,2,3,...: p4info.proto
    skips 1, so the real map is {0: UNSPECIFIED, 2: EXACT, 3: LPM, 4: TERNARY, 5: RANGE,
    6: OPTIONAL}. A transcribed table that assumed the obvious numbering was off by one and
    made this file report every `lpm` entry of exercises/basic as an unsupported TERNARY --
    caught on the first real run, and it would have been a pre-flight that refuses the one
    package stage one exists to bring up.
    """
    from p4.config.v1 import p4info_pb2

    enum = p4info_pb2.MatchField.MatchType
    try:
        return enum.Name(int(value))
    except ValueError:
        return f"match_type {value}"


class Report:
    """The PASS/FAIL table, and the verdict."""

    def __init__(self):
        self.rows = []

    def add(self, status, label, detail=""):
        self.rows.append((status, label, detail))
        return status

    def ok(self, label, detail=""):
        return self.add(PASS, label, detail)

    def bad(self, label, detail=""):
        return self.add(FAIL, label, detail)

    def note(self, label, detail=""):
        return self.add(INFO, label, detail)

    @property
    def failures(self):
        return [r for r in self.rows if r[0] == FAIL]

    def render(self):
        width = max([len(r[1]) for r in self.rows] + [10])
        lines = []
        for status, label, detail in self.rows:
            line = f"  {status:<4}  {label:<{width}}"
            if detail:
                line += f"  {detail}"
            lines.append(line.rstrip())
        return "\n".join(lines)


# --- p4info ----------------------------------------------------------------------------------

class P4InfoIndex:
    """Tables and actions by name, with the same name-or-alias lookup tutorials uses."""

    def __init__(self, p4info):
        self.p4info = p4info

    @classmethod
    def parse(cls, path):
        from google.protobuf import text_format
        from p4.config.v1 import p4info_pb2

        pb = p4info_pb2.P4Info()
        with open(path, encoding="utf-8") as fh:
            # allow_unknown_field: a p4info written by a newer p4c carries fields this
            # protobuf build does not know, and refusing those would make the check fail on
            # the compiler rather than on the package. tutorials' own helper does the same.
            text_format.Merge(fh.read(), pb, allow_unknown_field=True)
        return cls(pb)

    def table(self, name):
        for t in self.p4info.tables:
            if t.preamble.name == name or t.preamble.alias == name:
                return t
        return None

    def action(self, name):
        for a in self.p4info.actions:
            if a.preamble.name == name or a.preamble.alias == name:
                return a
        return None

    def table_names(self):
        return [t.preamble.name for t in self.p4info.tables]


def encoded_width(value, bitwidth):
    """The number of bytes `value` encodes to, or None when it cannot be encoded.

    Same inference as tutorials' `p4runtime_lib/convert.encode`: a MAC string is six bytes, a
    dotted-quad is four, anything else that is a string is assumed already encoded, and an int
    is packed into ceil(bitwidth/8) -- which is where an out-of-range value is caught.
    """
    if isinstance(value, (list, tuple)):
        if len(value) != 1:
            return None
        value = value[0]
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        if value < 0 or value >= (1 << bitwidth):
            return None
        return math.ceil(bitwidth / 8.0)
    if isinstance(value, str):
        if _MAC_RE.match(value):
            return 6
        if _IPV4_RE.match(value):
            try:
                socket.inet_aton(value)
            except OSError:
                return None
            return 4
        try:
            socket.inet_pton(socket.AF_INET6, value)
            return 16
        except OSError:
            pass
        return len(value.encode("utf-8"))
    return None


def check_value(value, bitwidth):
    """None when the value fits the field, else why not."""
    want = math.ceil(bitwidth / 8.0)
    got = encoded_width(value, bitwidth)
    if got is None:
        return f"{value!r} cannot be encoded into a {bitwidth}-bit field"
    if got != want:
        return (f"{value!r} encodes to {got} byte(s) but the field is {bitwidth} bits "
                f"({want} byte(s))")
    return None


def check_entry(entry, index, where):
    """Everything wrong with one tutorials table entry, as a list of strings."""
    problems = []
    table_name = entry.get("table")
    table = index.table(table_name) if table_name else None
    if table is None:
        known = ", ".join(index.table_names()[:6]) or "(none)"
        return [f"{where}: table {table_name!r} is not in the p4info (it has: {known})"]

    match = entry.get("match")
    is_default = bool(entry.get("default_action"))
    if is_default and match:
        problems.append(f"{where}: a default_action entry cannot also carry a match")
    if not is_default and not match:
        problems.append(f"{where}: neither a match nor default_action -- nothing says which "
                        f"entry of {table_name} this is")

    fields = {f.name: f for f in table.match_fields}
    for field_name, value in (match or {}).items():
        field = fields.get(field_name)
        if field is None:
            known = ", ".join(sorted(fields)) or "(none)"
            problems.append(f"{where}: {table_name} has no match field {field_name!r} "
                            f"(it has: {known})")
            continue
        kind = match_type_name(field.match_type)
        if kind not in _SUPPORTED_MATCH:
            problems.append(f"{where}: {field_name} is a {kind} match -- G5 not done "
                            f"(stage one installs exact and lpm only)")
            continue
        if kind == "LPM":
            if not (isinstance(value, (list, tuple)) and len(value) == 2):
                problems.append(f"{where}: {field_name} is an lpm match, so its value must be "
                                f"[value, prefix_len]; got {value!r}")
                continue
            addr, prefix = value
            if not isinstance(prefix, int) or isinstance(prefix, bool):
                problems.append(f"{where}: {field_name} prefix length {prefix!r} is not an integer")
            elif not 0 <= prefix <= field.bitwidth:
                # 🔴 A prefix longer than the field is not a near miss. bmv2 takes the mask
                # from this number, and an out-of-range one is either rejected at install time
                # (a switch with no route) or silently truncated (a route that matches the
                # wrong traffic). Neither shows up as an error in the twin.
                problems.append(f"{where}: {field_name} has prefix length {prefix}, which is "
                                f"outside 0..{field.bitwidth} for this field")
            bad = check_value(addr, field.bitwidth)
            if bad:
                problems.append(f"{where}: {field_name} {bad}")
        else:
            if isinstance(value, (list, tuple)) and len(value) != 1:
                problems.append(f"{where}: {field_name} is an exact match but its value is a "
                                f"list of {len(value)}")
                continue
            bad = check_value(value, field.bitwidth)
            if bad:
                problems.append(f"{where}: {field_name} {bad}")

    action_name = entry.get("action_name")
    action = index.action(action_name) if action_name else None
    if action is None:
        problems.append(f"{where}: action {action_name!r} is not in the p4info")
        return problems
    allowed = {ref.id for ref in table.action_refs}
    if allowed and action.preamble.id not in allowed:
        problems.append(f"{where}: {table_name} does not list {action_name!r} among its actions")

    params = {p.name: p for p in action.params}
    given = entry.get("action_params") or {}
    for missing in sorted(set(params) - set(given)):
        problems.append(f"{where}: action {action_name} needs a parameter {missing!r}")
    for extra in sorted(set(given) - set(params)):
        known = ", ".join(sorted(params)) or "(none)"
        problems.append(f"{where}: action {action_name} has no parameter {extra!r} "
                        f"(it has: {known})")
    for pname, pvalue in given.items():
        param = params.get(pname)
        if param is None:
            continue
        bad = check_value(pvalue, param.bitwidth)
        if bad:
            problems.append(f"{where}: {action_name}.{pname} {bad}")
    return problems


# --- the checks ------------------------------------------------------------------------------

def run(package_dir, report=None, compile_p4=True):
    """Fill a Report for this package directory. Returns the Report."""
    report = report or Report()
    package_dir = os.path.abspath(package_dir)
    pkg_path = os.path.join(package_dir, "package.json")
    if not os.path.isfile(pkg_path):
        report.bad("package.json", f"not at {pkg_path}")
        return report
    try:
        package = common.load_json(pkg_path)
    except ValueError as exc:
        report.bad("package.json", f"does not parse: {exc}")
        return report

    fmt = package.get("format")
    if fmt == common.PACKAGE_FORMAT:
        report.ok("format", f"{fmt}")
    else:
        report.bad("format", f"is {fmt!r}, this tool writes and reads format "
                             f"{common.PACKAGE_FORMAT}")
        return report

    report.note("name", str(package.get("name")))
    _check_control_plane(report, package)
    referenced = _check_referenced_files(report, package_dir, package)
    model = _check_topology(report, package_dir, package)
    _check_hosts(report, package, model)
    _check_entries(report, package_dir, package, referenced)
    _check_port_block(report, package)
    _check_compile(report, package_dir, package, compile_p4)
    return report


def _check_control_plane(report, package):
    cp = package.get("control_plane") or {}
    mode = cp.get("mode")
    if mode in ("ndtwin", "external"):
        report.ok("control_plane.mode", mode)
    else:
        report.bad("control_plane.mode", f"{mode!r} is neither 'ndtwin' nor 'external'")

    base = cp.get("grpc_base")
    if base == common.REQUIRED_GRPC_BASE:
        report.ok("control_plane.grpc_base", str(base))
    else:
        report.bad("control_plane.grpc_base",
                   f"{base!r}: stage one allows only {common.REQUIRED_GRPC_BASE}, the block "
                   f"grpc_ports.py assigns (F-15). A controller that has to be moved is moved "
                   f"on the controller's side by run_external_controller.py, not here")

    dev = cp.get("device_id")
    if dev == common.REQUIRED_DEVICE_ID:
        report.ok("control_plane.device_id", str(dev))
    else:
        report.bad("control_plane.device_id",
                   f"{dev!r}: stage one allows only {common.REQUIRED_DEVICE_ID!r}")

    eid = cp.get("election_id")
    if (isinstance(eid, (list, tuple)) and len(eid) == 2
            and all(isinstance(v, int) and not isinstance(v, bool) and v >= 0 for v in eid)):
        report.ok("control_plane.election_id", f"[{eid[0]}, {eid[1]}]")
    else:
        report.bad("control_plane.election_id", f"{eid!r} is not a [high, low] pair of integers")

    cpu = (package.get("bmv2") or {}).get("cpu_port")
    if isinstance(cpu, int) and not isinstance(cpu, bool) and cpu >= 0:
        report.ok("bmv2.cpu_port", str(cpu))
    else:
        report.bad("bmv2.cpu_port", f"{cpu!r} is not a port number")

    switches = package.get("switches") or {}
    if not switches:
        report.bad("switches", "the package declares none")
        return
    bad_keys = [k for k in switches if not (str(k).isdigit() and int(k) >= 1)]
    if bad_keys:
        report.bad("switches keys", f"not positive integers: {sorted(bad_keys)[:5]}")
    else:
        report.ok("switches keys", f"{len(switches)} dpids: "
                                   f"{sorted(int(k) for k in switches)}")
    pipelined = sorted(k for k, v in switches.items() if (v or {}).get("pipeline") is not None)
    if pipelined:
        report.bad("switches pipeline",
                   f"dpid(s) {pipelined} name a pipeline -- G4 not done. Stage one runs "
                   f"NDTwin's own p4_src/build/ndtwin_switch.* on every switch, so a package "
                   f"that names its own would be loaded by nobody")
    else:
        report.ok("switches pipeline", "all null (NDTwin's own artefact; G4 is stage two)")
    misnamed = sorted(k for k, v in switches.items()
                      if (v or {}).get("name") != f"s{k}")
    if misnamed:
        report.bad("switches name", f"dpid(s) {misnamed} are not named sN for their own N")
    else:
        report.ok("switches name", "every sN has dpid N")


def _check_referenced_files(report, package_dir, package):
    """Every path package.json names, resolved against package_dir. Returns {label: abs_path}."""
    refs = {}
    topo = package.get("topology")
    if topo:
        refs["topology"] = topo
    source = package.get("source") or {}
    for key in ("topology_json", "p4", "p4info", "bmv2_json"):
        if source.get(key):
            refs[f"source.{key}"] = source[key]
    for dpid, spec in sorted((package.get("switches") or {}).items(), key=lambda kv: int(kv[0])):
        if (spec or {}).get("entries"):
            refs[f"switches[{dpid}].entries"] = spec["entries"]

    missing, resolved = [], {}
    for label, rel in refs.items():
        path = rel if os.path.isabs(rel) else os.path.join(package_dir, rel)
        if os.path.isfile(path):
            resolved[label] = path
        else:
            missing.append(f"{label}={rel}")
    if missing:
        report.bad("referenced files", f"{len(missing)} missing: {', '.join(missing[:4])}")
    else:
        report.ok("referenced files", f"{len(refs)} present")
    return resolved


def _check_topology(report, package_dir, package):
    rel = package.get("topology")
    if not rel:
        report.bad("topology", "package.json names no topology")
        return None
    path = rel if os.path.isabs(rel) else os.path.join(package_dir, rel)
    if not os.path.isfile(path):
        report.bad("topology", f"not at {path}")
        return None
    T = common.import_topo_from_json()
    try:
        model = T.load(path)
    except ValueError as exc:
        report.bad("topology", f"does not parse: {exc}")
        return None

    reads = {}
    for name in ("switches", "hosts", "switch_links", "host_links"):
        try:
            reads[name] = getattr(T, name)(model)
        except T.TopologyModelError as exc:
            report.bad(f"topo_from_json.{name}", str(exc))
        except Exception as exc:  # noqa: BLE001 -- a reader crash is a FAIL, not a traceback
            report.bad(f"topo_from_json.{name}", f"{type(exc).__name__}: {exc}")
        else:
            report.ok(f"topo_from_json.{name}", f"{len(reads[name])} entries")
    if len(reads) != 4:
        return None

    model_dpids = {d for d, _ in reads["switches"]}
    pkg_dpids = {int(k) for k in (package.get("switches") or {})}
    if model_dpids == pkg_dpids:
        report.ok("switches agree", f"model and package.json both say {sorted(pkg_dpids)}")
    else:
        report.bad("switches agree",
                   f"model has {sorted(model_dpids)}, package.json has {sorted(pkg_dpids)}")

    n_links = len(reads["switch_links"]) + len(reads["host_links"])
    if n_links == len(package.get("links") or []):
        report.ok("links agree", f"{n_links} links in both")
    else:
        report.bad("links agree",
                   f"model has {n_links} ({len(reads['switch_links'])} inter-switch + "
                   f"{len(reads['host_links'])} access), package.json lists "
                   f"{len(package.get('links') or [])}")
    return {"model": model, "reads": reads}


def _check_hosts(report, package, model):
    pkg_hosts = package.get("hosts") or {}
    if not pkg_hosts:
        report.bad("hosts", "the package declares none")
        return
    # The naming rule, checked against the package's own map before the model is consulted:
    # topo_from_json derives h<N> from the last octet and never reads a host's device_name, so
    # a mismatch here is a host the package can name and the fabric cannot (topo_from_json.py:86).
    wrong = []
    for name, spec in sorted(pkg_hosts.items()):
        ip = (spec or {}).get("ip")
        if not ip:
            wrong.append(f"{name} (no ip)")
            continue
        try:
            expected = f"h{common.host_index_from_ip(ip)}"
        except ValueError:
            wrong.append(f"{name} has ip {ip!r}, whose last octet is not a number")
            continue
        if name != expected:
            wrong.append(f"{name} on {ip} would be built as {expected}")
    if wrong:
        report.bad("hosts named h<last octet>", "; ".join(wrong[:4]))
    else:
        report.ok("hosts named h<last octet>", f"{len(pkg_hosts)} hosts")

    if model is None:
        return
    model_hosts = {name for name, _ip, _mac in model["reads"]["hosts"]}
    if model_hosts == set(pkg_hosts):
        report.ok("hosts agree", f"model and package.json both say {sorted(model_hosts)}")
    else:
        report.bad("hosts agree",
                   f"model has {sorted(model_hosts)}, package.json has {sorted(pkg_hosts)}")


def _check_entries(report, package_dir, package, referenced):
    """Table entries against the p4info the exercise shipped them with."""
    switches = package.get("switches") or {}
    with_entries = {k: v for k, v in switches.items() if (v or {}).get("entries")}
    if not with_entries:
        mode = (package.get("control_plane") or {}).get("mode")
        report.note("entries", f"none (control plane '{mode}' brings its own)")
        _check_source_p4info(report, package_dir, package)
        return

    total, problems = 0, []
    parsed_any = False
    for dpid, spec in sorted(with_entries.items(), key=lambda kv: int(kv[0])):
        path = referenced.get(f"switches[{dpid}].entries")
        if path is None:
            problems.append(f"s{dpid}: entries file missing (see 'referenced files')")
            continue
        try:
            conf = common.load_json(path)
        except ValueError as exc:
            problems.append(f"s{dpid}: {spec['entries']} does not parse: {exc}")
            continue
        p4info_rel = conf.get("p4info")
        if not p4info_rel:
            problems.append(f"s{dpid}: {spec['entries']} names no p4info, so its entries "
                            f"cannot be checked against anything")
            continue
        p4info_path = (p4info_rel if os.path.isabs(p4info_rel)
                       else os.path.join(package_dir, p4info_rel))
        if not os.path.isfile(p4info_path):
            problems.append(f"s{dpid}: p4info {p4info_rel} is not at {p4info_path}")
            continue
        try:
            index = P4InfoIndex.parse(p4info_path)
        except Exception as exc:  # noqa: BLE001
            problems.append(f"s{dpid}: p4info {p4info_rel} does not parse: "
                            f"{type(exc).__name__}: {exc}")
            continue
        parsed_any = True
        entries = conf.get("table_entries") or []
        total += len(entries)
        for i, entry in enumerate(entries):
            problems.extend(check_entry(entry, index, f"s{dpid} entry {i}"))

    if parsed_any:
        report.ok("p4info parses", "google.protobuf.text_format into p4.config.v1.P4Info")
    else:
        report.bad("p4info parses", "no switch's p4info could be read")

    if problems:
        report.bad("entries match p4info",
                   f"{len(problems)} problem(s); first: {problems[0]}")
        for extra in problems[1:6]:
            report.bad("", extra)
        if len(problems) > 6:
            report.bad("", f"... and {len(problems) - 6} more")
    else:
        report.ok("entries match p4info",
                  f"{total} entr{'y' if total == 1 else 'ies'} across "
                  f"{len(with_entries)} switch(es); recorded, NOT applied in stage one")


def _check_source_p4info(report, package_dir, package):
    """With no entries there is still a p4info to parse -- the one the exercise was built from."""
    rel = (package.get("source") or {}).get("p4info")
    if not rel:
        report.bad("p4info parses",
                   "the package carries no p4info at all (source.p4info is null and no switch "
                   "has entries), so nothing here can be checked against the program")
        return
    path = rel if os.path.isabs(rel) else os.path.join(package_dir, rel)
    try:
        index = P4InfoIndex.parse(path)
    except Exception as exc:  # noqa: BLE001
        report.bad("p4info parses", f"{rel}: {type(exc).__name__}: {exc}")
        return
    report.ok("p4info parses", f"{rel}: {len(index.table_names())} table(s)")


def _check_port_block(report, package):
    dpids = sorted(int(k) for k in (package.get("switches") or {}) if str(k).isdigit())
    if not dpids:
        report.bad("gRPC port block", "no dpids to check")
        return
    g = common.import_grpc_ports()
    base = (package.get("control_plane") or {}).get("grpc_base", g.GRPC_PORT_BASE)
    if not isinstance(base, int) or isinstance(base, bool):
        report.bad("gRPC port block", f"grpc_base {base!r} is not a port number")
        return
    ports = g.grpc_port_block(dpids, base=base)
    try:
        warning = g.assert_port_block_is_safe(ports)
    except g.PortBlockError as exc:
        report.bad("gRPC port block", str(exc))
        return
    detail = f"{min(ports)}-{max(ports)} safe on this machine"
    if warning:
        report.bad("gRPC port block", warning)
    else:
        report.ok("gRPC port block", detail)


def _check_compile(report, package_dir, package, compile_p4):
    rel = (package.get("source") or {}).get("p4")
    if not rel:
        report.note("p4c-bm2-ss", "source.p4 is null -- nothing to compile")
        return
    if not compile_p4:
        report.note("p4c-bm2-ss", "skipped (--no-compile)")
        return
    p4c = shutil.which("p4c-bm2-ss")
    if p4c is None:
        # Not a PASS and not a FAIL: the compiler's absence says nothing about the package.
        report.note("p4c-bm2-ss", "NOT COMPILED (p4c-bm2-ss absent)")
        return
    path = rel if os.path.isabs(rel) else os.path.join(package_dir, rel)
    if not os.path.isfile(path):
        report.bad("p4c-bm2-ss", f"source.p4 {rel} is not at {path}")
        return
    with tempfile.TemporaryDirectory(prefix="p4_exercise_preflight_") as tmp:
        stem = os.path.splitext(os.path.basename(path))[0]
        out_json = os.path.join(tmp, f"{stem}.json")
        out_p4info = os.path.join(tmp, f"{stem}.p4.p4info.txtpb")
        cmd = [p4c, "--p4v", "16", "--p4runtime-files", out_p4info, "-o", out_json, path]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").strip().splitlines()
            report.bad("p4c-bm2-ss", f"rc={proc.returncode}: "
                                     f"{tail[-1] if tail else '(no output)'}")
            return
        import hashlib

        def sha(p):
            with open(p, "rb") as fh:
                return hashlib.sha256(fh.read()).hexdigest()[:16]

        report.ok("p4c-bm2-ss",
                  f"rc=0  {os.path.basename(out_json)} sha256:{sha(out_json)}  "
                  f"{os.path.basename(out_p4info)} sha256:{sha(out_p4info)}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("package_dir")
    ap.add_argument("--no-compile", action="store_true",
                    help="skip the p4c compile (it is the only slow check)")
    args = ap.parse_args(argv)

    print(f"pre-flight: {os.path.abspath(args.package_dir)}")
    report = run(args.package_dir, compile_p4=not args.no_compile)
    print(report.render())
    n_fail = len(report.failures)
    if n_fail:
        print(f"\nFAIL -- {n_fail} check(s) failed; do NOT bring this package up")
        return 1
    print("\nPASS -- every check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
