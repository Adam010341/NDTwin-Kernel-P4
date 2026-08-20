#!/usr/bin/env python3
"""
Interface-counter logger with no twin polling at all.

[Co-developed with claude code -- Adam]

The poll-off arm of the CPU matrix. run.py reads /proc/net/dev *and* polls
/ndt/get_graph_data at 4 Hz -- and on a 128-host graph that HTTP work lands inside the very
kernel process whose CPU is being measured, so the "cost of ingesting sFlow" it produces is
really "cost of ingesting sFlow plus serving my own measurement". This drops the HTTP half and
keeps the ground truth, which needs nothing from the kernel.

Same output shape as run.py minus the "twin" key, so the same analysis code reads both.

Usage:  netdev_only.py <seconds> [hz] [out.jsonl]
"""
import json
import re
import sys
import time

IFACE = re.compile(r"^s\d+-eth\d+$")


def netdev():
    d = {}
    for line in open("/proc/net/dev"):
        if ":" not in line:
            continue
        name, rest = line.split(":", 1)
        name = name.strip()
        if not IFACE.match(name):
            continue
        d[name] = int(rest.split()[8])          # tx_bytes
    return d


def main():
    dur = float(sys.argv[1])
    hz = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
    out = sys.argv[3] if len(sys.argv) > 3 else "netdev.jsonl"
    period = 1.0 / hz
    end = time.time() + dur
    n = 0
    with open(out, "w") as fh:
        while time.time() < end:
            t = time.time()
            try:
                fh.write(json.dumps({"t": round(t, 3), "tx": netdev()}) + "\n")
                fh.flush()
                n += 1
            except Exception as exc:            # visible, not silently interpolated over
                fh.write(json.dumps({"t": round(t, 3), "error": str(exc)}) + "\n")
                fh.flush()
            slp = period - (time.time() - t)
            if slp > 0:
                time.sleep(slp)
    print(f"done: {n} samples -> {out}")


if __name__ == "__main__":
    main()
