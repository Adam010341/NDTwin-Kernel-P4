"""
The veth heartbeat's report, as this proxy reads it -- TICKET-P4-heartbeat segment W.

[Co-developed with claude code -- Adam]

The root helper (`sudo ndtwin-lab heartbeat start`, segment H) sends one frame per inter-switch
direction per period over a FOREIGN fabric's veths -- programs with no controller header, where
LLDP cannot run -- and writes what it HEARD to /run/ndtwin-lab/heartbeat.json. It decides nothing:
no up, no down, no reroute (ruling 3: this proxy does not get root; it reads what the root helper
reports). What turns "last heard at t" into a verdict is this proxy's, with its own constants:

  * THE RULE IS THE BEACON RULE. This module only turns the report into beacon EVIDENCE -- "this
    direction was last heard at t", or "silent since t" -- which TopologyManager enters through
    the first cut's reserved `report_external_link_state(..., at=)` (TICKET-P4-roles 2.4), and
    `check_link_beacons` then decides with LINK_BEACON_TIMEOUT_S / LINK_STARTUP_GRACE_S exactly as
    it does for LLDP, and `_notify_link` tells the kernel (段 W: "常數與自家 fabric 共用、不另寫
    一份"). There is no timeout in this file. The period is compared with the proxy's own
    LLDP_BEACON_INTERVAL_S, handed in by TopologyManager rather than imported, because that
    module imports this one.
  * TRUSTED OR NOT EVIDENCE (segment H's H.7 item 1). A regular file, not a symlink, owned by
    root and not group/other writable, in a root-owned directory nobody else can write. A report
    adam could write would let any local process cut a link in the twin -- or hide a real cut.
  * ALIVE OR FROZEN (H.7 item 2). `status: running` and rewritten within two periods (the daemon
    rewrites every period). A report that is not usable is NO evidence at all -- not "every
    direction silent" -- and the watchdog judges nothing on it while it lasts: the daemon's death
    is not the network's.
  * THIS FABRIC, THIS PERIOD (H.7 items 3 and 6). Every direction the package declares must be in
    the report; one missing makes it a report about something else. Directions the package does
    not declare are disclosed and ignored. A period other than the proxy's would make the
    3-period timeout the wrong multiple of it, so that is not usable either.

The one piece of state kept here is the EPOCH from which silence counts. A new session starts it
at the daemon's own start (`started_mono`); a report that comes back after being unusable
restarts it at that report's `written_mono` -- a direction nobody could hear while the heartbeat
was away is not a direction that went quiet.

`*_mono` in the report is CLOCK_MONOTONIC, which is `time.monotonic()` on Linux -- the proxy's
own clock (the daemon says so in the report's `clock` key).
"""

from __future__ import annotations

import errno
import json
import os
import stat
import threading
import time
from dataclasses import dataclass, field
from typing import Optional

#: Where the root helper's daemon writes. Pinned by tests/test_link_heartbeat.py to the helper's
#: own `HB_RUN_DIR` -- one path, two readers would be a proxy reading a file nobody writes.
REPORT_PATH = "/run/ndtwin-lab/heartbeat.json"
#: Whose file it must be: the helper's `HB_EXPECT_UID` (its daemon runs as root).
REPORT_OWNER_UID = 0
REPORT_FORMAT = 1
REPORT_SOURCE = "heartbeat"
#: The daemon's report is a few KiB; anything past this is not one.
MAX_REPORT_BYTES = 1 << 20
#: A running daemon rewrites the report every period, so two periods without a write is a daemon
#: that is gone or hung (H.7 item 2).
ALIVE_PERIODS = 2
#: How far in the future `written_mono` may lie before it is not this machine's clock.
CLOCK_SLACK_S = 1.0

#: Why a reading is not usable -- the words `reroute.reason` and `heartbeat.state` carry.
REASON_NOT_RUNNING = "heartbeat_not_running"
REASON_STALE = "heartbeat_stale"
REASON_UNTRUSTED = "heartbeat_report_untrusted"
REASON_UNREADABLE = "heartbeat_report_unreadable"
REASON_PERIOD_MISMATCH = "heartbeat_period_mismatch"
REASON_FABRIC_MISMATCH = "heartbeat_fabric_mismatch"


