#!/usr/bin/env python3
"""
cpu_gate.py -- PREREG-E §2/§4's exclusive-CPU gate: is anything OTHER than this round's own
fabric and instruments consuming CPU during a cell?

[Co-developed with claude code -- Adam]

WHY THIS GATE EXISTS.  PREREG §4 pins the round to NDT_EXCLUSIVE_CPU=1 because the readout is a
CPU plateau: a sibling session's compile is not noise, it is a treatment, and on 2026-08-28 one
contaminated a six-arm window asymmetrically without touching the fabric, the build or a binary
-- nothing the claim covers.  memory/vm-on-this-machine-is-invisible-to-ndt-status.

WHY IT COUNTS *FOREIGN* CORES AND NOT load1.
    load1 is a lagging composite and cannot be a threshold (same memory note).  What this round
    needs to know is narrower and answerable: how much CPU is being burned by processes that are
    neither the fabric nor this round's instruments.  That is a difference of two /proc/<pid>/stat
    reads over a window, attributed per process, with an explicit allow list.

🔴 THE ALLOW LIST IS THE GATE'S WEAK POINT, AND §2's FORCE-GREEN (ii) IS AIMED AT IT.
    An allow list that is too wide cannot go red; one that is too narrow reports the experiment's
    own load as contamination and demands a re-run of exactly the arms carrying the headline --
    which is how the ③ round's gate died (auditor-review E3b).  So the gate is forced in BOTH
    directions before it is trusted:
        force-red    a burner known to eat one core must turn it RED
        force-green  (i) an idle fabric must be GREEN  -- proves it CAN be green
                     (ii) a normal arm under the fabric's own load must ALSO be GREEN
                          -- proves it does not misreport the experiment as contamination
    (i) alone is the second kind of bad gate recorded on 08-30: it passes because there is nothing
    there.  Both are required, and a disagreement stops the round rather than moving the threshold.

OUTPUT is one machine-readable line plus a per-process attribution, so that a RED verdict names
the process rather than asserting a number.  Exit 0 = GREEN, 1 = RED, 2 = the gate could not run
(which is neither colour and must never be read as GREEN).
"""
import argparse
import json
import os
import sys
import time

# The fabric and this round's own instruments, matched as PREFIXES of `comm` (the executable
# name in /proc/<pid>/comm, which the kernel truncates to 15 bytes).
#
# 🔴 WHY PREFIXES RATHER THAN EXACT NAMES (changed 2026-08-31, after G5b caught it live).
#   This was a set tested with `in`, i.e. exact equality, holding "simple_switch_" -- 14
#   characters.  The real comm is "simple_switch_g" -- 15.  The entry therefore matched nothing,
#   and the three bmv2 switches (1.93 cores between them) were classified as FOREIGN: the
#   experiment's own fabric counted as contamination of itself.  G5b exists to catch precisely
#   that failure mode, and did.
#   🔑 The comment that used to sit here already warned that "matching a longer name would
#   silently never fire".  It guarded the too-LONG direction and missed the too-SHORT one.
#   Knowing that comm is truncated is not the same as having counted the truncation correctly.
#   This is the project's SECOND time in this pit; the first was pgrep's 15-char comm in the
#   power-on round, where the pattern likewise "correctly anticipated" truncation and was wrong.
#
# 🔴 THE TWO CANDIDATE FIXES FAIL IN OPPOSITE DIRECTIONS, AND THIS ONE IS THE UNSAFE SIDE.
#       exact, too narrow : ours -> foreign  =>  FALSE ALARM            (safe side)
#       prefix            : foreign -> ours  =>  CONTAMINATION MISSED   (unsafe side)
#   This is a contamination gate, so the second is the direction it least wants to fail in.  The
#   prefix form is used anyway, because reaching the unsafe case requires someone to be
#   violating the lab claim AND running bmv2 on this machine -- exactly what `ndt claim` plus
#   NDT_EXCLUSIVE_CPU=1 exist to prevent.  🔑 That makes it an ACCEPTED risk, not an absent one,
#   and the next reader must not mistake the choice for a free one.  Available tightening, not
#   done here: require the comm prefix AND the pid to appear in the fabric manifest.
#   [Co-developed with claude code -- Adam]
FABRIC_PREFIXES = (
    "ndtwin_kernel",      # the twin itself
    "simple_switch",      # matches simple_switch and simple_switch_grpc (comm "simple_switch_g")
    "ryu-manager",
    "ovs-vswitchd", "ovsdb-server",
    "iperf3",             # the offered load, started by measure.sh
    "mnexec",
)
# The proxy is a python process, so it cannot be recognised by comm without also exempting every
# other python on the machine -- including a burner.  It is identified by the socket it holds.
PROXY_PORT = 8081

