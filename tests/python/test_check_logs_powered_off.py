"""
Tests for check_logs.py's WHEN-POWERED-OFF rule kind.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES A-8. The kernel writes

    [warning] localhost:8081 reported a read failure for switch 5 (...) -- keeping the
    previous table rather than treating it as a switch with no rules

(src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:1134) *because it is
correctly handling a switch the Energy-Saving-App powered down. The allowlist did not carry
it, so the log check went red -- the third of three tools that turn red when the system is
working (doc/audit/2026-08-18_live-full-stack-round/live-findings-2026-08-18-p4.md, N-9).

The obvious fix is the wrong one. Adding a plain WARNING entry would also silence the line
when no switch is powered off, and that is the 2026-08-07 wedged-controller defect the
warning was added to expose: all ten switches reporting zero flow rules while s1 held 130,
with every liveness indicator green. So the permission has to be scoped to the switches the
run declares off, and the tool has to refuse to guess when nothing is declared.

Three outcomes, and each is pinned below:

    --powered-off 5      a read failure for switch 5 is EXPECTED      exit 0
    --powered-off none   the same line is a PROBLEM                   exit 1
    (flag omitted)       TOOL-PRECONDITION-FAILED, no verdict         exit 3

Runs check_logs.py as a subprocess rather than importing it, because the exit code is the
contract: run_layers.sh:211 uses nothing else, and exit 3 existing at all is half the fix.

Lives in tests/python/ under a plain python3 with no PYTHONPATH, like its sibling
test_contract_spec.py, and uses unittest because tools/test_workflow/l1_unit_tests.sh
executes each file directly and parses "Ran N tests".
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHECK_LOGS = os.path.join(REPO_ROOT, "tools", "contract_test", "check_logs.py")
SHIPPED_ALLOWLIST = os.path.join(REPO_ROOT, "tools", "contract_test", "warning_allowlist.txt")

#: The line as the kernel actually emits it, timestamp and all.
READ_FAILURE = ("[2026-08-18 17:04:11.221] [warning] [DeviceConfigurationAndPowerManager.cpp"
                ":1134 pollFlowStats] localhost:8081 reported a read failure for switch {dpid}"
                ' ({{"error":"switch not connected"}}) -- keeping the previous table rather'
                " than treating it as a switch with no rules")

INFO_LINE = ("[2026-08-18 17:04:10.000] [info] [Main.cpp:10 main] kernel started")

MINIMAL_ALLOWLIST = textwrap.dedent("""\
    # test allowlist
    WHEN-POWERED-OFF | reported a read failure for switch (?P<dpid>\\d+) | powered down on purpose
    """)


def write(directory, name, text):
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def run_check(logfile, allowlist, *extra):
    """Returns (rc, combined output). No pipe: the exit code is what is under test."""
    proc = subprocess.run(
        [sys.executable, CHECK_LOGS, logfile, "--allowlist", allowlist, *extra],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env={**os.environ, "NO_COLOR": "1"})
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


class ScopedPermissionTest(unittest.TestCase):
    """The same line, three declarations, three different answers."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.allowlist = write(self.tmp.name, "allow.txt", MINIMAL_ALLOWLIST)
        self.log = write(self.tmp.name, "kernel.log",
                         INFO_LINE + "\n" + READ_FAILURE.format(dpid=5) + "\n")

    def test_a_read_failure_for_a_declared_off_switch_passes(self):
        rc, out = run_check(self.log, self.allowlist, "--powered-off", "5")
        self.assertEqual(rc, 0, out)
        self.assertIn("EXPECTED", out)
        self.assertNotIn("PROBLEMS", out)

    def test_the_same_line_for_a_switch_declared_on_is_still_a_failure(self):
        # This is the 2026-08-07 wedged-controller signal. Scoping the permission must not
        # cost us it.
        rc, out = run_check(self.log, self.allowlist, "--powered-off", "7")
        self.assertEqual(rc, 1, out)
        self.assertIn("PROBLEMS", out)

    def test_declaring_that_nothing_is_off_makes_it_a_failure(self):
        # 'none' is a real assertion, and it is the one that keeps the detection alive on a
        # fabric where the power app is not running at all.
        rc, out = run_check(self.log, self.allowlist, "--powered-off", "none")
        self.assertEqual(rc, 1, out)
        self.assertIn("PROBLEMS", out)

    def test_declaring_nothing_at_all_is_undecidable_not_a_failure(self):
        rc, out = run_check(self.log, self.allowlist)
        self.assertEqual(rc, 3, out)
        self.assertIn("TOOL-PRECONDITION-FAILED", out)
        self.assertNotIn("PROBLEMS", out)

    def test_the_undecidable_verdict_does_not_use_the_word_fail(self):
        # A reader scanning for FAIL must not find one: the whole point is that the tool's
        # inability to judge does not render as the system being broken.
        _rc, out = run_check(self.log, self.allowlist)
        self.assertNotIn("FAIL:", out)

    def test_omitting_the_flag_and_declaring_none_are_different_answers(self):
        rc_silent, _ = run_check(self.log, self.allowlist)
        rc_declared, _ = run_check(self.log, self.allowlist, "--powered-off", "none")
        self.assertNotEqual(rc_silent, rc_declared)


