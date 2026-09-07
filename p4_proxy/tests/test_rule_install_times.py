"""
The P4 plane's clock: who writes it, what it refuses to say, and that the endpoint reads it.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES G-13. A bmv2 table entry has no age, so `/stats/flow/<dpid>` reported
`duration_sec: 0, duration_nsec: 0` for every rule and the P4 plane had no time axis at all.
Measured 2026-09-07 (W16-3, P4 plane, 4 hosts): a route installed, read back at +12 s and +32 s,
0/0 both times, for it and for every rule already on the switch, while its counters moved. `ndt`
therefore could not attribute a leftover rule to the app that wrote it, and marked the whole
table UNKNOWN.

Three things have to hold, and each fails silently on its own:

  1. **The write side records only what the switch accepted.** A stamp for a refused write dates
     a rule that is not there, and the next rule at that key inherits it.
  2. **The read side finds what the write side recorded.** Both compute
     `rule_install_times.entry_key`; if they ever diverge -- a table name spelled differently, a
     priority the switch reports as 0, bytes compared raw against a canonicalised read-back --
     every lookup misses, every rule reports 0/0, and the result is *identical to the defect*.
     That is why the cases below drive the real `P4RuntimeClient` write methods and then look the
     entry up in the shape `read_table_entries` returns, rather than asserting on either half
     alone.
  3. **A rule with no record keeps 0/0.** Never the proxy's start time, never the poll time.
     `ndt` reads 0/0 as "unknown"; anything else is a confident wrong number.

The renderer's half of this contract is in test_ryu_flow_stats.py
(`DurationComesFromTheProxysOwnRecordTest`); the mutation gate is
tests/shell/mutate_p4_rule_install_time.sh.

unittest rather than pytest, because tools/test_workflow/l1_unit_tests.sh runs these files
directly and parses "Ran N tests".
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent import ryu_flow_stats  # noqa: E402
from proxy_agent.rule_install_times import (  # noqa: E402
    RuleInstallTimes, entry_key, is_dont_care, normalise_match,
)

# The write paths live on P4RuntimeClient, which needs the P4Runtime protobufs. Guarded the way
# test_p4_client_writes.py guards them: a bare module-level SkipTest is an uncaught exception
# during import and exits nonzero exactly like the ImportError it replaces.
try:
    import grpc
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2

    from proxy_agent import api_routes
    from proxy_agent.p4_client import P4RuntimeClient

    class FakeRpcError(grpc.RpcError):
        """Must derive from grpc.RpcError, or the client's own except clause will not catch it."""

        def __init__(self, code, details="fake failure"):
            self._code = code
            self._details = details

        def code(self):
            return self._code

        def details(self):
            return self._details

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover - depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False


# Real ids from p4_src/build/ndtwin_switch.p4info.txt, so a mixed-up id reads as the wrong number
# rather than as an off-by-one that happens to work.
IPV4_LPM_ID = 37375156
FLOW_5TUPLE_ID = 50095925
IPV4_FORWARD_ID = 28792405
DST_ADDR_PARAM_ID = 1
PORT_PARAM_ID = 2
LPM_DST_FIELD_ID = 1
FIVE_TUPLE_FIELDS = {
    "standard_metadata.ingress_port": 1,
    "hdr.ipv4.srcAddr": 2,
    "hdr.ipv4.dstAddr": 3,
    "hdr.ipv4.protocol": 4,
    "meta.l4_src_port": 5,
    "meta.l4_dst_port": 6,
}

LPM_TABLE = "MyIngress.ipv4_lpm"
FIVE_TUPLE_TABLE = "MyIngress.flow_5tuple"
FORWARD_ACTION = "MyIngress.ipv4_forward"


