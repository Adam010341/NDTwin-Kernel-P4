#!/usr/bin/env python3
"""
Tests for cpu_gate.py's lifetime accounting -- the 2026-09-01 change that stopped a window full of
short-lived processes from reading identical to a quiet one.

[Co-developed with claude code -- Adam]

## What was wrong, and why it could not be tested before

The gate differences two /proc snapshots.  Until 09-01 the loop skipped every pid that was not in
BOTH -- `if pid not in a: continue` -- so a process that started inside the window contributed
exactly 0 cores and was counted nowhere.  A cell contaminated entirely by short-lived processes
(a build's thousands of cc1, a loop of qemu-img, a busy shell script) therefore produced the same
reading as an idle machine.  Measured on this machine 2026-09-01 with 648 short-lived children
burning ~3.6 cores: the old gate reported excess 0.007 cores and said GREEN.

Three defects were closed together, and each has its own case below:
    (1) mid-window processes charged at zero        -> attributed in full via starttime
    (2) the 0.005 floor filtered before summing     -> it is a LISTING floor now, not a counting one
    (3) identity was (pid, comm)                    -> it is (pid, starttime); comm is a label the
                                                       kernel rewrites while the process runs

## Why fixture procfs trees rather than real processes

There is no way to *write down* "a process that started mid-window" against the real /proc: it
depends on the ordering of two reads separated by a sleep, and reproducing that with real
processes makes the test a race.  So `measure()` takes `sleeper` and `clock` as arguments, and the
sleeper here does not sleep -- it swaps `cg.PROCFS` from the opening tree to the closing tree.
Every lifetime case then becomes a pair of directory listings, which is exactly the input the
differencing logic actually consumes.

🔑 The seam is not free, and the gate knows it: whenever PROCFS is not /proc the JSON record
carries a `procfs` key, so a green produced against a fabricated tree can never be mistaken for a
green produced against a machine.  That property is itself a case here (test_procfs_seam_...).

## Where the fixtures could lie, and what stops them

A fixture that builds /proc/<pid>/stat by the same (wrong) field arithmetic the parser uses would
agree with it perfectly and prove nothing.  `test_starttime_field_index_against_real_proc` closes
that: it reads the REAL /proc for this very process and checks the value lands in the only window
field 22 can occupy -- after boot, before now, and within minutes of /proc/uptime, because the
test process was started by the test run.  Field 21 (itrealvalue) is 0 and field 23 (vsize) is
astronomically larger, so an off-by-one in either direction fails it.

Run:      python3 tests/python/test_cpu_gate_lifetime.py -v
Mutants:  bash tests/shell/mutate_cpu_gate_lifetime.sh
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

GATE_PATH = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..",
    "doc", "audit", "2026-08-31_sampling-ceiling-after-merge", "cpu_gate.py"))


def _load_gate():
    """Import the shipped file by path.

    It lives under a directory whose name starts with a digit and contains hyphens, so it is not
    importable as a module; and copying it here would test a copy.  An edit to cpu_gate.py is an
    edit this file sees.
    """
    spec = importlib.util.spec_from_file_location("cpu_gate_under_test", GATE_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cg = _load_gate()


# --------------------------------------------------------------------------------------------
# fixture procfs trees
# --------------------------------------------------------------------------------------------

def _stat_line(pid, comm, ticks, start_ticks):
    """One /proc/<pid>/stat line.

    proc(5) numbers fields from 1 and the parser splits after the closing paren, so index i of
    what it splits is field i+3:
        field 14 utime      -> index 11
        field 15 stime      -> index 12
        field 22 starttime  -> index 19
    `ticks` is split across utime AND stime on purpose: a parser that reads only one of the two
    halves the answer, and every core assertion below would catch it.
    """
    utime = ticks // 2
    stime = ticks - utime
    fields = (["S"] + ["0"] * 10 + [str(utime), str(stime)] + ["0"] * 6 + [str(start_ticks)])
    assert len(fields) == 20, fields
    return f"{pid} ({comm}) " + " ".join(fields) + "\n"


class TreeBuilder:
    """Builds a directory that `measure()` can be pointed at instead of /proc."""

    def __init__(self, case):
        self.case = case
        self.root = tempfile.mkdtemp(prefix="cpu_gate_procfs_")
        case.addCleanup(shutil.rmtree, self.root, True)
        # net/tcp is deliberately absent: _proxy_pids() then finds no inodes and returns early,
        # so no fixture process is accidentally exempted as "the proxy".
        self.procs = []
        self.uptime = 1000.0
        self.busy = "cpu 1000 0 0 5000 0 0 0 0 0 0"

    def proc(self, pid, comm, ticks, start_s):
        # A fixture pid equal to the test runner's own pid would be classified as `mine` by
        # measure()'s `pid == self_pid` branch, silently emptying the foreign bucket.
        assert pid != os.getpid(), f"fixture pid {pid} collides with the test runner"
        self.procs.append((pid, comm, ticks, int(start_s * cg.CLK)))
        return self

    def cpu(self, user=1000, nice=0, system=0, idle=5000, iowait=0, irq=0, softirq=0):
        self.busy = f"cpu {user} {nice} {system} {idle} {iowait} {irq} {softirq} 0 0 0"
        return self

    def build(self):
        with open(os.path.join(self.root, "uptime"), "w") as fh:
            fh.write(f"{self.uptime} {self.uptime}\n")
        with open(os.path.join(self.root, "stat"), "w") as fh:
            fh.write(self.busy + "\nintr 0 0\nbtime 1700000000\n")
        for pid, comm, ticks, start in self.procs:
            d = os.path.join(self.root, str(pid))
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "stat"), "w") as fh:
                fh.write(_stat_line(pid, comm, ticks, start))
        return self.root


class LifetimeCase(unittest.TestCase):
    """Base: two trees, an injected clock, and a sleeper that swaps between them."""

    ELAPSED = 10.0

    def setUp(self):
        self.addCleanup(setattr, cg, "PROCFS", cg.PROCFS)
        # The disown control turns _is_fabric() into `return False` for everything.  If it leaked
        # in from the ambient environment, every fabric case below would read as foreign and the
        # classification tests would be testing the control instead of the allow list.
        disown = os.environ.pop("FORCE_CPU_GATE_DISOWN_FABRIC", None)
        if disown is not None:
            self.addCleanup(os.environ.__setitem__, "FORCE_CPU_GATE_DISOWN_FABRIC", disown)
        self.a = TreeBuilder(self)
        self.b = TreeBuilder(self)

    def run_measure(self, elapsed=None, exempt=()):
        elapsed = self.ELAPSED if elapsed is None else elapsed
        tree_a, tree_b = self.a.build(), self.b.build()
        cg.PROCFS = tree_a
        ticks = iter([0.0, elapsed])
        return cg.measure(0.0, list(exempt),
                          sleeper=lambda _w: setattr(cg, "PROCFS", tree_b),
                          clock=lambda: next(ticks))

    def cores(self, ticks, elapsed=None):
        return round(ticks / cg.CLK / (self.ELAPSED if elapsed is None else elapsed), 3)


# --------------------------------------------------------------------------------------------
# (1) mid-window processes
# --------------------------------------------------------------------------------------------

class MidWindowAttribution(LifetimeCase):

    def test_midwindow_process_is_attributed_in_full(self):
        """The headline defect.  Absent when the window opened, alive when it closed, started
        after the opening uptime -- so every tick it holds was burned inside this window."""
        self.a.proc(900001, "steady", 100, 500.0)
        self.b.proc(900001, "steady", 100, 500.0)
        self.b.proc(900002, "cc1plus", 400, 1005.0)     # started 5s after the window opened

        m = self.run_measure()

        self.assertEqual(m["midwindow_attributed"], 1)
        self.assertEqual(m["foreign_cores_attributable"], self.cores(400))
        self.assertEqual(m["midwindow_foreign_cores"], self.cores(400))
        row = [r for r in m["foreign"] if r["pid"] == 900002]
        self.assertEqual(len(row), 1, m["foreign"])
        self.assertEqual(row[0]["started"], "mid-window",
                         "a row the reader cannot tell apart from a long-lived one hides the "
                         "fact that its whole lifetime was charged here")

    def test_midwindow_fabric_is_ours_not_foreign(self):
        """Charging mid-window CPU is only safe if the allow list still applies to it.  A gate
        that counted every freshly-spawned mnexec as contamination would go red on its own
        fabric -- the exact failure that killed the third round's gate."""
        self.b.proc(900010, "simple_switch_g", 900, 1002.0)

        m = self.run_measure()

        self.assertEqual(m["midwindow_attributed"], 1)
        self.assertEqual(m["foreign_cores_attributable"], 0.0)
        self.assertEqual(m["midwindow_foreign_cores"], 0.0)
        self.assertEqual(m["mine_cores_attributable"], self.cores(900))

    def test_process_older_than_the_window_without_a_baseline_is_counted_not_dropped(self):
        """Alive now, older than the window, missing from the opening snapshot -- that read
        failed.  It genuinely cannot be attributed, and the point of the change is that it is
        COUNTED anyway: a skipped process must never print the same as no process."""
        self.b.proc(900020, "unreadable", 999, 300.0)   # started long before uptime 1000

        m = self.run_measure()

        self.assertEqual(m["excluded_no_baseline"], 1)
        self.assertEqual(m["midwindow_attributed"], 0)
        self.assertEqual(m["foreign_cores_attributable"], 0.0)

    def test_vanished_process_is_counted(self):
        """In the opening snapshot, gone from the closing one: a baseline and no final reading.
        Not recoverable per-process, but the count says how many mouths the residual came from."""
        self.a.proc(900030, "short_lived", 50, 900.0)

        m = self.run_measure()

        self.assertEqual(m["excluded_vanished"], 1)
        self.assertEqual(m["foreign_cores_attributable"], 0.0)


