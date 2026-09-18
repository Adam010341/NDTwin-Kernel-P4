"""
PRE multicast groups: the writer, the route, and the package entries startup programs.
TICKET-P3 2.6 (G8, G9a).

[Co-developed with claude code -- Adam]

🔴 EVERY DEFECT HERE IS SILENT AT THE SWITCH. A group that replicates to nowhere is accepted by
the PRE and drops every packet sent to it. Two replicas sharing an (egress_port, instance) are
ONE replica to the PRE -- the second is absorbed, not refused -- so a four-port group written
with a copy-pasted instance id becomes a one-port group and three hosts stop receiving. A group
whose id is 0 is "do not multicast". None of those raises anywhere, and all three present
downstream as "the exercise's forwarding is broken", which is exactly what a student is meant to
be debugging. So each of them is refused here, by name, before the write goes out.

The three layers are asserted separately because they fail separately:

  * `write_multicast_group`  -- what goes on the wire, and the INSERT/MODIFY fallback
  * `POST /p4/multicast_group` -- a status code per refusal, and `stub.requests == []` for every
    refusal this proxy makes itself (the 502 is the switch's answer, so a Write necessarily went
    out and asserting an empty stub there would be asserting something false)
  * `apply_package_pre_entries` / `startup` -- that a package's declared groups are programmed
    and COUNTED, applied and failed apart

Run with:  p4_proxy/venv/bin/python -m unittest tests.test_multicast_group
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import grpc
    from fastapi import HTTPException
    from starlette.requests import Request
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2

    from proxy_agent import api_routes
    from proxy_agent import main
    from proxy_agent.p4_client import (ControlPlaneReadOnly, P4RuntimeClient, TableEntryInvalid)

    class FakeRpcError(grpc.RpcError):
        """Must derive from grpc.RpcError or the client's `except` would not catch it."""

        def __init__(self, code, details="fake failure"):
            self._code = code
            self._details = details

        def code(self):
            return self._code

        def details(self):
            return self._details

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False


class RecordingStub:
    """Captures WriteRequests instead of sending them, and can be told to fail."""

    def __init__(self, write_error=None, always=False):
        self.requests = []
        self.write_error = write_error
        self.always = always

    def Write(self, request, timeout=None):
        self.requests.append(request)
        if self.write_error is not None:
            if self.always:
                raise self.write_error
            error, self.write_error = self.write_error, None   # fail once, then succeed
            raise error

    def groups(self):
        """[(update type, group id, [(port, instance)])] for every PRE write recorded."""
        out = []
        for request in self.requests:
            for update in request.updates:
                entry = update.entity.packet_replication_engine_entry
                if not entry.HasField("multicast_group_entry"):
                    continue
                group = entry.multicast_group_entry
                out.append((update.type, group.multicast_group_id,
                            [(r.egress_port, r.instance) for r in group.replicas]))
        return out


def a_client(stub=None, device_id=1, arbitration=True):
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = device_id
    client.grpc_addr = "127.0.0.1:50051"
    client.p4info = p4info_pb2.P4Info()
    client.stub = stub if stub is not None else RecordingStub()
    client.election_id = (0, 1)
    client.arbitration = arbitration
    return client


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


def a_request(body, path="/p4/multicast_group", raw=None):
    payload = raw if raw is not None else json.dumps(body).encode()

    async def receive():
        return {"type": "http.request", "body": payload, "more_body": False}

    return Request({"type": "http", "http_version": "1.1", "method": "POST",
                    "path": path, "raw_path": path.encode(), "root_path": "", "scheme": "http",
                    "query_string": b"", "headers": [(b"content-type", b"application/json")],
                    "client": ("127.0.0.1", 0), "server": ("127.0.0.1", 8081)},
                   receive)


A_GROUP = {"dpid": 1, "multicast_group_id": 1,
           "replicas": [{"egress_port": 1, "instance": 1},
                        {"egress_port": 2, "instance": 1},
                        {"egress_port": 3, "instance": 1}]}


