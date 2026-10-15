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
            self.cookie_timeouts = []  # the timeout each COOKIE_ONLY read was given
            #: (op) -> exception or None: raised AFTER the write took effect (an answer lost)
            self.lose_answer = None
            #: (op) -> exception or None: raised INSTEAD of the write (nothing happens)
            self.refuse = None

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
            self.cookie_timeouts.append(timeout)
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
            error = self.refuse(op) if self.refuse else None
            if error is not None:
                self.rpcs.append(("write", op))
                raise error
            self._write(entry, op)
            error = self.lose_answer(op) if self.lose_answer else None
            if error is not None:
                raise error

        def _write(self, entry, op):
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
# A delete the switch answered NOT_FOUND leaves the entry's start unknown.
# =============================================================================================


class ANotFoundDeleteLeavesTheStartUnknownTest(ReplayCase):
    def test_a_delete_at_another_priority_then_an_insert_at_it_both_come_back(self):
        # A ternary sequence: insert at 10; delete at 20 -- the switch answers NOT_FOUND, the
        # journal records it; insert at 20. Folded by the first op alone, 20 was a modify: after
        # the push emptied the switch it met NOT_FOUND and the entry did not come back.
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

    def test_an_insert_after_a_restart_that_replayed_the_not_found_delete_still_comes_back(self):
        # [Co-developed with claude code -- Adam]
        # The same sequence with a restart in the middle: the first restart replays the net
        # delete at 20 (NOT_FOUND, so it is done) and snapshots it; the insert at 20 is made
        # after that; the second restart must put it back and keep it in the journal. The
        # snapshot of the delete has to remember that its start was unknown, or the insert folds
        # to a modify that the emptied switch refuses.
        self.start_proxy()
        self.ok(ternary("10.0.3.0", "255.255.255.0", 10))
        status, answer = self.post(ternary("10.0.3.0", "255.255.255.0", 20, op="delete"))
        self.assertEqual((status, answer["p4rt_error"]["code"]), (502, "NOT_FOUND"))
        self.start_proxy()
        self.assertEqual(self.switches[1].holds(TERNARY_ID, 20), 0)
        self.ok(ternary("10.0.3.0", "255.255.255.0", 20))
        self.start_proxy()
        self.assert_both_priorities_are_back_and_journalled()

    def test_an_insert_after_a_readopt_that_replayed_the_not_found_delete_still_comes_back(self):
        # The same through readopt, which replays and snapshots the same way.
        # [Co-developed with claude code -- Adam]
        self.start_proxy()
        self.ok(ternary("10.0.3.0", "255.255.255.0", 10))
        status, answer = self.post(ternary("10.0.3.0", "255.255.255.0", 20, op="delete"))
        self.assertEqual((status, answer["p4rt_error"]["code"]), (502, "NOT_FOUND"))
        self.assertEqual(self.readopt(1)["status"], "success")
        self.assertEqual(self.switches[1].holds(TERNARY_ID, 20), 0)
        self.ok(ternary("10.0.3.0", "255.255.255.0", 20))
        result = self.readopt(1)
        self.assertEqual(result["table_entries"]["replay"]["when"], "readopt")
        self.assert_both_priorities_are_back_and_journalled()

    def assert_both_priorities_are_back_and_journalled(self):
        self.assertEqual(self.switches[1].holds(TERNARY_ID, 10), 1)
        self.assertEqual(self.switches[1].holds(TERNARY_ID, 20), 1, "the entry inserted at 20")
        report = self.replay_report()
        self.assertEqual((report["status"], report["failed"]), ("complete", []))
        live = [x for x in self.lines(self.live()) if not x.get("header")]
        self.assertEqual(sorted((r["spec"]["priority"], r["op"], r["outcome"]) for r in live
                                if r["outcome"] == "ok"),
                         [(10, "insert", "ok"), (20, "insert", "ok")],
                         "and both are in the journal for the start after this one")

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
        self.assertEqual([f["kept"] for f in report["failed"]], [False, False],
                         "a stale write is dropped from the journal, as the report says")
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
        self.assertEqual([f["kept"] for f in report["failed"]], [False])
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

    def test_a_confirmed_switch_whose_push_fails_is_replayed_by_its_readopt(self):
        # DESIGN 5.4 step 0: "even if its push then fails and it is broken, the file says this
        # boot confirmed it". The journal is another process's (its header names another boot);
        # the cookie confirms it; the push fails once; the readopt puts the entry back.
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        lines = self.read_bytes(self.live()).decode().splitlines()
        header = json.loads(lines[0])
        header["boot_id"] = "the-proxy-process-before-this-one"
        with open(self.live(), "w") as fh:
            fh.write("\n".join([json.dumps(header)] + lines[1:]) + "\n")
        original = FabricSwitch.SetForwardingPipelineConfig
        calls = []

        def fail_once(switch, request, timeout=None):
            calls.append(1)
            if len(calls) == 1:
                raise FakeRpcError(grpc.StatusCode.UNAVAILABLE, details="push failed")
            return original(switch, request, timeout)
        with mock.patch.object(FabricSwitch, "SetForwardingPipelineConfig", fail_once):
            self.start_proxy()
            self.assertEqual(self.summary["broken"], [1])
            self.assertIs(self.replay_report()["fresh_fabric"], False, "the cookie confirmed it")
            self.assertEqual(self.lines(self.live())[0]["boot_id"], boot_identity.BOOT_ID)
            result = self.readopt(1)
        self.assertEqual(result["table_entries"]["replay"]["succeeded"], 1)
        self.assertEqual(self.switches[1].holds(EXACT_ID), 1)

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
        # The switch refuses the journal's modify of the package's boot entry at the next start
        # (not NOT_FOUND: that one is retried as an insert).
        original = FabricSwitch.Write

        def refuse_the_modify(switch, request, timeout=None):
            if request.updates[0].type == p4runtime_pb2.Update.MODIFY:
                raise refused(code_pb2.INVALID_ARGUMENT, "no")
            return original(switch, request, timeout)
        with mock.patch.object(FabricSwitch, "Write", refuse_the_modify):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual((report["attempted"], report["succeeded"]), (2, 1))
        self.assertEqual(report["status"], "partial")
        (failed,) = report["failed"]
        self.assertEqual(failed["entry"]["op"], "modify")
        self.assertIn("INVALID_ARGUMENT", failed["reason"], "the switch's own reason, not UNKNOWN")
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