class ReportUntrusted(Exception):
    """The report, or the directory it is in, is not one only root could have written."""


@dataclass(frozen=True)
class Reading:
    """One read of the report. `usable` False means: no evidence, and `reason` says why."""

    usable: bool
    reason: Optional[str]
    detail: str
    status: Optional[str] = None
    session: Optional[str] = None
    pid: Optional[int] = None
    period_s: Optional[float] = None
    started_mono: Optional[float] = None
    written_mono: Optional[float] = None
    #: now - written_mono when the reading was taken.
    age_s: Optional[float] = None
    #: declared direction -> last_heard_mono (None = never heard). Only when usable.
    heard: dict = field(default_factory=dict)
    #: Declared directions the report does not carry / carried directions nobody declared.
    missing: tuple = ()
    undeclared: tuple = ()
    #: The daemon's own counters, verbatim: forwarded_to_hosts > 0 is ruling 4's stop condition.
    side_effects: Optional[dict] = None


def _check_owner_and_mode(what, st, owner_uid):
    if st.st_uid != owner_uid:
        raise ReportUntrusted(f"{what} is owned by uid {st.st_uid}, not {owner_uid}")
    if st.st_mode & 0o022:
        raise ReportUntrusted(f"{what} is group- or other-writable "
                              f"(mode {oct(stat.S_IMODE(st.st_mode))})")