# --- the writer -------------------------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheWriterTest(unittest.TestCase):
    def setUp(self):
        self.stub = RecordingStub()
        self.client = a_client(self.stub)

    def test_an_insert_carries_the_group_and_every_replica(self):
        self.assertTrue(self.client.write_multicast_group(
            1, [{"egress_port": 1, "instance": 1}, {"egress_port": 2, "instance": 1}]))
        self.assertEqual(self.stub.groups(),
                         [(p4runtime_pb2.Update.INSERT, 1, [(1, 1), (2, 1)])])

    def test_the_request_is_stamped_with_this_clients_election_id(self):
        # Without it bmv2 answers PERMISSION_DENIED, which surfaces as "the exercise's multicast
        # does not work" rather than as a mastership problem.
        self.client.election_id = (0, 65535)
        self.client.write_multicast_group(1, [{"egress_port": 1}])
        self.assertEqual(self.stub.requests[0].election_id.low, 65535)
        self.assertEqual(self.stub.requests[0].device_id, 1)

    def test_instance_defaults_to_one_rather_than_zero(self):
        # 🔴 Two replicas to the same port with the same instance are ONE replica. Defaulting to
        # 0 would make every replica of a two-port group whose file omits `instance` collide the
        # moment the ports repeated -- and tutorials' files omit it freely.
        self.client.write_multicast_group(7, [{"egress_port": 4}])
        self.assertEqual(self.stub.groups(), [(p4runtime_pb2.Update.INSERT, 7, [(4, 1)])])

    def test_a_modify_is_sent_as_a_modify(self):
        self.client.write_multicast_group(1, [{"egress_port": 1}], op="modify")
        self.assertEqual(self.stub.groups()[0][0], p4runtime_pb2.Update.MODIFY)

    def test_a_delete_names_the_group(self):
        self.client.write_multicast_group(1, [], op="delete")
        self.assertEqual(self.stub.groups(), [(p4runtime_pb2.Update.DELETE, 1, [])])

    def test_an_insert_that_fails_falls_back_to_modify(self):
        # bmv2 answers a duplicate PRE object with UNKNOWN and an empty details string, not
        # ALREADY_EXISTS (measured 2026-08-13, C9) -- so a code-specific check never fires.
        self.stub.write_error = FakeRpcError(grpc.StatusCode.UNKNOWN, "")
        self.assertTrue(self.client.write_multicast_group(1, [{"egress_port": 1}]))
        self.assertEqual([kind for kind, _gid, _reps in self.stub.groups()],
                         [p4runtime_pb2.Update.INSERT, p4runtime_pb2.Update.MODIFY])

    def test_a_modify_that_also_fails_is_reported_as_a_failure(self):
        self.stub.write_error = FakeRpcError(grpc.StatusCode.INTERNAL)
        self.stub.always = True
        self.assertFalse(self.client.write_multicast_group(1, [{"egress_port": 1}]))

    def test_there_is_no_delete_first_settle_pair(self):
        # 🔴 DELIBERATELY UNLIKE write_clone_session. That method leads with a DELETE because a
        # clone session's backing multicast group survives a pipeline re-push and accumulates a
        # replica per proxy restart (doc/audit/2026-08-16_clone-stacking-raw-repro.md). MODIFY
        # on a multicast group REPLACES its replica list, so the stacking shape cannot arise --
        # and a DELETE here would briefly leave the exercise with no group at all.
        self.client.write_multicast_group(1, [{"egress_port": 1}])
        self.assertEqual([kind for kind, _gid, _reps in self.stub.groups()],
                         [p4runtime_pb2.Update.INSERT])

    def test_an_external_client_writes_nothing(self):
        client = a_client(self.stub, arbitration=False)
        with self.assertRaises(ControlPlaneReadOnly):
            client.write_multicast_group(1, [{"egress_port": 1}])
        self.assertEqual(self.stub.requests, [])


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheWriterRefusesTest(unittest.TestCase):
    """Each of these reaches no switch, and each is invisible downstream if it does."""

    def setUp(self):
        self.stub = RecordingStub()
        self.client = a_client(self.stub)

    def refused(self, *args, **kwargs):
        with self.assertRaises(TableEntryInvalid) as caught:
            self.client.write_multicast_group(*args, **kwargs)
        self.assertEqual(self.stub.requests, [], "a refusal must reach no switch")
        return str(caught.exception)

    def test_group_id_zero_is_refused(self):
        message = self.refused(0, [{"egress_port": 1}])
        self.assertIn("do not multicast", message)

    def test_a_non_integer_group_id_is_refused(self):
        self.refused("one", [{"egress_port": 1}])

    def test_a_group_with_no_replicas_is_refused(self):
        message = self.refused(1, [])
        self.assertIn("drops every packet", message)

    def test_a_delete_needs_no_replicas(self):
        # The one verb for which an empty list is meaningful: P4Runtime identifies the entity by
        # its id, so a DELETE says nothing about replicas.
        self.assertTrue(self.client.write_multicast_group(1, [], op="delete"))

    def test_a_replica_with_no_port_is_refused(self):
        message = self.refused(1, [{"instance": 1}])
        self.assertIn("egress_port", message)

    def test_a_negative_port_is_refused(self):
        self.refused(1, [{"egress_port": -1}])

    def test_a_boolean_port_is_refused(self):
        # True is an int in Python and 1 is a real port; a body carrying `true` must not quietly
        # become port 1.
        self.refused(1, [{"egress_port": True}])

    def test_the_same_port_and_instance_twice_is_refused_and_names_the_pair(self):
        message = self.refused(1, [{"egress_port": 2, "instance": 1},
                                   {"egress_port": 2, "instance": 1}])
        self.assertIn("(2, 1)", message)
        self.assertIn("one replica", message)

    def test_the_same_port_with_different_instances_is_allowed(self):
        # Two copies out of one port IS a thing the PRE does, and the exercise that wants it
        # must not be refused by a check aimed at the copy-paste case.
        self.assertTrue(self.client.write_multicast_group(
            1, [{"egress_port": 2, "instance": 1}, {"egress_port": 2, "instance": 2}]))

    def test_an_unknown_op_is_refused(self):
        self.refused(1, [{"egress_port": 1}], op="upsert")


