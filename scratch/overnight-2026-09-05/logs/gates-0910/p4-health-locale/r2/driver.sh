#!/usr/bin/env bash
# driver.sh <clone> : round 9's pre-gate checks for feat/p4-health-locale, one at a time, in the throwaway clone.
# NOT the full gate. Each step runs in a session of its own (setsid); a TERM/INT/HUP to the driver kills the running
# step's whole session and waits until no process of it is left before the driver exits, so no suite outlives it.
# [Co-developed with claude code -- Adam]
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-locale/r2
C="$1"; D="$L/driver.log"
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/p4hl2/tmp
mkdir -p "$TMPDIR"
cd "$C" || exit 2
STEP_SID=""
session_left() { ps -o pid= -s "$1" 2>/dev/null | tr -d ' ' | grep -v '^$'; }
stop_step() {
    local sig="$1"
    echo "$(date -Is) driver got $sig: stopping step session ${STEP_SID:-none}" >> "$D"
    if [[ -n "$STEP_SID" ]]; then
        kill -TERM -- "-$STEP_SID" 2>/dev/null
        for _ in $(seq 1 30); do [[ -z "$(session_left "$STEP_SID")" ]] && break; sleep 1; done
        [[ -n "$(session_left "$STEP_SID")" ]] && kill -KILL -- "-$STEP_SID" 2>/dev/null
        for _ in $(seq 1 30); do [[ -z "$(session_left "$STEP_SID")" ]] && break; sleep 1; done
        echo "$(date -Is) session $STEP_SID left: $(session_left "$STEP_SID" | tr '\n' ' ')" >> "$D"
    fi
    exit 3
}
trap 'stop_step TERM' TERM; trap 'stop_step INT' INT; trap 'stop_step HUP' HUP
echo "$(date -Is) driver start pid $$ pgid $(ps -o pgid= -p $$ | tr -d ' ') sid $(ps -o sid= -p $$ | tr -d ' '), clone HEAD $(git rev-parse HEAD), LANG=${LANG:-} LC_ALL=${LC_ALL:-}" >> "$D"
run() {
    local name="$1"; shift
    local avail; avail=$(free -m | awk 'NR==2{print $7}')
    while [[ "$avail" -lt 1800 ]]; do echo "$(date -Is) [$name] waiting: available $avail MB" >> "$D"; sleep 60; avail=$(free -m | awk 'NR==2{print $7}'); done
    echo "$(date -Is) [$name] start (avail ${avail} MB)" >> "$D"
    setsid nice -n 19 bash "$L/runlog.sh" "$L/$name.log" "$@" &
    STEP_SID=$!
    wait "$STEP_SID"; local rc=$?
    # a step's children that are still in its session (none should be) are named, then stopped
    local left; left="$(session_left "$STEP_SID")"
    [[ -n "$left" ]] && { echo "$(date -Is) [$name] session $STEP_SID still has: $left -- stopping it" >> "$D"; kill -TERM -- "-$STEP_SID" 2>/dev/null; sleep 2; }
    STEP_SID=""
    echo "$(date -Is) [$name] end rc=$rc :: $(grep -E 'mutations,|^Ran |^OK|^FAILED|ALL CHECKS|checks|^GATE|^NOT THE GATE' "$L/$name.log" | tail -2 | tr '\n' ' ')" >> "$D"
}
PY=p4_proxy/venv/bin/python
PY38=/home/adam/miniconda3/envs/ryu-env/bin/python
HUP=(-c 'import os, signal, sys; signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGHUP]); os.execv(sys.argv[1], sys.argv[1:])')
STEPS="${STEPS:-anchors suites10 once sum partial}"
for step in $STEPS; do case "$step" in
anchors)
    run anchor_check env ANCHOR_CHECK=1 bash tests/shell/mutate_p4_health.sh
    run check_gate_anchors $PY tests/shell/check_gate_anchors.py HEAD
    run bare_sort_grep bash -c "grep -nE '[|] *sort( |\$)' tests/shell/mutate_p4_health.sh | grep -vF 'LC_ALL=C sort'; echo \"bare (not LC_ALL=C) sorts in a pipe: \$(grep -nE '[|] *sort( |\$)' tests/shell/mutate_p4_health.sh | grep -vcF 'LC_ALL=C sort')\"; grep -nE '[|] *sort( |\$)' tests/shell/mutate_p4_health.sh";;
suites10)
    for i in 01 02 03 04 05 06 07 08 09 10; do
        run p4h.cells.r$i        $PY   tests/python/test_p4_health_cells.py
        run p4h.cells.py38.r$i   $PY38 tests/python/test_p4_health_cells.py
        run p4h.collect.r$i      $PY   tests/python/test_p4_health_collect.py
        run p4h.collect.py38.r$i $PY38 tests/python/test_p4_health_collect.py
    done;;
once)
    run p4h.recover        bash tests/shell/test_p4_health_recover.sh
    run p4h.gate_scripts   bash tests/shell/test_p4_health_gate_scripts.sh
    run p4h.cells.sighup_blocked_parent $PY "${HUP[@]}" $PY tests/python/test_p4_health_cells.py;;
sum)
    run sum_real_shards bash "$L/sumcheck.sh";;
partial)
    for pre in C2R9- C2R8- C2R5-6 C2R7-1; do
        run "mutate_partial_${pre%-}" env ONLY_LABEL_PREFIX=$pre bash tests/shell/mutate_p4_health.sh
    done;;
esac; done
echo "$(date -Is) driver end" >> "$D"
