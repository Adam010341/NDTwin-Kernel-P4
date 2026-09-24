"""
Tests for Phase 7 powerOn's proxy half: readopt_switch, per-dpid route reinstall, the
POST /p4/readopt/{dpid} endpoint, and write_manifest's atomic replacement.

[Co-developed with claude code -- Adam]

Expected behaviour is taken from decision 2 of doc/2026-08-11_phase7_power_mechanism_design.md -- a
restarted bmv2 has no pipeline, no clone session, no mastership and no routes, and liveness
cannot tell -- and from Phase 7 of doc/2026-07-27_p4_bmv2_support_plan.md. Not from reading
readopt_switch and writing down what it does. The required sequence is the design's:
callbacks wired before start, a mastership settle before the pipeline push, the clone
session only after the pipeline it lives in, the old client left in place on failure so the
switch keeps reporting Down rather than vanishing, and a per-dpid route reinstall. The HTTP
mappings (404 unknown / 502 failed / 503 unwired) are the design's too.

The settle is observed by patching time.sleep to *record* instead of wait, for the reason
test_link_watchdog gives about its injected clock: a settle tested by sleeping through it is
a test nobody runs.

write_manifest lives in p4_proxy/mininet/p4_testbed_topo.py, which imports mininet at module
level; the venv does not have mininet, so stub modules are injected before loading it. The
stubs stand in for nothing under test -- write_manifest touches only json/os/tempfile.

Run:  cd p4_proxy && PYTHONPATH=. venv/bin/python tests/test_readopt.py -v
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import signal
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

#: The two real compiled p4infos TICKET-P3 section 9 ruling 4's decision rests on: `basic`
#: declares no controller header, `basic_telemetry` is the same solution with
#: `#include "ndtwin_telemetry.p4"`. Absolute, because a per-switch pipeline is passed through
#: `Package.pipeline_for` untouched when it already is. [Co-developed with claude code -- Adam]
_FIXTURES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "tools", "p4_exercise", "tests", "fixtures")
PLAIN_FOREIGN_PIPELINE = (os.path.join(_FIXTURES, "basic", "build", "basic.p4.p4info.txtpb"),
                          os.path.join(_FIXTURES, "basic", "build", "basic.json"))
TELEMETRY_FOREIGN_PIPELINE = (
    os.path.join(_FIXTURES, "basic_telemetry", "build", "basic_telemetry.p4.p4info.txtpb"),
    os.path.join(_FIXTURES, "basic_telemetry", "build", "basic_telemetry.json"))

from fastapi import HTTPException  # noqa: E402

from proxy_agent import api_routes, topology_manager  # noqa: E402
from proxy_agent.topology_manager import TopologyManager  # noqa: E402
# [Co-developed with claude code -- Adam]
# TICKET-P2 4.2: the endpoint goes through main.readopt_switch now, because what a foreign
# pipeline changes about a re-adoption is package knowledge. Guarded the way
# test_app_package_proxy.py guards it -- main pulls in the P4Runtime protobufs, and an
# interpreter without them should report a skip rather than crash the whole file's import.
try:
    import proxy_agent.main as main  # noqa: E402
except ImportError:  # pragma: no cover -- environment, not behaviour
    main = None

H1, H2 = "10.0.50.1", "10.0.50.2"


class FakeClient:
    """
    A P4RuntimeClient double that records the order things happened to it and can fail on
    demand at each independent step. Shape follows test_startup.FakeClient; `log` is shared
    across clients so cross-client ordering is observable.
    """

    def __init__(self, dpid, log=None, start_error=None, pipeline_error=None,
                 clone_ok=True, route_ok=True, mastership_confirmed=True, arbitration=True):
        self.dpid = dpid
        # [Co-developed with claude code -- Adam]
        # Whether this client may drive the switch at all. Declared rather than left to a
        # getattr default on readopt's side: a double that has stopped standing in for the real
        # object should fail with AttributeError, and a permissive default in the production
        # code is a branch that can be silently skipped -- this repo's most-repeated shape.
        # False is what an `external` app package builds (P4RuntimeClient(arbitration=False)).
        self.arbitration = arbitration
        self.log = log if log is not None else []
        self.start_error = start_error
        self.pipeline_error = pipeline_error
        self.clone_ok = clone_ok
        self.route_ok = route_ok
        # True is the power-cycle default this endpoint was designed for: the old process is
        # gone, so a fresh arbitration is granted. False models the live 2026-08-13 shape --
        # readopt against a healthy switch whose old client still held mastership.
        self.mastership_confirmed = mastership_confirmed
        self.packet_in_callback = None
        self.sample_callback = None
        self.callback_at_start = None
        self.sample_at_start = None
        self.stopped = False
        self.routes = []

    def start(self, push_config=True):
        self.log.append(("start", self.dpid, push_config))
        self.callback_at_start = self.packet_in_callback
        self.sample_at_start = self.sample_callback
        if self.start_error is not None:
            raise self.start_error

    def set_forwarding_pipeline_config(self):
        self.log.append(("pipeline", self.dpid))
        if self.pipeline_error is not None:
            raise self.pipeline_error

    def write_clone_session(self):
        self.log.append(("clone", self.dpid))
        return self.clone_ok

    def stop(self):
        self.stopped = True
        self.log.append(("stop", self.dpid))

    def insert_ipv4_route(self, dst_ip, prefix_len, mac, port):
        self.routes.append((dst_ip, prefix_len, mac, port))
        return self.route_ok


def sample_sink(*args, **kwargs):
    """Stands in for SFlowEmitter.handle_sample."""


def build_topology():
    """
    Two switches in a line, one host on each:  h1 -- s1 -- s2 -- h2.
    Small enough that the full expected route set can be written out by hand: each switch
    routes to both hosts, so a per-dpid reinstall is exactly two rules.
    """
    topo = TopologyManager()
    old1, old2 = FakeClient(1), FakeClient(2)
    topo.add_switch(1, old1)
    topo.add_switch(2, old2)
    topo.add_link(1, 2, src_port=2, dst_port=2)
    topo.add_host(H1, "00:00:00:00:50:01", 1, 1)
    topo.add_host(H2, "00:00:00:00:50:02", 2, 1)
    return topo, old1, old2


class RecordingSleep:
    """Replaces time.sleep inside topology_manager for a test: records, never waits."""

    def __init__(self, log):
        self.log = log

    def __call__(self, seconds):
        self.log.append(("settle", seconds))


class ReadoptTestBase(unittest.TestCase):
    def setUp(self):
        self.topo, self.old1, self.old2 = build_topology()
        self.log = []
        self._real_sleep = topology_manager.time.sleep
        topology_manager.time.sleep = RecordingSleep(self.log)
        self.addCleanup(self._restore_sleep)
        self.made = []

    def _restore_sleep(self):
        topology_manager.time.sleep = self._real_sleep

    def factory(self, **client_kwargs):
        def make(dpid):
            client = FakeClient(dpid, log=self.log, **client_kwargs)
            self.made.append(client)
            return client
        return make

    def factory_that_raises(self, exc=None):
        """A client_factory that dies before producing a client -- readopt's first step."""
        def make(dpid):
            raise exc or RuntimeError("no p4info on disk")
        return make

    def readopt(self, dpid=1, factory=None, callback=sample_sink, settle_s=0.25):
        return self.topo.readopt_switch(dpid, factory or self.factory(),
                                        callback, settle_s=settle_s)


class ReadoptSequenceTest(ReadoptTestBase):
    def test_an_unknown_dpid_is_reported_not_invented(self):
        calls = []

        def factory(dpid):
            calls.append(dpid)
            return FakeClient(dpid)

        result = self.topo.readopt_switch(99, factory, sample_sink, settle_s=0)
        self.assertEqual(result["status"], "unknown-switch")
        self.assertEqual(calls, [], "no client may be built for a switch startup never "
                                    "established; readopt replaces a connection, it does "
                                    "not create one")

    def test_the_sequence_is_start_settle_pipeline_then_clone(self):
        # The design's ordering, each arrow load-bearing: a pipeline pushed before
        # mastership settles is rejected, and a clone session programmed before the
        # pipeline is silently discarded -- the switch would forward but report zero
        # traffic forever.
        self.readopt(settle_s=0.25)
        steps = [e for e in self.log if e[0] in ("start", "settle", "pipeline", "clone")]
        self.assertEqual(steps, [("start", 1, False), ("settle", 0.25),
                                 ("pipeline", 1), ("clone", 1)])

    def test_start_does_not_ask_the_client_to_push_config_itself(self):
        # start(push_config=False): the settle must happen between arbitration and the
        # push, which is only possible if start() does not push on its own.
        self.readopt()
        starts = [e for e in self.log if e[0] == "start"]
        self.assertEqual(starts, [("start", 1, False)])

    def test_the_packet_in_callback_is_wired_before_start(self):
        # The receiver thread runs from the moment the stream opens; a callback wired
        # after start() loses whatever arrives in the gap.
        self.readopt()
        # assertEqual, not assertIs: each attribute access mints a new bound-method object,
        # and bound methods compare equal iff function and instance both match.
        self.assertEqual(self.made[0].callback_at_start, self.topo.handle_packet_in)

    def test_the_sample_callback_is_wired_before_start(self):
        self.readopt(callback=sample_sink)
        self.assertIs(self.made[0].sample_at_start, sample_sink)


