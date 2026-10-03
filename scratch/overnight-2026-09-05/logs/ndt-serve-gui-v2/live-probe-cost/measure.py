#!/usr/bin/env python3
"""Process cost of a command, untraced: the delta of /proc/stat's `processes` (forks since boot,
system-wide) around one run, against an idle window of the same length taken right after it.
Alternates run / idle, REPS times. [Co-developed with claude code -- Adam]
usage: measure.py <label> <reps> <shell command>     (env passes through)"""
import json, statistics, subprocess, sys, time

def forks():
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("processes "):
                return int(line.split()[1])

label, reps, cmd = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = []
for i in range(reps):
    a = forks(); t = time.monotonic()
    rc = subprocess.run(["bash", "-c", cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    wall = time.monotonic() - t; b = forks()
    c = forks(); time.sleep(wall); d = forks()
    rows.append({"rep": i, "rc": rc, "wall_s": round(wall, 3), "run_forks": b - a, "idle_forks": d - c,
                 "net": (b - a) - (d - c)})
    print(json.dumps(rows[-1]), flush=True)
    time.sleep(1)
net = [r["net"] for r in rows]; wall = [r["wall_s"] for r in rows]
print(json.dumps({"label": label, "cmd": cmd, "reps": reps, "net_median": statistics.median(net),
                  "net_min": min(net), "net_max": max(net), "wall_median_s": statistics.median(wall),
                  "rcs": sorted(set(r["rc"] for r in rows))}))
