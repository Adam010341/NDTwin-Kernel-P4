#!/usr/bin/env python3
"""Segment S's judge: reads the heartbeat report and answers timing questions about it.

[Co-developed with claude code -- Adam]

🔴 THE RULE IS THE PROXY'S, WITH THE PROXY'S CONSTANT. A direction counts as "not heard" when
`now - last_heard_mono > LINK_BEACON_TIMEOUT_S` -- the beacon rule `check_link_beacons` applies to
LLDP today, and the rule segment W is to apply to the heartbeat. The constant is imported from
p4_proxy/proxy_agent/topology_manager.py by the caller (`timeout` below), never written here.
`now` is this process's time.monotonic(), which on Linux is CLOCK_MONOTONIC -- the clock the
daemon stamps `*_mono` with, and the proxy's own.

What this measures is the REPORT-LEVEL detection: the moment the proxy COULD call a direction
down if it read the report then. Segment W's end-to-end adds at most one watchdog pass
(LINK_WATCHDOG_INTERVAL_S) on top, and the kernel's reaction after that.

Pure functions first (the --self-test drives every one of them against a synthetic report it
must accept and one it must reject), then the thin polling wrappers the spike calls.

    hb_watch.py now
    hb_watch.py session   <report> <pid>                     -> the session of daemon <pid> while running, or ""
    hb_watch.py started-pid <start-output>                   -> the pid `heartbeat start` says it started, or ""
    hb_watch.py all-heard <report> <after_mono>              -> OK n/n | BAD ...
    hb_watch.py wait-heard <report> <dirs> <after_mono> <cap_s>
    hb_watch.py wait-down  <report> <dirs> <t0_mono> <timeout_s> <cap_s>
    hb_watch.py others-up  <report> <dirs> <timeout_s>
    hb_watch.py summary   <cycles.tsv> <timeout_s> <period_s>
    hb_watch.py census-verdict <sniff-dir> <report-snapshot>
    hb_watch.py first-hit <sniff-dir>                        -> the first host that saw one, or ""
    hb_watch.py sim-init <dir> [<json overrides>]           -> (self-test only) a simulated daemon
    hb_watch.py --self-test

<dirs> is "1:3>3:1,3:1>1:3" -- tx dpid:port > rx dpid:port, comma separated.

🔴 HB_WATCH_SIM=<dir>, when set, puts every verb that reads the heartbeat report onto the SELF-TEST'S
simulated daemon (class Sim) at the fake time in <dir>/clock, and every wait moves that clock on
instead of sleeping. It exists so the spike's --self-test can run its own detection loop against a
known timeline.
"""
import contextlib
import glob
import io
import json
import math
import os
import random
import re
import statistics
import sys
import tempfile
import time


def load(path):
    with open(path) as fh:
        return json.load(fh)


# ------------------------------------------------------------ the clock and the report (round 8)
#: 🔴 THE SELF-TEST'S TIMELINE, NEVER A LAB'S: set, it replaces the clock, every wait and the report.
SIM_ENV = "HB_WATCH_SIM"


def sim_dir():
    return os.environ.get(SIM_ENV) or ""


def clock():
    """CLOCK_MONOTONIC -- the daemon's clock and the proxy's -- or the simulated one."""
    d = sim_dir()
    if not d:
        return time.monotonic()
    with open(os.path.join(d, "clock")) as fh:
        return float(fh.read())


def nap(seconds):
    """Sleep -- or move the simulated clock on by that much."""
    seconds = max(0.0, seconds)
    d = sim_dir()
    if not d:
        time.sleep(seconds)
        return
    t = clock() + seconds
    with open(os.path.join(d, "clock"), "w") as fh:
        fh.write(f"{t:.6f}\n")


def report(path):
    """The heartbeat report at `path` -- or the simulated daemon's, as of the simulated clock."""
    d = sim_dir()
    if not d:
        return load(path)
    return Sim(d).report(clock())


