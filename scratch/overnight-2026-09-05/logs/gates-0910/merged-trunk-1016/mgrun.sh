#!/usr/bin/env bash
# mgrun.sh <stage>... (C D) : the merged-head gate for merge/trunk-1016 (M5'), in the gate clone, every step behind the shared lock,
# guard.sh and mexec.sh (signal-mask exec wrapper), its verdict from the last line of its own log. Stage C = the 10-15 step list
# (Stage B of 10-15 dropped) + three additions, Stage D = the four-shard health gate (chain_mut.sh).
# A step that exceeds its cap is stopped by its SESSION (pid list from ps -s), recorded, and the next step goes on.
# [Co-developed with claude code -- Adam]
E=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1016
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/mg16
CI=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/pr-cut2
C=$S/gate; D=$E/mgrun.log
M5=cc0bca4bde02d6611935508ae49a3d3790d6ffbe
LOCK=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/heavy-step.lock
export TMPDIR=$S/tmp
mkdir -p "$TMPDIR"
cd "$C" || { echo "STOPPED: no clone at $C" > "$E/STOPPED"; exit 2; }
PY=p4_proxy/venv/bin/python
PY38=/home/adam/miniconda3/envs/ryu-env/bin/python
PY312=/usr/bin/python3.12
RL=$E/runlog.sh
CAP=1800
echo "$(date -Is) mgrun start pid $$ stages: $* ; clone HEAD $(git rev-parse HEAD); LANG=${LANG:-} LC_ALL=${LC_ALL:-}; PYTHON=${PYTHON:-unset}" >> "$D"
[[ "$(git rev-parse HEAD)" == "$M5" ]] || { echo "STOPPED: clone HEAD is not M5'" > "$E/STOPPED"; exit 2; }
stop() { echo "$*" > "$E/STOPPED"; echo "$(date -Is) STOPPED: $*" >> "$D"; exit 2; }
take_lock() {   # $1 = step name : the shared lock on fd 9 of this shell (never flock <cmd>: guard.sh scans argv), then :8081 empty
    local name="$1" t0 n=0
    t0=$(date +%s)
    exec 9>>"$LOCK"
    echo "$(date -Is) [$name] lock wait begin" >> "$D"
    flock 9
    echo "$(date -Is) [$name] lock acquired after $(( $(date +%s) - t0 )) s" >> "$D"
    while ss -ltn | awk '{print $4}' | grep -qE '[:.]8081$'; do
        n=$((n+1)); [[ $n -gt 120 ]] && stop "a listener on :8081 for 2 h before $name"
        echo "$(date -Is) [$name] :8081 has a listener (wait $n of 120)" >> "$D"
        sleep 60
    done
    [[ $n -gt 0 ]] && echo "$(date -Is) [$name] :8081 empty after $n waits" >> "$D"
}
drop_lock() {   # $1 = step name : release, close, 30 s for the others
    flock -u 9; exec 9>&-
    echo "$(date -Is) [$1] lock released" >> "$D"
    sleep 30
}
wait_ok() {   # $1 = step name : guard (retry up to 2 h), then the old procscan
    local name="$1" n=0 g
    while :; do
        bash "$E/guard.sh" "$E/$name.guard.log"; g=$?
        [[ $g -eq 0 ]] && break
        [[ $g -eq 2 ]] && stop "a stop signal is blocked before $name (see $name.guard.log)"
        n=$((n+1)); [[ $n -gt 120 ]] && stop "guard busy (process / disk / memory) for 2 h before $name"
        echo "$(date -Is) [$name] guard busy (try $n): $(tail -3 "$E/$name.guard.log" | head -1 | cut -c1-200)" >> "$D"
        sleep 60
    done
    echo "$(date -Is) [$name] guard ok: $(grep -E 'guard: [0-9]+ matching|SigBlk &' "$E/$name.guard.log" | tail -2 | tr '\n' ' ')" >> "$D"
    python3 "$E/procscan.py" "$D" 9>&- || stop "procscan: other mutate_/probe.py processes before $name"
}
guarded() {   # guarded <name> <cap seconds> <logfile of the step> <cmd...> : mexec + watchdog; the step's own verdict is its log's last line
    local name="$1" cap="$2" log="$3"; shift 3
    local t0 t1 W rc p
    take_lock "$name"
    wait_ok "$name"
    rm -f "$E/.sid.$name"
    echo "$(date -Is) [$name] start (cap ${cap}s)" >> "$D"
    t0=$(date +%s)
    # the watchdog: its own session; after <cap> s it stops the step's session (the pid the step wrote to .sid.<name>)
    setsid bash -c 'sleep "$1"; sid=$(cat "$2" 2>/dev/null); [ -n "$sid" ] && bash "$3" "$sid" "$4" "$5" "$6"' _ "$cap" "$E/.sid.$name" "$E/stopsess.sh" "$name" "$D" "$log" 9>&- &
    W=$!
    setsid --wait nice -n 19 bash "$E/mexec.sh" "$E/$name.guard.log" bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$E/.sid.$name" "$@" 9>&-
    rc=$?
    for p in $(ps -o pid= -s "$W" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
    wait "$W" 2>/dev/null
    t1=$(date +%s)
    echo "$(date -Is) [$name] end wall=$((t1-t0))s exit=$rc :: last line of $(basename "$log"): $(tail -1 "$log" 2>/dev/null | cut -c1-120) :: $(grep -E 'mutation gate:|mutations,|cells ok|FAILURES=|survived|^ok:|^Ran |^OK|^FAILED|ALL CHECKS|NOT ALL|S0 verdict|S0 checks|^GATE' "$log" 2>/dev/null | tail -2 | cut -c1-200 | tr '\n' ' ')" >> "$D"
    drop_lock "$name"
}
run() {   # run <name> <cmd...> : through the runlog $RL, log $E/<name>.log
    local name="$1"; shift
    guarded "$name" "${CAPS[$name]:-$CAP}" "$E/$name.log" bash "$RL" "$E/$name.log" "$@"
}
declare -A CAPS=([mutate_table_journal]=5400 [mutate_roles_binding]=6000 [klane]=2400 [mutate_table_entry]=3000 [mutate_stack_telemetry_identity]=3600 [test_ndt_app_package]=3600 )
stage_note() { echo "$(date -Is) ===== STAGE $1 $2 (epoch $(date +%s))" >> "$D"; }

stage_C() {
    stage_note C begin
    RL=$E/runlog.sh
    run mutate_table_journal         bash tests/shell/mutate_table_journal.sh
    run mutate_table_entry           bash tests/shell/mutate_table_entry.sh
    run mutate_table_entry_owner     bash tests/shell/mutate_table_entry_owner.sh
    run mutate_p4_rule_install_time  bash tests/shell/mutate_p4_rule_install_time.sh
    run mutate_roles_binding         bash tests/shell/mutate_roles_binding.sh
    run mutate_p4_exercise_tools     bash tests/shell/mutate_p4_exercise_tools.sh
    run mutate_rule_journal_is_wired bash tests/shell/mutate_rule_journal_is_wired.sh
    run mutate_app_package           bash tests/shell/mutate_app_package.sh
    run mutate_telemetry_by_name     bash tests/shell/mutate_telemetry_by_name.sh
    run mutate_p4_priority_refusal   bash tests/shell/mutate_p4_priority_refusal.sh
    run mutate_p4_probe              bash tests/shell/mutate_p4_probe.sh
    run mutate_l1_shell_scoring      bash tests/shell/mutate_l1_shell_scoring.sh
    run test_l1_shell_scoring        bash tests/shell/test_l1_shell_scoring.sh
    run check_test_tmpdirs           $PY tests/shell/check_test_tmpdirs.py
    run check_gate_anchors           $PY tests/shell/check_gate_anchors.py HEAD
    run p4lane                       "$E/ci-r2.sh" "$C" "$CI/p4lane.sh"
    run klane                        "$E/ci-r2.sh" "$C" "$CI/klane.sh"
    run no_stray_table_journal       bash tests/shell/check_no_stray_table_journal.sh
    run dot_run_after                bash -c 'cd p4_proxy && if [ -e .run ]; then echo "p4_proxy/.run EXISTS:"; find .run | head; exit 1; else echo "p4_proxy/.run does not exist"; fi'
    run p4h.cells.py312    $PY312 tests/python/test_p4_health_cells.py
    run p4h.cells.py38     $PY38  tests/python/test_p4_health_cells.py
    run p4h.collect.py312  $PY312 tests/python/test_p4_health_collect.py
    run p4h.collect.py38   $PY38  tests/python/test_p4_health_collect.py
    run p4h.recover        bash tests/shell/test_p4_health_recover.sh
    run p4h.gate_scripts   bash tests/shell/test_p4_health_gate_scripts.sh
    # the extra: how r5 ran the cells suite (C5/p4_health_cells_tests.log line 2), from the repo root
    run p4h.cells.unittest_root $PY -m unittest tests.python.test_p4_health_cells
    guarded s0 1200 "$E/s0.log" bash "$E/s0_run.sh" "$C"
    guarded trial-final 1800 "$E/trial-final.log" bash "$E/trial_run.sh" "$C" final
    run journal_tests_seen_red   python3 "$E/seen_red.py" "$C" "$E/mutate_table_journal.log" tests.test_table_entry_journal tests.test_table_entry_replay
    run mutate_stack_telemetry_identity bash tests/shell/mutate_stack_telemetry_identity.sh
    run test_ndt_app_package            bash tests/shell/test_ndt_app_package.sh
    { echo "commit $(git rev-parse HEAD)"; echo "command: git rev-parse $M5:tools/p4_health"; echo "$(git rev-parse "$M5:tools/p4_health")  (expected fd872b3ddb9d6eaa87d264675c8aaabcbabf2c26)"; } > "$E/p4_health_tree.log"
    echo "$(date -Is) [p4_health_tree] $(tail -1 "$E/p4_health_tree.log")" >> "$D"
    stage_note C end
}

stage_D() {
    stage_note D begin
    # the lock, :8081 wait, guard and procscan are taken per shard inside chain_mut.sh
    ( setsid --wait bash "$E/chain_mut.sh" "$C" ) >> "$E/chain_mut.stdout" 2>&1 9>&-
    echo "$(date -Is) [chain_mut] exit $?; GATE.log last lines: $(tail -3 "$E/GATE.log" 2>/dev/null | cut -c1-300 | tr '\n' '|')" >> "$D"
    stage_note D end
}

for s in "$@"; do case "$s" in C) stage_C;; D) stage_D;; esac; done
echo "$(date -Is) mgrun end" >> "$D"
touch "$E/mgrun.done"
