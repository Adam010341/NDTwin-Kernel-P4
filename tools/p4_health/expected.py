"""The pre-registered predictions: read from the committed TSV, never derived from a run.

[Co-developed with claude code -- Adam]

design 5.1: expected_today.tsv is committed before the first live run, and every fix that flips
a cell changes it in the same PR. So the prediction a row is compared with comes from the file
and only from the file -- a prediction computed from this run's verdict would make every delta
"same" (mutation M12).
"""
from __future__ import annotations

import csv

COLUMNS = ("cell", "dimension", "scope", "bringup", "cut", "expected", "basis", "added")


class ExpectedError(ValueError):
    pass


def load(path):
    """{cell id: row dict}. Refuses a file whose header is not COLUMNS, or a cell twice."""
    with open(path, encoding="utf-8", newline="") as fh:
        rows = [r for r in csv.reader(fh, delimiter="\t") if r and not r[0].startswith("#")]
    if not rows or tuple(rows[0]) != COLUMNS:
        raise ExpectedError("%s: header is %r, expected %r" % (path, rows[0] if rows else None, COLUMNS))
    out = {}
    for r in rows[1:]:
        if len(r) != len(COLUMNS):
            raise ExpectedError("%s: row %r has %d fields" % (path, r[:1], len(r)))
        row = dict(zip(COLUMNS, r))
        if row["cell"] in out:
            raise ExpectedError("%s: %s appears twice" % (path, row["cell"]))
        out[row["cell"]] = row
    return out


NOT_OBSERVED = "not observed"


def delta(expected_label, observed_label, phase=None):
    """same | flipped | unpredicted | not observed. A cell this run never observed (verdict
    phase "unobserved": a later Cut's cell, or one --only left out) is no evidence about its
    prediction either way (Cut 2 review m1)."""
    if phase == "unobserved":
        return NOT_OBSERVED
    if expected_label is None:
        return "unpredicted"
    return "same" if expected_label == observed_label else "flipped"


def annotate(ctx, expected):
    """{cell: (expected label or None, delta)} for every judged cell."""
    out = {}
    for cid, verdict in ctx.cells.items():
        exp = (expected.get(cid) or {}).get("expected")
        out[cid] = (exp, delta(exp, verdict.label, verdict.phase))
    return out