def read_trusted(path, owner_uid=REPORT_OWNER_UID):
    """The report's bytes. FileNotFoundError when there is none; ReportUntrusted when it, or the
    directory it is in, is not one only `owner_uid` could have written."""
    directory = os.path.dirname(path) or "."
    dst = os.lstat(directory)
    if stat.S_ISLNK(dst.st_mode) or not stat.S_ISDIR(dst.st_mode):
        raise ReportUntrusted(f"{directory} is not a plain directory")
    _check_owner_and_mode(directory, dst, owner_uid)
    try:
        # O_NOFOLLOW: a symlink is refused rather than followed. O_NONBLOCK: a FIFO planted in
        # its place opens at once (and is then refused as not a regular file) instead of hanging
        # the watchdog thread on a writer that never comes.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise ReportUntrusted(f"{path} is a symlink") from None
        raise
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ReportUntrusted(f"{path} is not a regular file")
        _check_owner_and_mode(path, st, owner_uid)
        chunks, total = [], 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_REPORT_BYTES:
                raise ReportUntrusted(f"{path} is larger than {MAX_REPORT_BYTES} bytes")
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def _number(value):
    """A float, or None for anything that is not a real number (bools included)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _link_of(record):
    """(tx dpid, tx port, rx dpid, rx port) -- the key LLDP evidence uses (H.7 item 4)."""
    tx, rx = record["tx"], record["rx"]
    link = (tx["dpid"], tx["port"], rx["dpid"], rx["port"])
    if not all(isinstance(v, int) and not isinstance(v, bool) for v in link):
        raise ValueError(f"direction {record.get('id')!r} has a non-integer endpoint: {link}")
    return link


def read_report(declared, *, now, period_expected, path=REPORT_PATH,
                owner_uid=REPORT_OWNER_UID):
    """Read the report once and say whether it is evidence for `declared` at `now`."""
    declared = set(declared)
    try:
        raw = read_trusted(path, owner_uid)
    except FileNotFoundError:
        return Reading(False, REASON_NOT_RUNNING,
                       f"no report at {path}: no heartbeat has run on this machine since boot")
    except ReportUntrusted as exc:
        return Reading(False, REASON_UNTRUSTED,
                       f"{exc} -- only a report root alone could have written is evidence")
    except OSError as exc:
        return Reading(False, REASON_UNREADABLE, f"could not read {path}: {exc}")
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        return Reading(False, REASON_UNREADABLE, f"{path} does not parse: {exc}")
    if not isinstance(doc, dict) or doc.get("format") != REPORT_FORMAT \
            or doc.get("source") != REPORT_SOURCE:
        return Reading(False, REASON_UNREADABLE,
                       f"{path} is not a heartbeat report this proxy reads (format "
                       f"{doc.get('format') if isinstance(doc, dict) else None!r}, source "
                       f"{doc.get('source') if isinstance(doc, dict) else None!r})")
    side = doc.get("side_effects") if isinstance(doc.get("side_effects"), dict) else None
    status = doc.get("status")
    common = {"status": status, "session": doc.get("session"), "pid": doc.get("pid"),
              "side_effects": side}
    if status != "running":
        return Reading(False, REASON_NOT_RUNNING,
                       f"the report says status {status!r} ({doc.get('stop_reason')})", **common)
    period = _number(doc.get("period_s"))
    written = _number(doc.get("written_mono"))
    started = _number(doc.get("started_mono"))
    if period is None or period <= 0 or written is None or started is None:
        return Reading(False, REASON_UNREADABLE,
                       "the report lacks a usable period_s, written_mono or started_mono",
                       **common)
    common.update(period_s=period, started_mono=started, written_mono=written,
                  age_s=round(now - written, 3))
    age = now - written
    if age > ALIVE_PERIODS * period or age < -CLOCK_SLACK_S:
        return Reading(False, REASON_STALE,
                       f"the report says running and was written {age:.1f} s ago; a running "
                       f"daemon rewrites it every {period:g} s", **common)
    if float(period) != float(period_expected):
        return Reading(False, REASON_PERIOD_MISMATCH,
                       f"the heartbeat's period is {period:g} s and this proxy's beacon interval "
                       f"is {period_expected:g} s: the timeout (3 intervals) would be the wrong "
                       f"multiple of it", **common)
    reported = {}
    try:
        for record in doc.get("directions") or []:
            last = record.get("last_heard_mono")
            if last is not None and _number(last) is None:
                raise ValueError(f"last_heard_mono {last!r} is not a number")
            reported[_link_of(record)] = None if last is None else float(last)
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        return Reading(False, REASON_UNREADABLE, f"a direction in the report is malformed: {exc}",
                       **common)
    missing = tuple(sorted(declared - set(reported)))
    undeclared = tuple(sorted(set(reported) - declared))
    common.update(missing=missing, undeclared=undeclared)
    if not declared or missing:
        return Reading(False, REASON_FABRIC_MISMATCH,
                       ("this fabric declares no inter-switch direction to judge" if not declared
                        else f"{len(missing)} declared direction(s) are not in the report, so it "
                             f"is about another fabric: {list(missing)[:4]}"), **common)
    return Reading(True, None,
                   f"running, written {age:.1f} s ago, {len(declared)} declared direction(s)"
                   + (f"; {len(undeclared)} undeclared one(s) ignored" if undeclared else ""),
                   heard={link: reported[link] for link in declared}, **common)


class HeartbeatEvidence:
    """The report, polled once per watchdog pass, as evidence per declared direction.

    `poll()` answers `(reading, evidence)`. `evidence` is None when the reading is not usable --
    frozen, nothing to judge -- and otherwise one `(link, heard, at)` per declared direction:
    heard at `at`, or silent since `at` (the epoch). Thread-safe: the watchdog thread polls, the
    HTTP handlers read `last()`.
    """

    def __init__(self, declared, *, period_s, clock=time.monotonic, path=REPORT_PATH,
                 owner_uid=REPORT_OWNER_UID):
        self.declared = tuple(sorted(set(declared)))
        self.period_s = period_s
        self.path = path
        self._clock = clock
        self._owner_uid = owner_uid
        self._lock = threading.Lock()
        self._last = None
        self._session = None
        self._epoch = None
        self._was_usable = False

    def poll(self):
        reading = read_report(self.declared, now=self._clock(), period_expected=self.period_s,
                              path=self.path, owner_uid=self._owner_uid)
        with self._lock:
            self._last = reading
            if not reading.usable:
                self._was_usable = False
                return reading, None
            if reading.session != self._session:
                # A new daemon: silence counts from its own start, not from before it existed.
                self._session, self._epoch = reading.session, reading.started_mono
            elif not self._was_usable:
                # The same daemon, back after a gap: nothing it did not hear while away counts.
                self._epoch = reading.written_mono
            self._was_usable = True
            epoch = self._epoch
        evidence = []
        for link in self.declared:
            last = reading.heard.get(link)
            if last is not None and last >= epoch:
                evidence.append((link, True, last))
            else:
                evidence.append((link, False, epoch))
        return reading, evidence

    def last(self):
        """The most recent reading, or None before the first poll."""
        with self._lock:
            return self._last