class ReadoptSuccessTest(ReadoptTestBase):
    def test_success_reports_status_clone_and_route_count(self):
        result = self.readopt()
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dpid"], 1)
        self.assertIs(result["clone_session"], True)
        self.assertEqual(result["routes_installed"], 2)

    def test_success_swaps_the_new_client_into_the_switch_map(self):
        self.readopt()
        self.assertIs(self.topo.switches[1], self.made[0],
                      "liveness and every write path read self.switches; without the swap "
                      "they keep talking to the dead connection")

    def test_success_stops_the_old_client(self):
        self.readopt()
        self.assertTrue(self.old1.stopped,
                        "the replaced client keeps a receiver thread and a channel; "
                        "leaking one per power cycle is a slow strangulation")

    def test_readopt_reinstalls_routes_on_that_switch_only(self):
        # The design: the restarted switch's tables are empty, the other switches' are
        # not, and rewriting theirs is forty gRPC round trips of nothing.
        self.readopt(dpid=1)
        new = self.made[0]
        self.assertEqual(sorted(r[0] for r in new.routes), sorted([H1, H2]),
                         "the readopted switch must be told how to reach every host")
        self.assertEqual(self.old2.routes, [],
                         "the other switch's tables were rewritten during a readopt of "
                         "switch 1")

    def test_a_failed_clone_session_costs_telemetry_not_the_switch(self):
        # Same policy as startup: no clone session means zero reported traffic, not a
        # dead switch -- but the caller must be told, or nobody ever fixes it.
        result = self.readopt(factory=self.factory(clone_ok=False))
        self.assertEqual(result["status"], "success")
        self.assertIn("clone_session", result)
        self.assertFalse(result["clone_session"])
        self.assertIs(self.topo.switches[1], self.made[0])


class ReadoptFailureTest(ReadoptTestBase):
    def assert_switch_kept_old_client(self):
        self.assertIs(self.topo.switches[1], self.old1,
                      "on failure the old client must stay in place: the liveness poller "
                      "keeps probing it, so the switch keeps reporting Down instead of "
                      "vanishing or reporting Up on a pipeline-less process")
        self.assertFalse(self.old1.stopped,
                         "the old client is what liveness still probes; stopping it on a "
                         "failed readopt would kill that evidence")

    def test_a_factory_that_raises_is_a_reported_failure(self):
        def factory(dpid):
            raise RuntimeError("no p4info on disk")

        result = self.topo.readopt_switch(1, factory, sample_sink, settle_s=0)
        self.assertEqual(result["status"], "failed")
        self.assert_switch_kept_old_client()

    def test_a_failed_start_keeps_the_old_client_in_place(self):
        result = self.readopt(factory=self.factory(start_error=RuntimeError("no stream")))
        self.assertEqual(result["status"], "failed")
        self.assert_switch_kept_old_client()

    def test_a_failed_pipeline_push_keeps_the_old_client_and_installs_nothing(self):
        result = self.readopt(factory=self.factory(pipeline_error=RuntimeError("rejected")))
        self.assertEqual(result["status"], "failed")
        self.assert_switch_kept_old_client()
        self.assertEqual(self.made[0].routes, [],
                         "routes must not be written through a client whose pipeline "
                         "never loaded; bmv2 would accept them into nothing")
        self.assertEqual([e for e in self.log if e[0] == "clone"], [],
                         "there is no PRE to program a clone session into without a "
                         "pipeline")

    def test_a_failure_names_the_step_it_died_at(self):
        # Decision 2, item 5: "report how far it got, and which step failed" -- the kernel's
        # log line is built from this.
        #
        # [Co-developed with claude code -- Adam]
        # This asserted only assertIn("step", result), which is key presence, not an answer:
        # labelling every failure the same thing satisfies it while the operator is sent to
        # the wrong place. The value is the deliverable here, so the value is what is pinned.
        #
        # "pipeline" rather than any other spelling because it is a wire token, not an
        # internal name: api_routes.readopt puts this dict straight into the 502 detail, the
        # kernel logs it, and ReadoptEndpointTest.test_a_failed_readopt_is_502_carrying_the_step
        # asserts the endpoint surfaces exactly "pipeline". That test feeds a canned dict, so
        # without this one the two halves of the same contract are free to disagree: the
        # endpoint would keep proving it forwards a token nothing produces.
        result = self.readopt(factory=self.factory(pipeline_error=RuntimeError("rejected")))
        self.assertEqual(result["step"], "pipeline",
                         "the pipeline push is what failed, so that is the step to name")
        self.assertIn("error", result)
        self.assertIn("RuntimeError", result["error"],
                      "the exception type is half the diagnosis; 'rejected' alone does not "
                      "distinguish a refused config from an unreachable switch")

    def test_a_failure_before_the_client_exists_names_a_different_step(self):
        # Decision 2's sequence starts by building a *new* client; that is where a missing
        # p4info or a bad address dies, before any RPC is attempted. Reporting it as the same
        # step as a pipeline failure would send someone to look at the switch for a fault
        # that is on this host.
        def factory(dpid):
            raise RuntimeError("no p4info on disk")

        result = self.topo.readopt_switch(1, factory, sample_sink, settle_s=0)
        self.assertEqual(result["step"], "build")

    def test_the_two_failure_points_are_not_given_the_same_label(self):
        # The property behind both assertions above, stated without their literals: whatever
        # the vocabulary, "which step failed" is only reported if the answers differ. A single
        # constant everywhere passes every key-presence check ever written.
        build = self.topo.readopt_switch(
            1, self.factory_that_raises(), sample_sink, settle_s=0)
        pipeline = self.readopt(factory=self.factory(pipeline_error=RuntimeError("rejected")))

        self.assertEqual(build["status"], "failed")
        self.assertEqual(pipeline["status"], "failed")
        self.assertNotEqual(build["step"], pipeline["step"],
                            "both failure paths report the same step, so the report cannot "
                            "say which one happened")

    def test_a_failed_start_is_reported_as_the_pipeline_step(self):
        # [Co-developed with claude code -- Adam]
        # Recording current behaviour rather than endorsing it, in the style of
        # test_OvsPowerStrategy.cpp's empty-bridge test. start() raising means arbitration or
        # the stream died -- the design lists that as its own arrow, before the settle and the
        # push -- but it shares an except block with set_forwarding_pipeline_config, so it
        # reports "pipeline". An operator reading that goes looking at the p4info and the
        # switch's config rather than at the gRPC stream.
        #
        # Not changed here: this file is a test file, and relabelling is a production change.
        # If a fix lands, this expectation is the one to change.
        result = self.readopt(factory=self.factory(start_error=RuntimeError("no stream")))
        self.assertEqual(result["step"], "pipeline")


class ReadoptMastershipGateTest(ReadoptTestBase):
    """
    The destructive gate added 2026-08-13. A readopt against a *healthy* switch meant the old
    client still held mastership. Because every client bids the same hardcoded election_id
    (0, 1), the new client presented the incumbent's own credentials: bmv2 killed its
    duplicate stream (so its arbitration was refused) yet still applied its pipeline push,
    wiping every table. The route writes then failed with "Not primary" -- not because Write
    is checked more strictly, but because old.stop() runs before install_initial_routes, so
    no primary was left by then. readopt therefore wiped a working switch, installed nothing,
    and reported success. Observed live on s1 and s6.

    The expectations below are unchanged by that correction, and the gate is still the right
    fix: a client that did not win arbitration must not reach the destructive push.
    doc/2026-08-13_p4runtime-mastership-spec-check.md has the measured scenarios.
    """

    def test_refused_arbitration_fails_before_the_pipeline_push(self):
        result = self.readopt(factory=self.factory(mastership_confirmed=False))
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["step"], "mastership")
        self.assertNotIn(("pipeline", 1), self.log,
                         "the pipeline push wipes every table on the switch; a client that "
                         "never became primary must not reach it")

    def test_refused_arbitration_keeps_the_old_client_in_place(self):
        self.readopt(factory=self.factory(mastership_confirmed=False))
        self.assertIs(self.topo.switches[1], self.old1,
                      "the old client may still be primary and forwarding fine; swapping in "
                      "a non-primary client would darken a healthy switch")
        self.assertTrue(self.made[0].stopped,
                        "the refused client still holds a channel and a receiver thread")

    def test_all_route_writes_refused_is_a_failure_not_a_success(self):
        result = self.readopt(factory=self.factory(route_ok=False))
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["step"], "routes")
        self.assertIn("refused all 2", result["error"])

    def test_zero_attempted_routes_is_still_success(self):
        # The documented honest-zero: nothing is routable right now (the watchdog may hold
        # this switch's links down until its beacons resume), and the watchdog's recovery
        # path reinstalls. Modelled structurally: no hosts, so no rule is even wanted.
        self.topo.net.remove_node(H1)
        self.topo.net.remove_node(H2)
        result = self.readopt()
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["routes_installed"], 0)
        self.assertEqual(result["routes_attempted"], 0)

    def test_zero_attempted_says_the_routes_are_pending(self):
        # Live 2026-08-13: a power-cycled switch was readopted 2 s after boot, before its
        # beacons resumed, so nothing was routable and this returned a bare 200 while the
        # switch held no rules at all -- the watchdog installed them ~30 s later. Success is
        # the right status (adoption did work), but the caller must be able to tell "adopted
        # and forwarding" from "adopted, tables still empty".
        self.topo.net.remove_node(H1)
        self.topo.net.remove_node(H2)
        result = self.readopt()
        self.assertIs(result["routes_pending"], True)
        self.assertIn("links", result["note"])

    def test_installed_routes_are_not_reported_as_pending(self):
        result = self.readopt()
        self.assertEqual(result["routes_attempted"], 2)
        self.assertNotIn("routes_pending", result,
                         "a switch that took its routes must not look like it is waiting")
        self.assertNotIn("note", result)


