"""
The table-entry journal: what `POST /p4/table_entry` records, how a record folds, and what the
proxy is allowed to say about it.

[Co-developed with claude code -- Adam]

What the replay does with these records -- startup, readopt, the pipeline cookie -- is
tests/test_table_entry_replay.py. Here `journaled` is asserted where it is computed: true for a
recorded write since the replay exists (`rule_journal.TABLE_JOURNAL_REPLAYS`), and the tests under
`TheClaimFlipsInOnePlace` patch the constant back to False to show that it, and nothing else, is
what decides the claim.

This file is self-contained: `p4_proxy/tests` has no `__init__.py`, so importing another test
file's fixtures works under `-m unittest tests.x` and is a coin flip under a per-file runner.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
# Before anything imports `main`: its table-entry journals go to a temp directory, never to the
# checkout's .run/ (tests/journal_isolation.py). [Co-developed with claude code -- Adam]
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import journal_isolation  # noqa: E402,F401

try:
    import grpc
    from fastapi import HTTPException
    from starlette.requests import Request
    from google.rpc import code_pb2, status_pb2
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2

    from proxy_agent import api_routes
    from proxy_agent import rule_journal
    from proxy_agent.p4_client import P4RuntimeClient
    from proxy_agent.rule_install_times import RuleInstallTimes, entry_key
    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- environment, not behaviour
    HAVE_P4RUNTIME = False

from proxy_agent.rule_journal import (TableEntryJournal, TableJournals, SwitchGone,  # noqa: E402
                                      fold_records, key_digest, records_from_net)

# 🔴 READ AT IMPORT, BEFORE ANY TEST HAS RUN: what main.py itself injected, for the reason
# test_app_package_proxy.WIRED_AT_IMPORT is read there. Importing main is what runs its
# `api_routes.inject_*` calls; reading `api_routes.table_journals` inside a test would assert only
# that an earlier test's cleanup worked.
if HAVE_P4RUNTIME:
    from proxy_agent import main  # noqa: E402
    WIRED_AT_IMPORT = api_routes.table_journals
else:  # pragma: no cover
    main = None
    WIRED_AT_IMPORT = None

PROXY_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LPM_ID = 37375156
TERNARY_ID = 900000001
FORWARD_ID = 28792405


# --- pure record builders (no gRPC) --------------------------------------------------------------


def rec(op, key, spec=None, outcome="ok"):
    """One journal record, in the shape `TableEntryJournal.record` writes."""
    return {"v": 1, "t": 1.0, "op": op, "key": key, "outcome": outcome,
            "spec": {"table": "t", "match": {}, "action_name": "a", "action_params": {},
                     **(spec or {})}}


def a_default(op="modify", **extra):
    return rec(op, "DEFAULT", {"default_action": True, **extra})


# --- a real client with no channel, in front of a recording stub ---------------------------------


def a_p4info():
    p4info = p4info_pb2.P4Info()
    table = p4info.tables.add()
    table.preamble.id = LPM_ID
    table.preamble.name = "MyIngress.ipv4_lpm"
    table.preamble.alias = "ipv4_lpm"
    field = table.match_fields.add()
    field.id = 1
    field.name = "hdr.ipv4.dstAddr"
    field.bitwidth = 32
    field.match_type = p4info_pb2.MatchField.LPM
    table.action_refs.add().id = FORWARD_ID

    # A table with a priority column. Synthetic -- but it is a table NDTwin does not own only because
    # `a_client` binds no routes (`bind_routes(None)`): on the class default, NDTwin's own pipeline,
    # the owner check refuses every table here, this one included.
    ternary = p4info.tables.add()
    ternary.preamble.id = TERNARY_ID
    ternary.preamble.name = "Synthetic.t_ternary"
    ternary.preamble.alias = "t_ternary"
    field = ternary.match_fields.add()
    field.id = 1
    field.name = "hdr.ipv4.srcAddr"
    field.bitwidth = 32
    field.match_type = p4info_pb2.MatchField.TERNARY
    ternary.action_refs.add().id = FORWARD_ID

    # [Co-developed with claude code -- Adam] A range table and an optional table, for the
    # identity tests through the route (both have a priority column).
    for table_id, name, kind in ((900000002, "Synthetic.t_range", p4info_pb2.MatchField.RANGE),
                                 (900000003, "Synthetic.t_optional",
                                  p4info_pb2.MatchField.OPTIONAL)):
        extra = p4info.tables.add()
        extra.preamble.id = table_id
        extra.preamble.name = name
        extra.preamble.alias = name.split(".")[-1]
        field = extra.match_fields.add()
        field.id = 1
        field.name = "hdr.ipv4.srcAddr"
        field.bitwidth = 32
        field.match_type = kind
        extra.action_refs.add().id = FORWARD_ID

    forward = p4info.actions.add()
    forward.preamble.id = FORWARD_ID
    forward.preamble.name = "MyIngress.ipv4_forward"
    forward.preamble.alias = "ipv4_forward"
    param = forward.params.add()
    param.id = 1
    param.name = "dstAddr"
    param.bitwidth = 48
    param = forward.params.add()
    param.id = 2
    param.name = "port"
    param.bitwidth = 9
    return p4info


if HAVE_P4RUNTIME:
    class FakeRpcError(grpc.RpcError):
        def __init__(self, code, trailers=None):
            self._code = code
            self._trailers = trailers

        def code(self):
            return self._code

        def details(self):
            return "fake failure"

        def trailing_metadata(self):
            return self._trailers

    def per_update_trailer(canonical, message):
        status = status_pb2.Status(code=code_pb2.UNKNOWN)
        status.details.add().Pack(p4runtime_pb2.Error(canonical_code=canonical, message=message))
        return (("grpc-status-details-bin", status.SerializeToString()),)

    class RecordingStub:
        def __init__(self, write_error=None):
            self.requests = []
            self.write_error = write_error

        def Write(self, request, timeout=None):
            self.requests.append(request)
            if self.write_error is not None:
                raise self.write_error

    def a_client(stub=None, device_id=1, read_only=False):
        client = P4RuntimeClient.__new__(P4RuntimeClient)
        client.device_id = device_id
        client.grpc_addr = "127.0.0.1:50051"
        client.p4info = a_p4info()
        client.stub = stub if stub is not None else RecordingStub()
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
        # [Co-developed with claude code -- Adam] A FOREIGN PIPELINE WITH NO `roles`: every table
        # here is a user table, as in tests/test_table_entry_route.py's double. Left on the class
        # default (`route_binding.BASELINE`, NDTwin's own pipeline) every write below would be
        # the owner check's 409 `owned_by_ndtwin` before anything is built, and these tests would
        # be about who may write a table instead of about what the journal records.
        # `owned_by_ndtwin` binds one the other way, for the test that an owner refusal leaves
        # no record.
        client.bind_routes(None)
        return client

    def owned_by_ndtwin(client):
        """Bind `client` back to NDTwin's own pipeline, where every table is NDTwin's."""
        from proxy_agent import route_binding
        client.bind_routes(route_binding.BASELINE)
        return client

    class FakeTopology:
        def __init__(self, switches):
            self.switches = switches

        def switch_liveness(self):
            return {"status": "success", "probe_interval_s": 2.0,
                    "switches": {str(d): {"probe_ok": True} for d in self.switches},
                    "boot_id": "b", "boot_at": 1.0}

    def a_request(body):
        payload = json.dumps(body).encode()

        async def receive():
            return {"type": "http.request", "body": payload, "more_body": False}

        return Request({"type": "http", "http_version": "1.1", "method": "POST",
                        "path": "/p4/table_entry", "raw_path": b"/p4/table_entry",
                        "root_path": "", "scheme": "http", "query_string": b"",
                        "headers": [(b"content-type", b"application/json")],
                        "client": ("127.0.0.1", 0), "server": ("127.0.0.1", 8081)}, receive)


AN_LPM_ENTRY = {"dpid": 1, "table": "MyIngress.ipv4_lpm",
                "match": {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}


class TempDirCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ndt-table-journal-")
        self.addCleanup(shutil.rmtree, self.dir, True)

    def lines(self, name="s1.jsonl"):
        with open(os.path.join(self.dir, name), encoding="utf-8") as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def records(self, name="s1.jsonl"):
        return [x for x in self.lines(name) if not x.get("header")]


# =============================================================================================
# R13. The fold: one test per outcome, and the default.
# =============================================================================================


class TheFoldTest(unittest.TestCase):
    """
    The first record of an entry says whether it existed before the API touched it; the last says
    whether it exists after, and with what. Tested here without a file,
    because the fold is a pure function and a test of it that needs a disk is a test of the disk.
    """

    def test_not_there_then_there_is_an_insert_of_the_last_spec(self):
        net = fold_records([rec("insert", "A", {"action_params": {"port": 1}}),
                            rec("modify", "A", {"action_params": {"port": 2}})])
        self.assertEqual([(n["op"], n["spec"]["action_params"]) for n in net],
                         [("insert", {"port": 2})])

    def test_there_then_there_is_a_modify_of_the_last_spec(self):
        # First record a modify: the entry was already there (a boot entry), so the net is a
        # modify and not an insert -- an insert would be refused as already-existing.
        net = fold_records([rec("modify", "A", {"action_params": {"port": 1}}),
                            rec("modify", "A", {"action_params": {"port": 7}})])
        self.assertEqual([(n["op"], n["spec"]["action_params"]) for n in net],
                         [("modify", {"port": 7})])

    def test_there_then_gone_is_a_delete(self):
        net = fold_records([rec("modify", "A"), rec("delete", "A")])
        self.assertEqual([n["op"] for n in net], ["delete"])

    def test_a_delete_with_nothing_before_it_is_still_a_delete(self):
        # A delete the switch ACCEPTED removed something the API never wrote: a boot entry.
        # Folding it away would resurrect that entry after a replay, which is the failure the
        # journal exists to prevent.
        net = fold_records([rec("delete", "A")])
        self.assertEqual([n["op"] for n in net], ["delete"])

    # --- a delete answered NOT_FOUND says nothing about whether the entry was there before --

    def test_a_not_found_delete_then_an_insert_is_an_insert(self):
        # The switch said the entry was not there, so it began unknown and the insert's spec is
        # what it should be: an insert (with a modify fallback). Folded as "there", it would be a
        # plain modify -- refused after the push empties the table.
        net = fold_records([rec("delete", "A", outcome="not_found"),
                            rec("insert", "A", {"action_params": {"port": 4}})])
        self.assertEqual([(n["op"], n["spec"]["action_params"]) for n in net],
                         [("insert", {"port": 4})])

    def test_an_insert_then_a_not_found_delete_is_nothing(self):
        # The other order: it began absent (an insert) and the last word is a delete, whatever
        # the switch answered it.
        self.assertEqual(fold_records([rec("insert", "A"),
                                       rec("delete", "A", outcome="not_found")]), [])

    def test_a_lone_not_found_delete_is_a_net_delete(self):
        # The first NOT_FOUND leaves "before" unknown -- the reason may be a lost-answer delete
        # of a package boot entry the next push puts back -- and absent is the last word, so the
        # replay deletes it; a NOT_FOUND then means done. The mark is kept even though a delete
        # has no insert to retry: a snapshot of it must fold back to a delete that began unknown,
        # or an insert of the same key after the next start would fold to a modify.
        net = fold_records([rec("delete", "A", outcome="not_found")])
        self.assertEqual([n["op"] for n in net], ["delete"])
        self.assertIs(net[0].get("unknown_before"), True)

    def test_a_not_found_delete_then_an_insert_is_an_insert_marked_unknown_before(self):
        net = fold_records([rec("delete", "A", outcome="not_found"), rec("insert", "A")])
        self.assertEqual([(n["op"], n.get("unknown_before")) for n in net], [("insert", True)])

    def test_an_ordinary_insert_is_not_marked_unknown_before(self):
        net = fold_records([rec("insert", "A")])
        self.assertNotIn("unknown_before", net[0])

    def test_a_snapshot_of_an_unknown_start_delete_then_an_insert_is_an_insert_marked_unknown(self):
        # [Co-developed with claude code -- Adam]
        # The snapshot of a lone NOT_FOUND delete is what the next start reads. An insert of the
        # same key made after that start must still fold to an insert that began unknown -- not
        # to a modify, which the switch refuses once the push has emptied the table.
        snapshot = records_from_net(fold_records([rec("delete", "K", outcome="not_found")]))
        net = fold_records(snapshot + [rec("insert", "K", {"action_params": {"port": 4}})])
        self.assertEqual([(n["op"], n.get("unknown_before"), n["spec"]["action_params"])
                          for n in net], [("insert", True, {"port": 4})])

    def test_an_accepted_delete_then_an_insert_is_still_a_modify(self):
        # The boot-entry case, unchanged: the accepted delete removed something, so the key began
        # present and the insert put it back -- after the replay's push and boot entries, that
        # is a modify of the boot entry.
        net = fold_records([rec("delete", "A"),
                            rec("insert", "A", {"action_params": {"port": 6}})])
        self.assertEqual([(n["op"], n["spec"]["action_params"]) for n in net],
                         [("modify", {"port": 6})])

    def test_only_the_first_record_decides_what_was_there_before(self):
        # A not_found delete that is NOT first says nothing about before: modify, then a delete
        # nobody's switch could find, then an insert is still a boot entry put back.
        net = fold_records([rec("modify", "A"), rec("delete", "A", outcome="not_found"),
                            rec("insert", "A")])
        self.assertEqual([n["op"] for n in net], ["modify"])
        # And a not_found delete that is LAST says only "absent after": a boot entry modified and
        # then deleted is still a delete.
        net = fold_records([rec("modify", "B"), rec("delete", "B", outcome="not_found")])
        self.assertEqual([n["op"] for n in net], ["delete"])

    def test_a_snapshot_of_a_fold_with_not_found_deletes_folds_to_the_same(self):
        # records_from_net must keep an entry's unknown start: the snapshot is what the next
        # boot folds.
        history = [rec("delete", "A", outcome="not_found"), rec("insert", "A"),
                   rec("delete", "B"),
                   rec("delete", "C", outcome="not_found"),
                   rec("insert", "D"), rec("delete", "D", outcome="not_found")]
        net = fold_records(history)
        self.assertEqual([(n["key"], n["op"]) for n in net],
                         [("A", "insert"), ("B", "delete"), ("C", "delete")])
        again = fold_records(records_from_net(net))
        self.assertEqual([(n["key"], n["op"], n["spec"], n.get("unknown_before")) for n in again],
                         [(n["key"], n["op"], n["spec"], n.get("unknown_before")) for n in net],
                         "the snapshot keeps A's unknown start, so the next boot may still meet "
                         "a boot entry there")

    def test_not_there_then_not_there_is_nothing(self):
        self.assertEqual(fold_records([rec("insert", "A"), rec("delete", "A")]), [])

    def test_gone_then_back_is_a_modify_of_the_reinsert(self):
        net = fold_records([rec("modify", "A", {"action_params": {"port": 1}}),
                            rec("delete", "A"),
                            rec("insert", "A", {"action_params": {"port": 3}})])
        self.assertEqual([(n["op"], n["spec"]["action_params"]) for n in net],
                         [("modify", {"port": 3})])

    def test_a_deleted_then_reinserted_entry_that_began_absent_is_an_insert(self):
        net = fold_records([rec("insert", "A", {"action_params": {"port": 1}}),
                            rec("delete", "A"),
                            rec("insert", "A", {"action_params": {"port": 3}})])
        self.assertEqual([(n["op"], n["spec"]["action_params"]) for n in net],
                         [("insert", {"port": 3})])

    def test_each_entry_folds_on_its_own_and_in_the_order_it_first_appeared(self):
        net = fold_records([rec("insert", "B"), rec("insert", "A"), rec("modify", "C"),
                            rec("delete", "B"), rec("modify", "A")])
        self.assertEqual([(n["key"], n["op"]) for n in net], [("A", "insert"), ("C", "modify")])

    def test_a_default_entry_nets_to_one_modify_of_its_last_spec(self):
        net = fold_records([a_default(action_name="x"), a_default(action_name="y")])
        self.assertEqual([(n["op"], n["spec"]["action_name"]) for n in net], [("modify", "y")])

    def test_a_default_entry_is_never_an_insert(self):
        # Even if a record said insert (the writer turns a default insert into a modify before it
        # is recorded, but the fold must not depend on that).
        net = fold_records([a_default("insert")])
        self.assertEqual([n["op"] for n in net], ["modify"])

    def test_a_default_entry_whose_last_record_is_a_delete_nets_to_nothing(self):
        # A switch refuses to delete a default, so this cannot come from a real journal; the fold
        # must still not turn it into a write that would be refused again at replay.
        self.assertEqual(fold_records([a_default("modify"), a_default("delete")]), [])

    def test_the_header_and_a_line_that_is_not_a_record_are_not_folded(self):
        net = fold_records([{"v": 1, "header": True, "dpid": 1}, "junk", 7,
                            {"op": "insert"}, rec("insert", "A")])
        self.assertEqual([n["key"] for n in net], ["A"])

    def test_folding_does_not_change_its_input(self):
        records = [rec("insert", "A"), rec("modify", "A")]
        before = json.dumps(records, sort_keys=True)
        fold_records(records)
        self.assertEqual(json.dumps(records, sort_keys=True), before)

    def test_a_folded_journal_folds_to_itself(self):
        # The property a snapshot relies on: the new file is `records_from_net(net)`, and folding
        # it again must say the same thing, or a second restart would replay something else.
        history = [rec("modify", "A", {"action_params": {"port": 1}}),
                   rec("delete", "B"),
                   rec("insert", "C", {"action_params": {"port": 5}}),
                   rec("insert", "D"), rec("delete", "D"),
                   a_default(action_name="z")]
        net = fold_records(history)
        self.assertEqual([n["op"] for n in net], ["modify", "delete", "insert", "modify"])
        again = fold_records(records_from_net(net))
        self.assertEqual([(n["key"], n["op"], n["spec"]) for n in again],
                         [(n["key"], n["op"], n["spec"]) for n in net])


# =============================================================================================
# The file: header, records, torn lines, snapshot.
# =============================================================================================


class TheFileTest(TempDirCase):
    def a_journal(self, header=None):
        return TableEntryJournal(os.path.join(self.dir, "s7.jsonl"), 7, header=header)

    def test_the_first_line_is_a_header_and_then_one_record_per_line(self):
        journal = self.a_journal(lambda: {"p4info_sha256": "abc", "entries_sha256": None,
                                          "boot_id": "boot1"})
        self.assertTrue(journal.record("insert", {"table": "t"}, "K1"))
        self.assertTrue(journal.record("delete", {"table": "t"}, "K1"))
        lines = self.lines("s7.jsonl")
        self.assertEqual(len(lines), 3)
        self.assertTrue(lines[0]["header"])
        self.assertEqual((lines[0]["dpid"], lines[0]["p4info_sha256"], lines[0]["boot_id"]),
                         (7, "abc", "boot1"))
        # This provider names no cookie, and the header says so rather than leaving the key out
        # (main's provider names one: TheJournalIsWiredInMainTest).
        self.assertIsNone(lines[0]["fabric_cookie"])
        self.assertEqual([(x["op"], x["key"], x["outcome"]) for x in lines[1:]],
                         [("insert", "K1", "ok"), ("delete", "K1", "ok")])

    def test_the_header_is_written_once_not_per_record(self):
        journal = self.a_journal()
        for n in range(3):
            journal.record("insert", {}, f"K{n}")
        self.assertEqual(sum(1 for x in self.lines("s7.jsonl") if x.get("header")), 1)

    def test_a_header_that_cannot_be_built_does_not_lose_the_record(self):
        def broken():
            raise RuntimeError("no package")
        journal = self.a_journal(broken)
        self.assertTrue(journal.record("insert", {}, "K"))
        self.assertEqual([x["key"] for x in self.records("s7.jsonl")], ["K"])

    def test_read_gives_the_header_the_records_and_the_count_of_lines_it_could_not_read(self):
        journal = self.a_journal(lambda: {"boot_id": "b"})
        journal.record("insert", {}, "K1")
        with open(journal.path, "a", encoding="utf-8") as fh:
            fh.write("{torn\n")
            fh.write("[1, 2]\n")
        journal.record("modify", {}, "K1")
        header, records, unreadable = journal.read()
        self.assertEqual(header["boot_id"], "b")
        self.assertEqual([r["op"] for r in records], ["insert", "modify"])
        self.assertEqual(unreadable, 2)

    def test_a_line_that_is_not_utf8_is_one_unreadable_line_not_an_exception(self):
        # Startup reads every switch's file in step 0; one bad byte must not raise out of it.
        journal = self.a_journal(lambda: {"boot_id": "b"})
        journal.record("insert", {}, "K1")
        with open(journal.path, "ab") as fh:
            fh.write(b'{"v":1,"op":"insert","key":"\xff\xfe"}\n')
        journal.record("insert", {}, "K2")
        header, records, unreadable = journal.read()
        self.assertEqual([r["key"] for r in records], ["K1", "K2"])
        self.assertEqual(unreadable, 1)

    def test_a_missing_file_reads_as_empty_and_not_as_an_error(self):
        self.assertEqual(self.a_journal().read(), (None, [], 0))
        self.assertEqual(self.a_journal().fold(), [])

    def test_a_torn_last_line_does_not_swallow_the_next_record(self):
        journal = self.a_journal()
        journal.record("insert", {}, "K1")
        with open(journal.path, "ab") as fh:
            fh.write(b'{"v":1,"op":"ins')   # a crash mid-write: no newline
        journal.record("insert", {}, "K2")
        _header, records, unreadable = journal.read()
        self.assertEqual([r["key"] for r in records], ["K1", "K2"])
        self.assertEqual(unreadable, 1)

    def test_record_never_raises_and_says_false_when_the_disk_will_not_take_it(self):
        blocker = os.path.join(self.dir, "not-a-directory")
        with open(blocker, "w") as fh:
            fh.write("x")
        journal = TableEntryJournal(os.path.join(blocker, "s7.jsonl"), 7)
        self.assertIs(journal.record("insert", {}, "K"), False)

    def test_record_says_false_for_a_spec_that_is_not_json_instead_of_raising(self):
        self.assertIs(self.a_journal().record("insert", {"x": object()}, "K"), False)

    def test_fold_reads_the_file(self):
        journal = self.a_journal()
        journal.record("modify", {"table": "t", "match": {}}, "A")
        journal.record("delete", {"table": "t", "match": {}}, "A")
        self.assertEqual([n["op"] for n in journal.fold()], ["delete"])


class TheSnapshotTest(TempDirCase):
    """Every snapshot here is taken under the journal's lock, as every production caller takes it
    (`test_a_snapshot_nobody_holds_the_lock_for_is_refused` is why)."""

    def a_journal(self):
        journal = TableEntryJournal(os.path.join(self.dir, "s7.jsonl"), 7)
        for n in range(3):
            journal.record("insert", {"table": "t", "n": n}, f"K{n}")
        journal.lock.acquire()
        self.addCleanup(lambda: journal.lock.locked() and journal.lock.release())
        return journal

    def read_bytes(self, path):
        with open(path, "rb") as fh:
            return fh.read()

    def test_the_new_file_is_the_header_and_the_given_records(self):
        journal = self.a_journal()
        keep = [rec("insert", "K9")]
        journal.write_snapshot({"boot_id": "b2", "p4info_sha256": "p"}, keep)
        header, records, unreadable = journal.read()
        self.assertEqual((header["boot_id"], header["p4info_sha256"], header["dpid"]),
                         ("b2", "p", 7))
        self.assertEqual([r["key"] for r in records], ["K9"])
        self.assertEqual(unreadable, 0)

    def test_the_old_file_is_kept_byte_for_byte_under_another_name(self):
        journal = self.a_journal()
        old = self.read_bytes(journal.path)
        quarantined = journal.write_snapshot({}, [])
        self.assertNotEqual(quarantined, journal.path)
        self.assertEqual(self.read_bytes(quarantined), old)

    def test_the_set_aside_generation_is_the_old_file_itself_and_the_live_one_is_new(self):
        # The set-aside name is the old inode (a link or a rename both give that). What tells a
        # LINK from a rename is the crash test below: with a rename the live path names nothing
        # between the two steps.
        journal = self.a_journal()
        before = os.stat(journal.path).st_ino
        quarantined = journal.write_snapshot({}, [])
        self.assertEqual(os.stat(quarantined).st_ino, before)
        self.assertNotEqual(os.stat(journal.path).st_ino, before)

    def test_a_crash_before_the_replace_leaves_the_old_file_whole(self):
        # Fault injection: the step after the link raises. A snapshot that overwrote in place
        # would already have destroyed the old content by now.
        journal = self.a_journal()
        old = self.read_bytes(journal.path)
        original = rule_journal.os.replace

        def boom(src, dst):
            raise OSError("injected: crash before the replace")
        rule_journal.os.replace = boom
        try:
            with self.assertRaises(OSError):
                journal.write_snapshot({"boot_id": "new"}, [rec("insert", "NEW")])
        finally:
            rule_journal.os.replace = original
        self.assertEqual(self.read_bytes(journal.path), old)
        self.assertEqual([n for n in os.listdir(self.dir) if ".tmp." in n], [],
                         "a failed snapshot must not leave its temp file behind")

    def test_a_first_snapshot_with_no_live_file_quarantines_nothing(self):
        journal = TableEntryJournal(os.path.join(self.dir, "s9.jsonl"), 9)
        with journal.lock:
            self.assertIsNone(journal.write_snapshot({}, []))

    # --- the snapshot's lock, one header shape, what a crash leaves ----------------------

    def test_a_snapshot_nobody_holds_the_lock_for_is_refused(self):
        # One lock covers the append and the snapshot. A record appended between the
        # snapshot's link and its replace would land in the set-aside inode and be lost.
        journal = TableEntryJournal(os.path.join(self.dir, "s9.jsonl"), 9)
        journal.record("insert", {}, "K")
        before = self.read_bytes(journal.path)
        with self.assertRaises(RuntimeError):
            journal.write_snapshot({}, [])
        with self.assertRaises(RuntimeError):
            journal.reheader({})
        self.assertEqual(self.read_bytes(journal.path), before)
        self.assertEqual(sorted(os.listdir(self.dir)), ["s9.jsonl"])

    def test_a_snapshot_header_has_the_shape_a_recorded_header_has(self):
        journal = self.a_journal()
        recorded_header = self.lines("s7.jsonl")[0]
        journal.write_snapshot({"boot_id": "b2", "unknown_key": 1, "dpid": 99}, [])
        header = self.lines("s7.jsonl")[0]
        self.assertEqual(sorted(header), sorted(recorded_header))
        self.assertEqual((header["dpid"], header["boot_id"], header["fabric_cookie"]),
                         (7, "b2", None))

    def test_reheader_keeps_every_other_line_byte_for_byte_torn_ones_too(self):
        journal = self.a_journal()
        with open(journal.path, "ab") as fh:
            fh.write(b"{torn\n")
        body_before = self.read_bytes(journal.path).split(b"\n", 1)[1]
        quarantined = journal.reheader({"boot_id": "b3", "fabric_cookie": "00000000000000ab"})
        self.assertIsNotNone(quarantined)
        head, body = self.read_bytes(journal.path).split(b"\n", 1)
        self.assertEqual(body, body_before)
        self.assertEqual(json.loads(head)["boot_id"], "b3")
        self.assertEqual(journal.read()[2], 1, "the torn line is still counted")

    def test_a_temp_file_a_dead_snapshot_left_is_removed_by_the_next(self):
        journal = self.a_journal()
        stale = os.path.join(self.dir, "s7.jsonl.tmp.leftover")
        other = os.path.join(self.dir, "s8.jsonl.tmp.leftover")
        for path in (stale, other):
            with open(path, "w") as fh:
                fh.write("half a snapshot")
        journal.write_snapshot({}, [])
        self.assertFalse(os.path.exists(stale))
        self.assertTrue(os.path.exists(other), "another switch's temp file is not this one's")

    def test_the_live_file_keeps_its_mode_through_a_snapshot(self):
        journal = self.a_journal()
        os.chmod(journal.path, 0o640)
        journal.write_snapshot({}, [])
        self.assertEqual(os.stat(journal.path).st_mode & 0o777, 0o640)

    def test_ten_generations_are_kept_by_default(self):
        journal = self.a_journal()
        for _ in range(12):
            journal.write_snapshot({}, [])
            time.sleep(0.002)
        self.assertEqual(len([n for n in os.listdir(self.dir) if ".q" in n]),
                         rule_journal.QUARANTINE_KEEP)
        self.assertEqual(rule_journal.QUARANTINE_KEEP, 10)

    def test_only_the_most_recent_generations_are_kept(self):
        journal = self.a_journal()
        made = []
        for _ in range(5):
            made.append(os.path.basename(journal.write_snapshot({}, [rec("insert", "K")], keep=2)))
            time.sleep(0.002)
        kept = sorted(n for n in os.listdir(self.dir) if ".q" in n)
        self.assertEqual(kept, sorted(made)[-2:],
                         "the two NEWEST set-aside generations survive, not any two")

    def test_the_snapshot_survives_a_read_back_through_the_fold(self):
        journal = self.a_journal()
        net = journal.fold()
        journal.write_snapshot({}, records_from_net(net))
        self.assertEqual([(n["key"], n["op"]) for n in journal.fold()],
                         [(n["key"], n["op"]) for n in net])


# =============================================================================================
# The write: switch first, journal second, one lock around both.
# =============================================================================================


class AFakeSwitch:
    """Just enough client for `write_and_journal`: records what it was asked, can refuse."""

    def __init__(self, error=None, key=("1", "t", 0, ())):
        self.error = error
        self.key = key
        self.calls = []

    def write_table_entry(self, spec, op):
        self.calls.append((op, spec))
        if self.error is not None:
            raise self.error
        return {"op": op, "entry_key": self.key}

    def table_entry_key(self, spec):
        return self.key


class TheOrderOfTheWriteTest(TempDirCase):
    def journals(self, **kw):
        return TableJournals(self.dir, **kw)

    def test_a_write_the_switch_refuses_is_not_recorded(self):
        # R11. The journal holds what the switch took; replaying a refused entry would install
        # something that never existed. Red only on a mutant that records first (M-J1).
        switch = AFakeSwitch(error=RuntimeError("refused"))
        journals = self.journals()
        with self.assertRaises(RuntimeError):
            journals.write_and_journal(lambda: switch, 1, {"table": "t"}, "insert")
        self.assertFalse(os.path.exists(os.path.join(self.dir, "s1.jsonl")))
        self.assertEqual(journals.report(1)["recorded"], 0)
        self.assertEqual(journals.report(1)["failures"], 0)

    def test_the_record_is_made_after_the_switch_has_taken_the_write(self):
        journals = self.journals()
        journal = journals.journal_for(1)
        seen = []
        original = journal.record

        def spying(*a, **kw):
            seen.append(list(switch.calls))
            return original(*a, **kw)
        journal.record = spying
        switch = AFakeSwitch()
        journals.write_and_journal(lambda: switch, 1, {"table": "t"}, "insert")
        self.assertEqual(seen, [[("insert", {"table": "t"})]],
                         "the switch must already have the write when the journal is asked to "
                         "record it")

    def test_what_is_recorded_is_the_op_the_switch_got_and_the_spec_that_was_validated(self):
        switch = AFakeSwitch()
        journals = self.journals()
        spec = {"table": "t", "match": {"f": 1}, "default_action": True}
        written, recorded = journals.write_and_journal(lambda: switch, 1, spec, "modify")
        self.assertTrue(recorded)
        (record,) = self.records()
        self.assertEqual((record["op"], record["spec"]), ("modify", spec))
        self.assertEqual(record["key"], key_digest(switch.key))

    def test_the_op_recorded_is_the_one_on_the_wire_not_the_one_asked_for(self):
        # A default entry's insert goes out as a modify (write_table_entry says so in `written`),
        # and the fold's default rule and the replay both read `op` as what happened.
        class Substituting(AFakeSwitch):
            def write_table_entry(self, spec, op):
                return {"op": "modify", "entry_key": self.key}
        journals = self.journals()
        journals.write_and_journal(lambda: Substituting(), 1, {"table": "t"}, "insert")
        self.assertEqual(self.records()[0]["op"], "modify")

    def test_a_switch_that_is_gone_is_a_SwitchGone_and_nothing_is_recorded(self):
        with self.assertRaises(SwitchGone):
            self.journals().write_and_journal(lambda: None, 1, {}, "insert")
        self.assertFalse(os.path.exists(os.path.join(self.dir, "s1.jsonl")))

    def test_the_client_is_looked_up_inside_the_lock(self):
        # A readopt swaps the client; the write must go through the one that is current when the
        # lock is taken, not the one that was current when the request arrived.
        journals = self.journals()
        journal = journals.journal_for(1)
        held = []

        def lookup():
            held.append(journal.lock.locked())
            return AFakeSwitch()
        journals.write_and_journal(lookup, 1, {"table": "t"}, "insert")
        self.assertEqual(held, [True])

    def test_each_switch_has_its_own_file_and_its_own_lock(self):
        journals = self.journals()
        journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "a"}, "insert")
        journals.write_and_journal(lambda: AFakeSwitch(), 2, {"table": "b"}, "insert")
        self.assertEqual([r["spec"]["table"] for r in self.records("s1.jsonl")], ["a"])
        self.assertEqual([r["spec"]["table"] for r in self.records("s2.jsonl")], ["b"])
        self.assertIsNot(journals.journal_for(1).lock, journals.journal_for(2).lock)

    def test_a_delete_the_switch_answered_NOT_FOUND_is_recorded_as_not_found_and_still_raised(self):
        # A delete whose answer was lost may have landed, and the retry's NOT_FOUND
        # is the only evidence. It is a 502 to the caller (the exception propagates) and a
        # `not_found` line to the journal.
        error = RuntimeError("NOT_FOUND")
        switch = AFakeSwitch(error=error)
        journals = self.journals()
        with self.assertRaises(RuntimeError) as caught:
            journals.write_and_journal(lambda: switch, 1, {"table": "t"}, "delete",
                                       refusal_is_not_found=lambda e: e is error)
        self.assertIs(caught.exception, error)
        (record,) = self.records()
        self.assertEqual((record["op"], record["outcome"]), ("delete", "not_found"))
        # `recorded` is ACCEPTED writes that reached the file -- what `api_writes` counts. This
        # was a refused write (a 502), so it is counted on its own and `recorded` does not move.
        report = journals.report(1)
        self.assertEqual((report["recorded"], report["not_found"]), (0, 1))
        self.assertIs(report["record_complete"], True,
                      "a not_found record that reached the file is not a failure")

    def test_an_accepted_write_and_a_not_found_delete_are_counted_apart(self):
        journals = self.journals()
        journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        with self.assertRaises(RuntimeError):
            journals.write_and_journal(lambda: AFakeSwitch(error=RuntimeError("x")), 1,
                                       {"table": "t"}, "delete",
                                       refusal_is_not_found=lambda e: True)
        report = journals.report(1)
        self.assertEqual((report["recorded"], report["not_found"], report["failures"]),
                         (1, 1, 0))

    def test_a_not_found_record_the_disk_would_not_take_is_a_failure_not_a_not_found(self):
        journals = TableJournals(self.dir)
        journals.journal_for(1).record = lambda *a, **kw: False
        with self.assertRaises(RuntimeError):
            journals.write_and_journal(lambda: AFakeSwitch(error=RuntimeError("x")), 1,
                                       {"table": "t"}, "delete",
                                       refusal_is_not_found=lambda e: True)
        report = journals.report(1)
        self.assertEqual((report["not_found"], report["failures"]), (0, 1))

    def test_no_other_refusal_is_recorded(self):
        error = RuntimeError("INVALID_ARGUMENT")
        for op in ("insert", "modify", "delete"):
            journals = self.journals()
            with self.assertRaises(RuntimeError):
                journals.write_and_journal(lambda: AFakeSwitch(error=error), 1, {}, op,
                                           refusal_is_not_found=lambda e: False)
        # ... and a NOT_FOUND that is not a delete (a modify at a priority that does not exist)
        # is a refusal like any other.
        nf = RuntimeError("NOT_FOUND")
        with self.assertRaises(RuntimeError):
            self.journals().write_and_journal(lambda: AFakeSwitch(error=nf), 1, {}, "modify",
                                              refusal_is_not_found=lambda e: True)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "s1.jsonl")))

    def test_a_journal_that_is_off_does_not_record_a_not_found_delete_either(self):
        error = RuntimeError("NOT_FOUND")
        journals = self.journals(enabled=False)
        with self.assertRaises(RuntimeError):
            journals.write_and_journal(lambda: AFakeSwitch(error=error), 1, {"table": "t"},
                                       "delete", refusal_is_not_found=lambda e: True)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "s1.jsonl")))

    def test_a_recording_that_is_switched_off_still_writes_and_records_nothing(self):
        switch = AFakeSwitch()
        journals = self.journals(enabled=False)
        written, recorded = journals.write_and_journal(lambda: switch, 1, {"table": "t"}, "insert")
        self.assertEqual(len(switch.calls), 1)
        self.assertIs(recorded, False)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "s1.jsonl")))
        self.assertIs(journals.report(1)["enabled"], False)
        self.assertEqual(journals.report(1)["failures"], 0,
                         "a journal that is off has not failed")


class TheLockTest(TempDirCase):
    """
    The write and the record are one critical section. Without it two POSTs to one switch can
    land A, B on the wire and be journaled B, A -- and a fold that reads the journal in order
    would then reverse them. The route runs on FastAPI's threadpool, so this is a real race.
    """

    def run_two(self, journals):
        """Run A then B on two threads. A's write and A's record each wait for B to arrive, if B
        is ever allowed to; returns the event log in the order it happened."""
        log = []
        b_arrived = threading.Event()
        a_started = threading.Event()

        class Switch:
            def write_table_entry(self, spec, op):
                log.append(f"write {spec['id']}")
                if spec["id"] == "B":
                    b_arrived.set()
                if spec["id"] == "A":
                    a_started.set()
                    b_arrived.wait(0.25)       # B only arrives here if nothing stops it
                return {"op": op, "entry_key": ("1", "t", 0, (spec["id"],))}

            def table_entry_key(self, spec):
                return None

        journal = journals.journal_for(1)
        original = journal.record

        def slow_record(op, spec, key, outcome="ok"):
            if spec["id"] == "A":
                b_arrived.wait(0.25)
            ok = original(op, spec, key, outcome)
            log.append(f"record {spec['id']}")
            return ok
        journal.record = slow_record
        switch = Switch()

        def go(ident):
            journals.write_and_journal(lambda: switch, 1, {"id": ident, "table": "t"}, "insert")

        a = threading.Thread(target=go, args=("A",))
        b = threading.Thread(target=go, args=("B",))
        a.start()
        self.assertTrue(a_started.wait(2))
        b.start()
        a.join(5)
        b.join(5)
        self.assertFalse(a.is_alive() or b.is_alive(), "a write never finished")
        return log

    def test_two_writes_to_one_switch_never_interleave_with_each_others_record(self):
        log = self.run_two(TableJournals(self.dir))
        self.assertEqual(log, ["write A", "record A", "write B", "record B"])

    def test_the_journal_order_is_the_order_the_switch_saw(self):
        self.run_two(TableJournals(self.dir))
        self.assertEqual([r["spec"]["id"] for r in self.records()], ["A", "B"])


# =============================================================================================
# A journal that cannot be written.
# =============================================================================================


class AJournalThatCannotBeWrittenTest(TempDirCase):
    """
    R12. The rule IS on the switch, so the answer is a 200 and the failure is counted and shown --
    and it stays shown, because a missing record can make every later fold wrong (an insert that
    was never recorded, then a delete and a re-insert that were: the fold reads the delete as
    removing something that was "already there").
    """

    def broken(self):
        blocker = os.path.join(self.dir, "blocker")
        with open(blocker, "w") as fh:
            fh.write("x")
        return TableJournals(os.path.join(blocker, "journal"))

    def test_the_write_still_succeeds_and_says_it_was_not_recorded(self):
        switch = AFakeSwitch()
        journals = self.broken()
        written, recorded = journals.write_and_journal(lambda: switch, 1, {"table": "t"}, "insert")
        self.assertEqual(len(switch.calls), 1)
        self.assertIs(recorded, False)

    def test_each_failure_is_counted_and_a_success_does_not_hide_it(self):
        journals = self.broken()
        journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        report = journals.report(1)
        self.assertEqual((report["failures"], report["recorded"]), (2, 0))

    def test_the_failure_is_permanent_for_the_boot_even_after_the_disk_recovers(self):
        journals = TableJournals(self.dir)
        journal = journals.journal_for(1)
        original = journal.record
        journal.record = lambda *a, **kw: False
        journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        journal.record = original
        written, recorded = journals.write_and_journal(lambda: AFakeSwitch(), 1,
                                                       {"table": "t"}, "insert")
        self.assertIs(recorded, True)
        report = journals.report(1)
        self.assertEqual((report["recorded"], report["failures"]), (1, 1))
        self.assertIs(report["record_complete"], False,
                      "one lost record makes the journal untrustworthy until the proxy restarts")

    def test_another_switchs_failure_is_not_this_switchs(self):
        journals = TableJournals(self.dir)
        journals.journal_for(2).record = lambda *a, **kw: False
        journals.write_and_journal(lambda: AFakeSwitch(), 2, {"table": "t"}, "insert")
        journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        self.assertIs(journals.report(1)["record_complete"], True)
        self.assertIs(journals.report(2)["record_complete"], False)


class TheThreeConditionsTest(TempDirCase):
    """
    R12b. `record_complete` -- and, once something replays, `journaled` -- needs ALL of: recording
    is on, the switch is ours to write, and no record has failed. One test per condition, each
    flipping only that one, because a conjunction with a missing term passes every test that holds
    the other two true.
    """

    def good(self, **kw):
        journals = TableJournals(self.dir, **kw)
        journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        return journals

    def test_all_three_true_is_complete(self):
        self.assertIs(self.good().report(1)["record_complete"], True)

    def test_recording_off_is_not_complete(self):
        self.assertIs(self.good(enabled=False).report(1)["record_complete"], False)

    def test_an_external_control_plane_is_not_complete(self):
        # The proxy only reads such a fabric; nothing it wrote is its to claim.
        self.assertIs(self.good(read_only=lambda: True).report(1)["record_complete"], False)

    def test_a_failed_record_is_not_complete(self):
        journals = TableJournals(self.dir)
        journals.journal_for(1).record = lambda *a, **kw: False
        journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        self.assertIs(journals.report(1)["record_complete"], False)

    def test_read_only_is_asked_when_the_report_is_made_not_when_the_journals_are_built(self):
        state = {"ro": False}
        journals = TableJournals(self.dir, read_only=lambda: state["ro"])
        self.assertIs(journals.report(1)["record_complete"], True)
        state["ro"] = True
        self.assertIs(journals.report(1)["record_complete"], False)


# =============================================================================================
# R10-R12 through the route, on a real client and a recording stub.
# =============================================================================================


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheRouteRecordsTest(TempDirCase):
    def setUp(self):
        super().setUp()
        self.saved = (api_routes.topology, api_routes.note_api_table_entry_write,
                      api_routes.table_journals)
        self.addCleanup(self.restore)
        self.stub = RecordingStub()
        self.client = a_client(self.stub)
        api_routes.topology = FakeTopology({1: self.client})
        api_routes.note_api_table_entry_write = None
        self.journals = TableJournals(self.dir)
        api_routes.table_journals = self.journals

    def restore(self):
        (api_routes.topology, api_routes.note_api_table_entry_write,
         api_routes.table_journals) = self.saved

    def post(self, body=None, **overrides):
        payload = dict(AN_LPM_ENTRY if body is None else body)
        payload.update(overrides)
        return asyncio.run(api_routes.table_entry(a_request(payload)))

    def refused(self, body=None, **overrides):
        with self.assertRaises(HTTPException) as caught:
            self.post(body, **overrides)
        return caught.exception

    # --- R10 ----------------------------------------------------------------------

    def test_an_accepted_write_is_recorded_and_the_response_says_so_under_journal(self):
        body = self.post()
        self.assertEqual(body["status"], "success")
        # R10: this write reached the file, and startup and readopt replay the file.
        self.assertEqual(body["journal"], {"recorded": True, "enabled": True,
                                           "replay": rule_journal.REPLAYED_WHEN})
        self.assertIs(body["journaled"], True)
        self.assertNotIn("note", body, "a journaled entry has nothing to warn about")

    def test_the_file_gains_one_record_with_the_validated_spec(self):
        self.post()
        (record,) = self.records()
        self.assertEqual((record["op"], record["outcome"]), ("insert", "ok"))
        self.assertEqual(record["spec"]["table"], "MyIngress.ipv4_lpm")
        self.assertEqual(record["spec"]["match"], {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]})
        self.assertEqual(len(self.stub.requests), 1)

    def test_the_key_is_the_normalised_identity_not_the_way_the_request_spelled_it(self):
        # R10, the half M-J3 attacks. "10.0.1.1" and 167772417 are one entry; a delete in one
        # spelling must fold away an insert in the other, which only works if both are keyed by
        # the encoded value.
        self.post()
        self.post(op="delete", match={"hdr.ipv4.dstAddr": [167772417, 32]})
        first, second = self.records()
        self.assertEqual(first["key"], second["key"])
        self.assertEqual([r["op"] for r in self.records()], ["insert", "delete"])
        self.assertEqual(self.journals.journal_for(1).fold(), [],
                         "an insert and a delete of one entry in two spellings net to nothing")

    def test_two_different_entries_have_two_keys(self):
        self.post()
        self.post(match={"hdr.ipv4.dstAddr": ["10.0.2.2", 32]})
        first, second = self.records()
        self.assertNotEqual(first["key"], second["key"])

    def test_a_prefix_length_is_part_of_the_identity(self):
        self.post()
        self.post(match={"hdr.ipv4.dstAddr": ["10.0.1.0", 24]})
        first, second = self.records()
        self.assertNotEqual(first["key"], second["key"])

    def test_a_ternary_entry_is_recorded_under_its_priority(self):
        body = {"dpid": 1, "table": "Synthetic.t_ternary", "priority": 10,
                "match": {"hdr.ipv4.srcAddr": ["10.0.1.1", "255.255.255.255"]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
        self.post(body)
        self.post(body, priority=11)
        first, second = self.records()
        self.assertNotEqual(first["key"], second["key"],
                            "the same match at another priority is another entry")

    def test_a_range_entry_is_recorded_under_its_priority_and_its_bounds(self):
        body = {"dpid": 1, "table": "Synthetic.t_range", "priority": 10,
                "match": {"hdr.ipv4.srcAddr": ["10.0.1.1", "10.0.1.9"]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
        self.post(body)
        self.post(body, priority=11)
        self.post(body, match={"hdr.ipv4.srcAddr": ["10.0.1.1", "10.0.1.8"]})
        keys = [r["key"] for r in self.records()]
        self.assertEqual(len(set(keys)), 3)

    def test_an_optional_entry_is_recorded_under_its_priority_and_its_value(self):
        body = {"dpid": 1, "table": "Synthetic.t_optional", "priority": 10,
                "match": {"hdr.ipv4.srcAddr": "10.0.1.1"},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
        self.post(body)
        self.post(body, priority=11)
        self.post(body, match={"hdr.ipv4.srcAddr": "10.0.1.2"})
        self.post(body, op="delete", match={"hdr.ipv4.srcAddr": 167772417})
        keys = [r["key"] for r in self.records()]
        self.assertEqual(len(set(keys[:3])), 3)
        self.assertEqual(keys[3], keys[0], "the same optional value in another spelling")

    def test_a_ternary_delete_at_another_priority_is_a_not_found_record_under_that_priority(self):
        body = {"dpid": 1, "table": "Synthetic.t_ternary", "priority": 10,
                "match": {"hdr.ipv4.srcAddr": ["10.0.1.1", "255.255.255.255"]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
        self.post(body)
        self.stub.write_error = FakeRpcError(grpc.StatusCode.UNKNOWN,
                                             per_update_trailer(code_pb2.NOT_FOUND, "gone"))
        error = self.refused(body, op="delete", priority=20)
        self.assertEqual(error.status_code, 502)
        self.assertEqual(error.detail["p4rt_error"]["code"], "NOT_FOUND")
        inserted, missed = self.records()
        self.assertEqual((missed["op"], missed["outcome"]), ("delete", "not_found"))
        self.assertNotEqual(inserted["key"], missed["key"])
        self.stub.write_error = None
        self.post(body, priority=20)
        net = self.journals.journal_for(1).fold()
        self.assertEqual([n["op"] for n in net], ["insert", "insert"],
                         "priority 20 began unknown, so its insert is an insert")

    def test_a_default_entry_and_a_catch_all_of_the_same_table_are_two_entries(self):
        # Without a key of its own the default (no match, priority 0) and an LPM
        # entry with every field omitted share `(dpid, table, 0, ())`, and deleting the catch-all
        # would fold away the default's modify.
        action = {"action_name": "MyIngress.ipv4_forward",
                  "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
        self.post({"dpid": 1, "table": "MyIngress.ipv4_lpm", "match": {},
                   "default_action": True, **action})
        self.post({"dpid": 1, "table": "MyIngress.ipv4_lpm", "match": {}, **action})
        default, catch_all = self.records()
        self.assertNotEqual(default["key"], catch_all["key"])
        self.assertEqual(default["op"], "modify", "a default insert goes out as a modify")

    def test_the_count_a_response_gives_and_the_report_gives_agree(self):
        self.post()
        self.post(match={"hdr.ipv4.dstAddr": ["10.0.2.2", 32]})
        self.assertEqual(self.journals.report(1)["recorded"], 2)

    # --- R11 ----------------------------------------------------------------------

    def test_a_switch_refusal_is_a_502_and_leaves_no_record(self):
        self.stub.write_error = FakeRpcError(grpc.StatusCode.UNKNOWN,
                                             per_update_trailer(code_pb2.INVALID_ARGUMENT, "no"))
        self.assertEqual(self.refused().status_code, 502)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "s1.jsonl")))
        self.assertEqual(self.journals.report(1)["recorded"], 0)

    def test_every_refusal_made_before_the_wire_leaves_no_record(self):
        for kwargs, status in ((dict(table="nope"), 404),
                               (dict(match={"hdr.ipv4.dstAddr": ["10.0.1.1", 99]}), 400),
                               (dict(op="frobnicate"), 400),
                               (dict(dpid=9), 404)):
            self.assertEqual(self.refused(**kwargs).status_code, status)
        self.assertEqual(self.stub.requests, [])
        self.assertEqual(os.listdir(self.dir), [])

    def test_a_write_into_a_table_ndtwin_owns_is_a_409_and_leaves_no_record(self):
        # [Co-developed with claude code -- Adam] A table NDTwin owns is refused by
        # the owner check (409 owned_by_ndtwin) before the entry is built, so the journal never
        # sees it -- not even the delete the switch would have answered NOT_FOUND, which is the
        # one refusal the journal does record when it comes from the switch.
        owned_by_ndtwin(self.client)
        self.stub.write_error = FakeRpcError(grpc.StatusCode.UNKNOWN,
                                             per_update_trailer(code_pb2.NOT_FOUND, "gone"))
        for op in ("insert", "delete"):
            with self.subTest(op=op):
                error = self.refused(op=op)
                self.assertEqual(error.status_code, 409)
                self.assertEqual(error.detail["outcome"], "owned_by_ndtwin")
        # The journal first: it is this test's subject, and the wire is the owner gate's.
        self.assertEqual(os.listdir(self.dir), [])
        report = self.journals.report(1)
        self.assertEqual((report["recorded"], report["not_found"], report["failures"]),
                         (0, 0, 0))
        self.assertEqual(self.stub.requests, [])

    def test_a_delete_that_the_switch_answers_NOT_FOUND_is_a_502_with_a_not_found_record(self):
        self.stub.write_error = FakeRpcError(grpc.StatusCode.UNKNOWN,
                                             per_update_trailer(code_pb2.NOT_FOUND, "gone"))
        error = self.refused(op="delete")
        self.assertEqual(error.status_code, 502)
        self.assertEqual(error.detail["p4rt_error"]["code"], "NOT_FOUND")
        (record,) = self.records()
        self.assertEqual((record["op"], record["outcome"]), ("delete", "not_found"))

    def test_an_upper_case_delete_the_switch_answers_NOT_FOUND_is_recorded_too(self):
        # The writer reads "DELETE" and " Delete" as deletes (it lower-cases and strips), so the
        # journal must too: the route normalises the op once and passes the same word to both.
        self.stub.write_error = FakeRpcError(grpc.StatusCode.UNKNOWN,
                                             per_update_trailer(code_pb2.NOT_FOUND, "gone"))
        self.assertEqual(self.refused(op=" DELETE").status_code, 502)
        (record,) = self.records()
        self.assertEqual((record["op"], record["outcome"]), ("delete", "not_found"))

    def test_an_upper_case_insert_is_recorded_under_the_normalised_op(self):
        self.post(op="INSERT")
        (record,) = self.records()
        self.assertEqual(record["op"], "insert")

    def test_a_modify_the_switch_answers_NOT_FOUND_is_not_recorded(self):
        self.stub.write_error = FakeRpcError(grpc.StatusCode.UNKNOWN,
                                             per_update_trailer(code_pb2.NOT_FOUND, "gone"))
        self.assertEqual(self.refused(op="modify").status_code, 502)
        self.assertEqual(os.listdir(self.dir), [])

    def test_a_top_level_not_found_with_no_per_update_reason_is_not_recorded(self):
        # Only the per-update reason (E1's p4rt_error) says NOT_FOUND here; bmv2 answers
        # every refused Write UNKNOWN at the top. A top-level NOT_FOUND with no per-update detail is
        # not taken as "the entry was absent": the record says only what the switch said per update.
        self.stub.write_error = FakeRpcError(grpc.StatusCode.NOT_FOUND)
        self.assertEqual(self.refused(op="delete").status_code, 502)
        self.assertEqual(os.listdir(self.dir), [])

    def test_a_delete_refused_for_another_reason_is_not_recorded(self):
        self.stub.write_error = FakeRpcError(grpc.StatusCode.UNKNOWN,
                                             per_update_trailer(code_pb2.INVALID_ARGUMENT, "bad"))
        self.assertEqual(self.refused(op="delete").status_code, 502)
        self.assertEqual(os.listdir(self.dir), [])

    def test_an_external_control_plane_is_409_and_leaves_no_record(self):
        # `arbitration` False is how a client says "this fabric's controller is somebody else's".
        self.client.arbitration = False
        self.assertEqual(self.refused().status_code, 409)
        self.assertEqual(self.stub.requests, [])
        self.assertEqual(os.listdir(self.dir), [])

    def test_a_switch_that_left_between_the_check_and_the_lock_is_a_404(self):
        class Vanishing(dict):
            """A switch table that has it for the route's own check and not afterwards."""
            def __init__(self, client):
                super().__init__({1: client})
                self.calls = 0

            def get(self, key, default=None):
                self.calls += 1
                return self[key] if self.calls == 1 else None
        api_routes.topology = FakeTopology(Vanishing(self.client))
        error = self.refused()
        self.assertEqual(error.status_code, 404)
        self.assertEqual(self.stub.requests, [])

    # --- R12 ----------------------------------------------------------------------

    def test_a_journal_that_cannot_be_written_is_still_a_200_that_says_so(self):
        blocker = os.path.join(self.dir, "blocker")
        with open(blocker, "w") as fh:
            fh.write("x")
        api_routes.table_journals = TableJournals(os.path.join(blocker, "j"))
        body = self.post()
        self.assertEqual(body["status"], "success")
        self.assertEqual(len(self.stub.requests), 1, "the write IS on the switch")
        self.assertEqual(body["journal"]["recorded"], False)
        self.assertIs(body["journaled"], False)
        self.assertIn("the journal did not record it", body["note"])
        self.assertEqual(api_routes.table_journals.report(1)["failures"], 1)

    def test_the_note_for_an_unrecorded_write_says_what_each_op_turns_into(self):
        # "Lost when the proxy restarts" is true of an insert only: the journal
        # puts back what it last knew, so a modify reverts and a deleted entry returns, and the
        # replay cannot flag it.
        note = api_routes.TABLE_ENTRY_JOURNAL_WRITE_FAILED
        for words in ("an insert does not come back", "a modified entry reverts",
                      "a deleted entry returns", "will not flag it"):
            self.assertIn(words, note)
        self.assertNotIn("lost when the proxy restarts", note)

    def test_a_proxy_with_no_journal_at_all_still_writes_and_says_the_journal_is_off(self):
        api_routes.table_journals = None
        body = self.post()
        self.assertEqual(len(self.stub.requests), 1)
        self.assertEqual(body["journal"], {"recorded": False, "enabled": False,
                                           "replay": rule_journal.REPLAYED_WHEN})
        self.assertIs(body["journaled"], False)
        self.assertEqual(body["note"], api_routes.TABLE_ENTRY_JOURNAL_OFF)

    def test_the_note_for_a_journal_that_is_off_says_what_each_op_turns_into(self):
        # An insert is gone, a modified or deleted package entry is back.
        note = api_routes.TABLE_ENTRY_JOURNAL_OFF
        for words in ("journal is off", "an inserted entry is gone",
                      "modified or deleted is back as the package declares it"):
            self.assertIn(words, note)

    def test_a_journal_that_is_switched_off_says_so_and_is_not_called_a_failure(self):
        api_routes.table_journals = TableJournals(self.dir, enabled=False)
        body = self.post()
        self.assertEqual(body["journal"]["enabled"], False)
        self.assertEqual(body["journal"]["recorded"], False)
        self.assertEqual(body["note"], api_routes.TABLE_ENTRY_JOURNAL_OFF)
        self.assertEqual(os.listdir(self.dir), [])