# --------------------------------------------------------------------------------------------
# (3) identity is (pid, starttime)
# --------------------------------------------------------------------------------------------

class ProcessIdentity(LifetimeCase):

    def test_kworker_rename_is_not_a_pid_reuse(self):
        """The pre-existing defect found while validating the fix.  The kernel rewrites a
        kworker's comm to name the workqueue it is currently servicing; the old identity check
        read that as pid reuse and discarded the CPU.  Measured 2026-09-01 over one 8s window on
        this machine: 12 comm changes, 0 starttime changes, all of them kworkers."""
        self.a.proc(900040, "kworker/2:1H-i915_cleanup", 100, 100.0)
        self.b.proc(900040, "kworker/2:1H-events_highpri", 340, 100.0)

        m = self.run_measure()

        self.assertEqual(m["excluded_pid_reused"], 0,
                         "a renamed kworker is the same process, and its CPU is real")
        self.assertEqual(m["foreign_cores_attributable"], self.cores(240))

    def test_genuine_pid_reuse_is_still_excluded(self):
        """The case the old check *claimed* to be for.  A recycled pid is by construction a
        process that started later, so starttime separates it -- without also throwing away every
        renamed kworker."""
        self.a.proc(900050, "victim", 100, 100.0)
        self.b.proc(900050, "victim", 100000, 990.0)    # same comm, different life

        m = self.run_measure()

        self.assertEqual(m["excluded_pid_reused"], 1)
        self.assertEqual(m["foreign_cores_attributable"], 0.0)

    def test_starttime_field_index_against_real_proc(self):
        """Guards the fixtures themselves.  Everything above would agree with a parser that read
        the wrong field, because the fixture writes the field the parser reads.  This reads the
        REAL /proc for this process: field 22 must be after boot, at or before now, and -- since
        the test runner was started by this test run -- within minutes of /proc/uptime.  Field 21
        is always 0 and field 23 (vsize) is orders of magnitude larger, so either off-by-one
        fails."""
        cg.PROCFS = "/proc"
        comm, ticks, start = cg._read(os.getpid())

        self.assertIn("python", comm.lower())
        self.assertGreater(ticks, 0, "this process has burned CPU getting here")
        up = cg._uptime()
        age = up - start / cg.CLK
        self.assertGreater(start, 0, "field 21 (itrealvalue) is 0; reading it would land here")
        self.assertLessEqual(start / cg.CLK, up, "nothing starts before boot")
        self.assertLess(age, 600.0,
                        f"the test process is {age:.0f}s old by this field; field 23 (vsize) "
                        f"would make it absurdly negative and field 21 absurdly positive")

    def test_comm_containing_spaces_and_parens_parses(self):
        """The classic /proc/<pid>/stat bug is splitting on whitespace.  comm is arbitrary bytes
        between the first '(' and the LAST ')'."""
        self.a.proc(900060, "weird (proc) name", 10, 100.0)
        self.b.proc(900060, "weird (proc) name", 210, 100.0)

        m = self.run_measure()

        self.assertEqual(m["excluded_pid_reused"], 0)
        self.assertEqual(m["by_comm"], {"weird (proc) name": self.cores(200)})