class DoesNotWeakenTheGateTest(unittest.TestCase):
    """A scoped permission must not become a general one."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.allowlist = write(self.tmp.name, "allow.txt", MINIMAL_ALLOWLIST)

    def test_an_unrelated_warning_still_fails_even_with_a_declaration(self):
        log = write(self.tmp.name, "k.log",
                    "[2026-08-18 17:04:11.221] [warning] [X.cpp:1 f] something new\n")
        rc, out = run_check(log, self.allowlist, "--powered-off", "5")
        self.assertEqual(rc, 1, out)

    def test_an_error_level_line_still_fails_even_with_a_declaration(self):
        log = write(self.tmp.name, "k.log",
                    "[2026-08-18 17:04:11.221] [error] [X.cpp:1 f] boom\n")
        rc, out = run_check(log, self.allowlist, "--powered-off", "5")
        self.assertEqual(rc, 1, out)

    def test_a_crash_still_fails_even_for_a_declared_off_switch(self):
        # Crash detection is documented as never allowlistable; a power-down declaration is
        # an allowlist scope, so it must not reach it.
        log = write(self.tmp.name, "k.log",
                    READ_FAILURE.format(dpid=5) + "\nterminate called after throwing\n")
        rc, out = run_check(log, self.allowlist, "--powered-off", "5")
        self.assertEqual(rc, 1, out)
        self.assertIn("CRASHES", out)

    def test_a_read_failure_for_a_second_undeclared_switch_still_fails(self):
        log = write(self.tmp.name, "k.log",
                    READ_FAILURE.format(dpid=5) + "\n" + READ_FAILURE.format(dpid=8) + "\n")
        rc, out = run_check(log, self.allowlist, "--powered-off", "5")
        self.assertEqual(rc, 1, out)
        self.assertIn("switch 8", out)

    def test_a_when_powered_off_rule_without_a_dpid_group_is_rejected(self):
        # Without the capture the rule would excuse the message for every switch, which is
        # exactly the blanket permission this kind exists to avoid.
        bad = write(self.tmp.name, "bad.txt",
                    "WHEN-POWERED-OFF | reported a read failure | no capture group\n")
        log = write(self.tmp.name, "k.log", INFO_LINE + "\n")
        rc, out = run_check(log, bad, "--powered-off", "5")
        self.assertNotEqual(rc, 0, out)
        self.assertIn("dpid", out)


class ReportingTest(unittest.TestCase):
    """What the run says, beyond its exit code."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.allowlist = write(self.tmp.name, "allow.txt", MINIMAL_ALLOWLIST)

    def test_a_switch_declared_off_that_produced_no_such_line_is_reported(self):
        # The declaration and the log disagreeing is worth saying: it may mean the
        # power-down never took effect.
        log = write(self.tmp.name, "k.log", INFO_LINE + "\n")
        rc, out = run_check(log, self.allowlist, "--powered-off", "9")
        self.assertEqual(rc, 0, out)
        self.assertIn("declared powered off produced no matching log line", out)

    def test_an_unused_when_powered_off_rule_is_not_reported_as_stale(self):
        # An unfired scoped rule means no switch was powered off, not that the rule rotted.
        log = write(self.tmp.name, "k.log", INFO_LINE + "\n")
        _rc, out = run_check(log, self.allowlist, "--powered-off", "none")
        self.assertNotIn("UNUSED ALLOWLIST ENTRIES", out)

    def test_suggest_mode_refuses_to_suggest_an_undecidable_line(self):
        # Otherwise --suggest-allowlist would print "nothing unmatched" over lines it
        # deliberately did not judge.
        log = write(self.tmp.name, "k.log", READ_FAILURE.format(dpid=5) + "\n")
        rc, out = run_check(log, self.allowlist, "--suggest-allowlist")
        self.assertEqual(rc, 3, out)
        self.assertIn("NOT SUGGESTED", out)


