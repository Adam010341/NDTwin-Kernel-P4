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

  * That the entries would actually be *installed*. This checks that they *could* be, against
    the p4info they came with -- and, when the switch carries its own pipeline (G4), that the
    p4info they came with IS that switch's.
  * That NDTwin's own pipeline can run this program's entries. It cannot, and it is not asked
    to: a switch whose `pipeline` is null runs `ndtwin_switch`, and its entries are still
    checked against the exercise's own p4info because that is the only program they were ever
    written for. That pairing is a package the fabric will bring up and whose entries nothing
    will apply -- which is what `--ndtwin-pipeline` is for and what the proxy discloses.
  * That the two halves of a pipeline came from one compile, in the sense of a build id. There
    is none to compare (see _check_pipelines); what is checked is that every table and action
    the p4info names exists in the bmv2 json, and the p4info's sha256 is printed so the
    question can be settled between two files that both claim to be the same program.
  * ternary / range / optional matches. Refused with "G5 not done" rather than accepted and
    silently dropped later; `POST /p4/table_entry` answers 501 for the same three.
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
            # The writer's own contract, quoted rather than paraphrased: `POST /p4/table_entry`
            # answers 501 for these three and names the match_type in the body (TICKET-P2
            # section 2.3). Saying so here means the pre-flight and the endpoint give the
            # operator one story instead of two, and that the refusal arrives before the
            # fabric is up rather than one entry at a time after it.
            problems.append(f"{where}: {field_name} is a {kind} match -- G5 not done; "
                            f"POST /p4/table_entry answers 501 for {kind} in this stage "
                            f"(exact and lpm only)")
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
    pipeline_p4info = _check_pipelines(report, package_dir, package)
    used_p4info = _check_entries(report, package_dir, package, referenced)
    _check_entries_are_for_this_pipeline(report, used_p4info, pipeline_p4info)
    _check_roles(report, package_dir, package, model, pipeline_p4info, referenced)
    _check_telemetry(report, package_dir, package, pipeline_p4info)
    _check_pre_entries(report, package_dir, package, model, referenced)
    _check_port_block(report, package)
    _check_compile(report, package_dir, package, compile_p4)
    return report


# --- roles.ipv4_route (TICKET-P4-roles section 2.1) ---------------------------------------------
#
# [Co-developed with claude code -- Adam]
#
# 🔴 THE SAME TWO FUNCTIONS THE PROXY RUNS. The shape goes through `app_package.parse_roles` and
# every p4info through `proxy_agent/route_binding.resolve` -- the loader's and the client
# factory's own code, imported by path -- so a package this table passes is one the proxy starts
# on, and one it fails is refused at bring-up with the same sentence (2.1-4).
#
# 🔴 THE HEURISTIC LIVES HERE AND NOWHERE ELSE (2.1-6). A foreign pipeline with no `roles` whose
# p4info has a table that LOOKS like a destination route table gets one INFO line: the block an
# author could paste. It is never applied, never fatal, and never consulted by the proxy -- a
# name is not consent (ANALYSIS section 5).


def _roles_max_port(model, dpid):
    ports = _switch_ports(model).get(int(dpid)) if model else None
    return max(ports) if ports else None


def _suggest_route_role(route_binding, p4infos, model):
    """A roles.ipv4_route every foreign p4info resolves, or None. The one heuristic."""
    from p4.config.v1 import p4info_pb2

    lpm = p4info_pb2.MatchField.LPM
    shared = None
    for dpid, p4info in p4infos.items():
        found = set()
        for table in p4info.tables:
            fields = list(table.match_fields)
            if len(fields) != 1 or fields[0].match_type != lpm or fields[0].bitwidth != 32:
                continue
            refs = {ref.id for ref in table.action_refs}
            for action in p4info.actions:
                params = list(action.params)
                if action.preamble.id not in refs or len(params) != 2:
                    continue
                macs = [p for p in params if p.bitwidth == 48]
                if len(macs) != 1:
                    continue
                port = [p for p in params if p is not macs[0]][0]
                found.add((table.preamble.name, fields[0].name, action.preamble.name,
                           macs[0].name, port.name))
        shared = found if shared is None else shared & found
    for table, field, action, mac, port in sorted(shared or ()):
        role = {"owner": "ndtwin", "table": table, "match_field": field, "action": action,
                "params": {"dst_mac": mac, "port": port}}
        try:
            for dpid, p4info in p4infos.items():
                route_binding.resolve(role, p4info, max_port=_roles_max_port(model, dpid))
        except route_binding.RouteBindingError:
            continue
        return role
    return None