# =============================================================================================
# R12b / 5.6 at the other surface: what switch_state says.
# =============================================================================================


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class SwitchStateSaysWhatIsTrueTest(TempDirCase):
    def setUp(self):
        super().setUp()
        self.saved_routes = (api_routes.topology, api_routes.table_entries_report,
                             api_routes.note_api_table_entry_write, api_routes.pipelines_report,
                             api_routes.table_journals)
        self.saved_main = main.table_journals
        self.addCleanup(self.restore)
        self.journals = TableJournals(self.dir)
        main.table_journals = self.journals
        api_routes.table_journals = self.journals
        api_routes.topology = FakeTopology({1: a_client(), 2: a_client(device_id=2)})
        api_routes.pipelines_report = None
        api_routes.table_entries_report = main.table_entries_report

    def restore(self):
        main.table_journals = self.saved_main
        (api_routes.topology, api_routes.table_entries_report,
         api_routes.note_api_table_entry_write, api_routes.pipelines_report,
         api_routes.table_journals) = self.saved_routes

    def state(self):
        return asyncio.run(api_routes.switch_state())["switches"]

    def write(self, dpid=1):
        self.journals.write_and_journal(lambda: AFakeSwitch(), dpid, {"table": "t"}, "insert")

    def test_a_recorded_write_shows_under_journal_and_the_switch_is_journaled(self):
        # T8 reads `journaled is True`: every accepted write of this boot is in the journal the
        # next startup or readopt replays.
        self.write()
        entry = self.state()["1"]["table_entries"]
        self.assertIs(entry["journaled"], True)
        self.assertEqual(entry["journal"]["recorded"], 1)
        self.assertEqual(entry["journal"]["failures"], 0)
        self.assertIs(entry["journal"]["record_complete"], True)
        self.assertIsNone(entry["journal"]["replay"], "no replay has run in this test")

    def test_a_switch_nobody_wrote_to_still_answers_with_a_journal_block(self):
        entry = self.state()["2"]["table_entries"]
        self.assertIs(entry["journaled"], True)
        self.assertEqual(entry["journal"]["recorded"], 0)
        self.assertIsNone(entry["journal"]["replay"])

    def test_a_switch_the_report_does_not_list_gets_its_journaled_through_the_constant(self):
        # The fallback in switch_state is a second place `journaled` is written. It must follow
        # rule_journal.TABLE_JOURNAL_REPLAYS like the first. Dpid 77: no other test gives it a
        # counts entry, so it is always the fallback.
        api_routes.topology = FakeTopology({77: a_client(device_id=77)})
        entry = self.state()["77"]["table_entries"]
        self.assertIs(entry["journal"]["record_complete"], True)
        self.assertIs(entry["journaled"], True)
        original = rule_journal.TABLE_JOURNAL_REPLAYS
        self.addCleanup(setattr, rule_journal, "TABLE_JOURNAL_REPLAYS", original)
        rule_journal.TABLE_JOURNAL_REPLAYS = False
        self.assertIs(self.state()["77"]["table_entries"]["journaled"], False)

    def test_the_fallback_still_says_false_when_there_are_no_journals_at_all(self):
        original = rule_journal.TABLE_JOURNAL_REPLAYS
        self.addCleanup(setattr, rule_journal, "TABLE_JOURNAL_REPLAYS", original)
        rule_journal.TABLE_JOURNAL_REPLAYS = True
        api_routes.table_journals = None
        api_routes.topology = FakeTopology({77: a_client(device_id=77)})
        self.assertIs(self.state()["77"]["table_entries"]["journaled"], False)

    def test_the_report_in_main_carries_the_same_two_fields(self):
        self.write(3)
        entry = main.table_entries_report()["3"]
        self.assertIs(entry["journaled"], True)
        self.assertEqual(entry["journal"]["recorded"], 1)

    def test_a_failed_record_shows_on_the_switch_that_had_it(self):
        self.journals.journal_for(1).record = lambda *a, **kw: False
        self.write(1)
        self.write(2)
        states = self.state()
        self.assertEqual(states["1"]["table_entries"]["journal"]["failures"], 1)
        self.assertIs(states["1"]["table_entries"]["journal"]["record_complete"], False)
        self.assertIs(states["1"]["table_entries"]["journaled"], False,
                      "a switch whose journal missed a record is not journaled")
        self.assertIs(states["2"]["table_entries"]["journal"]["record_complete"], True)
        self.assertIs(states["2"]["table_entries"]["journaled"], True)


