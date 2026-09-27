#!/usr/bin/env python3
"""
The external arms' OWN evidence out of two live-p1/06 runs, side by side.

[Co-developed with claude code -- Adam]

09-27: `ndt up p4 --app` now starts the veth heartbeat on an external control plane too, detect
only. Adam's standing condition (09-25) is that the heartbeat must not change what a user's own
forwarding does, and the comparison that decides it is a live 06 with the heartbeat against one
without it (`live-p1/runs/2026-09-27T074635Z_06_thirteen`). The twin's own view is expected to
differ -- that is the feature. What must NOT differ is what the exercise's own controller saw and
did, and that is in its log, in each round's directory:

  p4runtime (skeleton and solution)  every rule it installed, and the LAST "Reading tunnel
                                     counters" block -- the packets and bytes each tunnel
                                     counter ended at;
  flowcache (solution)               how many packet-ins it received, every cache entry it added,
                                     and any packet-in whose frame carries the heartbeat's
                                     ethertype 0x88B5 (the frame reaching the exercise's own
                                     controller -- 0 is the only acceptable count);
  all three                          the arm's rc and verdict, and every gRPC error it logged.

Printed beside them and never compared: how many counter reads the controller made (a function of
how long the arm ran) and each run's venv fingerprint (00_venv.txt, when the run recorded one).

Usage:  external_evidence.py show <06 run dir>
        external_evidence.py compare <baseline 06 run dir> <new 06 run dir>
Exit:   0 nothing compared differs; 1 something does (each difference is printed); 2 an arm, its
        round directory or its controller log could not be read.
"""

from __future__ import annotations

import ast
import glob
import os
import re
import sys

#: (exercise, arm) -- the three 06 arms whose fabric has an external control plane.
EXTERNAL_ARMS = (("p4runtime", "skeleton"), ("p4runtime", "solution"), ("flowcache", "solution"))
HEARTBEAT_ETHERTYPE = 0x88B5
#: The evidence that decides; everything else printed is context.
COMPARED = ("rc", "verdict", "rules_installed", "counters_final", "packet_ins", "cache_entries",
            "heartbeat_packet_ins", "grpc_errors")

INSTALLED = re.compile(r"^Installed .* on s\d+\s*$")
COUNTER = re.compile(r"^(s\d+ \S+ \d+): (\d+ packets \(\d+ bytes\))\s*$")
CACHE_ENTRY = re.compile(r"^For switch s\d+ flow .* added table entry .*$")


class Unreadable(Exception):
    """An arm whose evidence cannot be read: exit 2, never a comparison."""


def table_rows(run):
    path = os.path.join(run, "00_table.tsv")
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as exc:
        raise Unreadable(f"{path}: {exc.strerror}") from exc
    rows = {}
    for line in lines[1:]:
        f = line.split("\t")
        if len(f) >= 5:
            rows[(f[0], f[1])] = {"rc": f[2], "verdict": f[3], "report": f[4]}
    return rows


def controller_log(report):
    """The round's own controller log: the round directory is the report's path without .md."""
    round_dir = report[:-3] if report.endswith(".md") else report
    logs = sorted(glob.glob(os.path.join(round_dir, "driver-controller-*.log")))
    if len(logs) != 1:
        raise Unreadable(f"{round_dir}: {len(logs)} controller logs, want exactly 1")
    return logs[0]


def ethertype_of(line):
    """The ethertype of a decodePacketInMetadata line's payload, or None when it cannot be read."""
    try:
        payload = ast.literal_eval(line.split("ret=", 1)[1].strip())["payload"]
    except (IndexError, KeyError, TypeError, ValueError, SyntaxError):
        return None
    return int.from_bytes(payload[12:14], "big") if len(payload) >= 14 else None


