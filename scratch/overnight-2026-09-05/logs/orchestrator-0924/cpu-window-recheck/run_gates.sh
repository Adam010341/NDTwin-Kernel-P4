#!/usr/bin/env bash
# Run this directory's gates on the worktree's HEAD, one log each under logs/gates-0910/.
# [Co-developed with claude code -- Adam]
# Usage: run_gates.sh <worktree>
set -uo pipefail
WT="$1"
D="$WT/doc/audit/2026-09-19_telemetry-three-groups"
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
VPY=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python
CPY=/home/adam/miniconda3/bin/python3
H="$(git -C "$WT" rev-parse --short=8 HEAD)"
DIRTY="$(git -C "$WT" status --short -- "$D" | wc -l)"
export PYTHONDONTWRITEBYTECODE=1

header() {   # header <name> <title> <interpreter> <why> <command>
    printf '### %s -- %s\n' "$1" "$2"
    printf '# tree:        %s\n' "$D"
    printf '# head:        %s (%s uncommitted path(s) under the round directory)\n' "$H" "$DIRTY"
    printf '# when:        %s\n' "$(date -u '+%F %T UTC')"
    printf '# interpreter: %s\n' "$3"
    printf '# why:         %s\n' "$4"
    printf '# command:     %s\n' "$5"
    printf '###\n'
}

run() {   # run <name> <title> <interpreter> <why> <command...>
    local name="$1" title="$2" interp="$3" why="$4"; shift 4
    local log="$L/$name.p4c-$H.log"
    { header "$name" "$title" "$interp" "$why" "$*"; ( cd "$D" && "$@" ) 2>&1; rc=$?
      printf '\n### rc=%s\n' "$rc"; } > "$log" 2>&1
    echo "$name rc=$(tail -1 "$log" | sed 's/### rc=//')  -> $log"
}

run unit-venv "unit tests, the project gate interpreter" "$VPY" \
    "no matplotlib, so RenderTest skips here" \
    bash -c "cd tests && $VPY -m unittest discover -v -s ."
run unit-py3 "unit tests with matplotlib (RenderTest draws the three figures into a temp dir)" "$CPY" \
    "the only run that executes plot.py over a summary carrying the new cpu_window block" \
    bash -c "cd tests && $CPY -c 'import matplotlib; print(\"# matplotlib\", matplotlib.__version__)' && $CPY -m unittest discover -v -s ."
run offline-round "offline whole-round suite (E_DRIVER unset)" "bash" \
    "the driver is untouched; the gate's shell mutations run this suite" \
    env -u E_DRIVER tests/test_drive_e_offline.sh
run hazard-scan "hazard_scan.py over the three round scripts and the mutation gate" "$VPY" \
    "the gate changed (M-E49..M-E53, C-E3)" \
    "$VPY" tests/hazard_scan.py drive_e.sh run_group_arm.sh sample_error.sh tests/mutate_analyse.sh
run anchor-sweep "tests/anchor_sweep.py: the gate's anchors AND the external ones" "$VPY" \
    "five mutations and one control added" \
    "$VPY" tests/anchor_sweep.py
run check_gate_anchors "tests/shell/check_gate_anchors.py HEAD -- the repo-wide gate anchor checker" \
    "/usr/bin/python3" "repo-wide checker; it does not scan this gate (the anchor sweep does)" \
    bash -c "cd '$WT' && /usr/bin/python3 tests/shell/check_gate_anchors.py HEAD"
run test_mutate_gate "tests/test_mutate_gate.sh -- the gate refuses correctly when it CANNOT test" "bash" \
    "the gate gained mutations; its refusal paths must still fire" \
    tests/test_mutate_gate.sh
run red-cpuwin-reproduced "this head's tests against analyse.py from 30aa500c (the base)" "$VPY" \
    "the tests-only commit's climb case was edited in the fix commit; this is the final test file seen red" \
    "$VPY" tests/red_against.py --rev 30aa500c --file analyse.py \
    --why "RED RUN cpu-window, reproduced at the final head: this head's tests against analyse.py from 30aa500c"
run mutate "mutation gate -- doc/audit/2026-09-19_telemetry-three-groups" "$VPY" \
    "M-E49..M-E53 and C-E3 added" \
    env PROXY_PY="$VPY" tests/mutate_analyse.sh
