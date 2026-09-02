"""
Whether anything actually writes to the rule journal.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES A-4c. `test_rule_journal.py` proves the journal keeps its promises; this file
proves it is connected to something. The distinction is not academic here -- this repository's
most-repeated defect is a component that exists, is documented, is committed, and has no
caller. NDTWIN_CLONE_DISABLE shipped a setter and docs with zero readers, and a run that set it
was sampling normally while being labelled a zero point. A journal with no writer is that
shape: it would come back empty after every restart and be read as "there was nothing to
restore".

Six success paths need it, not three. `route_flow`, `unroute_flow` and `modify_flow` each have
a 5-tuple branch and an ipv4_lpm branch, and the 5-tuple ones matter most: `_installed_routes`
deliberately does not record 5-tuple rules (topology_manager.py says why -- that map is
`(dpid, ipv4_dst) -> out_port` and a 5-tuple rule has no single-valued answer to fit in it), so
a `flow_5tuple` entry is the one rule class with no record anywhere else in the system. If the
journal misses those, it misses precisely the rules nothing else can reconstruct.

Only accepted writes are recorded. A rule the switch refused was never installed, and
replaying it later would install something that never existed -- the mirror of the bug where
`insert_ipv4_route` returned None for a rejected write and every consumer went on being told
the route existed.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent.topology_manager import TopologyManager  # noqa: E402


class RecordingJournal:
    """Only the surface TopologyManager touches."""

    def __init__(self):
        self.records = []

    def record(self, op, dpid, match, actions, priority=None):
        self.records.append({"op": op, "dpid": dpid, "match": match, "actions": actions,
                             "priority": priority})
        return True


class FakeClient:
    """A switch that accepts or refuses every write, and remembers which it was asked."""

    def __init__(self, verdict=True):
        self.verdict = verdict
        self.calls = []

    def insert_ipv4_route(self, dst, prefix, mac, port):
        self.calls.append(("insert_ipv4_route", dst, port))
        return self.verdict

    def delete_ipv4_route(self, dst, prefix):
        self.calls.append(("delete_ipv4_route", dst))
        return self.verdict

    def modify_ipv4_route(self, dst, prefix, mac, port):
        self.calls.append(("modify_ipv4_route", dst, port))
        return self.verdict

    def insert_5tuple_rule(self, keys, prio, mac, port):
        self.calls.append(("insert_5tuple_rule", prio, port))
        return self.verdict

    def delete_5tuple_rule(self, keys, prio):
        self.calls.append(("delete_5tuple_rule", prio))
        return self.verdict

    def modify_5tuple_rule(self, keys, prio, mac, port):
        self.calls.append(("modify_5tuple_rule", prio, port))
        return self.verdict


OUTPUT_3 = [{"type": "OUTPUT", "port": 3}]
LPM_MATCH = {"nw_dst": "10.0.0.4"}
#: Anything beyond a destination compiles to the ternary flow_5tuple table.
FIVE_TUPLE_MATCH = {"nw_dst": "10.0.0.4", "nw_src": "10.0.0.1", "tp_dst": 80}


class JournalWiringTestCase(unittest.TestCase):
    def topology(self, verdict=True):
        journal = RecordingJournal()
        topo = TopologyManager(journal=journal)
        topo.switches[1] = FakeClient(verdict=verdict)
        return topo, journal


class InstallIsRecordedTest(JournalWiringTestCase):
    def test_an_accepted_lpm_install_is_recorded(self):
        topo, journal = self.topology()

        self.assertTrue(topo.route_flow(1, LPM_MATCH, OUTPUT_3, 100))

        self.assertEqual(len(journal.records), 1)
        self.assertEqual(journal.records[0]["op"], "install")
        self.assertEqual(journal.records[0]["dpid"], 1)
        self.assertEqual(journal.records[0]["match"], LPM_MATCH)
        self.assertEqual(journal.records[0]["actions"], OUTPUT_3)

    def test_an_accepted_five_tuple_install_is_recorded(self):
        # The rule class with no record anywhere else. If only the LPM branch were wired, the
        # journal would look healthy and lose exactly the rules nothing can reconstruct.
        topo, journal = self.topology()

        self.assertTrue(topo.route_flow(1, FIVE_TUPLE_MATCH, OUTPUT_3, 100))

        self.assertEqual(len(journal.records), 1)
        self.assertEqual(journal.records[0]["match"], FIVE_TUPLE_MATCH)

    def test_the_priority_is_recorded(self):
        # Meaningless for ipv4_lpm, but both meaningful and mandatory for flow_5tuple -- a
        # replayed 5-tuple rule with the wrong priority is a different entry.
        topo, journal = self.topology()

        topo.route_flow(1, FIVE_TUPLE_MATCH, OUTPUT_3, 42)

        self.assertEqual(journal.records[0]["priority"], 42)

    def test_a_refused_install_is_not_recorded(self):
        # Replaying a rule the switch never accepted would install something that never
        # existed. The same shape as insert_ipv4_route reporting None for a rejected write.
        topo, journal = self.topology(verdict=False)

        self.assertFalse(topo.route_flow(1, LPM_MATCH, OUTPUT_3, 100))

        self.assertEqual(journal.records, [])

    def test_a_refused_five_tuple_install_is_not_recorded(self):
        topo, journal = self.topology(verdict=False)

        self.assertFalse(topo.route_flow(1, FIVE_TUPLE_MATCH, OUTPUT_3, 100))

        self.assertEqual(journal.records, [])


class DeleteIsRecordedTest(JournalWiringTestCase):
    def test_an_accepted_lpm_delete_is_recorded(self):
        # A delete must be journalled or a replay resurrects a rule that was deliberately
        # removed -- which is one of the three things a restart already does today.
        topo, journal = self.topology()

        self.assertTrue(topo.unroute_flow(1, LPM_MATCH, 100))

        self.assertEqual(journal.records[0]["op"], "delete")
        self.assertEqual(journal.records[0]["match"], LPM_MATCH)

    def test_an_accepted_five_tuple_delete_is_recorded(self):
        topo, journal = self.topology()

        self.assertTrue(topo.unroute_flow(1, FIVE_TUPLE_MATCH, 100))

        self.assertEqual(journal.records[0]["op"], "delete")

    def test_a_refused_delete_is_not_recorded(self):
        topo, journal = self.topology(verdict=False)

        self.assertFalse(topo.unroute_flow(1, LPM_MATCH, 100))

        self.assertEqual(journal.records, [])


class ModifyIsRecordedTest(JournalWiringTestCase):
    def test_an_accepted_lpm_modify_is_recorded(self):
        topo, journal = self.topology()

        self.assertTrue(topo.modify_flow(1, LPM_MATCH, OUTPUT_3, 100))

        self.assertEqual(journal.records[0]["op"], "modify")
        self.assertEqual(journal.records[0]["actions"], OUTPUT_3)

    def test_an_accepted_five_tuple_modify_is_recorded(self):
        topo, journal = self.topology()

        self.assertTrue(topo.modify_flow(1, FIVE_TUPLE_MATCH, OUTPUT_3, 100))

        self.assertEqual(journal.records[0]["op"], "modify")

    def test_a_refused_modify_is_not_recorded(self):
        topo, journal = self.topology(verdict=False)

        self.assertFalse(topo.modify_flow(1, LPM_MATCH, OUTPUT_3, 100))

        self.assertEqual(journal.records, [])


class NoJournalIsNotAnErrorTest(unittest.TestCase):
    """
    A TopologyManager built without a journal must behave exactly as it did before.

    Every existing construction site passes no journal -- main.py's module-level `topo`, and
    every sibling test suite -- so this is the path that must not change. It is also the
    default in production until someone turns recording on.
    """

    def test_a_manager_with_no_journal_still_installs(self):
        topo = TopologyManager()
        topo.switches[1] = FakeClient()

        self.assertTrue(topo.route_flow(1, LPM_MATCH, OUTPUT_3, 100))

    def test_a_manager_with_no_journal_still_deletes_and_modifies(self):
        topo = TopologyManager()
        topo.switches[1] = FakeClient()

        self.assertTrue(topo.unroute_flow(1, LPM_MATCH, 100))
        self.assertTrue(topo.modify_flow(1, LPM_MATCH, OUTPUT_3, 100))


class AJournalThatFailsMustNotBreakRoutingTest(JournalWiringTestCase):
    """
    The journal is a record of routing, not a precondition for it.

    A full disk, a bad path, a permissions change -- none of those are reasons for the fabric
    to stop forwarding. `RuleJournal.record` already returns False rather than raising, but the
    call site must survive a journal that raises anyway, or a future journal implementation
    turns a logging failure into an outage.
    """

    def test_an_install_succeeds_even_if_the_journal_raises(self):
        class ExplodingJournal:
            def record(self, *args, **kwargs):
                raise OSError("no space left on device")

        topo = TopologyManager(journal=ExplodingJournal())
        topo.switches[1] = FakeClient()

        self.assertTrue(topo.route_flow(1, LPM_MATCH, OUTPUT_3, 100))


if __name__ == "__main__":
    unittest.main()