CLK = os.sysconf("SC_CLK_TCK")


def _read(pid):
    """(comm, utime+stime ticks) or None.  Reads /proc directly: `ps | grep <pattern>` for
    existence always self-matches, and `pgrep -f` is prohibited project-wide."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            raw = fh.read().decode("utf-8", "replace")
        # comm is parenthesised and may itself contain spaces/parentheses -- split on the LAST
        # ')' rather than on whitespace, which is the classic /proc/stat parsing bug.
        lp, rp = raw.index("("), raw.rindex(")")
        comm = raw[lp + 1:rp]
        rest = raw[rp + 2:].split()
        return comm, int(rest[11]) + int(rest[12])     # utime, stime (fields 14,15 -> 0-based 11,12)
    except (OSError, ValueError, IndexError):
        return None


def _snapshot():
    out = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        r = _read(name)
        if r is not None:
            out[int(name)] = r
    return out


def _proxy_pids():
    """PIDs holding :8081.  Read from /proc/net/tcp inode -> fd links rather than shelling out,
    so the gate does not depend on `ss -p` being permitted."""
    inodes = set()
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path) as fh:
                next(fh)
                for line in fh:
                    f = line.split()
                    if int(f[1].split(":")[1], 16) == PROXY_PORT:
                        inodes.add(f[9])
        except (OSError, StopIteration, IndexError, ValueError):
            continue
    if not inodes:
        return set()
    pids = set()
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            for fd in os.listdir(f"/proc/{name}/fd"):
                try:
                    link = os.readlink(f"/proc/{name}/fd/{fd}")
                except OSError:
                    continue
                if link.startswith("socket:[") and link[8:-1] in inodes:
                    pids.add(int(name))
                    break
        except OSError:
            continue
    return pids


def _is_fabric(comm):
    """True when `comm` names one of our own processes.

    FORCE_CPU_GATE_DISOWN_FABRIC makes this answer False for everything, which is the force-RED
    control for the classification ITSELF.  With the fabric up, the gate must go RED once it
    stops recognising its own switches -- otherwise a green G5b could be coming from anywhere,
    and we would be reading "the allow list works" off a result that never depended on it.

    🔴 THIS HOOK HAS NOT YET BEEN EXERCISED WITH DISCRIMINATING POWER.  Three attempts on
    2026-08-31 (idle fabric / ping flood / ping that ended early) all put too little load on the
    switches: below the threshold the gate answers GREEN whether or not the disown fires, so
    those runs would have given the same answer either way and none of them is evidence.  What
    actually supports the allow-list fix is the natural experiment across it (FINDINGS F-3a,
    21:24:19 vs 22:02:33, delta ~1.43 cores).  Do not read this hook as a passed control until
    it has been run against switches carrying real load.
    [Co-developed with claude code -- Adam]
    """
    if os.environ.get("FORCE_CPU_GATE_DISOWN_FABRIC"):
        return False
    return comm.startswith(FABRIC_PREFIXES)


def measure(window, exempt_pids):
    a = _snapshot()
    proxy = _proxy_pids() | set(exempt_pids)
    t0 = time.monotonic()
    time.sleep(window)
    elapsed = time.monotonic() - t0
    b = _snapshot()

    foreign, mine = [], []
    for pid, (comm, ticks_b) in b.items():
        if pid not in a:
            continue                       # started mid-window: no baseline, cannot attribute
        comm_a, ticks_a = a[pid]
        if comm_a != comm:
            continue                       # pid reused: not the same process
        cores = (ticks_b - ticks_a) / CLK / elapsed
        if cores <= 0.005:
            continue
        rec = dict(pid=pid, comm=comm, cores=round(cores, 3))
        if _is_fabric(comm) or pid in proxy or pid == os.getpid():
            mine.append(rec)
        else:
            foreign.append(rec)
    foreign.sort(key=lambda r: -r["cores"])
    mine.sort(key=lambda r: -r["cores"])
    return elapsed, foreign, mine


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window", type=float, default=10.0)
    ap.add_argument("--threshold", type=float, default=0.50,
                    help="foreign cores at or above which the gate is RED")
    ap.add_argument("--exempt-pid", type=int, action="append", default=[],
                    help="a PID this round started itself (repeatable)")
    ap.add_argument("--label", default="cpu")
    ap.add_argument("--out", default=None, help="append the JSON record here")
    ap.add_argument("--expect", choices=("green", "red"), default=None,
                    help="force test: the gate must come out this colour, else exit 2")
    # 🔴 THE BASELINE, AND WHY IT IS A MEASURED FILE RATHER THAN A NUMBER SOMEBODY TYPED.
    #
    # Measured on this machine 2026-08-31 with no fabric and no burner: 0.76 foreign cores, of
    # which claude-desktop ~0.37, the CLI sessions ~0.20 and gnome-shell ~0.11.  So an absolute
    # 0.5-core threshold is RED before the round starts, and the session that DRIVES the round is
    # part of what makes it red -- memory/vm-on-this-machine-is-invisible-to-ndt-status already
    # names "the claude session itself" as the third invisible load source.
    #
    # Two wrong fixes, both of which this round has committed before in other forms:
    #   * raise the threshold until it passes  -- that is adjusting the instrument to the answer
    #   * default the baseline to 0            -- permanently red, i.e. a gate with no green
    # So: the baseline is MEASURED into a file by --record-baseline before the window, the gate
    # reads it, and it gates on the EXCESS over that baseline.  Both numbers are reported, so a
    # drifting desktop is visible rather than absorbed.  A missing baseline file is refused
    # (exit 2), never assumed -- an unrunnable gate is not a green gate.
    ap.add_argument("--baseline-file", default=None,
                    help="file holding the measured idle foreign-core baseline")
    ap.add_argument("--record-baseline", action="store_true",
                    help="measure now and WRITE the baseline file, then exit")
    # Named covariates, pulled out of the attribution table into their own field.
    #
    # Adam ruled on 2026-08-31 that the desktop stays up during the window.  That makes
    # claude-desktop and the CLI sessions a DECLARED covariate rather than an invisible one --
    # memory/vm-on-this-machine-is-invisible-to-ndt-status already names "the claude session
    # itself" as the third invisible load source, and this is what un-hides it.
    #
    # 🔑 They are OUR OWN processes, so their cost is attributable rather than inferred.  Without
    # this field the question "did that cell get worse because someone was using the desktop?"
    # has no answer at all -- and it is a question this round will be asked.
    ap.add_argument("--covariate-comm", default="claude-desktop,claude,gnome-shell,chrome",
                    help="comma-separated comms to record per run as named covariates")
    a = ap.parse_args()

    try:
        elapsed, foreign, mine = measure(a.window, a.exempt_pid)
    except Exception as e:                                    # noqa: BLE001 -- see below
        # 🔴 An unreadable gate is NOT a green gate.  Exit 2, never 0: the one failure this gate
        # must not have is the one that mimics a pass.
        print(f"GATE {a.label} verdict=UNRUNNABLE err={e!r}")
        return 2

    total = round(sum(r["cores"] for r in foreign), 3)
    want = [c for c in a.covariate_comm.split(",") if c]
    covariates = {c: round(sum(r["cores"] for r in foreign + mine if r["comm"] == c), 3)
                  for c in want}

    if a.record_baseline:
        if not a.baseline_file:
            print("GATE baseline verdict=UNRUNNABLE err=--record-baseline needs --baseline-file")
            return 2
        with open(a.baseline_file, "w") as fh:
            fh.write(json.dumps(dict(baseline_cores=total, when=time.strftime("%FT%T"),
                                     window_s=round(elapsed, 2), covariates=covariates,
                                     attribution=foreign[:15])) + "\n")
        print(f"GATE baseline recorded={total} cores -> {a.baseline_file}")
        for r in foreign[:8]:
            print(f"     {r['comm']:<18} pid={r['pid']:>7} cores={r['cores']}")
        return 0

    baseline = 0.0
    if a.baseline_file:
        try:
            with open(a.baseline_file) as fh:
                baseline = float(json.loads(fh.readline())["baseline_cores"])
        except Exception as e:                                # noqa: BLE001
            print(f"GATE {a.label} verdict=UNRUNNABLE err=baseline file unreadable: {e!r}")
            print("     Record it first:  cpu_gate.py --record-baseline --baseline-file <path>")
            print("     It is NOT defaulted to 0: that would make the gate permanently red, and")
            print("     defaulting it to anything else would make it permanently green.")
            return 2

    excess = round(total - baseline, 3)
    verdict = "RED" if excess >= a.threshold else "GREEN"
    rec = dict(label=a.label, when=time.strftime("%FT%T"), window_s=round(elapsed, 2),
               foreign_cores=total, baseline_cores=baseline, excess_cores=excess,
               threshold=a.threshold, verdict=verdict, covariates=covariates,
               foreign=foreign[:10], mine=mine[:10])
    print(f"GATE {a.label} foreign_cores={total} baseline={baseline} excess={excess} "
          f"threshold={a.threshold} verdict={verdict}")
    print("     covariates " + " ".join(f"{k}={v}" for k, v in covariates.items()))
    for r in foreign[:5]:
        print(f"     foreign  pid={r['pid']:>7} comm={r['comm']:<16} cores={r['cores']}")
    for r in mine[:8]:
        print(f"     ours     pid={r['pid']:>7} comm={r['comm']:<16} cores={r['cores']}")
    if a.out:
        with open(a.out, "a") as fh:
            fh.write(json.dumps(rec) + "\n")

    if a.expect:
        want = a.expect.upper()
        if verdict != want:
            print(f"GATE {a.label} FORCE-TEST FAILED: expected {want}, got {verdict}.")
            print("     PREREG §2: a gate whose forced direction does not come out is a broken")
            print("     gate.  Stop the round and fix the gate.  Do NOT move the threshold.")
            return 2
        print(f"GATE {a.label} force-test OK: expected {want}, got {verdict}")
        # 🔴 The force matched, and for a --expect invocation THAT is the success condition.
        #
        # Falling through to the verdict mapping below is what this line used to do, and it made
        # the force-RED direction impossible to record as a pass: a successful force-red ends
        # with verdict=RED, the mapping returned 1, and the caller
        #     if cpu_gate forcered_burner red ...; then record PASS; else record FAIL; abort
        # recorded a WORKING force-red as a failure and aborted with "a process burning a whole
        # core did NOT turn the gate red" -- the exact opposite of the two lines printed just
        # above it (verdict=RED, force-test OK).  Observed live 2026-08-31 21:11:23.
        #
        # 🔑 The exit code was serving two callers with incompatible questions: as a GATE it
        # answers "is the machine clean" (0=GREEN), as a FORCE TEST it answers "did the forced
        # direction come out" (0=matched, 2=did not).  With --expect the caller is asking the
        # second, so answer the second and stop overloading the code.
        #
        # 🔑 Why it survived until now: the two force-GREEN call sites are unaffected, because
        # GREEN happens to map to 0.  The defect was only ever reachable by forcing the RED
        # direction -- so it hid behind the habit of only ever confirming the green one.
        # [Co-developed with claude code -- Adam]
        return 0
    return 0 if verdict == "GREEN" else 1


if __name__ == "__main__":
    sys.exit(main())
