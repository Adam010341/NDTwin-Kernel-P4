#!/usr/bin/env bash
# driver.sh <clone> : the gates for feat/p4-ternary-replay-c, one at a time, in the throwaway clone.
# [Co-developed with claude code -- Adam]
# Before each: df -m / (wait while below 1800 MB) and a /proc scan for other mutate_/probe.py processes (wait while any).
# Writes nothing outside the log dir and the clone. driver.done is NOT written here; the caller writes it after reading
# the logs. The mutate_p4_health shards come last (chain_mut.sh), because they take hours.
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r2
C="$1"
CI=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/pr-cut2
D="$L/driver.log"
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/c-replay/tmp
mkdir -p "$TMPDIR"
cd "$C" || { echo "STOPPED: no clone at $C" > "$L/STOPPED"; exit 2; }
echo "$(date -Is) driver start pid $$, clone HEAD $(git rev-parse HEAD), LANG=${LANG:-} LC_ALL=${LC_ALL:-}" >> "$D"
wait_ok() {   # $1 = gate name
    local n=0 free
    while :; do
        free=$(df -m / | awk 'NR==2{print $4}')
        echo "$(date -Is) [$1] df -m /: ${free} MB free" >> "$D"
        mem=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
        echo "$(date -Is) [$1] MemAvailable: ${mem} MB" >> "$D"
        [[ "$free" -ge 1800 && "$mem" -ge 1800 ]] && break
        n=$((n+1)); [[ $n -gt 120 ]] && { echo "STOPPED: disk or available memory below 1800 MB for 2 h before $1" > "$L/STOPPED"; exit 2; }
        sleep 60
    done
    n=0
    while :; do
        echo "$(date -Is) [$1] /proc scan" >> "$D"
        python3 "$L/procscan.py" "$D" && break
        n=$((n+1)); [[ $n -gt 180 ]] && { echo "STOPPED: other mutate_/probe.py processes for 3 h before $1" > "$L/STOPPED"; exit 2; }
        sleep 60
    done
}
run() {   # $1 = log name, rest = command
    local name="$1" rc; shift
    wait_ok "$name"
    echo "$(date -Is) [$name] start" >> "$D"
    setsid --wait nice -n 19 bash "$L/runlog.sh" "$L/$name.log" "$@"
    rc=$?
    echo "$(date -Is) [$name] end rc=$rc :: $(grep -E 'mutation gate:|mutations,|cells ok|FAILURES=|survived|^ok:|^Ran |^OK|^FAILED|ALL CHECKS|S0 ' "$L/$name.log" | tail -2 | tr '\n' ' ')" >> "$D"
}
PY=p4_proxy/venv/bin/python
PY38=/home/adam/miniconda3/envs/ryu-env/bin/python
PY312=/usr/bin/python3.12
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
run p4lane                       "$CI/ci-r2.sh" "$C" "$CI/p4lane.sh"
run klane                        "$CI/ci-r2.sh" "$C" "$CI/klane.sh"
# m5: one process over the whole of p4_proxy/tests, from inside p4_proxy, then whether p4_proxy/.run exists at all.
run no_stray_table_journal       bash tests/shell/check_no_stray_table_journal.sh
run dot_run_after                bash -c 'cd p4_proxy && if [ -e .run ]; then echo "p4_proxy/.run EXISTS:"; find .run | head; exit 1; else echo "p4_proxy/.run does not exist"; fi'
# the four p4_health suites, on both interpreters
run p4h.cells.py312    $PY312 tests/python/test_p4_health_cells.py
run p4h.cells.py38     $PY38  tests/python/test_p4_health_cells.py
run p4h.collect.py312  $PY312 tests/python/test_p4_health_collect.py
run p4h.collect.py38   $PY38  tests/python/test_p4_health_collect.py
# the two shell suites name no interpreter (recover.sh is bash; the gate-script suite runs the gate with PYTHON=/bin/true)
run p4h.recover        bash tests/shell/test_p4_health_recover.sh
run p4h.gate_scripts   bash tests/shell/test_p4_health_gate_scripts.sh
# the offline S0 and the trial, each with /proc scans before, during and after
wait_ok s0;    echo "$(date -Is) [s0] start" >> "$D";    bash "$L/s0_run.sh" "$C";              echo "$(date -Is) [s0] end rc=$? :: $(grep -E 'S0 verdict' "$L/s0.log" | tail -1)" >> "$D"
wait_ok trial; echo "$(date -Is) [trial-final] start" >> "$D"; bash "$L/trial_run.sh" "$C" final; echo "$(date -Is) [trial-final] end rc=$? :: $(grep -E 'ALL CHECKS|NOT ALL' "$L/trial-final.log" | tail -1)" >> "$D"
# which journal and replay tests the journal gate saw red, with a commit line and an rc line
run journal_tests_seen_red   python3 "$L/seen_red.py" "$C" "$L/mutate_table_journal.log" tests.test_table_entry_journal tests.test_table_entry_replay
echo "$(date -Is) driver end" >> "$D"
