"""
Tests for the switch-count gate that decides whether initial routes are installed.

[Co-developed with claude code -- Adam]

The gate is:

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

## The gate moved, and this file did not notice for a while

It used to sit at the tail of `get_topology_data`. The ring fix (2026-08-25) moved the whole
rebuild onto `_topology_worker` and left `get_topology_data` as a queueing shim, so the gate now
lives in `_maybe_install_initial_routes`. **Every test in this file errored against the new
handler and the ring round shipped without running them** -- extracting a method by name is only
as good as the name, and a rename or a move turns these from "passing" into "erroring", which is
at least loud. Retargeted 2026-08-25.

`SwitchEnterHandlerTest` was added at the same time and covers what the shim itself now promises,
because that was the part with no test at this level: the coalescing suite stubs the handler out.

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
METHOD = "_maybe_install_initial_routes"       # the gate; moved here from get_topology_data
HANDLER = "get_topology_data"                  # what is left of the handler after the ring fix


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


class DirtyFlag:
    """hub.Event's two methods that the handler uses, and a record of every set()."""

    def __init__(self):
        self._set = False
        self.sets = 0

    def is_set(self):
        return self._set

    def set(self):
        self._set = True
        self.sets += 1

    def clear(self):
        self._set = False


class Router:
    """The attributes the gate and the switch-enter handler touch, and nothing else."""

    def __init__(self, installed=False):
        self.logger = Recorder()
        self.dynamic_net = FakeNet()
        self.topology_api_app = object()
        self.switches = {}
        self.install_initial_openflow_entries_completed = installed
        self._initial_watchdog_started = False
        # Added 2026-08-24 for the async-install path. This stub has now been short of a real
        # attribute three times; the first (_initial_watchdog_started) is why this file exists,
        # and the third was the ring fix moving the rebuild onto a worker.
        self._static_topology_spawned = False
        self.load_static_topology_calls = 0
        # What get_topology_data became after the ring fix: a queue, a flag and a worker.
        self._pending_switch_dpids = set()
        self._topology_dirty = DirtyFlag()
        self._topology_coalesced = 0
        self._topology_worker_started = False

    def load_static_topology(self):
        self.load_static_topology_calls += 1

    def _initial_install_watchdog(self):
        pass

    def _topology_worker(self):
        pass



def _hub_recording(spawned):
    """A hub stub whose spawn() records the callable instead of running it."""
    return type("hub", (), {
        "sleep": staticmethod(lambda _s: None),
        "spawn": staticmethod(lambda f, *a, **k: spawned.append(f)),
    })()


def load_method(switch_count, *, threshold=10, async_install=False, method=METHOD, router=None):
    """
    Compiles the real gate (or handler) against stubs, with `switch_count` switches connected.

    Returns (bound_callable, router). `switch_num` is injected as the module global the method
    reads, so a test can state the threshold it is exercising rather than depend on today's 10.
    """
    with open(ROUTER) as fh:
        tree = ast.parse(fh.read())

    func = next((n for n in ast.walk(tree)
                 if isinstance(n, ast.FunctionDef) and n.name == method), None)
    assert func is not None, f"{method} not found in {ROUTER} -- was it renamed?"
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

    router = Router() if router is None else router
    router.spawned = spawned
    router.switches = {i: object() for i in range(1, switch_count + 1)}

    if method == HANDLER:
        # The only method here that still takes an event.
        return (lambda dpid=1: ns[method](
            router, type("Ev", (), {"switch": type("S", (), {"dp": type("D", (), {"id": dpid})()})()})()
        )), router
    return (lambda: ns[method](router)), router


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
    EventOFPPacketIn, so punted packet-ins fill those slots while the handler is stuck.
    The review session's phase-1 diagnosis makes that the cycle behind six-of-ten boot failures,
    and its operative conclusion is that any fix keeping blocking work in EventSwitchEnter keeps
    the cycle.

    This docstring used to say "punted LLDP ... at ~2.5/s", a number nobody had measured.
    Measured 2026-08-25 (doc/audit/2026-08-25_ring-edge-fix Phase 5): 56-72/s over a boot,
    136-210/s over the opening burst, so the 128 slots fill in 1.8-2.3 s rather than the ~50 s
    the old figure implied -- and the LLDP guard moves that rate only 1.22x across a five-fold
    change, so the stream is not LLDP-dominated either. See intelligent_router's comment on the
    same branch for the library lines that explain the missing leverage.

    The flag is no longer load-bearing: since the rebuild moved to _topology_worker neither
    branch runs on the event loop, so this is now an ordinary latency choice rather than the
    difference between a wedge and a boot. Both branches stay tested because that reclassification
    is itself an unverified claim -- it was made in the same commit that moved the rebuild.
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


