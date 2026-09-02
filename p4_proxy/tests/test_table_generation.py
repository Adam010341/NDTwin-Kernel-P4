"""
Whether the proxy can tell a reader that it destroyed the switches' tables.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES A-4c. Restarting the proxy re-pushes the pipeline to every switch
(main.startup), and `SetForwardingPipelineConfig` with VERIFY_AND_COMMIT wipes every table
entry -- p4_client.py says so twice, once from a live 2026-08-16 measurement. bmv2 is never
restarted, so nothing else in the system observes an event. `install_initial_routes` then
refills the bring-up shortest paths, so the tables are not even empty afterwards: what is
gone is every rule installed *since* bring-up, and the twin has no statement of intent left
to compare against, so it reports a healthy fabric with no warning.

This file is the honesty half, and only the honesty half. It does not test that any rule
comes back. It tests that the destruction becomes *sayable*: a reader polling the proxy can
tell that the table it was told about earlier no longer exists.

Why a token and not a counter. The wipe also happens without a restart -- POST
/p4/readopt/{dpid} pushes a pipeline to one switch (topology_manager.readopt_switch), and
that path replaces the client object, so any counter living on the client restarts at zero
and a reader watching for "the number went up" sees it go *down* instead. An opaque token
that is merely required to *differ* has no such direction to get wrong, which is why the
assertions below are about inequality rather than about arithmetic.

Why a failed push must NOT change it. This is the assertion that decides whether the signal
is worth having. A push that raised did not commit, so it destroyed nothing; reporting a
wipe there would make a reader discard a view that is still correct, and startup's own
per-switch try/except exists precisely because one bmv2 out of ten routinely fails this call.
A signal that cries wolf on the ordinary failure path would be turned off within a week.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of
these files directly and parses "Ran N tests" -- and because p4_proxy/venv has no pytest.
"""

from __future__ import annotations

import os
import queue
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# A bare module-level `raise unittest.SkipTest(...)` is an uncaught exception during import and
# exits nonzero exactly like the ImportError it replaces, so the condition has to survive until
# unittest can act on it via skipUnless.
try:
    import grpc
    from p4.config.v1 import p4info_pb2

    from proxy_agent.p4_client import P4RuntimeClient

    class FakeRpcError(grpc.RpcError):
        """Derives from grpc.RpcError so the client's own handlers see it as one."""

        def __init__(self, details="pipeline push refused"):
            self._details = details

        def code(self):
            return None

        def details(self):
            return self._details

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover - depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False


class PipelineStub:
    """Records SetForwardingPipelineConfig calls, and can be told to refuse them."""

    def __init__(self, error=None):
        self.requests = []
        self.error = error

    def SetForwardingPipelineConfig(self, request, timeout=None):
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        return None


