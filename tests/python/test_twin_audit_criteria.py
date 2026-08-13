"""
Tests for tools/twin_audit/criteria.py -- the three-channel quorum shared by the twin lie
detector and the L5 fault-injection harness.

[Co-developed with claude code -- Adam]

## The scenario these encode

2026-08-13 overnight OVS round: the twin reported a flow "flowing at 9-15 Mbps" with
edges_up 287/288 while that flow had moved zero packets for 291 s. Every watched signal
agreed with the twin because they all descend from the same ingest. `LiveP0Shape` below is
that exact state, and it must come out LYING.

## Why nothing here touches the network

`WorldFreeTestCase` replaces all four of criteria.py's world functions (`run_command`,
`http_get_json`, `sleep`, `now`) with stubs that raise on an unexpected call, and restores
them afterwards. So a check that grew a new outbound call would fail loudly here rather
than quietly reaching a live testbed -- which matters because this file was written while
a live round owned the machine, and a stray `ping` or `urlopen` would have corrupted it.
It also means the suite takes no wall-clock time despite the two-sample counter gap.

## Why the module is loaded by path

tools/ is not a package and is not on sys.path. The repo root is found by walking up from
this file looking for tools/twin_audit/criteria.py, so the file works unchanged from
tests/python/ or from p4_proxy/tests/ -- moving it is a pure `git mv`.

## Standard library only

Everything in tests/python runs under plain `python3` and may depend on nothing outside
the standard library; l1_unit_tests.sh enforces that and it has already caught one file
importing networkx. criteria.py is itself stdlib-only, which is why this test can live
here at all.
"""

from __future__ import annotations

import importlib.util
import os
import unittest


def _load_criteria():
    here = os.path.dirname(os.path.abspath(__file__))
    probe = here
    for _ in range(6):
        candidate = os.path.join(probe, "tools", "twin_audit", "criteria.py")
        if os.path.isfile(candidate):
            spec = importlib.util.spec_from_file_location("twin_audit_criteria", candidate)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    raise AssertionError("could not locate tools/twin_audit/criteria.py from " + here)


criteria = _load_criteria()

MOVING = criteria.MOVING
STILL = criteria.STILL
UNKNOWN = criteria.UNKNOWN
DISPUTED = criteria.DISPUTED
INCONCLUSIVE = criteria.INCONCLUSIVE


def obs(check, verdict):
    return criteria.Observation(check, verdict, "")


class WorldFreeTestCase(unittest.TestCase):
    """Base class: no test may reach the network, the filesystem or the clock."""

    def setUp(self):
        self._saved = {
            "run_command": criteria.run_command,
            "http_get_json": criteria.http_get_json,
            "sleep": criteria.sleep,
            "now": criteria.now,
        }

        def forbidden(name):
            def _boom(*args, **kwargs):
                raise AssertionError("unexpected call to %s%r -- this test must not touch "
                                     "the outside world" % (name, args))
            return _boom

        for name in self._saved:
            setattr(criteria, name, forbidden(name))
        self.slept = []
        criteria.sleep = self.slept.append
        self.cfg = criteria.Config(ping="ping", mnexec="sudo -n mnexec", cat="cat",
                                   paths_url="http://paths.test", ping_count=3,
                                   gap_s=2.0, min_growth=1, timeout_s=10.0)

    def tearDown(self):
        for name, fn in self._saved.items():
            setattr(criteria, name, fn)


# --- the byte-order trap -------------------------------------------------------------