class ReadoptUnderAnExternalControlPlaneTest(ReadoptTestBase):
    """
    [Co-developed with claude code -- Adam]

    A fabric running `control_plane.mode: external` cannot be readopted: the exercise's own
    controller holds mastership and this proxy's clients bid for nothing. Failing closed was
    already true by accident -- an arbitration-less client never sets `mastership_confirmed`,
    so the gate above caught it -- but it answered `step: "mastership"` with "the old client
    (or another controller) likely still holds mastership", which describes a RACE THIS PROXY
    LOST. What actually happened is that it was configured never to enter the race. An
    operator acts differently on those two: the first says retry or power-cycle, the second
    says this is the mode you asked for.

    So the same outcome is reached by a check that names itself, placed before the gate. Found
    by the P1-A judge against c3ecf7f8 -- the SUMMARY had claimed readopt failed at the
    *pipeline* step, and it never got that far.
    """

    def external(self):
        return self.readopt(factory=self.factory(arbitration=False,
                                                 mastership_confirmed=False))

    def test_readopt_under_an_external_control_plane_says_so(self):
        result = self.external()
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["step"], "control_plane")
        self.assertIn("external control plane", result["error"])
        self.assertIn("read-only", result["error"])

    def test_it_does_not_blame_a_mastership_race_it_never_entered(self):
        # 🔴 The whole point. `step: "mastership"` here would send an operator looking for
        # another controller, or power-cycling a switch that is behaving exactly as configured.
        result = self.external()
        self.assertNotEqual(result["step"], "mastership")
        self.assertNotIn("likely still holds mastership", result["error"])

    def test_it_never_reaches_the_pipeline_push(self):
        self.external()
        self.assertNotIn(("pipeline", 1), self.log,
                         "the pipeline push empties every table the exercise's own controller "
                         "installed, and reports success while doing it")

    def test_it_installs_no_routes(self):
        self.external()
        self.assertEqual(self.made[0].routes, [],
                         "install_initial_routes would write into somebody else's tables")
        self.assertEqual(self.topo._installed_routes, {})

    def test_it_programs_no_clone_session(self):
        self.external()
        self.assertNotIn(("clone", 1), self.log)

    def test_the_old_client_stays_in_place(self):
        self.external()
        self.assertIs(self.topo.switches[1], self.old1)

    def test_the_client_it_built_is_torn_down_rather_than_left_holding_a_channel(self):
        self.external()
        self.assertTrue(self.made[0].stopped,
                        "a client readopt refuses to use still owns a gRPC channel and, on the "
                        "real object, a subchannel pool entry for that address")

    def test_an_arbitrating_client_is_unaffected(self):
        # The negative half: `arbitration` is what switches this on, not "readopt was called".
        result = self.readopt(factory=self.factory())
        self.assertEqual(result["status"], "success")
        self.assertIn(("pipeline", 1), self.log)


class RouteReinstallTest(unittest.TestCase):
    """install_initial_routes(only_dpid=...) directly, the seam readopt relies on."""

    def setUp(self):
        self.topo, self.c1, self.c2 = build_topology()

    def test_only_dpid_writes_to_that_switch_and_no_other(self):
        installed, attempted = self.topo.install_initial_routes(only_dpid=1)
        self.assertEqual(sorted(r[0] for r in self.c1.routes), sorted([H1, H2]))
        self.assertEqual(self.c2.routes, [])
        self.assertEqual(installed, 2)
        self.assertEqual(attempted, 2)

    def test_the_count_is_rules_the_switches_accepted_not_rules_attempted(self):
        # An honest count is the point: a refused write reported as installed is the same
        # "silent success" shape this repo keeps digging out.
        self.c1.route_ok = False
        installed, attempted = self.topo.install_initial_routes()
        self.assertEqual(sorted(r[0] for r in self.c2.routes), sorted([H1, H2]),
                         "switch 2's rules must still be attempted and counted")
        self.assertEqual(installed, 2,
                         "switch 1 refused both writes; counting them anyway tells the "
                         "caller routes exist while packets drop")
        self.assertEqual(attempted, 4,
                         "attempted counts what was tried; the gap between it and installed "
                         "is the refusal signal readopt reads")


class SentinelFactory:
    """Recording readopt_switch stand-in for the endpoint tests, plus canned results."""

    def __init__(self, result):
        self.result = result
        self.calls = []

    def readopt_switch(self, dpid, client_factory, sample_callback, settle_s=1.0):
        self.calls.append((dpid, client_factory, sample_callback))
        return self.result


def make_factory(dpid):
    raise AssertionError("the endpoint must pass the factory through, not call it")


def plain_runner(topology, dpid, client_factory, sample_callback):
    """What main.readopt_switch reduces to on a fabric with no foreign pipeline.

    [Co-developed with claude code -- Adam]
    The endpoint no longer calls the TopologyManager directly -- main.py wraps it, because what
    a foreign pipeline changes is package knowledge. These tests are about the endpoint's status
    codes, so the wrapper here is the identity one; ThePackageHalfOfReadoptTest below drives the
    real wrapper.
    """
    return topology.readopt_switch(dpid, client_factory, sample_callback)


class ReadoptEndpointTest(unittest.TestCase):
    """
    POST /p4/readopt/{dpid}. The handler is called directly, per the convention
    test_flow_stats_route.py states: it reads only its argument and module globals, so the
    routing layer would add a dependency without adding coverage.
    """

    def tearDown(self):
        api_routes.topology = None
        api_routes.readopt_client_factory = None
        api_routes.readopt_sample_callback = None
        api_routes.readopt_runner = None

    def wire(self, result):
        fake = SentinelFactory(result)
        api_routes.topology = fake
        api_routes.inject_readopt(make_factory, sample_sink, plain_runner)
        return fake

    def test_no_topology_is_503(self):
        api_routes.topology = None
        api_routes.inject_readopt(make_factory, sample_sink, plain_runner)
        with self.assertRaises(HTTPException) as ctx:
            api_routes.readopt(1)
        self.assertEqual(ctx.exception.status_code, 503)

    def test_an_unwired_runner_is_503_as_well(self):
        # [Co-developed with claude code -- Adam]
        # The wrapper is a third injected piece and it is not optional: without it there is
        # nobody to decide whether this switch may have a clone session. A None here used to be
        # reachable only as an AttributeError -- a 500, which the kernel reads as a proxy bug
        # rather than as the restart window it actually is.
        api_routes.topology = SentinelFactory({"status": "success"})
        api_routes.inject_readopt(make_factory, sample_sink, plain_runner)
        api_routes.readopt_runner = None
        with self.assertRaises(HTTPException) as ctx:
            api_routes.readopt(1)
        self.assertEqual(ctx.exception.status_code, 503)
        self.assertIn("wired", str(ctx.exception.detail))

    def test_unwired_factory_is_503_and_says_so(self):
        # The kernel retries a 503; a 500 looks like a bug in the proxy. "Not wired yet"
        # is the proxy-restart window, and it must be distinguishable.
        api_routes.topology = SentinelFactory({"status": "success"})
        # The runner IS injected, so the 503 below can only be the missing factory -- without
        # this line both halves are None and the test would pass whichever branch fired.
        # [Co-developed with claude code -- Adam]
        api_routes.inject_readopt(make_factory, sample_sink, plain_runner)
        api_routes.readopt_client_factory = None
        with self.assertRaises(HTTPException) as ctx:
            api_routes.readopt(1)
        self.assertEqual(ctx.exception.status_code, 503)
        self.assertIn("wired", str(ctx.exception.detail))

    def test_an_unknown_switch_is_404_carrying_the_result(self):
        self.wire({"status": "unknown-switch", "dpid": 99})
        with self.assertRaises(HTTPException) as ctx:
            api_routes.readopt(99)
        self.assertEqual(ctx.exception.status_code, 404)
        self.assertEqual(ctx.exception.detail.get("status"), "unknown-switch")

    def test_a_failed_readopt_is_502_carrying_the_step(self):
        self.wire({"status": "failed", "step": "pipeline", "error": "rejected"})
        with self.assertRaises(HTTPException) as ctx:
            api_routes.readopt(1)
        self.assertEqual(ctx.exception.status_code, 502)
        self.assertEqual(ctx.exception.detail.get("step"), "pipeline")

    def test_success_returns_the_result_body_unmodified(self):
        body = {"status": "success", "dpid": 1, "clone_session": True,
                "routes_installed": 2}
        self.wire(dict(body))
        self.assertEqual(api_routes.readopt(1), body,
                         "the kernel reads routes_installed and clone_session from this "
                         "body; a bare status would hide a zero-route readopt")

    def test_the_injected_factory_and_callback_are_passed_through(self):
        fake = self.wire({"status": "success"})
        api_routes.readopt(1)
        self.assertEqual(len(fake.calls), 1)
        dpid, factory, callback = fake.calls[0]
        self.assertEqual(dpid, 1)
        self.assertIs(factory, make_factory)
        self.assertIs(callback, sample_sink)


# --- the package's half of readopt (TICKET-P2 4.2) -------------------------------------


