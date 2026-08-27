#!/usr/bin/env python3
"""Per-switch CPU for the ten bmv2 processes, as raw jiffies. Ticket P instrument 2.

WHY IT EXISTS. Ticket 1 measured telemetry under-reporting by 34% while the data plane lost 5%,
ruled out collector drops and proxy starvation, and could not name what was left. The leading
candidate is bmv2 generating fewer samples -- ten userspace switches competing for the same cores
as the burners, and the sample source -- but ticket 1 had no per-process data for them, so it
stayed a candidate. This is the missing instrument, and naming it as missing is why it exists.

WHY NOT ps. `ps -o pcpu` is the process's average over its entire lifetime, which is useless for
comparing one six-minute arm against another on switches that have been up for an hour. Ticket 1
nearly shipped a comparison built on that. Raw counters differentiate over any window.

WHY A FILE AND NOT python3 -c. The proxy sampler written inline on 2026-08-27 matched its own
argv -- `pgrep -af proxy_agent` found the sampler, because the pattern was inside the program and
the program was inside the command line. A script file's argv is just its path. Identification
here is by /proc/<pid>/cmdline rather than pgrep, self is excluded explicitly, and the number of
switches found is recorded in every sample so a silent drop from ten to nine cannot pass as data.

Usage: sample_bmv2_cpu.py <out.jsonl> <interval_s>
[Co-developed with claude code -- Adam]
"""
import json
import os
import re
import sys
import time

NEEDLE = "simple_switch_grpc"


def switches():
    """Every running bmv2, by cmdline. Returns [(pid, cmd)].

    Not pgrep: `pgrep -f simple_switch_grpc` would match this process, and `pgrep
    simple_switch_grpc` without -f matches nothing at all -- the name is 18 characters and
    /proc/PID/comm caps at 15, which silently emptied the bmv2 field of every run on 2026-08-25.
    Reading cmdline directly avoids both.
    """
    me = os.getpid()
    found = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == me:
            continue
        try:
            cmd = open(f"/proc/{entry}/cmdline", "rb").read().replace(b"\0", b" ").decode(
                "utf-8", "replace")
        except Exception:
            continue
        if NEEDLE in cmd:
            found.append((entry, cmd))
    return found


IFACE = re.compile(r"\d+@(s\d+)-eth\d+")


def switch_id(cmd):
    """s1..s10 from the argv, so an arm can be read per switch and not only in aggregate.

    The name is not in the binary path -- every switch runs the same
    /usr/local/bmv2-fast/bin/simple_switch_grpc. It is in the interface arguments, which look
    like `-i 3@s1-eth3`. The first version of this function guessed at the path and returned None
    for all ten, which the smoke test caught on its first run; that is the whole reason the
    self-check asks whether the tool identified only what it should.

    Returns None rather than a guess when the interfaces disagree. A wrong label here silently
    files one switch's CPU under another, and per-switch attribution is the entire point of this
    instrument -- a missing label is recoverable, a confident wrong one is not.
    """
    names = set(IFACE.findall(cmd))
    return names.pop() if len(names) == 1 else None


def main():
    out_path, interval = sys.argv[1], float(sys.argv[2])
    f = open(out_path, "a", buffering=1)          # append, so a restart cannot truncate history
    while True:
        t0 = time.time()
        rec = {"t": t0, "procs": {}}
        for pid, cmd in switches():
            try:
                raw = open(f"/proc/{pid}/stat").read()
                fields = raw[raw.rindex(")") + 2:].split()
                rec["procs"][pid] = {"utime": int(fields[11]), "stime": int(fields[12]),
                                     "threads": int(fields[17]), "sw": switch_id(cmd)}
            except Exception:
                pass
        # Ten is the expected count on this fabric. Recording it every sample means a switch that
        # dies mid-arm shows up as a step in the data instead of as a quietly smaller sum -- the
        # aggregate would just look like less CPU, which is exactly the signal being hunted.
        rec["n_switches"] = len(rec["procs"])
        rec["clk_tck"] = os.sysconf("SC_CLK_TCK")
        rec["ncpu"] = os.cpu_count()
        f.write(json.dumps(rec) + "\n")
        # Sleep the remainder. A flat sleep drifts to 7.6 s under exactly the load this samples,
        # which is how the proxy sampler behaved before it was fixed.
        time.sleep(max(0.0, interval - (time.time() - t0)))


if __name__ == "__main__":
    main()