class Sim:
    """🔴 THE SELF-TEST'S HEARTBEAT DAEMON, reduced to its timing (round 8). Never a lab's.

    Modelled on run_daemon in tools/test_workflow/ndtwin-lab (READ, not run) and on the two live
    runs' reports (09-26): round k sends one frame per direction at s_k = started + delta + k*period
    (live: 1.7-7.0 ms after started_mono + 5k); the report is written at `started` (nothing sent),
    once per round at s_k + w -- BEFORE that round's frames are heard -- and, when a frame was
    heard in round k, once more at s_k + w + lag (REPORT_MIN_INTERVAL_S = 0.5 after the previous
    write: live, last_heard and written_mono 0.5006 s apart). A direction's round-k frame is heard
    at s_k + eps (eps > w; live 4.5-7 ms) unless a `loss 100%` netem sat on its tx interface at
    s_k (scope "tx"; scope "cable": on either end of its cable), or k is a deaf round (sent, heard
    by nobody). `sent` counts the rounds; `heard` is not simulated (None).

    <dir>/sim.json: started, period, delta, w, eps, lag, scope, deaf_rounds, links
      ([[a_if, a_dpid, a_port, b_if, b_dpid, b_port], ...], each cable once: both directions).
    <dir>/netem.log: "<add|del> <dev> <t> [netem params]" -- at the fake time the self-test's fake tc
      returned. <dir>/clock: the fake CLOCK_MONOTONIC.
    """

    DEFAULT = {"started": 1000.0, "period": 5.0, "delta": 0.003, "w": 0.004, "eps": 0.006,
               "lag": 0.5, "scope": "tx", "deaf_rounds": [],
               # pod-topo, as the live reports have it: s1-s3, s1-s4, s2-s4, s2-s3
               "links": [["s1-eth3", 1, 3, "s3-eth1", 3, 1], ["s1-eth4", 1, 4, "s4-eth2", 4, 2],
                         ["s2-eth3", 2, 3, "s4-eth1", 4, 1], ["s2-eth4", 2, 4, "s3-eth2", 3, 2]]}

    def __init__(self, d):
        with open(os.path.join(d, "sim.json")) as fh:
            c = dict(self.DEFAULT, **json.load(fh))
        self.S, self.P = float(c["started"]), float(c["period"])
        self.delta, self.w, self.eps, self.lag = (float(c[k]) for k in ("delta", "w", "eps", "lag"))
        self.scope, self.deaf = c["scope"], {int(k) for k in c["deaf_rounds"]}
        self.dirs = []
        for a_if, a_dp, a_pt, b_if, b_dp, b_pt in c["links"]:
            self.dirs.append(((a_dp, a_pt, a_if), (b_dp, b_pt, b_if)))
            self.dirs.append(((b_dp, b_pt, b_if), (a_dp, a_pt, a_if)))
        self.netem = {}                     # dev -> [[added, removed or None]], loss 100% only
        try:
            with open(os.path.join(d, "netem.log")) as fh:
                lines = fh.read().splitlines()
        except OSError:
            lines = []
        for line in lines:
            p = line.split()
            if len(p) < 3:
                continue
            op, dev, t = p[0], p[1], float(p[2])
            if op == "add" and "loss 100%" in " ".join(p[3:]):
                self.netem.setdefault(dev, []).append([t, None])
            elif op == "del":
                for iv in self.netem.get(dev, []):
                    if iv[1] is None:
                        iv[1] = t

    def send(self, k):
        return self.S + self.delta + k * self.P

    def last_round(self, t):
        """The last round sent at or before t; -1 before the first."""
        return math.floor((t - self.S - self.delta) / self.P) if t >= self.send(0) else -1

    def blocked(self, d, t):
        devs = (d[0][2],) if self.scope == "tx" else (d[0][2], d[1][2])
        return any(a <= t and (b is None or t < b) for dev in devs for a, b in self.netem.get(dev, []))

    def heard_in(self, d, k):
        return k >= 0 and k not in self.deaf and not self.blocked(d, self.send(k))

    def last_write(self, t):
        if t < self.S:
            return None
        writes = [self.S]
        k = self.last_round(t - self.w)
        if k >= 0:
            writes.append(self.send(k) + self.w)
            if self.send(k) + self.w + self.lag <= t and any(self.heard_in(d, k) for d in self.dirs):
                writes.append(self.send(k) + self.w + self.lag)
        return max(writes)

    def report(self, t):
        written = self.last_write(t)
        if written is None:
            raise FileNotFoundError("the simulated daemon has written no report yet")
        directions = []
        for d in self.dirs:
            (tdp, tpt, tif), (rdp, rpt, rif) = d
            last = None
            for j in range(self.last_round(written - self.eps), -1, -1):
                if self.heard_in(d, j):
                    last = self.send(j) + self.eps
                    break
            directions.append({"tx": {"dpid": tdp, "port": tpt, "ifname": tif},
                               "rx": {"dpid": rdp, "port": rpt, "ifname": rif},
                               "sent": self.last_round(written) + 1, "heard": None, "last_heard_mono": last})
        return {"format": 1, "source": "heartbeat (SIMULATED -- hb_watch.py Sim)", "status": "running",
                "pid": 4242, "session": "5a5a5a5a5a5a5a5a", "period_s": self.P, "started_mono": self.S,
                "written_mono": written, "directions": directions}


def parse_dirs(spec):
    out = []
    for part in spec.split(","):
        tx, rx = part.split(">")
        a, ap = (int(x) for x in tx.split(":"))
        b, bp = (int(x) for x in rx.split(":"))
        out.append((a, ap, b, bp))
    return out


