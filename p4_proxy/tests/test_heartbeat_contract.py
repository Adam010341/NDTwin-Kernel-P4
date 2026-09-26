"""
The contract between the heartbeat's two writers -- TICKET-P4-heartbeat segment W.

[Co-developed with claude code -- Adam]

The root helper's daemon WRITES /run/ndtwin-lab/heartbeat.json (tools/test_workflow/ndtwin-lab,
its embedded program: `Heartbeat.document()` and `write_json_atomic`); the proxy READS it
(proxy_agent/link_heartbeat.py: `read_report`, `HeartbeatEvidence`). Until now the key names
between the two were checked by eye only (the fable judge's 8.1 on 1a3ebd7f): every proxy test
builds its report by hand, in the shape its author believed the daemon writes, so a rename on
either side would leave both suites green and the live proxy reading `heartbeat_report_unreadable`
-- or, worse, reading a renamed `forwarded_to_hosts` as zero.

Here the report is produced by the helper's OWN code: the program is cut out of the helper exactly
as `hb_program` prints it (the text between its quoted heredoc markers), loaded as a module, fed a
pod-topo plan and real encoded frames, and its `document()` written with its own
`write_json_atomic` -- then read by the proxy's reader. Nothing is run as root and nothing touches
/run: the plan is built in memory (the daemon's `plan()`, which reads the fabric, is not called),
and the file goes into a temporary directory owned by whoever runs the test. The helper is read,
never changed (it is sha-pinned and installed; segment W does not touch it).

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
REPO = os.path.dirname(PROXY_DIR)
sys.path.insert(0, PROXY_DIR)

# link_heartbeat is standard library only: no third-party skip here.
from proxy_agent import link_heartbeat  # noqa: E402

HELPER = os.path.join(REPO, "tools", "test_workflow", "ndtwin-lab")
START_MARK = "cat <<'NDTWIN_LAB_HEARTBEAT_PY'\n"
END_MARK = "\nNDTWIN_LAB_HEARTBEAT_PY\n"


def load_daemon():
    """The helper's embedded program, as a module -- the same text `hb_program` prints."""
    with open(HELPER) as fh:
        text = fh.read()
    start = text.index(START_MARK) + len(START_MARK)
    end = text.index(END_MARK, start)
    module = types.ModuleType("ndtwin_lab_heartbeat_under_test")
    module.__file__ = HELPER
    exec(compile(text[start:end + 1], HELPER + " (hb_program)", "exec"), module.__dict__)
    return module


DAEMON = load_daemon()

#: exercises/basic/pod-topo: four cables between the two leaves (s1, s2) and the two spines
#: (s3, s4); hosts h1, h2 on s1 ports 1-2 and h3, h4 on s2 ports 1-2.
POD_CABLES = ((1, 3, 3, 1), (1, 4, 4, 2), (2, 3, 4, 1), (2, 4, 3, 2))
HOST_PORTS = ((1, 1), (1, 2), (2, 1), (2, 2))
SESSION = bytes.fromhex("0102030405060708")
STARTED = 1000.0
WALL0 = 1_790_400_000.0


def port(dpid, number):
    return DAEMON.Port(f"s{dpid}", dpid, number, f"s{dpid}-eth{number}")


