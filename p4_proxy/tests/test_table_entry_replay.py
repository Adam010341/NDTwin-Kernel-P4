"""
The table-entry journal's replay: what a proxy restart and a readopt put back, and on which fabric.
DESIGN.md sections 5.4-5.6, tests R13-R17, R20-R22, R24, R26, and ruling Q1 (a).

[Co-developed with claude code -- Adam]

Everything here runs the REAL `main.startup` and `main.readopt_switch` with REAL
`P4RuntimeClient`s, in front of a stub that behaves like the bmv2 the A0 round measured
(ternary-a0): a push empties every table and replaces the pipeline cookie (with none when the push
carries none); COOKIE_ONLY on a switch that has been pushed nothing is FAILED_PRECONDITION; an
insert of an entry that is there, and a modify or delete of one that is not, are per-update
refusals under a top-level UNKNOWN. Restarting the proxy is a new set of clients and a new
`TableJournals` on the same directory; restarting the bmv2 is `FabricSwitch.restart()`.

Self-contained, for the reason test_table_entry_journal.py is.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
# Before anything imports `main`: its table-entry journals go to a temp directory, never to the
# checkout's .run/ (tests/journal_isolation.py). [Co-developed with claude code -- Adam]
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import journal_isolation  # noqa: E402,F401

try:
    import grpc
    from fastapi import HTTPException
    from google.protobuf import text_format
    from google.rpc import code_pb2, status_pb2
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2
    from starlette.requests import Request

    from proxy_agent import api_routes, boot_identity, rule_journal
    import proxy_agent.main as main
    from proxy_agent.p4_client import P4RuntimeClient
    from proxy_agent.rule_install_times import RuleInstallTimes
    from proxy_agent.rule_journal import TableJournals, cookie_hex
    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- environment, not behaviour
    HAVE_P4RUNTIME = False

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mininet"))
import app_package  # noqa: E402

EXACT_ID, LPM_ID, TERNARY_ID, FORWARD_ID = 900000011, 900000012, 900000013, 900000021


def a_p4info():
    """Three user tables (exact, lpm, ternary with a priority column) and one action."""
    p4info = p4info_pb2.P4Info()
    for table_id, name, kind in ((EXACT_ID, "Pkg.t_exact", p4info_pb2.MatchField.EXACT),
                                 (LPM_ID, "Pkg.t_lpm", p4info_pb2.MatchField.LPM),
                                 (TERNARY_ID, "Pkg.t_ternary", p4info_pb2.MatchField.TERNARY)):
        table = p4info.tables.add()
        table.preamble.id = table_id
        table.preamble.name = name
        table.preamble.alias = name.split(".")[-1]
        field = table.match_fields.add()
        field.id = 1
        field.name = "hdr.ipv4.dstAddr"
        field.bitwidth = 32
        field.match_type = kind
        table.action_refs.add().id = FORWARD_ID
    forward = p4info.actions.add()
    forward.preamble.id = FORWARD_ID
    forward.preamble.name = "Pkg.forward"
    forward.preamble.alias = "forward"
    param = forward.params.add()
    param.id = 1
    param.name = "port"
    param.bitwidth = 9
    return p4info


def exact(dst, port=1, **extra):
    return dict({"dpid": 1, "table": "Pkg.t_exact", "match": {"hdr.ipv4.dstAddr": dst},
                 "action_name": "Pkg.forward", "action_params": {"port": port}}, **extra)


def lpm(dst, plen, port=1, **extra):
    return dict({"dpid": 1, "table": "Pkg.t_lpm", "match": {"hdr.ipv4.dstAddr": [dst, plen]},
                 "action_name": "Pkg.forward", "action_params": {"port": port}}, **extra)


def ternary(dst, mask, priority, port=1, **extra):
    return dict({"dpid": 1, "table": "Pkg.t_ternary", "priority": priority,
                 "match": {"hdr.ipv4.dstAddr": [dst, mask]},
                 "action_name": "Pkg.forward", "action_params": {"port": port}}, **extra)


if HAVE_P4RUNTIME:
    class FakeRpcError(grpc.RpcError):
        def __init__(self, code, trailers=None, details="fake"):
            self._code, self._trailers, self._details = code, trailers, details

        def code(self):
            return self._code

        def details(self):
            return self._details

        def trailing_metadata(self):
            return self._trailers

    def refused(canonical, message):
        status = status_pb2.Status(code=code_pb2.UNKNOWN)
        status.details.add().Pack(p4runtime_pb2.Error(canonical_code=canonical, message=message))
        return FakeRpcError(grpc.StatusCode.UNKNOWN,
                            (("grpc-status-details-bin", status.SerializeToString()),), "")

    class FabricSwitch:
        """
        One bmv2, as the stub every client of it talks to. Survives a proxy restart (the clients
        are new, this object is not); `restart()` is the bmv2 process being started again.
        """

        def __init__(self):
            self.tables = {}          # identity -> TableEntry, in insertion order
            self.pipeline = False
            self.cookie = None
            self.reachable = True
            self.rpcs = []            # ("get" | "set" | "write", detail), in order
            self.pushed_cookies = []  # the cookie each push carried (None for none)
            self.writes = []          # (op, table_id, priority) of every Write that went out

        def restart(self):
            self.tables, self.pipeline, self.cookie = {}, False, None

        @staticmethod
        def identity(entry):
            if entry.is_default_action:
                return (entry.table_id, "default")
            return (entry.table_id, entry.priority,
                    tuple(sorted(m.SerializeToString(deterministic=True) for m in entry.match)))

        def _check(self):
            if not self.reachable:
                raise FakeRpcError(grpc.StatusCode.UNAVAILABLE, details="connection refused")

        def GetForwardingPipelineConfig(self, request, timeout=None):
            self.rpcs.append(("get", request.response_type))
            self._check()
            if not self.pipeline:
                raise FakeRpcError(grpc.StatusCode.FAILED_PRECONDITION,
                                   details="No forwarding pipeline config set for this device")
            reply = p4runtime_pb2.GetForwardingPipelineConfigResponse()
            if self.cookie is not None:
                reply.config.cookie.cookie = self.cookie
            return reply

        def SetForwardingPipelineConfig(self, request, timeout=None):
            self.rpcs.append(("set", None))
            self._check()
            self.pipeline = True
            self.tables = {}
            self.cookie = (request.config.cookie.cookie if request.config.HasField("cookie")
                           else None)
            self.pushed_cookies.append(self.cookie)

        def Write(self, request, timeout=None):
            self._check()
            update = request.updates[0]
            entry = update.entity.table_entry
            op = {p4runtime_pb2.Update.INSERT: "insert", p4runtime_pb2.Update.MODIFY: "modify",
                  p4runtime_pb2.Update.DELETE: "delete"}[update.type]
            self.rpcs.append(("write", op))
            self.writes.append((op, entry.table_id, entry.priority))
            key = self.identity(entry)
            if entry.is_default_action:
                if op != "modify":
                    raise refused(code_pb2.INVALID_ARGUMENT, "default entries are modified")
                self.tables[key] = entry
                return
            if op == "insert":
                if key in self.tables:
                    raise refused(code_pb2.ALREADY_EXISTS, "Match entry exists")
                copy = p4runtime_pb2.TableEntry()
                copy.CopyFrom(entry)
                self.tables[key] = copy
            elif key not in self.tables:
                raise refused(code_pb2.NOT_FOUND, "Cannot find match entry")
            elif op == "modify":
                self.tables[key].CopyFrom(entry)
            else:
                del self.tables[key]

        def holds(self, table_id, priority=0, port=None):
            """How many entries of `table_id` at `priority` (with action param `port`)."""
            out = 0
            for entry in self.tables.values():
                if entry.table_id != table_id or entry.priority != priority:
                    continue
                if port is not None:
                    got = int.from_bytes(entry.action.action.params[0].value, "big")
                    if got != port:
                        continue
                out += 1
            return out

    def a_client(switch, workdir, device_id=1):
        """A real client with no channel: `switch` is its stub."""
        client = P4RuntimeClient.__new__(P4RuntimeClient)
        client.device_id = device_id
        client.grpc_addr = f"127.0.0.1:{50050 + device_id}"
        client.p4info = a_p4info()
        client.json_path = os.path.join(workdir, f"s{device_id}.json")
        client.stub = switch
        client.packet_in_callback = None
        client.sample_callback = None
        client.is_running = False
        client.stream_recv_thread = None
        import queue
        client.stream_out_q = queue.Queue()
        client.rule_install_times = RuleInstallTimes()
        client._last_table_read = None
        client.election_id = (0, 1)
        client.arbitration = True
        client.table_generation = None
        client.pipeline_commits = 0
        client.packet_in_ids = None
        client.packet_in_ids_error = "no packet_in controller header in this p4info"
        client.bind_routes(None)
        return client

    class FakeKernel:
        def switch_entered(self, dpid):
            return True

    class FakeSflow:
        def register_switch(self, dpid, agent_ip):
            pass

        def handle_sample(self, *args, **kwargs):
            pass

    class FakeFabric:
        """The topology startup, the routes and readopt each need, and nothing more.

        `readopt_switch` is the TopologyManager's sequence reduced to what matters here: build a
        client through the factory it is handed, push, swap it in. `during_readopt(stage)` runs
        at "before_swap" and "after_swap", so a test can POST at exactly those moments."""

        def __init__(self):
            self.switches = {}
            self.during_readopt = None

        def add_switch(self, dpid, client):
            self.switches[dpid] = client

        def seed_declared_links(self, *args, **kwargs):
            return 0

        def start_lldp_discovery(self):
            pass

        def start_link_watchdog(self, seed_expected=False, path=None):
            pass

        def start_liveness_polling(self):
            pass

        def switch_liveness(self):
            return {"status": "success", "probe_interval_s": 2.0, "boot_id": "b",
                    "boot_at": 1.0, "switches": {str(d): {"probe_ok": True}
                                                 for d in self.switches}}

        def readopt_switch(self, dpid, client_factory, sample_callback=None,
                           install_routes=True):
            new = client_factory(dpid)
            if self.during_readopt:
                self.during_readopt("before_swap")
            new.set_forwarding_pipeline_config()
            self.switches[dpid] = new
            if self.during_readopt:
                self.during_readopt("after_swap")
            return {"status": "success", "dpid": dpid, "clone_session": True,
                    "routes_installed": 0, "routes_attempted": 0}

    def a_request(body):
        payload = json.dumps(body).encode()

        async def receive():
            return {"type": "http.request", "body": payload, "more_body": False}

        return Request({"type": "http", "http_version": "1.1", "method": "POST",
                        "path": "/p4/table_entry", "raw_path": b"/p4/table_entry",
                        "root_path": "", "scheme": "http", "query_string": b"",
                        "headers": [(b"content-type", b"application/json")],
                        "client": ("127.0.0.1", 0), "server": ("127.0.0.1", 8081)}, receive)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class ReplayCase(unittest.TestCase):
    """A fabric of bmv2 stubs, a package whose switches run its own program, and one journal
    directory that outlives every "proxy process" a test starts."""

    DPIDS = (1,)

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ndt-table-replay-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.dir = os.path.join(self.tmp, "journal")
        self.switches = {d: FabricSwitch() for d in self.DPIDS}
        self.p4info_path = os.path.join(self.tmp, "pkg.p4info.txt")
        with open(self.p4info_path, "w") as fh:
            fh.write(text_format.MessageToString(a_p4info()))
        for d in self.DPIDS:
            with open(os.path.join(self.tmp, f"s{d}.json"), "w") as fh:
                fh.write("{}")
        self.entries_path = None
        self.entries_count = 0
        self.mode = "ndtwin"
        self.saved = (api_routes.topology, api_routes.table_journals,
                      api_routes.note_api_table_entry_write, api_routes.table_entries_report,
                      api_routes.pipelines_report, main.table_journals,
                      dict(main._generation))
        self.addCleanup(self.restore)
        api_routes.note_api_table_entry_write = None
        api_routes.pipelines_report = None
        self.fabric = None
        self.journals = None
        self.minted = []

    def restore(self):
        (api_routes.topology, api_routes.table_journals, api_routes.note_api_table_entry_write,
         api_routes.table_entries_report, api_routes.pipelines_report, main.table_journals,
         generation) = self.saved
        main._generation.clear()
        main._generation.update(generation)

    # --- the package ----------------------------------------------------------------

    def with_entries(self, entries):
        self.entries_path = os.path.join(self.tmp, "runtime.json")
        self.entries_count = len(entries)
        with open(self.entries_path, "w") as fh:
            json.dump({"table_entries": entries}, fh)

    def package(self):
        switches = tuple(
            app_package.SwitchSpec(dpid=d, name=f"s{d}",
                                   pipeline=(self.p4info_path,
                                             os.path.join(self.tmp, f"s{d}.json")),
                                   entries=self.entries_path,
                                   entries_recorded=self.entries_count)
            for d in self.DPIDS)
        return app_package.Package(dir=self.tmp, name="replay", mode=self.mode,
                                   switches=switches)

    # --- one proxy process ------------------------------------------------------------

    def mint(self):
        value = 0x1111000000000000 + len(self.minted) + 1
        self.minted.append(value)
        return value

    def start_proxy(self, enabled=True):
        """A proxy (re)start: new clients, new journals on the same directory, main.startup."""
        package = self.package()
        self.journals = TableJournals(self.dir, enabled=enabled,
                                      read_only=lambda: package.read_only,
                                      header_for=lambda d: main.table_journal_header(d, package))
        clients = {d: a_client(self.switches[d], self.tmp, d) for d in self.DPIDS}
        if package.read_only:
            for client in clients.values():
                client.arbitration = False
        self.fabric = FakeFabric()
        # The one object production has in both places: the route's journals and the report's.
        main.table_journals = self.journals
        knob = os.path.join(self.tmp, "no-telemetry-knob")
        with mock.patch.object(main, "TELEMETRY_KNOB_PATH", knob), \
                mock.patch.object(main, "mint_fabric_cookie", self.mint):
            self.summary = asyncio.run(main.startup(
                lambda: clients, FakeSflow(), FakeKernel(), self.fabric, settle_seconds=0,
                agent_ips_loader=lambda: {}, package=package, journals=self.journals))
        api_routes.topology = self.fabric
        api_routes.table_journals = self.journals
        api_routes.table_entries_report = main.table_entries_report
        return self.summary

    def readopt(self, dpid=1):
        package = self.package()
        factory = lambda d: a_client(self.switches[d], self.tmp, d)  # noqa: E731
        knob = os.path.join(self.tmp, "no-telemetry-knob")
        with mock.patch.object(main, "TELEMETRY_KNOB_PATH", knob):
            return main.readopt_switch(self.fabric, dpid, factory, None, package=package,
                                       journals=self.journals)

    def post(self, body):
        try:
            return 200, asyncio.run(api_routes.table_entry(a_request(body)))
        except HTTPException as exc:
            return exc.status_code, exc.detail

    def ok(self, body):
        status, answer = self.post(body)
        self.assertEqual(status, 200, answer)
        return answer

    # --- the files --------------------------------------------------------------------

    def live(self, dpid=1):
        return os.path.join(self.dir, f"s{dpid}.jsonl")

    def read_bytes(self, path):
        with open(path, "rb") as fh:
            return fh.read()

    def lines(self, path):
        return [json.loads(x) for x in self.read_bytes(path).decode().splitlines() if x.strip()]

    def set_aside(self, dpid=1):
        prefix = f"s{dpid}.jsonl.q"
        if not os.path.isdir(self.dir):
            return []
        return [os.path.join(self.dir, n) for n in sorted(os.listdir(self.dir))
                if n.startswith(prefix)]

    def replay_report(self, dpid=1):
        return self.journals.report(dpid)["replay"]


# =============================================================================================
# R14. What was POSTed before a restart is on the switch after it, and nothing was appended.
# =============================================================================================


class TheEntriesSurviveARestartTest(ReplayCase):
    def post_three(self):
        self.ok(exact("10.0.0.1", 1))
        self.ok(lpm("10.0.2.0", 24, 2))
        self.ok(ternary("10.0.3.0", "255.255.255.0", 10, 3))

    def test_entries_posted_before_a_restart_are_on_the_warm_switch_after_it(self):
        self.start_proxy()
        self.post_three()
        switch = self.switches[1]
        self.assertEqual(len(switch.tables), 3)
        self.start_proxy()   # the same bmv2, still holding this boot's cookie
        self.assertEqual(switch.holds(EXACT_ID, port=1), 1)
        self.assertEqual(switch.holds(LPM_ID, port=2), 1)
        self.assertEqual(switch.holds(TERNARY_ID, 10, port=3), 1)
        self.assertEqual(len(switch.tables), 3)
        report = self.replay_report()
        self.assertEqual((report["status"], report["attempted"], report["succeeded"]),
                         ("complete", 3, 3))
        self.assertIs(report["fresh_fabric"], False)
        self.assertEqual([r["op"] for r in report["restored"]], ["insert"] * 3)

    def test_the_restored_entries_go_back_after_the_push_that_emptied_the_switch(self):
        self.start_proxy()
        self.post_three()
        switch = self.switches[1]
        switch.rpcs.clear()
        self.start_proxy()
        kinds = [k for k, _ in switch.rpcs]
        self.assertEqual(kinds, ["get", "set", "write", "write", "write"],
                         "COOKIE_ONLY first, then the push, then the three replayed inserts")

    def test_the_set_aside_files_are_the_old_journal_and_nothing_was_appended_to_it(self):
        # M-J4: a replay that appended its writes to the live file would leave them in the file
        # the snapshot sets aside. Step 0 sets aside the journal exactly as it was; the replay's
        # snapshot then sets aside the step-0 file, which is the same records under a header
        # naming this boot -- and nothing else.
        self.start_proxy()
        self.post_three()
        before = self.read_bytes(self.live())
        old_records = [x for x in self.lines(self.live()) if not x.get("header")]
        already = set(self.set_aside())
        self.start_proxy()
        new = [p for p in self.set_aside() if p not in already]
        self.assertEqual(len(new), 2, "step 0 and the replay each set one generation aside")
        self.assertEqual(self.read_bytes(new[0]), before)
        step0 = self.lines(new[1])
        self.assertTrue(step0[0]["header"])
        self.assertEqual(step0[0]["boot_id"], boot_identity.BOOT_ID)
        self.assertEqual(step0[1:], old_records, "the replay appended to the journal it replays")

    def test_after_a_restart_the_live_file_is_this_boots_header_and_the_net_entries(self):
        self.start_proxy()
        self.post_three()
        self.start_proxy()
        header, *records = self.lines(self.live())
        self.assertEqual(header["boot_id"], boot_identity.BOOT_ID)
        self.assertEqual(header["fabric_cookie"], cookie_hex(self.switches[1].cookie))
        self.assertEqual([r["op"] for r in records], ["insert", "insert", "insert"])
        self.assertEqual([r["spec"]["table"] for r in records],
                         ["Pkg.t_exact", "Pkg.t_lpm", "Pkg.t_ternary"])

    def test_a_journal_another_proxy_process_wrote_is_replayed_when_the_cookie_confirms_it(self):
        # The production case. Every "restart" in this file runs in one test process, so
        # BOOT_ID never changes; a real restart is a new process with a new one. Step 0 is what
        # makes a confirmed file this boot's: it rewrites the header's boot_id, and the replay
        # then trusts it. A file still naming the old boot would be `unconfirmed_header`.
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        lines = self.read_bytes(self.live()).decode().splitlines()
        header = json.loads(lines[0])
        header["boot_id"] = "the-proxy-process-before-this-one"
        with open(self.live(), "w") as fh:
            fh.write("\n".join([json.dumps(header)] + lines[1:]) + "\n")
        self.start_proxy()
        self.assertEqual(self.switches[1].holds(EXACT_ID), 1)
        self.assertEqual(self.replay_report()["succeeded"], 1)
        self.assertEqual(self.lines(self.live())[0]["boot_id"], boot_identity.BOOT_ID)

    def test_a_second_restart_restores_the_same_entries_again(self):
        self.start_proxy()
        self.post_three()
        self.start_proxy()
        self.start_proxy()
        self.assertEqual(len(self.switches[1].tables), 3)
        self.assertEqual(self.replay_report()["succeeded"], 3)

    def test_journaled_is_true_in_the_response_and_in_switch_state(self):
        self.start_proxy()
        answer = self.ok(exact("10.0.0.1"))
        self.assertIs(answer["journaled"], True)
        self.assertNotIn("note", answer)
        state = asyncio.run(api_routes.switch_state())["switches"]["1"]["table_entries"]
        self.assertIs(state["journaled"], True)
        self.assertEqual(state["journal"]["replay"]["when"], "startup")


# =============================================================================================
# R13 through a restart: the net op the replay sends for each history.
# =============================================================================================


class TheReplaySendsTheNetOfEachEntryTest(ReplayCase):
    def setUp(self):
        super().setUp()
        # A boot entry, so that a journaled modify and delete have something to land on.
        self.with_entries([{"table": "Pkg.t_exact", "match": {"hdr.ipv4.dstAddr": "10.0.9.9"},
                            "action_name": "Pkg.forward", "action_params": {"port": 9}}])

    def restart_and_writes(self):
        self.switches[1].writes.clear()
        self.start_proxy()
        return [op for op, _t, _p in self.switches[1].writes]

    def test_a_modified_boot_entry_is_modified_again_after_the_restart(self):
        self.start_proxy()
        self.ok(exact("10.0.9.9", 5, op="modify"))
        ops = self.restart_and_writes()
        self.assertEqual(ops, ["insert", "modify"], "the boot entry, then the journal's modify")
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1)

    def test_a_deleted_boot_entry_is_deleted_again_after_the_restart(self):
        self.start_proxy()
        self.ok(exact("10.0.9.9", op="delete"))
        ops = self.restart_and_writes()
        self.assertEqual(ops, ["insert", "delete"])
        self.assertEqual(self.switches[1].holds(EXACT_ID), 0)

    def test_an_entry_inserted_and_deleted_is_not_written_at_all(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.ok(exact("10.0.0.1", op="delete"))
        self.assertEqual(self.restart_and_writes(), ["insert"], "only the boot entry")
        self.assertEqual(self.replay_report()["attempted"], 0)

    def test_two_spellings_of_one_entry_fold_into_one_write(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1", 1))
        self.ok(exact(167772161, 4, op="modify"))
        self.assertEqual(self.restart_and_writes(), ["insert", "insert"])
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=4), 1)


# =============================================================================================
# M1 (ruling 2026-10-12): a delete the switch answered NOT_FOUND says the entry was absent.
# =============================================================================================


class ANotFoundDeleteMeansAbsentTest(ReplayCase):
    def test_a_delete_at_another_priority_then_an_insert_at_it_both_come_back(self):
        # The review's sequence on a ternary table: insert at 10; delete at 20 -- the switch
        # answers NOT_FOUND, the journal records it; insert at 20. Folded with the old first-op
        # rule, 20 was a modify: after the push emptied the switch it met NOT_FOUND and the
        # entry did not come back.
        self.start_proxy()
        self.ok(ternary("10.0.3.0", "255.255.255.0", 10))
        status, answer = self.post(ternary("10.0.3.0", "255.255.255.0", 20, op="delete"))
        self.assertEqual(status, 502)
        self.assertEqual(answer["p4rt_error"]["code"], "NOT_FOUND")
        self.ok(ternary("10.0.3.0", "255.255.255.0", 20))
        self.start_proxy()
        self.assertEqual(self.switches[1].holds(TERNARY_ID, 10), 1)
        self.assertEqual(self.switches[1].holds(TERNARY_ID, 20), 1)
        self.assertEqual([r["op"] for r in self.replay_report()["restored"]],
                         ["insert", "insert"])
        self.assertEqual(self.replay_report()["status"], "complete")

    def test_the_not_found_delete_is_recorded_under_the_priority_it_named(self):
        self.start_proxy()
        self.ok(ternary("10.0.3.0", "255.255.255.0", 10))
        self.post(ternary("10.0.3.0", "255.255.255.0", 20, op="delete"))
        first, second = [x for x in self.lines(self.live()) if not x.get("header")]
        self.assertEqual((second["op"], second["outcome"]), ("delete", "not_found"))
        self.assertNotEqual(first["key"], second["key"],
                            "a delete at 20 is not a record of the entry at 10")
        self.assertEqual(self.switches[1].holds(TERNARY_ID, 10), 1, "and that entry is untouched")


# =============================================================================================
# R24 and Q1 (a): the cookie decides.
# =============================================================================================


class TheCookieDecidesTest(ReplayCase):
    def journal_one_entry(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        return self.read_bytes(self.live())

    def assert_set_aside_and_nothing_back(self, before, reason_fragment):
        report = self.replay_report()
        self.assertIs(report["fresh_fabric"], True)
        self.assertIn(reason_fragment, report["cookie"])
        self.assertEqual(report["attempted"], 0)
        self.assertEqual(self.switches[1].holds(EXACT_ID), 0)
        self.assertIn(before, [self.read_bytes(p) for p in self.set_aside()],
                      "the journal is set aside byte for byte, not lost")
        header, *records = self.lines(self.live())
        self.assertEqual(records, [], "the live journal is a header with nothing under it")
        self.assertEqual(header["boot_id"], boot_identity.BOOT_ID)

    def test_every_push_carries_this_boots_generation(self):
        self.start_proxy()
        cookie = self.switches[1].pushed_cookies[-1]
        self.assertIsNotNone(cookie, "a push with no cookie clears it on the switch")
        self.assertEqual(cookie, main._generation["cookie"])
        self.assertEqual(self.lines(self.live())[0]["fabric_cookie"], cookie_hex(cookie))

    def test_a_warm_switch_keeps_its_generation_across_restarts(self):
        self.start_proxy()
        first = self.switches[1].cookie
        self.start_proxy()
        self.assertEqual(self.switches[1].cookie, first)
        self.assertEqual(self.minted, [first], "nothing new was minted for a confirmed fabric")

    def test_a_fresh_bmv2_is_a_fresh_fabric(self):
        before = self.journal_one_entry()
        self.switches[1].restart()     # FAILED_PRECONDITION before its first push
        self.start_proxy()
        self.assert_set_aside_and_nothing_back(before, "FAILED_PRECONDITION")

    def test_a_switch_whose_pipeline_carries_no_cookie_is_a_fresh_fabric(self):
        before = self.journal_one_entry()
        self.switches[1].cookie = None   # somebody pushed it without one
        self.start_proxy()
        self.assert_set_aside_and_nothing_back(before, "carries no cookie")

    def test_another_cookie_is_a_fresh_fabric(self):
        before = self.journal_one_entry()
        self.switches[1].cookie = 0xDEAD
        self.start_proxy()
        self.assert_set_aside_and_nothing_back(before, "is not the journal's")
        self.assertNotEqual(self.switches[1].cookie, 0xDEAD)

    def test_a_cut_b_file_with_no_cookie_in_its_header_is_set_aside_and_not_replayed(self):
        # Exactly what Cut B wrote: a header whose fabric_cookie is null, written by an earlier
        # boot, and records under it. The switch even holds a cookie -- that does not help: the
        # file names none, so nothing confirms it.
        os.makedirs(self.dir)
        b_header = {"v": 1, "header": True, "dpid": 1, "fabric_cookie": None,
                    "p4info_sha256": main._p4info_fingerprint(self.p4info_path),
                    "entries_sha256": None, "boot_id": "an-earlier-boot"}
        spec = {k: v for k, v in exact("10.0.0.1").items() if k != "dpid"}
        b_record = {"v": 1, "t": 1.0, "op": "insert", "key": "k", "spec": spec, "outcome": "ok"}
        before = (json.dumps(b_header) + "\n" + json.dumps(b_record) + "\n").encode()
        with open(self.live(), "wb") as fh:
            fh.write(before)
        self.switches[1].pipeline = True
        self.switches[1].cookie = 0x1234
        self.start_proxy()
        self.assert_set_aside_and_nothing_back(before, "names no fabric cookie")

    def test_a_switch_with_no_journal_file_gets_a_header_and_nothing_else(self):
        self.start_proxy()
        header, *records = self.lines(self.live())
        self.assertEqual(records, [])
        self.assertIsNone(self.replay_report()["skipped_reason"])


class TwoSwitchesTest(ReplayCase):
    DPIDS = (1, 2)

    def test_confirmed_switches_that_disagree_are_all_unconfirmed_and_a_new_generation_is_minted(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.ok(dict(exact("10.0.0.2"), dpid=2))
        self.start_proxy()
        self.assertEqual(len(self.switches[1].tables) + len(self.switches[2].tables), 2)
        # Make each switch's journal confirm a DIFFERENT cookie.
        for dpid, cookie in ((1, 0xAAAA), (2, 0xBBBB)):
            self.switches[dpid].cookie = cookie
            lines = self.read_bytes(self.live(dpid)).decode().splitlines()
            header = json.loads(lines[0])
            header["fabric_cookie"] = cookie_hex(cookie)
            with open(self.live(dpid), "w") as fh:
                fh.write("\n".join([json.dumps(header)] + lines[1:]) + "\n")
        self.start_proxy()
        for dpid in (1, 2):
            report = self.journals.report(dpid)["replay"]
            self.assertIs(report["fresh_fabric"], True)
            self.assertIn("disagree", report["cookie"])
            self.assertEqual(len(self.switches[dpid].tables), 0)
        self.assertEqual(self.switches[1].cookie, self.switches[2].cookie)
        self.assertNotIn(self.switches[1].cookie, (0xAAAA, 0xBBBB))

    def test_a_switch_that_restarted_is_fresh_and_the_other_is_still_replayed(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.ok(dict(exact("10.0.0.2"), dpid=2))
        self.switches[2].restart()
        self.start_proxy()
        self.assertEqual(len(self.switches[1].tables), 1)
        self.assertEqual(len(self.switches[2].tables), 0)
        self.assertIs(self.journals.report(2)["replay"]["fresh_fabric"], True)
        self.assertEqual(self.switches[1].cookie, self.switches[2].cookie,
                         "the restarted switch is pushed this fabric's generation")

    def test_a_readopt_of_one_switch_leaves_the_others_record_in_its_own_file(self):
        # R21. Another switch's write during a readopt is in another file, so the readopt's
        # snapshot cannot set it aside.
        self.start_proxy()
        seen = []

        def during(stage):
            if stage == "before_swap":
                seen.append(self.post(dict(exact("10.0.0.2"), dpid=2)))
        self.fabric.during_readopt = during
        self.assertEqual(self.readopt(1)["status"], "success")
        self.assertEqual(seen[0][0], 200)
        records = [x for x in self.lines(self.live(2)) if not x.get("header")]
        self.assertEqual([r["op"] for r in records], ["insert"])


# =============================================================================================
# R15 and R16: the digests, and an external control plane.
# =============================================================================================


class TheDigestsGuardTheReplayTest(ReplayCase):
    def setUp(self):
        super().setUp()
        self.with_entries([{"table": "Pkg.t_exact", "match": {"hdr.ipv4.dstAddr": "10.0.9.9"},
                            "action_name": "Pkg.forward", "action_params": {"port": 9}}])

    def test_a_changed_p4info_replays_nothing(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.ok(exact("10.0.9.9", 5, op="modify"))
        with open(self.p4info_path, "a") as fh:
            fh.write("# another program\n")
        self.start_proxy()
        report = self.replay_report()
        self.assertEqual(report["stale_pipeline"], 2)
        self.assertEqual(report["succeeded"], 0)
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 0)
        self.assertEqual(len(self.switches[1].tables), 1, "only the boot entry")
        self.assertEqual(report["status"], "failed")

    def test_a_changed_entries_file_replays_the_inserts_and_not_what_was_aimed_at_its_entries(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.ok(exact("10.0.9.9", 5, op="modify"))
        self.with_entries([{"table": "Pkg.t_exact", "match": {"hdr.ipv4.dstAddr": "10.0.9.9"},
                            "action_name": "Pkg.forward", "action_params": {"port": 8}}])
        self.start_proxy()
        report = self.replay_report()
        self.assertEqual(report["stale_entries"], 1)
        self.assertEqual(report["succeeded"], 1)
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=1), 1, "the insert is back")
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=8), 1,
                         "and the new boot entry was not modified by the old journal")
        live = [x for x in self.lines(self.live()) if not x.get("header")]
        self.assertEqual([r["op"] for r in live], ["insert"], "a stale write leaves the journal")


class AnExternalControlPlaneTest(ReplayCase):
    def test_nothing_is_read_replayed_or_written_on_an_external_fabric(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        before = self.read_bytes(self.live())
        listing = sorted(os.listdir(self.dir))
        self.mode = "external"
        self.switches[1].rpcs.clear()
        self.start_proxy()
        self.assertEqual(self.read_bytes(self.live()), before)
        self.assertEqual(sorted(os.listdir(self.dir)), listing)
        self.assertEqual(self.switches[1].rpcs, [], "not even COOKIE_ONLY")
        self.assertEqual(self.replay_report()["skipped_reason"], "external control plane")


# =============================================================================================
# R26: a switch that is not there at startup.
# =============================================================================================


class ASwitchThatIsDownAtStartupTest(ReplayCase):
    def test_its_journal_is_set_aside_at_step_0_and_its_readopt_replays_nothing(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        before = self.read_bytes(self.live())
        old_cookie = self.switches[1].cookie
        self.switches[1].reachable = False
        self.start_proxy()
        self.assertEqual(self.summary["broken"], [1])
        self.assertIn(before, [self.read_bytes(p) for p in self.set_aside()],
                      "set aside at step 0, although its push failed")
        header, *records = self.lines(self.live())
        self.assertEqual(records, [])
        self.assertEqual(header["boot_id"], boot_identity.BOOT_ID)
        self.assertEqual(self.replay_report()["skipped_reason"],
                         "the pipeline push failed; a readopt of this switch replays its journal")
        # It comes back -- the same bmv2, still holding the old generation -- and is readopted.
        self.switches[1].reachable = True
        result = self.readopt(1)
        self.assertEqual(result["status"], "success")
        self.assertEqual(self.switches[1].holds(EXACT_ID), 0, "yesterday's entry is not back")
        self.assertEqual(result["table_entries"]["replay"]["attempted"], 0)
        self.assertEqual(self.switches[1].pushed_cookies[-1], main._generation["cookie"])
        self.assertNotEqual(self.switches[1].pushed_cookies[-1], old_cookie)

    def test_a_readopt_replays_nothing_from_a_file_this_boot_did_not_confirm(self):
        # M-J27. Step 0 makes this impossible in production; the check is there anyway.
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        lines = self.read_bytes(self.live()).decode().splitlines()
        header = json.loads(lines[0])
        header["boot_id"] = "another-boot"
        with open(self.live(), "w") as fh:
            fh.write("\n".join([json.dumps(header)] + lines[1:]) + "\n")
        result = self.readopt(1)
        self.assertEqual(result["table_entries"]["replay"]["skipped_reason"],
                         "unconfirmed_header")
        self.assertEqual(self.switches[1].holds(EXACT_ID), 0)
        self.assertEqual([x for x in self.lines(self.live()) if not x.get("header")], [])

    def test_a_readopt_pushes_this_boots_generation_not_the_one_a_header_names(self):
        # M-J28.
        self.start_proxy()
        generation = main._generation["cookie"]
        lines = self.read_bytes(self.live()).decode().splitlines()
        header = json.loads(lines[0])
        header["fabric_cookie"] = cookie_hex(0x5EED)
        with open(self.live(), "w") as fh:
            fh.write("\n".join([json.dumps(header)] + lines[1:]) + "\n")
        self.readopt(1)
        self.assertEqual(self.switches[1].pushed_cookies[-1], generation)


# =============================================================================================
# R17, R20, R22: readopt.
# =============================================================================================


class AReadoptReplaysTest(ReplayCase):
    def setUp(self):
        super().setUp()
        self.with_entries([{"table": "Pkg.t_exact", "match": {"hdr.ipv4.dstAddr": "10.0.9.9"},
                            "action_name": "Pkg.forward", "action_params": {"port": 9}}])

    def test_an_entry_posted_after_startup_is_back_after_a_readopt(self):
        # R17 / M-J17: the readopt reads the FILE again, so what was POSTed since startup is in it.
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.switches[1].writes.clear()
        result = self.readopt(1)
        self.assertEqual(result["status"], "success")
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=1), 1)
        self.assertEqual([op for op, _t, _p in self.switches[1].writes], ["insert", "insert"],
                         "the package's entry first, then the journal's")
        self.assertEqual(result["table_entries"]["replay"]["restored"][0]["op"], "insert")
        self.assertEqual(result["table_entries"]["replay"]["when"], "readopt")

    def test_two_readopts_report_the_same_replay(self):
        # M-J10: recorded, not added to.
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        first = self.readopt(1)["table_entries"]["replay"]
        second = self.readopt(1)["table_entries"]["replay"]
        self.assertEqual((first["attempted"], first["succeeded"]),
                         (second["attempted"], second["succeeded"]))
        self.assertEqual(self.journals.report(1)["replay"]["attempted"], 1)
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=1), 1)

    def test_the_readopts_push_carries_this_boots_generation(self):
        self.start_proxy()
        self.readopt(1)
        self.assertEqual(self.switches[1].pushed_cookies[-1], main._generation["cookie"])

    def post_during(self, stage):
        out = []

        def during(at):
            if at == stage:
                done = threading.Event()

                def go():
                    out.append(self.post(exact("10.0.0.7", 7)))
                    done.set()
                thread = threading.Thread(target=go, daemon=True)
                thread.start()
                done.wait(3)
        self.fabric.during_readopt = during
        return out

    def assert_refused_pending(self, out):
        self.assertEqual(len(out), 1, "the POST is still waiting: it should have been answered")
        status, answer = out[0]
        self.assertEqual(status, 503)
        self.assertEqual(answer["error"], "replay pending")
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=7), 0)
        self.assertEqual([x for x in self.lines(self.live()) if not x.get("header")
                          and x["spec"]["action_params"]["port"] == 7], [])

    def test_a_post_while_the_switch_is_being_readopted_is_503_and_writes_nothing(self):
        # R20 / M-J18.
        self.start_proxy()
        api_routes_timeout = api_routes.TABLE_ENTRY_LOCK_TIMEOUT_S
        self.addCleanup(setattr, api_routes, "TABLE_ENTRY_LOCK_TIMEOUT_S", api_routes_timeout)
        api_routes.TABLE_ENTRY_LOCK_TIMEOUT_S = 0.2
        out = self.post_during("before_swap")
        self.readopt(1)
        self.assert_refused_pending(out)

    def test_a_post_between_the_new_clients_swap_and_the_replay_is_503(self):
        # R22 / M-J20: the lock is held from before the swap, not taken after it.
        self.start_proxy()
        api_routes_timeout = api_routes.TABLE_ENTRY_LOCK_TIMEOUT_S
        self.addCleanup(setattr, api_routes, "TABLE_ENTRY_LOCK_TIMEOUT_S", api_routes_timeout)
        api_routes.TABLE_ENTRY_LOCK_TIMEOUT_S = 0.2
        out = self.post_during("after_swap")
        self.readopt(1)
        self.assert_refused_pending(out)

    def test_the_pending_flag_comes_down_after_a_readopt_and_after_one_that_failed(self):
        self.start_proxy()
        self.readopt(1)
        self.assertFalse(self.journals.pending(1))
        self.assertEqual(self.post(exact("10.0.0.1"))[0], 200)

        def explode(stage):
            raise RuntimeError("readopt blew up")
        self.fabric.during_readopt = explode
        with self.assertRaises(RuntimeError):
            self.readopt(1)
        self.assertFalse(self.journals.pending(1))
        self.assertFalse(self.journals.journal_for(1).lock.locked())


# =============================================================================================
# What the replay does with what does not go back, and with what it cannot read.
# =============================================================================================


class WhatDoesNotGoBackTest(ReplayCase):
    def test_a_write_the_switch_refuses_at_replay_is_reported_and_leaves_the_journal(self):
        self.with_entries([{"table": "Pkg.t_exact", "match": {"hdr.ipv4.dstAddr": "10.0.9.9"},
                            "action_name": "Pkg.forward", "action_params": {"port": 9}}])
        self.start_proxy()
        self.ok(exact("10.0.9.9", 5, op="modify"))
        self.ok(exact("10.0.0.1"))
        # The package's boot entry does not go on at the next start (the switch refuses it), so
        # the journal's modify of it finds nothing to modify.
        original = FabricSwitch.Write

        def refuse_the_boot_entry(switch, request, timeout=None):
            entry = request.updates[0].entity.table_entry
            if (request.updates[0].type == p4runtime_pb2.Update.INSERT
                    and int.from_bytes(entry.action.action.params[0].value, "big") == 9):
                raise refused(code_pb2.INVALID_ARGUMENT, "no")
            return original(switch, request, timeout)
        with mock.patch.object(FabricSwitch, "Write", refuse_the_boot_entry):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual((report["attempted"], report["succeeded"]), (2, 1))
        self.assertEqual(report["status"], "partial")
        (failed,) = report["failed"]
        self.assertEqual(failed["entry"]["op"], "modify")
        self.assertIn("NOT_FOUND", failed["reason"], "the switch's own reason, not UNKNOWN")
        live = [x for x in self.lines(self.live()) if not x.get("header")]
        self.assertEqual([r["op"] for r in live], ["insert"], "only what went back stays")

    def test_a_net_delete_the_switch_answers_not_found_has_reached_its_goal(self):
        self.with_entries([{"table": "Pkg.t_exact", "match": {"hdr.ipv4.dstAddr": "10.0.9.9"},
                            "action_name": "Pkg.forward", "action_params": {"port": 9}}])
        self.start_proxy()
        self.ok(exact("10.0.9.9", op="delete"))
        original = FabricSwitch.Write

        def skip_the_boot_entry(switch, request, timeout=None):
            if request.updates[0].type == p4runtime_pb2.Update.INSERT:
                raise refused(code_pb2.INVALID_ARGUMENT, "no")
            return original(switch, request, timeout)
        with mock.patch.object(FabricSwitch, "Write", skip_the_boot_entry):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual((report["succeeded"], report["failed"]), (1, []))
        live = [x for x in self.lines(self.live()) if not x.get("header")]
        self.assertEqual([r["op"] for r in live], ["delete"],
                         "kept, so the next boot deletes the boot entry again")

    def test_a_torn_line_is_kept_through_step_0_and_keeps_the_replay_from_claiming_complete(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        with open(self.live(), "ab") as fh:
            fh.write(b'{"v":1,"op":"ins\n')
        self.start_proxy()
        report = self.replay_report()
        self.assertEqual((report["succeeded"], report["unreadable"]), (1, 1))
        self.assertEqual(report["status"], "partial")

    def test_a_snapshot_that_fails_is_reported_and_the_switch_is_not_journaled(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))

        def no_disk(journal, header, records, keep=10):
            raise OSError("injected: the disk is full")
        with mock.patch.object(rule_journal.TableEntryJournal, "write_snapshot", no_disk):
            self.start_proxy()
        report = self.replay_report()
        self.assertIn("disk is full", report["snapshot_error"])
        self.assertEqual(report["succeeded"], 1, "the entry did go back on")
        self.assertEqual(self.journals.report(1)["failures"], 1)
        self.assertIs(self.journals.journaled(1), False,
                      "the live file is not what is on the switch, so the claim is withdrawn")

    def test_a_journal_that_is_off_replays_nothing_and_says_so(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.start_proxy(enabled=False)
        self.assertEqual(self.replay_report()["skipped_reason"], "the table-entry journal is off")
        self.assertEqual(self.switches[1].holds(EXACT_ID), 0)


# =============================================================================================
# The disclosure (DESIGN 5.6).
# =============================================================================================


class TheReportTest(ReplayCase):
    def test_switch_state_names_what_came_back(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.start_proxy()
        state = asyncio.run(api_routes.switch_state())["switches"]["1"]["table_entries"]
        replay = state["journal"]["replay"]
        self.assertEqual(replay["status"], "complete")
        self.assertEqual(replay["restored"][0]["spec"]["match"], {"hdr.ipv4.dstAddr": "10.0.0.1"})
        self.assertEqual(replay["cookie"], "confirmed")
        for key in ("fresh_fabric", "stale_pipeline", "stale_entries", "skipped_reason",
                    "attempted", "succeeded", "unreadable", "failed"):
            self.assertIn(key, replay)

    def test_the_startup_summary_carries_the_same_report(self):
        self.start_proxy()
        self.assertEqual(self.summary["table_entries"]["1"]["journal"]["replay"]["when"],
                         "startup")


if __name__ == "__main__":
    unittest.main()