def key(rec):
    return (rec["tx"]["dpid"], rec["tx"]["port"], rec["rx"]["dpid"], rec["rx"]["port"])


def find(doc, dirs):
    """The report's records for these directions, in order; KeyError naming a missing one."""
    by = {key(r): r for r in doc.get("directions", [])}
    missing = [d for d in dirs if d not in by]
    if missing:
        raise KeyError(f"the report has no direction {missing}")
    return [by[d] for d in dirs]


def running(doc):
    return doc.get("status") == "running"


def not_heard(rec, now, timeout):
    """The proxy's rule: silent for longer than `timeout` (never heard = silent since start)."""
    last = rec.get("last_heard_mono")
    return last is None or now - last > timeout


def heard_after(rec, t):
    last = rec.get("last_heard_mono")
    return last is not None and last > t


def all_heard(doc, after):
    recs = doc.get("directions", [])
    late = [f"{r['tx']['ifname']}->{r['rx']['ifname']}" for r in recs if not heard_after(r, after)]
    if not recs:
        return "BAD the report has no direction at all"
    if late:
        return f"BAD {len(recs) - len(late)}/{len(recs)} directions heard since {after:.1f}; not: {', '.join(late)}"
    return f"OK {len(recs)}/{len(recs)} directions heard"


def others_up(doc, dirs, now, timeout):
    """Every direction NOT in `dirs` is still heard -- the cut took only the link it was aimed at."""
    cut = set(dirs)
    bad = [f"{r['tx']['ifname']}->{r['rx']['ifname']}" for r in doc.get("directions", [])
           if key(r) not in cut and not_heard(r, now, timeout)]
    return "OK" if not bad else "BAD collateral: " + ", ".join(bad)


def summary(rows, timeout, period):
    """rows: [(cycle, down_s or None, up_s or None)] -> lines, and whether every cycle detected."""
    downs = [r[1] for r in rows if r[1] is not None]
    ups = [r[2] for r in rows if r[2] is not None]
    lines = [f"cycles {len(rows)}: down detected {len(downs)}/{len(rows)}, recovery detected "
             f"{len(ups)}/{len(rows)}"]
    for label, xs in (("cut -> both directions not heard", downs), ("restore -> both heard again", ups)):
        if xs:
            lines.append(f"  {label}: min {min(xs):.2f} s  median {statistics.median(xs):.2f} s  "
                         f"max {max(xs):.2f} s  (n={len(xs)})")
    lines.append(f"  expected from the constants alone (INFERRED): down in ({timeout - period:.0f}, "
                 f"{timeout:.0f}] s after the cut plus one poll; up in (0, {period:.0f}] s; "
                 f"segment W adds <= one watchdog pass")
    ok = len(downs) == len(rows) == len(ups) and len(rows) > 0
    return lines, ok


def census_verdict(sniffs, report):
    """sniffs: [{host, frames_hb, ...}]; report: the heartbeat report at the end of the window.

    STOP (ruling 4) if any host saw a heartbeat frame or the daemon counted one leaving a
    host-facing port. Otherwise OK, with the switch-side counters as the disclosure.
    """
    seen = [s for s in sniffs if s.get("frames_hb", 0) > 0]
    se = (report or {}).get("side_effects") or {}
    to_hosts = se.get("forwarded_to_hosts", 0)
    if any(s.get("error") for s in sniffs):
        return "BAD a sniffer did not run: " + "; ".join(f"{s.get('host')}: {s.get('error')}"
                                                          for s in sniffs if s.get("error"))
    if not sniffs:
        return "BAD no host was sniffed"
    if seen or to_hosts:
        return ("STOP heartbeat frames reached a host (ruling 4): "
                + ", ".join(f"{s['host']} {s['frames_hb']}" for s in seen)
                + f"; daemon forwarded_to_hosts={to_hosts}")
    return (f"OK no host saw a heartbeat frame ({len(sniffs)} host(s) sniffed); switch side: "
            f"forwarded_between_switches={se.get('forwarded_between_switches', 0)} "
            f"misdelivered={se.get('misdelivered', 0)} foreign={se.get('foreign_frames', 0)}")


def first_hit(sniffs):
    """The first host that saw a heartbeat frame, or "" -- the census's cue to stop everything."""
    for s in sniffs:
        if (s.get("frames_hb") or 0) > 0:
            return s.get("host") or "?"
    return ""


def session_of(doc, pid):
    """The session the census sniffs for: that of daemon `pid`, and only while its report says it
    is running; "" otherwise.

    Judge R4-1 (round-4 verdict): `start` can return while the report still holds the previous
    arm's final "stopped" document (the daemon writes its pidfile, which is what `start` waits
    for, an instant before its first report), and a daemon killed without its clean exit leaves a
    "running" report with its own pid behind. Neither session is this arm's.
    """
    if doc.get("status") != "running":
        return ""
    if doc.get("pid") != pid:
        return ""
    return doc.get("session") or ""


