"""
The write-ahead record of what was asked for, and what a replay of it is allowed to claim.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES A-4c, recovery half. `test_table_generation.py` covers the honesty half -- making
the wipe sayable. This file covers the other question: having detected it, is there anything to
put back?

Today there is nothing to put back anywhere in the system. The proxy's `_installed_routes`
(topology_manager.py) is a dict built in __init__ with no persistence, and it deliberately does
not record 5-tuple rules at all. The kernel has no intent store either: `FlowRoutingManager`
keeps no map of installed entries, `DispatchOutcomeLog` discards a successful job's actions
(so even its retained failures are unreplayable), and `m_cachedOpenFlowTables` is replaced
wholesale by the poll every ~10 s. So a journal on the proxy side is the only record that can
exist without new C++ state.

**The assertions here are mostly about what a replay may NOT say.** A replay that half
succeeds is worse than no replay at all: it leaves the fabric in a state matching neither the
journal nor what was there before, while a caller that read a boolean concludes the rules are
back. So `ReplayReport` has no success boolean. It has a four-valued `status`, and the two
tests that matter most are the ones asserting that a partial replay and an empty journal are
each distinguishable from a complete one -- including the case where the journal was empty,
which is "complete" in the arithmetic sense and must not be reportable as recovery.

Replay is opt-in for the same reason. A journal records *requests*, not the reasons behind
them: a Traffic-Engineering reroute installed because a link was congested is still in the
journal twenty minutes later when the congestion is gone, and replaying it programs a detour
nobody wants. That is a judgement call about a live fabric, so the default is off and the
decision is Adam's.

unittest rather than pytest -- tools/test_workflow/l1_unit_tests.sh parses "Ran N tests", and
p4_proxy/venv has no pytest.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent.rule_journal import ReplayReport, RuleJournal  # noqa: E402


class JournalTestCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ndt-journal-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.path = os.path.join(self.dir, "rules.jsonl")

    def a_journal(self):
        return RuleJournal(self.path)

    def an_install(self, dst="10.0.0.4", dpid=1, port=3):
        return {"op": "install", "dpid": dpid, "match": {"nw_dst": dst},
                "actions": [{"type": "OUTPUT", "port": port}], "priority": 100}


class RecordingTest(JournalTestCase):
    def test_a_recorded_rule_can_be_read_back(self):
        journal = self.a_journal()
        journal.record(**self.an_install())

        self.assertEqual(len(journal.entries()), 1)
        self.assertEqual(journal.entries()[0]["match"], {"nw_dst": "10.0.0.4"})
        self.assertEqual(journal.entries()[0]["actions"], [{"type": "OUTPUT", "port": 3}])

    def test_the_actions_survive(self):
        # The kernel's own DispatchOutcomeLog throws the actions away on success, which is why
        # its records cannot be replayed. A journal that did the same would be decoration.
        journal = self.a_journal()
        journal.record(**self.an_install(port=7))

        self.assertEqual(journal.entries()[0]["actions"][0]["port"], 7)

    def test_order_is_preserved_for_the_same_destination(self):
        # install -> delete -> install of the same destination is three different end states.
        # A journal that collapsed to a set would replay the wrong one.
        journal = self.a_journal()
        journal.record(**self.an_install(port=3))
        journal.record(op="delete", dpid=1, match={"nw_dst": "10.0.0.4"}, actions=[],
                       priority=100)
        journal.record(**self.an_install(port=9))

        self.assertEqual([e["op"] for e in journal.entries()],
                         ["install", "delete", "install"])
        self.assertEqual(journal.entries()[-1]["actions"][0]["port"], 9)

    def test_order_is_write_order_and_not_any_ordering_of_the_entries(self):
        # The test above cannot see a journal that sorts, because its three entries share a
        # match and a stable sort leaves them alone -- a mutation that returned
        # sorted(entries, key=match) passed it. These destinations are recorded in an order
        # no sort key would reproduce: descending by address, and the delete in the middle
        # sorts to neither end.
        journal = self.a_journal()
        journal.record(**self.an_install(dst="10.0.0.9"))
        journal.record(op="delete", dpid=1, match={"nw_dst": "10.0.0.1"}, actions=[])
        journal.record(**self.an_install(dst="10.0.0.5"))

        self.assertEqual([e["match"]["nw_dst"] for e in journal.entries()],
                         ["10.0.0.9", "10.0.0.1", "10.0.0.5"])

    def test_a_second_journal_object_sees_what_the_first_wrote(self):
        # The point of the file. A restart builds a new object over the same path.
        self.a_journal().record(**self.an_install())

        self.assertEqual(len(self.a_journal().entries()), 1)

    def test_a_torn_last_line_is_reported_rather_than_swallowed(self):
        # A process killed mid-append leaves a partial line. Skipping it is right -- one lost
        # rule must not make the whole journal unreadable -- but silently skipping it is how a
        # replay reports "complete" over a journal it could not fully read.
        journal = self.a_journal()
        journal.record(**self.an_install())
        with open(self.path, "a") as fh:
            fh.write('{"op": "install", "dpid": 1, "match"')

        self.assertEqual(len(journal.entries()), 1)
        self.assertEqual(journal.unreadable_lines(), 1)

    def test_a_journal_that_does_not_exist_yet_is_empty_not_an_error(self):
        # First boot. Raising here would make the proxy refuse to start over a missing file.
        self.assertEqual(self.a_journal().entries(), [])
        self.assertEqual(self.a_journal().unreadable_lines(), 0)


class ReplayReportTest(JournalTestCase):
    """What a replay is allowed to claim. Every assertion here is a thing it must NOT say."""

    def test_an_empty_journal_is_not_reported_as_recovery(self):
        # "0 of 0 succeeded" is arithmetically complete and means nothing was restored. A
        # caller that saw a success boolean here would log "rules recovered" after recovering
        # nothing -- and this is the normal case for a proxy whose journal was lost, which is
        # exactly when a human most needs to be told there is nothing to fall back on.
        report = self.a_journal().replay(lambda entry: True)

        self.assertEqual(report.status, "nothing-to-replay")
        self.assertEqual(report.attempted, 0)

    def test_a_fully_successful_replay_is_complete(self):
        journal = self.a_journal()
        journal.record(**self.an_install())
        journal.record(**self.an_install(dst="10.0.0.5"))

        report = journal.replay(lambda entry: True)

        self.assertEqual(report.status, "complete")
        self.assertEqual(report.attempted, 2)
        self.assertEqual(report.succeeded, 2)
        self.assertEqual(report.failed, [])

    def test_a_partial_replay_says_partial_and_names_what_is_missing(self):
        # The case the whole design turns on. Two rules asked for, one landed: the fabric now
        # matches neither the journal nor what was there before, and the only thing that makes
        # that recoverable by a human is knowing WHICH one is missing.
        journal = self.a_journal()
        journal.record(**self.an_install(dst="10.0.0.4"))
        journal.record(**self.an_install(dst="10.0.0.5"))

        report = journal.replay(lambda entry: entry["match"]["nw_dst"] != "10.0.0.5")

        self.assertEqual(report.status, "partial")
        self.assertEqual(report.succeeded, 1)
        self.assertEqual(len(report.failed), 1)
        self.assertEqual(report.failed[0]["entry"]["match"]["nw_dst"], "10.0.0.5")

    def test_a_replay_where_everything_failed_is_not_partial_either(self):
        # Distinguished from "partial" because it usually means something categorical -- the
        # switch is not accepting writes at all -- rather than N individual rejections, and it
        # is the case where continuing to serve traffic is least defensible.
        journal = self.a_journal()
        journal.record(**self.an_install())

        report = journal.replay(lambda entry: False)

        self.assertEqual(report.status, "failed")
        self.assertEqual(report.succeeded, 0)

    def test_an_applier_that_raises_is_a_failure_not_a_crash(self):
        # One switch refusing a write must not abandon the other nine, the same argument
        # main.startup's per-switch try/except already makes for the pipeline push.
        journal = self.a_journal()
        journal.record(**self.an_install(dst="10.0.0.4"))
        journal.record(**self.an_install(dst="10.0.0.5"))

        def applier(entry):
            if entry["match"]["nw_dst"] == "10.0.0.4":
                raise RuntimeError("switch refused")
            return True

        report = journal.replay(applier)

        self.assertEqual(report.status, "partial")
        self.assertEqual(report.succeeded, 1)
        self.assertIn("switch refused", report.failed[0]["reason"])

    def test_an_unreadable_line_keeps_a_replay_from_claiming_completeness(self):
        # Every entry it could read succeeded, so the arithmetic says complete -- but the
        # journal held a rule it could not read, so the fabric is missing something and nobody
        # can say what. Reporting "complete" here is the phantom-recovery case.
        journal = self.a_journal()
        journal.record(**self.an_install())
        with open(self.path, "a") as fh:
            fh.write('{"op": "install", "dpid"')

        report = journal.replay(lambda entry: True)

        self.assertEqual(report.status, "partial")
        self.assertEqual(report.unreadable, 1)

    def test_the_report_is_serialisable_so_a_reader_can_exist(self):
        # This repo's most-repeated defect is a writer with no reader. A replay outcome that
        # only ever reached stdout would be the same shape: the one process that knows the
        # fabric is incomplete is the one nobody queries.
        journal = self.a_journal()
        journal.record(**self.an_install())

        body = json.loads(json.dumps(journal.replay(lambda entry: False).as_dict()))

        self.assertEqual(body["status"], "failed")
        self.assertEqual(body["attempted"], 1)


class ReplayIsOptInTest(JournalTestCase):
    """
    Recording is safe; replaying is a decision.

    A journal records requests, not the reasons behind them. Replaying a Traffic-Engineering
    detour twenty minutes after the congestion that caused it programs a path nobody wants,
    and the journal cannot tell the difference. So the default is off.
    """

    def test_replay_is_disabled_by_default(self):
        self.assertFalse(RuleJournal.replay_enabled(env={}))

    def test_replay_turns_on_only_for_an_explicit_value(self):
        self.assertTrue(RuleJournal.replay_enabled(env={"NDTWIN_RULE_JOURNAL_REPLAY": "1"}))
        # Not "any non-empty string": "0" and "false" are what someone writes when they mean
        # off, and a gate that reads them as on is worse than no gate.
        self.assertFalse(RuleJournal.replay_enabled(env={"NDTWIN_RULE_JOURNAL_REPLAY": "0"}))
        self.assertFalse(RuleJournal.replay_enabled(env={"NDTWIN_RULE_JOURNAL_REPLAY": "false"}))

    def test_recording_does_not_depend_on_the_replay_gate(self):
        # The journal has to be written while replay is off, or turning it on later finds
        # nothing. This is the NDTWIN_CLONE_DISABLE shape inverted -- there, a setter shipped
        # with no reader; here the reader must not gate the writer.
        journal = self.a_journal()
        journal.record(**self.an_install())

        self.assertEqual(len(journal.entries()), 1)


class QuarantineTest(JournalTestCase):
    """
    A journal from a previous proxy generation is evidence, not a scratchpad.

    After a replay decision has been made, the old file is set aside under a name that says
    which boot wrote it, and the new process starts a clean one. Without this, one file
    accumulates every generation's rules and a later replay reinstalls rules that were
    deliberately deleted three restarts ago.
    """

    def test_quarantine_moves_the_old_journal_aside(self):
        journal = self.a_journal()
        journal.record(**self.an_install())

        moved = journal.quarantine("bootabc")

        self.assertTrue(os.path.exists(moved))
        self.assertIn("bootabc", os.path.basename(moved))
        self.assertEqual(self.a_journal().entries(), [], "the live journal starts clean")

    def test_quarantining_nothing_is_not_an_error(self):
        self.assertIsNone(self.a_journal().quarantine("bootabc"))


if __name__ == "__main__":
    unittest.main()
