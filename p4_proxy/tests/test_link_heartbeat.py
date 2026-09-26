"""
The veth heartbeat's report, as the proxy reads it -- TICKET-P4-heartbeat segment W.

[Co-developed with claude code -- Adam]

The root helper (`sudo ndtwin-lab heartbeat start`, segment H) writes what it HEARD to
/run/ndtwin-lab/heartbeat.json and decides nothing (ruling 3: this proxy does not get root, it
reads what the root helper reports). This file is about the reading, and the three things that
must be refused before any of it becomes link evidence:

  * a report this proxy cannot TRUST -- anything but a regular, root-owned, not group/other
    writable file in a root-owned directory nobody else can write (segment H's H.7 item 1). A
    report adam could write would let any local process cut a link in the twin, or hide a cut;
  * a report that is not ALIVE -- `status` other than running, or not rewritten within two
    periods (H.7 item 2). A dead heartbeat must NOT read as a network with every link down;
  * a report that is not about THIS fabric, or not at THIS proxy's period -- a direction the
    package declares that the report does not carry, or a period that would make the proxy's
    3-periods timeout the wrong multiple (H.7 items 3 and 6).

And the one piece of state the reader keeps: the EPOCH from which "not heard" counts. A new
session starts it at the daemon's own start; a report that comes back after being unusable
restarts it at that report -- the time the heartbeat was away is nobody's link's fault.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
REPO = os.path.dirname(PROXY_DIR)
sys.path.insert(0, PROXY_DIR)

# Only the THIRD-PARTY dependencies decide a skip. This ticket's own module failing to import is
# a failure -- the red-first run of this file must be red, not "OK (skipped=...)".
try:
    import fastapi  # noqa: F401
    import grpc  # noqa: F401
    import networkx  # noqa: F401

    HAVE_PROXY = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_PROXY = False

if HAVE_PROXY:
    from proxy_agent import link_heartbeat as hb
    from proxy_agent import topology_manager as tm

HELPER = os.path.join(REPO, "tools", "test_workflow", "ndtwin-lab")

#: pod-topo's four cables and both directions of each -- the shape the spike measured
#: (doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T052148Z_S_heartbeat/12_report_first.json).
POD_CABLES = ((1, 3, 3, 1), (1, 4, 4, 2), (2, 3, 4, 1), (2, 4, 3, 2))
POD_DIRECTIONS = tuple(sorted(POD_CABLES + tuple((d, dp, s, sp) for s, sp, d, dp in POD_CABLES)))
CUT = ((1, 3, 3, 1), (3, 1, 1, 3))
SESSION = "7cdb12ddde5e2a2c"
PERIOD = 5


def a_report(now, heard=None, *, status="running", session=SESSION, pid=4242, period_s=PERIOD,
             started=None, written=None, directions=POD_DIRECTIONS, side_effects=None,
             **extra):
    """A report in the daemon's own shape (segment H's `report` writer), every key it writes.

    `heard` maps a direction to its last_heard_mono (None = never heard); the default is every
    direction heard one second before `now`.
    """
    heard = dict(heard or {})
    records = []
    for i, (a, ap, b, bp) in enumerate(directions):
        last = heard.get((a, ap, b, bp), now - 1.0)
        records.append({
            "id": i, "heard": 0 if last is None else 3, "sent": 3, "send_errors": 0,
            "last_send_error": None, "last_seq": 3, "last_heard_mono": last,
            "last_heard_wall": None if last is None else 1_790_400_000.0 + last,
            "tx": {"dpid": a, "port": ap, "ifname": f"s{a}-eth{ap}"},
            "rx": {"dpid": b, "port": bp, "ifname": f"s{b}-eth{bp}"},
        })
    doc = {
        "format": 1, "source": "heartbeat", "status": status,
        "stop_reason": None if status == "running" else "stopped by SIGTERM",
        "session": session, "pid": pid, "period_s": period_s, "ethertype": "0x88b5",
        "dst_mac": "02:4e:44:54:48:42",
        "clock": "*_mono are CLOCK_MONOTONIC seconds",
        "started_mono": now - 60.0 if started is None else started,
        "started_wall": 1_790_400_000.0,
        "written_mono": now - 0.5 if written is None else written,
        "written_wall": 1_790_400_060.0,
        "directions": records,
        "side_effects": side_effects if side_effects is not None else {
            "foreign_frames": 0, "forwarded_between_switches": 0, "forwarded_to_hosts": 0,
            "misdelivered": 0},
        "fabric": {"manifest": "/tmp/ndtwin_p4_switches.json", "manifest_sha256": "caefa665",
                   "switches": {f"s{d}": {"dpid": d, "pid": 1000 + d, "program": "basic.json"}
                                for d in (1, 2, 3, 4)}},
        "interfaces": {}, "watch_only": [],
    }
    doc.update(extra)
    return doc


class ReportDir:
    """A directory shaped like /run/ndtwin-lab (0755, owned by whoever runs the test) and the
    report in it, replaced atomically the way the daemon replaces it."""

    def __init__(self, testcase):
        self.dir = tempfile.mkdtemp(prefix="ndtwin_heartbeat_")
        testcase.addCleanup(shutil.rmtree, self.dir, True)
        os.chmod(self.dir, 0o755)
        self.path = os.path.join(self.dir, "heartbeat.json")
        self.uid = os.getuid()

    def write(self, doc, mode=0o644):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(doc if isinstance(doc, str) else json.dumps(doc))
        os.chmod(tmp, mode)
        os.replace(tmp, self.path)


class Clock:
    def __init__(self, now=10_000.0):
        self.now = now

    def __call__(self):
        return self.now


def read(rd, now, declared=POD_DIRECTIONS, period=PERIOD, uid=None):
    return hb.read_report(declared, now=now, period_expected=period, path=rd.path,
                          owner_uid=rd.uid if uid is None else uid)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class AReportThisProxyCanTrustTest(unittest.TestCase):
    """H.7 item 1: root-written, in a directory nobody else can write -- or not evidence."""

    def setUp(self):
        self.rd = ReportDir(self)
        self.now = 10_000.0

    def test_a_well_formed_report_of_this_fabric_is_usable(self):
        self.rd.write(a_report(self.now))
        reading = read(self.rd, self.now)
        self.assertTrue(reading.usable, reading.detail)
        self.assertIsNone(reading.reason)
        self.assertEqual(sorted(reading.heard), list(POD_DIRECTIONS))

    def test_no_report_at_all_is_a_heartbeat_that_is_not_running(self):
        reading = read(self.rd, self.now)
        self.assertFalse(reading.usable)
        self.assertEqual(reading.reason, hb.REASON_NOT_RUNNING)

    def test_a_report_owned_by_somebody_else_is_not_evidence(self):
        self.rd.write(a_report(self.now))
        reading = read(self.rd, self.now, uid=self.rd.uid + 1)
        self.assertFalse(reading.usable)
        self.assertEqual(reading.reason, hb.REASON_UNTRUSTED)

    def test_a_group_writable_report_is_not_evidence(self):
        self.rd.write(a_report(self.now), mode=0o664)
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_UNTRUSTED))

    def test_an_other_writable_report_is_not_evidence(self):
        self.rd.write(a_report(self.now), mode=0o646)
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_UNTRUSTED))

    def test_a_symlink_is_not_followed(self):
        real = os.path.join(self.rd.dir, "elsewhere.json")
        with open(real, "w") as fh:
            json.dump(a_report(self.now), fh)
        os.chmod(real, 0o644)
        os.symlink(real, self.rd.path)
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_UNTRUSTED))

    def test_a_directory_somebody_else_can_write_is_not_trusted(self):
        self.rd.write(a_report(self.now))
        os.chmod(self.rd.dir, 0o777)
        self.addCleanup(os.chmod, self.rd.dir, 0o755)
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_UNTRUSTED))

    def test_a_fifo_is_refused_without_blocking(self):
        os.mkfifo(self.rd.path, 0o644)
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_UNTRUSTED))

    def test_a_report_larger_than_any_heartbeat_writes_is_refused(self):
        self.rd.write(json.dumps(a_report(self.now)) + " " * (hb.MAX_REPORT_BYTES + 1))
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_UNTRUSTED))

    def test_a_report_that_does_not_parse_is_unreadable_not_a_crash(self):
        self.rd.write("{not json")
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_UNREADABLE))

    def test_something_else_s_json_is_unreadable(self):
        self.rd.write(a_report(self.now, source="lldp"))
        self.assertEqual(read(self.rd, self.now).reason, hb.REASON_UNREADABLE)
        self.rd.write(a_report(self.now, format=2))
        self.assertEqual(read(self.rd, self.now).reason, hb.REASON_UNREADABLE)

    def test_a_malformed_direction_is_unreadable(self):
        doc = a_report(self.now)
        doc["directions"][0]["tx"]["dpid"] = "one"
        self.rd.write(doc)
        self.assertEqual(read(self.rd, self.now).reason, hb.REASON_UNREADABLE)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class AReportThatIsAliveTest(unittest.TestCase):
    """H.7 item 2: running, and rewritten within two periods -- the daemon rewrites every period."""

    def setUp(self):
        self.rd = ReportDir(self)
        self.now = 10_000.0

    def test_a_stopped_heartbeat_is_not_running(self):
        self.rd.write(a_report(self.now, status="stopped"))
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_NOT_RUNNING))
        self.assertIn("stopped", reading.detail)

    def test_written_two_periods_ago_is_still_alive(self):
        self.rd.write(a_report(self.now, written=self.now - 2 * PERIOD))
        self.assertTrue(read(self.rd, self.now).usable)

    def test_written_longer_ago_than_two_periods_is_stale(self):
        self.rd.write(a_report(self.now, written=self.now - 2 * PERIOD - 0.1))
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_STALE))

    def test_written_in_the_future_is_not_this_clock(self):
        self.rd.write(a_report(self.now, written=self.now + 30.0))
        self.assertEqual(read(self.rd, self.now).reason, hb.REASON_STALE)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class AReportAboutThisFabricAtThisPeriodTest(unittest.TestCase):
    """H.7 items 3 and 6."""

    def setUp(self):
        self.rd = ReportDir(self)
        self.now = 10_000.0

    def test_another_period_is_a_mismatch_the_timeout_would_be_wrong_for(self):
        self.rd.write(a_report(self.now, period_s=2))
        reading = read(self.rd, self.now, period=PERIOD)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_PERIOD_MISMATCH))

    def test_a_declared_direction_the_report_does_not_carry_is_a_fabric_mismatch(self):
        self.rd.write(a_report(self.now, directions=POD_DIRECTIONS[1:]))
        reading = read(self.rd, self.now)
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_FABRIC_MISMATCH))
        self.assertEqual(list(reading.missing), [POD_DIRECTIONS[0]])

    def test_no_declared_direction_at_all_is_not_usable(self):
        self.rd.write(a_report(self.now))
        reading = read(self.rd, self.now, declared=())
        self.assertEqual((reading.usable, reading.reason), (False, hb.REASON_FABRIC_MISMATCH))

    def test_a_direction_the_package_does_not_declare_is_disclosed_and_ignored(self):
        extra = POD_DIRECTIONS + ((9, 1, 8, 1),)
        self.rd.write(a_report(self.now, directions=extra))
        reading = read(self.rd, self.now)
        self.assertTrue(reading.usable, reading.detail)
        self.assertEqual(list(reading.undeclared), [(9, 1, 8, 1)])
        self.assertNotIn((9, 1, 8, 1), reading.heard)

    def test_the_side_effect_counters_travel_with_the_reading(self):
        effects = {"foreign_frames": 0, "forwarded_between_switches": 2,
                   "forwarded_to_hosts": 1, "misdelivered": 0}
        self.rd.write(a_report(self.now, side_effects=effects))
        self.assertEqual(read(self.rd, self.now).side_effects, effects)


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class TheEpochFromWhichSilenceCountsTest(unittest.TestCase):
    """HeartbeatEvidence.poll: (link, heard, at) per declared direction, or None when frozen."""

    def setUp(self):
        self.rd = ReportDir(self)
        self.clock = Clock()
        self.ev = hb.HeartbeatEvidence(POD_DIRECTIONS, period_s=PERIOD, clock=self.clock,
                                       path=self.rd.path, owner_uid=self.rd.uid)

    def by_link(self, evidence):
        return {link: (heard, at) for link, heard, at in evidence}

    def test_a_new_session_counts_from_the_daemons_own_start(self):
        now = self.clock.now
        self.rd.write(a_report(now, {CUT[0]: None}, started=now - 20.0))
        reading, evidence = self.ev.poll()
        got = self.by_link(evidence)
        self.assertEqual(got[CUT[0]], (False, now - 20.0))
        self.assertEqual(got[CUT[1]], (True, now - 1.0))

    def test_an_unusable_report_is_no_evidence_at_all(self):
        self.rd.write(a_report(self.clock.now, status="stopped"))
        reading, evidence = self.ev.poll()
        self.assertIsNone(evidence)
        self.assertEqual(self.ev.last().reason, hb.REASON_NOT_RUNNING)

    def test_a_gap_in_the_same_session_restarts_the_epoch_at_the_report_that_ended_it(self):
        now = self.clock.now
        self.rd.write(a_report(now, started=now - 100.0))
        self.ev.poll()
        # The daemon stalls: nothing written for a minute, then it writes again.
        self.clock.now = now + 60.0
        self.rd.write(a_report(now, started=now - 100.0, written=now - 0.5))
        _r, frozen = self.ev.poll()
        self.assertIsNone(frozen, "a report a minute old is stale, not evidence")
        self.clock.now = now + 61.0
        back = now + 60.5
        self.rd.write(a_report(self.clock.now, {CUT[0]: now - 1.0}, started=now - 100.0,
                               written=back))
        _r, evidence = self.ev.poll()
        # CUT[0] was last heard BEFORE the gap: silent since the epoch, and the epoch is `back`.
        self.assertEqual(self.by_link(evidence)[CUT[0]], (False, back))

    def test_a_new_session_after_a_stop_counts_from_its_own_start(self):
        now = self.clock.now
        self.rd.write(a_report(now, session="aaaaaaaaaaaaaaaa", started=now - 100.0))
        self.ev.poll()
        self.rd.write(a_report(now, {CUT[0]: None}, session="bbbbbbbbbbbbbbbb",
                               started=now - 3.0))
        _r, evidence = self.ev.poll()
        self.assertEqual(self.by_link(evidence)[CUT[0]], (False, now - 3.0))

    def test_heard_before_the_epoch_is_not_heard(self):
        now = self.clock.now
        self.rd.write(a_report(now, {CUT[0]: now - 50.0}, started=now - 20.0))
        _r, evidence = self.ev.poll()
        self.assertEqual(self.by_link(evidence)[CUT[0]], (False, now - 20.0))


@unittest.skipUnless(HAVE_PROXY, "proxy dependencies not available in this interpreter")
class OneRuleOneConstantTest(unittest.TestCase):
    """The report path is the helper's; the period the proxy compares with is its own LLDP one."""

    def test_the_report_path_is_the_one_the_root_helper_writes(self):
        with open(HELPER) as fh:
            text = fh.read()
        run_dir = re.search(r"^HB_RUN_DIR=(\S+)$", text, re.M).group(1)
        self.assertIn('$HB_RUN_DIR/heartbeat.json', text)
        self.assertEqual(hb.REPORT_PATH, f"{run_dir}/heartbeat.json")

    def test_the_owner_is_the_uid_the_helper_expects_of_its_daemon(self):
        with open(HELPER) as fh:
            expect = re.search(r"^HB_EXPECT_UID=(\d+)$", fh.read(), re.M).group(1)
        self.assertEqual(hb.REPORT_OWNER_UID, int(expect))

    def test_the_topology_manager_reads_its_period_from_the_lldp_constant(self):
        # Moved off its default, so a copy of the number (5) cannot pass for reading the constant
        # -- what NDTWIN_P4_BEACON_S does to a real proxy.
        from unittest import mock

        topo = tm.TopologyManager()
        rd = ReportDir(self)
        with mock.patch.object(tm, "LLDP_BEACON_INTERVAL_S", 2.5):
            evidence = topo.start_heartbeat_watchdog(path=rd.path, owner_uid=rd.uid)
        self.addCleanup(topo.stop_link_watchdog)
        self.assertEqual(evidence.period_s, 2.5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
