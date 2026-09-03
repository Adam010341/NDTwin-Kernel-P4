"""Tests for the ping self-test and the closing banner in testbed_topo.py.

[Co-developed with claude code -- Adam]

The defect (finding #42, measured 2026-09-03): the script launches 128 pings across the fabric
and then prints

    --- Final Configuration Active ---
    Host internet: OK | sFlow reachability: OK | Switch identification: OK

UNCONDITIONALLY. ping_test() returned None, the threads running it discarded even that, and no
value of any kind flowed from the measurement to the three claims. Measured on a fabric where
all 128 pings were at 100% loss: the banner printed all three OKs. This is the "instrument
lies" family -- a needle painted on the dial.

🔴 What these tests are about is the DATA FLOW, not whether the banner is well worded. Three
shapes, and each of them was true of the old file:

  * a banner printed from a constant. Every behavioural case below feeds a summary and reads
    the lines back; a banner that ignores its argument fails the FAIL cases.
  * a measurement that never reaches the banner. TheSelfTestIsWiredToTheBanner reads the
    `if __name__ == "__main__"` block as a syntax tree and asserts the call is there and that
    no health claim is spelled as a constant inside it. Existence is not wiring.
  * a summary that passes vacuously. 0 of 0 pings, results recorded twice, ping output nobody
    could parse -- each of those used to read like "nothing went wrong", and each is a case
    below.

And the control in the other direction: an implementation that prints FAIL for everything
satisfies every case in the first three groups and produces a script no operator can trust
either. Those cases are labelled `control` and the mutation gate drives them.

No Mininet, no fabric, no root: the mininet package is stubbed so the module can be imported,
and the hosts are fakes whose cmd() returns canned ping output. Nothing here runs a command.

Needs no third-party package.

    python3 tests/python/test_testbed_banner.py
Env: TESTBED_TOPO_UNDER_TEST=<path>   (the mutation gate points this at a mutated copy)
"""

from __future__ import annotations

import ast
import contextlib
import importlib.util
import io
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

TOPO_SCRIPT = os.environ.get(
    "TESTBED_TOPO_UNDER_TEST", os.path.join(REPO, "testbed_topo.py"))

#: The fabric the script builds. 128 hosts, pinged as 64 pairs in both directions = 128 pings.
HOST_NUM = 128
PINGS = HOST_NUM


def install_mininet_stubs():
    """Put stub mininet packages into sys.modules so the topology file can be imported.

    The file imports mininet at module level and mininet is not in either venv. Only the names
    the module body touches are needed: `Topo` is subclassed at import time, the rest are looked
    up inside the `__main__` block, which is never executed here -- the module is loaded under a
    name of our own, so `__name__ == "__main__"` is false and no os.system, no `ip addr add` and
    no Mininet ever runs.
    """
    def module(name, **attrs):
        mod = types.ModuleType(name)
        for key, value in attrs.items():
            setattr(mod, key, value)
        sys.modules[name] = mod
        return mod

    module("mininet")
    module("mininet.cli", CLI=object)
    module("mininet.link", TCLink=object)
    module("mininet.log", setLogLevel=lambda *a, **k: None)
    module("mininet.net", Mininet=object)
    module("mininet.node", OVSKernelSwitch=object, RemoteController=object)

    class StubTopo:
        def __init__(self, **opts):
            pass

        def addSwitch(self, name, **kw):
            return name

        def addHost(self, name, **kw):
            return name

        def addLink(self, *a, **kw):
            return None

    module("mininet.topo", Topo=StubTopo)