# --------------------------------------------------------------------------------------------
# (2) the floor lists, it does not count
# --------------------------------------------------------------------------------------------

class ListingFloor(LifetimeCase):

    def test_sub_floor_processes_count_toward_the_total_without_being_listed(self):
        """Hole (2).  0.005 used to `continue`, so a hundred processes at 0.004 cores summed to
        0.4 cores of contamination the total never saw -- which is most of an 0.5-core
        threshold."""
        per = 4                                          # ticks -> 0.004 cores at CLK=100, 10s
        for i in range(100):
            pid = 901000 + i
            self.a.proc(pid, "sub_floor_hog", 0, 100.0)
            self.b.proc(pid, "sub_floor_hog", per, 100.0)

        m = self.run_measure()

        self.assertEqual(m["foreign_cores_attributable"], self.cores(per * 100))
        self.assertGreater(m["foreign_cores_attributable"], 0.3,
                           "the crowd has to move the total or the fixture is not exercising it")
        self.assertEqual(m["foreign"], [],
                         "sub-floor processes still must not each earn a printed row")


# --------------------------------------------------------------------------------------------
# the residual
# --------------------------------------------------------------------------------------------

class Residual(LifetimeCase):

    def test_residual_is_system_busy_minus_everything_named(self):
        """The only term that sees a process which both started and ended inside the window.
        irq and softirq are in it (they are work being done); idle, iowait and steal are not."""
        self.a.cpu(user=1000, idle=5000)                                  # busy_a = 1000
        self.b.cpu(user=2000, system=300, idle=5000, irq=500, softirq=700)  # busy_b = 3500
        self.a.proc(900070, "named", 100, 100.0)
        self.b.proc(900070, "named", 500, 100.0)                          # named delta = 400

        m = self.run_measure()

        self.assertEqual(m["foreign_cores_attributable"], self.cores(400))
        self.assertEqual(m["unattributed_cores"], self.cores(2500 - 400))

    def test_zero_length_window_is_refused_rather_than_divided_by(self):
        """Every core figure is a rate over this number.  A zero-length window does not produce a
        small reading, it produces a meaningless one -- main() turns this into exit 2."""
        self.a.proc(900080, "x", 1, 100.0)
        self.b.proc(900080, "x", 2, 100.0)

        with self.assertRaises(ValueError) as cm:
            self.run_measure(elapsed=0.0)
        self.assertIn("rate", str(cm.exception))


