#!/usr/bin/env python3
"""Turn a built p4lang-tutorials exercise into a generated app package, for `ndt up p4 --app`.

[Co-developed with claude code -- Adam]

    tools/p4_exercise/one_step.py <exercise_dir> [--run-dir <repo>/.test_run]
        [--topology pod-topo/topology.json] [--p4 basic.p4]
        [--role-ipv4-route [owner=,]table=,match_field=,action=,dst_mac=,port= | --no-roles]
        [--table-owner package|ndtwin] [--mode auto|ndtwin|external]
        [--in-use <package dir>] [--emit-path <file>]

`ndt up p4 --app <exercise dir>` runs this, then pre-flight on what it wrote, then the bring-up.
It is convert.py with the three things a user would otherwise type worked out:

  * the topology: `--topology`, else the exercise Makefile's TOPO (what tutorials' own
    `make run` uses), else the only `topology.json` at the top of the exercise or one level down
    (pod-topo/, triangle-topo/, ...). Several and no TOPO are refused with the list and the
    `--topology` flag that picks one.
  * the program: `--p4`, else the Makefile's DEFAULT_PROG, else the one `*.p4` at the top of the
    exercise -- the rule tutorials' utils/Makefile applies to DEFAULT_PROG. Its stem picks the
    compiled build/<stem>.json and build/<stem>.p4.p4info.txtpb a switch runs unless the topology
    names that switch's own `program`.
  * the control plane: `--mode`, else auto -- external when the exercise has a mycontroller.py
    (its own controller programs the switches and the fabric comes up empty), NDTwin's otherwise.
    Which one it was, and why, is printed.
  * the route role: `convert.py --auto-role` (owner package, or `--table-owner ndtwin`), unless
    `--role-ipv4-route` names one or `--no-roles` asks for none.

The user compiles the exercise with `make build`, which only compiles. (The Makefile's default
target also starts tutorials' own Mininet under sudo, beside NDTwin's fabric.) An unbuilt exercise
is refused by convert.py, with that command.

WHERE THE PACKAGE GOES: <run-dir>/packages/generated/<exercise name>-<8 hex digits>, the digits
being the start of the sha256 of the exercise's resolved path.
  * Never inside the exercise. It is the user's working copy, and its build/ belongs to `make`.
  * Under the run directory (.test_run/, which git ignores and which is per checkout), so a
    generated package is never committed by accident and never seen by another checkout's `ndt`.
    Under packages/ because that is where `ndt serve` admits `up --app` packages from by default.
  * Keyed by the resolved path, so two exercises that share a directory name do not share a
    package, one exercise always lands in the same place, and a symlinked path to it is the same
    exercise.

A RE-RUN converts into <run-dir>/packages-staging/ (outside packages/, so `ndt serve` can never be
pointed at a half-written package) and compares the result with the last one file by file:
  * the same bytes: the old directory is kept as it is, and reported `unchanged`;
  * different: the new one replaces the old one whole, so no file of an earlier conversion
    survives into the new package -- unless the old one is the package the app-package knob names
    (`--in-use`), i.e. a fabric was brought up from it and has not been taken down. That is
    refused: those switches loaded the old program when they started and would go on running it
    under a package that no longer describes them. `ndt down` first.
Staging directories a killed run left behind for the same exercise are removed first.

Exit: 0 the package is ready (its path is printed, and written to --emit-path); 2 a usage error
(a malformed or conflicting flag, or an exercise path with a line break in it); 5 refused, and no
package was written.
"""
import argparse
import errno
import glob
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
#: `ndt`'s app_is_exercise skips the same four.
NOT_TOPOLOGY_DIRS = ("build", "logs", "pcaps", "ndtwin")

#: What convert.py writes besides the copies: a directory holding this but no package.json is a
#: package that lost its manifest, not an exercise.
PACKAGE_MODEL = os.path.join("ndtwin", "topology.json")

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


