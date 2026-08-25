"""The two timeout exits in _rebuild_topology, driven for real rather than reasoned about.

[Co-developed with claude code -- Adam]

WHY THIS EXISTS. `get_link`'s ceiling shipped in cce9c5d with no runtime evidence of any kind:
across every log in doc/audit the string "Link list unavailable after timeout" appears zero times.
Phase 2 measured seven aborts and 28 timeouts and all of them were the get_switch exit above it,
so the get_link branch is the one product path here that has never executed. A comment on it was
already wrong once for exactly that reason -- it claimed seven rounds had taken it.

These tests block the real calls and run the real `_rebuild_topology`, so the branch executes.
They need no fabric, no lab and no reproducible wedge: the point of B's invariant framework is
that questions like this stop depending on a decaying target.

WHAT THEY PIN, beyond "it logs something":
  * the abort returns BEFORE `Switch entered:` -- so a timed-out round notifies nobody,
  * and therefore the queued dpids must SURVIVE for the next rebuild, or the switch is lost.
The second is the fidelity question I guessed at in a comment and never measured.

Run: PYTHONDONTWRITEBYTECODE=1 <ryu-env>/bin/python tests/python/test_topology_read_timeouts.py

Ryu and networkx live in a conda env of their own, so under the CI lane's interpreter this file
would abort at import and read as a hard failure rather than a skip. Guarded the way
test_find_host_by_ip guards networkx -- a red line here means the tests ran and failed.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

try:
    import networkx as nx                                        # noqa: E402
    from ryu.lib import hub                                      # noqa: E402
    import intelligent_router as ir                              # noqa: E402
    HAVE_RYU = True
except ImportError:                                              # pragma: no cover
    HAVE_RYU = False
    nx = hub = ir = None


class _Log:
    def __init__(self):
        self.lines = []

    def _rec(self, fmt, *a):
        try:
            self.lines.append(str(fmt) % a if a else str(fmt))
        except Exception:
            self.lines.append(str(fmt))

    info = warning = error = _rec

    def exception(self, fmt, *a):
        self._rec(fmt, *a)

    def has(self, needle):
        return any(needle in ln for ln in self.lines)


class _Dp:
    def __init__(self, i):
        self.id = i


class _Sw:
    def __init__(self, i):
        self.dp = _Dp(i)


class _Rebuilder:
    """Enough `self` for the real _rebuild_topology; the topology API is what we control."""

    def __init__(self):
        self.logger = _Log()
        self.topology_api_app = self
        self.switches = {}
        self.dynamic_net = nx.DiGraph()
        self._initial_watchdog_started = True          # don't spawn the watchdog in a test
        self.install_initial_openflow_entries_completed = True
        self._pending_switch_dpids = {1, 2}
        self.notified = []

    def _notify_switch_entered(self, dpid, api_url):
        self.notified.append(dpid)

    def _maybe_install_initial_routes(self):
        pass


# The real methods under test, bound after the class body rather than inside it: a class
# attribute is evaluated at definition time, so `_bounded_topo_read = ir.IntelligentRyu...`
# inline would make this module unimportable wherever Ryu is absent -- which is every
# interpreter but one, including the CI lane's.
if HAVE_RYU:
    _Rebuilder._bounded_topo_read = ir.IntelligentRyu._bounded_topo_read
    _Rebuilder._drain_pending_dpids = ir.IntelligentRyu._drain_pending_dpids
    _Rebuilder._rebuild_topology = ir.IntelligentRyu._rebuild_topology


def _blocks_forever(*_a, **_k):
    hub.Queue().get()          # the exact primitive app_manager.py:279 parks in


@unittest.skipUnless(HAVE_RYU,
                     "needs the ryu conda env (ryu-env/bin/python); this interpreter has no ryu/networkx")
class GetLinkTimeoutTest(unittest.TestCase):
    """The branch with no runtime evidence anywhere in doc/audit."""

    def setUp(self):
        self.real = (ir.get_switch, ir.get_link)
        ir.get_switch = lambda *a, **k: [_Sw(1), _Sw(2)]
        ir.get_link = _blocks_forever
        self.saved = ir.TOPO_QUERY_TIMEOUT_S
        ir.TOPO_QUERY_TIMEOUT_S = 0.5              # keep the suite quick

    def tearDown(self):
        ir.get_switch, ir.get_link = self.real
        ir.TOPO_QUERY_TIMEOUT_S = self.saved

    def test_it_actually_takes_the_abort_and_says_so(self):
        r = _Rebuilder()
        r._rebuild_topology()
        self.assertTrue(r.logger.has("topology read did not answer"),
                        "the timeout must announce itself or a run cannot prove it fired")
        self.assertTrue(r.logger.has("(get_link)"), "and must name which read timed out")
        self.assertTrue(r.logger.has("Link list unavailable after timeout"),
                        "the branch that has never executed in any archived log")

    def test_the_abort_returns_before_the_switch_entered_marker(self):
        r = _Rebuilder()
        r._rebuild_topology()
        self.assertFalse(r.logger.has("Switch entered:"))
        self.assertFalse(r.logger.has("Complete get_link"))
        self.assertEqual(r.notified, [], "a timed-out round must notify nobody")

    def test_queued_dpids_survive_an_aborted_round(self):
        """The fidelity question I asserted in a comment and never measured."""
        r = _Rebuilder()
        r._rebuild_topology()
        self.assertEqual(r._pending_switch_dpids, {1, 2},
                         "the abort dropped the queued switches; they would never be notified, "
                         "because only a later rebuild can drain them")

    def test_a_recovered_round_then_notifies_everything_that_was_queued(self):
        """Aborting must defer the batch, not lose it -- checked by letting the next round win."""
        r = _Rebuilder()
        r._rebuild_topology()                       # round 1: get_link times out
        ir.get_link = lambda *a, **k: []            # round 2: it answers
        r._rebuild_topology()
        self.assertEqual(r.notified, [1, 2],
                         "the switches queued before the failed round must be notified by the "
                         "one that succeeded")


@unittest.skipUnless(HAVE_RYU,
                     "needs the ryu conda env (ryu-env/bin/python); this interpreter has no ryu/networkx")
class GetSwitchTimeoutTest(unittest.TestCase):
    """The exit Phase 2 did exercise (7 aborts, 28 timeouts) -- pinned so it stays that way."""

    def setUp(self):
        self.real = (ir.get_switch, ir.get_link)
        self.saved = (ir.TOPO_QUERY_TIMEOUT_S, ir.TOPO_DEADLINE_S)
        ir.get_switch = _blocks_forever
        ir.TOPO_QUERY_TIMEOUT_S, ir.TOPO_DEADLINE_S = 0.3, 0.9

    def tearDown(self):
        ir.get_switch, ir.get_link = self.real
        ir.TOPO_QUERY_TIMEOUT_S, ir.TOPO_DEADLINE_S = self.saved

    def test_the_deadline_cannot_be_evaded_by_one_blocking_call(self):
        """The defect this replaced: `while time()-start < 20` only checks between iterations."""
        t0 = ir.time()
        r = _Rebuilder()
        r._rebuild_topology()
        elapsed = ir.time() - t0
        self.assertLess(elapsed, 3.0,
                        f"took {elapsed:.1f}s against a 0.9s deadline: a single blocking call "
                        f"escaped the bound, which is the original defect")
        self.assertTrue(r.logger.has("Switch list is empty after timeout"))
        self.assertEqual(r._pending_switch_dpids, {1, 2})


if __name__ == "__main__":
    unittest.main(verbosity=2)
