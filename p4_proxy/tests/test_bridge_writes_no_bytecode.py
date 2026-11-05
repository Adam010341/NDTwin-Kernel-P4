"""The P4/NTG bridge must not leave bytecode in any tree it imports from.

[Co-developed with claude code -- Adam]

The bridge (p4_proxy/mininet/ntg_bmv2_topo.py) runs as root. It imports the modules next to it
and, after changing into the NTG checkout, NTG's own `network_traffic_generator`; it also starts
the link-telemetry emitter, which is another Python that imports from this checkout. Python
writes `__pycache__/*.pyc` beside every module it imports, so those trees -- owned by whoever
cloned them -- fill with root-owned directories, and a later `rm -rf` of the NTG checkout by its
owner fails on them.

The fix is two lines at the top of the bridge: `sys.dont_write_bytecode = True` for this process
and `PYTHONDONTWRITEBYTECODE=1` in the environment for the children it starts (the flag is a
per-process setting and is not inherited).

HOW THIS TEST SEES IT. Each case runs a fresh interpreter over throwaway copies of the files the
bridge imports and a fixture NTG directory (a tiny network_traffic_generator.py that imports a
helper), executes the bridge's module-load path exactly as a script would (compiled and exec'd,
so the bridge's own file is not cached either), drives `run_ntg_cli` through both of its NTG
imports (the first, and the re-import after a crash), and, in the second test, starts the real
emitter with the bridge's own `link_telemetry.start_emitter`. Then it walks both trees for a
`__pycache__` directory or a `.pyc` file.

CONTROLS, because "no bytecode appeared" is also what a machine with bytecode writing switched
off for some other reason shows (developer shells and CI images often
export PYTHONDONTWRITEBYTECODE=1):
  * the child's environment is built from scratch -- no PYTHONDONTWRITEBYTECODE, no
    PYTHONPYCACHEPREFIX, no PYTHONPATH -- and the interpreter gets no -B, whatever this test
    process has; the child reports what it started with and every case asserts it;
  * `TheProbeCanSeeBytecodeTest` runs the same probe against a copy of the bridge with the two
    lines taken out and requires bytecode to appear in both trees: a probe that cannot see
    bytecode when it is there proves nothing when it sees none.

Run:  cd p4_proxy && PYTHONPATH=. venv/bin/python tests/test_bridge_writes_no_bytecode.py -v
Gate: NDTWIN_BRIDGE_UNDER_TEST=<copy of ntg_bmv2_topo.py> runs the cases against that copy;
      NDTWIN_MININET_UNDER_TEST=<dir holding copies of the other files the bridge imports> does
      the same for those (link_telemetry.py and the rest).
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
MININET_DIR = os.path.join(PROXY_DIR, "mininet")
PROXY_AGENT_DIR = os.path.join(PROXY_DIR, "proxy_agent")

BRIDGE = os.environ.get("NDTWIN_BRIDGE_UNDER_TEST") or os.path.join(MININET_DIR, "ntg_bmv2_topo.py")
SIBLINGS_DIR = os.environ.get("NDTWIN_MININET_UNDER_TEST") or MININET_DIR

# What the bridge imports in-process (and the emitter it launches), copied into the throwaway
# kernel tree. The bridge itself is copied from BRIDGE.
SIBLINGS = ["p4_testbed_topo.py", "topo_log.py", "ntg_config.py", "topo_from_json.py",
            "grpc_ports.py", "app_package.py", "link_telemetry.py", "psample_sflow_emitter.py"]
AGENT_FILES = ["sflow_emitter.py"]

DRIVER = r'''
import json, os, subprocess, sys, types

mode, kernel_dir, ntg_dir, scratch = sys.argv[1:5]

# What this interpreter started with; the test asserts it, so the cases cannot pass because
# bytecode writing was already off.
report = {
    "dont_write_bytecode": bool(sys.dont_write_bytecode),
    "flag": sys.flags.dont_write_bytecode,
    "env": os.environ.get("PYTHONDONTWRITEBYTECODE"),
    "pycache_prefix_env": os.environ.get("PYTHONPYCACHEPREFIX"),
    "pycache_prefix": sys.pycache_prefix,
}

# Mininet stubbed at sys.modules level (the way test_fabric_bring_up.py does): p4_testbed_topo
# imports it at module level and it is a system package.
def stub(name, **attrs):
    mod = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(mod, k, v)
    sys.modules[name] = mod
cls = lambda n: type(n, (), {})
stub("mininet")
stub("mininet.net", Mininet=cls("Mininet"))
stub("mininet.topo", Topo=cls("Topo"))
stub("mininet.node", Switch=cls("Switch"), Host=cls("Host"))
stub("mininet.cli", CLI=cls("CLI"))
stub("mininet.log", setLogLevel=lambda *a, **k: None, info=lambda *a, **k: None)
stub("mininet.link", Intf=cls("Intf"), TCLink=cls("TCLink"))

# The bridge's module-load path, as a script: compiled and exec'd, so the bridge's own file is
# not cached the way `import` would cache it (a script is never cached).
os.environ["NTG_DIR"] = ntg_dir
path = os.path.join(kernel_dir, "p4_proxy", "mininet", "ntg_bmv2_topo.py")
with open(path) as f:
    code = compile(f.read(), path, "exec")
bridge = types.ModuleType("bridge_probe")
bridge.__file__ = path
exec(code, bridge.__dict__)

report["env_after_bridge_top"] = os.environ.get("PYTHONDONTWRITEBYTECODE")
report["dont_write_bytecode_after_bridge_top"] = bool(sys.dont_write_bytecode)

if mode == "import":
    # run_ntg_cli: chdir + the import at the top of it, then the loop; the fixture's
    # command_line crashes once so the loop's re-import runs as well.
    bridge.PREPARED_CONFIG = "unused.yaml"
    bridge.time = types.SimpleNamespace(sleep=lambda s: None)
    bridge.run_ntg_cli(object())
elif mode == "child":
    lt = sys.modules["link_telemetry"]
    real_popen = subprocess.Popen
    # The bridge's own launcher; only the wait is shortened. The Popen is the real one, with the
    # environment it inherits from this process.
    proc = lt.start_emitter(
        os.path.join(scratch, "no-such-manifest.json"),
        popen=lambda argv, **kw: real_popen(argv + ["--manifest-wait", "0"], **kw),
        log_path=os.path.join(scratch, "emitter.log"))
    report["emitter_rc"] = proc.wait(timeout=60)
else:
    raise SystemExit("unknown mode " + mode)

with open(os.path.join(scratch, "report.json"), "w") as f:
    json.dump(report, f)
'''

NTG_FIXTURE = '''\
import os
import ntg_support

_calls = 0


def logger_config(*a, **k):
    return "real"


def command_line(net, config_file_path=None):
    global _calls
    _calls += 1
    with open(os.environ.get("NTG_MARKER", os.path.join(os.path.dirname(__file__), "..", "marker.txt")), "a") as f:
        f.write("call %d logger_config=%s support=%s\\n" % (_calls, logger_config.__name__, ntg_support.VALUE))
    if _calls == 1:
        raise RuntimeError("a bad flow, once")
'''


def read_text(path, parse=lambda text: text):
    """The file's text (through `parse`), or None when there is no such file. Always closed."""
    if not os.path.exists(path):
        return None
    with open(path, errors="replace") as f:
        return parse(f.read())


