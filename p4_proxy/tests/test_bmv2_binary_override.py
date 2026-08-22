#!/usr/bin/env python3
"""
The bmv2 binary-override seam: resolve_bmv2_launcher / bmv2_launch_head, and their wiring
into BMv2Switch.start().

[Co-developed with claude code -- Adam]

Contract under test (from the seam's stated purpose, the A/B performance plan in
doc/2026-08-15_bmv2-performance-report.md):
  * no override file        -> stock bare name, no LD_LIBRARY_PATH (pre-seam behavior)
  * valid override          -> that binary; sibling ../lib auto-derived when present
  * commented-out override  -> stock (commenting the line out disables the override)
  * broken override         -> raises; NEVER silently falls back to the stock binary,
                               because that would produce "fast" numbers measured on the
                               slow build
  * start() wiring          -> the composed shell command actually begins with the
                               resolved head (a seam that exists but is not wired is the
                               known failure shape here)
"""

import importlib.util
import os
import shutil
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


class _StubSwitch:
    """Just enough of mininet.node.Switch for BMv2Switch.start() to run."""

    def __init__(self, name, **kwargs):
        self.name = name
        self.intfs = {}

    def cmd(self, line):
        self.last_cmd = line
        return "12345\n"


def load_testbed_module():
    """
    Import p4_testbed_topo.py with mininet stubbed out, under a name of our own.

    The Switch stub is a superset of the bare-type stubs test_readopt.py installs (it adds
    __init__ and cmd, which start() needs); installing it unconditionally is safe for the
    other file, which only needs the modules to be importable.
    """
    stubs = {
        "mininet": {},
        "mininet.net": {"Mininet": type("Mininet", (), {})},
        "mininet.topo": {"Topo": type("Topo", (), {"__init__": lambda self, **kw: None,
                                                   "addSwitch": lambda self, *a, **kw: None,
                                                   "addHost": lambda self, *a, **kw: None,
                                                   "addLink": lambda self, *a, **kw: None})},
        "mininet.node": {"Switch": _StubSwitch, "Host": type("Host", (), {})},
        "mininet.cli": {"CLI": type("CLI", (), {})},
        "mininet.log": {"setLogLevel": lambda *a, **k: None,
                        "info": lambda *a, **k: None},
    }
    for name, attrs in stubs.items():
        mod = sys.modules.get(name) or types.ModuleType(name)
        for attr, value in attrs.items():
            setattr(mod, attr, value)
        sys.modules[name] = mod
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "mininet", "p4_testbed_topo.py")
    spec = importlib.util.spec_from_file_location("p4_testbed_topo_override_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


topo = load_testbed_module()


class ResolveLauncherTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bmv2_override_test.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def make_prefix(self, with_lib=True):
        """A fake install prefix: <tmp>/prefix/bin/simple_switch_grpc (+x), optional lib/."""
        bin_dir = os.path.join(self.tmp, "prefix", "bin")
        os.makedirs(bin_dir)
        binary = os.path.join(bin_dir, "simple_switch_grpc")
        with open(binary, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(binary, 0o755)
        if with_lib:
            os.makedirs(os.path.join(self.tmp, "prefix", "lib"))
        return binary

    def override(self, content):
        path = os.path.join(self.tmp, "bmv2_binary_override")
        with open(path, "w") as fh:
            fh.write(content)
        return path

    def test_absent_file_refuses_instead_of_falling_back(self):
        # Was: an absent file selected the bare name, PATH lookup, the stock -O0 build --
        # silently. Both installs answer --version identically and differ ~10x in throughput,
        # so the fallback produced a plausible wrong number that read as "the fabric was busy".
        # Since 2026-08-22 the fast build is the default and the fallback is gone in BOTH
        # directions: silence would now hand the fast binary to someone who wanted stock.
        missing = os.path.join(self.tmp, "no_such_file")
        with self.assertRaises(ValueError) as ctx:
            topo.resolve_bmv2_launcher(missing)
        msg = str(ctx.exception)
        self.assertIn(missing, msg,
                      "the refusal does not say which file is missing")
        self.assertIn("simple_switch_grpc", msg,
                      "the refusal does not show what a valid directive looks like")

    def test_valid_override_with_sibling_lib(self):
        binary = self.make_prefix(with_lib=True)
        got = topo.resolve_bmv2_launcher(self.override(binary + "\n"))
        self.assertEqual(got, (binary, os.path.join(self.tmp, "prefix", "lib")))

    def test_valid_override_without_lib_dir(self):
        binary = self.make_prefix(with_lib=False)
        self.assertEqual(topo.resolve_bmv2_launcher(self.override(binary + "\n")),
                         (binary, None))

    def test_comments_and_blanks_are_skipped(self):
        binary = self.make_prefix()
        path = self.override("# which build this fabric runs\n\n  \n" + binary + "\n")
        self.assertEqual(topo.resolve_bmv2_launcher(path)[0], binary)

    def test_directive_whitespace_is_stripped(self):
        binary = self.make_prefix()
        path = self.override("   " + binary + "   \n")
        self.assertEqual(topo.resolve_bmv2_launcher(path)[0], binary)

    def test_commented_out_directive_refuses(self):
        # The other half of the same silent path: a file that exists but says nothing. Commenting
        # the line out was the documented way to "go back to stock", which is exactly the gesture
        # that left no trace in the run's own data.
        binary = self.make_prefix()
        path = self.override("# " + binary + "\n")
        with self.assertRaises(ValueError) as ctx:
            topo.resolve_bmv2_launcher(path)
        self.assertIn(path, str(ctx.exception),
                      "the refusal does not name the file that has no directive")

    def test_relative_path_raises_even_when_it_resolves_from_cwd(self):
        """
        The directive must be absolute so the choice cannot depend on the launcher's cwd.
        The relative path here really exists and is executable relative to the test's cwd
        -- the one case where dropping the absolute-path check would not be caught by the
        executable check behind it.
        """
        binary = self.make_prefix()
        cwd = os.getcwd()
        self.addCleanup(os.chdir, cwd)
        os.chdir(self.tmp)
        rel = os.path.relpath(binary, self.tmp)
        self.assertTrue(os.access(rel, os.X_OK))  # the trap is armed
        with self.assertRaises(ValueError):
            topo.resolve_bmv2_launcher(self.override(rel + "\n"))

    def test_missing_binary_raises(self):
        ghost = os.path.join(self.tmp, "prefix", "bin", "simple_switch_grpc")
        with self.assertRaises(ValueError):
            topo.resolve_bmv2_launcher(self.override(ghost + "\n"))

    def test_non_executable_binary_raises(self):
        binary = self.make_prefix()
        os.chmod(binary, 0o644)
        with self.assertRaises(ValueError):
            topo.resolve_bmv2_launcher(self.override(binary + "\n"))


class LaunchHeadTest(unittest.TestCase):
    def test_head_without_lib_dir_is_binary_alone(self):
        self.assertEqual(topo.bmv2_launch_head("simple_switch_grpc", None),
                         "simple_switch_grpc")

    def test_head_with_lib_dir_carries_env_prefix(self):
        self.assertEqual(
            topo.bmv2_launch_head("/opt/fast/bin/simple_switch_grpc", "/opt/fast/lib"),
            "LD_LIBRARY_PATH=/opt/fast/lib /opt/fast/bin/simple_switch_grpc")


class StartWiringTest(unittest.TestCase):
    """The seam must be what start() actually launches, not merely exist beside it."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bmv2_override_wiring.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def start_switch(self):
        sw = topo.BMv2Switch("s1", json_path="/tmp/prog.json",
                             device_id=3, grpc_port=50053, thrift_port=9093)
        sw.start(controllers=[])
        return sw

    def test_launch_refuses_when_the_override_is_absent(self):
        # End to end, through start(): a fabric with no directive must not come up at all.
        # It used to come up on the stock binary and look completely normal.
        original = topo.BINARY_OVERRIDE_PATH
        topo.BINARY_OVERRIDE_PATH = os.path.join(self.tmp, "absent")
        self.addCleanup(setattr, topo, "BINARY_OVERRIDE_PATH", original)
        with self.assertRaises(ValueError):
            self.start_switch()

    def test_override_reaches_the_launch_command(self):
        bin_dir = os.path.join(self.tmp, "prefix", "bin")
        os.makedirs(bin_dir)
        binary = os.path.join(bin_dir, "simple_switch_grpc")
        with open(binary, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(binary, 0o755)
        os.makedirs(os.path.join(self.tmp, "prefix", "lib"))
        override = os.path.join(self.tmp, "bmv2_binary_override")
        with open(override, "w") as fh:
            fh.write(binary + "\n")

        original = topo.BINARY_OVERRIDE_PATH
        topo.BINARY_OVERRIDE_PATH = override
        self.addCleanup(setattr, topo, "BINARY_OVERRIDE_PATH", original)
        sw = self.start_switch()
        lib_dir = os.path.join(self.tmp, "prefix", "lib")
        self.assertTrue(
            sw.last_cmd.startswith(f"LD_LIBRARY_PATH={lib_dir} {binary} "),
            f"launch command does not begin with the override head: {sw.last_cmd!r}")
        self.assertIn(f"LD_LIBRARY_PATH={lib_dir} {binary}", sw.launch_argv)


if __name__ == "__main__":
    unittest.main()
