"""
Tests for tools/twin_audit/twin_audit.py -- the twin lie detector's own logic: which flows
count as a claim, which host pairs get audited, and how the twin's integer addresses and
Mininet's process table are read.

[Co-developed with claude code -- Adam]

The criteria themselves are tested in test_twin_audit_criteria.py; this file stubs them out
and tests the reconciliation harness around them.

## Standard library only, and no contact with the outside world

Same rules as test_twin_audit_criteria.py: plain `python3`, stdlib only (enforced by
l1_unit_tests.sh), and every world-touching function in the criteria module is replaced
with a stub that raises unless the test installed it. twin_audit.py loads criteria.py by
path into its OWN module object, so the stubs are installed on `twin_audit.criteria` --
patching a separately-loaded copy would leave the real `urlopen` in place, which is the
kind of mistake that turns a unit test into a live probe.
"""

from __future__ import annotations

import importlib.util
import os
import unittest


def _load(module_name, relative_path):
    here = os.path.dirname(os.path.abspath(__file__))
    probe = here
    for _ in range(6):
        candidate = os.path.join(probe, relative_path)
        if os.path.isfile(candidate):
            spec = importlib.util.spec_from_file_location(module_name, candidate)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    raise AssertionError("could not locate %s from %s" % (relative_path, here))


twin_audit = _load("twin_audit_tool", os.path.join("tools", "twin_audit", "twin_audit.py"))
criteria = twin_audit.criteria

MOVING = criteria.MOVING
STILL = criteria.STILL
UNKNOWN = criteria.UNKNOWN


def flow(src_ip, dst_ip, rate=1000, stamp="2026-08-13 03:00:00"):
    return {
        "src_ip": src_ip,
        "dst_ip": dst_ip,
        twin_audit.RATE_FIELD: rate,
        "latest_sampled_time": stamp,
    }


class WorldFreeTestCase(unittest.TestCase):
    def setUp(self):
        self._saved = {name: getattr(criteria, name)
                       for name in ("run_command", "http_get_json", "sleep", "now")}

        def forbidden(name):
            def _boom(*args, **kwargs):
                raise AssertionError("unexpected call to %s%r" % (name, args))
            return _boom

        for name in self._saved:
            setattr(criteria, name, forbidden(name))
        criteria.sleep = lambda seconds: None
        criteria.now = lambda: 1000000.0
        self.cfg = twin_audit.AuditConfig(ps="ps", paths_url="http://paths.test",
                                          ndt_url="http://twin.test")

    def tearDown(self):
        for name, fn in self._saved.items():
            setattr(criteria, name, fn)


# --- what counts as a claim ----------------------------------------------------------


class ClaimTest(unittest.TestCase):
    def test_a_positive_rate_is_a_claim_of_activity(self):
        self.assertTrue(twin_audit.twin_claims_active(flow(1, 2, rate=9_000_000)))

    def test_a_zero_rate_is_not_a_claim(self):
        self.assertFalse(twin_audit.twin_claims_active(flow(1, 2, rate=0)))

    def test_a_missing_rate_field_is_not_a_claim(self):
        self.assertFalse(twin_audit.twin_claims_active({}))

    def test_a_non_numeric_rate_is_not_a_claim_rather_than_a_crash(self):
        self.assertFalse(twin_audit.twin_claims_active(flow(1, 2, rate="lots")))

    def test_the_claim_is_boolean_not_a_rate_comparison(self):
        # Scope decision: sFlow's 1/256 error floor (196*sqrt(1/c)) makes "wrong rate" and
        # "honestly sampled rate" inseparable, so this tool reads the field as a yes/no
        # claim and never compares its magnitude to anything.
        self.assertEqual(twin_audit.twin_claims_active(flow(1, 2, rate=1)),
                         twin_audit.twin_claims_active(flow(1, 2, rate=999_000_000)))


class FlowAgeTest(unittest.TestCase):
    def test_it_parses_the_documented_timestamp_format(self):
        import datetime
        stamp = "2026-08-13 03:00:00"
        base = datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S").timestamp()
        self.assertAlmostEqual(291.0, twin_audit.flow_age_s(flow(1, 2, stamp=stamp),
                                                            base + 291.0))

    def test_an_unparseable_timestamp_is_none_not_zero(self):
        # Zero would read as "sampled just now", i.e. the most reassuring possible answer
        # for the least trustworthy possible input.
        self.assertIsNone(twin_audit.flow_age_s(flow(1, 2, stamp="yesterday"), 0.0))

    def test_a_missing_timestamp_is_none(self):
        self.assertIsNone(twin_audit.flow_age_s({}, 0.0))


class FlowPairTest(unittest.TestCase):
    def test_addresses_come_out_in_the_documented_byte_order(self):
        self.assertEqual(("10.0.0.1", "10.0.0.2"),
                         twin_audit.flow_pair(flow(16777226, 33554442)))

    def test_a_record_without_addresses_is_skipped_not_fatal(self):
        self.assertIsNone(twin_audit.flow_pair({}))

    def test_a_junk_address_is_skipped_not_fatal(self):
        self.assertIsNone(twin_audit.flow_pair(flow("nope", 1)))