class SwitchEnterHandlerTest(unittest.TestCase):
    """What `get_topology_data` still promises now that the rebuild left it.

    [Co-developed with claude code -- Adam]
    The ring fix reduced this handler to three things -- record the dpid, mark the topology
    dirty, make sure a worker exists -- and its whole value is that none of them can block. The
    coalescing suite next door stubs the handler out to test the worker, so until now nothing
    exercised the shipped handler body at all; the gate suite in this file did, and stopped
    silently when the gate moved out from under it.

    The load-bearing one is the single spawn. Ten switches enter at boot, and a handler that
    spawned per event would start ten workers on the same dirty flag -- ten concurrent rebuilds,
    which is the defect the coalescing worker exists to prevent, reintroduced one level up.
    """

    def _handler(self, router=None):
        return load_method(switch_count=10, threshold=10, method=HANDLER, router=router)

    def test_the_dpid_is_queued_for_the_worker(self):
        run, router = self._handler()
        run(dpid=7)
        self.assertEqual(router._pending_switch_dpids, {7},
                         "the worker drains this set; a dpid missing from it is a switch that "
                         "never gets notified")

    def test_it_marks_the_topology_dirty(self):
        run, router = self._handler()
        run()
        self.assertTrue(router._topology_dirty.is_set(),
                        "the worker waits on this flag -- unset means the rebuild never runs")

    def test_the_worker_is_spawned_exactly_once_for_ten_switches(self):
        run, router = self._handler()
        for dpid in range(1, 11):
            run(dpid=dpid)
        workers = [f for f in router.spawned if f == router._topology_worker]
        self.assertEqual(len(workers), 1,
                         f"ten enter events spawned {len(workers)} workers; each one is another "
                         f"concurrent rebuild of the same graph")
        self.assertEqual(router._pending_switch_dpids, set(range(1, 11)),
                         "every switch that entered must still be queued for the batch")

    def test_a_second_event_while_dirty_is_counted_as_coalesced(self):
        # The counter is what the SIGUSR2 dump reports; if it never moves, the dump says the
        # worker is keeping up when it is actually behind.
        run, router = self._handler()
        run(dpid=1)
        self.assertEqual(router._topology_coalesced, 0, "the first event coalesced nothing")
        run(dpid=2)
        run(dpid=3)
        self.assertEqual(router._topology_coalesced, 2)

    def test_it_says_a_switch_was_queued_rather_than_rebuilt(self):
        # `Topology update triggered` counts rebuilds after the fix, so without this line the
        # event count and the rebuild count become impossible to tell apart in a log.
        run, router = self._handler()
        run(dpid=4)
        joined = " | ".join(router.logger.infos)
        self.assertIn("queued", joined.lower(),
                      f"nothing in the log distinguishes an event from a rebuild: {joined}")
        self.assertIn("4", joined, f"the line does not say which switch: {joined}")

    def test_the_handler_does_not_read_the_topology(self):
        """The invariant, at the one place it can be checked without a fabric.

        Any get_switch/get_link/get_all_host in this body is a synchronous request-reply back on
        the event loop, which is the ring. Checked against the source rather than a run, because
        a call that is present but not taken on this path would still close the ring on another.
        """
        with open(ROUTER) as fh:
            tree = ast.parse(fh.read())
        func = next(n for n in ast.walk(tree)
                    if isinstance(n, ast.FunctionDef) and n.name == HANDLER)
        called = {n.func.id for n in ast.walk(func)
                  if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        forbidden = called & {"get_switch", "get_link", "get_all_host", "send_request"}
        self.assertEqual(forbidden, set(),
                         f"{HANDLER} calls {sorted(forbidden)} -- a synchronous request-reply on "
                         f"the event loop is the ring this fix removed")


if __name__ == "__main__":
    unittest.main()
