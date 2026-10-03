#!/usr/bin/env python3
"""The P4 health check's entry point.

[Co-developed with claude code -- Adam]

    probe.py s0 --run-dir <dir> [--py-p4 PY]      S0, no lab (Cut 1)
    probe.py judge --observations OBS.json --run-dir DIR           verdicts from recorded readings
    probe.py lab ...                                               refused: Cut 2 builds it

Exit: 0 COMPLETE, 1 PROBE-BROKEN (not publishable), 2 INCOMPLETE / refused.
Refuses to run as root (design 7.3). Wrap in run.sh (setsid, nice) for anything long.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    __package__ = "p4_health"

from p4_health import expected as E  # noqa: E402
from p4_health import report as R  # noqa: E402
from p4_health.cells import table as T  # noqa: E402
from p4_health.cells import verdict as V  # noqa: E402
from p4_health.collect.config import REPO  # noqa: E402
from p4_health.collect.runner import Runner  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def _git(*args):
    try:
        return subprocess.run(["git", "-C", REPO] + list(args), stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, universal_newlines=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def probe_version():
    """The git tree sha of tools/p4_health at HEAD, plus whether the working copy differs."""
    tree = _git("rev-parse", "HEAD:tools/p4_health") or "unknown"
    dirty = _git("status", "--porcelain", "--", "tools/p4_health")
    return tree + ("+uncommitted" if dirty else "")


def repo_identity():
    """HEAD (a commit sha), the probe's tree, and whether either is dirty (review MINOR 14)."""
    return {"head": _git("rev-parse", "HEAD") or "unknown", "probe_tree": probe_version(),
            "dirty_paths": len([l for l in _git("status", "--porcelain").splitlines() if l.strip()])}


def cmd_s0(args):
    from p4_health.s0 import S0
    py = args.py_p4 or os.environ.get("P4_PROXY_PY") or os.path.join(REPO, "p4_proxy", "venv", "bin", "python")
    s0 = S0(args.run_dir, Runner(), py)
    ident = repo_identity()
    print("S0 -> %s  (HEAD %s, probe tree %s)" % (os.path.abspath(args.run_dir), ident["head"],
                                                  ident["probe_tree"]))
    s0.out["repo"] = ident
    rc = s0.run()
    print("S0 %s" % s0.out["verdict"])
    return rc


def cmd_judge(args):
    with open(args.observations, encoding="utf-8") as fh:
        doc = json.load(fh)
    ctx = V.judge_all(T.TABLE, doc.get("cells") or {}, doc.get("self_checks") or {})
    expected = E.load(args.expected or os.path.join(
        REPO, "doc", "audit", "2026-10-03_p4-health-check", "expected_today.tsv"))
    ann = E.annotate(ctx, expected)
    rollups = {s: V.rollup(T.TABLE, ctx, s) for s in V.SCOPES}
    # A recording that does not say its bring-ups completed did not complete (review MINOR 19).
    verdict, rc = V.run_verdict(ctx, bringups_complete=doc.get("bringups_complete") is True)
    rows = R.table_rows(T.TABLE, ctx, ann)
    os.makedirs(args.run_dir, exist_ok=True)
    with open(os.path.join(args.run_dir, "00_table.tsv"), "w", encoding="utf-8") as fh:
        fh.write(R.tsv(rows))
    R.dump(os.path.join(args.run_dir, "health.json"),
           R.health(doc.get("run", "offline"), probe_version(), doc.get("lab_surface") or {},
                    doc.get("s0") or {}, doc.get("bringups") or [], T.TABLE, ctx, ann, rollups,
                    verdict))
    print(R.render(rows, rollups))
    print("verdict %s%s" % (verdict, "  -- NOT PUBLISHABLE" if verdict == "PROBE-BROKEN" else ""))
    return rc


def main(argv=None):
    if os.geteuid() == 0:
        print("refusing to run as root (design 7.3)", file=sys.stderr)
        return 2
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd")
    a = sub.add_parser("s0")
    a.add_argument("--run-dir", required=True)
    a.add_argument("--py-p4", default=None)
    j = sub.add_parser("judge")
    j.add_argument("--observations", required=True)
    j.add_argument("--run-dir", required=True)
    j.add_argument("--expected", default=None)
    sub.add_parser("lab")
    args = ap.parse_args(argv)
    if args.cmd == "s0":
        return cmd_s0(args)
    if args.cmd == "judge":
        return cmd_judge(args)
    if args.cmd == "lab":
        print("refused: the lab half of the health check is Cut 2 and is not built", file=sys.stderr)
        return 2
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