class IpConversionTest(unittest.TestCase):
    """doc/2026-01-02_ndt_api.md: the integer IP fields hold s_addr, i.e. the address already in
    network byte order, so they must be unpacked little-endian on this host. Getting this
    backwards silently reverses every address in the report and the tool then audits host
    pairs that do not exist."""

    def test_the_documented_example_converts_to_the_documented_address(self):
        # 2026-01-02_ndt_api.md states in as many words: 16777226 is 10.0.0.1, not 1.0.0.10.
        self.assertEqual("10.0.0.1", criteria.ip_int_to_str(16777226))

    def test_the_host_order_integer_is_a_different_address(self):
        # The same doc: 167772161 would be 10.0.0.1 if these were host order. They are not.
        self.assertNotEqual("10.0.0.1", criteria.ip_int_to_str(167772161))
        self.assertEqual("1.0.0.10", criteria.ip_int_to_str(167772161))

    def test_the_api_sample_payload_addresses(self):
        # Both taken from the get_detected_flow_data example in doc/2026-01-02_ndt_api.md.
        self.assertEqual("192.168.1.1", criteria.ip_int_to_str(16885952))
        self.assertEqual("192.168.1.81", criteria.ip_int_to_str(1359063232))

    def test_a_signed_reading_of_a_high_address_is_masked_not_a_crash(self):
        # A high address read as a signed 32-bit integer arrives negative, and struct.pack
        # raises on it. Masking turns that back into the address; without the mask the
        # whole audit dies on one unusual record. (255.255.255.255 alone proves nothing
        # here -- it is symmetric under byte reversal, so it survives every byte-order
        # mistake this function can make.)
        self.assertEqual("255.255.255.255", criteria.ip_int_to_str(4294967295))
        self.assertEqual("255.255.255.255", criteria.ip_int_to_str(-1))
        self.assertEqual("10.0.0.1", criteria.ip_int_to_str(16777226 - 2 ** 32))


# --- namespace wrapping --------------------------------------------------------------


class NamespaceWrappingTest(WorldFreeTestCase):
    def test_no_pid_means_the_command_runs_here_unwrapped(self):
        self.assertEqual(["ping", "10.0.0.1"],
                         criteria._in_namespace(self.cfg, None, ["ping", "10.0.0.1"]))

    def test_a_pid_is_passed_to_mnexec_dash_a(self):
        # mnexec -a takes a PID. Passing a *name* is a documented past bug in this repo
        # (doc/2026-07-27_p4_bmv2_support_plan.md item 6) -- the command silently does nothing.
        self.assertEqual(["sudo", "-n", "mnexec", "-a", "4242", "ping", "10.0.0.1"],
                         criteria._in_namespace(self.cfg, 4242, ["ping", "10.0.0.1"]))


# --- check 1: bidirectional ping -----------------------------------------------------


class PingCheckTest(WorldFreeTestCase):
    def install(self, answers):
        """answers: dict mapping destination IP -> rc (or None for 'could not run')."""
        self.calls = []

        def fake(argv, timeout):
            self.calls.append(argv)
            dest = argv[-1]
            rc = answers[dest]
            return criteria.CommandResult(rc)

        criteria.run_command = fake

    def target(self):
        return criteria.Target("10.0.0.1", "10.0.0.2", src_pid=11, dst_pid=22)

    def test_both_directions_answer_is_moving(self):
        self.install({"10.0.0.2": 0, "10.0.0.1": 0})
        result = criteria.check_ping(self.cfg, self.target())
        self.assertEqual(MOVING, result.verdict)

    def test_it_actually_probes_both_directions(self):
        # The whole reason this check exists: the runbook measured 3 of 6 host pairs taking
        # different switches each way, so a one-way probe cannot decide reachability.
        self.install({"10.0.0.2": 0, "10.0.0.1": 0})
        criteria.check_ping(self.cfg, self.target())
        self.assertEqual(2, len(self.calls))
        self.assertEqual("10.0.0.2", self.calls[0][-1])
        self.assertEqual("10.0.0.1", self.calls[1][-1])
        # ...and each from the right end.
        self.assertIn("11", self.calls[0])
        self.assertIn("22", self.calls[1])

    def test_neither_direction_answers_is_still(self):
        self.install({"10.0.0.2": 1, "10.0.0.1": 1})
        result = criteria.check_ping(self.cfg, self.target())
        self.assertEqual(STILL, result.verdict)

    def test_only_the_forward_direction_answers_is_still_and_says_so(self):
        self.install({"10.0.0.2": 0, "10.0.0.1": 1})
        result = criteria.check_ping(self.cfg, self.target())
        self.assertEqual(STILL, result.verdict)
        self.assertIn("asymmetric", result.detail)
        self.assertIn("reverse", result.detail)

    def test_only_the_reverse_direction_answers_is_still_and_says_so(self):
        self.install({"10.0.0.2": 1, "10.0.0.1": 0})
        result = criteria.check_ping(self.cfg, self.target())
        self.assertEqual(STILL, result.verdict)
        self.assertIn("asymmetric", result.detail)
        self.assertIn("forward", result.detail)

    def test_a_ping_that_cannot_run_is_unknown_not_still(self):
        # "the probe failed" must never read as "the link is dead", or a missing binary or
        # a revoked sudo grant would manufacture a link failure out of nothing.
        self.install({"10.0.0.2": None, "10.0.0.1": 0})
        result = criteria.check_ping(self.cfg, self.target())
        self.assertEqual(UNKNOWN, result.verdict)


