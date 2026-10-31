"""
A pipeline push that empties a switch reports what it took of the Ryu-path rules, and replays none.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES A-4c: the rules are reported, never replayed. A proxy restart and a `POST /p4/readopt/{dpid}` both push the pipeline, and the push empties every table.
The rules written through /stats/flowentry/* are in the routing journal (`RuleJournal`) and
nowhere else; replaying them would reinstall requests whose reasons may have expired (a
traffic-engineering detour around congestion that is gone). So the journal is read, not replayed:
each push leaves a `ryu_rules_lost` record on that switch's GET /p4/switch_state entry, which
the kernel reads once a second, logs and copies onto its graph.

Four layers, each of which can be wrong while the others are right:

  DiscardedRules*   the pure fold: which journal records a push of one switch discarded.
  KernelShaped*     the same fold reached through the REST handlers with the requests the
                    kernel really sends (HttpRoutingStrategyBase): an install at priority 100, a
                    non-strict delete naming no priority, a modify at the default 0.
  JournalWiped*     `RuleJournal.wiped`: read and mark under one lock, so the next push counts
                    only what came after.
  Manager*          `TopologyManager`: the cookie each write is recorded under, the record on
                    switch_liveness / GET /p4/switch_state, and the readopt push.
  Startup*          `main.startup`: the cookie the switch held BEFORE the push decides, so a
                    fresh bmv2 (a whole-stack restart) reports nothing.

Run:  cd p4_proxy && PYTHONPATH=. venv/bin/python3 tests/test_ryu_rules_lost.py -v
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
# Before anything imports `main`: its table-entry journals go to a temp directory.
import journal_isolation  # noqa: E402,F401

from proxy_agent import api_routes, rule_journal, topology_manager  # noqa: E402
from proxy_agent.rule_journal import (LOST_RULES_SHOWN, RuleJournal, WIPED_OP,  # noqa: E402
                                      discarded_rules, loss_record)
from proxy_agent.topology_manager import TopologyManager  # noqa: E402
import test_startup  # noqa: E402  -- its fakes; its TestCases are not collected from here

G = 0x1111222233334444          # the fabric generation the rules were written under
OTHER = 0x5555666677778888       # some other generation
OUT_3 = [{"type": "OUTPUT", "port": 3}]
OUT_4 = [{"type": "OUTPUT", "port": 4}]
LPM = {"nw_dst": "10.0.0.4"}
FIVE = {"nw_dst": "10.0.0.4", "nw_src": "10.0.0.1", "tp_dst": 80}


def rec(op, match=LPM, actions=OUT_3, priority=100, dpid=1, cookie=G):
    return {"t": 0, "op": op, "dpid": dpid, "match": match, "actions": actions,
            "priority": priority, "cookie": cookie}


def mark(dpid=1, cookie=G):
    return {"t": 0, "op": WIPED_OP, "dpid": dpid, "cookie": cookie, "cause": "readopt"}


class DiscardedRulesTest(unittest.TestCase):
    def test_an_install_under_the_wiped_generation_is_lost(self):
        lost = discarded_rules([rec("install")], 1, G)
        self.assertEqual(lost, [{"op": "install", "match": LPM, "actions": OUT_3,
                                 "priority": 100}])

    def test_an_install_later_deleted_is_not_lost(self):
        # 5-tuple: the strict delete names the priority it installed with (an ipv4_lpm delete
        # cannot name one: the API answers 501; KernelShaped* covers that table).
        self.assertEqual(discarded_rules([rec("install", match=FIVE),
                                          rec("delete", match=FIVE, actions=[])], 1, G), [])

    def test_a_rewrite_reports_its_last_actions_once(self):
        lost = discarded_rules([rec("install"), rec("install", actions=OUT_4)], 1, G)
        self.assertEqual(len(lost), 1)
        self.assertEqual(lost[0]["actions"], OUT_4)

    def test_a_lone_delete_is_not_a_loss(self):
        # A delete on ipv4_lpm hands the slot back to the control-plane route (or leaves it
        # empty where the control plane has none), which is what the refill after a push leaves
        # too; on flow_5tuple nothing recreates an entry. Either way the switch ends where the
        # app left it.
        self.assertEqual(discarded_rules([rec("delete", actions=[])], 1, G), [])
        self.assertEqual(discarded_rules([rec("delete", match=FIVE, actions=[])], 1, G), [])

    def test_a_recorded_rule_identity_outranks_match_and_priority(self):
        a = dict(rec("install"), rule=["ipv4_lpm", "10.0.0.4"])
        b = dict(rec("modify", priority=0, actions=OUT_4), rule=["ipv4_lpm", "10.0.0.4"])
        lost = discarded_rules([a, b], 1, G)
        self.assertEqual(len(lost), 1)
        self.assertEqual(lost[0]["actions"], OUT_4)

    def test_unreadable_lines_count_only_after_the_switchs_last_mark(self):
        self.assertEqual(rule_journal._since_last_wipe([None, mark(), rec("install")], 1)[1], 0)
        self.assertEqual(rule_journal._since_last_wipe([mark(), None], 1)[1], 1)
        self.assertEqual(rule_journal._since_last_wipe([None, mark(dpid=2)], 1)[1], 1)

    def test_two_priorities_of_one_match_are_two_rules(self):
        lost = discarded_rules([rec("install", match=FIVE, priority=10),
                                rec("install", match=FIVE, priority=20)], 1, G)
        self.assertEqual(len(lost), 2)

    def test_only_records_after_the_last_marker_count(self):
        lost = discarded_rules([rec("install"), mark(), rec("install", match=FIVE)], 1, G)
        self.assertEqual([r["match"] for r in lost], [FIVE])

    def test_another_switchs_marker_does_not_close_this_one(self):
        lost = discarded_rules([rec("install"), mark(dpid=2)], 1, G)
        self.assertEqual(len(lost), 1)

    def test_another_switchs_rules_are_not_counted(self):
        self.assertEqual(discarded_rules([rec("install", dpid=2)], 1, G), [])

    def test_a_record_of_another_generation_is_not_counted(self):
        self.assertEqual(discarded_rules([rec("install", cookie=OTHER)], 1, G), [])

    def test_a_record_without_a_cookie_is_never_counted(self):
        # Every record written before this change has none. Neither a fresh switch (no cookie)
        # nor a pushed one may report them, or the first start after the upgrade would report
        # the journal's whole history as lost.
        legacy = dict(rec("install"))
        del legacy["cookie"]
        self.assertEqual(discarded_rules([legacy, rec("install", cookie=None)], 1, G), [])
        self.assertEqual(discarded_rules([legacy, rec("install", cookie=None)], 1, None), [])

    def test_a_switch_that_held_no_cookie_lost_nothing_this_journal_names(self):
        self.assertEqual(discarded_rules([rec("install")], 1, None), [])


class LossRecordTest(unittest.TestCase):
    def test_the_count_is_whole_and_the_list_is_capped(self):
        lost = [{"op": "install", "match": {"nw_dst": f"10.0.{i // 250}.{i % 250}"},
                 "actions": OUT_3, "priority": 100} for i in range(LOST_RULES_SHOWN + 7)]
        record = loss_record(lost, 0, "readopt", "abc", at=5.0)
        self.assertEqual(record["count"], LOST_RULES_SHOWN + 7)
        self.assertEqual(len(record["rules"]), LOST_RULES_SHOWN)
        self.assertEqual(record["rules_omitted"], 7)
        self.assertEqual((record["id"], record["cause"], record["at"]), ("abc", "readopt", 5.0))

    def test_it_says_nothing_was_replayed(self):
        self.assertIs(loss_record([], 0, "proxy_restart", "x")["replayed"], False)

    def test_an_unknown_count_is_null_with_its_reason(self):
        record = loss_record([{"op": "install"}], 0, "readopt", "x", count_known=False,
                             unknown_reason="why")
        self.assertIsNone(record["count"])
        self.assertEqual(record["count_unknown"], "why")
        self.assertEqual(len(record["rules"]), 1)


class JournalWipedTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ndt-ryu-lost-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.dir, True))
        self.journal = RuleJournal(os.path.join(self.dir, "rule_journal.jsonl"))

    def test_a_second_push_of_the_same_switch_finds_nothing_left(self):
        self.journal.record("install", 1, LPM, OUT_3, 100, cookie=G)
        lost, unreadable = self.journal.wiped(1, G, "readopt")
        self.assertEqual((len(lost), unreadable), (1, 0))
        self.assertEqual(self.journal.wiped(1, G, "readopt"), ([], 0))

    def test_the_marker_is_on_disk(self):
        self.journal.wiped(3, G, "proxy_restart")
        last = self.journal.entries()[-1]
        self.assertEqual((last["op"], last["dpid"], last["cause"]), (WIPED_OP, 3, "proxy_restart"))

    def test_the_cookie_is_recorded_with_each_write(self):
        self.journal.record("install", 1, LPM, OUT_3, 100, cookie=G)
        self.assertEqual(self.journal.entries()[0]["cookie"], G)

    def test_an_unreadable_line_is_counted(self):
        self.journal.record("install", 1, LPM, OUT_3, 100, cookie=G)
        with open(self.journal.path, "a", encoding="utf-8") as fh:
            fh.write('{"torn\n')
        lost, unreadable = self.journal.wiped(1, G, "readopt")
        self.assertEqual((len(lost), unreadable), (1, 1))

    def test_a_torn_line_before_the_mark_is_not_counted_again(self):
        # Otherwise one torn line makes every later push of every switch report it, forever.
        with open(self.journal.path, "a", encoding="utf-8") as fh:
            fh.write('{"torn\n')
        self.journal.wiped(1, G, "readopt")
        self.assertEqual(self.journal.wiped(1, G, "readopt"), ([], 0))

    def test_an_unmarked_wipe_leaves_the_rules_for_the_next_one(self):
        self.journal.record("install", 1, LPM, OUT_3, 100, cookie=G)
        self.assertEqual(len(self.journal.wiped(1, G, "readopt", mark=False)[0]), 1)
        self.assertEqual(len(self.journal.wiped(1, G, "readopt")[0]), 1)

    def test_a_replay_never_hands_a_marker_to_its_applier(self):
        self.journal.wiped(1, G, "readopt")
        seen = []
        self.journal.replay(lambda e: seen.append(e) or True)
        self.assertEqual(seen, [])


class InstallTimes:
    def __len__(self):
        return 0

    def oldest_installed_at_epoch(self):
        return None


class FakeSwitch:
    """A bmv2 client that takes every write and every step of a readopt, and remembers them."""

    #: Marks "the switch holds the cookie this client presents" -- the common case.
    SAME = object()

    def __init__(self, dpid, cookie=G, held=SAME, cookie_error=None):
        self.dpid = dpid
        self.pipeline_cookie = cookie
        # [Co-developed with claude code -- Adam]
        # What COOKIE_ONLY answers before the push: the cookie the SWITCH holds, which is not
        # what this client presents when a previous boot's tables are still on it.
        self.held = cookie if held is FakeSwitch.SAME else held
        self.cookie_error = cookie_error
        self.table_generation = None
        self.calls = []
        self.arbitration = True
        self.mastership_confirmed = True
        self.packet_in_callback = None
        self.sample_callback = None
        self.stream_alive = True
        self.rule_install_times = InstallTimes()

    def last_table_read(self):
        return None

    def read_pipeline_cookie(self, timeout_s=None):
        self.calls.append("read_pipeline_cookie")
        if self.cookie_error is not None:
            raise self.cookie_error
        return self.held

    def start(self, push_config=True):
        self.calls.append("start")

    def set_forwarding_pipeline_config(self):
        self.calls.append("pipeline")
        self.table_generation = f"gen-{self.dpid}-{len(self.calls)}"

    def write_clone_session(self, *a, **k):
        return True

    def stop(self):
        self.calls.append("stop")

    def __getattr__(self, name):
        # Every rule write (insert/modify/delete of ipv4 routes and 5-tuple rules) is accepted
        # and recorded, so a replay would show up in `calls`.
        if name.startswith(("insert_", "modify_", "delete_")):
            return lambda *a, **k: self.calls.append(name) or True
        raise AttributeError(name)


class ManagerTestBase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ndt-ryu-lost-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.dir, True))
        self.journal = RuleJournal(os.path.join(self.dir, "rule_journal.jsonl"))
        self.topo = TopologyManager(journal=self.journal)
        self.old = FakeSwitch(1)
        self.topo.add_switch(1, self.old)
        sleep = mock.patch.object(topology_manager.time, "sleep", lambda s: None)
        sleep.start()
        self.addCleanup(sleep.stop)


class ManagerRecordTest(ManagerTestBase):
    def test_a_ryu_write_is_journaled_under_its_clients_cookie(self):
        self.assertTrue(self.topo.route_flow(1, FIVE, OUT_3, 100))
        self.assertEqual(self.journal.entries()[-1]["cookie"], G)

    def test_before_any_push_the_switch_reports_null(self):
        entry = self.topo.switch_liveness()["switches"]["1"]
        self.assertIn("ryu_rules_lost", entry)
        self.assertIsNone(entry["ryu_rules_lost"])

    def test_the_record_reaches_switch_state(self):
        self.topo.route_flow(1, FIVE, OUT_3, 100)
        self.topo.close_ryu_generation(1, G, "proxy_restart", self.old)
        api_routes.inject_topology(self.topo)
        state = asyncio.run(api_routes.switch_state())
        record = state["switches"]["1"]["ryu_rules_lost"]
        self.assertEqual((record["count"], record["cause"]), (1, "proxy_restart"))
        self.assertEqual(record["rules"][0]["match"], FIVE)

    def test_without_a_journal_there_is_no_record(self):
        topo = TopologyManager()
        self.assertIsNone(topo.close_ryu_generation(1, G, "readopt", self.old))


class PrefixRouteJournalTest(ManagerTestBase):
    """
    A CIDR destination goes through the journal under its route key.

    [Co-developed with claude code -- Adam]
    route_flow and unroute_flow rewrite a prefix to its route key ("10.0.1.77/24" is the entry
    10.0.1.0/24) before anything is recorded, so the loss fold sees an install and a later delete
    of the same prefix as one switch entry, whichever host bits each request carried.
    """

    INSTALLED = {"nw_dst": "10.0.1.77/24"}
    NETWORK = {"nw_dst": "10.0.1.0/24"}

    def test_a_prefix_deleted_by_its_network_address_is_not_lost(self):
        self.assertTrue(self.topo.route_flow(1, self.INSTALLED, OUT_3, 100))
        self.assertTrue(self.topo.unroute_flow(1, self.NETWORK))
        record = self.topo.close_ryu_generation(1, G, "readopt", self.old)
        self.assertEqual(record["count"], 0, record)

    def test_a_prefix_deleted_with_host_bits_set_is_not_lost(self):
        # The other direction: the install names the network, the delete carries host bits.
        # [Co-developed with claude code -- Adam]
        self.assertTrue(self.topo.route_flow(1, self.NETWORK, OUT_3, 100))
        self.assertTrue(self.topo.unroute_flow(1, self.INSTALLED))
        record = self.topo.close_ryu_generation(1, G, "readopt", self.old)
        self.assertEqual(record["count"], 0, record)

    def test_a_prefix_left_installed_is_one_lost_rule_under_its_route_key(self):
        self.assertTrue(self.topo.route_flow(1, self.INSTALLED, OUT_3, 100))
        self.assertEqual(self.journal.entries()[-1]["rule"], ["ipv4_lpm", "10.0.1.0/24"])
        record = self.topo.close_ryu_generation(1, G, "readopt", self.old)
        self.assertEqual(record["count"], 1, record)
        self.assertEqual(record["rules"][0]["match"], self.NETWORK)


class FailingJournal(RuleJournal):
    """A journal whose disk refuses every rule write (record answers False)."""

    def record(self, *args, **kwargs):
        return False


class ManagerJournalFailureTest(unittest.TestCase):
    def test_a_write_the_journal_refused_marks_the_next_count_incomplete(self):
        d = tempfile.mkdtemp(prefix="ndt-ryu-lost-")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, True))
        topo = TopologyManager(journal=FailingJournal(os.path.join(d, "j.jsonl")))
        switch = FakeSwitch(1)
        topo.add_switch(1, switch)
        self.assertTrue(topo.route_flow(1, FIVE, OUT_3, 100), "the write itself must succeed")
        record = topo.close_ryu_generation(1, G, "proxy_restart", switch)
        self.assertEqual(record["journal_write_failures"], 1)
        self.assertEqual(topo.close_ryu_generation(1, G, "proxy_restart", switch)
                         ["journal_write_failures"], 0, "the count belongs to one generation")


class ManagerReadoptTest(ManagerTestBase):
    def readopt(self):
        made = []

        def factory(dpid):
            made.append(FakeSwitch(dpid, cookie=G))
            return made[-1]
        result = self.topo.readopt_switch(1, factory, None, settle_s=0)
        return result, made[0]

    def test_a_readopt_reports_the_rules_it_wiped(self):
        self.topo.route_flow(1, FIVE, OUT_3, 100)
        self.topo.route_flow(1, LPM, OUT_4, 100)

        result, new = self.readopt()

        self.assertEqual(result["status"], "success", result)
        record = result["ryu_rules_lost"]
        self.assertEqual((record["count"], record["cause"]), (2, "readopt"))
        self.assertEqual(record["id"], new.table_generation)
        self.assertEqual(self.topo.switch_liveness()["switches"]["1"]["ryu_rules_lost"], record)

    def test_a_readopt_replays_nothing(self):
        self.topo.route_flow(1, FIVE, OUT_3, 100)

        _, new = self.readopt()

        # Through either client: the generation is closed while the old one is still in place.
        self.assertNotIn("insert_5tuple_rule", new.calls,
                         "the readopt wrote the lost 5-tuple rule back onto the switch")
        self.assertEqual(self.old.calls.count("insert_5tuple_rule"), 1,
                         "the readopt wrote the lost 5-tuple rule again through the old client")

    def test_the_generation_is_closed_before_the_new_client_takes_writes(self):
        seen = []
        real = self.journal.wiped

        def watching(dpid, cookie, cause, mark=True):
            seen.append(self.topo.switches.get(dpid))
            return real(dpid, cookie, cause, mark=mark)
        self.journal.wiped = watching
        self.readopt()
        self.assertIs(seen[0], self.old, "the new client was swapped in before the mark")

    def test_a_readopt_whose_push_raised_reports_an_unknown_count(self):
        self.topo.route_flow(1, FIVE, OUT_3, 100)

        class Refusing(FakeSwitch):
            def set_forwarding_pipeline_config(self):
                raise RuntimeError("INTERNAL: the push died half way")
        result = self.topo.readopt_switch(1, lambda dpid: Refusing(dpid), None, settle_s=0)
        self.assertEqual(result["status"], "failed")
        record = result["ryu_rules_lost"]
        self.assertIsNone(record["count"])
        self.assertTrue(record["count_unknown"])
        self.assertEqual(len(record["rules"]), 1, "the candidates are listed")
        again, _ = self.readopt()
        self.assertEqual(again["ryu_rules_lost"]["count"], 1,
                         "an unmarked failure must leave the rule for the next push")

    def test_a_second_readopt_reports_only_what_came_after_the_first(self):
        self.topo.route_flow(1, FIVE, OUT_3, 100)
        self.readopt()
        result, _ = self.readopt()
        self.assertEqual(result["ryu_rules_lost"]["count"], 0)


class ManagerReadoptCookieTest(ManagerTestBase):
    """
    The loss record is folded against the cookie the switch HELD before the push, not the one
    this boot stamped on its clients. Startup gives every client this boot's cookie, pushed or
    not, so a switch whose push failed (it hung, or its stream broke) is still holding the
    previous generation's tables when it is readopted; one that was powered off comes back
    empty.

    [Co-developed with claude code -- Adam]
    """

    def setUp(self):
        super().setUp()
        # The rules were written under OTHER (the previous generation) ...
        self.old.pipeline_cookie = OTHER
        self.assertTrue(self.topo.route_flow(1, FIVE, OUT_3, 100))
        self.assertTrue(self.topo.route_flow(1, LPM, OUT_4, 100))
        # ... and this boot stamped its own cookie on the client, whose push never succeeded.
        self.old.pipeline_cookie = G

    def readopt(self, **new_kwargs):
        return self.topo.readopt_switch(
            1, lambda dpid: FakeSwitch(dpid, cookie=G, **new_kwargs), None, settle_s=0)

    def test_a_readopt_counts_the_rules_of_the_generation_the_switch_held(self):
        result = self.readopt(held=OTHER)

        self.assertEqual(result["status"], "success", result)
        self.assertEqual(result["ryu_rules_lost"]["count"], 2,
                         "the switch held the previous generation's tables; the push wiped "
                         "both rules and the apps must be told so")

    def test_a_readopt_whose_push_raised_lists_the_rules_the_switch_held(self):
        class Refusing(FakeSwitch):
            def set_forwarding_pipeline_config(self):
                raise RuntimeError("INTERNAL: the push died half way")
        result = self.topo.readopt_switch(
            1, lambda dpid: Refusing(dpid, cookie=G, held=OTHER), None, settle_s=0)

        self.assertEqual(result["status"], "failed")
        record = result["ryu_rules_lost"]
        self.assertIsNone(record["count"])
        self.assertEqual(len(record["rules"]), 2, "the candidates are the held generation's")

    def test_a_switch_that_cannot_say_what_it_held_gives_an_unknown_count(self):
        result = self.readopt(cookie_error=RuntimeError("UNAVAILABLE: no route to switch"))

        self.assertEqual(result["status"], "success", result)
        record = result["ryu_rules_lost"]
        self.assertIsNone(record["count"])
        self.assertIn("UNAVAILABLE", record["count_unknown"])

    def test_an_unreadable_cookie_still_lists_the_old_clients_rules_as_candidates(self):
        # The count is unknown, but "unknown" is not "nothing": the rules the old client wrote
        # under its own cookie are listed so the apps can resend them.
        self.assertTrue(self.topo.route_flow(1, {"nw_dst": "10.0.0.9"}, OUT_3, 100))
        result = self.readopt(cookie_error=RuntimeError("UNAVAILABLE: no route to switch"))

        record = result["ryu_rules_lost"]
        self.assertIsNone(record["count"])
        self.assertEqual([r["match"] for r in record["rules"]], [{"nw_dst": "10.0.0.9"}])

    def test_a_write_tagged_with_the_old_clients_cookie_is_counted_beside_the_held_ones(self):
        # The old client carries G but the switch held OTHER; a write it took in between was
        # journaled under G. The push wipes it as well, so both generations are folded.
        self.assertTrue(self.topo.route_flow(1, {"nw_dst": "10.0.0.9"}, OUT_3, 100))
        result = self.readopt(held=OTHER)

        self.assertEqual(result["ryu_rules_lost"]["count"], 3, result["ryu_rules_lost"])

    def test_a_switch_that_holds_no_cookie_still_reports_what_this_proxy_wrote(self):
        # The switch answers a cookie of None (a pipeline that carries none): the rules this
        # proxy wrote through the old client (cookie G) are what the record said before.
        self.assertTrue(self.topo.route_flow(1, {"nw_dst": "10.0.0.9"}, OUT_3, 100))
        result = self.readopt(held=None)

        self.assertEqual(result["status"], "success", result)
        self.assertEqual(result["ryu_rules_lost"]["count"], 1, result["ryu_rules_lost"])

    def test_a_power_cycled_switch_still_reports_what_this_proxy_wrote(self):
        # A restarted bmv2 answers COOKIE_ONLY with FAILED_PRECONDITION (it has been pushed no
        # pipeline). That is the common readopt, and the rule written through the old client
        # went with the reboot.
        self.assertTrue(self.topo.route_flow(1, {"nw_dst": "10.0.0.9"}, OUT_3, 100))
        result = self.readopt(cookie_error=RuntimeError("FAILED_PRECONDITION: no pipeline"))

        self.assertEqual(result["status"], "success", result)
        record = result["ryu_rules_lost"]
        self.assertEqual(record["count"], 1, record)
        self.assertIsNone(record["count_unknown"])

    def test_the_cookie_is_read_before_the_push(self):
        made = []

        def factory(dpid):
            made.append(FakeSwitch(dpid, cookie=G, held=OTHER))
            return made[-1]
        self.topo.readopt_switch(1, factory, None, settle_s=0)
        calls = made[0].calls
        self.assertIn("read_pipeline_cookie", calls)
        self.assertLess(calls.index("read_pipeline_cookie"), calls.index("pipeline"))


class ManagerReadoptSameKeyAcrossGenerationsTest(ManagerTestBase):
    """
    A rule key written under one generation and then written or deleted under the other is ONE
    entry on the switch, so the two generations are folded together, not counted one by one.

    [Co-developed with claude code -- Adam]
    """

    def readopt(self):
        return self.topo.readopt_switch(
            1, lambda dpid: FakeSwitch(dpid, cookie=G, held=OTHER), None, settle_s=0)

    def test_a_key_installed_under_both_generations_is_one_lost_rule(self):
        self.old.pipeline_cookie = OTHER
        self.assertTrue(self.topo.route_flow(1, LPM, OUT_3, 100))
        self.old.pipeline_cookie = G
        self.assertTrue(self.topo.route_flow(1, LPM, OUT_4, 100))

        record = self.readopt()["ryu_rules_lost"]

        self.assertEqual(record["count"], 1, record)

    def test_a_key_installed_under_one_generation_and_deleted_under_the_other_is_not_lost(self):
        self.old.pipeline_cookie = OTHER
        self.assertTrue(self.topo.route_flow(1, LPM, OUT_3, 100))
        self.old.pipeline_cookie = G
        self.assertTrue(self.topo.unroute_flow(1, LPM))

        record = self.readopt()["ryu_rules_lost"]

        self.assertEqual(record["count"], 0, record)


class CookieSwitch(test_startup.FakeClient):
    """test_startup's switch, plus the pipeline cookie it holds before this proxy's push."""

    def __init__(self, dpid, held=None, cookie_error=None, **kw):
        super().__init__(dpid, **kw)
        self.held = held
        self.cookie_error = cookie_error
        self.pipeline_cookie = None
        self.table_generation = None

    def read_pipeline_cookie(self):
        if self.cookie_error is not None:
            raise self.cookie_error
        if self.held is None:
            raise RuntimeError("FAILED_PRECONDITION: no pipeline has been pushed")
        return self.held

    def set_forwarding_pipeline_config(self):
        super().set_forwarding_pipeline_config()
        self.table_generation = f"after-push-{self.dpid}"


class LossTopo(test_startup.FakeTopo):
    """test_startup's topology, whose loss record is the real TopologyManager's."""

    def __init__(self, manager):
        super().__init__()
        self.manager = manager

    def close_ryu_generation(self, dpid, cookie, cause, client, **kw):
        return self.manager.close_ryu_generation(dpid, cookie, cause, client, **kw)


class StartupTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ndt-ryu-lost-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.dir, True))
        self.journal = RuleJournal(os.path.join(self.dir, "rule_journal.jsonl"))
        # What the previous proxy run wrote through /stats/flowentry/add, under its cookie G.
        self.journal.record("install", 1, FIVE, OUT_3, 100, cookie=G)
        self.journal.record("install", 1, LPM, OUT_4, 100, cookie=G)
        self.manager = TopologyManager(journal=self.journal)

    def start(self, clients):
        summary, _ = test_startup.run_startup(clients, topo=LossTopo(self.manager))
        return summary

    def test_a_restart_over_a_running_switch_reports_its_rules(self):
        switch = CookieSwitch(1, held=G)
        self.start({1: switch})
        record = self.manager._ryu_rules_lost[1]
        self.assertEqual((record["count"], record["cause"]), (2, "proxy_restart"))
        self.assertEqual(record["id"], "after-push-1")

    def test_a_restart_replays_nothing(self):
        switch = CookieSwitch(1, held=G)
        self.start({1: switch})
        self.assertEqual(switch.written, [], "a lost rule was written back at startup")
        ops = [e["op"] for e in self.journal.entries()]
        self.assertEqual(ops, ["install", "install", WIPED_OP],
                         "startup journaled a write it should not have made")

    def test_a_fresh_bmv2_reports_nothing(self):
        # A whole-stack restart: bmv2 restarted too, holds no cookie, and the rules died with
        # it -- not with this push, and nobody still believes in them.
        self.start({1: CookieSwitch(1, held=None)})
        self.assertEqual(self.manager._ryu_rules_lost[1]["count"], 0)

    def test_a_switch_of_another_generation_reports_nothing(self):
        self.start({1: CookieSwitch(1, held=OTHER)})
        self.assertEqual(self.manager._ryu_rules_lost[1]["count"], 0)

    def test_a_switch_whose_push_raised_reports_an_unknown_count(self):
        # A refused or interrupted push may still have emptied the tables: not "nothing lost".
        self.start({1: CookieSwitch(1, held=G, pipeline_error=RuntimeError("dead"))})
        record = self.manager._ryu_rules_lost[1]
        self.assertIsNone(record["count"])
        self.assertEqual(len(record["rules"]), 2, "the candidates are listed")
        self.assertNotIn(WIPED_OP, [e["op"] for e in self.journal.entries()],
                         "a failed push must not mark: the next push counts these again")

    def test_a_switch_that_could_not_be_asked_reports_an_unknown_count(self):
        # UNAVAILABLE (or anything but a fresh bmv2's FAILED_PRECONDITION) says nothing about
        # which generation the tables were under, and the push then emptied them.
        self.start({1: CookieSwitch(1, held=G, cookie_error=RuntimeError("UNAVAILABLE: gone"))})
        record = self.manager._ryu_rules_lost[1]
        self.assertIsNone(record["count"])
        self.assertIn("UNAVAILABLE", record["count_unknown"])


import test_modify_at_slot_priority as slot  # noqa: E402  -- its fabric and request shapes


class CookieSlotClient(slot.SlotClient):
    """test_modify_at_slot_priority's ipv4_lpm client, in fabric generation G."""
    pipeline_cookie = G
    table_generation = "gen"


