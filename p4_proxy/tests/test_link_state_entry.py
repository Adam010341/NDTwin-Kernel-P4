"""
The external link-state entry: where the second cut's fabric root helper will report.

[Co-developed with claude code -- Adam]

TICKET-P4-roles section 2.4. `TopologyManager.report_external_link_state` exists in this cut and
has NO CALLER and NO HTTP route -- on a foreign fabric the entry exists and is not wired. What it
does when something does call it is decided by one fact, whether the link watchdog runs:

  * running (an all-NDTwin fabric): the report takes the SAME path a beacon timeout or a
    returning beacon takes -- it becomes beacon evidence, and a watchdog pass reports it to the
    kernel through `_notify_link` and reroutes through `install_initial_routes`;
  * not running (a foreign fabric, this cut's case): recorded, counted on
    `GET /p4/switch_state` as `external_link_reports`, and NOTHING else -- no route rewritten,
    the kernel not told (M-R14 puts the reroute back and must go red).

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    from proxy_agent import topology_manager as tm
    from proxy_agent.topology_manager import TopologyManager
    # The switch double switch_liveness reads (probe, rule clock, stream) -- that suite's own.
    from tests.test_switch_state import FakeClient

    HAVE_PROXY = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_PROXY = False

LINK = (1, 2, 2, 1)


class Clock:
    def __init__(self, now=1_000.0):
        self.now = now

    def __call__(self):
        return self.now


class RecordingNotifier:
    def __init__(self):
        self.calls = []

    def link_failure(self, *link):
        self.calls.append(("link_failure", link))
        return True

    def link_recovery(self, *link):
        self.calls.append(("link_recovery", link))
        return True

    def all_destination_paths(self, paths):
        self.calls.append(("all_destination_paths",))
        return True


class CountingManager(TopologyManager if HAVE_PROXY else object):
    """A real TopologyManager whose route installer is counted rather than run."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.installs = 0

    def install_initial_routes(self, only_dpid=None):
        self.installs += 1
        return 0, 0


