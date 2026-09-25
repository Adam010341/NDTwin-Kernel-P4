#!/usr/bin/env python3
"""compile -> convert -> pre-flight one tutorials exercise arm, exactly as 06 does it.

[Co-developed with claude code -- Adam]

    census_prepare.py <exercise> <solution|skeleton> <package dir>

The census has to run each exercise's OWN pipeline, and "the pipeline 06 runs" is whatever
drive_exercise.py's NDTwin path builds: pick_source, compile_prog, companion_programs,
convert_p4_arg and the EXERCISES table. They are imported and called here, not copied, so a
change to how 06 builds an arm is a change to what the census measures. Only the ORDER of the
calls is restated (run_on_ndtwin's first two steps), because the driver has no entry point that
builds a package and stops.

Prints one last line and exits:
    PREP OK <package>                      0  ready for `ndt up p4 --app`
    PREP NOT-BUILT <stage> rc=<n> [...]    3  the arm stops before a fabric exists -- for
                                              flowcache/skeleton (compile) and
                                              basic_tunnel/skeleton (pre-flight) that is the
                                              arm's DESIGNED red, the same as in 06
    PREP ERROR <why>                       2  anything else
Touches no lab: the compile writes the exercise's build/, the package goes where it is told.
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DRIVER_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "2026-09-04_p4-tutorial-exercise-prep"))
sys.path.insert(0, DRIVER_DIR)
sys.dont_write_bytecode = True          # no __pycache__ left beside the driver

import drive_exercise as de  # noqa: E402


def main(argv):
    if len(argv) != 4 or argv[2] not in ("solution", "skeleton"):
        print(__doc__, file=sys.stderr)
        return 2
    ex, which, pkg = argv[1], argv[2], os.path.abspath(argv[3])
    spec = de.EXERCISES.get(ex)
    if spec is None:
        print(f"PREP ERROR '{ex}' is not in drive_exercise.EXERCISES")
        return 2
    if not pkg.startswith(os.path.abspath(de.PKG_ROOT) + os.sep):
        print(f"PREP ERROR the package must go under {de.PKG_ROOT}, not {pkg}")
        return 2
    exdir = os.path.join(de.TUT, "exercises", ex)
    src, base = de.pick_source(exdir, spec, which)
    if src is None or not os.path.exists(src):
        print(f"PREP ERROR no .p4 source for {ex}/{which}")
        return 2
    red = spec.get("red_arm") if which == "skeleton" else None
    rc, _json, _info = de.compile_prog(exdir, src, base)
    if rc != 0:
        print(f"PREP NOT-BUILT compile rc={rc}" + (" (the arm's designed red)" if red == "compile" else ""))
        return 3
    for esrc, ebase in de.companion_programs(exdir, spec, which):
        erc, _j, _i = de.compile_prog(exdir, esrc, ebase)
        if erc != 0:
            print(f"PREP ERROR companion compile failed ({esrc}, rc {erc})")
            return 2
    if os.path.isdir(pkg):
        shutil.rmtree(pkg)
    os.makedirs(os.path.dirname(pkg), exist_ok=True)
    cmd = [de.PROXY_PY, de.CONVERT, exdir, "--topology", spec["topo"],
           "--p4", de.convert_p4_arg(exdir, spec, which), "--out", pkg]
    print("$ " + " ".join(cmd))
    rc, out = de.run(cmd, cwd=de.REPO, timeout=600)
    print(out[-3000:].rstrip())
    if rc != 0:
        print(f"PREP ERROR convert.py exited {rc}")
        return 2
    cmd = [de.PROXY_PY, de.PREFLIGHT, pkg]
    print("$ " + " ".join(cmd))
    rc, out = de.run(cmd, cwd=de.REPO, timeout=600)
    print(out[-3000:].rstrip())
    if rc != 0:
        print(f"PREP NOT-BUILT preflight rc={rc}" + (" (the arm's designed red)" if red == "entries" else ""))
        return 3
    print(f"PREP OK {pkg}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