def _check_roles(report, package_dir, package, model, pipeline_p4info, referenced):
    """`roles`: its shape, every foreign switch's binding, and the owned table's entries."""
    import json as _json

    raw = package.get("roles")
    route_binding = common.import_route_binding()
    p4infos = {}
    for dpid, path in pipeline_p4info.items():
        try:
            p4infos[dpid] = P4InfoIndex.parse(path).p4info
        except Exception:  # noqa: BLE001 -- _check_pipelines already reported it
            continue

    if raw is None:
        if not p4infos:
            return
        suggestion = _suggest_route_role(route_binding, p4infos, model)
        if suggestion is not None:
            report.note("roles suggestion",
                        "no roles declared, so NDTwin writes none of this program's tables. "
                        "Its p4info has a destination-route-shaped table on every switch; to let "
                        "NDTwin route here, add to package.json: \"roles\": "
                        + _json.dumps({"ipv4_route": suggestion}, sort_keys=False)
                        + " (owner ndtwin: NDTwin writes that table and the package's own "
                          "entries for it must go -- convert.py --role-ipv4-route takes them "
                          "out; owner package: NDTwin only reads it)")
        return

    app_package = common.import_app_package()
    try:
        roles = app_package.parse_roles(raw, "package.json")
    except app_package.AppPackageError as exc:
        report.bad("roles", str(exc))
        return
    role = roles.ipv4_route if roles is not None else None
    if role is None:
        report.note("roles", "declares no ipv4_route")
        return
    if (package.get("control_plane") or {}).get("mode") == "external":
        report.note("roles.ipv4_route",
                    "carried, and bound to nothing: control_plane.mode is external, so the "
                    "exercise's own controller owns every table and NDTwin writes none")
    own = sorted((package.get("switches") or {}).items(), key=lambda kv: int(kv[0]))
    own = [k for k, v in own if (v or {}).get("pipeline")]
    if not own:
        report.note("roles.ipv4_route",
                    "applies to no switch: every switch runs NDTwin's own pipeline, which is "
                    "always bound to NDTwin's own table")
        return

    problems, bound = [], []
    for dpid in own:
        p4info = p4infos.get(str(dpid))
        if p4info is None:
            problems.append(f"s{dpid}: its pipeline did not pass (see 'switches pipeline'), so "
                            f"roles.ipv4_route cannot be checked against it")
            continue
        try:
            binding = route_binding.resolve(role.as_manifest(), p4info,
                                            max_port=_roles_max_port(model, dpid),
                                            where=f"s{dpid}: roles.ipv4_route")
        except route_binding.RouteBindingError as exc:
            problems.append(str(exc))
            continue
        bound.append((dpid, binding))
    if problems:
        report.bad("roles.ipv4_route resolves", f"{len(problems)} switch(es); first: "
                                                f"{problems[0]}")
        for extra in problems[1:4]:
            report.bad("", extra)
        if len(problems) > 4:
            report.bad("", f"... and {len(problems) - 4} more")
    else:
        first = bound[0][1]
        report.ok("roles.ipv4_route resolves",
                  f"{len(bound)} switch(es): {first.table} {first.match_field} -> "
                  f"{first.action}({first.dst_mac_param}, {first.port_param} "
                  f"bit<{first.port_bitwidth}>), owner {first.owner}")

    if not bound:
        # Nothing resolved, so there is no owned table to check entries against -- saying
        # "the owned table has no package entries" about a table the program does not have
        # would be a green row about nothing. [Co-developed with claude code -- Adam]
        return
    if role.owner != route_binding.OWNER_NDTWIN:
        report.note("roles.ipv4_route owner",
                    "package: the author owns the table; NDTwin reads and renders it and "
                    "writes nothing, so NDTwin's route writes to these switches answer 501")
        return
    # 🔴 2.1-5 / Adam's ruling 8-1: NDTwin owns the table exclusively, so the package may not
    # declare match entries for it -- each one named. A default action is not a route and stays.
    owned, defaults = [], []
    for dpid, _binding in bound:
        path = referenced.get(f"switches[{dpid}].entries")
        if path is None:
            continue
        try:
            conf = common.load_json(path)
        except ValueError:
            continue              # already reported by 'entries match p4info'
        names = {role.table}
        index_path = pipeline_p4info.get(str(dpid))
        if index_path:
            try:
                table = P4InfoIndex.parse(index_path).table(role.table)
            except Exception:  # noqa: BLE001
                table = None
            if table is not None:
                names = {table.preamble.name, table.preamble.alias} - {""}
        for i, entry in enumerate(conf.get("table_entries") or []):
            if not isinstance(entry, dict) or entry.get("table") not in names:
                continue
            if entry.get("default_action"):
                defaults.append(f"s{dpid} entry {i}: default action "
                                f"{entry.get('action_name')}")
            else:
                owned.append(f"s{dpid} entry {i}: {entry.get('table')} "
                             f"{_json.dumps(entry.get('match'), sort_keys=True)} -> "
                             f"{entry.get('action_name')}")
    if owned:
        report.bad("owned table has no package entries",
                   f"{len(owned)} match entr{'y' if len(owned) == 1 else 'ies'} for "
                   f"{role.table}, which roles.ipv4_route gives to NDTwin: {owned[0]}")
        for extra in owned[1:]:
            report.bad("", extra)
    else:
        report.ok("owned table has no package entries",
                  f"{role.table} is NDTwin's on {len(bound)} switch(es)")
    if defaults:
        report.note("owned table default action",
                    f"kept on {len(defaults)} switch(es) (a default is not a route): "
                    f"{'; '.join(defaults[:4])}")