class ProbeShapeTest(WorldFreeTestCase):
    """The ping argv is load-bearing: count, interval and timeout form one budget.

    [Co-developed with claude code -- Adam]
    faults.txt L-3 injects 30% loss on both ends and expects "moving". One echo survives
    that link with p = 0.49, so at the old count of three the whole probe died with
    p = 0.51^3 ~= 13% per direction and the harness's verdict was a coin toss stacked
    only 7:1 in favour of the truth. These tests pin the two knobs that fix it and the
    arithmetic that keeps the fix from becoming a different bug.
    """

    def captured_probe(self, cfg):
        calls = []

        def fake(argv, timeout):
            calls.append((list(argv), timeout))
            return criteria.CommandResult(0)

        criteria.run_command = fake
        criteria.ping_once(cfg, None, "10.0.0.2")
        return calls[0]

    def test_the_echo_count_comes_from_the_config_not_a_literal(self):
        # setUp's config says 3; a hardcoded count would ignore it and make
        # TWIN_AUDIT_PING_COUNT a lie.
        argv, _ = self.captured_probe(self.cfg)
        self.assertEqual("3", argv[argv.index("-c") + 1])

    def test_the_default_count_makes_a_gray_link_flip_negligible(self):
        # 0.51^10 < 0.2% per direction, against 13% at the old default of three. The
        # default is what faults.sh runs with, so it is the default that must survive L-3.
        self.assertGreaterEqual(criteria.Config().ping_count, 10)

    def test_the_interval_is_pinned_at_the_unprivileged_floor(self):
        # Without -i, ping sends one echo per second and ten echoes brush against
        # run_command's timeout; 0.2 s is the tightest interval iputils allows without
        # privileges, in and out of a namespace alike.
        argv, _ = self.captured_probe(self.cfg)
        self.assertEqual("0.2", argv[argv.index("-i") + 1])

    def test_the_probe_budget_fits_inside_its_own_timeout(self):
        # count x interval + the trailing -W wait must sit inside the timeout handed to
        # run_command, or a raised count converts flaky STILL into flaky UNKNOWN. Parsed
        # from the argv actually built, so any future change to count, interval, -W or
        # timeout_s that breaks the budget turns this red before a live run finds it.
        argv, timeout = self.captured_probe(criteria.Config())
        count = int(argv[argv.index("-c") + 1])
        interval = float(argv[argv.index("-i") + 1])
        wait = float(argv[argv.index("-W") + 1])
        self.assertLess(count * interval + wait, timeout,
                        "the probe cannot finish inside the timeout that will kill it")


# --- check 2: control-plane path count -----------------------------------------------


def path(*nodes):
    """all_destination_paths shape: a list of hops, each hop's [0] being the node."""
    return [[n, 1] for n in nodes]