class TheClaimFlipsInOnePlace(TempDirCase):
    """
    `rule_journal.TABLE_JOURNAL_REPLAYS` is the one line that decides whether this proxy claims an
    entry survives a restart. It is True since startup and readopt replay the journal
    (tests/test_table_entry_replay.py); patched back to False, every claim goes with it -- the
    POST's `journaled`, `switch_state.table_entries.journaled`, the T8 cell -- and with it True,
    everything else (a failed record, an off journal, an external plane) still withholds it.
    """

    def setUp(self):
        super().setUp()
        self.original = rule_journal.TABLE_JOURNAL_REPLAYS
        self.addCleanup(setattr, rule_journal, "TABLE_JOURNAL_REPLAYS", self.original)

    def test_the_constant_is_true_now_that_startup_and_readopt_replay(self):
        self.assertIs(self.original, True,
                      "the replay exists (main.replay_table_journal at startup and readopt); a "
                      "False here withdraws every `journaled` this proxy says")

    def test_with_replay_a_recorded_write_is_journaled_and_without_it_is_not(self):
        self.assertIs(rule_journal.journaled_claim(True), True)
        rule_journal.TABLE_JOURNAL_REPLAYS = False
        self.assertIs(rule_journal.journaled_claim(True), False)

    def test_a_write_that_was_not_recorded_is_never_journaled_whatever_replays(self):
        rule_journal.TABLE_JOURNAL_REPLAYS = True
        self.assertIs(rule_journal.journaled_claim(False), False)

    def test_the_switch_claim_needs_replay_and_all_three_conditions(self):
        journals = TableJournals(self.dir)
        journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        self.assertIs(journals.journaled(1), True)
        rule_journal.TABLE_JOURNAL_REPLAYS = False
        self.assertIs(journals.journaled(1), False)
        # No placeholder string: the block holds the last replay's report.
        self.assertNotEqual(journals.report(1)["replay"], "not implemented")
        self.assertIsNone(journals.report(1)["replay"])

    def test_with_replay_each_condition_still_withholds_the_claim(self):
        rule_journal.TABLE_JOURNAL_REPLAYS = True
        off = TableJournals(self.dir, enabled=False)
        self.assertIs(off.journaled(1), False)
        external = TableJournals(self.dir, read_only=lambda: True)
        self.assertIs(external.journaled(1), False)
        failing = TableJournals(self.dir)
        failing.journal_for(1).record = lambda *a, **kw: False
        failing.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        self.assertIs(failing.journaled(1), False)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheResponseFlipsToo(TempDirCase):
    def setUp(self):
        super().setUp()
        self.saved = (api_routes.topology, api_routes.note_api_table_entry_write,
                      api_routes.table_journals)
        self.original = rule_journal.TABLE_JOURNAL_REPLAYS
        self.addCleanup(self.restore)
        api_routes.topology = FakeTopology({1: a_client()})
        api_routes.note_api_table_entry_write = None
        api_routes.table_journals = TableJournals(self.dir)

    def restore(self):
        rule_journal.TABLE_JOURNAL_REPLAYS = self.original
        (api_routes.topology, api_routes.note_api_table_entry_write,
         api_routes.table_journals) = self.saved

    def post(self):
        return asyncio.run(api_routes.table_entry(a_request(dict(AN_LPM_ENTRY))))

    def test_with_replay_the_response_is_journaled_and_carries_no_note(self):
        body = self.post()
        self.assertIs(body["journaled"], True)
        self.assertNotIn("note", body)
        self.assertEqual(body["journal"]["recorded"], True)

    def test_without_replay_the_same_post_is_not_journaled_and_says_why(self):
        rule_journal.TABLE_JOURNAL_REPLAYS = False
        body = self.post()
        self.assertIs(body["journaled"], False)
        self.assertIn("note", body)


