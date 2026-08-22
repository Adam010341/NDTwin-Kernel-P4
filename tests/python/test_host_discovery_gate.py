"""
Tests for the host-discovery gate that replaced the fixed pre-walk sleep.

[Co-developed with claude code -- Adam]

## What broke, and why a test exists at all

`load_static_topology` used to `hub.sleep(settle_seconds)` before walking all host pairs and
installing routes. Nobody recorded what the sleep was for, so it was shortened 60 -> 10 on the
evidence that the data plane forwards fine at 3 s. It does. What the sleep was actually holding
open was Ryu's only chance to learn host IPv4 addresses:

    settle=60 -> Ryu knows 128/128 host IPv4s -> kernel graph 288 up /   0 down
    settle=10 -> Ryu knows   0/128            -> kernel graph  32 up / 256 down

Mechanism, pinned by intervention in e5e4980: a host's IPv4 reaches Ryu only via packet-in.
Once the all-pairs rules are installed nothing IPv4 punts again, and the fixture's static ARP
closes the ARP path -- so the learning window is exactly [switch connect, all-pairs install] and
no amount of later traffic can reopen it. The sleep length was silently deciding whether the
digital twin could see 256 of its own 288 links, on a network that forwards perfectly.

The fix waits for the event instead of guessing its duration. `NDTWIN_RYU_SETTLE_S` is now a
deadline, not a wait.

## The mutation this file exists to kill

`_hosts_with_ipv4` counts `if h.ipv4` -- truthiness, not `is not None`. Ryu initialises `ipv4`
to an empty list, so `is not None` counts every host from the instant it is discovered, the gate
returns immediately on a fabric that has learned nothing, and the regression comes back with
*better* boot numbers than the fix. `test_a_host_with_an_empty_ipv4_list_is_not_learned` is that
test; if it ever goes green under `is not None`, the gate is decorative.

## Why the methods are extracted rather than imported

Same as test_route_install_gate.py: importing `intelligent_router` pulls in Ryu, which lives in a
separate conda env. The methods are read out of the real file by AST and executed against stubs,
so this tests the shipped source -- an edit to either method is an edit these tests see.
"""

from __future__ import annotations

import ast
import os
import unittest

ROUTER = os.path.join(os.path.dirname(__file__), "..", "..", "intelligent_router.py")
METHODS = ("_hosts_with_ipv4", "_await_host_discovery")


class Recorder:
    def __init__(self):
        self.infos = []
        self.warnings = []
        self.exceptions = []

    def info(self, msg, *args):
        self.infos.append(msg % args if args else msg)

    def warning(self, msg, *args):
        self.warnings.append(msg % args if args else msg)

    def exception(self, msg, *args):
        self.exceptions.append(msg % args if args else msg)


class FakeHost:
    """Ryu's Host: `ipv4` is a list, empty until a packet-in carries an address."""

    def __init__(self, ipv4=None):
        self.ipv4 = list(ipv4 or [])


class Clock:
    """
    A hub.sleep that advances a virtual clock instead of a real one, and can hand control back
    to the test at each tick. `on_tick(elapsed)` may mutate the host table, which is how a test
    says "the ping burst lands at t=7" without waiting seven seconds.
    """

    def __init__(self, on_tick=None):
        self.elapsed = 0
        self.sleeps = []
        self.on_tick = on_tick

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.elapsed += seconds
        if self.on_tick:
            self.on_tick(self.elapsed)


class Router:
    """The attributes the two methods touch, and nothing else."""

    def __init__(self, hosts):
        self.logger = Recorder()
        self.hosts = hosts


def load_gate(hosts, *, on_tick=None, get_all_host=None):
    """
    Compiles both real methods against stubs.

    Returns (router, clock, call_await, call_count). `hosts` is a live list the test may mutate
    (or replace the contents of) from `on_tick`.
    """
    with open(ROUTER) as fh:
        tree = ast.parse(fh.read())

    funcs = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name in METHODS:
            node.decorator_list = []
            funcs[node.name] = node
    missing = set(METHODS) - set(funcs)
    assert not missing, f"{sorted(missing)} not found in {ROUTER} -- renamed or removed?"

    clock = Clock(on_tick=on_tick)
    ns = {
        "hub": type("hub", (), {"sleep": staticmethod(clock.sleep)})(),
        "get_all_host": get_all_host or (lambda _app: hosts),
    }
    module = ast.Module(body=[funcs[n] for n in METHODS], type_ignores=[])
    exec(compile(module, ROUTER, "exec"), ns)

    router = Router(hosts)
    # _await_host_discovery calls self._hosts_with_ipv4(); bind the extracted one onto the stub.
    router._hosts_with_ipv4 = lambda: ns["_hosts_with_ipv4"](router)

    return (router, clock,
            lambda expected, deadline: ns["_await_host_discovery"](router, expected, deadline),
            lambda: ns["_hosts_with_ipv4"](router))


