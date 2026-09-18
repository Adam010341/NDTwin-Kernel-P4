#!/usr/bin/env python3
"""
Per-process CPU sampler for one arm of the three-group telemetry round.

[Co-developed with claude code -- Adam]

Same /proc discipline as tools/test_workflow/cpu_probe.py -- read the kernel's own counters,
fixed cadence, JSONL with a timestamp so the post-pass integrates time-weighted instead of
assuming the cadence held, and the constants needed to turn jiffies into percentages written
into the data rather than left in the analyst's head.

WHY THIS EXISTS BESIDE cpu_probe.py RATHER THAN AS A PATCH TO IT (PREREG section 3.5)
------------------------------------------------------------------------------------
cpu_probe.py labels processes by a substring of /proc/<pid>/cmdline. Three problems here:

  * The psample emitter's cmdline contains none of its needles, so under `link` -- the group
    whose treatment IS that process -- its cost would read zero. A zero that looks like a
    measurement is the failure mode this whole round is built to avoid.

  * The proxy and the emitter are both a python interpreter. No `comm` rule separates them,
    and both have an authoritative pid: .test_run/pids/p4_proxy.child.pid and
    /tmp/ndtwin_link_telemetry.json. A recorded pid is strictly better evidence than any
    pattern, which is the same argument link_telemetry.process_is_the_emitter makes.

  * TICKET-P3 section 0 red line 1: never a pattern over argv. Adding a needle would leave the
    one process the ticket names "attribute by pid" inside the pattern rule.

So: pids are passed IN (--pid label=pid), discovered only where they cannot be (--comm
label=comm, which in practice is iperf3 alone -- every rung spawns fresh ones). Discovery is by
EXACT /proc/<pid>/comm equality, never a substring, and this process excludes itself.

TWO /proc TRAPS, both already paid for in this codebase
-------------------------------------------------------
  * /proc/<pid>/stat wraps comm in parentheses and it MAY CONTAIN SPACES AND PARENTHESES.
    Splitting on whitespace puts every later field at the wrong offset. Parse from the last
    ')'.
  * /proc/<pid>/comm truncates at 15 characters: `simple_switch_grpc` appears as
    `simple_switch_g`. A caller matching on comm must pass the TRUNCATED form; this file does
    not truncate for you, because guessing which 15 characters the caller meant is how a
    silent miss happens.

WHAT IS RECORDED THAT cpu_probe.py DOES NOT RECORD
--------------------------------------------------
The whole eight-column /proc/stat aggregate, softirq included and separate. Under `link` the
tc sampling action runs in softirq context and is charged to no pid at all, so it is invisible
in every per-process figure and would land silently in the foreign residual -- PREREG section
6.2 turns that into a measurement instead of a gate, and this is where the number comes from.

Usage:
    cpu_arm_probe.py --out <path.jsonl> --duration <seconds> [--hz 2]
                     [--pid <label>=<pid> ...] [--comm <label>=<exact comm> ...]

Exit: 0 when the run finished, 2 when an argument was unusable. A pid that is dead at startup
is reported on stderr and still recorded in the header -- "this was supposed to be here and was
not" is a finding, and dropping it silently would make the header lie.
"""
import argparse
import json
import os
import sys
import time

CLK_TCK = os.sysconf("SC_CLK_TCK")
NPROC = os.cpu_count() or 1

#: /proc/stat's aggregate line, in order. Kept as a name list so the post-pass never indexes a
#: column by a number it remembered.
STAT_COLUMNS = ("user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal")


def fields_after_comm(stat_text):
    """The fields following comm in a /proc/<pid>/stat body, or None if it is not one.

    rfind(')') rather than split(): comm is the only parenthesised field and may itself hold
    ')' and ' ' -- a process named "(evil) thing)" is legal and would shift every offset.
    """
    close = stat_text.rfind(")")
    if close < 0:
        return None
    return stat_text[close + 2:].split()


def cpu_jiffies(path):
    """utime+stime for a pid, or None if it exited between listing and reading.

    Racing an exit is normal, not exceptional: every ladder rung spawns fresh iperf3 processes
    that then leave. A vanished process drops out of the sample; it must not kill the probe.
    """
    try:
        with open(path) as fh:
            fields = fields_after_comm(fh.read())
    except (OSError, ValueError):
        return None
    if not fields or len(fields) < 13:
        return None
    try:
        # stat fields are 1-indexed with utime=14 and stime=15; fields[0] is field 3.
        return int(fields[11]) + int(fields[12])
    except ValueError:
        return None


def machine_stat(proc_root="/proc"):
    """The eight aggregate columns of /proc/stat, by name. softirq stays its own column."""
    with open(os.path.join(proc_root, "stat")) as fh:
        parts = fh.readline().split()[1:]
    values = [int(x) for x in parts[:len(STAT_COLUMNS)]]
    while len(values) < len(STAT_COLUMNS):
        values.append(0)
    return dict(zip(STAT_COLUMNS, values))


