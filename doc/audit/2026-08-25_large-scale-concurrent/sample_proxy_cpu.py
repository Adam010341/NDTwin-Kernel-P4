#!/usr/bin/env python3
"""Sample the proxy's CPU as raw jiffies, for amendment L's lambda-attribution question.

WHY NOT ps. sample_load.py records `ps -o pcpu`, which is the process's average over its whole
lifetime -- useless for comparing one six-minute arm against another on a proxy that has been up
for an hour. This reads /proc/<pid>/stat directly and stores the cumulative counters, so the
analysis differentiates them over whatever window it likes.

WHY IT IS A FILE. The first version of this was `python3 -c '...'` with the pgrep pattern inline,
so the whole program sat in its own argv -- and `pgrep -af proxy_agent` matched the sampler
itself, plus the pgrep it spawned. Two phantom "proxy" processes appeared in the output at the
instant sampling began. A script file's argv is just the path, so the pattern cannot match the
matcher. This project has a note about that trap; the note did not prevent it, the self-check did.

Identification is by cmdline containing proxy_agent/main.py, and self is excluded explicitly
rather than relying on pgrep's own self-exclusion, which did not save the spawned child.

Usage: sample_proxy_cpu.py <out.jsonl> <interval_s>
[Co-developed with claude code -- Adam]
"""
import json
import os
import sys
import time

NEEDLE = "proxy_agent/main.py"


def proxy_pids():
    me = os.getpid()
    found = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == me:
            continue
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode(
                "utf-8", "replace")
        except Exception:
            continue
        if NEEDLE in cmd:
            found.append((entry, cmd[:200]))
    return found


def main():
    out_path, interval = sys.argv[1], float(sys.argv[2])
    f = open(out_path, "a", buffering=1)          # append: a restart must not truncate history
    while True:
        t0 = time.time()
        rec = {"t": t0, "procs": {}}
        for pid, cmd in proxy_pids():
            try:
                raw = open(f"/proc/{pid}/stat").read()
                fields = raw[raw.rindex(")") + 2:].split()
                rec["procs"][pid] = {"utime": int(fields[11]), "stime": int(fields[12]),
                                     "threads": int(fields[17]), "cmd": cmd}
            except Exception:
                pass
        rec["clk_tck"] = os.sysconf("SC_CLK_TCK")
        f.write(json.dumps(rec) + "\n")
        # Sleep the REMAINDER, not a flat interval. The flat version drifted to 7.6 s under load
        # because the work happens before the sleep -- which is the same shape as the rate loop
        # this whole round exists to measure. Timestamps make it recoverable either way, but a
        # sampler that drifts under exactly the condition being studied is a bad instrument.
        time.sleep(max(0.0, interval - (time.time() - t0)))


if __name__ == "__main__":
    main()
