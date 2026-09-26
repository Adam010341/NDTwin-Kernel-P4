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

🔴 ROUND 8 (09-26, the segment-S report's judge, Blocking 1 and 2, and the re-review's notes): the
two live runs cut the cable at ONE phase of the heartbeat's round -- right after the loop's
previous wait returned, 0.62-0.80 s after the last frame heard, every cycle -- and restored it
~0.15 s after a send; `up_s` is the daemon's receive stamp, and the report that shows it is
written ~0.5 s later. The verbs under the round-8 line below give every cut and every restore a
phase of its own (a seeded random wait, or a sweep of start offsets after the last frame heard),
record that phase from the report's own last_heard_mono with the CLOCK_MONOTONIC stamps it is
computed from, record the REPORT level (the first report whose content shows the transition)
beside the daemon's receive stamp, and run the two discriminating controls (no cut; one end only).

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
  round 8:
    hb_watch.py plan        <random|sweep> <cycles> <seed> <period_s> [<offsets: s,s,...>]  -> the phase plan (TSV)
    hb_watch.py phase-wait  <report> <delay|phase> <value> <period_s> <margin_s>  -> wake, delay, anchor, source
    hb_watch.py cut-down    <report> <dirs> <t0_mono> <timeout_s> <cap_s> [<trace>]  -> down_s rule_s rpt_s lh phi src grid
    hb_watch.py restore-up  <report> <dirs> <t1_mono> <cap_s> <anchor_mono|-> [<trace>] -> up_s rpt_s poll_s lh phi src grid
    hb_watch.py quiet       <report> <seconds> <timeout_s> [<trace>]            -> observed, verdict (control a)
    hb_watch.py single-end  <report> <down_dir> <up_dir> <t0_mono> <timeout_s> <cap_s> <hold_s> [<trace>]
                                                                                -> observed, verdict (control b)
    hb_watch.py period-check <report> <period_s>                                -> OK | BAD
    hb_watch.py sub <a> <b>                                                     -> a - b, or "-"
    hb_watch.py sim-init <dir> [<json overrides>]                               -> (self-test only) a simulated daemon
    hb_watch.py --self-test

<dirs> is "1:3>3:1,3:1>1:3" -- tx dpid:port > rx dpid:port, comma separated.

🔴 HB_WATCH_SIM=<dir>, when set, puts every verb that reads the heartbeat report onto the SELF-TEST'S
simulated daemon (class Sim) at the fake time in <dir>/clock, and every wait moves that clock on
instead of sleeping. It exists so the spike's --self-test can run its own detection loop against a
known timeline; S_heartbeat_spike.sh refuses to run with it set.
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


#: 20_cycles.tsv's first six columns -- round 7's whole row. A file without a header row is read as these.
OLD_COLS = ["cycle", "down_s", "up_s", "cut_tc_s", "collateral", "netem_left"]
#: 🔴 PHASE COVERAGE (round 8). A run of PHASE=random or PHASE=sweep is judged to cover the period
#: when, from COVER_MIN_N cycles on, the largest circular gap between its recorded phases is below
#: COVER_GAP of the period. Round 7's loop put every cut 0.62-0.80 s after the last frame heard: a
#: gap of 0.96 of the period. For n independent uniform phases, P(largest gap >= 0.6 P) is
#: n * 0.4**(n-1) -- 1.3 % at n = 8, 0.26 % at n = 10 -- the false alarm a random run can meet.
COVER_MIN_N = 8
COVER_GAP = 0.6
#: A sweep whose smallest recorded cut phase is above this never sampled the worst case (phi -> 0).
SWEEP_WORST_MAX_S = 0.25


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def fmt(x, nd=3):
    return "-" if x is None else f"{x:.{nd}f}"


def read_cycles(path):
    """20_cycles.tsv as [{column: cell}], by its header row (round 7's file: OLD_COLS)."""
    rows, header = [], None
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cells = line.split("\t")
            if cells[0] == "cycle":
                header = cells
                continue
            rows.append(dict(zip(header or OLD_COLS, cells)))
    return rows


def mmm(xs, nd=2):
    return (f"min {min(xs):.{nd}f} s  median {statistics.median(xs):.{nd}f} s  "
            f"max {max(xs):.{nd}f} s  (n={len(xs)})")


