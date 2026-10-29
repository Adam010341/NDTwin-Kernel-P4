#!/usr/bin/env python3
"""Turn a built p4lang-tutorials exercise into a generated app package, for `ndt up p4 --app`.

[Co-developed with claude code -- Adam]

    tools/p4_exercise/one_step.py <exercise_dir> [--run-dir <repo>/.test_run]
        [--topology pod-topo/topology.json] [--p4 basic.p4]
        [--role-ipv4-route [owner=,]table=,match_field=,action=,dst_mac=,port= | --no-roles]
        [--owner package|ndtwin] [--in-use <package dir>] [--emit-path <file>]

`ndt up p4 --app <exercise dir>` runs this, then pre-flight on what it wrote, then the bring-up.
It is convert.py with the three things a user would otherwise type worked out:

  * the topology: `topology.json` at the top of the exercise, or `<subdir>/topology.json` one
    level down (pod-topo/, triangle-topo/, ...). Exactly one is used; several are refused with the
    list and the `--topology` flag that picks one.
  * the program: `--p4`, else the exercise Makefile's DEFAULT_PROG, else the one `*.p4` at the top
    of the exercise -- the same rule tutorials' utils/Makefile applies to DEFAULT_PROG.
  * the route role: `convert.py --auto-role` (owner package, or `--owner ndtwin`), unless
    `--role-ipv4-route` names one or `--no-roles` asks for none.

The user still runs `make`. An unbuilt exercise is refused by convert.py, with the make command.

WHERE THE PACKAGE GOES: <run-dir>/packages/generated/<exercise name>-<8 hex digits>, the digits
being the start of the sha256 of the exercise's resolved path.
  * Never inside the exercise. It is the user's working copy, and its build/ belongs to `make`.
  * Under the run directory (.test_run/, which git ignores and which is per checkout), so a
    generated package is never committed by accident and never seen by another checkout's `ndt`.
    Under packages/ because that is where `ndt serve` admits `up --app` packages from by default.
  * Keyed by the resolved path, so two exercises that share a directory name do not share a
    package, and one exercise always lands in the same place.

A RE-RUN builds the new conversion beside the old one and compares the two file by file:
  * the same bytes: the old directory is kept as it is, and reported `unchanged`;
  * different: the new one replaces the old one whole, so no file of an earlier conversion
    survives into the new package -- unless the old one is the package the app-package knob names
    (`--in-use`), i.e. a fabric was brought up from it and has not been taken down. That is
    refused: those switches loaded the old program when they started and would go on running it
    under a package that no longer describes them. `ndt down` first.

Exit: 0 the package is ready (its path is printed, and written to --emit-path); 2 a usage error;
5 refused, and nothing was written.
"""
import argparse
import hashlib
import os
import re
import shutil
import sys
import tempfile

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from p4_exercise import common, convert
else:
    from . import common, convert

#: The exit codes, the same words `ndt` uses: 5 means a guard refused and nothing was built.
RC_OK, RC_USAGE, RC_REFUSED = 0, 2, 5

#: Subdirectories that never hold an exercise's topology: what `make` writes, and the model
#: directory of a package (a package's ndtwin/topology.json is NDTwin's format, not tutorials').
NOT_TOPOLOGY_DIRS = ("build", "logs", "pcaps", "ndtwin")

#: The flag that picks one topology when an exercise has several; named in the refusal.
TOPOLOGY_FLAG = "--topology"


def topology_candidates(exercise_dir):
    """The exercise-relative topology.json files the exercise offers, sorted."""
    out = []
    if os.path.isfile(os.path.join(exercise_dir, "topology.json")):
        out.append("topology.json")
    try:
        names = sorted(os.listdir(exercise_dir))
    except OSError:
        names = []
    for name in names:
        if name.startswith(".") or name in NOT_TOPOLOGY_DIRS:
            continue
        if os.path.isfile(os.path.join(exercise_dir, name, "topology.json")):
            out.append(f"{name}/topology.json")
    return out


