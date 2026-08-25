#!/usr/bin/env python3
"""Per-cell verdict for the extended sampling ladder: SATURATED / DATAPLANE-HURT / OK.

[Co-developed with claude code -- Adam]

WHY THIS FILE EXISTS AT ALL. The handoff brief named `twin/truth` and `delivered` as existing
columns to read. They are not columns: `panel_stats` (plot_ladder_rates.py:58) returns
q/gt/lam/sd_mean/floor and nothing else, and there is no `delivered` anywhere in the round. The
ratio has to be computed, so it gets computed HERE, once, and both the stop-condition in
ladder_ext.sh and the report read the same function. See PREREG §1-bis correction 2.

THE TWO CHECKS ARE NOT INDEPENDENT, WHICH IS THE WHOLE POINT OF THE THIRD ONE.
`gt` is that interface's OWN tx counter (plot_ladder_rates.py:66-67). So:
  * samples lost between switch and kernel  -> ratio falls          -> SATURATED
  * packets lost in the fabric UPSTREAM     -> gt falls WITH twin   -> ratio stays ~1, invisible
The second case is exactly "sampling started hurting the data plane", so it needs a quantity
that is not derived from the switch's own counter: the RECEIVER's report. In iperf3 UDP that
comes back inside `end.sum` of the CLIENT json (the server's report is relayed to the client).
It is NOT in *_server.log -- measure.sh:49 writes one but to $OUT, and no *_server.log was ever
archived. See PREREG §1-bis correction 3.

NOTHING IS RESTATED. Loader, EDGE, SPAN and the quantum arithmetic are imported from the
round's own modules so this cannot drift from the figures beside it.
"""
import gzip
import json
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PRIOR = os.path.join(os.path.dirname(HERE), "2026-08-20_sampling-rate-and-cpu")
sys.path.insert(0, PRIOR)

from plot_figures import RAW, load_twin_path          # noqa: E402 -- reuse, never restate
from plot_ladder_rates import EDGE, SPAN, panel_stats  # noqa: E402

# Pre-registered in PREREG §4. Written here as constants so that a later edit to them shows up
# as a diff against the commit that fixed them, rather than as a quietly different number.
SATURATED_RATIO = 0.95   # mean(twin)/gt below this => samples are being lost, not measured
DATAPLANE_LOSS_PCT = 2.0  # end.sum.lost_percent above this => the data plane is being hurt
# Threshold provenance (PREREG §4): single-flow baseline m256_poll reads lost_percent 0.513;
# known-bad ladder from 5965983 reads 1.1 / 24.8 / 34.1 at 16 / 32 / 64 flows. 2.0 sits above
# the baseline and far below any known-bad value.


def _open(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def _find(cell, suffix):
    """Explicit paths, never a glob: `m1*` eats m1024/m128/m16 (PREREG §1-bis correction 4)."""
    for ext in ("", ".gz"):
        p = os.path.join(RAW, f"{cell}_{suffix}{ext}")
        if os.path.exists(p):
            return p
    return None


def lost_percent(cell):
    """Receiver-side loss, from the client json's end.sum. Returns None when absent -- a missing
    file must never read as 0.0, which would look like a perfect cell."""
    p = _find(cell, "client.json")
    if p is None:
        return None
    with _open(p) as fh:
        doc = json.load(fh)
    return doc.get("end", {}).get("sum", {}).get("lost_percent")


def verdict(cell):
    tp = _find(cell, "twin.jsonl")
    if tp is None:
        return dict(cell=cell, mark="NO-DATA", why="no twin trace")
    rows = load_twin_path(tp, span=SPAN)
    s = panel_stats(rows)
    if s is None:
        return dict(cell=cell, mark="NO-DATA", why=f"twin reported nothing on {EDGE}")

    ratio = st.mean(s["vs"]) / s["gt"] if s["gt"] else None
    loss = lost_percent(cell)

    marks = []
    if ratio is not None and ratio < SATURATED_RATIO:
        marks.append("SATURATED")
    if loss is not None and loss > DATAPLANE_LOSS_PCT:
        marks.append("DATAPLANE-HURT")
    # An absent loss number is not a pass. It is stated, so a cell can never be called OK on
    # evidence that was never collected.
    if loss is None:
        marks.append("LOSS-UNKNOWN")

    return dict(cell=cell, mark="+".join(marks) if marks else "OK",
                ratio=ratio, gt_mbit=s["gt"], lost_pct=loss, lam=s["lam"],
                quantum=s["q"], spread=s["sd_mean"], floor=s["floor"],
                distinct=s["distinct"])


def _fmt(v):
    keys = ("cell", "mark", "ratio", "gt_mbit", "lost_pct", "lam", "quantum",
            "spread", "floor", "distinct")
    out = []
    for k in keys:
        x = v.get(k)
        if x is None:
            continue
        out.append(f"{k}={x:.4g}" if isinstance(x, float) else f"{k}={x}")
    if "why" in v:
        out.append(f"why={v['why']}")
    return "  ".join(out)


def selftest():
    """PREREG §1-bis: prove the function works on a KNOWN-NON-EMPTY input before trusting it on
    a new one, and prove it can tell a known-bad apart from a pass. A ratio function that
    silently returns 'not found' would otherwise mark every new cell SATURATED and the run would
    read a broken reader as a discovered ceiling."""
    ok = True

    # 1. Known-good: a cell whose numbers are already published.
    v = verdict("m256_poll")
    print("  known-good  ", _fmt(v))
    if v["mark"] not in ("OK",):
        print(f"  FAIL: m256_poll should be OK, got {v['mark']}"); ok = False
    if not (0.90 <= (v.get("ratio") or 0) <= 1.15):
        print(f"  FAIL: m256_poll ratio {v.get('ratio')} outside sane band"); ok = False
    if v.get("lost_pct") is None or abs(v["lost_pct"] - 0.5126) > 0.01:
        print(f"  FAIL: m256_poll lost_percent {v.get('lost_pct')} != 0.5126"); ok = False

    # 2. Known-bad: a cell that does not exist must say NO-DATA, never a number.
    v = verdict("r999_poll_does_not_exist")
    print("  known-bad   ", _fmt(v))
    if v["mark"] != "NO-DATA":
        print(f"  FAIL: absent cell should be NO-DATA, got {v['mark']}"); ok = False

    # 3. Known-bad: the loss channel must distinguish "absent" from "zero".
    if lost_percent("r999_poll_does_not_exist") is not None:
        print("  FAIL: absent client.json must return None, not 0.0"); ok = False
    else:
        print("  known-bad    absent client.json -> None (not 0.0)  OK")

    print("SELFTEST", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    for cell in sys.argv[1:]:
        print(_fmt(verdict(cell)))