def load_topo():
    install_mininet_stubs()
    spec = importlib.util.spec_from_file_location("testbed_topo_under_test", TOPO_SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = load_topo()


# --------------------------------------------------------------------- canned ping output
# Verbatim shapes from iputils-ping and from BSD/busybox ping. Not paraphrased: the parser is
# the seam where "we could not tell" turns into a number, and a paraphrase would test the
# paraphrase.

REPLY = """PING 10.0.0.65 (10.0.0.65) 56(84) bytes of data.
64 bytes from 10.0.0.65: icmp_seq=1 ttl=64 time=12.3 ms

--- 10.0.0.65 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 12.345/12.345/12.345/0.000 ms
"""

TIMED_OUT = """PING 10.0.0.65 (10.0.0.65) 56(84) bytes of data.

--- 10.0.0.65 ping statistics ---
1 packets transmitted, 0 received, 100% packet loss, time 0ms
"""

HOST_UNREACHABLE = """PING 10.0.0.65 (10.0.0.65) 56(84) bytes of data.
From 10.0.0.1 icmp_seq=1 Destination Host Unreachable

--- 10.0.0.65 ping statistics ---
1 packets transmitted, 0 received, +1 errors, 100% packet loss, time 0ms
"""

BSD_REPLY = """--- 10.0.0.65 ping statistics ---
1 packets transmitted, 1 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 0.123/0.123/0.123/0.000 ms
"""

#: No statistics line at all -- ping never got far enough to print one.
NET_UNREACHABLE = "connect: Network is unreachable\n"


class FakeHost:
    """Stands in for a Mininet host. cmd() returns canned output; nothing is executed."""

    def __init__(self, name, output=REPLY, raises=None):
        self.name = name
        self.output = output
        self.raises = raises
        self.commands = []

    def cmd(self, command):
        self.commands.append(command)
        if self.raises is not None:
            raise self.raises
        return self.output


class LossySink(object):
    """A sink that records only pings to an odd last octet.

    Stands in for threads that died before recording anything -- the one shape run_ping_self_test
    cannot be made to produce through a fake host, and the one that separates "the denominator is
    what we launched" from "the denominator is what came back". Deterministic whatever order the
    threads run in.
    """

    def __init__(self):
        self._inner = T.PingResults()

    def add(self, result):
        if int(result.dst.rsplit(".", 1)[1]) % 2:
            self._inner.add(result)

    def all(self):
        return self._inner.all()


class FakeNet:
    """net.get(name) over a dict of FakeHost, built by a per-host rule."""

    def __init__(self, host_num, output_for=lambda name: REPLY, raises_for=lambda name: None):
        self.hosts = {
            f"h{i}": FakeHost(f"h{i}", output=output_for(f"h{i}"), raises=raises_for(f"h{i}"))
            for i in range(1, host_num + 1)
        }

    def get(self, name):
        return self.hosts[name]


def quietly(fn, *args, **kwargs):
    """Run fn with stdout swallowed. The self-test prints two lines per ping."""
    with contextlib.redirect_stdout(io.StringIO()):
        return fn(*args, **kwargs)


def results(n, reached=True, parsed=True, start=1):
    """n results for n DISTINCT host pairs, numbered from `start`.

    `start` is not decoration: every ping in this self-test is a different (src, dst) pair, and
    two batches built from the same range would be read as one batch recorded twice -- which is
    a case of its own below and must not leak into the partial-loss cases.
    """
    return [T.PingResult(src=f"h{i}", dst=f"10.0.0.{i}", transmitted=1,
                         received=1 if reached else 0, loss_pct=0.0 if reached else 100.0,
                         parsed=parsed)
            for i in range(start, start + n)]


# ------------------------------------------------------------------------------- the parser

class PingOutputIsRead(unittest.TestCase):
    """The seam where output becomes a number. Everything above it inherits its mistakes."""

    def test_a_reply_is_read_as_a_reply(self):
        self.assertEqual(T.parse_ping_output(REPLY), (1, 1, 0.0))

    def test_a_timeout_is_read_as_total_loss(self):
        self.assertEqual(T.parse_ping_output(TIMED_OUT), (1, 0, 100.0))

    def test_the_errors_field_does_not_confuse_the_loss_percentage(self):
        """iputils inserts `+1 errors,` between the received count and the percentage. A parser
        that takes the first number after `received` reads the loss as 1%."""
        self.assertEqual(T.parse_ping_output(HOST_UNREACHABLE), (1, 0, 100.0))

    def test_the_bsd_spelling_is_read_too(self):
        self.assertEqual(T.parse_ping_output(BSD_REPLY), (1, 1, 0.0))

    def test_output_with_no_statistics_line_is_unreadable_not_perfect(self):
        """🔴 The load-bearing one. `connect: Network is unreachable` has no statistics line;
        a parser that returns zero loss for it turns the worst outcome into the best."""
        self.assertIsNone(T.parse_ping_output(NET_UNREACHABLE))

    def test_empty_output_is_unreadable(self):
        self.assertIsNone(T.parse_ping_output(""))
        self.assertIsNone(T.parse_ping_output(None))


# -------------------------------------------------------------------------------- one ping

class OnePingReportsWhatItMeasured(unittest.TestCase):
    """ping_test used to return None. Nothing downstream could have been right."""

    def test_a_reply_is_returned_and_reached(self):
        r = quietly(T.ping_test, FakeHost("h1"), "10.0.0.65")
        self.assertIsNotNone(r, "ping_test returns nothing -- the banner cannot depend on it")
        self.assertTrue(r.reached)
        self.assertEqual((r.src, r.dst, r.received), ("h1", "10.0.0.65", 1))

    def test_total_loss_is_returned_and_not_reached(self):
        r = quietly(T.ping_test, FakeHost("h1", output=TIMED_OUT), "10.0.0.65")
        self.assertFalse(r.reached)
        self.assertEqual(r.loss_pct, 100.0)

    def test_unreadable_output_is_not_reached(self):
        r = quietly(T.ping_test, FakeHost("h1", output=NET_UNREACHABLE), "10.0.0.65")
        self.assertFalse(r.parsed)
        self.assertFalse(r.reached, "output nobody could read counted as a reply")

    def test_a_host_that_raises_records_a_failure_rather_than_vanishing(self):
        """A thread whose target raises leaves NO result behind, and a summary computed over
        what came back would not notice. Recorded as a failed ping instead."""
        sink = T.PingResults()
        r = quietly(T.ping_test, FakeHost("h1", raises=OSError("no such namespace")),
                    "10.0.0.65", sink=sink)
        self.assertFalse(r.reached)
        self.assertIn("no such namespace", r.error)
        self.assertEqual(len(sink.all()), 1)

    def test_the_result_reaches_the_sink(self):
        """threading.Thread discards return values. The sink is the only path to the banner."""
        sink = T.PingResults()
        quietly(T.ping_test, FakeHost("h1"), "10.0.0.65", sink=sink)
        self.assertEqual([r.dst for r in sink.all()], ["10.0.0.65"])

    def test_it_pings_the_address_it_was_given(self):
        host = FakeHost("h1")
        quietly(T.ping_test, host, "10.0.0.65")
        self.assertEqual(host.commands, ["ping -c 1 10.0.0.65"])


# ---------------------------------------------------------------------------- the summary

class TheSummaryCannotPassVacuously(unittest.TestCase):
    """Every way a count can look fine while the fabric is not."""

    def test_every_ping_replied(self):
        s = T.summarize_pings(results(PINGS), expected=PINGS)
        self.assertTrue(s.ok)
        self.assertEqual((s.replied, s.lost, s.loss_pct), (PINGS, 0, 0.0))

    def test_total_loss_is_not_ok(self):
        s = T.summarize_pings(results(PINGS, reached=False), expected=PINGS)
        self.assertFalse(s.ok)
        self.assertEqual((s.replied, s.lost, s.loss_pct), (0, PINGS, 100.0))

    def test_partial_loss_is_not_ok(self):
        """Stated as an assumption, not discovered: every host here has a static ARP entry for
        every other and the controller installs proactive rules, so one lost ping is a fabric
        defect. There is no tolerated-loss threshold, on purpose."""
        s = T.summarize_pings(results(64) + results(64, reached=False, start=65),
                              expected=PINGS)
        self.assertFalse(s.ok)
        self.assertEqual((s.replied, s.lost), (64, 64))
        self.assertAlmostEqual(s.loss_pct, 50.0)
        # It has to be the LOSS that fails this, not a count of pairs: all 128 are present and
        # distinct, so only `replied` discriminates here.
        self.assertEqual((s.attempted, s.distinct), (PINGS, PINGS))

    def test_a_single_lost_ping_is_not_ok(self):
        s = T.summarize_pings(results(127) + results(1, reached=False, start=128),
                              expected=PINGS)
        self.assertFalse(s.ok)
        self.assertEqual(s.lost, 1)

    def test_results_that_never_arrived_are_lost_not_absent(self):
        """🔴 64 threads died before recording anything. replied/attempted is 64/64 = perfect;
        replied/expected is 64/128."""
        s = T.summarize_pings(results(64), expected=PINGS)
        self.assertFalse(s.ok)
        self.assertEqual((s.attempted, s.replied, s.lost), (64, 64, 64))

    def test_measuring_nothing_is_not_passing(self):
        """0 of 0. The empty-list case reads as 100% success under any ratio."""
        s = T.summarize_pings([], expected=0)
        self.assertFalse(s.ok, "a self-test that measured nothing reported success")

    def test_measuring_nothing_does_not_report_zero_loss(self):
        """The percentage is the number an operator's eye lands on, and it has its own division
        by zero to get wrong. 0/0 is not 0% loss."""
        self.assertEqual(T.summarize_pings([], expected=0).loss_pct, 100.0,
                         "a self-test that measured nothing reported 0% loss")

    def test_more_results_than_pings_launched_is_not_ok(self):
        """129 results for 128 pings: one host's reply recorded twice, and one host that never
        answered. Every other count reads perfect -- 128 distinct pairs, 128 replies -- so only
        the attempted count separates this from a healthy fabric."""
        s = T.summarize_pings(results(127) + results(1, reached=False, start=128) + results(1),
                              expected=PINGS)
        self.assertEqual((s.attempted, s.distinct, s.replied), (PINGS + 1, PINGS, PINGS))
        self.assertFalse(s.ok)

    def test_no_result_at_all_from_a_fabric_that_was_pinged(self):
        s = T.summarize_pings([], expected=PINGS)
        self.assertFalse(s.ok)
        self.assertEqual((s.attempted, s.replied, s.lost), (0, 0, PINGS))

    def test_a_result_recorded_twice_does_not_fill_in_for_a_missing_one(self):
        """🔴 Double-counting reaches attempted == replied == expected without the fabric ever
        having answered that many times. Only the distinct-pair count separates it from a
        healthy run -- and a copied unit is not a second sample."""
        s = T.summarize_pings(results(64) + results(64), expected=PINGS)
        self.assertEqual((s.attempted, s.replied), (PINGS, PINGS))
        self.assertEqual(s.distinct, 64)
        self.assertFalse(s.ok, "128 results from 64 distinct pings signed off as 128 replies")

    def test_unreadable_output_is_counted_and_is_not_a_reply(self):
        s = T.summarize_pings(results(PINGS, reached=False, parsed=False), expected=PINGS)
        self.assertFalse(s.ok)
        self.assertEqual((s.unreadable, s.replied), (PINGS, 0))


# ----------------------------------------------------------------------------- the banner

class TheBannerCarriesTheNumbers(unittest.TestCase):
    """The finding itself: three OK claims with no data flow behind them."""

    def lines(self, summary):
        return "\n".join(T.banner_lines(summary))

    def test_a_healthy_fabric_says_ok_with_its_numbers(self):
        """control: an implementation that fails everything satisfies every case below."""
        text = self.lines(T.summarize_pings(results(PINGS), expected=PINGS))
        self.assertIn("OK", text)
        self.assertNotIn("FAIL", text)
        self.assertIn(f"{PINGS}/{PINGS}", text)

    def test_total_loss_does_not_say_ok_anywhere(self):
        """🔴 The measured defect, verbatim: 128 pings at 100% loss, banner printed three OKs."""
        text = self.lines(T.summarize_pings(results(PINGS, reached=False), expected=PINGS))
        self.assertNotIn("OK", text,
                         "the banner still claims OK on a fabric at 100% loss")
        self.assertIn("FAIL", text)

    def test_total_loss_carries_the_counts_it_was_computed_from(self):
        text = self.lines(T.summarize_pings(results(PINGS, reached=False), expected=PINGS))
        self.assertIn(f"0/{PINGS} pings replied", text)
        self.assertIn(f"{PINGS} lost", text)
        self.assertIn("100.0% loss", text)

    def test_partial_loss_is_a_failure_and_names_the_split(self):
        text = self.lines(T.summarize_pings(
            results(64) + results(64, reached=False, start=65), expected=PINGS))
        self.assertNotIn("OK", text)
        self.assertIn(f"64/{PINGS} pings replied", text)
        self.assertIn("64 lost", text)

    def test_missing_results_are_named_as_missing(self):
        text = self.lines(T.summarize_pings(results(64), expected=PINGS))
        self.assertNotIn("OK", text)
        self.assertIn(f"64/{PINGS} pings reported a result at all", text)
        self.assertNotIn("distinct host pairs", text,
                         "results that never arrived diagnosed as results recorded twice")

    def test_a_copied_result_is_named_as_a_copy(self):
        """The two failures are told apart: 64 results for 128 pings is a shortfall, 128
        results covering 64 pairs is a copy, and the operator is sent to a different place."""
        text = self.lines(T.summarize_pings(results(64) + results(64), expected=PINGS))
        self.assertNotIn("OK", text)
        self.assertIn(f"64/{PINGS} distinct host pairs", text)
        self.assertNotIn("reported a result at all", text)

    def test_unreadable_output_is_named(self):
        text = self.lines(
            T.summarize_pings(results(PINGS, reached=False, parsed=False), expected=PINGS))
        self.assertIn("could not read", text)

    def test_the_unmeasured_claims_are_not_claimed(self):
        """sFlow reachability and switch identification are not measured anywhere in this
        script -- not on the good path either. Printing OK for them was the other two thirds
        of the finding."""
        for summary in (T.summarize_pings(results(PINGS), expected=PINGS),
                        T.summarize_pings(results(PINGS, reached=False), expected=PINGS)):
            text = self.lines(summary)
            self.assertIn("sFlow reachability: NOT MEASURED", text)
            self.assertIn("switch identification: NOT MEASURED", text)
            self.assertNotIn("sFlow reachability: OK", text)
            self.assertNotIn("Switch identification: OK", text)

    def test_the_old_unconditional_line_is_gone_from_the_file(self):
        """The exact string that was printed on a fabric at 100% loss."""
        with open(TOPO_SCRIPT, encoding="utf-8") as fh:
            source = fh.read()
        self.assertNotIn(
            'print("Host internet: OK | sFlow reachability: OK | Switch identification: OK")',
            source)


# ------------------------------------------------------------- the self-test over a fabric

class TheSelfTestMeasuresTheFabric(unittest.TestCase):
    """run_ping_self_test over a fake net -- the pings, the sink and the fold, together."""

    def summary(self, host_num=8, **kw):
        return quietly(T.run_ping_self_test, FakeNet(host_num, **kw), host_num)

    def test_a_healthy_fabric_passes(self):
        """control."""
        s = self.summary()
        self.assertTrue(s.ok)
        self.assertEqual((s.expected, s.attempted, s.replied), (8, 8, 8))

    def test_the_full_fabric_launches_one_ping_per_host(self):
        """128 hosts, 64 pairs, both directions."""
        s = self.summary(host_num=HOST_NUM)
        self.assertEqual(s.expected, PINGS)
        self.assertEqual(s.replied, PINGS)

    def test_a_fabric_at_total_loss_fails(self):
        s = self.summary(output_for=lambda name: TIMED_OUT)
        self.assertFalse(s.ok)
        self.assertEqual((s.replied, s.lost), (0, 8))

    def test_half_a_fabric_fails(self):
        s = self.summary(output_for=lambda name: REPLY if int(name[1:]) <= 4 else TIMED_OUT)
        self.assertFalse(s.ok)
        self.assertEqual(s.replied, 4)

    def test_hosts_that_cannot_be_reached_at_all_still_report(self):
        """Every cmd() raises. Without the guard in ping_test the threads die, the sink stays
        empty and the summary is folded over nothing."""
        s = self.summary(raises_for=lambda name: OSError("mnexec: no such process"))
        self.assertFalse(s.ok)
        self.assertEqual((s.attempted, s.replied), (8, 0))

    def test_it_pings_across_the_two_halves(self):
        net = FakeNet(8)
        quietly(T.run_ping_self_test, net, 8)
        self.assertEqual(net.hosts["h1"].commands, ["ping -c 1 10.0.0.5"])
        self.assertEqual(net.hosts["h5"].commands, ["ping -c 1 10.0.0.1"])

    def test_results_lost_on_the_way_back_are_still_counted_as_pings(self):
        """🔴 The denominator has to be what was LAUNCHED. Half the results never arrive here;
        a self-test that divides by what came back sees 4 of 4 and signs off."""
        s = quietly(T.run_ping_self_test, FakeNet(8), 8, sink=LossySink())
        self.assertEqual((s.expected, s.attempted, s.replied), (8, 4, 4))
        self.assertFalse(s.ok, "a fabric that reported half its pings passed the self-test")


# ------------------------------------------------------------------------------- the wiring

class TheSelfTestIsWiredToTheBanner(unittest.TestCase):
    """🔴 Existence is not wiring. Every case above passes on a file whose `__main__` block
    still prints the constant banner and never calls any of it."""

    def main_block(self):
        with open(TOPO_SCRIPT, encoding="utf-8") as fh:
            tree = ast.parse(fh.read())
        for node in tree.body:
            if isinstance(node, ast.If) and "__main__" in ast.dump(node.test):
                return node
        raise AssertionError("testbed_topo.py has no `if __name__ == \"__main__\"` block")

    def called_names(self, node):
        return {n.func.id for n in ast.walk(node)
                if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}

    def test_the_bring_up_runs_the_self_test(self):
        self.assertIn("run_ping_self_test", self.called_names(self.main_block()),
                      "the bring-up never runs the ping self-test, so the banner below it is "
                      "printed from nothing -- the defect, exactly")

    def test_the_bring_up_prints_the_derived_banner(self):
        self.assertIn("banner_lines", self.called_names(self.main_block()),
                      "the bring-up does not print banner_lines(), so whatever it does print "
                      "is not derived from the measurement")

    def summary_names(self, block):
        """The names run_ping_self_test's result is assigned to inside the bring-up block."""
        assigned = set()
        for node in ast.walk(block):
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call) \
                    and isinstance(node.value.func, ast.Name) \
                    and node.value.func.id == "run_ping_self_test":
                assigned.update(t.id for t in node.targets if isinstance(t, ast.Name))
        return assigned

    def system_exits(self, node):
        return [n for n in ast.walk(node)
                if isinstance(n, ast.Raise) and isinstance(n.exc, ast.Call)
                and isinstance(n.exc.func, ast.Name) and n.exc.func.id == "SystemExit"]

    def test_the_banner_is_printed_from_the_self_tests_result(self):
        """Both called is not enough: banner_lines(PingSummary(...)) over a fresh constant
        would satisfy that and measure nothing."""
        block = self.main_block()
        assigned = self.summary_names(block)
        self.assertTrue(assigned, "run_ping_self_test's result is not assigned to anything")
        passed = set()
        for node in ast.walk(block):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                    and node.func.id == "banner_lines":
                passed.update(a.id for a in node.args if isinstance(a, ast.Name))
        self.assertTrue(assigned & passed,
                        f"banner_lines is called with {passed or 'no name'}, not with the "
                        f"self-test's result {assigned}")

    def test_no_health_claim_is_spelled_as_a_constant_in_the_bring_up(self):
        """The shape of the defect as text: an OK the code cannot withhold."""
        claims = [n.value for n in ast.walk(self.main_block())
                  if isinstance(n, ast.Constant) and isinstance(n.value, str)
                  and "OK" in n.value]
        self.assertEqual(claims, [],
                         f"the bring-up block still contains hard-coded OK text: {claims}")

    def test_the_run_exits_non_zero_when_the_self_test_failed(self):
        """No caller reads this today (stack.sh prompts the operator; ndtwin-lab launches it
        detached in tmux) -- but a script that measured 100% loss and exits 0 is the same
        defect one layer down."""
        raises = self.system_exits(self.main_block())
        self.assertTrue(raises, "the bring-up exits 0 whatever the self-test measured")
        for node in raises:
            self.assertNotEqual([a.value for a in node.exc.args], [0],
                                "SystemExit(0) is not a failing status")

    def test_the_exit_status_is_conditional_on_the_measurement(self):
        """control: an unconditional `raise SystemExit(1)` satisfies the case above and exits
        non-zero on a perfectly healthy fabric, which is the same instrument failing the other
        way round."""
        block = self.main_block()
        names = self.summary_names(block)
        self.assertTrue(names)
        guarded = set()
        for node in ast.walk(block):
            if isinstance(node, ast.If) and \
                    names & {n.id for n in ast.walk(node.test) if isinstance(n, ast.Name)}:
                guarded.update(id(r) for r in self.system_exits(node))
        for node in self.system_exits(block):
            self.assertIn(id(node), guarded,
                          f"line {node.lineno}: SystemExit is not guarded by anything that "
                          f"reads {names} -- the run exits non-zero whatever was measured")


if __name__ == "__main__":
    unittest.main(verbosity=2)
