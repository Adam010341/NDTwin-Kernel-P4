"""The sender's and the sniffer's stdout: what was SENT, and what arrived.

[Co-developed with claude code -- Adam]

design 2.1 step 3: the stimulus count is what the sender REPORTS it sent, never what it was
asked to send (mutation M3). The sender prints one line per run,

    SENT cell=<id> n=<frames actually sent> ident=<ip id used> requested=<n asked for>

and the sniffer one JSON object per marker it accepted (magic and cell id both right):

    RX {"cell": "K1", "seq": 3, "ttl": 63, "ident": 32768, "diffserv": 12, ...}

Anything else on stdout is ignored; a sender that printed no SENT line sent nothing we can count.
"""
from __future__ import annotations

import json
import re

_SENT = re.compile(r"^SENT cell=(\S+) n=(\d+)(?: ident=(\d+))?(?: requested=(\d+))?\s*$")


def sent(stdout, cell):
    """Frames the sender says it sent for `cell`; None when it said nothing about the cell."""
    total = None
    for line in (stdout or "").splitlines():
        m = _SENT.match(line.strip())
        if m and m.group(1) == cell:
            total = (total or 0) + int(m.group(2))
    return total


def sent_idents(stdout, cell):
    """The IP identification values the sender says it used for `cell` (SC-qstamp, 12-3)."""
    out = set()
    for line in (stdout or "").splitlines():
        m = _SENT.match(line.strip())
        if m and m.group(1) == cell and m.group(3) is not None:
            out.add(int(m.group(3)))
    return out


def received(stdout, cell, run_id=None):
    """The RX records for `cell` (and this run, when given)."""
    out = []
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("RX "):
            continue
        try:
            rec = json.loads(line[3:])
        except ValueError:
            continue
        if rec.get("cell") != cell:
            continue
        if run_id is not None and rec.get("run") != run_id:
            continue
        out.append(rec)
    return out
