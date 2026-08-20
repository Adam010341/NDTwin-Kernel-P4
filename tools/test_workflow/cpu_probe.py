#!/usr/bin/env python3
"""
Per-process CPU sampler for the NDTwin stack, read straight out of /proc.

[Co-developed with claude code -- Adam]

Every throughput number this project has produced says how fast something went and nothing
about where the CPU went. Ten bmv2 processes, Mininet, the proxy and the kernel all share one
machine, so contention is a confound in every measurement taken so far -- including the sFlow
accuracy rounds -- and no report has ever quantified it.

Same discipline as doc/audit/2026-08-18_live-full-stack-round/run.py, deliberately: read the
kernel's own counters rather than ask a tool, sample on a fixed cadence, write JSONL with a
timestamp so the post-pass can integrate time-weighted instead of assuming the cadence held.

Usage:
    python3 tools/test_workflow/cpu_probe.py <seconds> [hz] [out.jsonl]

WHY IT READS /proc DIRECTLY RATHER THAN SHELLING OUT TO ps OR top
-----------------------------------------------------------------
`ps` reports CPU as a *lifetime average* by default, which is the wrong quantity entirely: a
process that spun at 100% for a minute an hour ago and is idle now still reports high. What is
wanted is the delta over the measurement window, which means reading the raw counters at both
ends. top(1) can do it but only interactively or with a parse-hostile batch format.

Two /proc traps this codebase has already been bitten by, handled here:

  * A process name in /proc/<pid>/stat is wrapped in parentheses and MAY CONTAIN SPACES AND
    PARENTHESES. Splitting the line on whitespace and indexing puts every field after the name
    at the wrong offset. Parse from the LAST ')' instead -- see fields_after_comm().

  * /proc/<pid>/comm truncates at 15 characters, so "simple_switch_grpc" appears as
    "simple_switch_g". Matching on comm silently misses processes. cmdline is used instead.
    (See the process-liveness memo: this exact truncation has produced false negatives here.)

Per-thread sampling is included for the kernel because that is how the idle 100% CPU spin was
found -- a whole-process figure showed "busy" and said nothing about which thread. Threads are
cheap to read and the one time they mattered they were decisive.
"""
import json
import os
import sys
import time

CLK_TCK = os.sysconf("SC_CLK_TCK")          # jiffies per second, 100 on this machine
NPROC = os.cpu_count() or 1

# Matched against /proc/<pid>/cmdline. Order matters only for labelling: the first pattern that
# matches wins, so the more specific ones come first.
TARGETS = [
    ("bmv2", "simple_switch_grpc"),
    ("proxy", "proxy_agent"),
    ("kernel", "ndtwin_kernel"),
    ("ryu", "ryu-manager"),
    ("iperf", "iperf3"),
    ("mininet", "mnexec"),
]

# Only the kernel gets per-thread detail. Doing it for all ten bmv2 processes would multiply the
# sample cost by their thread count for a question nobody has asked of them.
PER_THREAD = {"kernel"}


def fields_after_comm(stat_line):
    """
    Splits /proc/<pid>/stat into the fields that follow the comm, 1-indexed from field 3.

    The comm is field 2, parenthesised, and may itself contain ')' and ' ' -- a process named
    "(evil) thing)" is legal. rfind(')') is correct because the comm is the only parenthesised
    field and everything after it is numeric or single-character.
    """
    close = stat_line.rfind(")")
    if close < 0:
        return None
    return stat_line[close + 2:].split()


def cpu_jiffies(path):
    """(utime, stime) for a pid or tid, or None if it exited between listing and reading."""
    try:
        with open(path) as fh:
            f = fields_after_comm(fh.read())
    except (OSError, ValueError):
        # Racing a process exit is normal, not exceptional: iperf3 flows start and stop
        # throughout a run. A vanished process must drop out of the sample, not kill the probe.
        return None
    if not f or len(f) < 13:
        return None
    # stat fields are 1-indexed with utime=14 and stime=15; f[0] is field 3, so subtract 3.
    return int(f[11]), int(f[12])


def machine_jiffies():
    """(busy, total) from /proc/stat's aggregate line. idle+iowait are the non-busy columns."""
    with open("/proc/stat") as fh:
        parts = fh.readline().split()[1:]
    v = [int(x) for x in parts[:8]]
    total = sum(v)
    return total - (v[3] + v[4]), total