# =============================================================================================
# An entry that began unknown, a journal that is off, a bad byte, a write with no answer.
# [Co-developed with claude code -- Adam]
# =============================================================================================

BOOT = [{"table": "Pkg.t_exact", "match": {"hdr.ipv4.dstAddr": "10.0.9.9"},
         "action_name": "Pkg.forward", "action_params": {"port": 9}}]


def deadline():
    return FakeRpcError(grpc.StatusCode.DEADLINE_EXCEEDED, details="Deadline Exceeded")


class ALostAnswerOnABootEntryTest(ReplayCase):
    """A first NOT_FOUND delete leaves the entry's start unknown."""

    def setUp(self):
        super().setUp()
        self.with_entries(BOOT)

    def lose_the_answer_to_one_delete(self):
        """The DELETE lands on the switch, its answer is lost (DEADLINE_EXCEEDED, nothing
        recorded), and the retry is answered NOT_FOUND (recorded as `not_found`)."""
        self.switches[1].lose_answer = lambda op: deadline() if op == "delete" else None
        status, answer = self.post(exact("10.0.9.9", op="delete"))
        self.assertEqual((status, answer.get("grpc_status")), (502, "DEADLINE_EXCEEDED"))
        self.switches[1].lose_answer = None
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=9), 0, "it did land")
        status, answer = self.post(exact("10.0.9.9", op="delete"))
        self.assertEqual(answer["p4rt_error"]["code"], "NOT_FOUND")
        records = [x for x in self.lines(self.live()) if not x.get("header")]
        self.assertEqual([(r["op"], r["outcome"]) for r in records], [("delete", "not_found")])

    def test_the_boot_entry_whose_delete_lost_its_answer_is_deleted_again_after_a_restart(self):
        self.start_proxy()
        self.lose_the_answer_to_one_delete()
        self.start_proxy()     # the push empties the switch and the package puts the entry back
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=9), 0,
                         "the operator deleted it; a restart must not bring it back")
        self.assertEqual([r["op"] for r in self.replay_report()["restored"]], ["delete"])

    def test_a_boot_entry_deleted_with_a_lost_answer_then_inserted_ends_as_the_insert(self):
        # [not_found, insert S] on a package entry: the replay's insert meets the entry the
        # package put back (ALREADY_EXISTS) and is retried once as a modify to S.
        self.start_proxy()
        self.lose_the_answer_to_one_delete()
        self.ok(exact("10.0.9.9", 5))
        self.start_proxy()
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1, "S is on the switch")
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=9), 0)
        report = self.replay_report()
        self.assertEqual((report["status"], report["failed"]), ("complete", []))
        self.assertEqual(len(report["retried_as_modify"]), 1)
        live = [x for x in self.lines(self.live()) if not x.get("header")]
        self.assertEqual([(r["op"], r["outcome"]) for r in live],
                         [("delete", "not_found"), ("insert", "ok")], "S, and its unknown start")
        self.assertEqual(live[1]["spec"]["action_params"], {"port": 5})
        self.start_proxy()
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1, "and again a boot later")

    def test_a_readopt_puts_back_a_boot_entry_deleted_with_a_lost_answer_then_inserted(self):
        # [Co-developed with claude code -- Adam]
        # [not_found, insert S] on a package entry, replayed by a readopt and not by a restart:
        # the readopt's push puts the boot entry back, so the insert meets it, is retried as a
        # modify, and S is what ends up on the switch.
        self.start_proxy()
        self.lose_the_answer_to_one_delete()
        self.ok(exact("10.0.9.9", 5))
        self.switches[1].writes.clear()
        result = self.readopt(1)
        self.assertEqual(result["status"], "success")
        report = result["table_entries"]["replay"]
        self.assertEqual(report["when"], "readopt")
        self.assertEqual([op for op, _t, _p in self.switches[1].writes],
                         ["insert", "insert", "modify"],
                         "the package's entry, the journal's insert that met it, the modify")
        self.assertEqual(len(report["retried_as_modify"]), 1)
        self.assertEqual((report["status"], report["failed"]), ("complete", []))
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1, "S is on the switch")
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=9), 0)

    def test_an_unknown_start_insert_refused_for_another_reason_is_not_retried(self):
        # The fallback is for ALREADY_EXISTS alone: any other per-update refusal is the
        # switch's answer about this write, and a modify would paper over it.
        self.start_proxy()
        self.lose_the_answer_to_one_delete()
        self.ok(exact("10.0.9.9", 5))
        original = FabricSwitch.Write

        def refuse_the_replay(switch, request, timeout=None):
            entry = request.updates[0].entity.table_entry
            if (request.updates[0].type == p4runtime_pb2.Update.INSERT
                    and int.from_bytes(entry.action.action.params[0].value, "big") == 5):
                raise refused(code_pb2.INVALID_ARGUMENT, "no")
            return original(switch, request, timeout)
        with mock.patch.object(FabricSwitch, "Write", refuse_the_replay):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual(report["retried_as_modify"], [])
        self.assertEqual(len(report["failed"]), 1)
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=9), 1, "the boot entry, unmodified")

    def test_an_unknown_start_insert_is_not_a_modify_over_an_entry_of_a_changed_package(self):
        # [Co-developed with claude code -- Adam]
        # The package's entries file changed since the journal was written, so the entry the
        # insert meets is the new package's, not the one the operator deleted. Overwriting it
        # with the old spec would undo the new package; the write is stale, as a modify or a
        # delete aimed at the entries file would be.
        self.start_proxy()
        self.lose_the_answer_to_one_delete()
        self.ok(exact("10.0.9.9", 5))
        self.with_entries([{"table": "Pkg.t_exact", "match": {"hdr.ipv4.dstAddr": "10.0.9.9"},
                            "action_name": "Pkg.forward", "action_params": {"port": 7}}])
        self.switches[1].writes.clear()
        self.start_proxy()
        self.assertEqual([op for op, _t, _p in self.switches[1].writes], ["insert", "insert"],
                         "the package's entry, then the journal's insert that was refused")
        report = self.replay_report()
        self.assertEqual(report["retried_as_modify"], [])
        self.assertEqual(report["stale_entries"], 1)
        self.assertEqual(len(report["failed"]), 1)
        self.assertTrue(report["failed"][0]["reason"].startswith("stale_entries"))
        self.assertIs(report["failed"][0]["kept"], False)
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=7), 1, "the new package's entry")
        self.assertEqual([x for x in self.lines(self.live()) if not x.get("header")], [])

    def test_a_modify_fallback_that_fails_is_still_named_in_the_report(self):
        # [Co-developed with claude code -- Adam]
        self.start_proxy()
        self.lose_the_answer_to_one_delete()
        self.ok(exact("10.0.9.9", 5))
        original = FabricSwitch.Write

        def refuse_the_modify(switch, request, timeout=None):
            if request.updates[0].type == p4runtime_pb2.Update.MODIFY:
                raise refused(code_pb2.INVALID_ARGUMENT, "no")
            return original(switch, request, timeout)
        with mock.patch.object(FabricSwitch, "Write", refuse_the_modify):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual(len(report["retried_as_modify"]), 1, "the retry was made, and failed")
        self.assertEqual(len(report["failed"]), 1)
        self.assertIs(report["failed"][0]["kept"], False)
        self.assertEqual(report["failed"][0]["retried_as"], "modify",
                         "the write that failed is the retry")
        self.assertEqual(report["failed"][0]["entry"]["op"], "insert", "the journal's own op")

    def test_an_ordinary_insert_that_meets_an_entry_is_not_retried_as_a_modify(self):
        # Only an `unknown_before` key gets the fallback: an insert journalled as an insert that
        # meets ALREADY_EXISTS is a failure the report names.
        self.start_proxy()
        self.ok(exact("10.0.0.1", 1))
        # A push that empties nothing, so the journal's own insert meets its entry.
        with mock.patch.object(FabricSwitch, "SetForwardingPipelineConfig",
                               lambda sw, req, timeout=None: setattr(sw, "pipeline", True)):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual(report["retried_as_modify"], [])
        self.assertEqual(len(report["failed"]), 1)
        self.assertIn("ALREADY_EXISTS", report["failed"][0]["reason"])


