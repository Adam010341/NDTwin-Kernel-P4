"""GET /sflow/stats -- the reader the send-side counters never had (ticket P).

[Co-developed with claude code -- Adam]

The counters datagrams_sent / samples_sent / send_errors have been incremented by
sflow_emitter.py since it was written and read by nothing, which is this repository's largest
live defect family. Ticket 1 needed them: it measured telemetry losing 34% of its bytes under CPU
contention and could not say which stage lost them, because the send side had no observable.

The test that matters here is not "the endpoint returns numbers". It is that an endpoint which is
NOT wired must fail loudly rather than return zeros -- because zero samples sent and "nobody
injected the emitter" are the same JSON, and the first is exactly the finding this endpoint
exists to detect. An instrument whose failure mode imitates its own signal is worse than none.
"""
import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "p4_proxy"))

from fastapi import HTTPException                      # noqa: E402
from proxy_agent import api_routes                     # noqa: E402


class FakeEmitter:
    def __init__(self, datagrams=0, samples=0, errors=0, batch=1):
        self.datagrams_sent = datagrams
        self.samples_sent = samples
        self.send_errors = errors
        self.batch_size = batch


class SFlowStatsEndpoint(unittest.TestCase):
    def setUp(self):
        self._saved = api_routes.sflow_emitter
        self.addCleanup(lambda: setattr(api_routes, "sflow_emitter", self._saved))

    def test_route_is_registered_on_the_router(self):
        """Existence is not wiring. A handler that no router serves is a dead function."""
        self.assertIn("/sflow/stats", [r.path for r in api_routes.router.routes])

    def test_not_injected_raises_rather_than_reporting_zero(self):
        """THE test. Kill the 503 branch and this is the one that must go red.

        A silent zero here is indistinguishable from the send side having stopped, which is the
        measurement this endpoint is for. Mutation check performed by hand before committing:
        replacing the raise with `getattr(emitter, "samples_sent", 0)` returns samples_sent=0 with
        no emitter at all, and this assertion catches it.
        """
        api_routes.sflow_emitter = None
        with self.assertRaises(HTTPException) as ctx:
            asyncio.run(api_routes.sflow_stats())
        self.assertEqual(ctx.exception.status_code, 503)
        self.assertIn("wiring", ctx.exception.detail)

    def test_injected_returns_the_counters_and_a_clock(self):
        api_routes.inject_emitter(FakeEmitter(datagrams=7, samples=42, errors=1, batch=8))
        out = asyncio.run(api_routes.sflow_stats())
        self.assertEqual(out["datagrams_sent"], 7)
        self.assertEqual(out["samples_sent"], 42)
        self.assertEqual(out["send_errors"], 1)
        self.assertEqual(out["batch_size"], 8)

    def test_clock_travels_with_the_counters(self):
        """Cumulative counters without a timestamp cannot be turned into a rate.

        This project has already published a number obtained by averaging a cumulative counter,
        and it looked entirely reasonable. The caller differentiates two reads; it needs both
        endpoints of the interval from the same response, not from its own wall clock.
        """
        api_routes.inject_emitter(FakeEmitter())
        first = asyncio.run(api_routes.sflow_stats())
        second = asyncio.run(api_routes.sflow_stats())
        self.assertIn("t", first)
        self.assertGreaterEqual(second["t"], first["t"])

    def test_counters_are_read_live_not_snapshotted_at_injection(self):
        """Reading a copy taken at injection time would report the send side as frozen.

        Same shape as the "should replace, can only add" family this codebase keeps producing:
        the value is captured once and never refreshed, and every later read looks like a system
        that stopped moving.
        """
        emitter = FakeEmitter(samples=1)
        api_routes.inject_emitter(emitter)
        before = asyncio.run(api_routes.sflow_stats())["samples_sent"]
        emitter.samples_sent += 99
        after = asyncio.run(api_routes.sflow_stats())["samples_sent"]
        self.assertEqual((before, after), (1, 100))


if __name__ == "__main__":
    unittest.main()