def started_pid(text):
    """The pid in `ndtwin-lab heartbeat start`'s "heartbeat started (pid N; ...)" answer, or None.

    Only that answer counts. "heartbeat already running (pid N)" also exits 0, but this call
    started nothing: the daemon is somebody else's, or an earlier arm's that was not stopped.
    """
    for line in text.splitlines():
        m = re.match(r"heartbeat started \(pid (\d+);", line)
        if m:
            return int(m.group(1))
    return None


# ------------------------------------------------------------------------------ polling wrappers
def wait_heard(path, dirs, after, cap):
    """Seconds (from `after`) until every one of `dirs` has been heard after `after`."""
    end = clock() + cap
    while clock() < end:
        try:
            doc = report(path)
            if running(doc) and all(heard_after(r, after) for r in find(doc, dirs)):
                return max(r["last_heard_mono"] for r in find(doc, dirs)) - after
        except (OSError, ValueError, KeyError):
            pass
        nap(0.1)
    return None


def wait_down(path, dirs, t0, timeout, cap):
    """Seconds after t0 until every one of `dirs` is not heard by the proxy's rule."""
    end = t0 + cap
    while clock() < end:
        now = clock()
        try:
            doc = report(path)
            if not running(doc):
                return None
            if all(not_heard(r, now, timeout) for r in find(doc, dirs)):
                return now - t0
        except (OSError, ValueError, KeyError):
            pass
        nap(0.1)
    return None


