#!/usr/bin/env python3
"""Two versions of the structural instrument, one fixture: which keys can each of them SEE missing?

[Co-developed with claude code -- Adam]

Ruling 37(1): inventory.py used to union the three controls' control.meta into one file class,
so a key missing from C1 and C2 but present in C3 (`verdict`) could never surface. Round 9 showed
it by running the old and the new instrument over the same old fixture and the same real run --
and kept only the output (ruling 39(9b)). This is that comparison as a file:

  * the OLD side: inventory.py and tests/fixtures/real_run_inventory.json at --old-rev;
  * the NEW side: both as they are in this tree;
  * the fixture: tests/synthetic.py at --fixture-rev, built into a temp dir and inventoried by
    each instrument.

Usage:  tests/compare_inventory_instruments.py [--old-rev e222176d] [--fixture-rev f51ee88f]
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = "doc/audit/2026-09-19_telemetry-three-groups/tests/"


def show(revision, name):
    return subprocess.run(["git", "-C", HERE, "show", "%s:%s%s" % (revision, PREFIX, name)],
                          check=True, capture_output=True, text=True).stdout


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def missing_control_keys(instrument, fixture_root, real):
    mine = instrument.inventory(fixture_root)["file_keys"]
    rows = []
    for cls in sorted(real["file_keys"]):
        if not cls.startswith("control.meta"):
            continue
        rows.append((cls, sorted(set(real["file_keys"][cls]) - set(mine.get(cls, [])))))
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--old-rev", default="e222176d")
    parser.add_argument("--fixture-rev", default="f51ee88f")
    args = parser.parse_args(argv)
    with tempfile.TemporaryDirectory() as work:
        for name, revision in (("inventory_old.py", args.old_rev),
                               ("synthetic_old.py", args.fixture_rev)):
            source = show(revision, name.replace("_old", ""))
            with open(os.path.join(work, name), "w") as fh:
                fh.write(source)
        old_real = json.loads(show(args.old_rev, "fixtures/real_run_inventory.json"))
        with open(os.path.join(HERE, "fixtures", "real_run_inventory.json")) as fh:
            new_real = json.load(fh)
        old_instrument = load(os.path.join(work, "inventory_old.py"), "inventory_old")
        sys.path.insert(0, HERE)
        new_instrument = load(os.path.join(HERE, "inventory.py"), "inventory_new")
        fixture = load(os.path.join(work, "synthetic_old.py"), "synthetic_old")
        root = os.path.join(work, "fixture")
        fixture.build(root)
        print("fixture:     tests/synthetic.py at %s" % args.fixture_rev)
        print("OLD instrument (inventory.py + real_run_inventory.json at %s):" % args.old_rev)
        for cls, missing in missing_control_keys(old_instrument, root, old_real):
            print("   %-20s missing from the fixture: %s" % (cls, missing))
        print("NEW instrument (inventory.py + real_run_inventory.json in this tree):")
        for cls, missing in missing_control_keys(new_instrument, root, new_real):
            print("   %-20s missing from the fixture: %s" % (cls, missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
