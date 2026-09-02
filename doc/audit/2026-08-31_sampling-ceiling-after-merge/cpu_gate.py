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

🔴 WHAT THE TWO-SNAPSHOT DESIGN CANNOT SEE, AND WHY THAT USED TO BE INVISIBLE (fixed 2026-09-01).
    A difference of two /proc reads can only attribute CPU to a process present in BOTH reads.
    Until today the loop simply skipped everything else -- `if pid not in a: continue` -- so a
    process that started inside the window contributed exactly 0 and was not counted anywhere.
    A cell whose contamination came entirely from short-lived processes (a build's thousands of
    cc1/as, a loop of qemu-img, a busy shell script) therefore read IDENTICAL to a quiet cell.
    The comment on that line was honest -- "no baseline, cannot attribute" -- and the defect was
    downstream, where the sum was used as if it were a total.

    Three separate populations, and they are not equally lost:
      started mid-window, still alive  ->  RECOVERABLE.  /proc/<pid>/stat field 22 is the process's
                                          start time in ticks since boot.  If that is after the
                                          opening snapshot, every tick it holds was burned inside
                                          this window, so the whole of it is attributable.
      in the opening snapshot, gone    ->  NOT recoverable per-process (we have a baseline and no
        by the closing one                final reading), but it is COUNTED.
      started and ended inside         ->  invisible to both snapshots at any sampling rate below
        the window                        the process's lifetime.  Not countable per-process.

    🔑 The third population is why a count of skipped pids is not sufficient on its own: the
    processes that hurt the most are exactly the ones neither snapshot ever sees.  So the gate
    also differences /proc/stat's aggregate cpu line over the same interval and reports
    unattributed_cores = (all busy cores) - (everything we could name).  That residual is the
    only quantity here that bounds the invisible population, and it is reported ALWAYS, not only
    when it is large -- a skipped process must never print the same as no process.

OUTPUT is one machine-readable line plus a per-process attribution, so that a RED verdict names
the process rather than asserting a number.  Exit 0 = GREEN, 1 = RED, 2 = the gate could not run
(which is neither colour and must never be read as GREEN).

🔴 `suspect` IS A SEPARATE FIELD AND DELIBERATELY NOT A FOURTH EXIT CODE.  This file already has
an essay (see --expect below) about the exit code serving two callers with incompatible
questions; a third meaning would be the same mistake a second time.  A cell can be GREEN and
suspect at once -- that is not a contradiction, it is the gate saying "the CPU I could name is
under the threshold, and here is how much I could not name".  The caller decides, and
lib_e.sh:cell_cpu_gate_finish does.
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

# 🔴 A VERSION STAMP, BECAUSE THIS CHANGE MOVES THE NUMBERS AND NOT ONLY THE FIELD NAMES.
#   Mid-window processes now enter the sum, and the sum is no longer truncated at the listing
#   floor, so a reading from this version is NOT comparable with one from before it -- in the
#   same direction, both times: the new number is >= the old one.  The sibling KNOWN-ISSUES entry
#   asks measure.sh for exactly this ("改版前／改版後的格永遠分得開"), and a gate that demands it
#   of others has to carry it itself.  Deliberately a date-string and not an integer: nobody can
#   accidentally write `if version < 3`.
GATE_VERSION = "2026-09-01.lifetime"

# The listing floor.  🔑 It is a LISTING floor now and no longer a counting one, which is the
# whole of hole (2) in the KNOWN-ISSUES entry: this same 0.005 used to `continue`, so a hundred
# processes at 0.004 cores summed to 0.4 cores of contamination that the total never saw.  The
# totals below are accumulated BEFORE this test; it only decides who is worth a printed row.
LIST_FLOOR = 0.005

# Test seam.  Every read below goes through this so the differencing logic can be exercised
# against fixture directories -- there is no other way to write a process that starts mid-window,
# and an untested attribution rule in a contamination gate is how the last three defects here got
# in.  🔴 It is reported in the record whenever it is not /proc: a gate pointed at a fabricated
# procfs must never be able to produce a green that reads like a real one.
PROCFS = os.environ.get("CPU_GATE_PROCFS", "/proc")