class ClientFixture:
    """
    Real `P4RuntimeClient.__init__`, with only the gRPC stub swapped for a recorder.

    Sibling suites build the client with `__new__` and assign every field by hand, to avoid
    depending on the generated p4info under p4_src/build. That trade is wrong *here*: half of
    what this file asserts is what `__init__` sets `table_generation` and `pipeline_commits`
    to, and a hand-built fixture would be asserting its own assignments. So the constructor
    runs for real against a throwaway empty p4info -- text_format parses an empty file to an
    empty P4Info, and none of these tests look anything up in it.

    `grpc.insecure_channel` connects lazily, so no socket is opened; the channel is closed on
    cleanup anyway so a long test run does not accumulate them.
    """

    def __init__(self, testcase):
        self.testcase = testcase

    def _temp(self, suffix, content=b""):
        handle, path = tempfile.mkstemp(suffix=suffix)
        with os.fdopen(handle, "wb") as fh:
            fh.write(content)
        self.testcase.addCleanup(os.unlink, path)
        return path

    def build(self, stub=None, device_id=1, with_pipeline=True):
        client = P4RuntimeClient(
            device_id=device_id,
            grpc_addr=f"127.0.0.1:{50050 + device_id}",
            p4info_path=self._temp(".p4info.txt"),
            json_path=self._temp(".json", b"{}") if with_pipeline else None,
        )
        self.testcase.addCleanup(client.channel.close)
        client.stub = stub if stub is not None else PipelineStub()
        return client


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TableGenerationTest(unittest.TestCase):
    def setUp(self):
        self.fixture = ClientFixture(self)

    def test_a_client_that_has_committed_nothing_reports_no_generation(self):
        # None, not a token. A reader must be able to tell "I have never wiped this switch"
        # from "I wiped it and here is which wipe", or the first poll after the proxy starts
        # looks exactly like a wipe that already happened and every table view is discarded
        # for no reason.
        client = self.fixture.build()

        self.assertIsNone(client.table_generation)
        self.assertEqual(client.pipeline_commits, 0)

    def test_a_committed_pipeline_produces_a_generation(self):
        client = self.fixture.build()

        client.set_forwarding_pipeline_config()

        self.assertIsInstance(client.table_generation, str)
        self.assertTrue(client.table_generation, "an empty token is not distinguishable")
        self.assertEqual(client.pipeline_commits, 1)

    def test_a_second_commit_produces_a_different_generation(self):
        # This is the whole signal. Two commits mean the tables were emptied twice, and a
        # reader holding the first token must be able to see that what it was told about is
        # gone. Equal tokens here would report the second wipe as "nothing happened".
        client = self.fixture.build()

        client.set_forwarding_pipeline_config()
        first = client.table_generation
        client.set_forwarding_pipeline_config()

        self.assertNotEqual(first, client.table_generation)
        self.assertEqual(client.pipeline_commits, 2)

    def test_a_refused_commit_leaves_the_generation_alone(self):
        # A push that raised did not commit, so the tables it would have wiped are intact.
        # startup() catches this per switch and carries on, and it is the ordinary case when
        # one bmv2 of ten is down -- so a false wipe report here would fire on a healthy day.
        client = self.fixture.build()
        client.set_forwarding_pipeline_config()
        before = client.table_generation
        # Not vacuous: without a token to begin with, "unchanged" would hold for a client that
        # never reports anything at all.
        self.assertIsNotNone(before, "the successful commit should have produced a token")

        client.stub.error = FakeRpcError()
        with self.assertRaises(grpc.RpcError):
            client.set_forwarding_pipeline_config()

        self.assertEqual(before, client.table_generation)
        self.assertEqual(client.pipeline_commits, 1, "a refused push committed nothing")

    def test_the_generation_survives_being_asked_for_twice(self):
        # Read-only. A token regenerated on read would make every poll look like a wipe.
        client = self.fixture.build()
        client.set_forwarding_pipeline_config()

        self.assertIsNotNone(client.table_generation, "nothing to re-read otherwise")
        self.assertEqual(client.table_generation, client.table_generation)

    def test_two_clients_do_not_share_a_generation(self):
        # readopt replaces one switch's client while the other nine keep theirs. A token stored
        # on the class, or derived from the pipeline artefact, would be identical across
        # switches and a wipe of s5 would read as a wipe of all ten.
        one = self.fixture.build(device_id=1)
        two = self.fixture.build(device_id=2)

        one.set_forwarding_pipeline_config()
        two.set_forwarding_pipeline_config()

        self.assertNotEqual(one.table_generation, two.table_generation)


class BootIdentityTest(unittest.TestCase):
    """
    The process-level half: which proxy instance is answering.

    A per-switch token alone cannot answer "is this the same proxy I was talking to before?",
    and that question has its own consequence -- a new proxy instance has an empty
    `_installed_routes` (topology_manager.py:577 builds it in __init__ with no persistence), so
    everything it says about which rules exist is derived from what it re-installed, not from
    what was there.
    """

    def test_the_boot_id_is_a_non_empty_string(self):
        from proxy_agent import boot_identity

        self.assertIsInstance(boot_identity.BOOT_ID, str)
        self.assertTrue(boot_identity.BOOT_ID)

    def test_the_boot_id_does_not_change_while_the_process_runs(self):
        # Read twice through a fresh import, because a module-level uuid4() call re-run on
        # reimport would give a reader a new identity every poll and permanently declare the
        # fabric untrustworthy.
        from proxy_agent import boot_identity

        first = boot_identity.BOOT_ID
        from proxy_agent import boot_identity as again

        self.assertEqual(first, again.BOOT_ID)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class SwitchStateCarriesTheGenerationTest(unittest.TestCase):
    """
    GET /p4/switch_state is where this has to surface.

    The kernel already polls it once a second (api_routes.switch_state), and it reads named
    keys out of each switch entry -- DeviceConfigurationAndPowerManager.cpp:426 looks up
    "probe_ok", then "probe_age_s", then "last_lldp_age_s" -- so extra keys are inert to the
    existing parse. Adding a second endpoint would mean a second poll and a second thing that
    can be forgotten.
    """

    def a_topology(self):
        from proxy_agent.topology_manager import TopologyManager

        topo = TopologyManager()
        topo.switches[1] = ClientFixture(self).build(device_id=1)
        return topo

    def test_the_payload_names_the_proxy_instance(self):
        from proxy_agent import boot_identity

        state = self.a_topology().switch_liveness()

        self.assertEqual(state["boot_id"], boot_identity.BOOT_ID)

    def test_a_switch_reports_its_table_generation(self):
        topo = self.a_topology()
        topo.switches[1].set_forwarding_pipeline_config()

        entry = topo.switch_liveness()["switches"]["1"]

        self.assertEqual(entry["table_generation"], topo.switches[1].table_generation)

    def test_a_switch_whose_pipeline_was_never_committed_reports_none(self):
        entry = self.a_topology().switch_liveness()["switches"]["1"]

        self.assertIsNone(entry["table_generation"])


if __name__ == "__main__":
    unittest.main()