def bridge_source():
    return read_text(BRIDGE)


def bytecode_in(tree):
    """Every __pycache__ directory and .pyc/.pyo file under `tree`."""
    found = []
    for root, dirs, files in os.walk(tree):
        for d in dirs:
            if d == "__pycache__":
                found.append(os.path.join(root, d))
        for name in files:
            if name.endswith((".pyc", ".pyo")):
                found.append(os.path.join(root, name))
    return sorted(found)


def without_the_two_lines(source):
    """The bridge as it was before: every statement that switches bytecode writing off."""
    kept = [line for line in source.splitlines(keepends=True)
            if not re.match(r"\s*(sys\.dont_write_bytecode\s*=|os\.environ\[['\"]PYTHONDONTWRITEBYTECODE['\"]\]\s*=)", line)]
    return "".join(kept)


class Probe:
    """One throwaway world: a kernel copy, an NTG fixture, a driver, and the interpreter's report."""

    def __init__(self, mode, bridge_source):
        self.root = tempfile.mkdtemp(prefix="bridge_no_bytecode.")
        self.kernel = os.path.join(self.root, "kernel")
        self.ntg = os.path.join(self.root, "ntg")
        self.driver_dir = os.path.join(self.root, "driver")
        mininet = os.path.join(self.kernel, "p4_proxy", "mininet")
        agent = os.path.join(self.kernel, "p4_proxy", "proxy_agent")
        for d in (mininet, agent, self.ntg, self.driver_dir):
            os.makedirs(d)
        for name in SIBLINGS:
            shutil.copy(os.path.join(SIBLINGS_DIR, name), mininet)
        for name in AGENT_FILES:
            shutil.copy(os.path.join(PROXY_AGENT_DIR, name), agent)
        with open(os.path.join(mininet, "ntg_bmv2_topo.py"), "w") as f:
            f.write(bridge_source)
        with open(os.path.join(self.ntg, "network_traffic_generator.py"), "w") as f:
            f.write(NTG_FIXTURE)
        with open(os.path.join(self.ntg, "ntg_support.py"), "w") as f:
            f.write("VALUE = 7\n")
        driver = os.path.join(self.driver_dir, "driver.py")
        with open(driver, "w") as f:
            f.write(DRIVER)
        # Built from nothing: whatever this process exports (PYTHONDONTWRITEBYTECODE, a pycache
        # prefix, PYTHONPATH) does not reach the interpreter under observation. No -B either.
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.root,
               "LANG": "C.UTF-8", "NTG_MARKER": os.path.join(self.root, "marker.txt")}
        self.proc = subprocess.run(
            [sys.executable, driver, mode, self.kernel, self.ntg, self.root],
            cwd=self.root, env=env, capture_output=True, text=True, timeout=120)
        report_path = os.path.join(self.root, "report.json")
        self.report = read_text(report_path, json.loads)
        self.marker = read_text(env["NTG_MARKER"]) or ""
        self.emitter_log = read_text(os.path.join(self.root, "emitter.log")) or ""

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