class ThePackageHalfOfReadoptTest(unittest.TestCase):
    """
    `main.readopt_switch`, the wrapper POST /p4/readopt/{dpid} now goes through.

    [Co-developed with claude code -- Adam]
    A readopt pushes a pipeline, and a pipeline push empties every table on the switch
    (KNOWN-ISSUES A-4c). On NDTwin's own pipeline `install_initial_routes` refills what matters
    and nothing else was there. On a FOREIGN pipeline the rules that vanished are the package's
    own entries, and nothing else in this system will ever put them back -- they are not
    journaled (Adam 2026-09-18, option a), so a power-cycled switch would come back forwarding
    nothing while every liveness signal said it was healthy.

    The clone session is the other half: a foreign pipeline clones nothing to the CPU port, so
    programming its PRE succeeds and produces zero samples forever.
    """

    def setUp(self):
        if main is None:  # pragma: no cover -- environment, not behaviour
            self.skipTest("proxy_agent.main is not importable in this interpreter")
        self.topo, self.old1, self.old2 = build_topology()
        self._real_sleep = topology_manager.time.sleep
        topology_manager.time.sleep = lambda seconds: None
        self.addCleanup(self._restore)
        self.made = []
        self.saved_entries = dict(main._table_entries)
        self.tmp = tempfile.mkdtemp(prefix="ndtwin_readopt_entries_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _restore(self):
        topology_manager.time.sleep = self._real_sleep
        main._table_entries.clear()
        main._table_entries.update(self.saved_entries)

    def factory(self, **kwargs):
        def make(dpid):
            client = FakeClient(dpid, **kwargs)
            client.write_table_entry = lambda spec, op="insert": client.written.append((spec, op))
            client.written = []
            self.made.append(client)
            return client
        return make

    def entries_file(self, count=2):
        path = os.path.join(self.tmp, "s1-runtime.json")
        with open(path, "w") as fh:
            json.dump({"target": "bmv2", "table_entries": [
                {"table": "MyIngress.ipv4_lpm",
                 "match": {"hdr.ipv4.dstAddr": [f"10.0.1.{i + 1}", 32]},
                 "action_name": "MyIngress.ipv4_forward",
                 "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
                for i in range(count)]}, fh)
        return path

    def package(self, pipeline=("build/x.p4info.txtpb", "build/x.json"), entries=None):
        """A package whose switch 1 runs `pipeline`; None there means NDTwin's own."""
        switch = main.app_package.SwitchSpec(dpid=1, name="s1", pipeline=pipeline,
                                             entries=entries,
                                             entries_recorded=0 if entries is None else 2)
        return main.app_package.Package(dir="/pkg", name="exercise", switches=(switch,))

    def readopt(self, package):
        return main.readopt_switch(self.topo, 1, self.factory(), sample_sink, package=package)

    def test_a_foreign_pipeline_gets_no_clone_session(self):
        self.readopt(self.package())
        self.assertIsNone(self.made[0].sample_at_start,
                          "a pipeline that clones nothing to the CPU port must not be "
                          "registered for sampling; the session would be programmed and "
                          "nothing would ever arrive in it")
        self.assertNotIn(("clone", 1), self.made[0].log)

    def test_a_readopted_foreign_switch_with_the_header_keeps_its_clone_session(self):
        # 🔴 TICKET-P3 SECTION 9 RULING 4, on the readopt path. This switch runs the exercise's
        # OWN program -- so `pipeline_is_ndtwin` is False and the routes are still not refilled
        # -- but that program includes `p4_proxy/p4_src/ndtwin_telemetry.p4`, so it really does
        # clone to the CPU port. Under `cooperative` it must come back from a power-cycle with
        # its clone session, or the exercise's twin goes dark the first time a switch restarts
        # and nothing says why.
        #
        # The decision is made from the p4info FILE, because the client this readopt will use
        # does not exist when `sample_callback` has to be chosen.
        knob = os.path.join(self.tmp, "telemetry_override")
        with open(knob, "w") as fh:
            fh.write("cooperative\n")
        package = self.package(pipeline=TELEMETRY_FOREIGN_PIPELINE)
        with mock.patch.object(main, "TELEMETRY_KNOB_PATH", knob):
            result = self.readopt(package)

        self.assertIsNotNone(self.made[0].sample_at_start,
                             "a program that carries the cooperative header must be handed the "
                             "sFlow callback")
        self.assertIn(("clone", 1), self.made[0].log)
        self.assertIs(result["clone_session"], True)
        self.assertNotIn("telemetry_note", result)
        # And the routes are still the exercise's own business.
        self.assertEqual(result["routes"], "skipped")
        self.assertEqual(main.pipelines_report()["1"]["skipped"], [],
                         "nothing was skipped on this switch, so the list is empty")

    def test_a_readopted_foreign_switch_without_the_header_still_gets_none(self):
        # The negative half, and the one that keeps the case above from being a change
        # detector: the same knob, a program with no controller header.
        knob = os.path.join(self.tmp, "telemetry_override")
        with open(knob, "w") as fh:
            fh.write("cooperative\n")
        with mock.patch.object(main, "TELEMETRY_KNOB_PATH", knob):
            result = self.readopt(self.package(pipeline=PLAIN_FOREIGN_PIPELINE))
        self.assertIsNone(self.made[0].sample_at_start)
        self.assertIs(result["clone_session"], False)
        self.assertIn("count every packet twice", result["telemetry_note"])

    def test_a_foreign_pipeline_gets_no_ndtwin_routes(self):
        # 🔴 Round 2, the orchestrator's ruling on objection ①. Before `install_routes` existed
        # this refill ran unconditionally: against `basic.p4` it SUCCEEDS, because that program
        # declares `MyIngress.ipv4_lpm` with `MyIngress.ipv4_forward(dstAddr, port)` under those
        # exact names -- so NDTwin's shortest paths landed on top of the exercise's own
        # forwarding and both sides reported success.
        result = self.readopt(self.package())
        self.assertEqual(self.topo.switches[1].routes, [],
                         "not one route write may be attempted against a foreign pipeline")
        self.assertEqual(result["routes_installed"], 0)
        self.assertEqual(result["routes_attempted"], 0)

    def test_it_says_the_routes_were_skipped_rather_than_reporting_a_bare_zero(self):
        # `routes_installed: 0` on its own reads as a switch that refused every write. The
        # named key is the difference between that and a switch that was deliberately not
        # offered any.
        result = self.readopt(self.package())
        self.assertEqual(result["routes"], "skipped")
        self.assertIn("no NDTwin route was installed", result["routes_note"])

    def test_it_does_not_claim_a_clone_session_it_never_programmed(self):
        # 🔴 `readopt_switch` answers `clone_session: True` when it is handed no sample callback
        # -- which means "nothing failed" and is right for a fabric whose sFlow is simply not
        # wired. Passed through here it would tell an operator a session was programmed when
        # the decision was that none should be: "reported success without doing it".
        self.assertIs(self.readopt(self.package())["clone_session"], False)

    def test_it_does_not_promise_a_watchdog_that_is_not_running_will_fix_it(self):
        # `routes_pending` promises the link watchdog installs the routes when the beacons
        # resume. On this fabric the watchdog was never started -- a foreign pipeline has no
        # controller header, so there are no beacons to resume.
        result = self.readopt(self.package())
        self.assertNotIn("routes_pending", result)
        self.assertNotIn("note", result)

    def test_an_exception_from_readopt_is_not_swallowed(self):
        # Round 1 wrapped this call in `except Exception` to turn the KeyError the route refill
        # raised against a foreign pipeline into a named failure instead of a 500. That was a
        # workaround for not having `install_routes`; with the parameter the refill does not
        # run, so anything raising here is a real fault and must not be dressed as a step name.
        class Exploding:
            switches = {1: None}

            def readopt_switch(self, dpid, factory, callback, install_routes=True):
                raise RuntimeError("the manager itself broke")

        for package in (self.package(), self.package(pipeline=None)):
            with self.assertRaises(RuntimeError):
                main.readopt_switch(Exploding(), 1, self.factory(), sample_sink,
                                    package=package)

    def test_the_ndtwin_path_still_installs_its_routes(self):
        # The negative half of test_a_foreign_pipeline_gets_no_ndtwin_routes: the flag follows
        # the pipeline, not "readopt was called through the wrapper".
        result = self.readopt(self.package(pipeline=None))
        self.assertEqual(result["routes_installed"], 2)
        self.assertEqual(result["routes_attempted"], 2)
        self.assertNotIn("routes", result)


    def test_the_packages_entries_go_back_on_after_the_push_that_erased_them(self):
        result = self.readopt(self.package(entries=self.entries_file(2)))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["table_entries"]["applied"], 2)
        self.assertEqual(len(self.topo.switches[1].written), 2,
                         "the pipeline push emptied the switch and nothing else in this "
                         "system replays these rules -- they are not journaled")

    def test_the_count_reaches_the_endpoint_report_not_just_the_response(self):
        self.readopt(self.package(entries=self.entries_file(2)))
        self.assertEqual(main.table_entries_report()["1"]["applied"], 2)
        self.assertEqual(main.table_entries_report()["1"]["journaled"], False)

    def test_ndtwins_own_pipeline_is_readopted_exactly_as_before(self):
        # The negative half. `pipeline: null` is every package phase 1 accepts, and this path
        # must stay the one that has been running: clone session programmed, no entries applied.
        result = self.readopt(self.package(pipeline=None, entries=self.entries_file(2)))
        self.assertEqual(result["status"], "success")
        self.assertIn(("clone", 1), self.made[0].log)
        self.assertNotIn("table_entries", result)
        self.assertEqual(self.topo.switches[1].written, [])

    def test_a_readopt_that_failed_applies_nothing(self):
        # Re-applying entries to a switch whose re-adoption failed would write into a client
        # that was torn down, and report a count for rules nobody holds.
        result = main.readopt_switch(
            self.topo, 1, self.factory(mastership_confirmed=False), sample_sink,
            package=self.package(entries=self.entries_file(2)))
        self.assertEqual(result["status"], "failed")
        self.assertNotIn("table_entries", result)
        self.assertIs(self.topo.switches[1], self.old1)


class ReadoptOnAFabricWhoseRouteTablesNdtwinOwnsTest(unittest.TestCase):
    """
    TICKET-P4-roles 2.3-3 on the power-on path.

    [Co-developed with claude code -- Adam]
    When every foreign switch binds roles.ipv4_route with owner ndtwin, startup put NDTwin's
    routes into those tables -- and the push inside readopt has just emptied this one. The
    package declares no entries for an owned table (pre-flight refuses them), and no watchdog
    runs on this fabric, so unless readopt puts the routes back the switch comes back forwarding
    nothing. The new client's binding is the factory's, re-resolved; one unbound switch, and the
    fabric's routes are nobody's to refill -- exactly as before roles.
    """

    def setUp(self):
        if main is None:  # pragma: no cover -- environment, not behaviour
            self.skipTest("proxy_agent.main is not importable in this interpreter")
        from proxy_agent import route_binding

        self.owned = route_binding.RouteBinding(
            table="MyIngress.ipv4_lpm", match_field="hdr.ipv4.dstAddr",
            action="MyIngress.ipv4_forward", dst_mac_param="dstAddr", port_param="port",
            owner="ndtwin", source="package")
        self.topo, self.old1, self.old2 = build_topology()
        self.old1.route_binding = self.old2.route_binding = self.owned
        self._real_sleep = topology_manager.time.sleep
        topology_manager.time.sleep = lambda seconds: None
        saved = (dict(main._table_entries), dict(main._capabilities),
                 dict(main._control_plane))

        def restore():
            topology_manager.time.sleep = self._real_sleep
            main._table_entries.clear()
            main._table_entries.update(saved[0])
            main._capabilities.clear()
            main._capabilities.update(saved[1])
            main._control_plane.clear()
            main._control_plane.update(saved[2])
        self.addCleanup(restore)
        self.made = []
        # What startup left on this fabric: every foreign switch owned, so LLDP and the
        # watchdog are skipped and the routes are not (round 2, section 7 ruling 5 item 1).
        self.startup_skipped([main.SKIP_LLDP, main.SKIP_WATCHDOG])

    def startup_skipped(self, skipped):
        main._control_plane.update({"skipped": sorted(skipped)})

    def factory(self, binding):
        def make(dpid):
            client = FakeClient(dpid)
            client.route_binding = binding
            client.write_table_entry = lambda spec, op="insert": None
            self.made.append(client)
            return client
        return make

    def package(self):
        switches = tuple(main.app_package.SwitchSpec(dpid=d, name=f"s{d}",
                                                     pipeline=PLAIN_FOREIGN_PIPELINE,
                                                     entries=None)
                         for d in (1, 2))
        return main.app_package.Package(dir="/pkg", name="basic", switches=switches)

    def test_the_routes_go_back_into_the_bound_table(self):
        result = main.readopt_switch(self.topo, 1, self.factory(self.owned), sample_sink,
                                     package=self.package())
        self.assertEqual(result["routes"], "installed")
        self.assertEqual(sorted(r[0] for r in self.made[0].routes), sorted([H1, H2]))
        self.assertEqual((result["routes_installed"], result["routes_attempted"]), (2, 2))

    def test_a_switch_that_came_back_unbound_is_not_refilled(self):
        result = main.readopt_switch(self.topo, 1, self.factory(None), sample_sink,
                                     package=self.package())
        self.assertEqual(result["routes"], "skipped")
        self.assertEqual(self.made[0].routes, [])

    def test_its_capabilities_follow_the_new_clients_binding(self):
        main.readopt_switch(self.topo, 1, self.factory(None), sample_sink,
                            package=self.package())
        self.assertEqual(main.capabilities_report()["1"]["ipv4_route"], "unbound")

    def test_a_fabric_that_skipped_its_routes_at_startup_is_not_refilled_now(self):
        # Round 2, section 7 ruling 5 item 1: the same predicate as startup -- the FABRIC did
        # not skip the routes, and this switch's binding is owner ndtwin. Round 1 asked only
        # whether every client is owned NOW, so a switch that was unbound (or absent) at
        # startup and comes back owned would get NDTwin's routes into its table while the rest
        # of the fabric carries none: a path half-installed.
        self.startup_skipped([main.SKIP_LLDP, main.SKIP_WATCHDOG, main.SKIP_ROUTES])
        result = main.readopt_switch(self.topo, 1, self.factory(self.owned), sample_sink,
                                     package=self.package())
        self.assertEqual(result["routes"], "skipped")
        self.assertEqual(self.made[0].routes, [])

    def test_before_startup_has_run_a_foreign_switch_is_not_refilled(self):
        # `skipped` is null until startup records it: no decision is not a yes.
        main._control_plane.update({"skipped": None})
        result = main.readopt_switch(self.topo, 1, self.factory(self.owned), sample_sink,
                                     package=self.package())
        self.assertEqual(result["routes"], "skipped")
        self.assertEqual(self.made[0].routes, [])

    def test_a_package_owned_switch_is_not_refilled_on_a_fabric_that_installs_routes(self):
        from proxy_agent import route_binding

        kept = route_binding.RouteBinding(**dict(vars(self.owned), owner="package"))
        result = main.readopt_switch(self.topo, 1, self.factory(kept), sample_sink,
                                     package=self.package())
        self.assertEqual(result["routes"], "skipped")
        self.assertEqual(self.made[0].routes, [])


class ReadoptOnAFabricThatSkipsItsRoutesTest(unittest.TestCase):
    """
    TICKET-P4-roles section 7 ruling 5, item 1: readopt obeys the fabric's route skip.

    [Co-developed with claude code -- Adam]
    A mixed fabric -- s1 on NDTwin's pipeline, s2 on a package's with no roles -- skips
    install_initial_routes for the whole fabric at startup, because s2's table is nobody's to
    write and a shortest path through it would be half-installed. Round 1 entered the declared
    s1-s2 cable into `net` (2.3-1), and readopt of s1 kept refilling over the whole graph -- so
    it wrote s1's route to h2, a path that crosses s2. Before the cut `net` had no inter-switch
    edge on such a fabric, and the same refill could reach only the hosts attached to s1. That
    is the behaviour kept: on a fabric that skips its routes, no route NDTwin writes may cross
    another switch.
    """

    def setUp(self):
        if main is None:  # pragma: no cover -- environment, not behaviour
            self.skipTest("proxy_agent.main is not importable in this interpreter")
        self.topo, self.old1, self.old2 = build_topology()   # h1 -- s1 -- s2 -- h2
        self.old2.route_binding = None
        self._real_sleep = topology_manager.time.sleep
        topology_manager.time.sleep = lambda seconds: None
        saved = (dict(main._table_entries), dict(main._capabilities),
                 dict(main._control_plane), dict(main._pipelines))

        def restore():
            topology_manager.time.sleep = self._real_sleep
            for live, old in zip((main._table_entries, main._capabilities,
                                  main._control_plane, main._pipelines), saved):
                live.clear()
                live.update(old)
        self.addCleanup(restore)
        self.made = []

    def fabric(self, skips_routes):
        """What startup leaves behind on this fabric, in both places it leaves it."""
        skipped = [main.SKIP_LLDP, main.SKIP_WATCHDOG] + ([main.SKIP_ROUTES] if skips_routes
                                                          else [])
        main._control_plane.update({"skipped": sorted(skipped)})
        self.topo.routes_to_attached_hosts_only = skips_routes

    def package(self):
        switches = (main.app_package.SwitchSpec(dpid=1, name="s1", pipeline=None, entries=None),
                    main.app_package.SwitchSpec(dpid=2, name="s2",
                                                pipeline=PLAIN_FOREIGN_PIPELINE, entries=None))
        return main.app_package.Package(dir="/pkg", name="mixed", switches=switches)

    def factory(self):
        def make(dpid):
            client = FakeClient(dpid)
            self.made.append(client)
            return client
        return make

    def readopt_s1(self):
        return main.readopt_switch(self.topo, 1, self.factory(), sample_sink,
                                   package=self.package())

    def test_readopting_the_ndtwin_switch_writes_no_route_through_the_unbound_one(self):
        self.fabric(skips_routes=True)
        result = self.readopt_s1()
        self.assertEqual(result["status"], "success")
        self.assertEqual([r[0] for r in self.made[0].routes], [H1],
                         "a route to h2 from s1 crosses s2, whose table NDTwin may not write")
        self.assertEqual((result["routes_installed"], result["routes_attempted"]), (1, 1))

    def test_it_says_the_refill_stopped_at_the_attached_hosts_and_why(self):
        self.fabric(skips_routes=True)
        result = self.readopt_s1()
        self.assertEqual(result["routes_scope"], "attached_hosts")
        self.assertIn(main.SKIP_ROUTES, result["routes_note"])

    def test_on_a_fabric_that_installs_routes_the_same_readopt_refills_every_host(self):
        # The other direction, so "write nothing" cannot pass the test above.
        self.fabric(skips_routes=False)
        result = self.readopt_s1()
        self.assertEqual(sorted(r[0] for r in self.made[0].routes), sorted([H1, H2]))
        self.assertNotIn("routes_scope", result)


class OnlyTheAttachedHostsTest(unittest.TestCase):
    """TopologyManager.install_initial_routes under `routes_to_attached_hosts_only`.
    [Co-developed with claude code -- Adam] Section 7 ruling 5 item 1, at the route writer."""

    def setUp(self):
        self.topo, self.s1, self.s2 = build_topology()

    def test_the_default_is_every_host_as_before(self):
        self.assertFalse(self.topo.routes_to_attached_hosts_only)
        self.topo.install_initial_routes()
        self.assertEqual(sorted(r[0] for r in self.s1.routes), sorted([H1, H2]))

    def test_restricted_each_switch_routes_only_to_its_own_hosts_and_counts_only_those(self):
        self.topo.routes_to_attached_hosts_only = True
        installed, attempted = self.topo.install_initial_routes()
        self.assertEqual([r[0] for r in self.s1.routes], [H1])
        self.assertEqual([r[0] for r in self.s2.routes], [H2])
        self.assertEqual((installed, attempted), (2, 2))


class InstallRoutesIsAParameterTest(ReadoptTestBase):
    """
    `TopologyManager.readopt_switch(install_routes=...)` on its own, without the wrapper.

    [Co-developed with claude code -- Adam]
    The seam the orchestrator's round-2 ruling added. Asserted here as well as through
    `main.readopt_switch` because the default is what every other caller gets, and a default
    that silently flipped would take the route refill away from the whole P4 plane.
    """

    def test_the_default_is_the_behaviour_every_caller_had_before_the_parameter(self):
        result = self.readopt()
        self.assertEqual(sorted(r[0] for r in self.made[0].routes), sorted([H1, H2]))
        self.assertEqual((result["routes_installed"], result["routes_attempted"]), (2, 2))

    def test_install_routes_false_attempts_not_one_write(self):
        result = self.topo.readopt_switch(1, self.factory(), sample_sink, settle_s=0.25,
                                          install_routes=False)
        self.assertEqual(self.made[0].routes, [],
                         "insert_ipv4_route must not be called at all -- against a foreign "
                         "pipeline the name it writes means somebody else's table")
        self.assertEqual(result["status"], "success")
        self.assertEqual((result["routes_installed"], result["routes_attempted"]), (0, 0))

    def test_install_routes_false_does_not_claim_the_watchdog_will_fix_it(self):
        result = self.topo.readopt_switch(1, self.factory(), sample_sink, settle_s=0.25,
                                          install_routes=False)
        self.assertNotIn("routes_pending", result)
        self.assertNotIn("note", result)

    def test_zero_attempted_still_says_pending_when_the_refill_did_run(self):
        # The other side of that guard: when install_routes is True, zero attempted still means
        # "this switch's links are down and the watchdog will reinstall" -- unchanged from
        # 79dd4312, and the note must not have been lost along with the false promise.
        self.topo.net.remove_edge(1, 2)
        for host in (H1, H2):
            if self.topo.net.has_node(host):
                self.topo.net.remove_node(host)
        result = self.readopt()
        self.assertEqual(result["routes_attempted"], 0)
        self.assertTrue(result["routes_pending"])
        self.assertIn("link watchdog", result["note"])

    def test_the_switch_is_still_adopted_when_the_refill_is_skipped(self):
        # The pipeline, the mastership gate and the client swap are unchanged: what the flag
        # removes is the refill, not the adoption.
        result = self.topo.readopt_switch(1, self.factory(), sample_sink, settle_s=0.25,
                                          install_routes=False)
        self.assertEqual(result["status"], "success")
        self.assertIn(("pipeline", 1), self.log)
        self.assertIs(self.topo.switches[1], self.made[0])
        self.assertTrue(self.old1.stopped)

# --- write_manifest -------------------------------------------------------------------

def load_testbed_module():
    """
    Import p4_testbed_topo.py with mininet stubbed out. The stubs are bare types: nothing
    from mininet participates in write_manifest, the module merely imports it at top level.

    P4_TESTBED_TOPO_UNDER_TEST names a different copy to load, which is how
    tests/shell/mutate_startup_clears_by_pid.sh puts each mutation into a temp-dir copy instead
    of writing the file in this shared worktree. Same seam and same reason as
    check_test_tmpdirs.py's CHECK_TMPDIRS_UNDER_TEST. [Co-developed with claude code -- Adam]
    """
    stubs = {
        "mininet": {},
        "mininet.net": {"Mininet": type("Mininet", (), {})},
        "mininet.topo": {"Topo": type("Topo", (), {})},
        "mininet.node": {"Switch": type("Switch", (), {}),
                         "Host": type("Host", (), {})},
        "mininet.cli": {"CLI": type("CLI", (), {})},
        "mininet.log": {"setLogLevel": lambda *a, **k: None,
                        "info": lambda *a, **k: None},
    }
    for name, attrs in stubs.items():
        if name not in sys.modules:
            mod = types.ModuleType(name)
            for attr, value in attrs.items():
                setattr(mod, attr, value)
            sys.modules[name] = mod
    path = os.environ.get("P4_TESTBED_TOPO_UNDER_TEST") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "mininet", "p4_testbed_topo.py")
    spec = importlib.util.spec_from_file_location("p4_testbed_topo_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeBmv2Switch:
    def __init__(self, name, pid=4242, grpc_port=53201, failure=None):
        self.name = name
        self.bmv2_pid = pid
        self.device_id = 7
        self.grpc_port = grpc_port
        self.thrift_port = grpc_port + 500
        self.log_file = f"/tmp/{name}.log"
        self.launch_argv = f"simple_switch_grpc --device-id 7 -- --grpc-server-addr 0.0.0.0:{grpc_port}"
        self._failure = failure

    def failure_reason(self):
        return self._failure


class WriteManifestTest(unittest.TestCase):
    """
    The design's trust boundary: /tmp is sticky, anyone can create the *name* first, and a
    root open(path, "w") truncates their inode in place -- leaving them the owner, able to
    rewrite the argv that ndtwin-p4-power later executes as root. So every write must be a
    fresh inode moved over the path, and a pre-existing file must be replaced, not reused.
    """

    @classmethod
    def setUpClass(cls):
        cls.mod = load_testbed_module()

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ndtwin_manifest.")
        self.addCleanup(__import__("shutil").rmtree, self.dir, ignore_errors=True)
        self.path = os.path.join(self.dir, "switches.json")

    def read(self):
        with open(self.path) as fh:
            return json.load(fh)

    def test_every_write_is_a_new_inode(self):
        self.mod.write_manifest([FakeBmv2Switch("s1")], path=self.path)
        first = os.stat(self.path).st_ino
        self.mod.write_manifest([FakeBmv2Switch("s1")], path=self.path)
        self.assertNotEqual(os.stat(self.path).st_ino, first,
                            "the manifest was rewritten in place; whoever owned the old "
                            "inode still owns the new content")

    def test_a_preexisting_file_at_the_path_is_replaced_not_truncated(self):
        # The squatter scenario itself: the name exists before the topology runs.
        with open(self.path, "w") as fh:
            fh.write('{"s1": {"argv": "rm -rf --no-preserve-root /"}}')
        squatter_ino = os.stat(self.path).st_ino

        self.mod.write_manifest([FakeBmv2Switch("s1", pid=555)], path=self.path)

        self.assertNotEqual(os.stat(self.path).st_ino, squatter_ino,
                            "the squatter's inode survived: as root this would leave the "
                            "file owned by the squatter, argv rewritable at will")
        self.assertEqual(self.read()["s1"]["pid"], 555,
                         "the squatter's content must be fully replaced")

    def test_only_verified_live_switches_are_listed(self):
        self.mod.write_manifest([FakeBmv2Switch("s1", pid=101),
                                 FakeBmv2Switch("s2", pid=102, failure="exited early")],
                                path=self.path)
        manifest = self.read()
        self.assertIn("s1", manifest)
        self.assertNotIn("s2", manifest,
                         "an entry for a dead switch is worse than no entry: the helper "
                         "would trust its pid and argv")

    def test_an_entry_records_what_the_helper_needs_verbatim(self):
        sw = FakeBmv2Switch("s3", pid=321, grpc_port=53207)
        self.mod.write_manifest([sw], path=self.path)
        entry = self.read()["s3"]
        self.assertEqual(entry["pid"], 321)
        self.assertEqual(entry["device_id"], sw.device_id)
        self.assertEqual(entry["grpc_port"], 53207)
        self.assertEqual(entry["thrift_port"], sw.thrift_port)
        self.assertEqual(entry["log_file"], sw.log_file)
        self.assertEqual(entry["argv"], sw.launch_argv,
                         "argv is what 'on' will execute as root; it must round-trip "
                         "byte-for-byte")


class ReapManifestSwitchesTest(unittest.TestCase):
    """
    Teardown deleted the manifest without stopping what it listed. A switch restarted by
    ndtwin-p4-power is spawned detached (start_new_session=True) so it can outlive the sudo
    call that created it -- that is what makes power-on work -- so net.stop() does not reap
    it, and once the manifest is gone the helper can no longer resolve its name to a pid.
    Reaping now happens before the file is removed.

    The kill and the liveness check are injected: these tests must never signal a real pid.
    """

    @classmethod
    def setUpClass(cls):
        cls.mod = load_testbed_module()

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ndtwin_reap.")
        self.addCleanup(__import__("shutil").rmtree, self.dir, ignore_errors=True)
        self.path = os.path.join(self.dir, "switches.json")
        self.signals = []

    def write(self, manifest):
        with open(self.path, "w") as fh:
            json.dump(manifest, fh)

    def recording_kill(self, pid, sig):
        self.signals.append((pid, sig))

    def reap(self, is_switch, **kw):
        return self.mod.reap_manifest_switches(
            path=self.path, is_switch=is_switch, kill=self.recording_kill,
            settle_s=0, **kw)

    def test_a_live_switch_is_signalled_and_reported(self):
        self.write({"s1": {"pid": 111}})
        reaped = self.reap(is_switch=lambda pid, **kw: pid == 111)
        self.assertEqual(reaped, ["s1"])
        self.assertIn((111, signal.SIGTERM), self.signals)

    def test_a_recycled_pid_is_never_signalled(self):
        # The whole reason process_is_a_switch exists: teardown runs as root, so killing a
        # stale manifest pid unchecked would eventually kill an unrelated process.
        self.write({"s1": {"pid": 222}})
        reaped = self.reap(is_switch=lambda pid, **kw: False)
        self.assertEqual(reaped, [])
        self.assertEqual(self.signals, [],
                         "a pid that is no longer a bmv2 must not receive any signal")

    def test_sigkill_only_when_sigterm_did_not_take(self):
        self.write({"s1": {"pid": 333}})
        self.reap(is_switch=lambda pid, **kw: True)      # still alive on the recheck
        self.assertEqual(self.signals, [(333, signal.SIGTERM), (333, signal.SIGKILL)])

    def test_no_sigkill_when_the_switch_exited_on_sigterm(self):
        alive = {"v": True}

        def is_switch(pid, **kw):
            if alive["v"]:
                alive["v"] = False       # first call: before the TERM. Second: after it.
                return True
            return False

        self.write({"s1": {"pid": 444}})
        self.reap(is_switch=is_switch)
        self.assertEqual(self.signals, [(444, signal.SIGTERM)],
                         "escalating to SIGKILL after a clean exit could hit a recycled pid")

    def test_every_listed_switch_is_reaped_not_just_the_first(self):
        self.write({"s1": {"pid": 1}, "s2": {"pid": 2}, "s3": {"pid": 3}})
        reaped = self.reap(is_switch=lambda pid, **kw: True)
        self.assertEqual(reaped, ["s1", "s2", "s3"])
        self.assertEqual([p for p, s in self.signals if s == signal.SIGTERM], [1, 2, 3])

    def test_a_missing_manifest_is_not_an_error(self):
        # Teardown calls this unconditionally; the manifest is absent whenever write_manifest
        # failed, and that must not take the teardown down with it.
        self.assertEqual(self.reap(is_switch=lambda pid, **kw: True), [])
        self.assertEqual(self.signals, [])

    def test_a_corrupt_manifest_is_not_an_error(self):
        with open(self.path, "w") as fh:
            fh.write("{not json")
        self.assertEqual(self.reap(is_switch=lambda pid, **kw: True), [])

    def test_an_entry_without_a_pid_is_skipped(self):
        self.write({"s1": {"grpc_port": 50051}, "s2": {"pid": None}})
        self.assertEqual(self.reap(is_switch=lambda pid, **kw: True), [])
        self.assertEqual(self.signals, [])

    def test_a_refused_kill_does_not_propagate(self):
        def refusing_kill(pid, sig):
            raise PermissionError("not yours")

        self.write({"s1": {"pid": 555}})
        reaped = self.mod.reap_manifest_switches(
            path=self.path, is_switch=lambda pid, **kw: True, kill=refusing_kill,
            settle_s=0)
        self.assertEqual(reaped, ["s1"],
                         "a switch we could not signal is still reported, so the operator "
                         "learns it is still out there")


class ProcessIsASwitchTest(unittest.TestCase):
    """Reads /proc/<pid>/cmdline, so it is driven against a fake proc tree."""

    @classmethod
    def setUpClass(cls):
        cls.mod = load_testbed_module()

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="ndtwin_proc.")
        self.addCleanup(__import__("shutil").rmtree, self.root, ignore_errors=True)

    def make(self, pid, cmdline):
        d = os.path.join(self.root, str(pid))
        os.makedirs(d)
        # Real cmdline entries are NUL-separated, which is why the check is a substring
        # search over bytes rather than a split-and-compare.
        with open(os.path.join(d, "cmdline"), "wb") as fh:
            fh.write(cmdline)

    def test_a_bmv2_cmdline_is_recognised(self):
        self.make(10, b"simple_switch_grpc\x00--device-id\x001\x00")
        self.assertTrue(self.mod.process_is_a_switch(10, proc_root=self.root))

    def test_an_unrelated_process_is_not(self):
        self.make(11, b"/usr/bin/python3\x00server.py\x00")
        self.assertFalse(self.mod.process_is_a_switch(11, proc_root=self.root))

    def test_a_vanished_pid_is_not_a_switch(self):
        self.assertFalse(self.mod.process_is_a_switch(9999, proc_root=self.root))


