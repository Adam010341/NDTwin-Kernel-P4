"""
Tests for the switch-count gate that decides whether initial routes are installed.

[Co-developed with claude code -- Adam]

`get_topology_data` ends with:

    if len(self.switches) >= switch_num:
        if not self.install_initial_openflow_entries_completed:
            self.load_static_topology()

`load_static_topology` is the only trigger for the initial route install, and `switch_num` is a
hardcoded 10 rather than the count the topology file declares. So a fabric of nine switches
connects, is reported to the kernel, answers every liveness probe -- and never installs a single
route. The only trace was an INFO line printing the count, with nothing to say the count was
load-bearing.

The gate itself is deliberately unchanged: whether 10 is the right threshold is a deployment
question the owner is reviewing. What is tested here is that the silent case stopped being silent.

## Why the method is extracted rather than imported

Same reason as test_route_reinstall.py: importing `intelligent_router` pulls in Ryu, which lives
in a separate conda env, so the file cannot be imported by the interpreter the rest of the Python
suites use. The method is read out of the real file by AST and executed against stubs, so this
tests the shipped source -- an edit to the method is an edit this test sees. It is not a copy.
"""

from __future__ import annotations

import ast
import os
import unittest

ROUTER = os.path.join(os.path.dirname(__file__), "..", "..", "intelligent_router.py")
METHOD = "get_topology_data"


class Recorder:
    """Stands in for self.logger, keeping every call so a test can ask what was said."""

    def __init__(self):
        self.infos = []
        self.warnings = []

    def info(self, msg, *args):
        self.infos.append(msg % args if args else msg)

    def warning(self, msg, *args):
        self.warnings.append(msg % args if args else msg)

    def error(self, msg, *args):
        self.warnings.append(msg % args if args else msg)


class FakeNet:
    def __init__(self):
        self.nodes = set()
        self.edges = []

    def has_node(self, n):
        return n in self.nodes

    def add_node(self, n):
        self.nodes.add(n)

    def add_edge(self, a, b, **kw):
        self.edges.append((a, b))


class Router:
    """The attributes get_topology_data touches, and nothing else."""

    def __init__(self, installed=False):
        self.logger = Recorder()
        self.dynamic_net = FakeNet()
        self.topology_api_app = object()
        self.switches = {}
        self.install_initial_openflow_entries_completed = installed
        self._initial_watchdog_started = False
        # Added 2026-08-24 for the async-install path. This stub has now been short of a real
        # attribute twice; the first time (_initial_watchdog_started) is why this file exists.
        self._static_topology_spawned = False
        self.load_static_topology_calls = 0

    def load_static_topology(self):
        self.load_static_topology_calls += 1

    def _initial_install_watchdog(self):
        pass



def _hub_recording(spawned):
    """A hub stub whose spawn() records the callable instead of running it."""
    return type("hub", (), {
        "sleep": staticmethod(lambda _s: None),
        "spawn": staticmethod(lambda f, *a, **k: spawned.append(f)),
    })()


def load_method(switch_count, *, threshold=10, async_install=False):
    """
    Compiles the real get_topology_data against stubs, with `switch_count` switches connected.

    Returns (bound_callable, router). `switch_num` is injected as the module global the method
    reads, so a test can state the threshold it is exercising rather than depend on today's 10.
    """
    with open(ROUTER) as fh:
        tree = ast.parse(fh.read())

    func = next((n for n in ast.walk(tree)
                 if isinstance(n, ast.FunctionDef) and n.name == METHOD), None)
    assert func is not None, f"{METHOD} not found in {ROUTER} -- was it renamed?"
    # The method carries Ryu's @set_ev_cls; the decorator is registration, not behaviour, and
    # evaluating it would need the Ryu import this whole approach exists to avoid.
    func.decorator_list = []

    switches = [type("Sw", (), {"dp": type("Dp", (), {"id": i})()})()
                for i in range(1, switch_count + 1)]
    spawned = []

    ns = {
        "time": lambda: 0.0,
        "hub": _hub_recording(spawned),
        "get_switch": lambda _app, _x: switches,
        "get_link": lambda _app, _x: [],
        "requests": type("requests", (), {
            "get": staticmethod(lambda *_a, **_k: type("R", (), {"status_code": 200})())
        })(),
        "switch_num": threshold,
        # The async-install flag and its spawn target. Injected as a module global so a test can
        # exercise either branch without depending on the process environment.
        "_async_topology_install": async_install,
        # The waiting-warning enumerates who is absent against the declared fabric; declare a
        # fabric of exactly `threshold` dpids so "short by one" means dpid `threshold` is missing.
        "expected_switch_dpids": list(range(1, threshold + 1)),
        "_switch_num_source": "test stub",
        "initial_install_deadline": 180,
    }
    exec(compile(ast.Module(body=[func], type_ignores=[]), ROUTER, "exec"), ns)

    router = Router()
    router.spawned = spawned
    ev = type("Ev", (), {"switch": type("S", (), {"dp": type("D", (), {"id": 1})()})()})()
    return (lambda: ns[METHOD](router, ev)), router


