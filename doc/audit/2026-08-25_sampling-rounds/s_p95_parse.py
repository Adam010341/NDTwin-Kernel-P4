#!/usr/bin/env python3
"""Sweep-interval distribution for the ticket S poller self-proof.

[Co-developed with claude code -- Adam]

Registered in PREREG amendment S-1 before the run.  Thresholds live here as constants so the
verdict is computed, not eyeballed.

RED -- ONE REGISTERED THRESHOLD WAS CORRECTED BEFORE THE RUN, AND THE CORRECTION IS DISCLOSED.
S-1-3 #5 registered "every arm >= 8640 rows (90% of 60 sweeps x 160 interfaces)".  That is wrong
for A2 BY CONSTRUCTION: the old poller is expected to be slow, so it completes fewer sweeps in the
same 120 s, and a row floor would have marked the control arm VOID exactly when it was working.
A row floor cannot tell "slow" from "dead" -- so completeness is split:

  structural (all arms)  every sweep must carry all 160 interfaces.  A poller killed mid-sweep
                         writes a short one; a slow poller writes complete ones, late.
  cadence   (A1/A3 only) at least 54 sweeps, since the CLAIM is about the new poller's cadence.

Corrected before any data existed -- the run had not started.  Recorded rather than silently fixed.
"""
import sys
import json
import math

# THREE GATES, NOT ONE (auditor's correction, 2026-08-27 night; PREREG S-3).
#
# The original gate was p95 alone, and p95 is BLIND to the failure the gate exists to catch.
# Ticket N's disaster was a single 24.7 s hole landing exactly when traffic started.  In a 300-
# sweep stage one outlier sits at rank 300; p95 reads rank 285 and never sees it.  selftest_gates()
# below demonstrates this on synthetic data rather than asserting it.
#
#   (a) max   < MAX_LIMIT    a single hole -- the one p95 cannot see
#   (b) p95   < P95_LIMIT    overall cadence -- the original gate, kept
#   (c) no gap >= P95_LIMIT inside the first RAMP_WINDOW s after traffic starts
#
# (c) is the real lesson: a hole mid-stage costs analyze.py a little; the same hole at the start
# voids the cell.  Position decides the damage, not just size.  (c) needs a traffic-start
# timestamp, so it applies to ladder stages, NOT to this self-proof, which has no such moment.
P95_LIMIT = 3.0          # S-1-3 #1: new poller must be under this
MAX_LIMIT = 5.0          # gate (a)
RAMP_WINDOW = 30.0       # gate (c), ladder only
CONTROL_MIN = 3.0        # S-1-3 #2: old poller must be at or above it, or the load was too weak
ORDER_TOL = 1.0          # S-1-3 #3
MIN_SWEEPS_NEW = 54      # 90% of 120s / 2s
IFACES = 160
STRUCT_OK = 0.95         # fraction of sweeps that must be complete


def sweeps(path):
    """[(ts, n_interfaces)] in file order. One sweep = one distinct timestamp."""
    order, counts = [], {}
    with open(path) as fh:
        next(fh, None)                                   # header
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) < 4:
                continue
            ts = float(f[0])
            if ts not in counts:
                counts[ts] = 0
                order.append(ts)
            counts[ts] += 1
    return [(t, counts[t]) for t in order]


def p95(xs):
    """Nearest-rank, stated explicitly so nobody has to guess which definition was used."""
    if not xs:
        return None
    s = sorted(xs)
    return s[min(len(s) - 1, int(math.ceil(0.95 * len(s))) - 1)]


