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
import signal
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from fastapi import HTTPException  # noqa: E402

from proxy_agent import api_routes, topology_manager  # noqa: E402
from proxy_agent.topology_manager import TopologyManager  # noqa: E402

H1, H2 = "10.0.50.1", "10.0.50.2"


class FakeClient:
    """
    A P4RuntimeClient double that records the order things happened to it and can fail on
    demand at each independent step. Shape follows test_startup.FakeClient; `log` is shared
    across clients so cross-client ordering is observable.
    """

    def __init__(self, dpid, log=None, start_error=None, pipeline_error=None,
                 clone_ok=True, route_ok=True, mastership_confirmed=True):
        self.dpid = dpid
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

    def wire(self, result):
        fake = SentinelFactory(result)
        api_routes.topology = fake
        api_routes.inject_readopt(make_factory, sample_sink)
        return fake

    def test_no_topology_is_503(self):
        api_routes.topology = None
        api_routes.inject_readopt(make_factory, sample_sink)
        with self.assertRaises(HTTPException) as ctx:
            api_routes.readopt(1)
        self.assertEqual(ctx.exception.status_code, 503)

    def test_unwired_factory_is_503_and_says_so(self):
        # The kernel retries a 503; a 500 looks like a bug in the proxy. "Not wired yet"
        # is the proxy-restart window, and it must be distinguishable.
        api_routes.topology = SentinelFactory({"status": "success"})
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


# --- write_manifest -------------------------------------------------------------------

def load_testbed_module():
    """
    Import p4_testbed_topo.py with mininet stubbed out. The stubs are bare types: nothing
    from mininet participates in write_manifest, the module merely imports it at top level.
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
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "mininet", "p4_testbed_topo.py")
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


if __name__ == "__main__":
    unittest.main()