def comm_of(pid, proc_root="/proc"):
    """/proc/<pid>/comm, stripped, or None. Truncated at 15 chars by the kernel, not by us."""
    try:
        with open(os.path.join(proc_root, str(pid), "comm")) as fh:
            return fh.read().strip()
    except OSError:
        return None


def discover_by_comm(wanted, proc_root="/proc", exclude=()):
    """{pid: label} for every process whose comm EQUALS one of `wanted` {label: comm}.

    Equality, not containment: a substring rule over comm would match `iperf3x` and, worse,
    would reintroduce the class of bug that pattern searches have already produced here twice.
    `exclude` carries this process's own pid, because a probe that counts itself is measuring
    its own instrument (cpu_probe.py's note says the same thing about pgrep).
    """
    found = {}
    by_comm = {}
    for label, comm in wanted.items():
        by_comm.setdefault(comm, []).append(label)
    if not by_comm:
        return found
    try:
        entries = os.listdir(proc_root)
    except OSError:
        return found
    for entry in entries:
        if not entry.isdigit() or int(entry) in exclude:
            continue
        comm = comm_of(entry, proc_root)
        if comm is None or comm not in by_comm:
            continue
        found[int(entry)] = by_comm[comm][0]
    return found


def sample(static, comms, proc_root="/proc", exclude=()):
    """One row: the clock, the machine, and utime+stime per pid keyed `<label>:<pid>`."""
    row = {"t": round(time.time(), 3), "machine": machine_stat(proc_root), "proc": {}}
    for label, pid in static.items():
        value = cpu_jiffies(os.path.join(proc_root, str(pid), "stat"))
        if value is None:
            continue
        row["proc"]["%s:%d" % (label, pid)] = value
    for pid, label in discover_by_comm(comms, proc_root, exclude).items():
        value = cpu_jiffies(os.path.join(proc_root, str(pid), "stat"))
        if value is None:
            continue
        row["proc"]["%s:%d" % (label, pid)] = value
    return row


def parse_pairs(items, what):
    """`label=value` pairs into a dict, refusing a duplicate label rather than overwriting."""
    out = {}
    for item in items or []:
        if "=" not in item:
            raise ValueError("--%s wants label=value, got %r" % (what, item))
        label, value = item.split("=", 1)
        label, value = label.strip(), value.strip()
        if not label or not value:
            raise ValueError("--%s wants a non-empty label and value, got %r" % (what, item))
        if label in out:
            raise ValueError("--%s label %r given twice; labels are the analysis's keys"
                             % (what, label))
        out[label] = value
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--hz", type=float, default=2.0)
    ap.add_argument("--pid", action="append", metavar="LABEL=PID",
                    help="a process whose pid is known from a manifest or a pidfile")
    ap.add_argument("--comm", action="append", metavar="LABEL=COMM",
                    help="a process class discovered each sample by EXACT /proc/<pid>/comm")
    args = ap.parse_args(argv)

    try:
        static_raw = parse_pairs(args.pid, "pid")
        comms = parse_pairs(args.comm, "comm")
    except ValueError as exc:
        print("cpu_arm_probe: %s" % exc, file=sys.stderr)
        return 2

    static, missing = {}, []
    for label, value in static_raw.items():
        if not value.isdigit():
            print("cpu_arm_probe: --pid %s=%s is not a pid" % (label, value), file=sys.stderr)
            return 2
        pid = int(value)
        static[label] = pid
        if cpu_jiffies("/proc/%d/stat" % pid) is None:
            missing.append("%s=%d" % (label, pid))
    if missing:
        # Reported, and still written into the header. "This was supposed to be here and was
        # not" is a reading; a header that quietly dropped it would claim the arm measured a
        # process it never saw.
        print("cpu_arm_probe: pid(s) not readable at start: %s" % ", ".join(missing),
              file=sys.stderr)

    self_pid = os.getpid()
    period = 1.0 / args.hz if args.hz > 0 else 0.5
    end = time.time() + args.duration
    written = 0
    with open(args.out, "w") as fh:
        fh.write(json.dumps({"clk_tck": CLK_TCK, "nproc": NPROC, "hz": args.hz,
                             "stat_columns": list(STAT_COLUMNS),
                             "static": static, "comms": comms,
                             "unreadable_at_start": missing,
                             "started": round(time.time(), 3)}) + "\n")
        fh.flush()
        while time.time() < end:
            t0 = time.time()
            try:
                fh.write(json.dumps(sample(static, comms, exclude=(self_pid,))) + "\n")
                written += 1
            except Exception as exc:                      # a dropped sample must be visible,
                fh.write(json.dumps({"t": round(t0, 3),   # never silently interpolated over
                                     "error": str(exc)}) + "\n")
            fh.flush()
            slack = period - (time.time() - t0)
            if slack > 0:
                time.sleep(slack)
    print("cpu_arm_probe: %d samples over %.0fs -> %s" % (written, args.duration, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