# --- the startup reset ----------------------------------------------------------------------


class ClearSwitchesFromAPreviousRunTest(unittest.TestCase):
    """
    Startup's reset. Until 2026-09-11 both topologies ran
    `os.system('sudo pkill -f simple_switch_grpc > /dev/null 2>&1')` as root on every bring-up
    -- the form CLAUDE.md's engineering discipline forbids by name, for the reason KNOWN-ISSUES
    G-9 and G-inst-2 each paid for once: `-f` matches the whole command line, so it takes any
    process whose argv mentions the string, and Mininet switches share the root PID namespace.

    Expected behaviour is taken from what the fix has to preserve and what it has to stop, not
    from reading the new function:

      * the pids are the manifest's, checked against /proc before they are signalled -- the
        machinery reap_manifest_switches and process_is_a_switch already provide, and which
        teardown has used since the A-4 bookkeeping fix;
      * a port that is still held by something the manifest does not name is REPORTED, with the
        way to find its owner BY THE PORT. That is the one thing a name match could do that a
        pid cannot, and dropping it silently would be the third way this rule gets lost;
      * the manifest is NOT deleted. reap_manifest_switches' own docstring is about that
        mistake: the file is the only handle left on a switch we failed to stop.

    Nothing here signals a real pid: the reap and the port probe are both injected.
    [Co-developed with claude code -- Adam]
    """

    @classmethod
    def setUpClass(cls):
        cls.mod = load_testbed_module()

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ndtwin_clear.")
        self.addCleanup(__import__("shutil").rmtree, self.dir, ignore_errors=True)
        self.path = os.path.join(self.dir, "switches.json")
        with open(self.path, "w") as fh:
            json.dump({"s1": {"pid": 111}}, fh)
        self.said = []
        self.probed = []
        self.slept = []
        self.asked_about = []
        self._real_sleep = self.mod.time.sleep
        self.mod.time.sleep = lambda seconds: self.slept.append(seconds)
        self.addCleanup(self._restore_sleep)

    def _restore_sleep(self):
        self.mod.time.sleep = self._real_sleep

    def clear(self, reaped=(), open_ports=(), ports=(53201, 53202), **kw):
        def reap(path):
            self.asked_about.append(path)
            return list(reaped)

        def port_is_open(port):
            self.probed.append(port)
            return port in open_ports

        return self.mod.clear_switches_from_a_previous_run(
            manifest_path=self.path, ports=ports, reap=reap, port_is_open=port_is_open,
            report=self.said.append, **kw)

    def report(self):
        return "\n".join(self.said)

    def test_the_pids_come_from_the_manifest(self):
        self.clear(reaped=["s1"])
        self.assertEqual(self.asked_about, [self.path],
                         "the reap must be asked about the manifest, which is the only place "
                         "a pid this run may signal comes from")

    def test_what_was_reaped_is_reported_by_name(self):
        self.clear(reaped=["s3", "s7"])
        self.assertIn("s3", self.report())
        self.assertIn("s7", self.report())

    def test_a_reap_that_stopped_nothing_says_nothing_about_reaping(self):
        self.clear(reaped=[])
        self.assertNotIn("Reaped", self.report(),
                         "an empty reap reported as a reap is a line an operator learns to "
                         "ignore, and this one has to be readable when it is not empty")

    def test_the_manifest_file_is_not_deleted(self):
        self.clear(reaped=["s1"])
        self.assertTrue(os.path.exists(self.path),
                        "the manifest is the only thing that can still address a switch the "
                        "reap failed to stop; removing it here is the A-4 defect, at startup")

    def test_every_wanted_port_is_probed(self):
        self.clear(ports=(1, 2, 3, 4))
        self.assertEqual(self.probed, [1, 2, 3, 4],
                         "probing only the first port answers about one switch out of ten")

    def test_a_port_still_held_is_reported_with_its_number(self):
        self.clear(ports=(53201, 53202), open_ports=(53202,))
        warning = [line for line in self.said if line.startswith("WARNING:")]
        self.assertEqual(len(warning), 1, "exactly one warning line, and it is the one an "
                                          "operator will read")
        # 🔴 The warning ITSELF, not the paragraph. The first version of this assertion was
        # `assertIn("53202", self.report())` and mutate_startup_clears_by_pid.sh's MS5 -- which
        # replaces the port list with the words "some of them" -- SURVIVED it, because the
        # how-to-look line further down happens to carry the same number.
        self.assertIn("53202", warning[0])
        self.assertNotIn("53201", warning[0],
                         "a port nothing holds must not be named as held")

    def test_the_report_says_how_to_find_the_owner_by_its_port(self):
        self.clear(ports=(53205,), open_ports=(53205,))
        self.assertIn("sport = :53205", self.report(),
                      "a warning that does not say how to look leaves the operator with the "
                      "name match as the only thing they know how to do")

    def test_a_held_port_is_not_signalled(self):
        # There is no seam here to signal through, and that IS the assertion: the function is
        # handed a reap (manifest pids) and a read-only probe, and nothing else. A port whose
        # owner is unknown produces a sentence, not a kill.
        reaped, held = self.clear(ports=(53201,), open_ports=(53201,))
        self.assertEqual(held, [53201])
        self.assertEqual(reaped, [])

    def test_free_ports_produce_no_warning(self):
        self.clear(ports=(53201, 53202), open_ports=())
        self.assertNotIn("WARNING", self.report(),
                         "a clean start must be quiet, or the warning that matters is noise")

    def test_it_returns_both_halves_of_what_happened(self):
        reaped, held = self.clear(reaped=["s1", "s2"], ports=(9, 10), open_ports=(10,))
        self.assertEqual((reaped, held), (["s1", "s2"], [10]))

    def test_the_settle_runs_once_when_something_was_reaped(self):
        self.clear(reaped=["s1"], settle_s=0.5)
        self.assertEqual(self.slept, [0.5],
                         "a port is released when the process exits, so probing without a "
                         "settle reads a switch on its way out as a stranger")

    def test_nothing_is_slept_through_when_nothing_was_reaped(self):
        self.clear(reaped=[], settle_s=0.5)
        self.assertEqual(self.slept, [])


