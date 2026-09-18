"""
Tests for the proxy's startup sequence.

[Co-developed with claude code -- Adam]

What is under test is not that startup runs, but *which switches it claims*. The one call that
matters is `inform_switch_entered`: it is the only thing that sets `isEnabled` on a kernel vertex,
and `isEnabled` gates BFS pathing, flow-table polling and link-usage attribution. Claim a switch the
control plane cannot actually drive and the twin reports paths and rates for a switch that forwards
nothing; fail to claim one that works and every flow crossing it has an empty path and a zero rate.
Neither shows up as an error anywhere.

The expected behaviour here is taken from Phase 6 of doc/2026-07-27_p4_bmv2_support_plan.md and from the
guiding constraint that the proxy must never report a silent success -- not from reading
main.startup and writing down what it does.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import proxy_agent.main as main  # noqa: E402
from proxy_agent.main import startup  # noqa: E402
from proxy_agent.sflow_emitter import PacketInIds  # noqa: E402

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mininet"))
import app_package  # noqa: E402

# [Co-developed with claude code -- Adam]
# 🔴 EVERY PACKAGE IN THIS FILE IS A HAND-BUILT `Package` OBJECT, and the artefact paths its
# switches name are files that do not exist. That is the right shape for asserting a branch and
# it cannot see whether the writer survives a real foreign p4info -- which is a different
# question, asked in tests/test_foreign_pipeline.py against ticket A's compiled fixtures. The
# two are separate files on purpose: this one must stay runnable from a tree that holds only
# `p4_proxy/`, because tests/shell/mutate_app_package.sh runs it inside exactly such a tree.


#: The two REAL compiled p4infos this file uses to decide whether a foreign program can carry
#: the cooperative header. Absolute, because `Package.pipeline_for` passes an absolute
#: per-switch pipeline through untouched, and these live outside the p4_proxy root.
#: [Co-developed with claude code -- Adam]
_FIXTURES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "tools", "p4_exercise", "tests", "fixtures")
#: tutorials `basic`: zero `controller_packet_metadata`. `auto` answers `link` for it, and
#: `cooperative` is refused.
PLAIN_FOREIGN_PIPELINE = (os.path.join(_FIXTURES, "basic", "build", "basic.p4.p4info.txtpb"),
                          os.path.join(_FIXTURES, "basic", "build", "basic.json"))
#: the same program with `#include "ndtwin_telemetry.p4"` -- TICKET-P3 section 9 ruling 4's
#: whole subject. Foreign pipeline, five packet_in fields, so `cooperative` works.
TELEMETRY_FOREIGN_PIPELINE = (
    os.path.join(_FIXTURES, "basic_telemetry", "build", "basic_telemetry.p4.p4info.txtpb"),
    os.path.join(_FIXTURES, "basic_telemetry", "build", "basic_telemetry.json"))

#: What `packet_in_metadata_ids` returns for ndtwin_switch.p4's p4info. Built with the
#: production class rather than a stand-in dict so a double cannot outlive a change to it.
#: [Co-developed with claude code -- Adam]
NDTWIN_PACKET_IN_IDS = PacketInIds(reason=1, ingress_port=2, egress_port=3, frame_length=4,
                                   sampling_rate=5)


class FakeClient:
    """A bmv2 switch that can be made to fail at each independent step."""

    def __init__(self, dpid, pipeline_error=None, clone_ok=True, json_path="pipeline.json",
                 stop_error=None, entry_errors=(), packet_in_ids=NDTWIN_PACKET_IN_IDS,
                 multicast_ok=True):
        self.dpid = dpid
        self.device_id = dpid
        # [Co-developed with claude code -- Adam]
        # TICKET-P3 2.6 (G1): the real client resolves the five packet_in metadata ids out of
        # its own p4info at construction, and `None` means "this program declares no controller
        # header". startup() refuses to give such a switch `cooperative` telemetry, so a double
        # that did not carry the attribute would make every test here take that refusal -- which
        # is how these two lines came to exist. The default is the NDTwin pipeline's answer,
        # because that is what every switch in this file runs unless it says otherwise.
        self.packet_in_ids = packet_in_ids
        self.packet_in_ids_error = (None if packet_in_ids is not None
                                    else "no packet_in controller header in this p4info")
        #: Whether this switch accepts a multicast group write (TICKET-P3 2.6, G8).
        self.multicast_ok = multicast_ok
        #: Every (group_id, replicas, op) and (session_id, replicas) the PRE was asked for.
        self.multicast_groups = []
        self.clone_sessions = []
        self.stop_error = stop_error
        self.json_path = json_path
        self.pipeline_error = pipeline_error
        self.clone_ok = clone_ok
        self.sample_callback = None
        #: Every step this client was put through, in order. Order is part of the contract: the
        #: clone session lives in the pipeline's PRE, so programming it before the pipeline push
        #: would be silently discarded and the switch would report zero traffic forever.
        self.events = []
        #: Every (spec, op) `apply_package_entries` handed this client, and the exceptions it
        #: should raise instead of accepting them -- one per entry, `None` for "accept this
        #: one". A tuple rather than a flag because the property under test is that ONE refused
        #: entry does not cost the others. [Co-developed with claude code -- Adam]
        self.written = []
        self.entry_errors = list(entry_errors)

    def set_forwarding_pipeline_config(self):
        self.events.append("pipeline")
        if self.pipeline_error is not None:
            raise self.pipeline_error

    def write_clone_session(self, session_id=None, egress_port=None, replicas=None):
        # [Co-developed with claude code -- Adam]
        # The signature is the production one as of TICKET-P3 2.6: startup's telemetry loop
        # still calls it with no arguments, and `apply_package_pre_entries` calls it with a
        # session id and a replica list out of the package's runtime file. A double that
        # accepted only the first would turn a correct G9a call into a TypeError.
        self.events.append("clone")
        self.clone_sessions.append((session_id, replicas))
        return self.clone_ok

    def write_multicast_group(self, group_id, replicas, op="insert"):
        self.events.append("multicast")
        self.multicast_groups.append((group_id, list(replicas or []), op))
        return self.multicast_ok

    def write_table_entry(self, spec, op="insert"):
        self.events.append("table_entry")
        self.written.append((spec, op))
        if self.entry_errors:
            error = self.entry_errors.pop(0)
            if error is not None:
                raise error
        return {"dpid": self.dpid, "op": op, "table": spec.get("table")}

    def stop(self):
        self.events.append("stop")
        if self.stop_error is not None:
            raise self.stop_error


class FakeSflow:
    def __init__(self):
        self.registered = {}
        self.closed = False

    def register_switch(self, dpid, agent_ip):
        self.registered[dpid] = agent_ip

    def handle_sample(self, *args, **kwargs):
        pass

    def close(self):
        self.closed = True


class FakeKernel:
    """Records what the kernel was told, and can refuse specific switches."""

    def __init__(self, refuse=()):
        self.entered = []
        self.refuse = set(refuse)

    def switch_entered(self, dpid):
        self.entered.append(dpid)
        return dpid not in self.refuse


class FakeTopo:
    def __init__(self):
        self.switches = {}
        self.started = []
        self.seed_expected = None

    def add_switch(self, dpid, client):
        self.switches[dpid] = client

    def start_lldp_discovery(self):
        self.started.append("lldp")

    def start_link_watchdog(self, seed_expected=False, path=None):
        # Signature mirrors the real TopologyManager.start_link_watchdog. A double narrower than
        # the thing it stands in for is how this suite went wrong once already: startup wraps the
        # call in try/except, so a TypeError here would be swallowed into a printed warning and
        # the watchdog would simply not run, with every test still green.
        # [Co-developed with claude code -- Adam]
        self.started.append("watchdog")
        self.seed_expected = seed_expected

    def start_liveness_polling(self):
        self.started.append("liveness")

    def stop_lldp_discovery(self):
        self.started.append("stop-lldp")

    def stop_link_watchdog(self):
        self.started.append("stop-watchdog")

    def stop_liveness_polling(self):
        self.started.append("stop-liveness")


def run_startup(clients, *, kernel=None, agent_ips=None, sflow=None, topo=None, package=None,
                telemetry_knob=None):
    """Drives startup with fakes and no settling delay, and returns (summary, parts).

    [Co-developed with claude code -- Adam]
    🔴 THE TELEMETRY KNOB IS ALWAYS PATCHED, even when a test says nothing about telemetry.
    `main.TELEMETRY_KNOB_PATH` is a real path inside the checkout (p4_proxy/mininet/
    telemetry_override) and `ndt up p4 --telemetry` writes it -- so without this, every startup
    test in this file would quietly change behaviour on a machine where somebody had left a
    fabric configured, and the suite would be green here and red there for a reason nobody
    could see in the diff. `telemetry_knob=None` means "no knob file", which is `auto`.
    """
    kernel = kernel if kernel is not None else FakeKernel()
    sflow = sflow if sflow is not None else FakeSflow()
    topo = topo if topo is not None else FakeTopo()
    ips = {dpid: f"192.168.123.{10 + dpid}" for dpid in clients} if agent_ips is None else agent_ips
    # os.getpid() in a path that is deliberately never created: tests/shell/check_test_tmpdirs.py
    # refuses a fixed /tmp name in a suite, and it is right to -- ctest gives every test its own
    # process, and two of them agreeing on one path is a race that only shows up under -j2.
    knob = telemetry_knob or os.path.join(
        tempfile.gettempdir(), f"ndtwin-no-such-telemetry-override-{os.getpid()}")
    with mock.patch.object(main, "TELEMETRY_KNOB_PATH", knob):
        summary = asyncio.run(startup(
            lambda: clients, sflow, kernel, topo,
            settle_seconds=0, agent_ips_loader=lambda: ips,
            package=package if package is not None else app_package.baseline(),
        ))
    return summary, {"kernel": kernel, "sflow": sflow, "topo": topo}


def declaring_telemetry(package, word):
    """A copy of `package` that declares `telemetry.source`.

    [Co-developed with claude code -- Adam]
    🔴 A REAL `Package`, AS OF ROUND 2 (TICKET-P3 section 9 ruling 5). Round 1 built a SUBCLASS
    carrying the word as a class attribute, because `Package` is a frozen dataclass that B owned
    and the field did not exist on this branch yet. B is merged and `telemetry_source` is a real
    field -- and the subclass trick stopped working the moment it was, silently: an instance
    attribute set by `__init__` shadows a class attribute, so every one of these cases quietly
    read `auto` instead of the word it asked for. `dataclasses.replace` on the real type is what
    a caller writes, so it is what these tests use.
    """
    return dataclasses.replace(package, telemetry_source=word)


def external_package(directory="/packages/p4runtime"):
    """A package whose exercise brings its own controller."""
    return app_package.Package(dir=directory, name="p4runtime", mode="external",
                               election_id=(0, 65535))


class WhichSwitchesAreClaimedTest(unittest.TestCase):
    def test_a_switch_that_took_a_pipeline_is_claimed(self):
        clients = {1: FakeClient(1), 2: FakeClient(2)}
        summary, parts = run_startup(clients)
        self.assertEqual(parts["kernel"].entered, [1, 2])
        self.assertEqual(summary["entered"], [1, 2])

    def test_a_switch_whose_pipeline_push_failed_is_not_claimed(self):
        # isEnabled means "the control plane can drive this switch". One with no pipeline cannot
        # forward, so enabling its vertex would put paths and rates on a dead switch.
        clients = {1: FakeClient(1), 2: FakeClient(2, pipeline_error=RuntimeError("no switch"))}
        summary, parts = run_startup(clients)
        self.assertEqual(parts["kernel"].entered, [1])
        self.assertEqual(summary["broken"], [2])
        self.assertNotIn(2, summary["entered"])

    def test_one_dead_switch_does_not_stop_the_others_from_being_set_up(self):
        # The whole reason the pipeline push is guarded per switch: an unguarded call made uvicorn
        # treat one dead bmv2 as a fatal startup error and the other nine lost everything.
        clients = {
            1: FakeClient(1, pipeline_error=RuntimeError("dead")),
            2: FakeClient(2),
            3: FakeClient(3),
        }
        summary, parts = run_startup(clients)
        self.assertEqual(summary["broken"], [1])
        self.assertEqual(parts["kernel"].entered, [2, 3])
        self.assertEqual(summary["telemetry"], [2, 3])

    def test_each_usable_switch_is_claimed_exactly_once(self):
        clients = {n: FakeClient(n) for n in range(1, 6)}
        _, parts = run_startup(clients)
        self.assertEqual(sorted(parts["kernel"].entered), [1, 2, 3, 4, 5])
        self.assertEqual(len(parts["kernel"].entered), 5, "a switch was claimed twice")

    def test_a_switch_the_kernel_refuses_is_reported_not_silently_dropped(self):
        clients = {1: FakeClient(1), 2: FakeClient(2)}
        summary, _ = run_startup(clients, kernel=FakeKernel(refuse=[2]))
        self.assertEqual(summary["entered"], [1])
        self.assertEqual(summary["not_entered"], [2],
                         "a switch the kernel did not acknowledge must be named; its vertex stays "
                         "disabled and every path through it will be empty")


class TelemetryIsIndependentOfBeingClaimedTest(unittest.TestCase):
    """
    Three separate outcomes, deliberately not collapsed into one health flag: a switch can hold
    mastership, take a pipeline, fail to get telemetry, and still belong in the graph.
    """

    def test_a_switch_with_no_agent_ip_gets_no_telemetry_but_is_still_claimed(self):
        clients = {1: FakeClient(1), 2: FakeClient(2)}
        summary, parts = run_startup(clients, agent_ips={1: "192.168.123.11"})
        self.assertEqual(parts["sflow"].registered, {1: "192.168.123.11"})
        self.assertEqual(summary["telemetry"], [1])
        self.assertIn(2, summary["entered"],
                      "a switch without telemetry still forwards; excluding it from the graph "
                      "would empty every path through it as well as its rates")

    def test_a_failed_clone_session_does_not_cost_the_switch_its_place_in_the_graph(self):
        clients = {1: FakeClient(1, clone_ok=False), 2: FakeClient(2)}
        summary, _ = run_startup(clients)
        self.assertEqual(summary["telemetry"], [2])
        self.assertEqual(summary["entered"], [1, 2])

    def test_a_broken_switch_gets_no_clone_session_attempted(self):
        # There is no PRE to program a clone session into without a pipeline, so attempting it
        # would only produce a second, misleading error for the same cause.
        broken = FakeClient(2, pipeline_error=RuntimeError("dead"))
        run_startup({1: FakeClient(1), 2: broken})
        self.assertNotIn("clone", broken.events)

    def test_the_clone_session_is_programmed_after_the_pipeline_not_before(self):
        client = FakeClient(1)
        run_startup({1: client})
        self.assertEqual(client.events, ["pipeline", "clone"],
                         "the clone session lives in the pipeline's PRE; programming it first is "
                         "discarded and the switch reports zero traffic with no error")

    def test_the_sample_callback_is_wired_so_arriving_samples_have_somewhere_to_go(self):
        client = FakeClient(1)
        _, parts = run_startup({1: client})
        self.assertEqual(client.sample_callback, parts["sflow"].handle_sample)


class BackgroundLoopsTest(unittest.TestCase):
    def test_all_three_loops_are_started(self):
        # The watchdog is the one that was missing: without it a link that goes down stays up in
        # the twin for the rest of the run.
        _, parts = run_startup({1: FakeClient(1)})
        self.assertEqual(sorted(parts["topo"].started), ["liveness", "lldp", "watchdog"])

        # And that it is asked to seed. Without this the watchdog only knows links that have
        # delivered a beacon, so one already broken at startup is absent rather than reported --
        # the operator sees a count that is short by one and has to work out which link it was.
        # Asserting the flag rather than just the call, because "watchdog started" was already
        # true before seeding was turned on. [Co-developed with claude code -- Adam]
        self.assertTrue(parts["topo"].seed_expected,
                        "startup must ask the watchdog to seed the declared links")

    def test_a_loop_that_fails_to_start_does_not_abort_the_rest_of_startup(self):
        class BadTopo(FakeTopo):
            def start_lldp_discovery(self):
                raise RuntimeError("cannot start")

        topo = BadTopo()
        summary, _ = run_startup({1: FakeClient(1)}, topo=topo)
        self.assertEqual(summary["entered"], [1])
        self.assertEqual(sorted(topo.started), ["liveness", "watchdog"])


class AnExternalControlPlaneTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam]

    `control_plane.mode: external` means the exercise ships its own controller, and that
    controller -- not this proxy -- holds mastership. Two controllers on one bmv2 is not a
    degraded mode: P4Runtime identifies the sender of a unary RPC by the election id in the
    message rather than by the connection it arrived on, so the second one's
    SetForwardingPipelineConfig is ACCEPTED and wipes every table the first installed (measured
    2026-08-13; p4_proxy/reference/p4runtime_mastership_probe.py re-runs it).

    🔴 So this suite asserts two things that have to hold together: that the write steps do NOT
    happen, and that every one of them is NAMED in what startup returns. Skipping alone is not
    enough -- a fabric with no telemetry, no discovered links and no proxy-installed routes looks
    exactly like a broken one, which is GAP-ANALYSIS section 5's "reports zero rather than
    reports an error".
    """

    def test_an_external_control_plane_pushes_no_pipeline(self):
        clients = {1: FakeClient(1), 2: FakeClient(2)}
        run_startup(clients, package=external_package())
        for dpid, client in clients.items():
            self.assertNotIn("pipeline", client.events,
                             f"switch {dpid}: a pipeline push would have emptied every table the "
                             f"exercise's own controller installed, and reported success")

    def test_an_external_control_plane_programs_no_clone_session(self):
        clients = {1: FakeClient(1)}
        summary, parts = run_startup(clients, package=external_package())
        self.assertNotIn("clone", clients[1].events)
        self.assertEqual(summary["telemetry"], [])
        self.assertEqual(parts["sflow"].registered, {},
                         "registering a switch for sFlow whose clone session was never "
                         "programmed advertises telemetry that cannot arrive")

    def test_an_external_control_plane_starts_no_lldp_and_no_watchdog(self):
        _, parts = run_startup({1: FakeClient(1)}, package=external_package())
        self.assertNotIn("lldp", parts["topo"].started)
        self.assertNotIn("watchdog", parts["topo"].started)

    def test_an_external_control_plane_still_polls_liveness(self):
        # The probe is a unary GetForwardingPipelineConfig with COOKIE_ONLY: no stream, no
        # election id, no write. Without it every switch reports probe_ok=null forever and the
        # kernel answers Unknown for the whole fabric.
        _, parts = run_startup({1: FakeClient(1)}, package=external_package())
        self.assertIn("liveness", parts["topo"].started)

    def test_an_external_control_plane_still_tells_the_kernel_the_switches_exist(self):
        # isEnabled gates BFS pathing, flow-table polling and link-usage attribution. A switch
        # somebody else programs still forwards, so leaving its vertex disabled would empty every
        # path through it -- the twin would see an exercise it is running as an empty network.
        summary, parts = run_startup({1: FakeClient(1), 2: FakeClient(2)},
                                     package=external_package())
        self.assertEqual(parts["kernel"].entered, [1, 2])
        self.assertEqual(summary["entered"], [1, 2])
        self.assertEqual(summary["broken"], [],
                         "no pipeline was attempted, so no pipeline failed; reporting these as "
                         "broken would mark a healthy fabric down")

    def test_an_external_startup_names_every_step_it_skipped(self):
        summary, _ = run_startup({1: FakeClient(1)}, package=external_package())
        self.assertEqual(summary["control_plane"]["mode"], "external")
        self.assertEqual(summary["control_plane"]["package"], "/packages/p4runtime")
        self.assertEqual(summary["control_plane"]["skipped"], sorted(main.EXTERNAL_SKIPS))
        for step in ("pipeline_push", "clone_session", "sflow_telemetry", "lldp_discovery",
                     "link_watchdog", "install_initial_routes"):
            self.assertIn(step, summary["control_plane"]["skipped"])

    def test_a_baseline_startup_reports_an_empty_skip_list_not_a_missing_one(self):
        # `[]` is the assertion that the disclosure is live on the ordinary fabric too. A field
        # that only appears when something was skipped cannot be told apart from a proxy too old
        # to have the field.
        summary, _ = run_startup({1: FakeClient(1)})
        self.assertEqual(summary["control_plane"],
                         {"mode": "ndtwin", "package": None, "skipped": []})

    def test_what_startup_reported_is_what_the_endpoint_serves(self):
        # The report is not a second copy: main.control_plane_report() is what
        # GET /p4/switch_state reads, and startup is what writes it.
        run_startup({1: FakeClient(1)}, package=external_package())
        self.assertEqual(main.control_plane_report()["mode"], "external")
        self.addCleanup(run_startup, {1: FakeClient(1)})

    def test_an_ndtwin_mode_package_is_not_treated_as_external(self):
        # The negative half: mode is what switches this on, not "there is a package".
        package = app_package.Package(dir="/packages/basic", name="basic", mode="ndtwin")
        clients = {1: FakeClient(1)}
        summary, parts = run_startup(clients, package=package)
        self.assertEqual(clients[1].events, ["pipeline", "clone"])
        self.assertEqual(sorted(parts["topo"].started), ["liveness", "lldp", "watchdog"])
        self.assertEqual(summary["control_plane"]["skipped"], [])
        self.assertEqual(summary["control_plane"]["package"], "/packages/basic")