class RouteInstallGateTest(unittest.TestCase):
    def test_a_full_fabric_installs_routes(self):
        # The accept path. Without it, a gate that never installs anything would satisfy every
        # assertion below about the short-fabric case.
        run, router = load_method(switch_count=10, threshold=10)
        run()
        self.assertEqual(router.load_static_topology_calls, 1,
                         "a complete fabric did not trigger the initial route install")
        self.assertEqual(router.logger.warnings, [],
                         f"warned about a fabric that is complete: {router.logger.warnings}")

    def test_a_short_fabric_says_no_routes_will_be_installed(self):
        run, router = load_method(switch_count=9, threshold=10)
        run()

        self.assertEqual(router.load_static_topology_calls, 0,
                         "precondition: the gate should not have opened")
        joined = " | ".join(router.logger.warnings)
        self.assertTrue(router.logger.warnings,
                        "nine switches connected, no routes installed, and nothing said so")
        self.assertIn("9", joined, f"the warning does not say how many are connected: {joined}")
        self.assertIn("10", joined, f"the warning does not say how many are required: {joined}")
        self.assertIn("route", joined.lower(),
                      f"the warning does not say what is not happening: {joined}")

    def test_a_short_fabric_that_already_installed_does_not_warn(self):
        # Reconnections after the install has happened are routine, and a warning per reconnect
        # would be the log flood this project keeps having to undo.
        run, router = load_method(switch_count=9, threshold=10)
        router.install_initial_openflow_entries_completed = True
        run()

        self.assertEqual(router.load_static_topology_calls, 0)
        self.assertEqual(router.logger.warnings, [],
                         f"warned although routes were already installed: {router.logger.warnings}")

    def test_the_gate_itself_is_unchanged(self):
        # The owner is reviewing why the threshold is 10; this records that nothing here moved it.
        run, router = load_method(switch_count=9, threshold=10)
        run()
        self.assertEqual(router.load_static_topology_calls, 0,
                         "the gate opened below its threshold -- the warning was supposed to be "
                         "the whole change")


class AsyncTopologyInstallTest(unittest.TestCase):
    """
    Whether the settle wait and the all-pairs walk run ON the event handler.

    [Co-developed with claude code -- Adam]
    `load_static_topology` blocks for the settle wait plus the walk. Inline, that blocking sits
    on this app's event queue, which Ryu bounds at 128 -- and this app also observes
    EventOFPPacketIn, so punted LLDP fills those slots at ~2.5/s while the handler is stuck.
    The review session's phase-1 diagnosis makes that the cycle behind six-of-ten boot failures,
    and its operative conclusion is that any fix keeping blocking work in EventSwitchEnter keeps
    the cycle.

    The flag is off by default because the mechanism is INFERRED, not confirmed. Both branches
    are tested so flipping it is a one-line change with coverage already in place, rather than a
    switch nobody has exercised -- this repo has shipped one of those in each direction.
    """

    def test_inline_by_default(self):
        run, router = load_method(switch_count=10, threshold=10)
        run()
        self.assertEqual(router.load_static_topology_calls, 1,
                         "the default path must still install routes")
        self.assertNotIn(router.load_static_topology, router.spawned,
                         "the walk was handed to a greenlet with the flag off")

    def test_async_spawns_instead_of_blocking(self):
        run, router = load_method(switch_count=10, threshold=10, async_install=True)
        run()
        self.assertEqual(router.load_static_topology_calls, 0,
                         "the handler ran the walk inline despite the async flag -- which is "
                         "exactly the blocking this flag exists to remove")
        self.assertIn(router.load_static_topology, router.spawned,
                      "the walk was not handed to a greenlet")

    def test_async_spawns_at_most_one_walk(self):
        # THE load-bearing one. install_initial_openflow_entries_completed is only set after the
        # walk finishes, so every enter event arriving inside that window sees it False. Without
        # its own guard set BEFORE the spawn, each would spawn another walk -- concurrent
        # all-pairs walks issuing OFPFC_ADD for the same (switch, ipv4_dst), which is a defect
        # this file already had to fix once for the reinstall worker.
        run, router = load_method(switch_count=10, threshold=10, async_install=True)
        run()
        run()
        run()
        walks = [f for f in router.spawned if f == router.load_static_topology]
        self.assertEqual(len(walks), 1,
                         f"three enter events spawned {len(walks)} walks")

    def test_the_spawned_callable_is_the_walk(self):
        # A spawn of the wrong callable would satisfy every count above and install nothing.
        run, router = load_method(switch_count=10, threshold=10, async_install=True)
        run()
        self.assertIn(router.load_static_topology, router.spawned)



if __name__ == "__main__":
    unittest.main()
