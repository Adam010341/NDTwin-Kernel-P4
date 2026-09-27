#!/usr/bin/env python3
"""Which veth gets a sampling filter, what that filter is, and what is written down about it.

[Co-developed with claude code -- Adam]

TICKET-P3 sections 2.2 and 2.5. `link_telemetry.py` is the half of the link path that decides;
`psample_sflow_emitter.py` is the half that runs, and has its own file. Nothing here opens a
socket, runs `tc` or touches /sys: `plan()` is a pure function of the package, the model and the
switch objects, `attach()` only ever calls the `run` it is handed, and `read_ifindex` is the one
seam a unit test replaces (a machine running this suite has no `s1-eth1`, and if it does, that
one belongs to somebody else's fabric).

🔴 WHAT IS ACTUALLY ON TRIAL, because "it emits some tc commands" is not a specification:

  1. an INGRESS filter on every port and an EGRESS filter on host-facing ports ONLY. The kernel
     credits a link from the RECEIVING switch's ingress samples, so an egress filter on an
     inter-switch port double-counts that cable; the one direction with no receiving switch is
     switch->host, which is paid out of the egress bank (section 2.2);
  2. the ifindex map is keyed on the LOW SIXTEEN BITS, because that is what psample reports
     (`nla_put_u16`, measured 2026-09-17), and two interfaces that alias there are a REFUSAL --
     whichever won, every sample from the other would be booked against it;
  3. a switch in its own network namespace is a refusal, because one root emitter cannot hear
     it and the failure looks exactly like an idle fabric;
  4. teardown reads the MANIFEST rather than a plan object, so an abort path -- and the next
     bring-up -- can clean up after a process that died without one.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
REPO = os.path.dirname(PROXY_DIR)
sys.path.insert(0, os.path.join(PROXY_DIR, "mininet"))

import app_package  # noqa: E402
import link_telemetry  # noqa: E402
import topo_from_json  # noqa: E402

FOUR_HOST_MODEL = os.path.join(REPO, "setting",
                               "StaticNetworkTopologyP4_10Switches_4Hosts.json")


def load_package_fixture(name="link_telemetry_pkg", foreign_switches=()):
    """A/P1's verbatim `basic` package (pod-topo), optionally with some switches made foreign.

    Loaded out of test_app_package.py by path rather than re-typed: `CONVERTER_BASIC` there is
    `json.load()` of the bytes tools/p4_exercise/convert.py actually wrote, and its own header
    records what a hand-typed copy of it got wrong.

    pod-topo matters here for two reasons the shipped 10-switch model cannot show: its hosts
    attach on **port 1**, not port 3, and a package can put a foreign pipeline on some switches
    and not others -- which is what `auto` has to resolve per switch.
    """
    import importlib.util
    path = os.path.join(HERE, "test_app_package.py")
    spec = importlib.util.spec_from_file_location("test_app_package_fixture_source", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    manifest = json.loads(json.dumps(module.CONVERTER_BASIC))
    for key in (str(d) for d in foreign_switches):
        manifest["switches"][key]["pipeline"] = {
            "p4info": "build/firewall.p4.p4info.txtpb", "bmv2_json": "build/firewall.json"}
    directory = module.lay_out_converter_package(
        tempfile.mkdtemp(prefix="ndtwin_link_pkg_"), manifest, name,
        entry_files=[spec_["entries"] for spec_ in manifest["switches"].values()])
    for rel in ("build/firewall.p4.p4info.txtpb", "build/firewall.json"):
        full = os.path.join(directory, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as fh:
            fh.write("{}\n")
    return app_package.load(directory)


class StubIntf:
    def __init__(self, name):
        self.name = name


class StubSwitch:
    """A Mininet switch, reduced to the four things `plan()` reads off one."""

    def __init__(self, name, dpid, ports, in_namespace=False):
        self.name = name
        self.device_id = dpid
        self.intfs = {port: StubIntf(f"{name}-eth{port}") for port in ports}
        self.inNamespace = in_namespace


class FakeRun:
    """`subprocess.run`, recorded. Nothing in this file is allowed to execute `tc`."""

    class Completed:
        def __init__(self, argv, returncode=0, stderr=b""):
            self.args, self.returncode, self.stderr, self.stdout = argv, returncode, stderr, b""

    def __init__(self, returncode=0, stderr=b"", fail_on=None):
        self.calls = []
        self.returncode = returncode
        self.stderr = stderr
        self.fail_on = fail_on

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        rc = self.returncode
        if self.fail_on is not None and self.fail_on in " ".join(argv):
            rc = 2
        return self.Completed(list(argv), returncode=rc, stderr=self.stderr)

    def lines(self):
        return [" ".join(argv) for argv in self.calls]


def ifindex_of(ifname, sys_root=None):
    """`sN-ethM` -> a number, deterministically. Stands in for the /sys read."""
    switch, _, port = ifname.partition("-eth")
    return 1000 + int(switch[1:]) * 10 + int(port or 0)


class PlanFixture(unittest.TestCase):
    """The shipped 4-host model, ten switches, and a knob this suite owns."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_link_telemetry_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.knob = os.path.join(self.tmp, "telemetry_override")
        self.model = topo_from_json.load(FOUR_HOST_MODEL)
        self.package = app_package.baseline()

    def switches(self, in_namespace=False):
        ports = {}
        for a, ap, b, bp in topo_from_json.switch_links(self.model):
            ports.setdefault(a, set()).add(ap)
            ports.setdefault(b, set()).add(bp)
        for _name, dpid, port in topo_from_json.host_links(self.model):
            ports.setdefault(dpid, set()).add(port)
        return [StubSwitch(name, dpid, sorted(ports.get(dpid, ())),
                           in_namespace=in_namespace)
                for dpid, name in topo_from_json.switches(self.model)]

    def set_knob(self, word):
        with open(self.knob, "w") as fh:
            fh.write(word + "\n")

    def plan(self, switches=None, **kwargs):
        kwargs.setdefault("ifindex_of", ifindex_of)
        kwargs.setdefault("knob_path", self.knob)
        return link_telemetry.plan(self.package, self.model,
                                   switches if switches is not None else self.switches(),
                                   **kwargs)


class WhichSwitchesSampleTest(PlanFixture):

    def test_nothing_is_planned_when_no_switch_is_on_the_link_path(self):
        # No knob at all, NDTwin's own pipeline everywhere: `auto` answers `cooperative`.
        plan = self.plan()
        self.assertTrue(plan.is_empty)
        self.assertEqual(plan.commands, ())
        self.assertIn("10 cooperative", plan.reason)

    def test_the_reason_counts_every_switch_by_the_source_it_resolved_to(self):
        self.set_knob("none")
        self.assertIn("10 none", self.plan().reason)

    def test_the_knob_puts_every_switch_on_the_link_path(self):
        self.set_knob("link")
        plan = self.plan()
        self.assertEqual([s.dpid for s in plan.switches], list(range(1, 11)))

    def test_the_resolved_source_of_every_switch_is_recorded_even_the_ones_not_planned(self):
        # `ndt verify_p4` cross-checks the proxy's per-switch `telemetry.source` against this.
        self.assertEqual(dict(self.plan().sources),
                         {dpid: "cooperative" for dpid in range(1, 11)})


