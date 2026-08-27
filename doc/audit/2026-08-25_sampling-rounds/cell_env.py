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
import sys


def snapshot(path):
    """Copy the lines of /proc/stat we need, plus memory, verbatim."""
    out = []
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
    cpus, meta = {}, {}
    for line in open(path):
        f = line.split()
        if f[0].startswith("cpu"):
            # user nice system idle iowait irq softirq steal guest guest_nice
            cpus[f[0]] = [int(x) for x in f[1:]]
        elif len(f) >= 2:
            meta[f[0].rstrip(":")] = f[1]
    return cpus, meta


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
    a_cpu, a_meta = parse(before_path)
    b_cpu, b_meta = parse(after_path)
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
    verdict = ("SATURATED" if agg[0] >= 90.0 else
               "BUSY" if agg[0] >= 60.0 else "NOT SATURATED")
    print("       -> %s (diagnostic only, does not enter any verdict)" % verdict)
    return {"busy": agg[0], "iowait": agg[1], "steal": agg[2],
            "cores_pegged": sat, "cores": len(per), "reclaim_pages": ps, "verdict": verdict}


def selftest():
    import tempfile, os
    d = tempfile.mkdtemp()
    a, b = os.path.join(d, "a"), os.path.join(d, "b")
    # known-good: one core fully busy, one fully idle -> aggregate 50%
    open(a, "w").write("cpu  0 0 0 0 0 0 0 0\ncpu0 0 0 0 0 0 0 0 0\ncpu1 0 0 0 0 0 0 0 0\n"
                       "MemAvailable: 100 kB\npgscan_direct 0\n")
    open(b, "w").write("cpu  100 0 0 100 0 0 0 0\ncpu0 100 0 0 0 0 0 0 0\n"
                       "cpu1 0 0 0 100 0 0 0 0\nMemAvailable: 50 kB\npgscan_direct 7\n")
    r = report(a, b, "selftest")
    assert abs(r["busy"] - 50.0) < 0.01, r["busy"]
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
