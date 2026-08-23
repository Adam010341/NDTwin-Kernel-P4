"""
/stats/flow/{dpid}: a failed read must be distinguishable from an empty table.

[Co-developed with claude code -- Adam]

The kernel's side of this contract (Classifier::updateFromQueriedTables) applies an empty table
as an authoritative snapshot, sweeping every rule absent from it. This route used to answer the
empty map for *failures* too -- unknown switch, gRPC error -- so a read that failed fast blanked
every flow's path for that switch with nothing logged kernel-side. The kernel shells out
`curl -s` and never sees the HTTP status, so the body shape is the whole signal: a failure must
carry "error", which classifyFlowStatsReply treats as ReportedFailure and keeps the old table.

The handler is called directly rather than through a FastAPI TestClient: it reads only its dpid
argument and the module-global topology, so the routing layer would add a dependency without
adding coverage. It used to be called via asyncio.run -- that stopped being possible when the
handler became a plain `def`, which is itself the subject of BlockingWorkStaysOffTheEventLoopTest
below.
"""

import asyncio
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from fastapi.responses import JSONResponse  # noqa: E402

from proxy_agent import api_routes  # noqa: E402


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


class FailingClient:
    def read_table_entries(self):
        raise RuntimeError("stream broken")


class HealthyClient:
    def read_table_entries(self):
        return []


class FakeStatus:
    name = "DEADLINE_EXCEEDED"


class DeadlineExceededClient:
    """Stands in for grpc's _MultiThreadedRendezvous: a useless class name over a real status."""

    def read_table_entries(self):
        class _MultiThreadedRendezvous(Exception):
            def code(self):
                return FakeStatus()

        raise _MultiThreadedRendezvous("deadline")


def call(dpid):
    return api_routes.get_flow_stats(dpid)


class AFailedReadIsNotAnEmptyTableTest(unittest.TestCase):
    def tearDown(self):
        api_routes.topology = None

    def test_an_unknown_switch_answers_503_with_an_error_body(self):
        # The proxy-restart window: the switch map is empty while the kernel still polls every
        # dpid it knows. The empty-map answer here is what used to blank all ten switches'
        # tables until discovery caught up.
        api_routes.topology = FakeTopology(switches={})

        resp = call(7)

        self.assertIsInstance(resp, JSONResponse)
        self.assertEqual(resp.status_code, 503)
        self.assertIn(b'"error"', resp.body)

    def test_a_read_that_raises_answers_503_with_an_error_body(self):
        # The reported defect: a fast gRPC failure came back inside the kernel's 0.5 s suspicion
        # threshold as {"<dpid>": []} and was applied as a snapshot.
        api_routes.topology = FakeTopology(switches={7: FailingClient()})

        resp = call(7)

        self.assertIsInstance(resp, JSONResponse)
        self.assertEqual(resp.status_code, 503)
        self.assertIn(b'"error"', resp.body)

    def test_the_error_body_is_an_object_carrying_the_error_key(self):
        # The kernel's classifyFlowStatsReply keys on exactly this shape ({"error": ...}); if the
        # shape drifts, the kernel goes back to applying failures as snapshots. This pins the
        # cross-component contract, not a cosmetic detail.
        api_routes.topology = FakeTopology(switches={7: FailingClient()})

        import json as jsonlib
        body = jsonlib.loads(call(7).body)
        self.assertIsInstance(body, dict)
        self.assertIn("error", body)

    def test_a_healthy_read_still_answers_the_plain_ryu_shape(self):
        # The success path must stay a bare dict -- not a JSONResponse -- so render_flow_stats'
        # output reaches the kernel byte-identical to before this change.
        api_routes.topology = FakeTopology(switches={7: HealthyClient()})

        resp = call(7)

        self.assertIsInstance(resp, dict)
        self.assertEqual(resp, {"7": []})

    def test_no_topology_at_all_is_a_failure_not_an_empty_table(self):
        api_routes.topology = None

        resp = call(7)

        self.assertIsInstance(resp, JSONResponse)
        self.assertEqual(resp.status_code, 503)

    def test_a_grpc_failure_is_reported_by_status_name_not_by_python_class(self):
        # Observed in the 2026-08-13 live run: a deadline against a SIGSTOPed switch produced
        # {"error": "... failed: _MultiThreadedRendezvous"}, and the kernel logs this body verbatim
        # in its ReportedFailure warning. An operator reading that log learns nothing -- the class
        # is a grpc internal. The status name is the part that says what happened.
        api_routes.topology = FakeTopology(switches={7: DeadlineExceededClient()})

        import json as jsonlib
        body = jsonlib.loads(call(7).body)

        self.assertIn("DEADLINE_EXCEEDED", body["error"])
        self.assertNotIn("Rendezvous", body["error"])

    def test_a_non_grpc_failure_still_falls_back_to_the_class_name(self):
        # Not every failure here comes from gRPC -- a p4info mismatch raises a plain Python error,
        # and dropping its identity to report nothing would be worse than the class name.
        api_routes.topology = FakeTopology(switches={7: FailingClient()})

        import json as jsonlib
        body = jsonlib.loads(call(7).body)

        self.assertIn("RuntimeError", body["error"])