class WhichPortsAndWhichDirectionTest(PlanFixture):

    def setUp(self):
        super().setUp()
        self.set_knob("link")

    def test_every_port_the_model_declares_is_sampled(self):
        plan = self.plan()
        s1 = [s for s in plan.switches if s.dpid == 1][0]
        # s1 carries inter-switch ports 1 and 2 and host h1 on port 3.
        self.assertEqual([p.port for p in s1.ports], [1, 2, 3])
        self.assertEqual([p.ifname for p in s1.ports], ["s1-eth1", "s1-eth2", "s1-eth3"])

    def test_ingress_on_every_port_and_egress_on_host_facing_ports_only(self):
        plan = self.plan()
        self.assertTrue(all(p.ingress for s in plan.switches for p in s.ports))
        egress = [(s.dpid, p.port) for s in plan.switches for p in s.ports if p.egress]
        # 🔴 The model's four host links and nothing else. An egress filter on an inter-switch
        # port double-counts that cable: the kernel already credits it from the receiving
        # switch's ingress sample.
        self.assertEqual(egress, [(1, 3), (2, 3), (3, 3), (4, 3)])
        self.assertEqual(egress,
                         [(dpid, port)
                          for _name, dpid, port in topo_from_json.host_links(self.model)])

    def test_the_counts_the_bring_up_line_prints(self):
        plan = self.plan()
        self.assertEqual(plan.ingress_filters(), 36)   # 16 cables x 2 ends + 4 host ports
        self.assertEqual(plan.egress_filters(), 4)

    def test_the_agent_address_is_the_models_first_address_for_that_switch(self):
        plan = self.plan()
        self.assertEqual([s.agent_ip for s in plan.switches],
                         [f"192.168.123.{10 + d}" for d in range(1, 11)])

    def test_the_map_is_keyed_on_the_low_sixteen_bits_psample_reports(self):
        # 🔴 MEASURED 2026-09-17: the kernel writes IIFINDEX/OIFINDEX with `nla_put_u16()`.
        # A map keyed on the full ifindex works on a freshly booted machine and stops working
        # on one that has been up long enough to pass 65535.
        plan = self.plan(ifindex_of=lambda name, sys_root=None: 0x1F0000 + ifindex_of(name))
        port = plan.switches[0].ports[0]
        self.assertEqual(port.ifindex, 0x1F0000 + 1011)
        self.assertEqual(port.key, (0x1F0000 + 1011) & 0xFFFF)
        self.assertEqual(link_telemetry.IFINDEX_WIDTH_BITS, 16)


class ThePlanRefusesRatherThanGoingQuietTest(PlanFixture):

    def setUp(self):
        super().setUp()
        self.set_knob("link")

    def test_two_interfaces_that_alias_in_sixteen_bits_are_refused_by_name(self):
        def aliasing(ifname, sys_root=None):
            # s1-eth1 and s2-eth1 land on the same low sixteen bits.
            return {"s1-eth1": 0x00010001, "s2-eth1": 0x00020001}.get(
                ifname, ifindex_of(ifname))
        with self.assertRaises(link_telemetry.LinkTelemetryError) as ctx:
            self.plan(ifindex_of=aliasing)
        message = str(ctx.exception)
        self.assertIn("s1-eth1", message)
        self.assertIn("s2-eth1", message)
        self.assertIn("attributed to the other", message)

    def test_a_switch_in_its_own_namespace_is_refused(self):
        with self.assertRaises(link_telemetry.LinkTelemetryError) as ctx:
            self.plan(self.switches(in_namespace=True))
        self.assertIn("network namespace", str(ctx.exception))
        self.assertIn("one root emitter cannot hear it", str(ctx.exception))

    def test_an_interface_whose_ifindex_cannot_be_read_is_refused(self):
        def missing(ifname, sys_root=None):
            raise link_telemetry.LinkTelemetryError(f"cannot read ifindex of {ifname}")
        with self.assertRaises(link_telemetry.LinkTelemetryError):
            self.plan(ifindex_of=missing)

    def test_a_link_switch_with_no_agent_address_is_refused(self):
        model = json.loads(json.dumps(self.model))
        for node in model["nodes"]:
            if node.get("dpid") == 3 and node.get("vertex_type") == 0:
                node["ip"] = []
        with self.assertRaises(link_telemetry.LinkTelemetryError) as ctx:
            link_telemetry.plan(self.package, model, self.switches(),
                                knob_path=self.knob, ifindex_of=ifindex_of)
        self.assertIn("attributed to nothing", str(ctx.exception))

    def test_a_port_the_model_declares_but_the_switch_does_not_have_is_refused(self):
        switches = self.switches()
        del switches[0].intfs[3]
        with self.assertRaises(link_telemetry.LinkTelemetryError) as ctx:
            self.plan(switches)
        self.assertIn("port 3", str(ctx.exception))

    def test_a_refusal_is_a_value_error_so_both_mains_already_catch_it(self):
        self.assertTrue(issubclass(link_telemetry.LinkTelemetryError, ValueError))


class TheTcCommandsTest(PlanFixture):
    """The argv, word for word against the spike that was run live."""

    def setUp(self):
        super().setUp()
        self.set_knob("link")

    def test_one_switchs_commands_are_the_spikes(self):
        # 🔴 TRANSCRIBED from spike-tc-sample/spike.sh (`tc qdisc add dev X clsact`, then
        # `tc filter add dev X {ingress|egress} matchall action sample rate R group G trunc
        # 128`), which was run live on 2026-09-17 -- not read back from `_commands`.
        switches = [s for s in self.switches() if s.device_id == 1]
        plan = self.plan(switches)
        self.assertEqual([" ".join(c) for c in plan.commands], [
            "tc qdisc add dev s1-eth1 clsact",
            "tc filter add dev s1-eth1 ingress matchall action sample rate 256 group 27 trunc 128",
            "tc qdisc add dev s1-eth2 clsact",
            "tc filter add dev s1-eth2 ingress matchall action sample rate 256 group 27 trunc 128",
            "tc qdisc add dev s1-eth3 clsact",
            "tc filter add dev s1-eth3 ingress matchall action sample rate 256 group 27 trunc 128",
            "tc filter add dev s1-eth3 egress matchall action sample rate 256 group 27 trunc 128",
        ])

    def test_the_qdisc_comes_before_the_filters_on_that_interface(self):
        plan = self.plan()
        seen = set()
        for argv in plan.commands:
            device = argv[4]
            if argv[1] == "qdisc":
                seen.add(device)
            else:
                self.assertIn(device, seen,
                              f"a filter was added to {device} before its clsact qdisc")

    def test_the_rate_is_the_one_ndtwins_own_pipeline_samples_at(self):
        # Both telemetry paths at 1-in-256, which is what makes the section 2.8 arms
        # comparable: a link arm at another rate differs in two ways at once.
        self.assertEqual(link_telemetry.LINK_SAMPLE_RATE, 256)
        self.assertEqual(link_telemetry.LINK_SAMPLE_TRUNC, 128)

    def test_attach_runs_every_command_in_order(self):
        plan = self.plan()
        run = FakeRun()
        link_telemetry.attach(plan, run=run)
        self.assertEqual(run.lines(), [" ".join(c) for c in plan.commands])

    def test_a_tc_that_failed_stops_the_bring_up_rather_than_half_measuring(self):
        plan = self.plan()
        run = FakeRun(fail_on="s5-eth", stderr=b"RTNETLINK answers: No such device")
        with self.assertRaises(link_telemetry.LinkTelemetryError) as ctx:
            link_telemetry.attach(plan, run=run)
        self.assertIn("No such device", str(ctx.exception))
        self.assertIn("reports the rest as zero", str(ctx.exception))

    def test_detach_removes_the_qdisc_which_removes_its_filters(self):
        plan = self.plan()
        run = FakeRun()
        removed = link_telemetry.detach(plan, run=run)
        self.assertEqual(len(run.calls), 36)
        self.assertTrue(all(argv[:4] == ["tc", "qdisc", "del", "dev"] for argv in run.calls))
        self.assertTrue(all(argv[5] == "clsact" for argv in run.calls))
        self.assertEqual(removed, plan.interfaces())

    def test_detach_does_not_stop_at_a_device_that_has_already_gone(self):
        # `net.stop()` deletes the veths. A teardown that raised on the first missing one would
        # leave the rest of the fabric's qdiscs -- and the manifest -- behind.
        plan = self.plan()
        run = FakeRun(returncode=2)
        removed = link_telemetry.detach(plan, run=run)
        self.assertEqual(len(run.calls), 36)
        self.assertEqual(removed, [])