def testbed_source():
    """The text of the p4_testbed_topo.py under test, and its directory.

    Reads P4_TESTBED_TOPO_UNDER_TEST the same way load_testbed_module does, so that
    mutate_startup_clears_by_pid.sh's temp-dir copy is what the source-level assertions below
    read too. Without this a mutation that deletes a call in main() would be invisible to them
    and would be scored a survivor of the wrong thing. [Co-developed with claude code -- Adam]
    """
    path = os.environ.get("P4_TESTBED_TOPO_UNDER_TEST") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "mininet", "p4_testbed_topo.py")
    with open(path) as fh:
        return fh.read(), os.path.dirname(os.path.abspath(path))


class AbortOnHeldGrpcPortsTest(unittest.TestCase):
    """
    Startup's SECOND half: what to do about a gRPC port the reset could not free.

    Until 2026-09-12 the answer was "warn and go on", and the warning said so -- "The switches
    on those ports will fail to bind, and each one will be named with its own log path in the
    verification report below". That is a report, and a report is not a decision. What it buys
    an operator is a fabric with nine switches where the topology says ten, built anyway, with
    every measurement taken afterwards belonging to a population nobody declared. The 128-host
    rounds are the case that settles it: a missing switch there is 16 hosts that are not
    reachable, and the run that produced the numbers is over by the time anyone reads the log.

    So the policy is now: a held port ABORTS the bring-up, before Mininet is built. Expected
    behaviour below is what an operator needs in order to act on the abort -- which port, who
    holds it, and how to check that for themselves -- not what the new function does.

    🔴 Nothing here signals anything and nothing here runs `ss`: the owner lookup and sys.exit
    are both injected. The one thing a test must not do is act on a port some other session on
    this machine is legitimately using. [Co-developed with claude code -- Adam]
    """

    @classmethod
    def setUpClass(cls):
        cls.mod = load_testbed_module()

    def setUp(self):
        self.said = []
        self.exits = []
        self.asked = []

    def abort(self, held, owners=None, **kw):
        owners = owners or {}

        def owner_of(port):
            self.asked.append(port)
            return owners.get(port)

        return self.mod.abort_if_grpc_ports_are_held(
            held, owner_of=owner_of, report=self.said.append, exit_=self.exits.append, **kw)

    def report(self):
        return "\n".join(self.said)

    def test_a_clean_start_is_not_aborted_and_is_quiet(self):
        self.abort([])
        self.assertEqual(self.exits, [], "a fabric whose ports are free must start")
        self.assertEqual(self.said, [])

    def test_a_held_port_stops_the_run_with_a_non_zero_status(self):
        self.abort([53203])
        self.assertEqual(self.exits, [1],
                         "a bring-up that goes on without the switch on :53203 hands every "
                         "later measurement a fabric smaller than the topology it claims")

    def test_every_held_port_is_named_not_just_the_first(self):
        self.abort([53203, 53207])
        self.assertIn("53203", self.report())
        self.assertIn("53207", self.report(),
                      "naming one of two held ports leaves the operator to discover the "
                      "second one the next time the run aborts")

    def test_the_owner_of_each_held_port_is_printed_verbatim(self):
        line = ('LISTEN 0 10 0.0.0.0:53203 0.0.0.0:* '
                'users:(("simple_switch_g",pid=91234,fd=9))')
        self.abort([53203], owners={53203: line})
        self.assertIn(line, self.report(),
                      "the whole point of aborting instead of warning is that the operator is "
                      "told WHO to stop; a port number alone is the warning again")
        self.assertIn("91234", self.report(),
                      "the pid is what they act on -- by pid, never by name")

    def test_an_owner_that_could_not_be_read_says_so(self):
        self.abort([53203], owners={})
        self.assertIn("53203", self.report())
        self.assertNotIn("None", self.report(),
                         "an unreadable owner printed as None reads like a value")
        self.assertTrue(any("could not" in line for line in self.said),
                        "a lookup that failed must not look the same as a port nobody holds")

    def test_the_abort_says_how_to_check_it_by_the_port(self):
        self.abort([53205])
        self.assertIn("sport = :53205", self.report(),
                      "an operator who is not told how to look is left with the name match "
                      "this whole change removed")

    def test_the_owner_is_asked_about_every_held_port(self):
        self.abort([1, 2, 3])
        self.assertEqual(self.asked, [1, 2, 3])

    def test_it_aborts_even_when_no_owner_can_be_named(self):
        # The lookup needs root to name another user's process. Failing to name the owner is
        # not a reason to start on a port that is demonstrably taken.
        self.abort([53203], owners={})
        self.assertEqual(self.exits, [1])