# --- telemetry (TICKET-P3 2.1) ----------------------------------------------------------------

#: The words a package may declare, and what each one resolves to per switch. Spelled here as
#: well as in the proxy because pre-flight runs BEFORE the fabric exists and must refuse a
#: package the proxy would refuse to start on -- a refusal at bring-up costs a tmux pane full of
#: half-started switches and a `ndt down`. [Co-developed with claude code -- Adam]
TELEMETRY_WORDS = ("auto", "none", "cooperative", "link")

#: The five @controller_header("packet_in") fields the cooperative path needs, by name. The
#: proxy looks them up by name (sflow_emitter.packet_in_metadata_ids) because their ids are
#: positional; so does this.
PACKET_IN_FIELDS = ("reason", "ingress_port", "egress_port", "frame_length", "sampling_rate")


def packet_in_fields(p4info):
    """The names inside this p4info's `packet_in` controller header, as a set (empty if none)."""
    for entry in getattr(p4info, "controller_packet_metadata", []):
        if entry.preamble.name == "packet_in" or entry.preamble.alias == "packet_in":
            return {m.name for m in entry.metadata}
    return set()


def _check_telemetry(report, package_dir, package, pipeline_p4info):
    """`telemetry.source`, and whether the pipelines can carry what it asks for.

    [Co-developed with claude code -- Adam]
    🔴 `cooperative` ON A PROGRAM WITH NO CONTROLLER HEADER IS THE CASE THIS EXISTS FOR. Such a
    fabric comes up, pushes its pipelines, accepts a clone session into the PRE (a clone session
    is a target object, so bmv2 takes it against any program) and then reports zero samples for
    the entire run -- every step green, every link reading zero, and zero is what an idle fabric
    reads too. The proxy refuses to start on it; this says so before the switches are launched.

    Only the package is consulted, never the `telemetry_override` knob: the knob is this
    machine's state at bring-up time and pre-flight is a statement about a package directory,
    which somebody may be checking on another machine entirely.
    """
    telemetry = package.get("telemetry")
    if telemetry is None:
        report.note("telemetry.source", "not declared (auto: NDTwin's pipeline gets the "
                                        "cooperative path, anybody else's gets link telemetry)")
        source = "auto"
    elif not isinstance(telemetry, dict):
        report.bad("telemetry", f"{telemetry!r} is not an object with a 'source'")
        return
    else:
        source = telemetry.get("source")
        if source in TELEMETRY_WORDS:
            report.ok("telemetry.source", str(source))
        else:
            report.bad("telemetry.source",
                       f"{source!r} is not one of {', '.join(TELEMETRY_WORDS)}. A fabric started "
                       f"on a word nobody reads samples nothing and reports zero, which is "
                       f"indistinguishable from a fabric with no traffic")
            return

    if source != "cooperative":
        return

    # Every switch that carries its OWN program has to declare the header. A switch with
    # `pipeline: null` runs ndtwin_switch.p4, which declares it by construction -- and the
    # package directory does not carry that artefact, so there is nothing here to read.
    missing = []
    for dpid, rel in sorted(pipeline_p4info.items(), key=lambda kv: int(kv[0])):
        try:
            index = P4InfoIndex.parse(rel)
        except Exception as exc:  # noqa: BLE001 -- already reported by _check_pipelines
            missing.append(f"s{dpid}: p4info unreadable ({type(exc).__name__})")
            continue
        absent = [name for name in PACKET_IN_FIELDS
                  if name not in packet_in_fields(index.p4info)]
        if absent:
            missing.append(f"s{dpid}: no {', '.join(absent)} in its packet_in header")
    if missing:
        report.bad("telemetry cooperative is possible",
                   f"{len(missing)} switch(es) run a program that cannot clone to the CPU port: "
                   f"{'; '.join(missing[:3])}. Include p4_proxy/p4_src/ndtwin_telemetry.p4 in "
                   f"the program, or declare telemetry.source 'link' or 'none'")
    else:
        report.ok("telemetry cooperative is possible",
                  f"every switch's p4info declares the five packet_in fields")