class TheManifestTest(PlanFixture):

    def setUp(self):
        super().setUp()
        self.set_knob("link")
        self.path = os.path.join(self.tmp, "ndtwin_link_telemetry.json")

    def test_it_holds_the_pid_the_rate_and_every_port_of_every_switch(self):
        plan = self.plan()
        link_telemetry.write_manifest(plan, 31337, path=self.path)
        with open(self.path) as fh:
            document = json.load(fh)
        self.assertEqual(document["pid"], 31337)
        self.assertEqual(document["rate"], 256)
        self.assertEqual(document["trunc"], 128)
        self.assertEqual(document["group"], 27)
        self.assertEqual(document["ifindex_width"], 16)
        self.assertEqual(document["collector"], ["127.0.0.1", 6343])
        self.assertEqual(document["sub_agent_id"], 1)
        self.assertEqual(len(document["switches"]), 10)
        self.assertEqual(document["switches"][0]["ports"]["3"],
                         {"ifname": "s1-eth3", "ifindex": 1013, "key": 1013,
                          "ingress": True, "egress": True})

    def test_it_records_the_tc_commands_so_the_file_says_what_was_installed(self):
        plan = self.plan()
        document = link_telemetry.write_manifest(plan, 1, path=self.path)
        self.assertEqual([tuple(c) for c in document["tc_commands"]], list(plan.commands))

    def test_it_is_a_fresh_inode_every_time(self):
        # /tmp is sticky: anyone can create this NAME before the fabric runs, and truncating
        # their file as root would leave them owning a document that names a pid this
        # teardown then signals.
        with open(self.path, "w") as fh:
            fh.write("{}\n")
        before = os.stat(self.path).st_ino
        link_telemetry.write_manifest(self.plan(), 1, path=self.path)
        self.assertNotEqual(os.stat(self.path).st_ino, before)

    def test_reading_a_manifest_that_is_not_there_is_not_an_error(self):
        self.assertIsNone(link_telemetry.read_manifest(
            os.path.join(self.tmp, "absent.json")))

    def test_reading_a_corrupt_manifest_is_not_an_error_either(self):
        with open(self.path, "w") as fh:
            fh.write("not json")
        self.assertIsNone(link_telemetry.read_manifest(self.path))


