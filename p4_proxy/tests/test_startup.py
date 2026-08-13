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
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import proxy_agent.main as main  # noqa: E402
from proxy_agent.main import startup  # noqa: E402


class FakeClient:
    """A bmv2 switch that can be made to fail at each independent step."""

    def __init__(self, dpid, pipeline_error=None, clone_ok=True, json_path="pipeline.json",
                 stop_error=None):
        self.dpid = dpid
        self.stop_error = stop_error
        self.json_path = json_path
        self.pipeline_error = pipeline_error
        self.clone_ok = clone_ok
        self.sample_callback = None
        #: Every step this client was put through, in order. Order is part of the contract: the
        #: clone session lives in the pipeline's PRE, so programming it before the pipeline push
        #: would be silently discarded and the switch would report zero traffic forever.
        self.events = []

    def set_forwarding_pipeline_config(self):
        self.events.append("pipeline")
        if self.pipeline_error is not None:
            raise self.pipeline_error

    def write_clone_session(self):
        self.events.append("clone")
        return self.clone_ok

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


def run_startup(clients, *, kernel=None, agent_ips=None, sflow=None, topo=None):
    """Drives startup with fakes and no settling delay, and returns (summary, parts)."""
    kernel = kernel if kernel is not None else FakeKernel()
    sflow = sflow if sflow is not None else FakeSflow()
    topo = topo if topo is not None else FakeTopo()
    ips = {dpid: f"192.168.123.{10 + dpid}" for dpid in clients} if agent_ips is None else agent_ips
    summary = asyncio.run(startup(
        lambda: clients, sflow, kernel, topo,
        settle_seconds=0, agent_ips_loader=lambda: ips,
    ))
    return summary, {"kernel": kernel, "sflow": sflow, "topo": topo}


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


if __name__ == "__main__":
    unittest.main()
