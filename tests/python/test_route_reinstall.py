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

#: Scaled down from 240 s. The worker waits this long for the *initial* install before recomputing
#: anyway; both outcomes are exercised below.
INITIAL_WAIT_LIMIT = 2


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
    namespace = {
        "hub": hub,
        "reinstall_quiet_period": QUIET_SECONDS,
        "initial_install_wait_limit": INITIAL_WAIT_LIMIT,
    }
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

    def test_a_change_before_the_initial_install_waits_for_it_then_recomputes(self):
        # This used to `return`, on the stated grounds that "the initial install will cover the
        # current graph when it does". It will not: the initial walk may have *started before* this
        # change arrived, so it is walking a graph that predates it. Returning dropped the change.
        router, hub = make_router()
        router.install_initial_openflow_entries_completed = False

        router._schedule_route_reinstall("link down during the initial install")

        # The initial install finishes while the worker is waiting.
        time.sleep(QUIET_SECONDS * 2)
        router.install_initial_openflow_entries_completed = True

        self.assertTrue(hub.join_all())
        self.assertGreaterEqual(
            router.walk_count,
            1,
            "the change was dropped because the initial install had not finished:\n"
            + router.logger.text(),
        )
        self.assertFalse(router.reinstall_worker_running)

    def test_it_recomputes_anyway_if_the_initial_install_never_finishes(self):
        # An initial install that never completes has probably thrown, and then there are no routes
        # at all -- so a walk is exactly what is wanted. Waiting forever would park the greenlet and
        # leave the fabric with whatever it had.
        router, hub = make_router()
        router.install_initial_openflow_entries_completed = False

        router._schedule_route_reinstall("link down, initial install wedged")
        self.assertTrue(hub.join_all(timeout=INITIAL_WAIT_LIMIT + 10))

        self.assertGreaterEqual(router.walk_count, 1, router.logger.text())
        self.assertIn("recomputing anyway", router.logger.text())
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


class CompletionFlagOrderTest(unittest.TestCase):
    """
    The flag must be set *after* the walk it reports on, in every startup path.

    A structural test, read off the AST, and the reason it is one is worth stating: the invariant is
    the order of two adjacent statements in the startup method, and the reinstall worker -- the only
    thing that reads the flag -- lives in a different method. A behavioural test at the level of this
    file cannot see the startup path at all, so mutating the order left every other test green. An
    admitted structural check beats no coverage of a fault whose symptom is nondeterministic routing.

    What went wrong: the static path (the mode the manual documents) set the flag *before* the ~60 s
    initial walk, so it read True for the whole walk. The worker's guard is
    `if not ...completed: return`, so a link event during the walk passed it and started a second,
    concurrent walk. hub is cooperative so nothing corrupts, but both issue OFPFC_ADD for the same
    (switch, ipv4_dst) at the same priority -- which overwrites -- so whichever finished last won,
    and the one that started first was walking the pre-failure graph. Each also assigned its own
    local list to self.all_destination_paths, which the kernel then pulls. The dynamic path already
    had it right, which is what made the discrepancy findable.
    """

    FLAG = "install_initial_openflow_entries_completed"

    def test_every_startup_path_sets_the_flag_after_its_walk(self):
        with open(ROUTER) as f:
            tree = ast.parse(f.read())

        checked = 0
        for node in ast.walk(tree):
            body = getattr(node, "body", None)
            if not isinstance(body, list):
                continue

            # Direct children only. Walking each statement's whole subtree put both the call and
            # the assignment at the index of the enclosing `try`, so the comparison was 32 > 32 --
            # the test failed against correct code. ast.walk visits the Try node itself later, and
            # its own body is scanned then.
            walk_at = flag_at = None
            for index, statement in enumerate(body):
                if (isinstance(statement, ast.Expr)
                        and isinstance(statement.value, ast.Call)
                        and isinstance(statement.value.func, ast.Attribute)
                        and statement.value.func.attr == "install_all_pair_paths"):
                    walk_at = index
                if (isinstance(statement, ast.Assign)
                        and any(isinstance(t, ast.Attribute) and t.attr == self.FLAG
                                for t in statement.targets)
                        and isinstance(statement.value, ast.Constant)
                        and statement.value.value is True):
                    flag_at = index

            if walk_at is None or flag_at is None:
                continue
            checked += 1
            self.assertGreater(
                flag_at,
                walk_at,
                f"{self.FLAG} is set to True at statement {flag_at}, before the "
                f"install_all_pair_paths at statement {walk_at} -- so it reads True for the whole "
                "walk and the reinstall worker will start a second, concurrent one",
            )

        self.assertGreaterEqual(
            checked,
            2,
            "expected to find both the static and dynamic startup paths; found "
            f"{checked}, so this test is no longer looking at the right code",
        )


