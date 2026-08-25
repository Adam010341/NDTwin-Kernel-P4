"""The coalescing worker's one load-bearing property, and the mutation that breaks it.

[Co-developed with claude code -- Adam]

B replaces "one rebuild per EventSwitchEnter" with "at least one complete rebuild AFTER the last
event". That weaker promise is the whole point -- ten switches entering at boot would otherwise
race ten concurrent rebuilds over the same graph -- but it is only true if the dirty flag is
cleared BEFORE the rebuild runs. Clear it afterwards and an event that arrives mid-rebuild is
wiped by the clear that follows, so the topology silently never reflects that switch. There is no
wedge, no error, and no log line: exactly the quiet failure mode B trades the ring for.

These tests exercise the real `IntelligentRyu._topology_worker` bound to a stub `self`, rather
than a reimplementation of it, so a change to the shipped loop can actually fail them.

Run: PYTHONDONTWRITEBYTECODE=1 <ryu-env>/bin/python tests/python/test_topology_worker_coalescing.py

This file imports Ryu, which lives in its own conda env, so under the CI lane's interpreter it
would abort at import and read as a hard failure rather than a skip -- the same shape
test_walk_instrumentation had. Guarded the way test_find_host_by_ip guards networkx: skip with a
reason that names the interpreter, so a red line means the tests ran and failed.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

try:
    from ryu.lib import hub                                      # noqa: E402
    import intelligent_router as ir                              # noqa: E402
    HAVE_RYU = True
except ImportError:                                              # pragma: no cover
    HAVE_RYU = False
    hub = ir = None


class _StubLogger:
    def __init__(self):
        self.exceptions = []

    def info(self, *a, **k):
        pass

    def warning(self, *a, **k):
        pass

    def exception(self, *a, **k):
        self.exceptions.append(a)


class _Worker:
    """Just enough `self` for the real _topology_worker to run against."""

    def __init__(self, rebuild_s=0.0, explode=False):
        self._topology_dirty = hub.Event()
        self._topology_rebuilds = 0
        self._topology_coalesced = 0
        self._topology_last_start = None
        self._topology_last_ok = None
        self._pending_switch_dpids = set()
        self.logger = _StubLogger()
        self._rebuild_s = rebuild_s
        self._explode = explode
        self._seen_at_start = []

    def _rebuild_topology(self):
        # Snapshot what the rebuild would have acted on, the way the real one drains it.
        self._seen_at_start.append(set(self._pending_switch_dpids))
        self._pending_switch_dpids = set()
        if self._rebuild_s:
            hub.sleep(self._rebuild_s)
        if self._explode:
            raise RuntimeError("boom")

    def start(self):
        return hub.spawn(ir.IntelligentRyu._topology_worker, self)


@unittest.skipUnless(HAVE_RYU,
                     "needs the ryu conda env (ryu-env/bin/python); this interpreter has no ryu")
class CoalescingTest(unittest.TestCase):

    def test_an_event_arriving_mid_rebuild_still_gets_a_rebuild(self):
        """THE property. This is the one the clear-after mutation breaks."""
        w = _Worker(rebuild_s=0.30)
        w.start()

        w._pending_switch_dpids.add(1)
        w._topology_dirty.set()          # event 1 -> rebuild starts, dirty cleared
        hub.sleep(0.10)                  # we are now INSIDE rebuild #1
        self.assertEqual(w._topology_rebuilds, 1, "rebuild should have started")

        w._pending_switch_dpids.add(2)
        w._topology_dirty.set()          # event 2 arrives DURING rebuild #1
        hub.sleep(0.60)                  # let #1 finish and #2 run

        self.assertGreaterEqual(
            w._topology_rebuilds, 2,
            "an event that arrived during a rebuild must earn its own rebuild; "
            "clearing the dirty flag after the rebuild instead of before loses it")
        self.assertIn(
            {2}, w._seen_at_start,
            "the second rebuild must see the dpid queued during the first")

    def test_bursts_coalesce_instead_of_one_rebuild_each(self):
        """The other half: five events while idle must NOT become five rebuilds."""
        w = _Worker(rebuild_s=0.25)
        w.start()
        for d in range(1, 6):
            w._pending_switch_dpids.add(d)
            w._topology_dirty.set()
        hub.sleep(0.80)
        self.assertLess(w._topology_rebuilds, 5,
                        "a burst of five enters should coalesce, not run five rebuilds")
        self.assertGreaterEqual(w._topology_rebuilds, 1)

    def test_a_failing_rebuild_does_not_kill_the_worker(self):
        """A dead worker stops the twin silently -- the failure mode B introduces."""
        w = _Worker(explode=True)
        w.start()
        w._topology_dirty.set()
        hub.sleep(0.15)
        self.assertTrue(w.logger.exceptions, "the failure should have been logged")
        before = w._topology_rebuilds
        w._topology_dirty.set()          # worker must still be alive to serve this
        hub.sleep(0.15)
        self.assertGreater(w._topology_rebuilds, before,
                           "worker died on the first exception; the twin would stop updating "
                           "with no further sign of trouble")

    def test_heartbeat_advances_so_a_stall_is_visible(self):
        w = _Worker(rebuild_s=0.05)
        w.start()
        self.assertIsNone(w._topology_last_ok)
        w._topology_dirty.set()
        hub.sleep(0.25)
        self.assertIsNotNone(w._topology_last_start)
        self.assertIsNotNone(w._topology_last_ok)
        self.assertGreaterEqual(w._topology_last_ok, w._topology_last_start)


@unittest.skipUnless(HAVE_RYU,
                     "needs the ryu conda env (ryu-env/bin/python); this interpreter has no ryu")
class DrainTest(unittest.TestCase):
    """_drain_pending_dpids: the swap that keeps a mid-notify enter for the next batch."""

    def setUp(self):
        self.w = _Worker()

    def _drain(self):
        return ir.IntelligentRyu._drain_pending_dpids(self.w)

    def test_returns_the_queued_dpids_sorted(self):
        self.w._pending_switch_dpids = {3, 1, 2}
        self.assertEqual(self._drain(), [1, 2, 3])

    def test_leaves_the_queue_empty_so_the_batch_is_not_reprocessed(self):
        self.w._pending_switch_dpids = {1, 2}
        self._drain()
        self.assertEqual(self.w._pending_switch_dpids, set(),
                         "a drained batch left in place would be notified again next rebuild")

    def test_an_enter_arriving_after_the_drain_survives_for_the_next_batch(self):
        """The reason this is a swap and not an iterate-then-clear."""
        self.w._pending_switch_dpids = {1}
        batch = self._drain()
        self.w._pending_switch_dpids.add(2)      # arrives while batch 1 is being notified
        self.assertEqual(batch, [1])
        self.assertEqual(self._drain(), [2],
                         "the enter that arrived mid-notify was lost; clearing the set after the "
                         "walk instead of swapping before it drops exactly this switch")


if __name__ == "__main__":
    unittest.main(verbosity=2)