def makefile_assignment(exercise_dir, name):
    """What the exercise's Makefile assigns to `name`, as written, or None when it assigns nothing."""
    try:
        with open(os.path.join(exercise_dir, "Makefile"), encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    for line in lines:
        m = _MAKE_VAR.match(line)
        if m and m.group(1) == name and m.group(2):
            return m.group(2)
    return None


def makefile_var(exercise_dir, name):
    """The plain value the exercise's Makefile assigns to `name`, or None.

    Only a literal value counts: one built from `$(...)` is the Makefile's own computation and is
    not reproduced here.
    """
    value = makefile_assignment(exercise_dir, name)
    return value if value is not None and "$" not in value else None


def _package_path(rel, what):
    """`rel`, if convert.py would copy it to a path inside the package; else refused, naming
    `what`. The question is where the copy lands -- the path as written, normalised -- not where
    the file resolves: a topology reached through a symlinked directory of the exercise is copied
    inside the package wherever the link points. [Co-developed with claude code -- Adam]"""
    return convert.package_relative(rel, what)


def choose_topology(exercise_dir, given=None):
    """(topology_rel, how it was chosen): --topology, the Makefile's TOPO, or the only one."""
    if given:
        return _package_path(given, TOPOLOGY_FLAG), f"{TOPOLOGY_FLAG}"
    found = topology_candidates(exercise_dir)
    if not found:
        raise convert.ConversionError(
            f"{exercise_dir} is neither an app package (no package.json) nor a p4lang-tutorials "
            f"exercise (no topology.json at its top or one directory down)")
    make_topo = makefile_var(exercise_dir, "TOPO")
    if make_topo:
        _package_path(make_topo, "the Makefile's TOPO")
        if not os.path.isfile(os.path.join(exercise_dir, make_topo)):
            raise convert.ConversionError(
                f"the Makefile's TOPO is {make_topo}, which is not in {exercise_dir}. Pick the "
                f"topology with {TOPOLOGY_FLAG}, for example  {TOPOLOGY_FLAG} {found[0]}")
        return make_topo, "the Makefile's TOPO"
    if len(found) == 1:
        return found[0], "the only one"
    computed = makefile_assignment(exercise_dir, "TOPO")
    why = (f"its Makefile computes TOPO ({computed}), which this tool does not evaluate"
           if computed else "its Makefile sets no TOPO")
    raise convert.ConversionError(
        f"{exercise_dir} has {len(found)} topologies ({', '.join(found)}) and {why}. Pick one "
        f"with {TOPOLOGY_FLAG}, for example  {TOPOLOGY_FLAG} {found[0]}")


def choose_p4(exercise_dir, given=None):
    """(p4_rel, how it was chosen): --p4, the Makefile's DEFAULT_PROG, or the one top-level .p4."""
    if given:
        return _package_path(given, "--p4"), "--p4"
    default = makefile_var(exercise_dir, "DEFAULT_PROG")
    if default:
        _package_path(default, "the Makefile's DEFAULT_PROG")
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


def staging_root(run_dir):
    """Where conversions are built before they are put in place: outside packages/."""
    return os.path.join(os.path.abspath(run_dir), "packages-staging")


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


def _same_filesystem(a, b):
    """Whether two existing directories are on one filesystem, so a rename between them is one
    step. [Co-developed with claude code -- Adam]"""
    return os.stat(a).st_dev == os.stat(b).st_dev


def _move(src, dst):
    """os.rename, with a failure said as a refusal that names the cause instead of a traceback."""
    try:
        os.rename(src, dst)
    except OSError as exc:
        # Only EXDEV is a second filesystem; anything else (a destination that appeared, a
        # source that went away) is said as what it is. [Co-developed with claude code -- Adam]
        why = (". The conversion is moved into place in one rename, which needs the run "
               "directory's packages/ and packages-staging/ on one filesystem"
               if exc.errno == errno.EXDEV else "")
        raise convert.ConversionError(
            f"could not move {src} to {dst}: {errno.errorcode.get(exc.errno, exc.errno)} "
            f"({exc.strerror or exc}){why}") from exc


def prepare(exercise_dir, run_dir, topology=None, p4=None, role_text=None, owner=None,
            no_roles=False, in_use=None, mode="auto"):
    """Convert, compare with the last conversion, and put the package in place.

    Returns a dict: dest, state (created | replaced | unchanged), topology, topology_how, p4,
    p4_how, package, auto (auto_route_role's answer, {} when it did not run), role_source
    (auto | flag | none), removed ({dpid: entries taken out of an owner-ndtwin table}), mode_how
    (why the control plane is what it is). `mode` is convert's: auto, ndtwin or external. Raises
    convert.ConversionError for every refusal; by then no package has been written (only the
    empty parent directories, and a staging directory that has been removed again).
    """
    # The resolved path from here on: a symlink to the exercise and the exercise itself are one
    # exercise, so they convert to the same bytes (package.json records this path) and compare
    # `unchanged`.
    exercise_dir = os.path.realpath(exercise_dir)
    if not os.path.isdir(exercise_dir):
        raise convert.ConversionError(f"no exercise directory at {exercise_dir}")
    if os.path.isfile(os.path.join(exercise_dir, "package.json")):
        raise convert.ConversionError(
            f"{exercise_dir} already is an app package (it has package.json); bring it up as it "
            f"is, without the exercise flags")
    if os.path.isfile(os.path.join(exercise_dir, PACKAGE_MODEL)):
        raise convert.ConversionError(
            f"{exercise_dir} has {PACKAGE_MODEL} but no package.json: it is an app package that "
            f"lost its manifest, not an exercise. Convert the exercise it came from again, or put "
            f"its package.json back")
    topology_rel, topology_how = choose_topology(exercise_dir, topology)
    p4_rel, p4_how = choose_p4(exercise_dir, p4)
    role = None if role_text is None else convert.parse_role_flag(role_text, owner=owner)
    dest = generated_dir(run_dir, exercise_dir)
    if os.path.realpath(dest).startswith(exercise_dir + os.sep):
        raise convert.ConversionError(
            f"the generated package would be written inside the exercise ({dest}); this tool "
            f"never writes there. Run it from a checkout outside {exercise_dir}")
    stage_root = staging_root(run_dir)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    os.makedirs(stage_root, exist_ok=True)
    if not _same_filesystem(stage_root, os.path.dirname(dest)):
        # Refused before anything is converted: a rename across filesystems is a copy, and a
        # half-copied package in packages/generated/ is what staging exists to prevent.
        raise convert.ConversionError(
            f"{stage_root} and {os.path.dirname(dest)} are on two filesystems, so a conversion "
            f"cannot be put in place in one rename. Keep {os.path.join(run_dir, 'packages')} and "
            f"{stage_root} on one filesystem (do not mount or link one of them elsewhere)")
    # What a killed run of this same exercise left behind. Only this exercise's: another
    # exercise's conversion may be running beside this one.
    for stale in glob.glob(os.path.join(stage_root, glob.escape(os.path.basename(dest)) + ".*-*")):
        shutil.rmtree(stale, ignore_errors=True)
    staging = tempfile.mkdtemp(prefix=os.path.basename(dest) + ".new-", dir=stage_root)
    removed = {}
    try:
        auto = {}
        package, _model, _written = convert.convert(
            exercise_dir, topology_rel, staging, p4_rel=p4_rel, role_ipv4_route=role,
            auto_role=(role is None and not no_roles), owner=owner, auto_report=auto,
            removed=removed, mode=mode)
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
            old = tempfile.mkdtemp(prefix=os.path.basename(dest) + ".old-", dir=stage_root)
            try:
                _move(dest, os.path.join(old, "pkg"))
            except convert.ConversionError:
                os.rmdir(old)                                  # the empty directory made for it
                raise
            try:
                _move(staging, dest)
            except convert.ConversionError as exc:
                try:
                    os.rename(os.path.join(old, "pkg"), dest)     # the old package goes back
                except OSError as back:
                    raise convert.ConversionError(
                        f"{exc}; and the previous package could not be put back at {dest} "
                        f"({errno.errorcode.get(back.errno, back.errno)}): it was left at "
                        f"{os.path.join(old, 'pkg')}, and the next run of this exercise removes "
                        f"it -- copy it out first if it is needed") from back
                shutil.rmtree(old, ignore_errors=True)
                raise
            shutil.rmtree(old, ignore_errors=True)
            state = "replaced"
        else:
            _move(staging, dest)
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
    # [Co-developed with claude code -- Adam] Said, because `auto` decides it from one file name:
    # an exercise that ships a mycontroller.py comes up EMPTY unless told otherwise.
    if mode != "auto":
        mode_how = "--mode"
    elif package["control_plane"]["mode"] == "external":
        mode_how = ("mycontroller.py found: external; pass --mode ndtwin to let NDTwin install "
                    "routes")
    else:
        mode_how = "no mycontroller.py: NDTwin installs the routes"
    return {"mode_how": mode_how,
            "dest": dest, "state": state, "topology": topology_rel, "topology_how": topology_how,
            "p4": p4_rel, "p4_how": p4_how, "package": package, "auto": auto,
            "role_source": role_source, "removed": removed}


def _stripped_line(route, removed):
    """The line that says what owner ndtwin took out of the author's runtime files."""
    total = sum(removed.values())
    per = ", ".join(f"s{d}: {n}" for d, n in sorted(removed.items(), key=lambda kv: int(kv[0])))
    return (f"  stripped      : {total} match entr{'y' if total == 1 else 'ies'} of "
            f"{route['table']} taken out of the runtime files ({per or 'no switch had any'}), "
            f"because NDTwin owns that table; its default action stays")


def report_lines(result, no_roles=False):
    """What `ndt up p4 --app <exercise>` prints about the conversion.

    🔴 EVERY WAY OUT IS AN `ndt` FLAG. The user typed `ndt up p4 --app <exercise dir>` and never
    saw the generated package.json, so a hint to edit it would be a hint to edit a file the next
    run overwrites. Several candidates are printed as the --role-ipv4-route line that picks each.
    """
    package = result["package"]
    switches = package["switches"]
    lines = [f"  topology      : {result['topology']}   ({result['topology_how']})",
             f"  program       : {result['p4']}   ({result['p4_how']})",
             "  pipelines     : " + ", ".join(
                 f"{switches[k]['name']}="
                 + (switches[k]["pipeline"]["bmv2_json"] if switches[k]["pipeline"]
                    else "NDTwin's own")
                 for k in sorted(switches, key=int)),
             f"  control plane : {package['control_plane']['mode']}   ({result['mode_how']})"]
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
        candidates = (result["auto"] or {}).get("candidates") or []
        if len(candidates) > 1:
            lines.append("  to pick one   : add one of these to the ndt up command")
            lines += [f"                    --role-ipv4-route {convert.role_flag_text(c)}"
                      for c in candidates]
    if route is not None and route["owner"] == "ndtwin":
        lines.append(_stripped_line(route, result.get("removed") or {}))
    lines.append(f"  package       : {result['dest']}   ({result['state']})")
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("exercise_dir")
    ap.add_argument("--run-dir", default=os.path.join(common.REPO, ".test_run"),
                    help="the checkout's run directory (default <repo>/.test_run)")
    ap.add_argument("--topology", default=None,
                    help="the tutorials topology.json, relative to the exercise (default: the "
                         "Makefile's TOPO, else the only one)")
    ap.add_argument("--p4", default=None,
                    help="the exercise's default program, relative to the exercise: its stem "
                         "picks the compiled build/<stem>.json and build/<stem>.p4.p4info.txtpb "
                         "that every switch runs unless the topology names that switch's own "
                         "`program`, and the file itself is what pre-flight recompiles (default: "
                         "the Makefile's DEFAULT_PROG, else the one .p4 at its top)")
    ap.add_argument("--role-ipv4-route", default=None,
                    metavar="[owner=,]table=,match_field=,action=,dst_mac=,port=",
                    help="the forwarding table's role, written out; wins over the auto-filled one")
    ap.add_argument("--table-owner", default=None, choices=convert.ROLE_OWNERS,
                    help="who owns the forwarding table (default package: NDTwin only reads it). "
                         "ndtwin: NDTwin writes it, and the exercise's match entries for it are "
                         "taken out of the runtime files (the count is printed)")
    ap.add_argument("--mode", default="auto", choices=("auto", "ndtwin", "external"),
                    help="the control plane: ndtwin (NDTwin installs the routes), external (the "
                         "exercise's own mycontroller.py does), or auto (the default: external "
                         "when the exercise has a mycontroller.py)")
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
    # A newline in the path cannot be written to the app-package knob, which is one line. Asked of
    # the resolved path, which is the one written: a line break in what was typed is in it too.
    real = os.path.realpath(args.exercise_dir)
    if "\n" in real or "\r" in real:
        print("usage: the exercise path has, or resolves to one with, a line break in it",
              file=sys.stderr)
        return RC_USAGE
    if args.no_roles and (args.role_ipv4_route is not None or args.table_owner is not None):
        print("usage: --no-roles declares no route role, so it cannot be given with "
              "--role-ipv4-route or --table-owner", file=sys.stderr)
        return RC_USAGE
    if args.role_ipv4_route is not None:
        # Parsed here as well as in prepare(): a role that does not parse, or names an owner that
        # --table-owner contradicts, is a usage error (2), not a refusal of the exercise.
        try:
            convert.parse_role_flag(args.role_ipv4_route, owner=args.table_owner)
        except convert.ConversionError as exc:
            print(f"usage: {exc}", file=sys.stderr)
            return RC_USAGE

    print(f"  exercise      : {os.path.abspath(args.exercise_dir)}")
    try:
        result = prepare(args.exercise_dir, args.run_dir, topology=args.topology, p4=args.p4,
                         role_text=args.role_ipv4_route, owner=args.table_owner,
                         no_roles=args.no_roles, in_use=args.in_use, mode=args.mode)
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