class PortOwnerLineTest(unittest.TestCase):
    """The `ss -ltnp` read itself. The command is built here and the runner is injected, so no
    subprocess starts. [Co-developed with claude code -- Adam]"""

    @classmethod
    def setUpClass(cls):
        cls.mod = load_testbed_module()

    def ask(self, port, rc=0, out="", boom=None):
        seen = []

        def run(argv):
            seen.append(argv)
            if boom is not None:
                raise boom
            return rc, out
        return self.mod.port_owner_line(port, run=run), seen

    SS = ("State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process\n"
          'LISTEN 0      10       0.0.0.0:53203      0.0.0.0:*    '
          'users:(("simple_switch_g",pid=91234,fd=9))\n')

    def test_the_question_is_asked_by_the_port(self):
        _, seen = self.ask(53203, out=self.SS)
        self.assertEqual(seen, [["ss", "-ltnp", "sport = :53203"]],
                         "asked by the port it holds, never by a name the process carries")

    def test_the_listener_line_is_returned_and_the_header_is_not(self):
        line, _ = self.ask(53203, out=self.SS)
        self.assertIn("pid=91234", line)
        self.assertNotIn("Recv-Q", line)

    def test_a_port_with_no_listener_reads_as_unknown(self):
        line, _ = self.ask(53203, rc=0, out="State Recv-Q Send-Q Local Address:Port\n")
        self.assertIsNone(line)

    def test_a_missing_ss_is_unknown_rather_than_an_exception(self):
        line, _ = self.ask(53203, boom=FileNotFoundError("ss"))
        self.assertIsNone(line, "a machine without iproute2 must still be able to abort")

    def test_a_non_zero_ss_is_unknown(self):
        line, _ = self.ask(53203, rc=2, out="")
        self.assertIsNone(line)