def pod_plan():
    """A plan of the shape the daemon's own plan() returns, for pod-topo, built in memory."""
    links = [(port(a, ap), port(b, bp)) for a, ap, b, bp in POD_CABLES]
    directions = []
    for x, y in links:
        directions.append(DAEMON.Direction(len(directions), x, y))
        directions.append(DAEMON.Direction(len(directions), y, x))
    watch = [port(d, p) for d, p in HOST_PORTS]
    ifnames = [p.ifname for pair in links for p in pair] + [p.ifname for p in watch]
    macs = {name: bytes([0x02, 0, 0, 0, i // 256, i % 256]) for i, name in enumerate(ifnames)}
    switches = {f"s{d}": DAEMON.Switch(f"s{d}", d, 4000 + d, "build/basic.json") for d in (1, 2, 3, 4)}
    return DAEMON.Plan(switches, links, directions, watch, "/tmp/ndtwin_p4_switches.json",
                       "0" * 64, macs, {})


def declared():
    """The proxy's declared directions for pod-topo: (tx dpid, tx port, rx dpid, rx port)."""
    return tuple(sorted(POD_CABLES + tuple((b, bp, a, ap) for a, ap, b, bp in POD_CABLES)))


class ReportDir:
    """A directory shaped like /run/ndtwin-lab (0755), owned by whoever runs the test."""

    def __init__(self, testcase):
        self.dir = tempfile.mkdtemp(prefix="ndtwin_hb_contract_")
        testcase.addCleanup(shutil.rmtree, self.dir, True)
        os.chmod(self.dir, 0o755)
        self.path = os.path.join(self.dir, "heartbeat.json")
        self.uid = os.getuid()


def a_round(hb, now, silent=()):
    """One round: every direction's frame is sent, and arrives at its far end unless its
    (tx dpid, tx port, rx dpid, rx port) is in `silent`. Returns {direction key: heard at}."""
    heard = {}
    for ifname, frame, d in hb.frames():
        key = (d.tx.dpid, d.tx.port, d.rx.dpid, d.rx.port)
        hb.sent(d)
        if key in silent:
            continue
        # the frame leaving its own tx interface is seen there too; it is never evidence
        hb.on_frame(ifname, frame, DAEMON.PACKET_OUTGOING, now, WALL0 + now)
        hb.on_frame(d.rx.ifname, frame, 0, now + 0.001, WALL0 + now + 0.001)
        heard[key] = now + 0.001
    return heard


class TheHelpersOwnReportIsWhatTheProxyReadsTest(unittest.TestCase):
    """The daemon's document(), written by its own writer, read by the proxy's read_report."""

    def setUp(self):
        self.dir = ReportDir(self)
        self.hb = DAEMON.Heartbeat(pod_plan(), SESSION, STARTED, WALL0 + STARTED, pid=4242)

    def write(self, status="running", reason=None, now=STARTED + 5.2):
        DAEMON.write_json_atomic(self.dir.path, self.hb.document(status, reason, now, WALL0 + now))
        return now

    def read(self, now):
        return link_heartbeat.read_report(declared(), now=now, period_expected=DAEMON.PERIOD_S,
                                          path=self.dir.path, owner_uid=self.dir.uid)

    def test_a_running_daemon_that_heard_every_direction_is_usable_evidence(self):
        heard = a_round(self.hb, STARTED + 5.0)
        written = self.write()
        reading = self.read(written + 0.3)
        self.assertTrue(reading.usable, reading.detail)
        self.assertEqual((reading.status, reading.session, reading.pid, reading.period_s),
                         ("running", SESSION.hex(), 4242, float(DAEMON.PERIOD_S)))
        self.assertEqual((reading.started_mono, reading.written_mono), (STARTED, written))
        self.assertEqual(reading.heard, heard)
        self.assertEqual((reading.missing, reading.undeclared), ((), ()))

    def test_a_direction_the_daemon_never_heard_is_silent_since_the_daemons_start(self):
        cut = (1, 3, 3, 1)
        a_round(self.hb, STARTED + 5.0, silent={cut})
        written = self.write()
        reading = self.read(written + 0.3)
        self.assertTrue(reading.usable, reading.detail)
        self.assertIsNone(reading.heard[cut])
        clock = lambda: written + 0.3  # noqa: E731
        evidence = link_heartbeat.HeartbeatEvidence(declared(), period_s=DAEMON.PERIOD_S,
                                                    clock=clock, path=self.dir.path,
                                                    owner_uid=self.dir.uid)
        _reading, items = evidence.poll()
        by_link = {link: (was_heard, at) for link, was_heard, at in items}
        self.assertEqual(by_link[cut], (False, STARTED))
        self.assertEqual(by_link[(3, 1, 1, 3)], (True, STARTED + 5.001))

    def test_a_stopped_daemons_last_report_is_not_evidence_and_says_why(self):
        a_round(self.hb, STARTED + 5.0)
        written = self.write(status="stopped", reason="stopped by SIGTERM")
        reading = self.read(written + 0.3)
        self.assertFalse(reading.usable)
        self.assertEqual(reading.reason, link_heartbeat.REASON_NOT_RUNNING)
        self.assertIn("stopped by SIGTERM", reading.detail)

    def test_a_frame_leaving_a_host_port_reaches_the_proxy_as_forwarded_to_hosts(self):
        # Ruling 4's stop condition travels through the daemon's own key into the proxy's
        # frames_reached_hosts: a rename on either side must not read as zero.
        a_round(self.hb, STARTED + 5.0)
        ifname, frame, _d = self.hb.frames()[0]
        host = port(1, 1).ifname
        self.hb.on_frame(host, frame, DAEMON.PACKET_OUTGOING, STARTED + 5.1, WALL0 + STARTED + 5.1)
        written = self.write()
        reading = self.read(written + 0.3)
        self.assertTrue(reading.usable, reading.detail)
        self.assertEqual(reading.side_effects["forwarded_to_hosts"], 1)
        self.assertEqual(reading.side_effects["forwarded_between_switches"], 0)

    def test_the_file_the_daemons_writer_leaves_is_one_the_proxy_trusts(self):
        a_round(self.hb, STARTED + 5.0)
        self.write()
        mode = os.stat(self.dir.path).st_mode & 0o777
        self.assertEqual(mode, 0o644)
        with open(self.dir.path) as fh:
            self.assertEqual(json.load(fh)["source"], link_heartbeat.REPORT_SOURCE)
        self.assertEqual(link_heartbeat.read_trusted(self.dir.path, self.dir.uid)[:1], b"{")


if __name__ == "__main__":
    unittest.main()