# --- the route --------------------------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheRouteTest(unittest.TestCase):
    def setUp(self):
        self.saved = api_routes.topology
        self.addCleanup(self.restore)
        self.stub = RecordingStub()
        self.client = a_client(self.stub)
        api_routes.topology = FakeTopology({1: self.client})

    def restore(self):
        api_routes.topology = self.saved

    def post(self, body=None, **overrides):
        payload = dict(A_GROUP if body is None else body)
        payload.update(overrides)
        return asyncio.run(api_routes.multicast_group(a_request(payload)))

    def refused(self, body=None, **overrides):
        with self.assertRaises(HTTPException) as caught:
            self.post(body, **overrides)
        return caught.exception

    def test_a_good_group_is_200_and_reaches_the_switch(self):
        body = self.post()
        self.assertEqual(body["status"], "success")
        self.assertEqual(body["dpid"], 1)
        self.assertEqual(body["op"], "insert")
        self.assertEqual(body["multicast_group_id"], 1)
        self.assertEqual(body["replicas"], 3)
        self.assertEqual(self.stub.groups(),
                         [(p4runtime_pb2.Update.INSERT, 1, [(1, 1), (2, 1), (3, 1)])])

    def test_the_response_says_it_is_not_journaled(self):
        # Same warning POST /p4/table_entry carries, for the same reason: nothing journals a PRE
        # entry either, and a group that vanishes on a restart is a forwarding change nobody
        # connects to the restart.
        body = self.post()
        self.assertIs(body["journaled"], False)
        self.assertIn("lost when the proxy restarts", body["note"])

    def test_an_unknown_dpid_is_404_and_writes_nothing(self):
        error = self.refused(dpid=9)
        self.assertEqual(error.status_code, 404)
        self.assertEqual(self.stub.requests, [])

    def test_a_missing_dpid_is_400_and_writes_nothing(self):
        error = self.refused({"multicast_group_id": 1, "replicas": [{"egress_port": 1}]})
        self.assertEqual(error.status_code, 400)
        self.assertEqual(self.stub.requests, [])

    def test_a_group_id_of_zero_is_400_and_writes_nothing(self):
        error = self.refused(multicast_group_id=0)
        self.assertEqual(error.status_code, 400)
        self.assertIn("do not multicast", error.detail["message"])
        self.assertEqual(self.stub.requests, [])

    def test_replicas_that_are_not_a_list_is_400_and_writes_nothing(self):
        error = self.refused(replicas={"egress_port": 1})
        self.assertEqual(error.status_code, 400)
        self.assertEqual(self.stub.requests, [])

    def test_a_duplicated_replica_is_400_and_writes_nothing(self):
        error = self.refused(replicas=[{"egress_port": 2, "instance": 1},
                                       {"egress_port": 2, "instance": 1}])
        self.assertEqual(error.status_code, 400)
        self.assertEqual(self.stub.requests, [])

    def test_an_external_control_plane_is_409_and_writes_nothing(self):
        api_routes.topology = FakeTopology({1: a_client(self.stub, arbitration=False)})
        error = self.refused()
        self.assertEqual(error.status_code, 409)
        self.assertEqual(self.stub.requests, [])

    def test_a_switch_that_refuses_is_502(self):
        # 🔴 The one non-200 for which a Write DID go out: this is the switch's answer. Asserting
        # an empty stub here would be asserting something false.
        self.stub.write_error = FakeRpcError(grpc.StatusCode.INTERNAL)
        self.stub.always = True
        error = self.refused()
        self.assertEqual(error.status_code, 502)
        self.assertIn("dropped by the PRE", error.detail["message"])
        self.assertTrue(self.stub.requests)

    def test_a_malformed_body_is_400(self):
        with self.assertRaises(HTTPException) as caught:
            asyncio.run(api_routes.multicast_group(a_request(None, raw=b"{not json")))
        self.assertEqual(caught.exception.status_code, 400)
        self.assertEqual(self.stub.requests, [])

    def test_no_topology_is_503(self):
        api_routes.topology = None
        error = self.refused()
        self.assertEqual(error.status_code, 503)

    def test_the_route_is_registered(self):
        matches = [r for r in api_routes.router.routes
                   if getattr(r, "path", None) == "/p4/multicast_group"]
        self.assertEqual(len(matches), 1, "the multicast route is not registered")
        self.assertIn("POST", matches[0].methods)


