#!/usr/bin/env python3
"""One bring-up, two entry points -- and what each of them does to a net that records.

[Co-developed with claude code -- Adam]

🔴 WHAT THIS FILE IS FOR. `ndtwin-lab topo-start` launches ntg_bmv2_topo.py, NOT
p4_testbed_topo.py. For as long as those two files each carried their own copy of "build the
net, set the hosts up, list the switches, verify, write the manifest", every test in this repo
looked at the copy nothing ran. The app-package work landed in p4_testbed_topo.main() and the
copy that executes kept its literals -- `range(1, 11)` for the switch list above all -- so the
first live `ndt up p4 --app <4-switch package>` died at `net.get('s5')` before write_manifest,
with no try/finally, inside a tmux pane that stopped existing when the process did.

So the subject is not "does bring-up work". It is:

  1. there is ONE bring-up and both mains reach it (`TheTwoEntryPointsDoTheSameThingTest`
     drives both and compares the recordings call for call -- the assertion the two-copies era
     could never make);
  2. with no package, what it does is what it did (`BaselineIsWhatItWasTest` pins the bmv2
     argv, the static-ARP command and the manifest, each against the literal at the site it
     comes from, not against the code's own answer);
  3. with a package, the switches, the hosts and the host commands all come from the model and
     the manifest, and the all-pairs ARP does NOT run (`UnderAPackageTest`);
  4. the four-switch fabric never asks for s5 (`TheBridgeNeverAsksForASwitchTheModelDoesNotDeclareTest`
     -- this is the live red of 2026-09-18, in a unit test);
  5. the bridge's log is started before anything can fail and its crash lands in it
     (`TheBridgeRecordsWhatKilledItTest`).

HOW IT RUNS WITHOUT MININET. Mininet is stubbed at `sys.modules` level, exactly as
test_readopt.py and test_bmv2_binary_override.py already do, and the switch objects are REAL
`BMv2Switch` instances over a stub `Switch` base -- so the argv on trial is the argv
`BMv2Switch.start()` composes, not a transcription of it. `is_alive`/`grpc_is_listening` are
overridden because the real ones send a signal to a pid and open a TCP connection, and a unit
test that probed :30051 would pass or fail depending on whether somebody had a fabric up.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

import atexit
import contextlib
import importlib.util
import io
import json
import os
import shutil
import signal
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
REPO = os.path.dirname(PROXY_DIR)
MININET_DIR = os.path.join(PROXY_DIR, "mininet")
sys.path.insert(0, MININET_DIR)

import app_package  # noqa: E402
import topo_from_json  # noqa: E402
import topo_log  # noqa: E402
import link_telemetry  # noqa: E402

FOUR_HOST_MODEL = os.path.join(REPO, "setting", "StaticNetworkTopologyP4_10Switches_4Hosts.json")
HOST_128_MODEL = os.path.join(REPO, "setting", "StaticNetworkTopologyP4_10Switches_128Hosts.json")


# --- the stubs and the two modules under test ------------------------------------------------


class StubIntf:
    """Just enough of mininet.link.Intf for BMv2Switch.start's `-i port@name` loop."""

    def __init__(self, name, ip=""):
        self.name = name
        self._ip = ip

    def IP(self):
        return self._ip


class StubSwitchBase:
    """mininet.node.Switch, reduced to what BMv2Switch actually touches."""

    def __init__(self, name, **kwargs):
        self.name = name
        self.intfs = {}
        self.commands = []

    def cmd(self, line):
        self.commands.append(line)
        return "12345\n"

    def stop(self, deleteIntfs=True):
        self.stopped = True


class StubTCLink:
    """mininet.link.TCLink, as a name `build_net` can pass and a test can identify.

    It is never instantiated here: what is on trial is WHETHER it reaches Mininet's `link=`
    keyword, because a fabric nobody asked to shape must keep getting the plain Link it has
    always had (an htb qdisc on every interface changes the timing of every reading ever taken
    on this fabric).
    """


class StubTopo:
    """mininet.topo.Topo, recording what MultiSwitchTopo asks it to build."""

    def __init__(self, **opts):
        self.switch_calls = []
        self.host_calls = []
        self.link_calls = []

    def addSwitch(self, name, **kwargs):
        self.switch_calls.append((name, dict(kwargs)))
        return name

    def addHost(self, name, **kwargs):
        self.host_calls.append((name, dict(kwargs)))
        return name

    def addLink(self, a, b, **kwargs):
        self.link_calls.append((a, b, dict(kwargs)))
        return (a, b)


def install_mininet_stubs():
    """Put the stub Mininet into sys.modules, unconditionally.

    Unconditionally on purpose: test_readopt.py and test_bmv2_binary_override.py install their
    own bare-type versions, and which of the three a module ends up bound to would otherwise
    depend on import order. Each file's own `exec_module` happens right after its own install,
    so the class each captured is the one it asked for.
    """
    stubs = {
        "mininet": {},
        "mininet.net": {"Mininet": type("Mininet", (), {})},
        "mininet.topo": {"Topo": StubTopo},
        "mininet.node": {"Switch": StubSwitchBase, "Host": type("Host", (), {})},
        "mininet.cli": {"CLI": type("CLI", (), {"__init__": lambda self, net: None})},
        "mininet.log": {"setLogLevel": lambda *a, **k: None, "info": lambda *a, **k: None},
        "mininet.link": {"Intf": StubIntf, "TCLink": StubTCLink},
    }
    for name, attrs in stubs.items():
        mod = sys.modules.get(name) or types.ModuleType(name)
        for attr, value in attrs.items():
            setattr(mod, attr, value)
        sys.modules[name] = mod