class DistinctPairsTest(unittest.TestCase):
    def test_bidirectional_records_collapse_to_one_pair(self):
        # Every channel in criteria.py already asks both ways, so auditing both records
        # separately would double the probe load for the same answer.
        pairs = twin_audit.distinct_pairs([flow(16777226, 33554442),
                                           flow(33554442, 16777226)])
        self.assertEqual(1, len(pairs))

    def test_separate_pairs_stay_separate(self):
        pairs = twin_audit.distinct_pairs([flow(16777226, 33554442),
                                           flow(16777226, 50331658)])
        self.assertEqual(2, len(pairs))

    def test_unparseable_records_are_dropped(self):
        self.assertEqual([], twin_audit.distinct_pairs([{}, {"src_ip": "x"}]))


# --- reading the environment ---------------------------------------------------------


class HostPidTest(WorldFreeTestCase):
    PS_OUTPUT = (
        "  PID COMMAND\n"
        " 1234 bash -c something unrelated\n"
        " 4001 /usr/bin/env mnexec -cd bash -ms mininet:h1\n"
        " 4002 /usr/bin/env mnexec -cd bash -ms mininet:h2\n"
        " 4003 /usr/bin/env mnexec -cd bash -ms mininet:s1\n"
    )

    def install(self, rc, stdout):
        self.argv = None

        def fake(argv, timeout):
            self.argv = argv
            return criteria.CommandResult(rc, stdout)

        criteria.run_command = fake

    def test_it_reads_the_mininet_process_tags(self):
        self.install(0, self.PS_OUTPUT)
        self.assertEqual({"h1": 4001, "h2": 4002, "s1": 4003},
                         twin_audit.list_host_pids(self.cfg))

    def test_untagged_processes_are_ignored(self):
        # Asserted on the PIDs, not the keys: dropping the mininet: filter would key that
        # unrelated bash line by its last word ("unrelated"), so a key-based assertion
        # stays green while the map has grown a PID that mnexec must never be pointed at.
        self.install(0, self.PS_OUTPUT)
        self.assertNotIn(1234, twin_audit.list_host_pids(self.cfg).values())

    def test_it_uses_the_same_signal_as_stack_sh(self):
        # stack.sh's count_mininet_procs matches $NF ~ /^mininet:/ and mnexec targets the
        # same processes; disagreeing with them would make this tool address the wrong PID.
        self.install(0, self.PS_OUTPUT)
        twin_audit.list_host_pids(self.cfg)
        self.assertEqual(["ps", "-eo", "pid,args"], self.argv)

    def test_no_mininet_is_an_empty_map_not_an_error(self):
        self.install(0, "  PID COMMAND\n 1 init\n")
        self.assertEqual({}, twin_audit.list_host_pids(self.cfg))

    def test_a_failed_ps_is_an_empty_map(self):
        self.install(1, "")
        self.assertEqual({}, twin_audit.list_host_pids(self.cfg))


class IpToHostNameTest(unittest.TestCase):
    def test_host_vertices_are_indexed_by_every_address_they_carry(self):
        graph = {"nodes": [
            {"vertex_type": 1, "device_name": "h9", "ip": [16777226, 33554442]},
        ]}
        self.assertEqual({"10.0.0.1": "h9", "10.0.0.2": "h9"},
                         twin_audit.ip_to_host_name(graph))

    def test_switch_vertices_are_not_hosts(self):
        # vertex_type 0 is a switch; pinging a switch's management IP would answer for
        # reasons that have nothing to do with the flow under audit.
        graph = {"nodes": [
            {"vertex_type": 0, "device_name": "s4", "ip": [168430090]},
            {"vertex_type": 1, "device_name": "h9", "ip": [16777226]},
        ]}
        self.assertEqual({"10.0.0.1": "h9"}, twin_audit.ip_to_host_name(graph))

    def test_string_addresses_are_accepted_too(self):
        # doc/2026-01-02_ndt_api.md calls this field dotted text in one paragraph and shows integers
        # in its own sample; the C++ type is vector<uint32_t>, so integers are what ship.
        # Both are handled rather than guessed at -- see the report's open-questions list.
        graph = {"nodes": [{"vertex_type": 1, "device_name": "h9", "ip": ["10.0.0.1"]}]}
        self.assertEqual({"10.0.0.1": "h9"}, twin_audit.ip_to_host_name(graph))

    def test_malformed_nodes_do_not_abort_the_map(self):
        graph = {"nodes": ["junk", {"vertex_type": 1}, {"vertex_type": 1,
                                                        "device_name": "h1",
                                                        "ip": [16777226]}]}
        self.assertEqual({"10.0.0.1": "h1"}, twin_audit.ip_to_host_name(graph))

    def test_an_empty_graph_is_an_empty_map(self):
        self.assertEqual({}, twin_audit.ip_to_host_name({}))