def largest_gap(phis, period):
    """(the largest circular gap between the phases, the arc holding them all: first, last)."""
    xs = sorted(x % period for x in phis)
    if not xs:
        return period, None, None
    gaps = [(xs[i + 1] - xs[i], i + 1) for i in range(len(xs) - 1)] + [(xs[0] + period - xs[-1], 0)]
    g, j = max(gaps)
    return g, xs[j], xs[j - 1]


def coverage(phis, period, what):
    """(True | False | None, line) -- whether the phases cover the period; None: too few to judge."""
    n = len(phis)
    g, first, last = largest_gap(phis, period)
    lim = COVER_GAP * period
    head = f"  {what} phase coverage: n={n}, largest gap {g:.2f} s of the {period:g} s period"
    if n < COVER_MIN_N:
        return None, head + f" -- not judged (fewer than {COVER_MIN_N} cycles)"
    if g < lim:
        return True, head + f" < {lim:.2f} s -> covers it"
    return False, (head + f" >= {lim:.2f} s -> PHASE-LOCKED: all {n} within an arc of {period - g:.2f} s "
                   f"({first:.2f} .. {last:.2f} s)")


def bin_lines(pairs, period, label, fields):
    """pairs [(phase, row)] -> a line per fifth of the period (and one for a phase >= the period:
    a round whose frame was not heard before the cut), each field's min/median/max."""
    w = period / 5
    groups = [(f"[{b * w:.1f}, {(b + 1) * w:.1f}) s", [r for p, r in pairs if b * w <= p < (b + 1) * w])
              for b in range(5)]
    over = [r for p, r in pairs if p >= period]
    if over:
        groups.append((f">= {period:.1f} s", over))
    out = [f"  per {label} (bins of {w:g} s; min/median/max):"]
    for name, rs in groups:
        cells = []
        for f in fields:
            xs = [x for x in (num(r.get(f)) for r in rs) if x is not None]
            cells.append(f"{f} " + (f"{min(xs):.2f}/{statistics.median(xs):.2f}/{max(xs):.2f}" if xs else "-"))
        out.append(f"    {name:14s} n={len(rs):<3d} " + "  ".join(cells))
    return out


