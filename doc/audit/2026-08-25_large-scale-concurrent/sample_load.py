#!/usr/bin/env python3
"""Sample machine load for one arm of PREREG amendment L.

WHY THIS EXISTS. Amendment D's arm U carries a permanent caveat -- an unattributed co-variate --
because load was recorded as present/absent rather than measured. The auditor named that as the
thing to fix, so both arms here get their own readings and the QUIET arm is evidence, not an
assumption: there is an actor that writes this repo's root whose owner four layers of attribution
failed to name, and "nothing was running" is exactly the claim it would falsify.

WHAT IT RECORDS. Raw counters, not percentages. /proc/stat and /proc/<pid>/stat are cumulative,
so storing the raw values lets the arithmetic be redone later under a different definition
without re-running the fabric -- and it sidesteps the trap of averaging a cumulative counter,
which this project has already printed as a plausible-looking number once.

Usage: sample_load.py <out.jsonl> <interval_s>
[Co-developed with claude code -- Adam]
"""
import json
import os
import subprocess
import sys
import time


def kernel_pid():
    # -x: match the process NAME exactly. `pgrep -f ndtwin_kernel` would match this script's own
    # command line, and a plain `pgrep ndtwin_kernel` truncates at comm's 15-char limit.
    r = subprocess.run(["pgrep", "-x", "ndtwin_kernel"], capture_output=True, text=True)
    pids = [p for p in r.stdout.split() if p]
    return pids, (pids[0] if len(pids) == 1 else None)


def main():
    out_path, interval = sys.argv[1], float(sys.argv[2])
    f = open(out_path, "w", buffering=1)
    while True:
        rec = {"t": time.time()}
        try:
            rec["loadavg"] = open("/proc/loadavg").read().split()[:3]
        except Exception:
            rec["loadavg"] = None
        try:
            # cpu + per-core lines, raw jiffies
            rec["stat"] = [l.split() for l in open("/proc/stat")
                           if l.startswith("cpu")]
        except Exception:
            rec["stat"] = None

        pids, kpid = kernel_pid()
        rec["kernel_pids"] = pids
        # More than one kernel means the pid below may not be this fabric's. Record the ambiguity
        # rather than silently taking the lowest pid, which is how a previous round measured the
        # wrong process while every number looked reasonable.
        rec["kernel_ambiguous"] = len(pids) != 1
        if kpid:
            try:
                # utime, stime are fields 14,15 (1-indexed) -- but comm can contain spaces, so
                # split after the closing paren rather than on whitespace from the start.
                raw = open(f"/proc/{kpid}/stat").read()
                fields = raw[raw.rindex(")") + 2:].split()
                rec["kernel_utime"] = int(fields[11])
                rec["kernel_stime"] = int(fields[12])
                rec["kernel_threads"] = int(fields[17])
            except Exception:
                pass
        try:
            top = subprocess.run(
                ["ps", "-eo", "pid,pcpu,rss,args", "--sort=-pcpu"],
                capture_output=True, text=True).stdout.splitlines()[1:11]
            rec["top"] = [t[:220] for t in top]
        except Exception:
            rec["top"] = None
        rec["clk_tck"] = os.sysconf("SC_CLK_TCK")
        rec["ncpu"] = os.cpu_count()
        f.write(json.dumps(rec) + "\n")
        time.sleep(interval)


if __name__ == "__main__":
    main()
