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
import importlib.util
import json
import os
import shutil
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
        "mininet.link": {"Intf": StubIntf},
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

    def test_the_pipeline_is_still_ndtwins_own_because_g4_is_not_built(self):
        plan, _said = self.plan()
        self.assertEqual(plan.json_path, BASELINE_JSON)


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

    def test_the_plan_says_which_package_and_which_model_it_chose(self):
        # FINDING-01: a round that ran the wrong tree's topology for hours with no line of
        # output that could have caught it. Both mains print these two now; the bridge did not.
        _plan, said = self.plan()
        self.assertTrue(any(line.startswith("app package: ") for line in said), said)
        self.assertTrue(any(line.startswith("topology model: ") for line in said), said)
        self.assertTrue(any(line.startswith("bmv2 binary: ") for line in said), said)


if __name__ == "__main__":
    unittest.main()

# [Co-developed with claude code -- Adam]
