#!/usr/bin/env python3
"""Per-cell machine state: how busy every core actually was, from /proc/stat deltas.

[Co-developed with claude code -- Adam]

WHY NOT loadavg.  loadavg is an exponential moving average with a 60 s time constant, so it
cannot see a cell boundary: a 120 s cell that saturates the box reads mostly as whatever came
before it.  Ticket H logged loadavg and it ranged 7.03 to 20.07 across one six-minute run --
true, and useless for saying which arm was saturated.  /proc/stat is a set of monotonic
counters, so a difference over exactly the cell's span answers the question the loadavg number
only gestured at.

WHY IT MATTERS FOR TICKET N.  Ticket 1 measured the twin under-reporting by 34% while the data
plane lost only 5%, on a box whose fourteen cores were all pegged.  Ticket P will look for the
mechanism.  Whether P's answer applies to N's numbers depends on whether N ran saturated, and
nobody can decide that afterwards without this record.  A few lines now against re-running a
whole round later.

  snapshot(path)                 write one sample
  report(before, after)          per-core busy%, and the aggregate

Both are diagnostics.  They do not participate in any ticket's verdict.
"""
import os
import sys


def top_processes(n=5):
    """Who else is on this machine, by CPU and by RSS.

    THIS LINE IS THE ONE THAT WAS MISSING.  On 2026-08-27 a QEMU VM was started at 16:14:12 and
    shut down at 16:26:33 by another session; a make-up run sat inside that window, and because
    this file recorded CPU and memory but never *who*, nobody could settle afterwards whether
    the cell had carried it.  It took three separate transcript searches that day to attribute a
    file author, a VM, and a stray script -- transcript archaeology is the most expensive layer
    of attribution and this is the cheapest, so it should never have been the fallback.

    Read straight from /proc rather than `ps -o pcpu`: that column is an average over the
    process's whole lifetime, not an instantaneous rate, and reporting it as current load is how
    the same VM got described as 163% CPU while its build had already finished.
    """
    procs = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % d) as fh:
                r = fh.read()
            comm = r[r.index("(") + 1:r.rindex(")")]
            f = r[r.rindex(")") + 1:].split()
            jiffies = int(f[11]) + int(f[12])          # utime + stime, cumulative
            with open("/proc/%s/statm" % d) as fh:
                rss = int(fh.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")
        except Exception:
            continue                                    # process exited mid-scan: normal
        procs.append((int(d), comm, jiffies, rss))
    return procs


def snapshot(path):
    """Copy the lines of /proc/stat we need, plus memory, verbatim."""
    out = []
    # pid comm cumulative-jiffies rss -- differenced across the two snapshots, so the CPU figure
    # is this cell's, not the process's lifetime average.
    for pid, comm, j, rss in top_processes():
        out.append("proc\t%d\t%s\t%d\t%d" % (pid, comm, j, rss))
    for line in open("/proc/stat"):
        if line.startswith("cpu") or line.startswith("procs_"):
            out.append(line.rstrip())
    for line in open("/proc/meminfo"):
        if line.split(":")[0] in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"):
            out.append(line.rstrip())
    for line in open("/proc/vmstat"):
        if line.split()[0] in ("pgscan_direct", "pgsteal_direct"):
            out.append(line.rstrip())
    open(path, "w").write("\n".join(out) + "\n")


def parse(path):
    cpus, meta, procs = {}, {}, {}
    for line in open(path):
        if line.startswith("proc\t"):
            _, pid, comm, j, rss = line.rstrip("\n").split("\t")
            procs[int(pid)] = (comm, int(j), int(rss))
            continue
        f = line.split()
        if not f:
            continue
        if f[0].startswith("cpu"):
            # user nice system idle iowait irq softirq steal guest guest_nice
            cpus[f[0]] = [int(x) for x in f[1:]]
        elif len(f) >= 2:
            meta[f[0].rstrip(":")] = f[1]
    return cpus, meta, procs


def busy(before, after):
    """(busy%, iowait%, steal%) from two raw jiffy vectors."""
    d = [b - a for a, b in zip(before, after)]
    total = sum(d)
    if total <= 0:
        return None
    idle = d[3] + d[4]                    # idle + iowait
    return (100.0 * (total - idle) / total,
            100.0 * d[4] / total,
            100.0 * (d[7] if len(d) > 7 else 0) / total)


def report(before_path, after_path, label=""):
    a_cpu, a_meta, a_proc = parse(before_path)
    b_cpu, b_meta, b_proc = parse(after_path)
    agg = busy(a_cpu["cpu"], b_cpu["cpu"])
    if agg is None:
        print("  ENV %s: NO-DATA (counters did not move -- same snapshot twice?)" % label)
        return None
    per = []
    for k in sorted(a_cpu):
        if k == "cpu" or k not in b_cpu:
            continue
        r = busy(a_cpu[k], b_cpu[k])
        if r:
            per.append(r[0])
    per.sort()
    sat = sum(1 for p in per if p >= 95.0)
    print("  ENV %s: aggregate busy %.1f%%  iowait %.1f%%  steal %.1f%%" % (label, *agg))
    print("       per-core busy: min %.0f%%  median %.0f%%  max %.0f%%   cores >=95%%: %d/%d"
          % (per[0], per[len(per) // 2], per[-1], sat, len(per)))
    ps = int(b_meta.get("pgscan_direct", 0)) - int(a_meta.get("pgscan_direct", 0))
    print("       MemAvailable %s -> %s kB   direct-reclaim pages scanned: %d"
          % (a_meta.get("MemAvailable"), b_meta.get("MemAvailable"), ps))
    # The registered word for this cell, so a later reader does not have to re-judge it.
    tck = os.sysconf("SC_CLK_TCK")
    movers = []
    for pid, (comm, j, rss) in b_proc.items():
        if pid in a_proc:
            dj = j - a_proc[pid][1]
            if dj > 0:
                movers.append((dj / tck, comm, pid, rss))
    movers.sort(reverse=True)
    if movers:
        print("       busiest neighbours this cell (cpu-seconds, from /proc not ps -o pcpu):")
        for sec, comm, pid, rss in movers[:5]:
            print("         %-18s pid %-8d %6.1f cpu-s  rss %5.0f MB" % (comm[:18], pid, sec, rss/1e6))
        gone = sorted(set(a_proc) - set(b_proc))
        new = sorted(set(b_proc) - set(a_proc))
        if gone or new:
            print("       churn: %d exited, %d appeared during the cell" % (len(gone), len(new)))
    verdict = ("SATURATED" if agg[0] >= 90.0 else
               "BUSY" if agg[0] >= 60.0 else "NOT SATURATED")
    print("       -> %s (diagnostic only, does not enter any verdict)" % verdict)
    return {"busy": agg[0], "iowait": agg[1], "steal": agg[2],
            "cores_pegged": sat, "cores": len(per), "reclaim_pages": ps, "verdict": verdict}


def selftest():
    import tempfile
    d = tempfile.mkdtemp()
    a, b = os.path.join(d, "a"), os.path.join(d, "b")
    # known-good: one core fully busy, one fully idle -> aggregate 50%
    open(a, "w").write("cpu  0 0 0 0 0 0 0 0\ncpu0 0 0 0 0 0 0 0 0\ncpu1 0 0 0 0 0 0 0 0\n"
                       "MemAvailable: 100 kB\npgscan_direct 0\n")
    open(b, "w").write("cpu  100 0 0 100 0 0 0 0\ncpu0 100 0 0 0 0 0 0 0\n"
                       "cpu1 0 0 0 100 0 0 0 0\nMemAvailable: 50 kB\npgscan_direct 7\n")
    r = report(a, b, "selftest")
    assert abs(r["busy"] - 50.0) < 0.01, r["busy"]
    # the neighbour column: a process that burned CPU inside the cell must be visible, and one
    # that merely existed must not be -- otherwise the column reports lifetime totals again.
    ck = os.sysconf("SC_CLK_TCK")
    open(a, "a").write("proc\t111\tqemu\t0\t3300000000\nproc\t222\tidler\t500\t1000\n")
    open(b, "a").write("proc\t111\tqemu\t%d\t3300000000\nproc\t222\tidler\t500\t1000\n" % (7 * ck))
    _, _, ap = parse(a)
    _, _, bp = parse(b)
    assert bp[111][1] - ap[111][1] == 7 * ck, "busy neighbour must show 7 cpu-seconds"
    assert bp[222][1] - ap[222][1] == 0, "an idle neighbour must show zero, not its lifetime 500"
    assert r["cores_pegged"] == 1, r["cores_pegged"]
    assert r["reclaim_pages"] == 7, r["reclaim_pages"]
    assert r["verdict"] == "NOT SATURATED", r["verdict"]
    # known-bad: identical snapshots must say NO-DATA, not 0% busy
    assert report(a, a, "identical") is None, "identical snapshots must be NO-DATA"
    print("SELFTEST PASS (50%% aggregate, 1 core pegged, 7 reclaim pages, identical -> NO-DATA)")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    elif sys.argv[1] == "snap":
        snapshot(sys.argv[2])
    else:
        report(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
