#!/usr/bin/env python3
"""
The 34 earlier no-heartbeat rounds that external_evidence.py's DECISIVE / DESCRIPTIVE split rests on,
frozen: which files they are (external_survey_34.tsv: path and sha256 of each round report and its
controller log), that none of them had the heartbeat, and how many distinct values each compared
field took over them.

[Co-developed with claude code -- Adam]

Round 6 (the round-5 re-review's S-9 and the orchestrator's ruling on it): the split is pre-registered
on these rounds, so the rounds themselves are pinned -- a file that is gone or whose bytes changed
refuses the survey, and so does a round with any trace of the heartbeat (the detect-only start
line, a heartbeat block on switch_state, a running row): such a round would not be a control.
They live in the main checkout's runs/ (untracked raw); the manifest is tracked.

Usage:  external_survey.py <prep dir holding runs/> [<manifest>]
        (the prep dir: doc/audit/2026-09-04_p4-tutorial-exercise-prep of the checkout with the raw)
Exit:   0 every file matched and none had the heartbeat (the table printed); 3 refused (each
        reason printed); 2 usage or an unreadable manifest.
"""

from __future__ import annotations

import collections
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import external_evidence as ev  # noqa: E402

MANIFEST = os.path.join(HERE, "external_survey_34.tsv")
COLUMNS = ["arm", "report", "report_sha256", "log", "log_sha256"]
ARMS = {"p4runtime/skeleton": ("p4runtime", "skeleton"), "p4runtime/solution": ("p4runtime", "solution"),
        "flowcache/solution": ("flowcache", "solution")}
VERDICT = re.compile(r"^>>> (.*)$", re.M)
FIELDS = ("verdict", "p4c_sha", "json_shas", "rules_installed", "counters_final", "packet_ins", "cache_entries",
          "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_manifest(path):
    with open(path, encoding="utf-8") as fh:
        lines = [x.rstrip("\n") for x in fh if x.strip() and not x.startswith("#")]
    if not lines or lines[0].split("\t") != COLUMNS:
        raise ValueError(f"{path}: header {lines[:1]}, want {COLUMNS}")
    rows = [dict(zip(COLUMNS, x.split("\t"))) for x in lines[1:]]
    if any(len(r) != len(COLUMNS) or r["arm"] not in ARMS for r in rows):
        raise ValueError(f"{path}: a row that is not {COLUMNS} with a known arm")
    return rows


def value(v):
    """One hashable, printable form of a field's value."""
    if isinstance(v, dict):
        return repr(sorted(v.items()))
    if isinstance(v, list):
        return f"{len(v)} sha256 {hashlib.sha256(repr(v).encode()).hexdigest()[:12]}"
    return repr(v)


def survey(prep, manifest):
    rows = read_manifest(manifest)
    refused, per_arm = [], collections.defaultdict(list)
    for r in rows:
        for kind in ("report", "log"):
            p = os.path.join(prep, r[kind])
            try:
                got = sha256(p)
            except OSError as exc:
                refused.append(f"{r[kind]}: {type(exc).__name__}")
                continue
            if got != r[kind + "_sha256"]:
                refused.append(f"{r[kind]}: sha256 {got[:16]}, the manifest froze {r[kind + '_sha256'][:16]}")
        if refused:
            continue
        rep = ev.report_evidence(os.path.join(prep, r["report"]))
        trace = [w for w, hit in (("the detect-only start line", rep["hb_started"]),
                                  ("a heartbeat block", rep["hb_block"]),
                                  ("a running row", bool(rep["hb_running"]))) if hit]
        if trace:
            refused.append(f"{r['report']}: {', '.join(trace)} -- not a round without the heartbeat")
            continue
        c = ev.controller_evidence(os.path.join(prep, r["log"]))
        both = dict(c, **rep)
        m = VERDICT.search(ev.read_text(os.path.join(prep, r["report"])))
        both["verdict"] = m.group(1)[:40] if m else "?"
        both["invariants"] = {k: ok for k, (ok, _d) in ev.invariants(ARMS[r["arm"]], both).items()}
        per_arm[r["arm"]].append(both)
    if refused:
        for x in refused:
            print(f"REFUSED {x}")
        return 3
    print(f"{len(rows)} rounds, every report and controller log as frozen, none with the heartbeat")
    for arm, evs in per_arm.items():
        print(f"== {arm}: {len(evs)} rounds")
        for k in FIELDS + ("invariants",):
            cnt = collections.Counter(value(e[k]) for e in evs)
            print(f"   {k:22} {len(cnt)} distinct: " + "; ".join(f"{x[:60]} x{m}" for x, m in cnt.most_common(4)))
    return 0


def main(argv):
    if len(argv) not in (1, 2):
        print(__doc__.split("Usage:")[1].split("Exit:")[0].rstrip(), file=sys.stderr)
        return 2
    try:
        return survey(argv[0], argv[1] if len(argv) == 2 else MANIFEST)
    except (OSError, ValueError) as exc:
        print(f"UNREADABLE {exc}")
        return 2
    except ev.Unreadable as exc:
        print(f"UNREADABLE {exc}")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