# --- the PRE entries a runtime file declares (TICKET-P3 2.6, G8/G9a) --------------------------


def _switch_ports(model):
    """{dpid: {port numbers the model gives that switch}}, from the reader's own output."""
    ports = {}
    if not model:
        return ports
    reads = model.get("reads") or {}
    for dpid, _name in reads.get("switches") or ():
        ports.setdefault(dpid, set())
    for a_dpid, a_port, b_dpid, b_port in reads.get("switch_links") or ():
        ports.setdefault(a_dpid, set()).add(a_port)
        ports.setdefault(b_dpid, set()).add(b_port)
    for _host, dpid, port in reads.get("host_links") or ():
        ports.setdefault(dpid, set()).add(port)
    return ports


def _check_pre_entries(report, package_dir, package, model, referenced):
    """`multicast_group_entries` and `clone_session_entries`, against the model's own ports.

    [Co-developed with claude code -- Adam]
    A multicast group replicating to a port the fabric does not build is not an error at the
    switch: the PRE accepts the group, replicates into a port that carries nothing, and the
    host that should have received the packet does not. Which is exactly what a missing group
    looks like, and exactly what a wrong forwarding rule looks like. So the ports are checked
    against the model that will be built rather than against the switch that does not exist yet.

    The CPU port is the one legitimate exception: it is not a link, so no model edge names it,
    and a clone session's whole purpose is to replicate to it.
    """
    switches = package.get("switches") or {}
    ports = _switch_ports(model)
    cpu_port = (package.get("bmv2") or {}).get("cpu_port")
    problems, totals = [], {"multicast": 0, "clone": 0}

    for dpid, spec in sorted(switches.items(), key=lambda kv: int(kv[0])):
        if not (spec or {}).get("entries"):
            continue
        path = referenced.get(f"switches[{dpid}].entries")
        if path is None:
            continue              # already reported by 'referenced files'
        try:
            conf = common.load_json(path)
        except ValueError:
            continue              # already reported by 'entries match p4info'
        known = ports.get(int(dpid), set())

        for i, entry in enumerate(conf.get("multicast_group_entries") or []):
            totals["multicast"] += 1
            where = f"s{dpid} multicast entry {i}"
            if not isinstance(entry, dict):
                problems.append(f"{where}: not an object")
                continue
            gid = entry.get("multicast_group_id")
            if isinstance(gid, bool) or not isinstance(gid, int) or gid < 1:
                problems.append(
                    f"{where}: multicast_group_id {gid!r} is not a positive integer "
                    f"(P4Runtime numbers groups from 1; 0 means 'do not multicast')")
            replicas = entry.get("replicas")
            if not isinstance(replicas, list) or not replicas:
                problems.append(f"{where}: declares no replicas, so the group would drop every "
                                f"packet sent to it")
                continue
            seen = set()
            for j, replica in enumerate(replicas):
                if not isinstance(replica, dict) or "egress_port" not in replica:
                    problems.append(f"{where} replica {j}: no egress_port")
                    continue
                port = replica.get("egress_port")
                instance = replica.get("instance", 1)
                if isinstance(port, bool) or not isinstance(port, int):
                    problems.append(f"{where} replica {j}: egress_port {port!r} is not a port "
                                    f"number")
                    continue
                if known and port not in known and port != cpu_port:
                    problems.append(
                        f"{where} replica {j}: egress_port {port} is not a port s{dpid} has -- "
                        f"the model gives it {sorted(known)}. The PRE would accept this group "
                        f"and replicate into nothing")
                if (port, instance) in seen:
                    problems.append(
                        f"{where} replica {j}: (egress_port {port}, instance {instance}) is "
                        f"declared twice, and the PRE holds one replica for the pair -- the "
                        f"group would be smaller than it looks")
                seen.add((port, instance))

        for i, entry in enumerate(conf.get("clone_session_entries") or []):
            totals["clone"] += 1
            where = f"s{dpid} clone session entry {i}"
            if not isinstance(entry, dict):
                problems.append(f"{where}: not an object")
                continue
            sid = entry.get("clone_session_id", entry.get("session_id"))
            if isinstance(sid, bool) or not isinstance(sid, int) or sid < 1:
                problems.append(f"{where}: clone_session_id {sid!r} is not a positive integer")
            for j, replica in enumerate(entry.get("replicas") or []):
                if not isinstance(replica, dict) or "egress_port" not in replica:
                    problems.append(f"{where} replica {j}: no egress_port")
                    continue
                port = replica.get("egress_port")
                if isinstance(port, bool) or not isinstance(port, int):
                    problems.append(f"{where} replica {j}: egress_port {port!r} is not a port "
                                    f"number")
                    continue
                if known and port not in known and port != cpu_port:
                    problems.append(
                        f"{where} replica {j}: egress_port {port} is neither a port s{dpid} has "
                        f"nor this package's bmv2.cpu_port ({cpu_port})")

    if not totals["multicast"] and not totals["clone"]:
        report.note("PRE entries", "none declared (no multicast group, no clone session)")
        return
    if problems:
        report.bad("PRE entries", f"{len(problems)} problem(s); first: {problems[0]}")
        for extra in problems[1:4]:
            report.bad("", extra)
        if len(problems) > 4:
            report.bad("", f"... and {len(problems) - 4} more")
    else:
        report.ok("PRE entries",
                  f"{totals['multicast']} multicast group(s) and {totals['clone']} clone "
                  f"session(s); every replica names a port the model builds")


