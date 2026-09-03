"""Tests for the sFlow configuration in tools/test_workflow/ovs_4host_topo.py.

[Co-developed with claude code -- Adam]

The defect (finding #4, measured 2026-09-02): the file had ZERO sFlow references. All ten
bridges came up with `sflow=[]` while the kernel listened on :6343 as usual, so
`/ndt/get_average_link_usage` answered `{"avg_link_usage":0.0,"status":"success"}` through
3000 packets of real traffic and every per-flow rate read zero. Nothing failed. "We never
asked" and "the network is idle" were the same output on every channel.

🔴 What these tests are actually about is AGREEMENT BETWEEN FILES, not whether the script
parses. Three separate files have to hold the same numbers or the fix does not work and
nothing says so:

  * the agent address. The kernel identifies a sample's switch by the agent address inside
    the datagram (FlowLinkUsageCollector.cpp `agentIp = data[2]`) and looks up the edge whose
    src_ip matches (TopologyAndFlowMonitor::findEdgeByAgentIpAndPort). So the address this
    script assigns must be the address setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json
    declares -- a topology that samples with any other address produces datagrams that parse,
    match no edge, and read exactly like no datagrams at all.
  * the sFlow parameters. testbed_topo.py, the reference topology `ndt up ovs` runs, has had
    them since it was written. They are read out of that file here rather than copied, so
    "same as the reference" is falsifiable instead of asserted in a comment.
  * the collector port. Declared in this script, in `ndt` (SFLOW_PORT) and in ports.sh's 6343
    row; a change to one of them must not leave the other two lying.

No Mininet, no fabric, no root. The mininet package is stubbed so the module can be imported,
and the ovs-vsctl/ifconfig seam is a recorder -- nothing here runs a command.

Needs no third-party package: run under test_env/bin/python or p4_proxy/venv/bin/python.

    test_env/bin/python -m unittest discover -s tests/python -p 'test_ovs4_sflow.py' -v
Env: OVS4_TOPO_UNDER_TEST=<path>  NDT_UNDER_TEST=<path>   (the mutation gate sets both)
"""

from __future__ import annotations

import ast
import importlib.util
import json
import os
import re
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

TOPO_SCRIPT = os.environ.get(
    "OVS4_TOPO_UNDER_TEST", os.path.join(REPO, "tools", "test_workflow", "ovs_4host_topo.py"))
NDT = os.environ.get("NDT_UNDER_TEST", os.path.join(REPO, "tools", "test_workflow", "ndt"))
PORTS_SH = os.path.join(os.path.dirname(NDT), "ports.sh")
MODEL = os.path.join(REPO, "setting", "StaticNetworkTopologyOVS_10Switches_4Hosts.json")

#: The reference topology whose parameters must not be re-invented. The repo copy is the one
#: with the polling=0 reasoning written out; NTG's is the copy `ndt up ovs` actually executes,
#: and is checked too when it is present so the two cannot drift apart unnoticed.
REFERENCE = os.path.join(REPO, "testbed_topo.py")
REFERENCE_NTG = "/home/adam/Network-Traffic-Generator/testbed_topo.py"

SWITCHES = 10


def install_mininet_stubs():
    """Put stub mininet packages into sys.modules so the topology file can be imported.

    The file imports mininet at module level and mininet is not in either venv. Only the
    names the module body touches are needed: `Topo` is subclassed at import time, the rest
    are looked up inside main(), which these tests never run.
    """
    def module(name, **attrs):
        mod = types.ModuleType(name)
        for key, value in attrs.items():
            setattr(mod, key, value)
        sys.modules[name] = mod
        return mod

    module("mininet")
    module("mininet.cli", CLI=object)
    module("mininet.log", setLogLevel=lambda *a, **k: None)
    module("mininet.net", Mininet=object)
    module("mininet.node", OVSKernelSwitch=object, RemoteController=object)

    class StubTopo:
        def __init__(self, **opts):
            pass

        def addSwitch(self, name, **kw):
            return name

        def addHost(self, name, **kw):
            return name

        def addLink(self, *a, **kw):
            return None

    module("mininet.topo", Topo=StubTopo)