class PathCheckTest(WorldFreeTestCase):
    def install(self, payload):
        self.urls = []

        def fake(url, timeout):
            self.urls.append(url)
            return payload

        criteria.http_get_json = fake

    def target(self):
        return criteria.Target("10.0.0.1", "10.0.0.2")

    def test_a_path_each_way_is_moving(self):
        self.install({"all_destination_paths": [
            path("10.0.0.1", "s1", "10.0.0.2"),
            path("10.0.0.2", "s1", "10.0.0.1"),
        ]})
        self.assertEqual(MOVING, criteria.check_paths(self.cfg, self.target()).verdict)

    def test_no_path_either_way_is_still(self):
        self.install({"all_destination_paths": [path("10.0.0.3", "s1", "10.0.0.4")]})
        result = criteria.check_paths(self.cfg, self.target())
        self.assertEqual(STILL, result.verdict)
        self.assertIn("no path either way", result.detail)

    def test_a_path_one_way_only_is_still(self):
        # The 2026-08-13 P0's exact graph state: one EventLinkDelete fired, the reverse
        # edge stayed, and the DiGraph was asymmetric permanently. Reporting that as
        # "reachable" is how the twin got away with it for 291 s.
        self.install({"all_destination_paths": [path("10.0.0.1", "s1", "10.0.0.2")]})
        result = criteria.check_paths(self.cfg, self.target())
        self.assertEqual(STILL, result.verdict)
        self.assertIn("asymmetric", result.detail)

    def test_an_unreadable_endpoint_is_unknown_not_still(self):
        self.install(None)
        self.assertEqual(UNKNOWN, criteria.check_paths(self.cfg, self.target()).verdict)

    def test_a_payload_without_the_key_is_unknown(self):
        self.install({"something_else": []})
        self.assertEqual(UNKNOWN, criteria.check_paths(self.cfg, self.target()).verdict)

    def test_it_reads_the_documented_endpoint(self):
        self.install({"all_destination_paths": []})
        criteria.check_paths(self.cfg, self.target())
        self.assertEqual(["http://paths.test/ryu_server/all_destination_paths"], self.urls)

    def test_malformed_paths_are_skipped_not_counted(self):
        self.install({"all_destination_paths": [
            "not a path", [], [["10.0.0.1", 1]],
            path("10.0.0.1", "10.0.0.2"), path("10.0.0.2", "10.0.0.1"),
        ]})
        self.assertEqual(MOVING, criteria.check_paths(self.cfg, self.target()).verdict)


# --- check 3: peer counter growth ----------------------------------------------------


def procnetdev(rx):
    return ("Inter-|   Receive\n"
            " face |bytes    packets errs\n"
            "    lo:  100  9999  0\n"
            "  h2-eth0:  4242  %d  0\n" % rx)


class CounterCheckTest(WorldFreeTestCase):
    def install(self, samples):
        """samples: successive /proc/net/dev outputs, or None for an unreadable read."""
        self.samples = list(samples)
        self.reads = 0

        self.probes = 0

        def fake(argv, timeout):
            # check_counters now sends its own probe traffic between the two samples, so the
            # stub has to tell a counter read from a ping rather than counting calls.
            if "/proc/net/dev" not in " ".join(argv):
                self.probes += 1
                return criteria.CommandResult(self.probe_rc)
            sample = self.samples[self.reads]
            self.reads += 1
            if sample is None:
                return criteria.CommandResult(1, "", "no such process")
            return criteria.CommandResult(0, sample)

        criteria.run_command = fake

    probe_rc = 0

    def target(self):
        return criteria.Target("10.0.0.1", "10.0.0.2", src_pid=11, dst_pid=22)

    def test_it_generates_its_own_probe_traffic_between_the_samples(self):
        # Live 2026-08-13: as a passive observer this channel read STILL on a perfectly
        # healthy idle link, which paired with ping=MOVING into a permanent DISPUTED and
        # stopped the fault harness from ever injecting. Sending between the samples turns
        # the channel into an experiment: "did the packets I just sent arrive".
        self.install([procnetdev(1000), procnetdev(1003)])
        result = criteria.check_counters(self.cfg, self.target())
        self.assertEqual(MOVING, result.verdict)
        self.assertEqual(1, self.probes, "exactly one probe, between the two samples")

    def test_a_probe_that_cannot_run_is_unknown_not_still(self):
        # Without probe traffic the gap measures background noise only, which is the passive
        # trap again -- so say so instead of reporting the flow as dead.
        self.probe_rc = None
        self.install([procnetdev(1000), procnetdev(1000)])
        result = criteria.check_counters(self.cfg, self.target())
        self.assertEqual(UNKNOWN, result.verdict)
        self.assertIn("probe", result.detail)

    def test_a_growing_counter_is_moving(self):
        self.install([procnetdev(1000), procnetdev(1400)])
        result = criteria.check_counters(self.cfg, self.target())
        self.assertEqual(MOVING, result.verdict)

    def test_a_large_but_frozen_counter_is_still(self):
        # THE point of this channel. A non-zero counter proves packets moved at some point
        # in the past; the 291-second flow had a huge, completely static counter. Only
        # movement between two samples proves movement now.
        self.install([procnetdev(9_000_000), procnetdev(9_000_000)])
        result = criteria.check_counters(self.cfg, self.target())
        self.assertEqual(STILL, result.verdict)

    def test_it_samples_twice_with_a_gap(self):
        self.install([procnetdev(1), procnetdev(2)])
        criteria.check_counters(self.cfg, self.target())
        self.assertEqual(2, self.reads)
        self.assertEqual([self.cfg.gap_s], self.slept)

    def test_growth_below_the_floor_is_still(self):
        self.cfg.min_growth = 10
        self.install([procnetdev(100), procnetdev(105)])
        self.assertEqual(STILL, criteria.check_counters(self.cfg, self.target()).verdict)

    def test_growth_at_the_floor_is_moving(self):
        self.cfg.min_growth = 10
        self.install([procnetdev(100), procnetdev(110)])
        self.assertEqual(MOVING, criteria.check_counters(self.cfg, self.target()).verdict)

    def test_an_unreadable_counter_is_unknown_not_still(self):
        self.install([None])
        self.assertEqual(UNKNOWN, criteria.check_counters(self.cfg, self.target()).verdict)

    def test_an_unreadable_resample_is_unknown_not_still(self):
        self.install([procnetdev(1), None])
        self.assertEqual(UNKNOWN, criteria.check_counters(self.cfg, self.target()).verdict)

    def test_a_counter_that_went_backwards_is_unknown(self):
        # The interface was reset or the far end was replaced between samples: this channel
        # lost track of what it was measuring, which is not evidence of stillness.
        self.install([procnetdev(5000), procnetdev(10)])
        result = criteria.check_counters(self.cfg, self.target())
        self.assertEqual(UNKNOWN, result.verdict)
        self.assertIn("backwards", result.detail)


