#!/usr/bin/env bash
# redruns.sh : the seen-red runs of round 9's test changes, each in a throwaway clone of HEAD=$1 with ONE thing put
# back as it was (named on each log's note line). Not the gate. [Co-developed with claude code -- Adam]
H="$1"
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/p4hl2
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-locale/r2
export TMPDIR=$S/tmp
PY=p4_proxy/venv/bin/python
fresh() { cd / && bash "$L/mkclone.sh" "$S/red" "$H" > /dev/null || exit 2; cd "$S/red" || exit 2; }

# minor-1: the venv test against the gate script of a741e763 (no sys.prefix on the line)
# (the gate finds the checkout two levels above its own directory, so the old copy sits in tests/oldgate)
fresh; mkdir -p "$S/red/tests/oldgate"; git show a741e763:tests/shell/mutate_p4_health.sh > tests/oldgate/mutate_p4_health.sh
cp tests/shell/sum_p4_health_gate_shards.sh tests/shell/test_p4_health_gate_scripts.sh tests/oldgate/
NOTE="gate_scripts test of HEAD run against a741e763's mutate_p4_health.sh (P4_HEALTH_GATE_UNDER_TEST=tests/oldgate)" \
    P4_HEALTH_GATE_UNDER_TEST="$S/red/tests/oldgate" bash "$L/runlog.sh" "$L/venv_prefix_red_on_old_gate.log" bash tests/shell/test_p4_health_gate_scripts.sh

# minor-6: cells started by a parent with SIGHUP blocked: a741e763's cells test, then HEAD's
HUP=(-c 'import os, signal, sys; signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGHUP]); os.execv(sys.argv[1], sys.argv[1:])')
fresh; git show a741e763:tests/python/test_p4_health_cells.py > tests/python/test_p4_health_cells.py
NOTE="tests/python/test_p4_health_cells.py of a741e763, started by a parent with SIGHUP blocked (mask kept across exec)" \
    bash "$L/runlog.sh" "$L/sighup_blocked_parent_cells_a741e763.log" "$PY" "${HUP[@]}" "$PY" tests/python/test_p4_health_cells.py
fresh
NOTE="HEAD's cells suite, started by a parent with SIGHUP blocked (mask kept across exec)" \
    bash "$L/runlog.sh" "$L/sighup_blocked_parent_cells_head.log" "$PY" "${HUP[@]}" "$PY" tests/python/test_p4_health_cells.py

# minor-5: the T8 tsv test against c24a7d19's expected_today.tsv
fresh; git show c24a7d19:doc/audit/2026-10-03_p4-health-check/expected_today.tsv > doc/audit/2026-10-03_p4-health-check/expected_today.tsv
NOTE="doc/audit/2026-10-03_p4-health-check/expected_today.tsv of c24a7d19 (before the snapshot clause)" \
    bash "$L/runlog.sh" "$L/t8_tsv_red_on_c24a7d19_tsv.log" "$PY" tests/python/test_p4_health_cells.py -k test_the_t8_row_of_the_predictions

# minor-3: run_lab's handler test with C2R8-3c applied and a stray thread that can take a stop
STRAY=(-c 'import runpy, sys, threading; t = threading.Thread(target=threading.Event().wait, args=(120,), daemon=True); t.start(); sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")')
apply3c() { "$PY" - tools/p4_health/lab.py <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a = "            if old_handlers is not None:\n                for sig, h in old_handlers.items():"
assert s.count(a) == 1
p.write_text(s.replace(a, "            if False:  # MUTANT C2R8-3c\n                for sig, h in old_handlers.items():", 1))
PY
}
fresh; apply3c; git show a741e763:tests/python/test_p4_health_collect.py > tests/python/test_p4_health_collect.py
NOTE="C2R8-3c applied to lab.py; collect test of a741e763; a thread that does not block the stops started first" \
    bash "$L/runlog.sh" "$L/handlers_test_old_with_stray_thread_and_3c.log" "$PY" "${STRAY[@]}" tests/python/test_p4_health_collect.py -k test_run_lab_puts_the_handlers_it_found_back_when_it_ends
fresh; apply3c
NOTE="C2R8-3c applied to lab.py; HEAD's collect test; a thread that does not block the stops started first" \
    bash "$L/runlog.sh" "$L/handlers_test_head_with_stray_thread_and_3c.log" "$PY" "${STRAY[@]}" tests/python/test_p4_health_collect.py -k test_run_lab_puts_the_handlers_it_found_back_when_it_ends
fresh; apply3c
NOTE="C2R8-3c applied to lab.py; HEAD's collect test; no stray thread" \
    bash "$L/runlog.sh" "$L/handlers_test_head_with_3c.log" "$PY" tests/python/test_p4_health_collect.py -k test_run_lab_puts_the_handlers_it_found_back_when_it_ends
cd /; bash "$L/mkclone.sh" "$S/red" "$H" > /dev/null && rm -rf "$S/red"