def label_for(cmdline):
    for name, needle in TARGETS:
        if needle in cmdline:
            return name
    return None


def scan():
    """{pid: (label, cmdline-ish name)} for every process we care about, rescanned each sample."""
    found = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as fh:
                cmdline = fh.read().replace(b"\x00", b" ").decode("utf8", "replace")
        except OSError:
            continue
        # Never sample ourselves. The probe reading /proc has its own cost and counting it as
        # stack load would be the same mistake as a pgrep pattern matching its own command line.
        if str(os.getpid()) == entry or "cpu_probe.py" in cmdline:
            continue
        label = label_for(cmdline)
        if label is None:
            continue
        # bmv2 processes are told apart by their device id, which is what makes a per-switch
        # breakdown possible at all -- without it ten identical rows cannot be attributed.
        tag = label
        if label == "bmv2":
            for i, tok in enumerate(cmdline.split()):
                if tok == "--device-id" and i + 1 < len(cmdline.split()):
                    tag = f"bmv2-{cmdline.split()[i + 1]}"
                    break
        found[int(entry)] = (label, tag)
    return found


def udp_indatagrams():
    """
    System-wide UDP datagrams delivered, from /proc/net/snmp.

    A cross-check on how many sFlow datagrams the kernel actually received, usable when the
    twin is not being polled and so no per-window sample count can be recovered from its
    readings. It is system-wide rather than per-socket, so it counts any other UDP on the box
    too -- on this machine, during a run, sFlow dominates it by orders of magnitude, but the
    number is a corroboration and not a measurement.
    """
    try:
        with open("/proc/net/snmp") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    for i, line in enumerate(lines):
        if line.startswith("Udp:") and i + 1 < len(lines) and lines[i + 1].startswith("Udp:"):
            keys = line.split()[1:]
            vals = lines[i + 1].split()[1:]
            d = dict(zip(keys, vals))
            if "InDatagrams" in d:
                return int(d["InDatagrams"])
    return None


def sample():
    row = {"t": round(time.time(), 3), "proc": {}, "thread": {}}
    busy, total = machine_jiffies()
    row["machine"] = {"busy": busy, "total": total}
    udp = udp_indatagrams()
    if udp is not None:
        row["udp_in"] = udp
    for pid, (label, tag) in scan().items():
        cpu = cpu_jiffies(f"/proc/{pid}/stat")
        if cpu is None:
            continue
        row["proc"][f"{tag}:{pid}"] = cpu[0] + cpu[1]
        if label in PER_THREAD:
            try:
                tids = os.listdir(f"/proc/{pid}/task")
            except OSError:
                continue
            for tid in tids:
                t = cpu_jiffies(f"/proc/{pid}/task/{tid}/stat")
                if t is None:
                    continue
                try:
                    with open(f"/proc/{pid}/task/{tid}/comm") as fh:
                        tname = fh.read().strip()
                except OSError:
                    tname = "?"
                row["thread"][f"{tname}:{tid}"] = t[0] + t[1]
    return row


def main():
    dur = float(sys.argv[1])
    hz = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
    out = sys.argv[3] if len(sys.argv) > 3 else "cpu.jsonl"

    period = 1.0 / hz
    end = time.time() + dur
    n = 0
    with open(out, "w") as fh:
        # The header carries what the post-pass needs to turn jiffies into percentages. Writing
        # it into the data rather than assuming it at analysis time is the same rule the sFlow
        # rounds learned: a constant that lives only in the analyst's head is a constant that
        # will eventually be wrong for the file being analysed.
        fh.write(json.dumps({"clk_tck": CLK_TCK, "nproc": NPROC, "hz": hz}) + "\n")
        while time.time() < end:
            t0 = time.time()
            try:
                fh.write(json.dumps(sample()) + "\n")
                fh.flush()
                n += 1
            except Exception as exc:                       # a dropped sample must be visible,
                fh.write(json.dumps({"t": round(t0, 3),    # not silently interpolated over
                                     "error": str(exc)}) + "\n")
                fh.flush()
            slp = period - (time.time() - t0)
            if slp > 0:
                time.sleep(slp)
    print(f"done: {n} samples over {dur:.0f}s -> {out}")


if __name__ == "__main__":
    main()