# --- the per-switch pipeline (G4) --------------------------------------------------------------

def bmv2_json_names(bmv2):
    """(table names, action names) a compiled bmv2 JSON declares.

    Tables live under `pipelines[].tables[].name` (ingress and egress are separate pipelines)
    and actions at the top level. Both are the fully-qualified P4 names -- `MyIngress.ipv4_lpm`,
    `MyIngress.ipv4_forward`, `NoAction` -- which is the same spelling p4info's
    `preamble.name` uses, so the two are directly comparable.
    """
    tables = set()
    for pipe in bmv2.get("pipelines") or []:
        for table in (pipe or {}).get("tables") or []:
            if isinstance(table, dict) and table.get("name"):
                tables.add(table["name"])
    actions = {a["name"] for a in (bmv2.get("actions") or [])
               if isinstance(a, dict) and a.get("name")}
    return tables, actions


def _sha16(path):
    import hashlib

    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:16]


def pipeline_path_problem(package_dir, rel):
    """Why `rel` is not a usable pipeline path for this package, or None when it is.

    [Co-developed with claude code -- Adam]
    🔴 THE SAME THREE RULES THE LOADER ENFORCES, IN THE SAME ORDER -- relative, present, inside
    the package -- because a pre-flight that is more permissive than the loader is worse than no
    pre-flight at all. It hands an operator a green table and then `ndt up p4 --app <dir>` dies
    in `app_package.load` (p4_proxy/mininet/app_package.py, `_carried_by_the_package`), with
    `mn -c` possibly already run, over a package this tool just approved. The whole reason this
    file exists is to move refusals to the moment the operator is still holding the package.

    Absolute paths and `../` escapes are the two that matter: a pipeline is CARRIED BY the
    package, so that copying the package to another machine copies the program with it. One
    that points at `~/tutorials/exercises/firewall/build/firewall.json` passes every check on
    the machine that built it and loads a different program, or nothing, anywhere else.
    """
    if os.path.isabs(str(rel)):
        return (f"{rel} is an absolute path. A pipeline is carried by the package and named "
                f"relative to the package directory, so that moving the package moves the "
                f"program with it -- app_package.load refuses this, and this package would "
                f"fail at `ndt up p4 --app`, not here")
    path = os.path.join(package_dir, rel)
    if not os.path.isfile(path):
        return f"{rel} is not at {path}"
    root, real = os.path.realpath(package_dir), os.path.realpath(path)
    if not (real == root or real.startswith(root + os.sep)):
        return (f"{rel} resolves to {real}, which is OUTSIDE the package directory {root}. A "
                f"pipeline must be relative to the package and inside it -- app_package.load "
                f"refuses this, and this package would fail at `ndt up p4 --app`, not here")
    return None