def summary(rows, timeout, period):
    """rows: [{column: cell}] as read_cycles gives them, or round 7's [(cycle, down_s, up_s)].

    -> (lines, ok, why): every cycle detected -- and, for a round-8 run, the cut and restore
    phases covering the period and a sweep that sampled phi -> 0 -- and the verdict's reason.
    """
    rows = [r if isinstance(r, dict) else {"cycle": r[0], "down_s": r[1], "up_s": r[2]} for r in rows]
    downs = [x for x in (num(r.get("down_s")) for r in rows) if x is not None]
    ups = [x for x in (num(r.get("up_s")) for r in rows) if x is not None]
    lines = [f"cycles {len(rows)}: down detected {len(downs)}/{len(rows)}, recovery detected "
             f"{len(ups)}/{len(rows)}"]
    for label, xs in (("cut -> both directions not heard", downs), ("restore -> both heard again", ups)):
        if xs:
            lines.append(f"  {label}: {mmm(xs)}")
    ok = len(downs) == len(rows) == len(ups) and len(rows) > 0
    why = ["every cut and every restore detected" if ok else "not every cycle was detected"]
    judged = []
    if any("cut_phi_s" in r for r in rows):
        mode = rows[0].get("phase_mode", "?")
        lines.append(f"  -- round 8, PHASE={mode}: cut_phi_s = t0 - the last frame heard on the cable (the phase "
                     f"the proxy's rule sees); restore_phi_s = t1 - the last heartbeat round, mod {period:g} s --")
        cut = [(p, r) for p, r in ((num(r.get("cut_phi_s")), r) for r in rows) if p is not None]
        rst = [(p, r) for p, r in ((num(r.get("restore_phi_s")), r) for r in rows) if p is not None]
        # The phase re-derived from the raw CLOCK_MONOTONIC stamps (the re-review's note 1).
        differs = [r["cycle"] for p, r in cut
                   if num(r.get("cut_t0_mono")) is not None and num(r.get("cut_lh_mono")) is not None
                   and abs(num(r["cut_t0_mono"]) - num(r["cut_lh_mono"]) - p) > 0.002]
        lines.append("  cut_phi_s re-derived from the raw stamps (cut_t0_mono - cut_lh_mono): "
                     + ("agrees on every row" if not differs else
                        "DIFFERS on cycle(s) " + ",".join(str(c) for c in differs)))

        def two(r, a, b, f):
            x, y = num(r.get(a)), num(r.get(b))
            return None if x is None or y is None else f(x, y)
        derived = (
            (f"cut -> the rule true (down_rule_s = last frame heard + {timeout:g} s - t0)",
             lambda r: num(r.get("down_rule_s"))),
            ("poll lag (down_s - down_rule_s)", lambda r: two(r, "down_s", "down_rule_s", lambda x, y: x - y)),
            ("restore -> the first REPORT showing both heard (up_rpt_s)", lambda r: num(r.get("up_rpt_s"))),
            ("report lag, measured (up_rpt_s - up_s)", lambda r: two(r, "up_rpt_s", "up_s", lambda x, y: x - y)),
            (f"the round after the restore heard? (up_s + restore_phi_s - {period:g}; ~0 when it was)",
             lambda r: two(r, "up_s", "restore_phi_s", lambda x, y: x + y - period)))
        for label, get in derived:
            xs = [x for x in (get(r) for r in rows) if x is not None]
            if xs:
                lines.append(f"  {label}: {mmm(xs, 3)}")
        lines += bin_lines(cut, period, "cut phase (cut_phi_s)", ("down_s", "down_rule_s"))
        lines += bin_lines(rst, period, "restore phase (restore_phi_s)", ("up_s", "up_rpt_s"))
        if cut:
            p, r = min(cut, key=lambda pr: pr[0])
            lines.append(f"  smallest cut phase sampled: {p:.3f} s (cycle {r['cycle']}) -> down_s {r.get('down_s')} s, "
                         f"down_rule_s {r.get('down_rule_s')} s")
        for what, ps in (("cut", [p for p, _ in cut]), ("restore", [p for p, _ in rst])):
            v, line = coverage(ps, period, what)
            lines.append(line)
            judged.append(v)
            if v is False:
                ok = False
                why.append(f"the {what} phases do not cover the period --{line.split('->', 1)[1]}")
        if mode == "sweep":
            acc = [abs(p - num(r.get("cut_tc_s")) - num(r.get("cut_plan"))) for p, r in cut
                   if num(r.get("cut_tc_s")) is not None and num(r.get("cut_plan")) is not None]
            if acc:
                lines.append(f"  sweep: each cut started cut_plan s after the last frame heard, to "
                             f"|cut_phi_s - cut_tc_s - cut_plan| <= {max(acc):.3f} s")
            if cut and min(p for p, _ in cut) > SWEEP_WORST_MAX_S:
                ok = False
                why.append(f"the sweep never cut within {SWEEP_WORST_MAX_S:g} s of a heard frame "
                           f"(smallest cut_phi_s {min(p for p, _ in cut):.3f} s) -- phi -> 0 was not sampled")
    lines.append(f"  expected from the constants alone (INFERRED): down = {timeout:g} - cut_phi_s plus one poll, in "
                 f"({timeout - period:.0f}, {timeout:.0f}] s; up = {period:g} - restore_phi_s at daemon receive, in "
                 f"(0, {period:.0f}] s, plus the report lag at report level; segment W adds <= one watchdog pass")
    if ok and judged and all(v is True for v in judged):
        why.append("the cut and restore phases cover the period")
    elif ok and judged:
        why.append(f"phase coverage not judged (fewer than {COVER_MIN_N} cycles)")
    return lines, ok, "; ".join(why)


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


# ------------------------------------------------------------------ round 8: phases, levels, controls
#: The sweep's first start offset: the cut BEGINS this long after the last frame heard (the report's
#: last_heard_mono, never the schedule: the re-review's note 1 -- the daemon's actual send is 1.7-7.0 ms
#: after started_mono + k*period). Both ends' netem then go on after that round's frames were heard;
#: a cut that ended before them would measure the best case (phi ~ one period), not the worst.
SWEEP_FIRST_S = 0.05
#: ... and its last one this long before the next round, so the cut (cut_tc_s, 0.06-0.1 s live)
#: is over before that round's send.
SWEEP_LAST_GAP_S = 0.15


def dir_name(r):
    return f"{r['tx']['dpid']}:{r['tx']['port']}>{r['rx']['dpid']}:{r['rx']['port']}"