class AForeignPipelineTest(unittest.TestCase):
    """
    TICKET-P2 2.2: what changes when a switch is running the app package's own program.

    [Co-developed with claude code -- Adam]

    🔴 THE THREE THINGS THAT STOP HAPPENING ALL LOOK LIKE FAULTS FROM OUTSIDE, which is why
    every one of them is asserted together with its disclosure:

      * no clone session and no sFlow registration for that switch -- the PRE write would
        SUCCEED (a clone session is a target object, not part of the P4 program) and then
        nothing would ever clone into it, because `clone_preserving_field_list` exists only in
        ndtwin_switch.p4. A registered switch that never samples is zero telemetry with every
        intermediate step green;
      * no LLDP and no watchdog for the WHOLE fabric -- both ride a controller header a
        tutorials pipeline does not declare, and the watchdog seeds every declared link and
        would report the lot down inside its timeout;
      * the package's own entries ARE applied, which is the only reason such a fabric forwards
        anything at all.

    And the negative half, which is what keeps the two above from being change detectors: under
    NDTwin's own pipeline -- every package phase 1 accepts -- none of it happens, the entries
    stay recorded and unapplied, and `skipped` is empty.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_startup_entries_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.saved = (dict(main._pipelines), dict(main._table_entries), dict(main._api_writes))
        self.addCleanup(self.restore)

    def restore(self):
        for live, saved in ((main._pipelines, self.saved[0]),
                            (main._table_entries, self.saved[1]),
                            (main._api_writes, self.saved[2])):
            live.clear()
            live.update(saved)

    def entries_file(self, dpid, count):
        path = os.path.join(self.tmp, f"s{dpid}-runtime.json")
        with open(path, "w") as fh:
            json.dump({"target": "bmv2", "table_entries": [
                {"table": "MyIngress.ipv4_lpm",
                 "match": {"hdr.ipv4.dstAddr": [f"10.0.{dpid}.{i + 1}", 32]},
                 "action_name": "MyIngress.ipv4_forward",
                 "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
                for i in range(count)]}, fh)
        return path

    def package(self, dpids=(1,), pipeline=("build/basic.p4info.txtpb", "build/basic.json"),
                entries=2, mode="ndtwin"):
        switches = tuple(
            app_package.SwitchSpec(dpid=dpid, name=f"s{dpid}", pipeline=pipeline,
                                   entries=None if not entries else self.entries_file(dpid,
                                                                                      entries),
                                   entries_recorded=entries)
            for dpid in dpids)
        return app_package.Package(dir="/packages/basic", name="basic", mode=mode,
                                   switches=switches)

    # --- the fabric-wide half ---------------------------------------------------------

    def test_a_foreign_pipeline_names_every_fabric_wide_step_it_switched_off(self):
        # 🔴 THREE NAMES, NOT FIVE (TICKET-P2 2.2 :48, and round 2's ruling). The clone session
        # and the sFlow registration are per switch and are disclosed on that switch's own
        # `pipeline.skipped` -- see test_the_per_switch_skips_are_not_in_the_fabric_wide_list.
        summary, _ = run_startup({1: FakeClient(1)}, package=self.package())
        self.assertEqual(summary["control_plane"]["skipped"],
                         sorted([main.SKIP_LLDP, main.SKIP_WATCHDOG, main.SKIP_ROUTES]))

    def test_the_per_switch_skips_are_not_in_the_fabric_wide_list(self):
        # 🔴 The bug round 1 shipped and the judge caught. In a MIXED fabric the NDTwin switch
        # beside the package's still gets a clone session (asserted below in
        # test_an_ndtwin_switch_beside_a_foreign_one_keeps_its_clone_session) -- so
        # `clone_session` in the fabric-wide list is a sentence about one switch told about two.
        summary, _ = run_startup({1: FakeClient(1), 2: FakeClient(2)},
                                 package=self.package(dpids=(1,), entries=0))
        self.assertNotIn(main.SKIP_CLONE, summary["control_plane"]["skipped"])
        self.assertNotIn(main.SKIP_TELEMETRY, summary["control_plane"]["skipped"])
        self.assertEqual(summary["pipelines"]["1"]["skipped"],
                         sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]))
        self.assertEqual(summary["pipelines"]["2"]["skipped"], [],
                         "the NDTwin switch skipped nothing, and says so with an empty list "
                         "rather than by having no such key")

    def test_the_pipeline_push_itself_is_not_skipped(self):
        # 🔴 The one step that must still happen. `pipeline_push` is absent from the list above
        # on purpose: the package's program is loaded BY this proxy, which is the whole feature.
        client = FakeClient(1)
        summary, _ = run_startup({1: client}, package=self.package())
        self.assertIn("pipeline", client.events)
        self.assertNotIn(main.SKIP_PIPELINE, summary["control_plane"]["skipped"])

    def test_no_lldp_and_no_watchdog_run_on_a_fabric_with_a_foreign_pipeline(self):
        _, parts = run_startup({1: FakeClient(1)}, package=self.package())
        self.assertNotIn("lldp", parts["topo"].started)
        self.assertNotIn("watchdog", parts["topo"].started)
        self.assertIn("liveness", parts["topo"].started,
                      "the probe is a unary read with no election id; dropping it would make "
                      "the kernel answer Unknown for every switch")

    def test_one_foreign_switch_switches_the_whole_fabrics_discovery_off(self):
        # A beacon leaves one switch and arrives at another, so a link between an NDTwin switch
        # and a package switch cannot be discovered either -- and a seeded watchdog would report
        # it down. Per-switch here would be a fabric-wide false alarm.
        package = self.package(dpids=(1,), entries=0)
        _, parts = run_startup({1: FakeClient(1), 2: FakeClient(2)}, package=package)
        self.assertNotIn("lldp", parts["topo"].started)

    # --- the per-switch half ----------------------------------------------------------

    def test_a_foreign_pipeline_gets_no_clone_session_and_no_sflow_registration(self):
        client = FakeClient(1)
        summary, parts = run_startup({1: client}, package=self.package())
        self.assertNotIn("clone", client.events)
        self.assertEqual(parts["sflow"].registered, {})
        self.assertEqual(summary["telemetry"], [])
        self.assertEqual(summary["pipelines"]["1"]["skipped"],
                         sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]))

    def test_a_foreign_pipeline_that_cannot_carry_the_header_still_gets_nothing(self):
        # 🔴 THE GUARD'S DISCRIMINATING CASE, as of TICKET-P3 section 9 ruling 4. Under `auto` a
        # foreign pipeline resolves to `link`, so the telemetry-source check below would skip
        # this switch even with the foreign branch gone -- the two guards would mask each other
        # exactly the way `read_only` and "no agent IP" once did, and
        # tests/shell/mutate_table_entry.sh's M-B9 SURVIVED on precisely that in round 1.
        #
        # What separates them is a switch asked for `cooperative` whose program has no
        # controller header: the source check would let it through, and the refusal in startup
        # is what stops it -- with the client's own `packet_in_ids` as the evidence, not the
        # package's opinion of whose pipeline it is.
        knob = os.path.join(self.tmp, "telemetry_override")
        with open(knob, "w") as fh:
            fh.write("cooperative\n")
        blind = FakeClient(1, packet_in_ids=None)
        with self.assertRaises(main.TelemetryConfigError) as cm:
            run_startup({1: blind}, package=self.package(), telemetry_knob=knob)
        self.assertIn("switch 1", str(cm.exception))
        self.assertNotIn("clone", blind.events)

    def test_an_ndtwin_switch_beside_a_foreign_one_keeps_its_clone_session(self):
        # Per switch, not fabric-wide: the clone session is programmed into THAT switch's PRE,
        # and an NDTwin pipeline still clones into it whatever its neighbour is running.
        ours, theirs = FakeClient(2), FakeClient(1)
        summary, parts = run_startup({1: theirs, 2: ours}, package=self.package(dpids=(1,),
                                                                                entries=0))
        self.assertIn("clone", ours.events)
        self.assertNotIn("clone", theirs.events)
        self.assertEqual(summary["telemetry"], [2])
        self.assertEqual(sorted(parts["sflow"].registered), [2])

    def test_the_packages_entries_are_applied_to_a_foreign_pipeline(self):
        client = FakeClient(1)
        summary, _ = run_startup({1: client}, package=self.package(entries=2))
        self.assertEqual(len(client.written), 2)
        self.assertEqual(summary["table_entries"]["1"]["recorded"], 2)
        self.assertEqual(summary["table_entries"]["1"]["applied"], 2)
        self.assertEqual(summary["table_entries"]["1"]["failed"], 0)

    def test_the_entries_go_on_after_the_pipeline_that_defines_their_tables(self):
        client = FakeClient(1)
        run_startup({1: client}, package=self.package(entries=2))
        self.assertEqual(client.events, ["pipeline", "table_entry", "table_entry"],
                         "an entry written before the push is erased by it, and the push "
                         "reports success either way")

    def test_one_refused_entry_does_not_cost_the_others(self):
        # A tutorials runtime file is a list of independent rules. Stopping at the first failure
        # leaves the fabric programmed up to an arbitrary point with nothing saying where.
        client = FakeClient(1, entry_errors=[RuntimeError("table not in this pipeline"), None])
        summary, _ = run_startup({1: client}, package=self.package(entries=2))
        self.assertEqual(len(client.written), 2)
        self.assertEqual(summary["table_entries"]["1"]["applied"], 1)
        self.assertEqual(summary["table_entries"]["1"]["failed"], 1)

    def test_a_refused_entry_is_named_not_just_counted(self):
        client = FakeClient(1, entry_errors=[RuntimeError("no such table")])
        summary, _ = run_startup({1: client}, package=self.package(entries=1))
        self.assertIn("1", summary["entry_errors"])
        self.assertIn("no such table", summary["entry_errors"]["1"][0])

    def test_a_switch_whose_pipeline_push_failed_gets_no_entries(self):
        # There is no pipeline to write them into, and the attempt would produce a second
        # misleading error for the same cause.
        client = FakeClient(1, pipeline_error=RuntimeError("dead"))
        summary, _ = run_startup({1: client}, package=self.package(entries=2))
        self.assertEqual(client.written, [])
        self.assertEqual(summary["table_entries"]["1"]["applied"], 0)
        self.assertEqual(summary["table_entries"]["1"]["recorded"], 2,
                         "the count of what the package declared does not depend on whether "
                         "the switch was reachable")

    def test_every_switch_is_reported_with_the_program_it_runs(self):
        summary, _ = run_startup({1: FakeClient(1), 2: FakeClient(2)},
                                 package=self.package(dpids=(1,), entries=0))
        self.assertFalse(summary["pipelines"]["1"]["ndtwin"])
        self.assertTrue(summary["pipelines"]["2"]["ndtwin"])
        self.assertIn("basic.p4info.txtpb", summary["pipelines"]["1"]["p4info"])

    def test_an_external_package_skips_the_six_and_discloses_nothing_per_switch(self):
        # `external` is a fabric-wide statement about who owns the control plane; it does not
        # make any switch's PIPELINE foreign. So the six EXTERNAL_SKIPS stay in the fabric-wide
        # list (asserted below) and the per-switch list follows the pipeline, not the mode.
        summary, _ = run_startup({1: FakeClient(1)},
                                 package=self.package(pipeline=None, entries=0,
                                                      mode="external"))
        self.assertEqual(summary["control_plane"]["skipped"], sorted(main.EXTERNAL_SKIPS))
        self.assertEqual(summary["pipelines"]["1"]["skipped"], [])

    # --- the negative half: NDTwin's own pipeline is untouched ------------------------

    def test_under_ndtwins_own_pipeline_the_entries_stay_recorded_and_unapplied(self):
        # 🔴 What phase 1 shipped and `live-p1/02` asserts. `MyIngress.ipv4_lpm` in basic.p4 is
        # not `MyIngress.ipv4_lpm` in ndtwin_switch.p4 even though the two strings are equal, so
        # applying these would put the exercise's forwarding into our pipeline on top of the
        # routes install_initial_routes computes -- and both would report success.
        client = FakeClient(1)
        summary, _ = run_startup({1: client}, package=self.package(pipeline=None, entries=5))
        self.assertEqual(client.written, [])
        self.assertEqual(summary["table_entries"]["1"],
                         {"recorded": 5, "applied": 0, "failed": 0, "api_writes": 0,
                          "journaled": False})

    def test_under_ndtwins_own_pipeline_nothing_is_skipped(self):
        summary, parts = run_startup({1: FakeClient(1)},
                                     package=self.package(pipeline=None, entries=5))
        self.assertEqual(summary["control_plane"]["skipped"], [])
        self.assertEqual(sorted(parts["topo"].started), ["liveness", "lldp", "watchdog"])
        self.assertEqual(summary["telemetry"], [1])

    def test_an_external_package_is_reported_exactly_as_phase_one_reported_it(self):
        # `external` and "foreign pipeline" are independent: the first says somebody else drives
        # this fabric, the second says which program is on it. An external package still skips
        # the six EXTERNAL_SKIPS and nothing more, and applies no entries -- it is not allowed
        # to write at all.
        client = FakeClient(1)
        summary, _ = run_startup({1: client}, package=self.package(entries=5, mode="external"))
        self.assertEqual(summary["control_plane"]["skipped"], sorted(main.EXTERNAL_SKIPS))
        self.assertEqual(client.events, [])
        self.assertEqual(summary["table_entries"]["1"]["applied"], 0)
        self.assertEqual(summary["table_entries"]["1"]["recorded"], 5)

    def test_the_baseline_fabric_reports_a_pipeline_of_its_own_and_no_entries(self):
        summary, _ = run_startup({1: FakeClient(1)})
        self.assertTrue(summary["pipelines"]["1"]["ndtwin"])
        self.assertEqual(summary["control_plane"]["skipped"], [])
        self.assertEqual(summary["entry_errors"], {})



class RegistrationTest(unittest.TestCase):
    def test_every_connected_switch_is_registered_with_the_topology_manager(self):
        # Including the broken one: it keeps its client so the liveness poller still probes it, and
        # that is what lets the kernel show it as down rather than merely absent.
        clients = {1: FakeClient(1), 2: FakeClient(2, pipeline_error=RuntimeError("dead"))}
        _, parts = run_startup(clients)
        self.assertEqual(sorted(parts["topo"].switches), [1, 2])


class ShutdownStopsTheClientsTheTopologyManagerHoldsTest(unittest.TestCase):
    """
    [Co-developed with claude code -- Adam]
    Shutdown used to iterate a module-global `p4_clients`, assigned once from startup()'s
    summary. POST /p4/readopt/{dpid} replaces topology.switches[dpid] with a freshly built
    client after a power-cycle, and that copy did not follow: shutdown stopped the
    already-stopped old client and left the new one's gRPC channel and receiver thread running.

    The contract asserted here is "shutdown stops exactly the clients the topology manager
    currently holds", which is what makes a second copy impossible to get wrong -- because
    there is no second copy.
    """

    def run_shutdown(self, topo, sflow=None):
        sflow = sflow if sflow is not None else FakeSflow()
        with mock.patch.object(main, "topo", topo), mock.patch.object(main, "sflow", sflow):
            asyncio.run(main.shutdown_event())
        return sflow

    def test_every_switch_the_topology_manager_holds_is_stopped(self):
        topo = FakeTopo()
        topo.add_switch(1, FakeClient(1))
        topo.add_switch(2, FakeClient(2))

        self.run_shutdown(topo)

        for dpid, client in topo.switches.items():
            self.assertIn("stop", client.events, f"switch {dpid} was never stopped")

    def test_the_client_a_readopt_installed_is_the_one_that_gets_stopped(self):
        topo = FakeTopo()
        before = FakeClient(1)
        topo.add_switch(1, before)
        # What readopt_switch does: build a new client, swap it in, stop the old one.
        after = FakeClient(1)
        topo.switches[1] = after
        before.events.append("stop")  # readopt already stopped it

        self.run_shutdown(topo)

        self.assertIn("stop", after.events,
                      "shutdown stopped a client the topology manager no longer holds and left "
                      "the post-readopt one running: its channel and receiver thread outlive "
                      "shutdown, silently")
        self.assertEqual(before.events.count("stop"), 1,
                         "the pre-readopt client was stopped twice")

    def test_all_three_background_loops_are_stopped_before_the_clients(self):
        topo = FakeTopo()
        topo.add_switch(1, FakeClient(1))

        self.run_shutdown(topo)

        # The LLDP beacon thread had no stop at all once, so it kept calling send_packet_out on
        # clients that had already been torn down.
        self.assertEqual(topo.started, ["stop-lldp", "stop-watchdog", "stop-liveness"])

    def test_one_client_that_refuses_to_stop_does_not_abandon_the_rest(self):
        topo = FakeTopo()
        topo.add_switch(1, FakeClient(1, stop_error=RuntimeError("channel already dead")))
        topo.add_switch(2, FakeClient(2))

        sflow = self.run_shutdown(topo)

        self.assertIn("stop", topo.switches[2].events,
                      "a client that raised on stop() took the switches after it down with it")
        self.assertTrue(sflow.closed, "the emitter socket was never closed")


# --- where each switch's samples come from. TICKET-P3 2.1 --------------------------------------


class TelemetrySourceTest(unittest.TestCase):
    """
    The word, the three layers that resolve it, and the six cells it produces.

    [Co-developed with claude code -- Adam]
    🔴 THE TWO SOURCES ARE EXCLUSIVE AND NOTHING DOWNSTREAM CAN TELL WHEN THEY ARE NOT. Under
    `link` the switch-side veths are sampled by tc filters and a separate emitter synthesises the
    sFlow; if this proxy ALSO programmed a clone session, the same packet would be counted twice
    -- once cloned to the CPU and once sampled on the wire -- into the same edge's byte total.
    Every rate and every link utilisation would read exactly double, uniformly, with no error
    anywhere. That is the 2026-08-16 clone-stacking shape, which took a veth reconciliation
    harness to catch the last time it happened.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_telemetry_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.saved = (dict(main._pipelines), dict(main._table_entries), dict(main._telemetry),
                      dict(main._pre_entries))
        self.addCleanup(self.restore)

    def restore(self):
        for live, saved in ((main._pipelines, self.saved[0]),
                            (main._table_entries, self.saved[1]),
                            (main._telemetry, self.saved[2]),
                            (main._pre_entries, self.saved[3])):
            live.clear()
            live.update(saved)

    def knob(self, text):
        path = os.path.join(self.tmp, "telemetry_override")
        with open(path, "w") as fh:
            fh.write(text)
        return path

    def foreign_package(self, dpids=(1,), pipeline=None):
        """A package whose switches run their own program -- so `auto` answers `link`.

        [Co-developed with claude code -- Adam]
        `pipeline` defaults to the REAL compiled `basic` artefacts (absolute paths, which
        `Package.pipeline_for` passes through untouched). Round 1 named files that do not exist,
        which was enough while the only question was "is this NDTwin's pipeline" -- section 9
        ruling 4 made the p4info's CONTENT decide whether a foreign switch may have cooperative
        telemetry, so the fixture has to be a program that really does, or really does not,
        declare the header.
        """
        pipeline = pipeline or PLAIN_FOREIGN_PIPELINE
        switches = tuple(
            app_package.SwitchSpec(dpid=dpid, name=f"s{dpid}", pipeline=pipeline,
                                   entries=None, entries_recorded=0)
            for dpid in dpids)
        return app_package.Package(dir="/packages/basic", name="basic", switches=switches)

    def include_package(self, dpids=(1,)):
        """A package whose switches run their own program AND included ndtwin_telemetry.p4."""
        return self.foreign_package(dpids, pipeline=TELEMETRY_FOREIGN_PIPELINE)

    # --- the resolver itself ------------------------------------------------------------

    def test_no_knob_and_no_declaration_is_auto_and_auto_is_per_switch(self):
        baseline = app_package.baseline()
        with mock.patch.object(main, "TELEMETRY_KNOB_PATH", os.path.join(self.tmp, "absent")):
            self.assertEqual(main._telemetry_source(baseline, 1), main.TELEMETRY_COOPERATIVE)
            self.assertEqual(main._telemetry_source(self.foreign_package(), 1),
                             main.TELEMETRY_LINK)

    def test_the_knob_beats_the_package(self):
        # An operator who typed `--telemetry none` means it for this fabric, whatever the
        # package prefers -- that is what makes the measurement's control arm reachable at all.
        package = declaring_telemetry(app_package.baseline(), "cooperative")
        self.assertEqual(
            main._telemetry_source(package, 1, knob_path=self.knob("none\n")),
            main.TELEMETRY_NONE)

    def test_an_auto_knob_defers_to_the_package(self):
        package = declaring_telemetry(app_package.baseline(), "link")
        self.assertEqual(
            main._telemetry_source(package, 1, knob_path=self.knob("auto\n")),
            main.TELEMETRY_LINK)

    def test_the_package_beats_auto(self):
        package = declaring_telemetry(app_package.baseline(), "none")
        with mock.patch.object(main, "TELEMETRY_KNOB_PATH", os.path.join(self.tmp, "absent")):
            self.assertEqual(main._telemetry_source(package, 1), main.TELEMETRY_NONE)

    def test_comments_and_blank_lines_are_skipped_like_the_other_directive_files(self):
        knob = self.knob("# written by ndt up p4 --telemetry\n\nlink\n")
        self.assertEqual(main.read_telemetry_knob(knob), "link")

    def test_a_word_outside_the_domain_is_refused_rather_than_defaulted(self):
        # 🔴 The fallback is what turns a typo into a silent change of measurement conditions,
        # and this knob exists so that three processes agree -- the one that cannot read it must
        # not guess.
        with self.assertRaises(main.TelemetryConfigError) as cm:
            main.read_telemetry_knob(self.knob("cooperatvie\n"))
        self.assertIn("cooperatvie", str(cm.exception))

    def test_an_empty_knob_reads_as_nothing_rather_than_raising(self):
        # 🔴 A BEHAVIOUR THAT CHANGED AT THE COLLAPSE (section 9 ruling 5), recorded rather than
        # quietly adopted. Round 1's proxy-side reader REFUSED a knob file that exists and names
        # nothing, on the app-package knob's precedent. `app_package.read_telemetry_knob` is the
        # one implementation now and answers None -- "the package decides" -- and `ndt`, the
        # only writer, deletes the file rather than emptying it.
        self.assertIsNone(main.read_telemetry_knob(self.knob("# nothing but a comment\n")))

    def test_an_absent_knob_is_none_rather_than_an_error(self):
        self.assertIsNone(main.read_telemetry_knob(os.path.join(self.tmp, "absent")))

    def test_a_refusal_from_the_package_reader_arrives_as_a_telemetry_refusal(self):
        # 🔴 THE WRAPPING IS THE CONTRACT (section 9 ruling 5). The rule lives in app_package and
        # raises `AppPackageError`; startup's refusal path catches `TelemetryConfigError`. Let
        # the first through unwrapped and a fabric whose knob says `cooperatvie` dies with a
        # traceback nobody routes, instead of the named refusal this whole path exists to be.
        with self.assertRaises(main.TelemetryConfigError) as cm:
            main._telemetry_source(app_package.baseline(), 1,
                                   knob_path=self.knob("cooperatvie\n"))
        self.assertIn("cooperatvie", str(cm.exception))
        self.assertIsInstance(cm.exception.__cause__, app_package.AppPackageError)

    # --- the six cells: three sources x (NDTwin pipeline, foreign pipeline) ---------------

    def cell(self, source, foreign, include=False):
        """One (source, pipeline) cell. `include` is the foreign program that CAN carry it.

        The double's `packet_in_ids` is set from the same fact the package's p4info states, so
        the client and the file cannot disagree about a switch -- which is the disagreement
        section 9 ruling 4's decision now rests on.
        """
        if include:
            package = self.include_package()
        elif foreign:
            package = self.foreign_package()
        else:
            package = app_package.baseline()
        client = FakeClient(1, packet_in_ids=None if (foreign and not include)
                            else NDTWIN_PACKET_IN_IDS)
        summary, parts = run_startup({1: client}, package=package,
                                     telemetry_knob=self.knob(source + "\n"))
        return summary, parts, client

    def test_cooperative_on_ndtwins_pipeline_programs_the_clone_and_registers(self):
        summary, parts, client = self.cell("cooperative", foreign=False)
        self.assertIn("clone", client.events)
        self.assertEqual(parts["sflow"].registered, {1: "192.168.123.11"})
        self.assertEqual(summary["telemetry"], [1])
        self.assertEqual(summary["telemetry_sources"], {"1": "cooperative"})
        disclosure = summary["telemetry_report"]["1"]
        self.assertEqual(disclosure["source"], "cooperative")
        self.assertTrue(disclosure["clone_session"])
        self.assertTrue(disclosure["sflow_registered"])
        self.assertEqual(disclosure["packet_in_ids"],
                         {"reason": 1, "ingress_port": 2, "egress_port": 3,
                          "frame_length": 4, "sampling_rate": 5})

    def test_link_on_ndtwins_pipeline_programs_no_clone_and_registers_nothing(self):
        summary, parts, client = self.cell("link", foreign=False)
        self.assertNotIn("clone", client.events,
                         "a clone session under link telemetry counts every packet twice")
        self.assertEqual(parts["sflow"].registered, {})
        self.assertEqual(summary["telemetry"], [])
        disclosure = summary["telemetry_report"]["1"]
        self.assertEqual(disclosure["source"], "link")
        self.assertFalse(disclosure["clone_session"])
        self.assertFalse(disclosure["sflow_registered"])
        self.assertIn("counted twice", disclosure["reason"])

    def test_none_on_ndtwins_pipeline_samples_nothing_at_all(self):
        summary, parts, client = self.cell("none", foreign=False)
        self.assertNotIn("clone", client.events)
        self.assertEqual(parts["sflow"].registered, {})
        self.assertEqual(summary["telemetry_report"]["1"]["source"], "none")

    def test_link_on_a_foreign_pipeline_is_still_link_and_still_writes_nothing(self):
        summary, parts, client = self.cell("link", foreign=True)
        self.assertNotIn("clone", client.events)
        self.assertEqual(parts["sflow"].registered, {})
        self.assertEqual(summary["telemetry_report"]["1"]["source"], "link")
        # 🔴 TICKET-P2 7-7 froze this list and it stays frozen: those two steps really were
        # skipped. What is new is the `telemetry` object saying WHY.
        self.assertEqual(summary["pipelines"]["1"]["skipped"],
                         sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]))

    def test_none_on_a_foreign_pipeline_writes_nothing(self):
        summary, parts, client = self.cell("none", foreign=True)
        self.assertNotIn("clone", client.events)
        self.assertEqual(summary["telemetry_report"]["1"]["source"], "none")

    # --- the case ndtwin_telemetry.p4 exists for. TICKET-P3 section 9 ruling 4 -----------

    def test_a_foreign_program_that_included_the_header_gets_the_cooperative_path(self):
        # 🔴 THE WHOLE POINT OF THE INCLUDE. This switch runs the exercise's OWN program -- the
        # p4info is the compiled `basic_telemetry` fixture, which is the tutorials `basic`
        # solution plus `#include "ndtwin_telemetry.p4"` -- so `pipeline.ndtwin` is False. It
        # can nonetheless clone to the CPU port, so under `cooperative` it gets a clone session
        # and an sFlow registration exactly like an NDTwin switch. Round 1 refused it (P2 2.2's
        # frozen branch), which made the include decorative.
        summary, parts, client = self.cell("cooperative", foreign=True, include=True)
        self.assertFalse(summary["pipelines"]["1"]["ndtwin"],
                         "the fixture has to be a FOREIGN pipeline or this proves nothing")
        self.assertIn("clone", client.events)
        self.assertEqual(parts["sflow"].registered, {1: "192.168.123.11"})
        self.assertEqual(summary["telemetry"], [1])
        disclosure = summary["telemetry_report"]["1"]
        self.assertEqual(disclosure["source"], "cooperative")
        self.assertTrue(disclosure["clone_session"])
        self.assertTrue(disclosure["sflow_registered"])

    def test_that_switch_says_it_skipped_nothing(self):
        # P2 ruling 7 amended: `pipeline.skipped` is what was ACTUALLY skipped on this switch.
        # Saying `[clone_session, sflow_telemetry]` here would be false about a switch that has
        # both -- and a reader who acted on it would go looking for a telemetry fault.
        summary, _parts, _client = self.cell("cooperative", foreign=True, include=True)
        self.assertEqual(summary["pipelines"]["1"]["skipped"], [])

    def test_the_fabric_level_skips_are_unchanged_for_it(self):
        # 🔴 AND THE FABRIC-LEVEL THREE STAY. LLDP, the watchdog and the route refill are
        # skipped for ANY foreign pipeline: the refill writes `MyIngress.ipv4_lpm` by name into
        # a program that merely happens to spell it the same, and a beacon leaves one switch to
        # arrive at another. Section 9 ruling 4 moved the per-switch pair only.
        summary, _parts, _client = self.cell("cooperative", foreign=True, include=True)
        self.assertEqual(summary["control_plane"]["skipped"],
                         sorted([main.SKIP_LLDP, main.SKIP_WATCHDOG, main.SKIP_ROUTES]))

    def test_the_same_program_under_auto_is_still_link(self):
        # `auto` has not changed: it asks whose pipeline it is, not what the pipeline can do.
        # An author who includes the header and wants the cooperative path says so.
        summary, parts, client = self.cell("auto", foreign=True, include=True)
        self.assertEqual(summary["telemetry_report"]["1"]["source"], "link")
        self.assertNotIn("clone", client.events)
        self.assertEqual(parts["sflow"].registered, {})
        self.assertEqual(summary["pipelines"]["1"]["skipped"],
                         sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]))

    def test_the_same_program_under_link_gets_nothing_and_says_both_were_skipped(self):
        summary, parts, client = self.cell("link", foreign=True, include=True)
        self.assertNotIn("clone", client.events)
        self.assertEqual(summary["pipelines"]["1"]["skipped"],
                         sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]))

    def test_a_plain_foreign_program_still_says_both_were_skipped(self):
        # live-p1/02's switch, unchanged: `basic` under `auto` resolves to `link` and neither
        # step happens. The amended rule must not move this cell.
        summary, _parts, client = self.cell("auto", foreign=True)
        self.assertNotIn("clone", client.events)
        self.assertEqual(summary["pipelines"]["1"]["skipped"],
                         sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]))

    def test_the_endpoint_answers_the_same_before_startup_has_run(self):
        # `pipeline_report_for` PREDICTS the decision for the kernel's first poll, and the
        # prediction and the record come out of one function. A switch that answers
        # `[clone_session, sflow_telemetry]` before startup and `[]` afterwards would be a
        # disclosure that contradicts itself within one run.
        package = self.include_package()
        with mock.patch.object(main, "TELEMETRY_KNOB_PATH", self.knob("cooperative\n")):
            self.assertEqual(main.pipeline_report_for(1, package)["skipped"], [])
            self.assertEqual(
                main.pipeline_report_for(1, self.foreign_package())["skipped"],
                sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]),
                "a program with no controller header cannot have cooperative telemetry, so it "
                "skipped both whatever the knob says")

    def test_an_external_fabric_reports_both_skipped_whatever_the_source_says(self):
        # Under `external` nothing is programmed at all and `control_plane.skipped` carries the
        # six names. The per-switch pair stays as P2 wrote it: a switch that was not touched
        # did skip them.
        package = dataclasses.replace(self.include_package(), mode="external")
        with mock.patch.object(main, "TELEMETRY_KNOB_PATH", self.knob("cooperative\n")):
            self.assertEqual(main.pipeline_report_for(1, package)["skipped"],
                             sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]))

    def test_cooperative_on_a_foreign_pipeline_refuses_to_start(self):
        # 🔴 A REFUSAL, NOT A WARNING. Such a fabric comes up, pushes its pipelines, accepts the
        # clone session into the PRE (a clone session is a target object, so bmv2 takes it
        # against any program) and reports zero samples for the whole run with every
        # intermediate step green. The only moment that is distinguishable from an idle fabric
        # is now, and it has to be loud.
        with self.assertRaises(main.TelemetryConfigError) as cm:
            self.cell("cooperative", foreign=True)
        self.assertIn("switch 1", str(cm.exception))
        self.assertIn("ndtwin_telemetry.p4", str(cm.exception))

    def test_the_refusal_happens_before_the_pipeline_push(self):
        # Nothing is done to a fabric that will not be measurable. A refusal after the pushes
        # would leave ten switches carrying a program and no controller.
        client = FakeClient(1, packet_in_ids=None)
        with self.assertRaises(main.TelemetryConfigError):
            run_startup({1: client}, package=self.foreign_package(),
                        telemetry_knob=self.knob("cooperative\n"))
        self.assertNotIn("pipeline", client.events)

    # --- the baseline is unchanged ------------------------------------------------------

    def test_the_baseline_fabric_resolves_to_cooperative_and_behaves_as_before(self):
        # live-p1/01's assertion, in unit form: no knob, no package, NDTwin's pipeline.
        client = FakeClient(1)
        summary, parts = run_startup({1: client})
        self.assertEqual(summary["telemetry_sources"], {"1": "cooperative"})
        self.assertEqual(summary["telemetry"], [1])
        self.assertIn("clone", client.events)
        self.assertEqual(parts["sflow"].registered, {1: "192.168.123.11"})

    def test_an_external_control_plane_still_writes_nothing_whatever_the_source_says(self):
        client = FakeClient(1)
        summary, parts = run_startup({1: client}, package=external_package(),
                                     telemetry_knob=self.knob("cooperative\n"))
        self.assertNotIn("clone", client.events)
        self.assertEqual(parts["sflow"].registered, {})
        self.assertIn("external control plane", summary["telemetry_report"]["1"]["reason"])

    def test_a_switch_whose_pipeline_push_failed_gets_no_telemetry_and_says_why(self):
        client = FakeClient(1, pipeline_error=RuntimeError("switch is down"))
        summary, _ = run_startup({1: client})
        self.assertNotIn("clone", client.events)
        self.assertIn("pipeline push failed", summary["telemetry_report"]["1"]["reason"])

    def test_a_switch_with_no_agent_ip_is_told_apart_from_one_that_was_switched_off(self):
        client = FakeClient(1)
        summary, _ = run_startup({1: client}, agent_ips={})
        self.assertEqual(summary["telemetry_report"]["1"]["source"], "cooperative")
        self.assertIn("no IP in the topology file", summary["telemetry_report"]["1"]["reason"])

    def test_a_clone_session_that_fails_is_registered_but_not_sampling(self):
        # The loudest case: the emitter knows the agent, the switch will never send anything.
        client = FakeClient(1, clone_ok=False)
        summary, parts = run_startup({1: client})
        disclosure = summary["telemetry_report"]["1"]
        self.assertFalse(disclosure["clone_session"])
        self.assertTrue(disclosure["sflow_registered"])
        self.assertEqual(parts["sflow"].registered, {1: "192.168.123.11"})