class AModifyThatFindsNothingTest(ReplayCase):
    """
    A net modify whose entry is not on the switch after the push is retried once as an insert:
    the journal's last word for the key is "present with this spec", and only the package's
    entries survive a push. [Co-developed with claude code -- Adam]
    """

    K = "10.0.5.5"

    def land_an_insert_whose_answer_is_lost(self):
        """An insert at K that lands on the switch and is never recorded."""
        self.switches[1].lose_answer = lambda op: deadline() if op == "insert" else None
        status, answer = self.post(exact(self.K, 1))
        self.assertEqual((status, answer.get("grpc_status")), (502, "DEADLINE_EXCEEDED"))
        self.switches[1].lose_answer = None
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=1), 1, "it did land")
        self.assertEqual(self.records(), [], "and nothing was recorded")

    def records(self):
        if not os.path.exists(self.live()):
            return []
        return [(r["op"], r["outcome"]) for r in self.lines(self.live()) if not r.get("header")]

    def delete_then_insert(self):
        """The journal `[delete/ok K, insert S]`: K was on the switch when it was deleted, and
        the insert of K that put it there was never recorded."""
        self.start_proxy()
        self.land_an_insert_whose_answer_is_lost()
        self.ok(exact(self.K, op="delete"))
        self.ok(exact(self.K, 5))
        self.assertEqual(self.records(), [("delete", "ok"), ("insert", "ok")])

    def refusing(self, which, code, only=lambda entry: True):
        """A Write that refuses every `which` update that satisfies `only`, and logs the ops it
        was given in `self.sent`."""
        original = FabricSwitch.Write
        self.sent = []

        def write(switch, request, timeout=None):
            update = request.updates[0]
            op = {p4runtime_pb2.Update.INSERT: "insert", p4runtime_pb2.Update.MODIFY: "modify",
                  p4runtime_pb2.Update.DELETE: "delete"}[update.type]
            self.sent.append(op)
            if op == which and only(update.entity.table_entry):
                raise refused(code, "no")
            return original(switch, request, timeout)
        return mock.patch.object(FabricSwitch, "Write", write)

    def test_a_modify_that_finds_nothing_after_the_push_goes_back_as_an_insert(self):
        self.delete_then_insert()
        self.switches[1].writes.clear()
        self.start_proxy()
        report = self.replay_report()
        self.assertEqual([op for op, _t, _p in self.switches[1].writes], ["modify", "insert"])
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1, "S is on the switch")
        (restored,) = report["restored"]
        self.assertEqual(restored["op"], "modify", "the journal's own op")
        self.assertEqual(report["retried_as_insert"], [restored["key"]])
        self.assertEqual(report["retried_as_modify"], [])
        self.assertEqual((report["status"], report["failed"]), ("complete", []))
        self.assertEqual(self.records(), [("modify", "ok")],
                         "the snapshot keeps the modify, so each boot repeats the fallback")
        self.start_proxy()
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1, "and again a boot later")
        self.assertEqual(len(self.replay_report()["retried_as_insert"]), 1)

    def test_an_insert_made_after_a_restart_that_replayed_the_delete_comes_back(self):
        # `[delete/ok K]` is replayed first: the push emptied the switch, the delete meets
        # NOT_FOUND and is restored. The insert at K is made after that, so the next fold is
        # `[delete/ok K, insert S]`: a modify of an entry the next push will not have put back.
        self.start_proxy()
        self.land_an_insert_whose_answer_is_lost()
        self.ok(exact(self.K, op="delete"))
        self.start_proxy()
        self.assertEqual([r["op"] for r in self.replay_report()["restored"]], ["delete"])
        self.ok(exact(self.K, 5))
        self.assertEqual(self.records(), [("delete", "ok"), ("insert", "ok")])
        self.start_proxy()
        report = self.replay_report()
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1, "S is on the switch")
        self.assertEqual(len(report["retried_as_insert"]), 1)
        self.assertEqual((report["status"], report["failed"]), ("complete", []))

    def test_a_modify_of_an_entry_that_is_there_sends_no_insert(self):
        self.with_entries(BOOT)
        self.start_proxy()
        self.ok(exact("10.0.9.9", 5, op="modify"))
        self.switches[1].writes.clear()
        self.start_proxy()
        report = self.replay_report()
        self.assertEqual([op for op, _t, _p in self.switches[1].writes], ["insert", "modify"],
                         "the package's entry, then the journal's modify of it")
        self.assertEqual(report["retried_as_insert"], [])
        self.assertEqual((report["status"], report["failed"]), ("complete", []))
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1)

    def test_a_modify_refused_for_another_reason_is_failed_and_sends_no_insert(self):
        self.with_entries(BOOT)
        self.start_proxy()
        self.ok(exact("10.0.9.9", 5, op="modify"))
        with self.refusing("modify", code_pb2.INVALID_ARGUMENT):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual(self.sent, ["insert", "modify"], "no insert after the refused modify")
        self.assertEqual(report["retried_as_insert"], [])
        (failed,) = report["failed"]
        self.assertIn("INVALID_ARGUMENT", failed["reason"])
        self.assertNotIn("retried_as", failed)
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=9), 1, "the boot entry, unmodified")

    def test_a_default_entry_modify_that_meets_not_found_sends_no_insert(self):
        # A default entry is never inserted: the switch has one per table from the push on.
        default = {"dpid": 1, "table": "Pkg.t_exact", "default_action": True,
                   "action_name": "Pkg.forward", "action_params": {"port": 2}, "op": "modify"}
        self.start_proxy()
        self.ok(default)
        self.assertEqual(self.records(), [("modify", "ok")])
        with self.refusing("modify", code_pb2.NOT_FOUND, only=lambda e: e.is_default_action):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual(self.sent, ["modify"], "the modify, and nothing after it")
        self.assertEqual(report["retried_as_insert"], [])
        (failed,) = report["failed"]
        self.assertIn("NOT_FOUND", failed["reason"])
        self.assertNotIn("retried_as", failed)

    def test_an_insert_retry_that_fails_is_named_and_failed(self):
        self.delete_then_insert()
        with self.refusing("insert", code_pb2.INVALID_ARGUMENT):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual(self.sent, ["modify", "insert"], "the modify, then the retry")
        self.assertEqual(len(report["retried_as_insert"]), 1, "named although it failed")
        (failed,) = report["failed"]
        self.assertEqual(failed["retried_as"], "insert")
        self.assertEqual(failed["entry"]["op"], "modify", "the journal's own op")
        self.assertIn("INVALID_ARGUMENT", failed["reason"])
        self.assertIs(failed["kept"], False)
        self.assertEqual(report["retried_as_insert"], [failed["entry"]["key"]])
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 0)
        self.assertEqual(report["status"], "failed")

    def journal_key_of_k(self):
        """The key the journal gave K: its first record is the delete of it."""
        return [r for r in self.lines(self.live()) if not r.get("header")][0]["key"]

    def test_a_package_entry_that_did_not_go_back_on_leaves_its_modify_to_go_back_as_an_insert(self):
        # [Co-developed with claude code -- Adam]
        # The package declares B at K and the operator modified K to S, so the journal is
        # `[modify/ok S]`. At the next start the switch refuses B's boot insert: the modify finds
        # nothing, S is the journal's last word for K, and an insert cannot overwrite anything.
        self.with_entries(BOOT)
        self.start_proxy()
        self.ok(exact("10.0.9.9", 5, op="modify"))
        self.ok(exact("10.0.0.1"))
        key = self.journal_key_of_k()
        original = FabricSwitch.Write

        def refuse_the_boot_entry(switch, request, timeout=None):
            entry = request.updates[0].entity.table_entry
            if (request.updates[0].type == p4runtime_pb2.Update.INSERT
                    and int.from_bytes(entry.action.action.params[0].value, "big") == 9):
                raise refused(code_pb2.INVALID_ARGUMENT, "no")
            return original(switch, request, timeout)
        self.switches[1].writes.clear()
        with mock.patch.object(FabricSwitch, "Write", refuse_the_boot_entry):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1, "S is on the switch")
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=9), 0, "the boot entry is not")
        self.assertEqual(report["retried_as_insert"], [key])
        # The journal's two net writes, not the package's boot entry (which is not the journal's
        # and never reached the switch): the modify of K, retried, and the insert at 10.0.0.1.
        self.assertEqual((report["attempted"], report["succeeded"]), (2, 2))
        self.assertEqual((report["status"], report["failed"]), ("complete", []))
        self.assertEqual([op for op, _t, _p in self.switches[1].writes],
                         ["modify", "insert", "insert"], "the modify, its retry, the other insert")
        live = [x for x in self.lines(self.live()) if not x.get("header")]
        self.assertEqual([r["op"] for r in live], ["modify", "insert"], "S stays a modify")

    def test_a_failure_after_a_failed_insert_retry_does_not_say_it_was_a_retry(self):
        # [Co-developed with claude code -- Adam]
        # Two failed items. The first is K's modify, which meets NOT_FOUND and whose insert
        # retry is refused; the second is a modify of the package's boot entry that the switch
        # refuses outright. Only the first was a retry.
        self.with_entries(BOOT)
        self.start_proxy()
        self.land_an_insert_whose_answer_is_lost()
        self.ok(exact(self.K, op="delete"))
        self.ok(exact(self.K, 5))
        self.ok(exact("10.0.9.9", 6, op="modify"))
        original = FabricSwitch.Write

        def refuse_two(switch, request, timeout=None):
            update = request.updates[0]
            port = int.from_bytes(update.entity.table_entry.action.action.params[0].value, "big")
            if ((update.type == p4runtime_pb2.Update.INSERT and port == 5)
                    or (update.type == p4runtime_pb2.Update.MODIFY and port == 6)):
                raise refused(code_pb2.INVALID_ARGUMENT, "no")
            return original(switch, request, timeout)
        with mock.patch.object(FabricSwitch, "Write", refuse_two):
            self.start_proxy()
        report = self.replay_report()
        self.assertEqual((report["attempted"], report["succeeded"]), (2, 0))
        first, second = report["failed"]
        self.assertEqual(first["retried_as"], "insert", "K's insert retry was refused")
        self.assertEqual(second["entry"]["spec"]["action_params"], {"port": 6})
        self.assertIn("INVALID_ARGUMENT", second["reason"])
        self.assertNotIn("retried_as", second, "the second item was never retried")
        self.assertEqual(len(report["retried_as_insert"]), 1)

    def test_a_readopt_puts_back_an_entry_whose_modify_finds_nothing_as_an_insert(self):
        # [Co-developed with claude code -- Adam]
        # `[delete/ok K, insert S]` replayed by a readopt, whose push has emptied the switch.
        self.delete_then_insert()
        key = self.journal_key_of_k()
        self.switches[1].writes.clear()
        result = self.readopt(1)
        self.assertEqual(result["status"], "success")
        report = result["table_entries"]["replay"]
        self.assertEqual(report["when"], "readopt")
        self.assertEqual([op for op, _t, _p in self.switches[1].writes], ["modify", "insert"])
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1, "S is on the switch")
        self.assertEqual(report["retried_as_insert"], [key])
        self.assertEqual((report["status"], report["failed"]), ("complete", []))
        self.assertEqual(self.records(), [("modify", "ok")])

    def test_an_insert_retry_whose_answer_is_lost_stays_in_the_journal_for_the_next_start(self):
        # [Co-developed with claude code -- Adam]
        self.delete_then_insert()
        key = self.journal_key_of_k()
        self.switches[1].lose_answer = lambda op: deadline() if op == "insert" else None
        self.start_proxy()
        self.switches[1].lose_answer = None
        report = self.replay_report()
        self.assertEqual(report["retried_as_insert"], [key])
        (failed,) = report["failed"]
        self.assertIn("DEADLINE_EXCEEDED", failed["reason"])
        self.assertEqual(failed["retried_as"], "insert")
        self.assertEqual(failed["entry"]["op"], "modify", "the journal's own op")
        self.assertIs(failed["kept"], True, "no answer: the insert may have landed")
        self.assertEqual(self.records(), [("modify", "ok")], "so its record is in the snapshot")
        self.start_proxy()
        report = self.replay_report()
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=5), 1, "S is back at the next start")
        self.assertEqual(report["retried_as_insert"], [key])
        self.assertEqual((report["status"], report["failed"]), ("complete", []))