class NotificationIsNotAGateTest(unittest.TestCase):
    """
    Local state must be updated before the remote notification, not after it.

    Structural for the same reason as CompletionFlagOrderTest: the invariant is statement order in an
    event handler, and the failure needs a peer that accepts a connection and never answers -- which
    no test at this level can arrange, and which raises nothing, so the handler's `except` does not
    help either.

    `requests.post` had no `timeout=`, so it blocks until the peer replies or the socket errors. A
    refused connection returns at once, which is the common case and why this went unnoticed; a
    wedged kernel still listening on :8000 is documented in HANDOFF 1j as having bitten three times.
    Everything the handler did *below* that call inherited the hang: on_link_delete's edge removal and
    reinstall scheduling, and on_link_add's reinstall scheduling. That is the pre-2c81b26 behaviour
    returning silently, with the greenlet parked.
    """

    HANDLERS = ("on_link_delete", "on_link_add")
    LOCAL_WORK = ("_schedule_route_reinstall", "remove_edge", "add_edge")

    def _handler(self, name):
        with open(ROUTER) as f:
            tree = ast.parse(f.read())
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name == name:
                return node
        raise AssertionError(f"intelligent_router.py no longer defines {name}; this test is stale")

    def test_every_outbound_http_call_has_a_timeout(self):
        # Without one the call is unbounded, and no amount of statement ordering saves the handler
        # from parking on it.
        #
        # GET as well as POST. The first version of this test only looked at `post`, and missed the
        # two unbounded `requests.get` calls to /ndt/inform_switch_entered -- one of which runs inside
        # an OpenFlow event handler, once per switch that connects. That is the worst place in the
        # file to block: a parked datapath greenlet does not drain its socket. Ten switches
        # reconnecting at once (which is what happens when Ryu is started against an already-running
        # Mininet) fire ten of them together, and a wedged Ryu measured after exactly that startup
        # order held 88 KB of unread data per OpenFlow connection.
        # [Co-developed with claude code -- Adam]
        with open(ROUTER) as f:
            tree = ast.parse(f.read())
        calls = []
        for node in ast.walk(tree):
            if (isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and isinstance(node.func.value, ast.Name)
                    and node.func.value.id == "requests"):
                calls.append((node.func.attr, node.lineno))
                self.assertIn(
                    "timeout",
                    [kw.arg for kw in node.keywords],
                    f"requests.{node.func.attr} on line {node.lineno} has no timeout=",
                )
        self.assertGreaterEqual(
            len(calls),
            4,
            "expected the four outbound calls (two switch-enter GETs, two link POSTs); found "
            f"{calls} -- if a call was removed, update this count deliberately",
        )

    def test_local_work_happens_before_the_notification(self):
        for name in self.HANDLERS:
            handler = self._handler(name)

            post_line = None
            local_lines = []
            for node in ast.walk(handler):
                if (isinstance(node, ast.Call)
                        and isinstance(node.func, ast.Attribute)):
                    if node.func.attr == "post":
                        post_line = node.lineno
                    elif node.func.attr in self.LOCAL_WORK:
                        local_lines.append((node.func.attr, node.lineno))

            self.assertIsNotNone(post_line, f"{name} no longer notifies the kernel")
            self.assertTrue(local_lines, f"{name} does no local work; this test is stale")
            for what, line in local_lines:
                self.assertLess(
                    line,
                    post_line,
                    f"{name}: {what} is on line {line}, after the requests.post on line "
                    f"{post_line} -- a peer that accepts and never answers would park the greenlet "
                    "and this would never run",
                )


if __name__ == "__main__":
    unittest.main()
