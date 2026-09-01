#!/usr/bin/env python3
"""Prove the zero-sampling control holds -- BEFORE the cell is measured.

Usage:  verify_zero.py [seconds]        exit 0 = control holds, non-zero = do not measure

[Co-developed with claude code -- Adam]

This file exists because of what went wrong in the main round. Six cells were brought up with
NDTWIN_CLONE_DISABLE=1, measured for 300 s each, and only then checked -- at which point all
six turned out to have sampled exactly as hard as any other cell. Checking afterwards can only
throw data away. Checking first turns a wasted round into a refused one.

TWO ASSERTIONS, AND BOTH ARE LOAD-BEARING
  1. Every edge the twin reports must read zero.
  2. The interface counters must show bytes actually moving while that is true.

Without (2), "the twin reads zero" is satisfied by a fabric with no traffic on it, by a broken
iperf3, and by a kernel that stopped answering -- none of which is the condition under test.
The failure mode being guarded against is a control that is satisfied by absence, which is the
same shape as the thing it is here to catch.
"""
import json
import re
import subprocess
import sys
import time
import urllib.request

URL = "http://localhost:8000/ndt/get_graph_data"
IFACE = re.compile(r"^s\d+-eth\d+$")
DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0


def netdev():
    d = {}
    for line in open("/proc/net/dev"):
        if ":" not in line:
            continue
        name, rest = line.split(":", 1)
        name = name.strip()
        if IFACE.match(name):
            d[name] = int(rest.split()[8])
    return d


def twin():
    with urllib.request.urlopen(URL, timeout=5) as r:
        g = json.load(r)
    return {f"s{e['src_dpid']}-eth{e['src_interface']}": e["link_bandwidth_usage_bps"]
            for e in g["edges"]}


def host_pid(h):
    out = subprocess.run(["ps", "-eo", "pid,args"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if parts and parts[-1] == f"mininet:{h}":
            return parts[0]
    return None


h1, h33 = host_pid("h1"), host_pid("h33")
if not h1 or not h33:
    print(f"VERIFY FAIL: host pids not found (h1={h1} h33={h33})")
    sys.exit(2)

subprocess.run(["sudo", "-n", "mnexec", "-a", h33, "iperf3", "-s", "-1", "--daemon",
                "--logfile", "/dev/null"], capture_output=True)
time.sleep(1)
traffic = subprocess.Popen(
    ["sudo", "-n", "mnexec", "-a", h1, "iperf3", "-c", "10.0.0.33", "-u", "-b", "200M",
     "-t", str(int(DUR)), "-l", "1400"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

time.sleep(3)                                  # let the counters and the twin both move on
nd0 = netdev()
worst, samples = 0.0, 0
deadline = time.time() + DUR - 6
while time.time() < deadline:
    try:
        for k, v in twin().items():
            worst = max(worst, float(v))
        samples += 1
    except Exception as exc:
        print(f"VERIFY FAIL: twin unreadable: {exc}")
        traffic.kill()
        sys.exit(3)
    time.sleep(1.0)
nd1 = netdev()
traffic.wait(timeout=30)

moved = sum(nd1.get(k, 0) - v for k, v in nd0.items())
print(f"  twin polls: {samples}   worst edge reading: {worst:,.0f} bps")
print(f"  bytes moved on switch interfaces: {moved:,}")

if samples < 5:
    print("VERIFY FAIL: too few twin polls to conclude anything")
    sys.exit(4)
if moved <= 0:
    print("VERIFY FAIL: no traffic moved -- a zero telemetry reading proves nothing here")
    sys.exit(5)
if worst > 0:
    print(f"VERIFY FAIL: telemetry is still flowing (worst edge {worst:,.0f} bps)")
    sys.exit(6)

print("VERIFY OK: traffic moved and every edge read zero")
sys.exit(0)