class BlockingWorkStaysOffTheEventLoopTest(unittest.TestCase):
    """
    No endpoint may run a gRPC round trip on the asyncio event loop.

    [Co-developed with claude code -- Adam]
    Measured 2026-08-13. With s5 SIGSTOPed -- process alive, not answering gRPC -- the proxy stopped
    serving *every* endpoint, not just s5's. /p4/switch_state went from 1.9 ms to no response at
    all, and the kernel, unable to read any switch's liveness, walked its graph from 40/40 edges
    down to 32/40: one switch's fault amplified into total loss of fabric state. py-spy on the live
    process named the frame -- MainThread inside run_endpoint_function -> get_flow_stats ->
    read_table_entries, with run_forever underneath. The same dump showed the liveness prober idle
    and healthy and the AnyIO worker pool entirely unused, so the evidence the kernel wanted was
    already cached and a free worker was already there to serve it.

    These tests pin the dispatch decision, because that is what actually broke. A deadline on the
    gRPC call (tests/test_p4_client_writes.py ReadDeadlineTest) bounds how long a stall lasts; only
    getting the call off the loop stops one switch's stall from being everyone's outage. Asserting
    on iscoroutinefunction is not an implementation detail -- it is the exact predicate FastAPI's
    run_endpoint_function branches on to choose the threadpool.
    """

    def tearDown(self):
        api_routes.topology = None

    def test_get_flow_stats_is_dispatched_to_the_threadpool_not_the_loop(self):
        self.assertFalse(
            asyncio.iscoroutinefunction(api_routes.get_flow_stats),
            "get_flow_stats is a coroutine again, so FastAPI will run its blocking gRPC read on "
            "the event loop -- one unresponsive switch takes down every endpoint",
        )

    def test_a_flow_entry_write_runs_on_a_worker_thread(self):
        # These three must stay `async def` (they await request.json()), so the offload is by hand
        # and a rewrite could drop it without changing any response. Comparing thread identity
        # tests the property that matters rather than the spelling of the call.
        for name, payload, expected in (
            ("add_flow_entry", {"dpid": 1, "match": {}, "actions": []}, {"status": "success"}),
            ("delete_flow_entry", {"dpid": 1, "match": {}}, {"status": "success"}),
            ("modify_flow_entry", {"dpid": 1, "match": {}, "actions": []}, {"status": "success"}),
        ):
            with self.subTest(handler=name):
                topo = ThreadRecordingTopology()
                api_routes.topology = topo
                handler = getattr(api_routes, name)

                async def drive():
                    return threading.get_ident(), await handler(FakeRequest(payload))

                loop_thread, resp = asyncio.run(drive())

                self.assertEqual(resp, expected)
                self.assertTrue(topo.threads, "the handler never reached the topology manager")
                for t in topo.threads:
                    self.assertNotEqual(
                        t, loop_thread,
                        f"{name} called the switch on the event loop thread; a switch that is "
                        f"alive but not answering will freeze the whole proxy",
                    )


class ThreadRecordingTopology:
    """Records which thread each switch-facing call ran on."""

    def __init__(self):
        self.threads = []

    def _record(self):
        self.threads.append(threading.get_ident())
        return True

    # `priority` is forwarded by the handlers as of 2026-08-24 -- meaningless for ipv4_lpm,
    # mandatory for the ternary flow_5tuple table a richer match compiles to. These stubs only
    # care which thread they ran on, so they accept it and ignore it.
    def route_flow(self, dpid, match, actions, priority=None):
        return self._record()

    def unroute_flow(self, dpid, match, priority=None):
        return self._record()

    def modify_flow(self, dpid, match, actions, priority=None):
        return self._record()


class FakeRequest:
    def __init__(self, payload):
        self._payload = payload

    async def json(self):
        return self._payload


if __name__ == "__main__":
    unittest.main(verbosity=2)