class ReadRxPacketsTest(WorldFreeTestCase):
    def install(self, rc, stdout):
        self.argv = []

        def fake(argv, timeout):
            self.argv = argv
            return criteria.CommandResult(rc, stdout)

        criteria.run_command = fake

    def test_it_sums_real_interfaces_and_skips_loopback(self):
        self.install(0, procnetdev(777))
        self.assertEqual(777, criteria.read_rx_packets(self.cfg, 22))

    def test_it_sums_several_interfaces(self):
        self.install(0, "  a1:  1 10 0\n  a2:  1 25 0\n")
        self.assertEqual(35, criteria.read_rx_packets(self.cfg, None))

    def test_a_failed_read_is_none(self):
        self.install(1, "")
        self.assertIsNone(criteria.read_rx_packets(self.cfg, 22))

    def test_a_header_only_file_is_none_rather_than_zero(self):
        # Zero would be a legitimate-looking "no packets"; None routes to UNKNOWN instead.
        self.install(0, "Inter-|   Receive\n face |bytes packets\n")
        self.assertIsNone(criteria.read_rx_packets(self.cfg, 22))

    def test_it_reads_proc_net_dev_in_the_peer_namespace(self):
        self.install(0, procnetdev(1))
        criteria.read_rx_packets(self.cfg, 22)
        self.assertIn("/proc/net/dev", self.argv)
        self.assertEqual(["sudo", "-n", "mnexec", "-a", "22", "cat", "/proc/net/dev"],
                         self.argv)


# --- the quorum ----------------------------------------------------------------------