def if_name(r):
    return f"{r['tx']['ifname']}->{r['rx']['ifname']}"


def sweep_default(n, period):
    """n start offsets from SWEEP_FIRST_S to period - SWEEP_LAST_GAP_S, evenly spaced."""
    if n <= 1:
        return [SWEEP_FIRST_S]
    last = period - SWEEP_LAST_GAP_S
    return [SWEEP_FIRST_S + j * (last - SWEEP_FIRST_S) / (n - 1) for j in range(n)]


def plan_rows(mode, cycles, seed, period, sweep=None):
    """[(cycle, cut kind, cut value, restore kind, restore value)] -- a run's phase plan.

    random: the cut waits U[0, period) after the pre-cut check saw the cable heard, the restore
    U[0, period) after the down was called -- random.Random(seed), so the recorded seed gives the
    same plan back. sweep: the cut STARTS at the listed offsets after the last frame heard, one per
    cycle (the list wraps round), the restore at the same offsets in reverse order.
    ValueError on anything else, and on an offset outside (0, period).
    """
    if cycles < 1:
        raise ValueError(f"cycles must be >= 1, not {cycles}")
    if mode == "random":
        rng = random.Random(seed)
        return [(i, "delay", rng.random() * period, "delay", rng.random() * period)
                for i in range(1, cycles + 1)]
    if mode == "sweep":
        offs = list(sweep) if sweep else sweep_default(cycles, period)
        bad = [x for x in offs if not 0 < x < period]
        if not offs or bad:
            raise ValueError(f"sweep offsets must lie in (0, {period:g}) s: {bad or 'none given'}")
        rev = offs[::-1]
        return [(i, "phase", offs[(i - 1) % len(offs)], "phase", rev[(i - 1) % len(rev)])
                for i in range(1, cycles + 1)]
    raise ValueError(f"PHASE must be random or sweep, not {mode!r}")


def phase_target(now, anchor, period, offset, margin):
    """The first instant anchor + k*period + offset (k any integer) at or after now + margin."""
    base = anchor + offset
    return base + math.ceil((now + margin - base) / period) * period


def latest_heard(doc, dirs=None):
    """The newest last_heard_mono of `dirs` (every direction when None), or None."""
    recs = find(doc, dirs) if dirs else doc.get("directions", [])
    xs = [r["last_heard_mono"] for r in recs if r.get("last_heard_mono") is not None]
    return max(xs) if xs else None


def grid_phase(doc, t):
    """(t - started_mono) mod period_s -- the schedule's phase (the actual send is a few ms later)."""
    s, p = doc.get("started_mono"), doc.get("period_s")
    return None if s is None or not p else (t - s) % p


def down_detail(doc, dirs, now, t0, timeout):
    """None while any of `dirs` is still heard by the rule at `now`. Once none is -- the cut as the
    rule saw it: down_s (the reader's poll), rule_s (the instant the rule became true: the last frame
    heard + timeout), rpt_s (written_mono of the report the reader applied it to; the report has no
    down transition of its own -- the rule is the reader's clock against last_heard), lh (that last
    frame, CLOCK_MONOTONIC), phi = t0 - lh (source heard) and the schedule's phase."""
    if not all(not_heard(r, now, timeout) for r in find(doc, dirs)):
        return None
    lh, gp, w = latest_heard(doc, dirs), grid_phase(doc, t0), doc.get("written_mono")
    d = {"down_s": now - t0, "rpt_s": None if w is None else w - t0, "lh": lh, "phi_grid": gp}
    if lh is not None:
        d.update(rule_s=lh + timeout - t0, phi=t0 - lh, phi_src="heard")
    else:
        d.update(rule_s=None, phi=gp, phi_src="grid" if gp is not None else "none")
    return d


