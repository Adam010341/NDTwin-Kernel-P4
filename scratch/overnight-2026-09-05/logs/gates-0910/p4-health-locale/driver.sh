#!/usr/bin/env bash
# driver.sh <clone> : the checks for feat/p4-health-locale, one at a time, in the throwaway clone. NOT the full gate.
# [Co-developed with claude code -- Adam]
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-locale
C="$1"; D="$L/driver.log"
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/p4hl/tmp
cd "$C" || exit 2
echo "$(date -Is) driver start pid $$, clone HEAD $(git rev-parse HEAD), LANG=${LANG:-} LC_ALL=${LC_ALL:-}" >> "$D"
run() {
    local name="$1"; shift
    local avail; avail=$(free -m | awk 'NR==2{print $7}')
    while [[ "$avail" -lt 1800 ]]; do echo "$(date -Is) [$name] waiting: available $avail MB" >> "$D"; sleep 60; avail=$(free -m | awk 'NR==2{print $7}'); done
    echo "$(date -Is) [$name] start (avail ${avail} MB)" >> "$D"
    setsid --wait nice -n 19 bash "$L/runlog.sh" "$L/$name.log" "$@"
    echo "$(date -Is) [$name] end rc=$? :: $(grep -E 'mutations,|^Ran |^OK|^FAILED|ALL CHECKS|checks' "$L/$name.log" | tail -2 | tr '\n' ' ')" >> "$D"
}
PY=p4_proxy/venv/bin/python
PY38=/home/adam/miniconda3/envs/ryu-env/bin/python
run p4h.cells          $PY   tests/python/test_p4_health_cells.py
run p4h.cells.py38     $PY38 tests/python/test_p4_health_cells.py
run p4h.collect        $PY   tests/python/test_p4_health_collect.py
run p4h.collect.py38   $PY38 tests/python/test_p4_health_collect.py
run p4h.recover        bash tests/shell/test_p4_health_recover.sh
run p4h.gate_scripts   bash tests/shell/test_p4_health_gate_scripts.sh
run check_gate_anchors $PY tests/shell/check_gate_anchors.py HEAD
run mutate_c2r8_partial env ONLY_LABEL_PREFIX=C2R8- bash tests/shell/mutate_p4_health.sh
echo "$(date -Is) driver end" >> "$D"