def load_topo():
    install_mininet_stubs()
    spec = importlib.util.spec_from_file_location("ovs_4host_topo_under_test", TOPO_SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = load_topo()


def fabric_bridges(n=SWITCHES):
    """(bridge, interface names) for a fabric of n switches, shaped like Mininet's."""
    return [(f"s{i}", ["lo", f"s{i}-eth1", f"s{i}-eth2", f"s{i}-eth3"])
            for i in range(1, n + 1)]


class Recorder:
    """Stands in for the command runner. Records argv; never executes anything."""

    def __init__(self, fail_on=None):
        self.calls = []
        self.fail_on = fail_on

    def __call__(self, argv):
        self.calls.append(list(argv))
        if self.fail_on is not None and self.fail_on in argv:
            raise RuntimeError(f"pretend ovs-vsctl failed on {self.fail_on}")

    def by_program(self, program):
        return [c for c in self.calls if c and c[0] == program]

    def sflow_creates(self):
        return self.by_program("ovs-vsctl")

    def ifconfigs(self):
        return self.by_program("ifconfig")


def argv_field(argv, key):
    """The value of `key=...` in an argv, or None."""
    for word in argv:
        if word.startswith(key + "="):
            return word[len(key) + 1:]
    return None


def set_bridge_name(argv):
    """The bridge named by the trailing `set bridge <name> sflow=@sflow`."""
    for i, word in enumerate(argv):
        if word == "set" and i + 2 < len(argv) and argv[i + 1] == "bridge":
            return argv[i + 2]
    return None


def model_switch_ips():
    with open(MODEL) as fh:
        topo = json.load(fh)
    out = {}
    for node in topo["nodes"]:
        if node.get("vertex_type") != 0:
            continue
        name = node.get("bridge_name") or node.get("device_name")
        ips = node.get("ip") or []
        out[name] = ips[0] if ips else None
    return out


def reference_sflow_params(path):
    """header/sampling/polling as testbed_topo.py's enable_sflow writes them."""
    with open(path) as fh:
        text = fh.read()
    m = re.search(r"header=(\d+)\s+sampling=(\d+)\s+polling=(\d+)", text)
    if not m:
        raise AssertionError(f"no sFlow parameters found in the reference topology {path}")
    return {"header": m.group(1), "sampling": m.group(2), "polling": m.group(3)}


class EveryBridgeSamples(unittest.TestCase):
    """The defect itself: ten bridges, ten sFlow records, and not one fewer."""

    def setUp(self):
        self.rec = Recorder()
        self.configured = T.configure_sflow(fabric_bridges(), run=self.rec)

    def test_every_bridge_is_configured(self):
        self.assertEqual(self.configured, [f"s{i}" for i in range(1, SWITCHES + 1)])
        named = [set_bridge_name(c) for c in self.rec.sflow_creates()]
        self.assertEqual(named, [f"s{i}" for i in range(1, SWITCHES + 1)])

    def test_no_bridge_is_configured_twice(self):
        """The loosening shape: OVS accepts a second `create sflow` and leaves the first
        record referenced by nothing, which a checker asking only 'is it non-empty' signs
        off. Two records on one bridge is not a stricter version of one."""
        named = [set_bridge_name(c) for c in self.rec.sflow_creates()]
        self.assertEqual(len(named), len(set(named)), f"a bridge configured twice: {named}")

    def test_no_bridge_outside_the_fabric(self):
        """`set bridge s11 sflow=@sflow` fails at the switch and used to be invisible: the
        reference topology runs the command through os.system and discards its status."""
        fabric = {f"s{i}" for i in range(1, SWITCHES + 1)}
        for call in self.rec.sflow_creates():
            self.assertIn(set_bridge_name(call), fabric, f"configured a bridge the topology does not build: {call}")

    def test_one_record_per_bridge(self):
        creates = [c for c in self.rec.sflow_creates() if "create" in c]
        self.assertEqual(len(creates), SWITCHES)


class AgentAddressMatchesTheKernelModel(unittest.TestCase):
    """🔴 The load-bearing agreement. Samples with the wrong agent address are parsed,
    matched against no edge, and read exactly like no samples at all."""

    def setUp(self):
        self.rec = Recorder()
        T.configure_sflow(fabric_bridges(), run=self.rec)
        self.model = model_switch_ips()

    def test_each_switch_gets_the_address_the_model_declares(self):
        assigned = {}
        for call in self.rec.ifconfigs():
            assigned[call[1].split("-")[0]] = call[2].split("/")[0]
        self.assertEqual(len(assigned), SWITCHES)
        for bridge, want in self.model.items():
            self.assertEqual(assigned.get(bridge), want,
                             f"{bridge} samples as {assigned.get(bridge)} but the kernel's model "
                             f"file says {want}; the kernel matches samples to edges by this address")

    def test_the_helper_agrees_with_the_model_on_every_switch(self):
        for bridge, want in self.model.items():
            self.assertEqual(T.sflow_agent_ip(bridge), want)

    def test_the_address_is_assigned_before_the_record_is_created(self):
        """OVS reads the agent address off the interface when the record is created. An
        interface with no IPv4 makes it fall back to the route source address -- one address
        for all ten switches."""
        for i, call in enumerate(self.rec.calls):
            if call[0] == "ovs-vsctl":
                bridge = set_bridge_name(call)
                earlier = [c for c in self.rec.calls[:i]
                           if c[0] == "ifconfig" and c[1].startswith(bridge + "-")]
                self.assertTrue(earlier, f"{bridge}: sFlow record created before its agent had an address")

    def test_the_agent_is_the_bridges_own_interface(self):
        for call in self.rec.sflow_creates():
            bridge = set_bridge_name(call)
            self.assertEqual(argv_field(call, "agent"), f"{bridge}-eth1")

    def test_a_switch_with_no_usable_interface_is_refused(self):
        """Not configured-with-a-blank-agent: that is the fallback shape above, and it looks
        like success."""
        with self.assertRaises(RuntimeError):
            T.configure_sflow([("s1", ["lo"])], run=Recorder())

    def test_a_name_the_topology_does_not_build_is_refused(self):
        with self.assertRaises(ValueError):
            T.sflow_agent_ip("br0")


class ParametersComeFromTheReferenceTopology(unittest.TestCase):
    """Not a second set of sFlow parameters. Read out of testbed_topo.py, not copied here."""

    def setUp(self):
        self.rec = Recorder()
        T.configure_sflow(fabric_bridges(), run=self.rec)
        self.call = self.rec.sflow_creates()[0]

    def test_header_sampling_polling_match_the_reference(self):
        want = reference_sflow_params(REFERENCE)
        for key, value in want.items():
            self.assertEqual(argv_field(self.call, key), value,
                             f"{key} differs from the reference topology testbed_topo.py")

    def test_the_reference_copy_ndt_actually_runs_agrees_too(self):
        """`ndt up ovs` executes NTG's copy, not the repo's. If the two ever disagree, the
        parameters this fixture matches are not the ones the other plane uses."""
        if not os.path.exists(REFERENCE_NTG):
            self.skipTest("NTG's testbed_topo.py is not on this machine")
        self.assertEqual(reference_sflow_params(REFERENCE),
                         reference_sflow_params(REFERENCE_NTG))

    def test_polling_is_off(self):
        """Stated separately because it is the one a reader is most likely to 'fix': in
        MININET mode the kernel discards every counter sample, so polling only adds
        datagrams. The reasoning is in testbed_topo.py."""
        self.assertEqual(argv_field(self.call, "polling"), "0")


class CollectorPortAgreesEverywhere(unittest.TestCase):
    """Three files declare the collector port. A change to one must not leave the others lying."""

    def setUp(self):
        self.rec = Recorder()
        T.configure_sflow(fabric_bridges(), run=self.rec)
        self.target = argv_field(self.rec.sflow_creates()[0], "target").strip('"')

    def test_the_target_is_the_kernels_collector(self):
        self.assertEqual(self.target, f"{T.SFLOW_COLLECTOR_IP}:{T.SFLOW_COLLECTOR_PORT}")

    def test_ndt_verifies_against_the_same_port(self):
        with open(NDT) as fh:
            text = fh.read()
        m = re.search(r"^SFLOW_PORT=(\d+)", text, re.M)
        self.assertIsNotNone(m, "ndt no longer declares SFLOW_PORT, so its verify checks nothing")
        self.assertEqual(int(m.group(1)), T.SFLOW_COLLECTOR_PORT)

    def test_the_ports_table_names_the_same_port(self):
        with open(PORTS_SH) as fh:
            text = fh.read()
        self.assertTrue(
            re.search(rf"^{T.SFLOW_COLLECTOR_PORT}\|udp\|", text, re.M),
            "ports.sh has no row for the collector port, so a squatter on it is invisible again")

    def test_the_target_is_a_loopback_address(self):
        """The collector binds 0.0.0.0:6343 on this host, so loopback reaches it and needs no
        address added to any interface -- unlike the reference topology, which aliases
        192.168.123.1 onto `lo` and never removes it."""
        self.assertTrue(self.target.startswith("127."), self.target)


class FailuresAreNotSwallowed(unittest.TestCase):
    """The reference topology runs these through os.system and discards the status, which is
    why `set bridge <nonexistent> sflow=@sflow` was indistinguishable from success."""

    def test_a_failing_command_propagates(self):
        rec = Recorder(fail_on="s7")
        with self.assertRaises(RuntimeError):
            T.configure_sflow(fabric_bridges(), run=rec)

    def test_the_default_runner_checks_the_exit_status(self):
        with open(TOPO_SCRIPT) as fh:
            src = ast.unparse(ast.parse(fh.read()))
        self.assertIn("check=True", src,
                      "run_checked no longer asks subprocess to raise on a non-zero status")


class WiredIntoTheBringUp(unittest.TestCase):
    """Existence is not wiring. A configure_sflow nobody calls leaves the defect exactly
    where it was, and every test above still passes."""

    def _main(self):
        with open(TOPO_SCRIPT) as fh:
            tree = ast.parse(fh.read())
        for node in tree.body:
            if isinstance(node, ast.FunctionDef) and node.name == "main":
                return node
        raise AssertionError("ovs_4host_topo.py has no main()")

    def test_main_configures_sflow(self):
        called = {n.func.id for n in ast.walk(self._main())
                  if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        self.assertIn("configure_sflow", called,
                      "main() never calls configure_sflow -- the bridges come up with sflow=[] "
                      "and the twin reports 0.0 for every rate under any load")

    def test_it_is_configured_before_the_discovery_burst(self):
        """The burst is the first traffic on the fabric; a bridge not sampling yet contributes
        nothing to it."""
        body = self._main().body
        order = []
        for i, stmt in enumerate(body):
            for n in ast.walk(stmt):
                if isinstance(n, ast.Call) and isinstance(n.func, ast.Name):
                    if n.func.id in ("configure_sflow", "disable_host_offloads"):
                        order.append((i, n.func.id))
        names = [n for _, n in order]
        self.assertIn("configure_sflow", names)
        self.assertLess(names.index("configure_sflow"), names.index("disable_host_offloads"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