class HostsWithIpv4Test(unittest.TestCase):
    def test_a_host_with_an_empty_ipv4_list_is_not_learned(self):
        # THE load-bearing assertion. Ryu creates Host objects with ipv4=[] the moment it sees
        # the MAC; only a packet-in carrying an address fills the list. Counting those as
        # learned makes the gate return instantly on exactly the broken fabric it exists to
        # catch -- and boot gets *faster*, so nothing looks wrong.
        _, _, _, count = load_gate([FakeHost(), FakeHost(), FakeHost()])
        self.assertEqual(count(), 0,
                         "hosts with an empty ipv4 list were counted as learned; the gate would "
                         "pass immediately on a fabric that has learned nothing")

    def test_hosts_with_addresses_are_counted(self):
        # The accept path: without it, a count() that always returns 0 passes the test above.
        _, _, _, count = load_gate([FakeHost(["10.0.0.1"]), FakeHost(), FakeHost(["10.0.0.3"])])
        self.assertEqual(count(), 2)

    def test_a_topology_api_failure_counts_as_zero_and_does_not_raise(self):
        # Fail-open: this runs on the boot path, and an exception here would take the whole
        # control plane down rather than degrade the twin's view.
        def boom(_app):
            raise RuntimeError("topology API hiccup")

        router, _, _, count = load_gate([], get_all_host=boom)
        self.assertEqual(count(), 0)
        self.assertTrue(router.logger.exceptions,
                        "swallowed a topology-API failure without logging it")


class AwaitHostDiscoveryTest(unittest.TestCase):
    def test_an_already_learned_fabric_does_not_wait(self):
        # The boot-time claim. If this regresses, every OVS boot pays the full deadline.
        hosts = [FakeHost([f"10.0.0.{i}"]) for i in range(1, 5)]
        router, clock, run, _ = load_gate(hosts)
        run(4, 90)
        self.assertEqual(clock.elapsed, 0,
                         f"waited {clock.elapsed}s although every host was already learned")
        self.assertTrue(any("discovery complete" in m for m in router.logger.infos),
                        f"exited without saying why: {router.logger.infos}")

    def test_it_waits_for_the_event_not_for_the_deadline(self):
        # The correctness claim, and the difference between this and a fixed sleep: the burst
        # lands at t=7 and the gate returns at t=7, not at t=90.
        hosts = [FakeHost() for _ in range(4)]

        def burst(elapsed):
            if elapsed == 7:
                for i, h in enumerate(hosts, start=1):
                    h.ipv4 = [f"10.0.0.{i}"]

        router, clock, run, _ = load_gate(hosts, on_tick=burst)
        run(4, 90)
        self.assertEqual(clock.elapsed, 7,
                         f"returned at {clock.elapsed}s for an event that happened at 7s")
        self.assertTrue(any("4/4" in m for m in router.logger.infos),
                        f"did not report what it saw: {router.logger.infos}")

    def test_a_partial_fabric_runs_the_deadline_out_then_proceeds(self):
        # Fail-open, and loudly. A control plane that refuses to install routes because discovery
        # was incomplete breaks the network; one that proceeds only breaks a view.
        hosts = [FakeHost(["10.0.0.1"])] + [FakeHost() for _ in range(3)]
        router, clock, run, _ = load_gate(hosts)
        run(4, 30)

        self.assertEqual(clock.elapsed, 30, "did not wait out its deadline")
        joined = " | ".join(router.logger.warnings)
        self.assertTrue(router.logger.warnings,
                        "gave up on host discovery silently -- this is the failure mode that "
                        "produced 256 down edges with no log line to explain them")
        self.assertIn("1/4", joined, f"the warning does not say how many were learned: {joined}")
        self.assertIn("6", joined,
                      f"the warning does not predict the down-edge count (2 per unlearned host, "
                      f"so 6 here), which is the symptom an operator actually sees: {joined}")

    def test_no_hosts_in_the_model_falls_back_to_the_old_sleep(self):
        # A model with no hosts must not turn the gate into a silent no-wait: nothing would be
        # waiting for the switches to finish dialling in, and the failure would be a fabric that
        # boots faster and routes worse.
        router, clock, run, _ = load_gate([])
        run(0, 25)
        self.assertEqual(clock.elapsed, 25,
                         "an empty host model skipped the wait entirely instead of falling back")

    def test_a_zero_deadline_disables_the_wait(self):
        # The documented escape hatch -- NDTWIN_RYU_SETTLE_S=0 restores no-wait behaviour.
        hosts = [FakeHost() for _ in range(4)]
        _, clock, run, _ = load_gate(hosts)
        run(4, 0)
        self.assertEqual(clock.elapsed, 0, "slept although the wait was disabled")

    def test_it_polls_in_small_steps_rather_than_one_long_sleep(self):
        # A gate that sleeps the whole deadline and checks once at the end is a fixed sleep
        # wearing a gate's name: it would return at t=90 for an event at t=7.
        hosts = [FakeHost() for _ in range(4)]
        _, clock, run, _ = load_gate(hosts)
        run(4, 10)
        self.assertTrue(all(s <= 1 for s in clock.sleeps),
                        f"polled in steps of {sorted(set(clock.sleeps))}s; an event landing "
                        f"early inside one of those is not noticed until it ends")


if __name__ == "__main__":
    unittest.main(verbosity=2)
