"""
The three startup WARNs the residue/exemption work added, against the shipped allowlist.

[Co-developed with claude code -- Adam]

F-OFFLINE-1 G6 (hunt-0911/F-OFFLINE-1-REPORT.md 1.6) measured `check_logs.py` exit 1 on a
synthetic log carrying all three of them, and read that as three missing allowlist entries.
One of the three is a missing entry. The other two are the checker working, and this file
is what stops the next reader from "finishing" G6 by silencing them.

The window matters: run_layers.sh:349 records the log length with `wc -l` and :482 calls
check_logs.py with `--to-line "$LOG_MARK"`, i.e. it checks lines 1..mark -- the startup
segment. A startup WARNING that is not allowlisted therefore fails L2 on a healthy kernel.

  1. TopologyAndFlowMonitor.cpp:1354, warnAboutSwitchesWithNoBrandPathNoLock, reached from
     :1297 at every load. It fires once per startup on any topology that declares an
     explicit `switch_kind` for a brand this build has no power/telemetry path for (E-25).
     It is a statement about a permanent, designed condition -- the same shape as the
     already-allowlisted "HistoricalDataManager not started: MININET" -- so a kernel that
     is behaving correctly must not fail the log gate for saying it. THIS ONE IS THE GAP.

  2. TopologyAndFlowMonitor.cpp:3940, the residue sweep's "could not read this machine's
     qdisc tree". NOT allowlisted, deliberately. The sweep runs
     utils::netem::readOnlyTcRunner() -- a bare `tc qdisc show`, no sudo (NetemLinkFault.hpp
     :356-372) -- whose header says, verbatim: "this runner is allowed to fail, it is not
     allowed to look clean while failing." A plain WARNING entry is exactly "look clean
     while failing": the sweep would have made no claim about the fabric and the log gate
     would be green. If this ever turns out to fire routinely, the fix is a rule kind that
     exits 3 (the WHEN-POWERED-OFF precedent), not a blanket permission.

  3. TopologyAndFlowMonitor.cpp:4003, the E-20 residue finding itself: netem is attached to
     interfaces this kernel did not touch. NOT allowlisted, deliberately. That is a fact
     about the fabric a measurement is about to run on, and the message says so in capitals.
     Allowlisting it would make every run on a fabric somebody left faults on look clean.

Both halves are asserted here, not just the first: an allowlist entry wide enough to
swallow 2 and 3 as well would pass a test that only checked 1.

The message texts are not transcribed. They are extracted from the C++ format strings at
run time, so a reworded message makes this file fail instead of quietly passing while the
allowlist matches text the kernel no longer emits -- the failure mode the allowlist's own
"refusing flow batch" entry has already had once (see warning_allowlist.txt).

Runs check_logs.py as a subprocess, like tests/python/test_check_logs_powered_off.py: the
exit code is the contract run_layers.sh reads. Plain python3, no PYTHONPATH, unittest, so
tools/test_workflow/l1_unit_tests.sh can execute it directly.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHECK_LOGS = os.path.join(REPO_ROOT, "tools", "contract_test", "check_logs.py")
SHIPPED_ALLOWLIST = os.path.join(REPO_ROOT, "tools", "contract_test", "warning_allowlist.txt")
MONITOR = os.path.join(REPO_ROOT, "src", "ndt_core", "collection", "TopologyAndFlowMonitor.cpp")

#: A C++ string literal, escapes included.
_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

#: Anchor -> the values to substitute for the format string's `{}` placeholders, in order.
#: The anchor is a fragment of the format string that identifies the call site; the values
#: are shaped like what the call site passes, because the allowlist patterns are matched
#: against a rendered line and a pattern that only fits `{}` is not a pattern.
SITES = {
    "exempt_switch": (
        "switch(es) exempt from power/telemetry",
        ["2", 'dpid 7 (brand_name "Zyxel XS1930"), dpid 8 (brand_name "Zyxel XS1930")'],
    ),
    "qdisc_unreadable": (
        "could not read this machine's qdisc tree",
        ["2"],
    ),
    "residual_netem": (
        "netem is already attached to",
        ["2", "s1-eth1 (link end s1:1 -> s5:1), s2-eth9 (host-facing)", "1", "1", "0"],
    ),
}


def _spdlog_warn_format(source: str, anchor: str) -> str:
    """The format string of the SPDLOG_LOGGER_WARN call whose text contains `anchor`."""
    at = source.index(anchor)
    start = source.rindex("SPDLOG_LOGGER_WARN", 0, at)
    rest = source[source.index("Logger::instance()", start) + len("Logger::instance()"):]
    rest = rest.lstrip()
    assert rest.startswith(","), f"unexpected argument shape after the logger for {anchor!r}"
    rest = rest[1:].lstrip()
    parts = []
    while rest.startswith('"'):
        match = _LITERAL.match(rest)
        parts.append(match.group(1))
        rest = rest[match.end():].lstrip()
    assert parts, f"no format string literal found for {anchor!r}"
    return "".join(parts).replace('\\"', '"').replace("\\\\", "\\")


def kernel_message(site: str) -> str:
    """The message the kernel writes at `site`, rendered from its own format string."""
    with open(MONITOR, encoding="utf-8") as fh:
        source = fh.read()
    anchor, values = SITES[site]
    fmt = _spdlog_warn_format(source, anchor)
    holes = fmt.count("{}")
    assert holes == len(values), (
        f"{site}: the format string now takes {holes} argument(s), this test supplies "
        f"{len(values)} -- update SITES")
    out = fmt
    for value in values:
        out = out.replace("{}", value, 1)
    return out


def warning_line(message: str, where: str) -> str:
    return f"[2026-09-11 01:02:03.456] [warning] [{where}] {message}"


def run_check(logfile: str, *extra: str):
    """Returns (rc, combined output). The exit code is what is under test."""
    proc = subprocess.run(
        [sys.executable, CHECK_LOGS, logfile, "--allowlist", SHIPPED_ALLOWLIST, *extra],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env={**os.environ, "NO_COLOR": "1"})
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


class StartupWarningTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _log(self, *sites: str) -> str:
        wheres = {
            "exempt_switch": "TopologyAndFlowMonitor.cpp:1354 warnAboutSwitchesWithNoBrandPath",
            "qdisc_unreadable": "TopologyAndFlowMonitor.cpp:3940 warnAboutResidualNetem",
            "residual_netem": "TopologyAndFlowMonitor.cpp:4003 warnAboutResidualNetem",
        }
        lines = ["[2026-09-11 01:02:03.000] [info] [main.cpp:1 main] kernel started"]
        lines += [warning_line(kernel_message(s), wheres[s]) for s in sites]
        path = os.path.join(self.tmp.name, "-".join(sites) + ".log")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        return path

    def test_the_exemption_line_does_not_fail_a_healthy_kernel(self):
        # G6. A topology that declares switch_kind for an unsupported brand is a supported
        # configuration, and this line is how the operator learns which switches it applies
        # to. Before the allowlist entry, L2's log check went red on it at every startup.
        rc, out = run_check(self._log("exempt_switch"), "--powered-off", "none")
        self.assertEqual(rc, 0, out)

    def test_an_unreadable_qdisc_tree_is_still_a_problem(self):
        # Negative control for the entry above, and half of why G6 is not three entries.
        # `tc qdisc show` failing means the sweep has no opinion. Green here would be the
        # blind-probe-reads-as-clean shape.
        rc, out = run_check(self._log("qdisc_unreadable"), "--powered-off", "none")
        self.assertEqual(rc, 1, out)
        self.assertIn("PROBLEMS", out)

    def test_residual_netem_on_the_fabric_is_still_a_problem(self):
        # The other half. E-20's finding is about the fabric the run is about to measure.
        rc, out = run_check(self._log("residual_netem"), "--powered-off", "none")
        self.assertEqual(rc, 1, out)
        self.assertIn("PROBLEMS", out)

    def test_all_three_together_still_fail_on_the_two_that_should(self):
        rc, out = run_check(self._log("exempt_switch", "qdisc_unreadable", "residual_netem"),
                            "--powered-off", "none")
        self.assertEqual(rc, 1, out)
        self.assertIn("2 problem line(s)", out)

    def test_the_extracted_message_is_the_one_the_kernel_writes(self):
        # The extraction is the load-bearing part: an allowlist pattern checked only against
        # a hand-typed copy of the message proves the pattern matches the copy.
        exempt = kernel_message("exempt_switch")
        self.assertTrue(exempt.startswith("2 switch(es) exempt from power/telemetry"), exempt)
        self.assertNotIn("{}", exempt)
        self.assertNotIn("{}", kernel_message("qdisc_unreadable"))
        self.assertNotIn("{}", kernel_message("residual_netem"))


if __name__ == "__main__":
    unittest.main()
