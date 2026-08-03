"""
Tests for the route-reinstall debounce in intelligent_router.py.

[Co-developed with claude code -- Adam]

`2c81b26` added this because nothing recomputed routes after a link failed: the graph was never
updated and `install_all_pair_paths` ran exactly once per process, so the rules installed ~60 s after
startup were the final state for the life of the run. Observed live: `link s1 s5 down` with a flow
crossing that link stopped traffic, and it was never rerouted.

A review then found the same defect surviving in a narrower window. `_schedule_route_reinstall`
returns early while the worker is running, and the worker leaves the loop that watches
`topology_change_seq` *before* calling `install_all_pair_paths` -- a walk over 16,256 host pairs,
about 60 s. Any change arriving during that walk was therefore dropped by the early return and never
noticed by the worker, and the log said "route reinstall done" meaning the previous change.

## Why the methods are extracted rather than imported

Importing `intelligent_router` pulls in Ryu, which is only installed in a separate conda env, so
these would not run under the interpreter the rest of the Python suites use. Instead the two methods
are read out of the real file by AST and executed here, so this tests the shipped source -- if
someone edits those methods, this test sees the edit. It is not a copy.

`ryu.lib.hub` is cooperative greenthreads; the logic under test depends on a flag and a counter
rather than on the scheduling discipline, so real threads with scaled-down sleeps are faithful and
much easier to reason about.
"""

from __future__ import annotations

import ast
import os
import threading
import time
import unittest

ROUTER = os.path.join(os.path.dirname(__file__), "..", "..", "intelligent_router.py")
METHODS = ("_schedule_route_reinstall", "_route_reinstall_worker")

# How long the simulated all-pairs walk takes, and the quiet period. Scaled down from 60 s / 3 s but
# keeping the ratio that matters: the walk is much longer than the quiet period.
WALK_SECONDS = 0.40
QUIET_SECONDS = 0.05


def extract_methods():
    """The two methods, verbatim from the real file."""
    with open(ROUTER) as f:
        source = f.read()
    tree = ast.parse(source)
    found = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name in METHODS:
            found[node.name] = ast.get_source_segment(source, node)
    missing = set(METHODS) - set(found)
    if missing:
        raise AssertionError(
            f"intelligent_router.py no longer defines {sorted(missing)}; this test is stale"
        )
    return found


class FakeHub:
    """Stands in for ryu.lib.hub."""

    def __init__(self):
        self.threads = []

    def sleep(self, seconds):
        time.sleep(seconds)

    def spawn(self, fn, *args):
        t = threading.Thread(target=fn, args=args, daemon=True)
        self.threads.append(t)
        t.start()

    def join_all(self, timeout=15.0):
        deadline = time.monotonic() + timeout
        for t in self.threads:
            t.join(timeout=max(0.0, deadline - time.monotonic()))
        return all(not t.is_alive() for t in self.threads)


class FakeLogger:
    def __init__(self):
        self.lines = []

    def _add(self, level, msg, *args, **kwargs):
        try:
            self.lines.append((level, msg % args if args else msg))
        except Exception:
            self.lines.append((level, f"{msg} {args}"))

    def warning(self, msg, *a, **k):
        self._add("W", msg, *a, **k)

    def info(self, msg, *a, **k):
        self._add("I", msg, *a, **k)

    def error(self, msg, *a, **k):
        self._add("E", msg, *a, **k)

    def text(self):
        return "\n".join(f"{lvl} {m}" for lvl, m in self.lines)


class Router:
    """The minimum surface the two methods touch."""

    def __init__(self, walk_seconds=WALK_SECONDS):
        self.topology_change_seq = 0
        self.reinstall_worker_running = False
        self.install_initial_openflow_entries_completed = True
        self.logger = FakeLogger()
        self.walk_seconds = walk_seconds

        self.walk_started = threading.Event()
        self.walks = []            # the seq value observed at the start of each walk
        self.walk_count = 0
        self.raise_in_walk = False

    def _active_net(self):
        return "net"

    def install_all_pair_paths(self, net):
        self.walk_count += 1
        self.walks.append(self.topology_change_seq)
        self.walk_started.set()
        if self.raise_in_walk:
            raise RuntimeError("walk exploded")
        time.sleep(self.walk_seconds)


def make_router(**kwargs):
    """A Router with the real methods bound to it, plus the fake hub they close over."""
    hub = FakeHub()
    namespace = {"hub": hub, "reinstall_quiet_period": QUIET_SECONDS}
    for source in extract_methods().values():
        exec(source, namespace)  # noqa: S102 -- the "source" is this repository's own file

    router = Router(**kwargs)
    for name in METHODS:
        setattr(Router, name, namespace[name])
    return router, hub