class TheManifestIsTrustedOnlyFromItsOwnerTest(unittest.TestCase):
    """Judge KJL B2: the file root acts on must be root's, or the reading user's, and nobody else's.

    [Co-developed with claude code -- Adam]
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_manifest_trust_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.path = os.path.join(self.tmp, "ndtwin_link_telemetry.json")

    @staticmethod
    def st(mode, uid):
        return os.stat_result((mode, 0, 0, 1, uid, 0, 0, 0, 0, 0))

    def test_only_root_or_the_reader_may_own_it_and_nobody_else_may_write_it(self):
        me, reg = os.geteuid(), 0o100000
        self.assertIsNone(link_telemetry.manifest_distrust(self.st(reg | 0o644, 0), me))
        self.assertIsNone(link_telemetry.manifest_distrust(self.st(reg | 0o600, me), me))
        refused = {
            "another uid": self.st(reg | 0o644, me + 1),
            "group-writable": self.st(reg | 0o664, 0),
            "other-writable": self.st(reg | 0o646, me),
            "a directory": self.st(0o040000 | 0o755, 0),
            "a second hard link": os.stat_result((reg | 0o644, 0, 0, 2, 0, 0, 0, 0, 0, 0)),
        }
        for label, st in refused.items():
            with self.subTest(label):
                self.assertIsNotNone(link_telemetry.manifest_distrust(st, me))

    def test_a_hard_link_to_the_manifest_is_not_the_manifest(self):
        # The file `write_manifest` makes has exactly one name. A second one is a hard link
        # somebody made -- to an inode they do not own, unless `fs.protected_hardlinks` stops
        # them -- and the check must not rest on that sysctl. [Co-developed with claude code -- Adam]
        link_telemetry.write_manifest(link_telemetry.LinkTelemetryPlan(), 4242, path=self.path)
        os.link(self.path, os.path.join(self.tmp, "second-name.json"))
        document, problem = link_telemetry.load_manifest(self.path)
        self.assertIsNone(document, "a manifest with two names was acted on")
        self.assertIn("hard links", problem)

    def test_what_write_manifest_leaves_is_trusted(self):
        link_telemetry.write_manifest(link_telemetry.LinkTelemetryPlan(), 4242, path=self.path)
        document, problem = link_telemetry.load_manifest(self.path)
        self.assertEqual((document["pid"], problem), (4242, None))
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o644)

    def test_absent_is_nothing_and_not_a_problem(self):
        self.assertEqual(link_telemetry.load_manifest(self.path), (None, None))

    def test_a_fifo_at_the_name_is_refused_and_does_not_hang_the_reader(self):
        os.mkfifo(self.path, 0o644)
        document, problem = link_telemetry.load_manifest(self.path)
        self.assertIsNone(document)
        self.assertIn("not a regular file", problem)

    def test_a_document_that_is_not_an_object_is_a_problem_not_a_manifest(self):
        with open(self.path, "w") as fh:
            fh.write("[4242]")
        os.chmod(self.path, 0o644)
        self.assertEqual(link_telemetry.load_manifest(self.path)[0], None)
        self.assertIn("not a JSON object", link_telemetry.load_manifest(self.path)[1])
        self.assertIsNone(link_telemetry.read_manifest(self.path))


class StoppingTheEmitterTest(unittest.TestCase):
    """By the pid the manifest names, after /proc says it is still that process."""

    def test_a_pid_that_is_no_longer_the_emitter_is_not_signalled(self):
        # 🔴 Linux recycles pids and this teardown runs as root. A pid recorded at bring-up is
        # not evidence that the same process holds it at teardown -- which is the reason
        # `pkill -f` is forbidden AND the reason a bare `os.kill` would be no better.
        killed = []
        fate = link_telemetry.stop_emitter(999, kill=lambda *a: killed.append(a),
                                           is_emitter=lambda pid, **kw: False)
        self.assertEqual((fate, killed), ("absent", []))

    def test_it_goes_on_the_sigterm(self):
        alive = [True]
        killed = []

        def kill(pid, sig):
            killed.append((pid, sig))
            alive[0] = False
        fate = link_telemetry.stop_emitter(42, kill=kill,
                                           is_emitter=lambda pid, **kw: alive[0],
                                           sleep=lambda _s: None)
        self.assertEqual(fate, "term")
        self.assertEqual(killed, [(42, signal.SIGTERM)])

    def test_one_that_will_not_go_is_killed_after_the_grace_period(self):
        killed, slept = [], []
        fate = link_telemetry.stop_emitter(42, kill=lambda p, s: killed.append((p, s)),
                                           is_emitter=lambda pid, **kw: True,
                                           sleep=slept.append, grace_s=0.5)
        self.assertEqual(fate, "kill")
        self.assertEqual(killed, [(42, signal.SIGTERM), (42, signal.SIGKILL)])
        # 🔴 FIVE, and it is a whole number because the loop counts steps rather than
        # subtracting 0.1 from a float five times -- which gives six, and is the pattern
        # `p4_testbed_topo.start_link_telemetry` carries a warning about beside its own loop.
        self.assertEqual(len(slept), 5)
        self.assertEqual(set(slept), {link_telemetry.EMITTER_POLL_INTERVAL_S})

    def test_every_question_it_asks_carries_the_recorded_identity(self):
        # 🔴 Adam 2026-09-27, ruling K. The grace loop asks again on every step, and a step that
        # asked without the argv and start time would be judging a different process than the
        # first question did -- the one that decided to send SIGTERM at all.
        # [Co-developed with claude code -- Adam]
        asked = []

        def is_emitter(pid, **identity):
            asked.append(identity)
            return len(asked) < 3
        link_telemetry.stop_emitter(42, kill=lambda p, s: None, is_emitter=is_emitter,
                                    sleep=lambda _s: None, argv=["a", "b"], start_time=9)
        self.assertEqual(len(asked), 3)
        self.assertEqual(asked, [{"argv": ["a", "b"], "start_time": 9}] * 3)

    def test_the_process_check_reads_one_cmdline_and_never_scans(self):
        tmp = tempfile.mkdtemp(prefix="ndtwin_proc_")
        self.addCleanup(shutil.rmtree, tmp, True)
        os.makedirs(os.path.join(tmp, "77"))
        with open(os.path.join(tmp, "77", "cmdline"), "wb") as fh:
            fh.write(b"/usr/bin/python3\x00/x/psample_sflow_emitter.py\x00--manifest\x00m.json\x00")
        os.makedirs(os.path.join(tmp, "78"))
        with open(os.path.join(tmp, "78", "cmdline"), "wb") as fh:
            fh.write(b"/usr/bin/vim\x00notes.txt\x00")
        self.assertTrue(link_telemetry.process_is_the_emitter(77, proc_root=tmp))
        self.assertFalse(link_telemetry.process_is_the_emitter(78, proc_root=tmp))
        self.assertFalse(link_telemetry.process_is_the_emitter(79, proc_root=tmp))


class ShuttingDownFromTheManifestTest(PlanFixture):
    """Section 2.5: teardown takes no plan, so an abort path has nothing extra to remember."""

    def setUp(self):
        super().setUp()
        self.set_knob("link")
        self.path = os.path.join(self.tmp, "ndtwin_link_telemetry.json")
        link_telemetry.write_manifest(self.plan(), 4242, path=self.path)

    def test_an_untrusted_manifest_detaches_nothing(self):
        # The `tc` half of what an untrusted manifest could make root do: `tc qdisc del` on
        # every interface it lists. The file here lists all 36 of this plan's interfaces, and is
        # then made untrusted two ways; neither may produce a single command.
        # [Co-developed with claude code -- Adam]
        other = os.path.join(self.tmp, "real.json")
        os.replace(self.path, other)
        for label, plant in (("group-writable", lambda: (shutil.copy(other, self.path),
                                                         os.chmod(self.path, 0o664))),
                             ("a symlink", lambda: os.symlink(other, self.path))):
            with self.subTest(label):
                plant()
                run, killed = FakeRun(), []
                fate, removed, _doc = link_telemetry.shut_down(
                    self.path, run=run, kill=lambda pid, sig: killed.append((pid, sig)),
                    is_emitter=lambda pid, **kw: False, sleep=lambda _s: None)
                self.assertEqual(run.calls, [], "an untrusted manifest had root run tc")
                self.assertEqual((removed, killed), ([], []))
                os.unlink(self.path)

    def test_it_stops_the_pid_the_manifest_names_and_detaches_every_interface(self):
        stopped, run = [], FakeRun()
        fate, removed, document = link_telemetry.shut_down(
            self.path, run=run,
            kill=lambda pid, sig: stopped.append((pid, sig)),
            is_emitter=lambda pid, **kw: not stopped, sleep=lambda _s: None)
        self.assertEqual(fate, "term")
        self.assertEqual(stopped, [(4242, signal.SIGTERM)])
        self.assertEqual(len(removed), 36)
        self.assertEqual(document["pid"], 4242)
        self.assertFalse(os.path.exists(self.path))

    def test_the_emitter_is_stopped_before_the_filters_come_off(self):
        # A filter left on while the listener is already gone is a sample nobody counts; the
        # other order leaves a listener hearing a fabric that is being dismantled.
        events = []
        link_telemetry.shut_down(
            self.path, run=lambda argv, **kw: events.append("tc") or FakeRun.Completed(argv),
            kill=lambda pid, sig: events.append("kill"),
            is_emitter=lambda pid, **kw: "kill" not in events, sleep=lambda _s: None)
        self.assertEqual(events[0], "kill")

    def test_nothing_at_all_happens_when_there_is_no_manifest(self):
        run = FakeRun()
        result = link_telemetry.shut_down(os.path.join(self.tmp, "absent.json"), run=run)
        self.assertEqual(result, (None, [], None))
        self.assertEqual(run.calls, [])

    def test_the_manifest_goes_even_when_the_emitter_was_already_gone(self):
        # 🔴 A KILL THAT ONLY RECORDS (judge K-N4). Without it, a mutant that skips the
        # predicate (M-B13) would send a REAL SIGTERM to pid 4242 -- whatever holds that number
        # on the machine running the gate. [Co-developed with claude code -- Adam]
        run, killed = FakeRun(), []
        fate, _removed, _doc = link_telemetry.shut_down(
            self.path, run=run, is_emitter=lambda pid, **kw: False,
            kill=lambda pid, sig: killed.append((pid, sig)), sleep=lambda _s: None)
        self.assertEqual((fate, killed), ("absent", []))
        self.assertFalse(os.path.exists(self.path))


# --- which process the manifest's pid is, now (Adam 2026-09-27, ruling K) -------------------
#
# [Co-developed with claude code -- Adam]
# 🔴 THE TEARDOWN THAT READS THIS RUNS AS ROOT AND SENDS SIGTERM, THEN SIGKILL. Until this ruling
# "is pid N the emitter" was answered by `b"psample_sflow_emitter.py" in <the whole cmdline>` --
# so an editor with that file open, a `grep` or `tail` naming it, or a test runner with it on
# its command line, holding a recycled pid, was the emitter as far as `stop_emitter` knew. The
# cases below are REAL processes, started unprivileged by this file and reaped by this file
# through their own Popen (never by pattern): a check against a fake /proc can agree with
# itself about a cmdline no kernel would write, and these ones cannot. Nothing here is
# signalled for real except, in the one positive case, this file's own child, by its own pid,
# through a kill that refuses any other number.


def observed_start_time(pid):
    """Field 22 of /proc/<pid>/stat, read HERE rather than by the module under test.

    The oracle the identity cases compare against, so that a wrong parse in `link_telemetry`
    cannot agree with itself. `comm` (field 2) is parenthesised and may itself contain spaces
    and parentheses, which is why the split starts after the LAST ')'.
    """
    with open(f"/proc/{int(pid)}/stat", "rb") as fh:
        raw = fh.read()
    return int(raw[raw.rindex(b")") + 1:].split()[19])


def observed_cmdline(pid):
    with open(f"/proc/{int(pid)}/cmdline", "rb") as fh:
        raw = fh.read()
    return [os.fsdecode(part) for part in raw.split(b"\0")[:-1]]


def wait_until_exec_has_finished(proc, timeout_s=10.0):
    """Block until the kernel has published `proc`'s new argv, and return it.

    🔴 POPEN CAN RETURN BEFORE /proc/<pid>/cmdline SAYS ANYTHING. It returns when the exec
    closes its close-on-exec error pipe (and, under vfork, when the exec releases the parent),
    and both happen in `begin_new_exec` -- BEFORE the ELF loader sets the new mm's arg_start
    and arg_end. A read in that window gets an EMPTY cmdline: this file's first gate run saw it
    as a flaky red in 2 of 4 decoy cases. Nothing in production reads the cmdline that soon (the
    bring-up waits out a three-second grace on `poll()` first, and the start time is fixed at
    fork, not at exec), so the wait belongs here and not in the module.
    """
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        argv = observed_cmdline(proc.pid)
        if argv:
            return argv
        if proc.poll() is not None:
            raise AssertionError(f"pid {proc.pid} exited ({proc.returncode}) before exec was seen")
        time.sleep(0.005)
    raise AssertionError(f"pid {proc.pid} published no cmdline within {timeout_s}s")


class LiveProcessFixture(unittest.TestCase):
    """A stand-in emitter file, a manifest path, and children that are always reaped."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_emitter_identity_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.manifest = os.path.join(self.tmp, "ndtwin_link_telemetry.json")
        # A file with the emitter's own name that only sleeps -- somewhere other than beside
        # link_telemetry.py, which is the point of two of the cases below.
        stub_dir = os.path.join(self.tmp, "elsewhere")
        os.makedirs(stub_dir)
        self.stub = os.path.join(stub_dir, os.path.basename(link_telemetry.EMITTER_PATH))
        with open(self.stub, "w") as fh:
            fh.write("import time\ntime.sleep(120)\n")

    def spawn(self, argv):
        """Start `argv` unprivileged; reaped by its own Popen whatever the case does."""
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, env=env)
        self.addCleanup(self.reap, proc)
        self.assertEqual(wait_until_exec_has_finished(proc), list(argv))
        return proc

    @staticmethod
    def reap(proc):
        if proc.poll() is None:
            proc.kill()                  # Popen.kill: os.kill(proc.pid, SIGKILL), our own child
        proc.wait(timeout=30)

    def write_document(self, path=None, mode=0o644, **fields):
        """A manifest written by hand, so a case can name what a bring-up would have recorded.

        0644 by default, as `write_manifest` leaves it: this user's umask is 0002, and a
        group-writable manifest is refused before any identity is looked at (judge KJL B2) --
        a case about the identity check must not pass because of the mode.
        """
        path = path or self.manifest
        document = link_telemetry.manifest_document(link_telemetry.LinkTelemetryPlan(), None)
        document.update(fields)
        with open(path, "w") as fh:
            json.dump(document, fh)
        os.chmod(path, mode)
        return path

    def tear_down_recording(self):
        """`shut_down` with a kill that only RECORDS. Returns (fate, [(pid, signal), ...])."""
        kills, self.said = [], []
        fate, _removed, _doc = link_telemetry.shut_down(
            self.manifest, run=FakeRun(), kill=lambda pid, sig: kills.append((pid, sig)),
            sleep=lambda _s: None, report=self.said.append)
        return fate, kills

    def identity_of(self, proc):
        """What /proc says about `proc` now -- read by THIS file, not by the module under test."""
        return {"argv": observed_cmdline(proc.pid), "start_time": observed_start_time(proc.pid)}

    def launcher_shaped(self):
        """A live child in exactly the launcher's four-word shape, running the stand-in."""
        return self.spawn(link_telemetry.emitter_argv(self.manifest, python=sys.executable,
                                                      emitter=self.stub))


