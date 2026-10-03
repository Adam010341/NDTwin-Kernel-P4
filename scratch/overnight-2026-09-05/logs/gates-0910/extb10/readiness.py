#!/usr/bin/env python3
"""readiness.py <external_evidence.py> -- the compare stages that never ran on live data, on 10-02's C1, C2, T and
H5, each called directly with its exceptions caught. Prints, per stage and run: stage, run, ok or FAIL, and on a
FAIL only the Unreadable/Refused reason (or the exception's type for anything else).

Called (external_evidence.py at 75b5dd0e): settled() on every arm of C1, C2, T, over the same evidence arms()
builds (table_rows, controller_log, controller_evidence, report_evidence); arms() for C1, C2, T (it runs
settled() again and sets each arm's window); programs_same() over the three; read_samples() and t06_end() on
H5's samples; check_roles() with C1, C2 as controls and T as the treatment (session_evidence, push_offset,
heard_evidence inside it). Its return value is never printed: only whether each arm's heard window was decided.
NOT called: identities(), compare(), invariants(), within(), show(), header(), fingerprint(), fmt(), main() --
no decisive field is compared, printed or kept, and no verdict is formed.
[Co-developed with claude code -- Adam]"""
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
tool = sys.argv[1]
sys.path.insert(0, os.path.dirname(tool))
spec = importlib.util.spec_from_file_location("ee_under_test", tool)
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

RUNS = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs"
RUN = {"C1": f"{RUNS}/2026-10-02T111831Z_06_thirteen", "C2": f"{RUNS}/2026-10-02T114559Z_06_thirteen",
       "T": f"{RUNS}/2026-10-02T121504Z_06_thirteen"}
H5 = f"{RUNS}/2026-10-02T121502Z_08_heartbeat"
fails = 0


def line(stage, run, err=None):
    global fails
    if err is None:
        print(f"{stage}\t{run}\tok")
        return
    fails += 1
    if isinstance(err, (ev.Unreadable, ev.Refused)):
        why = f"{type(err).__name__}: {err}"
    else:
        why = f"{type(err).__name__} (not a reader verdict; message withheld)"
    print(f"{stage}\t{run}\tFAIL\t{why}")


def attempt(stage, run, fn):
    try:
        out = fn()
    except Exception as exc:  # noqa: BLE001 -- every failure is a line, never a traceback
        line(stage, run, exc)
        return None
    line(stage, run)
    return out


# settled() on every arm, over the evidence arms() builds
for label, run in RUN.items():
    for arm in ev.EXTERNAL_ARMS:
        def one(run=run, arm=arm):
            row = ev.table_rows(run).get(arm)
            if row is None:
                raise ev.Unreadable(f"{run}: no {arm[0]}/{arm[1]} row in 00_table.tsv")
            e = dict(row, **ev.controller_evidence(ev.controller_log(row["report"])),
                     **ev.report_evidence(row["report"]))
            ev.settled(arm, e)
        attempt(f"settled {arm[0]}/{arm[1]}", label, one)

evs = {label: attempt("arms", label, lambda run=run: ev.arms(run)) for label, run in RUN.items()}
if all(evs.values()):
    attempt("programs_same", "C1,C2,T",
            lambda: ev.programs_same([("control", evs["C1"]), ("control2 #1", evs["C2"]), ("treatment", evs["T"])]))
samples_path = os.path.join(H5, "50_samples.tsv")
samples = attempt("read_samples", "H5", lambda: ev.read_samples(samples_path))
end_06 = attempt("t06_end", "H5", lambda: ev.t06_end(samples_path))
if samples is not None and end_06 is not None and all(evs.values()):
    roles = attempt("check_roles (controls C1,C2; treatment T; heard window)", "C1,C2,T,H5",
                    lambda: ev.check_roles([("control", evs["C1"]), ("control2 #1", evs["C2"])], evs["T"],
                                           samples, end_06))
    if roles is not None:
        for arm in ev.EXTERNAL_ARMS:
            und = roles[arm]["heard"]["undecided"]
            # only whether the window could decide; the session's counters and heard counts are not printed
            print(f"heard window {arm[0]}/{arm[1]}\tT,H5\t{'ok' if not und else 'FAIL'}"
                  + (f"\tUNDECIDED: {und}" if und else ""))
            fails += bool(und)
print(f"readiness: {fails} FAIL")
sys.exit(1 if fails else 0)
