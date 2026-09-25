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
    hb_watch.py session   <report>
    hb_watch.py all-heard <report> <after_mono>              -> OK n/n | BAD ...
    hb_watch.py wait-heard <report> <dirs> <after_mono> <cap_s>
    hb_watch.py wait-down  <report> <dirs> <t0_mono> <timeout_s> <cap_s>
    hb_watch.py others-up  <report> <dirs> <timeout_s>
    hb_watch.py summary   <cycles.tsv> <timeout_s> <period_s>
    hb_watch.py census-verdict <sniff-dir> <report-snapshot>
    hb_watch.py first-hit <sniff-dir>                        -> the first host that saw one, or ""
    hb_watch.py --self-test

<dirs> is "1:3>3:1,3:1>1:3" -- tx dpid:port > rx dpid:port, comma separated.
"""
import contextlib
import glob
import io
import json
import os
import statistics
import sys
import tempfile
import time


def load(path):
    with open(path) as fh:
        return json.load(fh)


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


# ------------------------------------------------------------------------------ polling wrappers
def wait_heard(path, dirs, after, cap):
    """Seconds (from `after`) until every one of `dirs` has been heard after `after`."""
    end = time.monotonic() + cap
    while time.monotonic() < end:
        try:
            doc = load(path)
            if running(doc) and all(heard_after(r, after) for r in find(doc, dirs)):
                return max(r["last_heard_mono"] for r in find(doc, dirs)) - after
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.1)
    return None


def wait_down(path, dirs, t0, timeout, cap):
    """Seconds after t0 until every one of `dirs` is not heard by the proxy's rule."""
    end = t0 + cap
    while time.monotonic() < end:
        now = time.monotonic()
        try:
            doc = load(path)
            if not running(doc):
                return None
            if all(not_heard(r, now, timeout) for r in find(doc, dirs)):
                return now - t0
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.1)
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
    lines, ok = summary([(1, 12.1, 3.0), (2, 14.0, 1.0)], 15, 5)
    expect("summary: two detected cycles pass", "True", ok)
    expect("summary: states min/median/max", "  cut", lines[1])
    lines, ok = summary([(1, None, 3.0)], 15, 5)
    expect("summary: an undetected cut fails", "False", ok)
    lines, ok = summary([], 15, 5)
    expect("summary: no cycle is not a pass", "False", ok)
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
    print("SELF-TEST PASS" if rc == 0 else "SELF-TEST FAIL")
    return rc


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "now":
        print(f"{time.monotonic():.3f}")
    elif cmd == "session":
        print(load(argv[2]).get("session") or "")
    elif cmd == "all-heard":
        print(all_heard(load(argv[2]), float(argv[3])))
    elif cmd == "wait-heard":
        r = wait_heard(argv[2], parse_dirs(argv[3]), float(argv[4]), float(argv[5]))
        print("TIMEOUT" if r is None else f"{r:.3f}")
    elif cmd == "wait-down":
        r = wait_down(argv[2], parse_dirs(argv[3]), float(argv[4]), float(argv[5]), float(argv[6]))
        print("TIMEOUT" if r is None else f"{r:.3f}")
    elif cmd == "others-up":
        print(others_up(load(argv[2]), parse_dirs(argv[3]), time.monotonic(), float(argv[4])))
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
            report = load(argv[3])
        except (OSError, ValueError):
            report = None
        print(census_verdict(sniffs, report))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