class ProbeCase(unittest.TestCase):
    def probe(self, mode, source=None):
        p = Probe(mode, bridge_source() if source is None else source)
        self.addCleanup(p.close)
        self.assertEqual(0, p.proc.returncode, "the probe itself failed:\n" + p.proc.stderr[-3000:])
        self.assertIsNotNone(p.report, "the probe wrote no report:\n" + p.proc.stderr[-3000:])
        # The controls on the probe's own start: bytecode writing was ON when it began.
        self.assertFalse(p.report["dont_write_bytecode"], "probe started with sys.dont_write_bytecode")
        self.assertEqual(0, p.report["flag"], "probe started with -B")
        self.assertIsNone(p.report["env"], "probe started with PYTHONDONTWRITEBYTECODE set")
        self.assertIsNone(p.report["pycache_prefix_env"])
        self.assertIsNone(p.report["pycache_prefix"], "bytecode would be redirected, not absent")
        return p

    def assertReachedNtgTwice(self, p):
        lines = p.marker.splitlines()
        self.assertEqual(2, len(lines), "run_ntg_cli did not reach NTG's command_line twice: %r" % p.marker)
        self.assertIn("support=7", lines[0])
        self.assertIn("logger_config=logger_config", lines[0])
        # After the crash the loop re-imported the module and replaced its logger_config.
        self.assertIn("logger_config=<lambda>", lines[1])


class TheBridgeWritesNoBytecodeTest(ProbeCase):

    def test_importing_the_kernel_modules_and_ntg_writes_no_bytecode_in_either_tree(self):
        p = self.probe("import")
        self.assertReachedNtgTwice(p)
        self.assertEqual([], bytecode_in(p.kernel), "bytecode in the kernel tree")
        self.assertEqual([], bytecode_in(p.ntg), "bytecode in the NTG tree")

    def test_a_python_the_bridge_starts_writes_no_bytecode_either(self):
        p = self.probe("child")
        # The emitter really ran and got past its module-level imports into main().
        self.assertEqual(1, p.report["emitter_rc"], p.emitter_log)
        self.assertIn("psample_sflow_emitter:", p.emitter_log)
        # What the child wrote decides here, not the bridge's own environment: a child that
        # lost the variable on the way (an env= on the Popen) is seen even while the bridge's
        # environment still holds it.
        self.assertEqual([], bytecode_in(p.kernel), "bytecode in the kernel tree")

    def test_the_bridge_switches_it_off_for_this_process_and_for_its_children(self):
        p = self.probe("import")
        self.assertTrue(p.report["dont_write_bytecode_after_bridge_top"])
        # Python treats any non-empty value as "set"; the empty string is "not set".
        self.assertTrue(p.report["env_after_bridge_top"], "PYTHONDONTWRITEBYTECODE is empty or unset")


class TheProbeCanSeeBytecodeTest(ProbeCase):
    """The same probe over the bridge without the two lines: bytecode must show up."""

    def test_without_the_two_lines_the_import_path_does_write_bytecode(self):
        p = self.probe("import", without_the_two_lines(bridge_source()))
        self.assertReachedNtgTwice(p)
        self.assertTrue(any(f.endswith("p4_testbed_topo.cpython-%d%d.pyc" % sys.version_info[:2])
                            for f in bytecode_in(p.kernel)), bytecode_in(p.kernel))
        self.assertTrue(any("network_traffic_generator" in f for f in bytecode_in(p.ntg)), bytecode_in(p.ntg))
        self.assertTrue(any("ntg_support" in f for f in bytecode_in(p.ntg)), bytecode_in(p.ntg))

    def test_without_the_two_lines_the_emitter_does_write_bytecode(self):
        p = self.probe("child", without_the_two_lines(bridge_source()))
        self.assertEqual(1, p.report["emitter_rc"], p.emitter_log)
        agent_pyc = bytecode_in(os.path.join(p.kernel, "p4_proxy", "proxy_agent"))
        self.assertTrue(any("sflow_emitter" in f for f in agent_pyc), agent_pyc)

    def test_the_stripped_copy_has_no_statement_that_switches_it_off(self):
        stripped = without_the_two_lines(bridge_source())
        self.assertIsNone(re.search(r"^\s*sys\.dont_write_bytecode\s*=", stripped, re.M))
        self.assertIsNone(re.search(r"^\s*os\.environ\[.PYTHONDONTWRITEBYTECODE.\]\s*=", stripped, re.M))


if __name__ == "__main__":
    unittest.main()