class ADecoyIsNeverTheEmitterTest(LiveProcessFixture):
    """Red at b005bf50, where a substring of the cmdline decided; green once identity is exact."""

    def decoy(self):
        # Its command line CONTAINS the emitter's full path -- as a plain argument python never
        # opens -- and it is not the emitter by any definition.
        proc = self.spawn([sys.executable, "-c", "import time; time.sleep(120)",
                           link_telemetry.EMITTER_PATH])
        self.assertIn(link_telemetry.EMITTER_PATH, observed_cmdline(proc.pid),
                      "the decoy does not carry the emitter's name, so it proves nothing")
        return proc

    def test_a_process_that_only_mentions_the_emitter_is_not_the_emitter(self):
        decoy = self.decoy()
        self.assertFalse(link_telemetry.process_is_the_emitter(decoy.pid),
                         "a process whose argv merely mentions psample_sflow_emitter.py was "
                         "taken for the emitter")

    def test_teardown_does_not_signal_a_decoy_the_manifest_names(self):
        # A manifest with only a pid in it -- what every bring-up before this ruling wrote --
        # whose pid a decoy now holds.
        decoy = self.decoy()
        link_telemetry.write_manifest(link_telemetry.LinkTelemetryPlan(), decoy.pid,
                                      path=self.manifest)
        fate, kills = self.tear_down_recording()
        self.assertEqual(kills, [], "the root teardown would have signalled the decoy")
        self.assertEqual(fate, "absent")
        self.assertIsNone(decoy.poll())

    def test_a_pid_now_held_by_a_process_that_started_later_is_not_signalled(self):
        # 🔴 PID REUSE ITSELF. The process holding the recorded pid has EXACTLY the emitter's
        # argv -- the launcher's own shape -- but it is not the process the bring-up recorded:
        # that one started at a different instant. Only the start time can tell them apart.
        argv = link_telemetry.emitter_argv(self.manifest, python=sys.executable,
                                           emitter=self.stub)
        holder = self.spawn(argv)
        self.write_document(pid=holder.pid, argv=argv,
                            start_time=observed_start_time(holder.pid) - 1)
        fate, kills = self.tear_down_recording()
        self.assertEqual(kills, [], "a process that started after the recorded emitter was "
                                    "signalled because its pid and argv matched")
        self.assertEqual(fate, "absent")

    def test_the_same_file_name_at_another_path_is_not_the_recorded_emitter(self):
        # The recorded argv names the emitter beside link_telemetry.py; the process holding the
        # pid runs a file of the same NAME from somewhere else. Same pid, same start time --
        # only the argv differs, so only an exact argv comparison can refuse it.
        holder = self.spawn(link_telemetry.emitter_argv(self.manifest, python=sys.executable,
                                                        emitter=self.stub))
        recorded = link_telemetry.emitter_argv(self.manifest, python=sys.executable)
        self.assertNotEqual(recorded, observed_cmdline(holder.pid))
        self.write_document(pid=holder.pid, argv=recorded,
                            start_time=observed_start_time(holder.pid))
        fate, kills = self.tear_down_recording()
        self.assertEqual(kills, [])
        self.assertEqual(fate, "absent")