def a_fabric(watchdog_running):
    kernel, clock = RecordingNotifier(), Clock()
    topo = CountingManager(kernel_notifier=kernel, clock=clock)
    for dpid in (1, 2):
        topo.add_switch(dpid, FakeClient())
    topo.add_link(1, 2, 2, 1)
    # The flag start_link_watchdog sets, without the thread: the pass is driven by hand, the
    # way tests/test_link_watchdog.py drives run_watchdog_pass.
    topo._link_watchdog_running = watchdog_running
    return topo, kernel, clock


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class WhereTheWatchdogIsSkippedTheReportIsOnlyRecordedTest(unittest.TestCase):
    """The foreign-fabric branch -- this cut's only real case."""

    def setUp(self):
        self.topo, self.kernel, self.clock = a_fabric(watchdog_running=False)

    def test_a_down_report_changes_no_route_and_tells_the_kernel_nothing(self):
        result = self.topo.report_external_link_state(*LINK, up=False, source="heartbeat")
        self.assertFalse(result["applied"])
        self.assertEqual(self.topo.installs, 0, "a route was rewritten on a fabric with no watchdog")
        self.assertEqual(self.kernel.calls, [])

    def test_no_beacon_evidence_is_written_so_nothing_can_act_on_it_later(self):
        self.topo.report_external_link_state(*LINK, up=False, source="heartbeat")
        self.assertEqual(self.topo._link_beacons, {})
        self.assertEqual(self.topo.down_link_endpoints(), set())

    def test_it_is_counted_where_switch_state_serves_it(self):
        self.topo.report_external_link_state(*LINK, up=False, source="heartbeat")
        self.topo.report_external_link_state(*LINK, up=True, source="heartbeat")
        report = self.topo.switch_liveness()["external_link_reports"]
        self.assertEqual((report["received"], report["recorded_only"],
                          report["routed_through_watchdog"]), (2, 2, 0))
        self.assertEqual(report["last"], {"link": list(LINK), "up": True, "source": "heartbeat"})

    def test_before_any_report_the_count_is_zero_and_present(self):
        report = self.topo.switch_liveness()["external_link_reports"]
        self.assertEqual((report["received"], report["last"]), (0, None))


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class WhereTheWatchdogRunsTheReportTakesTheBeaconsPathTest(unittest.TestCase):
    """The all-NDTwin branch: `_notify_link` + `run_watchdog_pass`, the path a timeout takes."""

    def setUp(self):
        self.topo, self.kernel, self.clock = a_fabric(watchdog_running=True)

    def test_a_down_report_is_reported_to_the_kernel_and_rerouted_on_the_next_pass(self):
        result = self.topo.report_external_link_state(*LINK, up=False, source="heartbeat")
        self.assertTrue(result["applied"])
        self.clock.now += 0.1
        passed = self.topo.run_watchdog_pass()
        self.assertEqual(passed["down"], [LINK])
        self.assertIn(("link_failure", LINK), self.kernel.calls)
        self.assertEqual(self.topo.installs, 1)
        self.assertIn(("all_destination_paths",), self.kernel.calls)

    def test_an_up_report_brings_a_down_link_back_the_way_a_beacon_does(self):
        self.topo.report_external_link_state(*LINK, up=False, source="heartbeat")
        self.topo.run_watchdog_pass()
        self.clock.now += 1.0
        self.topo.report_external_link_state(*LINK, up=True, source="heartbeat")
        passed = self.topo.run_watchdog_pass()
        self.assertEqual(passed["up"], [LINK])
        self.assertIn(("link_recovery", LINK), self.kernel.calls)
        self.assertEqual(self.topo.installs, 2)

    def test_the_withheld_direction_leaves_the_topology_reply_like_a_timed_out_one(self):
        self.topo.report_external_link_state(*LINK, up=False, source="heartbeat")
        self.topo.run_watchdog_pass()
        self.assertIn((1, 2), self.topo.down_link_endpoints())

    def test_it_is_counted_as_routed_through_the_watchdog(self):
        self.topo.report_external_link_state(*LINK, up=False, source="heartbeat")
        report = self.topo.external_link_report()
        self.assertEqual((report["received"], report["routed_through_watchdog"],
                          report["recorded_only"]), (1, 1, 0))


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class TheEntryIsNotWiredInThisCutTest(unittest.TestCase):
    """Section 2.4: no HTTP route, no caller. Said by a test so it cannot quietly change.

    [Co-developed with claude code -- Adam] TICKET-P4-heartbeat segment W changed it on purpose
    ("心跳報告接到第一刀預留的 report_external_link_state"), and this is where that shows: the
    entry now has exactly ONE caller, the watchdog pass's own ingest of the heartbeat report
    (TopologyManager._ingest_link_evidence), and still no HTTP route -- the proxy reads the root
    helper's report file; nothing can POST link state at it. The class keeps its name so the
    first cut's gate (TM10's killer below) still finds it; `test_nothing_in_the_proxy_calls_it`
    was this second test until segment W, asserting no caller outside topology_manager.py.
    """

    def test_no_proxy_route_reaches_it(self):
        from proxy_agent import api_routes

        with open(api_routes.__file__) as fh:
            self.assertNotIn("report_external_link_state", fh.read())

    def test_its_one_caller_is_the_watchdog_pass_ingesting_the_heartbeat(self):
        import ast
        import re

        here = os.path.dirname(tm.__file__)
        calls = []
        for filename in sorted(os.listdir(here)):
            if not filename.endswith(".py"):
                continue
            with open(os.path.join(here, filename)) as fh:
                tree = ast.parse(fh.read())
            for func in ast.walk(tree):
                if not isinstance(func, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                for node in ast.walk(func):
                    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                            and node.func.attr == "report_external_link_state"):
                        calls.append((filename, func.name))
        self.assertEqual(calls, [("topology_manager.py", "_ingest_link_evidence")])
        self.assertTrue(re.search(r"source=\"heartbeat\"",
                                  open(os.path.join(here, "topology_manager.py")).read()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