def load_module(filename, as_name):
    path = os.path.join(MININET_DIR, filename)
    spec = importlib.util.spec_from_file_location(as_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[as_name] = module
    spec.loader.exec_module(module)
    return module


install_mininet_stubs()
testbed = load_module("p4_testbed_topo.py", "p4_testbed_topo_bring_up_test")

# ntg_bmv2_topo.py does `import p4_testbed_topo as testbed`, and the point of this file is that
# both entry points drive ONE module. So the copy loaded above is the one it is handed, rather
# than a second import that would give the two mains two sets of patchable seams -- which is the
# very shape being repaired. `nornir` is NTG's hard dependency and is absent from the proxy's
# venv; the bridge only uses its presence as an "is this the right interpreter" probe.
_saved_testbed = sys.modules.get("p4_testbed_topo")
_saved_nornir = sys.modules.get("nornir")
sys.modules["p4_testbed_topo"] = testbed
sys.modules["nornir"] = types.ModuleType("nornir")
try:
    ntg = load_module("ntg_bmv2_topo.py", "ntg_bmv2_topo_bring_up_test")
finally:
    if _saved_testbed is None:
        del sys.modules["p4_testbed_topo"]
    else:
        sys.modules["p4_testbed_topo"] = _saved_testbed
    if _saved_nornir is None:
        del sys.modules["nornir"]
    else:
        sys.modules["nornir"] = _saved_nornir


class RecordingSwitch(testbed.BMv2Switch):
    """A real BMv2Switch whose health is asserted rather than probed.

    The real `is_alive` sends signal 0 to a pid and the real `grpc_is_listening` opens a TCP
    connection to 127.0.0.1:3005N. Both would make this suite's answer depend on what else is
    running on the machine, and one of them would signal a pid this test made up.
    `start()` -- the argv composer, which is what is on trial -- is untouched.
    """

    healthy = True

    def is_alive(self):
        return self.healthy

    def grpc_is_listening(self, timeout=0.3):
        return self.healthy


class RecordingIntf(StubIntf):
    """A mininet.link.Intf that records `rename` instead of touching a device.

    The real one fixes up the node's nameToIntf and runs `ip link set ... name ...` between an
    ifconfig down and up; what matters to these cells is that it was called, on which
    interface, and WHEN relative to the host's commands.
    """

    def __init__(self, name, host):
        StubIntf.__init__(self, name)
        self.host = host

    def rename(self, newname):
        self.host.events.append(("rename", self.name, newname))
        self.name = newname
        return ""


class RecordingHost:
    """A Mininet host that writes down every command instead of running it.

    `outputs` maps a command to what `cmd()` should answer, so a cell can reproduce the thing
    the 09-18 live round threw away: `route add default gw ... dev eth0` answering
    `SIOCADDRT: No such device` on a host whose interface was never renamed.
    """

    def __init__(self, name, ip, mac, outputs=None):
        self.name = name
        self._ip = ip.split("/")[0]
        self._mac = mac
        self.commands = []
        # One ordered log of everything that happened to this host, so "the rename came first"
        # is a fact a test can read rather than an order it has to assume.
        self.events = []
        self.outputs = dict(outputs or {})
        self._intfs = [RecordingIntf(f"{name}-eth0", self), StubIntf("lo")]

    def IP(self):
        return self._ip

    def MAC(self):
        return self._mac

    def defaultIntf(self):
        return self._intfs[0]

    def intfList(self):
        return list(self._intfs)

    def cmd(self, line):
        self.commands.append(line)
        self.events.append(("cmd", line))
        return self.outputs.get(line, "")

    @property
    def host_setup(self):
        """The commands run before disable_host_offloads -- the ARP or the package's own."""
        return [c for c in self.commands if not c.startswith("ethtool ")]

    @property
    def offload_commands(self):
        return [c for c in self.commands if c.startswith("ethtool ")]

    @property
    def intf_name(self):
        return self.defaultIntf().name


class RecordingNet:
    """A net built from what MultiSwitchTopo declared, which answers `get` and records it.

    `gets` is the list this file exists for: on 2026-09-18 the bridge asked this object for
    's5' on a fabric whose model declares four switches, and Mininet answered with the KeyError
    that ended the process. So `get` raises KeyError for an unknown name, exactly as
    Mininet.getNodeByName does.
    """

    def __init__(self, package, model, healthy=True, outputs=None):
        self.topo = testbed.MultiSwitchTopo(package=package, model=model)
        self.switches = {}
        for name, kwargs in self.topo.switch_calls:
            self.switches[name] = RecordingSwitch(
                name, **{k: v for k, v in kwargs.items() if k != "cls"})
            self.switches[name].healthy = healthy
        self.hosts = {}
        for name, kwargs in self.topo.host_calls:
            self.hosts[name] = RecordingHost(name, kwargs["ip"], kwargs["mac"],
                                             outputs=(outputs or {}).get(name))
        # Interfaces in link-declaration order, which is the order real Mininet numbers them
        # and therefore the order BMv2Switch.start emits `-i port@intf`.
        for a, b, kwargs in self.topo.link_calls:
            for node, port in ((a, kwargs.get("port1")), (b, kwargs.get("port2"))):
                switch = self.switches.get(node)
                if switch is not None:
                    switch.intfs[port] = StubIntf(f"{node}-eth{port}")
        self.nodes = dict(self.switches)
        self.nodes.update(self.hosts)
        self.gets = []
        self.started = False
        self.stopped = False

    def get(self, name):
        self.gets.append(name)
        return self.nodes[name]

    def start(self):
        self.started = True
        for switch in self.switches.values():
            switch.start([])

    def stop(self):
        self.stopped = True

    # --- what the assertions read -----------------------------------------------------------

    def argv(self):
        """{switch name: the shell command BMv2Switch.start composed}, in launch order."""
        out = {}
        for name, switch in self.switches.items():
            # `<cmd> > <log> 2>&1 & echo $!` is what start() hands to the shell; the argv is
            # the part in front of the redirection, and launch_argv is what the manifest keeps.
            out[name] = switch.launch_argv
        return out

    def host_setup(self):
        return {name: host.host_setup for name, host in self.hosts.items()}


# --- a deterministic machine ------------------------------------------------------------------
#
# The bmv2 binary the argv names must not be whatever this machine happens to have installed,
# and the fabric must not read the operator's own knob or host count. Everything below is the
# fixture those three come from.

_TMP = tempfile.mkdtemp(prefix="fabric_bring_up_test.")
atexit.register(shutil.rmtree, _TMP, ignore_errors=True)

FAKE_BINARY = os.path.join(_TMP, "prefix", "bin", "simple_switch_grpc")
os.makedirs(os.path.dirname(FAKE_BINARY))
with open(FAKE_BINARY, "w") as _fh:
    _fh.write("#!/bin/sh\n")
os.chmod(FAKE_BINARY, 0o755)
# No sibling ../lib on purpose: bmv2_launch_head then contributes no LD_LIBRARY_PATH prefix and
# the argv below is one literal rather than one with a machine-dependent head.
BINARY_OVERRIDE = os.path.join(_TMP, "bmv2_binary_override")
with open(BINARY_OVERRIDE, "w") as _fh:
    _fh.write(FAKE_BINARY + "\n")

#: 🔴 TRANSCRIBED, not read back from the code. app_package.BASELINE_PIPELINE's second element
#: is "p4_src/build/ndtwin_switch.json", and MultiSwitchTopo resolves it against
#: `os.path.join(<this file's directory>, "..")` -- un-normalised, which is what lands in the
#: argv today and therefore what has to land in it after this change.
BASELINE_JSON = os.path.join(MININET_DIR, "..", "p4_src", "build", "ndtwin_switch.json")


def load_two_program_package_fixture(only_s1_is_foreign=False, name="two-programs"):
    """A/P1's `basic` package with exercises/firewall's per-switch pipeline shape laid on it.

    [Co-developed with claude code -- Adam]
    The shape, not the exercise: s1 names `build/firewall.*` and s2-s4 name `build/basic.*`,
    which is exactly what convert.py writes for firewall's pod-topo (its topology.json is the
    one shipped exercise that uses tutorials' per-switch `program` override). The artefact
    files are empty -- `BMv2Switch.start` only ever puts the PATH in the argv, and a fixture
    carrying a real compiled program would suggest something here parsed one.
    """
    path = os.path.join(HERE, "test_app_package.py")
    spec = importlib.util.spec_from_file_location("test_app_package_fixture_source", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    manifest = json.loads(json.dumps(module.CONVERTER_BASIC))
    for key, switch in manifest["switches"].items():
        if only_s1_is_foreign and key != "1":
            # `--ndtwin-pipeline` on some switches and not others is not a shape convert.py
            # writes, but it is one an operator can write by hand -- and it is the shape the
            # per-switch disclosure has to get right, because "some of them" is the answer a
            # count of "all of them" cannot distinguish from a bug.
            switch["pipeline"] = None
            continue
        stem = "firewall" if key == "1" else "basic"
        switch["pipeline"] = {"p4info": f"build/{stem}.p4.p4info.txtpb",
                              "bmv2_json": f"build/{stem}.json"}
    directory = module.lay_out_converter_package(
        _TMP, manifest, name,
        entry_files=[spec_["entries"] for spec_ in manifest["switches"].values()])
    for stem in ("firewall", "basic"):
        for rel in (f"build/{stem}.p4.p4info.txtpb", f"build/{stem}.json"):
            full = os.path.join(directory, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as fh:
                fh.write("{}\n")
    return app_package.load(directory)


def load_package_fixture():
    """A/P1's verbatim `basic` package, laid out in a temp directory.

    Reused rather than re-typed: test_app_package.py's CONVERTER_BASIC is `json.load()` of the
    bytes tools/p4_exercise/convert.py actually wrote, re-emitted with pprint, and its own
    header records what a hand-typed copy of it got wrong. Loaded by file path so this works
    whether unittest was pointed at a module or at this file.
    """
    path = os.path.join(HERE, "test_app_package.py")
    spec = importlib.util.spec_from_file_location("test_app_package_fixture_source", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    directory = module.lay_out_converter_package(
        _TMP, module.CONVERTER_BASIC, "basic",
        entry_files=[spec_["entries"] for spec_ in module.CONVERTER_BASIC["switches"].values()])
    return app_package.load(directory)


class FakeProcess:
    """A `subprocess.Popen` that is a pid and an exit status, and nothing else."""

    def __init__(self, pid=4242, exits=None):
        self.pid = pid
        #: None means "still running". A list is consumed one poll at a time, which is how the
        #: "it died during the grace period" case is written without a real process.
        self._exits = list(exits) if isinstance(exits, list) else exits
        self.polls = 0

    def poll(self):
        """None until the scripted status is reached, and that status for ever after.

        Latching matters: a real `Popen.poll()` does not un-exit, so a fake that answered the
        next element of a list on every call would let production code pass this suite by
        calling `poll()` a different number of times than it does live.
        """
        self.polls += 1
        if isinstance(self._exits, list):
            if self._exits:
                status = self._exits.pop(0)
                if status is None:
                    return None
                self._exits = status
                return status
            return None
        return self._exits


class FakeSubprocess:
    """`subprocess`, for a suite that is forbidden to run `tc` or start a process.

    🔴 INSTALLED FOR EVERY CASE IN THIS FILE, not only the link-telemetry ones. TICKET-P3
    section 0 forbids this suite from running `tc`, and `link_telemetry.attach` resolves
    `subprocess.run` out of its own module globals at call time -- so replacing the module
    attribute is what makes "a unit test cannot shell out" a property of the fixture rather
    than of each test remembering to patch.
    """

    PIPE = -1

    class CompletedProcess:
        def __init__(self, argv, returncode=0, stderr=b""):
            self.args = argv
            self.returncode = returncode
            self.stderr = stderr
            self.stdout = b""

    def __init__(self):
        # 🔴 ONE ORDERED LOG, not a list per kind. Two lists can say what happened and cannot
        # say what happened FIRST, and the order of attach / start / write_manifest is the
        # part of section 2.5 that is load-bearing: a `tc` that fails after the emitter exists
        # leaves an orphan holding a psample group, and the manifest cannot carry a pid that
        # does not exist yet. `reset()` rather than reassignment, because the derived views
        # below are properties.
        self.events = []
        self.rc = 0
        self.process = None

    def reset(self):
        self.events = []

    def run(self, argv, **kwargs):
        self.events.append(("run", list(argv)))
        return self.CompletedProcess(list(argv), returncode=self.rc)

    def Popen(self, argv, **kwargs):          # noqa: N802 -- subprocess spells it this way
        self.events.append(("popen", list(argv)))
        self.process = self.process or FakeProcess()
        return self.process

    # --- what the assertions read ------------------------------------------------------
    @property
    def ran(self):
        return [argv for kind, argv in self.events if kind == "run"]

    @property
    def started(self):
        return [argv for kind, argv in self.events if kind == "popen"]

    def tc(self):
        """Every `tc` command line, as a string, in order."""
        return [" ".join(argv) for argv in self.ran if argv and argv[0] == "tc"]

    def kinds(self):
        """The sequence of things that happened, one word each."""
        out = []
        for kind, argv in self.events:
            if kind == "popen":
                out.append("popen")
            elif argv and argv[0] == "tc" and argv[1:3] == ["qdisc", "add"]:
                out.append("qdisc")
            elif argv and argv[0] == "tc" and argv[1:3] == ["filter", "add"]:
                out.append("filter")
            elif argv and argv[0] == "tc" and argv[1:3] == ["qdisc", "del"]:
                out.append("detach")
            else:
                out.append(" ".join(argv))
        return out


#: ifindexes for the offline suites: `sN-ethM` -> a number nothing on this machine owns.
#: Deterministic and stated here rather than read from /sys, which a unit test has no veth in.
def fake_ifindex(ifname, sys_root="/sys/class/net"):
    switch, _, port = ifname.partition("-eth")
    return 1000 + int(switch[1:]) * 10 + int(port or 0)


class FabricFixture(unittest.TestCase):
    """Base: the machine's own knob, host count and binary replaced by this file's."""

    package = None          # None means "the baseline", set by subclasses
    host_num = "4"

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fabric_bring_up_case.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.manifest = os.path.join(self.tmp, "ndtwin_p4_switches.json")

        self.patch(testbed, "BINARY_OVERRIDE_PATH", BINARY_OVERRIDE)
        self.patch(testbed, "MANIFEST_PATH", self.manifest)
        # A knob that does not exist is the baseline; a package fixture sets one below.
        self.patch(app_package, "KNOB_PATH", os.path.join(self.tmp, "no_such_knob"))
        self.setenv("NDTWIN_P4_HOST_NUM", self.host_num)
        self.setenv("NDTWIN_P4_TOPO_FILE", None)
        # ntg_bmv2_topo.main()'s first precondition is `import nornir`, which is NTG's hard
        # dependency and its probe for "is this the ntg-env interpreter". The proxy's venv has
        # no nornir and never will, so the probe is answered rather than removed -- taking the
        # check out to make a test pass would delete the one line that catches the commonest
        # way this script is run wrongly.
        self.stub_module("nornir")

        # 🔴 NOTHING IN THIS SUITE READS THE HOST'S /proc. `tear_down` calls
        # `reap_manifest_switches`, whose `is_switch` default is bound at def time to
        # `process_is_a_switch` -- which opens /proc/<pid>/cmdline for every pid in the
        # manifest, and the manifest these tests write says pid 12345. What that pid is on the
        # machine running the suite is not something a unit test gets to depend on (the answer
        # today is "nothing"; tomorrow it is somebody's editor). The real function has its own
        # tests in test_readopt.py, against an injected /proc root.
        self.reaped_paths = []
        self.patch(testbed, "reap_manifest_switches",
                   lambda path=None, **kwargs: (self.reaped_paths.append(path), [])[1])

        # --- link telemetry (TICKET-P3 sections 2.1, 2.5) ----------------------------------
        #
        # 🔴 FOUR THINGS THIS SUITE MUST NOT REACH, and all four are the machine's:
        #   * the telemetry knob next to the topology script -- an operator's `link` would
        #     otherwise make every case in this file build a different fabric;
        #   * /tmp/ndtwin_link_telemetry.json -- `tear_down` reads it and SIGTERMs the pid it
        #     names, so a suite run while a fabric is up would kill that fabric's emitter;
        #   * `tc` and `Popen`, which section 0 forbids outright;
        #   * /sys/class/net, which has no `s1-eth1` unless somebody has a fabric up -- in
        #     which case it has one belonging to a DIFFERENT fabric.
        self.telemetry_knob_path = os.path.join(self.tmp, "telemetry_override")
        self.patch(app_package, "TELEMETRY_KNOB_PATH", self.telemetry_knob_path)
        self.link_manifest = os.path.join(self.tmp, "ndtwin_link_telemetry.json")
        self.patch(link_telemetry, "LINK_TELEMETRY_MANIFEST", self.link_manifest)
        # The emitter is launched onto its OWN file rather than inheriting fds 1 and 2 (see
        # LINK_TELEMETRY_LOG), which means `start_emitter` opens a file -- and /tmp's is not
        # this suite's to truncate.
        self.link_log = os.path.join(self.tmp, "ndtwin_link_telemetry.log")
        self.patch(link_telemetry, "LINK_TELEMETRY_LOG", self.link_log)
        self.patch(link_telemetry, "read_ifindex", fake_ifindex)
        self.sub = FakeSubprocess()
        self.patch(link_telemetry, "subprocess", self.sub)
        # The three-second liveness grace is real time in production and dead time here. The
        # loop that spends it has its own case (StartingTheEmitterTest), which is where it is
        # allowed to cost something.
        self.patch(link_telemetry, "EMITTER_STARTUP_GRACE_S", 0.0)

    def set_telemetry_knob(self, word):
        """Write the knob `ndt up p4 --telemetry <word>` writes."""
        with open(self.telemetry_knob_path, "w") as fh:
            fh.write(word + "\n")

    def link_manifest_contents(self):
        with open(self.link_manifest) as fh:
            return json.load(fh)

    def stub_module(self, name, module=None):
        old = sys.modules.get(name)
        had = name in sys.modules

        def restore():
            if not had:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = old
        self.addCleanup(restore)
        sys.modules[name] = types.ModuleType(name) if module is None else module

    def patch(self, module, name, value):
        old = getattr(module, name)
        self.addCleanup(setattr, module, name, old)
        setattr(module, name, value)

    def setenv(self, name, value):
        old = os.environ.get(name)

        def restore():
            if old is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = old
        self.addCleanup(restore)
        if value is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = value

    def use_package(self, package):
        """Point the knob at a package directory, the way `ndt up p4 --app` does."""
        knob = os.path.join(self.tmp, "app_package_override")
        with open(knob, "w") as fh:
            fh.write(package.dir + "\n")
        self.patch(app_package, "KNOB_PATH", knob)

    def plan(self):
        quiet = []
        return testbed.plan_fabric(report=quiet.append), quiet

    def bring_up(self, healthy=True, verify_timeout=None, outputs=None, report=None):
        # An unhealthy fabric is judged immediately: verify_switches POLLS for ten seconds
        # because a real bmv2 needs a moment to bind, and a suite that waited for that on
        # purpose would spend twenty seconds proving something it already knows.
        if verify_timeout is None:
            verify_timeout = 10.0 if healthy else 0.0
        plan, _said = self.plan()
        net = RecordingNet(plan.package, plan.model, healthy=healthy, outputs=outputs)
        result = testbed.bring_up(plan.package, plan.model, net=net,
                                  manifest_path=self.manifest,
                                  link_manifest_path=self.link_manifest,
                                  verify_timeout=verify_timeout,
                                  report=(report if report is not None else lambda _line: None))
        return plan, net, result

    def manifest_contents(self):
        with open(self.manifest) as fh:
            return json.load(fh)


# --- 1. the baseline is what it was ------------------------------------------------------------


class BaselineIsWhatItWasTest(FabricFixture):
    """No knob: the argv, the ARP and the manifest, each against the literal it comes from."""

    def test_the_switches_are_the_models_ten_in_dpid_order(self):
        _plan, net, (_net, switches, _fatal, _report, _setup) = self.bring_up()
        self.assertEqual([s.name for s in switches],
                         ["s%d" % i for i in range(1, 11)])
        # And they were fetched by name from the net, in that order -- which is what
        # `[net.get(f's{i}') for i in range(1, 11)]` used to produce for this model and must
        # keep producing now that the list comes from the model instead.
        self.assertEqual([g for g in net.gets if g.startswith("s")],
                         ["s%d" % i for i in range(1, 11)])

    def test_s1s_launch_command_is_the_one_bmv2_has_always_been_given(self):
        # 🔴 The right-hand side is written from BMv2Switch.start()'s own format string plus
        # grpc_ports' two bases (30050/9090) and app_package.BASELINE_CPU_PORT's 255 -- not
        # read back from the object. s1's three ports are the 4-host model's wiring, which
        # tools/test_workflow/test_topo_from_json.py pins against the literals it replaced.
        _plan, net, _result = self.bring_up()
        self.assertEqual(
            net.argv()["s1"],
            f"{FAKE_BINARY} -i 1@s1-eth1 -i 2@s1-eth2 -i 3@s1-eth3 "
            f"--thrift-port 9091 --device-id 1 {BASELINE_JSON} "
            f"-- --grpc-server-addr 0.0.0.0:30051 --cpu-port 255")

    def test_every_switch_gets_its_own_device_id_and_port_pair(self):
        _plan, net, _result = self.bring_up()
        for dpid in range(1, 11):
            with self.subTest(dpid=dpid):
                argv = net.argv()["s%d" % dpid]
                self.assertIn(f"--thrift-port {9090 + dpid} ", argv)
                self.assertIn(f"--device-id {dpid} ", argv)
                self.assertIn(f"--grpc-server-addr 0.0.0.0:{30050 + dpid}", argv)
                self.assertTrue(argv.endswith("--cpu-port 255"), argv)
                self.assertIn(BASELINE_JSON, argv)

    def test_the_static_arp_is_one_batched_command_per_host(self):
        # 🔴 Independently re-derived rather than pinned: the expectation below is built here,
        # from the model, by the rule the baseline has always followed -- every peer, in host
        # order, joined by " ; ". At four hosts the batching question does not arise (three
        # peers is one chunk), so this is byte-for-byte what both entry points sent before.
        _plan, net, _result = self.bring_up()
        model = topo_from_json.load(FOUR_HOST_MODEL)
        addresses = [(name, ip, topo_from_json.mac_str(mac, name))
                     for name, ip, mac in topo_from_json.hosts(model)]
        for name, _ip, _mac in addresses:
            with self.subTest(host=name):
                expected = " ; ".join(f"arp -s {ip} {mac}"
                                      for peer, ip, mac in addresses if peer != name)
                self.assertEqual(net.hosts[name].host_setup, [expected])

    def test_h1s_arp_command_is_the_exact_string_it_has_always_been(self):
        # The same claim, spelled out once, so that a change to the derivation above cannot
        # quietly change both sides of it.
        _plan, net, _result = self.bring_up()
        self.assertEqual(
            net.hosts["h1"].host_setup,
            ["arp -s 10.0.0.2 00:00:00:00:00:02 ; arp -s 10.0.0.3 00:00:00:00:00:03 ; "
             "arp -s 10.0.0.4 00:00:00:00:00:04"])

    def test_nothing_is_renamed_under_the_baseline(self):
        # 🔴 THE HALF THAT KEEPS THE PROMISE. The baseline fabric's hosts are h1-eth0 and every
        # reader of it -- the ARP fan-out, disable_host_offloads, NTG's MininetCommunicator --
        # has always seen that name. The rename is a package's business only.
        _plan, net, (_n, _sw, _fatal, _report, setup) = self.bring_up()
        self.assertEqual(setup.renamed, ())
        for name, host in net.hosts.items():
            with self.subTest(host=name):
                self.assertEqual(host.intf_name, f"{name}-eth0")
                self.assertEqual([kind for kind, *_r in host.events][0], "cmd")

    def test_offloads_are_turned_off_on_every_host(self):
        # Without this, bulk TCP stalls at zero through bmv2 (measured 2026-08-15).
        _plan, net, _result = self.bring_up()
        for name, host in net.hosts.items():
            with self.subTest(host=name):
                self.assertEqual(host.offload_commands,
                                 [f"ethtool -K {name}-eth0 tx off rx off gso off tso off "
                                  f"gro off"])

    def test_the_manifest_holds_all_ten_switches_with_their_argv(self):
        _plan, net, _result = self.bring_up()
        manifest = self.manifest_contents()
        self.assertEqual(sorted(manifest), sorted("s%d" % i for i in range(1, 11)))
        self.assertEqual(manifest["s1"], {
            "pid": 12345,
            "device_id": 1,
            "grpc_port": 30051,
            "thrift_port": 9091,
            "log_file": "/tmp/s1_bmv2.log",
            "argv": net.argv()["s1"],
        })

    def test_a_fabric_that_came_up_is_not_fatal_and_says_nothing(self):
        _plan, _net, (_n, switches, fatal, report, _setup) = self.bring_up()
        self.assertFalse(fatal)
        self.assertIsNone(report)
        self.assertEqual(len(switches), 10)

    def test_a_fabric_that_did_not_come_up_is_fatal_and_names_the_count(self):
        _plan, _net, (_n, _switches, fatal, report, _setup) = self.bring_up(healthy=False)
        self.assertTrue(fatal)
        self.assertIn("10 of 10 BMv2 switches did NOT come up.", report)

    def test_a_dead_switch_is_left_out_of_the_manifest(self):
        # write_manifest lists only verified switches: an entry for a dead one is worse than
        # no entry, because ndtwin-p4-power would trust it.
        self.bring_up(healthy=False)
        self.assertEqual(self.manifest_contents(), {})


class TheBaselineAt128HostsTest(FabricFixture):
    """The one place the two old copies DISAGREED, and the disagreement had been measured."""

    host_num = "128"

    def test_the_arp_fan_out_is_chunked_at_32_peers_per_command(self):
        # 🔴 THIS IS A BEHAVIOUR CHANGE FOR p4_testbed_topo.main() AND IT IS THE FIX.
        # That file batched all 127 entries into ONE cmd(); ntg_bmv2_topo.py -- the copy
        # ndtwin-lab actually runs -- chunked them in 32s, with the reason written beside it:
        # a single command is ~4.4 kB, Mininet TRUNCATES it, and h1 was measured holding
        # entries for h2..h112 and nothing after. A partial ARP table fails exactly like a
        # broken data plane. The chunked copy is the one that survives the merge.
        _plan, net, _result = self.bring_up()
        commands = net.hosts["h1"].host_setup
        self.assertEqual(len(commands), 4, "127 peers must be four commands, not one")
        self.assertEqual([c.count("arp -s") for c in commands], [32, 32, 32, 31])

    def test_no_single_command_is_long_enough_for_mininet_to_truncate(self):
        _plan, net, _result = self.bring_up()
        longest = max(len(c) for c in net.hosts["h1"].host_setup)
        self.assertLess(longest, 2048,
                        "a command this long is the 4.4 kB truncation that left h1 with a "
                        "partial ARP table and no error anywhere")

    def test_every_host_still_learns_every_peer(self):
        _plan, net, _result = self.bring_up()
        joined = " ; ".join(net.hosts["h1"].host_setup)
        self.assertEqual(joined.count("arp -s"), 127)
        self.assertNotIn("10.0.0.1 ", joined + " ", "h1 was given an ARP entry for itself")


# --- 2. one bring-up, two entry points ----------------------------------------------------------


class TheTwoEntryPointsDoTheSameThingTest(FabricFixture):
    """Both mains driven to completion against an identical recorder, then compared.

    🔴 THE ASSERTION THE TWO-COPIES ERA COULD NOT MAKE. Nothing compared p4_testbed_topo.main()
    with ntg_bmv2_topo.main() -- they were two transcriptions and the comparison was a human
    reading both. This drives each of them over the same fixture and asserts the recordings are
    equal, so a literal that drifts in one of them is a red cell rather than a live failure.
    """

    def drive(self, main, **extra):
        nets = []
        captured = {}
        real_tear_down = testbed.tear_down

        def tear_down(net, manifest_path=None, report=print):
            # The manifest is read here because teardown is what deletes it, and a recording
            # taken after teardown would compare two absences. The real teardown still runs.
            try:
                with open(manifest_path or testbed.MANIFEST_PATH) as fh:
                    captured["manifest"] = json.load(fh)
            except (OSError, ValueError):
                captured["manifest"] = None
            return real_tear_down(net, manifest_path=manifest_path, report=report)

        self.patch(testbed, "build_net", lambda package, model: nets.append(
            RecordingNet(package, model)) or nets[-1])
        self.patch(testbed, "reset_for_bring_up", lambda ports, settle_s=0.5: None)
        self.patch(testbed, "CLI", lambda net: None)
        self.patch(testbed, "tear_down", tear_down)
        main(**extra)
        self.assertEqual(len(nets), 1)
        net = nets[0]
        return {
            "argv": net.argv(),
            "host_setup": net.host_setup(),
            "switch_order": [name for name in net.switches],
            "gets": net.gets,
            "manifest": captured.get("manifest"),
            "stopped": net.stopped,
        }

    def test_the_two_mains_record_the_same_calls_on_the_baseline(self):
        from_topo = self.drive(testbed.main)
        from_bridge = self.drive(ntg.main, enter_cli=lambda net: None)
        self.assertEqual(from_topo, from_bridge)

    def test_the_two_mains_record_the_same_calls_under_a_package(self):
        self.use_package(load_package_fixture())
        from_topo = self.drive(testbed.main)
        from_bridge = self.drive(ntg.main, enter_cli=lambda net: None)
        self.assertEqual(from_topo, from_bridge)

    def test_both_mains_tear_the_net_down_when_they_are_done(self):
        # tear_down is shared too: net.stop, then reap what outlived it, then the manifest --
        # in that order, because once the manifest is gone nothing can address a switch the
        # power helper restarted.
        self.assertTrue(self.drive(testbed.main)["stopped"])
        self.assertTrue(self.drive(ntg.main, enter_cli=lambda net: None)["stopped"])
        self.assertFalse(os.path.exists(self.manifest),
                         "teardown left the manifest behind")
        # 🔴 AND IT REAPED BY THE MANIFEST IT WAS GIVEN. The reap is stubbed in this suite (it
        # would otherwise read the host's /proc), so without this the stub would be hiding the
        # wiring as well as the /proc read: a tear_down that never called it, or called it on
        # the machine's real /tmp manifest, would look identical.
        self.assertEqual(self.reaped_paths, [self.manifest, self.manifest],
                         "tear_down did not reap the manifest it was given, once per main")


# --- 3. under a package -------------------------------------------------------------------------


class UnderAPackageTest(FabricFixture):
    """A four-switch pod-topo package: everything from the model, nothing from a literal."""

    def setUp(self):
        super().setUp()
        self.pkg = load_package_fixture()
        self.use_package(self.pkg)

    def test_the_switches_are_the_packages_four_and_nothing_asks_for_more(self):
        _plan, net, (_n, switches, _fatal, _report, _setup) = self.bring_up()
        self.assertEqual([s.name for s in switches], ["s1", "s2", "s3", "s4"])

    def test_the_hosts_are_the_packages_four_with_its_addresses(self):
        _plan, net, _result = self.bring_up()
        self.assertEqual(sorted(net.hosts), ["h1", "h2", "h3", "h4"])
        self.assertEqual(net.hosts["h1"].IP(), "10.0.1.1")
        self.assertEqual(net.hosts["h4"].IP(), "10.0.4.4")

    def test_each_host_runs_the_packages_own_commands_in_order(self):
        _plan, net, _result = self.bring_up()
        self.assertEqual(net.hosts["h1"].host_setup,
                         ["route add default gw 10.0.1.10 dev eth0",
                          "arp -i eth0 -s 10.0.1.10 08:00:00:00:01:00"])
        self.assertEqual(net.hosts["h3"].host_setup,
                         ["route add default gw 10.0.3.30 dev eth0",
                          "arp -i eth0 -s 10.0.3.30 08:00:00:00:03:00"])

    def test_the_all_pairs_arp_does_not_run_under_a_package(self):
        # 🔴 The half that makes the package worth having. pod-topo's four hosts are in four
        # different /24s and reach each other through the exercise's forwarding tables; an
        # all-pairs fan-out would give every host every other host's MAC up front, so a broken
        # data plane would ping perfectly and the exercise would grade itself green.
        _plan, net, _result = self.bring_up()
        for name, host in net.hosts.items():
            with self.subTest(host=name):
                fanout = [c for c in host.host_setup if c.startswith("arp -s ")]
                self.assertEqual(fanout, [],
                                 "the fabric ran its own all-pairs ARP over the package's "
                                 "host commands")

    def test_every_host_gets_its_interface_renamed_to_eth0(self):
        # 🔴 THE 2026-09-18 DATA-PLANE RED. The package's commands are p4lang/tutorials'
        # commands -- `route add default gw 10.0.1.10 dev eth0` -- and a tutorials host IS
        # eth0, because P4Host.config renames it (utils/p4_mininet.py:21). An NDTwin host is
        # h1-eth0, so the route went to a device that does not exist, and every ping in the
        # live run answered `connect: Network is unreachable` over a fabric that was otherwise
        # perfect: 4 switches, 4 up, 16 edges, entries recorded on all four.
        _plan, net, _result = self.bring_up()
        for name, host in net.hosts.items():
            with self.subTest(host=name):
                self.assertEqual(host.intf_name, "eth0")

    def test_the_rename_happens_before_the_first_command(self):
        # Order is the whole content of the fix: renaming after the commands have run leaves
        # exactly the failure it is meant to remove.
        _plan, net, _result = self.bring_up()
        for name, host in net.hosts.items():
            with self.subTest(host=name):
                kinds = [kind for kind, *_rest in host.events]
                self.assertEqual(kinds[0], "rename",
                                 f"{name} ran something before its interface was renamed")
                self.assertEqual(host.events[0], ("rename", f"{name}-eth0", "eth0"))

    def test_a_host_the_package_gives_no_commands_is_renamed_too(self):
        # P4Host renames every host, and so does this: the exercise's own send.py and
        # receive.py name eth0 whether or not the manifest asked for anything to be run here.
        package = load_package_fixture()
        silent = app_package.Package(
            dir=package.dir, name=package.name, topology=package.topology,
            hosts=tuple(app_package.HostSpec(name=h.name, ip=h.ip, prefix_len=h.prefix_len,
                                             mac=h.mac, commands=())
                        for h in package.hosts),
            switches=package.switches)
        hosts = [RecordingHost("h1", "10.0.1.1/24", "08:00:00:00:01:11")]
        setup = testbed.configure_hosts(silent, hosts, report=lambda _line: None)
        self.assertEqual(hosts[0].intf_name, "eth0")
        self.assertEqual(setup.renamed, (("h1", "h1-eth0"),))
        self.assertEqual(hosts[0].host_setup, [])

    def test_the_offload_commands_name_the_renamed_interface(self):
        # disable_host_offloads walks intfList() and uses intf.name, so it follows the rename
        # rather than fighting it. Read rather than assumed: a helper that had cached the old
        # name would silently stop turning offloads off, and bulk TCP stalls at zero when it
        # does (measured 2026-08-15).
        _plan, net, _result = self.bring_up()
        self.assertEqual(net.hosts["h1"].offload_commands,
                         ["ethtool -K eth0 tx off rx off gso off tso off gro off"])

    def test_what_a_host_command_printed_is_reported_and_counted(self):
        # 🔴 THE OTHER HALF OF THE SAME LIVE RED: `host.cmd(command)` threw its answer away, so
        # the kernel's own five-word diagnosis existed nowhere on the machine and the fabric
        # looked healthy all the way up.
        said = []
        broken = "route add default gw 10.0.1.10 dev eth0"
        _plan, net, (_n, _sw, _fatal, _report, setup) = self.bring_up(
            outputs={"h1": {broken: "SIOCADDRT: No such device\n"}},
            report=said.append)
        self.assertEqual([(h, c) for h, c, _o in setup.noisy], [("h1", broken)])
        self.assertEqual(setup.noisy[0][2], "SIOCADDRT: No such device")
        # bring_up's own line, on stdout, which is what `ndt up` tails out of topo.log. The
        # per-command copy goes through Mininet's info() and has its own cell below.
        self.assertTrue(any("PRINTED OUTPUT" in line for line in said),
                        f"bring_up said nothing about a host command that failed: {said}")
        self.assertTrue(any("1 of this package's host command(s)" in line for line in said),
                        f"the count is not in what it said: {said}")

    def test_the_printed_output_is_written_under_the_command_that_produced_it(self):
        said = []
        broken = "route add default gw 10.0.1.10 dev eth0"
        hosts = [RecordingHost("h1", "10.0.1.1/24", "08:00:00:00:01:11",
                               outputs={broken: "SIOCADDRT: No such device\n"})]
        testbed.configure_hosts(load_package_fixture(), hosts, report=said.append)
        joined = "".join(said)
        self.assertIn(f"*** h1: {broken}\n", joined)
        self.assertIn("***   h1: SIOCADDRT: No such device\n", joined)
        self.assertLess(joined.index(f"*** h1: {broken}"),
                        joined.index("***   h1: SIOCADDRT"),
                        "the output is printed somewhere other than under its own command")

    def test_a_silent_host_command_is_not_reported_as_a_problem(self):
        # The control. `route`, `arp` and `ifconfig` say nothing when they work, and a fabric
        # that warned about every one of them would be a warning nobody reads.
        _plan, _net, (_n, _sw, _fatal, _report, setup) = self.bring_up()
        self.assertEqual(setup.noisy, ())

    def test_the_manifest_holds_the_packages_four_switches(self):
        self.bring_up()
        self.assertEqual(sorted(self.manifest_contents()), ["s1", "s2", "s3", "s4"])

    def test_the_port_block_is_the_models_dpids_not_a_block_of_ten(self):
        # The bridge pre-flighted `grpc_port_block(range(1, 11))` regardless of the model, so a
        # four-switch package refused over six ports it never wanted and checked nothing about
        # the four it did.
        plan, _said = self.plan()
        self.assertEqual(plan.dpids, [1, 2, 3, 4])
        self.assertEqual(plan.ports, [30051, 30052, 30053, 30054])

    def test_a_package_whose_switches_name_no_pipeline_still_runs_ndtwins_own(self):
        # A/P1's `basic` package leaves every `pipeline` null, so all four switches keep
        # NDTwin's own artefact -- and the plan says so per switch rather than once.
        plan, _said = self.plan()
        self.assertEqual(plan.json_paths, {d: BASELINE_JSON for d in (1, 2, 3, 4)})


class EachSwitchRunsTheProgramItsPackageNamedTest(FabricFixture):
    """🔴 G4 ON THE FABRIC SIDE: the json in each bmv2's argv is THAT switch's.

    [Co-developed with claude code -- Adam]
    `BMv2Switch.__init__` has taken `json_path` per switch since it was written. What it was
    handed was `pipeline_for(1, ...)` -- dpid 1's answer, copied onto all of them -- which was
    invisible while every package said `pipeline: null` and every switch therefore got the same
    `ndtwin_switch.json`. It stops being invisible the moment a package names two programs:
    exercises/firewall wants firewall.json on s1 and basic.json on s2-s4, and dpid 1's answer
    for all four is a fabric where three switches run a program the exercise never asked for.
    They come up. They forward. The exercise does not happen.
    """

    def setUp(self):
        super().setUp()
        self.pkg = load_two_program_package_fixture()
        self.use_package(self.pkg)

    def test_each_switch_is_launched_with_its_own_program(self):
        _plan, net, _result = self.bring_up()
        argv = net.argv()
        self.assertIn(os.path.join(self.pkg.dir, "build", "firewall.json"), argv["s1"])
        for name in ("s2", "s3", "s4"):
            with self.subTest(switch=name):
                self.assertIn(os.path.join(self.pkg.dir, "build", "basic.json"), argv[name])
                self.assertNotIn("firewall.json", argv[name])

    def test_ndtwins_own_pipeline_is_on_none_of_them(self):
        _plan, net, _result = self.bring_up()
        for name, line in net.argv().items():
            with self.subTest(switch=name):
                self.assertNotIn("ndtwin_switch.json", line)

    def test_the_plan_holds_one_json_per_switch(self):
        plan, _said = self.plan()
        self.assertEqual(sorted(plan.json_paths), [1, 2, 3, 4])
        self.assertTrue(plan.json_paths[1].endswith(os.path.join("build", "firewall.json")),
                        plan.json_paths[1])
        for dpid in (2, 3, 4):
            with self.subTest(dpid=dpid):
                self.assertTrue(
                    plan.json_paths[dpid].endswith(os.path.join("build", "basic.json")),
                    plan.json_paths[dpid])

    def test_plan_fabric_checks_every_switch_not_just_the_first(self):
        # 🔴 dpid 1's program is there and dpid 2's is not. A pre-flight that checked only the
        # first would return a plan, `reset_for_bring_up` would then `mn -c` the fabric that
        # was running, and s2 would die inside `simple_switch_grpc` with its error in
        # /tmp/s2_bmv2.log, which nothing reads.
        #
        # The package object is loaded first and the file removed afterwards on purpose:
        # `app_package.load` refuses a package that does not carry its own pipeline, so this is
        # the second of two doors, and it has to be tested with the first one already open.
        os.remove(os.path.join(self.pkg.dir, "build", "basic.json"))
        with self.assertRaises(testbed.FabricPlanError) as ctx:
            testbed.plan_fabric(package=self.pkg, report=lambda _line: None)
        self.assertIn("s2", str(ctx.exception))
        self.assertIn("basic.json", str(ctx.exception))

    def test_the_plan_says_out_loud_which_switches_are_not_on_ndtwins_pipeline(self):
        # By the time the proxy discloses this in `switch_state` the fabric is already up. An
        # operator reading a bring-up log has to be able to tell "telemetry is off because this
        # fabric runs somebody else's program" from "telemetry broke".
        _plan, said = self.plan()
        lines = [line for line in said if line.startswith("package pipelines: ")]
        self.assertEqual(len(lines), 1, said)
        self.assertIn("4 of 4", lines[0])
        self.assertIn("s1=firewall.json", lines[0])

    def test_the_baseline_says_nothing_of_the_kind(self):
        # The control. No package, no line -- a fabric on NDTwin's own pipeline must not start
        # explaining itself, or the line stops meaning anything when it does appear.
        self.patch(app_package, "KNOB_PATH", os.path.join(self.tmp, "no_such_knob"))
        _plan, said = self.plan()
        self.assertEqual([line for line in said if line.startswith("package pipelines: ")], [])


class AMixedFabricNamesOnlyTheSwitchesThatAreForeignTest(FabricFixture):
    """One switch on the exercise's program, three on NDTwin's own.

    [Co-developed with claude code -- Adam]
    The all-foreign case cannot tell a correct count from `len(dpids)`, and it cannot tell a
    correct list from "every switch". This one can: `1 of 4`, and s1 alone in the list. It
    matters because worker B's per-switch skips are driven by the same predicate -- a fabric
    where s2-s4 still get their clone session and telemetry, and only s1 does not, is the whole
    point of asking per switch instead of per fabric.
    """

    def setUp(self):
        super().setUp()
        self.pkg = load_two_program_package_fixture(only_s1_is_foreign=True, name="mixed")
        self.use_package(self.pkg)

    def test_only_s1_is_off_ndtwins_pipeline(self):
        self.assertFalse(self.pkg.pipeline_is_ndtwin(1, os.path.join(MININET_DIR, "..")))
        for dpid in (2, 3, 4):
            with self.subTest(dpid=dpid):
                self.assertTrue(self.pkg.pipeline_is_ndtwin(dpid, os.path.join(MININET_DIR, "..")))

    def test_the_plan_counts_one_of_four_and_lists_only_s1(self):
        _plan, said = self.plan()
        lines = [line for line in said if line.startswith("package pipelines: ")]
        self.assertEqual(len(lines), 1, said)
        self.assertIn("1 of 4", lines[0])
        self.assertIn("s1=firewall.json", lines[0])
        for switch in ("s2=", "s3=", "s4="):
            with self.subTest(switch=switch):
                self.assertNotIn(switch, lines[0])

    def test_the_other_three_are_launched_with_ndtwins_own_json(self):
        _plan, net, _result = self.bring_up()
        argv = net.argv()
        self.assertIn(os.path.join(self.pkg.dir, "build", "firewall.json"), argv["s1"])
        for name in ("s2", "s3", "s4"):
            with self.subTest(switch=name):
                self.assertIn(BASELINE_JSON, argv[name])
                self.assertNotIn("firewall.json", argv[name])

    def test_the_plans_json_paths_are_one_foreign_and_three_baseline(self):
        plan, _said = self.plan()
        self.assertTrue(plan.json_paths[1].endswith(os.path.join("build", "firewall.json")),
                        plan.json_paths[1])
        for dpid in (2, 3, 4):
            with self.subTest(dpid=dpid):
                self.assertEqual(plan.json_paths[dpid], BASELINE_JSON)


class TheBridgeNeverAsksForASwitchTheModelDoesNotDeclareTest(FabricFixture):
    """🔴 THE LIVE RED OF 2026-09-18, as a unit test.

    `ndt up p4 --app <basic>` reached `[1/3] bmv2 fabric` and reported `0/4 switches, manifest
    missing`. The cause was one line in ntg_bmv2_topo.main(): `switches = [net.get(f's{i}') for
    i in range(1, 11)]`. On a fabric built from a four-switch model, `net.get('s5')` raises
    KeyError -- before write_manifest, with no try/finally -- so the process died, tmux reaped
    the session, and the pane holding the traceback went with it.
    """

    def setUp(self):
        super().setUp()
        self.use_package(load_package_fixture())

    def test_the_bridges_main_never_asks_for_s5(self):
        nets = []
        self.patch(testbed, "build_net", lambda package, model: nets.append(
            RecordingNet(package, model)) or nets[-1])
        self.patch(testbed, "reset_for_bring_up", lambda ports, settle_s=0.5: None)
        ntg.main(enter_cli=lambda net: None)
        asked = nets[0].gets
        self.assertNotIn("s5", asked,
                         "the bridge asked a four-switch fabric for s5 -- this is the 09-18 "
                         "KeyError, and Mininet answers it with the exception that ended the "
                         "process")
        self.assertEqual([g for g in asked if g.startswith("s")], ["s1", "s2", "s3", "s4"])

    def test_the_same_is_true_of_the_other_main(self):
        nets = []
        self.patch(testbed, "build_net", lambda package, model: nets.append(
            RecordingNet(package, model)) or nets[-1])
        self.patch(testbed, "reset_for_bring_up", lambda ports, settle_s=0.5: None)
        self.patch(testbed, "CLI", lambda net: None)
        testbed.main()
        self.assertNotIn("s5", nets[0].gets)


# --- 4. the bridge's log ------------------------------------------------------------------------


class FakeTee:
    """Records the order of the calls ntg_bmv2_topo makes on its log."""

    def __init__(self):
        self.calls = []
        self.path = "/dev/null/topo.log"
        self.tracebacks = []

    def start(self):
        self.calls.append("start")
        return True

    def stop(self, join_timeout=5.0):
        self.calls.append("stop")

    def close(self):
        self.calls.append("close")

    def note(self, line):
        self.calls.append("note")

    def record_traceback(self, banner=None, text=None):
        # The real one formats the live exception when no text is given, which is how the
        # bridge calls it -- so the double has to do the same or the cell would be asserting
        # against `None` and passing for any exception at all.
        import traceback
        self.calls.append("record_traceback")
        self.tracebacks.append(traceback.format_exc() if text is None else text)


class TheBridgeRecordsWhatKilledItTest(FabricFixture):
    """`run()`: the log is open before main can fail, and a crash is written into it."""

    def test_the_log_is_started_before_main_runs(self):
        tee = FakeTee()
        seen = []
        ntg.run(tee=tee, main_=lambda tee=None: seen.append(list(tee.calls)))
        self.assertEqual(seen, [["start"]],
                         "main ran before the log was opened, so anything it printed on the "
                         "way to dying is in the pane and nowhere else")
        self.assertEqual(tee.calls, ["start", "close"])

    def test_an_uncaught_exception_is_recorded_and_then_re_raised(self):
        tee = FakeTee()

        def explode(tee=None):
            raise KeyError("s5")

        with self.assertRaises(KeyError):
            ntg.run(tee=tee, main_=explode)
        self.assertEqual(tee.calls, ["start", "record_traceback", "close"])
        self.assertIn("KeyError", tee.tracebacks[0] or "")
        self.assertIn("'s5'", tee.tracebacks[0] or "")

    def test_running_the_module_as_a_script_goes_through_run_not_main(self):
        # 🔴 EXISTENCE IS NOT WIRING, and every other cell in this file would stay green on the
        # defect: they call `run()` or `main()` themselves. `if __name__ == '__main__': main()`
        # ships a bridge whose log is never opened -- which is the whole ticket -- so the
        # module is EXECUTED as __main__ here, with the tee replaced by a recorder and the
        # pre-flight made to refuse at once, and what is asserted is that a tee was built and
        # started before anything else could happen.
        import runpy
        built = []

        class RecordingTee(FakeTee):
            def __init__(self, path, **kwargs):
                FakeTee.__init__(self)
                self.path = path
                built.append(self)

        self.patch(topo_log, "Tee", RecordingTee)

        def refuse(*args, **kwargs):
            raise SystemExit(7)

        def never(*args, **kwargs):
            # 🔴 The stop before `os.system('sudo mn -c')`. If the module under runpy somehow
            # bound a DIFFERENT p4_testbed_topo than the one patched here, the refusal above
            # would not fire and the next statement in main() tears down this machine's
            # fabric. It fails loudly instead.
            raise AssertionError("reset_for_bring_up was reached from a unit test")

        self.patch(testbed, "plan_fabric", refuse)
        self.patch(testbed, "reset_for_bring_up", never)
        self.setenv("NTG_DIR", self.tmp)
        # The re-executed module does `import p4_testbed_topo as testbed` and `import
        # topo_log`; both have to resolve to the copies patched above.
        self.stub_module("p4_testbed_topo", testbed)
        self.stub_module("topo_log", topo_log)
        self.assertIs(sys.modules["p4_testbed_topo"], testbed)

        with self.assertRaises(SystemExit) as ctx:
            runpy.run_path(os.path.join(MININET_DIR, "ntg_bmv2_topo.py"),
                           run_name="__main__")
        self.assertEqual(ctx.exception.code, 7, "the module did not reach the pre-flight")
        self.assertEqual(len(built), 1,
                         "running the bridge as a script opened no log at all -- __main__ is "
                         "not going through run(), so a crash would die in the pane again")
        self.assertEqual(built[0].calls[0], "start",
                         "the log was built but not started before main ran")

    def test_a_refusal_is_not_dressed_up_as_a_crash(self):
        # `fail()` has already printed its reason onto a stream the tee was copying; a
        # traceback here would only name the exit and would read like a defect in the bridge.
        tee = FakeTee()

        def refuse(tee=None):
            sys.exit(1)

        with self.assertRaises(SystemExit):
            ntg.run(tee=tee, main_=refuse)
        self.assertEqual(tee.calls, ["start", "close"])

    def test_the_tee_comes_off_for_the_prompt_and_goes_back_on_for_teardown(self):
        # 🔴 prompt_toolkit's create_output returns a PlainTextOutput the moment
        # sys.stdout.isatty() is false, so NTG's prompt needs the real descriptor back. What is
        # captured is the bring-up -- the part that fails -- and the teardown.
        self.use_package(load_package_fixture())
        tee = FakeTee()
        nets = []
        self.patch(testbed, "build_net", lambda package, model: nets.append(
            RecordingNet(package, model)) or nets[-1])
        self.patch(testbed, "reset_for_bring_up", lambda ports, settle_s=0.5: None)
        ntg.main(tee=tee, enter_cli=lambda net: tee.calls.append("NTG prompt"))
        self.assertEqual(tee.calls, ["note", "stop", "NTG prompt", "start"])

    def test_the_fabric_is_torn_down_even_when_the_prompt_raises(self):
        self.use_package(load_package_fixture())
        tee = FakeTee()
        nets = []
        self.patch(testbed, "build_net", lambda package, model: nets.append(
            RecordingNet(package, model)) or nets[-1])
        self.patch(testbed, "reset_for_bring_up", lambda ports, settle_s=0.5: None)

        def boom(net):
            raise RuntimeError("NTG died")

        with self.assertRaises(RuntimeError):
            ntg.main(tee=tee, enter_cli=boom)
        self.assertTrue(nets[0].stopped, "the net outlived the exception that ended the CLI")
        self.assertFalse(os.path.exists(self.manifest))


# --- 5. the pre-flight ---------------------------------------------------------------------------


class PlanFabricRefusesBeforeAnythingIsTornDownTest(FabricFixture):
    """Every refusal in the plan happens while the running fabric is still running."""

    def test_a_missing_compiled_json_is_refused_by_name(self):
        # Refused BEFORE reset_for_bring_up, which is the whole point of the pre-flight being a
        # function of its own: a fabric torn down for a pipeline that was never compiled is a
        # machine left worse than it was found.
        uncompiled = app_package.Package(
            pipeline=("p4_src/build/nope.p4info.txt", "p4_src/build/nope.json"))
        with self.assertRaises(testbed.FabricPlanError) as ctx:
            testbed.plan_fabric(package=uncompiled, report=lambda _line: None)
        self.assertIn("nope.json", str(ctx.exception))
        self.assertIn("p4c-bm2-ss", str(ctx.exception))

    def test_a_broken_binary_override_is_refused(self):
        broken = os.path.join(self.tmp, "override")
        with open(broken, "w") as fh:
            fh.write("# every line a comment\n")
        self.patch(testbed, "BINARY_OVERRIDE_PATH", broken)
        with self.assertRaises(ValueError) as ctx:
            testbed.plan_fabric(report=lambda _line: None)
        self.assertIn("no directive line", str(ctx.exception))

    def test_a_telemetry_knob_outside_the_domain_is_refused_in_the_pre_flight(self):
        # 🔴 F2. TICKET-P3 §2.1: a word outside the domain is "refuse to start". Read for the
        # first time inside `bring_up`, that refusal lands AFTER `reset_for_bring_up` has
        # destroyed the fabric that was running and AFTER `net.start()` has built its
        # replacement -- "refuse to start" degraded into "die halfway up".
        self.set_telemetry_knob("linkk")
        with self.assertRaises(app_package.AppPackageError) as ctx:
            testbed.plan_fabric(report=lambda _line: None)
        self.assertIn("'linkk'", str(ctx.exception))

    def test_the_refusal_happens_before_anything_is_reset(self):
        # The property that makes it a pre-flight rather than an early error: `plan_fabric`
        # returns (or raises) before `reset_for_bring_up` is ever called, and `main` calls them
        # in that order. Asserted by watching the reset itself.
        self.set_telemetry_knob("nonsense")
        reset = []
        self.patch(testbed, "reset_for_bring_up",
                   lambda ports, settle_s=0.5: reset.append(ports))
        self.patch(testbed, "build_net", lambda package, model: self.fail("built a net"))
        with self.assertRaises(SystemExit):
            testbed.main()
        self.assertEqual(reset, [], "the running fabric was destroyed before the knob was read")

    def test_the_plan_resolves_and_reports_the_source_of_every_switch(self):
        # The same argument the foreign-pipeline line above is here for: by the time the proxy
        # discloses this in `switch_state` the fabric is already up.
        self.set_telemetry_knob("link")
        plan, said = self.plan()
        self.assertEqual(plan.telemetry_knob, "link")
        self.assertEqual(plan.telemetry_sources, {dpid: "link" for dpid in range(1, 11)})
        self.assertIn("telemetry: link (knob) -> 10 link", said)

    def test_with_no_knob_the_plan_reports_the_rule_that_was_applied(self):
        plan, said = self.plan()
        self.assertIsNone(plan.telemetry_knob)
        self.assertIn("telemetry: auto (no knob) -> 10 cooperative", said)

    def test_the_plan_says_which_package_and_which_model_it_chose(self):
        # FINDING-01: a round that ran the wrong tree's topology for hours with no line of
        # output that could have caught it. Both mains print these two now; the bridge did not.
        _plan, said = self.plan()
        self.assertTrue(any(line.startswith("app package: ") for line in said), said)
        self.assertTrue(any(line.startswith("topology model: ") for line in said), said)
        self.assertTrue(any(line.startswith("bmv2 binary: ") for line in said), said)


# --- 6. G2-C: TCLink only when the package shaped something (TICKET-P3 section 2.4) ---------


class RecordingMininet:
    """Mininet's constructor, recorded. `build_net`'s whole subject is what it is called with."""

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        RecordingMininet.last = self


def shaped_package_fixture(name, edits):
    """CONVERTER_BASIC with `edits` applied to its `links`, laid out and loaded."""
    path = os.path.join(HERE, "test_app_package.py")
    spec = importlib.util.spec_from_file_location("test_app_package_fixture_source", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    manifest = json.loads(json.dumps(module.CONVERTER_BASIC))
    edits(manifest["links"])
    directory = module.lay_out_converter_package(
        _TMP, manifest, name,
        entry_files=[spec_["entries"] for spec_ in manifest["switches"].values()])
    return app_package.load(directory)


class TheMininetConstructorTest(FabricFixture):
    """`link=TCLink` reaches Mininet if and only if this package shaped a cable."""

    def setUp(self):
        super().setUp()
        self.patch(testbed, "Mininet", RecordingMininet)

    def build(self, package):
        plan, _said = self.plan() if package is None else (None, None)
        if package is None:
            package, model = plan.package, plan.model
        else:
            model = topo_from_json.load(package.topology)
        return testbed.build_net(package, model).kwargs

    def test_the_baseline_is_the_constructor_call_this_fabric_has_always_made(self):
        # 🔴 EQUAL, not "contains". The claim G2-C has to keep is that a fabric nobody asked to
        # shape is built exactly as before, and `assertIn` would pass with `link=TCLink` beside
        # the other three. Written from the literal in build_net's own first branch.
        kwargs = self.build(None)
        self.assertEqual(sorted(kwargs), ["autoSetMacs", "controller", "topo"])
        self.assertIs(kwargs["controller"], None)
        self.assertIs(kwargs["autoSetMacs"], True)
        self.assertIsInstance(kwargs["topo"], testbed.MultiSwitchTopo)

    def test_a_package_that_shapes_nothing_is_also_the_call_it_has_always_been(self):
        # pod-topo's every link is 1 Gbit/s with no delay, which is convert.py's default for a
        # tutorials link that declares neither -- so `basic` must not drag TCLink in.
        kwargs = self.build(load_package_fixture())
        self.assertEqual(sorted(kwargs), ["autoSetMacs", "controller", "topo"])

    def test_a_bandwidth_a_package_shaped_brings_tclink_in(self):
        package = shaped_package_fixture(
            "shaped_bw", lambda links: links[2].__setitem__("bandwidth_bps", 500000))
        kwargs = self.build(package)
        self.assertIs(kwargs["link"], StubTCLink)

    def test_a_delay_alone_brings_tclink_in(self):
        # Bandwidth left at the default: `delay_ms` on its own is shaping too, which is the
        # half of section 2.4's condition a `bandwidth_bps != DEFAULT` test cannot reach.
        package = shaped_package_fixture(
            "shaped_delay", lambda links: links[2].__setitem__("delay_ms", 5))
        self.assertIs(self.build(package)["link"], StubTCLink)


class OnlyTheShapedCablesCarryShapingTest(FabricFixture):
    """`bw=`/`delay=` land on the declared cable and on no other."""

    def topo_for(self, package):
        return testbed.MultiSwitchTopo(package=package,
                                       model=topo_from_json.load(package.topology))

    def kwargs_by_cable(self, topo):
        return {(a, kw.get("port1"), b, kw.get("port2")):
                {k: v for k, v in kw.items() if k not in ("port1", "port2")}
                for a, b, kw in topo.link_calls}

    def test_an_unshaped_package_adds_no_link_argument_anywhere(self):
        for kwargs in self.kwargs_by_cable(self.topo_for(load_package_fixture())).values():
            self.assertEqual(kwargs, {})

    def test_the_shaped_cable_gets_bw_in_mbit_and_the_others_get_nothing(self):
        # links[2] of CONVERTER_BASIC is {"a": ["s1", 3], "b": ["s3", 1]}: an inter-switch
        # cable, and the shape ecn/mri declare (`["s1-p3", "s2-p3", "0", 0.5]` -> 500000 bps).
        package = shaped_package_fixture(
            "only_one_shaped", lambda links: links[2].__setitem__("bandwidth_bps", 500000))
        cables = self.kwargs_by_cable(self.topo_for(package))
        self.assertEqual(cables[("s1", 3, "s3", 1)], {"bw": 0.5})
        others = [k for k, v in cables.items() if v and k != ("s1", 3, "s3", 1)]
        self.assertEqual(others, [], "shaping leaked onto a cable the package did not shape")

    def test_a_host_cable_can_be_shaped_too_and_is_matched_by_name_and_port(self):
        package = shaped_package_fixture(
            "shaped_host", lambda links: links[0].update({"bandwidth_bps": 2000000,
                                                          "delay_ms": 1.5}))
        cables = self.kwargs_by_cable(self.topo_for(package))
        # `{"a": ["h1", 1], "b": ["s1", 1]}`, and MultiSwitchTopo builds host cables as
        # (host, switch, port1=1, port2=port) -- so the match has to be unordered.
        self.assertEqual(cables[("h1", 1, "s1", 1)], {"bw": 2.0, "delay": "1.5ms"})

    def test_a_declared_zero_delay_is_no_delay_at_all(self):
        # tutorials' own rule, and convert.py's: ecn's `["s1-p3", "s2-p3", "0", 0.5]` asks for
        # the same delay pod-topo's `["h1", "s1-p1"]` asks for -- none. A netem for it would be
        # a qdisc the exercise never asked for.
        package = shaped_package_fixture(
            "zero_delay", lambda links: links[2].update({"delay_ms": 0}))
        self.assertEqual(app_package.shaped_links(package), [])
        for kwargs in self.kwargs_by_cable(self.topo_for(package)).values():
            self.assertEqual(kwargs, {})


# --- 7. link telemetry (TICKET-P3 sections 2.1, 2.2, 2.5) ------------------------------------


class LinkTelemetryIsOffUnlessSomethingAsksForItTest(FabricFixture):
    """The baseline, and the byte-identical claim that goes with it."""

    def test_no_knob_and_ndtwins_pipeline_means_no_tc_and_no_emitter(self):
        said = []
        self.bring_up(report=said.append)
        self.assertEqual(self.sub.tc(), [])
        self.assertEqual(self.sub.started, [])
        self.assertFalse(os.path.exists(self.link_manifest))

    def test_the_bring_up_says_why_it_is_off_rather_than_saying_nothing(self):
        said = []
        self.bring_up(report=said.append)
        line = [l for l in said if l.startswith("link telemetry:")]
        self.assertEqual(line, ["link telemetry: off (no switch is on the link path "
                                "(10 cooperative))"])

    def test_telemetry_none_switches_it_off_and_says_so(self):
        self.set_telemetry_knob("none")
        said = []
        self.bring_up(report=said.append)
        self.assertEqual(self.sub.tc(), [])
        self.assertIn("link telemetry: off (no switch is on the link path (10 none))", said)


class LinkTelemetryUnderTheKnobTest(FabricFixture):
    """`--telemetry link` on NDTwin's own ten-switch fabric: every filter, word for word."""

    def setUp(self):
        super().setUp()
        self.set_telemetry_knob("link")

    def test_every_port_gets_an_ingress_filter_and_only_host_ports_an_egress_one(self):
        self.bring_up()
        ingress = [c for c in self.sub.tc() if " ingress " in c]
        egress = [c for c in self.sub.tc() if " egress " in c]
        # 16 inter-switch cables = 32 switch-side ends, plus 4 host-facing ports.
        self.assertEqual(len(ingress), 36)
        # 🔴 FOUR, one per host. An egress filter on every port would double-count every
        # inter-switch link: the kernel already credits those from the RECEIVING switch's
        # ingress sample, and the one direction with no receiving switch is switch->host.
        self.assertEqual(len(egress), 4)
        self.assertEqual(sorted(c.split()[4] for c in egress),
                         ["s1-eth3", "s2-eth3", "s3-eth3", "s4-eth3"])

    def test_s1s_commands_are_the_ones_the_spike_measured(self):
        # 🔴 TRANSCRIBED from spike-tc-sample/spike.sh, which was run live on 2026-09-17 --
        # not read back from link_telemetry's own composer. s1 carries switch ports 1 and 2 and
        # host h1 on port 3, which tools/test_workflow/test_topo_from_json.py pins.
        self.bring_up()
        s1 = [c for c in self.sub.tc() if " s1-eth" in c]
        self.assertEqual(s1, [
            "tc qdisc add dev s1-eth1 clsact",
            "tc filter add dev s1-eth1 ingress matchall action sample rate 256 group 27 "
            "trunc 128",
            "tc qdisc add dev s1-eth2 clsact",
            "tc filter add dev s1-eth2 ingress matchall action sample rate 256 group 27 "
            "trunc 128",
            "tc qdisc add dev s1-eth3 clsact",
            "tc filter add dev s1-eth3 ingress matchall action sample rate 256 group 27 "
            "trunc 128",
            "tc filter add dev s1-eth3 egress matchall action sample rate 256 group 27 "
            "trunc 128",
        ])

    def test_the_rate_is_the_one_compiled_into_ndtwins_own_pipeline(self):
        # 1-in-256 on both telemetry paths, which is what makes the section 2.8 arms
        # comparable: a link arm at another rate would differ in two ways at once.
        self.assertEqual(link_telemetry.LINK_SAMPLE_RATE, 256)
        self.assertEqual(link_telemetry.LINK_SAMPLE_TRUNC, 128)

    def test_the_emitter_is_started_with_the_manifest_it_has_to_read(self):
        self.bring_up()
        self.assertEqual(len(self.sub.started), 1)
        argv = self.sub.started[0]
        self.assertEqual(argv[1:], [link_telemetry.EMITTER_PATH,
                                    "--manifest", self.link_manifest])

    def test_the_filters_are_on_before_the_emitter_is_started(self):
        # 🔴 ORDER, WHICH IS WHAT THIS CELL IS NAMED FOR -- it used to assert only that both
        # lists were non-empty, which the opposite order satisfies just as well.
        #
        # Attach first because a `tc` that fails is then a failure with no process to clean up:
        # `start_link_telemetry`'s recovery detaches, and it cannot stop an emitter whose pid
        # was never written down (the manifest is what carries it). Start the emitter first and
        # a mid-way attach failure leaves a process holding a psample group that nothing --
        # not this teardown, not the next bring-up -- can address.
        self.bring_up()
        kinds = self.sub.kinds()
        self.assertIn("popen", kinds, "the emitter was never started")
        self.assertEqual(kinds.count("popen"), 1)
        before = kinds[:kinds.index("popen")]
        self.assertEqual(sorted(set(before)), ["filter", "qdisc"],
                         "something other than the filters ran before the emitter")
        self.assertEqual(len(before), 76, "not every filter was on before the emitter started")
        self.assertEqual(kinds[kinds.index("popen") + 1:], [],
                         "a tc command ran after the emitter was started")

    def test_the_manifest_is_written_after_the_emitter_so_it_can_carry_its_pid(self):
        # The manifest is the only handle anything downstream gets on that process, and it is
        # written with `proc.pid` -- so writing it first would record None and every later
        # reader (`ndt status`, `verify_p4`, teardown, the next bring-up) would have nothing to
        # address. Pinned by order, not only by the value, because a value can be right by luck.
        order = []
        real = link_telemetry.write_manifest

        def write_manifest(plan, emitter_pid, path=None, log_path=None):
            order.append(("write_manifest", emitter_pid))
            return real(plan, emitter_pid, path=path, log_path=log_path)
        self.patch(link_telemetry, "write_manifest", write_manifest)
        original_popen = self.sub.Popen

        def popen(argv, **kwargs):
            proc = original_popen(argv, **kwargs)
            order.append(("popen", proc.pid))
            return proc
        self.sub.Popen = popen
        self.bring_up()
        self.assertEqual([step for step, _pid in order], ["popen", "write_manifest"])
        self.assertEqual(order[0][1], order[1][1])
        self.assertEqual(self.link_manifest_contents()["pid"], order[0][1])

    def test_the_manifest_names_the_pid_the_rate_and_every_port(self):
        self.bring_up()
        document = self.link_manifest_contents()
        self.assertEqual(document["pid"], 4242)
        self.assertEqual(document["rate"], 256)
        self.assertEqual(document["group"], 27)
        self.assertEqual(document["ifindex_width"], 16)
        self.assertEqual(document["sub_agent_id"], 1)
        self.assertEqual(document["collector"], ["127.0.0.1", 6343])
        self.assertEqual(len(document["switches"]), 10)
        s1 = document["switches"][0]
        self.assertEqual(s1["dpid"], 1)
        self.assertEqual(s1["agent_ip"], "192.168.123.11")
        self.assertEqual(sorted(s1["ports"]), ["1", "2", "3"])
        self.assertEqual(s1["ports"]["3"],
                         {"ifname": "s1-eth3", "ifindex": 1013, "key": 1013,
                          "ingress": True, "egress": True})
        self.assertEqual(s1["ports"]["1"]["egress"], False)

    def test_the_agent_address_is_the_one_the_kernel_looks_samples_up_by(self):
        # AgentKey{agentIP, port}: an address the kernel's topology does not hold produces
        # telemetry attributed to nothing -- no error, an empty twin.
        self.bring_up()
        document = self.link_manifest_contents()
        self.assertEqual([s["agent_ip"] for s in document["switches"]],
                         [f"192.168.123.{10 + d}" for d in range(1, 11)])

    def test_the_bring_up_line_counts_the_switches_and_the_filters(self):
        said = []
        self.bring_up(report=said.append)
        self.assertIn("link telemetry: 10 switch(es), 36 ingress + 4 egress filters, "
                      "emitter pid 4242", said)

    def test_the_emitter_gets_its_own_log_and_not_the_topologys_descriptors(self):
        # 🔴 `topo_log.Tee` is an FD-level tee whose `stop()` ends the pump by letting the LAST
        # write end of its pipe go -- and its own comment states the invariant: this process
        # owns them all, because Mininet's node shells get their own pipes and bmv2 is launched
        # onto /tmp/sN_bmv2.log. A child of ours holding fd 2 would make `stop()` burn its
        # five-second join on every bring-up and put a statistics line on the operator's NTG
        # prompt every ten seconds for the life of the fabric.
        self.bring_up()
        self.assertTrue(os.path.exists(self.link_log),
                        "the emitter was not given a log file of its own")
        self.assertEqual(self.link_manifest_contents()["log"], self.link_log)

    def test_the_manifest_records_the_tc_commands_that_were_run(self):
        self.bring_up()
        recorded = [" ".join(argv) for argv in self.link_manifest_contents()["tc_commands"]]
        self.assertEqual(recorded, self.sub.tc())


class TearingLinkTelemetryDownTest(FabricFixture):
    """The emitter, then the filters, then the net -- and the manifest last."""

    def setUp(self):
        super().setUp()
        self.set_telemetry_knob("link")
        self.events = []
        # Mutable rather than re-patched: `stop_emitter` binds its predicate once, on the way
        # in, so a SIGTERM that "worked" has to be observable through the same callable.
        self.emitter_alive = [True]
        self.patch(link_telemetry, "process_is_the_emitter",
                   lambda pid, **kw: pid == 4242 and self.emitter_alive[0])

        def kill(pid, sig):
            self.events.append(("kill", pid, sig))
            self.emitter_alive[0] = False       # it went on the SIGTERM
        self.kill = kill

    def tear_down(self):
        _plan, net, (built, _s, _f, _r, _u) = self.bring_up()
        original_run = self.sub.run

        def run(argv, **kwargs):
            self.events.append(("tc", " ".join(argv)))
            return original_run(argv, **kwargs)
        self.sub.run = run
        original_stop = net.stop

        def stop():
            self.events.append(("net.stop",))
            return original_stop()
        net.stop = stop
        testbed.tear_down(built, manifest_path=self.manifest,
                          link_manifest_path=self.link_manifest,
                          report=lambda _line: None)
        return net

    def test_the_emitter_is_signalled_by_the_pid_the_manifest_named(self):
        self.patch(link_telemetry, "stop_emitter",
                   lambda pid, **kw: self.events.append(("stop", pid)) or "term")
        self.tear_down()
        self.assertIn(("stop", 4242), self.events)

    def test_the_qdiscs_come_off_before_the_net_is_stopped(self):
        # 🔴 ORDER. `net.stop()` deletes the veths; a `tc qdisc del` after it is addressed to
        # devices that are gone, so the filters would come off only by accident.
        self.patch(link_telemetry, "stop_emitter", lambda pid, **kw: "term")
        self.tear_down()
        kinds = [e[0] for e in self.events]
        self.assertIn("net.stop", kinds)
        first_del = min(i for i, e in enumerate(self.events)
                        if e[0] == "tc" and "qdisc del" in e[1])
        self.assertLess(first_del, kinds.index("net.stop"))

    def test_every_interface_that_was_given_a_qdisc_gets_it_taken_away(self):
        self.patch(link_telemetry, "stop_emitter", lambda pid, **kw: "term")
        self.tear_down()
        removed = [e[1].split()[4] for e in self.events
                   if e[0] == "tc" and "qdisc del" in e[1]]
        self.assertEqual(len(removed), 36)
        self.assertEqual(sorted(set(removed)), sorted(removed),
                         "an interface was detached twice")

    def test_the_emitter_is_sigtermed_and_then_left_alone_when_it_goes(self):
        self.patch(link_telemetry, "os", _OsWithKill(self.kill))
        self.tear_down()
        self.assertEqual([e for e in self.events if e[0] == "kill"],
                         [("kill", 4242, signal.SIGTERM)])

    def test_the_manifest_is_gone_afterwards(self):
        self.patch(link_telemetry, "stop_emitter", lambda pid, **kw: "term")
        self.tear_down()
        self.assertFalse(os.path.exists(self.link_manifest))

    def test_a_teardown_with_no_link_telemetry_at_all_is_quiet(self):
        # The baseline path, and the one every existing case in this file takes.
        fate, removed, document = link_telemetry.shut_down(
            os.path.join(self.tmp, "no_such_manifest.json"))
        self.assertEqual((fate, removed, document), (None, [], None))


class _OsWithKill:
    """`os`, with `kill` replaced. Everything else is the real module."""

    def __init__(self, kill):
        self.kill = kill

    def __getattr__(self, name):
        return getattr(os, name)


class AnEmitterThatDiedIsFatalTest(FabricFixture):
    """Section 2.5: not a warning. The filters are on and nothing is listening."""

    def setUp(self):
        super().setUp()
        self.set_telemetry_knob("link")

    def test_a_fabric_whose_emitter_exited_is_refused(self):
        self.sub.process = FakeProcess(pid=777, exits=9)
        _plan, _net, (_n, _s, fatal, verdict, _u) = self.bring_up()
        self.assertTrue(fatal, "ten healthy switches and a dead emitter was not fatal")
        self.assertIn("exited with 9", verdict)
        self.assertIn("zero link usage", verdict)

    def test_a_live_emitter_on_a_healthy_fabric_is_not_fatal_and_says_nothing(self):
        _plan, _net, (_n, _s, fatal, verdict, _u) = self.bring_up()
        self.assertFalse(fatal)
        self.assertIsNone(verdict)

    def test_a_dead_switch_and_a_dead_emitter_are_both_reported(self):
        # An operator told only about the switch fixes half of it.
        self.sub.process = FakeProcess(pid=777, exits=1)
        _plan, _net, (_n, _s, fatal, verdict, _u) = self.bring_up(healthy=False)
        self.assertTrue(fatal)
        self.assertIn("0/10", verdict)
        self.assertIn("link-telemetry emitter", verdict)


class StartingTheEmitterTest(FabricFixture):
    """The grace period itself, which every other case patches to zero."""

    def setUp(self):
        super().setUp()
        self.set_telemetry_knob("link")

    def start(self, process, grace_s, slept=None):
        plan, _said = self.plan()
        net = RecordingNet(plan.package, plan.model)
        switches = [net.get(name) for _d, name in topo_from_json.switches(plan.model)]
        self.sub.process = process
        return testbed.start_link_telemetry(
            plan.package, plan.model, switches, manifest_path=self.link_manifest,
            report=lambda _line: None, grace_s=grace_s,
            sleep=(slept.append if slept is not None else lambda _s: None))

    def test_an_emitter_that_survives_the_grace_period_is_polled_until_it_expires(self):
        slept = []
        result = self.start(FakeProcess(pid=11), grace_s=0.5, slept=slept)
        self.assertFalse(result.fatal)
        # 0.5s in 0.1s steps: five sleeps, and it was asked each time rather than once.
        self.assertEqual(len(slept), 5)   # 0.5s in 0.1s steps, stated as a trip count

    def test_an_emitter_that_dies_during_the_grace_period_is_caught(self):
        # Alive for the first two polls, gone on the third: the case a single poll at t=0
        # cannot see, which is the whole reason there is a grace period.
        slept = []
        result = self.start(FakeProcess(pid=11, exits=[None, None, 3]),
                            grace_s=1.0, slept=slept)
        self.assertTrue(result.fatal)
        self.assertIn("exited with 3", result.verdict)
        self.assertLess(len(slept), 10, "the loop did not stop when the process did")


class NothingIsLeftAttachedOnAPathNoTeardownRunsTest(FabricFixture):
    """The two ways a `clsact` qdisc could outlive the process that installed it."""

    def setUp(self):
        super().setUp()
        self.set_telemetry_knob("link")

    def fail_attach_at(self, device):
        """Make the `tc filter add` for `device` fail, the way a missing veth does."""
        original = self.sub.run

        def run(argv, **kwargs):
            if device in " ".join(argv) and argv[1] == "filter":
                self.sub.rc = 2
            return original(argv, **kwargs)
        self.sub.run = run

    def test_an_attach_that_failed_takes_off_what_it_had_already_put_on(self):
        # 🔴 The manifest is not written until the emitter exists, so `tear_down` -- which reads
        # it -- would find nothing to undo. Without this recovery both mains would leave
        # `clsact` on whichever interfaces got that far.
        self.fail_attach_at("s5-eth")
        _plan, _net, (_n, _s, fatal, _v, _u) = self.bring_up()
        self.assertTrue(fatal)
        deletes = [c for c in self.sub.ran if c[1:3] == ["qdisc", "del"]]
        self.assertTrue(deletes, "a failed attach left every qdisc it had installed behind")

    def test_an_attach_that_failed_started_no_emitter_to_be_orphaned(self):
        # The other half of why attach comes first: there is no process to stop, and no pid
        # written down that anything could stop it BY.
        self.fail_attach_at("s5-eth")
        self.bring_up()
        self.assertEqual(self.sub.started, [])
        self.assertFalse(os.path.exists(self.link_manifest))

    def test_a_previous_runs_emitter_is_stopped_before_a_new_fabric_is_built(self):
        # `mn -c` does not touch it, exactly as `mn -c` does not touch bmv2. An emitter orphaned
        # by a closed terminal holds a psample group and writes sFlow the kernel attributes to a
        # fabric that no longer exists.
        stale = link_telemetry.plan(app_package.baseline(),
                                    topo_from_json.load(FOUR_HOST_MODEL),
                                    [], knob_path=self.telemetry_knob_path)
        link_telemetry.write_manifest(stale, 4242, path=self.link_manifest)
        stopped = []
        self.patch(link_telemetry, "stop_emitter",
                   lambda pid, **kw: stopped.append(pid) or "term")
        # 🔴 `reset_for_bring_up` runs `sudo mn -c`. TICKET-P3 section 0 forbids this suite
        # from touching Mininet at all, so the one call that would is replaced -- restored by
        # addCleanup whether this case passes or fails.
        self.patch(testbed.os, "system", lambda _cmd: 0)
        self.patch(testbed, "clear_switches_from_a_previous_run",
                   lambda ports=(), **kw: ([], []))
        self.patch(testbed, "abort_if_grpc_ports_are_held", lambda held, **kw: None)
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            testbed.reset_for_bring_up([30051], settle_s=0.0)
        self.assertEqual(stopped, [4242])
        self.assertFalse(os.path.exists(self.link_manifest))
        # 🔴 AND IT SAID SO. Everything else this function reaps is announced -- the switch
        # reap prints what it took, `abort_if_grpc_ports_are_held` names the holder -- because
        # "something killed my process" is exactly the kind of fact that is unanswerable later.
        # A stale emitter killed in silence would be the one exception, for no reason.
        self.assertIn("link telemetry: emitter pid 4242 term", said.getvalue())


class ARefusalInsideTheBringUpIsAVerdictAndNotATracebackTest(FabricFixture):
    """🔴 F1. `bring_up` is not inside either main's `except ValueError` -- only `plan_fabric` is.

    `link_telemetry.plan` refuses four things (a switch in its own netns, an unreadable ifindex,
    two interfaces aliasing in psample's sixteen bits, a link switch with no agent address),
    `attach` a fifth, and the knob reader a sixth. Every one is a ValueError, and for a long
    time this file called that "both mains already catch it". They do -- around `plan_fabric`,
    which has already returned by then. By the time these fire, `net` has been built and
    STARTED, and a bare raise would unwind out of `bring_up` past a `tear_down` that is only
    ever reached through the `fatal` return: a running fabric, no manifest, whatever filters
    got attached, and the traceback in a tmux pane that stops existing when the process does.
    """

    def setUp(self):
        super().setUp()
        self.set_telemetry_knob("link")
        # Two interfaces that collide in the low sixteen bits: `plan()` refuses, because
        # whichever alias won, every sample from the other would be booked against it.
        self.patch(link_telemetry, "read_ifindex",
                   lambda ifname, sys_root=None: {"s1-eth1": 0x00010001,
                                                  "s2-eth1": 0x00020001}.get(
                                                      ifname, fake_ifindex(ifname)))

    def test_it_comes_back_as_a_fatal_verdict_that_names_the_reason(self):
        _plan, _net, (_n, _s, fatal, verdict, _u) = self.bring_up()
        self.assertTrue(fatal, "a fabric whose link telemetry was refused was not fatal")
        self.assertIn("link telemetry could not be brought up", verdict)
        self.assertIn("s1-eth1", verdict)
        self.assertIn("attributed to the other", verdict)

    def test_a_dead_switch_and_a_refusal_are_both_reported(self):
        _plan, _net, (_n, _s, fatal, verdict, _u) = self.bring_up(healthy=False)
        self.assertTrue(fatal)
        self.assertIn("0/10", verdict)
        self.assertIn("link telemetry could not be brought up", verdict)

    def drive(self, main, **extra):
        nets = []
        self.patch(testbed, "build_net", lambda package, model: nets.append(
            RecordingNet(package, model)) or nets[-1])
        self.patch(testbed, "reset_for_bring_up", lambda ports, settle_s=0.5: None)
        self.patch(testbed, "CLI", lambda net: None)
        self.patch(link_telemetry, "process_is_the_emitter", lambda pid, **kw: False)
        with self.assertRaises(SystemExit) as ctx:
            main(**extra)
        self.assertEqual(ctx.exception.code, 1)
        self.assertEqual(len(nets), 1)
        return nets[0]

    def test_the_topology_script_stops_the_net_it_started(self):
        # 🔴 THE CELL THE FIRST ROUND WAS MISSING. `net.stopped` is the whole question: a
        # refusal that unwound would leave this False and a fabric up.
        self.assertTrue(self.drive(testbed.main).stopped)

    def test_the_bridge_stops_the_net_it_started(self):
        # And the bridge above all, because `ndtwin-lab topo-start` launches THIS one.
        self.assertTrue(self.drive(ntg.main, enter_cli=lambda net: None).stopped)

    def test_nothing_is_left_attached_and_no_emitter_was_started(self):
        self.drive(testbed.main)
        self.assertEqual(self.sub.started, [],
                         "an emitter was started for a plan that was refused")
        # `plan()` refused before `attach`, so there is nothing to detach -- and nothing was
        # attached either. The fabric is exactly as it was, minus the net.
        self.assertEqual(self.sub.tc(), [])
        self.assertFalse(os.path.exists(self.link_manifest))

    def test_a_defect_in_this_code_is_still_a_traceback(self):
        # 🔴 The catch is ValueError and stays ValueError. A verdict that swallowed an
        # AttributeError would turn a bug in this file into "the fabric is partly up", which is
        # the shape the fatal verdict exists to stop being.
        def boom(*_a, **_k):
            raise AttributeError("a defect, not a fabric verdict")
        self.patch(link_telemetry, "plan", boom)
        with self.assertRaises(AttributeError):
            self.bring_up()


# --- 7b. the shutdown signal, and the teardown that has to survive it ------------------------
#
# 🔴 THE ONLY DEFECT LIVE FOUND (TICKET-P3 section 9 ruling 19(1), 2026-09-19). `ndt down`
# reported "residue: /tmp/ndtwin_link_telemetry.json is still there and the pid it names
# (2386073) is gone" after every run. `ndtwin-lab topo-stop` sends C-c to the tmux pane, waits
# ten seconds, then `kill-session`; Mininet's CLI catches KeyboardInterrupt and carries on by
# design, so the C-c did nothing, and the SIGHUP landed on a process whose `main()` was a bare
# `CLI(net)` followed by `tear_down(net)` -- python died between the two lines. Every cell
# below is one link in that chain.


class TheShutdownSignalReachesTheTeardownTest(FabricFixture):

    def setUp(self):
        super().setUp()
        self.set_telemetry_knob("link")
        # Whatever this suite installs for real is put back afterwards, whichever way it ends.
        for name in testbed.TEARDOWN_SIGNALS:
            number = getattr(signal, name, None)
            if number is not None:
                self.addCleanup(signal.signal, number, signal.getsignal(number))

    def raise_guarded(self, name):
        """Raise this signal at ourselves, but never with its default disposition in place.

        🔴 THE GUARD IS THE WHOLE POINT, and it is here because its absence cost a gate run:
        with SIGHUP left at SIG_DFL, `signal.raise_signal` TERMINATES the test runner. The
        suite then produces no output at all -- unittest prints its failures at the end -- so a
        mutant that removed a handler came back as a SURVIVOR of nothing rather than as a red
        cell. A test that can kill its own runner is not a test.
        """
        number = getattr(signal, name)
        self.assertNotIn(signal.getsignal(number), (signal.SIG_DFL, signal.SIG_IGN, None),
                         f"{name} still has its default disposition -- raising it here would "
                         f"terminate this process instead of testing anything")
        signal.raise_signal(number)

    def test_all_three_signals_are_installed(self):
        installed = testbed.install_teardown_signal_handlers(
            report=lambda _line: None, install=lambda number, handler: None)
        self.assertEqual(installed, ["SIGINT", "SIGTERM", "SIGHUP"])

    def test_each_one_really_changes_the_disposition_and_raises(self):
        # 🔴 Guarded on purpose: if the handler were NOT installed, raising SIGTERM or SIGHUP
        # here would terminate the test runner. The assertion below fails first in that case,
        # so this cell can never be the thing that kills the suite.
        testbed.install_teardown_signal_handlers(report=lambda _line: None)
        for name in ("SIGINT", "SIGTERM", "SIGHUP"):
            with self.assertRaises(SystemExit) as ctx:
                self.raise_guarded(name)
            self.assertEqual(ctx.exception.code, 0)
            # Re-armed for the next one: each iteration is a fresh "first" signal.
            testbed.install_teardown_signal_handlers(report=lambda _line: None)

    def test_the_second_signal_does_not_interrupt_the_teardown_the_first_asked_for(self):
        # `topo-stop` sends C-c and then SIGHUP ten seconds later, so the second one can easily
        # land while the teardown is still running. Re-raising there would abort it halfway and
        # leave exactly the residue this exists to remove.
        said = []
        testbed.install_teardown_signal_handlers(report=said.append)
        with self.assertRaises(SystemExit):
            self.raise_guarded("SIGINT")
        self.raise_guarded("SIGHUP")      # must NOT raise
        self.raise_guarded("SIGTERM")     # nor this
        self.assertEqual(len([line for line in said if "tearing the fabric down" in line]), 1)
        self.assertEqual(len([line for line in said if "still going" in line]), 2)

    def test_a_cli_that_catches_keyboardinterrupt_still_lets_the_shutdown_out(self):
        # 🔴 THE LIVE DEFECT, IN A UNIT TEST. This is `mininet.cli.CLI.run`'s shape: a
        # `while True` whose body is wrapped in `except KeyboardInterrupt`, which is exactly
        # why the C-c did nothing. With our handler installed the signal raises SystemExit --
        # a BaseException that is not a KeyboardInterrupt -- so the catch does not see it and
        # it leaves the loop.
        #
        # Checked rather than assumed, 2026-09-19: there is no `signal.signal` anywhere in
        # mininet/*.py on this machine, so nothing puts the default disposition back.
        testbed.install_teardown_signal_handlers(report=lambda _line: None)
        loops = []
        raise_guarded = self.raise_guarded

        def mininets_cli_loop():
            while True:
                try:
                    raise_guarded("SIGINT")              # what topo-stop's C-c becomes
                    return "the signal did nothing at all"
                except KeyboardInterrupt:
                    loops.append(1)
                    if len(loops) > 3:
                        raise RuntimeError(
                            "the shutdown was swallowed by the CLI loop, which is the "
                            "2026-09-19 live defect")
        with self.assertRaises(SystemExit):
            mininets_cli_loop()
        self.assertEqual(loops, [], "the CLI loop caught our shutdown")

    def test_catching_keyboardinterrupt_does_not_catch_systemexit(self):
        # The load-bearing step of the argument above, pinned on its own so that if Python
        # ever changed it this file says which cell to read.
        try:
            raise SystemExit(0)
        except KeyboardInterrupt:                        # noqa: B014 -- that is the point
            self.fail("a KeyboardInterrupt catch swallowed a SystemExit")
        except SystemExit:
            pass


class BothMainsTearDownWhateverEndsTheCliTest(FabricFixture):
    """The `finally`, driven through each main with a CLI that ends the way a signal ends it."""

    def setUp(self):
        super().setUp()
        self.set_telemetry_knob("link")
        self.torn = []
        self.order = []

    def drive(self, main, cli, **extra):
        nets = []
        real_tear_down = testbed.tear_down

        def tear_down(net, manifest_path=None, report=print, link_manifest_path=None):
            self.torn.append(net)
            return real_tear_down(net, manifest_path=manifest_path,
                                  report=lambda _line: None,
                                  link_manifest_path=link_manifest_path or self.link_manifest)
        self.patch(testbed, "build_net", lambda package, model: nets.append(
            RecordingNet(package, model)) or nets[-1])
        self.patch(testbed, "reset_for_bring_up", lambda ports, settle_s=0.5: None)
        self.patch(testbed, "CLI", cli)
        self.patch(testbed, "tear_down", tear_down)
        self.patch(link_telemetry, "process_is_the_emitter", lambda pid, **kw: False)
        # The real handlers are not installed by these cells: `main` installs them, and this
        # process must not be left with them afterwards. Recorded rather than silenced, so
        # "main arms them at all" is a fact a cell can read -- and it is one of the two halves
        # of ruling 19(1); the `finally` without the handlers is a `finally` nothing reaches.
        self.patch(testbed, "install_teardown_signal_handlers",
                   lambda **kwargs: self.order.append("armed") or ["SIGINT", "SIGTERM",
                                                                   "SIGHUP"])
        try:
            main(**extra)
        except SystemExit as exc:
            return nets[0], exc.code
        return nets[0], None

    def signalled_cli(self, net):
        """What `CLI(net)` does once a shutdown signal has raised SystemExit through it."""
        self.order.append("cli")
        raise SystemExit(0)

    def test_the_handlers_are_armed_before_the_cli_is_entered(self):
        # 🔴 The other half of ruling 19(1). A `finally` is not reached by a signal whose
        # disposition is still the default: SIGHUP terminates the process where it stands.
        self.drive(testbed.main, self.signalled_cli)
        self.assertEqual(self.order, ["armed", "cli"])

    def test_the_bridge_arms_them_too(self):
        self.drive(ntg.main, lambda _net: None,
                   enter_cli=lambda _net: self.order.append("cli"))
        self.assertEqual(self.order, ["armed", "cli"])

    def test_the_topology_script_tears_down_when_the_cli_is_cut_short(self):
        net, code = self.drive(testbed.main, self.signalled_cli)
        self.assertEqual(code, 0)
        self.assertEqual(self.torn, [net], "tear_down did not run, or ran twice")
        self.assertTrue(net.stopped)
        self.assertFalse(os.path.exists(self.link_manifest),
                         "the link manifest outlived the process, which is the live defect")

    def test_the_bridge_tears_down_when_the_cli_is_cut_short(self):
        # `ndtwin-lab topo-start` launches THIS one, so it is the one that mattered nightly.
        net, code = self.drive(ntg.main, self.signalled_cli,
                               enter_cli=lambda _net: (_ for _ in ()).throw(SystemExit(0)))
        self.assertEqual(code, 0)
        self.assertTrue(net.stopped)
        self.assertFalse(os.path.exists(self.link_manifest))

    def test_a_normal_cli_exit_still_tears_down_exactly_once(self):
        net, code = self.drive(testbed.main, lambda _net: None)
        self.assertIsNone(code)
        self.assertEqual(self.torn, [net])
        self.assertFalse(os.path.exists(self.link_manifest))

    def test_a_fatal_fabric_tears_down_exactly_once_and_still_exits_one(self):
        # 🔴 There used to be a `tear_down(net)` on the fatal line AND now there is a
        # `finally`. Two teardowns would mean `net.stop()` twice and a second reap of a
        # manifest that is already gone.
        self.sub.process = FakeProcess(pid=777, exits=9)
        net, code = self.drive(testbed.main, lambda _net: self.fail("the CLI was offered"))
        self.assertEqual(code, 1)
        self.assertEqual(self.torn, [net], "the fatal path tore the fabric down twice")

    def test_an_exception_out_of_the_cli_also_reaches_the_teardown(self):
        # Not only signals: NTG's command loop has crashed in here before, and the fabric it
        # was driving must not be left up because of it.
        def angry_cli(_net):
            raise RuntimeError("the CLI fell over")
        with self.assertRaises(RuntimeError):
            self.drive(testbed.main, angry_cli)
        self.assertEqual(len(self.torn), 1)


# --- 8. both entry points, on the link path --------------------------------------------------


class TheTwoEntryPointsBringLinkTelemetryUpTheSameWayTest(FabricFixture):
    """The section-4.2 claim: this is one bring-up, so it is one on the link path too."""

    def setUp(self):
        super().setUp()
        self.set_telemetry_knob("link")

    def drive(self, main, **extra):
        recorded = {}
        real_tear_down = testbed.tear_down

        def tear_down(net, manifest_path=None, report=print, link_manifest_path=None):
            try:
                with open(link_manifest_path or self.link_manifest) as fh:
                    recorded["manifest"] = json.load(fh)
            except (OSError, ValueError):
                recorded["manifest"] = None
            return real_tear_down(net, manifest_path=manifest_path, report=report,
                                  link_manifest_path=link_manifest_path or self.link_manifest)

        nets = []
        self.patch(testbed, "build_net", lambda package, model: nets.append(
            RecordingNet(package, model)) or nets[-1])
        self.patch(testbed, "reset_for_bring_up", lambda ports, settle_s=0.5: None)
        self.patch(testbed, "CLI", lambda net: None)
        self.patch(testbed, "tear_down", tear_down)
        self.patch(link_telemetry, "process_is_the_emitter", lambda pid, **kw: False)
        self.sub.reset()
        main(**extra)
        return {"tc": self.sub.tc(), "started": self.sub.started,
                "manifest": recorded.get("manifest")}

    def test_both_mains_attach_the_same_filters_and_start_the_same_emitter(self):
        # 🔴 `ndtwin-lab topo-start` launches the BRIDGE. For as long as the two files carried
        # two copies of the bring-up, a feature landing in the other one was a feature that
        # never ran. This is that assertion for link telemetry.
        from_topo = self.drive(testbed.main)
        from_bridge = self.drive(ntg.main, enter_cli=lambda net: None)
        self.assertEqual(from_topo, from_bridge)
        # 36 clsact qdiscs + 36 ingress + 4 egress filters on the way up, and one `qdisc del`
        # per interface on the way down. Spelled out rather than as a total, because a total
        # cannot tell "the egress filters went missing" from "four extra deletes".
        commands = from_topo["tc"]
        self.assertEqual(len([c for c in commands if "qdisc add" in c]), 36)
        self.assertEqual(len([c for c in commands if "filter add" in c and " ingress " in c]), 36)
        self.assertEqual(len([c for c in commands if "filter add" in c and " egress " in c]), 4)
        self.assertEqual(len([c for c in commands if "qdisc del" in c]), 36)

    def test_the_default_manifest_path_is_the_one_every_other_reader_uses(self):
        # Neither main passes a path -- `ndt status`, `verify_p4` and the proxy's
        # `switch_state` all find the emitter through this one name.
        self.assertEqual(link_telemetry.LINK_TELEMETRY_MANIFEST, self.link_manifest)


if __name__ == "__main__":
    unittest.main()

# [Co-developed with claude code -- Adam]