class CombineTest(unittest.TestCase):
    def test_two_agreeing_still_channels_are_a_verdict(self):
        self.assertEqual(STILL, criteria.combine(
            [obs("ping", STILL), obs("paths", UNKNOWN), obs("counters", STILL)]))

    def test_two_agreeing_moving_channels_are_a_verdict(self):
        self.assertEqual(MOVING, criteria.combine(
            [obs("ping", MOVING), obs("paths", UNKNOWN), obs("counters", MOVING)]))

    def test_a_claim_channel_cannot_supply_a_quorum(self):
        # paths reads the controller's own belief, so ping+paths is one witness and one
        # defendant, not two witnesses. Without counters there is nothing to decide with.
        self.assertEqual(INCONCLUSIVE, criteria.combine(
            [obs("ping", STILL), obs("paths", STILL), obs("counters", UNKNOWN)]))

    def test_a_claim_channel_cannot_create_a_dispute(self):
        # The founding case: both witnesses say still, the controller insists otherwise.
        # That is the finding, not a tie.
        self.assertEqual(STILL, criteria.combine(
            [obs("ping", STILL), obs("paths", MOVING), obs("counters", STILL)]))

    def test_one_channel_alone_decides_nothing(self):
        # "單一來源會被騙" -- this repo has been fooled by a lone signal repeatedly.
        self.assertEqual(INCONCLUSIVE, criteria.combine(
            [obs("ping", STILL), obs("paths", UNKNOWN), obs("counters", UNKNOWN)]))
        self.assertEqual(INCONCLUSIVE, criteria.combine(
            [obs("ping", MOVING), obs("paths", UNKNOWN), obs("counters", UNKNOWN)]))

    def test_any_dissent_is_disputed_even_when_outnumbered(self):
        # Two beating one is not a majority verdict here: three independent observers of
        # the same network disagreeing means one of them is broken, and that is worth
        # surfacing rather than voting away.
        self.assertEqual(DISPUTED, criteria.combine(
            [obs("ping", STILL), obs("paths", STILL), obs("counters", MOVING)]))
        self.assertEqual(DISPUTED, criteria.combine(
            [obs("ping", MOVING), obs("paths", MOVING), obs("counters", STILL)]))

    def test_all_unknown_is_inconclusive(self):
        self.assertEqual(INCONCLUSIVE, criteria.combine(
            [obs("ping", UNKNOWN), obs("paths", UNKNOWN), obs("counters", UNKNOWN)]))

    def test_no_observations_at_all_is_inconclusive(self):
        self.assertEqual(INCONCLUSIVE, criteria.combine([]))

    def test_the_quorum_is_two(self):
        self.assertEqual(2, criteria.QUORUM)


# --- the check registry, including the reserved slot ---------------------------------


class RegistryTest(unittest.TestCase):
    def test_the_three_implemented_channels_are_registered_in_order(self):
        self.assertEqual(["ping", "paths", "counters"], list(criteria.CHECKS))

    def test_path_reconciliation_is_declared_reserved(self):
        # The interface is reserved this round, not implemented -- and it is registered
        # rather than merely mentioned so adding it later is one line here.
        self.assertIn("path_match", criteria.RESERVED_CHECKS)
        self.assertNotIn("path_match", criteria.CHECKS)

    def test_asking_for_the_reserved_check_refuses_loudly(self):
        # It must not quietly return UNKNOWN: that would look implemented in the output.
        with self.assertRaises(NotImplementedError):
            criteria.resolve_checks(["path_match"])

    def test_calling_the_reserved_check_directly_also_refuses(self):
        with self.assertRaises(NotImplementedError):
            criteria.check_path_match(None, None)

    def test_an_unknown_check_is_a_different_error_from_a_reserved_one(self):
        with self.assertRaises(KeyError):
            criteria.resolve_checks(["pnig"])

    def test_the_default_selection_is_every_implemented_check(self):
        self.assertEqual(["ping", "paths", "counters"],
                         list(criteria.resolve_checks(None)))

    def test_a_subset_can_be_selected(self):
        self.assertEqual(["paths"], list(criteria.resolve_checks(["paths"])))


# --- reconciliation against the twin's claim -----------------------------------------


class ReconcileTest(unittest.TestCase):
    def test_active_claim_against_a_still_network_is_lying(self):
        self.assertEqual(criteria.LYING, criteria.reconcile(True, STILL))

    def test_no_claim_against_a_moving_network_is_blind(self):
        self.assertEqual(criteria.BLIND, criteria.reconcile(False, MOVING))

    def test_agreement_both_ways(self):
        self.assertEqual(criteria.AGREES, criteria.reconcile(True, MOVING))
        self.assertEqual(criteria.AGREES, criteria.reconcile(False, STILL))

    def test_disputed_and_inconclusive_pass_through_unchanged(self):
        # A twin claim cannot be judged against evidence that does not agree with itself.
        for claim in (True, False):
            self.assertEqual(DISPUTED, criteria.reconcile(claim, DISPUTED))
            self.assertEqual(INCONCLUSIVE, criteria.reconcile(claim, INCONCLUSIVE))