def up_detail(doc, dirs, now, t1, anchor):
    """None until every one of `dirs` was heard after t1. Then -- the restore as the report shows
    it: up_s (the daemon's receive stamp, round 7's up_s), rpt_s (written_mono of this report, the
    first the reader saw showing it: REPORT level), poll_s (the reader's poll), lh (the newest of
    those frames), phi = (t1 - anchor) mod period -- anchor: a frame heard in the report read
    before the restore (source heard@plan) -- and the schedule's phase."""
    recs = find(doc, dirs)
    if not all(heard_after(r, t1) for r in recs):
        return None
    lh, gp, w, p = max(r["last_heard_mono"] for r in recs), grid_phase(doc, t1), doc.get("written_mono"), doc.get("period_s")
    d = {"up_s": lh - t1, "rpt_s": None if w is None else w - t1, "poll_s": now - t1, "lh": lh, "phi_grid": gp}
    if anchor is not None and p:
        d.update(phi=(t1 - anchor) % p, phi_src="heard@plan")
    else:
        d.update(phi=gp, phi_src="grid" if gp is not None else "none")
    return d


class Tracer:
    """Every poll's CLOCK_MONOTONIC, the report's written_mono and the watched directions'
    last_heard_mono, appended to a TSV (the re-review's note 4: the daemon's pulse, per poll)."""

    def __init__(self, path, part):
        self.path, self.part, self.fh = path, part, None

    def poll(self, now, doc, recs):
        if not self.path:
            return
        if self.fh is None:
            self.fh = open(self.path, "a")
            if self.fh.tell() == 0:
                self.fh.write("part\tpoll_mono\twritten_mono\tstatus\tlast_heard_mono\n")
        heard = ",".join(f"{dir_name(r)}={fmt(r.get('last_heard_mono'), 6)}" for r in recs) or "-"
        self.fh.write(f"{self.part}\t{now:.6f}\t{fmt((doc or {}).get('written_mono'), 6)}\t"
                      f"{(doc or {}).get('status', 'unreadable')}\t{heard}\n")

    def close(self):
        if self.fh is not None:
            self.fh.close()


def wait_cut_down(path, dirs, t0, timeout, cap, trace=None):
    """down_detail once the rule holds for every one of `dirs`, polled every 0.1 s; None by t0 + cap."""
    tr = Tracer(trace, "cut")
    try:
        while clock() < t0 + cap:
            now = clock()
            try:
                doc = report(path)
                tr.poll(now, doc, find(doc, dirs))
                if not running(doc):
                    return None
                d = down_detail(doc, dirs, now, t0, timeout)
                if d is not None:
                    return d
            except (OSError, ValueError, KeyError):
                tr.poll(now, None, [])
            nap(0.1)
        return None
    finally:
        tr.close()


def wait_restore_up(path, dirs, t1, cap, anchor, trace=None):
    """up_detail at the first poll whose report shows every one of `dirs` heard after t1."""
    tr = Tracer(trace, "restore")
    try:
        end = clock() + cap
        while clock() < end:
            now = clock()
            try:
                doc = report(path)
                tr.poll(now, doc, find(doc, dirs))
                if running(doc):
                    d = up_detail(doc, dirs, now, t1, anchor)
                    if d is not None:
                        return d
            except (OSError, ValueError, KeyError):
                tr.poll(now, None, [])
            nap(0.1)
        return None
    finally:
        tr.close()


def phase_wait(path, kind, value, period, margin):
    """Wait before a cut or a restore, as the plan says. kind `delay`: `value` s from now. kind
    `phase`: until `value` s after a heartbeat round -- the next anchor + k*period + value at or after
    now + margin, where the anchor is the newest last_heard_mono in the report (source heard; its
    started_mono when nothing was heard yet: grid; no report: none, and no wait).
    -> {wake, delay, anchor, src}: wake is CLOCK_MONOTONIC as this returns -- the cut's t0a."""
    entry = clock()
    anchor, src, p = None, "none", period
    try:
        doc = report(path)
        p = doc.get("period_s") or period
        anchor = latest_heard(doc)
        if anchor is not None:
            src = "heard"
        elif doc.get("started_mono") is not None:
            anchor, src = doc["started_mono"], "grid"
    except (OSError, ValueError, KeyError):
        pass
    if kind == "delay":
        target = entry + value
    elif kind == "phase":
        target = entry if anchor is None else phase_target(entry, anchor, p, value, margin)
    else:
        raise ValueError(f"phase-wait: kind must be delay or phase, not {kind!r}")
    nap(target - clock())
    wake = clock()
    return {"wake": wake, "delay": wake - entry, "anchor": anchor, "src": src}


