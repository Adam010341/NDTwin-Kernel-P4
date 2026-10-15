#!/usr/bin/env bash
# stopmask_mutants.sh <head> : the cells suite against each stops_held mutant applied by hand (C2R9-4a = C2R7-1n's edit,
# C2R7-1o, C2R7-1r), to see that the suite still runs to its `Ran N tests` line and which tests go red, with tracebacks.
# Not the gate. [Co-developed with claude code -- Adam]
H="$1"; S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/p4hl2
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-locale/r2
export TMPDIR=$S/tmp
for m in 4a 1o 1r; do
    cd / && bash "$L/mkclone.sh" "$S/red" "$H" > /dev/null || exit 2; cd "$S/red" || exit 2
    M="$m" p4_proxy/venv/bin/python - tools/p4_health/s0.py <<'PY' || exit 2
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
edits = {
    "4a": ("        signal.pthread_sigmask(signal.SIG_SETMASK, held)", "        pass  # MUTANT"),
    "1o": ("    try:\n        yield\n    finally:\n        signal.pthread_sigmask(signal.SIG_SETMASK, held)",
           "    yield  # MUTANT\n    signal.pthread_sigmask(signal.SIG_SETMASK, held)"),
    "1r": ("    try:\n        yield\n    finally:\n        signal.pthread_sigmask(signal.SIG_SETMASK, held)",
           "    try:\n        yield\n    finally:\n        for sig in STOP_SIGNALS:  # MUTANT\n            signal.sigtimedwait([sig], 0)\n"
           "        signal.pthread_sigmask(signal.SIG_SETMASK, held)"),
}
a, r = edits[os.environ["M"]]
assert s.count(a) == 1
p.write_text(s.replace(a, r, 1))
PY
    NOTE="stops_held mutant $m (as in the gate's table: C2R9-4a / C2R7-1o / C2R7-1r) applied by hand to s0.py; the cells suite" \
        bash "$L/runlog.sh" "$L/stops_held_mutant_$m.cells.log" p4_proxy/venv/bin/python tests/python/test_p4_health_cells.py
done
cd / && bash "$L/mkclone.sh" "$S/red" "$H" > /dev/null && rm -rf "$S/red"