_MAKE_VAR = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*[:?]?=\s*(.*?)\s*(?:#.*)?$")


def makefile_var(exercise_dir, name):
    """The plain value the exercise's Makefile assigns to `name`, or None.

    Only a literal value counts: one built from `$(...)` is the Makefile's own computation and is
    not reproduced here.
    """
    try:
        with open(os.path.join(exercise_dir, "Makefile"), encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    for line in lines:
        m = _MAKE_VAR.match(line)
        if m and m.group(1) == name and m.group(2) and "$" not in m.group(2):
            return m.group(2)
    return None


def choose_topology(exercise_dir, given=None):
    """(topology_rel, how it was chosen). Several candidates and no `given` are refused."""
    if given:
        return given, f"{TOPOLOGY_FLAG}"
    found = topology_candidates(exercise_dir)
    if len(found) == 1:
        return found[0], "the only one"
    if not found:
        raise convert.ConversionError(
            f"{exercise_dir} is neither an app package (no package.json) nor a p4lang-tutorials "
            f"exercise (no topology.json at its top or one directory down)")
    make_topo = makefile_var(exercise_dir, "TOPO")
    listing = ", ".join(f"{rel} (the Makefile's TOPO)" if rel == make_topo else rel
                        for rel in found)
    pick = make_topo if make_topo in found else found[0]
    raise convert.ConversionError(
        f"{exercise_dir} has {len(found)} topologies: {listing}. Pick one with "
        f"{TOPOLOGY_FLAG}, for example  {TOPOLOGY_FLAG} {pick}")


def choose_p4(exercise_dir, given=None):
    """(p4_rel, how it was chosen): --p4, the Makefile's DEFAULT_PROG, or the one top-level .p4."""
    if given:
        return given, "--p4"
    default = makefile_var(exercise_dir, "DEFAULT_PROG")
    if default:
        if not os.path.isfile(os.path.join(exercise_dir, default)):
            raise convert.ConversionError(
                f"the Makefile's DEFAULT_PROG is {default}, which is not in {exercise_dir}. "
                f"Name the program with --p4")
        return default, "the Makefile's DEFAULT_PROG"
    try:
        found = sorted(n for n in os.listdir(exercise_dir) if n.endswith(".p4")
                       and os.path.isfile(os.path.join(exercise_dir, n)))
    except OSError:
        found = []
    if len(found) == 1:
        return found[0], "the only .p4 at the top"
    if not found:
        raise convert.ConversionError(
            f"{exercise_dir} has no .p4 program at its top. Name it with --p4, for example  "
            f"--p4 solution/<name>.p4")
    raise convert.ConversionError(
        f"{exercise_dir} has {len(found)} .p4 programs at its top ({', '.join(found)}) and its "
        f"Makefile sets no DEFAULT_PROG. Name the one every switch runs with --p4, for example  "
        f"--p4 {found[0]}")


def generated_dir(run_dir, exercise_dir):
    """Where the package generated from `exercise_dir` lives. See the module docstring."""
    real = os.path.realpath(exercise_dir)
    digest = hashlib.sha256(real.encode("utf-8")).hexdigest()[:8]
    return os.path.join(os.path.abspath(run_dir), "packages", "generated",
                        f"{os.path.basename(real) or 'exercise'}-{digest}")


def _tree(root):
    """{relative path: sha256} of every file under root."""
    out = {}
    for d, _subdirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, root)] = hashlib.sha256(fh.read()).hexdigest()
    return out


def _same_dir(a, b):
    return bool(a) and bool(b) and os.path.realpath(a) == os.path.realpath(b)


def prepare(exercise_dir, run_dir, topology=None, p4=None, role_text=None, owner=None,
            no_roles=False, in_use=None):
    """Convert, compare with the last conversion, and put the package in place.

    Returns a dict: dest, state (created | replaced | unchanged), topology, topology_how, p4,
    p4_how, package, auto (auto_route_role's answer, {} when it did not run), role_source
    (auto | flag | none). Raises convert.ConversionError for every refusal; by then nothing has
    been written but the (empty) parent directory and a staging directory it has removed.
    """
    exercise_dir = os.path.abspath(exercise_dir)
    if not os.path.isdir(exercise_dir):
        raise convert.ConversionError(f"no exercise directory at {exercise_dir}")
    if os.path.isfile(os.path.join(exercise_dir, "package.json")):
        raise convert.ConversionError(
            f"{exercise_dir} already is an app package (it has package.json); bring it up as it "
            f"is, without the exercise flags")
    topology_rel, topology_how = choose_topology(exercise_dir, topology)
    p4_rel, p4_how = choose_p4(exercise_dir, p4)
    role = None if role_text is None else convert.parse_role_flag(role_text, owner=owner)
    dest = generated_dir(run_dir, exercise_dir)
    real_ex = os.path.realpath(exercise_dir)
    if os.path.realpath(dest) == real_ex or os.path.realpath(dest).startswith(real_ex + os.sep):
        raise convert.ConversionError(
            f"the generated package would be written inside the exercise ({dest}); this tool "
            f"never writes there. Run it from a checkout outside {exercise_dir}")
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    staging = tempfile.mkdtemp(prefix=os.path.basename(dest) + ".new-", dir=parent)
    try:
        auto = {}
        package, _model, _written = convert.convert(
            exercise_dir, topology_rel, staging, p4_rel=p4_rel, role_ipv4_route=role,
            auto_role=(role is None and not no_roles), owner=owner, auto_report=auto)
        if os.path.lexists(dest) and not os.path.isdir(dest):
            raise convert.ConversionError(f"{dest} exists and is not a directory; remove it")
        if os.path.isdir(dest) and _tree(dest) == _tree(staging):
            state = "unchanged"
        elif os.path.isdir(dest) and _same_dir(dest, in_use):
            raise convert.ConversionError(
                f"the exercise converts to a package different from {dest}, and that package is "
                f"the one p4_proxy/mininet/app_package_override names: a fabric was brought up "
                f"from it and not taken down, and its switches run the program they loaded then. "
                f"Take it down first:  ndt down")
        elif os.path.isdir(dest):
            old = tempfile.mkdtemp(prefix=os.path.basename(dest) + ".old-", dir=parent)
            os.rename(dest, os.path.join(old, "pkg"))
            os.rename(staging, dest)
            shutil.rmtree(old, ignore_errors=True)
            state = "replaced"
        else:
            os.rename(staging, dest)
            state = "created"
    finally:
        if os.path.isdir(staging):
            shutil.rmtree(staging, ignore_errors=True)
    if role is not None:
        role_source = "flag"
    elif auto.get("role") is not None:
        role_source = "auto"
    else:
        role_source = "none"
    return {"dest": dest, "state": state, "topology": topology_rel, "topology_how": topology_how,
            "p4": p4_rel, "p4_how": p4_how, "package": package, "auto": auto,
            "role_source": role_source}