def watch_quiet(path, seconds, timeout, trace=None):
    """CONTROL (a): no cut for `seconds` -- the proxy's rule must fire on NO direction of the report.
    Its discriminating power: a heartbeat nobody hears is not-heard by the rule within `timeout` s,
    so a window of more than timeout + one period sees it whichever the phase. -> (observed, verdict)."""
    tr = Tracer(trace, "quiet")
    start = now = clock()
    reads = polls = 0
    longest, fired, stopped = {}, {}, False
    try:
        while True:
            now = clock()
            polls += 1
            try:
                doc = report(path)
                recs = doc.get("directions", [])
                tr.poll(now, doc, recs)
                if not running(doc):
                    stopped = True
                else:
                    reads += 1
                    for r in recs:
                        lh = r.get("last_heard_mono")
                        sil = math.inf if lh is None else now - lh
                        longest[if_name(r)] = max(longest.get(if_name(r), 0.0), sil)
                        if sil > timeout:
                            fired[if_name(r)] = max(fired.get(if_name(r), 0.0), sil)
            except (OSError, ValueError, KeyError):
                tr.poll(now, None, [])
            if now - start >= seconds:
                break
            nap(0.1)
    finally:
        tr.close()
    worst = max(longest.items(), key=lambda kv: kv[1]) if longest else ("-", math.nan)
    observed = (f"window_s={now - start:.1f} reads={reads}/{polls} "
                f"longest_silence_s={worst[1]:.3f}@{worst[0]}")
    if fired:
        return observed, ("BAD the proxy's rule fired with NO cut: "
                          + ", ".join(f"{n} silent {s:.2f} s > {timeout:g} s" for n, s in sorted(fired.items())))
    if stopped:
        return observed, "BAD the report stopped saying `running` inside the no-cut window"
    if not longest or reads < polls / 2:
        return observed, f"BAD the report was readable in only {reads} of {polls} polls"
    return observed, (f"OK no direction went not-heard in {now - start:.1f} s with no cut ({reads} reads; the "
                      f"longest silence {worst[1]:.2f} s, {worst[0]}; the rule needs > {timeout:g} s)")