class TheEmitterItselfIsStillTheEmitterTest(LiveProcessFixture):
    """The positive half: what `start_emitter` launches, and what `shut_down` then stops."""

    def launch(self):
        proc = link_telemetry.start_emitter(self.manifest, python=sys.executable,
                                            emitter=self.stub, stderr=subprocess.DEVNULL)
        self.addCleanup(self.reap, proc)
        wait_until_exec_has_finished(proc)
        return proc

    def test_the_launch_records_the_argv_it_ran_and_the_start_time_proc_gives_it(self):
        proc = self.launch()
        identity = link_telemetry.emitter_identity(proc)
        self.assertEqual(identity, {
            "argv": link_telemetry.emitter_argv(self.manifest, python=sys.executable,
                                                emitter=self.stub),
            "start_time": observed_start_time(proc.pid)})
        self.assertEqual(identity["argv"], observed_cmdline(proc.pid))
        self.assertTrue(link_telemetry.process_is_the_emitter(proc.pid, **identity))

    def test_teardown_stops_the_emitter_the_manifest_recorded(self):
        proc = self.launch()
        link_telemetry.write_manifest(link_telemetry.LinkTelemetryPlan(), proc.pid,
                                      path=self.manifest,
                                      identity=link_telemetry.emitter_identity(proc))
        sent = []

        def kill(pid, sig):
            # 🔴 THIS FILE'S OWN CHILD, BY ITS OWN PID, AND NOTHING ELSE.
            self.assertEqual(pid, proc.pid)
            sent.append(sig)
            os.kill(pid, sig)
        fate, _removed, _doc = link_telemetry.shut_down(self.manifest, run=FakeRun(),
                                                        kill=kill, sleep=time.sleep)
        self.assertEqual(sent, [signal.SIGTERM])
        self.assertEqual(fate, "term")
        self.assertEqual(proc.wait(timeout=30), -signal.SIGTERM)

    def test_a_manifest_that_records_no_identity_still_stops_an_emitter_of_the_launchers_shape(self):
        # A manifest written before this ruling carries a pid and nothing else. Its emitter was
        # launched as `<python> <.../psample_sflow_emitter.py> --manifest <path>`, and that
        # exact shape -- four words, the flag in third place -- is still recognised, so a
        # fabric brought up by the old code is not orphaned by the new teardown.
        proc = self.launch()
        self.write_document(pid=proc.pid)
        fate, kills = self.tear_down_recording()
        # An assertion, not an IndexError, when nothing was signalled (judge K-N3): the mutant
        # that orphans this emitter (M-B37) must die for the reason this cell is about.
        self.assertTrue(kills, "a pre-ruling manifest's emitter was left running")
        self.assertEqual(kills[0], (proc.pid, signal.SIGTERM))
        self.assertEqual(fate, "kill")      # the recording kill never really stopped it

    def test_a_launch_whose_start_time_cannot_be_read_records_no_identity_at_all(self):
        # Both or neither (judge K-N7): half an identity is refused outright, so recording one
        # would orphan the emitter just launched. Neither falls back to the launcher's shape.
        # [Co-developed with claude code -- Adam]
        proc = self.launch()
        empty = tempfile.mkdtemp(prefix="ndtwin_proc_empty_")
        self.addCleanup(shutil.rmtree, empty, True)
        self.assertEqual(link_telemetry.emitter_identity(proc, proc_root=empty),
                         {"argv": None, "start_time": None})


class AForgedManifestKillsNothingTest(LiveProcessFixture):
    """Judge KJL B2, red at 4a96f894: what a manifest someone else wrote could make root signal.

    [Co-developed with claude code -- Adam]
    /tmp/ndtwin_link_telemetry.json is a name any local user can create while no fabric is up,
    and /proc has no hidepid here, so anybody can read any process's argv and stat. At 4a96f894
    a recorded argv REPLACED the launcher-shape check, and `read_manifest` looked at neither the
    owner nor the mode of what it read: a hand-written manifest naming any process by its full
    identity was signalled by the next root bring-up. Every kill here only RECORDS; every
    process is this file's own child, reaped by its own Popen.
    """

    def test_a_forged_manifest_holding_a_live_non_emitters_full_identity_sends_no_signal(self):
        victim = self.spawn([sys.executable, "-c", "import time; time.sleep(120)"])
        self.write_document(pid=victim.pid, **self.identity_of(victim))
        fate, kills = self.tear_down_recording()
        self.assertEqual(kills, [], "a manifest copying a non-emitter's argv and start time out "
                                    "of /proc had root signal it")
        self.assertEqual(fate, "absent")
        self.assertIsNone(victim.poll())

    def refused(self, fate, kills, reason):
        self.assertEqual(kills, [], "an untrusted manifest was acted on")
        self.assertEqual(fate, "refused")
        self.assertTrue(any(reason in line and "nothing was signalled" in line
                            for line in self.said),
                        f"the refusal was not said, or not why: {self.said}")
        self.assertTrue(os.path.lexists(self.manifest), "an untrusted file was removed")

    def test_a_group_or_other_writable_manifest_is_refused(self):
        # The identity is the launcher-shaped child's own and correct -- a trusted manifest
        # would have it signalled -- so only the mode can be what refuses it.
        holder = self.launcher_shaped()
        for mode in (0o664, 0o646):
            with self.subTest(mode=oct(mode)):
                self.write_document(pid=holder.pid, mode=mode, **self.identity_of(holder))
                fate, kills = self.tear_down_recording()
                self.refused(fate, kills, "writable by its group or by others")

    def test_a_manifest_owned_by_another_uid_is_refused(self):
        # No root here to chown with, so the OWNER is put in front of the check through its
        # one seam, `_fstat` -- the descriptor's stat, with only st_uid changed.
        holder = self.launcher_shaped()
        self.write_document(pid=holder.pid, **self.identity_of(holder))
        other = os.geteuid() + 1

        def fstat(fd):
            st = os.fstat(fd)
            return os.stat_result((st.st_mode, st.st_ino, st.st_dev, st.st_nlink, other,
                                   st.st_gid, st.st_size, st.st_atime, st.st_mtime, st.st_ctime))
        with mock.patch.object(link_telemetry, "_fstat", fstat, create=True):
            fate, kills = self.tear_down_recording()
        self.refused(fate, kills, f"owned by uid {other}")

    def test_a_symlinked_manifest_is_refused(self):
        holder = self.launcher_shaped()
        target = self.write_document(path=os.path.join(self.tmp, "elsewhere.json"),
                                     pid=holder.pid, **self.identity_of(holder))
        os.symlink(target, self.manifest)
        fate, kills = self.tear_down_recording()
        self.refused(fate, kills, "symbolic link")

    def test_pid_true_is_never_signalled_even_when_the_predicate_says_yes(self):
        # `int(True)` is 1. The predicate is injectable, so the pid is checked before it.
        kills = []
        fate = link_telemetry.stop_emitter(True, kill=lambda p, s: kills.append((p, s)),
                                           is_emitter=lambda pid, **kw: True,
                                           sleep=lambda _s: None)
        self.assertEqual((fate, kills), ("absent", []))

    def test_a_manifest_whose_pid_is_true_sends_no_signal(self):
        # `"pid": true` with init's own argv and start time -- which anyone can read.
        with open("/proc/1/cmdline", "rb") as fh:
            argv = [os.fsdecode(w) for w in fh.read().split(b"\0")[:-1]]
        self.write_document(pid=True, argv=argv, start_time=observed_start_time(1))
        fate, kills = self.tear_down_recording()
        self.assertEqual((fate, kills), ("absent", []))