# =============================================================================================
# The lock is bounded: a write behind a hung switch gives up instead of waiting for ever.
# =============================================================================================


class ABlockingSwitch(AFakeSwitch):
    """A switch whose write does not return until `release` is set; `entered` says it started."""

    def __init__(self):
        super().__init__()
        self.entered = threading.Event()
        self.release = threading.Event()

    def write_table_entry(self, spec, op):
        self.calls.append((op, spec))
        self.entered.set()
        self.release.wait(5)
        return {"op": op, "entry_key": self.key}


class TheLockIsBoundedTest(TempDirCase):
    def test_a_write_behind_a_write_that_does_not_return_is_SwitchBusy_and_writes_nothing(self):
        journals = TableJournals(self.dir)
        slow = ABlockingSwitch()
        first = threading.Thread(target=lambda: journals.write_and_journal(
            lambda: slow, 1, {"table": "a"}, "insert"), daemon=True)
        first.start()
        self.addCleanup(first.join, 5)
        self.addCleanup(slow.release.set)
        self.assertTrue(slow.entered.wait(2))
        second = AFakeSwitch()
        outcome = []

        def go():
            try:
                journals.write_and_journal(lambda: second, 1, {"table": "b"}, "insert",
                                           lock_timeout=0.2)
            except Exception as exc:  # noqa: BLE001
                outcome.append(exc)
        waiter = threading.Thread(target=go, daemon=True)
        waiter.start()
        waiter.join(3)
        self.assertFalse(waiter.is_alive(), "the second write is still waiting: no timeout")
        self.assertEqual([type(e) for e in outcome], [rule_journal.SwitchBusy])
        self.assertEqual(second.calls, [], "a write that gave up must not have touched the switch")

    def test_a_write_that_is_not_blocked_ignores_the_timeout(self):
        journals = TableJournals(self.dir)
        written, recorded = journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "a"},
                                                       "insert", lock_timeout=0.2)
        self.assertTrue(recorded)

    def test_the_lock_is_free_again_after_a_write_that_raised(self):
        journals = TableJournals(self.dir)
        with self.assertRaises(RuntimeError):
            journals.write_and_journal(lambda: AFakeSwitch(error=RuntimeError("x")), 1,
                                       {"table": "a"}, "insert", lock_timeout=0.2)
        self.assertFalse(journals.journal_for(1).lock.locked())

    def test_the_lock_is_free_again_after_a_write_that_gave_up_waiting(self):
        journals = TableJournals(self.dir)
        journal = journals.journal_for(1)
        journal.lock.acquire()
        self.addCleanup(lambda: journal.lock.locked() and journal.lock.release())
        outcome = []

        def go():
            try:
                journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "a"}, "insert",
                                           lock_timeout=0.05)
            except Exception as exc:  # noqa: BLE001
                outcome.append(exc)
        # In a thread, so that code with no timeout fails this test instead of hanging it.
        waiter = threading.Thread(target=go, daemon=True)
        waiter.start()
        waiter.join(3)
        self.assertFalse(waiter.is_alive(), "the write is still waiting: no timeout")
        self.assertEqual([type(e) for e in outcome], [rule_journal.SwitchBusy])
        journal.lock.release()
        written, recorded = journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "a"},
                                                       "insert", lock_timeout=0.05)
        self.assertTrue(recorded)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class The503ComesBeforeAnyRefusalTest(TempDirCase):
    """
    The owner check -- like every refusal the writer makes -- runs INSIDE the
    switch's lock, because the binding it reads belongs to the client looked up there (a readopt
    may swap both). So a write queued behind a held lock, or addressed to a switch being
    re-adopted, is a 503 before it is anything else: it never reaches the writer, the owner
    check included.
    """

    SPEC = {k: v for k, v in AN_LPM_ENTRY.items() if k != "dpid"}

    def owned_client(self):
        stub = RecordingStub()
        client = owned_by_ndtwin(a_client(stub))
        calls = []
        original = client.write_table_entry

        def spy(spec, op="insert", source=None):
            calls.append(op)
            return original(spec, op, source)
        client.write_table_entry = spy
        return client, stub, calls

    def in_thread(self, fn):
        outcome = []

        def go():
            try:
                outcome.append(fn())
            except Exception as exc:  # noqa: BLE001
                outcome.append(exc)
        thread = threading.Thread(target=go, daemon=True)
        thread.start()
        thread.join(3)
        self.assertFalse(thread.is_alive(), "the write is still waiting")
        return outcome

    def test_the_client_would_answer_409(self):
        client, stub, calls = self.owned_client()
        from proxy_agent.p4_client import TableOwnedByNDTwin
        with self.assertRaises(TableOwnedByNDTwin):
            TableJournals(self.dir).write_and_journal(lambda: client, 1, dict(self.SPEC),
                                                      "insert")
        self.assertEqual(stub.requests, [])

    def test_behind_a_held_lock_it_is_switch_busy_and_the_owner_check_never_ran(self):
        journals = TableJournals(self.dir)
        client, stub, calls = self.owned_client()
        journal = journals.journal_for(1)
        journal.lock.acquire()
        self.addCleanup(lambda: journal.lock.locked() and journal.lock.release())
        outcome = self.in_thread(lambda: journals.write_and_journal(
            lambda: client, 1, dict(self.SPEC), "insert", lock_timeout=0.05))
        self.assertEqual([type(e) for e in outcome], [rule_journal.SwitchBusy])
        self.assertEqual(calls, [], "the writer was never asked, so neither was its owner check")

    def test_on_a_switch_being_readopted_it_is_replay_pending_at_once(self):
        journals = TableJournals(self.dir)
        client, stub, calls = self.owned_client()
        with journals.replaying(1):
            outcome = self.in_thread(lambda: journals.write_and_journal(
                lambda: client, 1, dict(self.SPEC), "insert"))   # no timeout: must not wait
        self.assertEqual([type(e) for e in outcome], [rule_journal.ReplayPending])
        self.assertEqual(calls, [])
        self.assertFalse(journals.pending(1))
        self.assertEqual(os.listdir(self.dir), [])

    def test_two_overlapping_readopts_keep_the_switch_pending_until_the_second_ends(self):
        # A count, not a set. The first readopt's end must not clear the flag the
        # second one still holds, or a POST meanwhile queues for "switch busy".
        journals = TableJournals(self.dir)
        first_in = threading.Event()
        first_go = threading.Event()
        second_in = threading.Event()
        second_go = threading.Event()

        def first():
            with journals.replaying(1):
                first_in.set()
                first_go.wait(3)

        def second():
            with journals.replaying(1):
                second_in.set()
                second_go.wait(3)
        a = threading.Thread(target=first, daemon=True)
        a.start()
        self.assertTrue(first_in.wait(2))
        b = threading.Thread(target=second, daemon=True)
        b.start()                               # pending twice; waits for the lock
        # Wait until the second readopt is counted, not for a fixed time. [Co-developed with
        # claude code -- Adam]
        give_up = time.monotonic() + 3
        while True:
            with journals._registry_lock:
                if journals._pending.get("1") == 2:
                    break
            if time.monotonic() > give_up:
                self.fail("the second readopt never registered as pending")
            time.sleep(0.005)
        first_go.set()
        a.join(3)
        self.assertTrue(second_in.wait(2))
        self.addCleanup(second_go.set)
        self.assertTrue(journals.pending(1), "the second readopt is still under way")
        outcome = self.in_thread(lambda: journals.write_and_journal(
            lambda: AFakeSwitch(), 1, {"table": "a"}, "insert", lock_timeout=0.05))
        self.assertEqual([type(e) for e in outcome], [rule_journal.ReplayPending])
        second_go.set()
        b.join(3)
        self.assertFalse(journals.pending(1))

    def test_a_write_that_got_past_the_first_check_meets_the_second_inside_the_lock(self):
        journals = TableJournals(self.dir)
        slow = ABlockingSwitch()
        first = threading.Thread(target=lambda: journals.write_and_journal(
            lambda: slow, 1, {"table": "a"}, "insert"), daemon=True)
        first.start()
        self.addCleanup(first.join, 5)
        self.addCleanup(slow.release.set)
        self.assertTrue(slow.entered.wait(2))
        second = AFakeSwitch()
        outcome = []

        def go():
            try:
                outcome.append(journals.write_and_journal(lambda: second, 1, {"table": "b"},
                                                          "insert", lock_timeout=3))
            except Exception as exc:  # noqa: BLE001
                outcome.append(exc)
        waiter = threading.Thread(target=go, daemon=True)
        waiter.start()
        time.sleep(0.1)                         # it is now waiting for the lock
        with journals._registry_lock:
            journals._pending["1"] = 1          # a readopt began meanwhile
        self.addCleanup(journals._pending.pop, "1", None)
        slow.release.set()
        waiter.join(3)
        self.assertEqual([type(e) for e in outcome], [rule_journal.ReplayPending])
        self.assertEqual(second.calls, [])


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheRouteAnswers503WhenTheSwitchIsBusyTest(TempDirCase):
    def setUp(self):
        super().setUp()
        # getattr: the wait is a module constant the route reads; a tree without it must fail
        # these tests on the behaviour (the second POST never gives up), not on the lookup.
        self.saved = (api_routes.topology, api_routes.note_api_table_entry_write,
                      api_routes.table_journals,
                      getattr(api_routes, "TABLE_ENTRY_LOCK_TIMEOUT_S", None))
        self.addCleanup(self.restore)
        self.release = threading.Event()
        self.entered = threading.Event()
        outer = self

        class BlockingStub(RecordingStub):
            def Write(self, request, timeout=None):
                self.requests.append(request)
                outer.entered.set()
                outer.release.wait(5)
        self.stub = BlockingStub()
        api_routes.topology = FakeTopology({1: a_client(self.stub)})
        api_routes.note_api_table_entry_write = None
        api_routes.table_journals = TableJournals(self.dir)
        api_routes.TABLE_ENTRY_LOCK_TIMEOUT_S = 0.2

    def restore(self):
        self.release.set()
        (api_routes.topology, api_routes.note_api_table_entry_write,
         api_routes.table_journals, api_routes.TABLE_ENTRY_LOCK_TIMEOUT_S) = self.saved

    def post(self, **overrides):
        payload = dict(AN_LPM_ENTRY)
        payload.update(overrides)
        return asyncio.run(api_routes.table_entry(a_request(payload)))

    def test_the_second_post_to_a_switch_that_does_not_answer_is_503_and_writes_nothing(self):
        first = []
        thread = threading.Thread(target=lambda: first.append(self.post()), daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.assertTrue(self.entered.wait(2))
        result = []

        def second():
            try:
                self.post(match={"hdr.ipv4.dstAddr": ["10.0.2.2", 32]})
            except HTTPException as err:
                result.append(err)
        waiter = threading.Thread(target=second, daemon=True)
        waiter.start()
        waiter.join(3)
        self.assertFalse(waiter.is_alive(), "the second POST is still waiting: no timeout")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].status_code, 503)
        self.assertEqual(result[0].detail["error"], "switch busy")
        self.assertIn("nothing was written", result[0].detail["message"])
        self.assertEqual(len(self.stub.requests), 1, "only the first write reached the wire")
        self.release.set()
        thread.join(5)
        self.assertEqual(first[0]["status"], "success")
        self.assertEqual(len(self.records()), 1, "and only the first was recorded")

    def test_the_wait_is_bounded_by_one_grpc_deadline(self):
        from proxy_agent import p4_client
        self.assertEqual(self.saved[3], p4_client.RPC_TIMEOUT_S)

    def test_a_switch_being_readopted_is_503_replay_pending_and_writes_nothing(self):
        with api_routes.table_journals.replaying(1):
            result = []

            def go():
                try:
                    self.post()
                except HTTPException as err:
                    result.append(err)
            waiter = threading.Thread(target=go, daemon=True)
            waiter.start()
            waiter.join(3)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].status_code, 503)
        self.assertEqual(result[0].detail["error"], "replay pending")
        self.assertIn("nothing was written", result[0].detail["message"])
        self.assertEqual(self.stub.requests, [])