def watch_single_end(path, down_dir, up_dir, t0, timeout, cap, hold, trace=None):
    """CONTROL (b): netem on ONE end of the cable since t0. Only `down_dir` -- the direction that end
    sends -- may go not-heard; `up_dir` and every other direction must stay heard. Watched until
    down_dir is not heard by the rule and `hold` s more (a period and a second: had the other
    direction been cut too, it would be not-heard within that), or `cap` s after t0.
    -> (observed, verdict)."""
    tr = Tracer(trace, "single")
    t_down, longest, up_fired, others = None, 0.0, None, {}
    reads = polls = 0
    now = clock()
    names = (f"{down_dir[0]}:{down_dir[1]}>{down_dir[2]}:{down_dir[3]}",
             f"{up_dir[0]}:{up_dir[1]}>{up_dir[2]}:{up_dir[3]}")
    try:
        while True:
            now = clock()
            if (t_down is not None and now >= t_down + hold) or now >= t0 + cap:
                break
            polls += 1
            try:
                doc = report(path)
                rd, ru = find(doc, [down_dir, up_dir])
                tr.poll(now, doc, [rd, ru])
                if running(doc):
                    reads += 1
                    if t_down is None and not_heard(rd, now, timeout):
                        t_down = now
                    lu = ru.get("last_heard_mono")
                    sil = math.inf if lu is None else now - lu
                    longest = max(longest, sil)
                    if sil > timeout:
                        up_fired = max(up_fired or 0.0, sil)
                    for r in doc.get("directions", []):
                        if key(r) not in (down_dir, up_dir) and not_heard(r, now, timeout):
                            others[if_name(r)] = True
            except (OSError, ValueError, KeyError):
                tr.poll(now, None, [])
            nap(0.1)
    finally:
        tr.close()
    observed = (f"down_s={fmt(None if t_down is None else t_down - t0)} "
                f"other_longest_silence_s={longest:.3f} window_s={now - t0:.1f} reads={reads}/{polls}")
    if t_down is None:
        return observed, (f"BAD {names[0]} was still heard {now - t0:.1f} s after netem went on its sending end "
                          f"-- the one-end cut was not seen")
    if up_fired is not None:
        return observed, (f"BAD {names[1]} went not-heard too (silent {up_fired:.2f} s > {timeout:g} s) -- "
                          f"the one-end netem took both directions of the cable")
    if others:
        return observed, "BAD collateral with one end cut: " + ", ".join(sorted(others))
    return observed, (f"OK only {names[0]} went not-heard, {t_down - t0:.2f} s after the one-end cut; {names[1]} "
                      f"stayed heard (longest silence {longest:.2f} s over {now - t0:.1f} s, {hold:g} s past the down)")


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
        print(f"{clock():.6f}")
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
        lines, ok, why = summary(read_cycles(argv[2]), float(argv[3]), float(argv[4]))
        print("\n".join(lines))
        print(f"{'OK' if ok else 'BAD'} {why}")
    # ---- round 8. Each prints one line and exits 0 whatever it found (the spike runs under set -e);
    # `plan` alone answers 2 on a bad argument, because the spike asks it before anything is claimed.
    elif cmd == "plan":
        try:
            period = float(argv[5])
            offs = [float(x) for x in argv[6].split(",") if x.strip()] if len(argv) > 6 and argv[6] else None
            rows = plan_rows(argv[2], int(argv[3]), int(argv[4]), period, offs)
        except (ValueError, IndexError) as exc:
            print(f"BAD {exc}")
            return 2
        print(f"# PHASE={argv[2]} seed={argv[4]} period_s={period:g} cycles={argv[3]} -- kind 'delay': seconds "
              f"waited (from the pre-cut check seeing the cable heard / from the down being called); kind 'phase': "
              f"the cut or restore STARTS this many seconds after the last frame heard (last_heard_mono)")
        print("cycle\tcut_kind\tcut_value\trestore_kind\trestore_value")
        for i, ck, cv, rk, rv in rows:
            print(f"{i}\t{ck}\t{cv:.3f}\t{rk}\t{rv:.3f}")
    elif cmd == "phase-wait":
        w = phase_wait(argv[2], argv[3], float(argv[4]), float(argv[5]), float(argv[6]))
        print(f"{w['wake']:.6f}\t{w['delay']:.3f}\t{fmt(w['anchor'], 6)}\t{w['src']}")
    elif cmd == "cut-down":
        d = wait_cut_down(argv[2], parse_dirs(argv[3]), float(argv[4]), float(argv[5]), float(argv[6]),
                          argv[7] if len(argv) > 7 else None)
        print("TIMEOUT" if d is None else "\t".join([
            fmt(d["down_s"]), fmt(d["rule_s"]), fmt(d["rpt_s"]), fmt(d["lh"], 6), fmt(d["phi"]), d["phi_src"],
            fmt(d["phi_grid"])]))
    elif cmd == "restore-up":
        anchor = num(argv[6]) if len(argv) > 6 else None
        d = wait_restore_up(argv[2], parse_dirs(argv[3]), float(argv[4]), float(argv[5]), anchor,
                            argv[7] if len(argv) > 7 else None)
        print("TIMEOUT" if d is None else "\t".join([
            fmt(d["up_s"]), fmt(d["rpt_s"]), fmt(d["poll_s"]), fmt(d["lh"], 6), fmt(d["phi"]), d["phi_src"],
            fmt(d["phi_grid"])]))
    elif cmd == "quiet":
        print("\t".join(watch_quiet(argv[2], float(argv[3]), float(argv[4]), argv[5] if len(argv) > 5 else None)))
    elif cmd == "single-end":
        down_dir, = parse_dirs(argv[3])
        up_dir, = parse_dirs(argv[4])
        print("\t".join(watch_single_end(argv[2], down_dir, up_dir, float(argv[5]), float(argv[6]),
                                         float(argv[7]), float(argv[8]), argv[9] if len(argv) > 9 else None)))
    elif cmd == "period-check":
        try:
            p = report(argv[2]).get("period_s")
        except (OSError, ValueError) as exc:
            p = exc
        if isinstance(p, (int, float)) and abs(p - float(argv[3])) < 1e-9:
            print(f"OK the heartbeat's period_s {p:g} is the proxy's LLDP_BEACON_INTERVAL_S {float(argv[3]):g}")
        else:
            print(f"BAD the heartbeat's period_s is {p!r}, the proxy's LLDP_BEACON_INTERVAL_S {argv[3]} -- the "
                  f"phases would be read against the wrong round")
    elif cmd == "sub":
        a, b = num(argv[2]), num(argv[3])
        print(fmt(None if a is None or b is None else a - b))
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