class TheIdentityCheckTest(unittest.TestCase):
    """The check itself, against a /proc written here: exact argv, start time, and refusals."""

    ARGV = ["/usr/bin/python3", "/opt/ndtwin/p4_proxy/mininet/psample_sflow_emitter.py",
            "--manifest", "/tmp/ndtwin_link_telemetry.json"]

    def setUp(self):
        self.proc = tempfile.mkdtemp(prefix="ndtwin_proc_identity_")
        self.addCleanup(shutil.rmtree, self.proc, True)

    def process(self, pid, argv, start_time=7777, comm="python3"):
        d = os.path.join(self.proc, str(pid))
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "cmdline"), "wb") as fh:
            fh.write(b"".join(os.fsencode(a) + b"\0" for a in argv))
        # Fields 3..21 are placeholders; 22 is the start time.
        rest = ["S"] + ["0"] * 18 + [str(start_time)] + ["0"] * 30
        with open(os.path.join(d, "stat"), "w") as fh:
            fh.write(f"{pid} ({comm}) " + " ".join(rest) + "\n")

    def is_emitter(self, pid, **identity):
        return link_telemetry.process_is_the_emitter(pid, proc_root=self.proc, **identity)

    def test_the_start_time_is_field_twenty_two_even_after_a_comm_with_parentheses(self):
        self.process(5, self.ARGV, start_time=424242, comm="a) b (c")
        self.assertEqual(link_telemetry.process_start_time(5, proc_root=self.proc), 424242)
        self.assertIsNone(link_telemetry.process_start_time(6, proc_root=self.proc))

    def test_the_recorded_argv_must_match_word_for_word(self):
        self.process(5, self.ARGV)
        self.assertTrue(self.is_emitter(5, argv=list(self.ARGV), start_time=7777))
        for i in range(len(self.ARGV)):
            other = list(self.ARGV)
            other[i] += "x"
            with self.subTest(word=i):
                self.assertFalse(self.is_emitter(5, argv=other, start_time=7777))
        self.assertFalse(self.is_emitter(5, argv=self.ARGV + ["--extra"], start_time=7777))
        self.assertFalse(self.is_emitter(5, argv=self.ARGV[:-1], start_time=7777))

    def test_the_recorded_start_time_must_match(self):
        self.process(5, self.ARGV, start_time=7777)
        self.assertTrue(self.is_emitter(5, argv=list(self.ARGV), start_time=7777))
        self.assertFalse(self.is_emitter(5, argv=list(self.ARGV), start_time=7778))

    def test_an_identity_that_is_not_the_right_shape_is_never_a_match(self):
        # Fail closed: the manifest is JSON on a sticky /tmp, and a field of the wrong type is
        # a document nobody here wrote -- not a reason to fall back to something looser.
        self.process(5, self.ARGV, start_time=7777)
        self.assertFalse(self.is_emitter(5, argv=" ".join(self.ARGV), start_time=7777))
        self.assertFalse(self.is_emitter(5, argv=[1, 2, 3, 4], start_time=7777))
        self.assertFalse(self.is_emitter(5, argv=list(self.ARGV), start_time=True))
        self.assertFalse(self.is_emitter(5, argv=list(self.ARGV), start_time="7777"))

    def test_a_bool_start_time_is_not_the_number_it_equals(self):
        # 🔴 `True == 1` in Python (judge K-N2): a manifest saying `"start_time": true` must not
        # match a process whose start time really is 1. [Co-developed with claude code -- Adam]
        self.process(5, self.ARGV, start_time=1)
        self.assertTrue(self.is_emitter(5, argv=list(self.ARGV), start_time=1))
        self.assertFalse(self.is_emitter(5, argv=list(self.ARGV), start_time=True))

    def test_a_string_argv_is_not_the_list_of_its_characters(self):
        # `list("ab") == ["a", "b"]` (judge K-N2). Under the always-required launcher shape a
        # one-character-per-word cmdline can never pass, so this cell holds the refusal without
        # being able to tell the type check from the shape check -- see the gate's note.
        self.process(5, ["a", "b"])
        self.assertFalse(self.is_emitter(5, argv="ab", start_time=7777))
        self.process(6, self.ARGV, start_time=7777)
        self.assertFalse(self.is_emitter(6, argv="".join(self.ARGV), start_time=7777))

    def test_half_an_identity_is_never_a_match(self):
        # Judge K-N7: the launcher records both or neither, so either half alone is a document
        # nobody here wrote -- refused, not checked against the half that is there.
        self.process(5, self.ARGV, start_time=7777)
        self.assertTrue(self.is_emitter(5))
        self.assertTrue(self.is_emitter(5, argv=list(self.ARGV), start_time=7777))
        self.assertFalse(self.is_emitter(5, argv=list(self.ARGV)))
        self.assertFalse(self.is_emitter(5, start_time=7777))

    def test_init_a_bool_and_a_process_group_are_never_the_emitter(self):
        # A fake /proc/1 in the launcher's exact shape: only the pid check can refuse it.
        for pid in ("1", "0"):
            self.process(pid, self.ARGV, start_time=7777)
        for pid in (1, True, 0, -1, False, None, "5", 5.0):
            with self.subTest(pid=pid):
                self.assertFalse(self.is_emitter(pid))
                self.assertFalse(self.is_emitter(pid, argv=list(self.ARGV), start_time=7777))

    def test_a_process_with_no_command_line_is_not_the_emitter(self):
        # A zombie -- which is what a SIGTERMed emitter is until its parent reaps it -- has an
        # empty cmdline. That is "gone", and it is what makes stop_emitter's loop end in "term".
        self.process(5, [])
        self.assertFalse(self.is_emitter(5))
        self.assertFalse(self.is_emitter(5, argv=[], start_time=7777))
        self.assertFalse(self.is_emitter(9))

    def test_without_a_recorded_identity_only_the_launchers_exact_shape_is_recognised(self):
        self.process(5, self.ARGV)
        self.assertTrue(self.is_emitter(5))
        refused = {
            "a fifth word": self.ARGV + ["x"],
            "three words": self.ARGV[:3],
            "not python": ["/usr/bin/vim"] + self.ARGV[1:],
            "not the flag": self.ARGV[:2] + ["--manifesto", self.ARGV[3]],
            "another file": [self.ARGV[0], "/x/psample_sflow_emitter.py.bak"] + self.ARGV[2:],
            "the name as a substring": [self.ARGV[0], "-c", "psample_sflow_emitter.py",
                                        self.ARGV[3]],
            "the name inside one word": ["/usr/bin/grep", "psample_sflow_emitter.py --manifest",
                                         "--manifest", "/tmp/x"],
        }
        for label, argv in refused.items():
            self.process(6, argv)
            with self.subTest(label):
                self.assertFalse(self.is_emitter(6))

    def test_the_document_reader_passes_the_recorded_identity(self):
        # `emitter_is_running` is what `ndt` and the proxy read the manifest through, so neither
        # can quietly compare less than the teardown does. The process IS in the launcher's
        # shape -- so the shape alone would say yes -- and only the recorded start time can
        # tell the right document from the wrong one (judge KJL B2 reworked this cell: it used
        # to rest on "not the shape, but the identity", which is exactly what B2 forbids).
        self.running = lambda doc: link_telemetry.emitter_is_running(doc, proc_root=self.proc)
        self.process(5, self.ARGV, start_time=11)
        document = {"pid": 5, "argv": list(self.ARGV), "start_time": 11}
        self.assertTrue(self.running(document))
        self.assertFalse(self.running(dict(document, start_time=12)))
        self.assertFalse(self.running(dict(document, argv=self.ARGV[:3] + ["/tmp/other.json"])))
        self.assertTrue(self.running({"pid": 5}))           # pre-ruling: the shape alone
        self.assertFalse(self.running("not a document"))
        for pid in (None, 0, 1, -1, True, "5", 5.0):
            with self.subTest(pid=pid):
                self.assertFalse(self.running(dict(document, pid=pid)))


# --- a package's own fabric, which is neither ten switches nor all of one source --------------


