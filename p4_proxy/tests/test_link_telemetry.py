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
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
REPO = os.path.dirname(PROXY_DIR)
sys.path.insert(0, os.path.join(PROXY_DIR, "mininet"))

import app_package  # noqa: E402
import link_telemetry  # noqa: E402
import topo_from_json  # noqa: E402

FOUR_HOST_MODEL = os.path.join(REPO, "setting",
                               "StaticNetworkTopologyP4_10Switches_4Hosts.json")


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
        killed = []
        fate = link_telemetry.stop_emitter(42, kill=lambda p, s: killed.append((p, s)),
                                           is_emitter=lambda pid, **kw: True,
                                           sleep=lambda _s: None, grace_s=0.5)
        self.assertEqual(fate, "kill")
        self.assertEqual(killed, [(42, signal.SIGTERM), (42, signal.SIGKILL)])

    def test_the_process_check_reads_one_cmdline_and_never_scans(self):
        tmp = tempfile.mkdtemp(prefix="ndtwin_proc_")
        self.addCleanup(shutil.rmtree, tmp, True)
        os.makedirs(os.path.join(tmp, "77"))
        with open(os.path.join(tmp, "77", "cmdline"), "wb") as fh:
            fh.write(b"/usr/bin/python3\x00/x/psample_sflow_emitter.py\x00--manifest\x00/tmp/m\x00")
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
        run = FakeRun()
        fate, _removed, _doc = link_telemetry.shut_down(
            self.path, run=run, is_emitter=lambda pid, **kw: False)
        self.assertEqual(fate, "absent")
        self.assertFalse(os.path.exists(self.path))


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

    def test_it_names_the_emitter_beside_this_module_and_the_manifest(self):
        argv = link_telemetry.emitter_argv("/tmp/m.json", python="/usr/bin/python3")
        self.assertEqual(argv, ["/usr/bin/python3", link_telemetry.EMITTER_PATH,
                                "--manifest", "/tmp/m.json"])
        self.assertTrue(os.path.exists(link_telemetry.EMITTER_PATH),
                        "the emitter the bring-up starts is not next to this module")

    def test_the_default_manifest_is_the_one_every_other_reader_uses(self):
        self.assertEqual(link_telemetry.LINK_TELEMETRY_MANIFEST,
                         "/tmp/ndtwin_link_telemetry.json")


if __name__ == "__main__":
    unittest.main()

# [Co-developed with claude code -- Adam]
