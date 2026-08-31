#!/usr/bin/env python3
"""
ratio_gate.py -- PREREG-E §2's `ratio` gate, and the two forced runs that decide whether it may
be trusted.

[Co-developed with claude code -- Adam]

NOTHING IS RESTATED.  The ratio, the threshold and the health verdict all come from
cell_verdict.py, imported.  A second implementation of `mean(twin)/gt` here would be a second
number that merely resembles the one the round reports, and it would drift on the first edit.
The consequence is a hard dependency on the plot venv -- which is checked and refused loudly
rather than worked around, because a `python3` missing the round's modules is exactly how
"I could not reproduce it" got recorded as evidence once already.

THE FORCE-RED, AND WHY IT IS SHAPED LIKE THIS.
    PREREG §2 registers: "feed a copy with the tail 20% of samples artificially cut off; the gate
    must go red".  Implemented as: zero the twin's reading on the measured edge for every row in
    the last 20% of the statistics window, and leave the interface tx counters untouched.

    That is the literal reading, and it is also the only one that bites.  `ratio` is
    mean(twin)/gt with gt taken from the edge's OWN tx counter over the window, so simply
    DELETING the last 20% of rows shortens both sides and leaves the ratio where it was -- a
    force-red that comes out green for a reason that has nothing to do with the gate.  Zeroing
    the tail drops the numerator by ~20% while ground truth stands, i.e. ~0.80.

    🔑 It is also the exact shape PREREG §3b names as the most likely batching bug: "_pending not
    flushed at the end".  So the forced input is not an arbitrary corruption; it is the failure
    the gate is deployed to catch.

BOTH ASSERTIONS ARE MADE, IN THIS ORDER, AND EITHER ONE FAILING STOPS THE ROUND:
    1. the SOURCE cell must already be ratio-green.  A force-red built from an already-red cell
       proves nothing -- the gate would have gone red without the injection.
       (memory/injections-must-assert-their-own-success: a deletion leaves a hole, but a rename
       leaves a plausible wrong answer, quietly.)
    2. the PRODUCED cell must be ratio-red.  If it is not, the gate cannot detect a 20% loss and
       every green reading in the round is uninformative.
"""
import argparse
import gzip
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROUND25 = os.path.join(os.path.dirname(HERE), "2026-08-25_sampling-rounds")
PRIOR = os.path.join(os.path.dirname(HERE), "2026-08-20_sampling-rate-and-cpu")
sys.path.insert(0, ROUND25)
sys.path.insert(0, PRIOR)

try:
    import cell_verdict as CV                                  # noqa: E402 -- reuse, never restate
    from plot_figures import RAW, load_twin_path               # noqa: E402
    from plot_ladder_rates import EDGE, SPAN                   # noqa: E402
except ImportError as e:                                       # noqa: BLE001
    sys.stderr.write(
        f"REFUSE: cannot import the round's own modules ({e}).\n"
        "        cell_verdict.py needs the plotting venv, not the system python3 and not conda's\n"
        "        (they share a binary but not site-packages).  Point PY_PLOT at an interpreter\n"
        "        that can `import plot_figures, plot_ladder_rates` and re-run.  Falling back to a\n"
        "        second implementation of the ratio is what this file exists to prevent.\n")
    sys.exit(2)