class PackageFixture(unittest.TestCase):
    """pod-topo: four switches, four hosts, and hosts on port 1."""

    foreign = ()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_link_pkg_case_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.knob = os.path.join(self.tmp, "telemetry_override")
        self.package = load_package_fixture(name=f"pkg_{id(self)}",
                                            foreign_switches=self.foreign)
        self.model = topo_from_json.load(self.package.topology)

    def set_knob(self, word):
        with open(self.knob, "w") as fh:
            fh.write(word + "\n")

    def switches(self):
        ports = {}
        for a, ap, b, bp in topo_from_json.switch_links(self.model):
            ports.setdefault(a, set()).add(ap)
            ports.setdefault(b, set()).add(bp)
        for _name, dpid, port in topo_from_json.host_links(self.model):
            ports.setdefault(dpid, set()).add(port)
        return [StubSwitch(name, dpid, sorted(ports.get(dpid, ())))
                for dpid, name in topo_from_json.switches(self.model)]

    def plan(self, **kwargs):
        kwargs.setdefault("ifindex_of", ifindex_of)
        kwargs.setdefault("knob_path", self.knob)
        return link_telemetry.plan(self.package, self.model, self.switches(), **kwargs)


class APackagesOwnFabricTest(PackageFixture):
    """Every link test above uses the shipped model, whose hosts are all on port 3."""

    def test_the_hosts_of_this_model_are_on_port_one(self):
        # The premise of the next cell, asserted rather than assumed: a host-facing port is
        # whatever the model says, and hard-coding 3 would pass every test in this file that
        # uses the shipped 10-switch model.
        self.assertEqual(topo_from_json.host_links(self.model),
                         [("h1", 1, 1), ("h2", 1, 2), ("h3", 2, 1), ("h4", 2, 2)])

    def test_the_egress_filters_follow_the_model_and_not_the_number_three(self):
        self.set_knob("link")
        plan = self.plan()
        egress = [(s.dpid, p.port) for s in plan.switches for p in s.ports if p.egress]
        self.assertEqual(egress, [(1, 1), (1, 2), (2, 1), (2, 2)])
        # s3 and s4 carry no host at all: ingress only, on both of their ports.
        s3 = [s for s in plan.switches if s.dpid == 3][0]
        self.assertEqual([(p.port, p.ingress, p.egress) for p in s3.ports],
                         [(1, True, False), (2, True, False)])

    def test_the_counts_for_this_fabric(self):
        self.set_knob("link")
        plan = self.plan()
        # Four hosts + eight switch-side ends of the four inter-switch cables.
        self.assertEqual(plan.ingress_filters(), 12)
        self.assertEqual(plan.egress_filters(), 4)

    def test_the_agent_addresses_are_the_packages_model_not_the_shipped_ones(self):
        self.set_knob("link")
        self.assertEqual([s.agent_ip for s in self.plan().switches],
                         [f"192.168.123.{10 + d}" for d in range(1, 5)])


class AMixedFabricUnderAutoTest(PackageFixture):
    """🔴 `auto` is resolved PER SWITCH, and every other plan test is all-or-nothing.

    `exercises/firewall` is this shape: its own program on s1, NDTwin's on s2-s4. Cooperative
    telemetry needs the `packet_in` header and the clone session only NDTwin's pipeline has, so
    on s1 it would produce nothing at all -- not an error, an empty twin. A plan that answered
    "all ten" or "none" would satisfy every other cell in this file.
    """

    foreign = (1,)

    def test_only_the_foreign_switch_is_on_the_link_path(self):
        plan = self.plan()          # no knob: the `auto` rule decides
        self.assertEqual([s.dpid for s in plan.switches], [1])

    def test_the_sources_record_one_link_and_three_cooperative(self):
        self.assertEqual(dict(self.plan().sources),
                         {1: "link", 2: "cooperative", 3: "cooperative", 4: "cooperative"})

    def test_the_filters_are_only_on_that_switchs_ports(self):
        plan = self.plan()
        devices = sorted({argv[4] for argv in plan.commands})
        self.assertEqual(devices, ["s1-eth1", "s1-eth2", "s1-eth3", "s1-eth4"])
        self.assertEqual(plan.ingress_filters(), 4)
        # s1 carries h1 on port 1 and h2 on port 2; ports 3 and 4 go to s3 and s4.
        self.assertEqual(plan.egress_filters(), 2)

    def test_the_manifest_holds_only_the_switch_that_samples(self):
        document = link_telemetry.manifest_document(self.plan(), 99)
        self.assertEqual([s["dpid"] for s in document["switches"]], [1])

    def test_the_knob_overrides_the_rule_for_every_switch(self):
        # The mixed answer is the RULE's, not a property of the fabric: `--telemetry link`
        # still puts all four on the link path.
        self.set_knob("link")
        self.assertEqual([s.dpid for s in self.plan().switches], [1, 2, 3, 4])

    def test_none_takes_even_the_foreign_switch_off(self):
        self.set_knob("none")
        plan = self.plan()
        self.assertTrue(plan.is_empty)
        self.assertIn("4 none", plan.reason)


class TheBringUpLineTest(PlanFixture):

    def test_an_empty_plan_says_off_and_why(self):
        self.assertEqual(link_telemetry.describe(self.plan()),
                         "link telemetry: off (no switch is on the link path (10 cooperative))")

    def test_a_live_plan_counts_switches_filters_and_names_the_pid(self):
        self.set_knob("link")
        self.assertEqual(link_telemetry.describe(self.plan(), 4242),
                         "link telemetry: 10 switch(es), 36 ingress + 4 egress filters, "
                         "emitter pid 4242")


class TheEmitterCommandLineTest(unittest.TestCase):

    def test_it_is_launched_onto_its_own_file_and_this_process_keeps_no_descriptor(self):
        # 🔴 The invariant `topo_log.Tee.stop()` states in its own comment: this process owns
        # every write end of the tee's pipe, because Mininet's node shells get their own pipes
        # and bmv2 is launched onto /tmp/sN_bmv2.log. An emitter inheriting fd 2 would be a
        # fourth owner -- the pump never sees EOF, `stop()` burns its whole join, and the
        # statistics line lands on the NTG prompt every ten seconds.
        opened = []
        started = {}

        class Handle:
            closed = False

            def close(self):
                Handle.closed = True

        def opener(path, mode):
            opened.append((path, mode))
            return Handle()

        def popen(argv, **kwargs):
            started.update(kwargs)
            return "process"
        result = link_telemetry.start_emitter("<manifest path>", popen=popen, opener=opener,
                                              log_path="<emitter log path>")
        self.assertEqual(result, "process")
        self.assertEqual(opened, [("<emitter log path>", "wb")])
        self.assertIs(started["stdout"], started["stderr"])
        self.assertTrue(Handle.closed, "the parent kept a descriptor on the emitter's log")

    def test_the_default_log_sits_beside_the_switches_own(self):
        self.assertEqual(link_telemetry.LINK_TELEMETRY_LOG, "/tmp/ndtwin_link_telemetry.log")

    def test_it_names_the_emitter_beside_this_module_and_the_manifest(self):
        argv = link_telemetry.emitter_argv("<manifest path>", python="/usr/bin/python3")
        self.assertEqual(argv, ["/usr/bin/python3", link_telemetry.EMITTER_PATH,
                                "--manifest", "<manifest path>"])
        self.assertTrue(os.path.exists(link_telemetry.EMITTER_PATH),
                        "the emitter the bring-up starts is not next to this module")

    def test_the_default_manifest_is_the_one_every_other_reader_uses(self):
        self.assertEqual(link_telemetry.LINK_TELEMETRY_MANIFEST,
                         "/tmp/ndtwin_link_telemetry.json")


if __name__ == "__main__":
    unittest.main()

# [Co-developed with claude code -- Adam]