# =============================================================================================
# The identity of a default entry.
# =============================================================================================


class TheDefaultEntryHasItsOwnKeyTest(unittest.TestCase):
    def test_the_default_and_a_catch_all_are_two_keys(self):
        catch_all = entry_key(1, "MyIngress.ipv4_lpm", 0, {})
        default = entry_key(1, "MyIngress.ipv4_lpm", 0, {}, default=True)
        self.assertNotEqual(catch_all, default)

    def test_a_default_has_one_key_whatever_priority_or_match_it_was_built_with(self):
        self.assertEqual(entry_key(1, "t", 0, {}, default=True),
                         entry_key("1", "t", 5, {"f": {"type": "exact", "value": 1}},
                                   default=True))

    def test_the_default_of_one_table_is_not_the_default_of_another(self):
        self.assertNotEqual(entry_key(1, "a", 0, {}, default=True),
                            entry_key(1, "b", 0, {}, default=True))

    def test_a_non_default_entry_keeps_the_key_it_always_had(self):
        self.assertEqual(entry_key(1, "t", 3, {}), ("1", "t", 3, ()))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheWriterKeepsTheTwoApartTest(unittest.TestCase):
    ACTION = {"action_name": "MyIngress.ipv4_forward",
              "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}

    def test_deleting_a_catch_all_does_not_forget_the_defaults_install_time(self):
        client = a_client()
        table = "MyIngress.ipv4_lpm"
        client.write_table_entry({"table": table, "match": {}, "default_action": True,
                                  **self.ACTION}, "insert")
        client.write_table_entry({"table": table, "match": {}, **self.ACTION}, "insert")
        self.assertIsNotNone(client.rule_install_times.age_seconds(1, table, 0, {}, True))
        client.write_table_entry({"table": table, "match": {}}, "delete")
        self.assertIsNone(client.rule_install_times.age_seconds(1, table, 0, {}, False),
                          "the catch-all is gone")
        self.assertIsNotNone(client.rule_install_times.age_seconds(1, table, 0, {}, True),
                             "and the default is not")

    def test_deleting_the_default_does_not_forget_a_catch_alls_install_time(self):
        client = a_client()
        table = "MyIngress.ipv4_lpm"
        client.write_table_entry({"table": table, "match": {}, "default_action": True,
                                  **self.ACTION}, "insert")
        client.write_table_entry({"table": table, "match": {}, **self.ACTION}, "insert")
        client.write_table_entry({"table": table, "match": {}, "default_action": True},
                                 "delete")
        self.assertIsNone(client.rule_install_times.age_seconds(1, table, 0, {}, True))
        self.assertIsNotNone(client.rule_install_times.age_seconds(1, table, 0, {}, False))

    def test_what_the_writer_returns_is_the_key_the_install_times_use(self):
        client = a_client()
        written = client.write_table_entry(dict(AN_LPM_ENTRY, dpid=None), "insert")
        self.assertEqual(written["entry_key"][:3], ("1", "MyIngress.ipv4_lpm", 0))

    def test_a_spec_that_does_not_build_has_no_key_and_raises_nothing(self):
        self.assertIsNone(a_client().table_entry_key({"table": "no.such"}))

    def test_a_spec_that_builds_has_the_key_the_write_would_have_returned(self):
        client = a_client()
        spec = {k: v for k, v in AN_LPM_ENTRY.items() if k != "dpid"}
        self.assertEqual(client.table_entry_key(spec),
                         client.write_table_entry(spec, "insert")["entry_key"])

    def test_and_so_does_a_ternary_spec_with_its_priority(self):
        # The priority is part of the key on both paths.
        client = a_client()
        spec = {"table": "Synthetic.t_ternary", "priority": 10,
                "match": {"hdr.ipv4.srcAddr": ["10.0.1.1", "255.255.255.255"]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}}
        key = client.table_entry_key(spec)
        self.assertEqual(key, client.write_table_entry(spec, "insert")["entry_key"])
        self.assertEqual(key[2], 10)

    def test_and_so_does_a_default_entry_spec(self):
        client = a_client()
        spec = {"table": "MyIngress.ipv4_lpm", "match": {}, "default_action": True,
                **self.ACTION}
        self.assertEqual(client.table_entry_key(spec),
                         client.write_table_entry(spec, "insert")["entry_key"])
        self.assertEqual(client.table_entry_key(spec)[2], "default")


# =============================================================================================
# The wiring: what PRODUCTION built, not what a test builds by hand.
# =============================================================================================


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheJournalIsWiredInMainTest(unittest.TestCase):
    def test_main_handed_the_route_the_journals_it_built(self):
        self.assertIsNotNone(WIRED_AT_IMPORT, "main.py never injected the table-entry journals: "
                                              "every POST would run with the journal off")
        self.assertIs(WIRED_AT_IMPORT, main.table_journals)

    def test_the_headers_main_builds_are_written_with_this_boot_and_the_p4info_digest(self):
        # The header provider reaches a file through three links: main passes `header_for=`,
        # TableJournals wraps it per switch, TableEntryJournal calls it when it creates the file.
        # Every other test builds its journals without one, so each link could break and leave
        # every production header all-null (a live probe showed that shape).
        from proxy_agent import boot_identity
        directory = tempfile.mkdtemp(prefix="ndt-table-journal-")
        self.addCleanup(shutil.rmtree, directory, True)
        p4info = os.path.join(directory, "a.p4info.txt")
        entries = os.path.join(directory, "s1-runtime.json")
        for path, text in ((p4info, "p4info"), (entries, "entries")):
            with open(path, "w") as fh:
                fh.write(text)

        class Spec:
            dpid = 1

        class Package:
            read_only = False
            switches = [Spec()]

            def pipeline_for(self, dpid, base):
                return p4info, None
        Spec.entries = entries
        journals_dir = os.path.join(directory, "journals")
        saved = main.profile.current
        main.profile.current = lambda: Package()
        try:
            journals = main.build_table_journals({"NDTWIN_TABLE_JOURNAL_DIR": journals_dir})
            journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"}, "insert")
        finally:
            main.profile.current = saved
        header, records, _bad = journals.journal_for(1).read()
        self.assertEqual(header["boot_id"], boot_identity.BOOT_ID)
        self.assertEqual(header["p4info_sha256"], main._p4info_fingerprint(p4info))
        self.assertEqual(header["entries_sha256"], main._p4info_fingerprint(entries))
        self.assertIsNotNone(header["p4info_sha256"])
        self.assertEqual(len(records), 1)

    def test_the_default_directory_is_absolute_inside_this_checkout_and_stable(self):
        directory = main.build_table_journals({}).directory
        self.assertTrue(os.path.isabs(directory))
        self.assertTrue(directory.startswith(PROXY_DIR + os.sep), directory)
        self.assertTrue(directory.endswith(os.path.join(".run", "table_entry_journal")))
        self.assertEqual(directory, main.build_table_journals({}).directory)

    def test_the_directory_can_be_overridden_and_recording_can_be_switched_off(self):
        journals = main.build_table_journals({"NDTWIN_TABLE_JOURNAL_DIR": "/somewhere/else",
                                              "NDTWIN_TABLE_JOURNAL": "off"})
        self.assertEqual(journals.directory, "/somewhere/else")
        self.assertIs(journals.enabled, False)
        self.assertIs(main.build_table_journals({}).enabled, True)

    def test_only_off_switches_it_off(self):
        for value, expected in (("", True), ("on", True), ("1", True), ("garbage", True),
                                ("off", False), ("OFF", False), ("0", False), ("false", False)):
            self.assertIs(rule_journal.table_journal_enabled({"NDTWIN_TABLE_JOURNAL": value}),
                          expected, value)

    def test_a_file_is_named_for_its_switch(self):
        with tempfile.TemporaryDirectory(prefix="ndt-table-journal-") as directory:
            journals = TableJournals(directory)
            self.assertEqual(journals.journal_for(12).path, os.path.join(directory, "s12.jsonl"))

    def test_the_header_main_supplies_names_this_boot(self):
        from proxy_agent import boot_identity
        self.assertEqual(main.table_journal_header(1)["boot_id"], boot_identity.BOOT_ID)

    def test_the_journals_main_builds_ask_the_package_whether_the_fabric_is_external(self):
        class Package:
            read_only = True
        saved = main.profile.current
        main.profile.current = lambda: Package()
        try:
            journals = main.build_table_journals({})
            self.assertIs(journals.report(1)["record_complete"], False)
            Package.read_only = False
            self.assertIs(journals.report(1)["record_complete"], True)
        finally:
            main.profile.current = saved

    def test_the_header_digests_are_those_of_the_files_the_package_names(self):
        directory = tempfile.mkdtemp(prefix="ndt-table-journal-")
        self.addCleanup(shutil.rmtree, directory, True)
        p4info = os.path.join(directory, "a.p4info.txt")
        entries = os.path.join(directory, "s1-runtime.json")
        with open(p4info, "w") as fh:
            fh.write("p4info")
        with open(entries, "w") as fh:
            fh.write("entries")

        class Spec:
            dpid = 1

        class Package:
            read_only = False
            switches = [Spec()]

            def pipeline_for(self, dpid, base):
                return p4info, None
        Spec.entries = entries
        saved = main.profile.current
        main.profile.current = lambda: Package()
        try:
            header = main.table_journal_header(1)
            Spec.entries = None
            bare = main.table_journal_header(1)
        finally:
            main.profile.current = saved
        self.assertEqual(header["p4info_sha256"], main._p4info_fingerprint(p4info))
        self.assertEqual(header["entries_sha256"], main._p4info_fingerprint(entries))
        self.assertNotEqual(header["p4info_sha256"], header["entries_sha256"])
        self.assertIsNone(bare["entries_sha256"], "a switch with no entries file has no digest")

    def test_the_real_report_has_no_replay_before_one_has_run(self):
        with tempfile.TemporaryDirectory(prefix="ndt-table-journal-") as directory:
            saved = main.table_journals
            main.table_journals = TableJournals(directory)
            try:
                main.table_journals.write_and_journal(lambda: AFakeSwitch(), 1, {"table": "t"},
                                                      "insert")
                journal = main.table_entries_report()["1"]["journal"]
            finally:
                main.table_journals = saved
        self.assertIsNone(journal["replay"])
        self.assertEqual(journal["recorded"], 1)

    def test_the_headers_main_builds_name_this_boots_fabric_generation(self):
        saved = dict(main._generation)
        self.addCleanup(main._generation.update, saved)
        main._generation["cookie"] = 0xABCDEF
        self.assertEqual(main.table_journal_header(1)["fabric_cookie"], "0000000000abcdef")
        main._generation["cookie"] = None
        self.assertIsNone(main.table_journal_header(1)["fabric_cookie"])

    def test_the_constants_the_two_surfaces_disagree_on_are_split(self):
        # The multicast response keeps its own sentence, verbatim; a table entry's two
        # are their own. One sentence cannot be true of a thing that is recorded and replayed
        # and a thing that is recorded nowhere.
        notes = (api_routes.TABLE_ENTRY_NOT_JOURNALED, api_routes.TABLE_ENTRY_JOURNAL_WRITE_FAILED,
                 api_routes.TABLE_ENTRY_JOURNAL_OFF)
        self.assertEqual(len(set(notes)), 3)
        self.assertEqual(api_routes.TABLE_ENTRY_NOT_JOURNALED,
                         "not journaled: this entry is lost when the proxy restarts "
                         "(Adam 2026-09-18, option a)")
        self.assertFalse(hasattr(api_routes, "TABLE_ENTRY_RECORDED_NOT_REPLAYED"),
                         "a recorded entry is replayed: that sentence is no longer true")


class TheKeyDigestTest(unittest.TestCase):
    def test_equal_keys_have_equal_digests_and_different_keys_do_not(self):
        self.assertEqual(key_digest(("1", "t", 0, ())), key_digest(("1", "t", 0, ())))
        self.assertNotEqual(key_digest(("1", "t", 0, ())), key_digest(("1", "t", 1, ())))
        self.assertNotEqual(key_digest(("1", "t", "default")), key_digest(("1", "t", 0, ())))

    def test_the_digest_is_a_short_hex_string(self):
        digest = key_digest(("1", "t", 0, ()))
        self.assertEqual(len(digest), 32)
        int(digest, 16)


if __name__ == "__main__":
    unittest.main()
