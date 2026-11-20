#!/usr/bin/env python3
"""Fixtures for the cells of test_ndt_up_down_robust.sh that run `ndt`'s fabric-record glue for real.

[Co-developed with claude code -- Adam]

  fabric_record_fixture.py package <dest>
      Lay down the four-switch app package the bring-up tests use (s1 runs its own program, the
      others another one, every switch has a runtime entries file) at <dest>.

  fabric_record_fixture.py record <repo> <package-dir> <record> <builder-pid> <telemetry-word>
      Plan the fabric the way the topology script does -- `<repo>/p4_proxy/mininet` is that
      script's own directory, so its knob, host count and bmv2 override are the fixture tree's --
      and write the build record with the topology script's own `write_fabric_record`, naming
      <builder-pid> as the process that built the fabric. The record is what a real bring-up
      leaves; the shell side then reads it with `ndt`'s functions.

Mininet is not installed where the suites run, so its modules are bare stand-ins, as in
p4_proxy/tests/test_fabric_bring_up.py. Standard library only.
"""

import importlib.util
import os
import shutil
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.normpath(os.path.join(HERE, "..", "..", "..", "p4_proxy", "tests"))


def install_mininet_stand_ins():
    class Base:
        def __init__(self, *args, **kwargs):
            pass

    modules = {
        "mininet": {},
        "mininet.net": {"Mininet": Base},
        "mininet.topo": {"Topo": Base},
        "mininet.node": {"Switch": Base, "Host": Base},
        "mininet.cli": {"CLI": Base},
        "mininet.log": {"setLogLevel": lambda *a, **k: None, "info": lambda *a, **k: None},
        "mininet.link": {"Intf": Base, "TCLink": Base},
    }
    for name, attrs in modules.items():
        module = types.ModuleType(name)
        for attr, value in attrs.items():
            setattr(module, attr, value)
        sys.modules[name] = module


def lay_out_package(dest):
    """The package fixture test_fabric_bring_up.py builds, copied to `dest` before this exits."""
    sys.path.insert(0, TESTS)
    import test_fabric_bring_up as bring_up          # noqa: E402  (installs its own stand-ins)
    package = bring_up.load_two_program_package_fixture()
    shutil.copytree(package.dir, dest)


def write_record(repo, package_dir, record, builder_pid, word):
    mininet = os.path.join(repo, "p4_proxy", "mininet")
    sys.path.insert(0, mininet)
    install_mininet_stand_ins()
    import app_package                                # noqa: E402
    import link_telemetry                             # noqa: E402
    path = os.path.join(mininet, "p4_testbed_topo.py")
    spec = importlib.util.spec_from_file_location("p4_testbed_topo", path)
    testbed = importlib.util.module_from_spec(spec)
    sys.modules["p4_testbed_topo"] = testbed
    spec.loader.exec_module(testbed)
    knob = record + ".telemetry"
    with open(knob, "w") as fh:
        fh.write(word + "\n")
    app_package.TELEMETRY_KNOB_PATH = knob
    plan = testbed.plan_fabric(package=app_package.load(package_dir), report=lambda _line: None)
    problem = testbed.write_fabric_record(
        plan.identity, path=record, builder=link_telemetry.process_identity(int(builder_pid)))
    if problem:
        sys.stderr.write(problem + "\n")
        raise SystemExit(1)


def main(argv):
    if len(argv) == 3 and argv[1] == "package":
        lay_out_package(argv[2])
    elif len(argv) == 7 and argv[1] == "record":
        write_record(*argv[2:])
    else:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