# --------------------------------------------------------------------------------------------
# main(): reporting, suspect, and the version guard
# --------------------------------------------------------------------------------------------

def _canned(**over):
    """A measure() result with nothing wrong with it, so each case below changes one thing."""
    m = dict(elapsed=10.0, foreign=[], mine=[], by_comm={},
             foreign_cores_attributable=0.10, mine_cores_attributable=0.20,
             midwindow_foreign_cores=0.0, unattributed_cores=0.01,
             midwindow_attributed=0, excluded_no_baseline=0,
             excluded_pid_reused=0, excluded_vanished=0)
    m.update(over)
    return m


class GateReporting(unittest.TestCase):

    def setUp(self):
        self.addCleanup(setattr, cg, "measure", cg.measure)
        self.addCleanup(setattr, cg, "PROCFS", cg.PROCFS)
        self.addCleanup(setattr, sys, "argv", sys.argv)
        self.tmp = tempfile.mkdtemp(prefix="cpu_gate_main_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def call_main(self, argv, result=None, **over):
        cg.measure = lambda *a, **k: _canned(**over) if result is None else result
        sys.argv = ["cpu_gate.py"] + argv
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cg.main()
        return rc, buf.getvalue()

    def path(self, name):
        return os.path.join(self.tmp, name)

    def read_record(self, name):
        with open(self.path(name)) as fh:
            return json.loads(fh.readlines()[-1])

    def test_unaccounted_line_prints_even_when_there_is_nothing_to_report(self):
        """A skipped process must never print the same as no process -- which means the line
        cannot be conditional on the numbers being interesting, or its absence would carry
        information nobody reads."""
        rc, out = self.call_main(["--label", "quiet"],
                                 unattributed_cores=0.0, excluded_vanished=0)

        self.assertEqual(rc, 0)
        self.assertIn("UNACCOUNTED-SHORT-LIVED", out)
        self.assertIn("unattributed_cores=0.0", out)
        self.assertIn("vanished=0", out)

    def test_suspect_fires_while_the_verdict_stays_green(self):
        """Not a contradiction: the verdict is about the CPU the gate could NAME.  This is the
        shape of the 09-01 acceptance run -- 3.6 cores of short-lived churn, GREEN, suspect."""
        rc, out = self.call_main(["--label", "churn", "--out", self.path("rec.jsonl")],
                                 foreign_cores_attributable=0.007,
                                 unattributed_cores=3.635, midwindow_attributed=41)

        self.assertEqual(rc, 0, "the named CPU is under threshold, so the exit code is GREEN")
        self.assertIn("verdict=GREEN", out)
        self.assertIn("suspect=true", out)
        self.assertIn("SUSPECT", out)
        rec = self.read_record("rec.jsonl")
        self.assertTrue(rec["suspect"])
        self.assertEqual(rec["verdict"], "GREEN")
        self.assertEqual(rec["unattributed_cores"], 3.635)

    def test_suspect_stays_false_below_the_residual_threshold(self):
        """The other half of the same switch: without this, `suspect = True` would pass the case
        above and the field would carry no information."""
        rc, out = self.call_main(["--label", "clean", "--suspect-residual", "0.5"],
                                 unattributed_cores=0.02)

        self.assertEqual(rc, 0)
        self.assertIn("suspect=false", out)
        self.assertNotIn("SUSPECT", out)

    def test_record_reports_attributable_and_no_longer_the_bare_total(self):
        """The rename is load-bearing.  A caller still reading `foreign_cores` must break loudly
        rather than read a key that quietly means something else now."""
        rc, out = self.call_main(["--label", "n", "--out", self.path("rec.jsonl")],
                                 foreign_cores_attributable=0.42)

        self.assertEqual(rc, 0)
        rec = self.read_record("rec.jsonl")
        self.assertEqual(rec["foreign_cores_attributable"], 0.42)
        self.assertNotIn("foreign_cores", rec)
        self.assertIn("foreign_cores_attributable=0.42", out)

    def test_covariates_come_from_the_untruncated_sums_not_the_printed_rows(self):
        """Eight processes at 0.004 cores are a covariate at 0.032 and none of them is listed.
        Reading covariates off the listing would call that zero."""
        rc, _ = self.call_main(
            ["--label", "cov", "--covariate-comm", "gnome-shell", "--out", self.path("r.jsonl")],
            foreign=[], by_comm={"gnome-shell": 0.032})

        self.assertEqual(rc, 0)
        self.assertEqual(self.read_record("r.jsonl")["covariates"], {"gnome-shell": 0.032})

    def test_procfs_seam_is_recorded_whenever_it_is_not_proc(self):
        """A green produced against a fabricated /proc must never be readable as a green produced
        against a machine."""
        rc, _ = self.call_main(["--label", "real", "--out", self.path("real.jsonl")])
        self.assertEqual(rc, 0)
        self.assertNotIn("procfs", self.read_record("real.jsonl"))

        cg.PROCFS = "/tmp/fabricated"
        rc, _ = self.call_main(["--label", "fake", "--out", self.path("fake.jsonl")])
        self.assertEqual(rc, 0)
        self.assertEqual(self.read_record("fake.jsonl")["procfs"], "/tmp/fabricated")

    def test_baseline_recorded_by_this_version_is_accepted(self):
        """The accept path.  Without it, a guard that refused EVERY baseline would pass both
        refusal cases below and leave the gate permanently unrunnable."""
        bl = self.path("bl.json")
        rc, _ = self.call_main(["--record-baseline", "--baseline-file", bl],
                               foreign_cores_attributable=0.30)
        self.assertEqual(rc, 0)

        rc, out = self.call_main(["--label", "run", "--baseline-file", bl],
                                 foreign_cores_attributable=0.35)

        self.assertEqual(rc, 0, out)
        self.assertIn("baseline=0.3", out)
        self.assertIn("excess=0.05", out)
        self.assertNotIn("UNRUNNABLE", out)

    def test_baseline_from_another_gate_version_is_refused(self):
        """excess = total - baseline only means anything when both sides were computed the same
        way.  This version added mid-window processes to the total and stopped truncating it at
        the floor, so a cross-version difference is a version artefact reported as
        contamination."""
        bl = self.path("old.json")
        with open(bl, "w") as fh:
            fh.write(json.dumps(dict(baseline_cores=0.30, gate_version="2026-08-31.something"))
                     + "\n")

        rc, out = self.call_main(["--label", "run", "--baseline-file", bl])

        self.assertEqual(rc, 2, "not green and not red: the gate could not run")
        self.assertIn("UNRUNNABLE", out)
        self.assertIn("2026-08-31.something", out)

    def test_baseline_from_before_versioning_is_refused_and_says_so(self):
        """The baselines that already exist on disk have no version key at all.  Treating a
        missing key as "probably fine" is how the version stamp would end up decorative."""
        bl = self.path("prev.json")
        with open(bl, "w") as fh:
            fh.write(json.dumps(dict(baseline_cores=0.30)) + "\n")

        rc, out = self.call_main(["--label", "run", "--baseline-file", bl])

        self.assertEqual(rc, 2)
        self.assertIn("<pre-versioning>", out)

    def test_unrunnable_measure_exits_two_not_zero(self):
        """The one failure this gate must not have is the one that mimics a pass."""
        def boom(*a, **k):
            raise ValueError("window measured 0.0s of elapsed time")

        cg.measure = boom
        sys.argv = ["cpu_gate.py", "--label", "boom"]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cg.main()

        self.assertEqual(rc, 2)
        self.assertIn("verdict=UNRUNNABLE", buf.getvalue())


# --------------------------------------------------------------------------------------------
# the real CLI, against the real /proc
# --------------------------------------------------------------------------------------------

class RealCliSmoke(unittest.TestCase):
    """Everything above runs in-process against fabricated trees.  This runs the file the round
    actually invokes, against this machine, and takes the record-then-read path end to end --
    because "the module's functions behave" and "the command works" have been different answers
    here before."""

    def test_record_baseline_then_gate_on_it(self):
        tmp = tempfile.mkdtemp(prefix="cpu_gate_cli_")
        self.addCleanup(shutil.rmtree, tmp, True)
        bl = os.path.join(tmp, "bl.json")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        env.pop("FORCE_CPU_GATE_DISOWN_FABRIC", None)

        rec = subprocess.run(
            [sys.executable, GATE_PATH, "--record-baseline", "--baseline-file", bl,
             "--window", "0.3"],
            capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(rec.returncode, 0, rec.stdout + rec.stderr)
        self.assertIn("UNACCOUNTED-SHORT-LIVED", rec.stdout)
        with open(bl) as fh:
            written = json.loads(fh.readline())
        self.assertEqual(written["gate_version"], cg.GATE_VERSION)

        run = subprocess.run(
            [sys.executable, GATE_PATH, "--label", "smoke", "--baseline-file", bl,
             "--window", "0.3"],
            capture_output=True, text=True, env=env, timeout=120)

        self.assertIn(run.returncode, (0, 1),
                      f"2 means the gate could not run:\n{run.stdout}{run.stderr}")
        self.assertRegex(run.stdout, r"GATE smoke foreign_cores_attributable=[0-9.]+")
        self.assertIn("UNACCOUNTED-SHORT-LIVED", run.stdout)
        self.assertNotIn("UNRUNNABLE", run.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