class TheOneImplementationTest(unittest.TestCase):
    """
    `main._telemetry_source` and `app_package.telemetry_source` answer the same thing. Always.

    [Co-developed with claude code -- Adam]
    🔴 THIS TEST IS TRIVIALLY TRUE TODAY, AND THAT IS WHY IT EXISTS (TICKET-P3 section 9 ruling
    5). Round 1 had two implementations of one rule -- section 2.1 required it, so that neither
    ticket blocked on the other -- and the arrangement worked exactly as intended right up to
    the moment nobody collapsed them. `main._telemetry_source` is one line of delegation now, so
    every cell below passes by construction. What the grid catches is the DAY SOMEBODY RE-FORKS
    IT: a branch added on the proxy side "just for this case" reddens here, which is the only
    place that would notice. A one-off reconciliation done at merge time would not have been.

    🔴 AND IT IS A GRID, not one call. The rule has three layers and a per-switch tail, so a
    fork that agreed about the knob and disagreed about `auto` would pass a single comparison.
    """

    #: Everything a package may declare, everything the knob may say, and both kinds of switch.
    DECLARATIONS = (None, "auto", "none", "cooperative", "link")
    KNOB_WORDS = (None, "auto", "none", "cooperative", "link")

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_one_impl_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def knob_path(self, word):
        if word is None:
            return os.path.join(self.tmp, "absent")
        path = os.path.join(self.tmp, "telemetry_override")
        with open(path, "w") as fh:
            fh.write(word + "\n")
        return path

    def packages(self):
        """(label, package, dpid) for an NDTwin switch and a foreign one."""
        foreign = app_package.Package(
            dir="/packages/basic", name="basic",
            switches=(app_package.SwitchSpec(dpid=1, name="s1",
                                             pipeline=PLAIN_FOREIGN_PIPELINE,
                                             entries=None, entries_recorded=0),))
        return (("ndtwin", app_package.baseline(), 1), ("foreign", foreign, 1))

    def test_every_cell_of_the_grid_agrees(self):
        checked = 0
        for label, package, dpid in self.packages():
            for declared in self.DECLARATIONS:
                declaring = (package if declared is None
                             else dataclasses.replace(package, telemetry_source=declared))
                for word in self.KNOB_WORDS:
                    knob = self.knob_path(word)
                    with self.subTest(pipeline=label, declared=declared, knob=word):
                        mine = main._telemetry_source(declaring, dpid, knob_path=knob)
                        theirs = app_package.telemetry_source(
                            declaring, dpid, knob_path=knob,
                            base_dir=main.proxy_root())
                        self.assertEqual(mine, theirs)
                        self.assertIn(mine, main.TELEMETRY_SOURCES,
                                      "a resolved source is never `auto`")
                        checked += 1
        self.assertEqual(checked, 2 * len(self.DECLARATIONS) * len(self.KNOB_WORDS))

    def test_the_two_modules_name_the_same_knob_file(self):
        # Three processes agreeing on a word cannot agree on it through two different files.
        self.assertEqual(main.TELEMETRY_KNOB_PATH, app_package.TELEMETRY_KNOB_PATH)

    def test_the_words_are_the_same_objects_not_equal_copies(self):
        # Re-exported, not re-spelled. A second `"link"` here would be free to stop agreeing,
        # and the disagreement would present as a fabric counting every packet twice.
        self.assertIs(main.TELEMETRY_COOPERATIVE, app_package.TELEMETRY_COOPERATIVE)
        self.assertIs(main.TELEMETRY_LINK, app_package.TELEMETRY_LINK)
        self.assertIs(main.TELEMETRY_NONE, app_package.TELEMETRY_NONE)
        self.assertIs(main.TELEMETRY_AUTO, app_package.TELEMETRY_AUTO)
        self.assertEqual(tuple(main.TELEMETRY_SOURCES), tuple(app_package.TELEMETRY_RESOLVED))
        self.assertEqual(tuple(main.TELEMETRY_WORDS), tuple(app_package.TELEMETRY_SOURCES))

    def test_the_proxy_does_not_carry_its_own_copy_of_the_rule(self):
        # 🔴 A STRUCTURAL ASSERTION, because the grid above passes for a fork that HAPPENS to
        # agree -- and a fork that agrees today is the one that stops agreeing quietly. The
        # proxy's function body must be a delegation: no knob file is opened on this side, and
        # no `pipeline_is_ndtwin` branch is taken on this side.
        import inspect
        body = inspect.getsource(main._telemetry_source)
        self.assertIn("app_package.telemetry_source", body)
        self.assertNotIn("pipeline_is_ndtwin", body,
                         "the `auto` rule belongs to app_package; a copy here is a second "
                         "implementation whatever it currently answers")