def self_test():
    rc = 0

    def expect(label, want_prefix, got):
        nonlocal rc
        ok = str(got).startswith(want_prefix)
        print(f"  {'ok' if ok else '🔴'}    {label:58s} {str(got)[:90]}")
        if not ok:
            rc = 1

    def rec(a, ap, b, bp, last):
        return {"tx": {"dpid": a, "port": ap, "ifname": f"s{a}-eth{ap}"},
                "rx": {"dpid": b, "port": bp, "ifname": f"s{b}-eth{bp}"}, "last_heard_mono": last}
    cables = [(1, 3, 3, 1), (1, 4, 4, 2), (2, 3, 4, 1), (2, 4, 3, 2)]
    dirs8 = cables + [(b, bp, a, ap) for a, ap, b, bp in cables]
    fresh = {"status": "running", "directions": [rec(*d, 100.0) for d in dirs8]}
    cut = [(1, 3, 3, 1), (3, 1, 1, 3)]
    stale = {"status": "running",
             "directions": [rec(*d, 80.0 if d in cut else 100.0) for d in dirs8]}
    half = {"status": "running",
            "directions": [rec(*d, 80.0 if d == cut[0] else 100.0) for d in dirs8]}
    never = {"status": "running",
             "directions": [rec(*d, None if d in cut else 100.0) for d in dirs8]}
    print("hb_watch --self-test (synthetic reports; no lab)")
    expect("all heard after 99", "OK 8/8", all_heard(fresh, 99.0))
    expect("not all heard after 101", "BAD", all_heard(fresh, 101.0))
    expect("an empty report is not all heard", "BAD", all_heard({"directions": []}, 0))
    expect("both cut directions silent 20 s > 15: not heard", "True",
           all(not_heard(r, 100.0, 15) for r in find(stale, cut)))
    expect("silent 10 s is still heard", "False",
           all(not_heard(r, 90.0, 15) for r in find(stale, cut)))
    expect("only one direction silent: not both down", "False",
           all(not_heard(r, 100.0, 15) for r in find(half, cut)))
    expect("never heard counts as silent", "True", all(not_heard(r, 100.0, 15) for r in find(never, cut)))
    expect("a heard-after answer needs a newer stamp", "True",
           heard_after(find(fresh, cut)[0], 99.9) and not heard_after(find(fresh, cut)[0], 100.0))
    expect("no collateral when only the cut is stale", "OK", others_up(stale, cut, 100.0, 15))
    expect("collateral when another direction is stale", "BAD", others_up(stale, cut[:1], 100.0, 15))
    try:
        find(fresh, [(9, 9, 9, 9)])
        expect("a direction the report lacks is an error", "KeyError", "no error")
    except KeyError:
        expect("a direction the report lacks is an error", "KeyError", "KeyError")
    res = summary([(1, 12.1, 3.0), (2, 14.0, 1.0)], 15, 5)
    expect("summary: two detected cycles pass", "True", res[1])
    expect("summary: states min/median/max", "  cut", res[0][1])
    res = summary([(1, None, 3.0)], 15, 5)
    expect("summary: an undetected cut fails", "False", res[1])
    res = summary([], 15, 5)
    expect("summary: no cycle is not a pass", "False", res[1])
    clean = {"side_effects": {"forwarded_to_hosts": 0, "forwarded_between_switches": 2}}
    leak = {"side_effects": {"forwarded_to_hosts": 1}}
    expect("census: nothing seen", "OK", census_verdict([{"host": "h1", "frames_hb": 0}], clean))
    expect("census: a host saw one", "STOP", census_verdict([{"host": "h1", "frames_hb": 1}], clean))
    expect("census: the daemon saw one leave a host port", "STOP",
           census_verdict([{"host": "h1", "frames_hb": 0}], leak))
    expect("census: a sniffer that did not run is not a clean host", "BAD",
           census_verdict([{"host": "h1", "error": "mnexec refused"}], clean))
    expect("census: no host sniffed is not clean", "BAD", census_verdict([], clean))
    fh = globals().get("first_hit")
    expect("first hit: the first host that saw one", "h2",
           fh([{"host": "h1", "frames_hb": 0}, {"host": "h2", "frames_hb": 3}]) if fh else "missing")
    expect("first hit: nobody saw one is no hit", "True",
           (fh([{"host": "h1", "frames_hb": 0}, {"host": "h2", "error": "x"}]) == "") if fh else "missing")
    # Round 5, judge R4-1: the census's session is the one of the daemon `start` just started.
    so = globals().get("session_of")
    live = {"status": "running", "pid": 4242, "session": "0102030405060708"}
    expect("session: the running report of the pid start named", "0102030405060708",
           so(live, 4242) if so else "missing")
    expect("session: a stopped report is none, even of that pid", "True",
           (so(dict(live, status="stopped"), 4242) == "") if so else "missing")
    expect("session: a running report of another pid is none", "True",
           (so(live, 1111) == "") if so else "missing")
    sp = globals().get("started_pid")
    expect("started pid: 'heartbeat started (pid N; ...)'", "4242",
           sp("heartbeat started (pid 4242; report: /run/ndtwin-lab/heartbeat.json, log: x)\n")
           if sp else "missing")
    expect("started pid: 'already running' started nothing", "None",
           sp("heartbeat already running (pid 4242) -- not starting a second one\n") if sp else "missing")
    # Round 5, judge (d)(i): all-heard / others-up answer BAD, not a traceback, when the report
    # cannot be read -- the way wait-* / first-hit / census-verdict already do.
    with tempfile.TemporaryDirectory() as td:
        absent = os.path.join(td, "absent.json")
        for verb, args in (("all-heard", [absent, "0"]), ("others-up", [absent, "1:3>3:1", "15"])):
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    got = f"rc {main(['hb_watch.py', verb] + args)}: {buf.getvalue().strip()}"
            except Exception as exc:        # what the round-4 code did: the caller's `set -e` ends the run
                got = f"raised {type(exc).__name__}"
            expect(f"{verb} on a report that cannot be read: BAD, rc 0", "rc 0: BAD", got)

    # ---------------------------------------------------------------------------------- round 8
    # The new functions are looked up by name, so that this block reddens -- line by line, never
    # a traceback -- on code that does not have them yet.
    print("  -- round 8: the phase plan, coverage and the summary (pure)")
    g = globals().get
    pr = g("plan_rows")
    if pr:
        a = pr("random", 10, 7, 5.0)
        expect("plan: random is the seed's (the same seed, the same plan)", "True", a == pr("random", 10, 7, 5.0))
        expect("plan: every random wait in [0, period)", "True",
               all(0 <= r[2] < 5 and 0 <= r[4] < 5 for r in a))
        expect("plan: another seed, another plan", "True", pr("random", 10, 8, 5.0) != a)
        sw = pr("sweep", 10, 0, 5.0)
        expect("plan: the sweep starts 0.05 s after a frame heard, ends 0.15 s before the next round",
               "0.05 4.85 10", f"{sw[0][2]:.2f} {sw[-1][2]:.2f} {len(sw)}")
        expect("plan: the sweep's restores take the offsets the other way round", "True",
               [r[4] for r in sw] == [r[2] for r in sw][::-1])
        try:
            pr("sweep", 3, 0, 5.0, [0.05, 5.0])
            got = "accepted"
        except ValueError:
            got = "ValueError"
        expect("plan: an offset outside (0, period) is refused", "ValueError", got)
    else:
        expect("plan: random is the seed's (the same seed, the same plan)", "True", "missing")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
        prc = main(["hb_watch.py", "plan", "sweep", "3", "0", "5", "0.05,5.5"])
    expect("plan verb: a bad offset answers rc 2 and says why (asked before any claim)", "rc 2: BAD",
           f"rc {prc}: {buf.getvalue().strip()}")
    pt = g("phase_target")
    expect("phase target: the first anchor + k*period + offset at or after now + margin", "1015.059",
           f"{pt(1012.0, 1000.009, 5.0, 0.05, 0.05):.3f}" if pt else "missing")
    cov = g("coverage")
    locked = [0.62, 0.66, 0.70, 0.72, 0.75, 0.80, 0.64, 0.69, 0.71, 0.78]    # round 7's loop, cycles 2-10
    spread = [0.1, 0.6, 1.1, 1.6, 2.1, 2.6, 3.1, 3.6, 4.1, 4.6]
    expect("coverage: round 7's phases (0.62-0.80 s over 10 cycles) are PHASE-LOCKED", "False",
           cov(locked, 5.0, "cut")[0] if cov else "missing")
    expect("coverage: ten phases spread over the period cover it", "True",
           cov(spread, 5.0, "cut")[0] if cov else "missing")
    expect("coverage: fewer than 8 cycles are not judged", "None",
           cov(spread[:7], 5.0, "cut")[0] if cov else "missing")

    def summ(rows):     # a summary that cannot read round-8 rows reddens below instead of ending the self-test
        try:
            return summary(rows, 15, 5)
        except Exception as exc:
            return [f"raised {type(exc).__name__}"], f"raised {type(exc).__name__}", f"raised {type(exc).__name__}"

    def r8(i, phi, rphi, mode="random"):
        down, up = 15 - phi + 0.05, 5 - rphi
        return {"cycle": str(i), "down_s": f"{down:.3f}", "up_s": f"{up:.3f}", "cut_tc_s": "0.070",
                "phase_mode": mode, "cut_plan": f"{phi - 0.07:.3f}", "cut_phi_s": f"{phi:.3f}",
                "down_rule_s": f"{15 - phi:.3f}", "restore_phi_s": f"{rphi:.3f}", "up_rpt_s": f"{up + 0.498:.3f}"}
    res = summ([r8(i + 1, p, p) for i, p in enumerate(spread)])
    expect("summary: round-8 rows get per-phase-bin statistics", "True",
           any(l.startswith("  per cut phase") for l in res[0]) and any(l.startswith("  per restore phase") for l in res[0]))
    expect("summary: ... and the report lag, measured from up_rpt_s - up_s", "0.498",
           next((l.split("median ")[1][:5] for l in res[0] if "report lag" in l), "no report-lag line"))
    expect("summary: a random run whose phases spread over the period passes", "True", res[1])
    res = summ([r8(i + 1, p, 0.15) for i, p in enumerate(locked)])
    expect("summary: a phase-locked run (round 7's loop) is BAD, and says PHASE-LOCKED", "False PHASE-LOCKED",
           f"{res[1]} " + ("PHASE-LOCKED" if "PHASE-LOCKED" in (res[2] if len(res) > 2 else "") else
                           f"-- its verdict: {res[2] if len(res) > 2 else 'none'}"))
    res = summ([r8(i + 1, 0.4 + 0.45 * i, 0.4 + 0.45 * i, "sweep") for i in range(10)])
    expect("summary: a sweep whose smallest cut phase is 0.4 s never sampled phi -> 0: BAD", "False", res[1])

    # A simulated daemon (class Sim, set through HB_WATCH_SIM) on a fake clock: first the timeline
    # itself, then every round-8 wrapper against it. The netem log is what the spike's fake tc writes.
    print("  -- round 8: a simulated daemon on a fake clock")
    with tempfile.TemporaryDirectory() as td:
        saved = os.environ.get(SIM_ENV)
        os.environ[SIM_ENV] = td

        def init(**over):
            with contextlib.redirect_stdout(io.StringIO()):
                main(["hb_watch.py", "sim-init", td, json.dumps(over)])

        def at(t):
            with open(os.path.join(td, "clock"), "w") as fh:
                fh.write(f"{t:.6f}\n")

        def tc(op, dev, t):
            with open(os.path.join(td, "netem.log"), "a") as fh:
                fh.write(f"{op} {dev} {t:.6f}" + (" loss 100%\n" if op == "add" else "\n"))

        def lh_of(doc):
            return {f"{r['tx']['dpid']}:{r['tx']['port']}>{r['rx']['dpid']}:{r['rx']['port']}": r["last_heard_mono"]
                    for r in doc["directions"]}
        try:
            init(lag=0.7)
            at(999.9)
            try:
                report("x")
                got = "a report"
            except FileNotFoundError:
                got = "none"
            expect("sim: no report before the daemon's first write", "none", got)
            at(1000.5)
            expect("sim: a round's frames are not in its own send-round write", "1000.007 None",
                   f"{report('x')['written_mono']:.3f} {lh_of(report('x'))['1:3>3:1']}")
            at(1000.71)
            expect("sim: ... they are in the write `lag` s after it (0.7 here)", "1000.707 1000.009",
                   f"{report('x')['written_mono']:.3f} {lh_of(report('x'))['1:3>3:1']:.3f}")
            tc("add", "s1-eth3", 1004.0)
            at(1011.0)
            h = lh_of(report("x"))
            expect("sim: netem on s1-eth3 (scope tx) silences 1:3>3:1 only", "1000.009 1010.009 1010.009",
                   f"{h['1:3>3:1']:.3f} {h['3:1>1:3']:.3f} {h['1:4>4:2']:.3f}")
            tc("del", "s1-eth3", 1012.0)
            at(1016.0)
            expect("sim: the netem removed, the next round is heard", "1015.009",
                   f"{lh_of(report('x'))['1:3>3:1']:.3f}")
            init(scope="cable")
            tc("add", "s1-eth3", 1004.0)
            at(1011.0)
            h = lh_of(report("x"))
            expect("sim: scope cable -- a netem on one end silences both directions", "1000.009 1000.009",
                   f"{h['1:3>3:1']:.3f} {h['3:1>1:3']:.3f}")
            init(deaf_rounds=[1, 2])
            at(1011.0)
            d = report("x")
            expect("sim: deaf rounds are sent and heard by nobody (no lag write after them)", "1010.007 3 1000.009",
                   f"{d['written_mono']:.3f} {d['directions'][0]['sent']} {lh_of(d)['1:4>4:2']:.3f}")

            wcd, wru, pw, wq, wse = (g(n) for n in ("wait_cut_down", "wait_restore_up", "phase_wait",
                                                     "watch_quiet", "watch_single_end"))
            cut = [(1, 3, 3, 1), (3, 1, 1, 3)]
            init(lag=0.7)
            at(1003.95)
            tc("add", "s1-eth3", 1003.95)
            tc("add", "s3-eth1", 1003.95)
            trace = os.path.join(td, "trace.tsv")
            d = wcd("x", cut, 1003.95, 15, 35, trace) if wcd else None
            expect("cut-down (sim): phi = t0 - the last frame heard (1000.009), not the schedule", "3.941 heard 3.950",
                   f"{d['phi']:.3f} {d['phi_src']} {d['phi_grid']:.3f}" if d else "missing")
            expect("cut-down (sim): the rule true 15 s after that frame, the poll within 0.1 s after it", "11.059 True",
                   f"{d['rule_s']:.3f} {0 <= d['down_s'] - d['rule_s'] < 0.1}" if d else "missing")
            try:
                with open(trace) as fh:
                    tl = fh.read().splitlines()
            except OSError:
                tl = []
            head = "part\tpoll_mono\twritten_mono"
            expect("cut-down (sim): its trace has every poll's time and the report's written_mono", "True 112",
                   f"{bool(tl) and tl[0].startswith(head)} {sum(1 for l in tl if l.startswith('cut'))}")
            at(1017.0)
            w = pw("x", "delay", 0.0, 5.0, 0.05) if pw else None
            tc("del", "s1-eth3", 1017.0)
            tc("del", "s3-eth1", 1017.0)
            u = wru("x", cut, 1017.0, 20, w["anchor"]) if wru and w else None
            expect("restore-up (sim): up_s at the daemon's receive, up_rpt_s at the first report showing it",
                   "3.009 3.707", f"{u['up_s']:.3f} {u['rpt_s']:.3f}" if u else "missing")
            expect("restore-up (sim): the report lag is MEASURED -- 0.698 = the sim's lag 0.7 + w - eps, not 0.5",
                   "0.698", f"{u['rpt_s'] - u['up_s']:.3f}" if u else "missing")
            expect("restore-up (sim): the restore's phase from the frame heard before it", "1.991 heard@plan",
                   f"{u['phi']:.3f} {u['phi_src']}" if u else "missing")
            at(1030.2)
            w = pw("x", "delay", 1.25, 5.0, 0.05) if pw else None
            expect("phase-wait (sim): a delay is waited on the clock", "1031.450 1.250",
                   f"{w['wake']:.3f} {w['delay']:.3f}" if w else "missing")
            w = pw("x", "phase", 0.05, 5.0, 0.05) if pw else None
            expect("phase-wait (sim): a phase starts 0.05 s after the next frame heard", "1035.059 heard",
                   f"{w['wake']:.3f} {w['src']}" if w else "missing")
            init()
            at(1000.8)
            q = wq("x", 20, 15) if wq else ("", "missing")
            expect("quiet (control a, sim): a heartbeat heard throughout, 20 s, no cut", "OK", q[1])
            init(deaf_rounds=[1, 2, 3])
            at(1000.8)
            q = wq("x", 20, 15) if wq else ("", "missing")
            expect("quiet (control a, sim): a heartbeat nobody hears for three rounds",
                   "BAD the proxy's rule fired with NO cut", q[1])
            init()
            at(1003.95)
            tc("add", "s1-eth3", 1003.95)
            s = wse("x", cut[0], cut[1], 1003.95, 15, 35, 6) if wse else ("", "missing")
            expect("single-end (control b, sim): netem on s1-eth3 only -> only 1:3>3:1 goes not-heard",
                   "OK only 1:3>3:1 went not-heard", s[1])
            init(scope="cable")
            at(1003.95)
            tc("add", "s1-eth3", 1003.95)
            s = wse("x", cut[0], cut[1], 1003.95, 15, 35, 6) if wse else ("", "missing")
            expect("single-end (control b, sim): a one-end netem that takes the whole cable",
                   "BAD 3:1>1:3 went not-heard too", s[1])
            init()
            at(1003.95)
            s = wse("x", cut[0], cut[1], 1003.95, 15, 20, 6) if wse else ("", "missing")
            expect("single-end (control b, sim): no netem at all -> the cut was not seen", "BAD 1:3>3:1 was still heard",
                   s[1])
        finally:
            if saved is None:
                os.environ.pop(SIM_ENV, None)
            else:
                os.environ[SIM_ENV] = saved
    print("SELF-TEST PASS" if rc == 0 else "SELF-TEST FAIL")
    return rc


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "now":
        print(f"{clock():.3f}")
    elif cmd == "session":
        print(session_of(load(argv[2]), int(argv[3])))
    elif cmd == "started-pid":
        with open(argv[2]) as fh:
            pid = started_pid(fh.read())
        print("" if pid is None else pid)
    elif cmd == "all-heard":
        # BAD, not a traceback, when the report cannot be read (judge (d)(i), round-4 verdict): the
        # spike's `set -e` would otherwise end the run on it, like wait-* / first-hit already avoid.
        try:
            print(all_heard(report(argv[2]), float(argv[3])))
        except (OSError, ValueError, KeyError) as exc:
            print(f"BAD the report could not be read: {exc!r}")
    elif cmd == "wait-heard":
        r = wait_heard(argv[2], parse_dirs(argv[3]), float(argv[4]), float(argv[5]))
        print("TIMEOUT" if r is None else f"{r:.3f}")
    elif cmd == "wait-down":
        r = wait_down(argv[2], parse_dirs(argv[3]), float(argv[4]), float(argv[5]), float(argv[6]))
        print("TIMEOUT" if r is None else f"{r:.3f}")
    elif cmd == "others-up":
        try:
            print(others_up(report(argv[2]), parse_dirs(argv[3]), clock(), float(argv[4])))
        except (OSError, ValueError, KeyError) as exc:
            print(f"BAD the report could not be read: {exc!r}")
    elif cmd == "summary":
        rows = []
        with open(argv[2]) as fh:
            for line in fh:
                if line.startswith("cycle") or not line.strip():
                    continue
                c, down, up = line.rstrip("\n").split("\t")[:3]
                rows.append((int(c), None if down == "TIMEOUT" else float(down),
                             None if up == "TIMEOUT" else float(up)))
        lines, ok = summary(rows, float(argv[3]), float(argv[4]))
        print("\n".join(lines))
        print("OK every cut and every restore detected" if ok else "BAD not every cycle was detected")
    elif cmd == "sim-init":
        # The self-test's simulated daemon (class Sim): sim.json (Sim.DEFAULT with the overrides),
        # its clock half a second before the daemon starts, and an empty netem.log.
        cfg = dict(Sim.DEFAULT, **(json.loads(argv[3]) if len(argv) > 3 else {}))
        with open(os.path.join(argv[2], "sim.json"), "w") as fh:
            json.dump(cfg, fh)
        with open(os.path.join(argv[2], "clock"), "w") as fh:
            fh.write(f"{cfg['started'] - 0.5:.6f}\n")
        open(os.path.join(argv[2], "netem.log"), "w").close()
    elif cmd == "first-hit":
        sniffs = []
        for p in sorted(glob.glob(os.path.join(argv[2], "sniff_*.json"))):
            try:
                sniffs.append(load(p))
            except (OSError, ValueError):
                pass                    # not written yet, or half written: not a hit yet
        print(first_hit(sniffs))
    elif cmd == "census-verdict":
        sniffs = []
        for p in sorted(glob.glob(os.path.join(argv[2], "sniff_*.json"))):
            try:
                sniffs.append(load(p))
            except (OSError, ValueError) as exc:
                sniffs.append({"host": os.path.basename(p), "error": f"unreadable: {exc}"})
        try:
            snapshot = load(argv[3])
        except (OSError, ValueError):
            snapshot = None
        print(census_verdict(sniffs, snapshot))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
