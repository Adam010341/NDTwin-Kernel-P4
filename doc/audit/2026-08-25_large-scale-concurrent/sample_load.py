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

🔴 EDITED AFTER THE ROUNDS THAT USED IT (2026-09-12, FIX-NDT-9 ③). Only kernel_pid() changed,
and only in HOW it identifies the kernel; every key written to load.jsonl means what it meant,
with one added (kernel_pid_source). The raw this instrument produced for the 08-25 and 08-28
arms is NOT re-derivable from this file as it now stands -- the command the archived numbers
came from is quoted verbatim in doc/audit/2026-08-28_QM-mirrored-block/REPORT.md:363, which is
where a reader checking those numbers should start.

Usage: sample_load.py <out.jsonl> <interval_s>
[Co-developed with claude code -- Adam]
"""
import json
import os
import subprocess
import sys
import time


# The same two lines run_arm_L.sh:14-15 computes, so the tree this reads is the tree the arm
# claimed: HERE is this round's directory, and the repo root is three levels above it.
HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
KERNEL_PIDFILE = os.path.join(REPO_ROOT, ".test_run", "pids", "kernel.pid")
KERNEL_COMM = "ndtwin_kernel"


def _comm(pid):
    """/proc/<pid>/comm, or '' -- the kernel's own name for the executable behind that pid."""
    try:
        with open("/proc/%s/comm" % pid) as fh:
            return fh.read().strip()
    except Exception:
        return ""


def _kernels_on_this_machine():
    """Every pid whose comm is exactly ndtwin_kernel, read straight out of /proc.

    No subprocess and no pattern: the search walks pids and compares one string, so the
    searcher's own command line can never be a match for the search. comm truncates at 15
    characters and "ndtwin_kernel" is 13, so an exact comparison is exact here -- the same
    reason `ndt` counts with `ps -eo comm=` and an `==` rather than by pattern (ndt:44-49).
    """
    out = []
    try:
        names = os.listdir("/proc")
    except Exception:
        return out
    for name in names:
        if name.isdigit() and _comm(name) == KERNEL_COMM:
            out.append(name)
    out.sort(key=int)
    return out


def kernel_pid():
    """(every ndtwin_kernel pid on this machine, the one to measure) -- or None to measure none.

    🔴 CHANGED 2026-09-12 (FIX-NDT-9 ③, on AUDIT-SCAN-1 §7-2). This used to find the kernel by
    calling the process-name tool this project bans the `-f` form of; the exact command it ran,
    and the review note that says why the narrow form was correct, are quoted verbatim in
    doc/audit/2026-08-28_QM-mirrored-block/REPORT.md:363 -- so what produced the recorded
    load.jsonl of the 08-25 and 08-28 arms is on the record and is not this function.
    Nothing about what is RECORDED changes: the same two keys, the same ambiguity flag.
    The identity test is now the one `ndt` uses -- a pidfile this stack wrote, confirmed
    against /proc -- and the file's own driver proves that channel exists here:
    run_arm_L.sh refuses to start unless .test_run/lab.claim names this owner (run_arm_L.sh:26),
    so this script has only ever run inside a checkout whose lab `ndt` had brought up.

    The pidfile is the AUTHORITY and the /proc walk is the WITNESS, and they answer two
    different questions. "Which kernel is this fabric's" is the pidfile's; "is there more than
    one kernel on this machine" is the walk's, and it is the co-variate the whole amendment
    exists to stop assuming. When the pidfile cannot answer, the old rule stands: exactly one
    kernel means that one, more than one means none -- recording the ambiguity rather than
    silently taking the lowest pid, which is how a previous round measured the wrong process.
    """
    pids = _kernels_on_this_machine()
    chosen = None
    try:
        with open(KERNEL_PIDFILE) as fh:
            recorded = fh.read().strip()
        if recorded.isdigit() and _comm(recorded) == KERNEL_COMM:
            chosen = recorded
    except Exception:
        pass
    source = "pidfile"
    if chosen is None:
        source = "proc-scan" if len(pids) == 1 else "none"
        chosen = pids[0] if len(pids) == 1 else None
    return pids, chosen, source


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

        pids, kpid, ksrc = kernel_pid()
        rec["kernel_pids"] = pids
        # More than one kernel means the pid below may not be this fabric's. Record the ambiguity
        # rather than silently taking the lowest pid, which is how a previous round measured the
        # wrong process while every number looked reasonable.
        rec["kernel_ambiguous"] = len(pids) != 1
        # Which channel named the pid the fields below are read from: the stack's own pidfile,
        # the /proc walk (only when it found exactly one), or nothing. Recorded because
        # "ambiguous, and we measured the one this stack started" and "ambiguous, and we
        # measured nothing" are different rows and used to be the same one.
        rec["kernel_pid_source"] = ksrc
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
