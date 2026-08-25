#!/usr/bin/env python3
"""Ticket A: put a NAME on the thread that burns ~45 points of a core.

[Co-developed with claude code -- Adam]

Why this could not be done from the 08-20 data. That round archived no kernel.log, so its cpu
trace's tids are anonymous, and tid-minus-pid offsets are not stable across builds (+13 in that
trace, +11 in today's). The handoff proposed closing the gap with the offset anyway -- i.e. with
the method that had already failed. Instead ladder_ext.sh keeps a kernel.log NEXT TO each cell's
cpu trace, from the same boot, so the mapping is read rather than inferred.

The amplification test is what separates the roles: a thread whose cost tracks sample count is
ingest, a thread whose cost is flat across a 32x change in sampling rate is doing work that has
nothing to do with samples.
"""
import glob
import gzip
import json
import os
import re
import statistics as st
import sys

RAW = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "2026-08-20_sampling-rate-and-cpu", "raw")
CELLS = ["r032_poll", "r016_poll", "r008_poll", "r004_poll", "r002_poll", "r001_poll"]
LINE = re.compile(r"\[(\w+)\] pid=(\d+) tid=(\d+)")


def _open(p):
    return gzip.open(p, "rt") if p.endswith(".gz") else open(p, errors="replace")


def names_for(cell):
    """tid -> thread name, from the log written by THIS cell's kernel process."""
    p = os.path.join(RAW, f"{cell}_kernel.log")
    if not os.path.exists(p):
        return {}, None
    out, pid = {}, None
    with _open(p) as fh:
        for line in fh:
            m = LINE.search(line)
            if m:
                out[int(m.group(3))] = m.group(1)
                pid = int(m.group(2))
    return out, pid


def cpu_for(cell):
    """tid -> percent of ONE core, averaged over the cell.

    cpu_probe.py:190 stores `utime + stime` -- the CUMULATIVE tick counters straight out of
    /proc, not a per-interval delta. A trace's values climb monotonically (0 -> 1193 over 300 s),
    so averaging them yields a number that rises with trace LENGTH and is not a rate at all. The
    first version of this file did exactly that and produced "7002 points", which is not a unit.
    The rate is (last - first) / elapsed / clk_tck * 100.
    """
    for ext in (".gz", ""):
        p = os.path.join(RAW, f"{cell}_cpu.jsonl{ext}")
        if os.path.exists(p):
            break
    else:
        return {}
    hz_hdr, first, last, t0, t1 = None, {}, {}, None, None
    with _open(p) as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if "clk_tck" in r:
                hz_hdr = r["clk_tck"]
                continue
            if "t" not in r:
                continue
            if t0 is None:
                t0 = r["t"]
            t1 = r["t"]
            for k, v in (r.get("thread") or {}).items():
                if ":" not in k:
                    continue
                tid = int(k.rsplit(":", 1)[1])
                first.setdefault(tid, v)
                last[tid] = v
    tck = hz_hdr or 100
    dt = (t1 - t0) if (t0 is not None and t1 is not None and t1 > t0) else None
    if not dt:
        return {}
    return {t: (last[t] - first[t]) / tck / dt * 100.0 for t in last}


rows = {}
for cell in CELLS:
    names, pid = names_for(cell)
    cpu = cpu_for(cell)
    if not names:
        print(f"{cell:12} NO kernel.log -- cannot name threads in this cell")
        continue
    if not cpu:
        print(f"{cell:12} NO cpu trace")
        continue
    named = {names[t]: c for t, c in cpu.items() if t in names}
    # Everything the log never named: worker pool, grpc, spdlog, main.
    unnamed = sorted((c for t, c in cpu.items() if t not in names), reverse=True)
    rows[cell] = (named, unnamed, pid, names)
    tot = sum(cpu.values())
    print(f"\n{cell}  pid={pid}  threads={len(cpu)}  total={tot:.1f} pts")
    for n, c in sorted(named.items(), key=lambda kv: -kv[1]):
        print(f"    {n:38} {c:7.2f}%")
    print(f"    {'(unnamed, top 5)':38} {', '.join(f'{x:.2f}' for x in unnamed[:5])}")

if len(rows) >= 2:
    lo, hi = CELLS[0], [c for c in CELLS if c in rows][-1]
    print(f"\n=== AMPLIFICATION  {lo} -> {hi} (sampling rate x32) ===")
    a, b = rows[lo][0], rows[hi][0]
    for n in sorted(set(a) | set(b)):
        x, y = a.get(n), b.get(n)
        if x is None or y is None:
            continue
        f = (y / x) if x > 0.005 else float("inf")
        print(f"    {n:38} {x:7.2f} -> {y:7.2f}   x{f:.2f}")
    ua, ub = rows[lo][1], rows[hi][1]
    print(f"    {'(unnamed total)':38} {sum(ua):7.2f} -> {sum(ub):7.2f}")