class ShippedAllowlistTest(unittest.TestCase):
    """The rule that ships must actually match the message the kernel writes."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_the_shipped_allowlist_covers_the_real_read_failure_line(self):
        log = write(self.tmp.name, "k.log", READ_FAILURE.format(dpid=5) + "\n")
        rc, out = run_check(log, SHIPPED_ALLOWLIST, "--powered-off", "5")
        self.assertEqual(rc, 0, out)
        self.assertIn("EXPECTED", out)

    def test_the_shipped_allowlist_covers_the_empty_flow_table_timeout_line(self):
        line = ("[2026-08-18 17:04:11.221] [warning] [DeviceConfigurationAndPowerManager.cpp"
                ":1146 pollFlowStats] localhost:8081 returned an empty flow table for switch"
                " 7 after 3.500s, at or beyond its 3.0s suspicion threshold -- treating it"
                " as a lost reply, not as a switch with no rules. Keeping the previous"
                " table. Check whether the controller has stopped reading its switch"
                " connections.")
        log = write(self.tmp.name, "k.log", line + "\n")
        rc, out = run_check(log, SHIPPED_ALLOWLIST, "--powered-off", "7")
        self.assertEqual(rc, 0, out)

    def test_the_shipped_allowlist_still_fails_those_lines_for_a_powered_on_switch(self):
        log = write(self.tmp.name, "k.log", READ_FAILURE.format(dpid=5) + "\n")
        rc, out = run_check(log, SHIPPED_ALLOWLIST, "--powered-off", "none")
        self.assertEqual(rc, 1, out)

    def test_the_shipped_allowlist_loads_without_error(self):
        log = write(self.tmp.name, "k.log", INFO_LINE + "\n")
        rc, out = run_check(log, SHIPPED_ALLOWLIST, "--powered-off", "none")
        self.assertIn(rc, (0, 1), out)
        self.assertNotIn("Traceback", out)


class ParsePoweredOffTest(unittest.TestCase):
    """The declaration parser, imported directly -- 'none' must not collapse into 'absent'."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, os.path.join(REPO_ROOT, "tools", "contract_test"))
        global check_logs
        import check_logs  # noqa: F401

    def test_absent_declares_nothing(self):
        dpids, declared = check_logs.parse_powered_off(None)
        self.assertFalse(declared)
        self.assertEqual(set(dpids), set())

    def test_none_declares_an_empty_set(self):
        dpids, declared = check_logs.parse_powered_off("none")
        self.assertTrue(declared)
        self.assertEqual(set(dpids), set())

    def test_a_list_is_parsed(self):
        dpids, declared = check_logs.parse_powered_off(" 5, 7 ,9 ")
        self.assertTrue(declared)
        self.assertEqual(set(dpids), {5, 7, 9})

    def test_a_non_numeric_dpid_is_rejected_rather_than_ignored(self):
        with self.assertRaises(SystemExit):
            check_logs.parse_powered_off("5,s7")


if __name__ == "__main__":
    unittest.main(verbosity=2)