class BuildTargetsTest(unittest.TestCase):
    def test_pids_are_attached_from_the_resolved_maps(self):
        targets = twin_audit.build_targets([("10.0.0.1", "10.0.0.2")],
                                           {"10.0.0.1": "h1", "10.0.0.2": "h2"},
                                           {"h1": 4001, "h2": 4002})
        self.assertEqual(4001, targets[0].src_pid)
        self.assertEqual(4002, targets[0].dst_pid)

    def test_an_unresolved_host_leaves_the_pid_none_rather_than_guessing(self):
        targets = twin_audit.build_targets([("10.0.0.1", "10.0.0.9")],
                                           {"10.0.0.1": "h1"}, {"h1": 4001})
        self.assertEqual(4001, targets[0].src_pid)
        self.assertIsNone(targets[0].dst_pid)


# --- the audit itself ----------------------------------------------------------------


class AuditTest(WorldFreeTestCase):
    def install_verdict(self, verdict):
        self.evaluated = []

        def fake(cfg, target, checks=None):
            self.evaluated.append(target)
            return verdict, [criteria.Observation("ping", verdict, "stub")]

        criteria.evaluate = fake

    def setUp(self):
        super().setUp()
        self._real_evaluate = criteria.evaluate

    def tearDown(self):
        criteria.evaluate = self._real_evaluate
        super().tearDown()

    def test_the_2026_08_13_shape_is_reported_as_lying(self):
        self.install_verdict(STILL)
        findings = twin_audit.audit(self.cfg, [flow(16777226, 33554442, rate=9_000_000)],
                                    {}, {})
        self.assertEqual(1, len(findings))
        self.assertEqual(criteria.LYING, findings[0].reconciliation)
        self.assertTrue(findings[0].is_contradiction)

    def test_a_healthy_flow_is_not_a_contradiction(self):
        self.install_verdict(MOVING)
        findings = twin_audit.audit(self.cfg, [flow(16777226, 33554442)], {}, {})
        self.assertEqual(criteria.AGREES, findings[0].reconciliation)
        self.assertFalse(findings[0].is_contradiction)

    def test_flows_the_twin_calls_idle_are_not_probed(self):
        # The audit is of the twin's *claims*. Probing every idle record would multiply the
        # ping load by the size of the flow table for no added evidence.
        self.install_verdict(STILL)
        twin_audit.audit(self.cfg, [flow(16777226, 33554442, rate=0)], {}, {})
        self.assertEqual([], self.evaluated)

    def test_an_explicit_pair_is_audited_even_with_no_twin_flow(self):
        # This is the entry point faults.sh uses: there is no twin claim to read during an
        # injection round, so the caller asserts the pair directly.
        self.install_verdict(STILL)
        findings = twin_audit.audit(self.cfg, [], {}, {},
                                    only_pair=("10.0.0.1", "10.0.0.2"))
        self.assertEqual(1, len(findings))
        self.assertEqual(criteria.LYING, findings[0].reconciliation)

    def test_the_twins_own_sample_age_is_carried_into_the_finding(self):
        self.install_verdict(STILL)
        import datetime
        stamp = "2026-08-13 03:00:00"
        criteria.now = lambda: (datetime.datetime.strptime(
            stamp, "%Y-%m-%d %H:%M:%S").timestamp() + 291.0)
        findings = twin_audit.audit(
            self.cfg, [flow(16777226, 33554442, stamp=stamp)], {}, {})
        self.assertAlmostEqual(291.0, findings[0].ages[0])

    def test_bidirectional_records_are_audited_once(self):
        self.install_verdict(MOVING)
        twin_audit.audit(self.cfg, [flow(16777226, 33554442),
                                    flow(33554442, 16777226)], {}, {})
        self.assertEqual(1, len(self.evaluated))


class ExitCodeTest(unittest.TestCase):
    def make(self, reconciliation):
        target = criteria.Target("10.0.0.1", "10.0.0.2")
        return twin_audit.Finding(target, True, STILL, reconciliation, [], [])

    def test_a_lie_exits_one(self):
        self.assertEqual(1, twin_audit.exit_code_for([self.make(criteria.LYING)]))

    def test_a_blind_spot_also_exits_one(self):
        self.assertEqual(1, twin_audit.exit_code_for([self.make(criteria.BLIND)]))

    def test_agreement_exits_zero(self):
        self.assertEqual(0, twin_audit.exit_code_for([self.make(criteria.AGREES)]))

    def test_nothing_to_audit_exits_zero(self):
        self.assertEqual(0, twin_audit.exit_code_for([]))

    def test_all_undecided_exits_three(self):
        self.assertEqual(3, twin_audit.exit_code_for([self.make(criteria.INCONCLUSIVE),
                                                      self.make(criteria.DISPUTED)]))

    def test_one_decided_pair_beats_the_undecided_ones(self):
        self.assertEqual(0, twin_audit.exit_code_for([self.make(criteria.INCONCLUSIVE),
                                                      self.make(criteria.AGREES)]))

    def test_a_lie_beats_everything(self):
        self.assertEqual(1, twin_audit.exit_code_for([self.make(criteria.INCONCLUSIVE),
                                                      self.make(criteria.LYING)]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