def _check_pipelines(report, package_dir, package):
    """Each switch's own program. Returns {dpid: realpath of its p4info} for the ones that pass.

    [Co-developed with claude code -- Adam]
    🔴 THE TWO HALVES HAVE TO BE ONE COMPILE. bmv2 is launched with the json and the proxy
    pushes the p4info; if they came from different builds the switch runs one program while
    every table id, action id and field id the controller uses belongs to another. What that
    looks like afterwards is not a crash -- it is `INVALID_ARGUMENT` on some writes, silence on
    the rest, and a data plane that forwards the wrong traffic.

    There is no sha to compare them by: p4c writes no build id into either file, and the bmv2
    json's own sha is not even stable for one program (it embeds the absolute source path in
    `program`, so the same .p4 compiled in two directories gives two shas -- measured in
    TICKET-P1 B). What CAN be checked without running anything is containment: every table and
    every action the p4info names must exist in the json, because the json is the full program
    and the p4info is the externally-visible subset of it. A p4info from a different program
    almost always names something the json does not.

    The p4info's OWN sha is stable, and it is printed: it is the identifier to quote when
    asking "is this the program the entries were written for", and TICKET-P2 section 3.5 asks
    for it for exactly that reason. The json's `program` field -- an absolute path into
    whoever's home directory compiled it -- is printed as information, never compared.
    """
    switches = package.get("switches") or {}
    named = {k: (v or {}).get("pipeline") for k, v in switches.items()}
    named = {k: p for k, p in named.items() if p is not None}
    if not named:
        report.ok("switches pipeline", "all null (every switch runs NDTwin's own artefact)")
        return {}

    problems, resolved, notes = [], {}, []
    for key in sorted(named, key=lambda k: (int(k) if str(k).isdigit() else 1 << 30, str(k))):
        spec, where = named[key], f"s{key}"
        if not isinstance(spec, dict):
            problems.append(f"{where}: pipeline is a {type(spec).__name__}, not an object with "
                            f"'p4info' and 'bmv2_json'")
            continue
        absent = [k for k in ("p4info", "bmv2_json") if not spec.get(k)]
        if absent:
            problems.append(f"{where}: pipeline names no {absent}; both halves are required")
            continue
        paths = {}
        for k in ("p4info", "bmv2_json"):
            rel = spec[k]
            bad = pipeline_path_problem(package_dir, rel)
            if bad:
                problems.append(f"{where}: pipeline.{k} {bad}")
                continue
            paths[k] = os.path.join(package_dir, rel)
        if len(paths) != 2:
            continue
        try:
            index = P4InfoIndex.parse(paths["p4info"])
        except Exception as exc:  # noqa: BLE001 -- an unreadable p4info is a FAIL, not a crash
            problems.append(f"{where}: pipeline.p4info {spec['p4info']} does not parse: "
                            f"{type(exc).__name__}: {exc}")
            continue
        try:
            bmv2 = common.load_json(paths["bmv2_json"])
        except ValueError as exc:
            problems.append(f"{where}: pipeline.bmv2_json {spec['bmv2_json']} does not parse: "
                            f"{exc}")
            continue
        json_tables, json_actions = bmv2_json_names(bmv2)
        stray_tables = sorted({t.preamble.name for t in index.p4info.tables} - json_tables)
        stray_actions = sorted({a.preamble.name for a in index.p4info.actions} - json_actions)
        if stray_tables or stray_actions:
            problems.append(
                f"{where}: the p4info and the bmv2 json are not one compile -- the p4info names "
                f"table(s) {stray_tables[:3]} and action(s) {stray_actions[:3]} the json does "
                f"not have. bmv2 would run {os.path.basename(spec['bmv2_json'])} while every id "
                f"the controller writes came from {os.path.basename(spec['p4info'])}")
            continue
        resolved[str(key)] = os.path.realpath(paths["p4info"])
        notes.append((where, spec, paths, bmv2))

    if problems:
        report.bad("switches pipeline", f"{len(problems)} problem(s); first: {problems[0]}")
        for extra in problems[1:4]:
            report.bad("", extra)
        if len(problems) > 4:
            report.bad("", f"... and {len(problems) - 4} more")
    else:
        report.ok("switches pipeline",
                  f"{len(named)} of {len(switches)} switch(es) carry their own program; "
                  f"p4info tables and actions are all in the bmv2 json")
    for where, spec, paths, bmv2 in notes:
        sha = _sha16(paths["p4info"])
        report.note(f"{where} pipeline",
                    f"{spec['bmv2_json']}  p4info sha256:{sha}  "
                    f"program={bmv2.get('program')}")
    return resolved


