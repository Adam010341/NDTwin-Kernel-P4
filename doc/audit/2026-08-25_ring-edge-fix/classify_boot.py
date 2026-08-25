#!/usr/bin/env python3
"""Three-leg boot classifier for Phase 2 (PREREG.md 5-bis R1).

🔴 SCOPE: PRE-B CORPUS ONLY. B (bfb0569) moved the rebuild off the event loop, which changed this
log grammar for the third time: `Topology update triggered` now counts REBUILDS, not events, and
events are counted by `switch-enter queued for topology rebuild` instead. A post-B boot reads
ent=10 with trig/gsw/glk=2 and is perfectly healthy, so every rule below would misclassify it.
Phase 3 judges by the invariant (assert_invariant.py) plus the fidelity pair; this file is kept
for reading the archived pre-B corpus and must not be pointed at new runs.

WHY THIS EXISTS. Phase 0 classified boots by cumulative counters:
`triggered - "Complete get_switch" == 1` meant "parked in get_switch". That rule
held 47/47 on archived logs -- but it was validated on the log grammar of an
UNBOUNDED :752. Fix A wraps :752 in a timeout, and a fired timeout takes the
:757 abort path ("Switch list is empty after timeout", then return) which
produces the SAME cumulative signature while being a perfectly healthy recovery.
The rule would read the fix working as the bug persisting.

So Phase 2 reads the LAST invocation only, where "did it finish" is a question
about one chain of log lines rather than about a sum:

    Topology update triggered          <- last one starts the window
      ... Complete get_switch          <- got past :752
      ... Complete get_link            <- got past :779
      ... Switch entered:              <- finished the handler
    or ... Switch list is empty after timeout   <- healthy give-up (A only)
    or  nothing more                   <- parked, and where says which site

VALIDATED BEFORE USE against every archived ryu log: on the historical corpus
(no fix, so abort never fires) this must agree with the Phase 0 rule on every
file. Disagreement means one of the two rules is wrong and both are suspect.
`--selftest` runs exactly that comparison.

[Co-developed with claude code -- Adam]
"""
import sys, os, glob, argparse

TRIG = "Topology update triggered"
GSW  = "Complete get_switch"
GLK  = "Complete get_link"
ENT  = "Switch entered:"
# Fix A gives the handler two healthy give-up exits, not one; both must count as
# "recovered", or the second would be read as a park.
ABRT  = "Switch list is empty after timeout"
ABRT2 = "Link list unavailable after timeout"
HTO  = "host-table read did not answer"
# The line fix A must emit when its timeout fires. Absent + parked == injection
# failure, not falsification (PREREG 5-bis R2), so it is counted separately.
TOPO_TO = "topology read did not answer"


def counts(text):
    return {k: text.count(k) for k in (TRIG, GSW, GLK, ENT, ABRT, ABRT2, HTO, TOPO_TO)}


def last_chain(text):
    """What happened after the final `Topology update triggered`."""
    i = text.rfind(TRIG)
    if i < 0:
        return "NO-INVOCATION", {}
    tail = text[i:]
    seen = {"gsw": GSW in tail, "glk": GLK in tail,
            "ent": ENT in tail, "abort": (ABRT in tail or ABRT2 in tail)}
    if seen["ent"]:
        # NOT "the handler returned". `Switch entered:` is logged at :793, and the
        # handler goes on to notify (:797) and then to load_static_topology (:851).
        # The 2026-08-24 wedges all reach this line and then park inside the walk.
        # The --selftest caught exactly this: nine logs classified COMPLETED that the
        # Phase 0 rule called downstream-of-handler, and the Phase 0 rule was right.
        return "REACHED-ENT", seen
    if seen["abort"]:
        return "ABORTED-HEALTHY", seen        # only reachable once A is in
    if seen["glk"]:
        return "PARKED-after-get_link", seen  # past :779, stuck before :793
    if seen["gsw"]:
        return "PARKED@get_link", seen
    return "PARKED@get_switch", seen


def phase0_rule(c):
    """The Phase 0 cumulative rule, kept only to cross-check against."""
    if c[ENT] >= 10:
        return "HEALTHY"
    d = c[TRIG] - c[GSW]
    if d == 1:
        return "WEDGE@get_switch"
    if d == 0 and c[GSW] > c[GLK]:
        return "WEDGE@get_link"
    if d == 0 and c[GSW] == c[GLK]:
        return "WEDGE@downstream-of-handler"
    return f"WEDGE@unclassified(d={d})"


def verdict(text):
    c = counts(text)
    chain, _ = last_chain(text)
    healthy = c[ENT] >= 10
    if healthy:
        state = "HEALTHY"
    elif chain == "ABORTED-HEALTHY":
        state = "RECOVERED-BUT-INCOMPLETE"   # A fired and the loop kept turning
    elif chain == "REACHED-ENT":
        # Past :793 but fewer than ten switches ever got there: parked in what the
        # handler does AFTER the marker -- the notify or the walk.
        state = "WEDGE@downstream-of-handler"
    elif chain.startswith("PARKED"):
        state = "WEDGE:" + chain
    else:
        state = "INCONCLUSIVE:" + chain
    return state, chain, c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="*")
    ap.add_argument("--selftest", action="store_true",
                    help="agree-with-Phase-0 check over archived logs")
    a = ap.parse_args()

    if a.selftest:
        root = os.path.join(os.path.dirname(__file__), "..")
        files = sorted(glob.glob(os.path.join(root, "**", "*ryu*.log"), recursive=True))
        bad = skipped = 0
        for f in files:
            t = open(f, errors="replace").read()
            c = counts(t)
            if c[ABRT] or c[ABRT2]:
                skipped += 1
                print(f"  SKIP (abort present, grammars differ by design) {os.path.basename(f)}")
                continue
            state, chain, _ = verdict(t)
            old = phase0_rule(c)
            new = ("HEALTHY" if state == "HEALTHY"
                   else state.replace("WEDGE:PARKED@", "WEDGE@"))
            # downstream-of-handler: old rule's name for "handler finished, stuck later".
            agree = (new == old)
            if not agree:
                bad += 1
                print(f"  🔴 DISAGREE {os.path.basename(f):<34} old={old:<28} new={state}")
        print(f"\n{len(files)} logs, {skipped} skipped, {bad} disagreements")
        print("PASS: three-leg rule reproduces the Phase 0 rule on the historical corpus"
              if bad == 0 else "🔴 FAIL: rules disagree -- both are suspect")
        return 0 if bad == 0 else 1

    for f in a.logs:
        t = open(f, errors="replace").read()
        state, chain, c = verdict(t)
        print(f"{os.path.basename(f)}")
        print(f"  verdict     : {state}")
        print(f"  last chain  : {chain}")
        print(f"  counts      : trig={c[TRIG]} gsw={c[GSW]} glk={c[GLK]} ent={c[ENT]}")
        print(f"  aborts={c[ABRT]}+{c[ABRT2]}  host-timeouts={c[HTO]}  topo-timeouts={c[TOPO_TO]}")
        if c[TOPO_TO] == 0 and state.startswith("WEDGE"):
            print("  ⚠️  zero topology-timeout lines: check the injection landed"
                  " before reading this as falsification (PREREG 5-bis R2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