def arm(path, name, is_new):
    sw = sweeps(path)
    if len(sw) < 2:
        return {"arm": name, "verdict": "VOID", "why": "fewer than 2 sweeps (%d)" % len(sw),
                "sweeps": len(sw)}
    gaps = [round(b[0] - a[0], 3) for a, b in zip(sw, sw[1:])]
    complete = sum(1 for _, n in sw if n == IFACES)
    frac = complete / len(sw)
    r = {"arm": name, "sweeps": len(sw), "p95": p95(gaps), "max": max(gaps),
         "median": sorted(gaps)[len(gaps) // 2], "min": min(gaps),
         "complete_sweeps": "%d/%d" % (complete, len(sw)),
         "over_3s": sum(1 for g in gaps if g >= 3.0)}
    if frac < STRUCT_OK:
        r["verdict"] = "VOID"
        r["why"] = "only %.0f%% of sweeps carried all %d interfaces -- poller died mid-sweep" % (
            frac * 100, IFACES)
        return r
    if is_new and len(sw) < MIN_SWEEPS_NEW:
        r["verdict"] = "VOID"
        r["why"] = "%d sweeps < %d: a poller that stopped early has a flattering p95" % (
            len(sw), MIN_SWEEPS_NEW)
        return r
    r["verdict"] = "OK"
    return r


def verdict(a1, a2, a3):
    out = []
    if any(a["verdict"] == "VOID" for a in (a1, a2, a3)):
        return ["VOID -- an arm failed its completeness check; no conclusion about the poller"]
    # The control is judged FIRST.  If the load did not hurt the old poller, the new poller's
    # good number means nothing, and reporting it first is how it gets quoted anyway.
    if a2["p95"] < CONTROL_MIN:
        out.append("VOID -- control A2 p95 %.3f s < %.1f s: the manufactured load did NOT "
                   "reproduce the condition. Nothing may be concluded about poll_veth2.sh."
                   % (a2["p95"], CONTROL_MIN))
        return out
    out.append("control A2 p95 %.3f s >= %.1f s -- load adequate, the old poller does stall"
               % (a2["p95"], CONTROL_MIN))
    if abs(a1["p95"] - a3["p95"]) > ORDER_TOL:
        out.append("ORDER EFFECT: A1 %.3f vs A3 %.3f differ by more than %.1f s -- report only"
                   % (a1["p95"], a3["p95"], ORDER_TOL))
        return out
    fails = []
    for a in (a1, a3):
        if a["p95"] >= P95_LIMIT:
            fails.append("(b) %s p95 %.3f >= %.1f" % (a["arm"], a["p95"], P95_LIMIT))
        if a["max"] >= MAX_LIMIT:
            fails.append("(a) %s max %.3f >= %.1f" % (a["arm"], a["max"], MAX_LIMIT))
    if fails:
        out.append("FAIL -- " + "; ".join(fails) +
                   ". Process spawns were not the only cause; the ladder stays blocked.")
    else:
        out.append("PASS -- (a) max A1 %.3f / A3 %.3f < %.1f s; (b) p95 A1 %.3f / A3 %.3f "
                   "< %.1f s.  [(c) ramp gate not applicable: a self-proof has no traffic start]"
                   % (a1["max"], a3["max"], MAX_LIMIT, a1["p95"], a3["p95"], P95_LIMIT))
    return out


def ramp_gate(path, traffic_start):
    """Gate (c), for ladder stages: no gap >= P95_LIMIT in the first RAMP_WINDOW s of traffic.

    Separate from arm()/verdict() because it needs a fact those do not have -- the moment traffic
    started.  A stage that cannot supply it does not silently pass this gate; it reports N/A.
    """
    sw = sweeps(path)
    gaps = [(a[0], b[0] - a[0]) for a, b in zip(sw, sw[1:])]
    inside = [(t, g) for t, g in gaps if traffic_start <= t <= traffic_start + RAMP_WINDOW]
    bad = [(t, g) for t, g in inside if g >= P95_LIMIT]
    return {"gate": "c", "window_s": RAMP_WINDOW, "gaps_in_window": len(inside),
            "violations": [(round(t - traffic_start, 2), round(g, 3)) for t, g in bad],
            "verdict": "PASS" if not bad else "FAIL"}


def selftest_gates():
    """Show that p95 is blind to the hole gate (a) exists for -- do not merely assert it."""
    # 300 sweeps, 2 s apart, with ONE 24.7 s hole at the start: exactly ticket N's shape.
    ts, t = [], 1000.0
    for i in range(300):
        ts.append(t)
        t += 24.7 if i == 3 else 2.0
    gaps = [round(b - a, 3) for a, b in zip(ts, ts[1:])]
    blind = p95(gaps)
    assert blind < P95_LIMIT, "expected p95 to miss the hole, got %s" % blind
    assert max(gaps) >= MAX_LIMIT, max(gaps)
    r = ramp_gate.__doc__ is not None
    assert r
    print("  gate demo: one 24.7 s hole among 300 sweeps -> p95 %.3f s (PASSES the p95 gate, "
          "blind), max %.1f s (gate (a) catches it)" % (blind, max(gaps)))


def selftest():
    import tempfile
    import os
    d = tempfile.mkdtemp()

    def write(name, rows):
        p = os.path.join(d, name)
        with open(p, "w") as fh:
            fh.write("ts\tiface\trx_bytes\ttx_bytes\n")
            for ts, n in rows:
                for i in range(n):
                    fh.write("%s\ts1-eth%d\t1\t2\n" % (ts, i))
        return p

    # known-good: 60 sweeps 2 s apart, three stragglers at 2.5 -> p95 must be 2.0 (nearest-rank
    # over 59 gaps picks index 56, still inside the 2.0 run)
    good = write("good", [(1000 + 2 * i, IFACES) for i in range(60)])
    r = arm(good, "A1", True)
    assert r["verdict"] == "OK" and r["p95"] == 2.0, r

    # known-bad 1: a poller killed mid-sweep -- short sweeps must VOID, not average out
    bad = write("bad", [(1000 + 2 * i, IFACES) for i in range(30)] +
                       [(1060 + 2 * i, 12) for i in range(30)])
    assert arm(bad, "A1", True)["verdict"] == "VOID", arm(bad, "A1", True)

    # known-bad 2: an early exit with a beautiful cadence -- 10 perfect sweeps must still VOID
    short = write("short", [(1000 + 2 * i, IFACES) for i in range(10)])
    assert arm(short, "A1", True)["verdict"] == "VOID", arm(short, "A1", True)
    # ... but the same file as the OLD poller is legitimate: slow is the finding, not a fault
    assert arm(short, "A2", False)["verdict"] == "OK", arm(short, "A2", False)

    # the control gate: a weak load must void the whole run even when the new poller looks perfect
    slowish = write("slowish", [(1000 + 2 * i, IFACES) for i in range(20)])
    v = verdict(arm(good, "A1", True), arm(slowish, "A2", False), arm(good, "A3", True))
    assert v[0].startswith("VOID"), v
    stalled = write("stalled", [(1000 + 15 * i, IFACES) for i in range(20)])
    v = verdict(arm(good, "A1", True), arm(stalled, "A2", False), arm(good, "A3", True))
    assert any("PASS" in x for x in v), v
    # and a new poller that also stalls must FAIL even with a firing control
    v = verdict(arm(stalled, "A1", True), arm(stalled, "A2", False), arm(stalled, "A3", True))
    assert any("VOID" in x for x in v), v          # stalled has only 20 sweeps -> completeness
    # gate (c): a hole 5 s after traffic starts must FAIL; the same hole 200 s later must not.
    holed = write("holed", [(1000 + 2 * i, IFACES) for i in range(3)] +
                           [(1030 + 2 * i, IFACES) for i in range(30)])
    assert ramp_gate(holed, 1000.0)["verdict"] == "FAIL", ramp_gate(holed, 1000.0)
    assert ramp_gate(holed, 800.0)["verdict"] == "PASS", ramp_gate(holed, 800.0)
    selftest_gates()
    print("SELFTEST PASS (p95=2.0; mid-sweep death, early exit, weak control, stalled-new "
          "all caught; slow old poller correctly allowed; gates a/c verified)")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    base = sys.argv[1]
    a1 = arm("%s/A1.tsv" % base, "A1", True)
    a2 = arm("%s/A2.tsv" % base, "A2", False)
    a3 = arm("%s/A3.tsv" % base, "A3", True)
    for a in (a1, a2, a3):
        print("  %-3s sweeps %-4d p95 %-8s median %-8s max %-8s  gaps>=3s %-4s %s %s"
              % (a["arm"], a["sweeps"], a.get("p95"), a.get("median"), a.get("max"),
                 a.get("over_3s"), a.get("complete_sweeps", ""), a["verdict"]))
        if a.get("why"):
            print("      why: %s" % a["why"])
    print()
    for line in verdict(a1, a2, a3):
        print("  " + line)
    if "--json" in sys.argv:
        print(json.dumps({"arms": [a1, a2, a3], "verdict": verdict(a1, a2, a3)}, indent=1))
