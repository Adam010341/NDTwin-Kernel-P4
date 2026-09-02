#!/usr/bin/env python3
"""Prove the sampling condition holds -- BEFORE the cell is measured. Both directions.

Usage:  verify_cond.py {zero|sampled} [seconds]     exit 0 = condition holds, non-zero = refuse

[Co-developed with claude code -- Adam]

Derived from 2026-09-01_cpu-matrix-1hz/verify_zero.py, which checked only the zero side. That
round's lesson was that six cells were measured for 300 s each and checked afterwards, at which
point all six turned out to have sampled exactly as hard as every other cell -- checking
afterwards can only throw data away.

WHY THE SAMPLED SIDE NEEDS A CHECK TOO, and it is not symmetry for its own sake:
this round's whole claim is a DIFFERENCE between two conditions. A cell labelled "1/1024" that
silently sampled nothing -- p4c compiled but the fabric loaded a stale JSON, the mirror session
never got installed, the clone predicate edit did not get reverted -- would read as a small
number and be subtracted from the other arm as though it were real. That is the same failure as
the mislabelled zero, only it produces a *smaller* gap instead of a larger one, so it looks like
a conservative result rather than a broken one.

TWO ASSERTIONS PER MODE, AND THE SECOND ONE IS THE LOAD-BEARING ONE
  zero    : (1) every edge the twin reports reads zero   (2) bytes actually moved
  sampled : (1) at least one edge reads non-zero         (2) bytes actually moved

Without (2), the zero mode is satisfied by a fabric with no traffic, by a dead iperf3 and by a
kernel that stopped answering -- a control satisfied by absence, which is the same shape as the
thing it is here to catch. (2) is kept in the sampled mode as well so that both modes fail for
the same reason when the fabric is the problem, rather than one of them passing by luck.
"""
import json
import re
import subprocess
import sys
import time
import urllib.request

URL = "http://localhost:8000/ndt/get_graph_data"
IFACE = re.compile(r"^s\d+-eth\d+$")

if len(sys.argv) < 2 or sys.argv[1] not in ("zero", "sampled"):
    print("usage: verify_cond.py {zero|sampled} [seconds]")
    sys.exit(64)
MODE = sys.argv[1]
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0


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
worst, nonzero_edges, samples = 0.0, 0, 0
deadline = time.time() + DUR - 6
while time.time() < deadline:
    try:
        seen = twin()
        for k, v in seen.items():
            worst = max(worst, float(v))
        nonzero_edges = max(nonzero_edges, sum(1 for v in seen.values() if float(v) > 0))
        samples += 1
    except Exception as exc:
        print(f"VERIFY FAIL: twin unreadable: {exc}")
        traffic.kill()
        sys.exit(3)
    time.sleep(1.0)
nd1 = netdev()
traffic.wait(timeout=30)

moved = sum(nd1.get(k, 0) - v for k, v in nd0.items())
print(f"  mode: {MODE}   twin polls: {samples}   worst edge reading: {worst:,.0f} bps"
      f"   non-zero edges (max over polls): {nonzero_edges}")
print(f"  bytes moved on switch interfaces: {moved:,}")

if samples < 5:
    print("VERIFY FAIL: too few twin polls to conclude anything")
    sys.exit(4)
if moved <= 0:
    print("VERIFY FAIL: no traffic moved -- neither telemetry reading proves anything here")
    sys.exit(5)

if MODE == "zero":
    if worst > 0:
        print(f"VERIFY FAIL: telemetry is still flowing (worst edge {worst:,.0f} bps)")
        sys.exit(6)
    print("VERIFY OK: traffic moved and every edge read zero")
else:
    if worst <= 0:
        print("VERIFY FAIL: traffic moved but NO edge ever read non-zero -- this cell would be "
              "a zero-sampling cell wearing a sampled label")
        sys.exit(7)
    print(f"VERIFY OK: traffic moved and telemetry is flowing "
          f"({nonzero_edges} edges non-zero, worst {worst:,.0f} bps)")
sys.exit(0)