# --- the package's own PRE entries (G9a) ------------------------------------------------------


class PreClient:
    """A switch that records what its PRE was asked for, and can refuse either kind."""

    def __init__(self, device_id=1, multicast_ok=True, clone_ok=True, raise_on_multicast=None):
        self.device_id = device_id
        self.multicast_ok = multicast_ok
        self.clone_ok = clone_ok
        self.raise_on_multicast = raise_on_multicast
        self.groups = []
        self.clones = []

    def write_multicast_group(self, group_id, replicas, op="insert"):
        if self.raise_on_multicast is not None:
            raise self.raise_on_multicast
        self.groups.append((group_id, list(replicas or []), op))
        return self.multicast_ok

    def write_clone_session(self, session_id=None, egress_port=None, replicas=None):
        self.clones.append((session_id, replicas))
        return self.clone_ok


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ThePackagesPreEntriesTest(unittest.TestCase):
    """What `apply_package_pre_entries` does with a tutorials runtime file."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p3c_pre_")
        self.addCleanup(self._clean)

    def _clean(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def entries(self, doc):
        path = os.path.join(self.tmp, "s1-runtime.json")
        with open(path, "w") as fh:
            json.dump(doc, fh)
        return path

    #: exercises/multicast/sig-topo/s1-runtime.json, transcribed. One group, three replicas.
    MULTICAST_FILE = {
        "target": "bmv2",
        "table_entries": [],
        "multicast_group_entries": [
            {"multicast_group_id": 1,
             "replicas": [{"egress_port": 1, "instance": 1},
                          {"egress_port": 2, "instance": 1},
                          {"egress_port": 3, "instance": 1}]}],
    }

    def test_a_file_with_neither_kind_counts_zero_and_writes_nothing(self):
        client = PreClient()
        counts = main.apply_package_pre_entries(client, self.entries({"table_entries": []}))
        self.assertEqual(counts["multicast"], {"recorded": 0, "applied": 0, "failed": 0})
        self.assertEqual(counts["clone"], {"recorded": 0, "applied": 0, "failed": 0})
        self.assertEqual(client.groups, [])
        self.assertEqual(client.clones, [])

    def test_no_entries_file_at_all_is_zero_rather_than_an_error(self):
        counts = main.apply_package_pre_entries(PreClient(), None)
        self.assertEqual(counts["multicast"]["recorded"], 0)

    def test_the_multicast_exercises_group_is_programmed(self):
        client = PreClient()
        counts = main.apply_package_pre_entries(client, self.entries(self.MULTICAST_FILE))
        self.assertEqual(counts["multicast"], {"recorded": 1, "applied": 1, "failed": 0})
        self.assertEqual(client.groups,
                         [(1, [{"egress_port": 1, "instance": 1},
                               {"egress_port": 2, "instance": 1},
                               {"egress_port": 3, "instance": 1}], "insert")])

    def test_a_refused_group_is_counted_as_failed_not_applied(self):
        # 🔴 `write_multicast_group` returns False for a refusal, and False is falsy in the same
        # way a successful write of nothing is. A group counted as applied that is not on the
        # switch makes `pre_entries.failed == 0` a sentence about nothing.
        client = PreClient(multicast_ok=False)
        counts = main.apply_package_pre_entries(client, self.entries(self.MULTICAST_FILE))
        self.assertEqual(counts["multicast"], {"recorded": 1, "applied": 0, "failed": 1})
        self.assertTrue(counts["errors"])

    def test_a_raising_writer_is_counted_as_failed_and_does_not_escape(self):
        client = PreClient(raise_on_multicast=TableEntryInvalid("nope"))
        counts = main.apply_package_pre_entries(client, self.entries(self.MULTICAST_FILE))
        self.assertEqual(counts["multicast"]["failed"], 1)
        self.assertIn("TableEntryInvalid", counts["errors"][0])

    def test_one_refused_group_does_not_cost_the_others(self):
        doc = {"multicast_group_entries": [
            {"multicast_group_id": 1, "replicas": [{"egress_port": 1}]},
            {"multicast_group_id": 2, "replicas": [{"egress_port": 2}]}]}
        client = PreClient()
        counts = main.apply_package_pre_entries(client, self.entries(doc))
        self.assertEqual(counts["multicast"], {"recorded": 2, "applied": 2, "failed": 0})
        self.assertEqual([g[0] for g in client.groups], [1, 2])

    def test_clone_session_entries_are_programmed_with_their_own_replicas(self):
        # flowcache's controller programs session 57. A package that declares one must get it,
        # and it must NOT be collapsed into the proxy's own session 250.
        doc = {"clone_session_entries": [
            {"clone_session_id": 57, "replicas": [{"egress_port": 510, "instance": 1}]}]}
        client = PreClient()
        counts = main.apply_package_pre_entries(client, self.entries(doc))
        self.assertEqual(counts["clone"], {"recorded": 1, "applied": 1, "failed": 0})
        self.assertEqual(client.clones,
                         [(57, [{"egress_port": 510, "instance": 1}])])

    def test_a_session_id_spelled_session_id_is_accepted_too(self):
        doc = {"clone_session_entries": [{"session_id": 5, "replicas": [{"egress_port": 1}]}]}
        client = PreClient()
        main.apply_package_pre_entries(client, self.entries(doc))
        self.assertEqual(client.clones[0][0], 5)

    def test_an_unreadable_entries_file_counts_zero_rather_than_raising(self):
        path = os.path.join(self.tmp, "broken.json")
        with open(path, "w") as fh:
            fh.write("{not json")
        counts = main.apply_package_pre_entries(PreClient(), path)
        self.assertEqual(counts["multicast"]["recorded"], 0)

    def test_read_pre_entries_reads_both_keys(self):
        doc = dict(self.MULTICAST_FILE)
        doc["clone_session_entries"] = [{"clone_session_id": 57, "replicas": []}]
        declared = main.read_pre_entries(self.entries(doc))
        self.assertEqual(len(declared["multicast"]), 1)
        self.assertEqual(len(declared["clone"]), 1)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheDefaultCloneSessionIsUnchangedTest(unittest.TestCase):
    """`replicas=None` has to mean exactly what the old single-replica code meant, or every
    baseline fabric's telemetry request changes shape."""

    def test_no_replicas_argument_writes_one_replica_to_the_cpu_port(self):
        from proxy_agent.p4_client import CPU_PORT, SAMPLE_SESSION_ID
        stub = RecordingStub()
        client = a_client(stub)
        client.write_clone_session()
        sessions = []
        for request in stub.requests:
            for update in request.updates:
                entry = update.entity.packet_replication_engine_entry
                if entry.HasField("clone_session_entry"):
                    session = entry.clone_session_entry
                    sessions.append((session.session_id,
                                     [(r.egress_port, r.instance) for r in session.replicas]))
        self.assertTrue(sessions)
        for session_id, replicas in sessions:
            self.assertEqual(session_id, SAMPLE_SESSION_ID)
            self.assertEqual(replicas, [(CPU_PORT, 1)])

    def test_an_explicit_replica_list_is_used_instead(self):
        stub = RecordingStub()
        client = a_client(stub)
        client.write_clone_session(session_id=57,
                                   replicas=[{"egress_port": 510, "instance": 2}])
        first = stub.requests[0].updates[0].entity.packet_replication_engine_entry
        self.assertEqual(first.clone_session_entry.session_id, 57)
        self.assertEqual([(r.egress_port, r.instance)
                          for r in first.clone_session_entry.replicas], [(510, 2)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