def _read(pid):
    """(comm, utime+stime ticks, starttime ticks) or None.  Reads /proc directly: `ps | grep
    <pattern>` for existence always self-matches, and `pgrep -f` is prohibited project-wide.

    `rest` starts at field 3 (state), so field N of proc(5)'s table is rest[N-3]:
        utime     field 14 -> rest[11]
        stime     field 15 -> rest[12]
        starttime field 22 -> rest[19]     ticks since boot; the same clock as /proc/uptime
    """
    try:
        with open(f"{PROCFS}/{pid}/stat", "rb") as fh:
            raw = fh.read().decode("utf-8", "replace")
        # comm is parenthesised and may itself contain spaces/parentheses -- split on the LAST
        # ')' rather than on whitespace, which is the classic /proc/stat parsing bug.
        lp, rp = raw.index("("), raw.rindex(")")
        comm = raw[lp + 1:rp]
        rest = raw[rp + 2:].split()
        return comm, int(rest[11]) + int(rest[12]), int(rest[19])
    except (OSError, ValueError, IndexError):
        return None


def _snapshot():
    out = {}
    for name in os.listdir(PROCFS):
        if not name.isdigit():
            continue
        r = _read(name)
        if r is not None:
            out[int(name)] = r
    return out


def _uptime():
    """Seconds since boot.  Read BEFORE the opening snapshot, so that a process which starts
    while that snapshot is being taken compares as mid-window and has its whole lifetime charged
    to us.  🔑 That is the deliberate direction: over-charging a stranger is a false alarm, and
    under-charging one is a missed contamination -- the failure this gate exists to prevent."""
    with open(f"{PROCFS}/uptime") as fh:
        return float(fh.readline().split()[0])


def _cpu_busy_ticks():
    """Busy ticks across all CPUs, from /proc/stat's aggregate line.

    Everything except idle and iowait, neither of which is work being done.  steal is excluded
    too: it is time the hypervisor took, not time a process on this machine spent.  guest and
    guest_nice are NOT added -- the kernel already counts them inside user and nice, so adding
    them would double-charge every guest tick.

    This is the only reading that can see a process which both started and ended inside the
    window, and it sees it only in aggregate.  It is the term that makes UNACCOUNTED-SHORT-LIVED
    a quantity instead of a hand-wave."""
    with open(f"{PROCFS}/stat") as fh:
        f = fh.readline().split()
    if not f or f[0] != "cpu":
        raise ValueError(f"{PROCFS}/stat does not open with the aggregate cpu line")
    user, nice, system, _idle, _iowait, irq, softirq = (int(x) for x in f[1:8])
    return user + nice + system + irq + softirq