class AJournalThatIsOffSetsEverythingAsideTest(ReplayCase):
    """DESIGN 5.4 step 0: a boot with the journal off cannot vouch for what it leaves behind."""

    def test_an_entry_deleted_while_the_journal_was_off_stays_deleted(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.start_proxy(enabled=False)           # the push empties it; nothing replays
        report = self.replay_report()
        self.assertIs(report["fresh_fabric"], True)
        self.assertEqual(report["cookie"], "the table-entry journal is off")
        self.start_proxy()
        self.assertEqual(self.switches[1].holds(EXACT_ID), 0,
                         "the journal of before the off boot is set aside, not replayed")

    def test_the_off_boot_sets_the_file_aside_byte_for_byte(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        before = self.read_bytes(self.live())
        self.start_proxy(enabled=False)
        self.assertIn(before, [self.read_bytes(p) for p in self.set_aside()])
        self.assertEqual([x for x in self.lines(self.live()) if not x.get("header")], [])


class ABrokenSwitchOnAnOffBootTest(ReplayCase):   # [Co-developed with claude code -- Adam]
    def test_its_report_says_the_journal_is_off_and_promises_no_replay(self):
        self.start_proxy()
        self.switches[1].reachable = False
        self.start_proxy(enabled=False)
        self.assertEqual(self.summary["broken"], [1])
        reason = self.replay_report()["skipped_reason"]
        self.assertIn("journal is off", reason)
        self.assertNotIn("replays its journal", reason)


class AClientWithNoProgramFileTest(ReplayCase):
    """No json_path, no push -- so no replay either (the push loop's own test)."""

    def test_a_switch_that_was_not_pushed_is_not_replayed_into(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        self.switches[1].writes.clear()
        original = a_client

        def no_program(switch, workdir, device_id=1):
            client = original(switch, workdir, device_id)
            client.json_path = None
            return client
        with mock.patch(__name__ + ".a_client", no_program):
            self.start_proxy()
        self.assertEqual(self.switches[1].writes, [], "no replayed insert met the entry")
        self.assertEqual(self.switches[1].holds(EXACT_ID), 1, "still there: nothing emptied it")
        self.assertIn("no pipeline was pushed", self.replay_report()["skipped_reason"])


class TheCookieReadWaitsOneWriteDeadlineTest(ReplayCase):
    def test_cookie_only_is_given_rpc_timeout_s(self):
        from proxy_agent.p4_client import RPC_TIMEOUT_S
        self.start_proxy()
        self.assertEqual(self.switches[1].cookie_timeouts, [RPC_TIMEOUT_S])


class AFailedStep0IsReportedTest(ReplayCase):
    def test_a_header_rewrite_that_fails_is_in_the_report_and_withdraws_the_claim(self):
        # A confirmed switch whose header rewrite fails keeps the old boot's
        # header, so the replay sets it aside as unconfirmed_header -- and the report says why.
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        lines = self.read_bytes(self.live()).decode().splitlines()
        header = json.loads(lines[0])
        header["boot_id"] = "the-proxy-process-before-this-one"
        with open(self.live(), "w") as fh:
            fh.write("\n".join([json.dumps(header)] + lines[1:]) + "\n")

        def no_disk(journal, header, keep=10):
            raise OSError("injected: the disk is full")
        with mock.patch.object(rule_journal.TableEntryJournal, "reheader", no_disk):
            self.start_proxy()
        report = self.replay_report()
        self.assertIn("disk is full", report["step0_error"])
        self.assertEqual(report["cookie"], "confirmed")
        self.assertEqual(report["skipped_reason"], "unconfirmed_header")
        self.assertEqual(self.journals.report(1)["failures"], 1)
        self.assertIs(self.journals.journaled(1), False)


class AReplayWriteWithNoAnswerIsKeptTest(ReplayCase):
    """A replayed write that met a deadline may have landed."""

    def test_an_insert_that_timed_out_stays_in_the_journal_and_comes_back_next_start(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1", 3))
        self.switches[1].refuse = lambda op: deadline() if op == "insert" else None
        self.start_proxy()
        report = self.replay_report()
        self.assertEqual(report["succeeded"], 0)
        self.assertIs(report["failed"][0]["kept"], True)
        live = [x for x in self.lines(self.live()) if not x.get("header")]
        self.assertEqual([r["op"] for r in live], ["insert"], "kept for the next start")
        self.switches[1].refuse = None
        self.start_proxy()
        self.assertEqual(self.switches[1].holds(EXACT_ID, port=3), 1)

    def test_a_write_the_switch_refused_per_update_is_still_dropped(self):
        self.start_proxy()
        self.ok(exact("10.0.0.1", 3))
        self.switches[1].refuse = (lambda op: refused(code_pb2.INVALID_ARGUMENT, "no")
                                   if op == "insert" else None)
        self.start_proxy()
        self.assertIs(self.replay_report()["failed"][0]["kept"], False)
        self.assertEqual([x for x in self.lines(self.live()) if not x.get("header")], [])


class AJournalWithABadByteTest(ReplayCase):
    def test_one_invalid_utf8_byte_does_not_stop_startup(self):
        # The file is read as bytes and each line decoded inside the try.
        self.start_proxy()
        self.ok(exact("10.0.0.1"))
        with open(self.live(), "ab") as fh:
            fh.write(b'{"v":1,"op":"insert","key":"\xff"}\n')
        self.start_proxy()
        report = self.replay_report()
        self.assertEqual((report["succeeded"], report["unreadable"]), (1, 1))
        self.assertEqual(self.switches[1].holds(EXACT_ID), 1)



if __name__ == "__main__":
    unittest.main()