def _open(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def ratio_of(cell):
    v = CV.verdict(cell)
    return v.get("ratio"), v


def make_forcered(src, dst, tail_frac):
    """Copy `src`'s cell files to `dst`, zeroing the twin's EDGE reading over the last
    `tail_frac` of the statistics window.  Everything else -- tx counters, timestamps, the client
    json, the cpu trace -- is carried across byte-identically."""
    sp = CV._find(src, "twin.jsonl")
    if sp is None:
        raise SystemExit(f"REFUSE: source cell {src!r} has no twin trace in {RAW}.\n"
                         "        A force-red built from an absent cell is the 'it passed because\n"
                         "        there was nothing there' gate this round is required to avoid.")

    # Assertion 1 -- the source must already be green, or the injection proves nothing.
    r_src, v_src = ratio_of(src)
    print(f"  source     {CV._fmt(v_src)}")
    if r_src is None or r_src < CV.SATURATED_RATIO:
        raise SystemExit(
            f"REFUSE: source cell {src!r} has ratio={r_src}, already below {CV.SATURATED_RATIO}.\n"
            "        The force-red would come out red without the injection, so it would not\n"
            "        test anything.  Choose a ratio-green archived cell.")

    # The loader trims and clips to SPAN, so "the last 20%" must be of the window the verdict
    # actually sees -- not of the file, which contains rows the verdict discards.
    rows = load_twin_path(sp, span=SPAN)
    t_first, t_last = rows[0]["t"], rows[-1]["t"]
    cut = t_last - (t_last - t_first) * tail_frac
    print(f"  window     {t_last - t_first:.1f}s of rows; zeroing {EDGE} after t+"
          f"{cut - t_first:.1f}s ({tail_frac:.0%} tail)")

    dp = os.path.join(RAW, f"{dst}_twin.jsonl")
    n_zeroed = 0
    with _open(sp) as fh, open(dp, "w") as out:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                out.write(line)
                continue
            if isinstance(r, dict) and "twin" in r and r.get("t", 0) > cut:
                if r["twin"].get(EDGE):
                    r["twin"][EDGE] = 0
                    n_zeroed += 1
            out.write(json.dumps(r) + "\n")
    if n_zeroed == 0:
        raise SystemExit(
            "REFUSE: the injection changed nothing -- 0 rows were zeroed.\n"
            "        A mutation that did not land must never be reported as 'the gate held'.")
    print(f"  injected   {n_zeroed} row(s) zeroed on {EDGE} -> {dp}")

    # The other three files are carried across unchanged so the produced cell is a complete cell:
    # cell_verdict marks LOSS-UNKNOWN without a client.json, and a gate that goes red for a
    # missing file instead of for the ratio is not the gate that was registered.
    for suffix in ("client.json", "cpu.jsonl", "server.log"):
        s = CV._find(src, suffix)
        if s:
            shutil.copyfile(s, os.path.join(RAW, f"{dst}_{suffix.replace('.gz','')}")
                            if not s.endswith(".gz") else os.path.join(RAW, f"{dst}_{suffix}.gz"))

    # Assertion 2 -- the produced cell must be red, or the gate cannot see a 20% loss at all.
    r_dst, v_dst = ratio_of(dst)
    print(f"  produced   {CV._fmt(v_dst)}")
    if r_dst is None or r_dst >= CV.SATURATED_RATIO:
        raise SystemExit(
            f"REFUSE: the forced cell reads ratio={r_dst}, still at or above "
            f"{CV.SATURATED_RATIO}.\n"
            "        The gate cannot detect a 20% sample loss.  PREREG §2: stop the round and fix\n"
            "        the gate; do not lower the threshold to make this pass.")
    print(f"  FORCE-RED  OK: {r_src:.4f} -> {r_dst:.4f}, crossing {CV.SATURATED_RATIO}")
    return 0


def check(cell, expect):
    r, v = ratio_of(cell)
    print(f"  {CV._fmt(v)}")
    if r is None:
        print(f"GATE ratio cell={cell} verdict=UNRUNNABLE (no ratio -- {v.get('mark')})")
        return 2
    verdict = "GREEN" if r >= CV.SATURATED_RATIO else "RED"
    print(f"GATE ratio cell={cell} ratio={r:.4f} threshold={CV.SATURATED_RATIO} verdict={verdict}")
    # 🔴 The exit code carried TWO meanings and one of them made a passing force-test look like a
    # failure.  With `--expect red` on a genuinely red cell it printed "force-test OK" and then
    # returned 1, because the final line answered "what colour was it" -- so any caller using shell
    # truthiness read a SUCCESSFUL force-red as a failure, and a force-red could never be recorded
    # as a pass.  Fixed 2026-09-01 by splitting the two questions:
    #
    #   --expect given      -> the exit code answers ONLY "did the force-test pass": 0 pass, 2 fail.
    #   --expect not given  -> the exit code carries the verdict itself: 0 green, 1 red.
    #
    # Same family as the `iperf3` string that is killed in one file and absolved in another, and as
    # `comm` meaning three different lengths in three tools: one value, two semantics, drifting at a
    # module boundary with nothing to report the drift.  [Co-developed with claude code -- Adam]
    if expect:
        if verdict != expect.upper():
            print(f"GATE ratio FORCE-TEST FAILED: expected {expect.upper()}, got {verdict}.")
            print("     PREREG §2: fix the gate, do not move the threshold.")
            return 2
        print(f"GATE ratio force-test OK: expected {expect.upper()}, got {verdict}")
        return 0
    return 0 if verdict == "GREEN" else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", metavar="CELL")
    ap.add_argument("--expect", choices=("green", "red"))
    ap.add_argument("--make-forcered", nargs=2, metavar=("SRC", "DST"))
    ap.add_argument("--tail-frac", type=float, default=0.20)
    a = ap.parse_args()
    if a.make_forcered:
        return make_forcered(a.make_forcered[0], a.make_forcered[1], a.tail_frac)
    if a.check:
        return check(a.check, a.expect)
    ap.error("nothing to do: pass --check or --make-forcered")


if __name__ == "__main__":
    sys.exit(main())