def _proxy_pids():
    """PIDs holding :8081.  Read from /proc/net/tcp inode -> fd links rather than shelling out,
    so the gate does not depend on `ss -p` being permitted."""
    inodes = set()
    for path in (f"{PROCFS}/net/tcp", f"{PROCFS}/net/tcp6"):
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
    for name in os.listdir(PROCFS):
        if not name.isdigit():
            continue
        try:
            for fd in os.listdir(f"{PROCFS}/{name}/fd"):
                try:
                    link = os.readlink(f"{PROCFS}/{name}/fd/{fd}")
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

    ✅ EXERCISED 2026-08-31 22:50, both directions, under real switch load (gates_e.controls.log):
        ctl_disown_off  foreign_cores=0.534  excess=-0.421  threshold=0.5  GREEN
        ctl_disown_on   foreign_cores=3.313  excess=+2.358  threshold=0.5  RED
    🔑 It took four attempts to get a control with any discriminating power.  The first three
    (idle fabric / ping flood / ping that ended early) all put too little load on the switches,
    and below the threshold the gate answers GREEN whether or not the disown fires -- the same
    answer either way, so none of them was evidence.  The load recipe that works is G5b's
    (measure.sh at 200 Mbit), which puts ~1.5 cores on three switches, 3x the threshold.
    ⇒ When a force comes out as predicted, ask whether the unforced run would have said the same.
    [Co-developed with claude code -- Adam]
    """
    if os.environ.get("FORCE_CPU_GATE_DISOWN_FABRIC"):
        return False
    return comm.startswith(FABRIC_PREFIXES)


def measure(window, exempt_pids, sleeper=time.sleep, clock=time.monotonic):
    """Difference two /proc snapshots over `window` seconds and attribute the CPU.

    `sleeper` and `clock` are injected so the differencing rules can be tested against fixture
    procfs trees: a test's sleeper swaps PROCFS from the opening tree to the closing one, which
    is the only way to write "a process that started mid-window" down as a test case.  Nothing
    else in this function knows the difference.
    """
    up_a = _uptime()
    cpu_a = _cpu_busy_ticks()
    a = _snapshot()
    proxy = _proxy_pids() | set(exempt_pids)
    t0 = clock()
    sleeper(window)
    elapsed = clock() - t0
    b = _snapshot()
    cpu_b = _cpu_busy_ticks()
    if elapsed <= 0:
        # Refused rather than guarded with a tiny epsilon: every core figure below is a rate over
        # this number, so a zero-length window does not produce a small reading, it produces a
        # meaningless one.  main() turns this into exit 2.
        raise ValueError(f"window measured {elapsed!r}s of elapsed time; nothing can be a rate over that")

    foreign, mine = [], []
    by_comm = {}
    foreign_total = mine_total = midwindow_foreign = 0.0
    named_ticks = 0
    counts = dict(midwindow_attributed=0, excluded_no_baseline=0,
                  excluded_pid_reused=0, excluded_vanished=0)
    self_pid = os.getpid()

    for pid, (comm, ticks_b, start_b) in b.items():
        prev = a.get(pid)
        midwindow = False
        if prev is None:
            if start_b / CLK >= up_a:
                # It did not exist when the window opened, so every tick it is holding now was
                # burned inside the window.  The whole of it is attributable -- this is the
                # population the old `continue` charged at zero.
                midwindow = True
                counts["midwindow_attributed"] += 1
                delta = ticks_b
            else:
                # Running now, older than the window, and absent from the opening snapshot: that
                # read failed (permission, or /proc's own race).  There is no baseline, so this
                # one really cannot be attributed -- and it is COUNTED, not skipped.
                counts["excluded_no_baseline"] += 1
                continue
        else:
            _comm_a, ticks_a, start_a = prev
            # 🔴 IDENTITY IS (pid, starttime).  IT IS NOT (pid, comm), AND THAT COST REAL CPU.
            #   This test used to read `if comm_a != comm: continue  # pid reused`, which treats
            #   comm as an identity when it is only a label -- one the kernel rewrites while the
            #   process runs.  Measured on this machine 2026-09-01 over a single 8s window: 12
            #   processes changed comm and NONE changed starttime, every one of them a kworker
            #   being renamed after the workqueue it is currently servicing
            #       kworker/2:1H-i915_cleanup  ->  kworker/2:1H-events_highpri
            #       kworker/u58:5-writeback    ->  kworker/u58:5-flush-259:0
            #   Those do the machine's writeback and flush work, none of them matches
            #   FABRIC_PREFIXES, and all of their CPU was being dropped -- silently, and by the
            #   line whose comment said it was catching pid reuse.
            #   🔑 Same shape as the mid-window hole this change exists to close: an identity
            #   check discarding CPU that is really there, with a comment describing a different
            #   and rarer case.  starttime is a strictly better identity -- a recycled pid is by
            #   construction a process that started later, so it cannot collide.
            if start_a != start_b:
                counts["excluded_pid_reused"] += 1
                continue
            delta = ticks_b - ticks_a

        named_ticks += delta
        cores = delta / CLK / elapsed
        by_comm[comm] = by_comm.get(comm, 0.0) + cores
        if _is_fabric(comm) or pid in proxy or pid == self_pid:
            mine_total += cores
            bucket = mine
        else:
            foreign_total += cores
            if midwindow:
                midwindow_foreign += cores
            bucket = foreign
        # 🔑 The floor is applied HERE and nowhere else.  Everything above has already been
        # summed, so a crowd of sub-floor processes still moves the total; it just does not each
        # earn a printed row.
        if cores > LIST_FLOOR:
            rec = dict(pid=pid, comm=comm, cores=round(cores, 3))
            if midwindow:
                rec["started"] = "mid-window"
            bucket.append(rec)

    # In the opening snapshot and gone from the closing one.  We hold a baseline and no final
    # reading, so their share of the window is not recoverable per process; it lands in the
    # residual below, and the count says how many mouths it came from.
    counts["excluded_vanished"] = len(a.keys() - b.keys())

    # 🔴 THE RESIDUAL.  All busy cores minus every core we could put a name to.  It is the only
    # term that sees a process which both started and ended inside the window, and it sees it
    # only in aggregate -- so it is a bound, not an attribution, and is never folded into
    # foreign_cores_attributable.  It runs slightly positive even on a clean machine (irq and
    # softirq time belongs to no process, and the snapshots do not open and close on the same
    # instant as the /proc/stat reads), which is why the suspect test below is a threshold and
    # not `> 0`.
    unattributed = (cpu_b - cpu_a - named_ticks) / CLK / elapsed

    foreign.sort(key=lambda r: -r["cores"])
    mine.sort(key=lambda r: -r["cores"])
    return dict(elapsed=elapsed, foreign=foreign, mine=mine, by_comm=by_comm,
                foreign_cores_attributable=round(foreign_total, 3),
                mine_cores_attributable=round(mine_total, 3),
                midwindow_foreign_cores=round(midwindow_foreign, 3),
                unattributed_cores=round(unattributed, 3), **counts)


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
    # The residual at or above which the reading is marked suspect.  Defaults to --threshold, so
    # by default the gate says "there is as much CPU here that I cannot name as there would have
    # to be, named, for me to call this contaminated".  That reuses the number PREREG already
    # registered instead of inventing a second one to argue about.
    #
    # 🔴 If a run is suspect and the response is to raise this, that is adjusting the instrument
    # to the answer -- the same move the baseline comment above refuses twice.  Raising it is a
    # registered decision with a reason, not a way to get a clean line.
    ap.add_argument("--suspect-residual", type=float, default=None,
                    help="unattributed cores at or above which the reading is SUSPECT "
                         "(default: the same value as --threshold)")
    a = ap.parse_args()

    try:
        m = measure(a.window, a.exempt_pid)
    except Exception as e:                                    # noqa: BLE001 -- see below
        # 🔴 An unreadable gate is NOT a green gate.  Exit 2, never 0: the one failure this gate
        # must not have is the one that mimics a pass.
        print(f"GATE {a.label} verdict=UNRUNNABLE err={e!r}")
        return 2

    elapsed, foreign, mine = m["elapsed"], m["foreign"], m["mine"]
    total = m["foreign_cores_attributable"]
    residual = m["unattributed_cores"]
    suspect_at = a.threshold if a.suspect_residual is None else a.suspect_residual
    excluded = m["excluded_vanished"] + m["excluded_no_baseline"] + m["excluded_pid_reused"]
    suspect = residual >= suspect_at
    # Named covariates come from the UNTRUNCATED per-comm sums, not from the printed rows: a
    # covariate that spends the window at 0.004 cores per process across eight processes is a
    # covariate at 0.032, and reading it off the listing would have called it zero.
    want = [c for c in a.covariate_comm.split(",") if c]
    covariates = {c: round(m["by_comm"].get(c, 0.0), 3) for c in want}
    provenance = dict(gate_version=GATE_VERSION)
    if PROCFS != "/proc":
        provenance["procfs"] = PROCFS

    def _unaccounted_line():
        return (f"     UNACCOUNTED-SHORT-LIVED unattributed_cores={residual} "
                f"(suspect at {suspect_at}) excluded_midwindow={m['midwindow_attributed']} "
                f"vanished={m['excluded_vanished']} no_baseline={m['excluded_no_baseline']} "
                f"pid_reused={m['excluded_pid_reused']}")

    if a.record_baseline:
        if not a.baseline_file:
            print("GATE baseline verdict=UNRUNNABLE err=--record-baseline needs --baseline-file")
            return 2
        with open(a.baseline_file, "w") as fh:
            fh.write(json.dumps(dict(baseline_cores=total, when=time.strftime("%FT%T"),
                                     window_s=round(elapsed, 2), covariates=covariates,
                                     unattributed_cores=residual,
                                     midwindow_attributed=m["midwindow_attributed"],
                                     excluded=excluded, attribution=foreign[:15],
                                     **provenance)) + "\n")
        print(f"GATE baseline recorded={total} cores -> {a.baseline_file}")
        print(_unaccounted_line())
        for r in foreign[:8]:
            print(f"     {r['comm']:<18} pid={r['pid']:>7} cores={r['cores']}")
        return 0

    baseline = 0.0
    if a.baseline_file:
        try:
            with open(a.baseline_file) as fh:
                bl = json.loads(fh.readline())
            baseline = float(bl["baseline_cores"])
        except Exception as e:                                # noqa: BLE001
            print(f"GATE {a.label} verdict=UNRUNNABLE err=baseline file unreadable: {e!r}")
            print("     Record it first:  cpu_gate.py --record-baseline --baseline-file <path>")
            print("     It is NOT defaulted to 0: that would make the gate permanently red, and")
            print("     defaulting it to anything else would make it permanently green.")
            return 2
        # 🔴 A BASELINE FROM ANOTHER VERSION IS NOT A BASELINE, IT IS AN OFFSET OF UNKNOWN SIGN.
        # excess = total - baseline only means anything when both sides were computed the same
        # way, and this version changed how the total is computed in two places (mid-window
        # processes enter it; the listing floor no longer removes anyone from it).  Comparing
        # them would quietly overstate the excess by however much those two populations weigh --
        # i.e. it would report contamination that is really a version difference.
        if bl.get("gate_version") != GATE_VERSION:
            print(f"GATE {a.label} verdict=UNRUNNABLE err=baseline recorded by "
                  f"{bl.get('gate_version', '<pre-versioning>')}, this gate is {GATE_VERSION}")
            print("     The two do not compute the total the same way, so their difference is")
            print("     not an excess.  Re-record the baseline with THIS binary:")
            print(f"     cpu_gate.py --record-baseline --baseline-file {a.baseline_file}")
            return 2

    excess = round(total - baseline, 3)
    verdict = "RED" if excess >= a.threshold else "GREEN"
    rec = dict(label=a.label, when=time.strftime("%FT%T"), window_s=round(elapsed, 2),
               foreign_cores_attributable=total, baseline_cores=baseline, excess_cores=excess,
               threshold=a.threshold, verdict=verdict, suspect=suspect,
               suspect_residual=suspect_at, unattributed_cores=residual,
               midwindow_attributed=m["midwindow_attributed"],
               midwindow_foreign_cores=m["midwindow_foreign_cores"],
               excluded_vanished=m["excluded_vanished"],
               excluded_no_baseline=m["excluded_no_baseline"],
               excluded_pid_reused=m["excluded_pid_reused"],
               covariates=covariates, foreign=foreign[:10], mine=mine[:10], **provenance)
    print(f"GATE {a.label} foreign_cores_attributable={total} baseline={baseline} "
          f"excess={excess} threshold={a.threshold} verdict={verdict} suspect={str(suspect).lower()}")
    print(_unaccounted_line())
    if suspect:
        print(f"🔴   SUSPECT: {residual} cores of this window belong to no process this gate could")
        print("     name.  verdict= above is the CPU it COULD name; it is not a claim about the")
        print("     rest.  Short-lived processes are invisible to a two-snapshot difference, so")
        print("     a green verdict beside this line does not mean the cell was quiet.")
    print("     covariates " + " ".join(f"{k}={v}" for k, v in covariates.items()))
    for r in foreign[:5]:
        print(f"     foreign  pid={r['pid']:>7} comm={r['comm']:<16} cores={r['cores']}"
              + ("  [started mid-window]" if r.get("started") else ""))
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