def delete_body(dst):
    """The kernel's non-strict delete (HttpRoutingStrategyBase): no `priority` key at all."""
    return {"dpid": 1, "match": {"eth_type": 2048, "ipv4_dst": dst}}


class KernelShapedRequestsTest(slot.SlotTestCase):
    def setUp(self):
        super().setUp()
        self.dir = tempfile.mkdtemp(prefix="ndt-ryu-lost-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.dir, True))
        self.topo, self.c1, _ = self.fabric(client1=CookieSlotClient(), client2=CookieSlotClient())
        self.topo._journal = RuleJournal(os.path.join(self.dir, "rule_journal.jsonl"))

    def restart(self):
        return self.topo.close_ryu_generation(1, G, "proxy_restart", self.c1)["count"]

    def test_install_then_nonstrict_delete_on_a_routed_destination_loses_nothing(self):
        slot.post(api_routes.add_flow_entry, slot.body(priority=100, dst=slot.DST))
        slot.post(api_routes.delete_flow_entry, delete_body(slot.DST))
        self.assertEqual(self.restart(), 0)

    def test_install_then_nonstrict_delete_on_an_unrouted_destination_loses_nothing(self):
        slot.post(api_routes.add_flow_entry, slot.body(priority=100, dst=slot.UNROUTED))
        slot.post(api_routes.delete_flow_entry, delete_body(slot.UNROUTED))
        self.assertEqual(self.restart(), 0)

    def test_install_then_modify_is_one_lost_rule(self):
        slot.post(api_routes.add_flow_entry, slot.body(priority=100, dst=slot.DST))
        slot.modify(slot.body(priority=0, port=4, dst=slot.DST))
        self.assertEqual(self.restart(), 1)

    def test_an_install_alone_is_one_lost_rule(self):
        slot.post(api_routes.add_flow_entry, slot.body(priority=100, dst=slot.DST))
        self.assertEqual(self.restart(), 1)


if __name__ == "__main__":
    unittest.main()
