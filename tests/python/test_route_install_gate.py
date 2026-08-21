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
        self.load_static_topology_calls = 0

    def load_static_topology(self):
        self.load_static_topology_calls += 1

    def _initial_install_watchdog(self):
        pass


def load_method(switch_count, *, threshold=10):
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

    ns = {
        "time": lambda: 0.0,
        "hub": type("hub", (), {"sleep": staticmethod(lambda _s: None),
                                "spawn": staticmethod(lambda _f: None)})(),
        "get_switch": lambda _app, _x: switches,
        "get_link": lambda _app, _x: [],
        "requests": type("requests", (), {
            "get": staticmethod(lambda *_a, **_k: type("R", (), {"status_code": 200})())
        })(),
        "switch_num": threshold,
        # The waiting-warning enumerates who is absent against the declared fabric; declare a
        # fabric of exactly `threshold` dpids so "short by one" means dpid `threshold` is missing.
        "expected_switch_dpids": list(range(1, threshold + 1)),
        "_switch_num_source": "test stub",
        "initial_install_deadline": 180,
    }
    exec(compile(ast.Module(body=[func], type_ignores=[]), ROUTER, "exec"), ns)

    router = Router()
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


if __name__ == "__main__":
    unittest.main()
