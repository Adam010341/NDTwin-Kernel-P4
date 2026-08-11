"""
/stats/flow/{dpid}: a failed read must be distinguishable from an empty table.

[Co-developed with claude code -- Adam]

The kernel's side of this contract (Classifier::updateFromQueriedTables) applies an empty table
as an authoritative snapshot, sweeping every rule absent from it. This route used to answer the
empty map for *failures* too -- unknown switch, gRPC error -- so a read that failed fast blanked
every flow's path for that switch with nothing logged kernel-side. The kernel shells out
`curl -s` and never sees the HTTP status, so the body shape is the whole signal: a failure must
carry "error", which classifyFlowStatsReply treats as ReportedFailure and keeps the old table.

The handler is called directly via asyncio.run rather than through a FastAPI TestClient: it
reads only its dpid argument and the module-global topology, so the routing layer would add a
dependency without adding coverage.
"""

import asyncio
import os
import sys
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


def call(dpid):
    return asyncio.run(api_routes.get_flow_stats(dpid))


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
