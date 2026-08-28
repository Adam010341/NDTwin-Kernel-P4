#!/usr/bin/env python3
"""Host memory and swap pressure, logged beside the block -- EXPLANATORY, never a detector.

WHY IT IS NOT A DETECTOR. It was started mid-block, so it covers arms 3-6 and not 1-2. A signal
that exists for four arms and not the other two cannot be used to decide anything about the
comparison between them -- that is the same mistake as an error term built from the wrong
population. The step DETECTOR (PREREG amendment A) uses only loadavg and /proc/stat, which
sample_load.py has recorded identically on all six arms since before the block started.

WHAT IT IS FOR. Once the uniform detector says a step happened, this says WHY -- a neighbour VM
starting a p4c/bmv2 compile shows up here as swap-in and falling MemAvailable long before it
shows in a one-minute load average. Naming the mechanism is worth more than detecting it twice.

Reads two procfs files every 10 s. The 10 Hz API poller already running in every arm is three
orders of magnitude more work than this, which is why it is safe to add mid-block at all.

Usage: log_host_memory.py <out.jsonl> [interval_s]
[Co-developed with claude code -- Adam]
"""
import json, sys, time

def scrape(path, keys):
    out = {}
    try:
        for line in open(path):
            p = line.split()
            if p and p[0].rstrip(":") in keys:
                out[p[0].rstrip(":")] = int(p[1])
    except Exception:
        pass
    return out

def main():
    out, iv = sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
    f = open(out, "a", buffering=1)
    while True:
        rec = {"t": time.time()}
        rec.update(scrape("/proc/meminfo",
                          {"MemTotal", "MemAvailable", "SwapTotal", "SwapFree", "Dirty"}))
        rec.update(scrape("/proc/vmstat", {"pswpin", "pswpout", "pgmajfault"}))
        f.write(json.dumps(rec) + "\n")
        time.sleep(iv)

if __name__ == "__main__":
    main()