class RouteReinstallTest(unittest.TestCase):
    def test_one_operator_action_produces_one_recompute(self):
        # `link a b down` raises one EventLinkDelete per direction, and a switch coming up raises a
        # burst. The debounce exists so those coalesce instead of walking 16,256 pairs several times.
        router, hub = make_router()

        router._schedule_route_reinstall("link 1->5 down")
        router._schedule_route_reinstall("link 5->1 down")
        self.assertTrue(hub.join_all(), "the worker never finished")

        self.assertEqual(router.walk_count, 1, router.logger.text())

    def test_a_change_during_the_walk_is_recomputed(self):
        # The finding. The worker stops watching topology_change_seq before it starts walking, and
        # _schedule_route_reinstall returns early because the worker is still marked running -- so
        # this change used to be dropped entirely, with "route reinstall done" logged for the
        # previous one.
        router, hub = make_router()

        router._schedule_route_reinstall("link 1->5 down")
        self.assertTrue(router.walk_started.wait(timeout=5.0), "the first walk never started")
        seq_before = router.topology_change_seq

        # A second switch fails while the first recompute is still running.
        router._schedule_route_reinstall("link 2->6 down")
        self.assertTrue(router.reinstall_worker_running, "test is not exercising the early-return path")
        self.assertGreater(router.topology_change_seq, seq_before)

        self.assertTrue(hub.join_all(), "the worker never finished")
        self.assertGreaterEqual(
            router.walk_count,
            2,
            "a topology change that arrived during the recompute was never acted on:\n"
            + router.logger.text(),
        )
        self.assertIn(
            "topology changed again during the recompute",
            router.logger.text(),
            "the second pass ran but nothing said why",
        )

    def test_the_last_change_is_always_covered_by_a_later_walk(self):
        # The property that actually matters, stated directly: whatever the timing, the final walk
        # must start no earlier than the last change. Anything else leaves stale rules.
        router, hub = make_router()

        router._schedule_route_reinstall("first")
        self.assertTrue(router.walk_started.wait(timeout=5.0))
        router.walk_started.clear()
        router._schedule_route_reinstall("second, mid-walk")
        last_seq = router.topology_change_seq

        self.assertTrue(hub.join_all())
        self.assertTrue(
            any(seen_at_start >= last_seq for seen_at_start in router.walks),
            f"no walk observed the final change (walks saw {router.walks}, last change was "
            f"seq {last_seq}):\n{router.logger.text()}",
        )

    def test_the_worker_flag_is_always_cleared(self):
        # If the flag stuck, every later change would take the early return forever and the whole
        # mechanism would be dead for the rest of the run.
        router, hub = make_router()
        router._schedule_route_reinstall("x")
        self.assertTrue(hub.join_all())
        self.assertFalse(router.reinstall_worker_running)

    def test_a_walk_that_raises_clears_the_flag_and_is_logged(self):
        # A greenlet that dies takes its traceback with it. If this stopped clearing the flag, one
        # exception would silently disable rerouting for the life of the process.
        router, hub = make_router()
        router.raise_in_walk = True

        router._schedule_route_reinstall("x")
        self.assertTrue(hub.join_all())

        self.assertFalse(router.reinstall_worker_running, "the flag stuck after an exception")
        self.assertIn("route reinstall failed", router.logger.text())

    def test_nothing_is_installed_before_the_initial_install_has_run(self):
        # Recomputing before the initial install would race it, and the initial install covers the
        # current graph anyway.
        router, hub = make_router()
        router.install_initial_openflow_entries_completed = False

        router._schedule_route_reinstall("early change")
        self.assertTrue(hub.join_all())

        self.assertEqual(router.walk_count, 0)
        self.assertIn("initial install has not run yet", router.logger.text())
        self.assertFalse(router.reinstall_worker_running)

    def test_a_change_arriving_while_the_quiet_period_runs_restarts_it(self):
        # The debounce proper: a burst spread over more than one quiet period must still produce one
        # walk, and that walk must start after the last event of the burst.
        router, hub = make_router()

        router._schedule_route_reinstall("burst 1")
        for _ in range(4):
            time.sleep(QUIET_SECONDS * 0.6)
            router._schedule_route_reinstall("burst n")
        last_seq = router.topology_change_seq

        self.assertTrue(hub.join_all())
        self.assertEqual(router.walk_count, 1, router.logger.text())
        self.assertGreaterEqual(router.walks[0], last_seq, "the walk started before the burst ended")


if __name__ == "__main__":
    unittest.main()