class ThePackagesPreEntriesAtStartupTest(unittest.TestCase):
    """TICKET-P3 2.6 (G9a): the multicast groups and clone sessions a package declares."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_pre_entries_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.saved = (dict(main._pipelines), dict(main._table_entries), dict(main._telemetry),
                      dict(main._pre_entries))
        self.addCleanup(self.restore)

    def restore(self):
        for live, saved in ((main._pipelines, self.saved[0]),
                            (main._table_entries, self.saved[1]),
                            (main._telemetry, self.saved[2]),
                            (main._pre_entries, self.saved[3])):
            live.clear()
            live.update(saved)

    def package(self, doc, pipeline=None):
        path = os.path.join(self.tmp, "s1-runtime.json")
        with open(path, "w") as fh:
            json.dump(doc, fh)
        spec = app_package.SwitchSpec(dpid=1, name="s1", pipeline=pipeline, entries=path,
                                      entries_recorded=len(doc.get("table_entries") or []))
        return app_package.Package(dir="/packages/multicast", name="multicast",
                                   switches=(spec,))

    MULTICAST = {"table_entries": [],
                 "multicast_group_entries": [
                     {"multicast_group_id": 1,
                      "replicas": [{"egress_port": 1, "instance": 1},
                                   {"egress_port": 2, "instance": 1}]}]}

    def test_a_declared_group_is_programmed_on_ndtwins_own_pipeline_too(self):
        # 🔴 THE ONE PLACE PRE ENTRIES DIFFER FROM TABLE ENTRIES. A package's table entries name
        # tables inside the exercise's program and are deliberately NOT applied on our pipeline;
        # a multicast group is a target object with no program in it, so `mcast_grp 1 -> 1,2`
        # means the same thing under either. A package built with `convert --ndtwin-pipeline`
        # (live-p1/02's case) would otherwise lose its groups silently.
        client = FakeClient(1)
        summary, _ = run_startup({1: client}, package=self.package(self.MULTICAST))
        self.assertEqual(client.multicast_groups,
                         [(1, [{"egress_port": 1, "instance": 1},
                               {"egress_port": 2, "instance": 1}], "insert")])
        self.assertEqual(summary["pre_entries"]["1"]["multicast"],
                         {"recorded": 1, "applied": 1, "failed": 0})

    def test_a_refused_group_is_counted_as_failed(self):
        client = FakeClient(1, multicast_ok=False)
        summary, _ = run_startup({1: client}, package=self.package(self.MULTICAST))
        self.assertEqual(summary["pre_entries"]["1"]["multicast"],
                         {"recorded": 1, "applied": 0, "failed": 1})
        self.assertIn("1", summary["entry_errors"])

    def test_a_baseline_fabric_declares_none_and_writes_none(self):
        client = FakeClient(1)
        summary, _ = run_startup({1: client})
        self.assertEqual(client.multicast_groups, [])
        self.assertEqual(summary["pre_entries"]["1"],
                         {"multicast": {"recorded": 0, "applied": 0, "failed": 0},
                          "clone": {"recorded": 0, "applied": 0, "failed": 0}})

    def test_a_switch_whose_pipeline_push_failed_gets_no_pre_entries(self):
        # There is no PRE to program them into, and a group written into a switch with no
        # pipeline would be counted as applied.
        client = FakeClient(1, pipeline_error=RuntimeError("down"))
        summary, _ = run_startup({1: client}, package=self.package(self.MULTICAST))
        self.assertEqual(client.multicast_groups, [])
        self.assertEqual(summary["pre_entries"]["1"]["multicast"]["applied"], 0)

    def test_an_external_control_plane_programs_none_of_them(self):
        client = FakeClient(1)
        package = self.package(self.MULTICAST)
        external = type(package)(**{f.name: getattr(package, f.name)
                                    for f in dataclasses.fields(package)} | {"mode": "external"})
        summary, _ = run_startup({1: client}, package=external)
        self.assertEqual(client.multicast_groups, [])
        self.assertEqual(summary["pre_entries"]["1"]["multicast"]["applied"], 0)

    def test_a_declared_clone_session_is_programmed_with_its_own_id(self):
        doc = {"table_entries": [],
               "clone_session_entries": [{"clone_session_id": 57,
                                          "replicas": [{"egress_port": 510, "instance": 1}]}]}
        client = FakeClient(1)
        summary, _ = run_startup({1: client}, package=self.package(doc))
        self.assertIn((57, [{"egress_port": 510, "instance": 1}]), client.clone_sessions)
        self.assertEqual(summary["pre_entries"]["1"]["clone"],
                         {"recorded": 1, "applied": 1, "failed": 0})

    def test_the_proxys_own_clone_session_is_written_after_the_packages(self):
        # Order matters: if a package declares session 250 as well, OUR write has to be the last
        # one, or this proxy's telemetry is whatever the exercise decided it should be.
        doc = {"table_entries": [],
               "clone_session_entries": [{"clone_session_id": 250,
                                          "replicas": [{"egress_port": 9, "instance": 1}]}]}
        client = FakeClient(1)
        run_startup({1: client}, package=self.package(doc))
        self.assertEqual(client.clone_sessions[-1], (None, None),
                         "the proxy's own default clone session must be the last PRE write")


if __name__ == "__main__":
    unittest.main()