def evidence(log_path):
    lines = open(log_path, encoding="utf-8", errors="replace").read().splitlines()
    blocks, current = [], None
    for line in lines:
        if line.startswith("----- Reading tunnel counters"):
            current = {}
            blocks.append(current)
            continue
        m = COUNTER.match(line)
        if m and current is not None:
            current[m.group(1)] = m.group(2)
        elif not line.strip():
            current = None
    ethertypes = [ethertype_of(line) for line in lines if line.startswith("decodePacketInMetadata:")]
    return {
        "rules_installed": sorted(line.strip() for line in lines if INSTALLED.match(line)),
        "counters_final": blocks[-1] if blocks else {},
        "counter_reads": len(blocks),
        "packet_ins": sum(1 for line in lines if line.startswith("Received PacketIn")),
        "cache_entries": sorted(line.strip() for line in lines if CACHE_ENTRY.match(line)),
        "heartbeat_packet_ins": sum(1 for e in ethertypes if e == HEARTBEAT_ETHERTYPE),
        "grpc_errors": sum(1 for line in lines if line.startswith("gRPC error occurred")),
        "log": log_path,
    }


def arms(run):
    rows = table_rows(run)
    out = {}
    for arm in EXTERNAL_ARMS:
        row = rows.get(arm)
        if row is None:
            raise Unreadable(f"{run}: no {arm[0]}/{arm[1]} row in 00_table.tsv")
        out[arm] = dict(row, **evidence(controller_log(row["report"])))
    return out


def fingerprint(run):
    """One line per interpreter from 00_venv.txt: the protobuf line and the distributions' sha."""
    path = os.path.join(run, "00_venv.txt")
    if not os.path.exists(path):
        return ["not recorded (no 00_venv.txt)"]
    out, who = [], None
    for line in open(path, encoding="utf-8").read().splitlines():
        if line.startswith("== interpreter "):
            who = line[len("== interpreter "):]
        elif line.startswith(("protobuf ", "distributions ", "NOT RECORDED")):
            out.append(f"{who}: {line}")
    return out


def fmt(value):
    if isinstance(value, dict):
        return "; ".join(f"{k} = {v}" for k, v in sorted(value.items())) or "(none)"
    if isinstance(value, list):
        return f"{len(value)}: " + " | ".join(value) if value else "0"
    return str(value)


def show(run):
    print(f"run {run}")
    for line in fingerprint(run):
        print(f"  venv  {line}")
    for (ex, which), ev in arms(run).items():
        print(f"\n== {ex}/{which}  (log {ev['log']})")
        for key in COMPARED + ("counter_reads",):
            print(f"   {key:<21} {fmt(ev[key])}")
    return 0


def compare(base, new):
    a, b = arms(base), arms(new)
    print(f"baseline {base}")
    for line in fingerprint(base):
        print(f"  venv  {line}")
    print(f"new      {new}")
    for line in fingerprint(new):
        print(f"  venv  {line}")
    diffs = 0
    for arm in EXTERNAL_ARMS:
        print(f"\n== {arm[0]}/{arm[1]}")
        for key in COMPARED:
            same = a[arm][key] == b[arm][key]
            diffs += not same
            print(f"   {'same' if same else 'DIFF':<4}  {key:<21} {fmt(b[arm][key])}"
                  + ("" if same else f"\n         {'':<21} baseline: {fmt(a[arm][key])}"))
        print(f"   ----  {'counter_reads':<21} {b[arm]['counter_reads']} (baseline "
              f"{a[arm]['counter_reads']}; not compared: it is how long the arm ran)")
        if b[arm]["heartbeat_packet_ins"]:
            print(f"   !! {b[arm]['heartbeat_packet_ins']} packet-in(s) carried the heartbeat's "
                  f"ethertype 0x88B5: the frame reached the exercise's own controller")
    print(f"\n{'NO DIFFERENCE' if not diffs else f'{diffs} DIFFERENCE(S)'} in the external arms' "
          f"own evidence")
    return 0 if not diffs else 1


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "show":
            return show(argv[1])
        if len(argv) == 3 and argv[0] == "compare":
            return compare(argv[1], argv[2])
    except Unreadable as exc:
        print(f"UNREADABLE {exc}")
        return 2
    print(__doc__.split("Usage:")[1].split("Exit:")[0].rstrip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