def _check_entries_are_for_this_pipeline(report, used_p4info, pipeline_p4info):
    """The p4info an entries file names must be the p4info that switch's pipeline names.

    [Co-developed with claude code -- Adam]
    🔴 OTHERWISE THE ENTRIES WERE VALIDATED AGAINST A PROGRAM THE SWITCH IS NOT RUNNING, and
    every row above that says "entries match p4info" is true of the wrong thing. It is not
    hypothetical in this format: a tutorials `sX-runtime.json` names its p4info INSIDE the file
    (`"p4info": "build/basic.p4.p4info.txtpb"`), so firewall's s1 -- whose `program` is
    `build/firewall.json` -- is one edit away from carrying entries checked against `basic`.
    Compared by realpath, not by the strings: two spellings of one file are one file, and
    saying they disagree would be a refusal an operator cannot act on.

    Switches whose pipeline is null are not checked: they run NDTwin's own artefact, whose
    p4info an exercise's entries will never name, and stage two applies none of them there.
    """
    shared = sorted(set(used_p4info) & set(pipeline_p4info),
                    key=lambda k: (int(k) if str(k).isdigit() else 1 << 30, str(k)))
    if not shared:
        return
    wrong = [(k, used_p4info[k], pipeline_p4info[k]) for k in shared
             if used_p4info[k] != pipeline_p4info[k]]
    if wrong:
        key, used, want = wrong[0]
        report.bad("entries p4info is the pipeline's",
                   f"{len(wrong)} switch(es) disagree; s{key}'s entries were checked against "
                   f"{os.path.basename(used)} but that switch runs {os.path.basename(want)}. "
                   f"The rows above say those entries are valid -- for a program this switch "
                   f"is not running")
    else:
        report.ok("entries p4info is the pipeline's",
                  f"{len(shared)} switch(es); entries and pipeline name the same p4info")


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
    """Table entries against the p4info the exercise shipped them with.

    Returns {dpid as string: realpath of the p4info the entries named}, which
    `_check_entries_are_for_this_pipeline` compares against the switch's own pipeline.
    """
    switches = package.get("switches") or {}
    with_entries = {k: v for k, v in switches.items() if (v or {}).get("entries")}
    if not with_entries:
        mode = (package.get("control_plane") or {}).get("mode")
        report.note("entries", f"none (control plane '{mode}' brings its own)")
        _check_source_p4info(report, package_dir, package)
        return {}

    total, problems = 0, []
    parsed_any = False
    used_p4info = {}
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
        used_p4info[str(dpid)] = os.path.realpath(p4info_path)
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
    return used_p4info


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