# --- end to end, on the shape that actually happened ---------------------------------


class LiveP0Shape(WorldFreeTestCase):
    """2026-08-13 OVS round, reproduced through the stubs: the twin says 9-15 Mbps, the
    network has moved nothing for 291 s."""

    def install(self, ping_rc, paths_payload, rx_first, rx_second):
        state = {"pings": 0, "reads": 0}

        def fake_cmd(argv, timeout):
            if "/proc/net/dev" in argv:
                rx = rx_first if state["reads"] == 0 else rx_second
                state["reads"] += 1
                return criteria.CommandResult(0, procnetdev(rx))
            state["pings"] += 1
            return criteria.CommandResult(ping_rc)

        criteria.run_command = fake_cmd
        criteria.http_get_json = lambda url, timeout: paths_payload

    def test_the_flow_the_twin_swore_was_flowing_comes_out_lying(self):
        self.install(ping_rc=1, paths_payload={"all_destination_paths": []},
                     rx_first=9_000_000, rx_second=9_000_000)
        target = criteria.Target("10.0.0.1", "10.0.0.2", src_pid=11, dst_pid=22)
        verdict, observations = criteria.evaluate(self.cfg, target)
        self.assertEqual(STILL, verdict)
        self.assertEqual([STILL, STILL, STILL], [o.verdict for o in observations])
        self.assertEqual(criteria.LYING, criteria.reconcile(True, verdict))

    def test_a_genuinely_healthy_flow_comes_out_agreeing(self):
        self.install(ping_rc=0, paths_payload={"all_destination_paths": [
            path("10.0.0.1", "s1", "10.0.0.2"), path("10.0.0.2", "s1", "10.0.0.1")]},
            rx_first=1000, rx_second=1500)
        target = criteria.Target("10.0.0.1", "10.0.0.2", src_pid=11, dst_pid=22)
        verdict, _ = criteria.evaluate(self.cfg, target)
        self.assertEqual(MOVING, verdict)
        self.assertEqual(criteria.AGREES, criteria.reconcile(True, verdict))

    def test_a_control_plane_that_still_advertises_a_dead_link_is_caught_lying(self):
        # The exact shape of both incidents: the control plane keeps advertising the route
        # while the data plane carries nothing. Measured live 2026-08-13 with h1's access
        # link cut -- ping still, counters still, paths moving. Reported as DISPUTED (exit 0)
        # by the first version, which would have missed the case the tool exists for. The
        # controller's belief is the thing under audit; it does not get to outvote the two
        # channels that went and looked.
        self.install(ping_rc=1, paths_payload={"all_destination_paths": [
            path("10.0.0.1", "s1", "10.0.0.2"), path("10.0.0.2", "s1", "10.0.0.1")]},
            rx_first=500, rx_second=500)
        target = criteria.Target("10.0.0.1", "10.0.0.2", src_pid=11, dst_pid=22)
        verdict, observations = criteria.evaluate(self.cfg, target)
        self.assertEqual(STILL, verdict)
        self.assertEqual(criteria.LYING, criteria.reconcile(True, verdict))
        self.assertEqual(MOVING, [o for o in observations if o.check == "paths"][0].verdict,
                         "the contradicting claim must still be reported, just not counted")


class ExitCodeContractTest(unittest.TestCase):
    """faults.sh branches on these numbers; changing one silently changes the harness."""

    def test_the_documented_exit_codes(self):
        self.assertEqual(0, criteria.EXIT_CODES[MOVING])
        self.assertEqual(1, criteria.EXIT_CODES[STILL])
        self.assertEqual(3, criteria.EXIT_CODES[INCONCLUSIVE])
        self.assertEqual(4, criteria.EXIT_CODES[DISPUTED])

    def test_two_is_left_free_for_usage_errors(self):
        # qdisc_snapshot.sh and stack.sh both use 2 for operator error; keeping it free
        # means a shell caller can treat 2 the same way everywhere.
        self.assertNotIn(2, criteria.EXIT_CODES.values())


if __name__ == "__main__":
    unittest.main(verbosity=2)