class BothMainsRefuseAHeldPortTest(unittest.TestCase):
    """
    Both topologies abort, asserted on the source text of each main.

    This is a source-level assertion and it is one on purpose: main() builds a real Mininet and
    cannot be called from a unit test, and the thing that has to be true is precisely that the
    refusal is reached from BOTH files. FIX-PROXY-1's finding is the reason the weaker test is
    worth having: the copy that actually runs is ntg_bmv2_topo.py -- ndtwin-lab starts that
    one, not p4_testbed_topo.py -- and for as long as both files carried their own copy the
    defect lived in both of them while every test looked at one.
    [Co-developed with claude code -- Adam]

    🔴 2026-09-18, TICKET-P1D: THE TWO COPIES ARE GONE. The reset is one function,
    `reset_for_bring_up`, and each main calls it -- so "the call is present in both files" is
    no longer the property to assert; it would now be satisfied by a main that had somehow
    grown its own second copy back. What is asserted instead is the pair that actually carries
    the guarantee: each main REACHES the one reset, and the one reset decides on what is still
    held AFTER the reap. The third case is the new way to break it, and it has its own cell:
    a main that re-grew a private `clear_switches_from_a_previous_run` would be reporting on a
    reset nobody had refused on.
    """

    def mains(self):
        """{filename: the text of its main()}. Sliced at `def main(` on purpose: the function
        being DEFINED in p4_testbed_topo.py says nothing about either file CALLING it, and a
        test that cannot tell those apart would stay green on the defect it exists for."""
        text, here = testbed_source()
        with open(os.path.join(here, "ntg_bmv2_topo.py")) as fh:
            ntg = fh.read()
        return {"p4_testbed_topo.py": text[text.index("def main("):],
                "ntg_bmv2_topo.py": ntg[ntg.index("def main("):]}

    def the_one_reset(self):
        """The text of `reset_for_bring_up`, the single function both mains go through."""
        text, _here = testbed_source()
        start = text.index("def reset_for_bring_up(")
        end = text.index("\ndef ", start + 1)
        return text[start:end]

    def test_each_main_aborts_on_what_the_reset_could_not_free(self):
        self.assertIn("abort_if_grpc_ports_are_held(", self.the_one_reset(),
                      "reset_for_bring_up goes on and lets a fabric be built on a port it "
                      "knows is taken")
        for name, text in self.mains().items():
            with self.subTest(file=name):
                self.assertIn("reset_for_bring_up(", text,
                              f"{name}'s main() never reaches the reset, so nothing refuses a "
                              f"held port on its path")

    def test_each_main_aborts_after_the_reset_not_before_it(self):
        text = self.the_one_reset()
        reset = text.index("clear_switches_from_a_previous_run(ports=")
        abort = text.index("abort_if_grpc_ports_are_held(")
        self.assertLess(reset, abort,
                        "reset_for_bring_up must decide on what is STILL held after the reap, "
                        "not on what was held before it")

    def test_neither_main_carries_a_second_copy_of_the_reset(self):
        for name, text in self.mains().items():
            with self.subTest(file=name):
                self.assertNotIn("clear_switches_from_a_previous_run(", text,
                                 f"{name}'s main() reaps on its own again -- a second copy of "
                                 f"the reset is how this file's switch list stayed at "
                                 f"range(1, 11) through the whole app-package change")


class GrpcPortIsOpenTest(unittest.TestCase):
    """The probe itself, against a real socket on an ephemeral port -- it is the one part of
    the reset that cannot be injected away without testing nothing."""

    @classmethod
    def setUpClass(cls):
        cls.mod = load_testbed_module()

    def test_a_listening_port_reads_as_open(self):
        import socket as _socket
        server = _socket.socket()
        self.addCleanup(server.close)
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        port = server.getsockname()[1]
        self.assertTrue(self.mod.grpc_port_is_open(port))

    def test_a_port_nothing_holds_reads_as_free(self):
        import socket as _socket
        probe = _socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()                       # nothing is listening there now
        self.assertFalse(self.mod.grpc_port_is_open(port))


if __name__ == "__main__":
    unittest.main()