def report_lines(result, no_roles=False):
    """What `ndt up p4 --app <exercise>` prints about the conversion."""
    package = result["package"]
    switches = package["switches"]
    lines = [f"  topology      : {result['topology']}   ({result['topology_how']})",
             f"  program       : {result['p4']}   ({result['p4_how']})",
             "  pipelines     : " + ", ".join(
                 f"{switches[k]['name']}="
                 + (switches[k]["pipeline"]["bmv2_json"] if switches[k]["pipeline"]
                    else "NDTwin's own")
                 for k in sorted(switches, key=int)),
             f"  control plane : {package['control_plane']['mode']}"]
    route = (package.get("roles") or {}).get("ipv4_route")
    if result["role_source"] == "flag":
        lines.append(f"  route role    : from --role-ipv4-route: "
                     f"{convert._describe_candidate(route)}, owner {route['owner']}")
    elif result["role_source"] == "auto":
        lines += convert.auto_role_lines(result["auto"])
        lines.append(f"                  owner {route['owner']}"
                     + ("  (NDTwin only reads this table, to compute flow paths)"
                        if route["owner"] == "package" else "  (NDTwin writes this table)")
                     + "; override with --role-ipv4-route, or --no-roles")
    elif no_roles:
        lines.append("  route role    : none -- --no-roles was given")
        own = any(s.get("pipeline") for s in switches.values())
        if own and package["control_plane"]["mode"] != "external":
            lines.append(f"  WARNING       : {convert.NO_PATHS_WARNING}")
    else:
        lines += convert.auto_role_lines(result["auto"])
    lines.append(f"  package       : {result['dest']}   ({result['state']})")
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("exercise_dir")
    ap.add_argument("--run-dir", default=os.path.join(common.REPO, ".test_run"),
                    help="the checkout's run directory (default <repo>/.test_run)")
    ap.add_argument("--topology", default=None,
                    help="the tutorials topology.json, relative to the exercise; needed only "
                         "when the exercise has several")
    ap.add_argument("--p4", default=None,
                    help="the .p4 every switch runs, relative to the exercise (default: the "
                         "Makefile's DEFAULT_PROG, else the one .p4 at its top)")
    ap.add_argument("--role-ipv4-route", default=None,
                    metavar="[owner=,]table=,match_field=,action=,dst_mac=,port=",
                    help="the forwarding table's role, written out; wins over the auto-filled one")
    ap.add_argument("--owner", default=None, choices=convert.ROLE_OWNERS,
                    help="owner of the route role (default package: NDTwin only reads the table)")
    ap.add_argument("--no-roles", action="store_true",
                    help="declare no route role, even when the p4info has one candidate")
    ap.add_argument("--in-use", default=None,
                    help="the package the app-package knob names; it is never replaced")
    ap.add_argument("--emit-path", default=None,
                    help="also write the package's path to this file")
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return RC_USAGE if exc.code else RC_OK
    # An empty value is a typo, not "no flag": taken as one, --topology "" would quietly fall
    # back to the candidate search the operator was trying to override.
    for flag, value in (("--topology", args.topology), ("--p4", args.p4),
                        ("--role-ipv4-route", args.role_ipv4_route)):
        if value is not None and not value.strip():
            print(f"usage: {flag} was given an empty value", file=sys.stderr)
            return RC_USAGE
    if args.no_roles and (args.role_ipv4_route is not None or args.owner is not None):
        print("usage: --no-roles declares no route role, so it cannot be given with "
              "--role-ipv4-route or --owner", file=sys.stderr)
        return RC_USAGE

    print(f"  exercise      : {os.path.abspath(args.exercise_dir)}")
    try:
        result = prepare(args.exercise_dir, args.run_dir, topology=args.topology, p4=args.p4,
                         role_text=args.role_ipv4_route, owner=args.owner,
                         no_roles=args.no_roles, in_use=args.in_use)
    except convert.ConversionError as exc:
        print(f"REFUSED: {exc}")
        return RC_REFUSED
    for line in report_lines(result, no_roles=args.no_roles):
        print(line)
    if args.emit_path:
        with open(args.emit_path, "w", encoding="utf-8") as fh:
            fh.write(result["dest"] + "\n")
    return RC_OK


if __name__ == "__main__":
    sys.exit(main())