class FakeClock:
    """A clock the test drives. No sleeping, and no age that depends on machine load."""

    def __init__(self, now=1_000.0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds
        return self.now


def a_p4info():
    """The subset of ndtwin_switch.p4info.txt the route methods look things up in."""
    p4info = p4info_pb2.P4Info()

    lpm = p4info.tables.add()
    lpm.preamble.id = IPV4_LPM_ID
    lpm.preamble.name = LPM_TABLE
    field = lpm.match_fields.add()
    field.id = LPM_DST_FIELD_ID
    field.name = "hdr.ipv4.dstAddr"

    ternary = p4info.tables.add()
    ternary.preamble.id = FLOW_5TUPLE_ID
    ternary.preamble.name = FIVE_TUPLE_TABLE
    for name, field_id in sorted(FIVE_TUPLE_FIELDS.items(), key=lambda kv: kv[1]):
        f = ternary.match_fields.add()
        f.id = field_id
        f.name = name

    forward = p4info.actions.add()
    forward.preamble.id = IPV4_FORWARD_ID
    forward.preamble.name = FORWARD_ACTION
    param = forward.params.add()
    param.id = DST_ADDR_PARAM_ID
    param.name = "dstAddr"
    param = forward.params.add()
    param.id = PORT_PARAM_ID
    param.name = "port"

    return p4info


class RecordingStub:
    """Captures writes instead of sending them, and can be told to refuse them."""

    def __init__(self, write_error=None, always=True):
        self.requests = []
        self.pipelines = []
        self.write_error = write_error
        self.always = always

    def Write(self, request, timeout=None):
        self.requests.append(request)
        if self.write_error is not None:
            if self.always:
                raise self.write_error
            error, self.write_error = self.write_error, None
            raise error

    def Read(self, request, timeout=None):
        return iter(())

    def SetForwardingPipelineConfig(self, request, timeout=None):
        self.pipelines.append(request)
        return None


def a_client(stub=None, device_id=1, clock=None, json_path=None):
    """
    A client with no gRPC channel, holding a record whose clock the test drives.

    Built with `__new__` for the reason test_p4_client_writes.py gives -- depending on the
    generated p4info under p4_src/build would couple these tests to a build step -- and every
    field the write paths touch is assigned, including the install record itself.
    """
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = device_id
    client.grpc_addr = "127.0.0.1:50051"
    client.p4info = a_p4info()
    client.json_path = json_path
    client.stub = stub if stub is not None else RecordingStub()
    client.packet_in_callback = None
    client.sample_callback = None
    client.is_running = False
    client.stream_recv_thread = None
    client.table_generation = None
    client.pipeline_commits = 0
    client.rule_install_times = RuleInstallTimes(monotonic=clock or FakeClock())
    # The row count of the last table read -- `rules_total` on GET /p4/switch_state, the
    # denominator the record above is reported against. Same starting value __init__ sets.
    client._last_table_read = None
    return client


def read_back_lpm(dst=b"\x0a\x00\x00\x04", prefix=32, port=3, priority=0):
    """
    One ipv4_lpm entry in the shape `read_table_entries` returns.

    Priority 0 because an LPM table has no priority concept and bmv2 reports one for every entry
    in it -- which is the number the write side has to have recorded, not the one a caller passed.
    """
    return {
        "table": LPM_TABLE,
        "priority": priority,
        "is_default": False,
        "match": {"hdr.ipv4.dstAddr": {"type": "lpm", "value": dst, "prefix_len": prefix}},
        "action": {"name": FORWARD_ACTION, "params": {"port": bytes([port])}},
        "counters": None,
    }


# --- the key: one function, both sides ---------------------------------------------------


class EntryKeyTest(unittest.TestCase):
    """
    What makes two table entries the same entry.

    Every case here is a way for the write side and the read side to disagree. They all fail the
    same way -- the lookup misses and the rule reports 0/0 -- which is indistinguishable from the
    defect this whole change exists to fix, so none of them can be left to be noticed in
    production.
    """

    def key(self, dpid=1, table=LPM_TABLE, priority=0, match=None):
        return entry_key(dpid, table, priority,
                         {} if match is None else match)

    def lpm(self, value, prefix=32):
        return {"hdr.ipv4.dstAddr": {"type": "lpm", "value": value, "prefix_len": prefix}}

    def test_bmv2_stripping_leading_zero_bytes_still_names_the_same_entry(self):
        # P4Runtime canonical form drops leading zero bytes, so four bytes written can be one
        # byte read. Comparing raw bytes would miss every address with a leading zero octet --
        # the same trap _ipv4_route_present had to be fixed for.
        self.assertEqual(self.key(match=self.lpm(b"\x00\x00\x00\x04")),
                         self.key(match=self.lpm(b"\x04")))

    def test_a_different_destination_is_a_different_entry(self):
        self.assertNotEqual(self.key(match=self.lpm(b"\x0a\x00\x00\x04")),
                            self.key(match=self.lpm(b"\x0a\x00\x00\x07")))

    def test_a_different_prefix_length_is_a_different_entry(self):
        # 10.0.0.0/24 and 10.0.0.0/32 are two rules, and deleting one leaves the other.
        self.assertNotEqual(self.key(match=self.lpm(b"\x0a\x00\x00\x00", prefix=24)),
                            self.key(match=self.lpm(b"\x0a\x00\x00\x00", prefix=32)))

    def test_a_different_priority_is_a_different_entry(self):
        # On a ternary table the priority is part of the entry's identity -- delete_5tuple_rule's
        # docstring records what happens when that is forgotten.
        match = {"hdr.ipv4.dstAddr": {"type": "ternary", "value": b"\x0a\x00\x00\x04",
                                      "mask": b"\xff\xff\xff\xff"}}
        self.assertNotEqual(self.key(table=FIVE_TUPLE_TABLE, priority=100, match=match),
                            self.key(table=FIVE_TUPLE_TABLE, priority=101, match=match))

    def test_a_different_table_is_a_different_entry(self):
        self.assertNotEqual(self.key(table=LPM_TABLE, match=self.lpm(b"\x04")),
                            self.key(table=FIVE_TUPLE_TABLE, match=self.lpm(b"\x04")))

    def test_a_different_switch_is_a_different_entry(self):
        self.assertNotEqual(self.key(dpid=1, match=self.lpm(b"\x04")),
                            self.key(dpid=2, match=self.lpm(b"\x04")))

    def test_a_dpid_given_as_text_names_the_same_switch_as_one_given_as_a_number(self):
        self.assertEqual(self.key(dpid=1, match=self.lpm(b"\x04")),
                         self.key(dpid="1", match=self.lpm(b"\x04")))

    def test_field_order_does_not_change_the_entry(self):
        a = {"hdr.ipv4.srcAddr": {"type": "exact", "value": b"\x01"},
             "hdr.ipv4.dstAddr": {"type": "exact", "value": b"\x02"}}
        b = {"hdr.ipv4.dstAddr": {"type": "exact", "value": b"\x02"},
             "hdr.ipv4.srcAddr": {"type": "exact", "value": b"\x01"}}
        self.assertEqual(self.key(match=a), self.key(match=b))

    def test_a_zero_masked_ternary_field_is_not_part_of_the_entry(self):
        # A zero mask matches everything, which is the same as the field being absent -- and
        # ryu_flow_stats already drops it when rendering. Both sides ask is_dont_care, so a
        # switch that echoes a wildcard the write never mentioned does not rename the entry.
        with_wildcard = {"hdr.ipv4.dstAddr": {"type": "ternary", "value": b"\x0a\x00\x00\x04",
                                              "mask": b"\xff\xff\xff\xff"},
                         "meta.l4_dst_port": {"type": "ternary", "value": b"\x00\x00",
                                              "mask": b"\x00\x00"}}
        without = {"hdr.ipv4.dstAddr": {"type": "ternary", "value": b"\x0a\x00\x00\x04",
                                        "mask": b"\xff\xff\xff\xff"}}
        self.assertEqual(self.key(match=with_wildcard), self.key(match=without))

    def test_the_renderer_and_the_key_agree_on_what_dont_care_means(self):
        spec = {"type": "ternary", "value": b"\x03", "mask": b"\x00"}
        self.assertTrue(is_dont_care(spec))
        self.assertNotIn("in_port",
                         ryu_flow_stats.render_flow_stats(
                             1, [{"table": FIVE_TUPLE_TABLE, "priority": 1, "is_default": False,
                                  "match": {"standard_metadata.ingress_port": spec,
                                            "hdr.ipv4.dstAddr": {"type": "ternary",
                                                                 "value": b"\x0a\x00\x00\x04",
                                                                 "mask": b"\xff\xff\xff\xff"}},
                                  "action": None}])["1"][0]["match"])

    def test_a_match_type_nobody_models_keeps_two_entries_apart(self):
        # An unknown type is a reason to be more careful, not less: collapsing two entries onto
        # one key would hand one of them the other's age.
        a = {"meta.future": {"type": "optional", "value": b"\x01"}}
        b = {"meta.future": {"type": "optional", "value": b"\x02"}}
        self.assertNotEqual(self.key(match=a), self.key(match=b))

    def test_an_empty_match_is_a_key_rather_than_a_crash(self):
        # read_table_entries reports default actions with no match fields at all. The renderer
        # drops them, but the key must not raise on the polling path first.
        self.assertEqual(normalise_match(None), ())
        self.assertEqual(normalise_match({}), ())


# --- the record: what it says, and what it refuses to say ----------------------------------


class RuleInstallTimesTest(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.wall = FakeClock(1_700_000_000.0)
        self.times = RuleInstallTimes(monotonic=self.clock, wall=self.wall)
        self.match = {"hdr.ipv4.dstAddr": {"type": "lpm", "value": b"\x0a\x00\x00\x04",
                                           "prefix_len": 32}}

    def age(self):
        return self.times.age_seconds(1, LPM_TABLE, 0, self.match)

    def test_an_entry_nobody_recorded_has_no_age_at_all(self):
        # None, not 0.0. "Unknown" and "installed this instant" are different facts, and the one
        # place they must not be merged is here, where the merge would be invisible downstream.
        self.assertIsNone(self.age())

    def test_a_recorded_entry_ages_with_the_clock(self):
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.clock.advance(12)
        self.assertAlmostEqual(self.age(), 12.0)
        self.clock.advance(20)
        self.assertAlmostEqual(self.age(), 32.0)

    def test_an_idempotent_rewrite_does_not_restart_the_clock(self):
        # 🔴 The one that would have made this whole record useless. install_initial_routes is
        # deliberately idempotent (insert_ipv4_route falls back to MODIFY) and the link watchdog
        # re-runs it on every link transition, so a fabric flapping a link every few seconds
        # would reset every rule's age every few seconds and no rule could look older than the
        # last flap.
        #
        # Since Adam's 2026-09-08 ruling this holds for EVERY second write of an entry, not only
        # a rewrite that changed nothing: the stamp is the first accepted write and only a delete
        # ends it, matching OVS, where `duration` is the switch's own and OpenFlow counts it from
        # the ADD. `record` no longer takes an action, so it has no way to tell the two apart --
        # the reroute case is at the client layer, where a reroute is a distinguishable call:
        # TheClientDatesWhatTheSwitchAcceptedTest.
        # test_an_app_rerouting_a_destination_does_not_make_the_rule_look_new.
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.clock.advance(30)
        self.times.record(1, LPM_TABLE, 0, self.match)

        self.assertAlmostEqual(self.age(), 30.0)

    def test_forgetting_an_entry_takes_its_age_with_it(self):
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.assertTrue(self.times.forget(1, LPM_TABLE, 0, self.match))
        self.assertIsNone(self.age())

    def test_forgetting_something_never_recorded_says_so_without_raising(self):
        self.assertFalse(self.times.forget(1, LPM_TABLE, 0, self.match))

    def test_a_reinstall_after_a_delete_is_dated_afresh(self):
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.clock.advance(60)
        self.times.forget(1, LPM_TABLE, 0, self.match)
        self.times.record(1, LPM_TABLE, 0, self.match)

        self.assertAlmostEqual(self.age(), 0.0)

    def test_clearing_forgets_every_entry(self):
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.times.record(1, FIVE_TUPLE_TABLE, 100, self.match)
        self.assertEqual(len(self.times), 2)

        self.times.clear()

        self.assertEqual(len(self.times), 0)
        self.assertIsNone(self.age())

    def test_a_clock_that_went_backwards_reports_zero_rather_than_a_negative_age(self):
        # duration_sec is unsigned on the wire; a negative here arrives as billions of seconds.
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.clock.advance(-5)

        self.assertEqual(self.age(), 0.0)

    def test_the_wall_clock_time_is_derived_from_the_same_age(self):
        # Derived rather than stored: a second clock is a second answer, and the two disagree
        # the moment the system clock is stepped.
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.clock.advance(10)
        self.wall.advance(10)

        self.assertAlmostEqual(self.times.oldest_installed_at_epoch(), 1_700_000_000.0)

    def test_a_record_holding_nothing_has_no_wall_clock_time_either(self):
        self.assertIsNone(self.times.oldest_installed_at_epoch())

    def test_the_oldest_stamp_is_reported_not_the_newest(self):
        # 🔴 The direction that matters. This number answers "how far back does this record
        # reach", and the newest stamp answers the opposite question -- it would say the record
        # began a moment ago however long it had actually been keeping rules, and an operator
        # reading it would conclude every undated rule on the switch predates the proxy.
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.clock.advance(600)
        self.wall.advance(600)
        self.times.record(1, FIVE_TUPLE_TABLE, 100, self.match)

        self.assertAlmostEqual(self.times.oldest_installed_at_epoch(), 1_700_000_000.0)

    def test_forgetting_the_oldest_entry_moves_the_reach_forward(self):
        # The stamp is gone with the rule, so the record no longer reaches back to it.
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.clock.advance(600)
        self.wall.advance(600)
        self.times.record(1, FIVE_TUPLE_TABLE, 100, self.match)
        self.times.forget(1, LPM_TABLE, 0, self.match)

        self.assertAlmostEqual(self.times.oldest_installed_at_epoch(), 1_700_000_600.0)

    def test_a_clock_that_went_backwards_does_not_date_the_record_in_the_future(self):
        # Same clamp age_seconds applies, and for a reader that will subtract this from now().
        self.times.record(1, LPM_TABLE, 0, self.match)
        self.clock.advance(-5)

        self.assertAlmostEqual(self.times.oldest_installed_at_epoch(), 1_700_000_000.0)


# --- the write paths: only what the switch accepted ----------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheClientDatesWhatTheSwitchAcceptedTest(unittest.TestCase):
    """
    Every P4RuntimeClient write path, against the record it is supposed to keep.

    The assertions look the entry up the way the flow-stats poll does -- through
    `rule_install_times`, in the shape `read_table_entries` returns -- so a write path that
    records under a key of its own invention fails here rather than in production, where it
    would look exactly like bmv2's missing clock.
    """

    def setUp(self):
        self.clock = FakeClock()
        self.client = a_client(clock=self.clock)

    def age_of(self, entry):
        return self.client.rule_install_times.age_seconds(
            self.client.device_id, entry["table"], entry["priority"], entry["match"])

    def test_an_accepted_route_install_is_dated(self):
        self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.clock.advance(12)

        self.assertAlmostEqual(self.age_of(read_back_lpm()), 12.0)

    def test_a_refused_route_install_is_not_dated(self):
        # 🔴 Control. A stamp for a write the switch rejected dates a rule that is not on the
        # switch, and the next rule written to that destination inherits an age it never had.
        # The INSERT/MODIFY fallback means "refused" has to mean refused twice.
        client = a_client(stub=RecordingStub(
            write_error=FakeRpcError(grpc.StatusCode.UNKNOWN), always=True))

        self.assertFalse(client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3))
        self.assertIsNone(client.rule_install_times.age_seconds(
            1, LPM_TABLE, 0, read_back_lpm()["match"]))

    def test_an_insert_that_lands_as_a_modify_is_still_dated(self):
        # bmv2 answers UNKNOWN for a duplicate, and the client resolves it by retrying as MODIFY.
        # The rule is on the switch afterwards, so it has an install time.
        client = a_client(stub=RecordingStub(
            write_error=FakeRpcError(grpc.StatusCode.UNKNOWN), always=False))

        self.assertTrue(client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3))
        self.assertIsNotNone(client.rule_install_times.age_seconds(
            1, LPM_TABLE, 0, read_back_lpm()["match"]))

    def test_an_accepted_modify_dates_a_route_this_client_had_not_written(self):
        # A modify is also how an entry this client has never written first reaches the switch --
        # insert_ipv4_route falls back to MODIFY when bmv2 reports the entry already exists. So
        # `record` is called on the modify path too; it is only a no-op when a stamp is already
        # held.
        self.client.modify_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 9)

        self.assertIsNotNone(self.age_of(read_back_lpm()))

    def test_an_app_rerouting_a_destination_does_not_make_the_rule_look_new(self):
        # 🔴 Adam's ruling, 2026-09-08 (DECISIONS.md), AGAINST this agent's recommendation in
        # R3-G13-SUMMARY §7-1, which had this restarting the clock. The stamp is the FIRST
        # accepted write of the entry; a reroute -- same destination, different out-port -- is a
        # MODIFY, and OpenFlow's duration does not restart on a MODIFY. The P4 plane now answers
        # the same question OVS's own duration answers.
        #
        # The accepted cost, asserted here so nobody rediscovers it as a bug: a rule an app
        # REROUTED reads as old as the fabric, so an age-filtered residue scan will not see it.
        # It would not see it on OVS either. A rule an app ADDS is still visible -- that is
        # test_an_accepted_route_install_is_dated -- and so is one it deletes and reinstalls.
        self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.clock.advance(600)
        self.client.modify_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 9)

        self.assertAlmostEqual(self.age_of(read_back_lpm()), 600.0)

    def test_an_accepted_delete_takes_the_date_away(self):
        self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.assertTrue(self.client.delete_ipv4_route("10.0.0.4", 32))

        self.assertIsNone(self.age_of(read_back_lpm()))

    def test_a_refused_delete_keeps_the_date_because_the_rule_is_still_there(self):
        # 🔴 Control. Forgetting on a refused delete would leave a rule on the switch that this
        # proxy can no longer date -- residue it installed itself, reported as 0/0.
        self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.client.stub.write_error = FakeRpcError(grpc.StatusCode.INTERNAL)
        self.client.stub.always = True

        self.assertFalse(self.client.delete_ipv4_route("10.0.0.4", 32))
        self.assertIsNotNone(self.age_of(read_back_lpm()))

    def test_a_delete_of_something_already_gone_still_clears_the_date(self):
        self.client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.client.stub.write_error = FakeRpcError(grpc.StatusCode.NOT_FOUND)
        self.client.stub.always = True

        self.assertTrue(self.client.delete_ipv4_route("10.0.0.4", 32))
        self.assertIsNone(self.age_of(read_back_lpm()))

    def test_an_accepted_five_tuple_install_is_dated(self):
        keys = {"hdr.ipv4.srcAddr": "10.0.0.1", "hdr.ipv4.dstAddr": "10.0.0.4",
                "hdr.ipv4.protocol": 6, "meta.l4_dst_port": 80}
        self.client.insert_5tuple_rule(keys, 101, "00:00:00:00:00:04", 3)
        self.clock.advance(4)

        read_back = {
            "table": FIVE_TUPLE_TABLE, "priority": 101, "is_default": False,
            "match": {"hdr.ipv4.srcAddr": {"type": "ternary", "value": b"\x0a\x00\x00\x01",
                                           "mask": b"\xff\xff\xff\xff"},
                      "hdr.ipv4.dstAddr": {"type": "ternary", "value": b"\x0a\x00\x00\x04",
                                           "mask": b"\xff\xff\xff\xff"},
                      "hdr.ipv4.protocol": {"type": "ternary", "value": b"\x06", "mask": b"\xff"},
                      "meta.l4_dst_port": {"type": "ternary", "value": b"\x50",
                                           "mask": b"\xff\xff"}},
            "action": None,
        }

        self.assertAlmostEqual(self.age_of(read_back), 4.0)

    def test_a_five_tuple_delete_takes_its_date_away(self):
        keys = {"hdr.ipv4.dstAddr": "10.0.0.4", "hdr.ipv4.protocol": 6}
        self.client.insert_5tuple_rule(keys, 101, "00:00:00:00:00:04", 3)
        self.assertEqual(len(self.client.rule_install_times), 1)

        self.assertTrue(self.client.delete_5tuple_rule(keys, 101))

        self.assertEqual(len(self.client.rule_install_times), 0)

    def test_a_five_tuple_rule_at_another_priority_is_a_different_rule(self):
        keys = {"hdr.ipv4.dstAddr": "10.0.0.4"}
        self.client.insert_5tuple_rule(keys, 101, "00:00:00:00:00:04", 3)
        self.client.delete_5tuple_rule(keys, 102)

        self.assertEqual(len(self.client.rule_install_times), 1)

    def test_an_address_with_a_leading_zero_octet_is_found_after_bmv2_canonicalises_it(self):
        # 🔴 The join between the two sides, in the shape that breaks it. Written as four bytes,
        # read back as one; a key that compared raw bytes would report 0/0 for this rule -- and
        # 0/0 is the defect, so nothing downstream would look wrong.
        self.client.insert_ipv4_route("0.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.clock.advance(9)

        self.assertAlmostEqual(self.age_of(read_back_lpm(dst=b"\x04")), 9.0)

    def test_the_pipeline_push_forgets_every_rule_it_destroyed(self):
        # 🔴 Control. A VERIFY_AND_COMMIT SetForwardingPipelineConfig empties every table on the
        # switch (KNOWN-ISSUES A-4c). Keeping the stamps would date the refill by the wipe.
        handle, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(handle, "wb") as fh:
            fh.write(b"{}")
        self.addCleanup(os.unlink, path)
        client = a_client(clock=self.clock, json_path=path)
        client.insert_ipv4_route("10.0.0.4", 32, "00:00:00:00:00:04", 3)
        self.assertEqual(len(client.rule_install_times), 1)

        client.set_forwarding_pipeline_config()

        self.assertEqual(len(client.rule_install_times), 0)

    def test_the_pipeline_push_also_drops_the_row_count_that_record_is_reported_against(self):
        # 🔴 Control, and the half that is easy to leave behind. GET /p4/switch_state serves
        # `rules_timed` against `rules_total`, so a wipe that empties one and keeps the other
        # reports "this proxy dated none of the 40 rules on this switch" -- a sentence about
        # forty rules that no longer exist. None, until something counts again.
        handle, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(handle, "wb") as fh:
            fh.write(b"{}")
        self.addCleanup(os.unlink, path)
        client = a_client(clock=self.clock, json_path=path)
        client.read_table_entries()
        self.assertIsNotNone(client.last_table_read())

        client.set_forwarding_pipeline_config()

        self.assertIsNone(client.last_table_read())


# --- the wiring: the endpoint reads the client's own record --------------------------------


class FlowStatsClient:
    """A client double that has installed one rule and can be read back."""

    def __init__(self, entries, install_times):
        self._entries = entries
        self.rule_install_times = install_times

    def read_table_entries(self):
        return list(self._entries)


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheEndpointReadsTheClientsOwnRecordTest(unittest.TestCase):
    """
    /stats/flow/<dpid> must pass the record belonging to the client it just read.

    This is the shape of finding #71, where the rule journal had 33 green tests and no caller
    because every test injected the journal itself. An install record production never hands to
    the renderer is a record that works perfectly in the suite and reports 0/0 on the fabric --
    and 0/0 is exactly what the defect looked like, so nothing would say so.
    """

    def tearDown(self):
        api_routes.topology = None

    def build(self, dpid=7, age=12.0):
        clock = FakeClock()
        times = RuleInstallTimes(monotonic=clock)
        entry = read_back_lpm()
        times.record(dpid, entry["table"], entry["priority"], entry["match"])
        clock.advance(age)
        api_routes.topology = FakeTopology(
            switches={dpid: FlowStatsClient([entry], times)})
        return dpid

    def test_a_rule_the_client_installed_comes_back_with_its_age(self):
        dpid = self.build(age=32.0)

        body = api_routes.get_flow_stats(dpid)

        self.assertEqual(body[str(dpid)][0]["duration_sec"], 32)

    def test_a_switch_with_no_record_of_a_rule_still_answers_zero(self):
        # Not an error and not a refusal: a rule this proxy did not install is reported with the
        # age nobody knows, which is what this endpoint has always emitted.
        times = RuleInstallTimes(monotonic=FakeClock())
        api_routes.topology = FakeTopology(
            switches={7: FlowStatsClient([read_back_lpm()], times)})

        body = api_routes.get_flow_stats(7)

        self.assertEqual((body["7"][0]["duration_sec"], body["7"][0]["duration_nsec"]), (0, 0))

    def test_the_real_client_carries_a_record_for_the_endpoint_to_read(self):
        # The production object, not a double: if P4RuntimeClient stopped constructing one, the
        # endpoint above would raise on every poll rather than quietly report 0/0.
        client = a_client()
        self.assertIsInstance(client.rule_install_times, RuleInstallTimes)


if __name__ == "__main__":
    unittest.main(verbosity=2)
